import Foundation

struct AIPlanIterationResult {
    var draftID: UUID
    var adjustedReviewTaskIDs: [UUID]
    var note: String
}

enum AIPlanIterationEngine {
    static func refresh(snapshot: inout StoreSnapshot, now: Date = Date()) -> [AIPlanIterationResult] {
        var results: [AIPlanIterationResult] = []
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? now

        for draftIndex in snapshot.aiPlanDrafts.indices {
            var draft = snapshot.aiPlanDrafts[draftIndex]
            guard draft.status == .confirmed, !draft.createdReviewTaskIDs.isEmpty else { continue }
            if let lastIterationAt = draft.lastIterationAt,
               calendar.isDate(lastIterationAt, inSameDayAs: now) {
                continue
            }

            let planTaskIDs = Set(draft.createdReviewTaskIDs)
            let taskIndices = snapshot.reviewTasks.indices.filter { planTaskIDs.contains(snapshot.reviewTasks[$0].id) }
            guard !taskIndices.isEmpty else { continue }

            var adjustedTaskIDs: [UUID] = []
            var noteParts: [String] = []

            let overdueIndices = taskIndices
                .filter { snapshot.reviewTasks[$0].status == .pending && snapshot.reviewTasks[$0].dueDate < todayStart }
                .sorted { snapshot.reviewTasks[$0].dueDate < snapshot.reviewTasks[$1].dueDate }

            if !overdueIndices.isEmpty {
                let dailyCarryLimit = carryLimit(for: draft.planTemplate)
                for (offset, taskIndex) in overdueIndices.enumerated() {
                    let daysFromNow = offset / dailyCarryLimit
                    snapshot.reviewTasks[taskIndex].dueDate = rollingDueDate(daysFromNow: daysFromNow, now: now)
                    if let priority = snapshot.reviewTasks[taskIndex].priority {
                        snapshot.reviewTasks[taskIndex].priority = max(0, priority - 1)
                    }
                    adjustedTaskIDs.append(snapshot.reviewTasks[taskIndex].id)
                }
                noteParts.append("顺延 \(overdueIndices.count) 个未完成任务，并降低优先级")
            }

            let goodCompletionCount = taskIndices.filter { taskIndex in
                let task = snapshot.reviewTasks[taskIndex]
                guard let reviewedAt = task.lastReviewedAt,
                      reviewedAt >= yesterdayStart,
                      reviewedAt < todayStart else {
                    return false
                }
                return (task.lastQuality ?? 0) >= ReviewPlanner.Quality.good.rawValue
            }.count

            if goodCompletionCount >= accelerationThreshold(for: draft.planTemplate),
               let futureIndex = taskIndices
                .filter({ snapshot.reviewTasks[$0].status == .pending && snapshot.reviewTasks[$0].dueDate > tomorrowStart })
                .sorted(by: { snapshot.reviewTasks[$0].dueDate < snapshot.reviewTasks[$1].dueDate })
                .first {
                snapshot.reviewTasks[futureIndex].dueDate = rollingDueDate(daysFromNow: 1, now: now)
                if let priority = snapshot.reviewTasks[futureIndex].priority {
                    snapshot.reviewTasks[futureIndex].priority = min(5, priority + 1)
                }
                adjustedTaskIDs.append(snapshot.reviewTasks[futureIndex].id)
                noteParts.append("昨日完成较好，提前 1 个后续任务")
            }

            let uniqueAdjustedIDs = Array(Set(adjustedTaskIDs))
            guard !uniqueAdjustedIDs.isEmpty else { continue }

            draft.lastIterationAt = now
            draft.iterationCount += 1
            draft.iterationNote = noteParts.joined(separator: "；")
            snapshot.aiPlanDrafts[draftIndex] = draft

            results.append(
                AIPlanIterationResult(
                    draftID: draft.id,
                    adjustedReviewTaskIDs: uniqueAdjustedIDs,
                    note: draft.iterationNote ?? "AI 计划已滚动调整"
                )
            )
        }

        return results
    }

    private static func carryLimit(for template: AIPlanTemplate) -> Int {
        switch template {
        case .today: return 2
        case .week: return 3
        case .thirtyDays: return 4
        case .general: return 3
        }
    }

    private static func accelerationThreshold(for template: AIPlanTemplate) -> Int {
        switch template {
        case .today: return Int.max
        case .week: return 2
        case .thirtyDays: return 3
        case .general: return 2
        }
    }

    private static func rollingDueDate(daysFromNow: Int, now: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let targetDay = calendar.date(byAdding: .day, value: max(0, daysFromNow), to: start) ?? now
        let due = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: targetDay) ?? targetDay
        if due <= now {
            return calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        }
        return due
    }
}
