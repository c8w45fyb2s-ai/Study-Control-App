import SwiftUI

private struct AdvancedFeatureHeader: View {
    var title: String
    var subtitle: String
    var icon: String
    var tint: Color
    var metric: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            StudyPageHeader(
                title: title,
                subtitle: subtitle,
                icon: icon,
                tint: StudyDesign.Colors.primary
            )

            Spacer(minLength: StudyDesign.Spacing.tight)

            if let metric {
                Text(metric)
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, StudyDesign.Spacing.normal)
                    .padding(.vertical, StudyDesign.Spacing.tight)
                    .background(Capsule().fill(StudyDesign.Colors.inputBackground))
                    .overlay(Capsule().stroke(tint.opacity(0.42), lineWidth: 1))
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

private struct AdvancedCard<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var icon: String
    var tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                            .stroke(tint.opacity(0.16), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            content
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.46), lineWidth: 1)
        )
    }
}

private struct AdvancedMetricPill: View {
    var title: String
    var value: String
    var icon: String
    var tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(Capsule().fill(StudyDesign.Colors.dataBackground))
        .overlay(Capsule().stroke(tint.opacity(0.14), lineWidth: 1))
    }
}

struct StudyCalendarView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedDayID = DailyActivityRecord.todayString()

    private var days: [StudyCalendarDay] {
        StudyCalendarPlanner.makeDays(snapshot: store.snapshot)
    }

    private var selectedDay: StudyCalendarDay? {
        days.first { $0.id == selectedDayID } ?? days.first { $0.isToday } ?? days.first
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 34), spacing: StudyDesign.Spacing.compact), count: 7)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                AdvancedFeatureHeader(
                    title: "学习日历",
                    subtitle: "把复习任务、完成记录和考试日期放到同一个时间表里。",
                    icon: "calendar",
                    tint: StudyDesign.Colors.primary,
                    metric: "\(days.filter(\.hasWork).count) 天"
                )

                LazyVGrid(columns: columns, spacing: StudyDesign.Spacing.compact) {
                    ForEach(days) { day in
                        Button {
                            selectedDayID = day.id
                        } label: {
                            CalendarDayCell(day: day, isSelected: selectedDayID == day.id)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let selectedDay {
                    CalendarDayDetail(day: selectedDay)
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .navigationTitle("学习日历")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct CalendarDayCell: View {
    var day: StudyCalendarDay
    var isSelected: Bool

    private var tint: Color {
        if !day.examGoals.isEmpty { return StudyDesign.Colors.warning }
        if !day.pendingTasks.isEmpty { return day.pendingTasks.contains { ($0.priority ?? 0) >= 4 } ? StudyDesign.Colors.danger : StudyDesign.Colors.success }
        if day.completedCount > 0 { return StudyDesign.Colors.info }
        return StudyDesign.Colors.labelTertiary
    }

    var body: some View {
        VStack(spacing: StudyDesign.Spacing.micro) {
            Text(day.date.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
            Text(day.date.formatted(.dateTime.day()))
                .font(.headline.weight(.bold))
                .foregroundStyle(isSelected ? tint : StudyDesign.Colors.labelPrimary)

            HStack(spacing: 2) {
                if !day.pendingTasks.isEmpty {
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
                if day.completedCount > 0 {
                    Circle().fill(StudyDesign.Colors.info).frame(width: 5, height: 5)
                }
                if !day.examGoals.isEmpty {
                    Circle().fill(StudyDesign.Colors.warning).frame(width: 5, height: 5)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(isSelected ? tint.opacity(0.10) : StudyDesign.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.35) : StudyDesign.Colors.accentHairline.opacity(0.36), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，\(day.pendingTasks.count) 项待复习，完成 \(day.completedCount) 项")
    }
}

private struct CalendarDayDetail: View {
    @EnvironmentObject private var store: AppStore
    var day: StudyCalendarDay

    var body: some View {
        AdvancedCard(
            title: day.isToday ? "今天安排" : day.date.formatted(date: .abbreviated, time: .omitted),
            subtitle: day.hasWork ? "待复习、已完成和考试节点" : "这一天暂时没有安排",
            icon: day.hasWork ? "list.bullet.clipboard" : "moon.zzz",
            tint: day.hasWork ? StudyDesign.Colors.success : StudyDesign.Colors.labelSecondary
        ) {
            if day.hasWork {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    HStack {
                        AdvancedMetricPill(title: "待复习", value: "\(day.pendingTasks.count)", icon: "calendar.badge.clock", tint: StudyDesign.Colors.success)
                        AdvancedMetricPill(title: "已完成", value: "\(day.completedCount)", icon: "checkmark.seal", tint: StudyDesign.Colors.info)
                        AdvancedMetricPill(title: "考试", value: "\(day.examGoals.count)", icon: "flag.checkered", tint: StudyDesign.Colors.warning)
                    }

                    ForEach(day.examGoals) { goal in
                        CalendarDetailRow(title: goal.name, subtitle: "\(goal.subjectText) · \(goal.countdownText())", icon: "flag.checkered", tint: StudyDesign.Colors.warning)
                    }

                    ForEach(day.pendingTasks.prefix(6)) { task in
                        let isOverdue = task.dueDate < Calendar.current.startOfDay(for: Date())
                        CalendarDetailRow(
                            title: task.title,
                            subtitle: "优先级 \(task.priority ?? 0) · \(task.dueDate.formatted(date: .omitted, time: .shortened))",
                            icon: isOverdue ? "exclamationmark.triangle.fill" : "calendar",
                            tint: isOverdue ? StudyDesign.Colors.danger : StudyDesign.Colors.primary
                        )
                    }

                    if day.pendingTasks.count > 6 {
                        Text("还有 \(day.pendingTasks.count - 6) 项未显示，可到复习计划中处理。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }

                    Button {
                        store.navigateToReviews()
                    } label: {
                        StudyActionPillLabel(title: "打开复习计划", systemImage: "arrow.right")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.success, prominence: .soft, size: .compact))
                }
            } else {
                Text("可以继续导入资料或让 AI 生成新的复习计划。")
                    .font(.footnote)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }
        }
    }
}

private struct CalendarDetailRow: View {
    var title: String
    var subtitle: String
    var icon: String
    var tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.micro))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: StudyDesign.Spacing.tight)
        }
        .padding(StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
    }
}

struct ExamSprintView: View {
    @EnvironmentObject private var store: AppStore

    private var plan: ExamSprintPlan? {
        store.snapshot.nextExamGoal().map { ExamSprintPlan.make(goal: $0, snapshot: store.snapshot) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                AdvancedFeatureHeader(
                    title: "考试冲刺模式",
                    subtitle: "按考试倒计时自动分阶段，把复习密度和薄弱科目放到前面。",
                    icon: "flag.checkered",
                    tint: StudyDesign.Colors.primary,
                    metric: plan.map { $0.daysRemaining >= 0 ? "\($0.daysRemaining) 天" : "已结束" }
                )

                if let plan {
                    SprintPhaseTimeline(currentPhase: plan.phase)

                    AdvancedCard(title: plan.goal.name, subtitle: "\(plan.goal.subjectText) · \(plan.capacityText)", icon: plan.phase.icon, tint: StudyDesign.Colors.warning) {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                            Text(plan.phase.summary)
                                .font(.footnote)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)

                            HStack {
                                AdvancedMetricPill(title: "本周任务", value: "\(plan.dueThisWeekCount)", icon: "calendar.badge.clock", tint: StudyDesign.Colors.success)
                                AdvancedMetricPill(title: "逾期", value: "\(plan.overdueTaskCount)", icon: "exclamationmark.triangle", tint: plan.overdueTaskCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelSecondary)
                            }

                            if !plan.weakSubjects.isEmpty {
                                Text("优先科目：\(plan.weakSubjects.joined(separator: "、"))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                            }
                        }
                    }

                    AdvancedCard(title: "今日冲刺动作", subtitle: "把建议压缩成可执行动作", icon: "checklist", tint: StudyDesign.Colors.success) {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                            ForEach(Array(plan.recommendedActions.enumerated()), id: \.offset) { index, action in
                                CalendarDetailRow(title: "动作 \(index + 1)", subtitle: action, icon: "checkmark.circle.fill", tint: StudyDesign.Colors.success)
                            }

                            HStack {
                                Button {
                                    store.navigateToReviews()
                                } label: {
                                    StudyActionPillLabel(title: "开始复习", systemImage: "play.fill")
                                }
                                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))

                                Button {
                                    store.navigateToExamGoals()
                                } label: {
                                    StudyActionPillLabel(title: "调整目标", systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.warning, prominence: .soft, size: .compact))
                            }
                        }
                    }
                } else {
                    StudyEmptyState(title: "还没有考试目标", subtitle: "设置考试名称、日期、科目和每日可用时间后，这里会生成冲刺阶段和动作建议。", icon: "flag.checkered", accentIcon: "calendar.badge.plus", accentTint: StudyDesign.Colors.warning, actionLabel: "设置考试目标") {
                        store.navigateToExamGoals()
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .navigationTitle("考试冲刺")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct SprintPhaseTimeline: View {
    var currentPhase: ExamSprintPhase

    var body: some View {
        AdvancedCard(title: "冲刺阶段", subtitle: "根据剩余天数自动定位", icon: "point.3.connected.trianglepath.dotted", tint: StudyDesign.Colors.info) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                ForEach(ExamSprintPhase.allCases.filter { $0 != .finished }) { phase in
                    VStack(spacing: StudyDesign.Spacing.compact) {
                        Image(systemName: phase.icon)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(phase == currentPhase ? .white : StudyDesign.Colors.labelSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(phase == currentPhase ? StudyDesign.Colors.primary : StudyDesign.Colors.dataBackground))
                        Text(phase.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(phase == currentPhase ? StudyDesign.Colors.labelPrimary : StudyDesign.Colors.labelSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct KnowledgeGraphView: View {
    @EnvironmentObject private var store: AppStore

    private var graph: KnowledgeGraph {
        KnowledgeGraph.make(from: store.snapshot)
    }

    private var groupedNodes: [(KnowledgeGraphNodeKind, [KnowledgeGraphNode])] {
        KnowledgeGraphNodeKind.allCasesForDisplay.compactMap { kind in
            let nodes = graph.nodes.filter { $0.kind == kind }
            return nodes.isEmpty ? nil : (kind, nodes)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                AdvancedFeatureHeader(
                    title: "知识图谱",
                    subtitle: "把科目、知识点、错题和资料来源连起来，找到真正薄弱的连接点。",
                    icon: "point.3.connected.trianglepath.dotted",
                    tint: StudyDesign.Colors.primary,
                    metric: "\(graph.nodes.count) 节点"
                )

                if graph.nodes.isEmpty {
                    StudyEmptyState(title: "还没有图谱数据", subtitle: "确认资料分析草稿后，知识点和错题会自动形成关联图谱。", icon: "point.3.connected.trianglepath.dotted", accentIcon: "sparkles", accentTint: StudyDesign.Colors.info, actionLabel: "去导入资料") {
                        store.navigateToImport()
                    }
                } else {
                    HStack {
                        AdvancedMetricPill(title: "科目", value: "\(graph.subjectCount)", icon: "books.vertical.fill", tint: StudyDesign.Colors.warning)
                        AdvancedMetricPill(title: "连接", value: "\(graph.edges.count)", icon: "link", tint: StudyDesign.Colors.info)
                        AdvancedMetricPill(title: "薄弱", value: "\(graph.weakNodeCount)", icon: "target", tint: StudyDesign.Colors.danger)
                    }

                    ForEach(groupedNodes, id: \.0.rawValue) { kind, nodes in
                        AdvancedCard(title: kind.rawValue, subtitle: "\(nodes.count) 个节点", icon: icon(for: kind), tint: tint(for: kind)) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
                                ForEach(nodes.prefix(12)) { node in
                                    KnowledgeNodeCard(node: node, tint: tint(for: node.kind))
                                }
                            }
                            if nodes.count > 12 {
                                Text("还有 \(nodes.count - 12) 个节点，可通过搜索知识点和错题继续查看。")
                                    .font(.caption)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            }
                        }
                    }

                    AdvancedCard(title: "关键连接", subtitle: "优先处理错题密集的知识点", icon: "link.badge.plus", tint: StudyDesign.Colors.success) {
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                            ForEach(graph.edges.prefix(8)) { edge in
                                CalendarDetailRow(title: edge.label, subtitle: edgeDescription(edge), icon: "arrow.right", tint: StudyDesign.Colors.success)
                            }
                        }
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .navigationTitle("知识图谱")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private func edgeDescription(_ edge: KnowledgeGraphEdge) -> String {
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.title) })
        return "\(nodes[edge.from] ?? edge.from) → \(nodes[edge.to] ?? edge.to)"
    }

    private func icon(for kind: KnowledgeGraphNodeKind) -> String {
        switch kind {
        case .subject: return "books.vertical.fill"
        case .knowledge: return "lightbulb.fill"
        case .mistake: return "xmark.circle.fill"
        case .document: return "doc.text.fill"
        }
    }

    private func tint(for kind: KnowledgeGraphNodeKind) -> Color {
        switch kind {
        case .subject: return StudyDesign.Colors.warning
        case .knowledge: return StudyDesign.Colors.success
        case .mistake: return StudyDesign.Colors.danger
        case .document: return StudyDesign.Colors.info
        }
    }
}

private extension KnowledgeGraphNodeKind {
    static var allCasesForDisplay: [KnowledgeGraphNodeKind] {
        [.subject, .knowledge, .mistake, .document]
    }
}

private struct KnowledgeNodeCard: View {
    var node: KnowledgeGraphNode
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack {
                Text(node.kind.rawValue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                Spacer()
                Text("权重 \(node.weight)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }
            Text(node.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(node.subtitle)
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .lineLimit(2)
            if let mastery = node.mastery {
                ProgressView(value: min(max(mastery, 0), 1))
                    .tint(tint)
            }
        }
        .padding(StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

struct DocumentSectionsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var sections: [DocumentSection] {
        let all = DocumentSectionExtractor.extractAll(from: store.snapshot)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.documentTitle.localizedCaseInsensitiveContains(query)
                || $0.excerpt.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                AdvancedFeatureHeader(
                    title: "资料章节",
                    subtitle: "自动从 Markdown 标题、章节编号、页码标记或长文本片段中建立资料索引。",
                    icon: "doc.text.magnifyingglass",
                    tint: StudyDesign.Colors.primary,
                    metric: "\(sections.count) 段"
                )

                TextField("搜索章节、资料或片段", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .padding(StudyDesign.Spacing.normal)
                    .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .stroke(
                                isSearchFocused ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                                lineWidth: isSearchFocused ? 2 : 1
                            )
                    )
                    .accessibilityLabel("搜索资料章节")
                    .accessibilityHint("输入章节标题、资料名或片段关键词")

                if store.snapshot.documents.isEmpty {
                    StudyEmptyState(title: "还没有资料", subtitle: "导入 PDF、图片、Word、PPT 或文本后，这里会建立章节索引。", icon: "doc.badge.plus", accentIcon: "tray.fill", accentTint: StudyDesign.Colors.secondary, actionLabel: "导入资料") {
                        store.navigateToImport()
                    }
                } else if sections.isEmpty {
                    StudyEmptyState(title: "没有匹配章节", subtitle: "换一个关键词试试。", icon: "magnifyingglass", accentIcon: "questionmark", actionLabel: "清空搜索") {
                        searchText = ""
                    }
                } else {
                    ForEach(Dictionary(grouping: sections, by: \.documentTitle).keys.sorted(), id: \.self) { title in
                        let documentSections = sections.filter { $0.documentTitle == title }
                        AdvancedCard(title: title, subtitle: "\(documentSections.count) 个章节/片段", icon: "doc.text.fill", tint: StudyDesign.Colors.secondary) {
                            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                                ForEach(documentSections.prefix(8)) { section in
                                    CalendarDetailRow(
                                        title: "\(section.ordinal). \(section.title)",
                                        subtitle: section.excerpt,
                                        icon: section.level <= 2 ? "text.book.closed.fill" : "text.alignleft",
                                        tint: StudyDesign.Colors.secondary
                                    )
                                }
                                if documentSections.count > 8 {
                                    Text("还有 \(documentSections.count - 8) 个片段，可搜索标题或内容定位。")
                                        .font(.caption)
                                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .navigationTitle("资料章节")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct StudyReportActivityMetric: Identifiable {
    var id: String { title }
    var title: String
    var value: String
    var icon: String
    var tint: Color
}

private struct StudyReportActivityMetricTile: View {
    var metric: StudyReportActivityMetric

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.compact) {
            Image(systemName: metric.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(metric.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(metric.title)
                    .font(.callout)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metric.value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(StudyDesign.Spacing.normal)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                .stroke(metric.tint.opacity(0.16), lineWidth: 1)
        )
    }
}

struct StudyReportInsightsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: StudyReportPeriod = .week

    private var report: StudyProgressReport {
        StudyProgressReport.make(from: store.snapshot, period: period)
    }

    private var activityReport: StudyActivityReport {
        store.activityReport(period: period, now: Date())
    }

    private var activityMetrics: [StudyReportActivityMetric] {
        [
            StudyReportActivityMetric(title: "学习次数", value: "\(activityReport.studyCount) 次", icon: "books.vertical", tint: StudyDesign.Colors.info),
            StudyReportActivityMetric(
                title: "已记录学习时长",
                value: activityReport.recordedMinutes.map { "\($0) 分钟" } ?? "未知",
                icon: "clock",
                tint: StudyDesign.Colors.success
            ),
            StudyReportActivityMetric(title: "有记录日数", value: "\(activityReport.studyDayCount) 天", icon: "calendar", tint: StudyDesign.Colors.secondary),
            StudyReportActivityMetric(title: "标准完成", value: "\(activityReport.standardCompletedCount) 项", icon: "checkmark.seal", tint: StudyDesign.Colors.success),
            StudyReportActivityMetric(title: "保底完成", value: "\(activityReport.minimumCompletedCount) 项", icon: "shield.lefthalf.filled", tint: StudyDesign.Colors.warning)
        ]
    }

    @ViewBuilder
    private var activityMetricGrid: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                ForEach(activityMetrics) { metric in
                    StudyReportActivityMetricTile(metric: metric)
                }
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 176), alignment: .leading)],
                alignment: .leading,
                spacing: StudyDesign.Spacing.tight
            ) {
                ForEach(activityMetrics) { metric in
                    StudyReportActivityMetricTile(metric: metric)
                }
            }
        }
    }

    private var forecast: StudyReportForecast {
        StudyReportForecast.make(from: store.snapshot)
    }

    private var loadBalancePlan: StudyLoadBalancePlan {
        StudyLoadBalancer.make(from: store.snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                let balancePlan = loadBalancePlan

                AdvancedFeatureHeader(
                    title: "学习报告增强",
                    subtitle: "在原有周/月报告基础上补充负荷预测、遗忘风险和下一步建议。",
                    icon: "chart.line.uptrend.xyaxis",
                    tint: StudyDesign.Colors.primary,
                    metric: "\(report.completionRatePercent)%"
                )

                Picker("周期", selection: $period) {
                    ForEach(StudyReportPeriod.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                AdvancedCard(
                    title: "学习量统计",
                    subtitle: "最近 \(activityReport.periodDays) 天 · 未记录时长只计学习次数，旧版汇总不推算时长",
                    icon: "timer",
                    tint: StudyDesign.Colors.success
                ) {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                        activityMetricGrid

                        Text("标准完成与保底完成按项数互斥统计；仅学习未达标 \(activityReport.studiedOnlyCount) 项。")
                            .font(.callout)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if activityReport.unrecordedDurationCount > 0 {
                            Text("另有 \(activityReport.unrecordedDurationCount) 项完成未记录时长；这些记录计入学习次数，不计入分钟数。")
                                .font(.callout)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if activityReport.legacyAggregateTaskCount > 0 {
                            Text("另有旧版汇总 \(activityReport.legacyAggregateTaskCount) 项，分布在 \(activityReport.legacyAggregateDayCount) 天；只保留原始项数，不推算学习次数、时长或达标项数。")
                                .font(.callout)
                                .foregroundStyle(StudyDesign.Colors.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if activityReport.isEmpty {
                            Text("当前周期没有可统计的完成事件或历史汇总。")
                                .font(.callout)
                                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                AdvancedCard(title: forecast.workloadTitle, subtitle: forecast.workloadDetail, icon: "speedometer", tint: forecast.overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.info) {
                    HStack {
                        AdvancedMetricPill(title: "待复习", value: "\(forecast.pendingCount)", icon: "tray.full", tint: StudyDesign.Colors.success)
                        AdvancedMetricPill(title: "风险", value: "\(forecast.retentionRiskCount)", icon: "brain.head.profile", tint: StudyDesign.Colors.warning)
                        AdvancedMetricPill(title: "预计", value: "\(forecast.projectedClearDays) 天", icon: "calendar", tint: StudyDesign.Colors.info)
                    }
                }

                AdvancedCard(
                    title: "智能负荷平衡",
                    subtitle: balancePlan.statusDetail,
                    icon: "scalemass.fill",
                    tint: balancePlan.overloadedDayCount > 0 ? StudyDesign.Colors.warning : StudyDesign.Colors.info
                ) {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                        HStack {
                            AdvancedMetricPill(title: "超载", value: "\(balancePlan.overloadedDayCount) 天", icon: "exclamationmark.triangle", tint: balancePlan.overloadedDayCount > 0 ? StudyDesign.Colors.warning : StudyDesign.Colors.success)
                            AdvancedMetricPill(title: "可顺延", value: "\(balancePlan.suggestedMoveCount)", icon: "arrow.right.to.line", tint: StudyDesign.Colors.info)
                            AdvancedMetricPill(title: "日容量", value: "\(balancePlan.dailyCapacityMinutes) 分", icon: "timer", tint: StudyDesign.Colors.secondary)
                        }

                        ForEach(balancePlan.recommendations) { recommendation in
                            CalendarDetailRow(
                                title: recommendation.title,
                                subtitle: recommendation.detail,
                                icon: recommendation.icon,
                                tint: recommendation.kind == .stable ? StudyDesign.Colors.success : StudyDesign.Colors.info
                            )
                        }

                        if !balancePlan.moveProposals.isEmpty {
                            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                                Text("建议顺延")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)

                                ForEach(balancePlan.moveProposals.prefix(4)) { proposal in
                                    CalendarDetailRow(
                                        title: proposal.taskTitle,
                                        subtitle: "\(proposal.reason) · 预计 \(proposal.estimatedMinutes) 分钟",
                                        icon: "arrow.right.to.line",
                                        tint: StudyDesign.Colors.warning
                                    )
                                }
                            }
                        }

                        if !balancePlan.compressedSessionItems.isEmpty {
                            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                                Text("30 分钟压缩版")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)

                                ForEach(balancePlan.compressedSessionItems.prefix(4)) { item in
                                    CalendarDetailRow(
                                        title: item.title,
                                        subtitle: "\(item.reason) · 预计 \(item.estimatedMinutes) 分钟",
                                        icon: "checkmark.circle.fill",
                                        tint: StudyDesign.Colors.success
                                    )
                                }
                            }
                        }

                        if balancePlan.canApply {
                            Button {
                                store.applySmartLoadBalancing()
                            } label: {
                                StudyActionPillLabel(title: "一键平衡负荷", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.warning, prominence: .secondary, minWidth: 148))
                            .help("顺延低优先级任务")
                            .accessibilityHint("自动把可移动任务顺延到负荷较低的日期")
                        }
                    }
                }

                AdvancedCard(title: report.period.detailTitle, subtitle: report.summarySentence, icon: "chart.bar.doc.horizontal", tint: StudyDesign.Colors.info) {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                        HStack {
                            AdvancedMetricPill(title: "完成", value: "\(report.completedCount)", icon: "checkmark.seal", tint: StudyDesign.Colors.success)
                            AdvancedMetricPill(title: "未完成", value: "\(report.dueUnfinishedCount)", icon: "clock", tint: StudyDesign.Colors.warning)
                            AdvancedMetricPill(title: "逾期", value: "\(report.overdueTaskCount)", icon: "exclamationmark.triangle", tint: report.overdueTaskCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelSecondary)
                        }

                        if !report.nextSuggestions.isEmpty {
                            ForEach(report.nextSuggestions) { suggestion in
                                CalendarDetailRow(title: suggestion.title, subtitle: suggestion.reason, icon: suggestion.icon, tint: StudyDesign.Colors.info)
                            }
                        }
                    }
                }

                AdvancedCard(title: "薄弱与错因", subtitle: "从知识点掌握度和错题错因中自动聚合", icon: "target", tint: StudyDesign.Colors.danger) {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                        if report.weakSubjects.isEmpty && report.repeatedErrorPatterns.isEmpty {
                            Text("暂时没有足够数据。完成几次复习、补充错因后，这里会出现更具体的诊断。")
                                .font(.footnote)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }

                        ForEach(report.weakSubjects) { subject in
                            CalendarDetailRow(
                                title: subject.subject,
                                subtitle: "\(subject.weakKnowledgeCount) 个薄弱知识点 · 平均掌握 \(Int((subject.averageMastery * 100).rounded()))%",
                                icon: "books.vertical.fill",
                                tint: StudyDesign.Colors.warning
                            )
                        }

                        ForEach(report.repeatedErrorPatterns) { pattern in
                            CalendarDetailRow(
                                title: pattern.type,
                                subtitle: "\(pattern.count) 次 · \(pattern.examples.joined(separator: "、"))",
                                icon: "exclamationmark.triangle.fill",
                                tint: StudyDesign.Colors.danger
                            )
                        }
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .navigationTitle("学习报告")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
