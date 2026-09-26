import SwiftUI

// MARK: - F 模块：计划一级入口
//
// 页面归属（F 的导航改造）：
// - B 的课表（`TimetableView`）
// - 现有学习日历（`StudyCalendarView`）
// - 任务列表（`ReviewsView`）与过往任务（`PastTasksView`）
// - 考试目标（`ExamGoalsView`）与冲刺模式（`ExamSprintView`）
//
// 这里只做导航与只读摘要，不实现课表 / 计划算法，也不直接改快照。

struct PlanningRootView: View {
    @EnvironmentObject private var store: AppStore

    @State private var isShowingTimetable = false
    @State private var isShowingAvailability = false
    @State private var isShowingFullPlan = false
    @State private var isShowingManualTaskEditor = false
    @State private var isReevaluatingPlan = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                StudyPageHeader(
                    title: "计划",
                    subtitle: "课表、学习日历、任务与考试目标",
                    icon: "calendar.badge.clock",
                    tint: StudyDesign.Colors.primary,
                    compact: true
                )

                scheduleCard
                todayPlanCard
                tasksCard
                calendarCard
                examCard
            }
            .padding(.horizontal, StudyDesign.Spacing.wide)
            .padding(.top, StudyDesign.Spacing.normal)
            .padding(.bottom, StudyDesign.Spacing.section)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(StudyDesign.Gradients.pageBackdrop)
        .navigationTitle("计划")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(isPresented: $isShowingTimetable) {
            TimetableSheetHost(isPresented: $isShowingTimetable)
        }
        .sheet(isPresented: $isShowingAvailability) { availabilitySheet }
        .sheet(isPresented: $isShowingFullPlan) {
            TodayPlanDetailSheet()
                .environmentObject(store)
#if os(macOS)
                .frame(minWidth: 720, minHeight: 640)
#endif
        }
        .sheet(isPresented: $isShowingManualTaskEditor) {
            ManualStudyTaskEditorSheet(
                planningTimeZoneIdentifier: store.snapshot.planningPreferences.planningTimeZoneIdentifier,
                now: Date(),
                onSave: { task in
                    let result = store.saveManualStudyTask(task)
                    if result.mayCloseEditor { isShowingManualTaskEditor = false }
                    return result
                },
                onCancel: { isShowingManualTaskEditor = false }
            )
        }
    }

    // MARK: 课表与作息

    private var scheduleCard: some View {
        StudyHomeCard(
            title: "课表与作息",
            subtitle: scheduleSubtitle,
            systemImage: "tablecells",
            tint: StudyDesign.Colors.info
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                if !store.snapshot.isSemesterConfigured {
                    StudyHomeNoticeLine(
                        text: "尚未添加课表：今天只按到期的复习任务安排，首页不会编造课程内容。",
                        systemImage: "info.circle",
                        tint: StudyDesign.Colors.info
                    )
                }

                Button {
                    isShowingTimetable = true
                } label: {
                    StudyRootNavigationRow(
                        title: "课程表",
                        subtitle: "课程、停课换课与学期设置",
                        systemImage: "calendar",
                        tint: StudyDesign.Colors.info,
                        countText: store.snapshot.scheduleCourses.isEmpty ? nil : "\(store.snapshot.scheduleCourses.count) 门"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开课程表页面")

                Button {
                    isShowingAvailability = true
                } label: {
                    StudyRootNavigationRow(
                        title: "学习窗口与作息",
                        subtitle: availabilitySubtitle,
                        systemImage: "moon.zzz",
                        tint: StudyDesign.Colors.secondary,
                        countText: nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("设置每天可用于学习的时间段、睡眠与固定占用")
            }
        }
    }

    private var scheduleSubtitle: String {
        guard let semester = store.snapshot.semester, semester.isConfigured else {
            return "还没有设置学期"
        }
        let week = semester.scheduleSemester.weekIndex(for: Date())
        return "\(semester.name) · 第 \(max(1, week)) / \(max(1, semester.weekCount)) 周"
    }

    private var availabilitySubtitle: String {
        let routine = store.snapshot.availabilitySettings
        if !routine.hasExplicitRoutine {
            return "还没有配置，计划会按默认假设解释"
        }
        let cap = store.snapshot.planningPreferences.dailyCapMinutes
        if let cap {
            return "已配置 · 每日上限 \(cap) 分钟"
        }
        return "已配置每日学习窗口"
    }

    // MARK: 今日计划（生成 / 重新评估 / 完整列表）

    private var todayPlanSubtitle: String {
        guard let plan = store.todayPlan else {
            return "今天还没有生效的计划"
        }
        let pending = store.todayPlanPendingCount
        return "\(plan.mode.label) · 第 \(plan.version) 版 · \(plan.items.count) 项（待完成 \(pending)）· \(plan.plannedMinutesFromItems) 分钟"
    }

    private var todayPlanCard: some View {
        StudyHomeCard(
            title: "今日计划",
            subtitle: todayPlanSubtitle,
            systemImage: "list.bullet.rectangle",
            tint: StudyDesign.Colors.success
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                if let message = store.planEngineAvailabilityMessage {
                    StudyHomeNoticeLine(
                        text: message,
                        systemImage: "exclamationmark.triangle",
                        tint: StudyDesign.Colors.warning
                    )
                }

                Text("包含课程回顾、预习、复习任务与手动任务；到期日与实际安排日分开显示。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: StudyDesign.Spacing.tight) {
                    Button {
                        isShowingManualTaskEditor = true
                    } label: {
                        StudyActionPillLabel(title: "添加手动任务", systemImage: "plus.circle")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .soft, size: .compact))
                    .accessibilityHint("创建一条预计分钟可填写、到期日可选的手动任务")

                    Button {
                        Task {
                            isReevaluatingPlan = true
                            await store.regenerateTodayPlan(force: true)
                            isReevaluatingPlan = false
                        }
                    } label: {
                        StudyActionPillLabel(
                            title: isReevaluatingPlan ? "正在重新规划…" : (store.todayPlan == nil ? "生成今日计划" : "重新规划今日计划"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.success, prominence: .primary, size: .compact))
                    .disabled(isReevaluatingPlan)
                    .accessibilityHint("使用最新学习记录、课表、作息和预算重新计算今天的安排")

                    Button {
                        isShowingFullPlan = true
                    } label: {
                        StudyActionPillLabel(title: "查看完整计划", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                    .accessibilityHint("查看全部计划项、放不下的任务与计划解释，并调整精力")
                }
            }
        }
    }

    // MARK: 任务

    private var tasksCard: some View {
        StudyHomeCard(
            title: "任务与复习",
            subtitle: "今日计划与历史任务都在这里",
            systemImage: "checklist",
            tint: StudyDesign.Colors.primary
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                NavigationLink(value: AppSection.reviews) {
                    StudyRootNavigationRow(
                        title: AppSection.reviews.rawValue,
                        subtitle: "到期与今日安排的复习任务",
                        systemImage: AppSection.reviews.icon,
                        tint: StudyDesign.Colors.primary,
                        countText: todayTaskCount > 0 ? "\(todayTaskCount) 项" : nil
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppSection.pastTasks) {
                    StudyRootNavigationRow(
                        title: AppSection.pastTasks.rawValue,
                        subtitle: "已完成的复习记录",
                        systemImage: AppSection.pastTasks.icon,
                        tint: StudyDesign.Colors.secondary,
                        countText: completedTaskCount > 0 ? "\(completedTaskCount) 项" : nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var todayTaskCount: Int {
        store.todayTasks.count
    }

    private var completedTaskCount: Int {
        store.snapshot.reviewTasks.filter { $0.lastQuality != nil }.count
    }

    // MARK: 日历与冲刺

    private var calendarCard: some View {
        StudyHomeCard(
            title: "日历与冲刺",
            subtitle: "按天查看负荷，或进入考试冲刺",
            systemImage: "calendar.day.timeline.left",
            tint: StudyDesign.Colors.secondary
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                NavigationLink(value: AppSection.calendarPlan) {
                    StudyRootNavigationRow(
                        title: AppSection.calendarPlan.rawValue,
                        subtitle: "每天的任务负荷与完成情况",
                        systemImage: AppSection.calendarPlan.icon,
                        tint: StudyDesign.Colors.primary,
                        countText: overloadedDayCount > 0 ? "\(overloadedDayCount) 天偏满" : nil
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppSection.examSprint) {
                    StudyRootNavigationRow(
                        title: AppSection.examSprint.rawValue,
                        subtitle: store.snapshot.nextExamGoal(now: Date()) == nil ? "先设置考试目标" : "按考试日期倒推安排",
                        systemImage: AppSection.examSprint.icon,
                        tint: StudyDesign.Colors.warning,
                        countText: nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var overloadedDayCount: Int {
        StudyLoadBalancer.make(from: store.snapshot).overloadedDayCount
    }

    // MARK: 考试目标

    private var examCard: some View {
        StudyHomeCard(
            title: "考试目标",
            subtitle: examSubtitle,
            systemImage: "flag.checkered",
            tint: StudyDesign.Colors.warning
        ) {
            NavigationLink(value: AppSection.examGoals) {
                StudyRootNavigationRow(
                    title: store.snapshot.nextExamGoal(now: Date())?.name ?? "添加考试目标",
                    subtitle: examSubtitle,
                    systemImage: AppSection.examGoals.icon,
                    tint: StudyDesign.Colors.warning,
                    countText: store.snapshot.nextExamGoal(now: Date()) == nil ? nil : "进行中"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var examSubtitle: String {
        guard let goal = store.snapshot.nextExamGoal(now: Date()) else {
            return "设置考试日期、科目与目标分数"
        }
        return "\(goal.countdownText(now: Date())) · \(goal.subjectText)"
    }

    // MARK: 弹层（B 的界面，回调走既有 store 入口）

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

}
