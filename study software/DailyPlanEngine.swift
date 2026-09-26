import Foundation

// MARK: - 今日任务自动规划（模块 C）
//
// 公共接口职责表：
//   DailyPlanEngine | 时间容量、任务候选、已有计划、完成记录 | 计划提案、无法安排项、解释
//
// 本文件实现 `DailyPlanEngine` 的本地版本（`LocalDailyPlanEngine`），特点：
//   - 本地优先：只用 Foundation + 真实数据，不需要网络或 API Key；
//   - 时间全部由外部注入（`PlanningContext.now` / 日历 / 规划时区），内部不调用 `Date()`；
//   - 纯计算：不写文件、不发通知、不改全局状态。提案由 G 的 `DailyPlanCoordinator` 决定是否保存；
//   - 生成提案与实际应用分离：`proposePlan` 只返回 `DailyPlanProposal`；
//   - 接入 D 的 `MinimumPlanPolicy` 做减量；未接入时**不另写第二套压缩算法**。

// MARK: - 精力

/// 精力档位。系数集中在 `StudyEnergyLevel.coefficient`，不散落在页面。
enum StudyEnergyLevel: String, Codable, CaseIterable, Sendable {
    case tired
    case normal
    case energetic

    /// 预算系数（乘在"可用空档 × 利用比例"之后）。
    var coefficient: Double {
        switch self {
        case .tired: return 0.6
        case .normal: return 0.8
        case .energetic: return 1.0
        }
    }

    var label: String {
        switch self {
        case .tired: return "较累"
        case .normal: return "正常"
        case .energetic: return "充足"
        }
    }
}

/// 精力建议：B 返回课表负担信息 → C 给出默认精力建议；用户手动设置优先。
///
/// 界面必须明确"这是估计"，不能把默认建议描述成用户设置。
enum EnergyAdvisor {
    struct Suggestion: Hashable, Sendable {
        var level: StudyEnergyLevel
        var isUserProvided: Bool
        var reason: String
        var burdenLevel: CourseBurdenLevel?
        var courseMinutes: Int
    }

    static func suggestion(
        courseMinutes: Int,
        courseCount: Int,
        maxBurden: CourseBurdenLevel?,
        userOverride: StudyEnergyLevel?,
        defaultLevel: StudyEnergyLevel = .normal
    ) -> Suggestion {
        let minutes = max(0, courseMinutes)

        if let userOverride {
            return Suggestion(
                level: userOverride,
                isUserProvided: true,
                reason: "用户手动设置为「\(userOverride.label)」，优先于课表估计。",
                burdenLevel: maxBurden,
                courseMinutes: minutes
            )
        }

        guard courseCount > 0 || maxBurden != nil else {
            return Suggestion(
                level: defaultLevel,
                isUserProvided: false,
                reason: "今天没有课程信息，按默认精力「\(defaultLevel.label)」估计。",
                burdenLevel: nil,
                courseMinutes: minutes
            )
        }

        let burden = maxBurden ?? .moderate
        let level: StudyEnergyLevel
        switch burden {
        case .veryHeavy:
            level = .tired
        case .heavy:
            level = minutes >= 240 ? .tired : .normal
        case .moderate:
            level = minutes >= 360 ? .tired : (minutes >= 180 ? .normal : .energetic)
        case .light:
            level = minutes >= 240 ? .normal : .energetic
        }

        let burdenText = maxBurden.map { "「\($0.label)」" } ?? "未标注（按「一般」）"
        return Suggestion(
            level: level,
            isUserProvided: false,
            reason: "按课表负担 \(burdenText) 与当天课程 \(minutes) 分钟估计为「\(level.label)」（可在可用时间设置中手动指定）。",
            burdenLevel: maxBurden,
            courseMinutes: minutes
        )
    }
}

// MARK: - 集中配置

/// 今日计划引擎的集中配置。
///
/// 所有排程参数都在这里，页面只读取展示、不各写一份：
/// - 可用时间利用比例默认 75%；
/// - 精力系数见 `StudyEnergyLevel`（较累 0.6 / 正常 0.8 / 充足 1.0）；
/// - 预算永不超过用户每日学习上限（在引擎内强制）。
struct DailyPlanEngineConfiguration: Hashable, Sendable {
    /// 可用时间利用比例（0...1）。默认 0.75。
    var utilizationRatio: Double
    /// 用户手动指定的精力；`nil` 表示使用课表估计。
    var energyOverride: StudyEnergyLevel?
    /// 没有课程信息时的默认精力。
    var defaultEnergyLevel: StudyEnergyLevel
    /// 考试"临近"的天数阈值。
    var examHorizonDays: Int
    /// "即将到期"的天数阈值。
    var nearDueDays: Int
    /// 低掌握度阈值。
    var lowMasteryThreshold: Double
    /// 预计耗时是否按 5 分钟取整。
    var roundsEstimatesToFiveMinutes: Bool
    /// 输入指纹相同时是否直接复用已有计划（重复生成不新增重复计划项）。
    ///
    /// 注意：G 的非强制刷新在调用引擎前已自行短路；若 `force = true` 时也要求
    /// 一定新建版本，把这里设为 `false`，或让 G 用新的输入指纹调用。
    var reusesUnchangedPlan: Bool

    init(
        utilizationRatio: Double = 0.75,
        energyOverride: StudyEnergyLevel? = nil,
        defaultEnergyLevel: StudyEnergyLevel = .normal,
        examHorizonDays: Int = 14,
        nearDueDays: Int = 3,
        lowMasteryThreshold: Double = 0.45,
        roundsEstimatesToFiveMinutes: Bool = true,
        reusesUnchangedPlan: Bool = true
    ) {
        self.utilizationRatio = min(max(utilizationRatio, 0), 1)
        self.energyOverride = energyOverride
        self.defaultEnergyLevel = defaultEnergyLevel
        self.examHorizonDays = max(1, examHorizonDays)
        self.nearDueDays = max(0, nearDueDays)
        self.lowMasteryThreshold = min(max(lowMasteryThreshold, 0), 1)
        self.roundsEstimatesToFiveMinutes = roundsEstimatesToFiveMinutes
        self.reusesUnchangedPlan = reusesUnchangedPlan
    }

    /// 默认配置：利用率 75%、精力按课表估计、考试视野 14 天。
    static let standard = DailyPlanEngineConfiguration()
}

// MARK: - 时间空档

/// 一段可安排的连续空档（排程内部使用）。
struct PlanTimeGap: Hashable, Sendable {
    var start: Date
    var end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

// MARK: - 引擎

/// 本地今日计划引擎。
///
/// 典型接入方式（G）：
/// ```swift
/// let engine = LocalDailyPlanEngine(
///     configuration: .standard,
///     signalIndex: TaskSignalIndex(snapshot: state),
///     minimumPolicy: minimumPolicyImplementation
/// )
/// let proposal = engine.proposePlan(request)
/// ```
struct LocalDailyPlanEngine: DailyPlanEngine {
    var configuration: DailyPlanEngineConfiguration
    /// 只读信号索引（掌握度 / 错题 / 考试 / 课程负担）。为空时仍可排程，只是少了优先级信号。
    var signalIndex: TaskSignalIndex
    var priorityPolicy: TaskPriorityPolicy
    var durationEstimator: TaskDurationEstimator
    /// D 模块的最低任务策略。未注入时不做任何本地压缩。
    var minimumPolicy: (any MinimumPlanPolicy)?

    init(
        configuration: DailyPlanEngineConfiguration = .standard,
        signalIndex: TaskSignalIndex = .empty,
        priorityPolicy: TaskPriorityPolicy? = nil,
        durationEstimator: TaskDurationEstimator? = nil,
        minimumPolicy: (any MinimumPlanPolicy)? = nil
    ) {
        self.configuration = configuration
        self.signalIndex = signalIndex
        self.priorityPolicy = priorityPolicy ?? TaskPriorityPolicy(
            examHorizonDays: configuration.examHorizonDays,
            nearDueDays: configuration.nearDueDays,
            lowMasteryThreshold: configuration.lowMasteryThreshold
        )
        self.durationEstimator = durationEstimator ?? TaskDurationEstimator(
            roundsToFiveMinutes: configuration.roundsEstimatesToFiveMinutes
        )
        self.minimumPolicy = minimumPolicy
    }

    // MARK: 入口

    func proposePlan(_ request: DailyPlanRequest) -> DailyPlanProposal {
        let context = request.context
        let dayKey = request.dayKey
        let preferences = request.preferences
        let activePlan = request.activePlan

        // 0) 相同输入 → 复用，不新增重复计划项。
        if configuration.reusesUnchangedPlan, !request.forceReplan,
           let activePlan,
           activePlan.hasSameInput(as: request.inputFingerprint) {
            return Self.reuseProposal(activePlan: activePlan)
        }

        // 1) 容量：只使用未来空档（`availability` 已按 now 裁剪过）。
        let availabilityMissing = request.availability == nil
        let freeIntervals = (request.availability?.freeIntervals ?? [])
            .filter { $0.end > context.now }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }
        let capacityMinutes = freeIntervals.reduce(0) { $0 + $1.durationMinutes }

        // 2) 已学习的有效时间计入当天上限。
        let studiedMinutes = Self.studiedMinutes(completions: request.completions, dayKey: dayKey)
        let capRemaining = preferences.dailyCapMinutes.map { max(0, $0 - studiedMinutes) } ?? Int.max

        // 3) 精力：用户手动设置优先，否则按课表负担估计。
        let courseBlocks = (request.availability?.occupiedIntervals ?? []).filter { $0.kind == .course }
        let courseMinutes = courseBlocks.reduce(0) { $0 + $1.durationMinutes }
        let maxBurden = Self.maximumBurden(courseBlocks: courseBlocks, index: signalIndex)
        let energy = EnergyAdvisor.suggestion(
            courseMinutes: courseMinutes,
            courseCount: courseBlocks.count,
            maxBurden: maxBurden,
            userOverride: configuration.energyOverride,
            defaultLevel: configuration.defaultEnergyLevel
        )

        // 4) 预算：空档 × 利用比例 × 精力系数，且不超过每日上限剩余额度。
        let utilizationBudget = Int(
            (Double(capacityMinutes) * configuration.utilizationRatio * energy.level.coefficient).rounded(.down)
        )
        var budgetMinutes = max(0, min(utilizationBudget, capRemaining))

        // 5) 候选：收集 → 去重 → 排除已完成 / 无来源 / 空内容。
        let candidateSet = TaskCandidateBuilder.build(
            TaskCandidateInput(
                dayKey: dayKey,
                context: context,
                rawCandidates: request.candidates,
                existingPlans: request.existingPlans,
                completions: request.completions,
                signalIndex: signalIndex
            )
        )
        let excludedCompleted = candidateSet.exclusions.filter { $0.reason == .completedToday }.count
        let excludedDuplicate = candidateSet.exclusions.filter { $0.reason == .duplicateOfSameObject }.count

        // 6) 保护既有任务：用户固定 / 进行中 / 已完成，绝不移动或删除。
        let protectedItems = (activePlan?.items ?? []).filter {
            $0.isPinned || $0.status == .inProgress || $0.status == .completed
        }
        let protectedSources = Set(protectedItems.map(\.source))
        let protectedReservedMinutes = protectedItems
            .filter { $0.status != .completed }
            .reduce(0) { $0 + max(0, $1.estimatedMinutes) }
        budgetMinutes = max(0, budgetMinutes - protectedReservedMinutes)

        // 7) 空档扣除保护任务已占用的时间段。
        var gaps = freeIntervals.map { PlanTimeGap(start: $0.start, end: $0.end) }
        gaps = Self.subtracting(protectedItems, from: gaps)

        // 8) 时间增加：不自动提高已经承诺的目标，只输出可追加建议。
        let reason = Self.generationReason(
            request: request,
            activePlan: activePlan,
            capacityMinutes: capacityMinutes
        )
        var committedTarget: Int?
        if reason == .timeIncreased, let activePlan, activePlan.goal.targetMinutes > 0 {
            committedTarget = activePlan.goal.targetMinutes
            budgetMinutes = max(0, min(budgetMinutes, activePlan.goal.targetMinutes))
        }

        // 9) 排程。
        let planID = UUID()
        var items: [DailyPlanItem] = Self.reassigning(protectedItems, planID: planID)
        var unplaceable: [UnplaceablePlanItem] = []
        var rankedByItemID: [UUID: RankedTaskCandidate] = [:]
        var appendable: [String] = []
        var spentMinutes = 0
        var tierCounts: [TaskPriorityTier: Int] = [:]
        var hardDeadlineConflict = false

        for ranked in priorityPolicy.ranked(candidateSet.candidates) {
            // 已经作为保护任务保留 → 不重复排入。
            if protectedSources.contains(ranked.candidate.candidate.source) { continue }

            let durationEstimate = durationEstimator.estimate(
                for: ranked.candidate,
                risk: ranked.forgettingRisk,
                preferences: preferences.planning,
                before: request.durationCalibrationCutoff ?? context.now
            )
            let minutes = durationEstimate.minutes
            guard minutes > 0 else { continue }

            let earliest = Self.earliestStart(for: ranked, context: context)
            let remainingBudget = budgetMinutes - spentMinutes
            guard minutes <= remainingBudget else {
                // 预算不足：跳过这一条并继续尝试其它可执行任务（不中断）。
                let fitsInGaps = Self.firstFit(minutes: minutes, gaps: gaps, earliest: earliest, calendar: context.calendar) != nil
                if fitsInGaps, committedTarget != nil {
                    appendable.append("\(ranked.candidate.title)（约 \(minutes) 分钟）")
                }
                unplaceable.append(
                    Self.unplaceable(
                        ranked,
                        minutes: minutes,
                        reason: .insufficientCapacity,
                        detail: Self.budgetDetail(
                            availabilityMissing: availabilityMissing,
                            fitsInGaps: fitsInGaps,
                            budgetMinutes: budgetMinutes,
                            committedTarget: committedTarget
                        ),
                        dayKey: dayKey
                    )
                )
                if ranked.tier == .hardDeadline { hardDeadlineConflict = true }
                continue
            }

            // 稳定性：未开始的既有任务优先保留原时间段，不来回搬动。
            var placement = Self.existingWindowPlacement(
                for: ranked,
                activePlan: activePlan,
                gaps: gaps,
                minutes: minutes,
                context: context
            )
            if placement == nil {
                placement = Self.firstFit(minutes: minutes, gaps: gaps, earliest: earliest, calendar: context.calendar)
            }

            guard let placement else {
                let diagnosis = Self.diagnose(
                    minutes: minutes,
                    gaps: gaps,
                    earliest: earliest,
                    calendar: context.calendar,
                    isSplittable: ranked.candidate.candidate.isSplittable
                )
                unplaceable.append(
                    Self.unplaceable(
                        ranked,
                        minutes: minutes,
                        reason: diagnosis.reason,
                        detail: diagnosis.detail,
                        dayKey: dayKey
                    )
                )
                if ranked.tier == .hardDeadline { hardDeadlineConflict = true }
                continue
            }

            gaps = Self.consuming(placement, from: gaps)
            spentMinutes += minutes
            let existing = activePlan?.items.first { $0.source == ranked.candidate.candidate.source }
            let item = Self.makeItem(
                ranked: ranked,
                planID: planID,
                dayKey: dayKey,
                minutes: minutes,
                durationEstimateExplanation: durationEstimate.explanation,
                placement: placement,
                context: context,
                existing: existing
            )
            items.append(item)
            rankedByItemID[item.id] = ranked
            tierCounts[ranked.tier, default: 0] += 1
        }

        // 10) 接入 D 的最低任务策略（未接入时不自行压缩）。
        var mode: DailyPlanMode = .standard
        var minimumPolicyNote: String?
        var extraExplanationLines: [String] = []

        if !unplaceable.isEmpty,
           preferences.planning.autoReduceEnabled,
           preferences.planning.allowsMinimumPlan {
            if let minimumPolicy {
                let candidatePlan = DailyStudyPlan(
                    id: planID,
                    dayKey: dayKey,
                    mode: mode,
                    status: .active,
                    budget: DailyPlanBudget(
                        capacityMinutes: capacityMinutes,
                        dailyCapMinutes: preferences.dailyCapMinutes,
                        plannedMinutes: items.reduce(0) { $0 + $1.estimatedMinutes }
                    ),
                    items: items,
                    unplaceable: unplaceable,
                    createdAt: context.now,
                    updatedAt: context.now
                )
                let splittableIDs = Set(items.filter(\.isSplittable).map(\.id))
                let reduced = minimumPolicy.reduce(
                    plan: candidatePlan,
                    remainingMinutes: max(0, budgetMinutes - spentMinutes),
                    splittableItemIDs: splittableIDs,
                    context: context
                )
                if !reduced.isEmpty {
                    items = reduced.plan.items
                    mode = reduced.plan.mode
                    let changeText = reduced.changes.isEmpty
                        ? "无明细变更"
                        : reduced.changes.map(\.kind.label).joined(separator: "、")
                    minimumPolicyNote = "已接入最低任务策略（D）：\(reduced.changes.count) 项变更（\(changeText)）。"
                    extraExplanationLines.append(contentsOf: reduced.explanation.lines)
                    // 减量后按保留下来的任务重新统计层级。
                    tierCounts = Self.tierCounts(for: items, rankedByItemID: rankedByItemID)
                } else {
                    minimumPolicyNote = "已接入最低任务策略（D）：判定今天不需要减量。"
                }
            } else {
                minimumPolicyNote = "最低任务策略（D）尚未接入：今天放不下的任务保留在待安排列表，未做本地压缩。"
            }
        }

        // 11) 汇总与解释。
        let plannedMinutes = items.reduce(0) { $0 + $1.estimatedMinutes }
        let effectiveCapacityMinutes = min(capacityMinutes, preferences.dailyCapMinutes ?? capacityMinutes)
        let explanationInput = PlanExplanationInput(
            dayKey: dayKey,
            context: context,
            generationReason: reason,
            capacityMinutes: capacityMinutes,
            dailyCapMinutes: preferences.dailyCapMinutes,
            studiedMinutes: studiedMinutes,
            budgetMinutes: budgetMinutes,
            utilizationRatio: configuration.utilizationRatio,
            energy: energy.level,
            energyReason: energy.reason,
            energyWasUserProvided: energy.isUserProvided,
            plannedMinutes: plannedMinutes,
            committedTargetMinutes: committedTarget,
            placed: Self.explanationItems(
                for: items,
                rankedByItemID: rankedByItemID,
                dayKey: dayKey,
                configuration: configuration
            ),
            unplaceable: unplaceable,
            tierCounts: tierCounts,
            excludedCompletedCount: excludedCompleted,
            excludedDuplicateCount: excludedDuplicate,
            appendableSuggestions: appendable,
            availabilityAssumptions: request.availability?.assumptions ?? [],
            protectedItemCount: protectedItems.count,
            minimumPolicyNote: minimumPolicyNote,
            isOverloaded: plannedMinutes > effectiveCapacityMinutes
        )
        var explanation = PlanExplanationBuilder.explanation(for: explanationInput)
        explanation.lines.append(contentsOf: extraExplanationLines)

        // D 的减量可能移除硬截止任务：移除后冲突说明要跟着更新。
        if hardDeadlineConflict {
            explanation = Self.ensuringHardDeadlineNotice(explanation)
        }

        let plan = DailyStudyPlan(
            id: planID,
            dayKey: dayKey,
            version: (request.existingPlans.map(\.version).max() ?? 0) + 1,
            mode: mode,
            status: .active,
            budget: DailyPlanBudget(
                capacityMinutes: capacityMinutes,
                dailyCapMinutes: preferences.dailyCapMinutes,
                plannedMinutes: plannedMinutes
            ),
            goal: DailyPlanGoal(
                targetMinutes: budgetMinutes,
                targetScope: nil,
                label: Self.goalLabel(
                    capacityMinutes: capacityMinutes,
                    budgetMinutes: budgetMinutes,
                    utilizationRatio: configuration.utilizationRatio,
                    energy: energy.level,
                    energyWasUserProvided: energy.isUserProvided,
                    committedTarget: committedTarget
                ),
                isUserEdited: false
            ),
            explanation: explanation,
            items: items,
            unplaceable: unplaceable,
            inputFingerprint: request.inputFingerprint,
            durationCalibrationCutoff: request.durationCalibrationCutoff ?? context.now,
            supersedesPlanID: activePlan?.id,
            createdAt: context.now,
            updatedAt: context.now
        )

        return DailyPlanProposal(
            plan: plan,
            unplaceable: unplaceable,
            explanation: explanation,
            didReuseExistingPlan: false
        )
    }

    // MARK: 复用

    static func reuseProposal(activePlan: DailyStudyPlan) -> DailyPlanProposal {
        var explanation = activePlan.explanation
        explanation.lines.insert(
            "生成原因：输入没有变化，沿用第 \(activePlan.version) 版计划，未新增重复计划项。",
            at: 0
        )
        return DailyPlanProposal(
            plan: activePlan,
            unplaceable: activePlan.unplaceable,
            explanation: explanation,
            didReuseExistingPlan: true
        )
    }

    // MARK: 计算辅助

    static func studiedMinutes(completions: [CompletionEvent], dayKey: StudyDayKey) -> Int {
        completions
            .filter { $0.dayKey == dayKey && !$0.isRevoked }
            .reduce(0) { $0 + max(0, $1.actualMinutes) }
    }

    static func maximumBurden(courseBlocks: [OccupiedInterval], index: TaskSignalIndex) -> CourseBurdenLevel? {
        courseBlocks
            .compactMap { block in
                block.sourceCourseID.flatMap { index.courseBurdenByCourseID[$0] }
            }
            .max { $0.rank < $1.rank }
    }

    static func generationReason(
        request: DailyPlanRequest,
        activePlan: DailyStudyPlan?,
        capacityMinutes: Int
    ) -> DailyPlanGenerationReason {
        guard let activePlan else { return .firstGeneration }
        if activePlan.hasSameInput(as: request.inputFingerprint) { return .noChange }
        let previousCapacity = activePlan.budget.capacityMinutes
        if capacityMinutes < previousCapacity { return .timeReduced }
        if capacityMinutes > previousCapacity { return .timeIncreased }
        return .inputChanged
    }

    /// 期望开始时间：`preferredStart`（例如课程结束）与 `now` 取较晚者。
    static func earliestStart(for ranked: RankedTaskCandidate, context: PlanningContext) -> Date {
        let preferred = ranked.candidate.candidate.preferredStart
        guard let preferred else { return context.now }
        return max(preferred, context.now)
    }

    static func firstFit(
        minutes: Int,
        gaps: [PlanTimeGap],
        earliest: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date, index: Int)? {
        guard minutes > 0 else { return nil }
        for (index, gap) in gaps.enumerated() {
            let start = max(gap.start, earliest)
            guard let end = calendar.date(byAdding: .minute, value: minutes, to: start) else { continue }
            if end <= gap.end { return (start, end, index) }
        }
        return nil
    }

    /// 沿用既有时间段（稳定性）：只有当整段仍然落在同一段空档里、且不早于 now 时才复用。
    static func existingWindowPlacement(
        for ranked: RankedTaskCandidate,
        activePlan: DailyStudyPlan?,
        gaps: [PlanTimeGap],
        minutes: Int,
        context: PlanningContext
    ) -> (start: Date, end: Date, index: Int)? {
        guard let existing = activePlan?.items.first(where: { $0.source == ranked.candidate.candidate.source }),
              existing.status == .pending,
              let scheduledStart = existing.scheduledStart
        else { return nil }
        let start = max(scheduledStart, context.now)
        guard let end = context.calendar.date(byAdding: .minute, value: minutes, to: start) else { return nil }
        for (index, gap) in gaps.enumerated() where start >= gap.start && end <= gap.end {
            return (start, end, index)
        }
        return nil
    }

    static func consuming(
        _ placement: (start: Date, end: Date, index: Int),
        from gaps: [PlanTimeGap]
    ) -> [PlanTimeGap] {
        guard gaps.indices.contains(placement.index) else { return gaps }
        let gap = gaps[placement.index]
        var result = gaps
        result.remove(at: placement.index)
        if gap.start < placement.start {
            result.append(PlanTimeGap(start: gap.start, end: placement.start))
        }
        if placement.end < gap.end {
            result.append(PlanTimeGap(start: placement.end, end: gap.end))
        }
        return result.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
    }

    static func subtracting(_ items: [DailyPlanItem], from gaps: [PlanTimeGap]) -> [PlanTimeGap] {
        var result = gaps
        for item in items {
            guard let start = item.scheduledStart, let end = item.scheduledEnd, end > start else { continue }
            result = subtract(start: start, end: end, from: result)
        }
        return result
    }

    static func subtract(start: Date, end: Date, from gaps: [PlanTimeGap]) -> [PlanTimeGap] {
        var result: [PlanTimeGap] = []
        for gap in gaps {
            if end <= gap.start || start >= gap.end {
                result.append(gap)
                continue
            }
            if gap.start < start {
                result.append(PlanTimeGap(start: gap.start, end: start))
            }
            if end < gap.end {
                result.append(PlanTimeGap(start: end, end: gap.end))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
    }

    /// 放不下的原因判定：是"总量不够"还是"空档被切碎"。
    static func diagnose(
        minutes: Int,
        gaps: [PlanTimeGap],
        earliest: Date,
        calendar: Calendar,
        isSplittable: Bool
    ) -> (reason: UnplaceableReason, detail: String) {
        var total = 0
        var longest = 0
        for gap in gaps {
            let start = max(gap.start, earliest)
            let available = max(0, Int((gap.end.timeIntervalSince(start) / 60).rounded(.down)))
            total += available
            longest = max(longest, available)
        }
        if total < minutes {
            return (
                .insufficientCapacity,
                "今天剩余空档共 \(total) 分钟，放不下这条 \(minutes) 分钟的任务。"
            )
        }
        if longest < minutes {
            let hint = isSplittable
                ? "允许拆分的任务也需要一段连续空档；本轮不跨碎片硬塞，因此未排入。"
                : "这条任务不可拆分，不会被塞进多个零碎空档。"
            return (
                .notSplittable,
                "空档被课程与作息切碎，最长一段 \(longest) 分钟，放不下 \(minutes) 分钟的任务；\(hint)"
            )
        }
        return (
            .insufficientCapacity,
            "预算已排满，今天剩余 \(total) 分钟不足以安排这条 \(minutes) 分钟的任务。"
        )
    }

    static func budgetDetail(
        availabilityMissing: Bool,
        fitsInGaps: Bool,
        budgetMinutes: Int,
        committedTarget: Int?
    ) -> String {
        if availabilityMissing {
            return "缺少可用时间数据（未接入课表 / 作息计算），本次不排程。"
        }
        if fitsInGaps, let committedTarget {
            return "可用时间够，但为不提高已承诺目标 \(committedTarget) 分钟而未自动排入，作为可追加建议。"
        }
        return "当天预算（\(budgetMinutes) 分钟）已排满，跳过并继续尝试其它任务。"
    }

    static func makeItem(
        ranked: RankedTaskCandidate,
        planID: UUID,
        dayKey: StudyDayKey,
        minutes: Int,
        durationEstimateExplanation: String?,
        placement: (start: Date, end: Date, index: Int),
        context: PlanningContext,
        existing: DailyPlanItem?
    ) -> DailyPlanItem {
        let candidate = ranked.candidate
        let itemKey = TaskIdentity.itemKey(dayKey: dayKey, identityKey: candidate.identityKey)
        return DailyPlanItem(
            id: StudyStableKey.uuid(from: itemKey),
            planID: planID,
            source: candidate.candidate.source,
            title: candidate.title,
            plannedScope: candidate.plannedScope,
            minimumScope: candidate.minimumScope,
            estimatedMinutes: minutes,
            durationEstimateExplanation: durationEstimateExplanation,
            scheduledStart: placement.start,
            scheduledEnd: placement.end,
            scheduledDayKey: dayKey,
            dueDate: candidate.candidate.dueDate,
            status: .pending,
            isPinned: existing?.isPinned ?? candidate.candidate.isPinned,
            isSplittable: candidate.candidate.isSplittable,
            carryOverCount: existing?.carryOverCount ?? 0,
            note: "第 \(ranked.tier.rawValue) 层（\(ranked.tier.label)）· 遗忘风险\(ranked.forgettingRisk.label)",
            createdAt: existing?.createdAt ?? context.now,
            updatedAt: context.now
        )
    }

    static func unplaceable(
        _ ranked: RankedTaskCandidate,
        minutes: Int,
        reason: UnplaceableReason,
        detail: String,
        dayKey: StudyDayKey
    ) -> UnplaceablePlanItem {
        UnplaceablePlanItem(
            id: StudyStableKey.uuid(from: "unplaceable|\(dayKey.localDateString)|\(ranked.candidate.identityKey)"),
            source: ranked.candidate.candidate.source,
            title: ranked.candidate.title,
            plannedScope: ranked.candidate.plannedScope,
            estimatedMinutes: minutes,
            reason: reason,
            detail: ranked.tier == .hardDeadline ? "硬截止任务。\(detail)" : detail
        )
    }

    static func reassigning(_ items: [DailyPlanItem], planID: UUID) -> [DailyPlanItem] {
        items.map { item in
            var copy = item
            copy.planID = planID
            return copy
        }
    }

    static func explanationItems(
        for items: [DailyPlanItem],
        rankedByItemID: [UUID: RankedTaskCandidate],
        dayKey: StudyDayKey,
        configuration: DailyPlanEngineConfiguration
    ) -> [PlacedExplanationItem] {
        items
            .compactMap { item -> PlacedExplanationItem? in
                guard let ranked = rankedByItemID[item.id] else { return nil }
                return PlacedExplanationItem(
                    title: item.title,
                    sourceKind: item.source.kind,
                    tier: ranked.tier,
                    minutes: item.estimatedMinutes,
                    start: item.scheduledStart,
                    end: item.scheduledEnd,
                    dueDate: item.dueDate,
                    reason: ranked.tier.label
                )
            }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                switch (lhs.start, rhs.start) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                default: return lhs.title < rhs.title
                }
            }
    }

    static func tierCounts(
        for items: [DailyPlanItem],
        rankedByItemID: [UUID: RankedTaskCandidate]
    ) -> [TaskPriorityTier: Int] {
        var counts: [TaskPriorityTier: Int] = [:]
        for item in items {
            guard let ranked = rankedByItemID[item.id] else { continue }
            counts[ranked.tier, default: 0] += 1
        }
        return counts
    }

    static func ensuringHardDeadlineNotice(_ explanation: DailyPlanExplanation) -> DailyPlanExplanation {
        guard !explanation.blockedReasons.contains(where: { $0.contains("硬截止") }) else { return explanation }
        var copy = explanation
        copy.blockedReasons.insert("有硬截止任务今天没有排入（明细见待安排列表），未伪造为已安排。", at: 0)
        return copy
    }

    static func goalLabel(
        capacityMinutes: Int,
        budgetMinutes: Int,
        utilizationRatio: Double,
        energy: StudyEnergyLevel,
        energyWasUserProvided: Bool,
        committedTarget: Int?
    ) -> String {
        let percent = Int((utilizationRatio * 100).rounded())
        let energyText = "\(energy.label) \(String(format: "%.1f", energy.coefficient))\(energyWasUserProvided ? "（用户设置）" : "（估计）")"
        if let committedTarget {
            return "保留上一版承诺目标 \(committedTarget) 分钟（空档增至 \(capacityMinutes) 分钟，未自动加码）"
        }
        return "目标 \(budgetMinutes) 分钟 = 空档 \(capacityMinutes) 分钟 × \(percent)% × 精力 \(energyText)"
    }
}
