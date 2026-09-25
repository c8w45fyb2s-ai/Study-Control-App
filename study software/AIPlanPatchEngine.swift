import Foundation

struct AIPlanPatchApplicationResult {
    var patch: AIPlanPatch
    var updatedReviewTaskIDs: [UUID]
    var deletedReviewTaskIDs: [UUID]
    var skippedOperationCount: Int

    var affectedCount: Int {
        updatedReviewTaskIDs.count + deletedReviewTaskIDs.count
    }

    var summary: String {
        if affectedCount == 0 {
            return "没有找到可修改的复习任务。"
        }

        var parts: [String] = []
        if !updatedReviewTaskIDs.isEmpty {
            parts.append("更新 \(updatedReviewTaskIDs.count) 个任务")
        }
        if !deletedReviewTaskIDs.isEmpty {
            parts.append("删除 \(deletedReviewTaskIDs.count) 个任务")
        }
        return "已修改复习计划：" + parts.joined(separator: "，")
    }
}

enum AIPlanPatchEngine {
    static func makeRuleBasedPatch(command: String, snapshot: StoreSnapshot, now: Date = Date()) -> AIPlanPatch? {
        let normalized = normalize(command)
        guard isPatchIntent(normalized) else { return nil }

        if containsAny(normalized, ["减半", "砍半", "减少一半", "少一半"]) {
            return makeReduceWeekPatch(command: command, snapshot: snapshot, now: now)
        }

        if containsAny(normalized, ["明天有事", "明天没空", "明天不方便", "明天不能学", "明天没时间", "顺延"]) {
            return makePostponePatch(command: command, snapshot: snapshot, now: now)
        }

        if containsAny(normalized, ["优先级提高", "提高优先级", "优先级调高", "更优先", "优先级最高"]) {
            return makePriorityPatch(command: command, normalizedCommand: normalized, snapshot: snapshot)
        }

        if containsAny(normalized, ["删除太宽泛", "删掉太宽泛", "删除宽泛", "删掉宽泛", "删除泛泛", "删除空泛"]) {
            return makeDeleteBroadTasksPatch(command: command, snapshot: snapshot)
        }

        if containsAny(normalized, ["没完成", "未完成"]) && containsAny(normalized, ["重新安排明天", "安排明天", "排到明天", "明天"]) {
            return makeRescheduleUnfinishedTodayPatch(command: command, snapshot: snapshot, now: now)
        }

        return nil
    }

    static func apply(_ patch: AIPlanPatch, to snapshot: inout StoreSnapshot, now: Date = Date()) -> AIPlanPatchApplicationResult {
        var updatedTaskIDs: [UUID] = []
        var deletedTaskIDs: [UUID] = []
        var skippedCount = 0

        for operation in patch.operations {
            guard let index = snapshot.reviewTasks.firstIndex(where: { $0.id == operation.reviewTaskID }) else {
                skippedCount += 1
                continue
            }

            switch operation.kind {
            case .delete:
                let removed = snapshot.reviewTasks.remove(at: index)
                deletedTaskIDs.append(removed.id)

            case .reschedule:
                guard let dueDate = operation.newDueDate else {
                    skippedCount += 1
                    continue
                }
                snapshot.reviewTasks[index].dueDate = dueDate
                snapshot.reviewTasks[index].status = .pending
                updatedTaskIDs.append(snapshot.reviewTasks[index].id)

            case .updatePriority:
                guard let priority = operation.newPriority else {
                    skippedCount += 1
                    continue
                }
                snapshot.reviewTasks[index].priority = min(max(priority, 0), 5)
                updatedTaskIDs.append(snapshot.reviewTasks[index].id)

            case .updateTitle:
                guard let title = operation.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else {
                    skippedCount += 1
                    continue
                }
                snapshot.reviewTasks[index].title = title
                updatedTaskIDs.append(snapshot.reviewTasks[index].id)
            }
        }

        var appliedPatch = patch
        appliedPatch.status = updatedTaskIDs.isEmpty && deletedTaskIDs.isEmpty ? .failed : .applied
        appliedPatch.appliedAt = now
        appliedPatch.updatedReviewTaskIDs = Array(Set(updatedTaskIDs))
        appliedPatch.deletedReviewTaskIDs = Array(Set(deletedTaskIDs))
        snapshot.aiPlanPatches.insert(appliedPatch, at: 0)

        return AIPlanPatchApplicationResult(
            patch: appliedPatch,
            updatedReviewTaskIDs: appliedPatch.updatedReviewTaskIDs,
            deletedReviewTaskIDs: appliedPatch.deletedReviewTaskIDs,
            skippedOperationCount: skippedCount
        )
    }

    private static func makeReduceWeekPatch(command: String, snapshot: StoreSnapshot, now: Date) -> AIPlanPatch? {
        let tasks = pendingTasks(in: snapshot, from: now, days: 7)
            .sorted {
                if ($0.priority ?? 0) != ($1.priority ?? 0) {
                    return ($0.priority ?? 0) < ($1.priority ?? 0)
                }
                return $0.dueDate > $1.dueDate
            }
        guard tasks.count >= 2 else { return nil }

        let moveCount = max(1, tasks.count / 2)
        let operations = tasks.prefix(moveCount).enumerated().map { offset, task in
            AIPlanPatchOperation(
                kind: .reschedule,
                reviewTaskID: task.id,
                reviewTaskTitle: task.title,
                newDueDate: dueDate(daysFromNow: 7 + offset, now: now),
                reason: "本周计划减半，低优先级任务顺延到下周"
            )
        }

        return patch(title: "本周计划减半", summary: "将本周低优先级任务顺延到下周。", command: command, operations: operations)
    }

    private static func makePostponePatch(command: String, snapshot: StoreSnapshot, now: Date) -> AIPlanPatch? {
        let normalized = normalize(command)
        let tasks: [ReviewTask]
        let summary: String
        if containsAny(normalized, ["明天有事", "明天没空", "明天不方便", "明天不能学", "明天没时间"]) {
            tasks = tasksDue(onDayOffset: 1, snapshot: snapshot, now: now)
            summary = "将明天任务顺延 1 天。"
        } else {
            tasks = pendingTasks(in: snapshot, from: now, days: 1)
            summary = "将近期任务顺延 1 天。"
        }

        let operations = tasks.map { task in
            AIPlanPatchOperation(
                kind: .reschedule,
                reviewTaskID: task.id,
                reviewTaskTitle: task.title,
                newDueDate: addingDays(1, to: task.dueDate),
                reason: "用户要求顺延"
            )
        }

        return patch(title: "顺延复习任务", summary: summary, command: command, operations: operations)
    }

    private static func makePriorityPatch(command: String, normalizedCommand: String, snapshot: StoreSnapshot) -> AIPlanPatch? {
        let keyword = priorityKeyword(from: normalizedCommand)
        let tasks = snapshot.reviewTasks.filter { task in
            task.status == .pending && matches(task: task, keyword: keyword, snapshot: snapshot)
        }
        let setToHighest = containsAny(normalizedCommand, ["最高", "拉满", "优先级5"])

        let operations = tasks.map { task in
            AIPlanPatchOperation(
                kind: .updatePriority,
                reviewTaskID: task.id,
                reviewTaskTitle: task.title,
                newPriority: setToHighest ? 5 : min((task.priority ?? 3) + 1, 5),
                reason: "提高相关任务优先级"
            )
        }

        let label = keyword.isEmpty ? "相关" : keyword
        return patch(title: "提高\(label)任务优先级", summary: "提高匹配任务的优先级。", command: command, operations: operations)
    }

    private static func makeDeleteBroadTasksPatch(command: String, snapshot: StoreSnapshot) -> AIPlanPatch? {
        let tasks = snapshot.reviewTasks.filter { task in
            task.status == .pending && isBroadTaskTitle(task.title)
        }
        let operations = tasks.map { task in
            AIPlanPatchOperation(
                kind: .delete,
                reviewTaskID: task.id,
                reviewTaskTitle: task.title,
                reason: "任务标题过于宽泛"
            )
        }

        return patch(title: "删除宽泛任务", summary: "删除标题过于宽泛、难以执行的任务。", command: command, operations: operations)
    }

    private static func makeRescheduleUnfinishedTodayPatch(command: String, snapshot: StoreSnapshot, now: Date) -> AIPlanPatch? {
        let tasks = unfinishedThroughToday(snapshot: snapshot, now: now)
        let operations = tasks.enumerated().map { offset, task in
            AIPlanPatchOperation(
                kind: .reschedule,
                reviewTaskID: task.id,
                reviewTaskTitle: task.title,
                newDueDate: dueDate(daysFromNow: 1 + offset / 4, now: now),
                reason: "根据今日未完成任务重新安排明天"
            )
        }

        return patch(title: "重新安排明天任务", summary: "把今日未完成任务移到明天，并按容量分散。", command: command, operations: operations)
    }

    private static func patch(title: String, summary: String, command: String, operations: [AIPlanPatchOperation]) -> AIPlanPatch? {
        guard !operations.isEmpty else { return nil }
        return AIPlanPatch(
            title: title,
            summary: summary,
            operations: operations
        )
    }

    private static func isPatchIntent(_ normalized: String) -> Bool {
        containsAny(normalized, [
            "减半", "顺延", "优先级", "删除", "删掉", "重新安排", "排到明天",
            "修改计划", "调整计划", "改一下计划", "改复习计划", "调整复习计划"
        ])
    }

    private static func pendingTasks(in snapshot: StoreSnapshot, from now: Date, days: Int) -> [ReviewTask] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? now
        return snapshot.reviewTasks
            .filter { $0.status == .pending && $0.dueDate >= start && $0.dueDate < end }
            .sorted { $0.dueDate < $1.dueDate }
    }

    private static func tasksDue(onDayOffset offset: Int, snapshot: StoreSnapshot, now: Date) -> [ReviewTask] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        return snapshot.reviewTasks
            .filter { $0.status == .pending && $0.dueDate >= start && $0.dueDate < end }
            .sorted { $0.dueDate < $1.dueDate }
    }

    private static func unfinishedThroughToday(snapshot: StoreSnapshot, now: Date) -> [ReviewTask] {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        return snapshot.reviewTasks
            .filter { $0.status == .pending && $0.dueDate < tomorrow }
            .sorted {
                if ($0.priority ?? 0) != ($1.priority ?? 0) {
                    return ($0.priority ?? 0) > ($1.priority ?? 0)
                }
                return $0.dueDate < $1.dueDate
            }
    }

    private static func priorityKeyword(from normalized: String) -> String {
        let separators = ["优先级", "提高", "调高", "最高", "更优先", "把", "将", "的"]
        var candidate = normalized
        for separator in separators {
            candidate = candidate.replacingOccurrences(of: separator, with: " ")
        }
        return candidate
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
            .max(by: { $0.count < $1.count }) ?? ""
    }

    private static func matches(task: ReviewTask, keyword: String, snapshot: StoreSnapshot) -> Bool {
        guard !keyword.isEmpty else { return true }
        let key = normalize(keyword)
        let haystack = normalize([
            task.title,
            task.knowledgePointID.flatMap { id in snapshot.knowledgePoints.first { $0.id == id }?.title } ?? "",
            task.mistakeID.flatMap { id in snapshot.mistakes.first { $0.id == id }?.question } ?? ""
        ].joined(separator: " "))
        return haystack.contains(key) || key.contains(haystack)
    }

    private static func isBroadTaskTitle(_ title: String) -> Bool {
        let normalized = normalize(title)
        let broadTitles = [
            "复习", "学习", "刷题", "做题", "看书", "背书", "背单词",
            "整理笔记", "复盘", "练习", "预习", "看课", "总结"
        ]
        if broadTitles.contains(normalized) { return true }
        return normalized.count <= 5 && broadTitles.contains { normalized.contains($0) }
    }

    private static func dueDate(daysFromNow: Int, now: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let target = calendar.date(byAdding: .day, value: max(0, daysFromNow), to: start) ?? now
        return calendar.date(bySettingHour: 22, minute: 0, second: 0, of: target) ?? target
    }

    private static func addingDays(_ days: Int, to date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    private static func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains { text.contains(normalize($0)) }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
    }
}
