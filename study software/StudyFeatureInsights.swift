import Foundation

struct StudyCalendarDay: Identifiable {
    var id: String { DailyActivityRecord.dateString(from: date) }
    var date: Date
    var pendingTasks: [ReviewTask]
    var completedCount: Int
    var examGoals: [ExamGoal]

    var totalCount: Int {
        pendingTasks.count + completedCount
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    var hasWork: Bool {
        !pendingTasks.isEmpty || completedCount > 0 || !examGoals.isEmpty
    }

    var topTaskTitle: String {
        pendingTasks.first?.title ?? (examGoals.first?.name ?? "暂无安排")
    }
}

enum StudyCalendarPlanner {
    static func makeDays(snapshot: StoreSnapshot, daysBefore: Int = 3, daysAfter: Int = 24, now: Date = Date()) -> [StudyCalendarDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let recordsByDate = Dictionary(uniqueKeysWithValues: snapshot.dailyActivityRecords.map { ($0.dateString, $0.completedTaskCount) })
        let activeGoals = snapshot.activeExamGoals(now: now)

        return (-max(daysBefore, 0)...max(daysAfter, 0)).compactMap { offset -> StudyCalendarDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            let tasks = snapshot.reviewTasks
                .filter { $0.status == .pending && $0.dueDate >= start && $0.dueDate < end }
                .sorted {
                    if ($0.priority ?? 0) != ($1.priority ?? 0) {
                        return ($0.priority ?? 0) > ($1.priority ?? 0)
                    }
                    return $0.dueDate < $1.dueDate
                }
            let goals = activeGoals.filter { calendar.isDate($0.examDate, inSameDayAs: date) }
            return StudyCalendarDay(
                date: start,
                pendingTasks: tasks,
                completedCount: recordsByDate[DailyActivityRecord.dateString(from: start)] ?? 0,
                examGoals: goals
            )
        }
    }
}

enum ExamSprintPhase: String, CaseIterable, Identifiable {
    case foundation = "基础补齐"
    case intensive = "强化训练"
    case simulation = "模拟冲刺"
    case finalPolish = "考前收束"
    case finished = "已结束"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .foundation: return "books.vertical.fill"
        case .intensive: return "bolt.fill"
        case .simulation: return "timer"
        case .finalPolish: return "checkmark.seal.fill"
        case .finished: return "archivebox.fill"
        }
    }

    var summary: String {
        switch self {
        case .foundation:
            return "先补齐低掌握度知识点，避免后期带着漏洞做题。"
        case .intensive:
            return "集中处理高频错因和重点科目，每天保留专项训练。"
        case .simulation:
            return "加入整卷/限时训练，用结果反推薄弱点。"
        case .finalPolish:
            return "少做新题，多回看错题、公式和易混概念。"
        case .finished:
            return "考试目标已结束，可以归档或建立新的目标。"
        }
    }
}

struct ExamSprintPlan {
    var goal: ExamGoal
    var phase: ExamSprintPhase
    var daysRemaining: Int
    var dailyMinutes: Int
    var weakSubjects: [String]
    var overdueTaskCount: Int
    var dueThisWeekCount: Int
    var recommendedActions: [String]

    var capacityText: String {
        let minutes = max(dailyMinutes, 0)
        if minutes < 60 {
            return "\(minutes) 分钟/天"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) 小时/天" : "\(hours) 小时 \(rest) 分钟/天"
    }

    static func make(goal: ExamGoal, snapshot: StoreSnapshot, now: Date = Date()) -> ExamSprintPlan {
        let days = goal.daysRemaining(now: now)
        let phase = phaseFor(daysRemaining: days)
        let weakSubjects = weakSubjects(from: snapshot, matching: goal.subjects)
        let overdueTaskCount = snapshot.reviewTasks.filter { $0.status == .pending && $0.dueDate < Calendar.current.startOfDay(for: now) }.count
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now)) ?? now
        let dueThisWeekCount = snapshot.reviewTasks.filter { $0.status == .pending && $0.dueDate <= weekEnd }.count

        return ExamSprintPlan(
            goal: goal,
            phase: phase,
            daysRemaining: days,
            dailyMinutes: goal.dailyAvailableMinutes,
            weakSubjects: weakSubjects,
            overdueTaskCount: overdueTaskCount,
            dueThisWeekCount: dueThisWeekCount,
            recommendedActions: actions(for: phase, weakSubjects: weakSubjects, overdueTaskCount: overdueTaskCount, dueThisWeekCount: dueThisWeekCount)
        )
    }

    private static func phaseFor(daysRemaining: Int) -> ExamSprintPhase {
        if daysRemaining < 0 { return .finished }
        if daysRemaining <= 7 { return .finalPolish }
        if daysRemaining <= 21 { return .simulation }
        if daysRemaining <= 45 { return .intensive }
        return .foundation
    }

    private static func weakSubjects(from snapshot: StoreSnapshot, matching goalSubjects: [String]) -> [String] {
        let wanted = Set(goalSubjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let grouped = Dictionary(grouping: snapshot.knowledgePoints) { point in
            point.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未分类" : point.subject
        }

        return grouped.compactMap { subject, points -> (String, Double, Int)? in
            guard wanted.isEmpty || wanted.contains(subject) else { return nil }
            let average = points.reduce(0) { $0 + min(max($1.mastery, 0), 1) } / Double(max(points.count, 1))
            let weakCount = points.filter { $0.mastery < 0.7 }.count
            guard weakCount > 0 else { return nil }
            return (subject, average, weakCount)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 > $1.2
        }
        .prefix(4)
        .map(\.0)
    }

    private static func actions(for phase: ExamSprintPhase, weakSubjects: [String], overdueTaskCount: Int, dueThisWeekCount: Int) -> [String] {
        var actions: [String] = []
        if overdueTaskCount > 0 {
            actions.append("先清理 \(min(overdueTaskCount, 5)) 个逾期复习，避免计划继续堆积。")
        }
        if let subject = weakSubjects.first {
            actions.append("今天给 \(subject) 留出一个完整番茄钟，先复盘再做题。")
        }
        switch phase {
        case .foundation:
            actions.append("每天选择 2-3 个低掌握度知识点补笔记和例题。")
        case .intensive:
            actions.append("把同类错题放在一起重做，记录触发错误的条件。")
        case .simulation:
            actions.append("安排至少一次限时模拟，并用错因更新复习优先级。")
        case .finalPolish:
            actions.append("停止大规模开新内容，重点回看错题、公式和易混点。")
        case .finished:
            actions.append("归档这个考试目标，并保留错题作为长期复习资料。")
        }
        if dueThisWeekCount > 8 {
            actions.append("本周待复习 \(dueThisWeekCount) 项，可顺延低优先级任务。")
        }
        return Array(actions.prefix(4))
    }
}

enum KnowledgeGraphNodeKind: String {
    case subject = "科目"
    case knowledge = "知识点"
    case mistake = "错题"
    case document = "资料"
}

struct KnowledgeGraphNode: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var kind: KnowledgeGraphNodeKind
    var weight: Int
    var mastery: Double?
}

struct KnowledgeGraphEdge: Identifiable {
    var id: String { "\(from)->\(to)" }
    var from: String
    var to: String
    var label: String
}

struct KnowledgeGraph {
    var nodes: [KnowledgeGraphNode]
    var edges: [KnowledgeGraphEdge]

    var subjectCount: Int {
        nodes.filter { $0.kind == .subject }.count
    }

    var weakNodeCount: Int {
        nodes.filter { ($0.mastery ?? 1) < 0.6 }.count
    }

    static func make(from snapshot: StoreSnapshot) -> KnowledgeGraph {
        var nodes: [KnowledgeGraphNode] = []
        var edges: [KnowledgeGraphEdge] = []
        var insertedNodeIDs = Set<String>()

        func insert(_ node: KnowledgeGraphNode) {
            guard insertedNodeIDs.insert(node.id).inserted else { return }
            nodes.append(node)
        }

        for point in snapshot.knowledgePoints {
            let subject = point.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未分类" : point.subject
            let subjectID = "subject-\(subject)"
            insert(KnowledgeGraphNode(id: subjectID, title: subject, subtitle: "科目", kind: .subject, weight: 2, mastery: nil))
            let pointID = "knowledge-\(point.id.uuidString)"
            let linkedMistakes = snapshot.mistakes.filter { $0.knowledgePointIDs.contains(point.id) }.count
            insert(KnowledgeGraphNode(
                id: pointID,
                title: point.title,
                subtitle: "\(subject) · \(Int((point.mastery * 100).rounded()))% · \(linkedMistakes) 错题",
                kind: .knowledge,
                weight: max(1, linkedMistakes + 1),
                mastery: point.mastery
            ))
            edges.append(KnowledgeGraphEdge(from: subjectID, to: pointID, label: "包含"))
        }

        let knowledgeByID = Dictionary(uniqueKeysWithValues: snapshot.knowledgePoints.map { ($0.id, $0) })
        let documentsByID = Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.id, $0) })
        for mistake in snapshot.mistakes {
            let mistakeID = "mistake-\(mistake.id.uuidString)"
            insert(KnowledgeGraphNode(
                id: mistakeID,
                title: mistake.question.compactedForStudyText(limit: 30),
                subtitle: mistake.errorReason.compactedForStudyText(limit: 34),
                kind: .mistake,
                weight: max(1, mistake.knowledgePointIDs.count),
                mastery: 0.25
            ))

            for pointIDValue in mistake.knowledgePointIDs {
                guard knowledgeByID[pointIDValue] != nil else { continue }
                edges.append(KnowledgeGraphEdge(from: "knowledge-\(pointIDValue.uuidString)", to: mistakeID, label: "关联错题"))
            }

            if let documentID = mistake.sourceDocumentID,
               let document = documentsByID[documentID] {
                let documentNodeID = "document-\(document.id.uuidString)"
                insert(KnowledgeGraphNode(
                    id: documentNodeID,
                    title: document.title,
                    subtitle: document.kind.rawValue,
                    kind: .document,
                    weight: 1,
                    mastery: nil
                ))
                edges.append(KnowledgeGraphEdge(from: documentNodeID, to: mistakeID, label: "来源"))
            }
        }

        return KnowledgeGraph(nodes: nodes, edges: edges)
    }
}

struct DocumentSection: Identifiable {
    var id: String
    var documentID: UUID
    var documentTitle: String
    var title: String
    var excerpt: String
    var level: Int
    var ordinal: Int
}

enum DocumentSectionExtractor {
    static func extract(from document: StudyDocument) -> [DocumentSection] {
        let content = document.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return [] }

        let lines = content.components(separatedBy: .newlines)
        var headingIndexes: [(Int, String, Int)] = []
        for (index, line) in lines.enumerated() {
            if let match = heading(from: line) {
                headingIndexes.append((index, match.title, match.level))
            }
        }

        if headingIndexes.isEmpty {
            return chunkedSections(from: document, content: content)
        }

        return headingIndexes.enumerated().map { ordinal, heading in
            let nextIndex = ordinal + 1 < headingIndexes.count ? headingIndexes[ordinal + 1].0 : lines.count
            let body = lines[(heading.0 + 1)..<nextIndex].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return DocumentSection(
                id: "\(document.id.uuidString)-heading-\(ordinal)",
                documentID: document.id,
                documentTitle: document.title,
                title: heading.1,
                excerpt: body.isEmpty ? "这个章节暂时只有标题。" : body.compactedForStudyText(limit: 130),
                level: heading.2,
                ordinal: ordinal + 1
            )
        }
    }

    static func extractAll(from snapshot: StoreSnapshot) -> [DocumentSection] {
        snapshot.documents.flatMap { extract(from: $0) }
    }

    private static func heading(from line: String) -> (title: String, level: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 80 else { return nil }
        if trimmed.hasPrefix("#") {
            let level = min(trimmed.prefix { $0 == "#" }.count, 4)
            let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (title, level)
        }

        let patterns = [
            #"^第[一二三四五六七八九十百0-9]+[章节讲课]\s*.+"#,
            #"^[0-9]+(\.[0-9]+){0,3}\s+.+$"#,
            #"^(Chapter|Section|Unit)\s+[0-9A-Za-z]+.*$"#,
            #"^P(age)?\s*[0-9]+\s*[:：].+$"#
        ]

        for pattern in patterns where trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return (trimmed, 2)
        }
        return nil
    }

    private static func chunkedSections(from document: StudyDocument, content: String) -> [DocumentSection] {
        let chunkSize = 1_200
        var sections: [DocumentSection] = []
        var start = content.startIndex
        var ordinal = 1
        while start < content.endIndex {
            let end = content.index(start, offsetBy: chunkSize, limitedBy: content.endIndex) ?? content.endIndex
            let chunk = String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                sections.append(DocumentSection(
                    id: "\(document.id.uuidString)-chunk-\(ordinal)",
                    documentID: document.id,
                    documentTitle: document.title,
                    title: "片段 \(ordinal)",
                    excerpt: chunk.compactedForStudyText(limit: 130),
                    level: 3,
                    ordinal: ordinal
                ))
                ordinal += 1
            }
            start = end
        }
        return sections
    }
}

struct StudyReportForecast {
    var pendingCount: Int
    var overdueCount: Int
    var retentionRiskCount: Int
    var projectedClearDays: Int
    var workloadTitle: String
    var workloadDetail: String

    static func make(from snapshot: StoreSnapshot, now: Date = Date()) -> StudyReportForecast {
        let pending = snapshot.reviewTasks.filter { $0.status == .pending }
        let overdue = pending.filter { $0.dueDate < Calendar.current.startOfDay(for: now) }.count
        let risky = pending.filter { ($0.lastQuality ?? 5) <= 2 || ($0.priority ?? 0) >= 4 }.count
        let dailyCapacity = max(snapshot.nextExamGoal(now: now)?.dailyAvailableMinutes ?? 45, 30)
        let estimatedTaskCapacity = max(1, dailyCapacity / 15)
        let clearDays = Int(ceil(Double(pending.count) / Double(estimatedTaskCapacity)))
        let title: String
        let detail: String
        if overdue > 0 {
            title = "需要减压"
            detail = "仍有 \(overdue) 个逾期任务，建议先清最早到期和高优先级内容。"
        } else if clearDays > 7 {
            title = "任务偏满"
            detail = "按当前每日时间预计 \(clearDays) 天清完待复习，可顺延低优先级。"
        } else if pending.isEmpty {
            title = "节奏轻盈"
            detail = "当前没有待复习任务，可以导入新资料或做一次综合回顾。"
        } else {
            title = "节奏可控"
            detail = "按当前每日时间预计 \(clearDays) 天清完待复习。"
        }
        return StudyReportForecast(
            pendingCount: pending.count,
            overdueCount: overdue,
            retentionRiskCount: risky,
            projectedClearDays: clearDays,
            workloadTitle: title,
            workloadDetail: detail
        )
    }
}

struct StudyLoadBalanceDay: Identifiable {
    var id: String { DailyActivityRecord.dateString(from: date) }
    var date: Date
    var tasks: [ReviewTask]
    var plannedMinutes: Int
    var capacityMinutes: Int

    var overloadMinutes: Int {
        max(plannedMinutes - capacityMinutes, 0)
    }

    var isOverloaded: Bool {
        overloadMinutes > 0
    }
}

struct StudyLoadBalanceFocusItem: Identifiable {
    var id: UUID { taskID }
    var taskID: UUID
    var title: String
    var estimatedMinutes: Int
    var reason: String
}

struct StudyLoadBalanceMoveProposal: Identifiable {
    var id: UUID { taskID }
    var taskID: UUID
    var taskTitle: String
    var fromDate: Date
    var toDate: Date
    var estimatedMinutes: Int
    var reason: String
}

struct StudyLoadBalanceRecommendation: Identifiable {
    enum Kind: String {
        case postponeLowPriority
        case compressedSession
        case examMistakePriority
        case stable
    }

    var id: String { kind.rawValue }
    var kind: Kind
    var title: String
    var detail: String
    var icon: String
}

struct StudyLoadBalancePlan {
    var generatedAt: Date
    var dailyCapacityMinutes: Int
    var horizonDays: Int
    var examGoal: ExamGoal?
    var days: [StudyLoadBalanceDay]
    var compressedSessionItems: [StudyLoadBalanceFocusItem]
    var recommendations: [StudyLoadBalanceRecommendation]
    var moveProposals: [StudyLoadBalanceMoveProposal]

    var totalPendingCount: Int {
        days.reduce(0) { $0 + $1.tasks.count }
    }

    var overloadedDays: [StudyLoadBalanceDay] {
        days.filter(\.isOverloaded)
    }

    var overloadedDayCount: Int {
        overloadedDays.count
    }

    var totalOverloadMinutes: Int {
        overloadedDays.reduce(0) { $0 + $1.overloadMinutes }
    }

    var suggestedMoveCount: Int {
        moveProposals.count
    }

    var canApply: Bool {
        !moveProposals.isEmpty
    }

    var statusTitle: String {
        if totalPendingCount == 0 {
            return "暂无负荷"
        }
        if overloadedDayCount > 0 {
            return "\(overloadedDayCount) 天任务偏满"
        }
        if !compressedSessionItems.isEmpty {
            return "节奏可控"
        }
        return "负荷轻盈"
    }

    var statusDetail: String {
        if totalPendingCount == 0 {
            return "当前没有待复习任务，暂时不需要平衡。"
        }
        if suggestedMoveCount > 0 {
            return "建议顺延 \(suggestedMoveCount) 个低优先级任务，保留高优先级和错题任务。"
        }
        if overloadedDayCount > 0 {
            return "存在超载日期，但当前任务都比较关键，建议用 30 分钟压缩版先处理核心内容。"
        }
        return "未来 \(horizonDays) 天没有明显超载，可以按当前节奏推进。"
    }
}

// MARK: - 学习报告的学习量口径（统一状态来源）

/// 报告里"学习次数 / 实际分钟数 / 保底达标 / 标准达标"的分账。
///
/// 数据只来自**完成事件**（唯一权威）：
/// - 学习次数 = 完成事件条数（每条完成事件就是一次被记录的学习）；
/// - 实际分钟数 = `actualMinutes` 之和；
/// - 标准达标 / 保底达标 / 已学习 = 按 `PlanCompletionTier` 分别计数，互不折叠；
/// - 旧版本的"每日完成总数"单独展示，**不**折算成时长、明细或达标。
struct StudyActivityReport: Sendable {
    struct Day: Identifiable, Sendable {
        var id: String { dayKey.localDateString }
        var dayKey: StudyDayKey
        var studyCount: Int
        var recordedMinutes: Int
        var standardCount: Int
        var minimumCount: Int
        var studiedCount: Int
        var unrecordedDurationCount: Int
        var legacyCompletedTaskCount: Int?

        var hasRecords: Bool { studyCount > 0 || (legacyCompletedTaskCount ?? 0) > 0 }
    }

    var periodDays: Int
    var days: [Day]

    var studyDayCount: Int { days.filter(\.hasRecords).count }
    var studyCount: Int { days.reduce(0) { $0 + $1.studyCount } }
    /// 只汇总有效完成事件里的已记录时长；只有旧版任务总数时保持未知。
    var recordedMinutes: Int? {
        if studyCount > 0 {
            return days.reduce(0) { $0 + $1.recordedMinutes }
        }
        return legacyAggregateTaskCount > 0 ? nil : 0
    }
    var standardCompletedCount: Int { days.reduce(0) { $0 + $1.standardCount } }
    var minimumCompletedCount: Int { days.reduce(0) { $0 + $1.minimumCount } }
    var studiedOnlyCount: Int { days.reduce(0) { $0 + $1.studiedCount } }
    var unrecordedDurationCount: Int { days.reduce(0) { $0 + $1.unrecordedDurationCount } }
    /// 旧版汇总保留的任务项总数，和完成事件统计分开显示。
    var legacyAggregateTaskCount: Int { days.reduce(0) { $0 + ($1.legacyCompletedTaskCount ?? 0) } }
    /// 带有旧版汇总的天数；同一天也有新完成事件时仍单独说明旧汇总。
    var legacyAggregateDayCount: Int { days.filter { ($0.legacyCompletedTaskCount ?? 0) > 0 }.count }

    var isEmpty: Bool { studyDayCount == 0 && legacyAggregateDayCount == 0 }

    var summaryLines: [String] {
        let minutesText = recordedMinutes.map { "\($0) 分钟" } ?? "未知（旧版汇总不含时长）"
        var lines: [String] = [
            "学习次数：\(studyCount) 次（\(studyDayCount) 个有记录日）",
            "已记录学习时长：\(minutesText)",
            "标准完成：\(standardCompletedCount) 项 · 保底完成：\(minimumCompletedCount) 项",
            "仅学习未达标：\(studiedOnlyCount) 项",
            "完成但未记录时长：\(unrecordedDurationCount) 项（计入学习次数，不计入分钟数）"
        ]
        if legacyAggregateTaskCount > 0 {
            lines.append("另有旧版汇总 \(legacyAggregateTaskCount) 项，分布在 \(legacyAggregateDayCount) 天；未计入学习次数、分钟数或达标项数，也不推算时长。")
        }
        return lines
    }

    static func make(from snapshot: StoreSnapshot, periodDays: Int, now: Date) -> StudyActivityReport {
        let context = snapshot.planningContext(now: now)
        let horizon = min(max(periodDays, 1), 400)
        let todayKey = context.todayKey

        let days: [Day] = (0..<horizon).compactMap { offset in
            let dayKey = todayKey.advanced(byDays: -offset)
            let summary = snapshot.dailySummary(for: dayKey)
            let events = snapshot.completionEvents.filter { $0.dayKey == dayKey && !$0.isRevoked }
            guard !events.isEmpty || (summary.legacyCompletedTaskCount ?? 0) > 0 else { return nil }
            return Day(
                dayKey: dayKey,
                studyCount: events.count,
                recordedMinutes: summary.recordedMinutes ?? 0,
                standardCount: summary.standardCompletedItemCount,
                minimumCount: summary.minimumCompletedItemCount,
                studiedCount: summary.studiedItemCount,
                unrecordedDurationCount: summary.unrecordedDurationItemCount,
                legacyCompletedTaskCount: summary.legacyCompletedTaskCount
            )
        }

        return StudyActivityReport(periodDays: horizon, days: days)
    }
}

// MARK: - 时间预算检查（AI 生成的计划必须经过）

/// 未来若干天的"任务池 vs 可用容量"检查结果。
///
/// 只做检查与解释，不删改任何任务、不编造内容：
/// 超预算时由调用方在界面与诊断记录里如实提示，用户可自行顺延或减量。
struct StudyBudgetCheck: Hashable, Sendable {
    struct DayOverflow: Hashable, Sendable {
        var dayKey: StudyDayKey
        var plannedMinutes: Int
        var capacityMinutes: Int
        var taskCount: Int

        var overflowMinutes: Int { max(plannedMinutes - capacityMinutes, 0) }
    }

    var horizonDays: Int
    var totalPlannedMinutes: Int
    var capacityMinutesPerDay: Int
    var overflowDays: [DayOverflow]
    var taskCount: Int

    var isWithinBudget: Bool { overflowDays.isEmpty }

    var summary: String {
        guard taskCount > 0 else { return "时间预算检查通过：当前没有待安排的复习任务。" }
        guard !isWithinBudget else {
            return "时间预算检查通过：\(taskCount) 个任务共 \(totalPlannedMinutes) 分钟，均可放进未来 \(horizonDays) 天的可用时间。"
        }
        let worst = overflowDays.max { $0.overflowMinutes < $1.overflowMinutes }
        let detail = worst.map { "最紧张的是 \($0.dayKey.localDateString)（超出 \($0.overflowMinutes) 分钟）" } ?? ""
        return "时间预算提醒：未来 \(horizonDays) 天有 \(overflowDays.count) 天排不下\(detail)。任务已保留，可顺延或使用减量方案。"
    }
}

enum StudyBudgetChecker {
    static let defaultHorizonDays = 7

    /// 按学习日聚合计划分钟数，并对照统一容量（`AvailabilityCalculator`）检查。
    static func check(
        state: StoreSnapshot,
        horizonDays: Int = defaultHorizonDays,
        now: Date
    ) -> StudyBudgetCheck {
        let horizon = min(max(horizonDays, 1), 30)
        let context = state.planningContext(now: now)
        let calendar = context.calendar
        let todayStart = calendar.startOfDay(for: now)
        let horizonEnd = calendar.date(byAdding: .day, value: horizon, to: todayStart) ?? todayStart

        let pending = state.reviewTasks.filter { $0.status == .pending && $0.dueDate < horizonEnd }
        let totalPlanned = pending.reduce(0) { $0 + StudyLoadBalancer.estimatedMinutes(for: $1, snapshot: state) }

        let fallbackCapacity = max(state.nextExamGoal(now: now)?.dailyAvailableMinutes ?? 45, 30)
        var overflowDays: [StudyBudgetCheck.DayOverflow] = []

        for offset in 0..<horizon {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart) else { continue }
            let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let tasks = pending.filter { task in
                if offset == 0 && task.dueDate < todayStart { return true }
                return task.dueDate >= dayStart && task.dueDate < next
            }
            guard !tasks.isEmpty else { continue }

            let planned = tasks.reduce(0) { $0 + StudyLoadBalancer.estimatedMinutes(for: $1, snapshot: state) }
            let capacity = StudyLoadBalancer.capacityMinutesForBudget(
                for: dayStart,
                snapshot: state,
                fallback: fallbackCapacity,
                context: context
            )
            if planned > capacity {
                overflowDays.append(
                    StudyBudgetCheck.DayOverflow(
                        dayKey: StudyDayKey(date: dayStart, timeZone: context.timeZone),
                        plannedMinutes: planned,
                        capacityMinutes: capacity,
                        taskCount: tasks.count
                    )
                )
            }
        }

        return StudyBudgetCheck(
            horizonDays: horizon,
            totalPlannedMinutes: totalPlanned,
            capacityMinutesPerDay: fallbackCapacity,
            overflowDays: overflowDays,
            taskCount: pending.count
        )
    }
}

struct StudyLoadBalanceApplyResult {    var movedTaskIDs: [UUID]
    var proposals: [StudyLoadBalanceMoveProposal]
    var beforeOverloadedDayCount: Int
    var afterOverloadedDayCount: Int

    var summary: String {
        if movedTaskIDs.isEmpty {
            return "暂时没有可顺延的低优先级任务"
        }
        let reduced = max(beforeOverloadedDayCount - afterOverloadedDayCount, 0)
        if reduced > 0 {
            return "已顺延 \(movedTaskIDs.count) 个任务，减少 \(reduced) 天超载"
        }
        return "已顺延 \(movedTaskIDs.count) 个任务，负荷已重新分布"
    }
}

enum StudyLoadBalancer {
    static let defaultHorizonDays = 14
    static let compressedSessionMinutes = 30

    static func make(from snapshot: StoreSnapshot, horizonDays: Int = defaultHorizonDays, now: Date = Date()) -> StudyLoadBalancePlan {
        let normalizedHorizon = min(max(horizonDays, 7), 30)
        let dailyCapacity = capacityMinutes(from: snapshot, now: now)
        let days = makeDays(from: snapshot, horizonDays: normalizedHorizon, capacityMinutes: dailyCapacity, now: now)
        let examGoal = snapshot.nextExamGoal(now: now)
        let proposals = makeMoveProposals(
            days: days,
            snapshot: snapshot,
            dailyCapacity: dailyCapacity,
            examGoal: examGoal,
            now: now
        )
        let compressedItems = makeCompressedSessionItems(
            from: days.flatMap(\.tasks),
            snapshot: snapshot,
            examGoal: examGoal,
            now: now
        )
        let recommendations = makeRecommendations(
            days: days,
            compressedItems: compressedItems,
            proposals: proposals,
            examGoal: examGoal,
            now: now
        )

        return StudyLoadBalancePlan(
            generatedAt: now,
            dailyCapacityMinutes: dailyCapacity,
            horizonDays: normalizedHorizon,
            examGoal: examGoal,
            days: days,
            compressedSessionItems: compressedItems,
            recommendations: recommendations,
            moveProposals: proposals
        )
    }

    static func apply(to snapshot: inout StoreSnapshot, horizonDays: Int = defaultHorizonDays, now: Date = Date()) -> StudyLoadBalanceApplyResult {
        let plan = make(from: snapshot, horizonDays: horizonDays, now: now)
        guard !plan.moveProposals.isEmpty else {
            return StudyLoadBalanceApplyResult(
                movedTaskIDs: [],
                proposals: [],
                beforeOverloadedDayCount: plan.overloadedDayCount,
                afterOverloadedDayCount: plan.overloadedDayCount
            )
        }

        var movedTaskIDs: [UUID] = []
        for proposal in plan.moveProposals {
            guard let index = snapshot.reviewTasks.firstIndex(where: { $0.id == proposal.taskID }) else { continue }
            let oldDate = snapshot.reviewTasks[index].dueDate
            snapshot.reviewTasks[index].dueDate = scheduledDate(on: proposal.toDate, preservingTimeFrom: oldDate, now: now)
            snapshot.reviewTasks[index].status = .pending
            movedTaskIDs.append(proposal.taskID)
        }

        let afterPlan = make(from: snapshot, horizonDays: horizonDays, now: now)
        return StudyLoadBalanceApplyResult(
            movedTaskIDs: movedTaskIDs,
            proposals: plan.moveProposals.filter { movedTaskIDs.contains($0.taskID) },
            beforeOverloadedDayCount: plan.overloadedDayCount,
            afterOverloadedDayCount: afterPlan.overloadedDayCount
        )
    }

    static func estimatedMinutes(for task: ReviewTask, snapshot: StoreSnapshot) -> Int {
        var minutes = 12

        if task.mistakeID != nil {
            minutes += 8
        }

        let priority = task.priority ?? 0
        if priority >= 5 {
            minutes += 6
        } else if priority >= 4 {
            minutes += 4
        } else if priority <= 1 {
            minutes -= 3
        }

        if let quality = task.lastQuality {
            if quality <= 2 {
                minutes += 6
            } else if quality == 3 {
                minutes += 3
            } else if quality >= 5 {
                minutes -= 2
            }
        }

        if let pointID = task.knowledgePointID,
           let point = snapshot.knowledgePoints.first(where: { $0.id == pointID }),
           point.mastery < 0.45 {
            minutes += 4
        }

        return min(max(minutes, 8), 30)
    }

    private static func makeDays(
        from snapshot: StoreSnapshot,
        horizonDays: Int,
        capacityMinutes: Int,
        now: Date
    ) -> [StudyLoadBalanceDay] {
        // 负荷平衡改用统一容量与安排机制（与今日计划同源）。
        let context = snapshot.planningContext(now: now)
        let calendar = context.calendar
        let today = calendar.startOfDay(for: now)
        let horizonEnd = calendar.date(byAdding: .day, value: horizonDays, to: today) ?? today
        let pendingTasks = snapshot.reviewTasks
            .filter { $0.status == .pending && $0.dueDate < horizonEnd }

        return (0..<horizonDays).compactMap { offset -> StudyLoadBalanceDay? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let nextDate = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            let tasks = pendingTasks
                .filter { task in
                    if offset == 0 && task.dueDate < today {
                        return true
                    }
                    return task.dueDate >= date && task.dueDate < nextDate
                }
                .sorted {
                    if ($0.priority ?? 0) != ($1.priority ?? 0) {
                        return ($0.priority ?? 0) > ($1.priority ?? 0)
                    }
                    return $0.dueDate < $1.dueDate
                }
            let plannedMinutes = tasks.reduce(0) { $0 + estimatedMinutes(for: $1, snapshot: snapshot) }
            return StudyLoadBalanceDay(
                date: date,
                tasks: tasks,
                plannedMinutes: plannedMinutes,
                capacityMinutes: Self.capacityMinutesForBudget(for: date, snapshot: snapshot, fallback: capacityMinutes, context: context)
            )
        }
    }

    private static func makeMoveProposals(
        days: [StudyLoadBalanceDay],
        snapshot: StoreSnapshot,
        dailyCapacity: Int,
        examGoal: ExamGoal?,
        now: Date
    ) -> [StudyLoadBalanceMoveProposal] {
        let calendar = Calendar.current
        var workingLoads = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0.plannedMinutes) })
        var workingTasks = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0.tasks) })
        let dayByID = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0) })
        var proposals: [StudyLoadBalanceMoveProposal] = []
        var movedTaskIDs = Set<UUID>()

        for day in days where (workingLoads[day.id] ?? 0) > dailyCapacity {
            var safetyCounter = 0
            while (workingLoads[day.id] ?? 0) > dailyCapacity && safetyCounter < 12 {
                safetyCounter += 1
                guard let candidate = workingTasks[day.id, default: []]
                    .filter({ !movedTaskIDs.contains($0.id) })
                    .filter({ canMove($0, from: day.date, examGoal: examGoal, now: now) })
                    .sorted(by: { moveScore(for: $0, now: now) < moveScore(for: $1, now: now) })
                    .first else {
                    break
                }

                let estimatedMinutes = estimatedMinutes(for: candidate, snapshot: snapshot)
                guard let targetDay = targetDay(
                    after: day.date,
                    estimatedMinutes: estimatedMinutes,
                    days: days,
                    workingLoads: workingLoads,
                    dailyCapacity: dailyCapacity,
                    examGoal: examGoal,
                    calendar: calendar
                ) else {
                    break
                }

                workingTasks[day.id, default: []].removeAll { $0.id == candidate.id }
                workingTasks[targetDay.id, default: []].append(candidate)
                workingLoads[day.id, default: 0] -= estimatedMinutes
                workingLoads[targetDay.id, default: 0] += estimatedMinutes
                movedTaskIDs.insert(candidate.id)

                proposals.append(StudyLoadBalanceMoveProposal(
                    taskID: candidate.id,
                    taskTitle: candidate.title,
                    fromDate: day.date,
                    toDate: targetDay.date,
                    estimatedMinutes: estimatedMinutes,
                    reason: moveReason(for: candidate, sourceDay: day, targetDay: dayByID[targetDay.id] ?? targetDay)
                ))
            }
        }

        return proposals
    }

    private static func makeCompressedSessionItems(
        from tasks: [ReviewTask],
        snapshot: StoreSnapshot,
        examGoal: ExamGoal?,
        now: Date
    ) -> [StudyLoadBalanceFocusItem] {
        let calendar = Calendar.current
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let candidateTasks = tasks
            .sorted {
                let lhsScore = focusScore(for: $0, examGoal: examGoal, now: now, todayEnd: todayEnd)
                let rhsScore = focusScore(for: $1, examGoal: examGoal, now: now, todayEnd: todayEnd)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return $0.dueDate < $1.dueDate
            }

        var remaining = compressedSessionMinutes
        var items: [StudyLoadBalanceFocusItem] = []
        for task in candidateTasks {
            let minutes = estimatedMinutes(for: task, snapshot: snapshot)
            guard items.isEmpty || minutes <= remaining else { continue }
            items.append(StudyLoadBalanceFocusItem(
                taskID: task.id,
                title: task.title,
                estimatedMinutes: min(minutes, remaining),
                reason: focusReason(for: task, examGoal: examGoal, now: now, todayEnd: todayEnd)
            ))
            remaining -= minutes
            if remaining <= 4 { break }
        }
        return items
    }

    private static func makeRecommendations(
        days: [StudyLoadBalanceDay],
        compressedItems: [StudyLoadBalanceFocusItem],
        proposals: [StudyLoadBalanceMoveProposal],
        examGoal: ExamGoal?,
        now: Date
    ) -> [StudyLoadBalanceRecommendation] {
        var recommendations: [StudyLoadBalanceRecommendation] = []
        let overloadedDays = days.filter(\.isOverloaded)

        if !proposals.isEmpty {
            recommendations.append(StudyLoadBalanceRecommendation(
                kind: .postponeLowPriority,
                title: "顺延低优先级",
                detail: "可移动 \(proposals.count) 个任务，把超载日让给高优先级、低掌握度和错题内容。",
                icon: "arrow.right.to.line"
            ))
        } else if !overloadedDays.isEmpty {
            recommendations.append(StudyLoadBalanceRecommendation(
                kind: .postponeLowPriority,
                title: "保留关键任务",
                detail: "这些超载日主要由高优先级或考前错题组成，暂不建议自动顺延。",
                icon: "lock.shield"
            ))
        }

        if !compressedItems.isEmpty {
            recommendations.append(StudyLoadBalanceRecommendation(
                kind: .compressedSession,
                title: "30 分钟压缩版",
                detail: "时间不够时，先完成 \(compressedItems.count) 个核心任务，其他内容再顺延。",
                icon: "timer"
            ))
        }

        if let examGoal,
           examGoal.daysRemaining(now: now) <= 14,
           days.flatMap(\.tasks).contains(where: { $0.mistakeID != nil }) {
            recommendations.append(StudyLoadBalanceRecommendation(
                kind: .examMistakePriority,
                title: "考前错题优先",
                detail: "\(examGoal.name) \(examGoal.countdownText(now: now))，平衡时会优先保留错题和高优先级任务。",
                icon: "flag.checkered.2.crossed"
            ))
        }

        if recommendations.isEmpty {
            recommendations.append(StudyLoadBalanceRecommendation(
                kind: .stable,
                title: "按计划推进",
                detail: "未来 \(days.count) 天的复习量没有明显超载。",
                icon: "checkmark.seal"
            ))
        }

        return recommendations
    }

    /// 未来负荷估算使用的每日容量。
    ///
    /// 优先使用统一容量机制（`AvailabilityCalculator`：课程、作息、缓冲、固定占用），
    /// 只有在用户尚未配置作息（`usesDefaultAssumption`）或算不出空闲时才退回
    /// 旧的考试目标估算，保证旧数据下行为不突变。
    private static func capacityMinutes(from snapshot: StoreSnapshot, now: Date) -> Int {
        let context = snapshot.planningContext(now: now)
        let availability = AvailabilityCalculator.availability(
            on: context.calendar.startOfDay(for: now),
            schedule: snapshot.scheduleForComputation,
            preferences: snapshot.availabilityPreferences,
            now: nil
        )
        let fallback = max(snapshot.nextExamGoal(now: now)?.dailyAvailableMinutes ?? 45, 30)
        if availability.usesDefaultAssumption || availability.totalFreeMinutes <= 0 {
            return fallback
        }
        return availability.totalFreeMinutes
    }

    /// 单日容量：同样优先使用统一容量机制（供负荷平衡与时间预算检查共用）。
    static func capacityMinutesForBudget(
        for date: Date,
        snapshot: StoreSnapshot,
        fallback: Int,
        context: PlanningContext
    ) -> Int {
        let preferences = snapshot.availabilityPreferences
        guard preferences.hasStudyWindows || !snapshot.scheduleCourses.isEmpty else { return fallback }
        let availability = AvailabilityCalculator.availability(
            on: date,
            schedule: snapshot.scheduleForComputation,
            preferences: preferences,
            now: nil
        )
        if availability.usesDefaultAssumption || availability.totalFreeMinutes <= 0 {
            return fallback
        }
        return availability.totalFreeMinutes
    }

    private static func canMove(_ task: ReviewTask, from sourceDate: Date, examGoal: ExamGoal?, now: Date) -> Bool {
        if (task.priority ?? 0) >= 5 {
            return false
        }
        if let lastQuality = task.lastQuality, lastQuality <= 2 {
            return false
        }
        if task.mistakeID != nil, let examGoal, examGoal.daysRemaining(now: now) <= 14 {
            return false
        }
        if Calendar.current.isDateInToday(sourceDate), task.mistakeID != nil {
            return false
        }
        return true
    }

    private static func moveScore(for task: ReviewTask, now: Date) -> Int {
        let priority = task.priority ?? 0
        var score = priority * 20
        if task.mistakeID != nil { score += 36 }
        if task.lastQuality ?? 5 <= 2 { score += 50 }
        if task.dueDate < now { score += max(priority, 1) * 8 }
        return score
    }

    private static func targetDay(
        after sourceDate: Date,
        estimatedMinutes: Int,
        days: [StudyLoadBalanceDay],
        workingLoads: [String: Int],
        dailyCapacity: Int,
        examGoal: ExamGoal?,
        calendar: Calendar
    ) -> StudyLoadBalanceDay? {
        let laterDays = days.filter { $0.date > sourceDate }
        if let fit = laterDays.first(where: { day in
            if let examGoal, calendar.isDate(day.date, inSameDayAs: examGoal.examDate) {
                return false
            }
            return (workingLoads[day.id] ?? 0) + estimatedMinutes <= dailyCapacity
        }) {
            return fit
        }

        return laterDays
            .filter { day in
                guard let examGoal else { return true }
                return !calendar.isDate(day.date, inSameDayAs: examGoal.examDate)
            }
            .min {
                (workingLoads[$0.id] ?? 0) < (workingLoads[$1.id] ?? 0)
            }
    }

    private static func moveReason(for task: ReviewTask, sourceDay: StudyLoadBalanceDay, targetDay: StudyLoadBalanceDay) -> String {
        let priority = task.priority ?? 0
        let sourceText = sourceDay.date.formatted(date: .abbreviated, time: .omitted)
        let targetText = targetDay.date.formatted(date: .abbreviated, time: .omitted)
        if priority <= 2 {
            return "低优先级任务从 \(sourceText) 顺延到 \(targetText)。"
        }
        return "为释放 \(sourceText) 的学习容量，顺延到 \(targetText)。"
    }

    private static func focusScore(for task: ReviewTask, examGoal: ExamGoal?, now: Date, todayEnd: Date) -> Int {
        var score = (task.priority ?? 0) * 18
        if task.dueDate < now { score += 80 }
        if task.dueDate < todayEnd { score += 42 }
        if task.mistakeID != nil { score += examGoal?.daysRemaining(now: now) ?? 30 <= 14 ? 56 : 28 }
        if task.lastQuality ?? 5 <= 2 { score += 34 }
        return score
    }

    private static func focusReason(for task: ReviewTask, examGoal: ExamGoal?, now: Date, todayEnd: Date) -> String {
        if task.dueDate < now {
            return "已逾期"
        }
        if task.mistakeID != nil, let examGoal, examGoal.daysRemaining(now: now) <= 14 {
            return "考前错题"
        }
        if (task.priority ?? 0) >= 4 {
            return "高优先级"
        }
        if task.dueDate < todayEnd {
            return "今日到期"
        }
        return "近期任务"
    }

    private static func scheduledDate(on day: Date, preservingTimeFrom oldDate: Date, now: Date) -> Date {
        let calendar = Calendar.current
        let oldComponents = calendar.dateComponents([.hour, .minute, .second], from: oldDate)
        let date = calendar.date(
            bySettingHour: oldComponents.hour ?? 22,
            minute: oldComponents.minute ?? 0,
            second: oldComponents.second ?? 0,
            of: calendar.startOfDay(for: day)
        ) ?? day
        guard date > now else {
            return calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(60 * 60)
        }
        return date
    }
}
