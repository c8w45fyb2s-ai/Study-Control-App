import Foundation

@MainActor
private final class MergeKeychain: AIKeychainStoring {
    func loadAPIKey(for configuration: AIConnectionConfiguration, allowLegacyFallback: Bool) -> String { "" }
    func credentialState(for configuration: AIConnectionConfiguration) throws -> AIKeychainCredentialState {
        AIKeychainCredentialState(apiKey: nil, migrationMarker: nil)
    }
    func saveAPIKey(_ value: String, for configuration: AIConnectionConfiguration) throws {}
    func restoreCredentialState(_ state: AIKeychainCredentialState, for configuration: AIConnectionConfiguration) throws {}
    func hasScopedCredential(for configuration: AIConnectionConfiguration) -> Bool { false }
}

@main
struct MergeImportVerify {
    static func check(_ condition: Bool, _ message: String) {
        if condition { print("PASS \(message)") }
        else { fatalError("FAIL \(message)") }
    }

    @MainActor
    static func main() async throws {
        let sourceLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "MergeImportSource")
        let targetLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "MergeImportTarget")
        defer {
            try? FileManager.default.removeItem(at: sourceLocation.directory)
            try? FileManager.default.removeItem(at: targetLocation.directory)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = StudyDayKey(date: now, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let sharedID = UUID()
        let sharedLocal = StudyDocument(id: sharedID, title: "共有资料", sourceName: "shared.txt",
            kind: .note, importedAt: now, content: "本机修订")
        let sharedRemote = StudyDocument(id: sharedID, title: "共有资料", sourceName: "shared.txt",
            kind: .note, importedAt: now, content: "另一端修订")
        var localDocument = StudyDocument(title: "本机 PDF", sourceName: "local.pdf", kind: .note,
            importedAt: now, content: "本机原文")
        localDocument.originalPDFFileName = "\(localDocument.id.uuidString).pdf"
        var remoteDocument = StudyDocument(title: "另一端 PDF", sourceName: "remote.pdf", kind: .note,
            importedAt: now, content: "另一端原文")
        remoteDocument.originalPDFFileName = "\(remoteDocument.id.uuidString).pdf"
        let localAttachment = Data("%PDF local synthetic".utf8)
        let remoteAttachment = Data("%PDF remote synthetic".utf8)
        let sourceAttachments = sourceLocation.directory.appendingPathComponent("Attachments", isDirectory: true)
        let targetAttachments = targetLocation.directory.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAttachments, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetAttachments, withIntermediateDirectories: true)
        try remoteAttachment.write(to: sourceAttachments.appendingPathComponent(remoteDocument.originalPDFFileName!))
        try localAttachment.write(to: targetAttachments.appendingPathComponent(localDocument.originalPDFFileName!))

        let task = ReviewTask(title: "合成复习", dueDate: now.addingTimeInterval(86_400 * 30))
        let card = StudyCard(kind: .questionAnswer, prompt: "合成问题", answer: "合成答案")
        let key = "same-task-day-key"
        let localEvent = CompletionEvent(id: UUID(), idempotencyKey: key, dayKey: day,
            source: .reviewTask(task.id), completedScope: .tasks(1), tier: .studied,
            actualMinutes: 0, durationSource: .unrecorded, completedAt: now, createdAt: now)
        let remoteEvent = CompletionEvent(id: UUID(), idempotencyKey: key, dayKey: day,
            source: .reviewTask(task.id), completedScope: .tasks(1), tier: .studied,
            actualMinutes: 0, durationSource: .unrecorded, completedAt: now, createdAt: now)
        let remoteAttempt = ReviewAttempt(id: UUID(), cardID: card.id, contentVersion: card.contentVersion,
            reviewTaskID: task.id, startedAt: now.addingTimeInterval(-30), submittedAt: now,
            answer: "合成回答", quality: 4, revealedAnswer: true, durationSeconds: 30,
            revokedAt: nil, revocationReason: nil, completionEventID: remoteEvent.id, priorReviewTask: task)
        var source = StoreSnapshot()
        source.documents = [sharedRemote, remoteDocument]
        source.reviewTasks = [task]
        source.studyCards = [card]
        source.reviewAttempts = [remoteAttempt]
        source.completionEvents = [remoteEvent]
        var target = StoreSnapshot()
        target.documents = [sharedLocal, localDocument]
        target.reviewTasks = [task]
        target.completionEvents = [localEvent]
        target.settings.allowModelRequests = false

        let pureMerge = try SnapshotMergeService.merge(local: target, incoming: source)
        check(pureMerge.report.conflicts >= 2, "同 ID 内容冲突和同幂等键事件被检测")
        check(pureMerge.snapshot.documents.first?.content == "本机修订", "冲突时保留本机内容")
        check(pureMerge.snapshot.completionEvents.count == 1, "同任务同日完成依据不重复")
        check(pureMerge.snapshot.reviewAttempts.first?.completionEventID == localEvent.id,
              "导入作答指向保留的完成依据")
        check(pureMerge.snapshot.reviewAttempts.first?.priorReviewTask == nil,
              "共有任务的导入作答不会携带可误恢复本机调度的旧快照")
        let repeated = try SnapshotMergeService.merge(local: pureMerge.snapshot, incoming: source)
        check(!repeated.report.didChange, "同一快照重复合并不新增记录或状态")

        try SnapshotFileStore(location: sourceLocation).save(source)
        try SnapshotFileStore(location: targetLocation).save(target)
        let sourceStore = AppStore(environment: StudyRuntimeEnvironment(isTestMode: true,
            allowsSystemNotifications: false, storeLocation: sourceLocation,
            storeLocationOrigin: "merge-import-source"), keychainStore: MergeKeychain())
        let targetStore = AppStore(environment: StudyRuntimeEnvironment(isTestMode: true,
            allowsSystemNotifications: false, storeLocation: targetLocation,
            storeLocationOrigin: "merge-import-target"), keychainStore: MergeKeychain())
        let backupURL = targetLocation.directory.appendingPathComponent("transfer.json")
        try sourceStore.makeBackupDocument().data.write(to: backupURL)
        targetStore.importBackup(url: backupURL, mode: .merge)
        for _ in 0..<200 where targetStore.snapshot.documents.count < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        check(targetStore.snapshot.documents.count == 3, "手动合并入口追加另一端独有资料")
        check(targetStore.snapshot.documents.first?.content == "本机修订", "写盘后的共有资料仍保留本机版本")
        check(targetStore.snapshot.settings.allowModelRequests == false, "合并不覆盖本机 AI 设置")
        check(targetStore.snapshot.reviewAttempts.count == 1
              && targetStore.snapshot.reviewAttempts[0].completionEventID == localEvent.id,
              "写盘后的作答与去重完成事件一致")
        check(!(await targetStore.revokeReviewAttempt(remoteAttempt.id)),
              "共有任务的导入作答拒绝不安全的本机撤销")
        check(try Data(contentsOf: targetAttachments.appendingPathComponent(localDocument.originalPDFFileName!)) == localAttachment,
              "合并保留本机 PDF 附件")
        if let importedName = targetStore.snapshot.documents.first(where: { $0.id == remoteDocument.id })?.originalPDFFileName {
            check(try Data(contentsOf: targetAttachments.appendingPathComponent(importedName)) == remoteAttachment,
                  "合并恢复另一端 PDF 附件")
        } else { check(false, "合并恢复另一端 PDF 附件") }
        let persisted = try SnapshotFileStore(location: targetLocation).load()
        check(persisted?.documents.count == 3 && persisted?.reviewAttempts.count == 1,
              "合并业务结果已写入隔离快照")

        targetStore.importBackup(url: backupURL, mode: .merge)
        for _ in 0..<100 where !targetStore.statusMessage.contains("未新增记录") {
            try await Task.sleep(for: .milliseconds(20))
        }
        check(targetStore.statusMessage.contains("未新增记录"), "重复导入明确告知没有新增记录")
        check(targetStore.snapshot.documents.count == 3 && targetStore.snapshot.completionEvents.count == 1,
              "重复导入不会重复资料或完成依据")
        check(try SnapshotFileStore(location: targetLocation).load()?.documents.count == 3,
              "重复导入后落盘数据仍只有一份")

        var revokedSource = source
        revokedSource.completionEvents[0] = remoteEvent.revoked(at: now.addingTimeInterval(60), reason: "另一端撤销")
        revokedSource.reviewAttempts[0].revokedAt = now.addingTimeInterval(60)
        let withRevocation = try SnapshotMergeService.merge(local: pureMerge.snapshot, incoming: revokedSource)
        check(!withRevocation.snapshot.completionEvents[0].isRevoked,
              "另一端独立完成事件撤销不会抹掉本机同日完成")
        check(withRevocation.snapshot.reviewAttempts[0].isActive == false,
              "另一端撤销同一作答时保留撤销状态")

        var sharedEventSource = source
        sharedEventSource.completionEvents = [localEvent.revoked(at: now.addingTimeInterval(60), reason: "同一事件撤销")]
        let sameEventRevocation = try SnapshotMergeService.merge(local: target, incoming: sharedEventSource)
        check(sameEventRevocation.snapshot.completionEvents[0].isRevoked,
              "真正相同 ID 的完成事件撤销会同步")
    }
}
