import Foundation

enum BackupImportMode { case replace, merge }

/// 显式手动合并备份：追加稳定身份不同的记录，同身份冲突保留本机版本并报告。
/// 设置和设备偏好留在本机；不根据旧汇总推造作答、时长或奖励。
enum SnapshotMergeService {
    struct Report: Equatable {
        var added = 0
        var updated = 0
        var identical = 0
        var conflicts = 0

        var didChange: Bool { added > 0 || updated > 0 }
        var summary: String {
            "新增 \(added) 条，关联或状态更新 \(updated) 条；跳过相同 \(identical) 条、同身份冲突 \(conflicts) 条（保留本机版本）"
        }
    }

    struct Result {
        var snapshot: StoreSnapshot
        var report: Report
    }

    static func merge(local: StoreSnapshot, incoming: StoreSnapshot) throws -> Result {
        var result = local.normalizedToCurrentSchema()
        var report = Report()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        result.documents = try records(local.documents, incoming.documents, key: { $0.id.uuidString },
            encoder: encoder, report: &report) { left, right in
                var lhs = left
                var rhs = right
                lhs.backupPDFData = nil
                rhs.backupPDFData = nil
                lhs.originalPDFFileName = nil
                rhs.originalPDFFileName = nil
                return try encoder.encode(lhs) == encoder.encode(rhs)
            }
        result.examGoals = try records(local.examGoals, incoming.examGoals, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.knowledgePoints = try records(local.knowledgePoints, incoming.knowledgePoints, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.mistakes = try records(local.mistakes, incoming.mistakes, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.reviewTasks = try records(local.reviewTasks, incoming.reviewTasks, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.studyCards = try records(local.studyCards, incoming.studyCards, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.reviewAttempts = try attempts(local.reviewAttempts, incoming.reviewAttempts, encoder: encoder, report: &report)
        // 共有任务保留本机调度。另一端新作答的“提交前调度”不能用于本机撤销，
        // 否则会把本机之后的复习状态倒退到另一端的分支。
        let localTaskIDs = Set(local.reviewTasks.map(\.id))
        let localAttemptIDs = Set(local.reviewAttempts.map(\.id))
        for index in result.reviewAttempts.indices {
            let attempt = result.reviewAttempts[index]
            guard !localAttemptIDs.contains(attempt.id),
                  let taskID = attempt.reviewTaskID, localTaskIDs.contains(taskID),
                  attempt.priorReviewTask != nil else { continue }
            result.reviewAttempts[index].priorReviewTask = nil
            report.updated += 1
        }
        result.drafts = try records(local.drafts, incoming.drafts, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.aiPlanDrafts = try records(local.aiPlanDrafts, incoming.aiPlanDrafts, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.aiPlanPatches = try records(local.aiPlanPatches, incoming.aiPlanPatches, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.chatMessages = try records(local.chatMessages, incoming.chatMessages, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.dailyActivityRecords = try records(local.dailyActivityRecords, incoming.dailyActivityRecords,
            key: { $0.dateString }, encoder: encoder, report: &report)

        if result.scheduleSemester == nil, let semester = incoming.scheduleSemester {
            result.scheduleSemester = semester
            result.semesterIdentity = incoming.semesterIdentity
            report.added += 1
        }
        if local.scheduleSemester != nil && incoming.scheduleSemester != nil
            && local.semesterIdentity.id != incoming.semesterIdentity.id {
            report.conflicts += incoming.scheduleCourses.count + incoming.scheduleExceptions.count
                + incoming.courseBurdenLevels.count
        } else {
            result.scheduleCourses = try records(local.scheduleCourses, incoming.scheduleCourses,
                key: { $0.id.uuidString }, encoder: encoder, report: &report)
            result.scheduleExceptions = try records(local.scheduleExceptions, incoming.scheduleExceptions,
                key: { $0.id.uuidString }, encoder: encoder, report: &report)
            result.courseBurdenLevels = try records(local.courseBurdenLevels, incoming.courseBurdenLevels,
                key: { $0.courseID.uuidString }, encoder: encoder, report: &report)
        }
        result.manualStudyTasks = try records(local.manualStudyTasks, incoming.manualStudyTasks,
            key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.dailyPlans = try records(local.dailyPlans, incoming.dailyPlans, key: { $0.id.uuidString }, encoder: encoder, report: &report)
        normalizeActivePlans(&result.dailyPlans, preferring: local.dailyPlans, report: &report)
        result.studySessions = try records(local.studySessions, incoming.studySessions,
            key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.completionEvents = try completions(local.completionEvents, incoming.completionEvents,
            encoder: encoder, report: &report)
        result.entertainmentRules = try records(local.entertainmentRules, incoming.entertainmentRules,
            key: { $0.id.uuidString }, encoder: encoder, report: &report)
        result.rewardGrants = try records(local.rewardGrants, incoming.rewardGrants,
            key: { $0.grantKey }, encoder: encoder, report: &report)
        remapCompletionReferences(in: &result, incoming: incoming.completionEvents, report: &report)
        if !result.onboardingCompleted && incoming.onboardingCompleted {
            result.onboardingCompleted = true
            report.updated += 1
        }
        return Result(snapshot: result, report: report)
    }

    private static func records<T: Encodable>(_ local: [T], _ incoming: [T],
                                               key: (T) -> String, encoder: JSONEncoder,
                                               report: inout Report,
                                               equivalent: ((T, T) throws -> Bool)? = nil) throws -> [T] {
        var merged = local
        var seen: [String: Int] = [:]
        for (index, item) in merged.enumerated() where seen[key(item)] == nil { seen[key(item)] = index }
        for item in incoming {
            let identity = key(item)
            if let index = seen[identity] {
                let same = try equivalent?(merged[index], item)
                    ?? (encoder.encode(merged[index]) == encoder.encode(item))
                if same { report.identical += 1 }
                else { report.conflicts += 1 }
            } else {
                seen[identity] = merged.count
                merged.append(item)
                report.added += 1
            }
        }
        return merged
    }

    private static func attempts(_ local: [ReviewAttempt], _ incoming: [ReviewAttempt],
                                 encoder: JSONEncoder, report: inout Report) throws -> [ReviewAttempt] {
        var merged = local
        var seen: [UUID: Int] = [:]
        for (index, item) in local.enumerated() where seen[item.id] == nil { seen[item.id] = index }
        for item in incoming {
            if let index = seen[item.id] {
                if merged[index].isActive && !item.isActive {
                    merged[index].revokedAt = item.revokedAt
                    merged[index].revocationReason = item.revocationReason
                    report.updated += 1
                } else if try encoder.encode(merged[index]) == encoder.encode(item) { report.identical += 1 }
                else { report.conflicts += 1 }
            } else {
                seen[item.id] = merged.count
                merged.append(item)
                report.added += 1
            }
        }
        return merged
    }

    private static func completions(_ local: [CompletionEvent], _ incoming: [CompletionEvent],
                                    encoder: JSONEncoder, report: inout Report) throws -> [CompletionEvent] {
        var merged = local
        var seenKeys: [String: Int] = [:]
        for (index, item) in local.enumerated() where seenKeys[item.idempotencyKey] == nil {
            seenKeys[item.idempotencyKey] = index
        }
        var seenIDs = Set(local.map(\.id))
        for item in incoming {
            if let index = seenKeys[item.idempotencyKey] {
                // 同一任务同一天可能在两端各自完成。按幂等键去重时，另一端
                // 独立事件的撤销不能抹掉本机仍有效的完成和奖励。
                if merged[index].id == item.id && !merged[index].isRevoked && item.isRevoked {
                    merged[index] = merged[index].revoked(at: item.revocation!.revokedAt,
                        reason: item.revocation!.reason, by: item.revocation!.revokedBy)
                    report.updated += 1
                } else if try encoder.encode(merged[index]) == encoder.encode(item) { report.identical += 1 }
                else { report.conflicts += 1 }
            } else if seenIDs.contains(item.id) {
                report.conflicts += 1
            } else {
                seenKeys[item.idempotencyKey] = merged.count
                seenIDs.insert(item.id)
                merged.append(item)
                report.added += 1
            }
        }
        return merged
    }

    private static func remapCompletionReferences(in snapshot: inout StoreSnapshot,
                                                  incoming: [CompletionEvent], report: inout Report) {
        var incomingKeys: [UUID: String] = [:]
        for event in incoming where incomingKeys[event.id] == nil { incomingKeys[event.id] = event.idempotencyKey }
        let mergedIDs = Set(snapshot.completionEvents.map(\.id))
        var mergedByKey: [String: UUID] = [:]
        for event in snapshot.completionEvents where mergedByKey[event.idempotencyKey] == nil {
            mergedByKey[event.idempotencyKey] = event.id
        }
        func resolvedID(_ id: UUID) -> UUID? {
            if mergedIDs.contains(id) { return id }
            guard let key = incomingKeys[id] else { return nil }
            return mergedByKey[key]
        }
        for index in snapshot.reviewAttempts.indices {
            guard let oldID = snapshot.reviewAttempts[index].completionEventID,
                  let newID = resolvedID(oldID), newID != oldID else { continue }
            snapshot.reviewAttempts[index].completionEventID = newID
            report.updated += 1
        }
        for index in snapshot.rewardGrants.indices {
            let oldIDs = snapshot.rewardGrants[index].basisEventIDs
            let newIDs = oldIDs.map { resolvedID($0) ?? $0 }
            guard newIDs != oldIDs else { continue }
            snapshot.rewardGrants[index].basisEventIDs = Array(Set(newIDs)).sorted { $0.uuidString < $1.uuidString }
            report.updated += 1
        }
    }

    private static func normalizeActivePlans(_ plans: inout [DailyStudyPlan], preferring local: [DailyStudyPlan],
                                             report: inout Report) {
        var preferred: [StudyDayKey: UUID] = [:]
        for plan in local where plan.isActive { preferred[plan.dayKey] = plan.id }
        for plan in plans where plan.isActive && preferred[plan.dayKey] == nil {
            preferred[plan.dayKey] = plan.id
        }
        for index in plans.indices where plans[index].isActive && preferred[plans[index].dayKey] != plans[index].id {
            plans[index].status = .superseded
            report.updated += 1
        }
    }
}
