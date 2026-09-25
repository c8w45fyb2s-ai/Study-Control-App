import Foundation

struct StudyProfileSummary {
    struct WeakSubject: Codable {
        var subject: String
        var averageMastery: Double
        var weakKnowledgeCount: Int
        var representativeTitles: [String]
    }

    struct TaskSnapshot: Codable {
        var title: String
        var dueDescription: String
        var priority: Int?
        var linkedSummary: String
    }

    struct GoalSnapshot: Codable {
        var name: String
        var examDate: Date
        var daysRemaining: Int
        var subjects: String
        var dailyAvailableTime: String
        var targetScore: String
    }

    var generatedAt: Date
    var examGoals: [GoalSnapshot]
    var goals: [String]
    var remainingTimeDescription: String
    var weakSubjects: [WeakSubject]
    var recentTasks: [TaskSnapshot]
    var overdueTaskCount: Int
    var dueTodayTaskCount: Int
    var dueThisWeekTaskCount: Int
    var dailyAvailableTimeDescription: String

    static func make(from snapshot: StoreSnapshot, now: Date = Date()) -> StudyProfileSummary {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? now
        let pendingTasks = snapshot.reviewTasks.filter { $0.status == .pending }
        let examGoals = makeExamGoalSnapshots(from: snapshot, now: now)
        let goalTexts = makeGoalTexts(from: snapshot)

        return StudyProfileSummary(
            generatedAt: now,
            examGoals: examGoals,
            goals: goalTexts,
            remainingTimeDescription: makeRemainingTimeDescription(from: examGoals, fallbackGoals: goalTexts, now: now),
            weakSubjects: makeWeakSubjects(from: snapshot.knowledgePoints),
            recentTasks: makeRecentTasks(from: pendingTasks, snapshot: snapshot, now: now),
            overdueTaskCount: pendingTasks.filter { $0.dueDate < todayStart }.count,
            dueTodayTaskCount: pendingTasks.filter { todayStart <= $0.dueDate && $0.dueDate < tomorrowStart }.count,
            dueThisWeekTaskCount: pendingTasks.filter { todayStart <= $0.dueDate && $0.dueDate < weekEnd }.count,
            dailyAvailableTimeDescription: makeDailyAvailableTimeDescription(from: snapshot.dailyActivityRecords, now: now)
        )
    }

    var promptText: String {
        var lines: [String] = [
            "## 学习状态诊断",
            "生成时间：\(generatedAt.formatted(date: .numeric, time: .shortened))",
            "目标：\(goals.isEmpty ? "尚未提炼出明确长期目标。" : goals.joined(separator: "；"))",
            "剩余时间：\(remainingTimeDescription)",
            "任务压力：逾期 \(overdueTaskCount) 个；今日到期 \(dueTodayTaskCount) 个；本周到期 \(dueThisWeekTaskCount) 个。",
            "每日可用时间：\(dailyAvailableTimeDescription)"
        ]

        lines.append("")
        lines.append("考试目标：")
        if examGoals.isEmpty {
            lines.append("- 尚未设置明确考试目标。")
        } else {
            for goal in examGoals {
                let targetScore = goal.targetScore.isEmpty ? "未填写" : goal.targetScore
                lines.append("- \(goal.name)：倒计时 \(max(goal.daysRemaining, 0)) 天，考试日期 \(goal.examDate.formatted(date: .numeric, time: .omitted))；科目：\(goal.subjects)；每日可用时间：\(goal.dailyAvailableTime)；目标分数：\(targetScore)")
            }
        }

        lines.append("")
        lines.append("薄弱科目：")
        if weakSubjects.isEmpty {
            lines.append("- 暂无低掌握度知识点。")
        } else {
            for subject in weakSubjects {
                let mastery = Int((subject.averageMastery * 100).rounded())
                let titles = subject.representativeTitles.isEmpty ? "暂无代表知识点" : subject.representativeTitles.joined(separator: "、")
                lines.append("- \(subject.subject)：平均掌握度 \(mastery)%，薄弱知识点 \(subject.weakKnowledgeCount) 个；代表：\(titles)")
            }
        }

        lines.append("")
        lines.append("近期任务：")
        if recentTasks.isEmpty {
            lines.append("- 暂无待复习任务。")
        } else {
            for task in recentTasks {
                let priority = task.priority.map { "优先级 \($0)" } ?? "未设优先级"
                lines.append("- \(task.title)：\(task.dueDescription)，\(priority)，\(task.linkedSummary)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func makeExamGoalSnapshots(from snapshot: StoreSnapshot, now: Date) -> [GoalSnapshot] {
        snapshot.activeExamGoals(now: now)
            .prefix(3)
            .map { goal in
                GoalSnapshot(
                    name: goal.name,
                    examDate: goal.examDate,
                    daysRemaining: goal.daysRemaining(now: now),
                    subjects: goal.subjectText,
                    dailyAvailableTime: goal.dailyAvailableTimeText,
                    targetScore: goal.targetScore.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    private static func makeGoalTexts(from snapshot: StoreSnapshot) -> [String] {
        var goals = snapshot.activeExamGoals().prefix(3).map { $0.promptSummary() }
        let summary = snapshot.chatMemorySummary
            .mergedWithLegacySummary(snapshot.chatContextSummary)
            .promptText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            goals.append(summary.compactedForStudyText(limit: 240))
        }

        for draft in snapshot.aiPlanDrafts
            .filter({ $0.status != .dismissed })
            .sorted(by: { $0.createdAt > $1.createdAt })
            .prefix(2) {
            let text = [draft.title, draft.summary]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "：")
            if !text.isEmpty {
                goals.append(text.compactedForStudyText(limit: 220))
            }
        }

        return Array(goals.prefix(3))
    }

    private static func makeWeakSubjects(from points: [KnowledgePoint]) -> [WeakSubject] {
        let weakPoints = points.filter { $0.mastery < 0.65 }
        let grouped = Dictionary(grouping: weakPoints) { point in
            point.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未分类" : point.subject
        }

        return grouped.map { subject, items in
            let sorted = items.sorted {
                if $0.mastery != $1.mastery {
                    return $0.mastery < $1.mastery
                }
                return $0.createdAt > $1.createdAt
            }
            let average = sorted.reduce(0) { $0 + min(max($1.mastery, 0), 1) } / Double(max(sorted.count, 1))
            return WeakSubject(
                subject: subject,
                averageMastery: average,
                weakKnowledgeCount: sorted.count,
                representativeTitles: Array(sorted.prefix(4).map(\.title))
            )
        }
        .sorted {
            if $0.averageMastery != $1.averageMastery {
                return $0.averageMastery < $1.averageMastery
            }
            return $0.weakKnowledgeCount > $1.weakKnowledgeCount
        }
        .prefix(6)
        .map { $0 }
    }

    private static func makeRecentTasks(from tasks: [ReviewTask], snapshot: StoreSnapshot, now: Date) -> [TaskSnapshot] {
        tasks.sorted {
            if ($0.priority ?? 0) != ($1.priority ?? 0) {
                return ($0.priority ?? 0) > ($1.priority ?? 0)
            }
            return $0.dueDate < $1.dueDate
        }
        .prefix(10)
        .map { task in
            TaskSnapshot(
                title: task.title,
                dueDescription: dueDescription(for: task.dueDate, now: now),
                priority: task.priority,
                linkedSummary: linkedSummary(for: task, snapshot: snapshot)
            )
        }
    }

    private static func makeRemainingTimeDescription(from examGoals: [GoalSnapshot], fallbackGoals: [String], now: Date) -> String {
        if let nearest = examGoals.sorted(by: { $0.daysRemaining < $1.daysRemaining }).first {
            let days = max(nearest.daysRemaining, 0)
            return "距离「\(nearest.name)」还有 \(days) 天（\(nearest.examDate.formatted(date: .abbreviated, time: .omitted))）。"
        }

        let goalText = fallbackGoals.joined(separator: "\n")
        if let date = nearestFutureDate(in: goalText, now: now) {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: date)).day ?? 0
            return "距离已识别目标日期约 \(max(days, 0)) 天（\(date.formatted(date: .abbreviated, time: .omitted))）。"
        }

        if let days = explicitDayWindow(in: goalText) {
            return "文本中提到约 \(days) 天的备考/规划周期。"
        }

        return "未识别明确截止日期；规划时应优先按本周与 30 天阶段滚动推进。"
    }

    private static func makeDailyAvailableTimeDescription(from records: [DailyActivityRecord], now: Date) -> String {
        let calendar = Calendar.current
        let recentDates = (0..<14).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: now).map(DailyActivityRecord.dateString)
        }
        let recentRecords = records.filter { recentDates.contains($0.dateString) }
        guard !recentRecords.isEmpty else {
            return "未记录每日可用学习时长；默认按每天 1-2 小时、2-4 个小任务安排。"
        }

        let averageTasks = Double(recentRecords.reduce(0) { $0 + $1.completedTaskCount }) / Double(recentRecords.count)
        let formatted = String(format: "%.1f", averageTasks)
        if averageTasks < 1 {
            return "近 \(recentRecords.count) 天日均完成 \(formatted) 个任务；建议先安排轻量任务，避免过载。"
        } else if averageTasks < 3 {
            return "近 \(recentRecords.count) 天日均完成 \(formatted) 个任务；适合每天 2-4 个核心任务。"
        } else {
            return "近 \(recentRecords.count) 天日均完成 \(formatted) 个任务；可以安排较高强度复习，但仍需保留复盘缓冲。"
        }
    }

    private static func linkedSummary(for task: ReviewTask, snapshot: StoreSnapshot) -> String {
        var linked: [String] = []
        if let id = task.knowledgePointID,
           let point = snapshot.knowledgePoints.first(where: { $0.id == id }) {
            linked.append("知识点：\(point.title)")
        }
        if let id = task.mistakeID,
           let mistake = snapshot.mistakes.first(where: { $0.id == id }) {
            linked.append("错题：\(mistake.question.compactedForStudyText(limit: 80))")
        }
        return linked.isEmpty ? "未关联资料" : linked.joined(separator: "；")
    }

    private static func dueDescription(for date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        if date < todayStart {
            return "已逾期，原定 \(date.formatted(date: .abbreviated, time: .shortened))"
        } else if date < tomorrowStart {
            return "今日到期 \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func nearestFutureDate(in text: String, now: Date) -> Date? {
        let candidates = dateCandidates(in: text, now: now)
        return candidates
            .filter { $0 >= Calendar.current.startOfDay(for: now) }
            .min()
    }

    private static func dateCandidates(in text: String, now: Date) -> [Date] {
        var results: [Date] = []
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)

        results.append(contentsOf: matches(
            pattern: #"(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})"#,
            in: text
        ).compactMap { parts in
            guard parts.count >= 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]) else { return nil }
            return DateComponents(calendar: calendar, year: year, month: month, day: day).date
        })

        results.append(contentsOf: matches(
            pattern: #"(\d{1,2})月(\d{1,2})[日号]?"#,
            in: text
        ).compactMap { parts in
            guard parts.count >= 2,
                  let month = Int(parts[0]),
                  let day = Int(parts[1]) else { return nil }
            var date = DateComponents(calendar: calendar, year: currentYear, month: month, day: day).date
            if let existing = date, existing < calendar.startOfDay(for: now) {
                date = DateComponents(calendar: calendar, year: currentYear + 1, month: month, day: day).date
            }
            return date
        })

        return results
    }

    private static func explicitDayWindow(in text: String) -> Int? {
        matches(pattern: #"(\d{1,3})\s*[天日]"#, in: text)
            .compactMap { $0.first.flatMap(Int.init) }
            .filter { $0 > 0 }
            .min()
    }

    private static func matches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
        }
    }

}
