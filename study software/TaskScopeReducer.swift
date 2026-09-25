import Foundation

// MARK: - D 模块：任务范围压缩
//
// 职责：把一条任务的**内容范围**压到给定预算内，而不是只改一个预计分钟数。
//
// 严格约束（公共开发约束 4/8/9 与 D 模块压缩要求）：
// 1. 纯值计算：不读时钟（时间一律来自外部）、不写文件、不发通知、不改全局状态。
// 2. 不虚构内容：缺少结构化范围时（例如整题的复习任务）**不编造**子题或子知识点，
//    而是判定为"不可安全压缩"，交由 `MinimumPlanPolicy` 改用其他任务或顺延。
// 3. 一组题可以减少题数；不可拆分的整体只能整体保留或整体移出。
// 4. 压缩结果必须能说清"保留了什么、剩下了什么、为什么"。

// MARK: - 压缩判定

/// 单条任务的压缩结论。
enum TaskScopeReduction: Hashable, Sendable {
    /// 原范围就能放进预算，无需改动。
    case unchanged
    /// 已按内容量减少（保留了可交付的一部分）。
    case trimmed(StudyScope)
    /// 内容量已不能再减，但这条任务整体仍然值得做（整块占用）。
    case wholeItem
    /// 不可安全压缩且放不进预算 → 必须换别的任务或顺延。
    case cannotReduce

    /// 压缩后的范围；`nil` 表示"不由本策略决定"（原样或整体移出）。
    var reducedScope: StudyScope? {
        switch self {
        case .trimmed(let scope): return scope
        case .unchanged, .wholeItem, .cannotReduce: return nil
        }
    }

    var isTrimmed: Bool {
        if case .trimmed = self { return true }
        return false
    }
}

/// 压缩后的任务量（范围 + 分钟 + 原因）。分钟永远跟着范围走，不独立变动。
struct TaskScopeReductionOutcome: Hashable, Sendable {
    var reduction: TaskScopeReduction
    /// 压缩后的内容范围。
    var scope: StudyScope
    /// 压缩后的预计分钟数。
    var estimatedMinutes: Int
    /// 保留内容的自然语言描述（界面直接展示）。
    var keptSummary: String
    /// 剩余内容的自然语言描述。
    var remainingSummary: String
    /// 为什么这样压（界面直接展示）。
    var reason: String

    init(
        reduction: TaskScopeReduction,
        scope: StudyScope,
        estimatedMinutes: Int,
        keptSummary: String,
        remainingSummary: String,
        reason: String
    ) {
        self.reduction = reduction
        self.scope = scope
        self.estimatedMinutes = max(0, estimatedMinutes)
        self.keptSummary = keptSummary
        self.remainingSummary = remainingSummary
        self.reason = reason
    }

    var isTrimmed: Bool { reduction.isTrimmed }
}

// MARK: - 配置

/// 压缩参数。全部可注入，便于测试固定阈值。
struct TaskScopeReducerConfiguration: Hashable, Sendable {
    /// 一次减量最少要留下多少分钟，低于这个数就不值得单独安排。
    var minimumUsefulMinutes: Int

    init(minimumUsefulMinutes: Int = 5) {
        self.minimumUsefulMinutes = max(1, minimumUsefulMinutes)
    }

    static let `default` = TaskScopeReducerConfiguration()
}

// MARK: - Reducer

/// 任务范围压缩器。
enum TaskScopeReducer {
    /// 哪些量纲允许按内容量减少。
    ///
    /// - `questions`（一组题）→ 减少题数；
    /// - `pages` / `sections` → 减少页数 / 节数；
    /// - `custom` → 用户自定义的可数单位（例如单词）。
    ///
    /// `tasks` 表示"一条不可再分的任务"（例如一次复习），`minutes` 只是时间声明。
    /// 这两种都**不能**靠改数字来假装减量，否则就是压缩要求第 3 条禁止的行为。
    static func isReducibleUnit(_ unit: StudyScopeUnit) -> Bool {
        switch unit {
        case .questions, .pages, .sections: return true
        case .custom: return true
        case .tasks, .minutes: return false
        }
    }

    /// 能否在不编造内容的前提下缩小这条任务。
    static func canReduce(_ item: DailyPlanItem) -> Bool {
        guard item.plannedScope.isPositive else { return false }
        guard isReducibleUnit(item.plannedScope.unit) else { return false }
        let lowerBound = item.minimumScope.flatMap { item.plannedScope.isComparable(to: $0) ? $0.amount : nil } ?? 1
        return item.plannedScope.amount - lowerBound >= 1
    }

    /// 按可用分钟压缩一条任务。
    ///
    /// 计算顺序：
    /// 1. 预算已够 → `unchanged`（哪怕它可减，也不动用户的范围）；
    /// 2. 可减 → 按 `预算 / 预计分钟` 的比例缩小**内容量**，再夹到 `minimumScope` 与至少 1 个单位；
    /// 3. 可减但缩完仍放不下 → 仍然返回能缩到的最小结构化范围（由策略决定是否采用）；
    /// 4. 不可减 → 放得下就是 `wholeItem`，放不下就是 `cannotReduce`（换任务或顺延）。
    ///
    /// 关键：内容量减少时，预计分钟按同一比例减少，并保证 `>= 1`，
    /// 因此不会出现"改了分钟但还是 15 分钟的题量"这种假减量。
    /// 按可用分钟压缩一条任务（自动推算目标范围）。
    static func reduce(
        item: DailyPlanItem,
        availableMinutes: Int,
        configuration: TaskScopeReducerConfiguration = .default
    ) -> TaskScopeReductionOutcome {
        reduce(item: item, to: nil, availableMinutes: availableMinutes, configuration: configuration)
    }

    /// 压缩到指定范围，或按可用分钟自动推算。
    ///
    /// `desiredScope` 非空时表示调用方（`MinimumPlanPolicy`）已经算好要保留多少内容，
    /// 例如"保底只需要 2 页"。此时:
    /// - 目标大于等于原范围 → `unchanged`（不放大）；
    /// - 目标小于原范围但可减 → `trimmed`；
    /// - 目标小于原范围且不可减 → `cannotReduce`（不编造子内容）。
    static func reduce(
        item: DailyPlanItem,
        to desiredScope: StudyScope?,
        availableMinutes: Int,
        configuration: TaskScopeReducerConfiguration = .default
    ) -> TaskScopeReductionOutcome {
        let available = max(0, availableMinutes)
        let plannedMinutes = max(0, item.estimatedMinutes)

        if let desiredScope {
            return reduceToDesiredScope(
                item: item,
                desiredScope: desiredScope,
                availableMinutes: available,
                plannedMinutes: plannedMinutes,
                configuration: configuration
            )
        }

        if plannedMinutes <= available {
            return TaskScopeReductionOutcome(
                reduction: .unchanged,
                scope: item.plannedScope,
                estimatedMinutes: plannedMinutes,
                keptSummary: item.plannedScope.displayText,
                remainingSummary: "",
                reason: "剩余时间够用，保持原范围。"
            )
        }

        guard canReduce(item) else {
            if available >= plannedMinutes {
                return TaskScopeReductionOutcome(
                    reduction: .unchanged,
                    scope: item.plannedScope,
                    estimatedMinutes: plannedMinutes,
                    keptSummary: item.plannedScope.displayText,
                    remainingSummary: "",
                    reason: "剩余时间够用，保持原范围。"
                )
            }
            return TaskScopeReductionOutcome(
                reduction: .cannotReduce,
                scope: item.plannedScope,
                estimatedMinutes: plannedMinutes,
                keptSummary: "",
                remainingSummary: item.plannedScope.displayText,
                reason: unavailableReason(for: item, available: available)
            )
        }

        // 按"时间预算 / 原预计分钟"折算内容量。只缩小，绝不放大。
        let ratio = plannedMinutes > 0 ? Double(available) / Double(plannedMinutes) : 0
        var reduced = item.plannedScope.scaled(by: min(1, max(0, ratio)), rounding: .down)

        // 夹到任务自己的保底范围（存在时），保证不低于用户认可的最低量。
        if let minimum = item.minimumScope, item.plannedScope.isComparable(to: minimum), reduced.amount < minimum.amount {
            reduced = minimum
        }
        if reduced.amount < 1 {
            reduced = StudyScope(unit: item.plannedScope.unit, amount: 1, customUnitLabel: item.plannedScope.customUnitLabel)
        }
        if reduced.amount >= item.plannedScope.amount {
            reduced = StudyScope(
                unit: item.plannedScope.unit,
                amount: max(1, item.plannedScope.amount - 1),
                customUnitLabel: item.plannedScope.customUnitLabel
            )
        }

        let reducedMinutes = estimatedMinutes(for: reduced, planned: item.plannedScope, plannedMinutes: plannedMinutes)
        let kept = reduced.displayText
        let remainingAmount = max(0, item.plannedScope.amount - reduced.amount)
        let remaining = StudyScope(
            unit: item.plannedScope.unit,
            amount: remainingAmount,
            customUnitLabel: item.plannedScope.customUnitLabel
        )

        return TaskScopeReductionOutcome(
            reduction: .trimmed(reduced),
            scope: reduced,
            estimatedMinutes: reducedMinutes,
            keptSummary: kept,
            remainingSummary: remaining.isZero ? "" : remaining.displayText,
            reason: trimmedReason(item: item, reduced: reduced, available: available, configuration: configuration)
        )
    }

    /// 压到调用方指定的内容范围。
    private static func reduceToDesiredScope(
        item: DailyPlanItem,
        desiredScope: StudyScope,
        availableMinutes: Int,
        plannedMinutes: Int,
        configuration: TaskScopeReducerConfiguration
    ) -> TaskScopeReductionOutcome {
        let planned = item.plannedScope

        // 量纲不同 → 不做任何换算，也不假装减量。
        guard planned.isComparable(to: desiredScope) else {
            return TaskScopeReductionOutcome(
                reduction: .cannotReduce,
                scope: planned,
                estimatedMinutes: plannedMinutes,
                keptSummary: "",
                remainingSummary: planned.displayText,
                reason: "目标范围与任务量纲不一致，无法在不编造内容的前提下换算。"
            )
        }

        if desiredScope.amount >= planned.amount {
            return TaskScopeReductionOutcome(
                reduction: .unchanged,
                scope: planned,
                estimatedMinutes: plannedMinutes,
                keptSummary: planned.displayText,
                remainingSummary: "",
                reason: "目标范围不小于原范围，保持原范围。"
            )
        }

        guard canReduce(item) else {
            return TaskScopeReductionOutcome(
                reduction: .cannotReduce,
                scope: planned,
                estimatedMinutes: plannedMinutes,
                keptSummary: "",
                remainingSummary: planned.displayText,
                reason: unavailableReason(for: item, available: availableMinutes)
            )
        }

        var reduced = desiredScope
        if let minimum = item.minimumScope, planned.isComparable(to: minimum), reduced.amount < minimum.amount {
            reduced = minimum
        }
        if reduced.amount < 1 {
            reduced = StudyScope(unit: planned.unit, amount: 1, customUnitLabel: planned.customUnitLabel)
        }
        if reduced.amount >= planned.amount {
            reduced = StudyScope(
                unit: planned.unit,
                amount: max(1, planned.amount - 1),
                customUnitLabel: planned.customUnitLabel
            )
        }

        let reducedMinutes = min(plannedMinutes, estimatedMinutes(for: reduced, planned: planned, plannedMinutes: plannedMinutes))
        let remaining = StudyScope(
            unit: planned.unit,
            amount: max(0, planned.amount - reduced.amount),
            customUnitLabel: planned.customUnitLabel
        )

        return TaskScopeReductionOutcome(
            reduction: .trimmed(reduced),
            scope: reduced,
            estimatedMinutes: max(0, reducedMinutes),
            keptSummary: reduced.displayText,
            remainingSummary: remaining.isZero ? "" : remaining.displayText,
            reason: trimmedReason(item: item, reduced: reduced, available: availableMinutes, configuration: configuration)
        )
    }

    /// 按同一比例折算分钟，至少 1 分钟，绝不出现"0 分钟但要学 3 页"。
    static func estimatedMinutes(
        for scope: StudyScope,
        planned: StudyScope,
        plannedMinutes: Int
    ) -> Int {
        guard planned.amount > 0, plannedMinutes > 0 else { return max(1, plannedMinutes) }
        let ratio = min(1, max(0, scope.amount / planned.amount))
        return max(1, Int((Double(plannedMinutes) * ratio).rounded(.down)))
    }

    // MARK: 说明文案

    private static func unavailableReason(for item: DailyPlanItem, available: Int) -> String {
        if item.plannedScope.unit == .tasks {
            return "这是一条不可再拆的任务，剩余 \(available) 分钟放不下 \(item.plannedScope.displayText)，需要改为安排其他任务或顺延。"
        }
        if item.plannedScope.unit == .minutes {
            return "任务只声明了总时长、没有可减少的内容量，剩余 \(available) 分钟放不下，需要改为安排其他任务或顺延。"
        }
        return "任务内容已到最小可交付量，剩余 \(available) 分钟放不下，需要改为安排其他任务或顺延。"
    }

    private static func trimmedReason(
        item: DailyPlanItem,
        reduced: StudyScope,
        available: Int,
        configuration: TaskScopeReducerConfiguration
    ) -> String {
        var reason = "剩余 \(available) 分钟，把 \(item.plannedScope.displayText) 缩到 \(reduced.displayText)，保留可交付的一部分内容。"
        if let minimum = item.minimumScope, item.plannedScope.isComparable(to: minimum), reduced.amount <= minimum.amount {
            reason += " 已经到这条任务的最低可交付量（\(minimum.displayText)）。"
        }
        if reduced.amount <= 1 {
            reason += " 这是最小可保留量。"
        }
        if available < configuration.minimumUsefulMinutes {
            reason += " 剩余时间低于 \(configuration.minimumUsefulMinutes) 分钟，这一段可能只能做极少量内容。"
        }
        return reason
    }
}

// MARK: - 可压缩范围（`MinimumPlanPolicy` 的输入归一）

extension DailyPlanItem {
    /// 由计划项与调用方给的"可拆分项集合"共同决定的可压缩范围。
    ///
    /// `MinimumPlanPolicy.reduce` 的入参包含 `splittableItemIDs`，因此这里统一
    /// 说明"什么才算可压缩"：
    /// - 量纲本身可数（题/页/节/自定义）；且
    /// - 计划项标记为可拆分；或计划项已经带有 `minimumScope`（说明产出方认可它有更小可交付量）。
    static func splittableScope(
        for item: DailyPlanItem,
        splittableItemIDs: Set<UUID>
    ) -> StudyScope? {
        let markedSplittable = item.isSplittable || splittableItemIDs.contains(item.id) || item.minimumScope != nil
        guard markedSplittable else { return nil }
        guard TaskScopeReducer.canReduce(item) else { return nil }
        return item.minimumScope.flatMap { item.plannedScope.isComparable(to: $0) ? $0 : nil }
    }
}
