import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard = "今日"
    case planningHome = "计划"
    case importData = "导入"
    case drafts = "待确认"
    case knowledge = "知识点"
    case mistakes = "错题"
    case reviews = "复习计划"
    case calendarPlan = "学习日历"
    case examSprint = "冲刺模式"
    case knowledgeGraph = "知识图谱"
    case documentSections = "资料章节"
    case reportInsights = "学习报告"
    case entertainmentRules = "娱乐规则"
    case pastTasks = "过往任务"
    case examGoals = "考试目标"
    case chat = "学习答疑"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "sun.max"
        case .planningHome: return "calendar.badge.plus"
        case .importData: return "square.and.arrow.down"
        case .drafts: return "checklist.unchecked"
        case .knowledge: return "lightbulb"
        case .mistakes: return "xmark.circle"
        case .reviews: return "calendar"
        case .calendarPlan: return "calendar.badge.clock"
        case .examSprint: return "flag.checkered.2.crossed"
        case .knowledgeGraph: return "point.3.connected.trianglepath.dotted"
        case .documentSections: return "doc.text.magnifyingglass"
        case .reportInsights: return "chart.line.uptrend.xyaxis"
        case .entertainmentRules: return "gamecontroller"
        case .pastTasks: return "clock.arrow.circlepath"
        case .examGoals: return "flag.checkered"
        case .chat: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }

    var tint: Color {
        StudyDesign.Colors.primary
    }
}

extension AppSection {
    /// 所属一级入口（穷举 switch：以后新增页面时编译器会要求补全）。
    var primarySection: StudyPrimarySection {
        switch self {
        case .dashboard: return .today
        case .planningHome, .reviews, .calendarPlan, .examSprint, .examGoals, .pastTasks: return .plan
        case .importData, .drafts, .knowledge, .mistakes, .knowledgeGraph, .documentSections: return .library
        case .chat: return .chat
        case .reportInsights, .entertainmentRules, .settings: return .profile
        }
    }

    static func sections(in primary: StudyPrimarySection) -> [AppSection] {
        allCases.filter { $0.primarySection == primary }
    }

    /// 页面本体。iOS 标签栈与 macOS 侧栏共用这一份映射，避免两处漂移。
    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .dashboard: DashboardView()
        case .planningHome: PlanningRootView()
        case .importData: ImportView()
        case .drafts:
#if os(iOS)
            IOSDraftsView()
#else
            DraftsView()
#endif
        case .knowledge: KnowledgeView()
        case .mistakes: MistakesView()
        case .reviews: ReviewsView()
        case .calendarPlan: StudyCalendarView()
        case .examSprint: ExamSprintView()
        case .knowledgeGraph: KnowledgeGraphView()
        case .documentSections: DocumentSectionsView()
        case .reportInsights: StudyReportInsightsView()
        case .entertainmentRules: EntertainmentRulesPage()
        case .pastTasks: PastTasksView()
        case .examGoals: ExamGoalsView()
        case .chat: ChatView()
        case .settings: SettingsView()
        }
    }
}

@MainActor
extension AppStore {
    /// 切换到某个一级入口（这是导航状态，不是学习数据）。
    ///
    /// 首页与各入口都用它跳转，避免各自拼 `navigateToTab` 字符串。
    func studyOpenPrimarySection(_ section: StudyPrimarySection) {
        navigateToTab = section.rawValue
        navigateToSection = ""
    }

    /// 打开明确的二级目标；由 iOS / macOS 根导航消费后清空请求。
    func studyOpenSection(_ section: AppSection) {
        navigateToSection = section.rawValue
    }
}

struct ContentView: View {
    var body: some View {
        #if os(iOS)
        IOSRootView()
            .foregroundStyle(StudyDesign.Colors.labelPrimary)
            .background(StudyDesign.Gradients.pageBackdrop)
        #else
        MacRootView()
            .foregroundStyle(StudyDesign.Colors.labelPrimary)
            .background(StudyDesign.Gradients.pageBackdrop)
        #endif
    }
}

#if os(iOS)
/// 一级入口标签栏的原生外观适配。
///
/// - iOS 26 及以上：使用系统 `TabView`（系统自带 **Liquid Glass** 外观），
///   并启用系统"向下滚动时收起标签栏"的行为；
/// - iOS 18–25：iPad 使用系统可切换侧栏（`.sidebarAdaptable`），iPhone 仍为标准底部标签栏；
/// - iOS 17：完全使用原生标准外观。
///
/// 这里**不**自绘底栏，也**不**把普通模糊材质当成 Liquid Glass；
/// 所有新 API 都用 `#available` 判断，deployment target 仍是 iOS 17。
private struct StudyPrimaryTabChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // iOS 26 的系统标签栏本身就是 Liquid Glass 外观；这里只额外启用
            // 系统"向下滚动时收起标签栏"的行为。
            //
            // 说明：实测把 `.tabViewStyle(.sidebarAdaptable)` 用在 iPhone 上
            // （配合 `tabItem`）会让整个 TabView 渲染为空白，因此这里不使用它；
            // iPad 由系统原生标签栏自行适配，不再手动指定样式。
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

/// 五个一级入口：今日 / 计划 / 资料 / 答疑 / 我的。
///
/// 使用**原生标签栏**（不再自绘底栏），每个入口保留独立的 `NavigationStack`
/// 与选择状态；原有 `navigateToTab` / `navigateToSection` 跳转继续有目标。
struct IOSRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var primarySection: StudyPrimarySection = .today
    @State private var navigationPaths: [StudyPrimarySection: NavigationPath] = Dictionary(
        uniqueKeysWithValues: StudyPrimarySection.allCases.map { ($0, NavigationPath()) }
    )
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if showOnboarding {
                NavigationStack {
                    OnboardingView {
                        showOnboarding = false
                    }
                }
            } else {
                primaryTabs
            }
        }
        .onAppear {
            showOnboarding = !store.onboardingCompleted
        }
        .onChange(of: store.navigateToSection) { _, target in
            consumeSectionTarget(target)
        }
        .onChange(of: store.navigateToTab) { _, target in
            consumeTabTarget(target)
        }
    }

    private var primaryTabs: some View {
        TabView(selection: $primarySection) {
            ForEach(StudyPrimarySection.allCases) { section in
                NavigationStack(path: navigationPath(for: section)) {
                    rootView(for: section)
                        .navigationDestination(for: AppSection.self) { destination in
                            destination.destinationView
                        }
                }
                .tabItem {
                    Label(section.title, systemImage: section.systemImage)
                }
                .tag(section)
                .badge(section == .library ? pendingDraftCount : 0)
            }
        }
        .modifier(StudyPrimaryTabChrome())
    }

    @ViewBuilder
    private func rootView(for section: StudyPrimarySection) -> some View {
        switch section {
        case .today:
            DashboardView()
        case .plan:
            PlanningRootView()
        case .library:
            StudyLibraryRootView()
        case .chat:
            ChatView()
        case .profile:
            ProfileRootView()
        }
    }

    private func navigationPath(for section: StudyPrimarySection) -> Binding<NavigationPath> {
        Binding {
            navigationPaths[section] ?? NavigationPath()
        } set: { newPath in
            navigationPaths[section] = newPath
        }
    }

    /// 「待确认」数量挂在资料入口上（标签栏徽标 + 资料页内的提示）。
    private var pendingDraftCount: Int {
        store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count
    }

    /// 原有跳转：`navigateToSection` 里带的是页面名，映射到它所属的一级入口再推进导航栈。
    private func consumeSectionTarget(_ raw: String) {
        guard !raw.isEmpty else { return }
        if let section = AppSection.allCases.first(where: { $0.rawValue == raw }) {
            switch section {
            case .dashboard:
                navigationPaths[.today] = NavigationPath()
                primarySection = .today
            case .planningHome:
                // 计划首页是一级栈根，不压入重复的 PlanningRootView。
                navigationPaths[.plan] = NavigationPath()
                primarySection = .plan
            case .entertainmentRules:
                // 每次显式打开都从“我的”根页进入唯一一层规则页。
                var path = NavigationPath()
                path.append(section)
                navigationPaths[.profile] = path
                primarySection = .profile
            default:
                push(section)
            }
        }
        store.navigateToSection = ""
    }

    /// 原有跳转：`navigateToTab` 里的旧内容页名字（`more` / `reviews` / `importData`…）
    /// 统一映射到新的一级入口；具体页面由 `navigateToSection` 负责推进。
    private func consumeTabTarget(_ raw: String) {
        guard !raw.isEmpty else { return }
        if let target = StudyPrimarySection.resolvingLegacyTabID(raw) {
            primarySection = target
        }
        store.navigateToTab = ""
    }

    private func push(_ section: AppSection) {
        let target = section.primarySection
        var path = navigationPaths[target] ?? NavigationPath()
        path.append(section)
        navigationPaths[target] = path
        primarySection = target
    }
}

struct IOSDraftsView: View {
    @EnvironmentObject private var store: AppStore

    private var analysisCount: Int {
        store.snapshot.drafts.count
    }

    private var planCount: Int {
        store.snapshot.pendingAIPlanDrafts.count
    }

    var body: some View {
        Group {
            if store.snapshot.drafts.isEmpty && store.snapshot.pendingAIPlanDrafts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                        IOSDraftsHubHeader(analysisCount: 0, planCount: 0)

                        StudyEmptyState(
                            title: "没有待确认内容",
                            subtitle: "资料分析和 AI 规划会先进入这里，确认后才会写入知识库和复习计划。",
                            icon: "checklist.unchecked",
                            accentIcon: "sparkles",
                            accentTint: StudyDesign.Colors.secondary,
                            actionLabel: "去导入资料"
                        ) {
                            store.navigateToImport()
                        }
                    }
                    .padding(StudyDesign.Spacing.wide)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(StudyDesign.Gradients.pageBackdrop)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                        IOSDraftsHubHeader(analysisCount: analysisCount, planCount: planCount)

                        if !store.snapshot.drafts.isEmpty {
                            IOSDraftSection(
                                title: "资料分析草稿",
                                subtitle: "确认后写入知识库、错题和复习任务",
                                icon: "doc.text.magnifyingglass",
                                tint: StudyDesign.Colors.info
                            ) {
                                ForEach(store.snapshot.drafts) { draft in
                                    NavigationLink {
                                        DraftDetailView(draft: draft)
                                            .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                        IOSAnalysisDraftRow(draft: draft)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if !store.snapshot.pendingAIPlanDrafts.isEmpty {
                            IOSDraftSection(
                                title: "待确认 AI 规划",
                                subtitle: "来自答疑的计划建议，可编辑后加入",
                                icon: "calendar.badge.plus",
                                tint: StudyDesign.Colors.warning
                            ) {
                                ForEach(store.snapshot.pendingAIPlanDrafts) { draft in
                                    NavigationLink {
                                        AIPlanDraftStandaloneDetailView(draft: draft)
                                            .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                        IOSPlanDraftRow(draft: draft)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(StudyDesign.Spacing.wide)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studyScrollBottomComfort()
                }
                .background(StudyDesign.Gradients.pageBackdrop)
            }
        }
        .navigationTitle("待确认")
    }
}

private struct IOSDraftsHubHeader: View {
    let analysisCount: Int
    let planCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("确认工作台")
                        .font(.title.weight(.semibold))
                    Text("先审阅 AI 的分析和规划，再把可靠内容写入你的学习系统。")
                        .font(.footnote)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: StudyDesign.Spacing.normal)

                Image(systemName: "checklist.unchecked")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.info)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(StudyDesign.Colors.dataBackground))
                    .overlay(Circle().stroke(StudyDesign.Colors.info.opacity(0.16), lineWidth: 1))
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                IOSDraftMetricPill(title: "分析草稿", value: "\(analysisCount)", icon: "doc.text.magnifyingglass", tint: StudyDesign.Colors.info)
                IOSDraftMetricPill(title: "AI 规划", value: "\(planCount)", icon: "calendar.badge.plus", tint: StudyDesign.Colors.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.50), lineWidth: 1)
        )
    }
}

private struct IOSDraftMetricPill: View {
    let title: String
    let value: String
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
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(Capsule().fill(StudyDesign.Colors.dataBackground))
    }
}

private struct IOSDraftSection<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(spacing: StudyDesign.Spacing.normal) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                            .fill(tint.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
                Spacer()
            }

            VStack(spacing: StudyDesign.Spacing.tight) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.48), lineWidth: 1)
        )
    }
}

private struct IOSAnalysisDraftRow: View {
    let draft: AnalysisDraft

    var body: some View {
        IOSDraftRowShell(
            title: draft.summary,
            subtitle: "\(draft.knowledgePoints.count) 个知识点 · \(draft.mistakes.count) 道错题 · \(draft.reviewItems.count) 个复习项",
            date: draft.createdAt,
            icon: "sparkles",
            tint: StudyDesign.Colors.info
        )
    }
}

private struct IOSPlanDraftRow: View {
    let draft: AIPlanDraft

    var body: some View {
        IOSDraftRowShell(
            title: draft.title,
            subtitle: "\(draft.reviewItems.count) 个任务 · \(draft.knowledgePoints.count) 个知识点 · \(draft.mistakes.count) 个错题",
            date: draft.createdAt,
            icon: "wand.and.stars",
            tint: StudyDesign.Colors.warning
        )
    }
}

private struct IOSDraftRowShell: View {
    let title: String
    let subtitle: String
    let date: Date
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.11)))

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.normal)
        .padding(.vertical, StudyDesign.Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(StudyDesign.Colors.dataBackground)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.46), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .help("打开详情：\(title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(subtitle)，\(date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityHint("打开待确认详情")
    }
}
#else
struct MacRootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var section: AppSection? = .dashboard
    @State private var detailPath: [AppSection] = []
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if showOnboarding {
                OnboardingView {
                    showOnboarding = false
                }
                .frame(minWidth: 920, minHeight: 640)
            } else {
                NavigationSplitView {
                    MacSidebar(
                        selection: $section,
                        keyboardShortcut: keyboardShortcut(for:),
                        keyboardModifiers: keyboardModifiers(for:)
                    )
                } detail: {
                    NavigationStack(path: $detailPath) {
                        (section ?? .dashboard).destinationView
                            .navigationDestination(for: AppSection.self) { destination in
                                destination.destinationView
                            }
                            .safeAreaInset(edge: .bottom) {
                                StatusBar()
                            }
                    }
                }
            }
        }
        .onAppear {
            showOnboarding = !store.onboardingCompleted
        }
        .onChange(of: store.navigateToSection) { _, target in
            guard !target.isEmpty else { return }
            if let s = AppSection.allCases.first(where: { $0.rawValue == target }) {
                detailPath = []
                section = s
            }
            store.navigateToSection = ""
        }
        .onChange(of: section) { _, _ in
            // 侧栏目标切换后，旧页面的详情不能留在新目标上方。
            detailPath = []
        }
    }

    private func keyboardShortcut(for item: AppSection) -> KeyEquivalent {
        switch item {
        case .dashboard: return "1"
        case .planningHome: return "p"
        case .importData: return "2"
        case .drafts: return "3"
        case .knowledge: return "4"
        case .mistakes: return "5"
        case .reviews: return "6"
        case .calendarPlan: return "7"
        case .examSprint: return "8"
        case .knowledgeGraph: return "9"
        case .documentSections: return "0"
        case .reportInsights: return "="
        case .entertainmentRules: return "e"
        case .pastTasks: return "["
        case .examGoals: return "]"
        case .chat: return "\\"
        case .settings: return ","
        }
    }

    private func keyboardModifiers(for item: AppSection) -> EventModifiers {
        switch item {
        case .planningHome, .entertainmentRules:
            return [.command, .option]
        default:
            return .command
        }
    }
}

private struct MacSidebar: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: AppStore
    @Binding var selection: AppSection?
    let keyboardShortcut: (AppSection) -> KeyEquivalent
    let keyboardModifiers: (AppSection) -> EventModifiers

    private var selectedSection: AppSection {
        selection ?? .dashboard
    }

    /// 按新的五个一级入口分组（与 iOS 标签栏一致），原有页面一个都没少。
    private var navigationGroups: [MacSidebarGroup] {
        StudyPrimarySection.allCases.compactMap { primary in
            let items = AppSection.sections(in: primary)
            return items.isEmpty ? nil : MacSidebarGroup(title: primary.title, items: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacSidebarHeader(
                dueCount: dueReviewCount,
                draftCount: store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count,
                knowledgeCount: store.snapshot.knowledgePoints.count
            )
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.top, StudyDesign.Spacing.relaxed)
            .padding(.bottom, StudyDesign.Spacing.normal)

            ScrollView {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                    ForEach(navigationGroups) { group in
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                            MacSidebarGroupHeader(title: group.title)

                            VStack(spacing: StudyDesign.Spacing.micro) {
                                ForEach(group.items) { item in
                                    MacSidebarRow(
                                        item: item,
                                        isSelected: selectedSection == item,
                                        shortcut: shortcutText(for: item),
                                        badgeValue: badgeValue(for: item),
                                        action: { selection = item }
                                    )
                                    .keyboardShortcut(keyboardShortcut(item), modifiers: keyboardModifiers(item))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, StudyDesign.Spacing.tight)
                .padding(.vertical, StudyDesign.Spacing.tight)
            }
        }
        .frame(minWidth: 244)
        .background(
            StudyDesign.Colors.sidebarBackground
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(StudyDesign.Colors.accentHairline.opacity(0.44))
                .frame(width: 1)
        }
    }

    private var dueReviewCount: Int {
        let endOfToday = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: Date())
        ) ?? Date()
        return store.snapshot.reviewTasks.filter { task in
            task.status == .pending && task.dueDate < endOfToday
        }.count
    }

    private func badgeValue(for item: AppSection) -> Int? {
        switch item {
        case .dashboard, .reviews:
            return dueReviewCount > 0 ? dueReviewCount : nil
        case .drafts:
            let count = store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count
            return count > 0 ? count : nil
        case .calendarPlan:
            let count = StudyCalendarPlanner.makeDays(snapshot: store.snapshot).filter(\.hasWork).count
            return count > 0 ? count : nil
        case .examSprint:
            return store.snapshot.nextExamGoal() == nil ? nil : 1
        case .knowledgeGraph:
            let count = KnowledgeGraph.make(from: store.snapshot).edges.count
            return count > 0 ? count : nil
        case .documentSections:
            let count = DocumentSectionExtractor.extractAll(from: store.snapshot).count
            return count > 0 ? count : nil
        case .reportInsights:
            let overloadCount = StudyLoadBalancer.make(from: store.snapshot).overloadedDayCount
            if overloadCount > 0 {
                return overloadCount
            }
            let forecast = StudyReportForecast.make(from: store.snapshot)
            return forecast.retentionRiskCount > 0 ? forecast.retentionRiskCount : nil
        case .knowledge:
            return store.snapshot.knowledgePoints.isEmpty ? nil : store.snapshot.knowledgePoints.count
        case .mistakes:
            return store.snapshot.mistakes.isEmpty ? nil : store.snapshot.mistakes.count
        default:
            return nil
        }
    }

    private func shortcutText(for item: AppSection) -> String {
        switch item {
        case .dashboard: return "⌘1"
        case .planningHome: return "⌥⌘P"
        case .importData: return "⌘2"
        case .drafts: return "⌘3"
        case .knowledge: return "⌘4"
        case .mistakes: return "⌘5"
        case .reviews: return "⌘6"
        case .calendarPlan: return "⌘7"
        case .examSprint: return "⌘8"
        case .knowledgeGraph: return "⌘9"
        case .documentSections: return "⌘0"
        case .reportInsights: return "⌘="
        case .entertainmentRules: return "⌥⌘E"
        case .pastTasks: return "⌘["
        case .examGoals: return "⌘]"
        case .chat: return "⌘\\"
        case .settings: return "⌘,"
        }
    }
}

private struct MacSidebarGroup: Identifiable {
    let title: String
    let items: [AppSection]

    var id: String { title }
}

private struct MacSidebarHeader: View {
    let dueCount: Int
    let draftCount: Int
    let knowledgeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.standard) {
                Image(systemName: "graduationcap.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.primary)
                    .frame(width: 38, height: 38)
                    .background(
                        StudyDesign.Gradients.semanticWash(StudyDesign.Colors.primary),
                        in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                            .stroke(StudyDesign.Colors.primary.opacity(0.20), lineWidth: 1)
                    )
                    .shadow(color: StudyDesign.Colors.primary.opacity(0.10), radius: 8, y: 3)

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("学习助手")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text("复习、资料和 AI 工作台")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
            }

            HStack(spacing: StudyDesign.Spacing.compact) {
                MacSidebarStatChip(title: "今日", value: "\(dueCount)", tint: dueCount > 0 ? StudyDesign.Colors.warning : StudyDesign.Colors.success)
                MacSidebarStatChip(title: "待确认", value: "\(draftCount)", tint: StudyDesign.Colors.secondary)
                MacSidebarStatChip(title: "知识", value: "\(knowledgeCount)", tint: StudyDesign.Colors.primary)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                        .stroke(StudyDesign.Colors.accentHairline.opacity(0.48), lineWidth: 1)
                )
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

private struct MacSidebarGroupHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .textCase(.uppercase)

            Rectangle()
                .fill(StudyDesign.Colors.accentHairline.opacity(0.52))
                .frame(height: 1)
        }
        .padding(.horizontal, StudyDesign.Spacing.normal)
    }
}

private struct MacSidebarStatChip: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.micro) {
            Text(value)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, StudyDesign.Spacing.compact)
        .padding(.vertical, 5)
        .background(Capsule().fill(StudyDesign.Colors.inputBackground))
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct MacSidebarRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: AppSection
    let isSelected: Bool
    let shortcut: String
    let badgeValue: Int?
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Image(systemName: item.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? navigationSelectionTint : StudyDesign.Colors.labelSecondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                            .fill(
                                isSelected
                                    ? navigationSelectionTint.opacity(colorScheme == .light ? 0.12 : 0.10)
                                    : StudyDesign.Colors.inputBackground.opacity(isHovering ? 0.70 : 0)
                            )
                    )

                Text(item.rawValue)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? StudyDesign.Colors.labelPrimary : StudyDesign.Colors.labelSecondary)

                Spacer(minLength: StudyDesign.Spacing.compact)

                if let badgeValue {
                    Text("\(badgeValue)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(item.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(StudyDesign.Colors.inputBackground)
                                .overlay(Capsule().fill(item.tint.opacity(0.05)))
                        )
                        .overlay(Capsule().stroke(item.tint.opacity(0.18), lineWidth: 1))
                } else if isSelected || isHovering {
                    Text(shortcut)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(StudyDesign.Colors.inputBackground))
                }
            }
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .fill(rowBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(rowStroke, lineWidth: rowStrokeWidth)
            }
            .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .help(isSelected ? "\(item.rawValue)，当前页面" : "打开\(item.rawValue)，快捷键 \(shortcut)")
        .accessibilityLabel(item.rawValue)
        .accessibilityValue(sidebarAccessibilityValue)
        .accessibilityHint(isSelected ? "当前页面" : "打开这个页面，快捷键 \(shortcut)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(StudyDesign.Motion.animation(.fast), value: isSelected)
        .animation(StudyDesign.Motion.animation(.fast), value: isHovering)
        .animation(StudyDesign.Motion.animation(.fast), value: isFocused)
    }

    private var navigationSelectionTint: Color {
        StudyDesign.Colors.primary
    }

    private var sidebarAccessibilityValue: String {
        if let badgeValue {
            return isSelected ? "已选中，\(badgeValue) 项待处理" : "\(badgeValue) 项待处理"
        }
        return isSelected ? "已选中" : "未选中"
    }

    private var rowBackground: Color {
        if isSelected {
            return colorScheme == .light
                ? StudyDesign.Colors.primary.opacity(0.085)
                : StudyDesign.Colors.elevatedBackground
        }
        if isFocused {
            return StudyDesign.Colors.primary.opacity(colorScheme == .light ? 0.055 : 0.08)
        }
        return isHovering ? StudyDesign.Colors.contentBackground.opacity(0.54) : .clear
    }

    private var rowStroke: Color {
        if isSelected {
            return navigationSelectionTint.opacity(colorScheme == .light ? 0.34 : 0.18)
        }
        if isFocused {
            return StudyDesign.Colors.primary
        }
        return isHovering ? StudyDesign.Colors.accentHairline.opacity(0.46) : .clear
    }

    private var rowStrokeWidth: CGFloat {
        isFocused ? 2 : 1
    }
}

#endif

struct StatusBar: View {
    @EnvironmentObject private var store: AppStore
    @State private var isDismissed = false

    var body: some View {
        Group {
            if shouldShow {
                statusContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(StudyDesign.Motion.animation(.fast), value: shouldShow)
        .onChange(of: notificationKey) { _, _ in
            isDismissed = false
            if hasMeaningfulMessage {
                StudyAccessibility.announce("\(statusTitle)：\(statusMessageText)")
            }
        }
        .task(id: notificationKey) {
            guard shouldAutoDismiss else { return }
            let delay: UInt64 = isError ? 10_000_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task<Never, Never>.isCancelled, !store.isBusy else { return }
            withAnimation(StudyDesign.Motion.animation(.fast)) {
                isDismissed = true
                store.statusMessage = ""
            }
        }
    }

    private var statusContent: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            statusCapsule

            if store.isBusy {
                Button {
                    store.cancelAIRequest()
                } label: {
                    StudyActionPillLabel(title: "取消", systemImage: "xmark")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact, minWidth: 72))
                .help("取消当前 AI 请求")
                .accessibilityLabel("取消当前 AI 请求")
                .accessibilityHint("停止正在进行的 AI 分析或生成。")
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.wide)
        .padding(.vertical, StudyDesign.Spacing.tight)
        .background(
            Rectangle()
                .fill(StudyDesign.Colors.sidebarBackground)
                .overlay(alignment: .topLeading) {
                    LinearGradient(
                        colors: [
                            statusTint.opacity(0.045),
                            StudyDesign.Colors.contentBackground.opacity(0.24),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 320)
                    .allowsHitTesting(false)
                }
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudyDesign.Colors.accentHairline.opacity(0.42))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(statusTitle)：\(statusMessageText)")
    }

    private var statusTitle: String {
        if store.isBusy { return "运行中" }
        return isError ? "需要处理" : "已完成"
    }

    private var statusMessageText: String {
        store.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canClearStatusMessage: Bool {
        !store.isBusy
    }

    private var statusTint: Color {
        if store.isBusy { return StudyDesign.Colors.info }
        return isError ? StudyDesign.Colors.danger : StudyDesign.Colors.success
    }

    private var notificationKey: String {
        "\(store.isBusy)-\(statusMessageText)"
    }

    private var shouldShow: Bool {
        if store.isBusy { return true }
        return !isDismissed && hasMeaningfulMessage
    }

    private var shouldAutoDismiss: Bool {
        !store.isBusy && hasMeaningfulMessage && !isDismissed
    }

    private var hasMeaningfulMessage: Bool {
        !statusMessageText.isEmpty
            && statusMessageText != "准备就绪"
            && statusMessageText != "本地数据已准备"
    }

    private var isError: Bool {
        let errorMarkers = ["失败", "错误", "无法", "不能", "请先", "未找到", "没有可用", "已关闭", "不可用", "发现"]
        return errorMarkers.contains { statusMessageText.localizedCaseInsensitiveContains($0) }
    }

    private var statusCapsule: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.13))
                if store.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(statusTint)
                }
            }
            .frame(width: 26, height: 26)
            .overlay(Circle().stroke(statusTint.opacity(0.20), lineWidth: 1))

            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(statusMessageText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if canClearStatusMessage {
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        isDismissed = true
                        store.statusMessage = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("关闭状态提示")
                .accessibilityLabel("关闭状态提示")
                .accessibilityHint("隐藏当前状态消息")
            }
        }
        .frame(minWidth: 220, maxWidth: 420, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, 6)
        .background(StudyDesign.Colors.inputBackground, in: Capsule())
        .overlay(Capsule().stroke(statusTint.opacity(0.20), lineWidth: 1))
        .help(statusMessageText)
        .accessibilityHint(store.isBusy ? "当前任务运行中，可使用取消按钮停止" : "显示最近一次操作状态")
    }

}
