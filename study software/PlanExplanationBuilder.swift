import Foundation

// MARK: - 计划解释构建（模块 C）
//
// 回答两个问题：
//   1. 为什么是这些任务？（层级计数 + 每条任务的来源、层级与时间段）
//   2. 为什么是这个任务量？（可用空档 → 利用比例 → 精力系数 → 每日上限 → 已学习时长的完整推导）
//
// 同时把"放不下"的任务如实写进 `blockedReasons`，不伪造已经排入。
// 纯计算，不读写文件、不发通知、不改全局状态。

/// 计划生成原因。随每个计划版本一起记录（与输入指纹并存）。
enum DailyPlanGenerationReason: String, Codable, CaseIterable, Sendable {
    case firstGeneration
    case inputChanged
    case timeReduced
    case timeIncreased
    case noChange

    var label: String {
        switch self {
        case .firstGeneration: return "首次生成"
        case .inputChanged: return "任务或偏好有变化"
        case .timeReduced: return "可用时间减少"
        case .timeIncreased: return "可用时间增加"
        case .noChange: return "输入未变化"
        }
    }
}

/// 已排入计划的单条任务（仅用于生成解释文本）。
struct PlacedExplanationItem: Hashable {
    var title: String
    var sourceKind: DailyPlanItemSourceKind
    var tier: TaskPriorityTier
    var minutes: Int
    var start: Date?
    var end: Date?
    var dueDate: Date?
    var reason: String
}

/// 解释构建输入。
struct PlanExplanationInput {
    var dayKey: StudyDayKey
    var context: PlanningContext
    var generationReason: DailyPlanGenerationReason
    /// 未来的可安排空档总分钟数（已按 `now` 裁剪，不含已过去的时间）。
    var capacityMinutes: Int
    var dailyCapMinutes: Int?
    /// 当天已学习并计入上限的分钟数（来自完成事件）。
    var studiedMinutes: Int
    /// 本次排程使用的预算（分钟）。
    var budgetMinutes: Int
    var utilizationRatio: Double
    var energy: StudyEnergyLevel
    var energyReason: String
    var energyWasUserProvided: Bool
    var plannedMinutes: Int
    /// 上一版承诺的目标（时间增加时不会被自动提高）。
    var committedTargetMinutes: Int?
    var placed: [PlacedExplanationItem]
    var unplaceable: [UnplaceablePlanItem]
    var tierCounts: [TaskPriorityTier: Int]
    var excludedCompletedCount: Int
    var excludedDuplicateCount: Int
    /// 时间增加时"可追加但未自动排入"的建议。
    var appendableSuggestions: [String]
    /// B 模块给出的假设（例如"未设置作息，按默认假设计算"）。
    var availabilityAssumptions: [String]
    var protectedItemCount: Int
    var minimumPolicyNote: String?
    /// 固定 / 进行中任务加上新安排是否已超出容量。
    var isOverloaded: Bool

    init(
        dayKey: StudyDayKey,
        context: PlanningContext,
        generationReason: DailyPlanGenerationReason,
        capacityMinutes: Int,
        dailyCapMinutes: Int? = nil,
        studiedMinutes: Int = 0,
        budgetMinutes: Int = 0,
        utilizationRatio: Double = 0.75,
        energy: StudyEnergyLevel = .normal,
        energyReason: String = "",
        energyWasUserProvided: Bool = false,
        plannedMinutes: Int = 0,
        committedTargetMinutes: Int? = nil,
        placed: [PlacedExplanationItem] = [],
        unplaceable: [UnplaceablePlanItem] = [],
        tierCounts: [TaskPriorityTier: Int] = [:],
        excludedCompletedCount: Int = 0,
        excludedDuplicateCount: Int = 0,
        appendableSuggestions: [String] = [],
        availabilityAssumptions: [String] = [],
        protectedItemCount: Int = 0,
        minimumPolicyNote: String? = nil,
        isOverloaded: Bool = false
    ) {
        self.dayKey = dayKey
        self.context = context
        self.generationReason = generationReason
        self.capacityMinutes = max(0, capacityMinutes)
        self.dailyCapMinutes = dailyCapMinutes.map { max(0, $0) }
        self.studiedMinutes = max(0, studiedMinutes)
        self.budgetMinutes = max(0, budgetMinutes)
        self.utilizationRatio = utilizationRatio
        self.energy = energy
        self.energyReason = energyReason
        self.energyWasUserProvided = energyWasUserProvided
        self.plannedMinutes = max(0, plannedMinutes)
        self.committedTargetMinutes = committedTargetMinutes
        self.placed = placed
        self.unplaceable = unplaceable
        self.tierCounts = tierCounts
        self.excludedCompletedCount = max(0, excludedCompletedCount)
        self.excludedDuplicateCount = max(0, excludedDuplicateCount)
        self.appendableSuggestions = appendableSuggestions
        self.availabilityAssumptions = availabilityAssumptions
        self.protectedItemCount = max(0, protectedItemCount)
        self.minimumPolicyNote = minimumPolicyNote
        self.isOverloaded = isOverloaded
    }
}

enum PlanExplanationBuilder {
    /// 计划项预览的最大条数（避免解释文本过长）。
    static let maximumItemPreviews = 5
    /// 最多列出几条"排不下"的明细。
    static let maximumBlockedDetails = 3

    static func explanation(for input: PlanExplanationInput) -> DailyPlanExplanation {
        var lines: [String] = []
        var assumptions: [String] = []
        var blocked: [String] = []

        lines.append("生成原因：\(input.generationReason.label)。")

        // 时间与容量的完整推导。
        let capText = input.dailyCapMinutes.map { "\($0) 分钟" } ?? "未设置"
        lines.append(
            "时间：今天剩余可安排空档 \(input.capacityMinutes) 分钟；每日学习上限 \(capText)；今天已学习并计入上限 \(input.studiedMinutes) 分钟。"
        )
        let percent = Int((input.utilizationRatio * 100).rounded())
        lines.append(
            "任务量：可用空档 × \(percent)% × 精力系数 \(energyCoefficientText(input.energy))（\(input.energyWasUserProvided ? "用户设置" : "估计")）= 预算 \(input.budgetMinutes) 分钟。"
        )
        if let committed = input.committedTargetMinutes {
            lines.append("时间比上一版更多，但已承诺目标 \(committed) 分钟保持不变，不自动加码。")
        }
        if let note = input.minimumPolicyNote {
            lines.append(note)
        }

        // 为什么是这些任务。
        let tierText = TaskPriorityTier.allCases
            .compactMap { tier -> String? in
                guard let count = input.tierCounts[tier], count > 0 else { return nil }
                return "\(tier.label) \(count)"
            }
            .joined(separator: " · ")
        if input.placed.isEmpty {
            lines.append("安排：今天没有排入任务（没有候选任务或预算为 0）。")
        } else {
            lines.append("安排：\(input.placed.count) 项任务，共 \(input.plannedMinutes) 分钟。" + (tierText.isEmpty ? "" : "层级分布：\(tierText)。"))
        }

        for item in input.placed.prefix(maximumItemPreviews) {
            lines.append("· " + previewText(for: item, context: input.context))
        }
        if input.placed.count > maximumItemPreviews {
            lines.append("· 其余 \(input.placed.count - maximumItemPreviews) 项按同一层级顺序排列。")
        }

        if input.protectedItemCount > 0 {
            lines.append("已保留 \(input.protectedItemCount) 项用户固定 / 进行中 / 已完成任务，自动排程不会移动它们。")
        }
        if input.excludedCompletedCount > 0 {
            lines.append("已排除 \(input.excludedCompletedCount) 项今天已经完成过的任务，不重复排入。")
        }
        if input.excludedDuplicateCount > 0 {
            lines.append("已合并 \(input.excludedDuplicateCount) 项重复任务（同一错题 / 知识点 / 课程只排一次）。")
        }
        if !input.appendableSuggestions.isEmpty {
            lines.append("可追加（未自动排入）：" + input.appendableSuggestions.joined(separator: "、"))
        }

        // 假设。
        assumptions.append("精力系数来源：\(input.energyReason)")
        assumptions.append("规划时区：\(input.context.timeZoneIdentifier)；学习日：\(input.dayKey.localDateString)。")
        assumptions.append("所有任务只安排在未来空档内；课间与服务缓冲已由可用时间计算扣除。")
        assumptions.append(contentsOf: input.availabilityAssumptions)

        // 阻塞原因（硬截止优先，绝不伪造已排入）。
        let hardDeadlines = input.unplaceable.filter { item in
            item.detail.contains("硬截止")
        }
        for item in hardDeadlines {
            blocked.append("硬截止任务「\(item.title)」今天放不下（\(item.reason.label)）：\(item.detail) 已保留在待安排列表，未排入计划。")
        }
        let others = input.unplaceable.filter { !hardDeadlines.contains($0) }
        if !others.isEmpty {
            let reasons = Dictionary(grouping: others, by: { $0.reason })
                .map { "\($0.key.label) \($0.value.count) 项" }
                .sorted()
                .joined(separator: "、")
            blocked.append("另有 \(others.count) 项今天没有排入：\(reasons)。这些任务保留在待安排列表，不会丢失，到期日期不变。")
            for item in others.prefix(maximumBlockedDetails) {
                blocked.append("· \(item.title)：\(item.detail)")
            }
        }
        if input.isOverloaded {
            blocked.append("当天已学习时长加上已安排任务已超过可用容量：用户固定 / 进行中任务不会被自动移走，因此总量可能超过预算。")
        }

        return DailyPlanExplanation(lines: lines, assumptions: assumptions, blockedReasons: blocked)
    }

    // MARK: 文本

    static func energyCoefficientText(_ energy: StudyEnergyLevel) -> String {
        String(format: "%.1f", energy.coefficient)
    }

    static func previewText(for item: PlacedExplanationItem, context: PlanningContext) -> String {
        var text = ""
        if let start = item.start, let end = item.end {
            text += "\(timeText(start, context: context))–\(timeText(end, context: context)) "
        }
        text += "\(item.sourceKind.label)：\(item.title)"
        if let dueDate = item.dueDate {
            text += "（到期 \(dateText(dueDate, context: context))）"
        }
        text += "｜\(item.reason)"
        return text
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
        formatter.dateFormat = "MM-dd"
        formatter.timeZone = context.timeZone
        return formatter.string(from: date)
    }
}
