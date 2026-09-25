import Foundation

// MARK: - 公共接口契约（模块 A 定稿）
//
// 本文件只声明接口与输入/输出值类型，不含任何文件读写、通知发送或
// 全局状态修改。实现方（其他模块）按下面的职责提供纯函数实现：
//
// | 契约接口            | 本文件中的名字            | 输入                                   | 输出                       |
// |---------------------|---------------------------|----------------------------------------|----------------------------|
// | ScheduleResolver    | `ScheduleResolving`       | 课表、例外、日期范围                   | 实际课程实例               |
// | AvailabilityCalculator | `AvailabilityCalculating` | 课程、作息、当前时间                 | 空闲时间段、扣除原因       |
// | DailyPlanEngine     | `DailyPlanEngine`         | 时间容量、任务候选、已有计划、完成记录 | 计划提案、无法安排项、解释 |
// | MinimumPlanPolicy   | `MinimumPlanPolicy`       | 当前计划、剩余时间、可拆分范围         | 轻量/保底提案、变更明细    |
// | StudySessionEngine  | `StudySessionEngine`      | 会话状态、操作事件                     | 新会话状态、可选完成事件   |
// | RewardEvaluator     | `RewardEvaluator`         | 规则、计划、完成事件、奖励记录         | 条件进度、资格、待发放奖励 |
// | DailyPlanCoordinator| `DailyPlanCoordinator`    | 用户操作或刷新事件                     | 统一提交状态、保存并提醒   |
//
// `ScheduleResolver` 与 `AvailabilityCalculator` 已由课表模块实现为具体命名空间，
// 这里通过 extension 让它们满足契约，不重复实现算法。

// MARK: - 课表

/// 课表解析接口：输入课表 + 例外 + 日期范围，输出实际课程实例。
protocol ScheduleResolving {
    /// 某一天实际发生的课程实例（已应用停课/换课/补课）。
    static func occurrences(
        on date: Date,
        schedule: ScheduleSnapshot,
        context: PlanningContext
    ) -> [ResolvedCourseOccurrence]

    /// 日期范围内每一天实际发生的课程实例，按时间升序。
    static func occurrences(
        in range: DateInterval,
        schedule: ScheduleSnapshot,
        context: PlanningContext
    ) -> [ResolvedCourseOccurrence]

    /// 某一天的完整解析结果（含占用块与说明）。
    static func planningDay(
        for date: Date,
        schedule: ScheduleSnapshot,
        context: PlanningContext
    ) -> ScheduleDay
}

extension ScheduleResolver: ScheduleResolving {
    static func occurrences(
        on date: Date,
        schedule: ScheduleSnapshot,
        context: PlanningContext
    ) -> [ResolvedCourseOccurrence] {
        planningDay(for: date, schedule: schedule, context: context).courses
    }

    static func occurrences(
        in range: DateInterval,
        schedule: ScheduleSnapshot,
        context: PlanningContext
    ) -> [ResolvedCourseOccurrence] {
        guard range.end > range.start else { return [] }
        var results: [ResolvedCourseOccurrence] = []
        var day = scheduleStartOfDay(range.start, context: context)
        while day < range.end {
            results.append(contentsOf: planningDay(for: day, schedule: schedule, context: context).courses)
            guard let next = context.calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return results.sorted { $0.start < $1.start }
    }

    static func planningDay(
        for date: Date,
        schedule: ScheduleSnapshot,
        context: PlanningContext
    ) -> ScheduleDay {
        // 一律使用快照的学期时区解析，避免设备时区变化让星期错位。
        ScheduleResolver.day(
            for: date,
            semester: schedule.semester,
            courses: schedule.courses,
            exceptions: schedule.exceptions
        )
    }

    private static func scheduleStartOfDay(_ date: Date, context: PlanningContext) -> Date {
        context.calendar.startOfDay(for: date)
    }
}

// MARK: - 可用时间

/// 可用时间计算接口：输入课程、作息与当前时间，输出空闲时间段与扣除原因。
protocol AvailabilityCalculating {
    static func availability(
        on date: Date,
        schedule: ScheduleSnapshot,
        preferences: AvailabilityPreferences,
        now: Date?
    ) -> AvailabilityDay
}

extension AvailabilityCalculator: AvailabilityCalculating {
    static func availability(
        on date: Date,
        schedule: ScheduleSnapshot,
        preferences: AvailabilityPreferences,
        now: Date?
    ) -> AvailabilityDay {
        AvailabilityCalculator.availability(
            on: date,
            semester: schedule.semester,
            courses: schedule.courses,
            exceptions: schedule.exceptions,
            settings: preferences.routine,
            now: now
        )
    }
}

// MARK: - 计划生成

/// 任务候选：进入计划生成器的原始输入。标题必须来自真实数据。
struct PlanCandidate: Hashable {
    var source: DailyPlanItemSource
    var title: String
    var plannedScope: StudyScope
    /// 保底范围；`nil` 表示不可减量。
    var minimumScope: StudyScope?
    var estimatedMinutes: Int
    /// 任务到期日期（与安排日期无关）。
    var dueDate: Date?
    var isPinned: Bool
    var isSplittable: Bool
    var note: String
    /// 期望开始时间（例如课程结束后）；`nil` 表示由引擎决定。
    var preferredStart: Date?

    init(
        source: DailyPlanItemSource,
        title: String,
        plannedScope: StudyScope,
        minimumScope: StudyScope? = nil,
        estimatedMinutes: Int,
        dueDate: Date? = nil,
        isPinned: Bool = false,
        isSplittable: Bool = false,
        note: String = "",
        preferredStart: Date? = nil
    ) {
        self.source = source
        self.title = title
        self.plannedScope = plannedScope
        self.minimumScope = minimumScope
        self.estimatedMinutes = max(0, estimatedMinutes)
        self.dueDate = dueDate
        self.isPinned = isPinned
        self.isSplittable = isSplittable
        self.note = note
        self.preferredStart = preferredStart
    }
}

struct DailyPlanRequest {
    var dayKey: StudyDayKey
    var context: PlanningContext
    /// 当天可安排容量（来自 `AvailabilityCalculating`）。
    var availability: AvailabilityDay?
    var preferences: AvailabilityPreferences
    var candidates: [PlanCandidate]
    var existingPlans: [DailyStudyPlan]
    var completions: [CompletionEvent]
    /// 输入指纹：指纹相同 → 重复生成，引擎应当复用已有计划。
    var inputFingerprint: String

    init(
        dayKey: StudyDayKey,
        context: PlanningContext,
        availability: AvailabilityDay?,
        preferences: AvailabilityPreferences,
        candidates: [PlanCandidate],
        existingPlans: [DailyStudyPlan] = [],
        completions: [CompletionEvent] = [],
        inputFingerprint: String = ""
    ) {
        self.dayKey = dayKey
        self.context = context
        self.availability = availability
        self.preferences = preferences
        self.candidates = candidates
        self.existingPlans = existingPlans
        self.completions = completions
        self.inputFingerprint = inputFingerprint
    }

    /// 当天已生效的计划（同一天只应有一个 active）。
    var activePlan: DailyStudyPlan? {
        existingPlans.first { $0.dayKey == dayKey && $0.isActive }
    }
}

/// 计划提案。
struct DailyPlanProposal {
    var plan: DailyStudyPlan
    var unplaceable: [UnplaceablePlanItem]
    var explanation: DailyPlanExplanation
    /// 是否复用了已有计划（输入指纹相同，没有重建）。
    var didReuseExistingPlan: Bool

    init(
        plan: DailyStudyPlan,
        unplaceable: [UnplaceablePlanItem] = [],
        explanation: DailyPlanExplanation = DailyPlanExplanation(),
        didReuseExistingPlan: Bool = false
    ) {
        self.plan = plan
        self.unplaceable = unplaceable
        self.explanation = explanation
        self.didReuseExistingPlan = didReuseExistingPlan
    }
}

/// 计划生成接口。
///
/// 纯计算：不写文件、不发通知、不修改全局状态；结果由 G 的
/// `DailyPlanCoordinator` 统一提交。
protocol DailyPlanEngine {
    func proposePlan(_ request: DailyPlanRequest) -> DailyPlanProposal
}

// MARK: - 最低任务

enum MinimumPlanChangeKind: String, Codable, CaseIterable, Sendable {
    /// 缩小任务范围（保留最小可交付量）。
    case trimmed
    /// 当天移除（不写入计划）。
    case removed
    /// 顺延到后续日期。
    case deferred
    /// 原样保留。
    case kept
    /// 整体降级为保底档。
    case convertedToMinimum

    var label: String {
        switch self {
        case .trimmed: return "缩小范围"
        case .removed: return "当天移除"
        case .deferred: return "顺延"
        case .kept: return "保留"
        case .convertedToMinimum: return "降为保底"
        }
    }
}

/// 减量的单条变更明细。
struct MinimumPlanChange: Identifiable, Hashable, Sendable {
    var id: UUID
    var itemID: UUID
    var title: String
    var kind: MinimumPlanChangeKind
    var beforeScope: StudyScope?
    var afterScope: StudyScope?
    var beforeMinutes: Int
    var afterMinutes: Int
    var reason: String

    init(
        id: UUID = UUID(),
        itemID: UUID,
        title: String,
        kind: MinimumPlanChangeKind,
        beforeScope: StudyScope? = nil,
        afterScope: StudyScope? = nil,
        beforeMinutes: Int = 0,
        afterMinutes: Int = 0,
        reason: String = ""
    ) {
        self.id = id
        self.itemID = itemID
        self.title = title
        self.kind = kind
        self.beforeScope = beforeScope
        self.afterScope = afterScope
        self.beforeMinutes = max(0, beforeMinutes)
        self.afterMinutes = max(0, afterMinutes)
        self.reason = reason
    }
}

/// 轻量 / 保底提案。
struct MinimumPlanProposal {
    var plan: DailyStudyPlan
    var changes: [MinimumPlanChange]
    var explanation: DailyPlanExplanation
    /// 剩余时间不足以安排任何保底任务时为 `true`。
    var isEmpty: Bool

    init(
        plan: DailyStudyPlan,
        changes: [MinimumPlanChange] = [],
        explanation: DailyPlanExplanation = DailyPlanExplanation(),
        isEmpty: Bool = false
    ) {
        self.plan = plan
        self.changes = changes
        self.explanation = explanation
        self.isEmpty = isEmpty
    }
}

/// 最低任务策略：输入当前计划、剩余时间、可拆分范围，输出保底提案与变更明细。
protocol MinimumPlanPolicy {
    func reduce(
        plan: DailyStudyPlan,
        remainingMinutes: Int,
        splittableItemIDs: Set<UUID>,
        context: PlanningContext
    ) -> MinimumPlanProposal
}

// MARK: - 学习会话

/// 会话所绑定的计划项上下文（构建完成事件所需的全部真实信息）。
struct PlanItemSessionContext: Hashable, Sendable {
    var planID: UUID?
    var planItemID: UUID
    var dayKey: StudyDayKey
    var source: DailyPlanItemSource
    var title: String
    var plannedScope: StudyScope
    var minimumScope: StudyScope?

    init(
        planID: UUID? = nil,
        planItemID: UUID,
        dayKey: StudyDayKey,
        source: DailyPlanItemSource,
        title: String,
        plannedScope: StudyScope,
        minimumScope: StudyScope? = nil
    ) {
        self.planID = planID
        self.planItemID = planItemID
        self.dayKey = dayKey
        self.source = source
        self.title = title
        self.plannedScope = plannedScope
        self.minimumScope = minimumScope
    }

    init?(item: DailyPlanItem) {
        self.init(
            planID: item.planID,
            planItemID: item.id,
            dayKey: item.scheduledDayKey,
            source: item.source,
            title: item.title,
            plannedScope: item.plannedScope,
            minimumScope: item.minimumScope
        )
    }
}

/// 会话状态迁移结果。
struct StudySessionTransition {
    var session: StudySession?
    var completionEvent: CompletionEvent?
    var rejection: StudySessionRejection?

    init(
        session: StudySession? = nil,
        completionEvent: CompletionEvent? = nil,
        rejection: StudySessionRejection? = nil
    ) {
        self.session = session
        self.completionEvent = completionEvent
        self.rejection = rejection
    }

    var didChange: Bool { session != nil }
    var producedCompletion: Bool { completionEvent != nil }
}

/// 学习会话接口：输入会话状态与操作事件，输出新状态与可选完成事件。
protocol StudySessionEngine {
    func apply(
        _ event: StudySessionEvent,
        to session: StudySession?,
        item: PlanItemSessionContext?,
        context: PlanningContext
    ) -> StudySessionTransition
}

// MARK: - 奖励评估

/// 奖励评估结果。
struct RewardEvaluation {
    /// 每条生效规则的条件进度。
    var progress: [RewardConditionProgress]
    /// 已达标（可发放）的规则版本 ID。
    var eligibleRuleRevisionIDs: [UUID]
    /// 评估出、尚未写入存储的待发放奖励。
    var pendingGrants: [RewardGrant]
    /// 因为数据不足而无法判定的规则版本 ID（例如只有旧版本每日总数）。
    var undecidableRuleRevisionIDs: [UUID]
    var explanation: [String]

    init(
        progress: [RewardConditionProgress] = [],
        eligibleRuleRevisionIDs: [UUID] = [],
        pendingGrants: [RewardGrant] = [],
        undecidableRuleRevisionIDs: [UUID] = [],
        explanation: [String] = []
    ) {
        self.progress = progress
        self.eligibleRuleRevisionIDs = eligibleRuleRevisionIDs
        self.pendingGrants = pendingGrants
        self.undecidableRuleRevisionIDs = undecidableRuleRevisionIDs
        self.explanation = explanation
    }
}

/// 奖励评估接口：输入规则、计划、完成事件、奖励记录，
/// 输出条件进度、资格与待发放奖励。
protocol RewardEvaluator {
    func evaluate(
        rules: [EntertainmentRule],
        plan: DailyStudyPlan?,
        completions: [CompletionEvent],
        grants: [RewardGrant],
        summary: DailyStudySummary,
        context: PlanningContext
    ) -> RewardEvaluation
}

/// 资格判定保护：旧版本的"每日完成总数"不能推导娱乐资格。
enum RewardEligibilityGuard {
    static func isDecidable(summary: DailyStudySummary) -> Bool {
        summary.source != .legacyAggregate
    }

    /// 无法判定时的说明文案。
    static func undecidableExplanation(for dayKey: StudyDayKey) -> String {
        "\(dayKey.localDateString) 只有旧版本的每日完成总数，缺少任务明细与学习时长，无法判定娱乐资格。"
    }
}

// MARK: - 统一提交

/// 用户操作或刷新事件。
enum PlanCoordinationEvent: Hashable, Sendable {
    case refresh(dayKey: StudyDayKey)
    case regeneratePlan(dayKey: StudyDayKey, force: Bool)
    case startSession(planItemID: UUID)
    case pauseSession(sessionID: UUID)
    case resumeSession(sessionID: UUID)
    case finishSession(sessionID: UUID, scope: StudyScope?, assessment: StudyAssessment?, note: String)
    case completeItemDirectly(planItemID: UUID, scope: StudyScope, minutes: Int, assessment: StudyAssessment?, note: String)
    /// 采用减量 / 保底 / 休息方案。
    ///
    /// `expectedPlanID` / `expectedVersion` 是**预览身份**：界面拿旧预览点应用时，
    /// 协调器会拒绝而不是悄悄应用成另一个方案。
    case applyMinimumPlan(
        dayKey: StudyDayKey,
        remainingMinutes: Int,
        expectedPlanID: UUID?,
        expectedVersion: Int?
    )
    /// 撤销最近一次减量，恢复到减量前的计划内容。
    case undoMinimumPlan(dayKey: StudyDayKey)
    case revokeCompletion(completionID: UUID, reason: String)
    case claimReward(grantID: UUID)
    case startReward(grantID: UUID)
    case finishReward(grantID: UUID, usedMinutes: Int)
}

/// 需要 G 落盘的写入意图。算法只产出意图，不直接写文件。
struct PlanStoreMutation: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case upsertPlan
        case removePlan
        case upsertSession
        case insertCompletion
        case updateCompletion
        case upsertRewardGrant
        case updatePreferences
    }

    var id: UUID
    var kind: Kind
    var entityID: UUID
    var summary: String

    init(id: UUID = UUID(), kind: Kind, entityID: UUID, summary: String = "") {
        self.id = id
        self.kind = kind
        self.entityID = entityID
        self.summary = summary
    }
}

/// 通知意图的类型。
///
/// 显式类型决定稳定标识的前缀：同一条提醒只有**一套**身份，
/// 不再出现"排程用标题哈希、取消用业务 ID"这种互相抵消的做法。
enum ReminderKind: String, Codable, CaseIterable, Sendable {
    /// 计划项提醒。
    case planItem
    /// 当天剩余任务的汇总提醒。
    case dailySummary
    /// 复习任务提醒（没有今日计划时的兜底）。
    case reviewTask
    /// 娱乐计时到期提醒（统一绑定 `grantID`）。
    case entertainmentEnd

    /// 该类型受统一管理的前缀。
    var identifierPrefix: String { "study.\(rawValue)." }
}

/// 需要 G 应用的通知变更意图（不把系统通知类型写进持久化模型）。
struct ReminderChangeRequest: Identifiable, Hashable, Sendable {
    enum Action: String, Codable, Sendable {
        case schedule
        case cancel
        case cancelAll
    }

    var id: UUID
    var action: Action
    var planItemID: UUID?
    var fireDate: Date?
    var title: String
    /// 意图类型。
    var kind: ReminderKind
    /// 稳定业务 ID（计划项 ID / 学习日 / 复习任务 ID / 奖励 grantID）。
    var businessID: String

    init(
        id: UUID = UUID(),
        action: Action,
        planItemID: UUID? = nil,
        fireDate: Date? = nil,
        title: String = "",
        kind: ReminderKind = .dailySummary,
        businessID: String = ""
    ) {
        self.id = id
        self.action = action
        self.planItemID = planItemID
        self.fireDate = fireDate
        self.title = title
        self.kind = kind
        self.businessID = businessID
    }

    /// 稳定的系统通知标识：同一业务对象在多次同步后仍是同一个 ID。
    var stableIdentifier: String { kind.identifierPrefix + businessID }
}

/// 把一次通知同步的业务意图归并成确定性的系统操作，便于无系统通知副作用地验证。
struct ReminderBatch: Sendable {
    var cancelsAllManaged: Bool
    var cancelledIdentifiers: [String]
    var scheduledChanges: [String: ReminderChangeRequest]

    static func make(from changes: [ReminderChangeRequest]) -> ReminderBatch {
        var cancelled = Set<String>()
        var scheduled: [String: ReminderChangeRequest] = [:]
        var cancelsAllManaged = false

        for change in changes {
            let businessID = change.businessID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !businessID.isEmpty || change.action == .cancelAll else { continue }
            let identifier = change.stableIdentifier

            switch change.action {
            case .cancelAll:
                cancelsAllManaged = true
            case .cancel:
                cancelled.insert(identifier)
            case .schedule:
                scheduled[identifier] = change
            }
        }

        // 只要这一批明确取消了某条提醒，该标识就不会被同批的 schedule 重新安排。
        for identifier in cancelled {
            scheduled.removeValue(forKey: identifier)
        }

        return ReminderBatch(
            cancelsAllManaged: cancelsAllManaged,
            cancelledIdentifiers: cancelled.sorted(),
            scheduledChanges: scheduled
        )
    }
}

/// 重复操作的类型化原因。
enum PlanCoordinationRejection: Hashable, Sendable {
    case duplicateCompletion(ignoredKey: String)
    case duplicateRewardClaim(grantID: UUID)
    case unknownPlanItem(UUID)
    case unknownSession(UUID)
    case unknownRewardGrant(UUID)
    case noPlan(dayKey: StudyDayKey)
    case missingSourceData(String)
    case invalidState(String)
    /// 奖励资格已失效（规则被改/停用，或已撤销）。
    case rewardNotEligible(String)
    /// 奖励不属于当前可用日期。
    case rewardNotUsableToday(String)
    /// 奖励已过期。
    case rewardExpired(grantID: UUID)
    /// 奖励已经使用完毕。
    case rewardAlreadyUsed(grantID: UUID)
    /// 已经有另一个娱乐计时在进行中。
    case anotherRewardRunning(grantID: UUID)

    var message: String {
        switch self {
        case .duplicateCompletion: return "这次完成已经有记录，未重复保存。"
        case .duplicateRewardClaim: return "奖励已经领取过，未重复发放。"
        case .unknownPlanItem: return "找不到对应的计划任务。"
        case .unknownSession: return "找不到对应的学习会话。"
        case .unknownRewardGrant: return "找不到对应的奖励记录。"
        case .noPlan: return "当天还没有计划。"
        case .missingSourceData(let detail): return "缺少来源数据：\(detail)"
        case .invalidState(let detail): return "当前状态不允许该操作：\(detail)"
        case .rewardNotEligible(let detail): return "这条奖励的资格已经失效：\(detail)"
        case .rewardNotUsableToday(let detail): return "这条奖励今天不可用：\(detail)"
        case .rewardExpired: return "这条奖励已经过期，不能再用。"
        case .rewardAlreadyUsed: return "这条奖励已经使用完毕。"
        case .anotherRewardRunning: return "已经有一个娱乐计时在进行中，请先结束它，再开始新的。"
        }
    }
}

/// 统一提交结果。
///
/// `snapshot` 是新的内存状态；`mutations` 与 `reminderChanges` 是交给 G 的意图。
/// 算法本身不落盘、不发通知。
struct PlanCoordinationResult {
    var snapshot: StoreSnapshot
    var mutations: [PlanStoreMutation]
    var reminderChanges: [ReminderChangeRequest]
    var statusMessage: String
    var didChange: Bool
    var rejection: PlanCoordinationRejection?

    init(
        snapshot: StoreSnapshot,
        mutations: [PlanStoreMutation] = [],
        reminderChanges: [ReminderChangeRequest] = [],
        statusMessage: String = "",
        didChange: Bool = false,
        rejection: PlanCoordinationRejection? = nil
    ) {
        self.snapshot = snapshot
        self.mutations = mutations
        self.reminderChanges = reminderChanges
        self.statusMessage = statusMessage
        self.didChange = didChange
        self.rejection = rejection
    }
}

/// 统一提交接口：首页、今日计划、娱乐资格、报告共用同一份计划与完成事件。
protocol DailyPlanCoordinator {
    func coordinate(_ event: PlanCoordinationEvent, state: StoreSnapshot, context: PlanningContext) -> PlanCoordinationResult
}

// MARK: - 日汇总计算（统一状态来源的读侧）

extension StoreSnapshot {
    /// 某个学习日的学习汇总。
    ///
    /// 统一状态来源规则：
    /// - 有完成事件 → `recordedEvents`，时长与任务数都来自事件；
    /// - 只有旧版本每日总数 → `legacyAggregate`，只保留 `completedTaskCount`，
    ///   不给时长、不给任务明细、不给娱乐资格；
    /// - 都没有 → `none`，且 `isEntertainmentEligible == false`（明确"不达标"，
    ///   而不是"未知"）。
    func dailySummary(for dayKey: StudyDayKey) -> DailyStudySummary {
        let dayEvents = completionEvents.filter { $0.dayKey == dayKey && !$0.isRevoked }
        let plan = dailyPlans.first { $0.dayKey == dayKey && $0.isActive }
            ?? dailyPlans.filter { $0.dayKey == dayKey }.max { $0.version < $1.version }
        let legacyCount = dailyActivityRecords
            .first { $0.dateString == Self.legacyDateString(for: dayKey) }?
            .completedTaskCount

        guard !dayEvents.isEmpty else {
            if let legacyCount, legacyCount > 0 {
                return DailyStudySummary(
                    dayKey: dayKey,
                    source: .legacyAggregate,
                    legacyCompletedTaskCount: legacyCount,
                    isEntertainmentEligible: nil,
                    planID: plan?.id,
                    planMode: plan?.mode,
                    explanation: "该学习日只有旧版本记录的完成总数（\(legacyCount) 项），没有任务明细与学习时长，因此不推算时长与娱乐资格。"
                )
            }
            return DailyStudySummary(
                dayKey: dayKey,
                source: .none,
                isEntertainmentEligible: false,
                planID: plan?.id,
                planMode: plan?.mode,
                explanation: "该学习日没有学习记录。"
            )
        }

        let standard = dayEvents.filter { $0.tier == .standard }.count
        let minimum = dayEvents.filter { $0.tier == .minimum }.count
        let studied = dayEvents.filter { $0.tier == .studied }.count
        // 只统计"已记录时长"的事件：未记录时长的完成仍然是完成，
        // 但绝不能凭空贡献分钟数（时长类奖励只看这里）。
        let minutes = dayEvents
            .filter { $0.durationSource.contributesRecordedMinutes }
            .reduce(0) { $0 + $1.actualMinutes }
        let unrecorded = dayEvents.filter { !$0.durationSource.contributesRecordedMinutes }.count
        return DailyStudySummary(
            dayKey: dayKey,
            source: .recordedEvents,
            standardCompletedItemCount: standard,
            minimumCompletedItemCount: minimum,
            studiedItemCount: studied,
            recordedMinutes: minutes,
            unrecordedDurationItemCount: unrecorded,
            legacyCompletedTaskCount: legacyCount,
            isEntertainmentEligible: (standard + minimum) > 0,
            planID: plan?.id,
            planMode: plan?.mode,
            explanation: unrecorded > 0
                ? "已完成：标准 \(standard) 项、保底 \(minimum) 项、已学习 \(studied) 项，记录时长 \(minutes) 分钟（另有 \(unrecorded) 项未记录时长，不计入时长）。"
                : "已完成：标准 \(standard) 项、保底 \(minimum) 项、已学习 \(studied) 项，记录时长 \(minutes) 分钟。"
        )
    }

    /// 旧数据 `DailyActivityRecord.dateString` 使用系统日历；这里按同一口径对齐。
    static func legacyDateString(for dayKey: StudyDayKey) -> String {
        dayKey.localDateString
    }
}
