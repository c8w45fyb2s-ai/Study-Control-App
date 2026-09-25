import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
private enum IOSImportSection: String, CaseIterable, Identifiable {
    case importing = "导入"
    case library = "资料库"
    case drafts = "待确认"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .importing:
            return "square.and.arrow.down"
        case .library:
            return "tray.full.fill"
        case .drafts:
            return "checklist.unchecked"
        }
    }
}

private struct IOSImportNextStep {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let actionTitle: String?
    let action: (() -> Void)?
}
#endif

private extension DocumentKind {
    var libraryTint: Color {
        switch self {
        case .note:
            return StudyDesign.Colors.info
        case .mistake:
            return StudyDesign.Colors.danger
        case .mixed:
            return StudyDesign.Colors.primary
        }
    }

    var libraryIcon: String {
        switch self {
        case .note:
            return "doc.text.fill"
        case .mistake:
            return "xmark.circle.fill"
        case .mixed:
            return "sparkles"
        }
    }

    var libraryShortLabel: String {
        switch self {
        case .note:
            return "笔记"
        case .mistake:
            return "错题"
        case .mixed:
            return "综合"
        }
    }
}

private enum ManualInputFocusField: Hashable {
    case title
    case content
}

private extension View {
    func importMetaPill(tint: Color = StudyDesign.Colors.secondary) -> some View {
        self.studyMetaPill(tint: tint)
    }
}

struct ImportView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showImporter = false
    @SceneStorage("import.draft.pendingURL") private var pendingImportURL: URL?
    @SceneStorage("import.draft.kind") private var importKind: DocumentKind = .mixed
    @SceneStorage("import.draft.manualTitle") private var manualTitle = ""
    @SceneStorage("import.draft.manualContent") private var manualContent = ""
    @SceneStorage("import.draft.manualExpanded") private var isManualInputExpanded = false
    @State private var isDropTargeted = false
    @State private var selectedDocumentIDs: Set<UUID> = []
    @State private var documentPendingDeletion: StudyDocument?
    @FocusState private var manualInputFocus: ManualInputFocusField?
#if os(iOS)
    @State private var selectedImportSection: IOSImportSection = .importing
    @Namespace private var importSectionNamespace
#endif

    private var supportedImportTypes: [UTType] {
        DocumentProcessor.supportedImportTypes
    }

    private var importedDocuments: [StudyDocument] {
        store.snapshot.documents
    }

    private var selectedDocuments: [StudyDocument] {
        importedDocuments.filter { selectedDocumentIDs.contains($0.id) }
    }

    private var isAllImportedDocumentsSelected: Bool {
        !importedDocuments.isEmpty && selectedDocuments.count == importedDocuments.count
    }

    private var currentImportStep: ImportStep {
        if store.isBusy {
            return .analyze
        }
        if pendingImportURL != nil {
            return .confirm
        }
        if !store.snapshot.drafts.isEmpty || !store.snapshot.pendingAIPlanDrafts.isEmpty {
            return .review
        }
        return .choose
    }

    private var trimmedManualContent: String {
        manualContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedManualTitle: String {
        let title = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "手动输入资料" : title
    }

    private var canSaveManualDocument: Bool {
        !trimmedManualContent.isEmpty && !store.isBusy
    }

    private var manualInputValidationMessage: String? {
        if store.isBusy {
            return "当前正在处理资料，完成后再保存新的手动输入。"
        }
        if trimmedManualContent.isEmpty {
            return "请输入正文后再保存或分析。"
        }
        return nil
    }

    private var fileImportHelp: String {
        if store.isBusy {
            return "当前正在处理资料，完成后再选择新的文件。"
        }
        return "打开文件浏览器，选择 PDF、图片、文本或 Office 文件导入"
    }

    var body: some View {
        platformBody
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: supportedImportTypes,
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    pendingImportURL = url
                    store.statusMessage = "已选择文件：\(url.lastPathComponent)，请确认资料类型后分析"
                } else if case .failure(let error) = result {
                    store.statusMessage = "选择文件失败：\(error.localizedDescription)"
                }
            }
            .alert(
                "删除这份资料？",
                isPresented: Binding(
                    get: { documentPendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented {
                            documentPendingDeletion = nil
                        }
                    }
                ),
                presenting: documentPendingDeletion
            ) { document in
                Button("删除", role: .destructive) {
                    deleteImportedDocument(document)
                    documentPendingDeletion = nil
                }
                Button("取消", role: .cancel) {
                    documentPendingDeletion = nil
                }
            } message: { document in
                Text("将删除“\(document.title)”以及它关联的待确认草稿、错题和复习任务。")
            }
    }

    @ViewBuilder
    private var platformBody: some View {
#if os(macOS)
        if importedDocuments.isEmpty {
            ScrollView {
                importControls
                    .padding(StudyDesign.Spacing.wide)
                    .frame(maxWidth: 680, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            HSplitView {
                ScrollView {
                    importControls
                        .padding(StudyDesign.Spacing.wide)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 300, idealWidth: 420)

                DocumentLibraryView()
            }
            .frame(minWidth: 640, minHeight: 520)
        }
#else
        ScrollView {
            iosImportContent
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studyScrollBottomComfort()
        }
        .safeAreaInset(edge: .bottom) {
            if shouldShowIOSLibraryBulkBar {
                iosLibraryBulkActionBar
                    .padding(.horizontal, StudyDesign.Spacing.wide)
                    .padding(.bottom, StudyDesign.Spacing.tight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle("导入资料")
        .navigationBarTitleDisplayMode(.inline)
        .dismissKeyboardOnTapOutside()
        .scrollDismissesKeyboard(.interactively)
#endif
    }

#if os(iOS)
    private var iosImportContent: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            IOSImportSectionSwitcher(selection: $selectedImportSection, namespace: importSectionNamespace)

            if shouldShowImportStatusBanner {
                importStatusBanner
            }

            if let nextStep = iosImportNextStep {
                IOSImportNextStepCard(step: nextStep)
            }

            Group {
                switch selectedImportSection {
                case .importing:
                    iosImportWorkspace
                case .library:
                    iosDocumentLibrarySection
                case .drafts:
                    iosDraftsSection
                }
            }
            .animation(StudyDesign.Motion.animation(.normal), value: selectedImportSection)

            if store.isBusy || pendingImportURL != nil {
                ImportProcessView(currentStep: currentImportStep)
            }
        }
    }

    private var iosImportNextStep: IOSImportNextStep? {
        if store.isBusy {
            return IOSImportNextStep(
                title: "正在分析资料",
                subtitle: "处理完成后，结果会进入待确认。当前请求可在状态栏取消。",
                icon: "sparkles",
                tint: StudyDesign.Colors.info,
                actionTitle: nil,
                action: nil
            )
        }

        if pendingImportURL != nil {
            return IOSImportNextStep(
                title: "确认资料类型后开始分析",
                subtitle: "选择笔记、错题或综合资料，AI 会按类型整理结果。",
                icon: "doc.badge.gearshape",
                tint: StudyDesign.Colors.warning,
                actionTitle: selectedImportSection == .importing ? nil : "去确认",
                action: {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        selectedImportSection = .importing
                    }
                }
            )
        }

        let draftCount = store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count
        if draftCount > 0 {
            return IOSImportNextStep(
                title: "\(draftCount) 个结果待确认",
                subtitle: "确认后才会写入知识点、错题和复习计划。",
                icon: "checklist.unchecked",
                tint: StudyDesign.Colors.secondary,
                actionTitle: selectedImportSection == .drafts ? nil : "去确认",
                action: {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        selectedImportSection = .drafts
                    }
                }
            )
        }

        if !importedDocuments.isEmpty {
            return IOSImportNextStep(
                title: "资料库已有 \(importedDocuments.count) 份资料",
                subtitle: "可以批量选择资料再次分析，或继续导入新内容。",
                icon: "tray.full.fill",
                tint: StudyDesign.Colors.info,
                actionTitle: selectedImportSection == .library ? nil : "看资料库",
                action: {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        selectedImportSection = .library
                    }
                }
            )
        }

        return nil
    }

    private var shouldShowImportStatusBanner: Bool {
        if store.isBusy { return true }
        let message = store.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return !message.isEmpty && message != "准备就绪"
    }

    private var shouldShowIOSLibraryBulkBar: Bool {
        selectedImportSection == .library && !selectedDocuments.isEmpty
    }

    private var iosImportWorkspace: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            dropZone

            if let pendingImportURL {
                FileImportReviewCard(
                    url: pendingImportURL,
                    importKind: $importKind,
                    isBusy: store.isBusy,
                    onAnalyze: analyzePendingFile,
                    onCancel: {
                        self.pendingImportURL = nil
                        store.statusMessage = "已取消本次文件导入"
                    }
                )
            }

            manualInputCard
        }
    }

    private var iosDocumentLibrarySection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Label("资料库", systemImage: "tray.full.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text(importedDocuments.isEmpty ? "导入后的文件和手动资料会显示在这里。" : "选择多份资料后可以批量分析。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }

                if !importedDocuments.isEmpty {
                    HStack(spacing: StudyDesign.Spacing.tight) {
                        Button {
                            toggleAllImportedDocuments()
                        } label: {
                            StudyActionPillLabel(
                                title: isAllImportedDocumentsSelected ? "清空选择" : "全选资料",
                                systemImage: isAllImportedDocumentsSelected ? "xmark.circle" : "checkmark.circle"
                            )
                        }
                        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .secondary, size: .compact, minWidth: 96))
                        .disabled(store.isBusy)
                        .help(store.isBusy ? "当前正在处理资料，完成后再选择资料。" : "选择或清空全部资料")
                        .accessibilityLabel(isAllImportedDocumentsSelected ? "清空资料选择" : "全选资料")
                        .accessibilityHint(store.isBusy ? "当前正在处理资料，完成后再选择资料。" : "选择或清空全部资料")

                        Spacer()

                        Text("\(importedDocuments.count) 份资料")
                            .importMetaPill(tint: StudyDesign.Colors.secondary)
                    }
                }
            }
            .padding(StudyDesign.Spacing.normal)
            .background(StudyDesign.Colors.elevatedBackground)
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                    .stroke(StudyDesign.Colors.accentHairline.opacity(0.70), lineWidth: 1)
            )

            if !importedDocuments.isEmpty {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    Label("已选 \(selectedDocuments.count) / \(importedDocuments.count)", systemImage: "checklist")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .padding(.horizontal, StudyDesign.Spacing.normal)
                .padding(.vertical, StudyDesign.Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
                )
                .help("已选 \(selectedDocuments.count) / \(importedDocuments.count) 份资料")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("资料选择状态，已选 \(selectedDocuments.count) / \(importedDocuments.count) 份资料")
            }

            if importedDocuments.isEmpty {
                StudyEmptyState(title: "资料库为空", subtitle: "选择文件或手动保存资料后，导入内容会显示在这里。", icon: "tray.fill", accentIcon: "doc.badge.plus", accentTint: StudyDesign.Colors.secondary)
            } else {
                VStack(spacing: StudyDesign.Spacing.standard) {
                    ForEach(importedDocuments) { document in
                        ImportedDocumentRow(
                            document: document,
                            isSelected: selectedDocumentIDs.contains(document.id),
                            onToggleSelection: {
                                toggleSelection(for: document)
                            },
                            onDelete: {
                                documentPendingDeletion = document
                            }
                        )
                    }
                }
            }
        }
        .animation(StudyDesign.Motion.animation(.normal), value: selectedDocumentIDs)
    }

    private var iosLibraryBulkActionBar: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedDocuments.count) 份资料")
                    .font(.subheadline.weight(.semibold))
                Text("将批量生成待确认结果")
                    .font(.caption2)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            Button {
                store.analyzeDocuments(selectedDocuments)
                selectedDocumentIDs.removeAll()
            } label: {
                StudyActionPillLabel(title: "批量分析", systemImage: "sparkles")
            }
            .buttonStyle(StudyActionPillButtonStyle(minWidth: 108))
            .disabled(store.isBusy)
            .help(store.isBusy ? "当前正在处理资料，完成后再批量分析。" : "分析已选择的资料")
            .accessibilityLabel("批量分析已选择资料")
            .accessibilityHint(store.isBusy ? "当前正在处理资料，完成后再批量分析。" : "分析已选择的资料")
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Gradients.panelSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.large)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.78), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.elevated.color, radius: StudyDesign.Shadow.elevated.radius, y: StudyDesign.Shadow.elevated.y)
        .help("已选 \(selectedDocuments.count) 份资料")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("批量分析栏，已选 \(selectedDocuments.count) 份资料")
    }

    private var iosDraftsSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Label("待确认", systemImage: "checklist.unchecked")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text("确认后才会写入知识点、错题和复习计划。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }

                Spacer()

                let totalCount = store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count
                Text("\(totalCount)")
                    .importMetaPill()
            }

            if store.snapshot.drafts.isEmpty && store.snapshot.pendingAIPlanDrafts.isEmpty {
                StudyEmptyState(title: "没有待确认内容", subtitle: "文件分析完成后，结果会先显示在这里。", icon: "checklist.unchecked", accentIcon: "sparkles", accentTint: StudyDesign.Colors.secondary)
            } else {
                VStack(spacing: StudyDesign.Spacing.standard) {
                    ForEach(store.snapshot.drafts) { draft in
                        AnalysisDraftPreviewCard(draft: draft)
                    }

                    ForEach(store.snapshot.pendingAIPlanDrafts) { draft in
                        AIPlanDraftPreviewCard(draft: draft)
                    }
                }
            }
        }
    }

    private var importStatusBanner: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(StudyDesign.Colors.info)
            }

            Text(store.statusMessage.isEmpty ? "正在处理资料..." : store.statusMessage)
                .font(.footnote)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if store.isBusy {
                Button {
                    store.cancelAIRequest()
                } label: {
                    StudyActionPillLabel(title: "取消", systemImage: "xmark")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact, minWidth: 74))
                .help("取消当前 AI 请求")
                .accessibilityLabel("取消当前 AI 请求")
                .accessibilityHint("停止当前资料处理")
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.62), lineWidth: 1)
        )
        .help(store.statusMessage.isEmpty ? "正在处理资料" : store.statusMessage)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.isBusy ? "资料处理中" : "导入状态")
        .accessibilityValue(store.statusMessage.isEmpty ? "正在处理资料" : store.statusMessage)
    }

    private struct IOSImportNextStepCard: View {
        let step: IOSImportNextStep

        var body: some View {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: step.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(step.tint)
                    .frame(width: 38, height: 38)
                    .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                            .stroke(step.tint.opacity(0.16), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text(step.subtitle)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                if let actionTitle = step.actionTitle, let action = step.action {
                    Button(action: action) {
                        StudyActionPillLabel(title: actionTitle, systemImage: "arrow.right")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: step.tint, prominence: .soft, size: .compact, minWidth: 82))
                    .help(actionTitle)
                    .accessibilityLabel(actionTitle)
                }
            }
            .padding(StudyDesign.Spacing.normal)
            .background(StudyDesign.Colors.elevatedBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                    .stroke(StudyDesign.Colors.accentHairline.opacity(0.42), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
        }
    }
#endif

    private func toggleSelection(for document: StudyDocument) {
        if selectedDocumentIDs.contains(document.id) {
            selectedDocumentIDs.remove(document.id)
        } else {
            selectedDocumentIDs.insert(document.id)
        }
    }

    private func toggleAllImportedDocuments() {
        if selectedDocuments.count == importedDocuments.count {
            selectedDocumentIDs.removeAll()
        } else {
            selectedDocumentIDs = Set(importedDocuments.map(\.id))
        }
    }

    private func deleteImportedDocument(_ document: StudyDocument) {
        selectedDocumentIDs.remove(document.id)
        store.deleteDocument(document)
    }

    private func analyzePendingFile() {
        guard let pendingImportURL else {
            store.statusMessage = "请先选择要导入的文件"
            return
        }
        store.importAndAnalyze(url: pendingImportURL, kind: importKind)
        self.pendingImportURL = nil
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            StudyPageHeader(
                title: "导入资料",
                subtitle: importedDocuments.isEmpty ? "先添加第一份资料；导入后会自动展开资料库与预览。" : "添加文件或手动资料，并在分析前确认类型。",
                icon: "square.and.arrow.down.fill"
            )

            ImportProcessView(currentStep: currentImportStep)

            // ── Drop zone ──────────────────────────────────
            dropZone

            if let pendingImportURL {
                FileImportReviewCard(
                    url: pendingImportURL,
                    importKind: $importKind,
                    isBusy: store.isBusy,
                    onAnalyze: analyzePendingFile,
                    onCancel: {
                        self.pendingImportURL = nil
                        store.statusMessage = "已取消本次文件导入"
                    }
                )
            }

            manualInputCard

            Spacer(minLength: 0)
        }
    }

    private var manualInputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                let shouldFocusEditor = !isManualInputExpanded
                withAnimation(StudyDesign.Motion.animation(.normal)) {
                    isManualInputExpanded.toggle()
                }
                if shouldFocusEditor {
                    let targetFocus: ManualInputFocusField = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .title : .content
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                        manualInputFocus = targetFocus
                    }
                } else {
                    manualInputFocus = nil
                }
            } label: {
                HStack(spacing: StudyDesign.Spacing.normal) {
                    Image(systemName: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.info)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                                .fill(StudyDesign.Gradients.semanticWash(StudyDesign.Colors.info).opacity(0.20))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                                .stroke(StudyDesign.Colors.info.opacity(0.18), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                        Text("手动输入资料")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        Text(isManualInputExpanded ? "正在编辑：\(resolvedManualTitle)" : "粘贴错题、笔记或文字资料，保存后可继续分析。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: StudyDesign.Spacing.tight)

                    DocumentKindBadge(kind: importKind)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .rotationEffect(.degrees(isManualInputExpanded ? 180 : 0))
                        .frame(width: 24, height: 24)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isManualInputExpanded ? "收起手动输入资料" : "展开手动输入资料")
            .accessibilityHint(isManualInputExpanded ? "收起后会保留当前输入内容。" : "展开后可选择资料类型、填写标题并粘贴内容。")
            .help(isManualInputExpanded ? "收起手动输入资料" : "展开手动输入资料")

            if isManualInputExpanded {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                    Divider()
                        .padding(.top, StudyDesign.Spacing.normal)

                    HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
                        Label("采集类型", systemImage: "tag.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)

                        Spacer(minLength: StudyDesign.Spacing.tight)
                    }

                    manualKindChips

                    manualTitleField

                    manualTextEditor

                    manualInputFooter
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                        .fill(importKind.libraryTint.opacity(isManualInputExpanded ? 0.07 : 0.035))
                        .frame(width: 150, height: 120)
                }
        )
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(
                    isManualInputExpanded ? importKind.libraryTint.opacity(0.48) : StudyDesign.Colors.accentHairline,
                    lineWidth: 1
                )
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .animation(StudyDesign.Motion.animation(.normal), value: isManualInputExpanded)
        .animation(StudyDesign.Motion.animation(.fast), value: importKind)
    }

    private var manualTitleField: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Label("资料标题", systemImage: "text.cursor")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Text("可选")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .padding(.horizontal, StudyDesign.Spacing.compact)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(
                                        LinearGradient(
                                            colors: [
                                        StudyDesign.Colors.elevatedBackground,
                                        StudyDesign.Colors.dataBackground
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            }

            TextField("不填则保存为“手动输入资料”", text: $manualTitle)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .focused($manualInputFocus, equals: .title)
                .submitLabel(.next)
                .onSubmit {
                    manualInputFocus = .content
                }
                .padding(StudyDesign.Spacing.normal)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                        .fill(StudyDesign.Colors.inputBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                        .stroke(manualInputFocus == .title ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline, lineWidth: manualInputFocus == .title ? 2 : 1)
                )
                .accessibilityLabel("资料标题，可选")
        }
    }

    private var manualKindChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                ForEach(DocumentKind.allCases, id: \.self) { kind in
                    ManualDocumentKindChip(kind: kind, isSelected: importKind == kind) {
                        importKind = kind
                    }
                }
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                ForEach(DocumentKind.allCases, id: \.self) { kind in
                    ManualDocumentKindChip(kind: kind, isSelected: importKind == kind) {
                        importKind = kind
                    }
                }
            }
        }
    }

    private var manualTextEditor: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Label("正文采集区", systemImage: "doc.text.magnifyingglass")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)

                Spacer(minLength: StudyDesign.Spacing.tight)

                Text(manualContent.isEmpty ? "等待输入" : "正在采集")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(manualContent.isEmpty ? StudyDesign.Colors.labelTertiary : importKind.libraryTint)
                    .padding(.horizontal, StudyDesign.Spacing.tight)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        StudyDesign.Colors.cardBackground,
                                        StudyDesign.Colors.inputBackground
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(Capsule().stroke(manualContent.isEmpty ? StudyDesign.Colors.accentHairline : importKind.libraryTint.opacity(0.18), lineWidth: 1))
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $manualContent)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160, idealHeight: 210, maxHeight: 300)
                    .padding(StudyDesign.Spacing.tight)
                    .focused($manualInputFocus, equals: .content)
                    .accessibilityLabel("资料正文")

                if manualContent.isEmpty {
                    Text("粘贴题目、错因、课堂笔记，或者直接写一段需要 AI 整理的资料...")
                        .font(.body)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .padding(.horizontal, StudyDesign.Spacing.normal + StudyDesign.Spacing.tight)
                        .padding(.vertical, StudyDesign.Spacing.normal + StudyDesign.Spacing.compact)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(StudyDesign.Colors.inputBackground)
                    .overlay(
                        LinearGradient(
                            colors: [
                                importKind.libraryTint.opacity(0.05),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .stroke(
                        manualInputFocus == .content ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                        lineWidth: manualInputFocus == .content ? 2 : 1
                    )
            )
            .shadow(color: StudyDesign.Shadow.card.color.opacity(0.68), radius: 5, y: 2)
        }
    }

    private var manualInputFooter: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                ManualInputMetricChip(title: "字数", value: "\(manualContent.count)", icon: "text.alignleft", tint: importKind.libraryTint)
                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            if store.isBusy, let manualInputValidationMessage {
                ManualInputValidationHint(message: manualInputValidationMessage)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    manualSaveButton
                    Spacer(minLength: StudyDesign.Spacing.tight)
                    manualAnalyzeButton
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    manualSaveButton
                    manualAnalyzeButton
                }
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
        )
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        Button {
            showImporter = true
        } label: {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(StudyDesign.Colors.secondary)
                        .frame(width: 48, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                .fill(StudyDesign.Colors.inputBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        Text(pendingImportURL == nil ? dropZoneTitle : "重新选择文件")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        Text("支持 PDF、图片、Word、PPT、文本")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }

                    Spacer(minLength: StudyDesign.Spacing.tight)

                    Image(systemName: "arrow.up.doc.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(StudyDesign.Colors.primary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(StudyDesign.Spacing.normal)
            .background {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(isDropTargeted ? StudyDesign.Colors.inputBackground : StudyDesign.Colors.cardBackground)
            }
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                    .stroke(
                        isDropTargeted ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 5])
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
        .help(fileImportHelp)
        .accessibilityLabel(pendingImportURL == nil ? dropZoneTitle : "重新选择文件")
        .accessibilityHint(fileImportHelp)
#if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            acceptDroppedFiles(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
#endif
        .animation(StudyDesign.Motion.animation(.fast), value: isDropTargeted)
    }

    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard !store.isBusy, let url = urls.first, url.isFileURL else { return false }
        guard let droppedType = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            store.statusMessage = "无法识别这个文件类型"
            return false
        }

        let isSupported = supportedImportTypes.contains { supported in
            droppedType.conforms(to: supported) || supported.conforms(to: droppedType)
        }
        guard isSupported else {
            store.statusMessage = "暂不支持 .\(url.pathExtension.lowercased()) 文件"
            return false
        }

        pendingImportURL = url
        store.statusMessage = "已拖入文件：\(url.lastPathComponent)，请确认资料类型后分析"
        return true
    }

    private var dropZoneTitle: String {
#if os(iOS)
        "选择文件"
#else
        "点击选择文件或拖放到此处"
#endif
    }

    private var manualSaveButton: some View {
        Button {
            store.addManualDocument(title: resolvedManualTitle, content: manualContent, kind: importKind)
            manualTitle = ""
            manualContent = ""
        } label: {
            StudyActionPillLabel(title: "保存资料", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: importKind.libraryTint, prominence: .secondary, minWidth: 104))
        .disabled(!canSaveManualDocument)
        .accessibilityLabel("保存手动输入资料")
        .help(manualInputValidationMessage ?? "保存手动输入资料")
        .accessibilityHint(manualInputValidationMessage ?? "保存手动输入资料")
    }

    private var manualAnalyzeButton: some View {
        Button {
            if let document = store.addManualDocument(title: resolvedManualTitle, content: manualContent, kind: importKind) {
                store.analyzeDocument(document)
            }
            manualTitle = ""
            manualContent = ""
        } label: {
            StudyActionPillLabel(title: "保存并分析", systemImage: "sparkles")
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: importKind.libraryTint, minWidth: 116))
        .disabled(!canSaveManualDocument)
        .accessibilityLabel("保存手动输入资料并开始 AI 分析")
        .help(manualInputValidationMessage ?? "保存手动输入资料并开始 AI 分析")
        .accessibilityHint(manualInputValidationMessage ?? "保存手动输入资料并开始 AI 分析")
    }
}

enum ImportStep: Int, CaseIterable, Identifiable {
    case choose
    case confirm
    case analyze
    case review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .choose: return "选择资料"
        case .confirm: return "确认类型"
        case .analyze: return "分析"
        case .review: return "待确认"
        }
    }

    var icon: String {
        switch self {
        case .choose: return "doc.badge.plus"
        case .confirm: return "checklist"
        case .analyze: return "sparkles"
        case .review: return "checkmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .choose: return StudyDesign.Colors.secondary
        case .confirm: return StudyDesign.Colors.info
        case .analyze: return StudyDesign.Colors.warning
        case .review: return StudyDesign.Colors.success
        }
    }
}

struct ImportProcessView: View {
    var currentStep: ImportStep

    private var progress: Double {
        Double(currentStep.rawValue + 1) / Double(ImportStep.allCases.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack {
                Text("导入进度")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Spacer()
                Text("\(currentStep.rawValue + 1) / \(ImportStep.allCases.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(StudyDesign.Colors.surfaceFillDeep.opacity(0.50))
                    Capsule()
                        .fill(StudyDesign.Gradients.semanticWash(currentStep.tint))
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)

            HStack(spacing: StudyDesign.Spacing.tight) {
                ForEach(ImportStep.allCases) { step in
                    ImportStepPill(
                        step: step,
                        isActive: step == currentStep,
                        isComplete: step.rawValue < currentStep.rawValue
                    )

                    if step != ImportStep.allCases.last {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(step.rawValue < currentStep.rawValue ? StudyDesign.Colors.success : StudyDesign.Colors.labelTertiary)
                    }
                }
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.72), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

struct ImportStepPill: View {
    var step: ImportStep
    var isActive: Bool
    var isComplete: Bool

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : step.icon)
                .font(.headline)
            Text(step.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(isActive || isComplete ? step.tint : StudyDesign.Colors.labelSecondary)
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.horizontal, StudyDesign.Spacing.compact)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .fill(StudyDesign.Colors.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .stroke(step.tint.opacity(0.24), lineWidth: 1)
                    )
            } else if isComplete {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .fill(StudyDesign.Colors.success.opacity(0.10))
            }
        }
    }
}

struct FileImportReviewCard: View {
    var url: URL
    @Binding var importKind: DocumentKind
    var isBusy = false
    var onAnalyze: () -> Void
    var onCancel: () -> Void

    private var fileTypeText: String {
        let fileExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return fileExtension.isEmpty ? "未知格式" : fileExtension.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.chatInner) {
            Text("预览并确认")
                .font(.headline)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)

            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(StudyDesign.Colors.info)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        StudyDesign.Colors.cardBackground,
                                        StudyDesign.Colors.inputBackground
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.headline)
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .lineLimit(2)
                    Text("\(fileTypeText) · \(url.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)
                }
            }

            FileImportKindSelector(selection: $importKind)

            ViewThatFits(in: .horizontal) {
                HStack {
                    reviewActions
                }

                VStack(alignment: .leading) {
                    reviewActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(StudyDesign.Colors.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.74), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
    }

    @ViewBuilder
    private var reviewActions: some View {
        Button {
            onCancel()
        } label: {
            StudyActionPillLabel(title: "取消", systemImage: "xmark")
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact, minWidth: 74))
        .accessibilityLabel("取消导入")
        .help("取消本次文件导入")

        Button {
            onAnalyze()
        } label: {
            StudyActionPillLabel(title: "开始分析", systemImage: "sparkles")
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: importKind.libraryTint, minWidth: 100))
        .disabled(isBusy)
        .help(isBusy ? "当前正在处理资料，完成后再开始分析。" : "开始分析这份资料")
        .accessibilityHint(isBusy ? "当前正在处理资料，完成后再开始分析。" : "将上传文件到 DeepSeek 进行分析")
    }
}

private struct FileImportKindSelector: View {
    @Binding var selection: DocumentKind

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(alignment: .firstTextBaseline) {
                Text("资料类型")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Spacer()
                Text(selection.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(selection.libraryTint)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    kindChips
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    kindChips
                }
            }
        }
        .padding(StudyDesign.Spacing.tight)
        .background(
            LinearGradient(
                colors: [
                    StudyDesign.Colors.cardBackground,
                    StudyDesign.Colors.inputBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var kindChips: some View {
        ForEach(DocumentKind.allCases, id: \.self) { kind in
            ManualDocumentKindChip(kind: kind, isSelected: selection == kind) {
                selection = kind
            }
        }
    }
}

#if os(iOS)
private struct AnalysisDraftPreviewCard: View {
    let draft: AnalysisDraft

    var body: some View {
        ListCard(tint: StudyDesign.Colors.info) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
                HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.info)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(StudyDesign.Colors.inputBackground))
                        .overlay(Circle().stroke(StudyDesign.Colors.accentHairline, lineWidth: 1))

                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                        Text(draft.summary)
                            .font(.headline)
                            .lineLimit(2)

                        Text("\(draft.knowledgePoints.count) 个知识点 · \(draft.mistakes.count) 道错题 · \(draft.reviewItems.count) 个复习项")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }
                }

                HStack {
                    Text(draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)

                    Spacer()

                    NavigationLink {
                        DraftDetailView(draft: draft)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        StudyActionPillLabel(title: "查看确认", systemImage: "arrow.right")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.info, prominence: .secondary))
                    .help("查看这份分析草稿并确认写入")
                    .accessibilityLabel("查看确认分析草稿")
                    .accessibilityHint("打开待确认详情")
                }
            }
        }
    }
}

private struct AIPlanDraftPreviewCard: View {
    let draft: AIPlanDraft

    var body: some View {
        ListCard(tint: StudyDesign.Colors.warning) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
                HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.warning)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(StudyDesign.Colors.inputBackground))
                        .overlay(Circle().stroke(StudyDesign.Colors.accentHairline, lineWidth: 1))

                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                        Text(draft.title)
                            .font(.headline)
                            .lineLimit(2)

                        Text("\(draft.reviewItems.count) 个任务 · \(draft.knowledgePoints.count) 个知识点 · \(draft.mistakes.count) 个错题")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }
                }

                Text(draft.summary)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)

                HStack {
                    Text(draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)

                    Spacer()

                    NavigationLink {
                        AIPlanDraftStandaloneDetailView(draft: draft)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        StudyActionPillLabel(title: "查看确认", systemImage: "arrow.right")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.warning, prominence: .secondary))
                    .help("查看这份 AI 规划并确认加入")
                    .accessibilityLabel("查看确认 AI 规划")
                    .accessibilityHint("打开规划详情")
                }
            }
        }
    }
}

struct ImportedDocumentRow: View {
    var document: StudyDocument
    var isSelected: Bool
    var onToggleSelection: () -> Void
    var onDelete: () -> Void

    var body: some View {
        ListCard(tint: document.kind.libraryTint) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
                HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                    Button {
                        onToggleSelection()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(isSelected ? document.kind.libraryTint : StudyDesign.Colors.labelTertiary)
                            .iOSTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .help(isSelected ? "取消选择：\(document.title)" : "选择资料：\(document.title)")
                    .accessibilityLabel(isSelected ? "取消选择资料：\(document.title)" : "选择资料：\(document.title)")
                    .accessibilityValue(isSelected ? "已选择" : "未选择")

                    Button(action: onToggleSelection) {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                            HStack(spacing: StudyDesign.Spacing.tight) {
                                DocumentKindBadge(kind: document.kind)

                                Text(document.sourceName)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                                    .lineLimit(1)
                            }

                            Text(document.title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                                .lineLimit(2)

                            HStack(spacing: StudyDesign.Spacing.tight) {
                                Label(document.importedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                                Label("\(document.content.count) 字", systemImage: "text.alignleft")
                            }
                            .font(.caption2)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .help(isSelected ? "取消选择资料：\(document.title)" : "选择资料：\(document.title)")
                    .accessibilityLabel("\(document.title)，\(document.kind.rawValue)，\(document.content.count) 字")
                    .accessibilityValue(isSelected ? "已选择" : "未选择")
                    .accessibilityHint("轻点切换选择状态")

                    Spacer(minLength: StudyDesign.Spacing.tight)

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        StudyActionPillLabel(title: "删除", systemImage: "trash")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact, minWidth: 74))
                    .help("删除资料：\(document.title)")
                    .accessibilityLabel("删除资料：\(document.title)")
                    .accessibilityHint("删除后会同时删除相关待确认草稿、错题和复习任务")
                }
            }
        }
        .background(selectionBackground)
        .overlay(selectionOverlay)
        .shadow(color: isSelected ? document.kind.libraryTint.opacity(0.22) : .clear, radius: 14, y: 6)
        .animation(StudyDesign.Motion.animation(.fast), value: isSelected)
        .contextMenu {
            Button {
                onToggleSelection()
            } label: {
                Label(isSelected ? "取消选择" : "选择资料", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除资料", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .fill(document.kind.libraryTint.opacity(0.08))
        }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(
                    LinearGradient(
                        colors: [
                            document.kind.libraryTint.opacity(0.72),
                            StudyDesign.Colors.secondary.opacity(0.42),
                            document.kind.libraryTint.opacity(0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        }
    }
}

#endif

#if os(iOS)
private struct IOSImportSectionSwitcher: View {
    @Binding var selection: IOSImportSection
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.micro) {
            ForEach(IOSImportSection.allCases) { section in
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        selection = section
                    }
                } label: {
                    HStack(spacing: StudyDesign.Spacing.compact) {
                        Image(systemName: section.icon)
                            .font(.caption.weight(.bold))
                        Text(section.rawValue)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(selection == section ? StudyDesign.Colors.labelPrimary : StudyDesign.Colors.labelSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background {
                        if selection == section {
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                .fill(StudyDesign.Colors.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                        .stroke(StudyDesign.Colors.primary, lineWidth: 2)
                                )
                                .matchedGeometryEffect(id: "importSection", in: namespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous))
                }
                .buttonStyle(.plain)
                .iOSTouchTarget()
                .accessibilityLabel(section.rawValue)
                .accessibilityValue(selection == section ? "已选择" : "未选择")
                .accessibilityHint("切换到\(section.rawValue)分区")
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(StudyDesign.Spacing.micro)
        .background(
            LinearGradient(
                colors: [
                    StudyDesign.Colors.cardBackground,
                    StudyDesign.Colors.inputBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
        )
    }
}
#endif

private struct DocumentKindBadge: View {
    let kind: DocumentKind

    var body: some View {
        Label(kind.libraryShortLabel, systemImage: kind.libraryIcon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(kind.libraryTint)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, 4)
            .background(Capsule().fill(kind.libraryTint.opacity(0.14)))
            .overlay(
                Capsule()
                    .stroke(kind.libraryTint.opacity(0.24), lineWidth: 1)
            )
    }
}

private struct ManualInputMetricChip: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(tint.opacity(0.10)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.44), lineWidth: 1)
        )
    }
}

private struct ManualInputValidationHint: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.warning)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                StudyDesign.Colors.cardBackground,
                in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
    }
}

private struct ManualDocumentKindChip: View {
    let kind: DocumentKind
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudyDesign.Spacing.compact) {
                Image(systemName: kind.libraryIcon)
                    .font(.caption.weight(.bold))

                Text(kind.rawValue)
                    .font(.caption.weight(.bold))

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
            }
            .foregroundStyle(isSelected ? StudyDesign.Colors.primary : kind.libraryTint)
            .padding(.horizontal, StudyDesign.Spacing.normal)
            .padding(.vertical, StudyDesign.Spacing.tight)
            .background(
                Capsule()
                    .fill(StudyDesign.Colors.inputBackground)
            )
            .overlay(
                Capsule()
                    .stroke(
                        isFocused || isSelected ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                        lineWidth: isFocused || isSelected ? 2 : 1
                    )
            )
            .shadow(color: isSelected ? StudyDesign.Colors.primary.opacity(0.18) : .clear, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .iOSTouchTarget()
        .accessibilityLabel("资料类型：\(kind.rawValue)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint("设置手动输入资料类型")
        .help(isSelected ? "当前类型：\(kind.rawValue)" : "切换为\(kind.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if os(macOS)
struct DocumentLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedID: UUID?
    @State private var documentPendingDeletion: StudyDocument?

    var selected: StudyDocument? {
        store.snapshot.documents.first { $0.id == selectedID } ?? store.snapshot.documents.first
    }

    private var selectedDocumentID: UUID? {
        selected?.id
    }

    private var totalCharacters: Int {
        store.snapshot.documents.reduce(0) { $0 + $1.content.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            MacDocumentLibraryHeader(
                documentCount: store.snapshot.documents.count,
                totalCharacters: totalCharacters,
                selectedKindText: selected?.kind.libraryShortLabel ?? "等待导入"
            )

            if store.snapshot.documents.isEmpty {
                StudyEmptyState(title: "资料库为空", subtitle: "选择文件或手动保存资料后，导入内容会显示在这里。", icon: "tray.fill", accentIcon: "doc.badge.plus", accentTint: StudyDesign.Colors.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                        HStack {
                            Label("资料清单", systemImage: "tray.full.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(StudyDesign.Colors.labelPrimary)

                            Spacer()

                            Text("\(store.snapshot.documents.count) 份")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                .padding(.horizontal, StudyDesign.Spacing.tight)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    StudyDesign.Colors.cardBackground,
                                                    StudyDesign.Colors.inputBackground
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                )
                        }

                        ScrollView {
                            LazyVStack(spacing: StudyDesign.Spacing.tight) {
                                ForEach(store.snapshot.documents) { document in
                                    MacDocumentLibraryRow(
                                        document: document,
                                        isSelected: document.id == selectedDocumentID
                                    ) {
                                        withAnimation(StudyDesign.Motion.animation(.fast)) {
                                            selectedID = document.id
                                        }
                                    } onDelete: {
                                        documentPendingDeletion = document
                                    }
                                }
                            }
                            .padding(StudyDesign.Spacing.tight)
                        }
                        .frame(minHeight: 168, idealHeight: 230, maxHeight: 280)
                    }
                    .padding(StudyDesign.Spacing.normal)
                    .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                            .stroke(StudyDesign.Colors.accentHairline.opacity(0.68), lineWidth: 1)
                    )

                    if let selected {
                        MacDocumentPreviewPanel(document: selected) {
                            store.analyzeDocument(selected)
                        } onDelete: {
                            documentPendingDeletion = selected
                        }
                    }
                }
            }
        }
        .padding(StudyDesign.Spacing.wide)
        .frame(minWidth: 360, idealWidth: 520)
        .background(StudyDesign.Gradients.pageBackdrop)
        .alert(
            "删除这份资料？",
            isPresented: Binding(
                get: { documentPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        documentPendingDeletion = nil
                    }
                }
            ),
            presenting: documentPendingDeletion
        ) { document in
            Button("删除", role: .destructive) {
                store.deleteDocument(document)
                selectedID = store.snapshot.documents.first?.id
                documentPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                documentPendingDeletion = nil
            }
        } message: { document in
            Text("将删除“\(document.title)”以及它关联的待确认草稿、错题和复习任务。")
        }
    }
}

private struct MacDocumentLibraryHeader: View {
    let documentCount: Int
    let totalCharacters: Int
    let selectedKindText: String

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "books.vertical.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.secondary)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                            .fill(StudyDesign.Gradients.semanticWash(StudyDesign.Colors.secondary).opacity(0.20))
                            .overlay(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                                    .stroke(StudyDesign.Colors.secondary.opacity(0.18), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("资料库")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)

                    Text("导入内容、手动资料和 AI 分析入口集中在这里。")
                        .font(.subheadline)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                MacDocumentMetricTile(title: "资料", value: "\(documentCount)", icon: "tray.full.fill", tint: StudyDesign.Colors.secondary)
                MacDocumentMetricTile(title: "字符", value: "\(totalCharacters)", icon: "text.alignleft", tint: StudyDesign.Colors.info)
                MacDocumentMetricTile(title: "当前", value: selectedKindText, icon: "scope", tint: StudyDesign.Colors.primary)
            }
        }
        .padding(StudyDesign.Spacing.roomy)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                .fill(StudyDesign.Colors.secondary.opacity(0.46))
                .frame(width: 4)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

private struct MacDocumentMetricTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.10)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            LinearGradient(
                colors: [
                    StudyDesign.Colors.cardBackground,
                    StudyDesign.Colors.inputBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

private struct MacDocumentLibraryRow: View {
    let document: StudyDocument
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                    VStack(spacing: StudyDesign.Spacing.micro) {
                        Image(systemName: document.kind.libraryIcon)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(document.kind.libraryTint)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(document.kind.libraryTint.opacity(0.10)))

                        RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                            .fill(isSelected ? document.kind.libraryTint : StudyDesign.Colors.accentHairline)
                            .frame(width: 3, height: 32)
                    }

                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        HStack(spacing: StudyDesign.Spacing.tight) {
                            DocumentKindBadge(kind: document.kind)
                            Text(document.sourceName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                                .lineLimit(1)
                        }

                        Text(document.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: StudyDesign.Spacing.tight) {
                            Label(document.importedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                            Label("\(document.content.count) 字", systemImage: "text.alignleft")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }

                    Spacer(minLength: StudyDesign.Spacing.tight)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("资料：\(document.title)")
            .accessibilityValue(isSelected ? "已选中" : "未选中")
            .accessibilityHint("选择这份资料并显示预览")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.danger)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(StudyDesign.Colors.danger.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .help("删除资料：\(document.title)")
            .accessibilityLabel("删除资料：\(document.title)")
            .accessibilityHint("删除后会同时删除相关待确认草稿、错题和复习任务")
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(isSelected ? StudyDesign.Colors.inputBackground : StudyDesign.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(isSelected ? document.kind.libraryTint : StudyDesign.Colors.accentHairline, lineWidth: isSelected ? 2 : 1)
        )
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label(isSelected ? "当前预览" : "选择预览", systemImage: isSelected ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
            }
            .disabled(isSelected)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除资料", systemImage: "trash")
            }
        }
        .help(isSelected ? "当前预览：\(document.title)" : "选择预览：\(document.title)")
    }
}

private struct MacDocumentPreviewPanel: View {
    let document: StudyDocument
    let onAnalyze: () -> Void
    let onDelete: () -> Void

    private var previewText: String {
        document.content.isEmpty ? "这份资料没有可预览的正文。" : document.content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    HStack(spacing: StudyDesign.Spacing.tight) {
                        DocumentKindBadge(kind: document.kind)
                        Text(document.importedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    }

                    Text(document.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .lineLimit(2)

                    Text(document.sourceName)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                HStack(spacing: StudyDesign.Spacing.tight) {
                    Button(action: onAnalyze) {
                        StudyActionPillLabel(title: "重新分析", systemImage: "sparkles")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(minWidth: 100))
                    .help("重新分析资料：\(document.title)")
                    .accessibilityLabel("重新分析资料：\(document.title)")
                    .accessibilityHint("再次调用 AI 分析这份资料")

                    Button(role: .destructive, action: onDelete) {
                        StudyActionPillLabel(title: "删除", systemImage: "trash")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact, minWidth: 74))
                    .help("删除资料：\(document.title)")
                    .accessibilityLabel("删除资料：\(document.title)")
                    .accessibilityHint("删除后会同时删除相关待确认草稿、错题和复习任务")
                }
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                MacDocumentMetricTile(title: "类型", value: document.kind.libraryShortLabel, icon: document.kind.libraryIcon, tint: document.kind.libraryTint)
                MacDocumentMetricTile(title: "正文", value: "\(document.content.count) 字", icon: "text.quote", tint: StudyDesign.Colors.info)
            }

            ScrollView {
                Text(previewText)
                    .font(.body)
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(StudyDesign.Spacing.normal)
            }
            .frame(minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .fill(StudyDesign.Colors.inputBackground)
                    .overlay(
                        LinearGradient(
                            colors: [
                                document.kind.libraryTint.opacity(0.055),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                    .fill(document.kind.libraryTint.opacity(0.52))
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.normal)
            }
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(StudyDesign.Colors.accentHairline.opacity(0.58), lineWidth: 1)
            )
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.66), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color.opacity(0.82), radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .contextMenu {
            Button(action: onAnalyze) {
                Label("重新分析", systemImage: "sparkles")
            }

            Button(role: .destructive, action: onDelete) {
                Label("删除资料", systemImage: "trash")
            }
        }
    }
}
#endif
