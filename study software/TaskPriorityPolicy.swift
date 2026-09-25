import Foundation

// MARK: - 任务优先级策略（模块 C）
//
// 严格的六层层级（数字越小越先安排）：
//   1. 必须在当天完成的硬截止任务
//   2. 高遗忘风险、低掌握度的到期任务
//   3. 临近考试的重要任务
//   4. 当天课程回顾
//   5. 次日预习
//   6. 普通知识巩固
//
// 同一层内再按"显式优先级 → 到期时间 → 预计耗时 → 稳定身份键"排序，
// 因此**相同输入必然得到相同顺序**（与传入顺序无关）。
//
// 纯计算：不读时钟、不读写文件、不发通知、不改全局状态。

/// 层级。顺序即排程顺序。
enum TaskPriorityTier: Int, Codable, CaseIterable, Comparable, Sendable {
    case hardDeadline = 1
    case forgettingRisk = 2
    case examFocus = 3
    case courseReview = 4
    case preview = 5
    case consolidation = 6

    static func < (lhs: TaskPriorityTier, rhs: TaskPriorityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .hardDeadline: return "当天硬截止"
        case .forgettingRisk: return "遗忘风险"
        case .examFocus: return "临近考试"
        case .courseReview: return "课程回顾"
        case .preview: return "次日预习"
        case .consolidation: return "普通巩固"
        }
    }

    var explanation: String {
        switch self {
        case .hardDeadline: return "到期日就是今天或已经逾期，必须今天完成。"
        case .forgettingRisk: return "临近到期且掌握度低 / 复习间隔短，遗忘风险高。"
        case .examFocus: return "所属科目有临近的考试目标。"
        case .courseReview: return "今天上过的课，安排当天回顾。"
        case .preview: return "明天有课，安排课前预习。"
        case .consolidation: return "没有紧迫期限的日常巩固。"
        }
    }
}

/// 遗忘风险等级。只根据真实数据（掌握度、SM-2 状态、逾期情况）判定。
enum ForgettingRisk: String, Codable, CaseIterable, Comparable, Sendable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: ForgettingRisk, rhs: ForgettingRisk) -> Bool { lhs.rank < rhs.rank }

    var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

/// 带层级与风险判定的候选。
struct RankedTaskCandidate: Hashable {
    var candidate: TaskCandidate
    var tier: TaskPriorityTier
    var forgettingRisk: ForgettingRisk
}

/// 优先级策略。参数集中在 `DailyPlanEngineConfiguration` 里注入，不散落在页面。
struct TaskPriorityPolicy: Hashable, Sendable {
    /// 考试"临近"的天数阈值。
    var examHorizonDays: Int
    /// "即将到期"的天数阈值（用于第 2 层）。
    var nearDueDays: Int
    /// 低掌握度阈值（0...1）。
    var lowMasteryThreshold: Double

    init(
        examHorizonDays: Int = 14,
        nearDueDays: Int = 3,
        lowMasteryThreshold: Double = 0.45
    ) {
        self.examHorizonDays = max(1, examHorizonDays)
        self.nearDueDays = max(0, nearDueDays)
        self.lowMasteryThreshold = min(max(lowMasteryThreshold, 0), 1)
    }

    // MARK: 层级

    func tier(for candidate: TaskCandidate) -> TaskPriorityTier {
        tier(for: candidate.candidate, signals: candidate.signals)
    }

    func tier(for planCandidate: PlanCandidate, signals: TaskSignals) -> TaskPriorityTier {
        let kind = planCandidate.source.kind
        let dueTodayOrOverdue = signals.overdueDays > 0 || signals.dueWithinDays == 0

        switch kind {
        case .reviewTask, .manual:
            // 1) 硬截止：今天到期或已逾期。
            if dueTodayOrOverdue { return .hardDeadline }
            // 2) 即将到期且高遗忘风险 / 低掌握度。
            if let dueWithin = signals.dueWithinDays, dueWithin <= nearDueDays {
                if forgettingRisk(for: signals) == .high { return .forgettingRisk }
                if let mastery = signals.mastery, mastery < lowMasteryThreshold { return .forgettingRisk }
            }
            // 3) 临近考试。
            if isExamFocus(signals) { return .examFocus }
            if kind == .manual { return .consolidation }
            // 复习任务没有紧迫到期日时按普通巩固处理。
            if signals.dueWithinDays == nil { return .consolidation }
            if let dueWithin = signals.dueWithinDays, dueWithin > nearDueDays, forgettingRisk(for: signals) == .high {
                return .forgettingRisk
            }
            return .consolidation

        case .courseReview:
            // 当天课程回顾：即使科目命中考试，也仍然排在第 4 层；
            // 但若该科目考试非常临近，则升级到第 3 层（考试优先于课程回顾）。
            if isExamFocus(signals) { return .examFocus }
            return .courseReview

        case .preview:
            if isExamFocus(signals) { return .examFocus }
            return .preview
        }
    }

    func isExamFocus(_ signals: TaskSignals) -> Bool {
        guard signals.matchesExamSubject, let days = signals.examDaysRemaining else { return false }
        return days <= examHorizonDays
    }

    /// 遗忘风险：只用真实数据判定，不猜。
    func forgettingRisk(for signals: TaskSignals) -> ForgettingRisk {
        var score = 0

        if signals.overdueDays > 0 { score += signals.overdueDays >= 3 ? 3 : 2 }
        if signals.dueWithinDays == 0 { score += 2 }

        if let mastery = signals.mastery {
            if mastery < 0.35 { score += 3 }
            else if mastery < lowMasteryThreshold { score += 2 }
            else if mastery < 0.7 { score += 1 }
        } else {
            // 没有掌握度记录：按"未验证"轻微加权，不当作已掌握。
            score += 1
        }

        if let repetition = signals.repetitionCount {
            if repetition == 0 { score += 2 }
            else if repetition == 1 { score += 1 }
        }
        if let interval = signals.reviewIntervalDays, interval <= 1, (signals.repetitionCount ?? 0) <= 1 {
            score += 1
        }
        if let quality = signals.lastQuality {
            if quality <= 2 { score += 2 }
            else if quality == 3 { score += 1 }
        }

        if score >= 5 { return .high }
        if score >= 2 { return .medium }
        return .low
    }

    // MARK: 排序

    /// 层级 + 层内稳定排序。
    func ranked(_ candidates: [TaskCandidate]) -> [RankedTaskCandidate] {
        candidates
            .map { RankedTaskCandidate(candidate: $0, tier: tier(for: $0), forgettingRisk: forgettingRisk(for: $0.signals)) }
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                let lhsPriority = lhs.candidate.signals.priority ?? 0
                let rhsPriority = rhs.candidate.signals.priority ?? 0
                if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
                let lhsDue = lhs.candidate.signals.dueDate
                let rhsDue = rhs.candidate.signals.dueDate
                if lhsDue != rhsDue {
                    switch (lhsDue, rhsDue) {
                    case let (l?, r?): return l < r
                    case (nil, _?): return false
                    case (_?, nil): return true
                    default: break
                    }
                }
                if lhs.candidate.estimatedMinutes != rhs.candidate.estimatedMinutes {
                    return lhs.candidate.estimatedMinutes < rhs.candidate.estimatedMinutes
                }
                return lhs.candidate.identityKey < rhs.candidate.identityKey
            }
    }

    // MARK: 解释

    /// 这条任务为什么在这个层级（写进计划项说明，便于界面解释）。
    func reason(for ranked: RankedTaskCandidate) -> String {
        let signals = ranked.candidate.signals
        var parts: [String] = ["第 \(ranked.tier.rawValue) 层（\(ranked.tier.label)）"]

        switch ranked.tier {
        case .hardDeadline:
            if signals.overdueDays > 0 {
                parts.append("已逾期 \(signals.overdueDays) 天")
            } else {
                parts.append("今天到期")
            }
        case .forgettingRisk:
            if let mastery = signals.mastery {
                parts.append("掌握度 \(Int((mastery * 100).rounded()))%")
            }
            parts.append("遗忘风险\(ranked.forgettingRisk.label)")
            if let dueWithin = signals.dueWithinDays {
                parts.append(dueWithin == 0 ? "今天到期" : "\(dueWithin) 天后到期")
            }
        case .examFocus:
            if let name = signals.nearestExamName, let days = signals.examDaysRemaining {
                parts.append("\(name) 还有 \(days) 天")
            }
        case .courseReview, .preview, .consolidation:
            if let dueWithin = signals.dueWithinDays, dueWithin > 0 {
                parts.append("\(dueWithin) 天后到期")
            }
        }
        return parts.joined(separator: " · ")
    }
}
