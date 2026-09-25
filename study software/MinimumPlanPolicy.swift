import Foundation

// MARK: - D 模块：最低任务策略（标准 / 轻量 / 保底 + 休息建议）
//
// 接口（A 定稿，不得更改签名）：
//   MinimumPlanPolicy | 当前计划、剩余时间、可拆分范围 | 轻量/保底提案及变更明细
//
// 纯计算：不读时钟（时间来自 `PlanningContext`）、不写文件、不发通知、不改全局状态。
// 本文件不新增 A 的结构体字段，只提供实现与只读派生。
//
// 三档模式规则：
// - 标准：当前未完成任务全部能放进剩余预算 → 不改任何范围（`DailyPlanMode.standard`）。
// - 轻量：全部放不下，但按内容量压缩后仍能留下多个核心动作（`.reduced`）。
// - 保底：只留极少数（默认 1 条）明确、有价值的动作，且总时长不超过上限（默认 15 分钟）（`.minimum`）。
// - 无可用时间 / 已到保护睡眠：返回休息建议，`isEmpty == true`，
//   绝不返回"保底已完成"，也不写入任何完成事件。
//
// 压缩顺序（D 模块压缩要求 1–7）：
// 1. 先移出优先级最低的任务（顺延到后续计划）；
// 2. 再缩小明确可拆分任务的内容范围（由 `TaskScopeReducer` 执行，题/页/节/自定义单位）；
// 3. 绝不只改预计分钟数：不可拆分的整题任务只能整体保留或整体移出；
// 4. 缺少结构化内容的任务不编造子题、子知识点。

// MARK: - 配置

/// 保底策略配置。所有阈值都可注入，便于测试固定边界。
struct MinimumPlanPolicyConfiguration: Hashable, Sendable {
    /// 剩余时间低于该值（分钟）时优先尝试保底方案。默认 20。
    var lowTimeThresholdMinutes: Int
    /// 保底方案的总时长上限（分钟）。默认 15。
    var minimumPlanCapMinutes: Int
    /// 一次减量最少留下的分钟数，低于这个数就不值得单独安排。默认 5。
    var minimumUsefulMinutes: Int
    /// 轻量模式的"核心动作"上限：至少保留几条任务。默认 2（满足"保留多个核心动作"）。
    var lightCoreActionCount: Int
    /// 保底模式的"核心动作"上限：只留少量明确动作。默认 1。
    var minimumCoreActionCount: Int
    /// 是否尊重"自动减量关闭"标记。默认 `true`。
    var respectsAutoReduceSetting: Bool
    /// 是否启用睡眠保护：当前时间已落入睡眠时段时不安排任何任务。默认 `true`。
    var enforcesProtectedSleep: Bool
    /// 用户的真实睡眠时段（由 G 从 `AvailabilitySettings.sleepWindows` 注入）。
    ///
    /// 刻意**没有**内置默认窗口：是否"在睡眠中"必须来自用户配置，
    /// 不能由算法假定一个固定的 23:00–次日 07:00。
    /// 空数组 = 用户没有配置睡眠时段 → 不做睡眠保护（而不是替用户假设）。
    var sleepWindows: [DayTimeRange]

    init(
        lowTimeThresholdMinutes: Int = 20,
        minimumPlanCapMinutes: Int = 15,
        minimumUsefulMinutes: Int = 5,
        lightCoreActionCount: Int = 2,
        minimumCoreActionCount: Int = 1,
        respectsAutoReduceSetting: Bool = true,
        enforcesProtectedSleep: Bool = true,
        sleepWindows: [DayTimeRange] = []
    ) {
        self.lowTimeThresholdMinutes = max(1, lowTimeThresholdMinutes)
        self.minimumPlanCapMinutes = max(1, minimumPlanCapMinutes)
        self.minimumUsefulMinutes = max(1, minimumUsefulMinutes)
        self.lightCoreActionCount = max(2, lightCoreActionCount)
        self.minimumCoreActionCount = max(1, minimumCoreActionCount)
        self.respectsAutoReduceSetting = respectsAutoReduceSetting
        self.enforcesProtectedSleep = enforcesProtectedSleep
        self.sleepWindows = sleepWindows
    }

    /// 从可用的作息偏好构建策略配置（G 的注入入口）。
    ///
    /// - Parameter isManual: 是否由用户**主动**采用方案。
    ///   自动减量为关时，手动采用仍然必须可用（需求 3），
    ///   因此手动路径不再受"自动减量关闭"标记约束。
    static func standard(
        availability: AvailabilityPreferences,
        isManual: Bool = false
    ) -> MinimumPlanPolicyConfiguration {
        MinimumPlanPolicyConfiguration(
            respectsAutoReduceSetting: !isManual,
            sleepWindows: availability.routine.sleepWindows
        )
    }

    static let `default` = MinimumPlanPolicyConfiguration()

    /// 内容压缩参数（与 `TaskScopeReducer` 共用同一套下限）。
    var scopeReducerConfiguration: TaskScopeReducerConfiguration {
        TaskScopeReducerConfiguration(minimumUsefulMinutes: minimumUsefulMinutes)
    }

    /// G 在生成/提交计划时写入的解释标记：自动减量为关。
    ///
    /// 政策拿不到 `AvailabilityPreferences`，因此通过计划自身的解释读取该标记；
    /// 没有标记时按"允许减量"处理（减量只在被显式调用时发生）。
    static let autoReduceDisabledMarker = "autoReduce:disabled"
}

// MARK: - 提案只读派生（不新增 A 的结构体字段）

extension MinimumPlanProposal {
    /// 休息建议：无可用时间 / 已到保护睡眠。
    ///
    /// 该状态下界面必须显示"建议休息"，不能显示"保底已完成"，
    /// 也不能据此写入任何完成事件。
    var isRestSuggestion: Bool { isEmpty }

    /// 变更明细里的调整动作（被缩小、被顺延、被移出）。
    var adjustedChanges: [MinimumPlanChange] {
        changes.filter { $0.kind != .kept }
    }

    /// 按变更类型筛出明细。
    func changes(of kind: MinimumPlanChangeKind) -> [MinimumPlanChange] {
        changes.filter { $0.kind == kind }
    }

    /// 计划里的保留项（与本轮变更无关的任务）。
    var retainedItems: [DailyPlanItem] { plan.items }

    /// 说清"为什么这么压"，直接用于界面文案。
    var explanationText: String {
        (explanation.lines + explanation.assumptions + explanation.blockedReasons).joined(separator: "\n")
    }

    /// 变更前的预计总分钟数 = 变更后分钟数 + 被缩小掉的分钟数 + 被移出/顺延的分钟数。
    var originalMinutes: Int {
        let trimmedBack = changes(of: .trimmed).reduce(0) { $0 + max(0, $1.beforeMinutes - $1.afterMinutes) }
        let removedBack = (changes(of: .removed) + changes(of: .deferred)).reduce(0) { $0 + $1.beforeMinutes }
        return plan.plannedMinutesFromItems + trimmedBack + removedBack
    }

    /// 变更后的预计总分钟数。
    var reducedMinutes: Int { plan.plannedMinutesFromItems }

    /// 变更后的保留任务条数（含原本已完成 / 固定的任务）。
    var keptItemCount: Int { plan.items.count }

    /// 今天的完成度影响。
    ///
    /// 容量口径与首页 / 报告一致：只有**已完成的计划项**才计入，
    /// `tier` 取完成事件重算后的缓存值。
    var progressImpact: MinimumPlanProgressImpact {
        let before = plan.items.filter { $0.status == .completed }.count
        let protectedNotKept = adjustedChanges.filter { change in
            plan.items.contains { $0.id == change.itemID }
        }
        _ = protectedNotKept
        return MinimumPlanProgressImpact(
            beforeCompletedItemCount: before,
            afterCompletedItemCount: before,
            keptItemCount: plan.items.count,
            removedItemCount: changes(of: .removed).count,
            deferredItemCount: changes(of: .deferred).count
        )
    }
}

/// 今天完成状态的影响。
///
/// 只描述"本次调整让今天还能完成多少"的**事实变化**，
/// 不判定娱乐资格（娱乐资格由 E 的 `RewardEvaluator` 判定，见 `EntertainmentImpactPresentation`）。
struct MinimumPlanProgressImpact: Hashable, Sendable {
    /// 调整前已完成的任务数（来自计划项的 `completed` 状态）。
    var beforeCompletedItemCount: Int
    /// 调整后今天仍有可能完成的任务数（已完成 + 保留的未完成项）。
    var afterCompletedItemCount: Int
    /// 调整后计划里保留的任务条数。
    var keptItemCount: Int
    /// 从今天移除的任务条数。
    var removedItemCount: Int
    /// 顺延到后续计划的任务条数。
    var deferredItemCount: Int

    init(
        beforeCompletedItemCount: Int = 0,
        afterCompletedItemCount: Int = 0,
        keptItemCount: Int = 0,
        removedItemCount: Int = 0,
        deferredItemCount: Int = 0
    ) {
        self.beforeCompletedItemCount = max(0, beforeCompletedItemCount)
        self.afterCompletedItemCount = max(0, afterCompletedItemCount)
        self.keptItemCount = max(0, keptItemCount)
        self.removedItemCount = max(0, removedItemCount)
        self.deferredItemCount = max(0, deferredItemCount)
    }

    /// 调整后相对调整前"今天能达到的完成数"变化。
    var reachableItemDelta: Int { afterCompletedItemCount - beforeCompletedItemCount }

    /// 是否与本轮调整无关。
    var isNeutral: Bool { reachableItemDelta == 0 && removedItemCount == 0 && deferredItemCount == 0 }

    /// 界面文案。
    var summaryText: String {
        var parts = ["今天已完成 \(beforeCompletedItemCount) 项"]
        if keptItemCount > 0 {
            parts.append("减量后仍有 \(keptItemCount) 项在做")
        }
        if deferredItemCount > 0 {
            parts.append("顺延 \(deferredItemCount) 项")
        }
        if removedItemCount > 0 {
            parts.append("今天移除 \(removedItemCount) 项")
        }
        return parts.joined(separator: "，") + "。"
    }
}

// MARK: - 策略

/// `MinimumPlanPolicy` 的实现。
///
/// 无状态值类型：同一输入永远得到同一输出，可安全地在任意线程构造与调用。
struct StudyMinimumPlanPolicy: MinimumPlanPolicy {
    var configuration: MinimumPlanPolicyConfiguration

    init(configuration: MinimumPlanPolicyConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: 入口

    func reduce(
        plan: DailyStudyPlan,
        remainingMinutes: Int,
        splittableItemIDs: Set<UUID>,
        context: PlanningContext
    ) -> MinimumPlanProposal {
        let available = max(0, remainingMinutes)
        let splitIDs = splittableItemIDs.union(plan.items.filter(\.isSplittable).map(\.id))

        let candidates = plan.items.filter { Self.isCandidate($0) }

        // 没有可调整的剩余任务：计划本来就是标准的，一个字段都不改。
        guard !candidates.isEmpty else {
            return Self.standardProposal(
                plan: plan,
                context: context,
                note: "当天没有未完成的任务，保持当前计划。"
            )
        }

        // 休息状态 1：时间已进入保护睡眠时段。
        if configuration.enforcesProtectedSleep,
           Self.isInsideProtectedSleep(plan: plan, context: context, sleepWindows: configuration.sleepWindows) {
            return Self.restProposal(
                plan: plan,
                context: context,
                reason: "当前时间已经进入你的睡眠保护时段，不再安排新的学习任务。今天先休息，未完成的任务会留在后续计划里。"
            )
        }

        // 休息状态 2：完全没有剩余时间 / 低于最小可用阈值。
        guard available >= configuration.minimumUsefulMinutes else {
            return Self.restProposal(
                plan: plan,
                context: context,
                reason: available <= 0
                    ? "今天已经没有可用的剩余时间，不假定任何任务已完成。未完成的任务会顺延到后续计划。"
                    : "剩余时间不足 \(configuration.minimumUsefulMinutes) 分钟，放不下任何完整动作，建议直接休息；未完成的任务会顺延。"
            )
        }

        // 自动减量为关：不自行减量，只如实说明哪些任务放不下。
        if configuration.respectsAutoReduceSetting, !Self.autoReduceEnabled(for: plan) {
            return Self.blockedProposal(
                plan: plan,
                candidates: candidates,
                available: available,
                context: context
            )
        }

        // 标准档：全部未完成任务都能放进剩余预算。
        let pendingMinutes = candidates.reduce(0) { $0 + max(0, $1.estimatedMinutes) }
        if pendingMinutes <= available {
            return Self.standardProposal(
                plan: plan,
                context: context,
                note: "剩余 \(available) 分钟可以完成全部未完成任务（约 \(pendingMinutes) 分钟），保持标准计划。"
            )
        }

        let ranked = Self.rankedCandidates(candidates)

        // 保底档：剩余时间紧张时优先尝试"少量、明确、有价值"的动作。
        if available <= configuration.lowTimeThresholdMinutes {
            let cap = min(available, configuration.minimumPlanCapMinutes)
            if let outcome = Self.allocate(
                rankedItems: ranked,
                allItems: plan.items,
                budgetMinutes: cap,
                maxKeptItems: configuration.minimumCoreActionCount,
                splitItemIDs: splitIDs,
                configuration: configuration
            ), !outcome.keptIDs.isEmpty {
                return Self.buildProposal(
                    plan: plan,
                    outcome: outcome,
                    mode: .minimum,
                    context: context,
                    candidates: candidates,
                    available: available,
                    reason: "剩余 \(available) 分钟，已压到保底：只保留 \(outcome.keptIDs.count) 条明确动作，总时长不超过 \(configuration.minimumPlanCapMinutes) 分钟。"
                )
            }
        }

        // 轻量档：按内容量压缩，尽量留下多个核心动作。
        if let outcome = Self.allocate(
            rankedItems: ranked,
            allItems: plan.items,
            budgetMinutes: available,
            maxKeptItems: configuration.lightCoreActionCount,
            splitItemIDs: splitIDs,
            configuration: configuration
        ), !outcome.keptIDs.isEmpty {
            let mode: DailyPlanMode = outcome.keptIDs.count <= configuration.minimumCoreActionCount ? .minimum : .reduced
            let reason = mode == .minimum
                ? "剩余 \(available) 分钟只能保留 \(outcome.keptIDs.count) 条动作，按保底处理。"
                : "剩余 \(available) 分钟放不下全部任务，已按内容量压缩并保留 \(outcome.keptIDs.count) 条核心动作，其余顺延。"
            return Self.buildProposal(
                plan: plan,
                outcome: outcome,
                mode: mode,
                context: context,
                candidates: candidates,
                available: available,
                reason: reason
            )
        }

        // 兜底：连一条动作都放不下 → 休息建议，绝不假装完成。
        return Self.restProposal(
            plan: plan,
            context: context,
            reason: "剩余 \(available) 分钟放不下任何一条可执行的保底动作（保底最少需要 \(configuration.minimumUsefulMinutes) 分钟），今天先休息；未完成的任务会顺延到后续计划。"
        )
    }

    // MARK: 候选筛选与排序

    /// 是否受保护（不参与减量、不改动）。
    ///
    /// 需求 3：自动/手动调整都**只处理未开始内容**，因此"进行中"同样是受保护的。
    static func isProtected(_ item: DailyPlanItem) -> Bool {
        item.isPinned || item.status == .completed || item.status == .inProgress
    }

    /// 是否是本轮可调整的剩余任务。
    static func isCandidate(_ item: DailyPlanItem) -> Bool {
        guard !isProtected(item) else { return false }
        switch item.status {
        case .pending, .carriedOver:
            return item.plannedScope.isPositive && item.estimatedMinutes > 0
        case .skipped, .completed, .inProgress:
            // 进行中属于受保护内容（见 `isProtected`），不参与调整。
            return false
        }
    }

    /// 核心动作价值：数值越小越先被保留。
    ///
    /// 刻意只使用**真实存在的字段**（来源类型、到期日、预计时长），
    /// 不读取任何编造的"重要性评分"。
    static func valueRank(of item: DailyPlanItem) -> Int {
        switch item.source.kind {
        case .reviewTask: return 0
        case .manual: return 1
        case .courseReview: return 2
        case .preview: return 3
        }
    }

    static func rankedCandidates(_ items: [DailyPlanItem]) -> [DailyPlanItem] {
        items.sorted { lhs, rhs in
            let leftRank = valueRank(of: lhs)
            let rightRank = valueRank(of: rhs)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftDue = lhs.dueDate ?? Date.distantFuture
            let rightDue = rhs.dueDate ?? Date.distantFuture
            if leftDue != rightDue { return leftDue < rightDue }
            if lhs.estimatedMinutes != rhs.estimatedMinutes { return lhs.estimatedMinutes < rhs.estimatedMinutes }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: 分配

    /// 一次分配的结果。
    struct AllocationOutcome {
        /// 保留的计划项（原样或已缩小），按原计划顺序。
        var keptItems: [DailyPlanItem]
        var keptIDs: [UUID]
        /// 被缩小的计划项 ID → 压缩结果。
        var reductions: [UUID: TaskScopeReductionOutcome]
        /// 没能进入计划的计划项（含原因）。
        var excluded: [(item: DailyPlanItem, reason: String)]
    }

    /// 把候选任务分配进预算。
    ///
    /// 算法：
    /// 1. 取价值最高的 `maxKeptItems` 条作为核心动作，其余移出当天计划（顺延）；
    /// 2. 核心动作原样放不下时，按比例 `p = 预算 / 原预计分钟` 缩小**内容范围**，
    ///    只对可拆分任务生效；不可拆分的整题任务要么整体保留，要么整体移出；
    /// 3. 仍越界（某条任务的保底范围本身就放不下）时把 `p` 递减后重试，
    ///    绝不通过篡改分钟数来假装放得下；
    /// 4. 一条都留不下 → 返回 `nil`，由调用方走休息建议。
    static func allocate(
        rankedItems: [DailyPlanItem],
        allItems: [DailyPlanItem],
        budgetMinutes: Int,
        maxKeptItems: Int,
        splitItemIDs: Set<UUID>,
        configuration: MinimumPlanPolicyConfiguration
    ) -> AllocationOutcome? {
        guard budgetMinutes >= configuration.minimumUsefulMinutes else { return nil }
        guard !rankedItems.isEmpty else { return nil }

        let core = Array(rankedItems.prefix(max(1, maxKeptItems)))
        let coreIDs = Set(core.map(\.id))
        let overCapacity = rankedItems
            .filter { !coreIDs.contains($0.id) }
            .map { (item: $0, reason: "优先级低于保留的核心动作（预算 \(budgetMinutes) 分钟）。") }

        var proportion = 1.0
        var reductions: [UUID: TaskScopeReductionOutcome] = [:]
        var kept: [DailyPlanItem] = []
        var refused: [(item: DailyPlanItem, reason: String)] = []

        while true {
            reductions = [:]
            kept = []
            refused = []

            for item in core {
                let splittable = Self.isSplittable(item, splitItemIDs: splitItemIDs)
                let target = desiredScope(for: item, proportion: proportion, splittable: splittable)
                let outcome = TaskScopeReducer.reduce(
                    item: item,
                    to: target,
                    availableMinutes: budgetMinutes,
                    configuration: configuration.scopeReducerConfiguration
                )

                switch outcome.reduction {
                case .unchanged, .trimmed:
                    var updated = item
                    updated.plannedScope = outcome.scope
                    updated.estimatedMinutes = outcome.estimatedMinutes
                    kept.append(updated)
                    if outcome.isTrimmed {
                        reductions[item.id] = outcome
                    }
                case .wholeItem:
                    kept.append(item)
                case .cannotReduce:
                    refused.append((item, outcome.reason))
                }
            }

            let total = kept.reduce(0) { $0 + $1.estimatedMinutes }
            if total <= budgetMinutes || proportion <= 0.01 {
                break
            }
            proportion = max(0, proportion - 0.05)
        }

        guard !kept.isEmpty else { return nil }

        // 极端情况（单条任务的保底范围就超过预算）：不强行保留，交给调用方。
        let keptTotal = kept.reduce(0) { $0 + $1.estimatedMinutes }
        guard keptTotal <= budgetMinutes else { return nil }

        // 按原计划顺序排列，但**必须使用缩小后的副本**（不能回退到原任务，
        // 否则压缩结果会被静默丢弃，等于只改了预算没改内容）。
        let reducedByID = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
        var orderedKept = allItems.compactMap { reducedByID[$0.id] }
        // 原计划里不存在的项（理论上不会发生）也要保留，避免静默丢任务。
        for item in kept where !orderedKept.contains(where: { $0.id == item.id }) {
            orderedKept.append(item)
        }

        return AllocationOutcome(
            keptItems: orderedKept,
            keptIDs: orderedKept.map(\.id),
            reductions: reductions,
            excluded: overCapacity + refused
        )
    }

    /// 目标内容范围：`nil` 表示"保持原状"。
    static func desiredScope(
        for item: DailyPlanItem,
        proportion: Double,
        splittable: Bool
    ) -> StudyScope? {
        guard splittable, proportion < 1 else { return nil }
        let planned = item.plannedScope
        var amount = (planned.amount * max(0, proportion)).rounded(.down)
        if let minimum = item.minimumScope, planned.isComparable(to: minimum) {
            amount = max(amount, minimum.amount)
        }
        amount = max(1, min(amount, max(1, planned.amount - 1)))
        return StudyScope(unit: planned.unit, amount: amount, customUnitLabel: planned.customUnitLabel)
    }

    /// 该任务是否允许按内容量压缩。
    ///
    /// 两个条件缺一不可：
    /// - 量纲必须可数（题 / 页 / 节 / 自定义）；
    /// - 必须由产出方或调用方标记为可拆分（`isSplittable` / `splittableItemIDs` / 带 `minimumScope`）。
    ///
    /// 缺任何一个都视为"整体任务"：只能整体保留或整体移出，
    /// 不允许把 15 分钟改成 5 分钟来假装减量。
    static func isSplittable(_ item: DailyPlanItem, splitItemIDs: Set<UUID>) -> Bool {
        guard TaskScopeReducer.isReducibleUnit(item.plannedScope.unit) else { return false }
        return item.isSplittable || splitItemIDs.contains(item.id) || item.minimumScope != nil
    }

    // MARK: 提案构造

    /// 标准档：一个字段都不改。
    static func standardProposal(
        plan: DailyStudyPlan,
        context: PlanningContext,
        note: String
    ) -> MinimumPlanProposal {
        var untouched = plan
        untouched.updatedAt = context.now
        return MinimumPlanProposal(
            plan: untouched,
            changes: [],
            explanation: DailyPlanExplanation(lines: [note]),
            isEmpty: false
        )
    }

    /// 自动减量关闭：不改计划，只如实说明放不下的任务。
    static func blockedProposal(
        plan: DailyStudyPlan,
        candidates: [DailyPlanItem],
        available: Int,
        context: PlanningContext
    ) -> MinimumPlanProposal {
        var untouched = plan
        untouched.updatedAt = context.now
        let needed = candidates.reduce(0) { $0 + $1.estimatedMinutes }
        let changes = candidates
            .sorted { $0.estimatedMinutes > $1.estimatedMinutes }
            .map { item in
                MinimumPlanChange(
                    itemID: item.id,
                    title: item.title,
                    kind: .kept,
                    beforeScope: item.plannedScope,
                    afterScope: item.plannedScope,
                    beforeMinutes: item.estimatedMinutes,
                    afterMinutes: item.estimatedMinutes,
                    reason: "自动减量已关闭，本条保持原样。"
                )
            }
        return MinimumPlanProposal(
            plan: untouched,
            changes: changes,
            explanation: DailyPlanExplanation(
                lines: ["剩余 \(available) 分钟，未完成任务约需 \(needed) 分钟。自动减量已关闭，没有改动任何任务范围。"],
                blockedReasons: ["如果想今天只做一部分内容，请手动选择减量方案。"]
            ),
            isEmpty: false
        )
    }

    /// 休息建议：计划原样保留、不写完成、不给"保底已完成"。
    static func restProposal(
        plan: DailyStudyPlan,
        context: PlanningContext,
        reason: String
    ) -> MinimumPlanProposal {
        var untouched = plan
        untouched.updatedAt = context.now
        return MinimumPlanProposal(
            plan: untouched,
            changes: [],
            explanation: DailyPlanExplanation(blockedReasons: [reason]),
            isEmpty: true
        )
    }

    /// 组装轻量 / 保底提案：保留项 + 变更明细 + 解释。
    static func buildProposal(
        plan: DailyStudyPlan,
        outcome: AllocationOutcome,
        mode: DailyPlanMode,
        context: PlanningContext,
        candidates: [DailyPlanItem],
        available: Int,
        reason: String
    ) -> MinimumPlanProposal {
        let keptIDs = Set(outcome.keptIDs)
        let protectedItems = plan.items.filter { isProtected($0) && !keptIDs.contains($0.id) }

        var newItems = protectedItems
        newItems.append(contentsOf: outcome.keptItems)
        // 保持原计划的展示顺序，避免减量后任务跳位。
        let order = Dictionary(uniqueKeysWithValues: plan.items.enumerated().map { ($0.element.id, $0.offset) })
        newItems.sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }

        let changes = changeRecords(outcome: outcome, candidates: candidates, available: available)

        var reduced = plan
        reduced.mode = mode
        reduced.items = newItems
        reduced.budget.plannedMinutes = newItems.reduce(0) { $0 + $1.estimatedMinutes }
        reduced.updatedAt = context.now
        reduced.explanation = DailyPlanExplanation(
            lines: [reason],
            blockedReasons: changeSummaryLines(changes: changes, available: available)
        )

        return MinimumPlanProposal(
            plan: reduced,
            changes: changes,
            explanation: reduced.explanation,
            isEmpty: false
        )
    }

    /// 变更明细：被缩小的、被顺延的、被移出的逐条写清"保留了什么、剩了什么、为什么"。
    static func changeRecords(
        outcome: AllocationOutcome,
        candidates: [DailyPlanItem],
        available: Int
    ) -> [MinimumPlanChange] {
        var records: [MinimumPlanChange] = []
        let keptIDs = Set(outcome.keptIDs)

        for item in candidates where keptIDs.contains(item.id) {
            guard let reduction = outcome.reductions[item.id] else { continue }
            records.append(
                MinimumPlanChange(
                    itemID: item.id,
                    title: item.title,
                    kind: .trimmed,
                    beforeScope: item.plannedScope,
                    afterScope: reduction.scope,
                    beforeMinutes: item.estimatedMinutes,
                    afterMinutes: reduction.estimatedMinutes,
                    reason: reduction.reason + keptRemainingText(reduction)
                )
            )
        }

        for entry in outcome.excluded {
            records.append(
                MinimumPlanChange(
                    itemID: entry.item.id,
                    title: entry.item.title,
                    kind: .deferred,
                    beforeScope: entry.item.plannedScope,
                    afterScope: nil,
                    beforeMinutes: entry.item.estimatedMinutes,
                    afterMinutes: 0,
                    reason: "\(entry.reason) 已顺延到后续计划，今天的完成状态不受影响。"
                )
            )
        }

        _ = available
        return records.sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.title < rhs.title }
            return kindOrder(lhs.kind) < kindOrder(rhs.kind)
        }
    }

    static func kindOrder(_ kind: MinimumPlanChangeKind) -> Int {
        switch kind {
        case .trimmed: return 0
        case .convertedToMinimum: return 1
        case .deferred: return 2
        case .removed: return 3
        case .kept: return 4
        }
    }

    static func keptRemainingText(_ outcome: TaskScopeReductionOutcome) -> String {
        var text = " 保留：\(outcome.keptSummary)。"
        if !outcome.remainingSummary.isEmpty {
            text += " 剩余：\(outcome.remainingSummary)（回到后续计划继续）。"
        }
        return text
    }

    static func changeSummaryLines(changes: [MinimumPlanChange], available: Int) -> [String] {
        let trimmed = changes.filter { $0.kind == .trimmed }.count
        let deferred = changes.filter { $0.kind == .deferred }.count
        let removed = changes.filter { $0.kind == .removed }.count
        var lines: [String] = []
        if trimmed > 0 { lines.append("缩小范围：\(trimmed) 项。") }
        if deferred > 0 { lines.append("顺延到后续计划：\(deferred) 项。") }
        if removed > 0 { lines.append("从今天移除：\(removed) 项。") }
        if lines.isEmpty { lines.append("剩余 \(available) 分钟，没有需要调整的任务。") }
        return lines
    }

    // MARK: 偏好与睡眠

    /// 是否允许自动减量。
    ///
    /// 政策不直接读 `AvailabilityPreferences`（那属于 G 的注入职责），
    /// 因此从计划自身的解释里读取 G 写入的显式标记：
    /// 没有该标记 = 允许减量（减量只在被显式调用时发生）。
    static func autoReduceEnabled(for plan: DailyStudyPlan) -> Bool {
        !plan.explanation.blockedReasons.contains(MinimumPlanPolicyConfiguration.autoReduceDisabledMarker)
    }

    /// 当前时间是否落在**用户配置的**睡眠时段里。
    ///
    /// 只使用 `plan.dayKey`、`PlanningContext` 与注入的睡眠窗口，不读系统时钟，
    /// 也不假定任何固定时刻。支持跨午夜窗口（`endDayOffset = 1`）。
    static func isInsideProtectedSleep(
        plan: DailyStudyPlan,
        context: PlanningContext,
        sleepWindows: [DayTimeRange]
    ) -> Bool {
        guard !sleepWindows.isEmpty else { return false }
        let calendar = context.calendar
        let dayStart = calendar.startOfDay(for: context.now)

        // 同时检查"今天"和"昨天"的窗口：跨午夜的窗口由昨天开始，延续到今天凌晨。
        for offset in [-1, 0] {
            guard let anchor = calendar.date(byAdding: .day, value: offset, to: dayStart) else { continue }
            let weekday = ScheduleWeekday(calendarWeekday: calendar.component(.weekday, from: anchor)) ?? .monday
            for window in sleepWindows where window.weekday == weekday {
                guard let start = calendar.date(byAdding: .minute, value: window.start.minutes, to: anchor),
                      let end = calendar.date(
                        byAdding: .minute,
                        value: window.end.minutes + window.endDayOffset * 24 * 60,
                        to: anchor
                      ),
                      end > start else { continue }
                if context.now >= start && context.now < end { return true }
            }
        }
        return false
    }
}
