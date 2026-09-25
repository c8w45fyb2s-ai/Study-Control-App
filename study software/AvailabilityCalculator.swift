import Foundation

// MARK: - AvailabilityCalculator
//
// “每天哪些时间可以用于自主学习”的纯计算。
//
// 核心规则：
// 1. 先合并所有重叠占用，再从学习窗口中扣除 —— 重叠只能扣一次。
// 2. 临时停课必须恢复空闲（停课课程根本不进入占用集合）。
// 3. 跨午夜睡眠按“绝对时间区间”处理，绝不出现负数时长。
// 4. 当天重算只返回 `now` 之后仍然可用的部分。
// 5. 小于最短可用阈值的碎片直接丢弃，且**不会**被拼成更长的连续区间。
//
// 本文件不读时钟、不读存储、不生成任何学习完成事件。

// MARK: - 设置

/// 学习时间偏好。全部本地，无网络依赖。
///
/// 时间单位为分钟，“可安排容量”只在这些窗口里产生。
struct AvailabilitySettings: Codable, Hashable, Sendable {
    /// 工作日（周一–周五）的学习窗口。可多段。
    var weekdayStudyWindows: [DayTimeRange]
    /// 周末（周六、周日）的学习窗口。可多段。
    var weekendStudyWindows: [DayTimeRange]
    /// 睡眠。默认跨午夜（23:00–07:00，`endDayOffset = 1`）。
    var sleepWindows: [DayTimeRange]
    /// 固定占用（实习、例会、健身等）。与课程一样先合并再扣除。
    var customBlocks: [DayTimeRange]
    /// 通勤时长（分钟）：有课程的每一天，在每段课程后扣除一次。
    var commuteMinutes: Int
    /// 缓冲时长（分钟）：每段课程前后各扣除一次的转场余量。
    var bufferMinutes: Int
    /// 空档小于该值就不计入可安排容量。默认 5 分钟。
    var minimumFreeBlockMinutes: Int

    init(
        weekdayStudyWindows: [DayTimeRange] = AvailabilitySettings.defaultWeekdayStudyWindows,
        weekendStudyWindows: [DayTimeRange] = AvailabilitySettings.defaultWeekendStudyWindows,
        sleepWindows: [DayTimeRange] = AvailabilitySettings.defaultSleepWindows,
        customBlocks: [DayTimeRange] = [],
        commuteMinutes: Int = 0,
        bufferMinutes: Int = 0,
        minimumFreeBlockMinutes: Int = 5
    ) {
        self.weekdayStudyWindows = weekdayStudyWindows
        self.weekendStudyWindows = weekendStudyWindows
        self.sleepWindows = sleepWindows
        self.customBlocks = customBlocks
        self.commuteMinutes = max(0, commuteMinutes)
        self.bufferMinutes = max(0, bufferMinutes)
        self.minimumFreeBlockMinutes = max(0, minimumFreeBlockMinutes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekdayStudyWindows = try container.decodeIfPresent([DayTimeRange].self, forKey: .weekdayStudyWindows)
            ?? AvailabilitySettings.defaultWeekdayStudyWindows
        weekendStudyWindows = try container.decodeIfPresent([DayTimeRange].self, forKey: .weekendStudyWindows)
            ?? AvailabilitySettings.defaultWeekendStudyWindows
        sleepWindows = try container.decodeIfPresent([DayTimeRange].self, forKey: .sleepWindows)
            ?? AvailabilitySettings.defaultSleepWindows
        customBlocks = try container.decodeIfPresent([DayTimeRange].self, forKey: .customBlocks) ?? []
        commuteMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .commuteMinutes) ?? 0)
        bufferMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .bufferMinutes) ?? 0)
        minimumFreeBlockMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .minimumFreeBlockMinutes) ?? 5)
    }

    // MARK: 默认值

    /// 默认学习窗口（工作日 19:00–22:30）。
    static var defaultWeekdayStudyWindows: [DayTimeRange] {
        [DayTimeRange(weekday: .monday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 22, minute: 30))]
    }

    /// 默认学习窗口（周末 09:00–12:00 与 14:00–21:00）。
    static var defaultWeekendStudyWindows: [DayTimeRange] {
        [
            DayTimeRange(weekday: .saturday, start: TimeOfDay(hour: 9, minute: 0), end: TimeOfDay(hour: 12, minute: 0)),
            DayTimeRange(weekday: .saturday, start: TimeOfDay(hour: 14, minute: 0), end: TimeOfDay(hour: 21, minute: 0))
        ]
    }

    /// 默认睡眠（23:00–次日 07:00）。
    static var defaultSleepWindows: [DayTimeRange] {
        [DayTimeRange(
            weekday: .monday,
            start: TimeOfDay(hour: 23, minute: 0),
            end: TimeOfDay(hour: 7, minute: 0),
            endDayOffset: 1
        )]
    }

    /// 用户是否显式配置过作息（用于“无作息时明确展示默认假设”）。
    var hasExplicitRoutine: Bool {
        !weekdayStudyWindows.isEmpty || !weekendStudyWindows.isEmpty || !sleepWindows.isEmpty
    }

    /// 该星期几适用的学习窗口。没有对应配置时返回空数组
    /// （而不是偷偷塞默认值），由调用方决定是否采用默认假设。
    func studyWindows(for weekday: ScheduleWeekday) -> [DayTimeRange] {
        weekday.isWeekend ? weekendStudyWindows : weekdayStudyWindows
    }

    /// 睡眠窗口：加上前一天跨午夜到今天的尾巴。
    func sleepWindowsAffecting(weekday: ScheduleWeekday) -> [DayTimeRange] {
        let previous = ScheduleWeekday(rawValue: weekday.rawValue == 1 ? 7 : weekday.rawValue - 1) ?? weekday
        return sleepWindows.filter { range in
            range.weekday == weekday || (range.weekday == previous && range.endDayOffset > 0)
        }
    }

    func customBlocks(for weekday: ScheduleWeekday) -> [DayTimeRange] {
        customBlocks.filter { $0.weekday == weekday }
    }

    // MARK: 占用块构造

    /// 把某一星期几的作息（睡眠、固定占用、通勤、缓冲）展开成绝对时间占用块。
    ///
    /// - Parameter courseBlocks: 已解析出的课程占用（用于按次扣通勤/缓冲）。
    func occupancyBlocks(
        onDay day: Date,
        weekday: ScheduleWeekday,
        semester: ScheduleSemester,
        courseBlocks: [ScheduleBlock]
    ) -> [ScheduleBlock] {
        let calendar = semester.calendar
        let dayStart = calendar.startOfDay(for: day)
        var result: [ScheduleBlock] = []

        func append(range: DayTimeRange, kind: OccupancyKind, label: String) {
            guard range.isValid else { return }
            guard let start = range.start.date(on: dayStart, calendar: calendar) else { return }
            let offset = max(0, range.endDayOffset)
            guard let endDay = calendar.date(byAdding: .day, value: offset, to: dayStart),
                  let end = range.end.date(on: endDay, calendar: calendar),
                  end > start else { return }
            result.append(ScheduleBlock(kind: kind, label: label, start: start, end: end))
        }

        for sleep in sleepWindowsAffecting(weekday: weekday) {
            append(range: sleep, kind: .custom, label: "睡眠")
        }

        for block in customBlocks(for: weekday) {
            append(range: block, kind: .custom, label: "固定占用")
        }

        // 通勤与缓冲按“每次课”扣一次，重叠部分由后续合并消掉。
        for course in courseBlocks where course.isValid {
            if commuteMinutes > 0,
               let start = calendar.date(byAdding: .minute, value: -commuteMinutes, to: course.end) {
                result.append(ScheduleBlock(
                    kind: .commute,
                    label: "通勤（\(course.label)）",
                    start: start,
                    end: course.end,
                    sourceCourseID: course.sourceCourseID
                ))
            }
            if bufferMinutes > 0 {
                if let before = calendar.date(byAdding: .minute, value: -bufferMinutes, to: course.start) {
                    result.append(ScheduleBlock(
                        kind: .buffer,
                        label: "缓冲",
                        start: before,
                        end: course.start,
                        sourceCourseID: course.sourceCourseID
                    ))
                }
                if let after = calendar.date(byAdding: .minute, value: bufferMinutes, to: course.end) {
                    result.append(ScheduleBlock(
                        kind: .buffer,
                        label: "缓冲",
                        start: course.end,
                        end: after,
                        sourceCourseID: course.sourceCourseID
                    ))
                }
            }
        }

        return result
    }
}

// MARK: - 结果

/// 一段可用于自主学习的时间。
struct FreeInterval: Identifiable, Hashable, Sendable {
    var start: Date
    var end: Date
    /// 是否被 `now` 截掉过开头（当天重算）。
    var trimmedByNow: Bool
    /// 是否因为短于阈值而被丢弃 —— 保留记录便于界面解释“为什么这段时间没算”。
    var discardedAsTooShort: Bool

    var id: Date { start }

    var durationMinutes: Int {
        max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
    }

    init(start: Date, end: Date, trimmedByNow: Bool = false, discardedAsTooShort: Bool = false) {
        self.start = start
        self.end = end
        self.trimmedByNow = trimmedByNow
        self.discardedAsTooShort = discardedAsTooShort
    }

    func timeText(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }
}

/// 一段被占用（不可学习）的时间，附带来源，便于界面解释。
struct OccupiedInterval: Identifiable, Hashable, Sendable {
    var kind: OccupancyKind
    var label: String
    var start: Date
    var end: Date
    var sourceCourseID: UUID?
    /// 合并前参与这段时间的全部来源标签（例如「早课」「缓冲」）。
    var contributorLabels: [String]

    var id: Date { start }

    var durationMinutes: Int {
        max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
    }

    /// 给界面用的一句话来源说明。
    var sourceText: String {
        contributorLabels.count > 1
            ? "\(kind.label)：\(contributorLabels.joined(separator: " + "))"
            : "\(kind.label)：\(label)"
    }

    func timeText(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }
}

/// 一天的可安排容量。
struct AvailabilityDay: Hashable, Sendable {
    /// 这一天的零点（学期时区）。
    var day: Date
    var weekday: ScheduleWeekday
    var weekIndex: Int?
    /// 用于计算的 `now`；`nil` 表示整日计算。
    var referenceNow: Date?
    /// 当天所有学习窗口（含前一天跨午夜延续进来的部分）。
    var studyWindows: [DateInterval]
    /// 合并 + 裁剪到当天之后的占用（课程、睡眠、固定占用、通勤、缓冲）。
    /// 注意：包含学习窗口之外的占用（例如上午的课落在晚间窗口之外），
    /// 用于界面解释“一天被什么占着”。
    var occupiedIntervals: [OccupiedInterval]
    /// 真正吃掉学习窗口的占用分钟数。满足
    /// `totalStudyWindowMinutes == occupiedMinutesWithinWindows + totalFreeMinutes`。
    var occupiedMinutesWithinWindows: Int
    /// 最终可用于自主学习的时间段，全部起点 `>= now`。
    var freeIntervals: [FreeInterval]
    /// 因为短于阈值被丢弃的碎片，仅用于解释，不计入容量。
    var discardedIntervals: [FreeInterval]
    var state: AvailabilityState
    var assumptions: [String]
    /// 缺少作息配置时为 `true`，界面必须明确提示。
    var usesDefaultAssumption: Bool
    var minimumFreeBlockMinutes: Int

    var totalFreeMinutes: Int {
        freeIntervals.reduce(0) { $0 + $1.durationMinutes }
    }

    /// 当天学习窗口的总长度（分钟）。
    var totalStudyWindowMinutes: Int {
        studyWindows.reduce(0) { $0 + Int(($1.duration / 60).rounded()) }
    }

    var longestFreeMinutes: Int {
        freeIntervals.map(\.durationMinutes).max() ?? 0
    }

    var hasFreeTime: Bool { !freeIntervals.isEmpty }
}

enum AvailabilityState: String, Hashable, Equatable, Sendable {
    /// 没有任何作息配置，只能按默认假设计算。
    case noRoutineConfigured
    /// 完全没有学习窗口（用户明确不打算学习）。
    case noStudyWindow
    /// 学习窗口被占用填满。
    case fullyOccupied
    /// 还剩一部分可安排时间。
    case partiallyFree
    /// 整段学习窗口都空着。
    case fullyFree

    var label: String {
        switch self {
        case .noRoutineConfigured: return "未设置作息"
        case .noStudyWindow: return "当天无学习窗口"
        case .fullyOccupied: return "已被占满"
        case .partiallyFree: return "有部分空档"
        case .fullyFree: return "当天全空"
        }
    }

    var explanation: String {
        switch self {
        case .noRoutineConfigured:
            return "还没有设置作息，以下结果基于工作日晚间、周末上午/下午的默认假设。请到「可用时间设置」确认。"
        case .noStudyWindow:
            return "这一天的学习窗口为空，因此没有可安排容量。可以先去设置里开启该星期的学习窗口。"
        case .fullyOccupied:
            return "当天的学习窗口已被课程或其他占用填满，没有可安排的空档。"
        case .partiallyFree:
            return "已从学习窗口中扣除课程与其他占用，下面是仍可安排的时段。"
        case .fullyFree:
            return "当天没有课程占用，学习窗口整体可用。"
        }
    }
}

// MARK: - Calculator

/// 可用时间计算器。纯函数集合，无可变状态，不读时钟。
enum AvailabilityCalculator {

    /// 计算某一天的可安排容量。
    ///
    /// - Parameters:
    ///   - date: 目标日期。
    ///   - semester: 学期配置（提供时区与周次）。
    ///   - courses: 课程定义。
    ///   - exceptions: 一次性停课/换课/补课。
    ///   - settings: 作息偏好。
    ///   - now: 当前时间。传入非 `nil` 时只返回该时刻之后仍可用的部分；
    ///          为 `nil` 时按整日计算。**算法内部不会调用 `Date()`。**
    ///   - applyDefaultRoutineWhenMissing: 无作息配置时是否按默认假设计算。
    static func availability(
        on date: Date,
        semester: ScheduleSemester,
        courses: [Course],
        exceptions: [ScheduleException] = [],
        settings: AvailabilitySettings,
        now: Date? = nil,
        applyDefaultRoutineWhenMissing: Bool = true
    ) -> AvailabilityDay {
        let calendar = semester.calendar
        let dayStart = calendar.startOfDay(for: date)
        let weekday = ScheduleResolver.weekday(of: dayStart, semester: semester)
        let weekIndex = semester.weekIndex(for: dayStart)
        let isInSemester = (1...semester.lastWeek).contains(weekIndex)

        let scheduleDay = ScheduleResolver.day(
            for: dayStart,
            semester: semester,
            courses: courses,
            exceptions: exceptions
        )

        // 1) 组装当天的有效作息。
        var assumptions: [String] = []
        var effectiveSettings = settings
        var usesDefault = false

        let hasAnyWindow = !settings.weekdayStudyWindows.isEmpty || !settings.weekendStudyWindows.isEmpty
        if !hasAnyWindow, applyDefaultRoutineWhenMissing {
            usesDefault = true
            effectiveSettings.weekdayStudyWindows = AvailabilitySettings.defaultWeekdayStudyWindows
            effectiveSettings.weekendStudyWindows = AvailabilitySettings.defaultWeekendStudyWindows
            if effectiveSettings.sleepWindows.isEmpty {
                effectiveSettings.sleepWindows = AvailabilitySettings.defaultSleepWindows
            }
            assumptions.append("没有检测到作息设置，以下为默认假设：工作日 19:00–22:30；周末 09:00–12:00、14:00–21:00。")
            if settings.sleepWindows.isEmpty {
                assumptions.append("没有检测到睡眠时间，默认假设为 23:00–次日 07:00。")
            }
        }

        if !isInSemester {
            assumptions.append("这一天不在学期范围内（第 \(weekIndex) 周），不计入课程占用。")
        }

        // 2) 学习窗口（含前一天跨午夜延续进来的部分），统一裁剪到当天。
        let windows = studyWindowIntervals(
            for: weekday,
            day: dayStart,
            settings: effectiveSettings,
            semester: semester,
            clipToDay: true
        )

        // 3) 占用：课程 + 作息（睡眠/固定占用/通勤/缓冲）。
        //
        // 关键点：跨午夜占用归“起始日”。要算准今天，必须同时收集昨天跨到今天的尾巴
        // （典型例子：周一 23:00–次日 07:00 的睡眠，会占掉周二凌晨 00:00–07:00）。
        // 统一裁剪到当天，因此永远不会出现负数时长。
        var rawBlocks = scheduleDay.blocks
        rawBlocks.append(contentsOf: effectiveSettings.occupancyBlocks(
            onDay: dayStart,
            weekday: weekday,
            semester: semester,
            courseBlocks: scheduleDay.blocks
        ))

        if let previousDay = calendar.date(byAdding: .day, value: -1, to: dayStart) {
            let previousScheduleDay = ScheduleResolver.day(
                for: previousDay,
                semester: semester,
                courses: courses,
                exceptions: exceptions
            )
            rawBlocks.append(contentsOf: previousScheduleDay.blocks)
            let previousWeekday = ScheduleResolver.weekday(of: previousDay, semester: semester)
            rawBlocks.append(contentsOf: effectiveSettings.occupancyBlocks(
                onDay: previousDay,
                weekday: previousWeekday,
                semester: semester,
                courseBlocks: previousScheduleDay.blocks
            ))
        }

        let dayInterval = DateInterval(
            start: dayStart,
            end: calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        )
        let clippedBlocks = rawBlocks.compactMap { block -> ScheduleBlock? in
            guard block.isValid else { return nil }
            let start = max(block.start, dayInterval.start)
            let end = min(block.end, dayInterval.end)
            guard end > start else { return nil }
            var clipped = block
            clipped.start = start
            clipped.end = end
            return clipped
        }

        // 4) 先合并重叠占用，再扣除 —— 重叠只扣一次。
        let mergedBlocks = ScheduleResolver.merged(clippedBlocks)
        let occupiedIntervals = mergedBlocks.map {
            OccupiedInterval(
                kind: $0.kind,
                label: $0.label,
                start: $0.start,
                end: $0.end,
                sourceCourseID: $0.sourceCourseID,
                contributorLabels: $0.contributorLabels
            )
        }

        // 5) 只保留落在学习窗口内的占用（课程若在窗口外，不影响可安排容量）。
        let windowIntervals = windows
        let occupiedInsideWindows = ScheduleResolver.mergedIntervals(
            ScheduleResolver.intersect(mergedBlocks.map { DateInterval(start: $0.start, end: $0.end) }, windowIntervals)
        )
        let occupiedMinuteCount = occupiedInsideWindows.reduce(0) { $0 + Int(($1.duration / 60).rounded()) }

        // 6) 扣除 + 阈值过滤（不拼接）。
        let threshold = effectiveSettings.minimumFreeBlockMinutes
        let rawFree = ScheduleResolver.freeIntervals(
            windows: windowIntervals,
            blocks: occupiedInsideWindows,
            minMinutes: 0
        )

        // 7) 当天重算：只返回 now 之后仍可用的部分。
        var usable: [FreeInterval] = []
        var discarded: [FreeInterval] = []
        for interval in rawFree {
            var start = interval.start
            var trimmed = false
            if let now, now > start {
                start = now
                trimmed = true
            }
            guard interval.end > start else { continue }
            let free = FreeInterval(start: start, end: interval.end, trimmedByNow: trimmed)
            if free.durationMinutes >= threshold {
                usable.append(free)
            } else {
                discarded.append(FreeInterval(
                    start: free.start,
                    end: free.end,
                    trimmedByNow: trimmed,
                    discardedAsTooShort: true
                ))
            }
        }

        let state: AvailabilityState
        if usesDefault {
            // 没有配置作息时必须明确说“这是默认假设”，而不是假装算出了真实容量。
            state = .noRoutineConfigured
        } else if windows.isEmpty {
            state = .noStudyWindow
        } else if usable.isEmpty {
            state = .fullyOccupied
        } else if occupiedInsideWindows.isEmpty {
            state = .fullyFree
        } else {
            state = .partiallyFree
        }

        return AvailabilityDay(
            day: dayStart,
            weekday: weekday,
            weekIndex: isInSemester ? weekIndex : nil,
            referenceNow: now,
            studyWindows: windows,
            occupiedIntervals: occupiedIntervals,
            occupiedMinutesWithinWindows: occupiedMinuteCount,
            freeIntervals: usable,
            discardedIntervals: discarded,
            state: state,
            assumptions: assumptions,
            usesDefaultAssumption: usesDefault,
            minimumFreeBlockMinutes: threshold
        )
    }

    /// 一周中每一天的可安排容量（周视图 / 规划负荷估算使用）。
    static func availability(
        forWeekStarting weekStart: Date,
        semester: ScheduleSemester,
        courses: [Course],
        exceptions: [ScheduleException] = [],
        settings: AvailabilitySettings,
        now: Date? = nil,
        applyDefaultRoutineWhenMissing: Bool = true
    ) -> [AvailabilityDay] {
        let calendar = semester.calendar
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return availability(
                on: day,
                semester: semester,
                courses: courses,
                exceptions: exceptions,
                settings: settings,
                now: now,
                applyDefaultRoutineWhenMissing: applyDefaultRoutineWhenMissing
            )
        }
    }

    // MARK: 窗口展开

    /// 展开某一星期几的学习窗口为绝对时间区间。
    ///
    /// - 包含“前一天开始、跨午夜延续到今天”的窗口尾部。
    /// - `clipToDay = true` 时结果被裁剪到当天 00:00–24:00 之内，
    ///   这样扣除计算永远不会出现负数时长。
    static func studyWindowIntervals(
        for weekday: ScheduleWeekday,
        day: Date,
        settings: AvailabilitySettings,
        semester: ScheduleSemester,
        clipToDay: Bool
    ) -> [DateInterval] {
        let calendar = semester.calendar
        let dayStart = calendar.startOfDay(for: day)
        var intervals: [DateInterval] = []

        func append(range: DayTimeRange) {
            guard range.isValid else { return }
            // 窗口自身的起点可能落在前一天（跨午夜窗口）。
            let baseDay: Date
            if range.weekday == weekday {
                baseDay = dayStart
            } else {
                guard let previous = calendar.date(byAdding: .day, value: -1, to: dayStart) else { return }
                baseDay = previous
            }
            guard let start = range.start.date(on: calendar.startOfDay(for: baseDay), calendar: calendar) else { return }
            let offset = max(0, range.endDayOffset)
            guard let endDay = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: baseDay)),
                  let end = range.end.date(on: endDay, calendar: calendar),
                  end > start else { return }
            var interval = DateInterval(start: start, end: end)
            if clipToDay {
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
                let clippedStart = max(interval.start, dayStart)
                let clippedEnd = min(interval.end, dayEnd)
                guard clippedEnd > clippedStart else { return }
                interval = DateInterval(start: clippedStart, end: clippedEnd)
            }
            intervals.append(interval)
        }

        // 当天自己的窗口。
        for range in settings.studyWindows(for: weekday) {
            append(range: range)
        }

        // 前一天跨午夜延续到今天的窗口（例如周一 21:00–次日 01:00，
        // 在周二的 00:00–01:00 仍然属于学习窗口）。
        let previousWeekday = ScheduleWeekday(rawValue: weekday.rawValue == 1 ? 7 : weekday.rawValue - 1) ?? weekday
        for range in settings.studyWindows(for: previousWeekday) where range.endDayOffset > 0 {
            append(range: range)
        }

        // 合并相邻/重叠窗口，避免同一段时间被算两次。
        return ScheduleResolver.mergedIntervals(intervals)
    }
}
