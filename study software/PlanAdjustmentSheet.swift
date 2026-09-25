import SwiftUI

// MARK: - D 模块：减量方案弹层
//
// 职责边界（公共约束 6：界面不直接修改快照）：
// - 只展示 `MinimumPlanProposal`（由策略算好）与调用方注入的娱乐影响；
// - 通过 `onApply` / `onKeepCurrentPlan` 回调交互，不写文件、不发通知；
// - 娱乐影响**必须由 E 提供**，本视图绝不自行推算（交互要求第 5 条）。
//
// 弹层必须显示（交互要求）：
// 1. 原计划与新计划的分钟数；
// 2. 保留的任务；
// 3. 被缩减或推迟的任务；
// 4. 对今日完成状态的影响；
// 5. 娱乐影响（由 E 注入，缺失时明确显示"尚未接入"）；
// 6. 「采用方案」与「保持当前计划」两个按钮。

// MARK: - 娱乐影响（E 注入）
//
// 类型直接复用 E 模块的 `EntertainmentReductionImpact`（`RewardEvaluator.swift`）：
// D 只负责展示，绝不自行推算娱乐资格或奖励分钟。
// `EntertainmentImpactPresentation` 只是"E 是否已接入"的显式包装，
// 不允许用它来编造一个推算出来的资格结论。

/// 娱乐影响的展示包装。
enum EntertainmentImpactPresentation: Hashable, Sendable {
    /// E 已接入：使用 E 计算出的逐规则影响。
    case evaluated([EntertainmentReductionImpact])
    /// 当天没有生效的娱乐规则（E 明确返回空）。
    case noEffectiveRules
    /// E 尚未接入：如实说明，不做任何推算。
    case unavailable

    var impacts: [EntertainmentReductionImpact] {
        if case .evaluated(let impacts) = self { return impacts }
        return []
    }

    /// 是否有任一规则在减量后仍预计发放奖励。
    var hasAnyReducedReward: Bool {
        impacts.contains { $0.reducedMinutes > 0 }
    }

    /// 是否有任一规则在减量后会失去奖励。
    var losesAnyEntitlement: Bool {
        impacts.contains(where: \.losesEntitlement)
    }
}

// MARK: - 弹层

/// 减量方案弹层。
struct PlanAdjustmentSheet: View {
    /// 策略产出的提案（含变更明细与解释）。
    var proposal: MinimumPlanProposal
    /// 娱乐影响；由 E 注入。`nil` 等价于"尚未接入"，界面如实说明而不推算。
    var entertainmentImpact: EntertainmentImpactPresentation?
    /// 剩余可用分钟（用于解释"为什么这么压"）。
    var remainingMinutes: Int

    var onApply: () -> Void
    var onKeepCurrentPlan: () -> Void

    init(
        proposal: MinimumPlanProposal,
        entertainmentImpact: EntertainmentImpactPresentation? = nil,
        remainingMinutes: Int = 0,
        onApply: @escaping () -> Void,
        onKeepCurrentPlan: @escaping () -> Void
    ) {
        self.proposal = proposal
        self.entertainmentImpact = entertainmentImpact
        self.remainingMinutes = max(0, remainingMinutes)
        self.onApply = onApply
        self.onKeepCurrentPlan = onKeepCurrentPlan
    }

    private var mode: DailyPlanMode {
        // 与协调层采用同一口径：休息 > 保底 > 轻量 > 标准。
        // 预览显示的档位必须与应用后的档位一致（验收要求）。
        if proposal.isRestSuggestion { return .rest }
        return proposal.plan.mode
    }

    private var trimmedChanges: [MinimumPlanChange] { proposal.changes(of: .trimmed) }
    private var deferredChanges: [MinimumPlanChange] { proposal.changes(of: .deferred) + proposal.changes(of: .removed) }
    private var keptChanges: [MinimumPlanChange] { proposal.changes(of: .kept) }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            header

            if proposal.isRestSuggestion {
                restView
            } else {
                minutesComparison
                if !trimmedChanges.isEmpty { changeSection(title: "被缩减的内容", changes: trimmedChanges) }
                if !deferredChanges.isEmpty { changeSection(title: "被推迟的任务", changes: deferredChanges) }
                keptSection
                impactSection
                entertainmentSection
                explanationSection
            }

            footer
        }
        .padding(StudyDesign.Spacing.wide)
        .frame(minWidth: 460, idealWidth: 520, maxWidth: 640, alignment: .leading)
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Image(systemName: proposal.isEmpty ? "moon.zzz" : "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(proposal.isEmpty ? StudyDesign.Colors.info : StudyDesign.Colors.primary)
                Text(proposal.isEmpty ? "建议休息" : "减量方案")
                    .font(StudyDesign.Typography.sectionTitle)
                Spacer()
                if !proposal.isEmpty {
                    Text(mode.label)
                        .font(StudyDesign.Typography.supporting)
                        .padding(.horizontal, StudyDesign.Spacing.tight)
                        .padding(.vertical, 3)
                        .background(StudyDesign.Colors.accentSubtle)
                        .clipShape(Capsule())
                }
            }
            Text("剩余可用时间 \(remainingMinutes) 分钟。以下方案只调整**尚未开始**的部分，已完成的内容不会消失。")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 休息建议

    private var restView: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text("今天不安排保底任务")
                .font(StudyDesign.Typography.cardTitle)
            ForEach(proposal.explanation.blockedReasons, id: \.self) { reason in
                Text(reason)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("没有任务会被标记为完成，未完成的内容会顺延到后续计划。")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
        .padding(StudyDesign.Spacing.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyDesign.Colors.info.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
    }

    // MARK: 分钟对比

    private var minutesComparison: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.roomy) {
            minuteColumn(title: "原计划", minutes: proposal.originalMinutes, emphasized: false)
            Image(systemName: "arrow.right")
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
            minuteColumn(title: "新方案", minutes: proposal.reducedMinutes, emphasized: true)
            Spacer(minLength: 0)
            if savedMinutes > 0 {
                Text("减少 \(savedMinutes) 分钟")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.success)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyDesign.Colors.dataBackground)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
    }

    private var savedMinutes: Int { max(0, proposal.originalMinutes - proposal.reducedMinutes) }

    private func minuteColumn(title: String, minutes: Int, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            Text("\(minutes) 分钟")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(emphasized ? StudyDesign.Colors.primary : StudyDesign.Colors.labelPrimary)
        }
    }

    // MARK: 变更明细

    private func changeSection(title: String, changes: [MinimumPlanChange]) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text(title)
                .font(StudyDesign.Typography.cardTitle)
            ForEach(changes) { change in
                changeRow(change)
            }
        }
    }

    private func changeRow(_ change: MinimumPlanChange) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Text(change.title)
                    .font(StudyDesign.Typography.body)
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(change.kind.label)
                    .font(.system(size: 11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(StudyDesign.Colors.accentSubtle)
                    .clipShape(Capsule())
            }
            HStack(spacing: StudyDesign.Spacing.tight) {
                if let before = change.beforeScope {
                    Text(before.displayText)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    if let after = change.afterScope {
                        Image(systemName: "arrow.right")
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        Text(after.displayText)
                            .foregroundStyle(StudyDesign.Colors.primary)
                    }
                }
                Text("\(change.beforeMinutes) → \(change.afterMinutes) 分钟")
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }
            .font(StudyDesign.Typography.supporting)
            if !change.reason.isEmpty {
                Text(change.reason)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyDesign.Colors.surfaceFill)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
    }

    // MARK: 保留任务

    private var keptSection: some View {
        // 保留 = 新方案里仍在执行、且没有出现在变更明细中的任务。
        // 已被缩减的任务只在上面的"被缩减的内容"里出现一次，不重复展示。
        let changedIDs = Set(proposal.changes.map(\.itemID))
        let kept = proposal.plan.items.filter {
            ($0.status == .pending || $0.status == .inProgress) && !changedIDs.contains($0.id)
        }
        return Group {
            if !kept.isEmpty {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    Text("保留的任务（\(kept.count) 项）")
                        .font(StudyDesign.Typography.cardTitle)
                    ForEach(kept) { item in
                        HStack(spacing: StudyDesign.Spacing.tight) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(StudyDesign.Colors.success)
                            Text(item.title)
                                .font(StudyDesign.Typography.body)
                            Spacer(minLength: 0)
                            Text("\(item.plannedScope.displayText) · \(item.estimatedMinutes) 分钟")
                                .font(StudyDesign.Typography.supporting)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 今日完成状态影响

    private var impactSection: some View {
        let impact = proposal.progressImpact
        return VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text("对今日完成状态的影响")
                .font(StudyDesign.Typography.cardTitle)
            Text(impact.summaryText)
                .font(StudyDesign.Typography.body)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("已经完成的任务不会因为减量而消失，也不会被改判。")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
    }

    // MARK: 娱乐影响（E 注入）

    private var entertainmentSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text("娱乐影响（由娱乐奖励评估提供）")
                .font(StudyDesign.Typography.cardTitle)

            switch entertainmentImpact ?? .unavailable {
            case .unavailable:
                Text("尚未接入娱乐奖励评估，本次不显示娱乐影响。D 不会自行推算娱乐资格，也不会因此改变任何奖励规则。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)

            case .noEffectiveRules:
                Text("当天没有生效的娱乐规则，减量不影响娱乐额度。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)

            case .evaluated(let impacts):
                ForEach(impacts) { impact in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: StudyDesign.Spacing.tight) {
                            Text(impact.ruleName)
                                .font(StudyDesign.Typography.body)
                                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                            Spacer(minLength: 0)
                            Text("\(impact.standardMinutes) → \(impact.reducedMinutes) 分钟")
                                .font(StudyDesign.Typography.supporting)
                                .foregroundStyle(impact.losesEntitlement
                                                 ? StudyDesign.Colors.warning
                                                 : StudyDesign.Colors.labelSecondary)
                        }
                        ForEach(impact.lines, id: \.self) { line in
                            Text(line)
                                .font(StudyDesign.Typography.supporting)
                                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if (entertainmentImpact ?? .unavailable).losesAnyEntitlement {
                    Text("注意：采用减量后，上面标出的规则预计拿不到娱乐额度。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.warning)
                }
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyDesign.Colors.surfaceFill)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
    }

    // MARK: 解释

    private var explanationSection: some View {
        Group {
            if !proposal.explanation.lines.isEmpty || !proposal.explanation.blockedReasons.isEmpty {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    Text("为什么这样压")
                        .font(StudyDesign.Typography.cardTitle)
                    ForEach(proposal.explanation.lines, id: \.self) { line in
                        Text(line)
                            .font(StudyDesign.Typography.supporting)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(proposal.explanation.blockedReasons, id: \.self) { line in
                        Text(line)
                            .font(StudyDesign.Typography.supporting)
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack(spacing: StudyDesign.Spacing.standard) {
            Button("保持当前计划") { onKeepCurrentPlan() }
                .buttonStyle(.bordered)
            Spacer(minLength: 0)
            Button(proposal.isRestSuggestion ? "保持当前计划，今天休息" : "采用方案") { onApply() }
                .buttonStyle(.borderedProminent)
                .disabled(proposal.isRestSuggestion)
        }
    }
}

// MARK: - 预览

#if DEBUG
struct PlanAdjustmentSheet_Previews: PreviewProvider {
    static var previews: some View {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let dayKey = StudyDayKey(date: now, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let planID = UUID()
        let itemID = UUID()
        let item = DailyPlanItem(
            id: itemID,
            planID: planID,
            source: .reviewTask(UUID()),
            title: "复习任务：线性代数特征值",
            plannedScope: .questions(5),
            minimumScope: .questions(2),
            estimatedMinutes: 20,
            scheduledDayKey: dayKey,
            isSplittable: true,
            createdAt: now,
            updatedAt: now
        )
        var plan = DailyStudyPlan(
            id: planID,
            dayKey: dayKey,
            budget: DailyPlanBudget(capacityMinutes: 60, plannedMinutes: 20),
            items: [item],
            createdAt: now,
            updatedAt: now
        )
        plan.items[0].plannedScope = .questions(2)
        plan.items[0].estimatedMinutes = 8

        let proposal = MinimumPlanProposal(
            plan: plan,
            changes: [
                MinimumPlanChange(
                    itemID: itemID,
                    title: item.title,
                    kind: .trimmed,
                    beforeScope: .questions(5),
                    afterScope: .questions(2),
                    beforeMinutes: 20,
                    afterMinutes: 8,
                    reason: "剩余 12 分钟，把 5 道题缩到 2 道题，保留可交付的一部分内容。"
                )
            ],
            explanation: DailyPlanExplanation(
                lines: ["剩余 12 分钟，已压到保底：只保留 1 条明确动作。"],
                blockedReasons: ["缩小范围：1 项。"]
            ),
            isEmpty: false
        )

        return PlanAdjustmentSheet(
            proposal: proposal,
            entertainmentImpact: .evaluated([
                EntertainmentReductionImpact(
                    ruleID: UUID(),
                    ruleName: "完成今日计划后可娱乐",
                    standardMinutes: 30,
                    reducedMinutes: 15,
                    losesEntitlement: false,
                    conditionIsReductionProof: false,
                    lines: ["减量后预计奖励从 30 分钟降为 15 分钟（按比例折算）。"]
                )
            ]),
            remainingMinutes: 12,
            onApply: {},
            onKeepCurrentPlan: {}
        )
    }
}
#endif
