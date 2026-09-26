import Foundation

// MARK: - F 模块：首页与一级导航的纯展示决策
//
// 本文件只依赖 Foundation 与公共数据契约（A 的模型、B 的可用时间结果），
// 不含 SwiftUI、不读写文件、不发通知、不修改全局状态。
//
// 目的（公共约束 13 / 14）：把"首页显示什么、主按钮做什么"从视图里抽出来，
// 让业务行为能在源码目标目录之外被 `script/verify_dashboard_flow.swift` 直接编译验证。
//
// 时间一律来自外部传入的 `now` / `PlanningContext`，这里不调用 `Date()`。

// MARK: - 一级入口

/// 五个一级入口：今日 / 计划 / 资料 / 答疑 / 我的。
///
/// iOS 用原生 `TabView` 呈现，macOS 侧栏按同样分组组织；
/// 具体分组（哪个 `AppSection` 属于哪个入口）由视图层用穷举 switch 映射，
/// 保证新增页面时编译器会提醒补全，而不是在这里维护字符串表。
enum StudyPrimarySection: String, CaseIterable, Identifiable, Sendable {
    case today
    case plan
    case library
    case chat
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今日"
        case .plan: return "计划"
        case .library: return "资料"
        case .chat: return "答疑"
        case .profile: return "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "sun.max"
        case .plan: return "calendar.badge.clock"
        case .library: return "books.vertical"
        case .chat: return "bubble.left.and.bubble.right"
        case .profile: return "person.crop.circle"
        }
    }

    /// 兼容旧版 `AppStore.navigateToTab` 的取值，同时接受新入口 id。
    ///
    /// 旧值是内容页名字（`importData` / `reviews` / `more`…），新结构下
    /// 它们分别落到对应的一级入口；真正"打开哪一页"由 `navigateToSection` 决定。
    static func resolvingLegacyTabID(_ raw: String) -> StudyPrimarySection? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = StudyPrimarySection(rawValue: trimmed) { return direct }
        switch trimmed {
        case "dashboard": return .today
        case "reviews", "calendarPlan", "examSprint", "examGoals", "pastTasks", "planningHome", "计划": return .plan
        case "importData", "drafts", "knowledge", "mistakes", "knowledgeGraph", "documentSections": return .library
        case "chat": return .chat
        case "more", "settings", "reportInsights", "entertainmentRules", "娱乐规则": return .profile
        default: return nil
        }
    }
}

// MARK: - 计划强度（文字优先，不靠颜色区分）

/// 标准 / 轻量 / 保底。
///
/// 契约里 `DailyPlanMode.reduced` 是"自动减量"；界面上统一叫**轻量**，
/// 与"保底"（`minimum`）用文字和图标双重区分，不只靠颜色。
enum StudyPlanIntensity: String, CaseIterable, Sendable {
    case standard
    case light
    case minimum
    case rest
    case none

    var label: String {
        switch self {
        case .standard: return "标准"
        case .light: return "轻量"
        case .minimum: return "保底"
        case .rest: return "休息"
        case .none: return "尚未生成"
        }
    }

    /// 完整说法，用于副标题与无障碍朗读。
    var fullLabel: String {
        switch self {
        case .standard: return "标准计划"
        case .light: return "轻量计划（已减量）"
        case .minimum: return "保底计划"
        case .rest: return "休息（今天不再安排新任务）"
        case .none: return "尚未生成计划"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: return "checkmark.circle"
        case .light: return "arrow.down.right.circle"
        case .minimum: return "shield.lefthalf.filled"
        case .rest: return "moon.zzz"
        case .none: return "circle.dashed"
        }
    }

    static func resolve(mode: DailyPlanMode?) -> StudyPlanIntensity {
        switch mode {
        case .standard: return .standard
        case .reduced: return .light
        case .minimum: return .minimum
        case .rest: return .rest
        case nil: return .none
        }
    }
}

// MARK: - 首页主按钮（整页最多一个）

/// 首页唯一主按钮代表的操作。
enum StudyHomePrimaryAction: Hashable, Sendable {
    case startStudy(itemID: UUID)
    case resumeSession(sessionID: UUID)
    case finishSession(sessionID: UUID)
    case claimReward(grantID: UUID)
    case startReward(grantID: UUID)
    case finishReward(grantID: UUID)
    case none

    var label: String {
        switch self {
        case .startStudy: return "开始学习"
        case .resumeSession: return "继续学习"
        case .finishSession: return "结束学习"
        case .claimReward: return "领取娱乐时间"
        case .startReward: return "开始娱乐"
        case .finishReward: return "结束娱乐"
        case .none: return ""
        }
    }

    var systemImage: String {
        switch self {
        case .startStudy: return "play.fill"
        case .resumeSession: return "play.fill"
        case .finishSession: return "stop.fill"
        case .claimReward: return "gift.fill"
        case .startReward: return "sparkles.tv.fill"
        case .finishReward: return "checkmark.circle.fill"
        case .none: return "circle"
        }
    }

    var isPrimary: Bool {
        if case .none = self { return false }
        return true
    }
}

// MARK: - 任务卡片模型

/// 首页展示的单条任务。只承载真实字段，不生成任何学习内容。
struct StudyHomeTask: Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var sourceLabel: String
    var estimatedMinutes: Int
    var scheduleText: String
    var statusLabel: String
    var tierLabel: String?
    var isPinned: Bool
    /// 到期日与安排日不同（契约要求两者分开表达）。
    var isDueOnAnotherDay: Bool
    var dueText: String?
    var accessibilityText: String
}

// MARK: - 今日概览

/// 今日概览：模式、目标分钟、已完成进度、一句安排原因。
struct StudyHomeOverview: Hashable, Sendable {
    enum State: String, Sendable {
        /// 还没配置课表（也没有今日计划）。
        case noSchedule
        /// 计划引擎尚未接入（G 的如实提示）。
        case engineUnavailable
        /// 有课表/资料，但今天还没有计划。
        case noPlan
        /// 正常计划。
        case planned
        /// 保底（或已减量到保底）模式。
        case minimumMode
        /// 今日目标已完成。
        case goalReached
    }

    var state: State
    var intensity: StudyPlanIntensity
    var stateLabel: String
    var targetMinutes: Int
    var completedMinutes: Int
    /// 是否有时长口径的完成记录（旧版本只有完成总数时为 false）。
    var hasRecordedMinutes: Bool
    var plannedMinutes: Int
    var remainingMinutes: Int
    var standardCount: Int
    var minimumCount: Int
    var studiedCount: Int
    var progressRatio: Double
    var progressText: String
    var completionText: String
    /// 紧凑口径（首屏用）：标准 / 保底 / 已学习 仍然分开表述。
    var completionCompactText: String
    var reasonLine: String
    var noticeLine: String?
    /// 与今天安排直接相关的考试摘要（一行，可选）。
    var examLine: String?
    var accessibilityText: String
}

// MARK: - 接下来做

struct StudyHomeNextSteps: Hashable, Sendable {
    var current: StudyHomeTask?
    /// 后续任务，最多 `upcomingLimit` 条。
    var upcoming: [StudyHomeTask]
    var remainingCount: Int
    var isStudying: Bool
    var isPaused: Bool
    /// 正在学习 / 暂停时的一句话状态（含已用分钟）。
    var sessionStatusText: String?
    var emptyTitle: String
    var emptySubtitle: String

    var isEmpty: Bool { current == nil && !isStudying }
}

// MARK: - 娱乐与休息

struct StudyHomeEntertainment: Hashable, Sendable {
    enum State: String, Sendable {
        /// 已进入睡眠或固定占用时段。
        case restTime
        /// 还没有任何娱乐规则。
        case noRules
        /// 有规则但尚未达标。
        case locked
        /// 已达标、可领取。
        case claimable
        /// 已领取，未开始。
        case claimed
        /// 娱乐进行中。
        case running
        /// 本次娱乐已结束。
        case finished
        /// 未使用奖励因资格失效被撤销。
        case revoked
        /// 未使用奖励超出允许日期。
        case expired
        /// 数据不足无法判定（例如只有旧版本每日总数）。
        case undecidable
    }

    var state: State
    var headline: String
    var detail: String
    /// 条件进度，例如 "1 / 2 项"；评估引擎未接入时为 nil。
    var progressText: String?
    var rewardMinutes: Int
    var remainingMinutes: Int
    var ruleName: String?
    /// 该奖励当时使用的规则版本（历史奖励不随规则编辑改写）。
    var ruleVersionText: String?
    var action: StudyHomePrimaryAction
    var accessibilityText: String
}

// MARK: - 反馈浮层去重

/// 完成反馈闸门：同一触发只播放一次，且同一时刻只允许一个浮层。
///
/// 公共约束 9（重复调用不重复执行）与验收要求"避免多个庆祝浮层同时出现"。
struct StudyHomeFeedbackGate: Sendable, Equatable {
    private(set) var lastHandledTrigger: Int = 0
    private(set) var visibleTrigger: Int?

    init() {}

    /// 是否应当播放这次反馈。
    mutating func begin(trigger: Int) -> Bool {
        guard trigger > 0 else { return false }
        guard trigger > lastHandledTrigger else { return false }
        guard visibleTrigger == nil else { return false }
        lastHandledTrigger = trigger
        visibleTrigger = trigger
        return true
    }

    /// 浮层消失。
    mutating func end(trigger: Int) {
        if visibleTrigger == trigger {
            visibleTrigger = nil
        }
    }

    var isShowingOverlay: Bool { visibleTrigger != nil }
}

// MARK: - 展示计算

enum StudyHomePresenter {

    // MARK: 今日概览

    static func overview(
        plan: DailyStudyPlan?,
        summary: DailyStudySummary,
        isSemesterConfigured: Bool,
        planEngineMessage: String?,
        isModelConfigured: Bool,
        examLine: String? = nil
    ) -> StudyHomeOverview {
        let intensity = StudyPlanIntensity.resolve(mode: plan?.mode ?? summary.planMode)
        let targetMinutes = max(0, plan?.goal.targetMinutes ?? 0)
        let hasRecordedMinutes = summary.recordedMinutes != nil
        let completedMinutes = max(0, summary.recordedMinutes ?? 0)
        let plannedMinutes = max(0, plan?.budget.plannedMinutes ?? plan?.plannedMinutesFromItems ?? 0)
        let remainingMinutes = max(0, targetMinutes - completedMinutes)
        let progressRatio: Double = {
            guard targetMinutes > 0 else { return 0 }
            return min(1, Double(completedMinutes) / Double(targetMinutes))
        }()
        let goalReached = targetMinutes > 0 && completedMinutes >= targetMinutes

        let state: StudyHomeOverview.State
        if goalReached {
            state = .goalReached
        } else if plan == nil {
            if !isSemesterConfigured {
                state = .noSchedule
            } else if planEngineMessage != nil {
                state = .engineUnavailable
            } else {
                state = .noPlan
            }
        } else if intensity == .minimum {
            state = .minimumMode
        } else {
            state = .planned
        }

        return StudyHomeOverview(
            state: state,
            intensity: intensity,
            stateLabel: stateLabel(state: state, intensity: intensity, goalReached: goalReached),
            targetMinutes: targetMinutes,
            completedMinutes: completedMinutes,
            hasRecordedMinutes: hasRecordedMinutes,
            plannedMinutes: plannedMinutes,
            remainingMinutes: remainingMinutes,
            standardCount: summary.standardCompletedItemCount,
            minimumCount: summary.minimumCompletedItemCount,
            studiedCount: summary.studiedItemCount,
            progressRatio: progressRatio,
            progressText: progressText(
                targetMinutes: targetMinutes,
                completedMinutes: completedMinutes,
                hasRecordedMinutes: hasRecordedMinutes,
                summary: summary
            ),
            completionText: completionText(summary: summary),
            completionCompactText: completionCompactText(summary: summary),
            reasonLine: reasonLine(plan: plan, summary: summary),
            noticeLine: noticeLine(
                state: state,
                intensity: intensity,
                isModelConfigured: isModelConfigured,
                planEngineMessage: planEngineMessage
            ),
            examLine: examLine,
            accessibilityText: accessibilityText(
                state: state,
                intensity: intensity,
                targetMinutes: targetMinutes,
                completedMinutes: completedMinutes,
                hasRecordedMinutes: hasRecordedMinutes,
                summary: summary
            )
        )
    }

    private static func stateLabel(
        state: StudyHomeOverview.State,
        intensity: StudyPlanIntensity,
        goalReached: Bool
    ) -> String {
        switch state {
        case .noSchedule: return "尚未添加课表"
        case .engineUnavailable: return "计划引擎尚未接入"
        case .noPlan: return "今天还没有计划"
        case .minimumMode: return "保底计划进行中"
        case .planned: return "正常计划进行中"
        case .goalReached: return intensity == .minimum ? "保底目标已完成" : "今日目标已完成"
        }
    }

    private static func progressText(
        targetMinutes: Int,
        completedMinutes: Int,
        hasRecordedMinutes: Bool,
        summary: DailyStudySummary
    ) -> String {
        guard hasRecordedMinutes else {
            if let legacy = summary.legacyCompletedTaskCount, legacy > 0 {
                return "旧版本只记录了 \(legacy) 项完成，没有时长口径。"
            }
            return "还没有学习时长记录。"
        }
        guard targetMinutes > 0 else {
            return "已记录 \(completedMinutes) 分钟；今天还没有设定目标分钟。"
        }
        return "已完成 \(completedMinutes) / \(targetMinutes) 分钟"
    }

    private static func completionText(summary: DailyStudySummary) -> String {
        var parts: [String] = []
        parts.append("标准完成 \(summary.standardCompletedItemCount) 项")
        parts.append("保底完成 \(summary.minimumCompletedItemCount) 项")
        parts.append("已学习 \(summary.studiedItemCount) 项")
        return parts.joined(separator: " · ")
    }

    private static func completionCompactText(summary: DailyStudySummary) -> String {
        [
            "标准 \(summary.standardCompletedItemCount)",
            "保底 \(summary.minimumCompletedItemCount)",
            "已学习 \(summary.studiedItemCount)"
        ].joined(separator: " · ")
    }

    private static func reasonLine(plan: DailyStudyPlan?, summary: DailyStudySummary) -> String {
        if let plan {
            if let first = plan.explanation.lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return first
            }
            if let assumption = plan.explanation.assumptions.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return assumption
            }
            if let blocked = plan.explanation.blockedReasons.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return blocked
            }
            let pending = plan.pendingItems.count
            if pending == 0 {
                return "今天安排的任务都已完成。"
            }
            return "今天按\(StudyPlanIntensity.resolve(mode: plan.mode).fullLabel)安排了 \(pending) 项任务，共 \(plan.plannedMinutesFromItems) 分钟。"
        }
        let trimmed = summary.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "还没有生成今日计划。" : trimmed
    }

    private static func noticeLine(
        state: StudyHomeOverview.State,
        intensity: StudyPlanIntensity,
        isModelConfigured: Bool,
        planEngineMessage: String?
    ) -> String? {
        var lines: [String] = []
        if state == .noSchedule {
            lines.append("尚未添加课表：可以先按到期的复习任务安排，也可以去「计划」页添加课程表。")
        }
        if state == .engineUnavailable, let planEngineMessage {
            lines.append(planEngineMessage)
        }
        if intensity == .light {
            lines.append("今天的时间比原计划少，已自动减量为轻量计划。")
        }
        if !isModelConfigured {
            lines.append("当前 AI 服务未就绪：本地任务照常执行，AI 分析与答疑暂不可用。")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func accessibilityText(
        state: StudyHomeOverview.State,
        intensity: StudyPlanIntensity,
        targetMinutes: Int,
        completedMinutes: Int,
        hasRecordedMinutes: Bool,
        summary: DailyStudySummary
    ) -> String {
        var parts: [String] = ["今日概览", intensity.fullLabel]
        switch state {
        case .noSchedule: parts.append("尚未添加课表")
        case .engineUnavailable: parts.append("计划引擎尚未接入")
        case .noPlan: parts.append("今天还没有计划")
        case .minimumMode: parts.append("保底计划进行中")
        case .planned: parts.append("正常计划进行中")
        case .goalReached: parts.append("今日目标已完成")
        }
        if targetMinutes > 0 {
            if hasRecordedMinutes {
                parts.append("目标 \(targetMinutes) 分钟，已完成 \(completedMinutes) 分钟")
            } else {
                parts.append("目标 \(targetMinutes) 分钟，完成时长未知")
            }
        }
        parts.append(completionText(summary: summary))
        return parts.joined(separator: "，")
    }

    // MARK: 接下来做

    static func nextSteps(
        items: [DailyPlanItem],
        activeSession: StudySession?,
        now: Date,
        context: PlanningContext,
        upcomingLimit: Int = 2
    ) -> StudyHomeNextSteps {
        let pending = items
            .filter { $0.status == .pending || $0.status == .inProgress }
            .sorted { lhs, rhs in
                switch (lhs.scheduledStart, rhs.scheduledStart) {
                case let (left?, right?): return left == right ? lhs.createdAt < rhs.createdAt : left < right
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.createdAt < rhs.createdAt
                }
            }

        if let session = activeSession, session.state.isActive {
            let item = session.planItemID.flatMap { id in items.first { $0.id == id } }
            let minutes = session.effectiveMinutes(asOf: now, calendar: context.calendar)
            let isPaused = session.isPausedRightNow
            let title = item?.title ?? "未命名任务"
            return StudyHomeNextSteps(
                current: item.map { task(from: $0, now: now, context: context) },
                upcoming: Array(pending.filter { $0.id != item?.id }.prefix(max(0, upcomingLimit)))
                    .map { task(from: $0, now: now, context: context) },
                remainingCount: pending.count,
                isStudying: true,
                isPaused: isPaused,
                sessionStatusText: isPaused
                    ? "已暂停：\(title)（已记录 \(minutes) 分钟）"
                    : "正在学习：\(title)（已记录 \(minutes) 分钟）",
                emptyTitle: "",
                emptySubtitle: ""
            )
        }

        let current = pending.first
        let upcoming = Array(pending.dropFirst().prefix(max(0, upcomingLimit)))
        let secondsUntil = current?.scheduledStart.map { $0.timeIntervalSince(now) } ?? 0
        let isFuture = current?.scheduledStart != nil && secondsUntil > 300

        return StudyHomeNextSteps(
            current: current.map { task(from: $0, now: now, context: context) },
            upcoming: upcoming.map { task(from: $0, now: now, context: context) },
            remainingCount: pending.count,
            isStudying: false,
            isPaused: false,
            sessionStatusText: nil,
            emptyTitle: emptyTitle(items: items, current: current),
            emptySubtitle: emptySubtitle(items: items, isFuture: isFuture)
        )
    }

    private static func emptyTitle(items: [DailyPlanItem], current: DailyPlanItem?) -> String {
        if current != nil { return "" }
        if items.isEmpty { return "今天还没有任务" }
        return "今天安排的任务都处理完了"
    }

    private static func emptySubtitle(items: [DailyPlanItem], isFuture: Bool) -> String {
        if items.isEmpty {
            return "生成今日计划后会在这里显示当前推荐任务，也可以手动添加任务。"
        }
        if isFuture {
            return "下一项还没到安排时间，可以先看娱乐与休息。"
        }
        return "可以放宽一下，或到「计划」页调整今天。"
    }

    /// 单条计划项 → 首页任务模型。
    static func task(from item: DailyPlanItem, now: Date, context: PlanningContext) -> StudyHomeTask {
        let scheduleText: String
        if let start = item.scheduledStart {
            scheduleText = "\(timeText(start, context: context)) 开始"
        } else {
            scheduleText = "今天内安排"
        }

        let dueText: String?
        if let due = item.dueDate {
            let dueDay = StudyDayKey(date: due, timeZone: context.timeZone)
            if dueDay == item.scheduledDayKey {
                dueText = nil
            } else if due < now {
                dueText = "已于 \(dateText(due, context: context)) 到期，安排在今天完成"
            } else {
                dueText = "到期日 \(dateText(due, context: context))，安排在今天"
            }
        } else {
            dueText = nil
        }

        let dueOnAnotherDay = item.isScheduledAfterDueDate

        var parts: [String] = []
        parts.append("\(item.source.kind.label)：\(item.title)")
        if item.isPinned { parts.append("已固定") }
        parts.append("预计 \(item.estimatedMinutes) 分钟")
        parts.append(scheduleText)
        parts.append(item.status.label)
        if let tier = item.completionTier { parts.append(tier.label) }
        if let dueText { parts.append(dueText) }

        return StudyHomeTask(
            id: item.id,
            title: item.title,
            sourceLabel: item.source.kind.label,
            estimatedMinutes: item.estimatedMinutes,
            scheduleText: scheduleText,
            statusLabel: item.status.label,
            tierLabel: item.completionTier?.label,
            isPinned: item.isPinned,
            isDueOnAnotherDay: dueOnAnotherDay,
            dueText: dueText,
            accessibilityText: parts.joined(separator: "，")
        )
    }

    // MARK: 娱乐与休息

    /// 娱乐与休息状态。
    ///
    /// - `progress` 来自 E 的 `RewardEvaluator`（只读评估结果）；为空时
    ///   界面只显示规则的解锁条件文字，不自行推算资格。
    /// - `isWithinRestWindow` 由调用方用 B 的作息数据算出（睡眠/固定占用时段）。
    static func entertainment(
        rules: [EntertainmentRule],
        grants: [RewardGrant],
        progress: [RewardConditionProgress] = [],
        summary: DailyStudySummary,
        isWithinRestWindow: Bool
    ) -> StudyHomeEntertainment {
        let sortedGrants = grants.sorted { $0.grantedAt > $1.grantedAt }
        let todayGrants = sortedGrants.filter { $0.dayKey == summary.dayKey }
        let activeRules = rules.filter(\.isUsable)

        if let grant = sortedGrants.first(where: { $0.state == .started }) {
            return StudyHomeEntertainment(
                state: .running,
                headline: "娱乐进行中：\(grant.ruleSnapshot.name)",
                detail: "本次可用 \(grant.grantedMinutes) 分钟，剩余 \(grant.remainingMinutes) 分钟。",
                progressText: nil,
                rewardMinutes: grant.grantedMinutes,
                remainingMinutes: grant.remainingMinutes,
                ruleName: grant.ruleSnapshot.name,
                ruleVersionText: versionText(version: grant.ruleVersion, revisionID: grant.ruleRevisionID),
                action: .finishReward(grantID: grant.id),
                accessibilityText: "娱乐进行中，本次可用 \(grant.grantedMinutes) 分钟，剩余 \(grant.remainingMinutes) 分钟"
            )
        }

        if let grant = todayGrants.first(where: { $0.isClaimable }) {
            return StudyHomeEntertainment(
                state: .claimable,
                headline: "娱乐已解锁：\(grant.ruleSnapshot.name)",
                detail: "完成条件：\(grant.ruleSnapshot.condition.displayText)。可领取 \(grant.grantedMinutes) 分钟。",
                progressText: ratioText(grant.conditionProgress),
                rewardMinutes: grant.grantedMinutes,
                remainingMinutes: grant.remainingMinutes,
                ruleName: grant.ruleSnapshot.name,
                ruleVersionText: versionText(version: grant.ruleVersion, revisionID: grant.ruleRevisionID),
                action: .claimReward(grantID: grant.id),
                accessibilityText: "娱乐已解锁，\(grant.ruleSnapshot.name)，可领取 \(grant.grantedMinutes) 分钟"
            )
        }

        if let grant = todayGrants.first(where: { $0.state == .claimed }) {
            return StudyHomeEntertainment(
                state: .claimed,
                headline: "已领取：\(grant.ruleSnapshot.name)",
                detail: "已领取 \(grant.grantedMinutes) 分钟，还没开始计时。",
                progressText: nil,
                rewardMinutes: grant.grantedMinutes,
                remainingMinutes: grant.remainingMinutes,
                ruleName: grant.ruleSnapshot.name,
                ruleVersionText: versionText(version: grant.ruleVersion, revisionID: grant.ruleRevisionID),
                action: .startReward(grantID: grant.id),
                accessibilityText: "已领取 \(grant.grantedMinutes) 分钟娱乐时间，可以开始计时"
            )
        }

        if let grant = todayGrants.first(where: { $0.state == .finished }) {
            return StudyHomeEntertainment(
                state: .finished,
                headline: "本次娱乐已结束：\(grant.ruleSnapshot.name)",
                detail: "记录使用 \(grant.usedMinutes) 分钟；下一次达标后会再发放。",
                progressText: nil,
                rewardMinutes: grant.grantedMinutes,
                remainingMinutes: grant.remainingMinutes,
                ruleName: grant.ruleSnapshot.name,
                ruleVersionText: versionText(version: grant.ruleVersion, revisionID: grant.ruleRevisionID),
                action: .none,
                accessibilityText: "本次娱乐已结束，记录使用 \(grant.usedMinutes) 分钟"
            )
        }

        let invalidatedStartDay = summary.dayKey.advanced(byDays: -1)
        let recentInvalidatedGrants = sortedGrants.filter {
            ($0.state == .revoked || $0.state == .expired)
                && $0.dayKey.timeZoneIdentifier == summary.dayKey.timeZoneIdentifier
                && $0.dayKey >= invalidatedStartDay
                && $0.dayKey <= summary.dayKey
        }

        if let grant = recentInvalidatedGrants.first(where: { $0.state == .revoked }) {
            return StudyHomeEntertainment(
                state: .revoked,
                headline: "未使用奖励已取消：\(grant.ruleSnapshot.name)",
                detail: grant.revocation?.reason ?? "奖励资格已失效，未使用奖励已取消。",
                progressText: nil,
                rewardMinutes: 0,
                remainingMinutes: 0,
                ruleName: grant.ruleSnapshot.name,
                ruleVersionText: versionText(version: grant.ruleVersion, revisionID: grant.ruleRevisionID),
                action: .none,
                accessibilityText: "未使用奖励已取消。\(grant.revocation?.reason ?? "奖励资格已失效")"
            )
        }

        if let grant = recentInvalidatedGrants.first(where: { $0.state == .expired }) {
            return StudyHomeEntertainment(
                state: .expired,
                headline: "奖励已过期：\(grant.ruleSnapshot.name)",
                detail: "该奖励仅限 \(grant.dayKey.localDateString) 使用，未使用部分已过期。",
                progressText: nil,
                rewardMinutes: 0,
                remainingMinutes: 0,
                ruleName: grant.ruleSnapshot.name,
                ruleVersionText: versionText(version: grant.ruleVersion, revisionID: grant.ruleRevisionID),
                action: .none,
                accessibilityText: "奖励已过期，未使用部分已过期。"
            )
        }

        if activeRules.isEmpty {
            return StudyHomeEntertainment(
                state: .noRules,
                headline: "还没有娱乐规则",
                detail: "在「我的 → 娱乐规则」里设定完成多少学习可以换多少娱乐时间。",
                progressText: nil,
                rewardMinutes: 0,
                remainingMinutes: 0,
                ruleName: nil,
                ruleVersionText: nil,
                action: .none,
                accessibilityText: "还没有娱乐规则"
            )
        }

        let rule = activeRules.sorted { lhs, rhs in
            if lhs.rewardMinutes != rhs.rewardMinutes { return lhs.rewardMinutes < rhs.rewardMinutes }
            return lhs.createdAt < rhs.createdAt
        }.first

        guard let rule else {
            return StudyHomeEntertainment(
                state: .noRules,
                headline: "还没有娱乐规则",
                detail: "在「我的 → 娱乐规则」里设定完成多少学习可以换多少娱乐时间。",
                progressText: nil,
                rewardMinutes: 0,
                remainingMinutes: 0,
                ruleName: nil,
                ruleVersionText: nil,
                action: .none,
                accessibilityText: "还没有娱乐规则"
            )
        }

        // 只取当前展示规则自己的条件进度：不同规则之间不混用。
        let ruleProgress = progress.first { $0.ruleRevisionID == rule.revisionID }
            ?? progress.first { $0.ruleID == rule.id }

        let headline: String
        let state: StudyHomeEntertainment.State
        if isWithinRestWindow {
            state = .restTime
            headline = "已到休息时间"
        } else if summary.source == .legacyAggregate {
            state = .undecidable
            headline = "娱乐资格暂时无法判定"
        } else if ruleProgress?.isSatisfied == true {
            state = .locked
            headline = "已达标：\(rule.name)"
        } else {
            state = .locked
            headline = "解锁娱乐：\(rule.name)"
        }

        var detailParts: [String] = []
        detailParts.append("解锁条件：\(rule.condition.displayText)")
        detailParts.append("奖励 \(rule.rewardMinutes) 分钟")
        if isWithinRestWindow {
            detailParts.append("现在是休息时段，先休息，奖励不会消失。")
        } else if summary.source == .legacyAggregate {
            detailParts.append(RewardEligibilityGuard.undecidableExplanation(for: summary.dayKey))
        } else if ruleProgress?.isSatisfied == true {
            detailParts.append("条件已经满足，奖励会在 G 的统一提交（刷新计划或完成学习）时写入，不会重复发放。")
        } else {
            detailParts.append("完成后由奖励评估发放。")
        }

        return StudyHomeEntertainment(
            state: state,
            headline: headline,
            detail: detailParts.joined(separator: "；"),
            progressText: ruleProgress.map { ratioText($0) },
            rewardMinutes: rule.rewardMinutes,
            remainingMinutes: 0,
            ruleName: rule.name,
            ruleVersionText: versionText(version: rule.ruleVersion, revisionID: rule.revisionID),
            action: .none,
            accessibilityText: "\(headline)，\(detailParts.joined(separator: "，"))"
        )
    }

    /// 整页唯一主按钮。
    ///
    /// 优先级：正在学习（结束）> 当前任务（开始/继续）> 可领取奖励 > 无。
    static func pagePrimaryAction(
        nextSteps: StudyHomeNextSteps,
        activeSession: StudySession?,
        entertainment: StudyHomeEntertainment
    ) -> StudyHomePrimaryAction {
        if let session = activeSession, session.state.isActive {
            return session.isPausedRightNow ? .resumeSession(sessionID: session.id) : .finishSession(sessionID: session.id)
        }
        if let current = nextSteps.current {
            return .startStudy(itemID: current.id)
        }
        switch entertainment.action {
        case .claimReward, .startReward:
            return entertainment.action
        default:
            return .none
        }
    }

    /// 娱乐操作是否为整页主按钮。
    ///
    /// 只有当整页唯一的主按钮就是娱乐操作时，娱乐卡片才渲染主按钮；
    /// 否则（例如正在学习、还有任务要做）娱乐操作降级为次级入口，
    /// 保证一个页面只有一个最突出的按钮。
    static func entertainmentActionIsPrimary(
        pagePrimary: StudyHomePrimaryAction,
        entertainment: StudyHomeEntertainment
    ) -> Bool {
        guard entertainment.action.isPrimary else { return false }
        return pagePrimary == entertainment.action
    }

    // MARK: 考试摘要（只在与今天安排直接相关时出现）

    /// 仅当考试日期落在 `horizonDays` 天内、或今天计划里确实有该科目的任务时，
    /// 才给出一行考试摘要；否则返回 nil（首页不常驻大面积考试卡片）。
    static func examLine(
        goal: ExamGoal?,
        plan: DailyStudyPlan?,
        now: Date,
        context: PlanningContext,
        horizonDays: Int = 7
    ) -> String? {
        guard let goal else { return nil }
        let days = goal.daysRemaining(now: now)
        guard days >= 0 else { return nil }

        let goalSubjects = Set(goal.subjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let planTitles = plan?.items.map(\.title) ?? []
        let hasRelatedTask = !goalSubjects.isEmpty && planTitles.contains { title in
            goalSubjects.contains { subject in
                !subject.isEmpty && title.localizedCaseInsensitiveContains(subject)
            }
        }

        if days <= horizonDays || hasRelatedTask {
            return "距离 \(goal.name) 还有 \(days) 天（\(goal.subjectText)）"
        }
        return nil
    }

    // MARK: 休息时段判定（用 B 的作息数据，纯计算）

    /// 当前时刻是否落在睡眠（或指定固定占用）时段内。
    ///
    /// 睡眠窗口按"开始那天的星期"记录，跨午夜用 `endDayOffset` 表达；
    /// 这里换算成绝对时间区间再判断，避免"23:00–07:00"被当成负数时长。
    static func isWithinRestWindow(
        now: Date,
        dayKey: StudyDayKey,
        settings: AvailabilitySettings,
        context: PlanningContext
    ) -> Bool {
        guard let startOfDay = dayKey.startOfDay(calendar: context.calendar) else { return false }
        let calendarWeekday = context.calendar.component(.weekday, from: startOfDay)
        guard let weekday = ScheduleWeekday(calendarWeekday: calendarWeekday) else { return false }
        let previousWeekday = ScheduleWeekday(rawValue: weekday.rawValue == 1 ? 7 : weekday.rawValue - 1) ?? weekday

        var ranges: [DayTimeRange] = settings.sleepWindowsAffecting(weekday: weekday)
        ranges.append(contentsOf: settings.customBlocks(for: weekday))
        if previousWeekday != weekday {
            ranges.append(contentsOf: settings.customBlocks(for: previousWeekday))
        }

        for range in ranges {
            let base: Date?
            if range.weekday == weekday {
                base = startOfDay
            } else if range.weekday == previousWeekday {
                base = context.calendar.date(byAdding: .day, value: -1, to: startOfDay)
            } else {
                base = nil
            }
            guard let base else { continue }
            guard let start = context.calendar.date(byAdding: .minute, value: range.start.minutes, to: base) else { continue }
            let endBase = range.endDayOffset > 0
                ? context.calendar.date(byAdding: .day, value: range.endDayOffset, to: base) ?? base
                : base
            guard let end = context.calendar.date(byAdding: .minute, value: range.end.minutes, to: endBase) else { continue }
            if now >= start && now < end {
                return true
            }
        }
        return false
    }

    // MARK: 小工具

    private static func versionText(version: Int, revisionID: UUID) -> String {
        "规则版本 v\(version)（\(revisionID.uuidString.prefix(8))）"
    }

    private static func ratioText(_ progress: RewardConditionProgress) -> String {
        "\(valueText(progress.achievedValue)) / \(valueText(progress.requiredValue))"
    }

    private static func valueText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func timeText(_ date: Date, context: PlanningContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = context.timeZone
        return formatter.string(from: date)
    }

    static func dateText(_ date: Date, context: PlanningContext) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        formatter.timeZone = context.timeZone
        return formatter.string(from: date)
    }
}
