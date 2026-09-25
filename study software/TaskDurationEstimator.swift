import Foundation

// MARK: - 预计耗时估计（模块 C）
//
// 规则（全部可解释、可复现）：
//   - 基准耗时来自候选本身（真实任务的 planning 参数），不凭空生成；
//   - 遗忘风险高 → 略增（需要更多回顾轮次）；
//   - 掌握度高 → 略减；
//   - 结果被 `PlanningPreferences.maximumTaskMinutes` 封顶；
//   - 绝不把"本来很短的真实任务"拉长到最小任务时长以上（不为了填满预算放大任务量）；
//   - 稳定：同一输入永远得到同一分钟数；按 5 分钟取整便于排程与展示。
//
// 纯计算：不读时钟、不读写文件、不发通知、不改全局状态。

/// 耗时估计器。
struct TaskDurationEstimator: Hashable, Sendable {
    /// 是否把结果按 5 分钟取整（默认开启，排程与展示更稳定）。
    var roundsToFiveMinutes: Bool
    /// 估计下限（分钟）。只对"本来就更长"的任务生效，不会拉长短任务。
    var minimumMinutes: Int

    init(roundsToFiveMinutes: Bool = true, minimumMinutes: Int = 5) {
        self.roundsToFiveMinutes = roundsToFiveMinutes
        self.minimumMinutes = max(1, minimumMinutes)
    }

    /// 估计单条候选的耗时。
    func estimatedMinutes(
        for candidate: TaskCandidate,
        risk: ForgettingRisk,
        preferences: PlanningPreferences
    ) -> Int {
        let base = max(1, candidate.estimatedMinutes)
        let factor = adjustmentFactor(risk: risk, mastery: candidate.signals.mastery)
        var minutes = Double(base) * factor

        let upperBound = Double(max(preferences.minimumTaskMinutes, preferences.maximumTaskMinutes))
        minutes = min(minutes, upperBound)

        // 短任务保持其真实长度：只有原本就更长时才抬到最小值。
        let lowerBound = Double(min(base, minimumMinutes))
        minutes = max(minutes, lowerBound)

        return roundedMinutes(minutes)
    }

    /// 调整系数：风险 + 掌握度。
    func adjustmentFactor(risk: ForgettingRisk, mastery: Double?) -> Double {
        var factor = 1.0
        switch risk {
        case .high: factor *= 1.15
        case .medium: factor *= 1.05
        case .low: factor *= 1.0
        }
        if let mastery {
            if mastery >= 0.8 { factor *= 0.9 }
            else if mastery <= 0.2 { factor *= 1.1 }
        }
        return min(max(factor, 0.5), 1.5)
    }

    /// 单独暴露取整规则，便于测试与解释。
    func roundedMinutes(_ raw: Double) -> Int {
        guard raw > 0 else { return 1 }
        guard roundsToFiveMinutes, raw >= 5 else { return max(1, Int(raw.rounded())) }
        let rounded = (raw / 5).rounded() * 5
        return max(5, Int(rounded))
    }
}
