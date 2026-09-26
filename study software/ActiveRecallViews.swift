import SwiftUI

/// 两端共用的卡片编辑器。挖空题面由用户写出一个「____」占位，答案另存。
struct StudyCardEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let existing: StudyCard?
    var initialPrompt = ""
    var knowledgePointID: UUID?
    var mistakeID: UUID?
    var sourceDocumentID: UUID?
    var linkedReviewTaskID: UUID?
    @State private var kind: StudyCard.Kind = .questionAnswer
    @State private var prompt = ""
    @State private var answer = ""
    @State private var sourceExcerpt = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("卡片类型", selection: $kind) {
                    ForEach(StudyCard.Kind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                TextField(kind == .cloze ? "题面，留一个 ____" : "问题", text: $prompt, axis: .vertical)
                TextField("标准答案", text: $answer, axis: .vertical)
                TextField("来源摘录（可选）", text: $sourceExcerpt, axis: .vertical)
                if let documentID = existing?.sourceDocumentID ?? sourceDocumentID,
                   let document = store.snapshot.documents.first(where: { $0.id == documentID }) {
                    Text("来源：\(document.title)")
                        .font(.caption)
                }
            }
            .navigationTitle(existing == nil ? "新建卡片" : "编辑卡片")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var card = existing ?? StudyCard(kind: kind, prompt: prompt, answer: answer,
                            knowledgePointID: knowledgePointID, mistakeID: mistakeID,
                            sourceDocumentID: sourceDocumentID)
                        card.kind = kind
                        card.prompt = prompt
                        card.answer = answer
                        card.sourceExcerpt = sourceExcerpt.isEmpty ? nil : sourceExcerpt
                        if store.saveStudyCard(card, linkedReviewTaskID: linkedReviewTaskID) { dismiss() }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (kind == .cloze && !prompt.contains("____")))
                }
            }
            .onAppear {
                kind = existing?.kind ?? .questionAnswer
                prompt = existing?.prompt ?? initialPrompt
                answer = existing?.answer ?? ""
                sourceExcerpt = existing?.sourceExcerpt ?? ""
            }
        }
    }
}

struct ActiveRecallView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let initialCardID: UUID
    @State private var cardID: UUID?
    @State private var answer = ""
    @State private var revealed = false
    @State private var startedAt = Date()
    @State private var submissionID = UUID()
    @State private var isSaving = false
    @State private var savedAttemptID: UUID?
    @State private var showEditor = false
    @State private var sourceReference: SourceReference?

    private var card: StudyCard? {
        store.snapshot.studyCards.first { $0.id == (cardID ?? initialCardID) }
    }

    private var activeAttempts: [ReviewAttempt] {
        guard let card else { return [] }
        return store.snapshot.reviewAttempts.filter { $0.cardID == card.id && $0.isActive }
            .sorted { $0.submittedAt > $1.submittedAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let card {
                        Text(card.kind.label).font(.caption).foregroundStyle(.secondary)
                        Text(card.prompt).font(.title3.weight(.semibold))
                            .accessibilityLabel("题面：\(card.prompt)")
                        if !revealed {
                            TextField("先回忆，再输入答案（可留空）", text: $answer, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                            Button("揭示答案") { revealed = true }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Divider()
                            Text("标准答案").font(.headline)
                            Text(card.answer)
                            if let excerpt = card.sourceExcerpt, !excerpt.isEmpty {
                                Text("来源摘录：\(excerpt)").font(.caption)
                            }
                            if let documentID = card.sourceReference?.documentID ?? card.sourceDocumentID,
                               let document = store.snapshot.documents.first(where: { $0.id == documentID }) {
                                Button("查看原始资料：\(document.title)") {
                                    sourceReference = card.sourceReference ?? SourceReference(
                                        documentID: documentID, chunkID: nil, pageNumber: nil, excerpt: "")
                                }
                            }
                            if savedAttemptID == nil {
                                Text("根据回忆质量自评")
                                    .font(.headline)
                                ForEach(ReviewPlanner.Quality.allCases) { quality in
                                    Button("\(quality.rawValue) · \(quality.label)") {
                                        save(quality, card: card)
                                    }
                                    .disabled(isSaving)
                                }
                            } else {
                                Button("下一题") { advance() }
                                    .buttonStyle(.borderedProminent)
                                Button("撤销本次作答") {
                                    guard let savedAttemptID else { return }
                                    Task {
                                        if await store.revokeReviewAttempt(savedAttemptID) {
                                            self.savedAttemptID = nil
                                            self.revealed = false
                                            self.submissionID = UUID()
                                            self.startedAt = Date()
                                        }
                                    }
                                }
                            }
                        }
                        if !activeAttempts.isEmpty {
                            Divider()
                            Text("最近作答").font(.headline)
                            ForEach(activeAttempts.prefix(5)) { attempt in
                                Text("\(attempt.submittedAt.formatted()) · \(ReviewPlanner.Quality(rawValue: attempt.quality)?.label ?? "未评分")")
                                    .font(.caption)
                            }
                        }
                    } else {
                        Text("卡片不存在或已删除")
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding()
            }
            .navigationTitle("应用内作答")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                if card != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("编辑卡片") { showEditor = true }
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                StudyCardEditor(existing: card)
                    .environmentObject(store)
            }
            .sheet(isPresented: Binding(get: { sourceReference != nil }, set: { if !$0 { sourceReference = nil } })) {
                if let sourceReference {
                    SourceLocationView(reference: sourceReference).environmentObject(store)
                }
            }
            .onAppear { cardID = initialCardID; startedAt = Date() }
            .onChange(of: card?.contentVersion) { oldVersion, newVersion in
                guard oldVersion != nil, oldVersion != newVersion, savedAttemptID == nil else { return }
                answer = ""
                revealed = false
                submissionID = UUID()
                startedAt = Date()
            }
        }
    }

    private func save(_ quality: ReviewPlanner.Quality, card: StudyCard) {
        guard !isSaving, savedAttemptID == nil else { return }
        isSaving = true
        let now = Date()
        let attempt = ReviewAttempt(id: submissionID, cardID: card.id,
            contentVersion: card.contentVersion, reviewTaskID: nil,
            startedAt: startedAt, submittedAt: now,
            answer: answer.isEmpty ? nil : answer, quality: quality.rawValue,
            revealedAnswer: revealed,
            durationSeconds: max(0, Int(now.timeIntervalSince(startedAt))),
            revokedAt: nil, revocationReason: nil, completionEventID: nil, priorReviewTask: nil)
        Task {
            if await store.submitReviewAttempt(attempt, now: now) { savedAttemptID = submissionID }
            isSaving = false
        }
    }

    private func advance() {
        let other = store.snapshot.reviewTasks
            .filter { $0.status == .pending && $0.cardID != cardID && $0.dueDate <= Date() }
            .sorted { $0.dueDate < $1.dueDate }
            .compactMap(\.cardID)
            .first
        guard let other else { dismiss(); return }
        cardID = other
        answer = ""
        revealed = false
        savedAttemptID = nil
        submissionID = UUID()
        startedAt = Date()
    }
}
