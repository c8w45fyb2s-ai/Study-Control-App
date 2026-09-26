import SwiftUI

struct KnowledgeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointPendingDeletion: KnowledgePoint?
    @State private var editingPoint: KnowledgePoint?
    @State private var searchText = ""
    @State private var selectedSubject = allSubjectsTitle
    @State private var masteryFilter: MasteryFilter = .all
    @State private var sort: KnowledgeSort = .recent

    private var subjectOptions: [String] {
        [allSubjectsTitle] + Array(Set(store.snapshot.knowledgePoints.map(\.subject)))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filteredPoints: [KnowledgePoint] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.snapshot.knowledgePoints.filter { point in
            let matchesSubject = selectedSubject == allSubjectsTitle || point.subject == selectedSubject
            let matchesMastery = masteryFilter.matches(point.mastery)
            let matchesSearch = query.isEmpty ||
                point.title.localizedCaseInsensitiveContains(query) ||
                point.subject.localizedCaseInsensitiveContains(query) ||
                point.summary.localizedCaseInsensitiveContains(query)
            return matchesSubject && matchesMastery && matchesSearch
        }

        return filtered.sorted { lhs, rhs in
            switch sort {
            case .recent:
                return lhs.createdAt > rhs.createdAt
            case .lowMastery:
                return lhs.mastery < rhs.mastery
            case .highMastery:
                return lhs.mastery > rhs.mastery
            case .title:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private var weakPointCount: Int {
        store.snapshot.knowledgePoints.filter { $0.mastery < 0.5 }.count
    }

    private var masteredPointCount: Int {
        store.snapshot.knowledgePoints.filter { $0.mastery >= 0.8 }.count
    }

    private var isFilteringKnowledge: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedSubject != allSubjectsTitle
            || masteryFilter != .all
            || sort != .recent
    }

    private var subjectCount: Int {
        max(subjectOptions.count - 1, 0)
    }

    private func resetKnowledgeFilters() {
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast)) {
            searchText = ""
            selectedSubject = allSubjectsTitle
            masteryFilter = .all
            sort = .recent
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudyDesign.Spacing.chatInner) {
                StudyPageHeader(
                    title: "知识点",
                    subtitle: "把 AI 提炼出的概念、科目和掌握状态收进一个可复盘的知识底座。",
                    icon: "lightbulb.fill",
                    tint: StudyDesign.Colors.primary
                )

                LibraryOverviewHeader(
                    icon: "lightbulb.fill",
                    tint: StudyDesign.Colors.warning,
                    countValue: store.snapshot.knowledgePoints.count,
                    countLabel: "知识点",
                    metrics: [
                        LibraryMetric(title: "薄弱", value: "\(weakPointCount)", icon: "gauge.with.dots.needle.33percent", tint: StudyDesign.Colors.warning),
                        LibraryMetric(title: "已掌握", value: "\(masteredPointCount)", icon: "checkmark.seal.fill", tint: StudyDesign.Colors.success),
                        LibraryMetric(title: "科目", value: "\(subjectCount)", icon: "books.vertical.fill", tint: StudyDesign.Colors.secondary)
                    ]
                )

                LibraryToolPanel(title: "知识检索", statusText: "\(filteredPoints.count) / \(store.snapshot.knowledgePoints.count)") {
                    StudyInlineSearchField(text: $searchText, prompt: "搜索知识点、科目或摘要")

                    KnowledgeFilterControls(
                        selectedSubject: $selectedSubject,
                        subjects: subjectOptions,
                        masteryFilter: $masteryFilter,
                        sort: $sort
                    )

                    if isFilteringKnowledge {
                        StudyFilterResetButton {
                            resetKnowledgeFilters()
                        }
                    }
                }

                ForEach(filteredPoints) { point in
                    KnowledgePointCard(point: point, editingPoint: $editingPoint, pointPendingDeletion: $pointPendingDeletion)
                }
                if store.snapshot.knowledgePoints.isEmpty {
                    StudyEmptyState(title: "知识点为空", subtitle: "确认分析草稿后，知识点会自动沉淀在这里。", icon: "lightbulb.fill", accentIcon: "sparkles", accentTint: StudyDesign.Colors.warning, actionLabel: "去导入资料") {
                        store.navigateToImport()
                    }
                } else if filteredPoints.isEmpty {
                    StudyEmptyState(title: "没有匹配的知识点", subtitle: "换一个关键词、科目或掌握度筛选试试。", icon: "magnifyingglass", accentIcon: "questionmark", actionLabel: "重置筛选") {
                        resetKnowledgeFilters()
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .sheet(item: $editingPoint) { point in
            KnowledgeEditSheetWrapper(point: point)
        }
        .alert(
            "删除这个知识点？",
            isPresented: Binding(
                get: { pointPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pointPendingDeletion = nil
                    }
                }
            ),
            presenting: pointPendingDeletion
        ) { point in
            Button("删除", role: .destructive) {
                store.deleteKnowledgePoint(point)
                pointPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pointPendingDeletion = nil
            }
        } message: { point in
            Text("将删除“\(point.title)”以及它关联的复习任务。")
        }
    }
}

struct MistakesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var selectedSubject = allSubjectsTitle
    @State private var sort: MistakeSort = .recent

    private var subjectOptions: [String] {
        let allSubjects = store.snapshot.mistakes.flatMap { subjects(for: $0) }
        return [allSubjectsTitle] + Array(Set(allSubjects))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var filteredMistakes: [Mistake] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.snapshot.mistakes.filter { mistake in
            let mistakeSubjects = subjects(for: mistake)
            let matchesSubject = selectedSubject == allSubjectsTitle || mistakeSubjects.contains(selectedSubject)
            let matchesSearch = query.isEmpty ||
                mistake.question.localizedCaseInsensitiveContains(query) ||
                mistake.correctAnswer.localizedCaseInsensitiveContains(query) ||
                mistake.errorReason.localizedCaseInsensitiveContains(query) ||
                mistakeSubjects.contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesSubject && matchesSearch
        }

        return filtered.sorted { lhs, rhs in
            switch sort {
            case .recent:
                return lhs.createdAt > rhs.createdAt
            case .oldest:
                return lhs.createdAt < rhs.createdAt
            case .question:
                return lhs.question.localizedStandardCompare(rhs.question) == .orderedAscending
            }
        }
    }

    private var subjectCount: Int {
        max(subjectOptions.count - 1, 0)
    }

    private var linkedKnowledgePointCount: Int {
        Set(store.snapshot.mistakes.flatMap(\.knowledgePointIDs)).count
    }

    private var isFilteringMistakes: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedSubject != allSubjectsTitle
            || sort != .recent
    }

    private func subjects(for mistake: Mistake) -> [String] {
        let subjects = mistake.knowledgePointIDs.compactMap { id in
            store.snapshot.knowledgePoints.first { $0.id == id }?.subject
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        return subjects.isEmpty ? [uncategorizedSubjectTitle] : Array(Set(subjects))
    }

    private func resetMistakeFilters() {
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast)) {
            searchText = ""
            selectedSubject = allSubjectsTitle
            sort = .recent
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudyDesign.Spacing.chatInner) {
                StudyPageHeader(
                    title: "错题本",
                    subtitle: "把做错的题目、答案和错因留在同一个复盘区，方便后续回看和再练。",
                    icon: "xmark.circle.fill",
                    tint: StudyDesign.Colors.primary
                )

                LibraryOverviewHeader(
                    icon: "xmark.circle.fill",
                    tint: StudyDesign.Colors.danger,
                    countValue: store.snapshot.mistakes.count,
                    countLabel: "错题",
                    metrics: [
                        LibraryMetric(title: "当前显示", value: "\(filteredMistakes.count)", icon: "line.3.horizontal.decrease.circle", tint: StudyDesign.Colors.info),
                        LibraryMetric(title: "关联知识", value: "\(linkedKnowledgePointCount)", icon: "lightbulb.fill", tint: StudyDesign.Colors.warning),
                        LibraryMetric(title: "科目", value: "\(subjectCount)", icon: "books.vertical.fill", tint: StudyDesign.Colors.secondary)
                    ]
                )

                LibraryToolPanel(title: "错题检索", statusText: "\(filteredMistakes.count) / \(store.snapshot.mistakes.count)") {
                    StudyInlineSearchField(text: $searchText, prompt: "搜索题目、答案、错因或科目")

                    ListFilterControls(
                        selectedSubject: $selectedSubject,
                        subjects: subjectOptions,
                        sort: $sort
                    )

                    if isFilteringMistakes {
                        StudyFilterResetButton {
                            resetMistakeFilters()
                        }
                    }
                }

                ForEach(filteredMistakes) { mistake in
                    MistakeRow(mistake: mistake)
                }
                if store.snapshot.mistakes.isEmpty {
                    StudyEmptyState(title: "错题本为空", subtitle: "导入错题并确认分析结果后，这里会出现错题和错因。", icon: "xmark.circle.fill", accentIcon: "sparkles", accentTint: StudyDesign.Colors.danger, actionLabel: "去导入资料") {
                        store.navigateToImport()
                    }
                } else if filteredMistakes.isEmpty {
                    StudyEmptyState(title: "没有匹配的错题", subtitle: "换一个关键词、科目或排序方式试试。", icon: "magnifyingglass", accentIcon: "questionmark", actionLabel: "重置筛选") {
                        resetMistakeFilters()
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
    }
}

private struct LibraryMetric: Identifiable {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var id: String { title }
}

private struct LibraryOverviewHeader: View {
    let icon: String
    let tint: Color
    let countValue: Int
    let countLabel: String
    let metrics: [LibraryMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
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
                            .overlay(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                                    .stroke(tint.opacity(0.16), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("\(countValue)")
                        .font(StudyDesign.Typography.metric)
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("\(countLabel)总数")
                        .font(StudyDesign.Typography.supporting.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
                ForEach(metrics) { metric in
                    LibraryMetricTile(metric: metric)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(StudyDesign.Colors.cardBackground)

                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                    .fill(tint.opacity(0.40))
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.normal)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .help("\(countLabel)总数：\(countValue)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(countLabel)总数，\(countValue)")
    }
}

private struct LibraryMetricTile: View {
    let metric: LibraryMetric

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.compact) {
            Image(systemName: metric.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(metric.tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(metric.value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(metric.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            StudyDesign.Colors.inputBackground,
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title)：\(metric.value)")
        .help("\(metric.title)：\(metric.value)")
    }
}

private struct LibraryToolPanel<Content: View>: View {
    let title: String
    let statusText: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Label(title, systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)

                Spacer()

                Text(statusText)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .padding(.horizontal, StudyDesign.Spacing.compact)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(StudyDesign.Colors.inputBackground)
                    )
                    .overlay(Capsule().stroke(StudyDesign.Colors.accentHairline, lineWidth: 1))
            }

            content
        }
        .padding(StudyDesign.Spacing.normal)
        .background {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .help("\(title)：\(statusText)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(statusText)")
    }
}

struct MistakeRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingCompleteConfirmation = false
    @State private var isEditing = false
    @State private var isShowingDetails = false
    @State private var practiceCard: StudyCard?
    @State private var openedSource: SourceReference?
    var mistake: Mistake

    private func openPractice() {
        if let existing = store.snapshot.studyCards.first(where: { $0.mistakeID == mistake.id }) {
            practiceCard = existing
        } else {
            practiceCard = store.createCard(from: mistake)
        }
    }

    private var relatedKnowledgeTitles: [String] {
        mistake.knowledgePointIDs.compactMap { id in
            store.snapshot.knowledgePoints.first { $0.id == id }?.title
        }
    }

    private var relationText: String {
        relatedKnowledgeTitles.isEmpty ? "未关联知识点" : "\(relatedKnowledgeTitles.count) 个关联知识点"
    }

    var body: some View {
        ListCard(tint: StudyDesign.Colors.danger) {
            mistakeContent
        }
        .contextMenu {
            if let sourceDocumentID = mistake.sourceDocumentID {
                Button("查看资料来源") {
                    openedSource = mistake.sourceReference ?? SourceReference(documentID: sourceDocumentID,
                        chunkID: nil, pageNumber: nil, excerpt: "")
                }
            }
            Button("应用内重做") { openPractice() }
            Button(mistake.practiceState == .mastered ? "恢复错题" : "手动归档") {
                store.setMistakeArchived(mistake, archived: mistake.practiceState != .mastered)
            }
            Button {
                isShowingCompleteConfirmation = true
            } label: {
                Label("订正完成", systemImage: "checkmark.circle")
            }

            Button {
                isEditing = true
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .sheet(isPresented: $isEditing) {
            MistakeEditSheetWrapper(mistake: mistake)
        }
        .sheet(item: $practiceCard) { card in
            ActiveRecallView(initialCardID: card.id).environmentObject(store)
        }
        .sheet(isPresented: Binding(get: { openedSource != nil }, set: { if !$0 { openedSource = nil } })) {
            if let openedSource { SourceLocationView(reference: openedSource).environmentObject(store) }
        }
        .alert("删除这道错题？", isPresented: $isShowingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                store.deleteMistake(mistake)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除这道错题以及它关联的复习任务。")
        }
        .confirmationDialog("完成订正？", isPresented: $isShowingCompleteConfirmation, titleVisibility: .visible) {
            Button("订正完成") {
                store.completeMistake(mistake)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("错题仍保留，接下来可应用内重做。")
        }
    }

    @ViewBuilder
    private var mistakeContent: some View {
#if os(iOS)
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
            mistakeHeader
            mistakeQuestionBlock
            if isShowingDetails {
                answerReasonBlocks
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            compactActionBar
        }
#else
        HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
                mistakeHeader
                mistakeQuestionBlock
                if isShowingDetails {
                    answerReasonBlocks
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .layoutPriority(1)

            Spacer(minLength: StudyDesign.Spacing.tight)
            desktopActionBar
        }
#endif
    }

    private var mistakeHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                mistakeTitleLabel
                Spacer(minLength: StudyDesign.Spacing.tight)
                mistakeMetadata
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                mistakeTitleLabel
                mistakeMetadata
            }
        }
    }

    private var mistakeTitleLabel: some View {
        Label(mistake.practiceState.label, systemImage: "xmark.circle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(StudyDesign.Colors.danger)
            .padding(.horizontal, StudyDesign.Spacing.compact)
            .padding(.vertical, 5)
            .background(Capsule().fill(StudyDesign.Colors.dangerSubtleLight))
            .overlay(
                Capsule()
                    .stroke(StudyDesign.Colors.danger.opacity(0.18), lineWidth: 1)
            )
            .fixedSize()
    }

    private var mistakeMetadata: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            MistakeMetaChip(
                title: mistake.createdAt.formatted(date: .abbreviated, time: .omitted),
                icon: "calendar",
                tint: StudyDesign.Colors.labelSecondary
            )
            MistakeMetaChip(
                title: relationText,
                icon: "link",
                tint: relatedKnowledgeTitles.isEmpty ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.warning
            )
        }
    }

    private var mistakeQuestionBlock: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: StudyDesign.Spacing.compact) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Text("题目")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            Text(mistake.question)
                .font(.headline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(StudyDesign.Spacing.tight)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
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

                StudyDesign.Gradients.semanticWash(StudyDesign.Colors.danger)
                    .opacity(0.12)
                    .mask(
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                    .fill(StudyDesign.Colors.danger.opacity(0.34))
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.tight)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .accessibilityLabel("题目：\(mistake.question)")
    }

    private var answerReasonBlocks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                mistakeDetailBlock(
                    title: "正确答案",
                    icon: "checkmark.seal.fill",
                    tint: StudyDesign.Colors.success,
                    text: mistake.correctAnswer
                )
                mistakeDetailBlock(
                    title: "错因分析",
                    icon: "exclamationmark.triangle.fill",
                    tint: StudyDesign.Colors.danger,
                    text: mistake.errorReason
                )
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                mistakeDetailBlock(
                    title: "正确答案",
                    icon: "checkmark.seal.fill",
                    tint: StudyDesign.Colors.success,
                    text: mistake.correctAnswer
                )
                mistakeDetailBlock(
                    title: "错因分析",
                    icon: "exclamationmark.triangle.fill",
                    tint: StudyDesign.Colors.danger,
                    text: mistake.errorReason
                )
            }
        }
    }

    private func mistakeDetailBlock(title: String, icon: String, tint: Color, text: String) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: StudyDesign.Spacing.compact) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(tint.opacity(0.12)))
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            Text(text)
                .font(.subheadline)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
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

                StudyDesign.Gradients.semanticWash(tint)
                    .opacity(0.08)
                    .mask(
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                    .fill(tint.opacity(0.38))
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.tight)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(tint.opacity(0.72))
                .frame(height: 2)
                .padding(.horizontal, StudyDesign.Spacing.tight)
        }
    }

    private var compactActionBar: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            detailsToggleButton

            Button("重做") { openPractice() }
                .buttonStyle(.bordered)

            completeButton
                .frame(minWidth: 92)

            Spacer(minLength: StudyDesign.Spacing.tight)

            mistakeMoreMenu
        }
        .frame(maxWidth: .infinity)
        .padding(.top, StudyDesign.Spacing.micro)
    }

    private var mistakeMoreMenu: some View {
        Menu {
            if let sourceDocumentID = mistake.sourceDocumentID {
                Button("查看资料来源") {
                    openedSource = mistake.sourceReference ?? SourceReference(documentID: sourceDocumentID,
                        chunkID: nil, pageNumber: nil, excerpt: "")
                }
            }
            Button(mistake.practiceState == .mastered ? "恢复错题" : "手动归档") {
                store.setMistakeArchived(mistake, archived: mistake.practiceState != .mastered)
            }
            Button {
                isEditing = true
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .fill(StudyDesign.Colors.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        }
        .iOSTouchTarget()
        .accessibilityLabel("更多错题操作：\(mistake.question)")
        .accessibilityHint("打开编辑和删除操作")
        .help("更多错题操作")
    }

    private var desktopActionBar: some View {
        VStack(alignment: .trailing, spacing: StudyDesign.Spacing.tight) {
            detailsToggleButton

            Button("应用内重做") { openPractice() }
                .buttonStyle(.bordered)

            completeButton

            Button(mistake.practiceState == .mastered ? "恢复" : "归档") {
                store.setMistakeArchived(mistake, archived: mistake.practiceState != .mastered)
            }
            .buttonStyle(.bordered)

            Button {
                isEditing = true
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.labelSecondary, prominence: .soft, size: .compact))
            .accessibilityLabel("编辑错题：\(mistake.question)")
            .help("编辑错题")

            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact))
            .accessibilityLabel("删除错题：\(mistake.question)")
            .accessibilityHint("删除后会移除关联复习任务")
            .help("删除错题")
        }
    }

    private var detailsToggleButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast)) {
                isShowingDetails.toggle()
            }
        } label: {
            Label(isShowingDetails ? "收起" : "详情", systemImage: isShowingDetails ? "chevron.up" : "text.alignleft")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.labelSecondary, prominence: .soft, size: .compact))
        .accessibilityLabel(isShowingDetails ? "收起错题详情：\(mistake.question)" : "查看错题详情：\(mistake.question)")
        .accessibilityHint(isShowingDetails ? "隐藏答案和错因" : "展开正确答案和错因分析")
        .help(isShowingDetails ? "收起答案和错因" : "查看答案和错因")
    }

    private var completeButton: some View {
        Button {
            isShowingCompleteConfirmation = true
        } label: {
            Label("订正完成", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))
        .accessibilityLabel("完成错题：\(mistake.question)")
        .accessibilityHint("错题将保留，等待重做")
        .help("完成订正并保留错题")
#if os(iOS)
        .sensoryFeedback(.success, trigger: store.snapshot.mistakes.count)
#endif
    }

}

private struct MistakeMetaChip: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.labelSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, StudyDesign.Spacing.compact)
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
            .overlay(
                Capsule()
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
    }
}

// MARK: - Inline Knowledge Point Card

struct KnowledgePointCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showMasteryPicker = false
    @State private var isShowingDetails = false
    @State private var practiceCard: StudyCard?
    @State private var openedSource: SourceReference?
    @Namespace private var masterySelectionNamespace
    var point: KnowledgePoint
    @Binding var editingPoint: KnowledgePoint?
    @Binding var pointPendingDeletion: KnowledgePoint?

    private let masteryOptions: [(value: Double, label: String)] = [
        (0, "重学"),
        (0.25, "薄弱"),
        (0.5, "学习中"),
        (0.75, "熟练"),
        (1, "掌握")
    ]

    private var masteryLevel: (label: String, color: Color) {
        switch point.mastery {
        case ..<0.25: return ("重学", StudyDesign.Colors.danger)
        case ..<0.5: return ("薄弱", StudyDesign.Colors.warning)
        case ..<0.8: return ("熟练", StudyDesign.Colors.info)
        default: return ("已掌握", StudyDesign.Colors.success)
        }
    }

    private var masteryPercent: Int {
        Int((min(max(point.mastery, 0), 1) * 100).rounded())
    }

    var body: some View {
        ListCard(tint: masteryLevel.color) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
                knowledgeHeader

                if isShowingDetails {
                    summaryPanel
                    masteryHealthPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    compactSummaryLine
                }

                if showMasteryPicker {
                    masteryPicker
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                knowledgeToolbar
            }
        }
        .contextMenu {
            if let sourceDocumentID = point.sourceDocumentID {
                Button("查看资料来源") {
                    openedSource = point.sourceReference ?? SourceReference(documentID: sourceDocumentID,
                        chunkID: nil, pageNumber: nil, excerpt: "")
                }
            }
            Button("从知识点创建问答卡") { practiceCard = store.createCard(from: point) }
            Button {
                withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.spring)) {
                    showMasteryPicker.toggle()
                }
            } label: {
                Label(showMasteryPicker ? "收起掌握度" : "调整掌握度", systemImage: "slider.horizontal.3")
            }

            Divider()

            ForEach(masteryOptions, id: \.value) { option in
                Button {
                    updateMastery(option.value)
                } label: {
                    Label("设为\(option.label)", systemImage: abs(point.mastery - option.value) < 0.01 ? "checkmark.circle.fill" : "circle")
                }
                .disabled(abs(point.mastery - option.value) < 0.01)
            }

            Divider()

            Button {
                editingPoint = point
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Button(role: .destructive) {
                pointPendingDeletion = point
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("知识点：\(point.title)，\(point.subject)，掌握度 \(Int(point.mastery * 100))%")
        .sheet(item: $practiceCard) { card in
            ActiveRecallView(initialCardID: card.id).environmentObject(store)
        }
        .sheet(isPresented: Binding(get: { openedSource != nil }, set: { if !$0 { openedSource = nil } })) {
            if let openedSource { SourceLocationView(reference: openedSource).environmentObject(store) }
        }
    }

    private var compactSummaryLine: some View {
        Text(point.summary)
            .font(.subheadline)
            .foregroundStyle(StudyDesign.Colors.labelSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("摘要：\(point.summary)")
    }

    private var knowledgeHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                knowledgeIcon
                headerText
                    .layoutPriority(1)
                masteryStatusBadge
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                    knowledgeIcon
                    headerText
                }
                masteryStatusBadge
            }
        }
    }

    private var knowledgeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                .fill(StudyDesign.Colors.inputBackground)
            Image(systemName: "lightbulb.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(masteryLevel.color)
        }
        .frame(width: 34, height: 34)
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                .stroke(masteryLevel.color.opacity(0.20), lineWidth: 1)
        )
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Text(point.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    KnowledgeSubjectBadge(subject: point.subject)
                    knowledgeMetaChip(point.createdAt.formatted(date: .abbreviated, time: .omitted), icon: "calendar")
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    KnowledgeSubjectBadge(subject: point.subject)
                    knowledgeMetaChip(point.createdAt.formatted(date: .abbreviated, time: .omitted), icon: "calendar")
                }
            }
        }
    }

    private var masteryStatusBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.compact) {
            Text("\(masteryPercent)%")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(masteryLevel.label)
                .font(.caption.weight(.bold))
                .foregroundStyle(masteryLevel.color)
                .lineLimit(1)
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, 6)
        .background(Capsule().fill(masteryLevel.color.opacity(0.10)))
        .overlay(Capsule().stroke(masteryLevel.color.opacity(0.20), lineWidth: 1))
        .fixedSize()
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Label("摘要", systemImage: "text.alignleft")
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            Text(point.summary)
                .font(.subheadline)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("摘要：\(point.summary)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
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

                StudyDesign.Gradients.semanticWash(masteryLevel.color)
                    .opacity(0.12)
                    .mask(
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                    .fill(masteryLevel.color.opacity(0.34))
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.tight)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }

    private var masteryHealthPanel: some View {
        Button {
            withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.spring)) {
                showMasteryPicker.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
                    Label {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                            Text("掌握状态")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                            Text(masteryLevel.label)
                                .font(.caption2)
                                .foregroundStyle(masteryLevel.color)
                        }
                    } icon: {
                        Image(systemName: "waveform.path.ecg")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(masteryLevel.color)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(masteryLevel.color.opacity(0.14)))
                    }

                    Spacer(minLength: StudyDesign.Spacing.tight)

                    Image(systemName: showMasteryPicker ? "chevron.up" : "slider.horizontal.3")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(StudyDesign.Colors.inputBackground))
                }

                MasteryHealthBar(value: point.mastery, tint: masteryLevel.color)
                    .frame(height: 22)

                HStack {
                    Text("重学")
                    Spacer()
                    Text("熟练")
                    Spacer()
                    Text("掌握")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }
            .padding(StudyDesign.Spacing.normal)
            .background {
                ZStack(alignment: .leading) {
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

                    StudyDesign.Gradients.semanticWash(masteryLevel.color)
                        .opacity(0.08)
                        .mask(
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                        .fill(masteryLevel.color.opacity(0.42))
                        .frame(width: 3)
                        .padding(.vertical, StudyDesign.Spacing.normal)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        }
        .buttonStyle(.plain)
        .iOSTouchTarget()
        .accessibilityLabel("掌握度 \(masteryPercent)%，\(masteryLevel.label)，点击调整")
        .accessibilityHint(showMasteryPicker ? "收起掌握度选项" : "展开掌握度选项")
        .help(showMasteryPicker ? "收起掌握度选项" : "展开掌握度选项")
    }

    private var masteryPicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.micro) {
                masteryOptionButtons
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72), spacing: StudyDesign.Spacing.micro)],
                alignment: .leading,
                spacing: StudyDesign.Spacing.micro
            ) {
                masteryOptionButtons
            }
        }
        .padding(StudyDesign.Spacing.micro)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var masteryOptionButtons: some View {
        ForEach(masteryOptions, id: \.value) { option in
            masteryOptionButton(value: option.value, label: option.label)
        }
    }

    private func masteryOptionButton(value: Double, label: String) -> some View {
        let tint = masteryTint(for: value)
        let isSelected = abs(point.mastery - value) < 0.01

        return Button {
            updateMastery(value)
        } label: {
            VStack(spacing: StudyDesign.Spacing.micro) {
                Text("\(Int(value * 100))%")
                    .font(.caption.weight(.black))
                    .monospacedDigit()
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.tight)
            .background(
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(StudyDesign.Colors.primary.opacity(0.15))
                            .matchedGeometryEffect(id: "knowledgeMasterySelection", in: masterySelectionNamespace)
                    } else {
                        Capsule()
                            .fill(tint.opacity(0.10))
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? StudyDesign.Colors.primary.opacity(0.62) : tint.opacity(0.22), lineWidth: isSelected ? 2 : 1)
            )
            .foregroundStyle(isSelected ? StudyDesign.Colors.primary : tint)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .iOSTouchTarget()
        .accessibilityLabel("设置掌握度 \(Int(value * 100))%，\(label)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint("更新这个知识点的掌握度")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(isSelected ? "当前掌握度：\(label)" : "设置为\(label)")
#if os(iOS)
        .sensoryFeedback(.selection, trigger: point.mastery)
#endif
    }

    private func updateMastery(_ value: Double) {
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.spring)) {
            store.updateKnowledgePoint(
                point,
                title: point.title,
                subject: point.subject,
                summary: point.summary,
                mastery: value
            )
        }
    }

    private func masteryTint(for value: Double) -> Color {
        switch value {
        case ..<0.25: return StudyDesign.Colors.danger
        case ..<0.5: return StudyDesign.Colors.warning
        case ..<0.8: return StudyDesign.Colors.info
        default: return StudyDesign.Colors.success
        }
    }

    private var knowledgeToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                detailsToggleButton
                Button("制卡") { practiceCard = store.createCard(from: point) }
                    .buttonStyle(.bordered)
                if let sourceDocumentID = point.sourceDocumentID {
                    Button("来源") {
                        openedSource = point.sourceReference ?? SourceReference(documentID: sourceDocumentID,
                            chunkID: nil, pageNumber: nil, excerpt: "")
                    }
                    .buttonStyle(.bordered)
                }
                if isShowingDetails || showMasteryPicker {
                    masteryToggleButton
                }
                Spacer(minLength: StudyDesign.Spacing.tight)
                knowledgeMoreMenu
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                detailsToggleButton
                if isShowingDetails || showMasteryPicker {
                    masteryToggleButton
                }
                knowledgeMoreMenu
            }
        }
    }

    private var detailsToggleButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast)) {
                isShowingDetails.toggle()
                if !isShowingDetails {
                    showMasteryPicker = false
                }
            }
        } label: {
            Label(isShowingDetails ? "收起" : "详情", systemImage: isShowingDetails ? "chevron.up" : "text.alignleft")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.labelSecondary, prominence: .soft, size: .compact))
        .accessibilityLabel(isShowingDetails ? "收起知识点详情：\(point.title)" : "查看知识点详情：\(point.title)")
        .accessibilityHint(isShowingDetails ? "隐藏摘要面板和掌握度面板" : "展开摘要和掌握度调整")
        .help(isShowingDetails ? "收起详情" : "查看详情")
    }

    private var masteryToggleButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.spring)) {
                showMasteryPicker.toggle()
            }
        } label: {
            Label(showMasteryPicker ? "收起掌握度" : "调整掌握度", systemImage: showMasteryPicker ? "chevron.up" : "slider.horizontal.3")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: masteryLevel.color, prominence: .secondary, size: .compact))
        .accessibilityLabel(showMasteryPicker ? "收起掌握度选项：\(point.title)" : "调整掌握度：\(point.title)")
        .accessibilityHint(showMasteryPicker ? "收起掌握度选项" : "展开掌握度选项")
        .help(showMasteryPicker ? "收起掌握度选项" : "展开掌握度选项")
    }

    private var knowledgeMoreMenu: some View {
        Menu {
            Button {
                editingPoint = point
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Button(role: .destructive) {
                pointPendingDeletion = point
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .fill(StudyDesign.Colors.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        }
        .iOSTouchTarget()
        .accessibilityLabel("更多知识点操作：\(point.title)")
        .accessibilityHint("打开编辑和删除操作")
        .help("更多知识点操作")
    }

    private func knowledgeMetaChip(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.labelSecondary)
            .lineLimit(1)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, 5)
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
            .overlay(
                Capsule()
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
    }
}

private struct KnowledgeSubjectBadge: View {
    let subject: String

    var body: some View {
        Text(subject)
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.labelSecondary)
            .lineLimit(1)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, 5)
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
            .overlay(
                Capsule()
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
    }
}

private struct MasteryHealthBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: Double
    let tint: Color

    private let checkpoints: [(value: Double, color: Color)] = [
        (0, StudyDesign.Colors.danger),
        (0.25, StudyDesign.Colors.warning),
        (0.5, StudyDesign.Colors.info),
        (0.75, StudyDesign.Colors.success),
        (1, StudyDesign.Colors.success)
    ]

    private var progress: Double {
        min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let trackHeight: CGFloat = 10

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StudyDesign.Colors.surfaceFillDeep)
                    .frame(height: trackHeight)
                    .frame(maxWidth: .infinity)
                    .position(x: width / 2, y: height / 2)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                StudyDesign.Colors.danger,
                                StudyDesign.Colors.warning,
                                StudyDesign.Colors.info,
                                StudyDesign.Colors.success
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(width * progress, trackHeight), height: trackHeight)
                    .position(x: max(width * progress, trackHeight) / 2, y: height / 2)

                ForEach(checkpoints, id: \.value) { checkpoint in
                    let isActive = checkpoint.value <= progress + 0.001
                    Circle()
                        .fill(isActive ? checkpoint.color : StudyDesign.Colors.cardBackground)
                        .frame(width: isActive ? 11 : 9, height: isActive ? 11 : 9)
                        .overlay(
                            Circle()
                                .stroke(isActive ? checkpoint.color.opacity(0.32) : StudyDesign.Colors.accentHairline.opacity(0.72), lineWidth: 1)
                        )
                        .position(x: max(5, min(width - 5, width * checkpoint.value)), y: height / 2)
                }

                Circle()
                    .fill(tint)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .stroke(StudyDesign.Colors.cardBackground, lineWidth: 2)
                    )
                    .position(x: max(9, min(width - 9, width * progress)), y: height / 2)
                    .animation(reduceMotion ? nil : StudyDesign.Motion.animation(.spring), value: progress)
            }
        }
        .accessibilityHidden(true)
    }
}
