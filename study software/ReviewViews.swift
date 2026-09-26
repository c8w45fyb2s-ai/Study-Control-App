import SwiftUI

private extension View {
    func reviewMetaPill(tint: Color = StudyDesign.Colors.info) -> some View {
        self.studyMetaPill(tint: tint)
    }
}

private enum ReviewQueueGroup: Int, CaseIterable, Identifiable {
    case overdue
    case today
    case later

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: return "逾期"
        case .today: return "今天"
        case .later: return "之后"
        }
    }

    var subtitle: String {
        switch self {
        case .overdue: return "优先处理已错过计划日期的任务"
        case .today: return "今天计划完成的任务"
        case .later: return "已经安排到后续日期的任务"
        }
    }

    var icon: String {
        switch self {
        case .overdue: return "exclamationmark.triangle.fill"
        case .today: return "sun.max.fill"
        case .later: return "calendar"
        }
    }

    var tint: Color {
        switch self {
        case .overdue: return StudyDesign.Colors.danger
        case .today: return StudyDesign.Colors.warning
        case .later: return StudyDesign.Colors.info
        }
    }
}

private struct ReviewQueueSection: Identifiable {
    let group: ReviewQueueGroup
    let tasks: [ReviewTask]

    var id: ReviewQueueGroup { group }
}

private struct ReviewLoadBalanceUndo {
    let originalTasks: [ReviewTask]
}

struct ReviewsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var selectedSubject = allSubjectsTitle
    @State private var sort: ReviewSort = .dueSoon
    @State private var balanceFeedback: String?
    @State private var loadBalanceUndo: ReviewLoadBalanceUndo?
    @State private var showingCardEditor = false

    private var subjectOptions: [String] {
        let allSubjects = store.snapshot.reviewTasks
            .filter { $0.status == .pending }
            .flatMap { subjects(for: $0) }
        return [allSubjectsTitle] + Array(Set(allSubjects))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var pendingTasks: [ReviewTask] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.snapshot.reviewTasks
            .filter { $0.status == .pending }
            .filter { task in
                let taskSubjects = subjects(for: task)
                let matchesSubject = selectedSubject == allSubjectsTitle || taskSubjects.contains(selectedSubject)
                let matchesSearch = query.isEmpty ||
                    task.title.localizedCaseInsensitiveContains(query) ||
                    task.status.rawValue.localizedCaseInsensitiveContains(query) ||
                    taskSubjects.contains { $0.localizedCaseInsensitiveContains(query) }
                return matchesSubject && matchesSearch
            }

        return filtered.sorted { lhs, rhs in
            switch sort {
            case .dueSoon:
                return lhs.dueDate < rhs.dueDate
            case .priority:
                if (lhs.priority ?? 0) != (rhs.priority ?? 0) {
                    return (lhs.priority ?? 0) > (rhs.priority ?? 0)
                }
                return lhs.dueDate < rhs.dueDate
            case .dueLatest:
                return lhs.dueDate > rhs.dueDate
            }
        }
    }

    private var pendingTaskIDs: [UUID] {
        pendingTasks.map(\.id)
    }

    private var pendingTaskSections: [ReviewQueueSection] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        return ReviewQueueGroup.allCases.compactMap { group in
            let tasks = pendingTasks.filter { task in
                switch group {
                case .overdue:
                    return task.dueDate < startOfToday
                case .today:
                    return calendar.isDateInToday(task.dueDate)
                case .later:
                    return task.dueDate >= (calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday)
                }
            }
            return tasks.isEmpty ? nil : ReviewQueueSection(group: group, tasks: tasks)
        }
    }

    private var isFilteringQueue: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedSubject != allSubjectsTitle
            || sort != .dueSoon
    }

    private var totalPendingCount: Int {
        store.snapshot.reviewTasks.filter { $0.status == .pending }.count
    }

    private var overdueCount: Int {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return store.snapshot.reviewTasks.filter { task in
            task.status == .pending && task.dueDate < startOfToday
        }.count
    }

    private var dueTodayCount: Int {
        let calendar = Calendar.current
        return store.snapshot.reviewTasks.filter { task in
            task.status == .pending && calendar.isDateInToday(task.dueDate)
        }.count
    }

    private var highPriorityCount: Int {
        store.snapshot.reviewTasks.filter { task in
            task.status == .pending && (task.priority ?? 0) >= 4
        }.count
    }

    private var loadBalancePlan: StudyLoadBalancePlan {
        StudyLoadBalancer.make(from: store.snapshot)
    }

    private func subjects(for task: ReviewTask) -> [String] {
        if let knowledgePointID = task.knowledgePointID,
           let point = store.snapshot.knowledgePoints.first(where: { $0.id == knowledgePointID }) {
            let subject = point.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            if !subject.isEmpty {
                return [subject]
            }
        }

        if let mistakeID = task.mistakeID,
           let mistake = store.snapshot.mistakes.first(where: { $0.id == mistakeID }) {
            let subjects = mistake.knowledgePointIDs.compactMap { id in
                store.snapshot.knowledgePoints.first { $0.id == id }?.subject
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            if !subjects.isEmpty {
                return Array(Set(subjects))
            }
        }

        return [uncategorizedSubjectTitle]
    }

    private func resetQueueFilters() {
        withAnimation(StudyDesign.Motion.animation(.fast)) {
            searchText = ""
            selectedSubject = allSubjectsTitle
            sort = .dueSoon
        }
    }

    private func applyLoadBalance(_ plan: StudyLoadBalancePlan) {
        let proposalIDs = Set(plan.moveProposals.map(\.taskID))
        let originalTasks = store.snapshot.reviewTasks.filter { proposalIDs.contains($0.id) }
        let result = store.applySmartLoadBalancing()

        guard !result.movedTaskIDs.isEmpty else {
            balanceFeedback = result.summary
            loadBalanceUndo = nil
            return
        }

        let movedIDs = Set(result.movedTaskIDs)
        loadBalanceUndo = ReviewLoadBalanceUndo(
            originalTasks: originalTasks.filter { movedIDs.contains($0.id) }
        )
        balanceFeedback = "\(result.summary)。如有需要，可以撤销本次调整。"
    }

    private func undoLoadBalance() {
        guard let undo = loadBalanceUndo else { return }

        for originalTask in undo.originalTasks {
            guard let currentTask = store.snapshot.reviewTasks.first(where: { $0.id == originalTask.id }) else { continue }
            store.updateReviewTask(
                currentTask,
                title: originalTask.title,
                dueDate: originalTask.dueDate,
                priority: originalTask.priority
            )
        }

        balanceFeedback = "已撤销本次负荷平衡，\(undo.originalTasks.count) 个任务已恢复到原日期。"
        loadBalanceUndo = nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                let balancePlan = loadBalancePlan

                ReviewPlanHeader(
                    pendingCount: totalPendingCount,
                    visibleCount: pendingTasks.count,
                    overdueCount: overdueCount,
                    dueTodayCount: dueTodayCount,
                    highPriorityCount: highPriorityCount
                )

                if balancePlan.totalPendingCount > 0 && (balancePlan.overloadedDayCount > 0 || balancePlan.canApply) {
                    SmartLoadBalanceCard(plan: balancePlan) {
                        applyLoadBalance(balancePlan)
                    }
                }

                if let balanceFeedback {
                    ReviewLoadBalanceFeedbackBanner(
                        message: balanceFeedback,
                        canUndo: loadBalanceUndo != nil,
                        onUndo: undoLoadBalance,
                        onDismiss: {
                            self.balanceFeedback = nil
                            loadBalanceUndo = nil
                        }
                    )
                }

                if totalPendingCount > 3 || isFilteringQueue {
                    ReviewPlanToolPanel(
                        searchText: $searchText,
                        selectedSubject: $selectedSubject,
                        subjectOptions: subjectOptions,
                        sort: $sort,
                        isFiltering: isFilteringQueue,
                        onResetFilters: resetQueueFilters
                    )
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                        Text("待复习队列")
                            .font(.headline.weight(.semibold))
                        Text("显示 \(pendingTasks.count) / \(totalPendingCount) 个任务")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }

                    Spacer()

                    Button("新建卡片") { showingCardEditor = true }
                        .buttonStyle(.bordered)

                    if isFilteringQueue {
                        Text("已调整")
                            .reviewMetaPill(tint: StudyDesign.Colors.secondary)
                    }
                }
                .padding(.top, StudyDesign.Spacing.tight)

                ForEach(pendingTaskSections) { section in
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                        ReviewQueueSectionHeader(section: section)

                        ForEach(section.tasks) { task in
                            ReviewTaskRow(task: task)
                        }
                    }
                }
                .animation(nil, value: pendingTaskIDs)
                if store.snapshot.reviewTasks.filter({ $0.status == .pending }).isEmpty {
                    StudyEmptyState(title: "没有待复习任务", subtitle: "点击完成后的任务会移到过往任务。", icon: "checkmark.circle.fill", accentIcon: "calendar", accentTint: StudyDesign.Colors.success, actionLabel: "去确认草稿") {
                        store.navigateToDrafts()
                    }
                } else if pendingTasks.isEmpty {
                    StudyEmptyState(title: "没有匹配的复习任务", subtitle: "换一个关键词、科目或排序方式试试。", icon: "magnifyingglass", accentIcon: "questionmark", actionLabel: "重置筛选") {
                        resetQueueFilters()
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .sheet(isPresented: $showingCardEditor) {
            StudyCardEditor(existing: nil).environmentObject(store)
        }
    }
}

private struct SmartLoadBalanceCard: View {
    let plan: StudyLoadBalancePlan
    let onApply: () -> Void
    @State private var isShowingPreview = false

    private var tint: Color {
        plan.overloadedDayCount > 0 ? StudyDesign.Colors.warning : StudyDesign.Colors.info
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.normal) {
                balanceSummary
                Spacer(minLength: StudyDesign.Spacing.tight)
                balanceStats
                previewButton
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                balanceSummary
                HStack(spacing: StudyDesign.Spacing.tight) {
                    balanceStats
                    Spacer(minLength: StudyDesign.Spacing.tight)
                    previewButton
                }
            }
        }
        .padding(StudyDesign.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(tint.opacity(0.42), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isShowingPreview) {
            ReviewLoadBalancePreview(plan: plan, onConfirm: onApply)
        }
    }

    private var balanceSummary: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: "scalemass.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text("智能负荷平衡")
                    .font(.subheadline.weight(.semibold))
                Text(plan.statusDetail)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)
            }
        }
        .layoutPriority(1)
    }

    private var balanceStats: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            ReviewPlanStatChip(title: "超载", value: plan.overloadedDayCount, icon: "exclamationmark.triangle.fill", tint: tint)
            ReviewPlanStatChip(title: "顺延", value: plan.suggestedMoveCount, icon: "arrow.right.to.line", tint: StudyDesign.Colors.info)
        }
    }

    @ViewBuilder
    private var previewButton: some View {
        if plan.canApply {
            Button {
                isShowingPreview = true
            } label: {
                StudyActionPillLabel(title: "预览调整", systemImage: "list.bullet.clipboard")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: tint, prominence: .secondary, size: .compact, minWidth: 104))
            .help("预览任务的新日期")
            .accessibilityLabel("预览负荷平衡调整")
            .accessibilityHint("查看将受影响的任务和调整后的日期，确认后才会应用")
        }
    }
}

private struct ReviewLoadBalancePreview: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let plan: StudyLoadBalancePlan
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text("确认负荷调整")
                    .font(.title2.weight(.semibold))
                Text("以下 \(plan.moveProposals.count) 个低优先级任务会改期。完成后仍可在复习页撤销。")
                    .font(.subheadline)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    store.snapshot.settings.remindersEnabled
                        ? "已开启提醒的任务会按新日期与默认提醒时间重新排程；未开启提醒的任务保持不变。"
                        : "全局复习提醒当前关闭；调整日期不会自动开启提醒。",
                    systemImage: store.snapshot.settings.remindersEnabled ? "bell.badge" : "bell.slash"
                )
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    ForEach(plan.moveProposals) { proposal in
                        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                            Image(systemName: "calendar.badge.clock")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(StudyDesign.Colors.info)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                                Text(proposal.taskTitle)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                                Text("\(proposal.fromDate.formatted(date: .abbreviated, time: .omitted)) → \(proposal.toDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                Text(proposal.reason)
                                    .font(.caption)
                                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: StudyDesign.Spacing.tight)

                            Text("\(proposal.estimatedMinutes) 分")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }
                        .padding(StudyDesign.Spacing.tight)
                        .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(proposal.taskTitle)，从 \(proposal.fromDate.formatted(date: .abbreviated, time: .omitted)) 调整到 \(proposal.toDate.formatted(date: .abbreviated, time: .omitted))，预计 \(proposal.estimatedMinutes) 分钟。\(proposal.reason)")
                    }
                }
            }

            HStack {
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Label("确认调整", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("应用预览中的日期调整；应用后可撤销")
            }
        }
        .padding(StudyDesign.Spacing.wide)
#if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 520)
#endif
    }
}

private struct ReviewLoadBalanceFeedbackBanner: View {
    let message: String
    let canUndo: Bool
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: canUndo ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(canUndo ? StudyDesign.Colors.info : StudyDesign.Colors.success)

            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: StudyDesign.Spacing.tight)

            if canUndo {
                Button("撤销", action: onUndo)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("恢复本次负荷平衡前的任务日期")
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .iOSTouchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭负荷平衡反馈")
        }
        .padding(StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct ReviewQueueSectionHeader: View {
    let section: ReviewQueueSection

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: section.group.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(section.group.tint)
            Text(section.group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
            Text("\(section.tasks.count)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .padding(.horizontal, StudyDesign.Spacing.compact)
                .padding(.vertical, 3)
                .background(StudyDesign.Colors.inputBackground, in: Capsule())
            Text(section.group.subtitle)
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.top, StudyDesign.Spacing.compact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.group.title)，\(section.tasks.count) 个任务。\(section.group.subtitle)")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ReviewPlanHeader: View {
    let pendingCount: Int
    let visibleCount: Int
    let overdueCount: Int
    let dueTodayCount: Int
    let highPriorityCount: Int

    private var statusTitle: String {
        if overdueCount > 0 {
            return "\(overdueCount) 项需要先处理"
        }
        if dueTodayCount > 0 {
            return "今天有 \(dueTodayCount) 项复习"
        }
        return "复习节奏稳定"
    }

    private var statusSubtitle: String {
        if pendingCount == 0 {
            return "当前没有待复习任务，可以去确认新草稿。"
        }
        if visibleCount < pendingCount {
            return "已按当前条件筛出 \(visibleCount) 项，完整队列共 \(pendingCount) 项。"
        }
        return "按到期时间、优先级和提醒状态整理你的复习队列。"
    }

    private var statusTint: Color {
        if overdueCount > 0 {
            return StudyDesign.Colors.danger
        }
        if dueTodayCount > 0 {
            return StudyDesign.Colors.warning
        }
        return StudyDesign.Colors.success
    }

    var body: some View {
#if os(iOS)
        iOSHeader
#else
        desktopHeader
#endif
    }

#if os(iOS)
    private var iOSHeader: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
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
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .stroke(StudyDesign.Colors.warning.opacity(0.16), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("复习工作台")
                        .font(StudyDesign.Typography.pageTitle)
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelPrimary)
                    Text(statusSubtitle)
                        .font(.footnote)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                VStack(alignment: .trailing, spacing: StudyDesign.Spacing.micro) {
                    Text("\(pendingCount)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("待复习")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
            }

            if overdueCount > 0 || dueTodayCount > 0 || highPriorityCount > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: StudyDesign.Spacing.tight) {
                        if overdueCount > 0 {
                            ReviewPlanCompactPill(title: "已过期", value: overdueCount, icon: "exclamationmark.triangle.fill", tint: StudyDesign.Colors.danger)
                        }
                        if dueTodayCount > 0 {
                            ReviewPlanCompactPill(title: "今日", value: dueTodayCount, icon: "calendar.badge.clock", tint: StudyDesign.Colors.info)
                        }
                        if highPriorityCount > 0 {
                            ReviewPlanCompactPill(title: "高优先", value: highPriorityCount, icon: "bolt.fill", tint: StudyDesign.Colors.warning)
                        }
                    }

                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                        if overdueCount > 0 {
                            ReviewPlanCompactPill(title: "已过期", value: overdueCount, icon: "exclamationmark.triangle.fill", tint: StudyDesign.Colors.danger)
                        }
                        if dueTodayCount > 0 {
                            ReviewPlanCompactPill(title: "今日", value: dueTodayCount, icon: "calendar.badge.clock", tint: StudyDesign.Colors.info)
                        }
                        if highPriorityCount > 0 {
                            ReviewPlanCompactPill(title: "高优先", value: highPriorityCount, icon: "bolt.fill", tint: StudyDesign.Colors.warning)
                        }
                    }
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
                    .fill(statusTint.opacity(0.40))
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.normal)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
#endif

    private var desktopHeader: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            StudyPageHeader(
                title: "复习工作台",
                subtitle: "\(statusTitle) · \(statusSubtitle)",
                icon: "calendar.badge.clock"
            )

            HStack(alignment: .center, spacing: StudyDesign.Spacing.compact) {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    ReviewPlanStatChip(title: "逾期", value: overdueCount, icon: "exclamationmark.triangle.fill", tint: StudyDesign.Colors.danger)
                    ReviewPlanStatChip(title: "今天", value: dueTodayCount, icon: "calendar.badge.clock", tint: StudyDesign.Colors.info)
                    ReviewPlanStatChip(title: "高优先", value: highPriorityCount, icon: "bolt.fill", tint: StudyDesign.Colors.warning)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.compact) {
                    Text("\(pendingCount)")
                        .font(StudyDesign.Typography.metric)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("待复习")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
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
                    .fill(StudyDesign.Colors.primary)
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.tight)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

#if os(iOS)
private struct ReviewPlanCompactPill: View {
    let title: String
    let value: Int
    let icon: String
    let tint: Color

    var body: some View {
        Label {
            Text("\(title) \(value)")
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(StudyDesign.Colors.labelSecondary)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, 6)
        .background(StudyDesign.Colors.inputBackground, in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.10), lineWidth: 1))
        .accessibilityLabel("\(title)：\(value)")
    }
}

#endif

private struct ReviewPlanStatChip: View {
    let title: String
    let value: Int
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            Text("\(value)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            Capsule()
                .fill(StudyDesign.Colors.inputBackground)
        )
        .overlay(Capsule().stroke(StudyDesign.Colors.accentHairline, lineWidth: 1))
    }
}

private struct ReviewPlanToolPanel: View {
    @State private var isExpanded = false
    @Binding var searchText: String
    @Binding var selectedSubject: String
    let subjectOptions: [String]
    @Binding var sort: ReviewSort
    let isFiltering: Bool
    let onResetFilters: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Button {
                withAnimation(StudyDesign.Motion.animation(.fast)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    Label(isFiltering ? "搜索与筛选已启用" : "搜索与筛选", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)

                    Spacer()

                    Text(sort.rawValue)
                        .font(.caption.weight(.semibold))
                        .reviewMetaPill(tint: StudyDesign.Colors.secondary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .frame(width: 24, height: 24)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起搜索与筛选" : "展开搜索与筛选")
            .accessibilityHint("搜索、科目和排序会影响当前复习队列")

            if isExpanded || isFiltering {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    StudyInlineSearchField(text: $searchText, prompt: "搜索复习任务或科目")

                    ListFilterControls(
                        selectedSubject: $selectedSubject,
                        subjects: subjectOptions,
                        sort: $sort
                    )

                    if isFiltering {
                        StudyFilterResetButton(title: "重置") {
                            onResetFilters()
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
    }
}

struct PastTasksView: View {
    @EnvironmentObject private var store: AppStore

    /// Tasks that have been reviewed at least once. Sorted by most recently reviewed first.
    private var reviewedTasks: [ReviewTask] {
        store.snapshot.reviewTasks
            .filter { $0.lastQuality != nil }
            .sorted {
                // First by repetition count descending, then by due date
                if $0.repetitionCount != $1.repetitionCount {
                    return $0.repetitionCount > $1.repetitionCount
                }
                return $0.dueDate > $1.dueDate
            }
    }

    private var reviewedTaskIDs: [UUID] {
        reviewedTasks.map(\.id)
    }

    private var totalReviewRounds: Int {
        reviewedTasks.reduce(0) { $0 + max($1.repetitionCount, 0) }
    }

    private var recentReviewedAt: Date? {
        reviewedTasks.compactMap(\.lastReviewedAt).max()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudyDesign.Spacing.chatInner) {
                PastTasksHeader(
                    reviewedCount: reviewedTasks.count,
                    totalReviewRounds: totalReviewRounds,
                    recentReviewedAt: recentReviewedAt
                )

                ForEach(reviewedTasks) { task in
                    ReviewTaskRow(task: task)
                }
                .animation(nil, value: reviewedTaskIDs)
                if reviewedTasks.isEmpty {
                    StudyEmptyState(title: "暂无复习记录", subtitle: "完成复习评分后，任务会重新安排并出现在这里。", icon: "clock.arrow.circlepath", accentIcon: "sparkles", accentTint: StudyDesign.Colors.success)
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
    }
}

private struct PastTasksHeader: View {
    let reviewedCount: Int
    let totalReviewRounds: Int
    let recentReviewedAt: Date?

    private var recentText: String {
        guard let recentReviewedAt else { return "暂无记录" }
        return recentReviewedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            StudyPageHeader(
                title: "复习记录",
                subtitle: "回看已经完成的任务、复习轮次和最近节奏，方便判断哪些内容已经进入长期记忆。",
                icon: "clock.arrow.circlepath"
            )

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: StudyDesign.Spacing.tight),
                          GridItem(.flexible(), spacing: StudyDesign.Spacing.tight),
                          GridItem(.flexible(), spacing: StudyDesign.Spacing.tight)],
                spacing: StudyDesign.Spacing.tight
            ) {
                PastTaskMetricTile(title: "已归档", value: "\(reviewedCount)", icon: "archivebox.fill", tint: StudyDesign.Colors.success)
                PastTaskMetricTile(title: "累计轮次", value: "\(totalReviewRounds)", icon: "arrow.triangle.2.circlepath", tint: StudyDesign.Colors.info)
                PastTaskMetricTile(title: "最近复习", value: recentText, icon: "calendar.badge.clock", tint: StudyDesign.Colors.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.relaxed)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(StudyDesign.Gradients.featureSurface)

                StudyDesign.Gradients.semanticWash(StudyDesign.Colors.primary)
                    .opacity(0.12)
                    .mask(
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                    .fill(StudyDesign.Colors.primary)
                    .frame(width: 4)
                    .padding(.vertical, StudyDesign.Spacing.normal)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

private struct PastTaskMetricTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                        .fill(StudyDesign.Colors.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                        .stroke(tint.opacity(0.14), lineWidth: 1)
                )

            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .lineLimit(1)
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
                    .fill(tint.opacity(0.36))
                    .frame(width: 3)
                    .padding(.vertical, StudyDesign.Spacing.tight)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

struct ReviewTaskRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingDeleteConfirmation = false
    @State private var isEditing = false
    @State private var showQualityPicker = false
    @State private var selectedQuality: ReviewPlanner.Quality = .good
    @State private var isCompleting = false
    @State private var hasAppeared = false
    @State private var completionBounce = false
    @State private var practiceCard: StudyCard?
    @State private var showingCardEditor = false
    @Namespace private var qualitySelectionNamespace
    var task: ReviewTask

    private var currentTask: ReviewTask {
        store.snapshot.reviewTasks.first { $0.id == task.id } ?? task
    }

    private var isOverdue: Bool {
        currentTask.status == .pending
            && currentTask.dueDate < Calendar.current.startOfDay(for: Date())
    }

    private var dueStatusText: String {
        if currentTask.status != .pending {
            return "已完成"
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(currentTask.dueDate) {
            return "今天到期"
        }
        if isOverdue {
            return "已过期"
        }
        return currentTask.dueDate.formatted(date: .abbreviated, time: .shortened)
    }

    private var dueTint: Color {
        if currentTask.status != .pending {
            return StudyDesign.Colors.success
        }
        return isOverdue ? StudyDesign.Colors.danger : StudyDesign.Colors.warning
    }

    private var reviewRoundText: String {
        if currentTask.repetitionCount == 0 {
            return "首轮"
        }
        return "\(currentTask.repetitionCount) 轮"
    }

    private func priorityTint(_ priority: Int) -> Color {
        switch priority {
        case 5...:
            return StudyDesign.Colors.danger
        case 4:
            return StudyDesign.Colors.warning
        default:
            return StudyDesign.Colors.secondary
        }
    }

    var body: some View {
        ListCard(tint: taskAccentTint) {
            reviewTaskContent
        }
        .contextMenu {
            Button("应用内作答") { openPractice() }
            Button("编辑卡片") { showingCardEditor = true }
            if currentTask.status == .pending {
                Button {
                    setQualityPickerVisible(true)
                } label: {
                    Label("完成并评价", systemImage: "checkmark.circle")
                }

                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        store.postpone(currentTask, days: 1)
                    }
                } label: {
                    Label("延后 1 天", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        store.setReminderEnabled(currentTask, enabled: !currentTask.remindersEnabled)
                    }
                } label: {
                    Label(currentTask.remindersEnabled ? "关闭提醒" : "开启提醒", systemImage: currentTask.remindersEnabled ? "bell.slash" : "bell.badge")
                }

                Divider()
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
        .opacity(isCompleting ? 0 : (hasAppeared ? 1 : 0))
        .offset(y: isCompleting ? -18 : (hasAppeared ? 0 : 12))
        .scaleEffect(isCompleting ? 0.965 : (hasAppeared ? 1 : 0.985))
        .animation(StudyDesign.Motion.animation(.normal), value: isCompleting)
        .animation(StudyDesign.Motion.animation(.heroReveal), value: hasAppeared)
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(StudyDesign.Motion.animation(.heroReveal)) {
                    hasAppeared = true
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            ReviewTaskEditSheetWrapper(task: currentTask)
        }
        .sheet(item: $practiceCard) { card in
            ActiveRecallView(initialCardID: card.id).environmentObject(store)
        }
        .sheet(isPresented: $showingCardEditor) {
            StudyCardEditor(existing: store.card(for: currentTask), initialPrompt: currentTask.title,
                knowledgePointID: currentTask.knowledgePointID, mistakeID: currentTask.mistakeID,
                linkedReviewTaskID: currentTask.id)
                .environmentObject(store)
        }
        .alert("删除这个复习任务？", isPresented: $isShowingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                store.deleteReviewTask(currentTask)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除“\(currentTask.title)”并取消它的本地提醒。")
        }
    }

    @ViewBuilder
    private var reviewTaskContent: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Button("应用内作答") { openPractice() }
                .buttonStyle(.borderedProminent)
#if os(iOS)
            taskSummary
                .layoutPriority(1)
#else
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                taskSummary
                    .frame(maxWidth: .infinity, alignment: .leading)

                desktopActionBar
                    .fixedSize(horizontal: true, vertical: true)
                    .layoutPriority(2)
            }
#endif

            if currentTask.status == .pending && showQualityPicker {
                qualityPickerButtons
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

#if os(iOS)
            if !showQualityPicker {
                mobileTaskActionRow
            }
#endif
        }
    }

    private func openPractice() {
        if let card = store.ensureCard(for: currentTask) {
            practiceCard = card
        } else {
            showingCardEditor = true
        }
    }

    private var taskSummary: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                ZStack {
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .fill(taskAccentTint.opacity(0.12))
                    Image(systemName: taskStatusIcon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(taskAccentTint)
                }
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .stroke(taskAccentTint.opacity(0.20), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(currentTask.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 34, alignment: .leading)
            }

            taskRhythmStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var taskAccentTint: Color {
        if currentTask.status != .pending {
            return StudyDesign.Colors.success
        }
        return isOverdue ? StudyDesign.Colors.danger : StudyDesign.Colors.secondary
    }

    private var taskStatusIcon: String {
        if currentTask.status != .pending {
            return "checkmark.seal.fill"
        }
        return isOverdue ? "exclamationmark.triangle.fill" : "calendar.badge.clock"
    }

    private var taskRhythmStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                ReviewTaskInfoChip(title: dueStatusText, icon: "calendar", tint: dueTint, emphasized: isOverdue)
                ReviewTaskInfoChip(title: reviewRoundText, icon: "arrow.triangle.2.circlepath", tint: StudyDesign.Colors.labelSecondary)
                priorityBadge
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    ReviewTaskInfoChip(title: dueStatusText, icon: "calendar", tint: dueTint, emphasized: isOverdue)
                    ReviewTaskInfoChip(title: reviewRoundText, icon: "arrow.triangle.2.circlepath", tint: StudyDesign.Colors.labelSecondary)
                }
                if currentTask.priority != nil {
                    HStack(spacing: StudyDesign.Spacing.compact) {
                        priorityBadge
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var priorityBadge: some View {
        if let priority = currentTask.priority {
            ReviewPriorityBadge(priority: priority, tint: priorityTint(priority))
        }
    }

#if os(iOS)
    private var mobileTaskActionRow: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            if currentTask.status == .pending {
                completeButton
                    .frame(minWidth: 92)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)
            taskManagementMenu
        }
        .frame(maxWidth: .infinity)
    }
#endif

    private var taskManagementMenu: some View {
        Menu {
            if currentTask.status == .pending {
                Button {
                    store.postpone(currentTask, days: 1)
                } label: {
                    Label("延后 1 天", systemImage: "clock.arrow.circlepath")
                }

                Button {
                    store.setReminderEnabled(currentTask, enabled: !currentTask.remindersEnabled)
                } label: {
                    Label(
                        currentTask.remindersEnabled ? "关闭提醒" : "开启提醒",
                        systemImage: currentTask.remindersEnabled ? "bell.slash" : "bell.badge"
                    )
                }

                Divider()
            }

            Button {
                isEditing = true
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .fill(StudyDesign.Colors.dataBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .stroke(StudyDesign.Colors.accentHairline.opacity(0.52), lineWidth: 1)
                )
        }
#if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: true)
#endif
        .iOSTouchTarget()
        .accessibilityLabel("管理复习任务：\(currentTask.title)")
        .accessibilityHint(currentTask.status == .pending ? "打开延期、提醒、编辑和删除操作" : "打开编辑和删除操作")
        .help("管理复习任务")
    }

    private var desktopActionBar: some View {
        HStack(spacing: StudyDesign.Spacing.standard) {
            if currentTask.status == .pending && !showQualityPicker {
                completeButton
            }

            taskManagementMenu
        }
    }

    private var completeButton: some View {
        Button {
            setQualityPickerVisible(true)
        } label: {
            StudyActionPillLabel(title: "线下自评", systemImage: "checkmark")
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact, minWidth: 82))
        .iOSTouchTarget()
        .accessibilityLabel("完成复习任务：\(currentTask.title)")
        .accessibilityHint("评价本次复习质量")
        .help("完成任务并评价复习质量")
#if os(iOS)
        .sensoryFeedback(.success, trigger: currentTask.status)
#endif
    }

    private func setQualityPickerVisible(_ isVisible: Bool) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                showQualityPicker = isVisible
            }
        } else {
            withAnimation(StudyDesign.Motion.animation(.spring)) {
                showQualityPicker = isVisible
            }
        }
    }

    // MARK: - Quality rating pills

    private var qualityPickerButtons: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Text("线下学习后，本次复习感觉如何？")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)

                Spacer(minLength: StudyDesign.Spacing.tight)

                Button {
                    setQualityPickerVisible(false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .frame(width: 28, height: 26)
                        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                                .stroke(StudyDesign.Colors.accentHairline.opacity(0.48), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
                }
                .buttonStyle(.plain)
                .iOSTouchTarget()
                .accessibilityLabel("取消本次评分")
                .accessibilityHint("返回未完成状态")
                .help("取消本次评分")
            }

            ViewThatFits(in: .horizontal) {
                qualityPillRow
                qualityPillGrid
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.dataBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本次复习感觉如何")
        .accessibilityHint("选择一个评分后会完成任务并安排下次复习")
    }

    private var qualityPillRow: some View {
        HStack(spacing: StudyDesign.Spacing.micro) {
            ForEach(ReviewPlanner.Quality.allCases) { quality in
                qualityPillButton(quality)
            }
        }
        .padding(StudyDesign.Spacing.micro)
    }

    private var qualityPillGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 78), spacing: StudyDesign.Spacing.micro)],
            alignment: .leading,
            spacing: StudyDesign.Spacing.micro
        ) {
            ForEach(ReviewPlanner.Quality.allCases) { quality in
                qualityPillButton(quality)
            }
        }
        .padding(StudyDesign.Spacing.micro)
    }

    private func qualityPillButton(_ quality: ReviewPlanner.Quality) -> some View {
        Button {
            complete(with: quality)
        } label: {
            Text(quality.shortLabel)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, StudyDesign.Spacing.normal)
                .padding(.vertical, StudyDesign.Spacing.tight)
                .background(
                    ZStack {
                        Capsule()
                            .fill(StudyDesign.Colors.cardBackground)
                            .overlay(
                                Capsule()
                                    .stroke(
                                        selectedQuality == quality
                                            ? qualityTint(quality).opacity(0.26)
                                            : StudyDesign.Colors.accentHairline.opacity(0.44),
                                        lineWidth: 1
                                    )
                            )
                        if selectedQuality == quality {
                            Capsule()
                                .fill(qualityTint(quality).opacity(0.12))
                                .matchedGeometryEffect(id: "qualitySelection", in: qualitySelectionNamespace)
                        }
                    }
                )
                .foregroundStyle(selectedQuality == quality ? StudyDesign.Colors.labelPrimary : qualityTint(quality))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(selectedQuality == quality ? 1.05 : 1.0)
        .animation(StudyDesign.Motion.animation(.spring), value: selectedQuality)
        .accessibilityLabel("评价：\(quality.label)")
        .accessibilityHint("按\(quality.label)完成本次复习")
        .help("按\(quality.label)完成")
    }

    private func complete(with quality: ReviewPlanner.Quality) {
        guard !isCompleting else { return }
        selectedQuality = quality
        completionBounce.toggle()

        if reduceMotion {
            commitReviewRating(quality)
            showQualityPicker = false
            return
        }

        withAnimation(StudyDesign.Motion.animation(.spring)) {
            isCompleting = true
            showQualityPicker = false
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            commitReviewRating(quality)
        }
    }

    private func commitReviewRating(_ quality: ReviewPlanner.Quality) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.rateReview(currentTask, quality: quality)
        }
    }

    private func qualityTint(_ q: ReviewPlanner.Quality) -> Color {
        switch q {
        case .blackout, .incorrectButRecognized, .incorrectButFamiliar:
            return StudyDesign.Colors.danger
        case .hard:
            return StudyDesign.Colors.warning
        case .good:
            return StudyDesign.Colors.secondary
        case .easy:
            return StudyDesign.Colors.success
        }
    }

}

private struct ReviewPriorityBadge: View {
    let priority: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)

            Text("优先级 \(priority)")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(StudyDesign.Colors.labelPrimary)
        .padding(.horizontal, StudyDesign.Spacing.compact)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.dataBackground
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
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(tint.opacity(0.34))
                .frame(width: 16, height: 2)
                .padding(.bottom, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("优先级 \(priority)")
    }
}

private struct ReviewTaskInfoChip: View {
    let title: String
    let icon: String
    let tint: Color
    var emphasized = false

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(emphasized ? tint : StudyDesign.Colors.labelSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.80)
            .padding(.horizontal, StudyDesign.Spacing.compact)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                emphasized ? StudyDesign.Colors.elevatedBackground : StudyDesign.Colors.elevatedBackground,
                                emphasized ? StudyDesign.Colors.dataBackground : StudyDesign.Colors.dataBackground
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Capsule()
                    .stroke(emphasized ? tint.opacity(0.24) : StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
            Capsule()
                .fill(tint.opacity(emphasized ? 0.42 : 0.18))
                .frame(width: 16, height: 2)
                .padding(.bottom, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
