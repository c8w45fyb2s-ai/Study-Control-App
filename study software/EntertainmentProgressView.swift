import SwiftUI

// MARK: - E 模块：娱乐资格进度页
//
// 只读展示：条件进度、依据的完成事件、无法判定的规则与最终说明。
// 页面不修改任何数据，领取/开始/结束等动作通过 `onIntents` 交给 G。

struct EntertainmentProgressView: View {
    var context: EntertainmentRulesContext
    var onRefresh: () -> Void
    var onIntents: ([EntertainmentSessionIntent]) -> Void
    var onClose: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                    summaryCard
                    if context.rules.isEmpty {
                        StudyEmptyState(
                            title: "今天没有生效的娱乐规则",
                            subtitle: "规则可能未启用、超出生效区间，或今天不是勾选的星期。",
                            icon: "calendar.badge.clock",
                            accentIcon: "info.circle",
                            accentTint: StudyDesign.Colors.info
                        )
                    } else {
                        ruleProgressList
                    }
                    undecidableCard
                    explanationCard
                }
                .padding(StudyDesign.Spacing.roomy)
                .frame(maxWidth: StudyDesign.Layout.readingMaxWidth, alignment: .leading)
            }
            .navigationTitle("娱乐资格进度")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onRefresh()
                    } label: {
                        Label("重新计算", systemImage: "arrow.clockwise")
                    }
                }
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", action: onClose)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }

    // MARK: 今日汇总

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text(context.dayKey.localDateString)
                .font(StudyDesign.Typography.cardTitle)
            Text(context.summary.explanation)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: StudyDesign.Spacing.tight) {
                metricTile("标准完成", "\(context.summary.standardCompletedItemCount) 项")
                metricTile("保底完成", "\(context.summary.minimumCompletedItemCount) 项")
                metricTile("记录时长", context.summary.recordedMinutes.map { "\($0) 分钟" } ?? "未知")
                metricTile("可领取", "\(context.claimableGrants.count) 条")
            }

            Text("判定只使用完成事件与计划项：不读取复习任务状态，跨天不累计，撤销的记录不计入，答题正确率不影响资格。")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .studyCard()
    }

    private func metricTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
            Text(title)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.dataBackground)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)")
    }

    // MARK: 每条规则

    private var ruleProgressList: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text("条件进度")
                .font(StudyDesign.Typography.cardTitle)

            ForEach(context.rules) { rule in
                ruleRow(rule)
            }
        }
    }

    private func ruleRow(_ rule: EntertainmentRule) -> some View {
        let progress = context.progress(for: rule)
        let grant = context.grant(for: rule)
        let needsAdjustment = context.adjustmentRuleIDs.contains(rule.id)
        let notes = context.evaluation.explanation.filter { $0.contains(rule.name) }

        return VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(rule.name.isEmpty ? "未命名规则" : rule.name)
                        .font(StudyDesign.Typography.body.weight(.semibold))
                    Text("\(rule.condition.displayText) · \(rule.repeatText) · 奖励 \(rule.rewardMinutes) 分钟")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: StudyDesign.Spacing.tight)
                chip(
                    needsAdjustment ? "需要调整" : (progress?.isSatisfied == true ? "已达标" : "未满足"),
                    tint: needsAdjustment
                        ? StudyDesign.Colors.warning
                        : (progress?.isSatisfied == true ? StudyDesign.Colors.success : StudyDesign.Colors.labelSecondary)
                )
            }

            if let progress {
                ProgressView(value: progress.ratio ?? 0)
                    .tint(progress.isSatisfied ? StudyDesign.Colors.success : StudyDesign.Colors.primary)
                    .accessibilityLabel("\(rule.name) 条件进度")
                    .accessibilityValue(progress.detail)

                detailLine("当前", "\(formatted(progress.achievedValue)) / \(formatted(progress.requiredValue)) \(progress.metric.unitLabel)")
                detailLine("口径", progress.metric.label)
                detailLine("依据", "\(progress.basisEventIDs.count) 条完成事件")
                if !rule.boundTargets.isEmpty {
                    detailLine("绑定", rule.boundTargets.map(\.displayText).joined(separator: "、"))
                    detailLine("要求", "所有绑定实例必须全部完成（多条件按「全部满足」处理）")
                }
            } else {
                detailLine("当前", "该规则今天不生效（未启用、超出区间或不在勾选的星期）")
            }

            if let grant {
                detailLine("奖励", "\(grant.state.label) · \(grant.grantedMinutes) 分钟 · 剩余 \(grant.remainingMinutes) 分钟 · 第 \(grant.ruleSnapshot.ruleVersion) 版")
            }

            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: needsAdjustment ? "exclamationmark.triangle" : "info.circle")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(needsAdjustment ? StudyDesign.Colors.warning : StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if grant?.isClaimable == true {
                Button("领取 \(grant?.grantedMinutes ?? 0) 分钟") {
                    guard let grant else { return }
                    onIntents([.requestClaim(grantID: grant.id)])
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .studyCard()
        .studyCardStroke(color: needsAdjustment ? StudyDesign.Colors.warning.opacity(0.5) : StudyDesign.Colors.accentHairline)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Text(title)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(StudyDesign.Typography.supporting)
            .foregroundStyle(tint)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.micro)
            .background(tint.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
    }

    // MARK: 无法判定

    @ViewBuilder
    private var undecidableCard: some View {
        if !context.evaluation.undecidableRuleRevisionIDs.isEmpty {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Label("有 \(context.evaluation.undecidableRuleRevisionIDs.count) 条规则无法判定", systemImage: "questionmark.circle")
                    .font(StudyDesign.Typography.cardTitle)
                    .foregroundStyle(StudyDesign.Colors.warning)
                Text("这些学习日只有旧版本的每日完成总数，缺少任务明细与学习时长。系统不会据此推算时长、明细或娱乐资格，因此不会补发奖励。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .studyCard(fill: StudyDesign.Colors.warning.opacity(0.08))
        }
    }

    // MARK: 判定说明

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
            Text("判定说明")
                .font(StudyDesign.Typography.cardTitle)
            if context.evaluation.explanation.isEmpty {
                Text("今天没有需要说明的判定。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            } else {
                ForEach(context.evaluation.explanation, id: \.self) { line in
                    Text("• \(line)")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let authorized = context.notificationAuthorized, !authorized {
                Text("• 系统通知不可用：到点提醒不会弹出，页面内计时仍然可用。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .studyCard(fill: StudyDesign.Colors.dataBackground)
    }
}
