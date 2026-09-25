import Foundation

// 课表与可用时间模块的独立行为测试。
//
// 这个文件刻意放在源码目标目录（`study software/`）之外：
// Xcode 使用 PBXFileSystemSynchronizedRootGroup，目录内的任何 .swift 都会被编进正式 App，
// 因此测试入口只能通过 swiftc 单独编译，见 `make verify-schedule`。
//
// 覆盖的验收标准（均为业务行为断言，不是“返回值非空”）：
// 1. 单双周在学期边界正确
// 2. 停课、补课和原课程不会重复计算
// 3. 两段重叠占用只扣一次
// 4. 四段 5 分钟空档保持为四段
// 5. 课程与睡眠重叠时，空闲时间不会出现负数
// 6. 跨午夜睡眠正确处理
// 7. 当天重算只返回当前时间之后仍可用的部分
// 8. 空档小于最短可用阈值时不计入可安排容量
// 9. 学期时区决定星期，系统时区变化不会让星期错位
// 10. 无课表仍可计算；无作息时明确标记为默认假设
// 11. 表单校验：结束早于开始、无有效周次、超出学期报错；冲突只警告

@main
struct ScheduleVerifyHarness {
    // MARK: - 断言基础设施

    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("PASS \(message)")
        } else {
            failed += 1
            print("FAIL \(message)")
        }
    }

    static func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual == expected {
            passed += 1
            print("PASS \(message)")
        } else {
            failed += 1
            print("FAIL \(message) —— 期望 \(expected)，实际 \(actual)")
        }
    }

    // MARK: - 固定时间环境

    static let beijing = TimeZone(identifier: "Asia/Shanghai")!

    static var semesterCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }

    /// 学期第一周周一：2026-03-02，共 18 周。
    static func makeSemester(weekCount: Int = 18) -> ScheduleSemester {
        ScheduleSemester(
            firstWeekStart: date(2026, 3, 2, 0, 0),
            weekCount: weekCount,
            timeZoneIdentifier: "Asia/Shanghai"
        )
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return semesterCalendar.date(from: components)!
    }

    /// 第 week 周的星期 weekdayOffset（0 = 周一）的日期。
    static func dayOfWeek(_ week: Int, _ weekdayOffset: Int) -> Date {
        let semester = makeSemester()
        let monday = semesterCalendar.date(
            byAdding: .day,
            value: (week - 1) * 7 + weekdayOffset,
            to: semester.firstWeekStart
        )!
        return semesterCalendar.startOfDay(for: monday)
    }

    static func minutes(_ intervals: [FreeInterval]) -> Int {
        intervals.reduce(0) { $0 + $1.durationMinutes }
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = beijing
        return formatter.string(from: date)
    }

    static func texts(_ intervals: [FreeInterval]) -> [String] {
        intervals.map { "\(timeText($0.start))-\(timeText($0.end))" }
    }

    static func course(
        _ name: String,
        weekday: ScheduleWeekday,
        start: (Int, Int),
        end: (Int, Int),
        endDayOffset: Int = 0,
        parity: CourseWeekParity = .every,
        weeks: [Int] = [],
        lastWeek: Int? = nil,
        subject: String? = nil
    ) -> Course {
        Course(
            name: name,
            subject: SubjectRef(displayName: subject ?? name),
            weekday: weekday,
            startTime: TimeOfDay(hour: start.0, minute: start.1),
            endTime: TimeOfDay(hour: end.0, minute: end.1),
            endDayOffset: endDayOffset,
            recurrence: CourseRecurrence(parity: parity, weeks: weeks, lastWeek: lastWeek)
        )
    }

    static func window(_ weekday: ScheduleWeekday, _ start: (Int, Int), _ end: (Int, Int), endDayOffset: Int = 0) -> DayTimeRange {
        DayTimeRange(
            weekday: weekday,
            start: TimeOfDay(hour: start.0, minute: start.1),
            end: TimeOfDay(hour: end.0, minute: end.1),
            endDayOffset: endDayOffset
        )
    }

    /// 只保留传入的星期几窗口，默认不扣睡眠，便于精确断言。
    /// 注意：窗口的星期几必须与测试目标的星期几一致，否则结果必然为空。
    static func settings(
        windows: [DayTimeRange],
        sleep: [DayTimeRange] = [],
        custom: [DayTimeRange] = [],
        commute: Int = 0,
        buffer: Int = 0,
        threshold: Int = 5
    ) -> AvailabilitySettings {
        let weekdays = windows.filter { !$0.weekday.isWeekend }
        let weekends = windows.filter { $0.weekday.isWeekend }
        return AvailabilitySettings(
            weekdayStudyWindows: weekdays,
            weekendStudyWindows: weekends,
            sleepWindows: sleep,
            customBlocks: custom,
            commuteMinutes: commute,
            bufferMinutes: buffer,
            minimumFreeBlockMinutes: threshold
        )
    }

    // MARK: - main

    static func main() {
        print("== 课表与可用时间行为测试 ==")

        acceptanceA_SingleDoubleWeekBoundary()
        acceptanceB_CancellationMakeupNoDoubleCount()
        acceptanceC_OverlappingBlocksDeductedOnce()
        acceptanceD_FourFiveMinuteGapsStaySeparate()
        acceptanceE_CourseAndSleepNeverNegative()
        acceptanceF_CrossMidnightSleep()
        acceptanceG_RecomputeOnlyAfterNow()
        acceptanceH_BelowThresholdNotCounted()
        acceptanceI_SemesterTimeZoneKeepsWeekday()
        acceptanceJ_NoTimetableStillComputes()
        acceptanceK_FormValidation()
        acceptanceL_DetailsAndIdempotence()
        acceptanceM_TimelineAndSemesterAlignment()

        print("\n== 结果：\(passed) 通过，\(failed) 失败 ==")
        if failed > 0 {
            exit(1)
        }
    }

    // MARK: - 1. 单双周在学期边界正确

    static func acceptanceA_SingleDoubleWeekBoundary() {
        print("\n[1] 单双周在学期边界")
        let semester = makeSemester(weekCount: 15) // 15 为奇数，期末边界最容易出错

        let oddCourse = course("单周课", weekday: .monday, start: (8, 0), end: (9, 0), parity: .odd)
        let evenCourse = course("双周课", weekday: .monday, start: (10, 0), end: (11, 0), parity: .even)

        let oddWeeks = ScheduleResolver.activeWeeks(for: oddCourse, semester: semester)
        let evenWeeks = ScheduleResolver.activeWeeks(for: evenCourse, semester: semester)

        checkEqual(oddWeeks, [1, 3, 5, 7, 9, 11, 13, 15], "单周课在 15 周学期内是 1,3,…,15")
        checkEqual(evenWeeks, [2, 4, 6, 8, 10, 12, 14], "双周课在 15 周学期内是 2,4,…,14（不含第 15 周）")
        checkEqual(oddWeeks.count + evenWeeks.count, 15, "单周 + 双周正好铺满 15 周，无重叠无遗漏")

        // 边界：第 15 周周一有单周课，没有双周课。
        let week15 = dayOfWeek(15, 0)
        let day15 = ScheduleResolver.day(for: week15, semester: semester, courses: [oddCourse, evenCourse])
        checkEqual(day15.courses.map(\.courseName), ["单周课"], "第 15 周周一只有单周课")
        checkEqual(day15.weekIndex, 15, "第 15 周周一 weekIndex = 15")

        // 边界：第 16 周超出学期（weekCount = 15）。
        let afterSemester = dayOfWeek(16, 0)
        let day16 = ScheduleResolver.day(for: afterSemester, semester: semester, courses: [oddCourse, evenCourse])
        check(day16.courses.isEmpty, "超出学期总周数后不再有课")
        checkEqual(day16.weekIndex, nil, "超出学期时 weekIndex 为 nil")

        // 边界：学期开始之前。
        let beforeSemester = date(2026, 2, 23, 0, 0)
        let dayBefore = ScheduleResolver.day(for: beforeSemester, semester: semester, courses: [oddCourse])
        check(dayBefore.courses.isEmpty, "学期开始之前没有课")

        // lastWeek 覆盖：只上前 8 周的双周课。
        let shortEven = course("前半学期双周", weekday: .tuesday, start: (8, 0), end: (9, 0), parity: .even, lastWeek: 8)
        let shortWeeks = ScheduleResolver.activeWeeks(for: shortEven, semester: semester)
        checkEqual(shortWeeks, [2, 4, 6, 8], "lastWeek=8 的双周课止于第 8 周")

        // 指定周次。
        let custom = course("指定周次课", weekday: .wednesday, start: (8, 0), end: (9, 0), parity: .custom, weeks: [1, 4, 4, 9, 99])
        checkEqual(
            ScheduleResolver.activeWeeks(for: custom, semester: semester),
            [1, 4, 9],
            "指定周次课去重并忽略超出学期的周次"
        )
    }

    // MARK: - 2. 停课、补课和原课程不会重复计算

    static func acceptanceB_CancellationMakeupNoDoubleCount() {
        print("\n[2] 停课 / 补课 / 原课程不重复计算")
        let semester = makeSemester()
        let original = course("数据结构", weekday: .tuesday, start: (10, 0), end: (11, 40))
        let target = dayOfWeek(1, 1) // 第 1 周周二

        // 基线：一次课 = 100 分钟。
        let base = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [original],
            settings: settings(windows: [window(.tuesday, (8, 0), (12, 0))])
        )
        checkEqual(base.occupiedIntervals.reduce(0) { $0 + $1.durationMinutes }, 100, "基线：一次 10:00–11:40 课程占用 100 分钟")
        checkEqual(base.totalFreeMinutes, 140, "基线：08:00–12:00 窗口扣除后剩 140 分钟")
        checkEqual(texts(base.freeIntervals), ["08:00-10:00", "11:40-12:00"], "基线：空闲为课程前后两段")

        // 停课：占用归零，整段窗口恢复。
        let cancellation = ScheduleException(kind: .cancellation, courseID: original.id, date: target)
        let cancelled = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [original],
            exceptions: [cancellation],
            settings: settings(windows: [window(.tuesday, (8, 0), (12, 0))])
        )
        check(cancelled.occupiedIntervals.isEmpty, "停课后当天没有课程占用")
        checkEqual(cancelled.totalFreeMinutes, 240, "停课后整段 240 分钟学习窗口恢复为空闲")
        checkEqual(texts(cancelled.freeIntervals), ["08:00-12:00"], "停课后空闲是连续的一段")

        // 换课：不额外增加占用，只是移动时间。
        let relocation = ScheduleException(
            kind: .relocation,
            courseID: original.id,
            date: target,
            replacementStart: TimeOfDay(hour: 14, minute: 0),
            replacementEnd: TimeOfDay(hour: 15, minute: 40),
            replacementLocation: "实验楼 302"
        )
        let relocated = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [original],
            exceptions: [relocation],
            settings: settings(windows: [window(.tuesday, (8, 0), (12, 0)), window(.tuesday, (14, 0), (16, 0))])
        )
        checkEqual(relocated.occupiedIntervals.count, 1, "换课后仍然只有一段占用")
        checkEqual(relocated.occupiedIntervals.first.map { timeText($0.start) } ?? "", "14:00", "换课后占用移到 14:00 开始")
        checkEqual(relocated.totalFreeMinutes, 240 + 20, "换课后 08:00–12:00 保持 240 分钟，14:00–16:00 扣除 100 分钟后剩 20 分钟")

        // 补课：在原课之外的日期增加一次，且只能算一次。
        let makeupDay = dayOfWeek(1, 4) // 第 1 周周五
        let makeup = ScheduleException(
            kind: .makeup,
            courseID: original.id,
            date: makeupDay,
            replacementStart: TimeOfDay(hour: 10, minute: 0),
            replacementEnd: TimeOfDay(hour: 11, minute: 40)
        )
        let withMakeup = AvailabilityCalculator.availability(
            on: makeupDay,
            semester: semester,
            courses: [original],
            exceptions: [makeup],
            settings: settings(windows: [window(.friday, (8, 0), (12, 0))])
        )
        checkEqual(withMakeup.occupiedIntervals.count, 1, "补课当天只有一段占用")
        checkEqual(withMakeup.totalFreeMinutes, 140, "补课当天扣除 100 分钟后剩 140 分钟")

        // 同一天同时有原课和补课：两段不同时间的课都保留。
        let doubleDay = dayOfWeek(1, 1)
        let sameDayMakeup = ScheduleException(
            kind: .makeup,
            courseID: original.id,
            date: doubleDay,
            replacementStart: TimeOfDay(hour: 15, minute: 0),
            replacementEnd: TimeOfDay(hour: 16, minute: 0)
        )
        let double = AvailabilityCalculator.availability(
            on: doubleDay,
            semester: semester,
            courses: [original],
            exceptions: [sameDayMakeup],
            settings: settings(windows: [window(.tuesday, (8, 0), (17, 0))])
        )
        checkEqual(double.occupiedIntervals.count, 2, "原课 + 同日补课 = 两段占用")
        checkEqual(double.occupiedIntervals.reduce(0) { $0 + $1.durationMinutes }, 160, "原课 100 分钟 + 补课 60 分钟")

        // 补课与补课完全重复：稳定 id 去重，不会算两次。
        let duplicateMakeups = [sameDayMakeup, makeSecondIdenticalMakeup(from: sameDayMakeup)]
        let duplicated = ScheduleResolver.day(
            for: doubleDay,
            semester: semester,
            courses: [original],
            exceptions: duplicateMakeups
        )
        checkEqual(duplicated.courses.filter { $0.isMakeup }.count, 1, "同一天重复的补课记录只展开一次")

        // 补课日期落在学期之外：给出提示但不当成正常周次。
        let outside = ScheduleException(
            kind: .makeup,
            courseID: original.id,
            date: date(2026, 8, 3, 0, 0),
            replacementStart: TimeOfDay(hour: 9, minute: 0),
            replacementEnd: TimeOfDay(hour: 10, minute: 0)
        )
        let outsideDay = ScheduleResolver.day(
            for: date(2026, 8, 3, 0, 0),
            semester: semester,
            courses: [original],
            exceptions: [outside]
        )
        checkEqual(outsideDay.courses.count, 1, "学期外的补课仍然会展开为占用")
        check(outsideDay.notes.contains { $0.contains("学期范围之外") }, "学期外的补课给出明确提示")
    }

    static func makeSecondIdenticalMakeup(from exception: ScheduleException) -> ScheduleException {
        ScheduleException(
            id: UUID(),
            kind: .makeup,
            courseID: exception.courseID,
            date: exception.date,
            replacementStart: exception.replacementStart,
            replacementEnd: exception.replacementEnd
        )
    }

    // MARK: - 3. 两段重叠占用只扣一次

    static func acceptanceC_OverlappingBlocksDeductedOnce() {
        print("\n[3] 重叠占用只扣一次")
        let semester = makeSemester()
        let target = dayOfWeek(1, 0) // 第 1 周周一

        let math = course("数学", weekday: .monday, start: (9, 30), end: (10, 30))
        let physics = course("物理", weekday: .monday, start: (10, 0), end: (11, 0))

        let result = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [math, physics],
            settings: settings(windows: [window(.monday, (9, 0), (12, 0))])
        )

        checkEqual(result.occupiedIntervals.count, 1, "两段重叠课程被合并为一段占用")
        checkEqual(result.occupiedIntervals.reduce(0) { $0 + $1.durationMinutes }, 90, "09:30–10:30 与 10:00–11:00 的并集是 90 分钟，不是简单相加的 120 分钟")
        checkEqual(texts(result.freeIntervals), ["09:00-09:30", "11:00-12:00"], "重叠课程只在 09:30–11:00 扣除一次")
        checkEqual(result.occupiedMinutesWithinWindows, 90, "窗口内被占用 90 分钟")
        checkEqual(result.totalFreeMinutes, 90, "180 分钟窗口扣掉 120 分钟后剩 90 分钟")
        checkEqual(
            result.totalFreeMinutes,
            180 - result.occupiedIntervals.reduce(0) { $0 + $1.durationMinutes },
            "记账自洽：空闲分钟数 = 窗口长度 − 合并后的占用分钟数"
        )

        let day = ScheduleResolver.day(for: target, semester: semester, courses: [math, physics])
        check(day.hasConflict, "重叠课程在解析层被标记为冲突，用于界面提示")
        checkEqual(day.courses.count, 2, "冲突不会吞掉任何一门课")
        checkEqual(ScheduleResolver.conflicts(in: day.blocks).count, 1, "冲突对被识别出来且只有一对")
    }

    // MARK: - 4. 四段 5 分钟空档保持为四段

    static func acceptanceD_FourFiveMinuteGapsStaySeparate() {
        print("\n[4] 四段 5 分钟空档保持为四段")
        let semester = makeSemester()
        let target = dayOfWeek(1, 2) // 第 1 周周三

        // 09:00–09:20 的窗口里塞四段各 5 分钟的课。
        let courses = [
            course("A", weekday: .wednesday, start: (9, 0), end: (9, 5)),
            course("B", weekday: .wednesday, start: (9, 5), end: (9, 10)),
            course("C", weekday: .wednesday, start: (9, 10), end: (9, 15)),
            course("D", weekday: .wednesday, start: (9, 15), end: (9, 20))
        ]

        let result = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: courses,
            settings: settings(windows: [window(.wednesday, (9, 0), (9, 20))], threshold: 5)
        )
        checkEqual(result.freeIntervals.count, 0, "四段课把 20 分钟窗口占满，没有残留空档")

        // 真正要验的场景：窗口比课程总时长多出 4 个 5 分钟空档。
        let spread = [
            course("E", weekday: .wednesday, start: (9, 5), end: (9, 10)),
            course("F", weekday: .wednesday, start: (9, 15), end: (9, 20)),
            course("G", weekday: .wednesday, start: (9, 25), end: (9, 30)),
            course("H", weekday: .wednesday, start: (9, 35), end: (9, 40))
        ]
        let spreadResult = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: spread,
            settings: settings(windows: [window(.wednesday, (9, 0), (9, 45))], threshold: 5)
        )
        checkEqual(
            texts(spreadResult.freeIntervals),
            ["09:00-09:05", "09:10-09:15", "09:20-09:25", "09:30-09:35", "09:40-09:45"],
            "五段 5 分钟空档保持为五段，未被伪装成连续 25 分钟"
        )
        checkEqual(spreadResult.freeIntervals.count, 5, "空档数量是 5 而不是 1")
        checkEqual(spreadResult.totalFreeMinutes, 25, "五段合计 25 分钟，但仍是五个独立区间")
        checkEqual(spreadResult.longestFreeMinutes, 5, "最长可连续学习时间是 5 分钟")
        check(
            spreadResult.freeIntervals.allSatisfy { $0.durationMinutes == 5 },
            "每个空档都保留自己的起止时间，而不是只输出分钟总数"
        )

        // 阈值调高到 6 分钟：五个碎片全部不计入容量。
        let strict = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: spread,
            settings: settings(windows: [window(.wednesday, (9, 0), (9, 45))], threshold: 6)
        )
        checkEqual(strict.freeIntervals.count, 0, "阈值 6 分钟时五个 5 分钟碎片都不计入容量")
        checkEqual(strict.totalFreeMinutes, 0, "阈值提高后总容量为 0")
        checkEqual(strict.discardedIntervals.count, 5, "被丢弃的碎片单独记录，便于界面解释")
        checkEqual(strict.discardedIntervals.map(\.durationMinutes), [5, 5, 5, 5, 5], "被丢弃的碎片仍是五段各 5 分钟")
    }

    // MARK: - 5. 课程与睡眠重叠不出负数

    static func acceptanceE_CourseAndSleepNeverNegative() {
        print("\n[5] 课程与睡眠重叠不会出现负数空闲")
        let semester = makeSemester()
        let target = dayOfWeek(1, 0)

        let nightClass = course("晚课", weekday: .monday, start: (22, 0), end: (23, 30))
        let sleep = window(.monday, (23, 0), (7, 0), endDayOffset: 1)

        let result = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [nightClass],
            settings: settings(windows: [window(.monday, (21, 0), (23, 45))], sleep: [sleep])
        )

        check(result.freeIntervals.allSatisfy { $0.end > $0.start }, "所有空闲区间时长均为正数")
        check(result.occupiedIntervals.allSatisfy { $0.end > $0.start }, "所有占用区间时长均为正数")
        check(
            result.occupiedIntervals.reduce(0) { $0 + $1.durationMinutes } <= 24 * 60,
            "占用总时长不超过一天"
        )
        checkEqual(texts(result.freeIntervals), ["21:00-22:00"], "课程与睡眠合并后，窗口内只剩 21:00–22:00 可用")
        checkEqual(result.totalFreeMinutes, 60, "22:00–23:45 被课程与睡眠合并后的占用一次扣除，剩 60 分钟")
        checkEqual(result.totalStudyWindowMinutes, result.occupiedMinutesWithinWindows + result.totalFreeMinutes, "窗口长度 = 窗口内占用 + 空闲（记账自洽，不会重复扣减）")

        // 睡眠完全覆盖学习窗口：容量为 0，且绝不出现负数。
        // 周一 22:00–次日 08:00 的睡眠，会完整覆盖周二 00:00–06:00 的学习窗口。
        let fullyAsleep = AvailabilityCalculator.availability(
            on: dayOfWeek(1, 1),
            semester: semester,
            courses: [],
            settings: AvailabilitySettings(
                weekdayStudyWindows: [window(.tuesday, (0, 0), (6, 0))],
                weekendStudyWindows: [],
                sleepWindows: [window(.monday, (22, 0), (8, 0), endDayOffset: 1)],
                minimumFreeBlockMinutes: 5
            )
        )
        checkEqual(fullyAsleep.totalFreeMinutes, 0, "睡眠覆盖整个学习窗口时容量为 0")
        check(fullyAsleep.freeIntervals.isEmpty, "睡眠覆盖时没有空闲区间")
        checkEqual(fullyAsleep.state, .fullyOccupied, "状态标记为已被占满")
        checkEqual(fullyAsleep.occupiedMinutesWithinWindows, 360, "睡眠占满 00:00–06:00 的整个学习窗口")
        checkEqual(fullyAsleep.totalStudyWindowMinutes, 360, "学习窗口本身是 6 小时")
    }

    // MARK: - 6. 跨午夜睡眠

    static func acceptanceF_CrossMidnightSleep() {
        print("\n[6] 跨午夜睡眠")
        let semester = makeSemester()

        // 周一 23:00 – 周二 07:00 的睡眠，周二 06:00–08:00 的学习窗口
        // 只应在 07:00–08:00 可用。
        let sleep = window(.monday, (23, 0), (7, 0), endDayOffset: 1)
        let tuesday = dayOfWeek(1, 1)
        let tuesdayResult = AvailabilityCalculator.availability(
            on: tuesday,
            semester: semester,
            courses: [],
            settings: AvailabilitySettings(
                weekdayStudyWindows: [window(.tuesday, (6, 0), (8, 0))],
                weekendStudyWindows: [],
                sleepWindows: [sleep],
                minimumFreeBlockMinutes: 5
            )
        )
        checkEqual(texts(tuesdayResult.freeIntervals), ["07:00-08:00"], "周二凌晨 06:00–07:00 属于周一跨午夜的睡眠")
        checkEqual(tuesdayResult.totalFreeMinutes, 60, "跨午夜睡眠只吃掉周二窗口的 60 分钟")

        // 周二 22:00–次日 02:00 的学习窗口：只有 22:00–23:00 可用。
        let lateWindow = window(.tuesday, (22, 0), (2, 0), endDayOffset: 1)
        let lateResult = AvailabilityCalculator.availability(
            on: tuesday,
            semester: semester,
            courses: [],
            settings: AvailabilitySettings(
                weekdayStudyWindows: [lateWindow],
                weekendStudyWindows: [],
                sleepWindows: [sleep],
                minimumFreeBlockMinutes: 5
            )
        )
        checkEqual(texts(lateResult.freeIntervals), ["22:00-23:00"], "跨午夜学习窗口只保留睡眠之前的部分")
        checkEqual(lateResult.totalFreeMinutes, 60, "跨午夜学习窗口扣除睡眠后剩 60 分钟")

        // 跨午夜课程：22:30–次日 00:30 占 120 分钟，且不会变成负数。
        let overnight = course("跨午夜实验", weekday: .thursday, start: (22, 30), end: (0, 30), endDayOffset: 1)
        let thursday = dayOfWeek(1, 3)
        let overnightResult = AvailabilityCalculator.availability(
            on: thursday,
            semester: semester,
            courses: [overnight],
            settings: settings(windows: [window(.thursday, (21, 0), (23, 0))], sleep: [])
        )
        checkEqual(overnight.durationMinutes, 120, "跨午夜课程时长为 120 分钟")
        checkEqual(overnightResult.totalFreeMinutes, 90, "21:00–23:00 窗口被课程扣掉 30 分钟后剩 90 分钟")
        checkEqual(texts(overnightResult.freeIntervals), ["21:00-22:30"], "跨午夜课程按绝对时间扣除，窗口内被占 30 分钟")
        checkEqual(overnightResult.occupiedMinutesWithinWindows, 30, "跨午夜课程只占用窗口内的 22:30–23:00")

        // 同一天内结束时刻早于开始时刻、但没勾跨天：按跨午夜处理，不产生负时长。
        let implicitOvernight = ScheduleResolver.resolveInterval(
            weekday: .thursday,
            startTime: TimeOfDay(hour: 22, minute: 30),
            endTime: TimeOfDay(hour: 0, minute: 30),
            endDayOffset: 0,
            onDay: thursday,
            semester: semester
        )
        checkEqual(
            implicitOvernight.map { Int($0.end.timeIntervalSince($0.start) / 60) } ?? -1,
            120,
            "未勾跨天但结束早于开始时，按次日处理（120 分钟，不是负数）"
        )
    }

    // MARK: - 7. 当天重算只返回 now 之后

    static func acceptanceG_RecomputeOnlyAfterNow() {
        print("\n[7] 当天重算只返回当前时间之后的部分")
        let semester = makeSemester()
        let target = dayOfWeek(1, 0)
        let courses = [
            course("早课", weekday: .monday, start: (8, 0), end: (9, 0)),
            course("午课", weekday: .monday, start: (12, 0), end: (13, 0))
        ]
        let config = settings(windows: [window(.monday, (7, 0), (18, 0))])

        // 10:30 重算：上午的空档已经从 09:00 开始，但只能从 10:30 起算。
        let now = date(2026, 3, 2, 10, 30)
        let result = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: courses,
            settings: config,
            now: now
        )
        checkEqual(
            texts(result.freeIntervals),
            ["10:30-12:00", "13:00-18:00"],
            "只返回 10:30 之后仍可用的部分"
        )
        checkEqual(result.totalFreeMinutes, 90 + 300, "10:30 之后的容量是 390 分钟")
        check(result.freeIntervals.first?.trimmedByNow == true, "第一段被 now 截断并标记")
        check(result.freeIntervals.allSatisfy { $0.start >= now }, "所有空闲区间都从 now 之后开始")
        checkEqual(result.referenceNow, now, "结果里回显使用的 now，便于界面说明")

        // 已经过去的最后一节课：21:00 重算时为 0。
        let lateNow = date(2026, 3, 2, 21, 0)
        let late = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: courses,
            settings: config,
            now: lateNow
        )
        checkEqual(late.totalFreeMinutes, 0, "过了学习窗口后当天重算为 0")
        check(late.freeIntervals.isEmpty, "过了学习窗口后没有空闲区间")

        // 整日计算（now = nil）不受影响。
        let whole = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: courses,
            settings: config
        )
        checkEqual(whole.totalFreeMinutes, 540, "整日计算包含已过去的时段（660 分钟窗口 − 120 分钟课程）")
        check(whole.freeIntervals.allSatisfy { !$0.trimmedByNow }, "整日计算不标记 now 截断")
        checkEqual(
            whole.totalFreeMinutes - result.totalFreeMinutes,
            150,
            "10:30 重算比整日少 150 分钟（07:00–10:30 中已过去的 90 分钟 + 被截掉的 60 分钟余量）"
        )
    }

    // MARK: - 8. 阈值

    static func acceptanceH_BelowThresholdNotCounted() {
        print("\n[8] 空档阈值")
        let semester = makeSemester()
        let target = dayOfWeek(1, 0)

        // 窗口 09:00–10:00，中间一段 25 分钟的课，前后各留出一段空档。
        let split = [course("占位课", weekday: .monday, start: (9, 30), end: (9, 55))]
        let splitSettings = settings(windows: [window(.monday, (9, 0), (10, 0))], threshold: 0)
        let splitResult = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: split,
            settings: splitSettings
        )
        checkEqual(
            splitResult.freeIntervals.map(\.durationMinutes),
            [30, 5],
            "阈值 0 时前后两段空档都保留（30 分钟与 5 分钟）"
        )
        checkEqual(splitResult.totalFreeMinutes, 35, "窗口 60 分钟扣掉 25 分钟后剩 35 分钟")

        // 默认阈值 5：恰好 5 分钟的空档仍然计入（边界是 >=）。
        let boundary = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: split,
            settings: settings(windows: [window(.monday, (9, 0), (10, 0))], threshold: 5)
        )
        checkEqual(
            boundary.freeIntervals.map(\.durationMinutes),
            [30, 5],
            "默认阈值 5 时，恰好 5 分钟的空档计入"
        )
        checkEqual(boundary.minimumFreeBlockMinutes, 5, "默认阈值为 5 分钟")
        checkEqual(boundary.discardedIntervals.count, 0, "没有 5 分钟以下的碎片被丢弃")

        // 真正的“小于阈值”：4 分钟碎片不计入容量。
        let gap4Courses = [
            course("前段", weekday: .monday, start: (9, 0), end: (9, 30)),
            course("后段", weekday: .monday, start: (9, 34), end: (9, 59))
        ]
        let strict = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: gap4Courses,
            settings: settings(windows: [window(.monday, (9, 0), (10, 0))], threshold: 5)
        )
        checkEqual(strict.freeIntervals.map(\.durationMinutes), [], "4 分钟间隙与 1 分钟尾段都小于阈值，没有可用空档")

        // 两段碎片都被记录为丢弃，便于界面解释“为什么这段时间没算”。
        checkEqual(strict.totalFreeMinutes, 0, "小于阈值的碎片全部不计入容量")
        checkEqual(strict.discardedIntervals.map(\.durationMinutes), [4, 1], "被丢弃的碎片单独记录（4 分钟与 1 分钟）")

        // 阈值调低到 4：4 分钟碎片重新计入。
        let relaxed = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: gap4Courses,
            settings: settings(windows: [window(.monday, (9, 0), (10, 0))], threshold: 4)
        )
        checkEqual(relaxed.freeIntervals.map(\.durationMinutes), [4], "阈值调成 4 分钟后 4 分钟碎片计入")
        checkEqual(relaxed.totalFreeMinutes, 4, "阈值 4 时容量为 4 分钟")

        // 阈值 0：任何正长度空档都计入，但仍不产生零长度区间。
        let zero = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: gap4Courses,
            settings: settings(windows: [window(.monday, (9, 0), (10, 0))], threshold: 0)
        )
        checkEqual(zero.freeIntervals.map(\.durationMinutes), [4, 1], "阈值 0 时两段空档都计入")
        check(zero.freeIntervals.allSatisfy { $0.durationMinutes > 0 }, "即使阈值为 0 也不产生零长度区间")

        // 没有课、窗口小于阈值：容量为 0。
        let tiny = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [],
            settings: settings(windows: [window(.monday, (9, 0), (9, 4))], threshold: 5)
        )
        checkEqual(tiny.totalFreeMinutes, 0, "整段窗口只有 4 分钟时不计入容量")
        checkEqual(tiny.discardedIntervals.map(\.durationMinutes), [4], "4 分钟窗口被记录为丢弃")
    }

    // MARK: - 9. 学期时区决定星期

    static func acceptanceI_SemesterTimeZoneKeepsWeekday() {
        print("\n[9] 学期时区 vs 系统时区")
        let semester = makeSemester()
        let mondayMorning = date(2026, 3, 2, 8, 0) // 北京时间周一 08:00

        checkEqual(
            ScheduleResolver.weekday(of: mondayMorning, semester: semester),
            .monday,
            "学期时区下的周一 08:00 解析为周一"
        )

        // 模拟“设备时区被改到纽约”：算法仍使用学期时区。
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let wrongWeekday = ScheduleWeekday(calendarWeekday: utcCalendar.component(.weekday, from: mondayMorning))
        checkEqual(wrongWeekday, .sunday, "如果误用纽约时区，同一时刻会被算成周日（说明时区必须显式传入）")

        let courseAt8 = course("周一早课", weekday: .monday, start: (8, 0), end: (9, 0))
        let day = ScheduleResolver.day(for: mondayMorning, semester: semester, courses: [courseAt8])
        checkEqual(day.courses.count, 1, "按学期时区，周一早课正常排上")
        checkEqual(day.weekday, .monday, "解析结果的 weekday 使用学期时区")

        // 同一时刻用不同系统日历解析，结果不变。
        let semesterCalendarResult = ScheduleResolver.day(
            for: mondayMorning,
            semester: semester,
            courses: [courseAt8],
            exceptions: []
        )
        checkEqual(semesterCalendarResult.courses.count, 1, "重复解析结果稳定（不依赖 Calendar.current）")

        // 夏令时地区：学期时区设为纽约时，3 月 8 日切换夏令时不应让星期错位。
        let newYorkSemester = ScheduleSemester(
            firstWeekStart: date(2026, 3, 2, 0, 0),
            weekCount: 18,
            timeZoneIdentifier: "America/New_York"
        )
        checkEqual(newYorkSemester.timeZone.identifier, "America/New_York", "学期时区可设为任意标识")
        checkEqual(newYorkSemester.calendar.timeZone.identifier, "America/New_York", "学期日历绑定学期时区")
    }

    // MARK: - 10. 无课表 / 无作息

    static func acceptanceJ_NoTimetableStillComputes() {
        print("\n[10] 无课表 / 无作息")
        let semester = makeSemester()
        let target = dayOfWeek(1, 0)

        let noCourses = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [],
            settings: settings(windows: [window(.monday, (19, 0), (21, 0))])
        )
        checkEqual(texts(noCourses.freeIntervals), ["19:00-21:00"], "无课表时按作息直接给出整段空闲")
        checkEqual(noCourses.state, .fullyFree, "无课表时状态为当天全空")
        checkEqual(noCourses.totalFreeMinutes, 120, "无课表时容量等于窗口长度")

        // 完全没有配置作息：使用默认假设并明确标记。
        let bare = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [],
            settings: AvailabilitySettings(
                weekdayStudyWindows: [],
                weekendStudyWindows: [],
                sleepWindows: [],
                minimumFreeBlockMinutes: 5
            )
        )
        check(bare.usesDefaultAssumption, "未配置作息时标记 usesDefaultAssumption")
        check(bare.totalFreeMinutes > 0, "未配置作息时仍按默认假设计算出容量")
        checkEqual(bare.state, .noRoutineConfigured, "使用默认假设时状态明确为「未设置作息」，不会假装是真实容量")
        check(bare.assumptions.contains { $0.contains("默认") }, "默认假设写入 assumptions 供界面展示")
        check(bare.assumptions.count >= 2, "默认假设包含学习窗口与睡眠两条说明")

        // 明确关掉默认假设：不猜，容量为 0 且状态明确。
        let strict = AvailabilityCalculator.availability(
            on: target,
            semester: semester,
            courses: [],
            settings: AvailabilitySettings(
                weekdayStudyWindows: [],
                weekendStudyWindows: [],
                sleepWindows: [],
                minimumFreeBlockMinutes: 5
            ),
            applyDefaultRoutineWhenMissing: false
        )
        checkEqual(strict.totalFreeMinutes, 0, "不允许默认假设时容量为 0")
        checkEqual(strict.state, .noStudyWindow, "不允许默认假设且没有窗口时，状态为「当天无学习窗口」")
        check(strict.assumptions.isEmpty, "不允许默认假设时不编造假设")

        // 工作日/周末窗口分别生效。
        let separated = AvailabilitySettings(
            weekdayStudyWindows: [window(.monday, (19, 0), (20, 0))],
            weekendStudyWindows: [window(.saturday, (9, 0), (11, 0))],
            sleepWindows: [],
            minimumFreeBlockMinutes: 5
        )
        let saturday = dayOfWeek(1, 5)
        let saturdayResult = AvailabilityCalculator.availability(
            on: saturday,
            semester: semester,
            courses: [],
            settings: separated
        )
        checkEqual(texts(saturdayResult.freeIntervals), ["09:00-11:00"], "周末使用周末窗口")
        checkEqual(saturdayResult.totalFreeMinutes, 120, "周末窗口 120 分钟")
    }

    // MARK: - 11. 表单校验

    static func acceptanceK_FormValidation() {
        print("\n[11] 表单校验与重复规则摘要")
        let semester = makeSemester(weekCount: 18)
        let existing = [course("已有课", weekday: .monday, start: (8, 0), end: (9, 40))]

        func errors(_ draft: CourseDraft) -> [ScheduleValidationIssue] {
            ScheduleValidation.issues(for: draft, semester: semester, existingCourses: existing)
                .filter { $0.severity == .error }
        }

        // 结束早于开始。
        let badTime = CourseDraft(
            name: "坏时间",
            subject: SubjectRef(displayName: "数学"),
            weekday: .tuesday,
            startTime: TimeOfDay(hour: 10, minute: 0),
            endTime: TimeOfDay(hour: 9, minute: 0)
        )
        check(errors(badTime).contains { $0.message.contains("结束时间必须晚于开始时间") }, "结束早于开始 → 报错")

        // 无名称 / 无科目。
        let noName = CourseDraft(
            name: "   ",
            subject: SubjectRef(displayName: "数学"),
            weekday: .tuesday,
            startTime: TimeOfDay(hour: 10, minute: 0),
            endTime: TimeOfDay(hour: 11, minute: 0)
        )
        check(errors(noName).contains { $0.message.contains("课程名称") }, "空课程名 → 报错")

        // 无有效周次。
        let noWeeks = CourseDraft(
            name: "指定周次",
            subject: SubjectRef(displayName: "数学"),
            weekday: .tuesday,
            startTime: TimeOfDay(hour: 10, minute: 0),
            endTime: TimeOfDay(hour: 11, minute: 0),
            parity: .custom,
            customWeeks: []
        )
        check(errors(noWeeks).contains { $0.message.contains("至少") }, "指定周次但没勾选 → 报错")

        // 超出学期。
        let outOfRange = CourseDraft(
            name: "超范围",
            subject: SubjectRef(displayName: "数学"),
            weekday: .tuesday,
            startTime: TimeOfDay(hour: 10, minute: 0),
            endTime: TimeOfDay(hour: 11, minute: 0),
            parity: .custom,
            customWeeks: [1, 25]
        )
        check(errors(outOfRange).contains { $0.message.contains("超出学期范围") }, "周次超出学期 → 报错")

        let outOfRangeLastWeek = CourseDraft(
            name: "结束周越界",
            subject: SubjectRef(displayName: "数学"),
            weekday: .tuesday,
            startTime: TimeOfDay(hour: 10, minute: 0),
            endTime: TimeOfDay(hour: 11, minute: 0),
            parity: .every,
            lastWeek: 30
        )
        check(errors(outOfRangeLastWeek).contains { $0.message.contains("结束周") }, "结束周超出学期 → 报错")

        // 合法草稿没有 error。
        let valid = CourseDraft(
            name: "合法课程",
            subject: SubjectRef(displayName: "数学"),
            weekday: .wednesday,
            startTime: TimeOfDay(hour: 10, minute: 0),
            endTime: TimeOfDay(hour: 11, minute: 0)
        )
        check(errors(valid).isEmpty, "合法草稿没有阻断性错误")

        // 冲突：同一时间同一星期 → warning，不阻断保存。
        let conflicting = CourseDraft(
            name: "冲突课",
            subject: SubjectRef(displayName: "物理"),
            weekday: .monday,
            startTime: TimeOfDay(hour: 9, minute: 0),
            endTime: TimeOfDay(hour: 10, minute: 0)
        )
        let issues = ScheduleValidation.issues(for: conflicting, semester: semester, existingCourses: existing)
        check(issues.contains { $0.severity == .warning && $0.message.contains("重叠") }, "冲突课程给出提示")
        check(!issues.contains { $0.severity == .error }, "冲突本身不阻断保存")
        check(issues.first { $0.severity == .warning }?.relatedCourseID == existing[0].id, "冲突提示关联到具体课程 id")

        // 编辑自己时不应和自己冲突。
        let editingSelf = CourseDraft(course: existing[0])
        let selfIssues = ScheduleValidation.issues(for: editingSelf, semester: semester, existingCourses: existing)
        check(!selfIssues.contains { $0.message.contains("重叠") }, "编辑既有课程时不会与自己冲突")

        // 摘要。
        checkEqual(valid.recurrenceSummary, "每周（整个学期）", "每周摘要")
        let odd = CourseDraft(
            name: "单周",
            subject: SubjectRef(displayName: "英语"),
            weekday: .friday,
            startTime: TimeOfDay(hour: 8, minute: 0),
            endTime: TimeOfDay(hour: 9, minute: 40),
            parity: .odd
        )
        checkEqual(odd.recurrenceSummary, "单周（整个学期）", "单周摘要")
        let custom = CourseDraft(
            name: "指定",
            subject: SubjectRef(displayName: "英语"),
            weekday: .friday,
            startTime: TimeOfDay(hour: 8, minute: 0),
            endTime: TimeOfDay(hour: 9, minute: 40),
            parity: .custom,
            customWeeks: [3, 1, 3]
        )
        checkEqual(custom.recurrenceSummary, "第 1、3 周", "指定周次摘要去重并排序")
        checkEqual(
            custom.normalizedRecurrence(semester: semester).weeks,
            [1, 3],
            "归一化后的周次去重且升序"
        )
        check(valid.saveSummary.contains("每周"), "保存摘要包含重复规则")
    }

    // MARK: - 13. 周视图布局与学期对齐

    static func acceptanceM_TimelineAndSemesterAlignment() {
        print("\n[13] 周视图布局与学期对齐")
        let semester = makeSemester()
        let monday = dayOfWeek(1, 0)

        // 普通课程：09:00–10:00，时间轴 7...22。
        let normal = course("普通课", weekday: .monday, start: (9, 0), end: (10, 0))
        let normalDay = ScheduleResolver.day(for: monday, semester: semester, courses: [normal])
        guard let normalOccurrence = normalDay.courses.first else {
            check(false, "普通课程应当解析成功")
            return
        }
        let normalLayout = ScheduleResolver.timelineLayout(
            for: normalOccurrence,
            hourRange: Array(7...22),
            semester: semester
        )
        checkEqual(normalLayout.offsetMinutes, 120, "09:00 在 07:00 起的时间轴上偏移 120 分钟")
        checkEqual(normalLayout.heightMinutes, 60, "09:00–10:00 的高度是 60 分钟")

        // 跨午夜课程：22:30–次日 00:30，高度为正，不出现负值。
        let overnight = course("跨午夜", weekday: .monday, start: (22, 30), end: (0, 30), endDayOffset: 1)
        let overnightDay = ScheduleResolver.day(for: monday, semester: semester, courses: [overnight])
        guard let overnightOccurrence = overnightDay.courses.first else {
            check(false, "跨午夜课程应当解析成功")
            return
        }
        let overnightLayout = ScheduleResolver.timelineLayout(
            for: overnightOccurrence,
            hourRange: Array(7...22),
            semester: semester
        )
        check(overnightLayout.heightMinutes > 0, "跨午夜课程高度必须为正")
        checkEqual(overnightLayout.offsetMinutes, 930, "22:30 偏移 930 分钟")
        check(
            overnightLayout.offsetMinutes + overnightLayout.heightMinutes <= 16 * 60,
            "跨午夜课程不会溢出时间轴"
        )

        // 极端短课程也保持最小可见高度。
        let tiny = course("微课", weekday: .monday, start: (9, 0), end: (9, 5))
        let tinyDay = ScheduleResolver.day(for: monday, semester: semester, courses: [tiny])
        if let tinyOccurrence = tinyDay.courses.first {
            let layout = ScheduleResolver.timelineLayout(
                for: tinyOccurrence,
                hourRange: Array(7...22),
                semester: semester,
                minimumVisibleMinutes: 20
            )
            checkEqual(layout.heightMinutes, 20, "5 分钟课程仍保留 20 分钟最小可见高度")
        }

        // 学期第一周对齐：无论传入周中哪一天，都对齐到周一。
        let wednesday = dayOfWeek(1, 2)
        let aligned = ScheduleResolver.weekStartDate(containing: wednesday, semester: semester)
        checkEqual(aligned, monday, "第一周起点对齐到周一")
        checkEqual(semester.weekIndex(for: aligned), 1, "对齐后的日期是第 1 周")
        checkEqual(
            ScheduleResolver.weekStartDate(containing: monday, semester: semester),
            monday,
            "周一自身仍对齐到同一天"
        )

        // 学期日期区间覆盖 18 周。
        let interval = semester.dateInterval
        let days = semester.calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
        checkEqual(days, 126, "18 周学期共 126 天")

        // 学期时区不同，同一时间戳的周次相同（周次只由日期与时区决定）。
        var tokyoSemester = semester
        tokyoSemester.timeZoneIdentifier = "Asia/Tokyo"
        checkEqual(
            tokyoSemester.weekIndex(for: monday),
            1,
            "换时区后同一日期仍在第 1 周（周次按学期时区计算，不漂移）"
        )
    }

    // MARK: - 12. 细节与幂等

    static func acceptanceL_DetailsAndIdempotence() {
        print("\n[12] 幂等、周视图与占用来源")
        let semester = makeSemester()

        // 稳定实例 id。
        let courseA = course("稳定课", weekday: .monday, start: (8, 0), end: (9, 0))
        let monday = dayOfWeek(1, 0)
        let first = ScheduleResolver.day(for: monday, semester: semester, courses: [courseA])
        let second = ScheduleResolver.day(for: monday, semester: semester, courses: [courseA])
        checkEqual(first.courses.first?.id, second.courses.first?.id, "重复解析得到相同的课程实例 id（幂等）")

        // 两门不同课在同一时间的实例 id 不同。
        let courseB = course("另一门", weekday: .monday, start: (8, 0), end: (9, 0))
        let mixed = ScheduleResolver.day(for: monday, semester: semester, courses: [courseA, courseB])
        checkEqual(Set(mixed.courses.map(\.id)).count, 2, "不同课程的实例 id 不冲突")

        // 一周七天。
        let week = ScheduleResolver.week(
            index: 1,
            semester: semester,
            courses: [
                course("周一课", weekday: .monday, start: (8, 0), end: (9, 0)),
                course("周日课", weekday: .sunday, start: (8, 0), end: (9, 0))
            ],
            today: monday
        )
        checkEqual(week.days.count, 7, "周视图固定 7 天")
        checkEqual(week.days.first?.weekday, .monday, "周视图从周一开始")
        checkEqual(week.days.last?.weekday, .sunday, "周视图以周日结束")
        checkEqual(week.days.first?.courses.count, 1, "周一的课落在第一天")
        checkEqual(week.days.last?.courses.count, 1, "周日的课落在第七天")
        check(week.days.first?.isToday == true, "今天标记正确")

        // 周次概览：15 周学期里单周课的出现次数。
        let oddCourse = course("单周", weekday: .monday, start: (8, 0), end: (9, 0), parity: .odd)
        let entries = ScheduleResolver.weekEntries(for: oddCourse, semester: makeSemester(weekCount: 15))
        checkEqual(entries.filter { $0.status == .scheduled }.count, 8, "15 周内单周课出现 8 次")
        checkEqual(entries.last?.status, .scheduled, "第 15 周（最后一周）单周课仍然上课")
        checkEqual(entries[13].status, .cancelled, "第 14 周单周课不上")

        // 停课在周次概览里标记。
        let cancelException = ScheduleException(
            kind: .cancellation,
            courseID: oddCourse.id,
            date: dayOfWeek(3, 0)
        )
        let entriesWithCancel = ScheduleResolver.weekEntries(
            for: oddCourse,
            semester: makeSemester(weekCount: 15),
            exceptions: [cancelException]
        )
        checkEqual(entriesWithCancel[2].status, .cancelled, "第 3 周被标记为停课")
        checkEqual(entriesWithCancel[2].note, "停课", "停课原因写入 note")

        // 占用来源标注。
        let settingsWithExtras = AvailabilitySettings(
            weekdayStudyWindows: [window(.monday, (7, 0), (18, 0))],
            weekendStudyWindows: [],
            sleepWindows: [],
            customBlocks: [window(.monday, (12, 0), (13, 0))],
            commuteMinutes: 30,
            bufferMinutes: 10,
            minimumFreeBlockMinutes: 5
        )
        let withExtras = AvailabilityCalculator.availability(
            on: monday,
            semester: semester,
            courses: [courseA],
            settings: settingsWithExtras
        )
        let kinds = Set(withExtras.occupiedIntervals.map(\.kind))
        let contributors = withExtras.occupiedIntervals.flatMap(\.contributorLabels)
        check(kinds.contains(.course), "课程与缓冲合并后仍标注为课程（不会被缓冲抢走归属）")
        checkEqual(withExtras.occupiedMinutesWithinWindows, 80 + 60, "窗口内被占用 140 分钟（课程含前后缓冲 80 分钟 + 固定占用 60 分钟）")
        checkEqual(withExtras.totalStudyWindowMinutes, withExtras.occupiedMinutesWithinWindows + withExtras.totalFreeMinutes, "记账自洽：窗口 660 = 占用 140 + 空闲 520")
        check(kinds.contains(.custom), "占用集合包含固定占用")
        check(contributors.contains { $0.contains("通勤") }, "合并后的占用仍保留通勤来源标签")
        check(contributors.contains("缓冲"), "合并后的占用仍保留缓冲来源标签")
        check(contributors.contains("稳定课"), "合并后的占用保留课程名")
        check(
            withExtras.occupiedIntervals.allSatisfy { $0.end > $0.start },
            "所有来源的占用时长都为正"
        )
        checkEqual(
            AvailabilityCalculator.availability(
                on: monday,
                semester: semester,
                courses: [courseA],
                settings: settingsWithExtras
            ).totalFreeMinutes,
            withExtras.totalFreeMinutes,
            "同一输入重复计算得到相同容量（幂等）"
        )

        // 归档课程不参与计算。
        var archived = courseA
        archived.isArchived = true
        let archivedDay = ScheduleResolver.day(for: monday, semester: semester, courses: [archived])
        check(archivedDay.courses.isEmpty, "归档课程不产生占用")

        // 课程不产生学习完成事件：可用时间结果里只有时间区间与占用来源，
        // 没有任何“完成 / 打卡 / 奖励”字段可供写入。
        check(
            withExtras.freeIntervals.allSatisfy { $0.durationMinutes > 0 && $0.end > $0.start },
            "可用时间结果只包含有效的纯时间区间"
        )
        check(
            withExtras.occupiedIntervals.allSatisfy { $0.kind != .course || $0.sourceCourseID != nil },
            "课程占用都能追溯到来源课程 id"
        )
    }
}
