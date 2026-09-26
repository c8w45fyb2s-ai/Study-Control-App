import Foundation

/// 主动回忆内容与错题状态的纯数据变换。AppStore 负责协调完成事件和一次性落盘。
enum ActiveRecallLibrary {
    static func saving(_ card: StudyCard, linkedReviewTaskID: UUID?,
                       in snapshot: StoreSnapshot, at now: Date) -> StoreSnapshot? {
        let prompt = card.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = card.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !answer.isEmpty else { return nil }
        var updated = card
        updated.prompt = prompt
        updated.answer = answer
        var candidate = snapshot
        if let index = candidate.studyCards.firstIndex(where: { $0.id == card.id }) {
            updated.contentVersion = candidate.studyCards[index].contentVersion + 1
            candidate.studyCards[index] = updated
            if let taskIndex = candidate.reviewTasks.firstIndex(where: { $0.cardID == card.id }) {
                candidate.reviewTasks[taskIndex].title = prompt
            }
        } else {
            candidate.studyCards.append(updated)
            // 显式选中的任务优先，不能被列表中更早的同知识点任务抢先匹配。
            let explicitTaskIndex = linkedReviewTaskID.flatMap { id in
                candidate.reviewTasks.firstIndex { $0.id == id }
            }
            if let taskIndex = explicitTaskIndex ?? candidate.reviewTasks.firstIndex(where: { task in
                task.cardID == nil && ((updated.mistakeID != nil && task.mistakeID == updated.mistakeID)
                    || (updated.mistakeID != nil && task.title == "重做错题：\(ReviewPlanner.shortTitle(prompt))")
                    || (updated.mistakeID == nil && updated.knowledgePointID != nil && task.knowledgePointID == updated.knowledgePointID))
            }) {
                candidate.reviewTasks[taskIndex].cardID = updated.id
                candidate.reviewTasks[taskIndex].title = prompt
            } else {
                var task = ReviewTask(title: prompt, dueDate: now,
                    knowledgePointID: updated.knowledgePointID, mistakeID: updated.mistakeID)
                task.cardID = updated.id
                candidate.reviewTasks.append(task)
            }
        }
        return candidate
    }

    static func card(for task: ReviewTask, in snapshot: StoreSnapshot) -> StudyCard? {
        snapshot.studyCards.first { $0.id == task.cardID }
    }

    /// 各个制卡入口共用内容校验和来源映射；旧知识点仅有文档 ID 时也保留来源。
    static func makeCard(mistake: Mistake? = nil, knowledgePoint: KnowledgePoint? = nil,
                         task: ReviewTask? = nil) -> StudyCard? {
        let prompt = (mistake?.question ?? task?.title ?? knowledgePoint?.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = (mistake?.correctAnswer ?? knowledgePoint?.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !answer.isEmpty else { return nil }
        let reference = mistake?.sourceReference ?? knowledgePoint?.sourceReference
        var card = StudyCard(kind: .questionAnswer, prompt: prompt, answer: answer,
            knowledgePointID: task?.knowledgePointID ?? mistake?.knowledgePointIDs.first ?? knowledgePoint?.id,
            mistakeID: mistake?.id ?? task?.mistakeID,
            sourceDocumentID: mistake?.sourceDocumentID ?? knowledgePoint?.sourceDocumentID ?? reference?.documentID)
        card.sourceReference = reference
        return card
    }

    static func creatingCard(for task: ReviewTask, in snapshot: StoreSnapshot,
                             at now: Date = Date()) -> (StoreSnapshot, StudyCard)? {
        guard snapshot.reviewTasks.contains(where: { $0.id == task.id }) else { return nil }
        let mistake = task.mistakeID.flatMap { id in snapshot.mistakes.first { $0.id == id } }
        let point = task.knowledgePointID.flatMap { id in snapshot.knowledgePoints.first { $0.id == id } }
        guard let card = makeCard(mistake: mistake, knowledgePoint: point, task: task),
              let candidate = saving(card, linkedReviewTaskID: task.id, in: snapshot, at: now) else { return nil }
        return (candidate, card)
    }

    static func practiceState(for mistakeID: UUID, in snapshot: StoreSnapshot,
                              timeZone: TimeZone) -> MistakePracticeState {
        let linkedCardIDs = Set(snapshot.studyCards.filter { $0.mistakeID == mistakeID }.map(\.id))
        let active = snapshot.reviewAttempts.filter { linkedCardIDs.contains($0.cardID) && $0.isActive }
            .sorted { lhs, rhs in
                lhs.submittedAt == rhs.submittedAt ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.submittedAt < rhs.submittedAt
            }
        guard let latest = active.last else { return .needsRetry }
        guard latest.quality >= 3 else { return .needsRetry }
        let latestFailure = active.last(where: { $0.quality < 3 })?.submittedAt ?? .distantPast
        let successfulDays = Set(active.filter { $0.quality >= 3 && $0.submittedAt > latestFailure }
            .map { StudyDayKey(date: $0.submittedAt, timeZone: timeZone).localDateString })
        return successfulDays.count >= 2 ? .mastered : .reviewing
    }
}
