import Foundation

enum StudyReportPeriod: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "本周"
        case .month: return "本月"
        }
    }

    var detailTitle: String {
        switch self {
        case .week: return "本周学习报告"
        case .month: return "本月学习报告"
        }
    }
}

struct StudyProgressReport {
    struct WeakSubject: Identifiable {
        var id: String { subject }
        var subject: String
        var averageMastery: Double
        var weakKnowledgeCount: Int
        var representativeTitles: [String]
    }

    struct ErrorPattern: Identifiable {
        var id: String { type }
        var type: String
        var count: Int
        var examples: [String]
    }

    struct UpcomingFocus: Identifiable {
        var id = UUID()
        var title: String
        var reason: String
        var icon: String
    }

    var period: StudyReportPeriod
    var startDate: Date
    var endDate: Date
    var generatedAt: Date
    var completedCount: Int
    var dueUnfinishedCount: Int
    var overdueTaskCount: Int
    var weakSubjects: [WeakSubject]
    var repeatedErrorPatterns: [ErrorPattern]
    var nextSuggestions: [UpcomingFocus]

    var completionRate: Double {
        let total = completedCount + dueUnfinishedCount
        guard total > 0 else { return completedCount > 0 ? 1 : 0 }
        return Double(completedCount) / Double(total)
    }

    var completionRatePercent: Int {
        Int((completionRate * 100).rounded())
    }

    var topWeakSubjectText: String {
        guard let subject = weakSubjects.first else { return "暂无明显薄弱科目" }
        return "\(subject.subject) · \(Int((subject.averageMastery * 100).rounded()))%"
    }

    var topErrorPatternText: String {
        guard let pattern = repeatedErrorPatterns.first else { return "暂无高频错误类型" }
        return "\(pattern.type) · \(pattern.count) 次"
    }

    var summarySentence: String {
        if completedCount == 0 && dueUnfinishedCount == 0 && weakSubjects.isEmpty {
            return "还没有足够数据生成诊断，先完成几次复习后这里会自动变得更有用。"
        }
        if overdueTaskCount > 0 {
            return "\(period.title)完成 \(completedCount) 项，仍有 \(overdueTaskCount) 个逾期任务，建议先清掉最早到期的内容。"
        }
        if let subject = weakSubjects.first {
            return "\(period.title)完成率 \(completionRatePercent)%，当前最需要照顾的是 \(subject.subject)。"
        }
        return "\(period.title)完成率 \(completionRatePercent)%，整体节奏稳定，可以继续按计划推进。"
    }

    static func make(from snapshot: StoreSnapshot, period: StudyReportPeriod, now: Date = Date()) -> StudyProgressReport {
        let calendar = Calendar.current
        let interval = dateInterval(for: period, now: now, calendar: calendar)
        let todayStart = calendar.startOfDay(for: now)
        let completedCount = completedTaskCount(from: snapshot, in: interval, calendar: calendar)
        let dueUnfinishedTasks = snapshot.reviewTasks.filter { task in
            task.status == .pending
                && task.dueDate >= interval.start
                && task.dueDate <= now
        }
        let overdueTasks = snapshot.reviewTasks.filter { task in
            task.status == .pending && task.dueDate < todayStart
        }
        let weakSubjects = makeWeakSubjects(from: snapshot.knowledgePoints)
        let errorPatterns = makeErrorPatterns(from: snapshot, in: interval)
        let suggestions = makeSuggestions(
            completedCount: completedCount,
            dueUnfinishedCount: dueUnfinishedTasks.count,
            overdueTaskCount: overdueTasks.count,
            weakSubjects: weakSubjects,
            errorPatterns: errorPatterns,
            period: period
        )

        return StudyProgressReport(
            period: period,
            startDate: interval.start,
            endDate: interval.end,
            generatedAt: now,
            completedCount: completedCount,
            dueUnfinishedCount: dueUnfinishedTasks.count,
            overdueTaskCount: overdueTasks.count,
            weakSubjects: weakSubjects,
            repeatedErrorPatterns: errorPatterns,
            nextSuggestions: suggestions
        )
    }

    private static func dateInterval(for period: StudyReportPeriod, now: Date, calendar: Calendar) -> DateInterval {
        switch period {
        case .week:
            if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                return DateInterval(start: interval.start, end: minDate(interval.end, now))
            }
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
            return DateInterval(start: start, end: now)
        case .month:
            if let interval = calendar.dateInterval(of: .month, for: now) {
                return DateInterval(start: interval.start, end: minDate(interval.end, now))
            }
            let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
            return DateInterval(start: start, end: now)
        }
    }

    private static func completedTaskCount(from snapshot: StoreSnapshot, in interval: DateInterval, calendar: Calendar) -> Int {
        let recordCount = snapshot.dailyActivityRecords.reduce(0) { partial, record in
            guard let date = recordDate(from: record.dateString, calendar: calendar),
                  date >= interval.start,
                  date <= interval.end else {
                return partial
            }
            return partial + record.completedTaskCount
        }

        let reviewedTaskCount = snapshot.reviewTasks.filter { task in
            guard let reviewedAt = task.lastReviewedAt else { return false }
            return reviewedAt >= interval.start && reviewedAt <= interval.end
        }.count

        return max(recordCount, reviewedTaskCount)
    }

    private static func recordDate(from dateString: String, calendar: Calendar) -> Date? {
        let parts = dateString.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return nil }
        return DateComponents(calendar: calendar, year: parts[0], month: parts[1], day: parts[2]).date
    }

    private static func makeWeakSubjects(from points: [KnowledgePoint]) -> [WeakSubject] {
        let grouped = Dictionary(grouping: points) { point in
            let subject = point.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            return subject.isEmpty ? "未分类" : subject
        }

        return grouped.compactMap { subject, items in
            let weakPoints = items
                .filter { $0.mastery < 0.7 }
                .sorted {
                    if $0.mastery != $1.mastery {
                        return $0.mastery < $1.mastery
                    }
                    return $0.createdAt > $1.createdAt
                }
            guard !weakPoints.isEmpty else { return nil }
            let average = items.reduce(0) { $0 + min(max($1.mastery, 0), 1) } / Double(max(items.count, 1))
            return WeakSubject(
                subject: subject,
                averageMastery: average,
                weakKnowledgeCount: weakPoints.count,
                representativeTitles: Array(weakPoints.prefix(3).map(\.title))
            )
        }
        .sorted {
            if $0.averageMastery != $1.averageMastery {
                return $0.averageMastery < $1.averageMastery
            }
            return $0.weakKnowledgeCount > $1.weakKnowledgeCount
        }
        .prefix(4)
        .map { $0 }
    }

    private static func makeErrorPatterns(from snapshot: StoreSnapshot, in interval: DateInterval) -> [ErrorPattern] {
        let knowledgeByID = Dictionary(uniqueKeysWithValues: snapshot.knowledgePoints.map { ($0.id, $0) })
        let mistakesInPeriod = snapshot.mistakes.filter { $0.createdAt >= interval.start && $0.createdAt <= interval.end }
        let sourceMistakes = mistakesInPeriod.isEmpty ? snapshot.mistakes : mistakesInPeriod
        let grouped = Dictionary(grouping: sourceMistakes) { mistake in
            errorType(for: mistake, knowledgeByID: knowledgeByID)
        }

        return grouped.map { type, mistakes in
            ErrorPattern(
                type: type,
                count: mistakes.count,
                examples: Array(mistakes
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(2)
                    .map { $0.question.compactedForStudyText(limit: 42) })
            )
        }
        .filter { $0.count >= 2 || grouped.count == 1 }
        .sorted {
            if $0.count != $1.count {
                return $0.count > $1.count
            }
            return $0.type < $1.type
        }
        .prefix(4)
        .map { $0 }
    }

    private static func errorType(for mistake: Mistake, knowledgeByID: [UUID: KnowledgePoint]) -> String {
        let reason = mistake.errorReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchable = reason.lowercased()

        let rules: [(String, [String])] = [
            ("审题偏差", ["审题", "题意", "看错", "漏看", "理解题目"]),
            ("概念混淆", ["概念", "定义", "公式", "定理", "原理", "混淆"]),
            ("计算失误", ["计算", "算错", "符号", "运算", "化简", "粗心"]),
            ("步骤缺漏", ["步骤", "过程", "推导", "证明", "漏步", "不完整"]),
            ("记忆不牢", ["记忆", "背诵", "忘记", "不熟", "默写"]),
            ("表达不清", ["表达", "书写", "格式", "单位", "答题规范"])
        ]

        if let matched = rules.first(where: { _, keywords in
            keywords.contains { searchable.localizedCaseInsensitiveContains($0) }
        }) {
            return matched.0
        }

        if let subject = mistake.knowledgePointIDs
            .compactMap({ knowledgeByID[$0]?.subject.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return "\(subject)错题"
        }

        if !reason.isEmpty {
            return reason.compactedForStudyText(limit: 12)
        }

        return "未分类错误"
    }

    private static func makeSuggestions(
        completedCount: Int,
        dueUnfinishedCount: Int,
        overdueTaskCount: Int,
        weakSubjects: [WeakSubject],
        errorPatterns: [ErrorPattern],
        period: StudyReportPeriod
    ) -> [UpcomingFocus] {
        var suggestions: [UpcomingFocus] = []

        if overdueTaskCount > 0 {
            suggestions.append(UpcomingFocus(
                title: "先清逾期任务",
                reason: "把最早到期的 \(min(overdueTaskCount, 5)) 个任务放到下一次学习的开头，避免滚雪球。",
                icon: "clock.badge.exclamationmark"
            ))
        }

        if let weak = weakSubjects.first {
            let titles = weak.representativeTitles.isEmpty ? "薄弱知识点" : weak.representativeTitles.joined(separator: "、")
            suggestions.append(UpcomingFocus(
                title: "补强 \(weak.subject)",
                reason: "围绕 \(titles) 做一次小测和错因复盘。",
                icon: "target"
            ))
        }

        if let pattern = errorPatterns.first {
            suggestions.append(UpcomingFocus(
                title: "专项处理\(pattern.type)",
                reason: "把同类错题集中重做，记录触发条件，下一轮复习先看这类题。",
                icon: "exclamationmark.triangle"
            ))
        }

        let total = completedCount + dueUnfinishedCount
        if total == 0 {
            suggestions.append(UpcomingFocus(
                title: "建立第一份报告数据",
                reason: "完成 3-5 个复习任务后，报告会开始识别趋势和薄弱点。",
                icon: "chart.bar.doc.horizontal"
            ))
        } else if Double(completedCount) / Double(max(total, 1)) < 0.6 {
            suggestions.append(UpcomingFocus(
                title: "降低每日任务密度",
                reason: "下一阶段先保留 2-3 个核心任务，把低优先级内容顺延。",
                icon: "slider.horizontal.3"
            ))
        } else {
            suggestions.append(UpcomingFocus(
                title: "\(period.title)节奏可以延续",
                reason: "保持当前完成强度，下阶段增加一次混合回顾来检查迁移能力。",
                icon: "checkmark.seal"
            ))
        }

        return Array(suggestions.prefix(4))
    }

    private static func minDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs < rhs ? lhs : rhs
    }
}
