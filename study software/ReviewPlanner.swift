import Foundation

/// SM-2 spaced repetition algorithm.
///
/// Based on P.A. Wozniak's SuperMemo SM-2, simplified for a personal study tool.
/// - After each review the user rates quality 0-5.
/// - Quality >= 3: the item graduates (or stays graduated), interval grows.
/// - Quality < 3: the item resets to the start.
/// - Easiness factor (EF) adjusts every review, clamped to [1.3, 2.5].
enum ReviewPlanner {

    // MARK: - Quality ratings

    /// The 0-5 rating the user gives after reviewing an item.
    enum Quality: Int, CaseIterable, Identifiable {
        case blackout = 0
        case incorrectButRecognized = 1
        case incorrectButFamiliar = 2
        case hard = 3
        case good = 4
        case easy = 5

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .blackout:              return "完全忘了"
            case .incorrectButRecognized: return "看到答案才想起"
            case .incorrectButFamiliar:   return "感觉熟悉但答错"
            case .hard:                  return "困难"
            case .good:                  return "正常"
            case .easy:                  return "轻松"
            }
        }

        var shortLabel: String {
            switch self {
            case .blackout:              return "忘了"
            case .incorrectButRecognized: return "勉强"
            case .incorrectButFamiliar:   return "熟悉但错"
            case .hard:                  return "困难"
            case .good:                  return "正常"
            case .easy:                  return "轻松"
            }
        }

        var icon: String {
            switch self {
            case .blackout:              return "1.square"
            case .incorrectButRecognized: return "2.square"
            case .incorrectButFamiliar:   return "3.square"
            case .hard:                  return "4.square"
            case .good:                  return "5.square"
            case .easy:                  return "6.square"
            }
        }
    }

    // MARK: - SM-2 algorithm

    /// Default intervals used when creating tasks from an analysis draft.
    /// — a reasonable starting point that SM-2 will adjust from.
    static let defaultIntervals = [0, 1, 3]
    private static let initialTaskDueHour = 22

    /// Compute the next review date and updated SM-2 state for a completed task.
    ///
    /// - Parameters:
    ///   - task: The task that was just reviewed. Must have status `.done` or be about to be marked done.
    ///   - quality: User's self-assessed rating (0-5).
    ///   - now: The reference date (injected for testability).
    /// - Returns: A new `ReviewTask` with updated SM-2 fields, status `.pending`, and a future `dueDate`.
    static func scheduleNextReview(task: ReviewTask, quality: Quality, now: Date = Date()) -> ReviewTask {
        scheduleNextReview(task: task, quality: quality, now: now, calendar: .current)
    }

    /// 同上，但使用外部注入的规划上下文（统一时间处理）。
    static func scheduleNextReview(task: ReviewTask, quality: Quality, context: PlanningContext) -> ReviewTask {
        scheduleNextReview(task: task, quality: quality, now: context.now, calendar: context.calendar)
    }

    private static func scheduleNextReview(
        task: ReviewTask,
        quality: Quality,
        now: Date,
        calendar: Calendar
    ) -> ReviewTask {
        var next = task
        next.status = .pending
        next.lastQuality = quality.rawValue

        let q = quality.rawValue

        if q >= 3 {
            // Successful recall — advance the interval.
            switch next.repetitionCount {
            case 0:
                next.intervalDays = 1
            case 1:
                next.intervalDays = 6
            default:
                let raw = Int((Double(next.intervalDays) * next.easinessFactor).rounded())
                next.intervalDays = max(raw, next.intervalDays + 1)
            }
            next.repetitionCount += 1
        } else {
            // Failed recall — reset.
            next.repetitionCount = 0
            next.intervalDays = 1
        }

        // Update easiness factor (clamped to [1.3, 2.5]).
        let delta = 0.1 - Double(5 - q) * (0.08 + Double(5 - q) * 0.02)
        next.easinessFactor = min(2.5, max(1.3, next.easinessFactor + delta))

        // Schedule next review at a usable study time instead of midnight.
        next.dueDate = reviewDueDate(daysFromNow: next.intervalDays, now: now, calendar: calendar)
        next.lastReviewedAt = now

        // Reset reminder flag so the new review gets a notification.
        next.remindersEnabled = true

        return next
    }

    // MARK: - 完成档次 → 复习推进规则（G 的旧业务接入）

    /// 完成档次对应的默认评分。
    ///
    /// 用户的答题自评优先；没有自评时按档次取默认值：
    /// - 标准完成 → `fallback`（默认"正常"）；
    /// - 保底 / 已学习 → "感觉熟悉但答错"（SM-2 中 q < 3，重置间隔）。
    static func quality(
        forTier tier: PlanCompletionTier,
        assessment: StudyAssessment?,
        fallback: Quality = .good
    ) -> Quality {
        if let rating = assessment?.selfRating, let quality = Quality(rawValue: rating) {
            return quality
        }
        switch tier {
        case .standard: return fallback
        case .minimum, .studied: return .incorrectButFamiliar
        }
    }

    /// 把一次"计划项完成"折算成复习任务的 SM-2 状态。
    ///
    /// 关键规则（公共开发约束）：
    /// - **完整复习**才按原 SM-2 规则推进间隔；
    /// - **部分练习不能直接当作完整成功复习**：评分封顶到 q < 3，间隔重置；
    /// - **已学习（未到保底）**不改变 SM-2 状态，任务仍然到期。
    static func applyCompletion(
        task: ReviewTask,
        tier: PlanCompletionTier,
        quality: Quality,
        context: PlanningContext
    ) -> ReviewTask {
        switch tier {
        case .standard:
            return scheduleNextReview(task: task, quality: quality, context: context)
        case .minimum:
            let capped = Quality(rawValue: min(quality.rawValue, Quality.incorrectButFamiliar.rawValue))
                ?? .incorrectButFamiliar
            return scheduleNextReview(task: task, quality: capped, context: context)
        case .studied:
            // 没有达到保底门槛：保留原到期日与 SM-2 状态，任务仍需继续。
            var unchanged = task
            unchanged.status = .pending
            return unchanged
        }
    }


    // MARK: - Draft → initial tasks

    /// Generate initial review tasks from an analysis draft.
    /// SM-2 initialization: all tasks start with EF=2.5, n=0, interval=0.
    /// Tasks with `dueInDays=0` are due today; others follow the draft's suggested delay.
    static func makeTasks(
        for draft: AnalysisDraft,
        titleToID: [String: UUID],
        mistakeIDsByDraftID: [UUID: UUID] = [:],
        now: Date = Date()
    ) -> [ReviewTask] {
        let aiTasks = draft.reviewItems.compactMap { item -> ReviewTask? in
            let days = normalizedInterval(item.dueInDays)
            let p = item.priority ?? priority(forMastery: mastery(for: item.relatedKnowledgeTitle, in: draft))
            let relatedMistakeID = draftMistakeID(for: item, in: draft).flatMap { mistakeIDsByDraftID[$0] }
            return ReviewTask(
                title: item.title,
                dueDate: initialReviewDueDate(daysFromNow: days, now: now),
                knowledgePointID: item.relatedKnowledgeTitle.flatMap { titleToID[$0] },
                mistakeID: relatedMistakeID,
                priority: min(max(p, 0), 5),
                easinessFactor: 2.5,
                repetitionCount: 0,
                intervalDays: days
            )
        }

        if !aiTasks.isEmpty {
            let coveredMistakeIDs = Set(draft.reviewItems.compactMap { draftMistakeID(for: $0, in: draft) })
            let uncoveredMistakes = draft.mistakes.filter { !coveredMistakeIDs.contains($0.id) }
            let generatedMistakeTasks = makeMistakeReviewTasks(
                for: uncoveredMistakes,
                in: draft,
                titleToID: titleToID,
                mistakeIDsByDraftID: mistakeIDsByDraftID,
                now: now
            )
            return Array((aiTasks + generatedMistakeTasks).sortedForStudy().prefix(80))
        }

        var generated: [ReviewTask] = []
        for point in draft.knowledgePoints.sorted(by: { $0.mastery < $1.mastery }) {
            let priority = priority(forMastery: point.mastery)
            for days in defaultIntervals {
                generated.append(
                    ReviewTask(
                        title: "复习知识点：\(point.title)",
                        dueDate: initialReviewDueDate(daysFromNow: days, now: now),
                        knowledgePointID: titleToID[point.title],
                        priority: priority,
                        intervalDays: days
                    )
                )
            }
        }

        generated.append(contentsOf: makeMistakeReviewTasks(
            for: draft.mistakes,
            in: draft,
            titleToID: titleToID,
            mistakeIDsByDraftID: mistakeIDsByDraftID,
            now: now
        ))

        return Array(generated.sortedForStudy().prefix(80))
    }

    private static func makeMistakeReviewTasks(
        for mistakes: [DraftMistake],
        in draft: AnalysisDraft,
        titleToID: [String: UUID],
        mistakeIDsByDraftID: [UUID: UUID],
        now: Date
    ) -> [ReviewTask] {
        var generated: [ReviewTask] = []
        for mistake in mistakes {
            let relatedMastery = mistake.relatedKnowledgeTitles
                .compactMap { title in draft.knowledgePoints.first { $0.title == title }?.mastery }
                .min()
            let priority = priority(forMastery: relatedMastery ?? 0.25) + 1
            for days in defaultIntervals {
                generated.append(
                    ReviewTask(
                        title: "重做错题：\(shortTitle(mistake.question))",
                        dueDate: initialReviewDueDate(daysFromNow: days, now: now),
                        knowledgePointID: mistake.relatedKnowledgeTitles.first.flatMap { titleToID[$0] },
                        mistakeID: mistakeIDsByDraftID[mistake.id],
                        priority: min(priority, 5),
                        intervalDays: days
                    )
                )
            }
        }

        return generated
    }

    // MARK: - Helpers

    nonisolated static func shortTitle(_ text: String) -> String {
        text.compactedForStudyText(limit: 36)
    }

    // MARK: - Private

    private static func calendarDate(daysFromNow days: Int, now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: now) ?? now
    }

    static func reviewDueDate(daysFromNow days: Int, now: Date = Date()) -> Date {
        reviewDueDate(daysFromNow: days, now: now, calendar: .current)
    }

    static func reviewDueDate(daysFromNow days: Int, now: Date, calendar: Calendar) -> Date {
        let targetDay = calendarDate(daysFromNow: max(0, days), now: now, calendar: calendar)
        return reviewDueDate(on: targetDay, now: now, calendar: calendar)
    }

    static func reviewDueDate(byAddingDays days: Int, to date: Date, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let base = date < now ? now : date
        let targetDay = calendar.date(byAdding: .day, value: max(0, days), to: base) ?? base
        return reviewDueDate(on: targetDay, now: now)
    }

    private static func initialReviewDueDate(daysFromNow days: Int, now: Date) -> Date {
        reviewDueDate(daysFromNow: days, now: now)
    }

    private static func reviewDueDate(on targetDay: Date, now: Date, calendar: Calendar = .current) -> Date {
        let targetStart = calendar.startOfDay(for: targetDay)
        let preferred = calendar.date(
            bySettingHour: initialTaskDueHour,
            minute: 0,
            second: 0,
            of: targetStart
        ) ?? targetStart

        guard preferred <= now else {
            return preferred
        }

        return calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(60 * 60)
    }

    private static func mastery(for title: String?, in draft: AnalysisDraft) -> Double {
        guard let title,
              let point = draft.knowledgePoints.first(where: { $0.title == title }) else {
            return 0.4
        }
        return point.mastery
    }

    private static func draftMistakeID(for item: DraftReviewItem, in draft: AnalysisDraft) -> UUID? {
        if let relatedMistakeID = item.relatedMistakeID,
           draft.mistakes.contains(where: { $0.id == relatedMistakeID }) {
            return relatedMistakeID
        }

        guard let title = item.relatedMistakeTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        let normalizedTitle = normalizedReference(title)
        return draft.mistakes.first { mistake in
            let normalizedQuestion = normalizedReference(mistake.question)
            return normalizedQuestion == normalizedTitle
                || normalizedQuestion.contains(normalizedTitle)
                || normalizedTitle.contains(normalizedQuestion)
        }?.id
    }

    private static func normalizedReference(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func normalizedInterval(_ days: Int) -> Int {
        guard days >= 0 else { return 0 }
        return min(days, 365)
    }

    private static func priority(forMastery mastery: Double) -> Int {
        switch mastery {
        case ..<0.25: return 5
        case ..<0.45: return 4
        case ..<0.65: return 3
        case ..<0.8: return 2
        default: return 1
        }
    }
}

private extension Array where Element == ReviewTask {
    func sortedForStudy() -> [ReviewTask] {
        sorted {
            if ($0.priority ?? 0) != ($1.priority ?? 0) {
                return ($0.priority ?? 0) > ($1.priority ?? 0)
            }
            return $0.dueDate < $1.dueDate
        }
    }
}
