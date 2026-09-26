import Foundation

/// 仅把完成事件中的真实数量与已记录有效时长配对；按科目、任务类型和单位隔离样本。
struct TaskDurationHistory: Hashable, Sendable {
    struct Category: Hashable, Sendable {
        var subjectKey: String
        var kind: DailyPlanItemSourceKind
        var unit: StudyScopeUnit
        var customUnitLabel: String
    }

    struct Observation: Hashable, Sendable {
        var id: UUID
        var category: Category
        var completedAt: Date
        var minutesPerUnit: Double
    }

    struct Calibration: Hashable, Sendable {
        var minutes: Double
        var sampleCount: Int
    }

    static let empty = TaskDurationHistory(observations: [], subjectsByReviewTaskID: [:],
                                           subjectsByCourseID: [:], subjectsByKnowledgePointID: [:])
    static let minimumSampleCount = 5
    static let maximumRecentSamples = 20

    var observations: [Observation]
    var subjectsByReviewTaskID: [UUID: String]
    var subjectsByCourseID: [UUID: String]
    var subjectsByKnowledgePointID: [UUID: String]

    init(snapshot: StoreSnapshot) {
        var knowledgeSubjects: [UUID: String] = [:]
        for point in snapshot.knowledgePoints where knowledgeSubjects[point.id] == nil {
            knowledgeSubjects[point.id] = StudySubjectMatcher.normalized(point.subject)
        }
        var reviewSubjects: [UUID: String] = [:]
        for task in snapshot.reviewTasks where reviewSubjects[task.id] == nil {
            if let id = task.knowledgePointID, let subject = knowledgeSubjects[id] {
                reviewSubjects[task.id] = subject
            } else if let mistakeID = task.mistakeID,
                      let mistake = snapshot.mistakes.first(where: { $0.id == mistakeID }) {
                let subjects = Set(mistake.knowledgePointIDs.compactMap { knowledgeSubjects[$0] })
                if subjects.count == 1 { reviewSubjects[task.id] = subjects.first }
            }
        }
        var courseSubjects: [UUID: String] = [:]
        for course in snapshot.scheduleCourses where courseSubjects[course.id] == nil {
            courseSubjects[course.id] = StudySubjectMatcher.normalized(
                course.subject.linkedKnowledgeSubject ?? course.subject.displayName
            )
        }
        self.init(observations: [], subjectsByReviewTaskID: reviewSubjects,
                  subjectsByCourseID: courseSubjects, subjectsByKnowledgePointID: knowledgeSubjects)

        var sessions: [UUID: StudySession] = [:]
        for session in snapshot.studySessions where sessions[session.id] == nil { sessions[session.id] = session }
        // 旧完成事件可能只有计划项 ID。只有历史计划给出唯一来源时才用于校准，
        // 不根据标题或完成数量猜测科目与任务类型。
        let sourcesByPlanItemID = Dictionary(grouping: snapshot.dailyPlans.flatMap(\.items), by: \.id)
        for event in snapshot.completionEvents {
            let historicalSources = event.planItemID.flatMap { sourcesByPlanItemID[$0] } ?? []
            let uniqueSources = Set(historicalSources.map(\.source))
            let source = event.source ?? (uniqueSources.count == 1 ? uniqueSources.first : nil)
            guard !event.isRevoked, event.hasRecordedDuration,
                  let source,
                  let category = category(for: source, scope: event.completedScope) else { continue }
            let minutes: Int
            if event.durationSource == .timed, let sessionID = event.sessionID, let session = sessions[sessionID] {
                guard session.state == .finished, let effective = session.recordedEffectiveMinutes,
                      effective > 0 else { continue }
                minutes = effective
            } else {
                minutes = event.actualMinutes
            }
            let speed = Double(minutes) / event.completedScope.amount
            guard speed.isFinite, speed > 0 else { continue }
            observations.append(Observation(id: event.id, category: category,
                                            completedAt: event.completedAt, minutesPerUnit: speed))
        }
    }

    private init(observations: [Observation], subjectsByReviewTaskID: [UUID: String],
                 subjectsByCourseID: [UUID: String], subjectsByKnowledgePointID: [UUID: String]) {
        self.observations = observations
        self.subjectsByReviewTaskID = subjectsByReviewTaskID
        self.subjectsByCourseID = subjectsByCourseID
        self.subjectsByKnowledgePointID = subjectsByKnowledgePointID
    }

    func calibration(for source: DailyPlanItemSource, scope: StudyScope, before cutoff: Date) -> Calibration? {
        guard let category = category(for: source, scope: scope) else { return nil }
        let recent = observations
            .filter { $0.category == category && $0.completedAt < cutoff }
            .sorted {
                if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(Self.maximumRecentSamples)
        guard recent.count >= Self.minimumSampleCount else { return nil }
        let speeds = recent.map(\.minutesPerUnit).sorted()
        let middle = speeds.count / 2
        let median = speeds.count.isMultiple(of: 2)
            ? (speeds[middle - 1] + speeds[middle]) / 2 : speeds[middle]
        let minutes = median * scope.amount
        guard minutes.isFinite, minutes > 0 else { return nil }
        return Calibration(minutes: minutes, sampleCount: recent.count)
    }

    private func category(for source: DailyPlanItemSource, scope: StudyScope) -> Category? {
        guard scope.isPositive, scope.amount.isFinite, scope.unit != .minutes else { return nil }
        let subjectKey: String
        switch source.kind {
        case .reviewTask:
            guard let id = source.reviewTaskID else { return nil }
            subjectKey = subjectsByReviewTaskID[id]
                ?? source.knowledgePointID.flatMap { subjectsByKnowledgePointID[$0] }
                ?? "unclassified-review:\(id.uuidString)"
        case .courseReview, .preview:
            guard let id = source.courseID else { return nil }
            subjectKey = subjectsByCourseID[id] ?? "unclassified-course:\(id.uuidString)"
        case .manual:
            guard let id = source.manualTaskID ?? source.knowledgePointID else { return nil }
            subjectKey = source.knowledgePointID.flatMap { subjectsByKnowledgePointID[$0] }
                ?? "unclassified-manual:\(id.uuidString)"
        }
        return Category(subjectKey: subjectKey, kind: source.kind, unit: scope.unit,
                        customUnitLabel: scope.unit == .custom
                            ? (scope.customUnitLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : "")
    }
}

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
    var history: TaskDurationHistory

    init(roundsToFiveMinutes: Bool = true, minimumMinutes: Int = 5,
         history: TaskDurationHistory = .empty) {
        self.roundsToFiveMinutes = roundsToFiveMinutes
        self.minimumMinutes = max(1, minimumMinutes)
        self.history = history
    }

    struct Estimate: Hashable, Sendable {
        var minutes: Int
        var explanation: String?
    }

    func estimate(for candidate: TaskCandidate, risk: ForgettingRisk,
                  preferences: PlanningPreferences, before cutoff: Date) -> Estimate {
        let calibration = history.calibration(for: candidate.candidate.source,
                                              scope: candidate.plannedScope, before: cutoff)
        let base = calibration?.minutes ?? Double(max(1, candidate.estimatedMinutes))
        let factor = adjustmentFactor(risk: risk, mastery: candidate.signals.mastery)
        var minutes = base * factor

        let upperBound = Double(max(preferences.minimumTaskMinutes, preferences.maximumTaskMinutes))
        minutes = min(minutes, upperBound)

        // 短任务保持其真实长度：只有原本就更长时才抬到最小值。
        let lowerBound = min(base, Double(minimumMinutes))
        minutes = max(minutes, lowerBound)

        let result = roundedMinutes(minutes)
        let explanation = calibration.map {
            "根据最近 \($0.sampleCount) 次同科目、同类型记录，预计完成 \(candidate.plannedScope.displayText)需要约 \(result) 分钟。"
        }
        return Estimate(minutes: result, explanation: explanation)
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
