import SwiftUI

#if os(macOS)
struct DraftsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedAIPlanDraftID: UUID?

    private var pendingAIPlanDrafts: [AIPlanDraft] {
        store.snapshot.pendingAIPlanDrafts
    }

    private var selectedAIPlanDraft: AIPlanDraft? {
        guard let selectedAIPlanDraftID else { return nil }
        return pendingAIPlanDrafts.first { $0.id == selectedAIPlanDraftID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                StudyPageHeader(
                    title: "待确认",
                    subtitle: "\(store.snapshot.drafts.count + pendingAIPlanDrafts.count) 项等待审核",
                    icon: "checklist.unchecked",
                    compact: true
                )
                .padding(.top, StudyDesign.Spacing.wide)
                .padding(.horizontal, StudyDesign.Spacing.relaxed)
                .padding(.bottom, StudyDesign.Spacing.normal)

                if store.snapshot.drafts.isEmpty && pendingAIPlanDrafts.isEmpty {
                    StudyEmptyState(title: "没有待确认内容", subtitle: "资料分析和 AI 规划会先进入这里，确认后才会写入知识库和复习计划。", icon: "checklist.unchecked", accentIcon: "sparkles", accentTint: StudyDesign.Colors.secondary)
                        .padding(StudyDesign.Spacing.relaxed)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                            if !store.snapshot.drafts.isEmpty {
                                DraftSidebarSection(title: "资料分析草稿", count: store.snapshot.drafts.count) {
                                    ForEach(store.snapshot.drafts) { draft in
                                        DraftSidebarRow(
                                            title: draft.summary,
                                            subtitle: "AI 提取的知识点、错题和复习日期",
                                            caption: draft.createdAt.formatted(date: .abbreviated, time: .shortened),
                                            icon: "doc.text.magnifyingglass",
                                            tint: StudyDesign.Colors.info,
                                            isSelected: store.selectedDraftID == draft.id && selectedAIPlanDraftID == nil
                                        ) {
                                            store.selectedDraftID = draft.id
                                            selectedAIPlanDraftID = nil
                                        }
                                    }
                                }
                            }

                            if !pendingAIPlanDrafts.isEmpty {
                                DraftSidebarSection(title: "待确认 AI 规划", count: pendingAIPlanDrafts.count) {
                                    ForEach(pendingAIPlanDrafts) { draft in
                                        DraftSidebarRow(
                                            title: draft.title,
                                            subtitle: "\(draft.reviewItems.count) 个任务 · \(draft.knowledgePoints.count) 个知识点",
                                            caption: draft.createdAt.formatted(date: .abbreviated, time: .shortened),
                                            icon: "calendar.badge.clock",
                                            tint: StudyDesign.Colors.warning,
                                            isSelected: selectedAIPlanDraftID == draft.id
                                        ) {
                                            selectedAIPlanDraftID = draft.id
                                            store.selectedDraftID = nil
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, StudyDesign.Spacing.normal)
                        .padding(.bottom, StudyDesign.Spacing.wide)
                    }
                }
            }
            .frame(width: 330)
            .background(StudyDesign.Colors.chromeBackground)

            Rectangle()
                .fill(StudyDesign.Colors.accentHairline)
                .frame(width: 1)

            if let selectedAIPlanDraft {
                AIPlanDraftStandaloneDetailView(draft: selectedAIPlanDraft)
            } else {
                DraftDetailView(draft: store.selectedDraft)
            }
        }
        .onAppear {
            if store.selectedDraft == nil {
                selectedAIPlanDraftID = pendingAIPlanDrafts.first?.id
            }
        }
    }
}

private struct DraftSidebarSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Spacer()
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(StudyDesign.Colors.inputBackground, in: Capsule())
            }
            .padding(.horizontal, StudyDesign.Spacing.compact)

            VStack(spacing: StudyDesign.Spacing.tight) {
                content
            }
        }
        .help("\(title)：\(count) 项")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(count) 项")
    }
}

private struct DraftSidebarRow: View {
    let title: String
    let subtitle: String
    let caption: String
    let icon: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? StudyDesign.Colors.primary : tint)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(StudyDesign.Colors.inputBackground)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(StudyDesign.Spacing.normal)
            .background(isSelected ? StudyDesign.Colors.cardBackground : StudyDesign.Colors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                    .fill(isSelected ? StudyDesign.Colors.primary : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.tight)
            }
            .overlay {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .stroke(isSelected ? StudyDesign.Colors.primary.opacity(0.54) : StudyDesign.Colors.accentHairline, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .help(isSelected ? "当前已选中：\(title)" : "查看：\(title)")
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityHint("打开这份待确认内容")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif

struct DraftDetailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draftPendingDeletion: AnalysisDraft?
    var draft: AnalysisDraft?
    var isEmbeddedInScrollView = false

    var body: some View {
        Group {
            if let draft {
                VStack(spacing: 0) {
                    if isEmbeddedInScrollView {
                        draftContent(draft)
                            .padding(StudyDesign.Spacing.wide)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView {
                            draftContent(draft)
                                .padding(StudyDesign.Spacing.wide)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .studyScrollBottomComfort()
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    bottomActionBar(draft)
                }
                .contextMenu {
                    Button {
                        store.confirmDraft(draft)
                    } label: {
                        Label("确认写入", systemImage: "checkmark.circle")
                    }

                    Button(role: .destructive) {
                        draftPendingDeletion = draft
                    } label: {
                        Label("删除草稿", systemImage: "trash")
                    }
                }
            } else {
                StudyEmptyState(
                    title: "选择一个草稿",
                    subtitle: "确认前可以先检查 AI 的知识点、错因和复习日期。",
                    icon: "doc.text.magnifyingglass",
                    accentIcon: "sparkles",
                    accentTint: StudyDesign.Colors.info
                )
            }
        }
        .alert(
            "删除这份分析草稿？",
            isPresented: Binding(
                get: { draftPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        draftPendingDeletion = nil
                    }
                }
            ),
            presenting: draftPendingDeletion
        ) { draft in
            Button("删除", role: .destructive) {
                store.deleteDraft(draft)
                draftPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                draftPendingDeletion = nil
            }
        } message: { draft in
            Text("将删除“\(draft.summary)”以及这份草稿里的待确认内容。")
        }
    }

    @ViewBuilder
    private func draftContent(_ draft: AnalysisDraft) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            // ── Summary card ──────────────────────────
            summaryCard(draft)

            // ── Sections ──────────────────────────────
            if !draft.knowledgePoints.isEmpty {
                knowledgeSection(draft.knowledgePoints)
            }
            if !draft.mistakes.isEmpty {
                mistakeSection(draft.mistakes)
            }
            if !draft.reviewItems.isEmpty {
                reviewSection(draft.reviewItems)
            }

            if draft.knowledgePoints.isEmpty
                && draft.mistakes.isEmpty
                && draft.reviewItems.isEmpty {
                StudyEmptyState(
                    title: "AI 未识别出条目",
                    subtitle: "尝试换一份资料或手动输入内容后重新分析。",
                    icon: "questionmark.circle",
                    accentIcon: "sparkles",
                    accentTint: StudyDesign.Colors.info
                )
            }
        }
    }

    // MARK: - Summary card

    private func summaryCard(_ draft: AnalysisDraft) -> some View {
        ActionCard(
            title: "AI 分析摘要",
            subtitle: draft.summary,
            icon: "sparkles",
            tint: StudyDesign.Colors.info,
            actionTitle: "确认写入",
            actionHint: "将这份分析草稿写入知识库、错题库和复习计划",
            action: { store.confirmDraft(draft) }
        )
    }

    // MARK: - Knowledge section

    private func knowledgeSection(_ points: [DraftKnowledgePoint]) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Label("知识点 · \(points.count)", systemImage: "lightbulb.fill")
                .font(.headline)

            ForEach(points) { point in
                ListCard {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        HStack(spacing: StudyDesign.Spacing.compact) {
                            Text(point.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(point.subject)
                                .draftMetaPill(tint: StudyDesign.Colors.warning)
                        }
                        Text(point.summary)
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    // MARK: - Mistake section

    private func mistakeSection(_ mistakes: [DraftMistake]) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Label("错题 · \(mistakes.count)", systemImage: "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(StudyDesign.Colors.danger)

            ForEach(mistakes) { mistake in
                ListCard {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        Text(mistake.question)
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: StudyDesign.Spacing.compact) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.success)
                            Text(mistake.correctAnswer)
                                .font(.caption)
                        }
                        HStack(spacing: StudyDesign.Spacing.compact) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.warning)
                            Text(mistake.errorReason)
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Review section

    private func reviewSection(_ items: [DraftReviewItem]) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Label("复习计划 · \(items.count)", systemImage: "calendar.badge.clock")
                .font(.headline)

            ForEach(items) { item in
                ListCard {
                    HStack {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                            if let related = item.relatedKnowledgeTitle {
                                Text(related)
                                    .font(.caption)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            }
                            if let relatedMistake = item.relatedMistakeTitle {
                                Text("错题：\(ReviewPlanner.shortTitle(relatedMistake))")
                                    .font(.caption)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            }
                        }
                        Spacer()
                        Text("\(item.dueInDays) 天后")
                            .draftMetaPill(tint: StudyDesign.Colors.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Bottom bar

    private func bottomActionBar(_ draft: AnalysisDraft) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: StudyDesign.Spacing.normal) {
                Button(role: .destructive) {
                    draftPendingDeletion = draft
                } label: {
                    StudyActionPillLabel(title: "删除", systemImage: "trash")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, minWidth: 86))
                .help("删除这份分析草稿")
                .accessibilityLabel("删除分析草稿")
                .accessibilityHint("删除后这份待确认内容不会写入资料库")

                Button {
                    store.confirmDraft(draft)
                } label: {
                    StudyActionPillLabel(title: "确认写入", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, minWidth: 120))
                .help("确认并写入知识库、错题库和复习计划")
                .accessibilityLabel("确认写入分析草稿")
                .accessibilityHint("将这份草稿里的知识点、错题和复习任务写入应用")
#if os(iOS)
                .sensoryFeedback(.success, trigger: store.snapshot.drafts.count)
#endif
            }
            .padding(.horizontal, StudyDesign.Spacing.wide)
            .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .background(StudyDesign.Colors.chromeBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudyDesign.Colors.accentHairline)
                .frame(height: 1)
        }
    }
}

private extension View {
    func draftMetaPill(tint: Color = StudyDesign.Colors.secondary) -> some View {
        self.studyMetaPill(tint: tint)
    }
}

struct AIPlanDraftStandaloneDetailView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editingPlanDraft: AIPlanDraft?
    @State private var isShowingDismissConfirmation = false
    var draft: AIPlanDraft

    private var sectionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: StudyDesign.Spacing.standard, alignment: .top)]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                    ActionCard(
                        title: draft.title,
                        subtitle: draft.summary,
                        icon: "calendar.badge.plus",
                        tint: StudyDesign.Colors.warning,
                        actionTitle: "编辑规划",
                        actionHint: "打开编辑器检查这份 AI 规划",
                        action: { editingPlanDraft = draft }
                    )

                    if !draft.reviewItems.isEmpty {
                        reviewSection(draft.reviewItems)
                    }
                    if !draft.knowledgePoints.isEmpty {
                        knowledgeSection(draft.knowledgePoints)
                    }
                    if !draft.mistakes.isEmpty {
                        mistakeSection(draft.mistakes)
                    }
                }
                .padding(StudyDesign.Spacing.wide)
                .frame(maxWidth: .infinity, alignment: .leading)
                .studyScrollBottomComfort()
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .contextMenu {
            Button {
                store.requestAIPlanDraftConfirmation(draft)
            } label: {
                Label("确定加入", systemImage: "checkmark.circle")
            }

            Button {
                editingPlanDraft = draft
            } label: {
                Label("编辑规划", systemImage: "slider.horizontal.3")
            }

            Button(role: .destructive) {
                isShowingDismissConfirmation = true
            } label: {
                Label("忽略规划", systemImage: "xmark.circle")
            }
        }
        .confirmationDialog("忽略这份 AI 规划？", isPresented: $isShowingDismissConfirmation, titleVisibility: .visible) {
            Button("忽略规划", role: .destructive) {
                store.dismissAIPlanDraft(draft)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("忽略后，这份规划不会写入复习队列。")
        }
        .sheet(item: $editingPlanDraft) { draft in
            AIPlanDraftEditSheet(
                draft: draft,
                onSave: { updatedDraft in
                    store.updateAIPlanDraft(updatedDraft)
                    editingPlanDraft = nil
                },
                onConfirm: { updatedDraft in
                    if store.updateAIPlanDraft(updatedDraft) {
                        store.requestAIPlanDraftConfirmation(updatedDraft)
                    }
                    editingPlanDraft = nil
                },
                onDismissDraft: { draft in
                    store.dismissAIPlanDraft(draft)
                    editingPlanDraft = nil
                }
            )
        }
    }

    private func reviewSection(_ items: [DraftReviewItem]) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Label("复习任务 · \(items.count)", systemImage: "calendar.badge.clock")
                .font(.headline)

            LazyVGrid(columns: sectionColumns, alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                ForEach(items) { item in
                    ListCard {
                        HStack {
                            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                if let related = item.relatedKnowledgeTitle {
                                    Text(related)
                                        .font(.caption)
                                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                }
                                if let relatedMistake = item.relatedMistakeTitle {
                                    Text("错题：\(ReviewPlanner.shortTitle(relatedMistake))")
                                        .font(.caption)
                                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(item.dueInDays == 0 ? "今天" : "\(item.dueInDays) 天后")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(item.dueInDays == 0 ? StudyDesign.Colors.warning : StudyDesign.Colors.success)
                                if let priority = item.priority {
                                    Text("优先级 \(priority)")
                                        .font(.caption2)
                                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func knowledgeSection(_ points: [DraftKnowledgePoint]) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Label("知识点 · \(points.count)", systemImage: "lightbulb.fill")
                .font(.headline)

            LazyVGrid(columns: sectionColumns, alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                ForEach(points) { point in
                    ListCard {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                            Text(point.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(point.subject) · 掌握度 \(Int(point.mastery * 100))%")
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.success)
                            Text(point.summary)
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                .lineLimit(3)
                        }
                    }
                }
            }
        }
    }

    private func mistakeSection(_ mistakes: [DraftMistake]) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Label("错题/薄弱项 · \(mistakes.count)", systemImage: "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(StudyDesign.Colors.danger)

            LazyVGrid(columns: sectionColumns, alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                ForEach(mistakes) { mistake in
                    ListCard {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                            Text(mistake.question)
                                .font(.subheadline.weight(.semibold))
                            Text("答案：\(mistake.correctAnswer)")
                                .font(.caption)
                            Text("原因：\(mistake.errorReason)")
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }
                    }
                }
            }
        }
    }

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: StudyDesign.Spacing.normal) {
                Button(role: .destructive) {
                    isShowingDismissConfirmation = true
                } label: {
                    StudyActionPillLabel(title: "忽略", systemImage: "trash")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, minWidth: 86))
                .help("忽略这份 AI 规划")
                .accessibilityLabel("忽略 AI 规划")
                .accessibilityHint("忽略后不会写入复习队列")

                Button {
                    editingPlanDraft = draft
                } label: {
                    StudyActionPillLabel(title: "编辑", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.info, prominence: .secondary, minWidth: 86))
                .help("编辑这份 AI 规划")
                .accessibilityLabel("编辑 AI 规划")
                .accessibilityHint("检查标题、任务和关联资料")

                Button {
                    store.requestAIPlanDraftConfirmation(draft)
                } label: {
                    StudyActionPillLabel(title: "确定加入", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, minWidth: 120))
                .help("确定加入复习队列")
                .accessibilityLabel("确定加入 AI 规划")
                .accessibilityHint("把这份规划写入复习任务")
            }
            .padding(.horizontal, StudyDesign.Spacing.wide)
            .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .background(StudyDesign.Colors.chromeBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudyDesign.Colors.accentHairline)
                .frame(height: 1)
        }
    }
}
