import Foundation

// C 模块（今日任务自动规划）的独立行为测试。
//
// 这个文件刻意放在源码目标目录（`study software/`）之外：
// Xcode 使用 PBXFileSystemSynchronizedRootGroup，目录内的任何 .swift 都会被编进正式 App，
// 因此测试入口只能通过 swiftc 单独编译。
//
// 运行方式（在工程根目录 `软件本体/study software` 下）：
//
//   make verify-daily-plan
//
// 覆盖的验收标准（都是业务行为断言，不是"函数返回了非空值"）：
//  1. 计划总量不超过预算；预算 = 空档 × 75% × 精力系数，且不超过每日上限扣除已学习后的余额
//  2. 所有安排都落在可用时间段内、不早于 now、互不重叠
//  3. 六层层级顺序正确（硬截止 → 遗忘风险 → 临近考试 → 课程回顾 → 次日预习 → 普通巩固）
//  4. 预算不足时跳过不合适任务并继续尝试其它可执行任务
//  5. 不可拆分任务不会被塞进多个零碎空档
//  6. 硬截止任务放不下时如实返回冲突说明，绝不伪造已排入
//  7. 积压 100 个任务时，计划只包含容量允许的任务
//  8. 重复生成结果稳定、无重复项；相同输入直接复用已有计划
//  9. 已完成的当前复习实例不再进入今日清单
// 10. 同一任务不因同时属于错题与考试重点而重复入选
// 11. 没有候选任务时返回空计划，不为凑预算创建无意义任务
// 12. 没有课程资料时只使用通用任务模板，不声称具体节数
// 13. 手动固定 / 进行中 / 已完成任务不被自动移走
// 14. 时间减少只调整未开始部分；时间增加不自动提高已承诺目标，只给可追加建议
// 15. 精力系数生效，用户手动设置优先于课表估计
// 16. 接入 D 的最低任务策略；未接入时不另写第二套压缩算法
// 17. 到期日期与实际安排日期分开记录
// 18. 解释能回答"为什么是这些任务、为什么是这个任务量"
// 19. 全程不需要 API Key 或网络（只用 Foundation 与本地数据）

@main
struct DailyPlanVerifyHarness {

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
        check(actual == expected, "\(message)（实际 \(actual)，期望 \(expected)）")
    }

    // MARK: - 时间工具

    static let timeZoneIdentifier = "Asia/Shanghai"
    static let weekday = ScheduleWeekday.wednesday

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    /// 2026-09-23（周三）19:00。
    static let now = date(2026, 9, 23, 19, 0)
    static var context: PlanningContext { PlanningContext(now: now, timeZoneIdentifier: timeZoneIdentifier) }
    static var dayKey: StudyDayKey { StudyDayKey(date: now, planningTimeZoneIdentifier: timeZoneIdentifier) }

    // MARK: - 夹具

    static func free(_ hour: Int, _ minute: Int, _ minutes: Int) -> FreeInterval {
        let start = date(2026, 9, 23, hour, minute)
        return FreeInterval(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    static func availability(
        _ intervals: [FreeInterval],
        courses: [OccupiedInterval] = [],
        assumptions: [String] = []
    ) -> AvailabilityDay {
        AvailabilityDay(
            day: date(2026, 9, 23, 0, 0),
            weekday: weekday,
            weekIndex: 4,
            referenceNow: now,
            studyWindows: intervals.map { DateInterval(start: $0.start, end: $0.end) },
            occupiedIntervals: courses,
            occupiedMinutesWithinWindows: courses.reduce(0) { $0 + $1.durationMinutes },
            freeIntervals: intervals,
            discardedIntervals: [],
            state: .partiallyFree,
            assumptions: assumptions,
            usesDefaultAssumption: false,
            minimumFreeBlockMinutes: 5
        )
    }

    static func courseBlock(_ courseID: UUID, start: Date, minutes: Int) -> OccupiedInterval {
        OccupiedInterval(
            kind: .course,
            label: "课程",
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes * 60)),
            sourceCourseID: courseID,
            contributorLabels: ["课程"]
        )
    }

    static func preferences(
        cap: Int? = nil,
        autoReduce: Bool = true,
        allowsMinimum: Bool = true,
        maxTask: Int = 90,
        minimumScopeRatio: Double = 0.4
    ) -> AvailabilityPreferences {
        AvailabilityPreferences(
            routine: .unconfigured,
            planning: PlanningPreferences(
                dailyCapMinutes: cap,
                autoReduceEnabled: autoReduce,
                minimumTaskMinutes: 10,
                maximumTaskMinutes: maxTask,
                breakMinutes: 5,
                reviewShareRatio: 0.6,
                planningTimeZoneIdentifier: timeZoneIdentifier,
                allowsMinimumPlan: allowsMinimum,
                minimumScopeRatio: minimumScopeRatio
            )
        )
    }

    static func manual(
        _ title: String,
        minutes: Int,
        due: Date? = nil,
        preferredStart: Date? = nil,
        isPinned: Bool = false,
        isSplittable: Bool = false,
        scope: StudyScope = .tasks(1)
    ) -> PlanCandidate {
        PlanCandidate(
            source: .manual(note: title),
            title: title,
            plannedScope: scope,
            minimumScope: nil,
            estimatedMinutes: minutes,
            dueDate: due,
            isPinned: isPinned,
            isSplittable: isSplittable,
            note: "",
            preferredStart: preferredStart
        )
    }

    static func review(
        _ task: ReviewTask,
        minutes: Int = 15,
        preferredStart: Date? = nil
    ) -> PlanCandidate {
        PlanCandidate(
            source: .reviewTask(task.id, knowledgePointID: task.knowledgePointID),
            title: task.title,
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.4),
            estimatedMinutes: minutes,
            dueDate: task.dueDate,
            isPinned: false,
            isSplittable: false,
            note: "",
            preferredStart: preferredStart
        )
    }

    static func courseReview(_ courseID: UUID, occurrenceID: UUID, title: String) -> PlanCandidate {
        PlanCandidate(
            source: .courseReview(courseID: courseID, occurrenceID: occurrenceID),
            title: title,
            plannedScope: .sections(1),
            minimumScope: nil,
            estimatedMinutes: 20,
            dueDate: nil,
            isPinned: false,
            isSplittable: false,
            note: "",
            preferredStart: date(2026, 9, 23, 12, 0)
        )
    }

    static func previewCandidate(_ courseID: UUID, occurrenceID: UUID, title: String) -> PlanCandidate {
        PlanCandidate(
            source: .preview(courseID: courseID, occurrenceID: occurrenceID),
            title: title,
            plannedScope: .sections(1),
            minimumScope: nil,
            estimatedMinutes: 20,
            dueDate: nil,
            isPinned: false,
            isSplittable: false,
            note: ""
        )
    }

    static func request(
        candidates: [PlanCandidate],
        availability: AvailabilityDay?,
        preferences: AvailabilityPreferences,
        existingPlans: [DailyStudyPlan] = [],
        completions: [CompletionEvent] = [],
        fingerprint: String = "fp-default"
    ) -> DailyPlanRequest {
        DailyPlanRequest(
            dayKey: dayKey,
            context: context,
            availability: availability,
            preferences: preferences,
            candidates: candidates,
            existingPlans: existingPlans,
            completions: completions,
            inputFingerprint: fingerprint
        )
    }

    static func engine(
        configuration: DailyPlanEngineConfiguration = .standard,
        index: TaskSignalIndex = .empty,
        minimumPolicy: (any MinimumPlanPolicy)? = nil
    ) -> LocalDailyPlanEngine {
        LocalDailyPlanEngine(
            configuration: configuration,
            signalIndex: index,
            minimumPolicy: minimumPolicy
        )
    }

    // MARK: - 校验辅助

    static func itemsFitFreeIntervals(_ items: [DailyPlanItem], in availability: AvailabilityDay) -> Bool {
        for item in items {
            guard let start = item.scheduledStart, let end = item.scheduledEnd else { return false }
            if start < now { return false }
            let fits = availability.freeIntervals.contains { start >= $0.start && end <= $0.end }
            if !fits { return false }
        }
        return true
    }

    static func itemsDoNotOverlap(_ items: [DailyPlanItem]) -> Bool {
        let windows = items
            .compactMap { item -> (Date, Date)? in
                guard let start = item.scheduledStart, let end = item.scheduledEnd else { return nil }
                return (start, end)
            }
            .sorted { $0.0 < $1.0 }
        for (previous, next) in zip(windows, windows.dropFirst()) where next.0 < previous.1 {
            return false
        }
        return true
    }

    static func explanationContains(_ explanation: DailyPlanExplanation, _ needle: String) -> Bool {
        explanation.summaryText.contains(needle)
    }

    // MARK: - 已有的上一版计划（用于稳定性与保护任务测试）

    static let pinnedSource = DailyPlanItemSource.manual(note: "任务P")
    static let inProgressSource = DailyPlanItemSource.manual(note: "任务I")
    static let completedSource = DailyPlanItemSource.manual(note: "任务C")
    static let carriedDSource = DailyPlanItemSource.manual(note: "任务D")
    static let carriedESource = DailyPlanItemSource.manual(note: "任务E")

    static func previousPlan(capacity: Int = 150, target: Int = 60) -> DailyStudyPlan {
        let planID = UUID()
        func makeItem(
            _ source: DailyPlanItemSource,
            _ title: String,
            _ start: Date,
            _ minutes: Int,
            status: DailyPlanItemStatus,
            pinned: Bool = false
        ) -> DailyPlanItem {
            DailyPlanItem(
                planID: planID,
                source: source,
                title: title,
                plannedScope: .tasks(1),
                estimatedMinutes: minutes,
                scheduledStart: start,
                scheduledEnd: start.addingTimeInterval(TimeInterval(minutes * 60)),
                scheduledDayKey: dayKey,
                status: status,
                isPinned: pinned,
                createdAt: now,
                updatedAt: now
            )
        }
        return DailyStudyPlan(
            id: planID,
            dayKey: dayKey,
            version: 1,
            mode: .standard,
            status: .active,
            budget: DailyPlanBudget(capacityMinutes: capacity, dailyCapMinutes: nil, plannedMinutes: 75),
            goal: DailyPlanGoal(targetMinutes: target, targetScope: nil, label: "上一版目标", isUserEdited: true),
            explanation: DailyPlanExplanation(lines: ["上一版计划"]),
            items: [
                makeItem(pinnedSource, "任务P", date(2026, 9, 23, 19, 0), 20, status: .pending, pinned: true),
                makeItem(inProgressSource, "任务I", date(2026, 9, 23, 19, 30), 20, status: .inProgress),
                makeItem(completedSource, "任务C", date(2026, 9, 23, 20, 0), 15, status: .completed),
                makeItem(carriedDSource, "任务D", date(2026, 9, 23, 20, 30), 20, status: .pending),
                makeItem(carriedESource, "任务E", date(2026, 9, 23, 21, 20), 20, status: .pending)
            ],
            inputFingerprint: "previous-fingerprint",
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - 主流程

    static func main() {
        testBudgetDerivation()
        testPlacementsFitAndStable()
        testTierOrdering()
        testBudgetSkipAndContinue()
        testFragmentedGapsRejectUnsplittable()
        testHardDeadlineConflictIsHonest()
        testBacklogOfHundredTasks()
        testRegenerationIsIdempotent()
        testCompletedReviewIsExcluded()
        testMistakeAndExamFocusDedupe()
        testPersistedManualStudyTaskCandidates()
        testEmptyCandidatesProduceEmptyPlan()
        testCourseReviewWithoutMaterialsUsesGenericTemplate()
        testProtectedItemsAreKept()
        testTimeReducedOnlyAdjustsPending()
        testTimeIncreasedDoesNotRaiseCommittedTarget()
        testEnergyCoefficientAndUserOverride()
        testStudiedMinutesCountTowardDailyCap()
        testMinimumPlanPolicyIntegration()
        #if CAN_USE_REAL_MINIMUM_POLICY
        testRealMinimumPolicySeam()
        #endif
        testOfflineWithoutSignalIndex()
        testExplanationAnswersWhy()

        print("")
        print("Daily plan flow verification complete. passed=\(passed) failed=\(failed)")
        if failed > 0 {
            exit(1)
        }
    }

    // MARK: - 1. 预算推导

    static func testBudgetDerivation() {
        print("--- 预算：空档 × 75% × 精力系数，且不超过每日上限 ---")
        let day = availability([free(19, 0, 120), free(21, 10, 30)])
        let candidates = (1...6).map { manual("巩固任务\($0)", minutes: 15) }
        let proposal = engine().proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences())
        )

        // 150 分钟空档 × 0.75 × 0.8（无课程信息 → 默认正常精力）= 90。
        checkEqual(proposal.plan.budget.capacityMinutes, 150, "容量来自未来空档总和")
        checkEqual(proposal.plan.goal.targetMinutes, 90, "预算 = 150 × 0.75 × 0.8")
        checkEqual(proposal.plan.budget.plannedMinutes, 90, "计划总量正好用满预算")
        check(
            proposal.plan.budget.plannedMinutes <= proposal.plan.goal.targetMinutes,
            "计划总量不超过预算"
        )
        check(
            proposal.plan.budget.plannedMinutes <= proposal.plan.budget.effectiveCapacityMinutes,
            "计划总量不超过有效容量（容量与每日上限的较小者）"
        )
        check(explanationContains(proposal.explanation, "75%"), "解释里写明利用比例 75%")
        check(explanationContains(proposal.explanation, "0.8"), "解释里写明精力系数")
        check(explanationContains(proposal.explanation, "生成原因：首次生成"), "解释里记录生成原因")
        check(proposal.plan.goal.label.contains("空档 150 分钟"), "计划目标标注预算推导来源")
    }

    // MARK: - 2. 安排落在空档内

    static func testPlacementsFitAndStable() {
        print("--- 安排必须落在可用时间段内且互不重叠 ---")
        let day = availability([free(19, 0, 120), free(21, 10, 30)])
        let candidates = (1...4).map { manual("任务\($0)", minutes: 20) }
        let proposal = engine().proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences())
        )
        checkEqual(proposal.plan.items.count, 4, "4 条 20 分钟任务在 90 分钟预算内全部排入")
        check(itemsFitFreeIntervals(proposal.plan.items, in: day), "每条任务的起止都落在可用空档内")
        check(itemsDoNotOverlap(proposal.plan.items), "任务之间不重叠")
        check(
            proposal.plan.items.allSatisfy { $0.scheduledDayKey == dayKey },
            "安排日期就是今日学习日"
        )
    }

    // MARK: - 3. 层级顺序

    static func testTierOrdering() {
        print("--- 六层层级：硬截止 → 遗忘风险 → 临近考试 → 课程回顾 → 次日预习 → 普通巩固 ---")
        let courseID = UUID()
        let pointHard = KnowledgePoint(title: "硬截止知识点", subject: "大学物理", summary: "", mastery: 0.5)
        let pointRisk = KnowledgePoint(title: "薄弱知识点", subject: "线性代数", summary: "", mastery: 0.1)
        let pointExam = KnowledgePoint(title: "考试知识点", subject: "高等数学", summary: "", mastery: 0.6)
        let hardTask = ReviewTask(
            title: "逾期复习", dueDate: date(2026, 9, 21, 8, 0),
            knowledgePointID: pointHard.id, priority: 5, repetitionCount: 2, intervalDays: 7, lastQuality: 4
        )
        let riskTask = ReviewTask(
            title: "薄弱复习", dueDate: date(2026, 9, 24, 8, 0),
            knowledgePointID: pointRisk.id, repetitionCount: 0, intervalDays: 0
        )
        let examTask = ReviewTask(
            title: "考试复习", dueDate: date(2026, 10, 3, 8, 0),
            knowledgePointID: pointExam.id, repetitionCount: 3, intervalDays: 7, lastQuality: 5
        )
        let exam = ExamGoal(
            name: "期中考试", examDate: date(2026, 9, 26, 9, 0),
            subjects: ["高等数学"], dailyAvailableMinutes: 120, targetScore: "90"
        )
        let index = TaskSignalIndex(
            reviewTasks: [hardTask, riskTask, examTask],
            knowledgePoints: [pointHard, pointRisk, pointExam],
            examGoals: [exam]
        )
        let candidates = [
            review(hardTask),
            review(riskTask),
            review(examTask),
            courseReview(courseID, occurrenceID: UUID(), title: "课程回顾：普通课程"),
            previewCandidate(courseID, occurrenceID: UUID(), title: "课前预习：普通课程"),
            manual("普通巩固任务", minutes: 20)
        ]
        let proposal = engine(index: index).proposePlan(
            request(
                candidates: candidates,
                availability: availability([free(19, 0, 240)]),
                preferences: preferences()
            )
        )

        let kinds = proposal.plan.items.map { $0.source.kind }
        checkEqual(proposal.plan.items.count, 6, "预算充足时六条候选全部排入")
        checkEqual(
            kinds,
            [.reviewTask, .reviewTask, .reviewTask, .courseReview, .preview, .manual],
            "任务顺序符合六层层级"
        )
        check(proposal.plan.items[0].title == "逾期复习", "第 1 层是硬截止任务")
        check(proposal.plan.items[1].title == "薄弱复习", "第 2 层是遗忘风险任务")
        check(proposal.plan.items[2].title == "考试复习", "第 3 层是临近考试任务")
        check(proposal.plan.items[0].note.contains("第 1 层"), "计划项说明标注第 1 层")
        check(proposal.plan.items[1].note.contains("第 2 层"), "计划项说明标注第 2 层")
        check(proposal.plan.items[2].note.contains("第 3 层"), "计划项说明标注第 3 层")
        check(proposal.plan.items[5].note.contains("第 6 层"), "计划项说明标注第 6 层")
        check(explanationContains(proposal.explanation, "当天硬截止 1"), "解释里统计硬截止任务数")
        check(explanationContains(proposal.explanation, "临近考试 1"), "解释里统计临近考试任务数")
    }

    // MARK: - 4. 预算不足时跳过并继续

    static func testBudgetSkipAndContinue() {
        print("--- 预算不足时跳过不合适任务并继续尝试其它任务 ---")
        let day = availability([free(19, 0, 40)])
        // 40 分钟空档 × 0.75 × 0.8 = 24 分钟预算。
        let candidates = [
            manual("硬截止大任务", minutes: 30, due: date(2026, 9, 23, 8, 0)),
            manual("小任务甲", minutes: 10),
            manual("小任务乙", minutes: 10)
        ]
        let proposal = engine().proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences())
        )
        checkEqual(proposal.plan.goal.targetMinutes, 24, "预算为 24 分钟")
        checkEqual(proposal.plan.items.count, 2, "放不下的 30 分钟任务被跳过，两条 10 分钟任务排入")
        check(proposal.plan.budget.plannedMinutes <= 24, "跳过之后总量仍然不超过预算")
        check(
            proposal.unplaceable.contains { $0.title == "硬截止大任务" },
            "放不下的任务进入待安排列表"
        )
        check(
            !proposal.plan.items.contains { $0.title == "硬截止大任务" },
            "放不下的任务没有被伪造为已排入"
        )
    }

    // MARK: - 5. 碎片空档

    static func testFragmentedGapsRejectUnsplittable() {
        print("--- 不可拆分任务不会被塞进多个零碎空档 ---")
        let day = availability([free(19, 0, 20), free(19, 30, 20)])
        let candidates = [manual("不可拆分 25 分钟任务", minutes: 25)]
        // 精力设为充足 → 预算 floor(40 × 0.75 × 1.0) = 30 分钟，足够 25 分钟，问题只在碎片化。
        let configuration = DailyPlanEngineConfiguration(energyOverride: .energetic)
        let proposal = engine(configuration: configuration).proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences())
        )
        checkEqual(proposal.plan.goal.targetMinutes, 30, "充足精力下预算为 30 分钟")
        check(proposal.plan.items.isEmpty, "25 分钟任务没有被硬塞进两段 20 分钟空档")
        checkEqual(proposal.unplaceable.count, 1, "任务进入待安排列表")
        checkEqual(proposal.unplaceable.first?.reason, .notSplittable, "原因是空档碎片化")
        check(
            proposal.unplaceable.first?.detail.contains("不可拆分") == true,
            "说明里写明不可拆分任务不跨碎片硬塞"
        )
    }

    // MARK: - 6. 硬截止冲突

    static func testHardDeadlineConflictIsHonest() {
        print("--- 硬截止任务放不下时返回冲突说明，不伪造已排入 ---")
        let day = availability([free(19, 0, 40)])
        let candidates = [
            manual("必须今天完成的复习", minutes: 30, due: date(2026, 9, 23, 8, 0)),
            manual("普通任务", minutes: 10)
        ]
        let proposal = engine().proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences())
        )
        check(
            !proposal.plan.items.contains { $0.title == "必须今天完成的复习" },
            "硬截止任务没有被排入"
        )
        check(
            explanationContains(proposal.explanation, "硬截止任务「必须今天完成的复习」今天放不下"),
            "解释里明确写出硬截止冲突"
        )
        check(
            proposal.explanation.blockedReasons.contains { $0.contains("未排入计划") },
            "冲突说明里写明未排入计划"
        )
        check(
            proposal.unplaceable.first?.detail.contains("硬截止") == true,
            "待安排列表标记这是硬截止任务"
        )
    }

    // MARK: - 7. 100 积压任务

    static func testBacklogOfHundredTasks() {
        print("--- 积压 100 个任务时只安排容量允许的部分 ---")
        let day = availability([free(19, 0, 120), free(21, 10, 30)])
        let candidates = (1...100).map { manual("积压任务\($0)", minutes: 15) }
        let proposal = engine().proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences())
        )
        checkEqual(proposal.plan.goal.targetMinutes, 90, "预算仍为 90 分钟")
        checkEqual(proposal.plan.items.count, 6, "只排入 90 ÷ 15 = 6 条任务")
        check(proposal.plan.budget.plannedMinutes <= 90, "总量不超过预算")
        checkEqual(proposal.unplaceable.count, 94, "其余 94 条保留在待安排列表，不删除")
        let identities = Set(proposal.plan.items.map(\.source))
        checkEqual(identities.count, proposal.plan.items.count, "计划里没有重复任务")
    }

    // MARK: - 8. 重复生成稳定

    static func testRegenerationIsIdempotent() {
        print("--- 重复生成结果稳定、无重复项 ---")
        let day = availability([free(19, 0, 120)])
        let candidates = (1...5).map { manual("稳定任务\($0)", minutes: 20) }
        let requestA = request(
            candidates: candidates,
            availability: day,
            preferences: preferences(),
            fingerprint: "fp-stable"
        )
        let engineUnderTest = engine()
        let first = engineUnderTest.proposePlan(requestA)

        // 同一输入再次生成：直接把上一版计划作为已有计划传入（G 的真实调用方式）。
        let second = engineUnderTest.proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences(), existingPlans: [first.plan], fingerprint: "fp-stable")
        )
        check(second.didReuseExistingPlan, "相同输入指纹时复用已有计划，不新增版本")
        checkEqual(second.plan.version, first.plan.version, "复用时不产生新版本号")

        // 强制重建（禁用复用）也必须产出完全相同的任务集合与身份。
        let rebuildConfiguration = DailyPlanEngineConfiguration(reusesUnchangedPlan: false)
        let rebuilt = engine(configuration: rebuildConfiguration).proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences(), existingPlans: [first.plan], fingerprint: "fp-stable")
        )
        check(!rebuilt.didReuseExistingPlan, "禁用复用时确实重建了计划")
        checkEqual(
            rebuilt.plan.items.map(\.id).sorted { $0.uuidString < $1.uuidString },
            first.plan.items.map(\.id).sorted { $0.uuidString < $1.uuidString },
            "重建后任务身份完全一致（无重复计划项）"
        )
        checkEqual(rebuilt.plan.items.count, first.plan.items.count, "重建后任务数量一致")

        // 输入顺序打乱不应改变结果。
        let shuffled = engine(configuration: rebuildConfiguration).proposePlan(
            request(
                candidates: candidates.reversed(),
                availability: day,
                preferences: preferences(),
                existingPlans: [first.plan],
                fingerprint: "fp-stable"
            )
        )
        checkEqual(shuffled.plan.items.map(\.title), first.plan.items.map(\.title), "候选顺序打乱不改变排程结果")
    }

    // MARK: - 9. 已完成排除

    static func testCompletedReviewIsExcluded() {
        print("--- 已完成的当前复习实例不再进入今日清单 ---")
        let doneTask = ReviewTask(title: "今天已复习", dueDate: date(2026, 9, 23, 2, 0))
        let closedTask = ReviewTask(title: "已标记完成", dueDate: date(2026, 9, 23, 2, 0), status: .done)
        let openTask = ReviewTask(title: "还没复习", dueDate: date(2026, 9, 23, 2, 0))
        let index = TaskSignalIndex(reviewTasks: [doneTask, closedTask, openTask])
        let completion = CompletionEvent.make(
            dayKey: dayKey,
            source: .reviewTask(doneTask.id, knowledgePointID: nil),
            plannedScope: .tasks(1),
            completedScope: .tasks(1),
            actualMinutes: 15,
            completedAt: date(2026, 9, 23, 18, 0),
            createdAt: date(2026, 9, 23, 18, 0)
        )
        let candidates = [review(doneTask), review(closedTask), review(openTask)]
        let proposal = engine(index: index).proposePlan(
            request(
                candidates: candidates,
                availability: availability([free(19, 0, 120)]),
                preferences: preferences(),
                completions: [completion]
            )
        )
        let titles = proposal.plan.items.map(\.title)
        check(!titles.contains("今天已复习"), "有完成事件的复习任务不再排入")
        check(!titles.contains("已标记完成"), "状态为已完成的复习任务不再排入")
        check(titles.contains("还没复习"), "未完成的复习任务仍然排入")
        check(explanationContains(proposal.explanation, "已排除 2 项今天已经完成过的任务"), "解释统计被排除的已完成任务")
    }

    // MARK: - 10. 错题 / 考试重点去重

    static func testMistakeAndExamFocusDedupe() {
        print("--- 同一任务不因同时属于错题与考试重点而重复入选 ---")
        let sharedMistake = UUID()
        let sharedPoint = UUID()
        let mistakeTask = ReviewTask(
            title: "错题复习", dueDate: date(2026, 9, 23, 2, 0),
            knowledgePointID: sharedPoint, mistakeID: sharedMistake
        )
        let examFocusTask = ReviewTask(
            title: "考试重点复习", dueDate: date(2026, 9, 23, 2, 0),
            knowledgePointID: sharedPoint, mistakeID: sharedMistake, priority: 9
        )
        let otherTask = ReviewTask(
            title: "同知识点另一任务", dueDate: date(2026, 9, 23, 2, 0),
            knowledgePointID: sharedPoint
        )
        let point = KnowledgePoint(id: sharedPoint, title: "共享知识点", subject: "高等数学", summary: "", mastery: 0.3)
        let mistake = Mistake(id: sharedMistake, question: "题", correctAnswer: "答", errorReason: "粗心")
        let index = TaskSignalIndex(
            reviewTasks: [mistakeTask, examFocusTask, otherTask],
            knowledgePoints: [point],
            mistakes: [mistake]
        )
        let manualOnSamePoint = PlanCandidate(
            source: .manual(note: "我自己加的任务", knowledgePointID: sharedPoint),
            title: "我自己加的任务",
            plannedScope: .tasks(1),
            minimumScope: nil,
            estimatedMinutes: 20,
            dueDate: nil,
            isPinned: false,
            isSplittable: false,
            note: ""
        )
        let set = TaskCandidateBuilder.build(
            TaskCandidateInput(
                dayKey: dayKey,
                context: context,
                rawCandidates: [review(mistakeTask), review(examFocusTask), review(otherTask), manualOnSamePoint],
                signalIndex: index
            )
        )
        checkEqual(set.candidates.count, 2, "三条指向同一错题/知识点的复习任务合并为一条，手动任务独立保留")
        checkEqual(
            set.exclusions.filter { $0.reason == .duplicateOfSameObject }.count,
            2,
            "两条重复任务被记录为同一对象的重复"
        )
        check(
            set.candidates.contains { $0.candidate.source.kind == .manual },
            "手动任务不会被复习任务吞掉"
        )
    }

    static func testPersistedManualStudyTaskCandidates() {
        print("--- 持久化手动任务按可选到期日进入候选池，同名仍有独立身份 ---")
        let first = ManualStudyTask(
            title: "复习课堂笔记",
            note: "看老师发的讲义",
            dayKey: dayKey,
            estimatedMinutes: 25,
            createdAt: now
        )
        let second = ManualStudyTask(
            title: "复习课堂笔记",
            note: "看老师发的讲义",
            dayKey: dayKey,
            estimatedMinutes: 20,
            createdAt: now.addingTimeInterval(1)
        )
        let tomorrow = ManualStudyTask(
            title: "明天预习",
            dayKey: context.dayKey(for: date(2026, 9, 24, 12, 0)),
            createdAt: now
        )
        var snapshot = StoreSnapshot()
        snapshot.manualStudyTasks = [first, second, tomorrow]

        let candidates = PlanCandidateBuilder.candidates(
            from: snapshot,
            dayKey: dayKey,
            context: context,
            includeCourseWork: false
        )
        checkEqual(candidates.count, 2, "仅指定学习日的持久化任务进入计划候选")
        check(candidates.allSatisfy { !$0.isPinned }, "手动任务不被固定，排期仍受今日容量限制")
        checkEqual(Set(candidates.compactMap { $0.source.manualTaskID }).count, 2, "两条同名任务保留不同持久化身份")
        check(candidates.contains { $0.note == "看老师发的讲义" }, "手动任务备注进入候选内容")

        let completedEvent = CompletionEvent.make(
            dayKey: dayKey,
            source: .manual(note: first.note, manualTaskID: first.id),
            plannedScope: .tasks(1),
            completedScope: .tasks(1),
            actualMinutes: 20,
            completedAt: now,
            createdAt: now,
            idempotencyKey: "manual-task-completion"
        )
        let completedCandidate = candidates.first { $0.source.manualTaskID == first.id }!
        check(
            TaskCandidateBuilder.isCompletedToday(
                raw: completedCandidate,
                signals: TaskSignalIndex.empty.signals(
                    for: completedCandidate,
                    dayKey: dayKey,
                    context: context,
                    existingActivePlan: nil
                ),
                reviewTask: nil,
                dayKey: dayKey,
                existingPlans: [],
                completions: [completedEvent]
            ),
            "已经完成的手动任务当天不会再次进入计划"
        )

        let tomorrowContext = PlanningContext(now: date(2026, 9, 24, 12, 0), timeZoneIdentifier: timeZoneIdentifier)
        let tomorrowKey = tomorrowContext.todayKey
        let afterCompletion = snapshot
        var completedSnapshot = afterCompletion
        completedSnapshot.completionEvents = [completedEvent]
        let nextDayCandidates = PlanCandidateBuilder.candidates(
            from: completedSnapshot,
            dayKey: tomorrowKey,
            context: tomorrowContext,
            includeCourseWork: false
        )
        checkEqual(nextDayCandidates.count, 2, "跨日重算继续保留未完成任务并排除已完成的同名任务")
        check(!nextDayCandidates.contains { $0.source.manualTaskID == first.id }, "有效完成会跨日阻止同一手动任务重复进入候选池")
        check(nextDayCandidates.contains { $0.source.manualTaskID == second.id }, "同名的另一条手动任务仍独立进入候选池")

        completedSnapshot.completionEvents = [completedEvent.revoked(at: now.addingTimeInterval(60), reason: "合成撤销")]
        let afterRevocation = PlanCandidateBuilder.candidates(
            from: completedSnapshot,
            dayKey: tomorrowKey,
            context: tomorrowContext,
            includeCourseWork: false
        )
        check(afterRevocation.contains { $0.source.manualTaskID == first.id }, "撤销完成后手动任务重新进入候选池")

        let noCapacity = engine().proposePlan(
            request(candidates: candidates, availability: availability([]), preferences: preferences())
        )
        check(noCapacity.plan.items.isEmpty, "没有可用容量时手动任务不会绕过计划预算")
        checkEqual(noCapacity.plan.budget.plannedMinutes, 0, "无容量计划的预计分钟保持为零")
        checkEqual(noCapacity.unplaceable.count, candidates.count, "放不下的手动任务仍保留在待安排列表")
        check(noCapacity.unplaceable.contains { $0.title == first.title }, "待安排列表保留手动任务标题")
    }

    // MARK: - 11. 空候选

    static func testEmptyCandidatesProduceEmptyPlan() {
        print("--- 没有候选任务时返回空计划，不为凑预算造任务 ---")
        let day = availability([free(19, 0, 120)])
        let proposal = engine().proposePlan(
            request(candidates: [], availability: day, preferences: preferences())
        )
        check(proposal.plan.items.isEmpty, "空候选 → 空计划")
        check(proposal.unplaceable.isEmpty, "没有候选也就没有待安排项")
        checkEqual(proposal.plan.budget.plannedMinutes, 0, "计划总量为 0")
        check(explanationContains(proposal.explanation, "没有排入任务"), "解释说明今天没有排入任务")
        let genericTitles = GenericTaskTemplate.allCases.map(\.title)
        check(
            !proposal.plan.items.contains { genericTitles.contains($0.title) },
            "没有为了凑预算造出通用任务"
        )
    }

    // MARK: - 12. 无资料的课程回顾

    static func testCourseReviewWithoutMaterialsUsesGenericTemplate() {
        print("--- 没有课程资料时只使用通用任务模板 ---")
        let courseID = UUID()
        let candidate = courseReview(courseID, occurrenceID: UUID(), title: "课程回顾：高等数学")
        let noMaterialIndex = TaskSignalIndex(courseHasMaterials: [courseID: false])
        let noMaterial = engine(index: noMaterialIndex).proposePlan(
            request(candidates: [candidate], availability: availability([free(19, 0, 120)]), preferences: preferences())
        )
        checkEqual(noMaterial.plan.items.first?.plannedScope, .tasks(1), "没有资料时按「1 个任务」记录，不声称具体节数")

        let withMaterialIndex = TaskSignalIndex(courseHasMaterials: [courseID: true])
        let withMaterial = engine(index: withMaterialIndex).proposePlan(
            request(candidates: [candidate], availability: availability([free(19, 0, 120)]), preferences: preferences())
        )
        checkEqual(withMaterial.plan.items.first?.plannedScope, .sections(1), "有资料时才保留课程声明的节数")

        // 缺少课程关联的课程回顾必须被拦下，不编造内容。
        let dangling = PlanCandidate(
            source: DailyPlanItemSource(kind: .courseReview, courseID: nil, occurrenceID: nil),
            title: "课程回顾",
            plannedScope: .sections(1),
            estimatedMinutes: 20,
            isSplittable: false
        )
        let danglingSet = TaskCandidateBuilder.build(
            TaskCandidateInput(dayKey: dayKey, context: context, rawCandidates: [dangling], signalIndex: .empty)
        )
        check(danglingSet.candidates.isEmpty, "缺少课程关联的课程回顾被排除")
        checkEqual(danglingSet.exclusions.first?.reason, .missingSourceData, "排除原因是来源数据缺失")
    }

    // MARK: - 13. 保护任务

    static func testProtectedItemsAreKept() {
        print("--- 手动固定 / 进行中 / 已完成任务不被自动移走 ---")
        let day = availability([free(19, 0, 120), free(21, 10, 30)])
        let previous = previousPlan()
        let candidates = [
            manual("任务P", minutes: 20, isPinned: true),
            manual("任务I", minutes: 20),
            manual("任务C", minutes: 15),
            manual("任务D", minutes: 20),
            manual("任务E", minutes: 20),
            manual("任务N1", minutes: 20),
            manual("任务N2", minutes: 20),
            manual("任务N3", minutes: 20)
        ]
        let proposal = engine().proposePlan(
            request(
                candidates: candidates,
                availability: day,
                preferences: preferences(),
                existingPlans: [previous],
                fingerprint: "fp-protected"
            )
        )
        let byTitle = Dictionary(uniqueKeysWithValues: proposal.plan.items.map { ($0.title, $0) })
        check(byTitle["任务P"]?.isPinned == true, "固定任务仍在计划里且保持固定标记")
        checkEqual(byTitle["任务P"]?.scheduledStart, date(2026, 9, 23, 19, 0), "固定任务的时间没有被移动")
        checkEqual(byTitle["任务I"]?.status, .inProgress, "进行中的任务状态被保留")
        checkEqual(byTitle["任务I"]?.scheduledStart, date(2026, 9, 23, 19, 30), "进行中的任务时间没有被移动")
        checkEqual(byTitle["任务C"]?.status, .completed, "已完成任务被保留在计划里")
        checkEqual(byTitle["任务D"]?.scheduledStart, date(2026, 9, 23, 20, 30), "未开始任务沿用原时间段（不来回搬动）")
        checkEqual(byTitle["任务E"]?.scheduledStart, date(2026, 9, 23, 21, 20), "另一条未开始任务同样保持稳定")
        check(!byTitle.keys.contains("任务N1"), "预算不足时新任务不排入")
        check(explanationContains(proposal.explanation, "已保留 3 项"), "解释说明保留了 3 项受保护任务")
        check(itemsDoNotOverlap(proposal.plan.items), "保留任务与新任务之间不重叠")
        let placed = proposal.plan.items.filter { $0.status == .pending && $0.title != "任务P" }
        check(itemsFitFreeIntervals(placed, in: day), "新排入的任务都落在可用空档内")
    }

    // MARK: - 14. 时间减少

    static func testTimeReducedOnlyAdjustsPending() {
        print("--- 时间减少时只调整未开始部分 ---")
        let previous = previousPlan(capacity: 150)
        let reducedDay = availability([free(19, 0, 100)])
        let candidates = [
            manual("任务P", minutes: 20, isPinned: true),
            manual("任务I", minutes: 20),
            manual("任务C", minutes: 15),
            manual("任务D", minutes: 20),
            manual("任务E", minutes: 20),
            manual("任务N1", minutes: 20),
            manual("任务N2", minutes: 20),
            manual("任务N3", minutes: 20)
        ]
        let proposal = engine().proposePlan(
            request(
                candidates: candidates,
                availability: reducedDay,
                preferences: preferences(),
                existingPlans: [previous],
                fingerprint: "fp-reduced"
            )
        )
        let titles = proposal.plan.items.map(\.title)
        check(titles.contains("任务P"), "时间减少后固定任务仍在")
        check(titles.contains("任务I"), "时间减少后进行中的任务仍在")
        check(titles.contains("任务C"), "时间减少后已完成任务仍在")
        checkEqual(
            proposal.plan.items.first { $0.title == "任务I" }?.scheduledStart,
            date(2026, 9, 23, 19, 30),
            "进行中任务的时间没有被改动"
        )
        check(!titles.contains("任务E"), "排不下的未开始任务被移到待安排列表")
        check(
            proposal.unplaceable.contains { $0.title == "任务E" },
            "未开始任务保留在待安排列表，没有删除"
        )
        check(explanationContains(proposal.explanation, "生成原因：可用时间减少"), "解释记录生成原因：可用时间减少")
        check(itemsDoNotOverlap(proposal.plan.items), "调整之后任务之间仍然不重叠")
    }

    // MARK: - 15. 时间增加

    static func testTimeIncreasedDoesNotRaiseCommittedTarget() {
        print("--- 时间增加时输出可追加建议，不自动提高已承诺目标 ---")
        let previous = previousPlan(capacity: 150, target: 60)
        let biggerDay = availability([free(19, 0, 120), free(21, 10, 170)])
        let candidates = [
            manual("任务P", minutes: 20, isPinned: true),
            manual("任务I", minutes: 20),
            manual("任务C", minutes: 15),
            manual("任务D", minutes: 20),
            manual("任务E", minutes: 20),
            manual("任务N1", minutes: 20),
            manual("任务N2", minutes: 20),
            manual("任务N3", minutes: 20)
        ]
        let proposal = engine().proposePlan(
            request(
                candidates: candidates,
                availability: biggerDay,
                preferences: preferences(),
                existingPlans: [previous],
                fingerprint: "fp-increased"
            )
        )
        checkEqual(proposal.plan.goal.targetMinutes, 60, "已承诺目标 60 分钟没有被自动提高")
        check(explanationContains(proposal.explanation, "生成原因：可用时间增加"), "解释记录生成原因：可用时间增加")
        check(explanationContains(proposal.explanation, "已承诺目标 60 分钟保持不变"), "解释说明不自动加码")
        check(explanationContains(proposal.explanation, "可追加（未自动排入）"), "解释输出可追加建议")
        check(
            proposal.unplaceable.contains { $0.detail.contains("为不提高已承诺目标") },
            "可追加任务保留在待安排列表并说明原因"
        )
        check(proposal.plan.goal.label.contains("保留上一版承诺目标"), "计划目标标注保留了上一版承诺")
    }

    // MARK: - 16. 精力

    static func testEnergyCoefficientAndUserOverride() {
        print("--- 精力系数生效，用户手动设置优先 ---")
        let day = availability([free(19, 0, 120), free(21, 10, 30)])
        let tired = engine(configuration: DailyPlanEngineConfiguration(energyOverride: .tired))
            .proposePlan(request(candidates: [], availability: day, preferences: preferences()))
        checkEqual(tired.plan.goal.targetMinutes, 67, "较累（0.6）：150 × 0.75 × 0.6 = 67 分钟")

        let energetic = engine(configuration: DailyPlanEngineConfiguration(energyOverride: .energetic))
            .proposePlan(request(candidates: [], availability: day, preferences: preferences()))
        checkEqual(energetic.plan.goal.targetMinutes, 112, "充足（1.0）：150 × 0.75 × 1.0 = 112 分钟")

        check(
            explanationContains(tired.explanation, "用户手动设置"),
            "解释说明精力来自用户设置（而不是把估计说成用户设置）"
        )

        // 课表负担很重 → 默认建议更保守；用户设置优先于估计。
        let heavyCourseID = UUID()
        let heavyDay = availability(
            [free(19, 0, 120), free(21, 10, 30)],
            courses: [courseBlock(heavyCourseID, start: date(2026, 9, 23, 8, 0), minutes: 300)]
        )
        let heavyIndex = TaskSignalIndex(courseBurdenByCourseID: [heavyCourseID: .veryHeavy])
        let heavy = engine(index: heavyIndex)
            .proposePlan(request(candidates: [], availability: heavyDay, preferences: preferences()))
        checkEqual(heavy.plan.goal.targetMinutes, 67, "很重负担的课表日按较累估计 → 67 分钟")

        let lightCourseID = UUID()
        let lightDay = availability(
            [free(19, 0, 120), free(21, 10, 30)],
            courses: [courseBlock(lightCourseID, start: date(2026, 9, 23, 8, 0), minutes: 60)]
        )
        let lightIndex = TaskSignalIndex(courseBurdenByCourseID: [lightCourseID: .light])
        let light = engine(index: lightIndex)
            .proposePlan(request(candidates: [], availability: lightDay, preferences: preferences()))
        checkEqual(light.plan.goal.targetMinutes, 112, "轻松负担的课表日按充足估计 → 112 分钟")

        let override = engine(
            configuration: DailyPlanEngineConfiguration(energyOverride: .energetic),
            index: heavyIndex
        ).proposePlan(request(candidates: [], availability: heavyDay, preferences: preferences()))
        checkEqual(override.plan.goal.targetMinutes, 112, "用户手动设置的精力和覆盖课表估计")
        check(
            explanationContains(override.explanation, "用户手动设置"),
            "解释说明用户设置优先"
        )
    }

    // MARK: - 17. 已学习时间计入上限

    static func testStudiedMinutesCountTowardDailyCap() {
        print("--- 已学习的有效时间计入当天上限 ---")
        let day = availability([free(19, 0, 150)])
        let task = ReviewTask(title: "早上复习过的任务", dueDate: date(2026, 9, 23, 2, 0))
        let completion = CompletionEvent.make(
            dayKey: dayKey,
            source: .reviewTask(task.id, knowledgePointID: nil),
            plannedScope: .tasks(1),
            completedScope: .tasks(1),
            actualMinutes: 45,
            completedAt: date(2026, 9, 23, 9, 0),
            createdAt: date(2026, 9, 23, 9, 0)
        )
        let candidates = (1...4).map { manual("任务\($0)", minutes: 15) }
        let proposal = engine().proposePlan(
            request(
                candidates: candidates,
                availability: day,
                preferences: preferences(cap: 60),
                completions: [completion]
            )
        )
        checkEqual(proposal.plan.goal.targetMinutes, 15, "每日上限 60 减去已学习 45 → 预算只剩 15 分钟")
        check(proposal.plan.budget.plannedMinutes <= 15, "排入总量不超过上限剩余额度")
        checkEqual(proposal.plan.items.count, 1, "只排入一条 15 分钟任务")
        check(
            explanationContains(proposal.explanation, "今天已学习并计入上限 45 分钟"),
            "解释里写明已学习时间计入上限"
        )
    }

    // MARK: - 18. D 的最低保底策略

    final class RecordingMinimumPolicy: MinimumPlanPolicy {
        var callCount = 0
        var lastRemaining = -1
        var lastSplittable: Set<UUID> = []
        var isEmptyResult = false

        func reduce(
            plan: DailyStudyPlan,
            remainingMinutes: Int,
            splittableItemIDs: Set<UUID>,
            context: PlanningContext
        ) -> MinimumPlanProposal {
            callCount += 1
            lastRemaining = remainingMinutes
            lastSplittable = splittableItemIDs
            if isEmptyResult {
                return MinimumPlanProposal(plan: plan, changes: [], explanation: DailyPlanExplanation(), isEmpty: true)
            }
            var changed = plan
            changed.mode = .minimum
            let kept = Array(plan.items.prefix(1))
            changed.items = kept
            let change = MinimumPlanChange(
                itemID: kept.first?.id ?? UUID(),
                title: kept.first?.title ?? "",
                kind: .convertedToMinimum,
                beforeMinutes: 20,
                afterMinutes: 10,
                reason: "保底"
            )
            return MinimumPlanProposal(
                plan: changed,
                changes: [change],
                explanation: DailyPlanExplanation(lines: ["D：已按保底策略减量。"]),
                isEmpty: false
            )
        }
    }

    static func testMinimumPlanPolicyIntegration() {
        print("--- 接入 D 的最低任务策略；未接入时不另写压缩算法 ---")
        let day = availability([free(19, 0, 40)])
        let candidates = [
            manual("硬截止大任务", minutes: 30, due: date(2026, 9, 23, 8, 0)),
            manual("可拆分小任务", minutes: 10, isSplittable: true),
            manual("普通小任务", minutes: 10)
        ]

        let policy = RecordingMinimumPolicy()
        let connected = engine(minimumPolicy: policy).proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences())
        )
        checkEqual(policy.callCount, 1, "放不下任务时调用一次最低任务策略")
        checkEqual(connected.plan.mode, .minimum, "采用 D 返回的保底模式")
        checkEqual(connected.plan.items.count, 1, "采用 D 减量后的任务集合")
        checkEqual(policy.lastSplittable.count, 1, "把可拆分任务 ID 交给 D")
        check(explanationContains(connected.explanation, "已接入最低任务策略（D）"), "解释说明已接入 D 的策略")
        check(explanationContains(connected.explanation, "D：已按保底策略减量"), "解释合并了 D 的说明")

        let policyNotNeeded = RecordingMinimumPolicy()
        let noUnplaceable = engine(minimumPolicy: policyNotNeeded).proposePlan(
            request(
                candidates: [manual("小任务", minutes: 10)],
                availability: day,
                preferences: preferences()
            )
        )
        checkEqual(policyNotNeeded.callCount, 0, "没有放不下的任务时不调用减量策略")
        checkEqual(noUnplaceable.plan.mode, .standard, "不需要减量时保持标准模式")

        let notConnected = engine().proposePlan(
            request(candidates: candidates, availability: day, preferences: preferences())
        )
        checkEqual(notConnected.plan.mode, .standard, "D 未接入时不做任何本地压缩")
        check(
            explanationContains(notConnected.explanation, "最低任务策略（D）尚未接入"),
            "解释如实说明 D 尚未接入"
        )
        check(
            notConnected.plan.items
                .filter { $0.source.kind == .manual }
                .allSatisfy { $0.minimumScope == nil && $0.plannedScope == .tasks(1) },
            "未接入 D 时没有为任务私自编造保底范围"
        )
        checkEqual(notConnected.plan.items.count, 2, "未接入 D 时按标准策略排入两条放得下的任务")

        let policyDisabled = RecordingMinimumPolicy()
        _ = engine(minimumPolicy: policyDisabled).proposePlan(
            request(
                candidates: candidates,
                availability: day,
                preferences: preferences(autoReduce: false)
            )
        )
        checkEqual(policyDisabled.callCount, 0, "关闭自动减量时不调用减量策略")
    }

    #if CAN_USE_REAL_MINIMUM_POLICY

    // MARK: - 18b. 与 D 的真实策略对接

    /// 用 D 真实的 `StudyMinimumPlanPolicy` 跑一遍，验证接口对接真的可用，
    /// 而且 C 没有另写一套压缩逻辑（减量只会缩小范围、不会凭空新增任务）。
    static func testRealMinimumPolicySeam() {
        print("--- 与 D 真实的最低价策略实现对接 ---")
        let day = availability([free(19, 0, 40)])
        let candidates = [
            manual("硬截止大任务", minutes: 30, due: date(2026, 9, 23, 8, 0)),
            manual("可拆分小任务", minutes: 10, isSplittable: true),
            manual("普通小任务", minutes: 10)
        ]
        let requestInput = request(
            candidates: candidates,
            availability: day,
            preferences: preferences(),
            fingerprint: "fp-real-seam"
        )
        let standard = engine().proposePlan(requestInput)
        let connected = engine(minimumPolicy: StudyMinimumPlanPolicy()).proposePlan(requestInput)

        check(
            explanationContains(connected.explanation, "已接入最低任务策略（D）"),
            "解释显示已接入 D 的真实策略"
        )
        let standardIDs = Set(standard.plan.items.map(\.id))
        let connectedIDs = Set(connected.plan.items.map(\.id))
        check(connectedIDs.isSubset(of: standardIDs), "D 的减量不会凭空新增任务")
        check(
            connected.plan.budget.plannedMinutes <= standard.plan.budget.plannedMinutes,
            "D 的减量只会让计划总量变小或不变"
        )
        var unitsPreserved = true
        for item in connected.plan.items {
            guard let before = standard.plan.items.first(where: { $0.id == item.id }) else { continue }
            if before.plannedScope.unit != item.plannedScope.unit { unitsPreserved = false }
            if item.plannedScope.amount > before.plannedScope.amount { unitsPreserved = false }
        }
        check(unitsPreserved, "D 只缩小同量纲的任务范围，不改量纲、不编造内容")
        check(
            connected.plan.budget.plannedMinutes <= connected.plan.goal.targetMinutes,
            "减量之后计划总量仍然不超过预算"
        )
    }

    #endif

    // MARK: - 19. 无索引 / 离线

    static func testOfflineWithoutSignalIndex() {
        print("--- 没有 API Key、没有网络、没有信号索引也能工作 ---")
        let day = availability([free(19, 0, 120)])
        // 到期日是昨天，实际安排在今天：到期日期与安排日期必须分开。
        let task = ReviewTask(title: "离线复习任务", dueDate: date(2026, 9, 22, 2, 0))
        let proposal = engine().proposePlan(
            request(candidates: [review(task)], availability: day, preferences: preferences())
        )
        checkEqual(proposal.plan.items.count, 1, "空索引下仍能排入真实复习候选")
        checkEqual(proposal.plan.items.first?.title, "离线复习任务", "任务内容来自真实数据")
        check(
            proposal.plan.inputFingerprint == "fp-default",
            "计划记录了输入指纹，便于判断是否需要重算"
        )
        check(
            proposal.plan.items.first?.dueDate == task.dueDate,
            "到期日期与安排日期分开记录"
        )
        check(
            proposal.plan.items.first?.scheduledDayKey == dayKey,
            "实际安排日期是今天"
        )
        check(
            proposal.plan.items.first?.isScheduledAfterDueDate == true,
            "可以判断这条任务实际上是逾期安排的"
        )
    }

    // MARK: - 20. 解释

    static func testExplanationAnswersWhy() {
        print("--- 解释能说明为什么是这些任务、为什么是这个任务量 ---")
        let day = availability([free(19, 0, 120)])
        let task = ReviewTask(title: "到期复习", dueDate: date(2026, 9, 23, 2, 0))
        let index = TaskSignalIndex(reviewTasks: [task])
        let proposal = engine(index: index).proposePlan(
            request(
                candidates: [review(task), manual("放不下的任务", minutes: 80), manual("小任务", minutes: 10)],
                availability: day,
                preferences: preferences()
            )
        )
        check(explanationContains(proposal.explanation, "任务量：可用空档 × 75%"), "解释包含预算推导")
        check(explanationContains(proposal.explanation, "安排："), "解释包含安排摘要")
        check(explanationContains(proposal.explanation, "层级分布"), "解释包含层级分布")
        check(explanationContains(proposal.explanation, "复习任务：到期复习"), "解释逐条列出任务、时间与来源")
        check(explanationContains(proposal.explanation, "到期"), "解释标注任务到期日期")
        check(
            proposal.explanation.assumptions.contains { $0.contains("精力系数来源") },
            "解释列出精力假设"
        )
        check(
            !proposal.explanation.blockedReasons.isEmpty,
            "有排不下的任务时解释给出受阻原因"
        )
    }
}
