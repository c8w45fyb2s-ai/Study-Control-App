import Foundation

struct RetrievedStudyContext: Identifiable {
    enum Kind: String {
        case document = "笔记"
        case mistake = "错题"
        case knowledge = "知识点"
        case reviewTask = "复习任务"
        case goal = "长期目标"
    }

    var id = UUID()
    var kind: Kind
    var sourceID: UUID?
    var title: String
    var excerpt: String
    var score: Int

    var label: String {
        "\(kind.rawValue)：\(title)"
    }
}

struct StudyContextRetrieval {
    var items: [RetrievedStudyContext]

    var promptContext: String {
        guard !items.isEmpty else {
            return "没有从用户个人资料中检索到直接相关内容。"
        }

        return items.enumerated().map { index, item in
            """
            [资料 \(index + 1)] \(item.kind.rawValue)
            标题：\(item.title)
            内容：\(item.excerpt)
            """
        }.joined(separator: "\n\n")
    }

    var citations: [ChatMessageCitation] {
        items.enumerated().map { index, item in
            ChatMessageCitation(
                kind: item.citationKind,
                title: item.title,
                excerpt: item.excerpt,
                sourceID: item.sourceID,
                promptIndex: index + 1
            )
        }
    }
}

enum StudyContextRetriever {
    static func retrieve(query: String, snapshot: StoreSnapshot, limit: Int = 14, now: Date = Date()) -> StudyContextRetrieval {
        let terms = SearchText.terms(from: query)
        let wantsStudyPlanning = SearchText.looksLikeStudyPlanningQuery(query, terms: terms)
        guard !terms.isEmpty || wantsStudyPlanning else { return StudyContextRetrieval(items: []) }

        var items: [RetrievedStudyContext] = []

        for mistake in snapshot.mistakes {
            let text = [mistake.question, mistake.correctAnswer, mistake.errorReason].joined(separator: "\n")
            let score = SearchText.score(terms: terms, title: mistake.question, body: text) + 8
            guard score > 8 else { continue }
            items.append(
                RetrievedStudyContext(
                    kind: .mistake,
                    sourceID: mistake.id,
                    title: mistake.question.compactedForStudyText(limit: 36),
                    excerpt: """
                    题目：\(mistake.question)
                    答案：\(mistake.correctAnswer)
                    错因：\(mistake.errorReason)
                    """,
                    score: score
                )
            )
        }

        for point in snapshot.knowledgePoints {
            let text = [point.title, point.subject, point.summary].joined(separator: "\n")
            let masteryBoost = Int((1 - point.mastery) * 6)
            let score = SearchText.score(terms: terms, title: point.title, body: text) + masteryBoost
            guard score > masteryBoost else { continue }
            items.append(
                RetrievedStudyContext(
                    kind: .knowledge,
                    sourceID: point.id,
                    title: point.title,
                    excerpt: """
                    学科：\(point.subject)
                    掌握度：\(Int(point.mastery * 100))%
                    说明：\(point.summary)
                    """,
                    score: score
                )
            )
        }

        if wantsStudyPlanning {
            items.append(contentsOf: weakKnowledgeContexts(snapshot: snapshot))
        }

        for document in snapshot.documents {
            let text = [document.title, document.sourceName, document.kind.rawValue, document.content].joined(separator: "\n")
            let score = SearchText.score(terms: terms, title: document.title, body: text)
            guard score > 0 else { continue }
            let excerpt = SearchText.excerpt(from: document.content, terms: terms, fallbackLimit: 1_200)
            items.append(
                RetrievedStudyContext(
                    kind: .document,
                    sourceID: document.id,
                    title: document.title,
                    excerpt: """
                    类型：\(document.kind.rawValue)
                    来源：\(document.sourceName)
                    摘录：\(excerpt)
                    """,
                    score: score
                )
            )
        }

        items.append(contentsOf: reviewTaskContexts(
            terms: terms,
            wantsStudyPlanning: wantsStudyPlanning,
            snapshot: snapshot,
            now: now
        ))
        items.append(contentsOf: longTermGoalContexts(
            terms: terms,
            wantsStudyPlanning: wantsStudyPlanning,
            snapshot: snapshot
        ))

        let ranked = items
            .deduplicatedForRetrieval()
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.title < $1.title
            }
            .prefix(limit)

        return StudyContextRetrieval(items: Array(ranked))
    }

    private static func weakKnowledgeContexts(snapshot: StoreSnapshot) -> [RetrievedStudyContext] {
        snapshot.knowledgePoints
            .filter { $0.mastery < 0.65 }
            .sorted {
                if $0.mastery != $1.mastery {
                    return $0.mastery < $1.mastery
                }
                return $0.createdAt > $1.createdAt
            }
            .prefix(6)
            .map { point in
                RetrievedStudyContext(
                    kind: .knowledge,
                    sourceID: point.id,
                    title: point.title,
                    excerpt: """
                    学科：\(point.subject)
                    掌握度：\(Int(point.mastery * 100))%
                    召回原因：当前掌握度较低，适合纳入今日/阶段复习安排。
                    说明：\(point.summary)
                    """,
                    score: 120 + Int((1 - point.mastery) * 20)
                )
            }
    }

    private static func reviewTaskContexts(
        terms: [String],
        wantsStudyPlanning: Bool,
        snapshot: StoreSnapshot,
        now: Date
    ) -> [RetrievedStudyContext] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: todayStart) ?? now

        return snapshot.reviewTasks
            .filter { $0.status == .pending }
            .compactMap { task -> RetrievedStudyContext? in
                let linkedText = linkedSummary(for: task, snapshot: snapshot)
                let body = [task.title, task.status.rawValue, linkedText].joined(separator: "\n")
                let keywordScore = SearchText.score(terms: terms, title: task.title, body: body)
                let urgencyScore: Int
                let urgencyLabel: String

                if task.dueDate < todayStart {
                    urgencyScore = 150
                    urgencyLabel = "已逾期"
                } else if task.dueDate < tomorrowStart {
                    urgencyScore = 135
                    urgencyLabel = "今日到期"
                } else if task.dueDate < weekEnd {
                    urgencyScore = 105
                    urgencyLabel = "本周到期"
                } else {
                    urgencyScore = 45
                    urgencyLabel = "后续任务"
                }

                guard wantsStudyPlanning || keywordScore > 0 || urgencyScore >= 135 else {
                    return nil
                }

                return RetrievedStudyContext(
                    kind: .reviewTask,
                    sourceID: task.id,
                    title: task.title,
                    excerpt: """
                    状态：\(task.status.rawValue)
                    到期：\(task.dueDate.formatted(date: .abbreviated, time: .shortened))（\(urgencyLabel)）
                    优先级：\(task.priority.map(String.init) ?? "未设置")
                    间隔状态：\(task.sm2Description)
                    关联：\(linkedText)
                    """,
                    score: urgencyScore + keywordScore
                )
            }
    }

    private static func longTermGoalContexts(
        terms: [String],
        wantsStudyPlanning: Bool,
        snapshot: StoreSnapshot
    ) -> [RetrievedStudyContext] {
        var contexts: [RetrievedStudyContext] = []

        let summary = snapshot.chatMemorySummary
            .mergedWithLegacySummary(snapshot.chatContextSummary)
            .promptText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryScore = SearchText.score(terms: terms, title: "长期记忆", body: summary)
        if !summary.isEmpty, wantsStudyPlanning || summaryScore > 0 {
            contexts.append(
                RetrievedStudyContext(
                    kind: .goal,
                    sourceID: nil,
                    title: "长期学习目标与偏好",
                    excerpt: summary.compactedForStudyText(limit: 1_200),
                    score: 125 + summaryScore
                )
            )
        }

        let planDraftContexts = snapshot.aiPlanDrafts
            .filter { $0.status != .dismissed }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(3)
            .compactMap { draft -> RetrievedStudyContext? in
                let body = [draft.title, draft.summary].joined(separator: "\n")
                let score = SearchText.score(terms: terms, title: draft.title, body: body)
                guard wantsStudyPlanning || score > 0 else { return nil }
                return RetrievedStudyContext(
                    kind: .goal,
                    sourceID: draft.id,
                    title: draft.title,
                    excerpt: """
                    状态：\(draft.status.rawValue)
                    摘要：\(draft.summary.compactedForStudyText(limit: 900))
                    任务数：\(draft.reviewItems.count)；知识点：\(draft.knowledgePoints.count)；错题：\(draft.mistakes.count)
                    """,
                    score: 108 + score
                )
            }

        contexts.append(contentsOf: planDraftContexts)
        return contexts
    }

    private static func linkedSummary(for task: ReviewTask, snapshot: StoreSnapshot) -> String {
        var linked: [String] = []
        if let knowledgePointID = task.knowledgePointID,
           let point = snapshot.knowledgePoints.first(where: { $0.id == knowledgePointID }) {
            linked.append("知识点：\(point.title)（\(point.subject)，掌握度 \(Int(point.mastery * 100))%）")
        }
        if let mistakeID = task.mistakeID,
           let mistake = snapshot.mistakes.first(where: { $0.id == mistakeID }) {
            linked.append("错题：\(mistake.question.compactedForStudyText(limit: 120))")
        }
        return linked.isEmpty ? "未关联资料" : linked.joined(separator: "；")
    }
}

private enum SearchText {
    static func terms(from query: String) -> [String] {
        let normalized = query.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        let wordTerms = normalized
            .components(separatedBy: separators)
            .filter { $0.count >= 2 }

        let cjkRuns = normalized
            .split { character in
                !character.unicodeScalars.contains { scalar in
                    (0x4E00...0x9FFF).contains(Int(scalar.value))
                }
            }
            .map(String.init)

        let cjkTerms = cjkRuns.flatMap { run in
            ngrams(from: run, sizes: [2, 3, 4])
        }

        let rankedTerms = Array(Set(wordTerms + cjkTerms))
            .sorted { $0.count > $1.count }
        return Array(rankedTerms.prefix(80))
    }

    static func looksLikeStudyPlanningQuery(_ query: String, terms: [String]) -> Bool {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let planningPhrases = [
            "今天怎么学", "今日怎么学", "今天学什么", "今日复习", "今天复习",
            "每日任务", "每天任务", "复习计划", "学习计划", "学习规划", "备考规划",
            "备考计划", "怎么安排", "安排复习", "规划", "计划", "任务", "复习",
            "怎么学", "先学什么", "本周", "30天", "三十天", "today", "studyplan",
            "reviewplan", "schedule", "roadmap"
        ]
        if planningPhrases.contains(where: { normalized.contains($0.replacingOccurrences(of: " ", with: "")) }) {
            return true
        }

        let planningTerms = Set(["今天", "今日", "本周", "复习", "学习", "任务", "计划", "规划", "安排", "备考", "study", "review", "plan", "schedule"])
        return terms.contains { planningTerms.contains($0) }
    }

    static func score(terms: [String], title: String, body: String) -> Int {
        let normalizedTitle = title.lowercased()
        let normalizedBody = body.lowercased()

        return terms.reduce(0) { partial, term in
            let titleHits = occurrences(of: term, in: normalizedTitle)
            let bodyHits = occurrences(of: term, in: normalizedBody)
            return partial + titleHits * 8 + min(bodyHits, 6) * max(1, term.count)
        }
    }

    static func excerpt(from text: String, terms: [String], fallbackLimit: Int) -> String {
        let bestRange = terms
            .compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { first, second in
                text.distance(from: text.startIndex, to: first.lowerBound)
                    < text.distance(from: text.startIndex, to: second.lowerBound)
            }

        guard let range = bestRange else {
            return text.compactedForStudyText(limit: fallbackLimit)
        }

        let hitOffset = text.distance(from: text.startIndex, to: range.lowerBound)
        let startOffset = max(0, hitOffset - 240)
        let endOffset = min(text.count, hitOffset + 520)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        let prefix = startOffset > 0 ? "..." : ""
        let suffix = endOffset < text.count ? "..." : ""
        return prefix + String(text[start..<end]).compactedForStudyText(limit: fallbackLimit) + suffix
    }

    private static func ngrams(from text: String, sizes: [Int]) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        var results: [String] = []
        for size in sizes where characters.count >= size {
            for start in 0...(characters.count - size) {
                results.append(String(characters[start..<(start + size)]))
            }
        }
        return results
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}

private extension Array where Element == RetrievedStudyContext {
    func deduplicatedForRetrieval() -> [RetrievedStudyContext] {
        var seen = Set<String>()
        var result: [RetrievedStudyContext] = []
        for item in self {
            let key = "\(item.kind.rawValue)|\(item.title)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }
}

private extension RetrievedStudyContext {
    var citationKind: ChatMessageCitationKind {
        switch kind {
        case .document: return .document
        case .mistake: return .mistake
        case .knowledge: return .knowledge
        case .reviewTask: return .reviewTask
        case .goal: return .goal
        }
    }
}
