import Foundation

// MARK: - G 模块：统一计划协调层
//
// 公共接口职责表：
//   DailyPlanCoordinator | 用户操作或刷新事件 | 统一提交状态、保存并更新提醒
//
// 本文件**只做编排与翻译**：
// - 调用 C/D/E 模块的算法引擎（`DailyPlanEngine` / `MinimumPlanPolicy` /
//   `StudySessionEngine` / `RewardEvaluator`）；
// - 把引擎输出翻译成「落盘意图 `PlanStoreMutation`」与「通知意图 `ReminderChangeRequest`」；
// - 自身不写文件、不发通知、不改全局 AppStore（由 AppStore 的统一提交入口完成）。
//
// 引擎未落地时**不会伪造算法**：相关动作返回带说明的拒绝结果，界面必须如实展示。

// MARK: - 引擎集合

/// 一次集成所需的四个算法引擎。
///
/// 计划引擎用**工厂**而不是固定实例保存：规划必须使用"发起这次规划时"的快照，
/// 否则掌握度、错题、考试、课程负担的变化不会生效（会一直用启动时的旧索引）。
struct StudyPlanEngines {
    /// 计划引擎工厂：入参是本次规划要用的快照与上下文。
    var planEngineFactory: ((StoreSnapshot, PlanningContext) -> (any DailyPlanEngine)?)?
    /// 最低任务策略工厂：睡眠窗口等用户约束必须来自**当前**快照，
    /// `isManual` 表示这次是否是用户主动采用方案（手动不受"自动减量关闭"限制）。
    var minimumPolicyFactory: ((StoreSnapshot, Bool) -> (any MinimumPlanPolicy)?)?
    var minimumPolicy: (any MinimumPlanPolicy)?
    var sessionEngine: (any StudySessionEngine)?
    var rewardEvaluator: (any RewardEvaluator)?

    init(
        planEngineFactory: ((StoreSnapshot, PlanningContext) -> (any DailyPlanEngine)?)? = nil,
        minimumPolicyFactory: ((StoreSnapshot, Bool) -> (any MinimumPlanPolicy)?)? = nil,
        minimumPolicy: (any MinimumPlanPolicy)? = nil,
        sessionEngine: (any StudySessionEngine)? = nil,
        rewardEvaluator: (any RewardEvaluator)? = nil
    ) {
        self.planEngineFactory = planEngineFactory
        self.minimumPolicyFactory = minimumPolicyFactory
        self.minimumPolicy = minimumPolicy
        self.sessionEngine = sessionEngine
        self.rewardEvaluator = rewardEvaluator
    }

    /// 有工厂时必须使用当前快照构造；不把工厂返回的 nil 偷换成旧静态策略。
    /// 固定策略只用于固定引擎的测试或简单场景。
    func resolvedMinimumPolicy(
        for state: StoreSnapshot,
        isManual: Bool = false
    ) -> (any MinimumPlanPolicy)? {
        if let minimumPolicyFactory {
            return minimumPolicyFactory(state, isManual)
        }
        return minimumPolicy
    }

    /// 便利初始化：固定一个计划引擎实例（测试与简单场景）。
    /// 生产路径请用 `planEngineFactory`，避免复用旧信号索引。
    init(
        planEngine: (any DailyPlanEngine)?,
        minimumPolicy: (any MinimumPlanPolicy)? = nil,
        sessionEngine: (any StudySessionEngine)? = nil,
        rewardEvaluator: (any RewardEvaluator)? = nil
    ) {
        if let planEngine {
            self.planEngineFactory = { _, _ in planEngine }
        } else {
            self.planEngineFactory = nil
        }
        self.minimumPolicyFactory = nil
        self.minimumPolicy = minimumPolicy
        self.sessionEngine = sessionEngine
        self.rewardEvaluator = rewardEvaluator
    }

    static let empty = StudyPlanEngines()

    /// 用当前快照构造计划引擎（每次调用都重建）。
    func planEngine(for state: StoreSnapshot, context: PlanningContext) -> (any DailyPlanEngine)? {
        planEngineFactory?(state, context)
    }

    /// 尚未接入的模块名（用于界面与诊断的如实提示）。
    var missingModules: [String] {
        var names: [String] = []
        if planEngineFactory == nil { names.append("今日计划引擎") }
        if minimumPolicyFactory == nil && minimumPolicy == nil { names.append("最低任务策略") }
        if sessionEngine == nil { names.append("学习会话引擎") }
        if rewardEvaluator == nil { names.append("娱乐奖励评估") }
        return names
    }

    var isComplete: Bool { missingModules.isEmpty }
}

/// 引擎注册表。
///
/// 这里只登记真实实现；刻意不提供任何兜底实现——缺模块就是缺模块，
/// 界面必须如实提示，而不是伪造一份计划。
enum StudyEngineRegistry {
    static func production() -> StudyPlanEngines {
        StudyPlanEngines(
            planEngineFactory: { state, context in
                makeDailyPlanEngine(for: state, context: context)
            },
            minimumPolicyFactory: { state, isManual in makeMinimumPlanPolicy(for: state, isManual: isManual) },
            sessionEngine: makeStudySessionEngine(),
            rewardEvaluator: makeRewardEvaluator()
        )
    }

    /// C 模块：`DailyPlanEngine`（本地规划引擎）。
    ///
    /// 每次规划都重新构建 `TaskSignalIndex` 与配置，并注入 D 的最低任务策略。
    static func makeDailyPlanEngine(
        for state: StoreSnapshot,
        context: PlanningContext
    ) -> (any DailyPlanEngine)? {
        LocalDailyPlanEngine(
            configuration: engineConfiguration(for: state),
            signalIndex: TaskSignalIndex(
                snapshot: state,
                courseHasMaterials: courseMaterialIndex(in: state)
            ),
            minimumPolicy: makeMinimumPlanPolicy(for: state, isManual: false)
        )
    }

    /// 规划引擎配置：用户手动设置的精力优先，否则按课表负担估计。
    static func engineConfiguration(for state: StoreSnapshot) -> DailyPlanEngineConfiguration {
        var configuration = DailyPlanEngineConfiguration.standard
        if let raw = state.planningPreferences.energyLevelIdentifier,
           let level = StudyEnergyLevel(rawValue: raw) {
            configuration.energyOverride = level
        }
        return configuration
    }

    /// 课程 → 是否有真实资料（存在同科目的知识点）。
    ///
    /// 没有资料时只能生成通用回顾任务；这里提供索引，避免界面/引擎编造章节。
    static func courseMaterialIndex(in state: StoreSnapshot) -> [UUID: Bool] {
        var subjectsWithMaterials = Set<String>()
        for point in state.knowledgePoints {
            if let normalized = StudySubjectMatcher.normalized(point.subject) {
                subjectsWithMaterials.insert(normalized)
            }
        }
        guard !subjectsWithMaterials.isEmpty else { return [:] }
        var result: [UUID: Bool] = [:]
        for course in state.scheduleCourses where result[course.id] == nil {
            let subject = course.subject.linkedKnowledgeSubject ?? course.subject.displayName
            guard let normalized = StudySubjectMatcher.normalized(subject) else { continue }
            result[course.id] = subjectsWithMaterials.contains(normalized)
        }
        return result
    }

    /// D 模块：`MinimumPlanPolicy`（最低任务策略）。
    ///
    /// 由 D 模块注册；默认阈值来自策略默认值，睡眠与自动减量设置来自本次快照。
    /// 带用户约束的最低任务策略（生产路径使用它）。
    static func makeMinimumPlanPolicy(
        for state: StoreSnapshot,
        isManual: Bool = false
    ) -> (any MinimumPlanPolicy)? {
        StudyMinimumPlanPolicy(configuration: minimumPlanConfiguration(for: state, isManual: isManual))
    }

    /// 减量预览与应用必须使用同一份策略配置（否则预览和落地会不一致）。
    static func minimumPlanConfiguration(
        for state: StoreSnapshot,
        isManual: Bool = false
    ) -> MinimumPlanPolicyConfiguration {
        MinimumPlanPolicyConfiguration.standard(
            availability: state.availabilityPreferences,
            isManual: isManual
        )
    }

    /// D 模块：`StudySessionEngine`（学习会话）。
    static func makeStudySessionEngine() -> (any StudySessionEngine)? {
        StudySessionEngineImpl()
    }

    /// E 模块：`RewardEvaluator`（娱乐解锁与奖励评估）。
    static func makeRewardEvaluator() -> (any RewardEvaluator)? {
        EntertainmentRewardEvaluator()
    }
}

// MARK: - G 补充的稳定幂等键

/// 没有计划项时的完成事件幂等键。
///
/// 旧业务（复习列表、错题页）允许在"今天还没生成计划"的情况下直接完成，
/// 此时没有 `planItemID` 可用。契约里的 `adHoc` 键带时间戳，无法防住
/// "隔一秒再点一次"，所以这里按「业务对象 + 学习日」定义稳定键。
enum StudyCompletionKey {
    static func reviewTask(_ reviewTaskID: UUID, dayKey: StudyDayKey) -> String {
        "completion|review-task:\(reviewTaskID.uuidString)|day:\(dayKey.localDateString)@\(dayKey.timeZoneIdentifier)"
    }

    static func mistake(_ mistakeID: UUID, dayKey: StudyDayKey) -> String {
        "completion|mistake:\(mistakeID.uuidString)|day:\(dayKey.localDateString)@\(dayKey.timeZoneIdentifier)"
    }

    static func knowledgePoint(_ pointID: UUID, dayKey: StudyDayKey) -> String {
        "completion|knowledge:\(pointID.uuidString)|day:\(dayKey.localDateString)@\(dayKey.timeZoneIdentifier)"
    }
}

extension CompletionEvent {
    /// 用 G 的稳定键构造完成事件（无计划项的场景）。
    static func direct(
        key: String,
        dayKey: StudyDayKey,
        source: DailyPlanItemSource?,
        plannedScope: StudyScope?,
        minimumScope: StudyScope? = nil,
        completedScope: StudyScope,
        actualMinutes: Int,
        durationSource: StudyDurationSource? = nil,
        durationNote: String? = nil,
        completedAt: Date,
        assessment: StudyAssessment? = nil,
        note: String = ""
    ) -> CompletionEvent {
        let tier = plannedScope.flatMap {
            PlanCompletionTier.resolve(completed: completedScope, planned: $0, minimum: minimumScope)
        } ?? .studied
        return CompletionEvent(
            id: StudyStableKey.uuid(from: key),
            idempotencyKey: key,
            sessionID: nil,
            planID: nil,
            planItemID: nil,
            dayKey: dayKey,
            source: source,
            plannedScope: plannedScope,
            completedScope: completedScope,
            tier: tier,
            actualMinutes: actualMinutes,
            durationSource: durationSource,
            durationNote: durationNote,
            completedAt: completedAt,
            assessment: assessment,
            note: note,
            createdAt: completedAt
        )
    }
}

// MARK: - 任务候选构建（StoreSnapshot → PlanCandidate）
//
// 契约把 `PlanCandidate` 定义为计划生成器的**输入**，因此把它从真实数据翻译出来
// 属于 G 的集成职责，而不是规划算法本身。这里只做映射：
// - 复习任务：标题与到期日来自 `ReviewTask`，不编造章节/题目；
// - 课程回顾 / 预习：标题只使用真实课程名，且有课表时才生成；
// - 手动任务：标题来自用户输入。
enum PlanCandidateBuilder {
    /// 单条复习任务的默认预计时长（分钟）。
    ///
    /// `ReviewTask` 本身没有时长字段，这是一个**规划参数**（只影响排期预算），
    /// 不代表任何学习内容。
    static let defaultReviewTaskMinutes = 15
    /// 单条课程回顾 / 预习的默认预计时长。
    static let defaultCourseReviewMinutes = 20

    static func candidates(
        from state: StoreSnapshot,
        dayKey: StudyDayKey,
        context: PlanningContext,
        includeCourseWork: Bool = true
    ) -> [PlanCandidate] {
        var result: [PlanCandidate] = []
        result.append(contentsOf: reviewCandidates(from: state, dayKey: dayKey, context: context))
        result.append(contentsOf: manualStudyTaskCandidates(from: state, dayKey: dayKey, context: context))
        if includeCourseWork {
            result.append(contentsOf: courseCandidates(from: state, dayKey: dayKey, context: context))
        }
        return result
    }

    /// 指定学习日的持久化手动任务 → 候选。
    static func manualStudyTaskCandidates(
        from state: StoreSnapshot,
        dayKey: StudyDayKey,
        context: PlanningContext
    ) -> [PlanCandidate] {
        let dueBoundary = endOfDay(dayKey: dayKey, context: context)
        let completedTaskIDs = Set(
            state.completionEvents
                .filter { !$0.isRevoked }
                .compactMap { $0.source?.manualTaskID }
        )
        return state.manualStudyTasks
            .filter { task in
                !completedTaskIDs.contains(task.id)
                    && (task.dueDate.map { $0 < dueBoundary } ?? true)
            }
            .sorted {
                switch ($0.dueDate, $1.dueDate) {
                case (.none, .some): return true
                case (.some, .none): return false
                case let (.some(lhs), .some(rhs)) where lhs != rhs: return lhs < rhs
                default:
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { task in
                PlanCandidate(
                    source: .manual(note: task.note, manualTaskID: task.id),
                    title: task.title,
                    plannedScope: .tasks(1),
                    estimatedMinutes: task.estimatedMinutes,
                    dueDate: task.dueDate,
                    isPinned: false,
                    isSplittable: false,
                    note: task.note
                )
            }
    }

    /// 到期的复习任务 → 候选。
    static func reviewCandidates(
        from state: StoreSnapshot,
        dayKey: StudyDayKey,
        context: PlanningContext
    ) -> [PlanCandidate] {
        let dueBoundary = endOfDay(dayKey: dayKey, context: context)
        let ratio = state.availabilityPreferences.planning.minimumScopeRatio
        return state.reviewTasks
            .filter { $0.status == .pending && $0.dueDate < dueBoundary }
            .sorted { lhs, rhs in
                if (lhs.priority ?? 0) != (rhs.priority ?? 0) {
                    return (lhs.priority ?? 0) > (rhs.priority ?? 0)
                }
                return lhs.dueDate < rhs.dueDate
            }
            .map { task in
                PlanCandidate(
                    source: .reviewTask(task.id, knowledgePointID: task.knowledgePointID),
                    title: DailyPlanItemSource.genericTitle(kind: .reviewTask, name: task.title),
                    plannedScope: .tasks(1),
                    minimumScope: .tasks(ratio),
                    estimatedMinutes: defaultReviewTaskMinutes,
                    dueDate: task.dueDate,
                    isPinned: false,
                    isSplittable: false,
                    note: ""
                )
            }
    }

    /// 当天课程 → 课程回顾候选；次日有课 → 预习候选。没有课表就不生成。
    static func courseCandidates(
        from state: StoreSnapshot,
        dayKey: StudyDayKey,
        context: PlanningContext
    ) -> [PlanCandidate] {
        guard let schedule = state.schedule else { return [] }
        guard let dayStart = dayKey.startOfDay(calendar: context.calendar) else { return [] }

        var result: [PlanCandidate] = []
        let today = ScheduleResolver.planningDay(for: dayStart, schedule: schedule, context: context)
        for course in today.courses where !course.isCancelled {
            result.append(
                PlanCandidate(
                    source: .courseReview(courseID: course.courseID, occurrenceID: course.id),
                    title: DailyPlanItemSource.genericTitle(kind: .courseReview, name: course.courseName),
                    plannedScope: .sections(1),
                    minimumScope: nil,
                    estimatedMinutes: defaultCourseReviewMinutes,
                    dueDate: course.end,
                    isPinned: false,
                    isSplittable: false,
                    note: "",
                    preferredStart: course.end
                )
            )
        }

        if let next = context.calendar.date(byAdding: .day, value: 1, to: dayStart) {
            let tomorrow = ScheduleResolver.planningDay(for: next, schedule: schedule, context: context)
            for course in tomorrow.courses where !course.isCancelled {
                result.append(
                    PlanCandidate(
                        source: .preview(courseID: course.courseID, occurrenceID: course.id),
                        title: DailyPlanItemSource.genericTitle(kind: .preview, name: course.courseName),
                        plannedScope: .sections(1),
                        minimumScope: nil,
                        estimatedMinutes: defaultCourseReviewMinutes,
                        dueDate: course.start,
                        isPinned: false,
                        isSplittable: false,
                        note: ""
                    )
                )
            }
        }
        return result
    }

    /// 输入指纹的全部输入。
    ///
    /// 只要这些输入里任何一项会影响"怎么排"，就必须进入指纹：
    /// 否则界面会显示"沿用旧计划"，而用户看到的是安排没跟着世界变化。
    struct PlanFingerprintInput {
        var dayKey: StudyDayKey
        var context: PlanningContext
        var availability: AvailabilityDay?
        var preferences: AvailabilityPreferences
        var engineConfiguration: DailyPlanEngineConfiguration
        var candidates: [PlanCandidate]
        var signalIndex: TaskSignalIndex
        var completions: [CompletionEvent]
        var activePlan: DailyStudyPlan?
    }

    /// 输入指纹：同样的输入必须得到同样的指纹，从而支持"重复生成不重复执行"。
    ///
    /// 覆盖范围：
    /// 1. 学习日与规划时区；
    /// 2. **具体空闲时间段**（起点/终点/时长），因此"总分钟数相同但分布不同"是两个输入；
    /// 3. 容量状态与假设（未配置作息时不得把默认假设当作用户设置）；
    /// 4. 预算设置：每日上限、自动减量、保底开关与比例、单任务时长区间、休息、复习占比、
    ///    利用率与精力档位；
    /// 5. 每个候选的来源、范围、到期日、优先级、固定标记、可拆分、期望开始时间与预计耗时；
    /// 6. 影响排序的学习信号：掌握度、错题/知识点、考试临近、课程负担、是否有资料；
    /// 7. 当天已完成进度（完成事件的幂等键 / 档次 / 分钟数）；
    /// 8. 既有计划里受保护任务（固定 / 进行中 / 已完成）的身份与安排时间。
    static func fingerprint(_ input: PlanFingerprintInput) -> String {
        var components: [String] = []
        let dayKey = input.dayKey
        let planning = input.preferences.planning

        components.append("day:\(dayKey.localDateString)@\(dayKey.timeZoneIdentifier)")

        // 2) 具体空闲时间段（不是只有总分钟数）。
        if let availability = input.availability {
            components.append("availabilityState:\(availability.state.rawValue)")
            components.append("assumesDefault:\(availability.usesDefaultAssumption)")
            components.append("freeTotal:\(availability.totalFreeMinutes)")
            for interval in availability.freeIntervals.sorted(by: { $0.start < $1.start }) {
                components.append(
                    "free:\(Int(interval.start.timeIntervalSince1970))-\(Int(interval.end.timeIntervalSince1970))"
                )
            }
            for assumption in availability.assumptions.sorted() {
                components.append("assumption:\(assumption)")
            }
        } else {
            components.append("availability:missing")
        }

        // 4) 预算设置。
        components.append(
            [
                "budget",
                "cap:\(input.preferences.dailyCapMinutes.map(String.init) ?? "-")",
                "autoReduce:\(planning.autoReduceEnabled)",
                "allowsMinimum:\(planning.allowsMinimumPlan)",
                "minimumRatio:\(planning.minimumScopeRatio)",
                "taskMinutes:\(planning.minimumTaskMinutes)-\(planning.maximumTaskMinutes)",
                "break:\(planning.breakMinutes)",
                "reviewShare:\(planning.reviewShareRatio)",
                "utilization:\(input.engineConfiguration.utilizationRatio)",
                "energy:\(input.engineConfiguration.energyOverride?.rawValue ?? "auto")",
                "buffer:\(input.preferences.bufferMinutes)"
            ].joined(separator: "|")
        )

        // 7) 当天已完成进度。
        let dayEvents = input.completions
            .filter { $0.dayKey == dayKey }
            .sorted { $0.idempotencyKey < $1.idempotencyKey }
        for event in dayEvents {
            components.append(
                [
                    "done",
                    event.idempotencyKey,
                    event.tier.rawValue,
                    String(event.actualMinutes),
                    event.isRevoked ? "revoked" : "active",
                    event.planItemID?.uuidString ?? "-"
                ].joined(separator: "|")
            )
        }

        // 5) + 6) 候选与其信号。顺序无关：按稳定身份排序后再拼。
        let signals = input.candidates.map { candidate in
            input.signalIndex.signals(
                for: candidate,
                dayKey: dayKey,
                context: input.context,
                existingActivePlan: input.activePlan
            )
        }
        let candidateLines: [String] = zip(input.candidates, signals).map { candidate, signal in
            [
                signal.identityKey,
                candidate.source.kind.rawValue,
                candidate.source.reviewTaskID?.uuidString ?? "-",
                candidate.source.courseID?.uuidString ?? "-",
                candidate.source.occurrenceID?.uuidString ?? "-",
                candidate.source.knowledgePointID?.uuidString ?? "-",
                candidate.title,
                "\(candidate.plannedScope.unit.rawValue):\(candidate.plannedScope.amount)",
                candidate.minimumScope.map { "\($0.unit.rawValue):\($0.amount)" } ?? "-",
                "est:\(candidate.estimatedMinutes)",
                candidate.dueDate.map { "due:\(Int($0.timeIntervalSince1970))" } ?? "due:-",
                "overdue:\(signal.overdueDays)",
                "within:\(signal.dueWithinDays.map(String.init) ?? "-")",
                "prio:\(signal.priority.map(String.init) ?? "-")",
                "mastery:\(signal.mastery.map { String(format: "%.3f", $0) } ?? "-")",
                "mistake:\(signal.linkedMistakeID?.uuidString ?? "-")",
                "kp:\(signal.linkedKnowledgePointID?.uuidString ?? "-")",
                "exam:\(signal.examDaysRemaining.map(String.init) ?? "-")",
                "burden:\(signal.courseBurdenLevel.map { String($0.rank) } ?? "-")",
                "material:\(signal.hasRealMaterial)",
                "courseMaterial:\(signal.hasCourseMaterials)",
                "pinned:\(signal.isPinned)",
                "splittable:\(candidate.isSplittable)",
                candidate.preferredStart.map { "start:\(Int($0.timeIntervalSince1970))" } ?? "start:-"
            ].joined(separator: "~")
        }
        components.append(contentsOf: candidateLines.sorted())

        // 8) 既有计划里的受保护任务：安排时间变化会让指纹变化，
        //    但它们本身不会因为"输入没变"被丢弃。
        if let activePlan = input.activePlan {
            let protectedLines = activePlan.items
                .filter { $0.isPinned || $0.status == .inProgress || $0.status == .completed }
                .map { item -> String in
                    // 刻意**不含**计划 ID 或版本号：重新生成时受保护任务会被搬进新计划，
                    // 如果指纹依赖计划 ID，同一份输入每生成一次指纹就会变一次，
                    // 于是"重复调用"会不断新建版本。
                    [
                        "protected",
                        item.id.uuidString,
                        item.status.rawValue,
                        item.isPinned ? "pinned" : "-",
                        item.scheduledStart.map { "at:\(Int($0.timeIntervalSince1970))" } ?? "at:-"
                    ].joined(separator: "|")
                }
                .sorted()
            components.append(contentsOf: protectedLines)
        }

        return StudyStableKey.fingerprint(components)
    }

    static func endOfDay(dayKey: StudyDayKey, context: PlanningContext) -> Date {
        guard let start = dayKey.startOfDay(calendar: context.calendar) else { return context.now }
        return context.calendar.date(byAdding: .day, value: 1, to: start) ?? start
    }
}

// MARK: - 剩余可安排时间（需求 2）

/// "今天还剩多少可安排时间"的完整口径。
///
/// 减量**不能**只看空闲分钟总和：
/// - 只统计能放下一个最小动作的连续空档（碎片不算容量）；
/// - 同时受每日剩余额度（每日上限 − 已完成时长）约束；
/// - 数据来自用户真实作息与课程占用（`AvailabilityCalculator`）。
struct StudyRemainingCapacity: Hashable, Sendable {
    /// 能放下最小动作的连续空档之和。
    var continuousFreeMinutes: Int
    /// 单个最长空档（用于解释"为什么放不下"）。
    var longestGapMinutes: Int
    /// 最小可安排块（分钟），来自策略配置。
    var minimumUsefulMinutes: Int
    /// 每日剩余额度；`nil` 表示没有设置每日上限。
    var dailyCapRemainingMinutes: Int?
    /// 最终用于减量的剩余时间。
    var effectiveMinutes: Int
    var freeIntervalCount: Int
    var discardedFragmentCount: Int
    var availabilityState: AvailabilityState?
    var usesDefaultAssumption: Bool
    var explanation: [String]
}

enum StudyCapacityPlanner {
    /// 计算剩余可安排时间。纯计算，不写文件、不读系统时钟。
    static func remainingCapacity(
        state: StoreSnapshot,
        availability: AvailabilityDay?,
        context: PlanningContext,
        minimumUsefulMinutes: Int = MinimumPlanPolicyConfiguration.default.minimumUsefulMinutes
    ) -> StudyRemainingCapacity {
        let threshold = max(1, minimumUsefulMinutes)
        let intervals = (availability?.freeIntervals ?? []).filter { $0.end > context.now }
        let usable = intervals.filter { $0.durationMinutes >= threshold }
        let continuous = usable.reduce(0) { $0 + $1.durationMinutes }
        let longest = intervals.map(\.durationMinutes).max() ?? 0

        let studied = state.completionEvents
            .filter { $0.dayKey == context.todayKey && !$0.isRevoked }
            .filter { $0.durationSource.contributesRecordedMinutes }
            .reduce(0) { $0 + $1.actualMinutes }
        let capRemaining = state.availabilityPreferences.dailyCapMinutes.map { max(0, $0 - studied) }

        let effective = min(continuous, capRemaining ?? Int.max)

        var lines: [String] = []
        lines.append(
            "剩余空档：\(intervals.count) 段，其中 \(usable.count) 段不小于 \(threshold) 分钟，可用 \(continuous) 分钟。"
        )
        if intervals.count > usable.count {
            lines.append("另有 \(intervals.count - usable.count) 段过短（< \(threshold) 分钟）的碎片，不计入容量。")
        }
        if let capRemaining {
            lines.append("每日上限剩余额度 \(capRemaining) 分钟（今天已计入 \(studied) 分钟）。")
        } else {
            lines.append("没有设置每日上限，容量只受剩余空档限制。")
        }
        if longest > 0, continuous > longest {
            lines.append("最长连续空档 \(longest) 分钟；多个空档无法合并使用。")
        }
        if let availability, availability.usesDefaultAssumption {
            lines.append("你还没有配置作息，容量按默认假设估算（仅作为解释出现）。")
        }

        return StudyRemainingCapacity(
            continuousFreeMinutes: continuous,
            longestGapMinutes: longest,
            minimumUsefulMinutes: threshold,
            dailyCapRemainingMinutes: capRemaining,
            effectiveMinutes: max(0, effective),
            freeIntervalCount: intervals.count,
            discardedFragmentCount: max(0, intervals.count - usable.count),
            availabilityState: availability?.state,
            usesDefaultAssumption: availability?.usesDefaultAssumption ?? true,
            explanation: lines
        )
    }
}

// MARK: - 协调器

/// `DailyPlanCoordinator` 的集成实现。
///
/// 纯函数式：输入快照 + 事件，输出新快照、落盘意图与通知意图。
/// 重复调用是安全的：所有写入实体的键都是稳定的（幂等键 / 发放键 / 计划版本）。
struct StudyPlanCoordinator: DailyPlanCoordinator {
    var engines: StudyPlanEngines
    /// 一次最多安排多少条近期提醒（避免系统通知数量上限与集中轰炸）。
    var maximumScheduledReminders: Int

    init(engines: StudyPlanEngines = .empty, maximumScheduledReminders: Int = 3) {
        self.engines = engines
        self.maximumScheduledReminders = max(1, maximumScheduledReminders)
    }

    // MARK: 入口

    func coordinate(
        _ event: PlanCoordinationEvent,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        switch event {
        case .refresh(let dayKey):
            return refresh(dayKey: dayKey, state: state, context: context)

        case .regeneratePlan(let dayKey, let force):
            return regeneratePlan(dayKey: dayKey, force: force, state: state, context: context)

        case .startSession(let planItemID):
            // 全局单会话：同一时刻只允许一个计时，无论它属于哪一天、哪条任务。
            // 页面按钮禁用只是辅助，真正的约束在这里（需求 4）。
            if let running = Self.conflictingActiveSession(in: state, startingPlanItemID: planItemID) {
                return PlanCoordinationResult(
                    snapshot: state,
                    statusMessage: Self.conflictingSessionMessage(running),
                    didChange: false,
                    rejection: .invalidState(Self.conflictingSessionMessage(running))
                )
            }
            return handleSessionEvent(
                .start(at: context.now),
                resolvedSession: state.activeStudySession(forPlanItemID: planItemID),
                planItemID: planItemID,
                state: state,
                context: context
            )

        case .pauseSession(let sessionID):
            return handleSessionEvent(
                .pause(at: context.now),
                resolvedSession: state.studySessions.first { $0.id == sessionID },
                planItemID: nil,
                state: state,
                context: context
            )

        case .resumeSession(let sessionID):
            return handleSessionEvent(
                .resume(at: context.now),
                resolvedSession: state.studySessions.first { $0.id == sessionID },
                planItemID: nil,
                state: state,
                context: context
            )

        case .finishSession(let sessionID, let scope, let assessment, let note):
            return handleSessionEvent(
                .finish(at: context.now, scope: scope, assessment: assessment, note: note),
                resolvedSession: state.studySessions.first { $0.id == sessionID },
                planItemID: nil,
                state: state,
                context: context
            )

        case .completeItemDirectly(let planItemID, let scope, let minutes, let assessment, let note):
            return completeItemDirectly(
                planItemID: planItemID,
                scope: scope,
                minutes: minutes,
                assessment: assessment,
                note: note,
                state: state,
                context: context
            )

        case .applyMinimumPlan(let dayKey, let remainingMinutes, let expectedPlanID, let expectedVersion):
            return reduceToMinimum(
                dayKey: dayKey,
                remainingMinutes: remainingMinutes,
                expectedPlanID: expectedPlanID,
                expectedVersion: expectedVersion,
                state: state,
                context: context
            )

        case .undoMinimumPlan(let dayKey):
            return undoMinimumPlan(dayKey: dayKey, state: state, context: context)

        case .revokeCompletion(let completionID, let reason):
            return revokeCompletion(completionID: completionID, reason: reason, state: state, context: context)

        case .claimReward(let grantID):
            return updateRewardGrant(grantID: grantID, operation: .claim, usedMinutes: 0, state: state, context: context)

        case .startReward(let grantID):
            return updateRewardGrant(grantID: grantID, operation: .start, usedMinutes: 0, state: state, context: context)

        case .finishReward(let grantID, let usedMinutes):
            return updateRewardGrant(grantID: grantID, operation: .finish, usedMinutes: usedMinutes, state: state, context: context)
        }
    }

    // MARK: 全局单会话

    /// 已经开始计时的其它会话（不同任务或不同学习日）。
    ///
    /// 返回 `nil` 表示可以开始新计时。
    static func conflictingActiveSession(
        in state: StoreSnapshot,
        startingPlanItemID: UUID
    ) -> StudySession? {
        state.studySessions.first { session in
            guard session.state.isActive else { return false }
            // 同一条任务的重复 start 由会话引擎按幂等键拒绝，不算冲突。
            return session.planItemID != startingPlanItemID
        }
    }

    static func conflictingSessionMessage(_ session: StudySession) -> String {
        let who = session.planItemID == nil ? "一条没有绑定任务的计时" : "另一条任务"
        return "已经有正在进行的计时（\(who)，开始于 \(session.dayKey.localDateString)）。请先暂停、结束或放弃它，再开始新的计时。"
    }

    // MARK: 刷新

    /// 刷新：重算计划项状态 + 评估奖励资格。幂等，可安全重复调用。
    private func refresh(
        dayKey: StudyDayKey,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        var working = state
        var mutations: [PlanStoreMutation] = []

        // 先统一结算已过使用日的未使用奖励。进行中的计时和已消费记录保留。
        mutations.append(contentsOf: Self.expiringStaleRewardGrants(in: &working, before: context.todayKey, at: context.now))

        let recomputed = working.recomputingPlans(from: working.completionEvents)
        if recomputed.dailyPlans != working.dailyPlans {
            for plan in recomputed.dailyPlans where plan.dayKey == dayKey {
                mutations.append(
                    PlanStoreMutation(kind: .upsertPlan, entityID: plan.id, summary: "按完成事件重算计划项状态")
                )
            }
            working = recomputed
        }

        var statusMessage = ""
        // 资格只在奖励所属的学习日仍可使用时核验；历史日期由上面的过期结算处理。
        if dayKey >= context.todayKey {
            let reward = applyingRewardEvaluation(state: working, dayKey: dayKey, context: context)
            working = reward.state
            mutations.append(contentsOf: reward.mutations)
            statusMessage = reward.statusMessage
        }

        return PlanCoordinationResult(
            snapshot: working,
            mutations: mutations,
            reminderChanges: [],
            statusMessage: statusMessage,
            didChange: !mutations.isEmpty
        )
    }

    /// 将早于今天且尚未开始、未消费的奖励改为过期。
    /// 幂等：已过期、已撤销、已开始或已消费的记录不再修改。
    private static func expiringStaleRewardGrants(
        in state: inout StoreSnapshot,
        before dayKey: StudyDayKey,
        at date: Date
    ) -> [PlanStoreMutation] {
        var mutations: [PlanStoreMutation] = []
        for index in state.rewardGrants.indices {
            let grant = state.rewardGrants[index]
            guard grant.dayKey < dayKey, grant.isUnstartedAndUnused else { continue }
            var expired = grant
            expired.state = .expired
            expired.endedAt = date
            state.rewardGrants[index] = expired
            mutations.append(PlanStoreMutation(kind: .upsertRewardGrant, entityID: expired.id, summary: "未使用奖励已过期"))
        }
        return mutations
    }

    // MARK: 生成 / 刷新今日计划

    private func regeneratePlan(
        dayKey: StudyDayKey,
        force: Bool,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        // 计划引擎每次都用**当前快照**重建：掌握度 / 错题 / 考试 / 课程负担
        // 的变化必须立刻影响这一次规划，不能复用启动时的旧信号索引。
        guard let engine = engines.planEngine(for: state, context: context) else {
            return Self.missingModuleResult(state, module: "今日计划引擎（DailyPlanEngine）")
        }

        let preferences = state.availabilityPreferences
        let schedule = state.scheduleForComputation
        let dayStart = dayKey.startOfDay(calendar: context.calendar) ?? context.now
        let availability = AvailabilityCalculator.availability(
            on: dayStart,
            schedule: schedule,
            preferences: preferences,
            now: context.now
        )

        let candidates = PlanCandidateBuilder.candidates(from: state, dayKey: dayKey, context: context)
        let existingPlans = state.dailyPlans.filter { $0.dayKey == dayKey }
        let activeExisting = existingPlans.first { $0.isActive }

        // 输入指纹：必须覆盖空闲时段分布、候选范围、到期/优先级、学习信号、
        // 预算设置与已完成进度。相同总分钟数但不同空闲时段不能算同一输入。
        let fingerprint = PlanCandidateBuilder.fingerprint(
            PlanCandidateBuilder.PlanFingerprintInput(
                dayKey: dayKey,
                context: context,
                availability: availability,
                preferences: preferences,
                engineConfiguration: StudyEngineRegistry.engineConfiguration(for: state),
                candidates: candidates,
                signalIndex: TaskSignalIndex(
                    snapshot: state,
                    courseHasMaterials: StudyEngineRegistry.courseMaterialIndex(in: state)
                ),
                completions: state.completionEvents,
                activePlan: activeExisting
            )
        )

        if !force, let activeExisting, activeExisting.hasSameInput(as: fingerprint) {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: "计划输入没有变化，沿用第 \(activeExisting.version) 版计划。",
                didChange: false
            )
        }

        let request = DailyPlanRequest(
            dayKey: dayKey,
            context: context,
            availability: availability,
            preferences: preferences,
            candidates: candidates,
            existingPlans: existingPlans,
            completions: state.completionEvents,
            inputFingerprint: fingerprint
        )
        let proposal = engine.proposePlan(request)

        if proposal.didReuseExistingPlan {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: "计划引擎复用了已有计划，未重建。",
                didChange: false
            )
        }

        var working = state
        var mutations: [PlanStoreMutation] = []

        // 旧版本置为 superseded 并保留历史（不删除）。
        if let activeExisting {
            Self.upserting(activeExisting.supersededCopy(now: context.now), in: &working)
            mutations.append(PlanStoreMutation(kind: .upsertPlan, entityID: activeExisting.id, summary: "旧版本标记为已替换"))
        }

        var newPlan = proposal.plan
        newPlan.version = (existingPlans.map(\.version).max() ?? 0) + 1
        newPlan.supersedesPlanID = activeExisting?.id
        // 普通重规划只是审计链中的新版本，不得继承减量撤销资格。
        newPlan.isUndoableReduction = false
        newPlan.reductionUndoTargetPlanID = nil
        newPlan.status = .active
        newPlan.inputFingerprint = fingerprint
        newPlan.updatedAt = context.now
        newPlan.items = Self.preservingProtectedItems(
            proposed: newPlan.items,
            existing: activeExisting,
            planID: newPlan.id
        )
        newPlan.budget.plannedMinutes = newPlan.plannedMinutesFromItems

        Self.upserting(newPlan, in: &working)
        mutations.append(PlanStoreMutation(kind: .upsertPlan, entityID: newPlan.id, summary: "生成第 \(newPlan.version) 版今日计划"))

        let reminderChanges = reminderChanges(for: newPlan, state: working, context: context)

        return PlanCoordinationResult(
            snapshot: working,
            mutations: mutations,
            reminderChanges: reminderChanges,
            statusMessage: Self.planStatusMessage(for: newPlan, proposal: proposal),
            didChange: true
        )
    }

    /// AI / 引擎重排时不得覆盖：用户固定、进行中、已完成的任务。
    static func preservingProtectedItems(
        proposed: [DailyPlanItem],
        existing: DailyStudyPlan?,
        planID: UUID
    ) -> [DailyPlanItem] {
        guard let existing else { return proposed }
        let protected = existing.items.filter { $0.isPinned || $0.status == .inProgress || $0.status == .completed }
        guard !protected.isEmpty else { return proposed }

        let protectedSources = Set(protected.map(\.source))
        var result: [DailyPlanItem] = protected.map { item in
            var copy = item
            copy.planID = planID
            return copy
        }
        for item in proposed where !protectedSources.contains(item.source) {
            result.append(item)
        }
        return result
    }

    static func planStatusMessage(for plan: DailyStudyPlan, proposal: DailyPlanProposal) -> String {
        let minutes = plan.plannedMinutesFromItems
        var message = "已生成第 \(plan.version) 版\(plan.mode.label)：\(plan.items.count) 项任务，共 \(minutes) 分钟。"
        if !proposal.unplaceable.isEmpty {
            message += " 有 \(proposal.unplaceable.count) 项今天放不下。"
        }
        return message
    }

    // MARK: 学习会话

    private func handleSessionEvent(
        _ event: StudySessionEvent,
        resolvedSession: StudySession?,
        planItemID: UUID?,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        guard let engine = engines.sessionEngine else {
            return Self.missingModuleResult(state, module: "学习会话引擎（StudySessionEngine）")
        }

        // 暂停 / 继续 / 结束事件不带计划项 ID，但它们同样需要计划项上下文：
        // 结束时要靠 `plannedScope` / `minimumScope` 判定标准完成还是保底完成，
        // 缺上下文就会把每一次完成都错记成"已学习"。这里从会话记录补齐。
        let resolvedPlanItemID = planItemID ?? resolvedSession?.planItemID
        let planItem = resolvedPlanItemID.flatMap { id in
            state.dailyPlans.flatMap(\.items).first { $0.id == id }
        }
        let itemContext = planItem.flatMap { PlanItemSessionContext(item: $0) }

        // 结束前先把不可信时间排除（未确认中断 / 超可信上限）：
        // 否则"崩溃后重新打开再点结束"会把未知离线时间整段算成学习时长。
        var sessionForEvent = resolvedSession
        if case .finish = event, let session = resolvedSession {
            sessionForEvent = Self.excludingUntrustedTime(from: session, engine: engine, context: context)
        }

        let transition = engine.apply(event, to: sessionForEvent, item: itemContext, context: context)
        if let rejection = transition.rejection {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: rejection.message,
                didChange: false,
                rejection: .invalidState(rejection.message)
            )
        }

        var working = state
        var mutations: [PlanStoreMutation] = []

        if let session = transition.session {
            Self.upserting(session, in: &working)
            mutations.append(
                PlanStoreMutation(kind: .upsertSession, entityID: session.id, summary: "会话状态更新为\(session.state.label)")
            )
            // 计划项状态跟随会话（完成事件仍是权威来源，这里只是即时反馈）。
            if let resolvedPlanItemID, session.state.isActive {
                Self.updatingItem(resolvedPlanItemID, in: &working, now: context.now) { item in
                    item.status = session.state == .running ? .inProgress : .inProgress
                    item.updatedAt = context.now
                }
            }
        }

        if let completion = transition.completionEvent {
            // 完成事件必须使用**引擎更新后**的会话状态（进度、结束时间都已落定），
            // 否则会丢掉本次会话累计的进度与有效时长。
            let settledSession = transition.session ?? resolvedSession
            let finalized = Self.finalizingCompletion(
                completion,
                session: settledSession,
                minimumScope: itemContext?.minimumScope,
                context: context
            )
            return applyingCompletion(
                finalized,
                state: working,
                mutations: mutations,
                context: context,
                successMessage: "已记录本次学习。"
            )
        }

        return PlanCoordinationResult(
            snapshot: working,
            mutations: mutations,
            statusMessage: transition.didChange ? "会话已更新。" : "没有需要提交的变化。",
            didChange: !mutations.isEmpty
        )
    }

    // MARK: 结束前的时间可信化（需求 5）

    /// 结束会话前把"不可信时间"按明确规则排除掉。
    ///
    /// 规则（会自动写进会话备注，用户仍可在补记里改回来）：
    /// 1. 有一段**未确认的中断**（切后台 / 崩溃 / 重启后的未知时间）→ 整段记为暂停，不计入；
    /// 2. 有效时长超过引擎的可信上限 → 超出部分记为暂停，不计入。
    ///
    /// 这样"未知离线时间"永远不会被自动全部计入，也不会把正常连续学习误判为中断
    /// （只有真的出现心跳缺口才触发规则 1）。
    static func excludingUntrustedTime(
        from session: StudySession,
        engine: any StudySessionEngine,
        context: PlanningContext
    ) -> StudySession {
        guard let impl = engine as? StudySessionEngineImpl else { return session }
        var prepared = session
        var notes: [String] = []

        if let interruption = impl.interruptionCandidate(for: prepared, context: context),
           interruption.requiresUserConfirmation {
            let paused = impl.apply(.pause(at: interruption.lastKnownActiveAt), to: prepared, item: nil, context: context)
            if let value = paused.session { prepared = value }
            let resumed = impl.apply(.resume(at: context.now), to: prepared, item: nil, context: context)
            if let value = resumed.session { prepared = value }
            notes.append(
                StudySessionEngineImpl.interruptionDecisionNote(
                    studiedDuringGap: false,
                    gapMinutes: interruption.gapMinutes
                ) + "|auto-excluded"
            )
        }

        if impl.exceedsTrustedDuration(prepared, context: context) {
            let cap = impl.configuration.maximumSessionMinutes
            let overflowStart = context.calendar.date(byAdding: .minute, value: cap, to: prepared.startedAt) ?? context.now
            prepared.pauses.append(StudyPauseInterval(startedAt: overflowStart, endedAt: context.now))
            notes.append("untrustedDuration:>\(cap)min|auto-excluded")
        }

        guard !notes.isEmpty else { return session }
        for note in notes {
            prepared.note = StudySessionEngineImpl.appendingNote(note, to: prepared.note)
        }
        prepared.updatedAt = context.now
        return prepared
    }

    // MARK: 会话恢复 / 放弃 / 进度 / 手动修正（需求 3、5）

    /// 会话上下文（含计划项），供恢复类操作复用。
    private static func sessionContext(
        for session: StudySession,
        state: StoreSnapshot
    ) -> PlanItemSessionContext? {
        session.planItemID
            .flatMap { id in state.dailyPlans.flatMap(\.items).first { $0.id == id } }
            .flatMap { PlanItemSessionContext(item: $0) }
    }

    /// 放弃学习。
    ///
    /// 与"暂停"语义不同：会话进入 `abandoned`，不再计入进行中，
    /// 已产生的时长仍留在会话里（放弃不等于没学过），但不会生成完成事件。
    func abandonSession(
        sessionID: UUID,
        reason: String,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        guard let engine = engines.sessionEngine else {
            return Self.missingModuleResult(state, module: "学习会话引擎（StudySessionEngine）")
        }
        guard let session = state.studySessions.first(where: { $0.id == sessionID }) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: PlanCoordinationRejection.unknownSession(sessionID).message,
                didChange: false,
                rejection: .unknownSession(sessionID)
            )
        }

        let transition = engine.apply(
            .abandon(at: context.now, reason: reason),
            to: session,
            item: Self.sessionContext(for: session, state: state),
            context: context
        )
        if let rejection = transition.rejection {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: rejection.message,
                didChange: false,
                rejection: .invalidState(rejection.message)
            )
        }
        guard let updated = transition.session else {
            return PlanCoordinationResult(snapshot: state, statusMessage: "没有需要提交的变化。", didChange: false)
        }

        var working = state
        Self.upserting(updated, in: &working)
        return PlanCoordinationResult(
            snapshot: working,
            mutations: [PlanStoreMutation(kind: .upsertSession, entityID: updated.id, summary: "放弃学习")],
            statusMessage: "已放弃本次学习（已记录的原因：\(reason)）。",
            didChange: true
        )
    }

    /// 保存部分进度（"记录进度"按钮）。
    func saveSessionProgress(
        sessionID: UUID,
        scope: StudyScope,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        guard let engine = engines.sessionEngine else {
            return Self.missingModuleResult(state, module: "学习会话引擎（StudySessionEngine）")
        }
        guard let session = state.studySessions.first(where: { $0.id == sessionID }) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: PlanCoordinationRejection.unknownSession(sessionID).message,
                didChange: false,
                rejection: .unknownSession(sessionID)
            )
        }

        let transition = engine.apply(
            .updateProgress(scope: scope, at: context.now),
            to: session,
            item: Self.sessionContext(for: session, state: state),
            context: context
        )
        if let rejection = transition.rejection {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: rejection.message,
                didChange: false,
                rejection: .invalidState(rejection.message)
            )
        }
        guard let updated = transition.session else {
            return PlanCoordinationResult(snapshot: state, statusMessage: "进度没有变化。", didChange: false)
        }

        var working = state
        Self.upserting(updated, in: &working)
        // 进度也要反映到计划项上，首页/计划页才能立刻看到（完成事件仍是权威来源）。
        if let planItemID = updated.planItemID {
            Self.updatingItem(planItemID, in: &working, now: context.now) { item in
                item.achievedScope = updated.progress
                item.status = .inProgress
                item.updatedAt = context.now
            }
        }
        return PlanCoordinationResult(
            snapshot: working,
            mutations: [PlanStoreMutation(kind: .upsertSession, entityID: updated.id, summary: "保存进度")],
            statusMessage: "已保存进度：\(updated.progress.displayText)。",
            didChange: true
        )
    }

    /// 手动修正会话时长（保留来源与原因）。
    ///
    /// - 目标比当前少：把差值记为一段暂停，有效时长自然减少；
    /// - 目标比当前多：把开始时间往前移（用户补记了线下学习时间）。
    func adjustSessionDuration(
        sessionID: UUID,
        targetMinutes: Int,
        reason: String,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        guard engines.sessionEngine != nil else {
            return Self.missingModuleResult(state, module: "学习会话引擎（StudySessionEngine）")
        }
        guard var session = state.studySessions.first(where: { $0.id == sessionID }) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: PlanCoordinationRejection.unknownSession(sessionID).message,
                didChange: false,
                rejection: .unknownSession(sessionID)
            )
        }

        let current = session.effectiveMinutes(asOf: context.now, calendar: context.calendar)
        let target = max(0, targetMinutes)
        guard target != current else {
            return PlanCoordinationResult(snapshot: state, statusMessage: "时长没有变化。", didChange: false)
        }

        if target < current {
            let delta = current - target
            let pauseStart = context.calendar.date(byAdding: .minute, value: -delta, to: context.now) ?? context.now
            session.pauses.append(StudyPauseInterval(startedAt: max(pauseStart, session.startedAt), endedAt: context.now))
        } else {
            let delta = target - current
            session.startedAt = context.calendar.date(byAdding: .minute, value: -delta, to: session.startedAt) ?? session.startedAt
        }
        session.note = StudySessionEngineImpl.appendingNote(
            StudySessionEngineImpl.manualAdjustmentNote(minutes: target, reason: reason),
            to: session.note
        )
        session.updatedAt = context.now

        var working = state
        Self.upserting(session, in: &working)
        let after = session.effectiveMinutes(asOf: context.now, calendar: context.calendar)
        return PlanCoordinationResult(
            snapshot: working,
            mutations: [PlanStoreMutation(kind: .upsertSession, entityID: session.id, summary: "手动修正时长")],
            statusMessage: "已把本次学习时长修正为 \(after) 分钟（原因：\(reason)）。",
            didChange: true
        )
    }

    /// 确认"中断期间是否在学"。
    ///
    /// - 在学：保留这段时间，只在会话上留下确认记录；
    /// - 没学：把这段未知时间记成暂停，从而**排除**在有效时长之外。
    func resolveInterruption(
        sessionID: UUID,
        studiedDuringGap: Bool,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        guard let engine = engines.sessionEngine as? StudySessionEngineImpl else {
            return Self.missingModuleResult(state, module: "学习会话引擎（StudySessionEngine）")
        }
        guard var session = state.studySessions.first(where: { $0.id == sessionID }) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: PlanCoordinationRejection.unknownSession(sessionID).message,
                didChange: false,
                rejection: .unknownSession(sessionID)
            )
        }
        guard let interruption = engine.interruptionCandidate(for: session, context: context) else {
            return PlanCoordinationResult(snapshot: state, statusMessage: "这段时间不算中断，无需确认。", didChange: false)
        }

        if !studiedDuringGap {
            // 翻译成既有事件：先暂停（回到最后已知活跃时刻），再恢复（到当前时间）。
            let paused = engine.apply(.pause(at: interruption.lastKnownActiveAt), to: session, item: nil, context: context)
            if let pausedSession = paused.session { session = pausedSession }
            let resumed = engine.apply(.resume(at: context.now), to: session, item: nil, context: context)
            if let resumedSession = resumed.session { session = resumedSession }
        }
        session.note = StudySessionEngineImpl.appendingNote(
            StudySessionEngineImpl.interruptionDecisionNote(
                studiedDuringGap: studiedDuringGap,
                gapMinutes: interruption.gapMinutes
            ),
            to: session.note
        )
        session.updatedAt = context.now

        var working = state
        Self.upserting(session, in: &working)
        return PlanCoordinationResult(
            snapshot: working,
            mutations: [PlanStoreMutation(kind: .upsertSession, entityID: session.id, summary: "确认中断时段")],
            statusMessage: studiedDuringGap
                ? "已确认中断的 \(interruption.gapMinutes) 分钟用于学习，计入有效时长。"
                : "已排除中断的 \(interruption.gapMinutes) 分钟，不计入有效时长。",
            didChange: true
        )
    }

    // MARK: 直接完成（旧业务：复习列表 / 错题页，可以还没有今日计划）

    /// 记录一次"没有计划项"的完成（复习列表、错题练习等旧入口）。
    ///
    /// 使用 G 的稳定幂等键（业务对象 + 学习日），因此重复点击不会重复记录。
    /// 完成事件仍会驱动计划项状态、SM-2 与奖励评估。
    func completeDirect(
        key: String,
        dayKey: StudyDayKey,
        source: DailyPlanItemSource,
        plannedScope: StudyScope?,
        minimumScope: StudyScope? = nil,
        completedScope: StudyScope,
        minutes: Int,
        durationSource: StudyDurationSource? = nil,
        durationNote: String? = nil,
        assessment: StudyAssessment?,
        note: String,
        state: StoreSnapshot,
        context: PlanningContext,
        successMessage: String
    ) -> PlanCoordinationResult {
        // 若当天计划里已经有同来源的计划项，则挂到该计划项上，保持"统一状态来源"。
        let existingItem = state.dailyPlans
            .flatMap(\.items)
            .first { $0.source == source && $0.scheduledDayKey == dayKey }

        let event: CompletionEvent
        if let existingItem {
            event = CompletionEvent.make(
                planID: existingItem.planID,
                planItemID: existingItem.id,
                dayKey: dayKey,
                source: source,
                plannedScope: existingItem.plannedScope,
                minimumScope: existingItem.minimumScope,
                completedScope: completedScope,
                actualMinutes: minutes,
                durationSource: durationSource,
                durationNote: durationNote,
                completedAt: context.now,
                assessment: assessment,
                note: note,
                createdAt: context.now
            )
        } else {
            event = CompletionEvent.direct(
                key: key,
                dayKey: dayKey,
                source: source,
                plannedScope: plannedScope,
                minimumScope: minimumScope,
                completedScope: completedScope,
                actualMinutes: minutes,
                durationSource: durationSource,
                durationNote: durationNote,
                completedAt: context.now,
                assessment: assessment,
                note: note
            )
        }

        return applyingCompletion(
            event,
            state: state,
            mutations: [],
            context: context,
            successMessage: successMessage
        )
    }

    // MARK: 直接完成计划项（不经过会话）

    private func completeItemDirectly(
        planItemID: UUID,
        scope: StudyScope,
        minutes: Int,
        assessment: StudyAssessment?,
        note: String,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        guard let item = state.dailyPlans.flatMap(\.items).first(where: { $0.id == planItemID }) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: PlanCoordinationRejection.unknownPlanItem(planItemID).message,
                didChange: false,
                rejection: .unknownPlanItem(planItemID)
            )
        }

        let event = CompletionEvent.make(
            planID: item.planID,
            planItemID: item.id,
            dayKey: item.scheduledDayKey,
            source: item.source,
            plannedScope: item.plannedScope,
            minimumScope: item.minimumScope,
            completedScope: scope,
            actualMinutes: minutes,
            completedAt: context.now,
            assessment: assessment,
            note: note,
            createdAt: context.now
        )

        return applyingCompletion(
            event,
            state: state,
            mutations: [],
            context: context,
            successMessage: "已记录完成：\(item.title)"
        )
    }

    /// 提交完成事件的统一路径。
    ///
    /// 顺序（与 G 的状态提交顺序一致）：
    /// 1. 幂等检查（重复 → 明确拒绝，不写任何东西）
    /// 2. 插入完成事件并重算计划项状态
    /// 3. 同步旧业务（复习任务的 SM-2）
    /// 4. 评估奖励资格并写入待发放奖励
    /// 5. 产出通知意图
    private func applyingCompletion(
        _ event: CompletionEvent,
        state: StoreSnapshot,
        mutations: [PlanStoreMutation],
        context: PlanningContext,
        successMessage: String
    ) -> PlanCoordinationResult {
        guard let inserted = state.insertingCompletionEvent(event) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: PlanCoordinationRejection.duplicateCompletion(ignoredKey: event.idempotencyKey).message,
                didChange: false,
                rejection: .duplicateCompletion(ignoredKey: event.idempotencyKey)
            )
        }

        var working = inserted
        var allMutations = mutations
        allMutations.append(
            PlanStoreMutation(kind: .insertCompletion, entityID: event.id, summary: "记录完成：\(event.completedScope.displayText)")
        )

        let recomputed = working.recomputingPlans(from: working.completionEvents)
        if recomputed.dailyPlans != working.dailyPlans {
            for plan in recomputed.dailyPlans where plan.dayKey == event.dayKey {
                allMutations.append(PlanStoreMutation(kind: .upsertPlan, entityID: plan.id, summary: "更新计划项完成状态"))
            }
            working = recomputed
        }

        allMutations.append(contentsOf: applyingLegacyReviewOutcome(event, state: &working, context: context))

        let reward = applyingRewardEvaluation(state: working, dayKey: event.dayKey, context: context)
        working = reward.state
        allMutations.append(contentsOf: reward.mutations)

        var reminders: [ReminderChangeRequest] = []
        if let plan = Self.activePlan(in: working, dayKey: event.dayKey) {
            reminders = reminderChanges(for: plan, state: working, context: context)
        }

        return PlanCoordinationResult(
            snapshot: working,
            mutations: allMutations,
            reminderChanges: reminders,
            statusMessage: successMessage + reward.statusSuffix,
            didChange: true
        )
    }

    // MARK: 旧业务：复习任务按原规则进入 SM-2

    /// 完成事件 → 复习任务状态。
    ///
    /// - 标准完成：按用户评分走原 SM-2 规则推进间隔；
    /// - 保底 / 部分完成：**不**当作完整成功复习（评分封顶为"答错但熟悉"，间隔重置）；
    /// - 已学习（未到保底）：任务保持待复习，不改变 SM-2 状态。
    private func applyingLegacyReviewOutcome(
        _ event: CompletionEvent,
        state: inout StoreSnapshot,
        context: PlanningContext
    ) -> [PlanStoreMutation] {
        guard let reviewTaskID = event.source?.reviewTaskID ?? Self.reviewTaskID(forItemIn: state, event: event),
              let index = state.reviewTasks.firstIndex(where: { $0.id == reviewTaskID }) else {
            return []
        }

        let quality = ReviewPlanner.quality(forTier: event.tier, assessment: event.assessment, fallback: .good)
        let updated = ReviewPlanner.applyCompletion(
            task: state.reviewTasks[index],
            tier: event.tier,
            quality: quality,
            context: context
        )
        // 「已学习」不改变 SM-2 状态；其余档次一定会推进/重置间隔与复习时间。
        guard event.tier != .studied else { return [] }
        state.reviewTasks[index] = updated
        return [PlanStoreMutation(kind: .upsertPlan, entityID: updated.id, summary: "复习任务按 SM-2 更新（\(event.tier.label)）")]
    }

    private static func reviewTaskID(forItemIn state: StoreSnapshot, event: CompletionEvent) -> UUID? {
        guard let planItemID = event.planItemID else { return nil }
        return state.dailyPlans
            .flatMap(\.items)
            .first { $0.id == planItemID }?
            .source
            .reviewTaskID
    }

    // MARK: 减量 / 保底

    /// 应用减量方案。
    ///
    /// 一致性规则（需求 1、4、5）：
    /// - **模式由策略决定**：标准 / 轻量 / 保底 / 休息，协调层不再统一改写成 `.reduced`；
    /// - 策略来自按当前快照构造的工厂（睡眠窗口 = 用户配置）；
    /// - 被推迟 / 移除 / 缩掉的**剩余范围**保留为"待安排"，不谎称已完成或已顺延完成；
    /// - `expectedPlanID` / `expectedVersion` 用于拒绝过期预览：界面拿旧预览点应用时，
    ///   不会悄悄应用成另一个方案。
    private func reduceToMinimum(
        dayKey: StudyDayKey,
        remainingMinutes: Int,
        expectedPlanID: UUID?,
        expectedVersion: Int?,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        // 走 reduceToMinimum 一定是用户主动采用方案 → isManual: true。
        guard let policy = engines.resolvedMinimumPolicy(for: state, isManual: true) else {
            return Self.missingModuleResult(state, module: "最低任务策略（MinimumPlanPolicy）")
        }
        guard let plan = Self.activePlan(in: state, dayKey: dayKey) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: PlanCoordinationRejection.noPlan(dayKey: dayKey).message,
                didChange: false,
                rejection: .noPlan(dayKey: dayKey)
            )
        }

        // 预览过期保护：计划在这期间换了版本 → 拒绝，让界面重新预览。
        if let expectedPlanID, expectedPlanID != plan.id {
            let message = "计划已经更新（当前是第 \(plan.version) 版），请重新查看减量预览后再应用。"
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: message,
                didChange: false,
                rejection: .invalidState(message)
            )
        }
        if let expectedVersion, expectedVersion != plan.version {
            let message = "计划已经更新（第 \(expectedVersion) 版 → 第 \(plan.version) 版），请重新查看减量预览后再应用。"
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: message,
                didChange: false,
                rejection: .invalidState(message)
            )
        }

        let splittable = Set(plan.items.filter(\.isSplittable).map(\.id))
        let proposal = policy.reduce(
            plan: plan,
            remainingMinutes: max(0, remainingMinutes),
            splittableItemIDs: splittable,
            context: context
        )

        let isRest = proposal.isRestSuggestion
        // 休息建议不改内容；但用户明确选择「今天休息」时要把模式落到计划上，
        // 这样首页、奖励进度与通知看到的是同一个状态。
        let targetMode: DailyPlanMode = isRest ? .rest : proposal.plan.mode

        if Self.isContentEquivalent(proposal.plan, plan) && plan.mode == targetMode {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: isRest
                    ? "剩余时间不足以安排保底任务，今天保持休息；计划内容未改动，也不会写入完成记录。"
                    : "方案与原计划一致，未做改动。",
                didChange: false
            )
        }

        var working = state
        var mutations: [PlanStoreMutation] = []

        Self.upserting(plan.supersededCopy(now: context.now), in: &working)
        mutations.append(PlanStoreMutation(kind: .upsertPlan, entityID: plan.id, summary: "减量前版本标记为已替换"))

        var reduced = proposal.plan
        reduced.id = proposal.plan.id == plan.id ? UUID() : proposal.plan.id
        reduced.version = plan.version + 1
        reduced.supersedesPlanID = plan.id
        reduced.isUndoableReduction = true
        reduced.reductionUndoTargetPlanID = plan.id
        reduced.status = .active
        reduced.mode = targetMode
        reduced.updatedAt = context.now
        reduced.items = Self.preservingProtectedItems(proposed: reduced.items, existing: plan, planID: reduced.id)
        // 被推迟 / 缩掉的剩余范围保留为「待安排」（不写完成、不写顺延完成）。
        reduced.unplaceable = Self.mergingPending(
            existing: reduced.unplaceable,
            from: proposal.changes,
            originalPlan: plan
        )
        reduced.budget.plannedMinutes = reduced.plannedMinutesFromItems
        reduced.explanation = Self.reductionExplanation(proposal: proposal, base: reduced.explanation, isRest: isRest)

        Self.upserting(reduced, in: &working)
        mutations.append(
            PlanStoreMutation(
                kind: .upsertPlan,
                entityID: reduced.id,
                summary: "应用「\(reduced.mode.label)」方案（第 \(reduced.version) 版）"
            )
        )

        let reward = applyingRewardEvaluation(state: working, dayKey: dayKey, context: context)
        working = reward.state
        mutations.append(contentsOf: reward.mutations)

        return PlanCoordinationResult(
            snapshot: working,
            mutations: mutations,
            reminderChanges: reminderChanges(for: reduced, state: working, context: context),
            statusMessage: Self.reductionStatusMessage(plan: reduced, proposal: proposal) + reward.statusSuffix,
            didChange: true
        )
    }

    /// 把减量造成的「剩余内容」记录成待安排项。
    static func mergingPending(
        existing: [UnplaceablePlanItem],
        from changes: [MinimumPlanChange],
        originalPlan: DailyStudyPlan
    ) -> [UnplaceablePlanItem] {
        var result = existing
        for change in changes where change.kind == .deferred || change.kind == .removed || change.kind == .trimmed {
            let remainingScope: StudyScope?
            switch change.kind {
            case .trimmed:
                if let before = change.beforeScope,
                   let after = change.afterScope,
                   before.isComparable(to: after) {
                    let rest = before.amount - after.amount
                    remainingScope = rest > 0
                        ? StudyScope(unit: before.unit, amount: rest, customUnitLabel: before.customUnitLabel)
                        : nil
                } else {
                    remainingScope = change.beforeScope
                }
            default:
                remainingScope = change.beforeScope
            }
            guard let scope = remainingScope, scope.isPositive else { continue }
            let item = originalPlan.items.first { $0.id == change.itemID }
            result.append(
                UnplaceablePlanItem(
                    id: UUID(),
                    source: item?.source ?? DailyPlanItemSource(kind: .manual, manualNote: change.title),
                    title: change.title,
                    plannedScope: scope,
                    estimatedMinutes: max(0, change.beforeMinutes - change.afterMinutes),
                    reason: .insufficientCapacity,
                    detail: "\(change.kind.label)：剩余 \(scope.displayText) 保留为待安排（未完成、未顺延完成）。原因：\(change.reason)"
                )
            )
        }
        return result
    }

    /// 把减量原因写进计划解释（保存后首页看到的就是这份解释）。
    static func reductionExplanation(
        proposal: MinimumPlanProposal,
        base: DailyPlanExplanation,
        isRest: Bool
    ) -> DailyPlanExplanation {
        var explanation = base
        let prefix = isRest ? "休息状态：" : "减量方案："
        let firstLine = proposal.explanation.lines.first ?? "\(proposal.changes.count) 项调整"
        explanation.lines.insert("\(prefix)\(firstLine)", at: 0)
        for line in proposal.explanation.lines.dropFirst() {
            explanation.lines.append(line)
        }
        for reason in proposal.explanation.blockedReasons where !explanation.blockedReasons.contains(reason) {
            explanation.blockedReasons.append(reason)
        }
        for assumption in proposal.explanation.assumptions where !explanation.assumptions.contains(assumption) {
            explanation.assumptions.append(assumption)
        }
        return explanation
    }

    static func reductionStatusMessage(plan: DailyStudyPlan, proposal: MinimumPlanProposal) -> String {
        if proposal.isRestSuggestion {
            return "已记录为休息状态：今天不再安排新任务，未完成内容保留为待安排。"
        }
        let kept = plan.items.count
        let pending = plan.unplaceable.count
        var message = "已采用「\(plan.mode.label)」：保留 \(kept) 项、共 \(plan.plannedMinutesFromItems) 分钟"
        if pending > 0 {
            message += "，另有 \(pending) 项剩余内容保留为待安排"
        }
        return message + "。"
    }

    // MARK: 撤销减量（需求 5）

    /// 撤销最近一次减量：回到减量前的计划版本。
    ///
    /// - 不覆盖减量之后新增的完成记录：恢复出来的计划项按**当前完成事件**重算状态；
    /// - 进行中 / 已完成 / 用户固定的任务保持稳定；
    /// - 撤销本身也是一次正常提交（保存成功后才提示生效）。
    private func undoMinimumPlan(
        dayKey: StudyDayKey,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        guard let current = Self.activePlan(in: state, dayKey: dayKey) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: PlanCoordinationRejection.noPlan(dayKey: dayKey).message,
                didChange: false,
                rejection: .noPlan(dayKey: dayKey)
            )
        }
        guard current.isUndoableReduction,
              let previousID = current.reductionUndoTargetPlanID,
              let previous = state.dailyPlans.first(where: { $0.id == previousID }),
              previous.dayKey == current.dayKey,
              previous.version < current.version,
              previous.status == .superseded else {
            let message = "没有可撤销的减量：当前计划不是由减量产生的。"
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: message,
                didChange: false,
                rejection: .invalidState(message)
            )
        }

        var working = state
        var mutations: [PlanStoreMutation] = []

        Self.upserting(current.supersededCopy(now: context.now), in: &working)
        mutations.append(PlanStoreMutation(kind: .upsertPlan, entityID: current.id, summary: "当前版本标记为已替换"))

        var restored = previous
        restored.id = UUID()
        restored.version = current.version + 1
        // 前驱关系保留为审计历史；明确恢复目标清空后，这次减量不可再次撤销。
        restored.supersedesPlanID = current.id
        restored.isUndoableReduction = false
        restored.reductionUndoTargetPlanID = nil
        restored.status = .active
        restored.updatedAt = context.now
        restored.items = Self.itemsForReductionUndo(
            restoring: previous.items,
            current: current,
            completionEvents: state.completionEvents,
            activeSessions: state.studySessions.filter { $0.state.isActive },
            planID: restored.id,
            now: context.now
        )
        restored.budget.plannedMinutes = restored.plannedMinutesFromItems
        restored.explanation.lines.insert(
            "已撤销减量：恢复到第 \(previous.version) 版的内容（第 \(restored.version) 版）。",
            at: 0
        )

        // 只重算刚恢复的版本，历史版本的状态缓存保持原样。
        restored = restored.recomputingItemStates(from: working.completionEvents)
        // 完成事件是完成进度的权威来源；固定状态和进行中会话则来自当前计划/会话。
        restored = Self.restoringPinnedAndInProgressState(
            on: restored,
            from: current,
            activeSessions: state.studySessions.filter { $0.state.isActive },
            completionEvents: working.completionEvents,
            now: context.now
        )
        restored.budget.plannedMinutes = restored.plannedMinutesFromItems
        Self.upserting(restored, in: &working)

        mutations.append(
            PlanStoreMutation(kind: .upsertPlan, entityID: restored.id, summary: "撤销减量，恢复第 \(previous.version) 版内容")
        )

        let restoredActive = Self.activePlan(in: working, dayKey: dayKey) ?? restored
        let reward = applyingRewardEvaluation(state: working, dayKey: dayKey, context: context)
        working = reward.state
        mutations.append(contentsOf: reward.mutations)
        return PlanCoordinationResult(
            snapshot: working,
            mutations: mutations,
            reminderChanges: reminderChanges(for: restoredActive, state: working, context: context),
            statusMessage: "已撤销减量，恢复到第 \(previous.version) 版；减量后新增的完成记录保持不变。" + reward.statusSuffix,
            didChange: true
        )
    }

    /// 恢复减量前的任务范围，同时保留减量后新增且仍有效的任务记录。
    private static func itemsForReductionUndo(
        restoring originalItems: [DailyPlanItem],
        current: DailyStudyPlan,
        completionEvents: [CompletionEvent],
        activeSessions: [StudySession],
        planID: UUID,
        now: Date
    ) -> [DailyPlanItem] {
        let originalIDs = Set(originalItems.map(\.id))
        var items = originalItems.map { original -> DailyPlanItem in
            var item = original
            item.planID = planID
            if let currentItem = current.items.first(where: { $0.id == original.id }) {
                item.isPinned = original.isPinned || currentItem.isPinned
                if currentItem.isPinned || currentItem.status == .inProgress {
                    item.scheduledStart = currentItem.scheduledStart
                    item.scheduledEnd = currentItem.scheduledEnd
                    item.scheduledDayKey = currentItem.scheduledDayKey
                }
                if currentItem.status == .inProgress {
                    item.status = .inProgress
                    item.achievedScope = currentItem.achievedScope
                }
            }
            return item
        }

        let completedIDs = Set(completionEvents.filter { !$0.isRevoked }.compactMap(\.planItemID))
        let activeSessionIDs = Set(activeSessions.compactMap(\.planItemID))
        let additions = current.items.filter { item in
            !originalIDs.contains(item.id)
                && (item.isPinned || item.status == .inProgress || completedIDs.contains(item.id) || activeSessionIDs.contains(item.id))
        }.map { item -> DailyPlanItem in
            var copy = item
            copy.planID = planID
            copy.updatedAt = now
            return copy
        }
        items.append(contentsOf: additions)
        return items
    }

    /// 完成事件重算之后恢复固定标记与没有完成事件表达的进行中会话进度。
    private static func restoringPinnedAndInProgressState(
        on plan: DailyStudyPlan,
        from current: DailyStudyPlan,
        activeSessions: [StudySession],
        completionEvents: [CompletionEvent],
        now: Date
    ) -> DailyStudyPlan {
        var restored = plan
        let currentByID = Dictionary(current.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let validCompletionIDs = Set(completionEvents.filter { !$0.isRevoked }.compactMap(\.planItemID))
        let activeSessionByItemID = Dictionary(
            activeSessions.compactMap { session in session.planItemID.map { ($0, session) } },
            uniquingKeysWith: { first, _ in first }
        )
        restored.items = restored.items.map { item in
            var copy = item
            if let currentItem = currentByID[item.id] {
                copy.isPinned = copy.isPinned || currentItem.isPinned
                if currentItem.status == .inProgress && !validCompletionIDs.contains(item.id) {
                    copy.status = .inProgress
                    copy.achievedScope = currentItem.achievedScope
                }
            }
            if let session = activeSessionByItemID[item.id], !validCompletionIDs.contains(item.id) {
                copy.status = .inProgress
                copy.achievedScope = session.progress
            }
            copy.updatedAt = now
            return copy
        }
        return restored
    }

    // MARK: 撤销完成

    private func revokeCompletion(
        completionID: UUID,
        reason: String,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        guard let revoked = state.revokingCompletionEvent(id: completionID, at: context.now, reason: reason) else {
            return PlanCoordinationResult(
                snapshot: state,
                statusMessage: "找不到可撤销的完成记录（可能已撤销过）。",
                didChange: false,
                rejection: .invalidState("完成记录不存在或已撤销")
            )
        }

        var working = revoked
        var mutations = [PlanStoreMutation(kind: .updateCompletion, entityID: completionID, summary: "撤销完成记录")]

        let recomputed = working.recomputingPlans(from: working.completionEvents)
        if recomputed.dailyPlans != working.dailyPlans {
            for plan in recomputed.dailyPlans {
                mutations.append(PlanStoreMutation(kind: .upsertPlan, entityID: plan.id, summary: "撤销后重算计划项状态"))
            }
            working = recomputed
        }

        let dayKey = state.completionEvent(id: completionID)?.dayKey ?? context.todayKey
        // 只按剩余的有效学习记录重新核验资格。某条依据撤销但其他记录仍达标时，奖励保留。
        mutations.append(contentsOf: Self.expiringStaleRewardGrants(in: &working, before: context.todayKey, at: context.now))
        if dayKey >= context.todayKey {
            let reward = applyingRewardEvaluation(state: working, dayKey: dayKey, context: context)
            working = reward.state
            mutations.append(contentsOf: reward.mutations)
        }

        return PlanCoordinationResult(
            snapshot: working,
            mutations: mutations,
            reminderChanges: Self.activePlan(in: working, dayKey: dayKey).map {
                reminderChanges(for: $0, state: working, context: context)
            } ?? [],
            statusMessage: "已撤销完成记录。",
            didChange: true
        )
    }

    // MARK: 娱乐奖励

    private enum RewardOperation { case claim, start, finish }

    /// 奖励操作的唯一业务入口（首页 / 娱乐页 / 设置页都走这里）。
    ///
    /// 统一下列校验（需求 6）：
    /// 1. 记录存在；
    /// 2. 未撤销 / 未过期 / 未使用完；
    /// 3. 属于当前可用学习日；
    /// 4. 资格仍然有效（发放时依据的规则版本仍在当天生效）；
    /// 5. 同一时刻只允许一个娱乐计时；
    /// 6. 不重复发放 / 重复领取。
    private func updateRewardGrant(
        grantID: UUID,
        operation: RewardOperation,
        usedMinutes: Int,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> PlanCoordinationResult {
        func rejected(_ rejection: PlanCoordinationRejection) -> PlanCoordinationResult {
            PlanCoordinationResult(
                snapshot: state,
                statusMessage: rejection.message,
                didChange: false,
                rejection: rejection
            )
        }

        guard let grant = state.rewardGrant(id: grantID) else {
            return rejected(.unknownRewardGrant(grantID))
        }
        if operation == .finish {
            // 结束已开始的计时不再受当前规则版本、资格或学习日限制。
            // 已开始的娱乐保留历史并允许正常落盘收尾。
            guard grant.state == .started, !grant.isRevoked else {
                return rejected(.invalidState("只有正在进行的娱乐计时可以结束。"))
            }
        } else {
            if grant.isRevoked {
                return rejected(.rewardNotEligible("这条奖励已经被撤销。"))
            }
            switch grant.state {
            case .expired:
                return rejected(.rewardExpired(grantID: grantID))
            case .finished:
                return rejected(.rewardAlreadyUsed(grantID: grantID))
            default:
                break
            }

            // 领取与开始只能使用今天的奖励。
            let dayKey = context.todayKey
            guard grant.dayKey == dayKey else {
                return rejected(.rewardNotUsableToday(
                    "它属于 \(grant.dayKey.localDateString)，只能在使用当天领取与计时。"
                ))
            }

            // 不只检查版本存在；每次领取 / 开始都按当前完成账本重新核验条件。
            switch rewardQualification(for: grant, state: state, context: context) {
            case .eligible:
                break
            case .undecidable:
                return rejected(.rewardNotEligible("当天学习记录不足，暂时无法重新核验资格。"))
            case .ineligible(let reason):
                guard grant.isUnstartedAndUnused,
                      let revoked = grant.revoked(at: context.now, reason: reason) else {
                    return rejected(.rewardNotEligible(reason))
                }
                var updatedState = state
                guard let index = updatedState.rewardGrants.firstIndex(where: { $0.id == grantID }) else {
                    return rejected(.unknownRewardGrant(grantID))
                }
                updatedState.rewardGrants[index] = revoked
                return PlanCoordinationResult(
                    snapshot: updatedState,
                    mutations: [PlanStoreMutation(kind: .upsertRewardGrant, entityID: grantID, summary: "资格核验后撤销未使用奖励")],
                    statusMessage: reason,
                    didChange: true
                )
            }
        }

        // 全局单娱乐计时：开始新计时前不允许已有正在进行的计时。
        if operation == .start,
           let running = state.rewardGrants.first(where: { $0.state == .started && $0.id != grantID }) {
            _ = running
            return rejected(.anotherRewardRunning(grantID: grantID))
        }

        let updated: StoreSnapshot?
        let summary: String
        switch operation {
        case .claim:
            updated = state.claimingRewardGrant(id: grantID, at: context.now)
            summary = "领取娱乐奖励"
        case .start:
            updated = state.startingRewardGrant(id: grantID, at: context.now)
            summary = "开始娱乐计时"
        case .finish:
            updated = state.finishingRewardGrant(id: grantID, at: context.now, usedMinutes: usedMinutes)
            summary = "结束娱乐计时"
        }

        guard let result = updated else {
            return rejected(.duplicateRewardClaim(grantID: grantID))
        }

        var reminderChanges: [ReminderChangeRequest] = []
        switch operation {
        case .start:
            if let started = result.rewardGrant(id: grantID), started.remainingMinutes > 0 {
                let fireDate = context.calendar.date(
                    byAdding: .minute,
                    value: started.remainingMinutes,
                    to: context.now
                ) ?? context.now
                // 一次娱乐只安排一次提醒，且统一绑定 grantID（需求 9）。
                reminderChanges.append(
                    ReminderChangeRequest(
                        action: .schedule,
                        planItemID: nil,
                        fireDate: fireDate,
                        title: "娱乐时间到（\(grant.ruleSnapshot.name)）",
                        kind: .entertainmentEnd,
                        businessID: grantID.uuidString
                    )
                )
            }
        case .finish:
            // 提前结束：必须取消这条娱乐的到期提醒。
            reminderChanges.append(
                ReminderChangeRequest(
                    action: .cancel,
                    planItemID: nil,
                    fireDate: nil,
                    title: "",
                    kind: .entertainmentEnd,
                    businessID: grantID.uuidString
                )
            )
        case .claim:
            break
        }

        return PlanCoordinationResult(
            snapshot: result,
            mutations: [PlanStoreMutation(kind: .upsertRewardGrant, entityID: grantID, summary: summary)],
            reminderChanges: reminderChanges,
            statusMessage: summary + "，共 \(grant.grantedMinutes) 分钟。",
            didChange: true
        )
    }

    // MARK: 奖励评估

    private struct RewardApplication {
        var state: StoreSnapshot
        var mutations: [PlanStoreMutation]
        var statusMessage: String

        var statusSuffix: String { statusMessage.isEmpty ? "" : " " + statusMessage }
    }

    private enum RewardGrantQualification {
        case eligible
        case undecidable
        case ineligible(String)
    }

    /// 独立核验规则仍生效与学习条件仍满足；不依赖是否会新建一条待发放记录。
    private func rewardQualification(
        for grant: RewardGrant,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> RewardGrantQualification {
        guard let evaluator = engines.rewardEvaluator else { return .undecidable }
        let effectiveRules = state.entertainmentRules.filter {
            $0.isEffective(on: grant.dayKey, calendar: context.calendar)
        }
        guard effectiveRules.contains(where: { $0.id == grant.ruleID && $0.revisionID == grant.ruleRevisionID }) else {
            return .ineligible("发放依据的规则版本已失效，未使用奖励已取消。")
        }

        let evaluation = evaluator.evaluate(
            rules: effectiveRules,
            plan: Self.activePlan(in: state, dayKey: grant.dayKey),
            completions: state.completionEvents,
            grants: state.rewardGrants,
            summary: state.dailySummary(for: grant.dayKey),
            context: context
        )
        if evaluation.undecidableRuleRevisionIDs.contains(grant.ruleRevisionID) {
            return .undecidable
        }
        guard evaluation.eligibleRuleRevisionIDs.contains(grant.ruleRevisionID) else {
            let revokedBasisStillPresent = grant.basisEventIDs.contains { eventID in
                state.completionEvents.contains { $0.id == eventID && $0.isRevoked }
            }
            return .ineligible(
                revokedBasisStillPresent
                    ? "相关学习记录已撤销，未使用奖励已取消。"
                    : "当前学习条件已不再满足，未使用奖励已取消。"
            )
        }
        return .eligible
    }

    /// 评估奖励资格并写入待发放奖励。幂等：发放键含规则版本 + 学习日。
    private func applyingRewardEvaluation(
        state: StoreSnapshot,
        dayKey: StudyDayKey,
        context: PlanningContext
    ) -> RewardApplication {
        guard let evaluator = engines.rewardEvaluator else {
            return RewardApplication(state: state, mutations: [], statusMessage: "")
        }

        let summary = state.dailySummary(for: dayKey)
        let plan = Self.activePlan(in: state, dayKey: dayKey)
        let evaluation = evaluator.evaluate(
            rules: state.entitlementRules(on: dayKey),
            plan: plan,
            completions: state.completionEvents,
            grants: state.rewardGrants,
            summary: summary,
            context: context
        )

        var working = state
        var mutations: [PlanStoreMutation] = []

        // 资格已失效时，立即撤销尚未使用的待领取 / 已领取奖励，避免界面继续展示可用。
        // 已开始的奖励保留原状态，避免回滚用户正在进行的计时。
        let activeRules = state.entertainmentRules.filter { $0.isEffective(on: dayKey, calendar: context.calendar) }
        let activeRevisionIDs = Set(activeRules.map(\.revisionID))
        let eligibleRevisionIDs = Set(evaluation.eligibleRuleRevisionIDs)
        let undecidableRevisionIDs = Set(evaluation.undecidableRuleRevisionIDs)
        var insertedGrantCount = 0
        for index in working.rewardGrants.indices {
            let grant = working.rewardGrants[index]
            guard grant.dayKey == dayKey, grant.isUnstartedAndUnused, !grant.isRevoked else { continue }

            // 旧规则版本无条件失效；学习条件不可判定时则保留现状，避免把未知当成不合格。
            let reason: String
            if !activeRevisionIDs.contains(grant.ruleRevisionID) {
                reason = "发放依据的规则版本已失效，未使用奖励已取消。"
            } else {
                guard !undecidableRevisionIDs.contains(grant.ruleRevisionID) else { continue }
                guard !eligibleRevisionIDs.contains(grant.ruleRevisionID) else { continue }
                let revokedBasisStillPresent = grant.basisEventIDs.contains { eventID in
                    working.completionEvents.contains { $0.id == eventID && $0.isRevoked }
                }
                reason = revokedBasisStillPresent
                    ? "相关学习记录已撤销，未使用奖励已取消。"
                    : "当前学习条件已不再满足，未使用奖励已取消。"
            }
            guard let revoked = grant.revoked(at: context.now, reason: reason) else { continue }
            working.rewardGrants[index] = revoked
            mutations.append(PlanStoreMutation(kind: .upsertRewardGrant, entityID: revoked.id, summary: "撤销失去资格的未使用奖励"))
        }

        for grant in evaluation.pendingGrants {
            guard let inserted = working.insertingRewardGrant(grant) else { continue }
            working = inserted
            mutations.append(
                PlanStoreMutation(kind: .upsertRewardGrant, entityID: grant.id, summary: "发放娱乐奖励：\(grant.ruleSnapshot.name)")
            )
            insertedGrantCount += 1
        }

        let message: String
        if insertedGrantCount > 0 {
            message = "获得 \(insertedGrantCount) 项娱乐奖励待领取。"
        } else if !evaluation.undecidableRuleRevisionIDs.isEmpty {
            message = RewardEligibilityGuard.undecidableExplanation(for: dayKey)
        } else {
            message = ""
        }
        return RewardApplication(state: working, mutations: mutations, statusMessage: message)
    }

    // MARK: 通知意图

    /// 为一份计划产出通知意图：先取消旧提醒，再只安排有限的近期提醒。
    func reminderChanges(
        for plan: DailyStudyPlan,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> [ReminderChangeRequest] {
        var requests: [ReminderChangeRequest] = [ReminderChangeRequest(action: .cancelAll)]

        let upcoming = plan.items
            .filter { $0.status == .pending || $0.status == .inProgress }
            .compactMap { item -> (item: DailyPlanItem, fireDate: Date)? in
                guard let start = item.scheduledStart, start > context.now else { return nil }
                return (item, start)
            }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(maximumScheduledReminders)

        for entry in upcoming {
            requests.append(
                ReminderChangeRequest(
                    action: .schedule,
                    planItemID: entry.item.id,
                    fireDate: entry.fireDate,
                    title: entry.item.title
                )
            )
        }

        // 没有可用的具体时间但有未完成任务时，只发一条汇总提醒，不做集中轰炸。
        let hasPending = plan.items.contains { $0.status == .pending || $0.status == .inProgress }
        if upcoming.isEmpty, hasPending {
            requests.append(
                ReminderChangeRequest(
                    action: .schedule,
                    planItemID: nil,
                    fireDate: nextUsableReminderDate(state: state, context: context),
                    title: "今天还有任务待完成"
                )
            )
        }

        return requests
    }

    /// 下一个可用提醒时间：避开课程、睡眠与固定占用。
    func nextUsableReminderDate(
        state: StoreSnapshot,
        context: PlanningContext,
        preferredHour: Int? = nil,
        searchLimitMinutes: Int = 24 * 60
    ) -> Date {
        let hour = min(max(preferredHour ?? state.settings.defaultReminderHour, 0), 23)
        let dayStart = context.calendar.startOfDay(for: context.now)
        var candidate = context.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart) ?? context.now
        if candidate <= context.now {
            candidate = context.calendar.date(byAdding: .minute, value: 30, to: context.now) ?? context.now
        }

        var remaining = searchLimitMinutes
        while remaining > 0 {
            if !Self.isProtected(candidate, state: state, context: context) {
                return candidate
            }
            guard let next = context.calendar.date(byAdding: .minute, value: 15, to: candidate) else { break }
            candidate = next
            remaining -= 15
        }
        return candidate
    }

    /// 该时刻是否落在课程 / 睡眠 / 固定占用里。
    static func isProtected(_ date: Date, state: StoreSnapshot, context: PlanningContext) -> Bool {
        let calendar = context.calendar
        let dayStart = calendar.startOfDay(for: date)

        // 前一天跨午夜的区间。
        for offset in [-1, 0] {
            guard let anchor = calendar.date(byAdding: .day, value: offset, to: dayStart) else { continue }
            let ranges = protectedRanges(state: state, on: anchor, context: context)
            if ranges.contains(where: { date >= $0.start && date < $0.end }) { return true }
        }

        let schedule = state.scheduleForComputation
        let occurrences = ScheduleResolver.planningDay(for: dayStart, schedule: schedule, context: context).courses
        return occurrences.contains { !$0.isCancelled && date >= $0.start && date < $0.end }
    }

    private static func protectedRanges(
        state: StoreSnapshot,
        on dayStart: Date,
        context: PlanningContext
    ) -> [(start: Date, end: Date)] {
        let calendar = context.calendar
        let weekday = weekday(of: dayStart, calendar: calendar)
        let routine = state.availabilityPreferences.routine
        let ranges = (routine.sleepWindows + routine.customBlocks).filter { $0.weekday == weekday }
        return ranges.compactMap { range in
            guard let start = calendar.date(byAdding: .minute, value: range.start.minutes, to: dayStart),
                  let end = calendar.date(byAdding: .minute, value: range.end.minutes + range.endDayOffset * 24 * 60, to: dayStart),
                  end > start else { return nil }
            return (start, end)
        }
    }

    // MARK: 小工具

    static func activePlan(in state: StoreSnapshot, dayKey: StudyDayKey) -> DailyStudyPlan? {
        state.dailyPlans.first { $0.dayKey == dayKey && $0.isActive }
    }

    /// 把会话引擎产出的完成事件校正为"引擎更新后"的会话状态。
    ///
    /// 会话引擎返回的完成事件基于更新后的会话；但实际完成范围与有效时长必须以
    /// 落定后的会话（`progress`、`endedAt`）为准，否则会丢掉本次会话累计的进度。
    ///
    /// 纯函数：不写文件、不发通知、不改全局状态。幂等键仍由会话 ID 派生，
    /// 因此重复提交依然不会产生第二条完成记录。
    static func finalizingCompletion(
        _ completion: CompletionEvent,
        session: StudySession?,
        minimumScope: StudyScope?,
        context: PlanningContext
    ) -> CompletionEvent {
        guard let session else { return completion }

        let completedScope = session.progress.isPositive ? session.progress : completion.completedScope
        let minutes = session.effectiveMinutes(asOf: completion.completedAt, calendar: context.calendar)
        let planItemID = completion.planItemID ?? session.planItemID

        // 统一去重键（需求 2）：同一条计划任务无论从"首页会话"还是"列表直接完成"
        // 哪条路径提交，都落到同一个幂等键上，因此不会重复计数、不会重复推进 SM-2。
        // 只有确实没有计划项的会话才退化为按会话 ID 去重。
        let key = planItemID.map { CompletionEvent.Key.planItem($0, dayKey: completion.dayKey) }

        return CompletionEvent.make(
            sessionID: session.id,
            planID: completion.planID ?? session.planID,
            planItemID: planItemID,
            dayKey: completion.dayKey,
            source: completion.source,
            plannedScope: completion.plannedScope,
            minimumScope: minimumScope,
            completedScope: completedScope,
            actualMinutes: max(0, minutes),
            durationSource: .timed,
            completedAt: completion.completedAt,
            assessment: completion.assessment ?? session.assessment,
            note: completion.note,
            createdAt: completion.createdAt,
            idempotencyKey: key
        )
    }

    /// 两条计划的内容是否等价（用于"重复调用不重复执行"）。
    ///
    /// 只比较**会影响用户看到的内容**的字段：任务 ID、状态、范围与分钟、顺序，
    /// 以及总预算分钟。版本号、时间戳、解释文案不参与比较。
    static func isContentEquivalent(_ lhs: DailyStudyPlan, _ rhs: DailyStudyPlan) -> Bool {
        guard lhs.items.count == rhs.items.count else { return false }
        guard lhs.plannedMinutesFromItems == rhs.plannedMinutesFromItems else { return false }
        for (left, right) in zip(lhs.items, rhs.items) {
            if left.id != right.id { return false }
            if left.status != right.status { return false }
            if left.plannedScope != right.plannedScope { return false }
            if left.estimatedMinutes != right.estimatedMinutes { return false }
        }
        return true
    }

    /// 规划时区下的星期几。
    static func weekday(of date: Date, calendar: Calendar) -> ScheduleWeekday {
        ScheduleWeekday(calendarWeekday: calendar.component(.weekday, from: date)) ?? .monday
    }

    static func upserting(_ plan: DailyStudyPlan, in state: inout StoreSnapshot) {
        if let index = state.dailyPlans.firstIndex(where: { $0.id == plan.id }) {
            state.dailyPlans[index] = plan
        } else {
            state.dailyPlans.append(plan)
        }
        state.dailyPlans.sort {
            if $0.dayKey != $1.dayKey { return $0.dayKey < $1.dayKey }
            if $0.version != $1.version { return $0.version < $1.version }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func upserting(_ session: StudySession, in state: inout StoreSnapshot) {
        if let index = state.studySessions.firstIndex(where: { $0.id == session.id }) {
            state.studySessions[index] = session
        } else {
            state.studySessions.append(session)
        }
        state.studySessions.sort { $0.startedAt < $1.startedAt }
    }

    static func updatingItem(
        _ itemID: UUID,
        in state: inout StoreSnapshot,
        now: Date,
        transform: (inout DailyPlanItem) -> Void
    ) {
        for planIndex in state.dailyPlans.indices {
            guard let itemIndex = state.dailyPlans[planIndex].items.firstIndex(where: { $0.id == itemID }) else { continue }
            transform(&state.dailyPlans[planIndex].items[itemIndex])
            return
        }
    }

    static func missingModuleResult(_ state: StoreSnapshot, module: String) -> PlanCoordinationResult {
        let detail = "\(module)尚未接入，本次操作没有修改任何数据。"
        return PlanCoordinationResult(
            snapshot: state,
            statusMessage: detail,
            didChange: false,
            rejection: .missingSourceData(detail)
        )
    }
}
