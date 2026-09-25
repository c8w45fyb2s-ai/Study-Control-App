import SwiftUI

// MARK: - E 模块：娱乐规则编辑器
//
// 只编辑本地草稿，保存回调交给 G 的统一写入入口（`AppStore.saveEntertainmentRule`）。
// 本文件不读写 store.json、不发通知、不改全局状态。

// MARK: - 条件预设

/// 首版支持的四种解锁条件。
///
/// 多个条件（度量条件 + 多个指定实例）统一按"全部满足"处理，
/// 因此不引入复杂的条件组合编辑器。
enum EntertainmentConditionPreset: String, CaseIterable, Identifiable, Sendable {
    case designatedTasks
    case accumulatedMinutes
    case minimumGoal
    case standardGoal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .designatedTasks: return "完成指定任务"
        case .accumulatedMinutes: return "累计学习时长"
        case .minimumGoal: return "完成今日保底目标"
        case .standardGoal: return "完成今日标准目标"
        }
    }

    var icon: String {
        switch self {
        case .designatedTasks: return "checklist"
        case .accumulatedMinutes: return "timer"
        case .minimumGoal: return "flag"
        case .standardGoal: return "target"
        }
    }

    var detail: String {
        switch self {
        case .designatedTasks:
            return "绑定今天计划里的具体任务或复习实例。绑定按学习日计算，昨天完成同一个知识点不会解锁今天。"
        case .accumulatedMinutes:
            return "按当天真实记录的分钟数判定。固定时长条件不受自动减量影响。"
        case .minimumGoal:
            return "达到保底档的任务数即可解锁，适合搭配保底替代。"
        case .standardGoal:
            return "需要达到原计划范围（标准完成）。适合允许保底替代的规则。"
        }
    }

    /// 保底替代对该预设的默认建议。
    var fallbackAdvice: String {
        switch self {
        case .designatedTasks, .accumulatedMinutes:
            return "指定任务与固定时长条件默认保持不变。开启保底替代后，减量日也可能发放奖励。"
        case .minimumGoal, .standardGoal:
            return "「跟随今日目标」的规则可以明确允许保底替代：保底奖励时长单独设置，不会默认发放标准奖励。"
        }
    }

    var isGoalFollowing: Bool {
        self == .minimumGoal || self == .standardGoal
    }
}

// MARK: - 保底替代选项

enum EntertainmentFallbackChoice: String, CaseIterable, Identifiable, Sendable {
    case fixedMinimumReward
    case scaledReward
    case unlockRegardless
    case suspend

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fixedMinimumReward: return "保底固定时长"
        case .scaledReward: return "按完成比例缩短"
        case .unlockRegardless: return "始终解锁"
        case .suspend: return "当天不发放"
        }
    }

    var detail: String {
        switch self {
        case .fixedMinimumReward: return "当天只要有学习记录，就发放下面单独设置的保底时长。"
        case .scaledReward: return "按当天完成比例缩短奖励，并保留至少指定比例。"
        case .unlockRegardless: return "即使没达标也照常发放标准时长（仍要求当天有学习记录）。"
        case .suspend: return "减量日不发放任何奖励。"
        }
    }

    func mode(minutes: Int, ratio: Double) -> EntertainmentFallbackMode {
        switch self {
        case .fixedMinimumReward: return .fixedMinimumReward(minutes: max(0, minutes))
        case .scaledReward: return .scaledReward(ratio: min(max(ratio, 0), 1))
        case .unlockRegardless: return .unlockRegardless
        case .suspend: return .suspend
        }
    }

    static func from(_ mode: EntertainmentFallbackMode) -> EntertainmentFallbackChoice? {
        switch mode {
        case .none: return nil
        case .fixedMinimumReward: return .fixedMinimumReward
        case .scaledReward: return .scaledReward
        case .unlockRegardless: return .unlockRegardless
        case .suspend: return .suspend
        }
    }
}

// MARK: - 草稿

/// 规则编辑草稿：界面与持久化之间的唯一载体。
struct EntertainmentRuleDraft: Hashable {
    var ruleID: UUID?
    var name: String
    var preset: EntertainmentConditionPreset
    /// 指定实例绑定（仅 `designatedTasks` 使用）。
    var targets: [EntertainmentTargetBinding]
    var usesWeeklyRepeat: Bool
    /// 1 = 周日 … 7 = 周六。
    var weekdays: Set<Int>
    var usesEffectiveRange: Bool
    var effectiveFrom: StudyDayKey?
    var effectiveUntil: StudyDayKey?
    /// 「保底/标准目标」需要的任务项数。
    var requiredItemCount: Int
    /// 「累计学习时长」需要的分钟数。
    var requiredMinutes: Int
    var rewardMinutes: Int
    var allowsFallback: Bool
    var fallbackChoice: EntertainmentFallbackChoice
    var fallbackMinutes: Int
    var fallbackRatio: Double
    var isEnabled: Bool

    init(
        ruleID: UUID? = nil,
        name: String = "",
        preset: EntertainmentConditionPreset = .designatedTasks,
        targets: [EntertainmentTargetBinding] = [],
        usesWeeklyRepeat: Bool = false,
        weekdays: Set<Int> = [],
        usesEffectiveRange: Bool = false,
        effectiveFrom: StudyDayKey? = nil,
        effectiveUntil: StudyDayKey? = nil,
        requiredItemCount: Int = 1,
        requiredMinutes: Int = 60,
        rewardMinutes: Int = 30,
        allowsFallback: Bool = false,
        fallbackChoice: EntertainmentFallbackChoice = .fixedMinimumReward,
        fallbackMinutes: Int = 10,
        fallbackRatio: Double = 0.5,
        isEnabled: Bool = true
    ) {
        self.ruleID = ruleID
        self.name = name
        self.preset = preset
        self.targets = targets
        self.usesWeeklyRepeat = usesWeeklyRepeat
        self.weekdays = weekdays
        self.usesEffectiveRange = usesEffectiveRange
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.requiredItemCount = max(1, requiredItemCount)
        self.requiredMinutes = max(1, requiredMinutes)
        self.rewardMinutes = max(1, rewardMinutes)
        self.allowsFallback = allowsFallback
        self.fallbackChoice = fallbackChoice
        self.fallbackMinutes = max(1, fallbackMinutes)
        self.fallbackRatio = min(max(fallbackRatio, 0), 1)
        self.isEnabled = isEnabled
    }

    /// 从既有规则还原草稿（编辑入口）。
    init(rule: EntertainmentRule, fallbackDefaultMinutes: Int = 10) {
        let preset: EntertainmentConditionPreset
        switch rule.condition.metric {
        case .standardCompletedItemCount: preset = .standardGoal
        case .minimumCompletedItemCount: preset = .minimumGoal
        case .recordedMinutes: preset = .accumulatedMinutes
        default: preset = rule.boundTargets.isEmpty ? .minimumGoal : .designatedTasks
        }
        let choice = EntertainmentFallbackChoice.from(rule.fallback)
        let fallbackMinutes: Int
        let fallbackRatio: Double
        switch rule.fallback {
        case .fixedMinimumReward(let minutes): fallbackMinutes = max(1, minutes)
        default: fallbackMinutes = max(1, fallbackDefaultMinutes)
        }
        switch rule.fallback {
        case .scaledReward(let ratio): fallbackRatio = min(max(ratio, 0), 1)
        default: fallbackRatio = 0.5
        }

        self.init(
            ruleID: rule.id,
            name: rule.name,
            preset: preset,
            targets: rule.boundTargets,
            usesWeeklyRepeat: !rule.occursEveryDay,
            weekdays: Set(rule.repeatWeekdays ?? []),
            usesEffectiveRange: rule.effectiveFrom != nil || rule.effectiveUntil != nil,
            effectiveFrom: rule.effectiveFrom,
            effectiveUntil: rule.effectiveUntil,
            requiredItemCount: max(1, Int(rule.condition.requiredValue.rounded())),
            requiredMinutes: max(1, Int(rule.condition.requiredValue.rounded())),
            rewardMinutes: max(1, rule.rewardMinutes),
            allowsFallback: choice != nil,
            fallbackChoice: choice ?? .fixedMinimumReward,
            fallbackMinutes: fallbackMinutes,
            fallbackRatio: fallbackRatio,
            isEnabled: rule.isEnabled
        )
    }

    // MARK: 派生

    var condition: EntertainmentUnlockCondition {
        switch preset {
        case .designatedTasks:
            // 度量条件是"当天有学习"，真正的要求是下面的指定实例（全部满足）。
            return EntertainmentUnlockCondition(metric: .anyStudied, requiredValue: 1)
        case .accumulatedMinutes:
            return .minutes(requiredMinutes)
        case .minimumGoal:
            return .minimumItems(requiredItemCount)
        case .standardGoal:
            return .standardItems(requiredItemCount)
        }
    }

    var repeatWeekdays: [Int]? {
        guard usesWeeklyRepeat else { return nil }
        let values = weekdays.filter { (1...7).contains($0) }
        return values.isEmpty ? nil : values.sorted()
    }

    var effectiveFromValue: StudyDayKey? { usesEffectiveRange ? effectiveFrom : nil }
    var effectiveUntilValue: StudyDayKey? { usesEffectiveRange ? effectiveUntil : nil }

    var fallback: EntertainmentFallbackMode {
        guard allowsFallback else { return .none }
        return fallbackChoice.mode(minutes: fallbackMinutes, ratio: fallbackRatio)
    }

    var validationIssues: [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("请填写娱乐名称。")
        }
        if preset == .designatedTasks, targets.isEmpty {
            issues.append("「完成指定任务」至少绑定一条今天的计划任务或复习实例。")
        }
        if usesWeeklyRepeat, repeatWeekdays == nil {
            issues.append("选择了每周重复，请至少勾选一个星期。")
        }
        if usesEffectiveRange {
            if let from = effectiveFrom, let until = effectiveUntil, until < from {
                issues.append("生效结束日期不能早于开始日期。")
            }
        }
        if rewardMinutes <= 0 {
            issues.append("奖励时长需要大于 0 分钟。")
        }
        if allowsFallback, fallbackChoice == .fixedMinimumReward, fallbackMinutes > rewardMinutes {
            issues.append("保底时长不能超过标准奖励时长。")
        }
        return issues
    }

    var isValid: Bool { validationIssues.isEmpty }

    var summaryText: String {
        var parts = [condition.displayText]
        if !boundTargets.isEmpty {
            parts.append("须全部完成：" + boundTargets.map(\.displayText).joined(separator: "、"))
        }
        if usesWeeklyRepeat, let weekdays = repeatWeekdays {
            let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            parts.append("每周 " + weekdays.compactMap { (1...7).contains($0) ? names[$0] : nil }.joined(separator: "、"))
        } else {
            parts.append("每天生效")
        }
        parts.append("奖励 \(rewardMinutes) 分钟")
        parts.append(allowsFallback ? "允许保底替代（\(fallback.label)）" : "不做保底替代")
        return parts.joined(separator: "；")
    }

    private var boundTargets: [EntertainmentTargetBinding] {
        preset == .designatedTasks ? targets : []
    }
}

// MARK: - 编辑器

struct EntertainmentRuleEditor: View {
    /// 规划上下文：日期换算全部走它，不读系统时钟。
    var context: PlanningContext
    /// 可绑定的真实候选（今天的计划项 + 复习实例）。
    var candidates: [EntertainmentTargetCandidate]
    /// 今天计划的任务数，用作「标准目标」的默认项数。
    var todayPlannedItemCount: Int
    var onSave: (EntertainmentRuleDraft) -> StoreChangeResult
    var onCancel: () -> Void

    @State private var draft: EntertainmentRuleDraft
    @State private var saveError: String?

    init(
        context: PlanningContext,
        candidates: [EntertainmentTargetCandidate],
        todayPlannedItemCount: Int,
        draft: EntertainmentRuleDraft,
        onSave: @escaping (EntertainmentRuleDraft) -> StoreChangeResult,
        onCancel: @escaping () -> Void
    ) {
        self.context = context
        self.candidates = candidates
        self.todayPlannedItemCount = todayPlannedItemCount
        self.onSave = onSave
        self.onCancel = onCancel
        var initial = draft
        if initial.ruleID == nil, initial.preset == .standardGoal, initial.requiredItemCount <= 1 {
            initial.requiredItemCount = max(1, todayPlannedItemCount)
        }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section("保存失败") {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .font(StudyDesign.Typography.supporting)
                            .foregroundStyle(StudyDesign.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                basicSection
                scheduleSection
                conditionSection
                rewardSection
                fallbackSection
                previewSection
            }
            .formStyle(.grouped)
            .navigationTitle(draft.ruleID == nil ? "新建娱乐规则" : "编辑娱乐规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let result = onSave(draft)
                        saveError = result.errorMessage
                    }
                        .disabled(!draft.isValid)
                        .accessibilityHint(draft.isValid ? "保存这条娱乐规则" : "还有未填写或冲突的内容")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    // MARK: 基本信息

    private var basicSection: some View {
        Section("基本信息") {
            TextField("娱乐名称（例如：看一集动画）", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("娱乐名称")

            Toggle("启用这条规则", isOn: $draft.isEnabled)
                .accessibilityHint("停用后不再参与解锁判定，既有奖励不受影响")
        }
    }

    // MARK: 生效时间

    private var scheduleSection: some View {
        Section("生效时间") {
            Toggle("每周重复指定日期", isOn: $draft.usesWeeklyRepeat)
                .accessibilityHint("关闭时每天都生效")

            if draft.usesWeeklyRepeat {
                weekdayPicker
                if draft.repeatWeekdays == nil {
                    Label("请至少勾选一个星期。", systemImage: "exclamationmark.triangle")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.warning)
                }
            }

            Toggle("限定生效日期区间", isOn: $draft.usesEffectiveRange)
                .accessibilityHint("关闭时长期有效")

            if draft.usesEffectiveRange {
                DatePicker("开始", selection: effectiveFromBinding, displayedComponents: .date)
                DatePicker("结束", selection: effectiveUntilBinding, displayedComponents: .date)
            }
        }
    }

    private var weekdayPicker: some View {
        let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
            ForEach(1...7, id: \.self) { weekday in
                let isSelected = draft.weekdays.contains(weekday)
                Button {
                    if isSelected { draft.weekdays.remove(weekday) } else { draft.weekdays.insert(weekday) }
                } label: {
                    Text(names[weekday])
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, StudyDesign.Spacing.tight)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                                .fill(isSelected ? StudyDesign.Colors.primary.opacity(0.18) : StudyDesign.Colors.inputBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                                .stroke(isSelected ? StudyDesign.Colors.primary.opacity(0.5) : StudyDesign.Colors.accentHairline, lineWidth: 1)
                        )
                        .foregroundStyle(isSelected ? StudyDesign.Colors.primary : StudyDesign.Colors.labelSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[weekday])
                .accessibilityValue(isSelected ? "已选择" : "未选择")
            }
        }
    }

    private var effectiveFromBinding: Binding<Date> {
        Binding(
            get: { draft.effectiveFrom?.startOfDay(calendar: context.calendar) ?? context.now },
            set: { draft.effectiveFrom = StudyDayKey(date: $0, context: context) }
        )
    }

    private var effectiveUntilBinding: Binding<Date> {
        Binding(
            get: { draft.effectiveUntil?.startOfDay(calendar: context.calendar) ?? context.now },
            set: { draft.effectiveUntil = StudyDayKey(date: $0, context: context) }
        )
    }

    // MARK: 解锁条件

    private var conditionSection: some View {
        Section("解锁条件") {
            Picker("条件类型", selection: $draft.preset) {
                ForEach(EntertainmentConditionPreset.allCases) { preset in
                    Label(preset.label, systemImage: preset.icon).tag(preset)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Text(draft.preset.detail)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            switch draft.preset {
            case .designatedTasks:
                targetPicker
            case .accumulatedMinutes:
                Stepper(value: $draft.requiredMinutes, in: 5...600, step: 5) {
                    Text("累计学习 \(draft.requiredMinutes) 分钟")
                }
                .accessibilityLabel("累计学习分钟数")
            case .minimumGoal, .standardGoal:
                Stepper(value: $draft.requiredItemCount, in: 1...20, step: 1) {
                    Text("\(draft.preset == .minimumGoal ? "保底完成" : "标准完成") \(draft.requiredItemCount) 项")
                }
                .accessibilityLabel("需要的任务项数")
                if draft.preset == .standardGoal, todayPlannedItemCount > 0 {
                    Text("今天计划 \(todayPlannedItemCount) 项，默认按全部完成计算。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            if candidates.isEmpty {
                Label("今天没有可绑定的计划任务或复习实例。请先在今日计划里生成任务，或改用其他条件。", systemImage: "info.circle")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("勾选后必须全部完成才解锁（多条件按「全部满足」处理）。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                ForEach(candidates) { candidate in
                    let isSelected = draft.targets.contains { $0.kind == candidate.kind && $0.id == candidate.id }
                    Button {
                        toggleTarget(candidate)
                    } label: {
                        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isSelected ? StudyDesign.Colors.primary : StudyDesign.Colors.labelTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.title)
                                    .font(StudyDesign.Typography.body)
                                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                                    .multilineTextAlignment(.leading)
                                Text(candidate.subtitle)
                                    .font(StudyDesign.Typography.supporting)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.title)
                    .accessibilityValue(isSelected ? "已绑定" : "未绑定")
                }
            }
        }
    }

    private func toggleTarget(_ candidate: EntertainmentTargetCandidate) {
        if let index = draft.targets.firstIndex(where: { $0.kind == candidate.kind && $0.id == candidate.id }) {
            draft.targets.remove(at: index)
        } else {
            draft.targets.append(
                EntertainmentTargetBinding(
                    kind: candidate.kind,
                    id: candidate.id,
                    dayKey: candidate.dayKey,
                    displayName: candidate.title
                )
            )
        }
    }

    // MARK: 奖励时长

    private var rewardSection: some View {
        Section("奖励时长") {
            Stepper(value: $draft.rewardMinutes, in: 5...300, step: 5) {
                Text("达标后奖励 \(draft.rewardMinutes) 分钟")
            }
            .accessibilityLabel("奖励时长分钟数")
        }
    }

    // MARK: 保底替代

    private var fallbackSection: some View {
        Section("保底替代") {
            Toggle("允许保底替代", isOn: $draft.allowsFallback)
                .accessibilityHint("开启后，减量或未达标的日子也可能发放奖励")

            Text(draft.preset.fallbackAdvice)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(draft.preset.isGoalFollowing ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)

            if draft.allowsFallback {
                Picker("保底方式", selection: $draft.fallbackChoice) {
                    ForEach(EntertainmentFallbackChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Text(draft.fallbackChoice.detail)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch draft.fallbackChoice {
                case .fixedMinimumReward:
                    Stepper(value: $draft.fallbackMinutes, in: 5...300, step: 5) {
                        Text("保底发放 \(draft.fallbackMinutes) 分钟（标准 \(draft.rewardMinutes) 分钟）")
                    }
                case .scaledReward:
                    Stepper(value: $draft.fallbackRatio, in: 0.1...1.0, step: 0.1) {
                        Text("至少保留 \(Int((draft.fallbackRatio * 100).rounded()))%")
                    }
                case .unlockRegardless, .suspend:
                    EmptyView()
                }
            }
        }
    }

    // MARK: 预览与校验

    private var previewSection: some View {
        Section("预览") {
            Text(draft.summaryText)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("奖励按当天真实完成事件判定：不读取复习任务的状态，跨天不累计，撤销的完成记录不计入。")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(draft.validationIssues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 绑定候选

/// 可绑定到规则的真实实例（来自今天的计划项与复习任务）。
struct EntertainmentTargetCandidate: Identifiable, Hashable {
    var kind: EntertainmentTargetBinding.Kind
    var id: UUID
    var title: String
    var subtitle: String
    var dayKey: StudyDayKey?

    var binding: EntertainmentTargetBinding {
        EntertainmentTargetBinding(kind: kind, id: id, dayKey: dayKey, displayName: title)
    }
}
