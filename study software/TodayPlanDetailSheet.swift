import SwiftUI

// MARK: - G 模块：完整今日计划
//
// 需求 8 的落点：
// - 「生成 / 重新规划今日计划」按钮（走 `AppStore.regenerateTodayPlan`，主动使用最新校准）；
// - 「精力调整」（写入 `PlanningPreferences.energyLevelIdentifier`，并触发重新规划）；
// - 「查看完整今日计划」：列出**全部来源**的计划项（课程回顾 / 预习 / 复习任务 / 手动任务），
//   不是只展示旧的 `reviewTasks`；同时展示放不下的任务与计划解释。
//
// 只读 + 回调：页面不直接改快照，所有写入都经过 AppStore 的统一提交入口。

struct TodayPlanDetailSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var showsExplanation = false
    /// 正在补记时长的那条完成记录。
    @State private var correctingCompletionID: UUID?
    @State private var manualMinutes = 15
    @State private var manualReason = "用户补记"
    @State private var isReducing = false
    @State private var isShowingManualTaskEditor = false
    @State private var editingManualTask: ManualStudyTask?

    private var context: PlanningContext {
        store.snapshot.planningContext(now: Date())
    }

    private var plan: DailyStudyPlan? {
        store.todayPlan
    }

    private var items: [DailyPlanItem] {
        store.todayPlanItems
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                    engineNotice
                    planHeader
                    capacitySection
                    energySection
                    actionsSection
                    manualTasksSection
                    itemsSection
                    unplaceableSection
                    explanationSection
                }
                .padding(StudyDesign.Spacing.wide)
                .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(StudyDesign.Gradients.pageBackdrop)
            .navigationTitle("完整今日计划")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingManualTaskEditor) {
                let now = Date()
                ManualStudyTaskEditorSheet(
                    planningTimeZoneIdentifier: context.timeZoneIdentifier,
                    now: now,
                    initialTask: editingManualTask,
                    onSave: { store.saveManualStudyTask($0, now: Date()) },
                    onDelete: { store.deleteManualStudyTask(id: $0, now: Date()) },
                    onCancel: {
                        isShowingManualTaskEditor = false
                        editingManualTask = nil
                    }
                )
            }
        }
    }

    // MARK: 引擎状态

    @ViewBuilder
    private var engineNotice: some View {
        if let message = store.planEngineAvailabilityMessage {
            noticeCard(text: message, icon: "exclamationmark.triangle", tint: StudyDesign.Colors.warning)
        }
    }

    // MARK: 计划头

    @ViewBuilder
    private var planHeader: some View {
        card(title: "今天", icon: "calendar", tint: StudyDesign.Colors.primary) {
            if let plan {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("\(plan.mode.label) · 第 \(plan.version) 版")
                        .font(StudyDesign.Typography.sectionTitle)
                    Text("安排 \(plan.plannedMinutesFromItems) 分钟 · 可用容量 \(plan.budget.capacityMinutes) 分钟" + capText(plan))
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    if plan.goal.targetMinutes > 0 {
                        Text("本次目标：\(plan.goal.targetMinutes) 分钟")
                            .font(StudyDesign.Typography.supporting)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }
                    Text("计划项 \(plan.items.count) 项 · 放不下 \(plan.unplaceable.count) 项")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("今天还没有生效的计划")
                        .font(StudyDesign.Typography.sectionTitle)
                    Text("点下面的「生成今日计划」即可按课表与作息安排；也可以先补全课程与学习窗口。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func capText(_ plan: DailyStudyPlan) -> String {
        guard let cap = plan.budget.dailyCapMinutes else { return " · 未设每日上限" }
        return " · 每日上限 \(cap) 分钟"
    }

    // MARK: 可用容量与减量（需求 2、4、5）

    private var capacity: StudyRemainingCapacity { store.remainingCapacity() }

    private var capacitySection: some View {
        card(title: "可用容量", icon: "hourglass", tint: StudyDesign.Colors.info) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text(capacitySummary)
                    .font(StudyDesign.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(capacity.explanation, id: \.self) { line in
                    Text(line)
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: StudyDesign.Spacing.tight) {
                    Button {
                        Task {
                            isReducing = true
                            // 预览与应用使用同一份容量口径与同一份策略配置。
                            guard let preview = store.minimumPlanPreview() else {
                                isReducing = false
                                return
                            }
                            let outcome = await store.applyMinimumPlan(preview: preview)
                            isReducing = false
                            if !outcome.didPersist, outcome.didChange || outcome.rejection != nil {
                                // 预览过期或被拒绝：保持界面原样，把原因显示出来。
                                store.statusMessage = outcome.errorMessage ?? outcome.statusMessage
                            }
                        }
                    } label: {
                        StudyActionPillLabel(
                            title: isReducing ? "正在应用…" : "采用减量 / 保底方案",
                            systemImage: "arrow.down.right.circle"
                        )
                    }
                    .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.warning, prominence: .soft, size: .compact))
                    .disabled(isReducing)

                    if store.canUndoMinimumPlan {
                        Button {
                            Task {
                                isReducing = true
                                let outcome = await store.undoMinimumPlan()
                                isReducing = false
                                if !outcome.didPersist {
                                    store.statusMessage = outcome.errorMessage ?? outcome.statusMessage
                                }
                            }
                        } label: {
                            StudyActionPillLabel(title: "撤销减量", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                        .disabled(isReducing)
                        .accessibilityHint("恢复到减量前的计划内容；减量后新增的完成记录不会被覆盖")
                    } else if let currentMode = store.todayPlan?.mode, currentMode != .standard {
                        Label("当前计划不可撤销", systemImage: "info.circle")
                            .font(StudyDesign.Typography.supporting)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }
                }
            }
        }
    }

    private var capacitySummary: String {
        var parts = ["有效剩余 \(capacity.effectiveMinutes) 分钟"]
        if capacity.longestGapMinutes > 0 {
            parts.append("最长连续空档 \(capacity.longestGapMinutes) 分钟")
        }
        if let cap = capacity.dailyCapRemainingMinutes {
            parts.append("每日额度剩余 \(cap) 分钟")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 精力

    private var energySection: some View {
        card(title: "精力", icon: "bolt.heart", tint: StudyDesign.Colors.secondary) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Text("精力只影响今天的预算系数，不改变任务内容。没有手动设置时按课表负担自动估计。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                FlowChips {
                    energyChip(title: "自动", level: nil)
                    ForEach(StudyEnergyLevel.allCases, id: \.self) { level in
                        energyChip(title: level.label, level: level)
                    }
                }
            }
        }
    }

    private func energyChip(title: String, level: StudyEnergyLevel?) -> some View {
        let isSelected = store.todayEnergyLevel == level
        return Button {
            store.setEnergyLevel(level)
        } label: {
            Text(title)
                .font(StudyDesign.Typography.supporting.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, StudyDesign.Spacing.tight)
                .padding(.vertical, StudyDesign.Spacing.micro)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .fill(isSelected ? StudyDesign.Colors.secondary.opacity(0.18) : StudyDesign.Colors.dataBackground)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("精力：\(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: 操作

    private var actionsSection: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Button {
                Task {
                    isWorking = true
                    await store.regenerateTodayPlan(force: true)
                    isWorking = false
                }
            } label: {
                StudyActionPillLabel(
                    title: isWorking ? "正在重新规划…" : (plan == nil ? "生成今日计划" : "重新规划今日计划"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))
            .disabled(isWorking)
            .accessibilityHint("使用最新学习记录、课表、作息和预算重新计算今天的安排")

            Button {
                withAnimation(StudyDesign.Motion.animation(.fast)) {
                    showsExplanation.toggle()
                }
            } label: {
                StudyActionPillLabel(title: showsExplanation ? "收起解释" : "查看解释", systemImage: "text.bubble")
            }
            .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
        }
    }

    // MARK: 手动任务

    private var manualTasksSection: some View {
        card(title: "手动任务", icon: "square.and.pencil", tint: StudyDesign.Colors.secondary) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Button {
                    editingManualTask = nil
                    isShowingManualTaskEditor = true
                } label: {
                    StudyActionPillLabel(title: "添加任务", systemImage: "plus")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .primary, size: .compact))

                if store.snapshot.manualStudyTasks.isEmpty {
                    Text("添加的任务会进入候选池，由今日计划按剩余容量安排。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(store.snapshot.manualStudyTasks) { task in
                        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                                Text(task.title)
                                    .font(StudyDesign.Typography.body.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("预计 \(task.estimatedMinutes) 分钟 · \(manualTaskStatus(task)) · 到期 \(dayText(task.dueDate))")
                                    .font(StudyDesign.Typography.supporting)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Button("编辑") {
                                editingManualTask = task
                                isShowingManualTaskEditor = true
                            }
                            .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                        }
                        .padding(StudyDesign.Spacing.tight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                                .fill(StudyDesign.Colors.dataBackground)
                        )
                    }
                }
            }
        }
    }

    private func manualTaskStatus(_ task: ManualStudyTask) -> String {
        if store.snapshot.completionEvents.contains(where: {
            !$0.isRevoked && $0.source?.manualTaskID == task.id
        }) {
            return "已完成"
        }
        if let item = store.todayPlan?.items.first(where: { $0.source.manualTaskID == task.id }) {
            return item.status == .inProgress ? "进行中" : "今日计划中"
        }
        if let dueDate = task.dueDate, dueDate > context.now {
            return "等待到期"
        }
        return "待安排"
    }

    // MARK: 计划项（全部来源）

    @ViewBuilder
    private var itemsSection: some View {
        card(title: "全部计划项", icon: "list.bullet.rectangle", tint: StudyDesign.Colors.success) {
            if items.isEmpty {
                Text("今天没有安排任务。可能是没有到期任务，也可能是可用时间为 0。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                    ForEach(orderedKinds, id: \.self) { kind in
                        let group = items.filter { $0.source.kind == kind }
                        if !group.isEmpty {
                            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                                Text("\(kind.label)（\(group.count)）")
                                    .font(StudyDesign.Typography.supporting.weight(.semibold))
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                ForEach(group) { item in
                                    itemRow(item)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var orderedKinds: [DailyPlanItemSourceKind] {
        let present = Set(items.map(\.source.kind))
        return [.courseReview, .preview, .reviewTask, .manual].filter { present.contains($0) }
    }

    private func itemRow(_ item: DailyPlanItem) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                Text(item.title)
                    .font(StudyDesign.Typography.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(item.status.label)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }

            Text(detailLine(item))
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let explanation = item.durationEstimateExplanation {
                Text(explanation)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let completion = completionEvent(for: item) {
                Text(durationLine(completion))
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(completion.hasRecordedDuration ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)

                if !completion.hasRecordedDuration {
                    Button("补记时长") {
                        correctingCompletionID = completion.id
                        manualMinutes = max(5, item.estimatedMinutes)
                    }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                    .font(StudyDesign.Typography.supporting)
                }

                if correctingCompletionID == completion.id {
                    manualDurationEditor(completion)
                }
            }

            if item.isScheduledAfterDueDate {
                Text("到期日与实际安排日不同：到期 \(dayText(item.dueDate))，安排到 \(item.scheduledDayKey.localDateString)")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(StudyDesign.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                .fill(StudyDesign.Colors.dataBackground)
        )
        .accessibilityElement(children: .combine)
    }

    private func detailLine(_ item: DailyPlanItem) -> String {
        var parts: [String] = []
        if let start = item.scheduledStart, let end = item.scheduledEnd {
            parts.append("\(timeText(start))–\(timeText(end))")
        } else {
            parts.append("未定具体时间")
        }
        parts.append("预计 \(item.estimatedMinutes) 分钟")
        parts.append("计划 \(item.plannedScope.displayText)")
        if let achieved = item.achievedScope, !achieved.isZero {
            parts.append("已完成 \(achieved.displayText)")
        }
        if let tier = item.completionTier {
            parts.append(tier.label)
        }
        if item.isPinned {
            parts.append("已固定")
        }
        parts.append("来源：\(item.source.kind.label)")
        return parts.joined(separator: " · ")
    }

    /// 计划项对应的最新完成事件（撤销的不算）。
    private func completionEvent(for item: DailyPlanItem) -> CompletionEvent? {
        store.snapshot.completionEvents
            .filter { $0.planItemID == item.id && !$0.isRevoked }
            .max { $0.completedAt < $1.completedAt }
    }

    private func durationLine(_ completion: CompletionEvent) -> String {
        if completion.hasRecordedDuration {
            var text = "实际时长：\(completion.actualMinutes) 分钟（\(completion.durationSource.label)）"
            if let note = completion.durationNote, !note.isEmpty {
                text += " · \(note)"
            }
            return text
        }
        return completion.durationSource == .unrecorded
            ? "未记录时长：完成已计入，但不计入学习分钟数，也不参与时长类奖励。"
            : "时长来源：\(completion.durationSource.label)"
    }

    private func manualDurationEditor(_ completion: CompletionEvent) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Stepper(value: $manualMinutes, in: 0...600, step: 5) {
                Text("补记 \(manualMinutes) 分钟")
                    .font(StudyDesign.Typography.supporting)
            }
            TextField("补记原因（会保留在记录里）", text: $manualReason)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: StudyDesign.Spacing.tight) {
                Button("保存补记") {
                    let reason = manualReason.trimmingCharacters(in: .whitespacesAndNewlines)
                    correctingCompletionID = nil
                    Task {
                        await store.recordManualDuration(
                            completionID: completion.id,
                            minutes: manualMinutes,
                            reason: reason.isEmpty ? "用户补记" : reason
                        )
                    }
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))

                Button("取消") { correctingCompletionID = nil }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
            }
            .font(StudyDesign.Typography.supporting)
        }
        .padding(StudyDesign.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                .fill(StudyDesign.Colors.dataBackground)
        )
    }

    // MARK: 放不下

    @ViewBuilder
    private var unplaceableSection: some View {
        if let plan, !plan.unplaceable.isEmpty {
            card(title: "今天放不下（\(plan.unplaceable.count)）", icon: "exclamationmark.circle", tint: StudyDesign.Colors.warning) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    ForEach(plan.unplaceable) { entry in
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                            Text(entry.title)
                                .font(StudyDesign.Typography.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(entry.reason.label)：\(entry.detail)")
                                .font(StudyDesign.Typography.supporting)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("这些任务不会被删除，也不会被算作完成；可以顺延、减量，或调整可用时间。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 解释

    @ViewBuilder
    private var explanationSection: some View {
        if showsExplanation {
            card(title: "计划解释", icon: "text.bubble", tint: StudyDesign.Colors.info) {
                if let plan, !plan.explanation.isEmpty {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        ForEach(plan.explanation.lines, id: \.self) { line in
                            explanationLine(line, tint: StudyDesign.Colors.labelPrimary)
                        }
                        ForEach(plan.explanation.assumptions, id: \.self) { line in
                            explanationLine("假设：\(line)", tint: StudyDesign.Colors.labelSecondary)
                        }
                        ForEach(plan.explanation.blockedReasons, id: \.self) { line in
                            explanationLine("受阻：\(line)", tint: StudyDesign.Colors.warning)
                        }
                    }
                } else {
                    Text("还没有可展示的解释。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
            }
        }
    }

    private func explanationLine(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(StudyDesign.Typography.supporting)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 通用样式

    private func card<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                            .fill(StudyDesign.Colors.dataBackground)
                    )
                Text(title)
                    .font(StudyDesign.Typography.sectionTitle)
            }
            content()
        }
        .padding(StudyDesign.Spacing.wide)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .fill(StudyDesign.Colors.cardBackground)
        )
    }

    private func noticeCard(text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(StudyDesign.Spacing.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .fill(tint.opacity(0.12))
        )
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = context.timeZone
        return formatter.string(from: date)
    }

    private func dayText(_ date: Date?) -> String {
        guard let date else { return "无到期日" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        formatter.timeZone = context.timeZone
        return formatter.string(from: date)
    }
}
