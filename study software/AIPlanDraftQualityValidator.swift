import Foundation

struct AIPlanDraftValidationResult {
    var draft: AIPlanDraft?
    var notes: [String]
}

enum AIPlanDraftQualityValidator {
    static func validate(_ draft: AIPlanDraft) -> AIPlanDraftValidationResult {
        var updated = draft
        var notes: [String] = []

        updated.reviewItems = updated.reviewItems
            .map { normalizedReviewItem($0, template: updated.planTemplate) }
            .filter { !$0.title.isEmpty }

        guard !updated.reviewItems.isEmpty else {
            return AIPlanDraftValidationResult(draft: nil, notes: ["规划没有可导入的复习任务"])
        }

        let beforeDedupCount = updated.reviewItems.count
        updated.reviewItems = mergeDuplicateTasks(updated.reviewItems)
        if updated.reviewItems.count < beforeDedupCount {
            notes.append("已合并 \(beforeDedupCount - updated.reviewItems.count) 个重复任务")
        }

        updated.reviewItems = inferMissingRelations(
            for: updated.reviewItems,
            knowledgePoints: updated.knowledgePoints,
            mistakes: updated.mistakes
        )

        if shouldRedistributeDueDays(updated.reviewItems, template: updated.planTemplate) {
            updated.reviewItems = redistributeDueDays(updated.reviewItems, template: updated.planTemplate)
            notes.append("已优化任务日期分布")
        }

        guard satisfiesTemplateCoverage(updated.reviewItems, template: updated.planTemplate) else {
            return AIPlanDraftValidationResult(draft: nil, notes: notes + ["30 天计划至少需要覆盖 3 个阶段"])
        }

        return AIPlanDraftValidationResult(draft: updated, notes: notes)
    }

    private static func normalizedReviewItem(_ item: DraftReviewItem, template: AIPlanTemplate) -> DraftReviewItem {
        DraftReviewItem(
            id: item.id,
            title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
            dueInDays: template.normalizedDueInDays(item.dueInDays),
            priority: item.priority.map { min(max($0, 0), 5) },
            relatedKnowledgeTitle: cleanedReference(item.relatedKnowledgeTitle),
            relatedMistakeTitle: cleanedReference(item.relatedMistakeTitle),
            relatedMistakeID: item.relatedMistakeID
        )
    }

    private static func mergeDuplicateTasks(_ items: [DraftReviewItem]) -> [DraftReviewItem] {
        var merged: [DraftReviewItem] = []
        var indexByKey: [String: Int] = [:]

        for item in items {
            let key = normalizedKey(item.title)
            guard !key.isEmpty else { continue }
            if let existingIndex = indexByKey[key] {
                var existing = merged[existingIndex]
                existing.dueInDays = min(existing.dueInDays, item.dueInDays)
                existing.priority = max(existing.priority ?? item.priority ?? 3, item.priority ?? existing.priority ?? 3)
                existing.relatedKnowledgeTitle = existing.relatedKnowledgeTitle ?? item.relatedKnowledgeTitle
                existing.relatedMistakeTitle = existing.relatedMistakeTitle ?? item.relatedMistakeTitle
                existing.relatedMistakeID = existing.relatedMistakeID ?? item.relatedMistakeID
                merged[existingIndex] = existing
            } else {
                indexByKey[key] = merged.count
                merged.append(item)
            }
        }

        return merged
    }

    private static func inferMissingRelations(
        for items: [DraftReviewItem],
        knowledgePoints: [DraftKnowledgePoint],
        mistakes: [DraftMistake]
    ) -> [DraftReviewItem] {
        items.map { item in
            var updated = item
            let titleKey = normalizedKey(item.title)

            if updated.relatedKnowledgeTitle == nil {
                updated.relatedKnowledgeTitle = knowledgePoints.first { point in
                    let pointKey = normalizedKey(point.title)
                    return !pointKey.isEmpty && (titleKey.contains(pointKey) || pointKey.contains(titleKey))
                }?.title
            }

            if updated.relatedMistakeTitle == nil {
                if let mistake = mistakes.first(where: { mistake in
                    let mistakeKey = normalizedKey(mistake.question)
                    return !mistakeKey.isEmpty && (titleKey.contains(mistakeKey) || mistakeKey.contains(titleKey))
                }) {
                    updated.relatedMistakeTitle = mistake.question
                    updated.relatedMistakeID = mistake.id
                }
            }

            return updated
        }
    }

    private static func shouldRedistributeDueDays(_ items: [DraftReviewItem], template: AIPlanTemplate) -> Bool {
        guard items.count >= 3 else { return false }
        switch template {
        case .today:
            return false
        case .thirtyDays:
            return coveredStages(for: items).count < 3
        case .week, .general:
            return Set(items.map(\.dueInDays)).count == 1 && items.count >= 4
        }
    }

    private static func redistributeDueDays(_ items: [DraftReviewItem], template: AIPlanTemplate) -> [DraftReviewItem] {
        let pattern: [Int]
        switch template {
        case .today:
            pattern = [0]
        case .week:
            pattern = [0, 1, 2, 3, 5, 6]
        case .thirtyDays:
            pattern = [0, 10, 23, 3, 14, 27, 7, 20, 30]
        case .general:
            pattern = [0, 1, 3, 7, 14, 30]
        }

        return items.enumerated().map { offset, item in
            var updated = item
            updated.dueInDays = template.normalizedDueInDays(pattern[offset % pattern.count])
            return updated
        }
    }

    private static func satisfiesTemplateCoverage(_ items: [DraftReviewItem], template: AIPlanTemplate) -> Bool {
        guard template == .thirtyDays else { return true }
        guard items.count >= 3 else { return false }
        return coveredStages(for: items).count >= 3
    }

    private static func coveredStages(for items: [DraftReviewItem]) -> Set<Int> {
        Set(items.map { item in
            switch item.dueInDays {
            case ...7: return 0
            case 8...20: return 1
            default: return 2
            }
        })
    }

    private static func cleanedReference(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalizedKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".")
    }
}
