import SwiftUI

// MARK: - F 模块：我的（个人）一级入口
//
// 页面归属（F 的导航改造）：
// - E 的娱乐规则（由可复用的 EntertainmentRulesPage 展示与编辑）
// - 学习报告（`StudyReportInsightsView`）
// - B 的作息设置（`AvailabilitySettingsView`）
// - 现有设置与备份（`SettingsView`）
//
// 本页不直接改快照：规则的新增/编辑/删除留给 E 的界面，设置走既有 store 入口。

struct ProfileRootView: View {
    @EnvironmentObject private var store: AppStore

    @State private var isShowingAvailability = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                StudyPageHeader(
                    title: "我的",
                    subtitle: "娱乐规则、学习报告与设置",
                    icon: "person.crop.circle",
                    tint: StudyDesign.Colors.primary,
                    compact: true
                )

                entertainmentCard
                reportCard
                settingsCard
                allEntriesCard
            }
            .padding(.horizontal, StudyDesign.Spacing.wide)
            .padding(.top, StudyDesign.Spacing.normal)
            .padding(.bottom, StudyDesign.Spacing.section)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(StudyDesign.Gradients.pageBackdrop)
        .navigationTitle("我的")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $isShowingAvailability) { availabilitySheet }
    }

    // MARK: 娱乐规则（只读 + 版本说明）

    private var entertainmentCard: some View {
        StudyHomeCard(
            title: "娱乐与休息",
            subtitle: entertainmentSubtitle,
            systemImage: "gamecontroller",
            tint: StudyDesign.Colors.secondary
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                NavigationLink(value: AppSection.entertainmentRules) {
                    StudyRootNavigationRow(
                        title: "娱乐规则与计时",
                        subtitle: "解锁条件、领取与计时都在这一页",
                        systemImage: "gamecontroller",
                        tint: StudyDesign.Colors.primary,
                        countText: usableRuleCount > 0 ? "\(usableRuleCount) 条" : nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开娱乐解锁规则与计时页面")

                if entertainmentRules.isEmpty {
                    Text("还没有娱乐规则：在娱乐规则页里设定完成多少学习换多少娱乐时间。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(entertainmentRules) { rule in
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                            HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.tight) {
                                Text(rule.name)
                                    .font(StudyDesign.Typography.cardTitle)
                                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                                if !rule.isUsable {
                                    StudyHomeChip(text: "已停用", systemImage: "pause.circle")
                                }
                                Spacer(minLength: 0)
                            }

                            Text("解锁条件：\(rule.condition.displayText)")
                                .font(StudyDesign.Typography.supporting)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: StudyDesign.Spacing.micro) {
                                StudyHomeChip(text: "奖励 \(rule.rewardMinutes) 分钟", systemImage: "clock")
                                StudyHomeChip(text: "规则版本 v\(rule.ruleVersion)", systemImage: "tag")
                                StudyHomeChip(text: rule.fallback.label, systemImage: "arrow.triangle.branch")
                            }
                        }
                        .padding(.vertical, StudyDesign.Spacing.micro)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("娱乐规则 \(rule.name)，解锁条件 \(rule.condition.displayText)，奖励 \(rule.rewardMinutes) 分钟，规则版本 \(rule.ruleVersion)")
                    }

                    Text("已发放的奖励会记住当时的规则版本，之后修改规则不会改写历史记录。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var usableRuleCount: Int {
        store.snapshot.entertainmentRules.filter(\.isUsable).count
    }

    private var entertainmentRules: [EntertainmentRule] {
        store.snapshot.entertainmentRules.sorted { lhs, rhs in
            if lhs.isUsable != rhs.isUsable { return lhs.isUsable }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var entertainmentSubtitle: String {
        let usable = store.snapshot.entertainmentRules.filter(\.isUsable).count
        if usable == 0 {
            return "尚未设置"
        }
        let todayGrants = store.snapshot.rewardGrants(on: StudyDayKey(date: Date(), timeZone: TimeZone.current)).count
        return "生效中 \(usable) 条 · 今天已发放 \(todayGrants) 次"
    }

    // MARK: 学习报告

    private var reportCard: some View {
        StudyHomeCard(
            title: "学习报告",
            subtitle: "周报、月报与负荷预测",
            systemImage: "chart.line.uptrend.xyaxis",
            tint: StudyDesign.Colors.info
        ) {
            NavigationLink(value: AppSection.reportInsights) {
                StudyRootNavigationRow(
                    title: AppSection.reportInsights.rawValue,
                    subtitle: "学习量、薄弱项与建议",
                    systemImage: AppSection.reportInsights.icon,
                    tint: StudyDesign.Colors.info,
                    countText: overloadedDayCount > 0 ? "\(overloadedDayCount) 天偏满" : nil
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var overloadedDayCount: Int {
        StudyLoadBalancer.make(from: store.snapshot).overloadedDayCount
    }

    // MARK: 设置与数据

    private var settingsCard: some View {
        StudyHomeCard(
            title: "设置与数据",
            subtitle: "作息、提醒、外观与本地备份",
            systemImage: "gearshape",
            tint: StudyDesign.Colors.secondary
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Button {
                    isShowingAvailability = true
                } label: {
                    StudyRootNavigationRow(
                        title: "学习窗口与作息",
                        subtitle: "每天可用时间、睡眠与固定占用",
                        systemImage: "moon.zzz",
                        tint: StudyDesign.Colors.info,
                        countText: nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("设置每天可用于学习的时间段")

                NavigationLink(value: AppSection.settings) {
                    StudyRootNavigationRow(
                        title: AppSection.settings.rawValue,
                        subtitle: "外观、提醒、隐私与本地备份",
                        systemImage: AppSection.settings.icon,
                        tint: StudyDesign.Colors.labelSecondary,
                        countText: nil
                    )
                }
                .buttonStyle(.plain)

                Text("存储：\(store.storageStatusMessage) · \(store.environment.isIsolatedStore ? "隔离数据目录（测试）" : "本机数据目录")")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var availabilitySheet: some View {
        AvailabilitySettingsView(
            semester: store.snapshot.scheduleSemester ?? .fallback,
            settings: store.snapshot.availabilitySettings,
            courses: store.snapshot.scheduleCourses,
            exceptions: store.snapshot.scheduleExceptions,
            now: Date(),
            periodTemplates: store.snapshot.schedulePeriodTemplates,
            onSaveSettings: { settings, templates in
                store.saveAvailabilityAndPeriodTemplates(settings: settings, templates: templates)
            },
            onCancel: { isShowingAvailability = false }
        )
    }

    // MARK: 全部入口（保证原有页面都能到达）

    private var allEntriesCard: some View {
        StudyHomeCard(
            title: "全部入口",
            subtitle: "原有页面都在这里，一个都没少",
            systemImage: "square.grid.2x2",
            tint: StudyDesign.Colors.labelSecondary
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                ForEach(StudyPrimarySection.allCases) { primary in
                    let sections = AppSection.sections(in: primary)
                    if !sections.isEmpty {
                        Text(primary.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .padding(.top, StudyDesign.Spacing.micro)

                        ForEach(sections) { section in
                            NavigationLink(value: section) {
                                StudyRootNavigationRow(
                                    title: section.rawValue,
                                    subtitle: nil,
                                    systemImage: section.icon,
                                    tint: StudyDesign.Colors.labelSecondary,
                                    countText: nil
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
