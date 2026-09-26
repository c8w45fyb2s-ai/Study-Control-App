import Foundation

@MainActor
private final class RecallKeychain: AIKeychainStoring {
    func loadAPIKey(for configuration: AIConnectionConfiguration, allowLegacyFallback: Bool) -> String { "" }
    func credentialState(for configuration: AIConnectionConfiguration) throws -> AIKeychainCredentialState {
        AIKeychainCredentialState(apiKey: nil, migrationMarker: nil)
    }
    func saveAPIKey(_ value: String, for configuration: AIConnectionConfiguration) throws {}
    func restoreCredentialState(_ state: AIKeychainCredentialState, for configuration: AIConnectionConfiguration) throws {}
    func hasScopedCredential(for configuration: AIConnectionConfiguration) -> Bool { false }
}

@main
struct ActiveRecallVerify {
    static func check(_ condition: Bool, _ message: String) {
        if condition { print("PASS \(message)") }
        else { fatalError("FAIL \(message)") }
    }

    static func verifyCardSourceMapping() {
        let documentID = UUID()
        var point = KnowledgePoint(title: " 定理 ", subject: "数学", summary: " 标准答案 ", mastery: 0)
        point.sourceDocumentID = documentID
        let task = ReviewTask(title: "复述定理", dueDate: Date(), knowledgePointID: point.id)
        var snapshot = StoreSnapshot()
        snapshot.knowledgePoints = [point]
        snapshot.reviewTasks = [task]
        let direct = ActiveRecallLibrary.makeCard(knowledgePoint: point)
        guard let (updated, fromTask) = ActiveRecallLibrary.creatingCard(for: task, in: snapshot) else {
            fatalError("旧知识点不能创建复习卡片")
        }
        check(direct?.sourceDocumentID == documentID && fromTask.sourceDocumentID == documentID,
              "旧知识点无页码引用时，两条制卡入口均保留原文档来源")
        check(direct?.answer == "标准答案" && fromTask.answer == "标准答案",
              "制卡入口统一清理答案首尾空白")
        check(updated.reviewTasks.count == 1 && updated.reviewTasks[0].id == task.id
              && updated.reviewTasks[0].cardID == fromTask.id && updated.reviewTasks[0].dueDate == task.dueDate,
              "从复习任务制卡复用原任务并保留调度时间")
        check(ActiveRecallLibrary.card(for: updated.reviewTasks[0], in: updated)?.id == fromTask.id,
              "已绑定卡片可直接复用")
        let earlierTask = ReviewTask(title: "同一知识点的另一项任务", dueDate: Date(), knowledgePointID: point.id)
        snapshot.reviewTasks.insert(earlierTask, at: 0)
        let explicitlyLinked = ActiveRecallLibrary.creatingCard(for: task, in: snapshot)
        check(explicitlyLinked?.0.reviewTasks[0].cardID == nil
              && explicitlyLinked?.0.reviewTasks[1].cardID == explicitlyLinked?.1.id,
              "制卡绑定明确选中的任务，不被更早的同知识点任务抢占")

        let mistakeDocumentID = UUID()
        var mistake = Mistake(question: "错题", correctAnswer: "错题答案", errorReason: "错因",
                              sourceDocumentID: mistakeDocumentID)
        mistake.sourceReference = SourceReference(documentID: mistakeDocumentID,
            chunkID: "mistake-chunk", pageNumber: 2, excerpt: "错题原文")
        let mistakeCard = ActiveRecallLibrary.makeCard(mistake: mistake, knowledgePoint: point, task: task)
        check(mistakeCard?.answer == "错题答案" && mistakeCard?.sourceDocumentID == mistakeDocumentID
              && mistakeCard?.sourceReference?.pageNumber == 2,
              "错题与知识点同时关联时保留错题答案及其来源")
        point.summary = " \n "
        snapshot.knowledgePoints = [point]
        check(ActiveRecallLibrary.makeCard(knowledgePoint: point) == nil
              && ActiveRecallLibrary.creatingCard(for: task, in: snapshot) == nil,
              "所有制卡入口拒绝仅包含空白的答案")
    }

    @MainActor
    static func main() async throws {
        verifyCardSourceMapping()
        let location = SnapshotStoreLocation.isolatedTemporary(prefix: "ActiveRecallVerify")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let file = try SnapshotFileStore(location: location)
        let mistake = Mistake(question: "合成题", correctAnswer: "合成答案", errorReason: "合成错因")
        var fixture = StoreSnapshot()
        fixture.mistakes = [mistake]
        let existingTask = ReviewTask(title: "重做错题：合成题", dueDate: Date(), mistakeID: mistake.id)
        fixture.reviewTasks = [existingTask]
        try file.save(fixture)
        let environment = StudyRuntimeEnvironment(isTestMode: true, allowsSystemNotifications: false,
            storeLocation: location, storeLocationOrigin: "active-recall-verify")
        let store = AppStore(environment: environment, keychainStore: RecallKeychain())
        store.completeMistake(mistake)
        check(store.snapshot.mistakes.first?.practiceState == .needsRetry, "订正保留原题且不写成功评分")
        check(store.snapshot.completionEvents.isEmpty, "订正不产生完成奖励依据")
        store.setMistakeArchived(mistake, archived: true)
        check(store.snapshot.mistakes.first?.practiceState == .mastered
              && store.snapshot.mistakes.first?.stateChangeSource == "用户手动归档",
              "人工归档保留原题并记录操作来源")
        store.setMistakeArchived(mistake, archived: false)
        check(store.snapshot.mistakes.first?.practiceState == .needsRetry
              && store.snapshot.mistakes.first?.stateChangeSource == "用户恢复",
              "人工恢复保留原题并记录操作来源")
        check(try file.load()?.mistakes.first?.practiceState == .needsRetry,
              "人工恢复后的错题状态已落盘")
        guard let card = store.createCard(from: mistake),
              let task = store.snapshot.reviewTasks.first(where: { $0.cardID == card.id }) else {
            fatalError("未能建立隔离测试卡片")
        }
        check(store.snapshot.reviewTasks.count == 1 && task.id == existingTask.id,
              "制卡复用既有错题复习任务")
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        func attempt(_ id: UUID = UUID(), at date: Date, quality: Int) -> ReviewAttempt {
            ReviewAttempt(id: id, cardID: card.id, contentVersion: card.contentVersion,
                reviewTaskID: nil, startedAt: date.addingTimeInterval(-30), submittedAt: date,
                answer: "合成回答", quality: quality, revealedAnswer: true, durationSeconds: 30,
                revokedAt: nil, revocationReason: nil, completionEventID: nil, priorReviewTask: nil)
        }
        let first = attempt(at: day1, quality: 4)
        check(await store.submitReviewAttempt(first, now: day1), "第一次应用内作答保存")
        let firstTask = store.snapshot.reviewTasks.first { $0.id == task.id }!
        check(!(await store.submitReviewAttempt(first, now: day1)), "同一提交 ID 重试被拒绝")
        let second = attempt(at: day1.addingTimeInterval(300), quality: 4)
        check(await store.submitReviewAttempt(second, now: second.submittedAt), "同日独立第二次作答保存")
        check(store.snapshot.reviewAttempts.count == 2, "同日保留两条独立作答")
        check(store.snapshot.completionEvents.filter { !$0.isRevoked }.count == 1, "同日只形成一个计划完成依据")
        check(store.snapshot.reviewTasks.first { $0.id == task.id }!.repetitionCount > firstTask.repetitionCount,
              "第二次作答仍推进记忆状态")
        check(store.snapshot.mistakes.first?.practiceState == .reviewing, "同日两次答对不归档")
        check(await store.revokeReviewAttempt(second.id, now: second.submittedAt.addingTimeInterval(60)), "撤销最新作答")
        check(store.snapshot.reviewTasks.first { $0.id == task.id }!.repetitionCount == firstTask.repetitionCount,
              "撤销恢复之前的调度状态")
        check(store.snapshot.reviewAttempts.filter(\.isActive).count == 1, "撤销保留审计记录")
        let day2 = day1.addingTimeInterval(86_400)
        let third = attempt(at: day2, quality: 4)
        check(await store.submitReviewAttempt(third, now: day2), "第二天可再次作答")
        check(store.snapshot.mistakes.first?.practiceState == .mastered, "跨两天成功回忆后归档")
        check(store.snapshot.mistakes.count == 1, "归档仍可检索原题")
        check(try file.load()?.reviewAttempts.count == 3, "快照回读保留作答历史")
        let privateBackup = SnapshotPrivacyRedactor.redact(store.snapshot).snapshot
        check(privateBackup.studyCards.first?.answer == SnapshotPrivacyRedactor.placeholder,
              "隐私备份遮盖卡片答案")
        check(privateBackup.reviewAttempts.first?.answer == SnapshotPrivacyRedactor.placeholder,
              "隐私备份遮盖用户作答")
        let day3 = day2.addingTimeInterval(86_400)
        let failed = attempt(at: day3, quality: 1)
        check(await store.submitReviewAttempt(failed, now: day3), "归档后可再次重做")
        check(store.snapshot.mistakes.first?.practiceState == .needsRetry, "再次答错回到待重做")
        check(await store.revokeReviewAttempt(failed.id, now: day3.addingTimeInterval(60)), "可撤销答错记录")
        check(store.snapshot.mistakes.first?.practiceState == .mastered, "撤销答错后恢复归档")
        check(await store.revokeReviewAttempt(third.id, now: day2.addingTimeInterval(60)), "撤销第二天作答")
        check(store.snapshot.mistakes.first?.practiceState == .reviewing, "撤销后撤回归档状态")
        check(await store.revokeReviewAttempt(first.id, now: day2.addingTimeInterval(120)), "撤销首日作答")
        check(store.snapshot.reviewTasks.first { $0.id == task.id }!.lastQuality == nil,
              "撤销首日作答后恢复最初调度")
        check(store.snapshot.completionEvents.allSatisfy(\.isRevoked), "作答撤销联动撤销完成依据")
        check(store.snapshot.dailyActivityRecords.isEmpty, "撤销作答同时撤回该次打卡计数")

        let sourceLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "DocumentBackupSource")
        let targetLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "DocumentBackupTarget")
        defer {
            try? FileManager.default.removeItem(at: sourceLocation.directory)
            try? FileManager.default.removeItem(at: targetLocation.directory)
        }
        let pdfDocument = StudyDocument(title: "隔离附件", sourceName: "fixture.pdf", kind: .note, content: "教材文本")
        let pdfName = "\(pdfDocument.id.uuidString).pdf"
        let pdfBytes = Data("%PDF-1.4 synthetic fixture".utf8)
        let sourceAttachmentDirectory = sourceLocation.directory.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAttachmentDirectory, withIntermediateDirectories: true)
        try pdfBytes.write(to: sourceAttachmentDirectory.appendingPathComponent(pdfName))
        var sourceSnapshot = StoreSnapshot()
        var sourcedDocument = pdfDocument
        sourcedDocument.originalPDFFileName = pdfName
        sourceSnapshot.documents = [sourcedDocument]
        try SnapshotFileStore(location: sourceLocation).save(sourceSnapshot)
        let sourceEnvironment = StudyRuntimeEnvironment(isTestMode: true, allowsSystemNotifications: false,
            storeLocation: sourceLocation, storeLocationOrigin: "document-backup-source")
        let sourceStore = AppStore(environment: sourceEnvironment, keychainStore: RecallKeychain())
        let fullBackup = try sourceStore.makeBackupDocument()
        let encoded = try JSONDecoder().decode(StoreSnapshot.self, from: fullBackup.data)
        check(encoded.documents.first?.backupPDFData == pdfBytes, "完整备份嵌入保留的 PDF 附件")
        let privacyBackup = try sourceStore.makePrivacyBackupDocument()
        let privacyEncoded = try JSONDecoder().decode(StoreSnapshot.self, from: privacyBackup.data)
        check(privacyEncoded.documents.first?.backupPDFData == nil && privacyEncoded.documents.first?.originalPDFFileName == nil,
              "隐私备份不带附件和原文件路径")

        let targetAttachmentDirectory = targetLocation.directory.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: targetAttachmentDirectory, withIntermediateDirectories: true)
        let targetPDF = targetAttachmentDirectory.appendingPathComponent(pdfName)
        try Data("stale attachment".utf8).write(to: targetPDF)
        try SnapshotFileStore(location: targetLocation).save(StoreSnapshot())
        let targetEnvironment = StudyRuntimeEnvironment(isTestMode: true, allowsSystemNotifications: false,
            storeLocation: targetLocation, storeLocationOrigin: "document-backup-target")
        let targetStore = AppStore(environment: targetEnvironment, keychainStore: RecallKeychain())
        let backupURL = targetLocation.directory.appendingPathComponent("import.json")
        try fullBackup.data.write(to: backupURL)
        targetStore.importBackup(url: backupURL)
        for _ in 0..<100 where targetStore.snapshot.documents.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restoredName = targetStore.snapshot.documents.first?.originalPDFFileName
        check(restoredName != nil && restoredName != pdfName, "同名旧附件存在时另存恢复附件")
        check(try Data(contentsOf: targetPDF) == Data("stale attachment".utf8), "历史附件仍可供旧快照引用")
        if let restoredName {
            let restoredPDF = targetAttachmentDirectory.appendingPathComponent(restoredName)
            check(try Data(contentsOf: restoredPDF) == pdfBytes, "完整备份恢复正确的 PDF 内容")
        }
    }
}
