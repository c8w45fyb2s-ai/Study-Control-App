import SwiftUI
import UserNotifications

// MARK: - E 模块：娱乐解锁与计时主页面
//
// 页面只读快照、只发回调：所有写入最终由 G 的统一入口（AppStore）完成。
// 没有通知权限时页面内解锁与计时照常工作。

/// 通知权限查询（只读，不触发系统授权弹窗）。
///
/// 页面内解锁与计时不依赖它：拿不到权限时只是少了到点提醒。
enum EntertainmentNotificationAvailability {
    static func isAuthorized() async -> Bool {
        let status = await NotificationScheduler.refreshAuthorizationStatus()
        return status == .authorized || status == .provisional
    }
}

// MARK: - 只读上下文

/// 娱乐页面所需的只读数据。
struct EntertainmentRulesContext {
    var dayKey: StudyDayKey
    /// 全部规则（含停用、超出区间、今天不在勾选星期的），用于管理。
    var rules: [EntertainmentRule]
    /// 今天生效的规则（资格判定只针对它们）。
    var effectiveRules: [EntertainmentRule]
    var grants: [RewardGrant]
    var evaluation: RewardEvaluation
    var summary: DailyStudySummary
    var targetCandidates: [EntertainmentTargetCandidate]
    /// 今天计划的任务数（用于「标准目标」默认值）。
    var todayPlannedItemCount: Int
    /// 绑定已经失效、需要用户调整的规则 ID。
    var adjustmentRuleIDs: Set<UUID>
    var notificationAuthorized: Bool?
    var now: Date
    var planningContext: PlanningContext

    func isEffectiveToday(_ rule: EntertainmentRule) -> Bool {
        effectiveRules.contains { $0.id == rule.id }
    }

    var hasAnyRule: Bool { !rules.isEmpty }

    var todayGrants: [RewardGrant] {
        grants
            .filter { $0.dayKey == dayKey }
            .sorted { $0.grantedAt < $1.grantedAt }
    }

    var visibleGrants: [RewardGrant] {
        var result = todayGrants
        if let runningGrant, !result.contains(where: { $0.id == runningGrant.id }) {
            result.append(runningGrant)
        }
        return result.sorted { $0.grantedAt < $1.grantedAt }
    }

    var runningGrant: RewardGrant? {
        EntertainmentSessionEngine.runningGrant(in: grants)
    }

    var claimableGrants: [RewardGrant] {
        todayGrants.filter { $0.isClaimable }
    }

    var mostRecentInvalidatedGrant: RewardGrant? {
        let cutoff = dayKey.advanced(byDays: -1)
        return grants
            .filter {
                ($0.state == .expired || $0.state == .revoked)
                    && $0.dayKey != dayKey
                    && $0.dayKey.timeZoneIdentifier == dayKey.timeZoneIdentifier
                    && $0.dayKey >= cutoff
                    && $0.dayKey <= dayKey
            }
            .max { $0.grantedAt < $1.grantedAt }
    }

    func progress(for rule: EntertainmentRule) -> RewardConditionProgress? {
        evaluation.progress.first { $0.ruleRevisionID == rule.revisionID }
            ?? evaluation.progress.first { $0.ruleID == rule.id }
    }

    func grant(for rule: EntertainmentRule) -> RewardGrant? {
        todayGrants.first { $0.ruleID == rule.id && !$0.isRevoked }
    }
}

extension StoreSnapshot {
    /// 组装娱乐页面的只读上下文（纯读取，不修改快照）。
    func entertainmentContext(
        context: PlanningContext,
        notificationAuthorized: Bool? = nil
    ) -> EntertainmentRulesContext {
        let dayKey = context.todayKey
        let plan = dailyPlans.first { $0.dayKey == dayKey && $0.isActive }
            ?? dailyPlans.filter { $0.dayKey == dayKey }.max { $0.version < $1.version }
        let summary = dailySummary(for: dayKey)
        let evaluation = EntertainmentRewardEvaluator().evaluate(
            rules: entitlementRules(on: dayKey),
            plan: plan,
            completions: completionEvents,
            grants: rewardGrants,
            summary: summary,
            context: context
        )

        var candidates: [EntertainmentTargetCandidate] = []
        for item in plan?.items ?? [] {
            candidates.append(
                EntertainmentTargetCandidate(
                    kind: .planItem,
                    id: item.id,
                    title: item.title,
                    subtitle: "今天的计划任务 · 计划 \(item.plannedScope.displayText) · 预计 \(item.estimatedMinutes) 分钟",
                    dayKey: dayKey
                )
            )
            if let reviewTaskID = item.source.reviewTaskID {
                candidates.append(
                    EntertainmentTargetCandidate(
                        kind: .reviewTask,
                        id: reviewTaskID,
                        title: item.title,
                        subtitle: "复习任务实例 · 今天完成该复习实例才算达成",
                        dayKey: nil
                    )
                )
            }
        }
        // 复习任务本身（今天没有排进计划，也允许绑定，避免因为重排而无法建规则）。
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = context.timeZone
        dayFormatter.locale = context.locale
        for task in reviewTasks {
            guard !candidates.contains(where: { $0.kind == .reviewTask && $0.id == task.id }) else { continue }
            candidates.append(
                EntertainmentTargetCandidate(
                    kind: .reviewTask,
                    id: task.id,
                    title: task.title.isEmpty ? "复习任务" : task.title,
                    subtitle: "复习任务实例 · 到期 \(dayFormatter.string(from: task.dueDate)) · 到期日与安排日分开，昨天完成不会解锁今天",
                    dayKey: nil
                )
            )
        }

        let dayEvents = EntertainmentEventLedger.activeEvents(completionEvents, dayKey: dayKey)
        let ruleInputs = EntertainmentRuleInputs(dayKey: dayKey, plan: plan, dayEvents: dayEvents, summary: summary)
        let effectiveRules = entitlementRules(on: dayKey)
        let adjustmentIDs = Set(effectiveRules.compactMap { rule -> UUID? in
            guard EntertainmentRewardEvaluator.targetReading(rule: rule, inputs: ruleInputs)?.needsAdjustment == true else {
                return nil
            }
            return rule.id
        })

        return EntertainmentRulesContext(
            dayKey: dayKey,
            rules: entertainmentRules.sorted { $0.createdAt < $1.createdAt },
            effectiveRules: effectiveRules,
            grants: rewardGrants,
            evaluation: evaluation,
            summary: summary,
            targetCandidates: candidates,
            todayPlannedItemCount: plan?.items.count ?? 0,
            adjustmentRuleIDs: adjustmentIDs,
            notificationAuthorized: notificationAuthorized,
            now: context.now,
            planningContext: context
        )
    }
}

// MARK: - 主页面

struct EntertainmentRulesView: View {
    var context: EntertainmentRulesContext
    var onSaveRule: (EntertainmentRuleDraft) -> StoreChangeResult
    var onDeleteRule: (UUID) -> Void
    var onToggleRule: (UUID, Bool) -> Void
    var onRefresh: () -> Void
    /// 计时意图统一交给 G：claim / start / finish / 通知。
    var onIntents: ([EntertainmentSessionIntent]) -> Void
    var onClose: (() -> Void)?

    @State private var editorDraft: EntertainmentRuleDraft?
    @State private var sessionRequest: SessionRequest?
    @State private var showProgress = false
    @State private var showExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            header
            if context.hasAnyRule {
                if context.effectiveRules.isEmpty {
                    statusChip("今天没有生效的规则：规则可能已停用、超出生效区间，或今天不在勾选的星期。", tint: StudyDesign.Colors.warning)
                }
                ruleList
            } else {
                emptyState
            }
            rewardSection
            if let grant = context.mostRecentInvalidatedGrant {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    Text("最近失效的奖励")
                        .font(StudyDesign.Typography.cardTitle)
                    grantRow(grant)
                }
            }
            explanationSection
        }
        .padding(StudyDesign.Spacing.roomy)
        .frame(maxWidth: StudyDesign.Layout.readingMaxWidth, alignment: .leading)
        .sheet(item: $editorDraft) { draft in
            EntertainmentRuleEditor(
                context: context.planningContext,
                candidates: context.targetCandidates,
                todayPlannedItemCount: context.todayPlannedItemCount,
                draft: draft,
                onSave: { edited in
                    let result = onSaveRule(edited)
                    if result.mayCloseEditor {
                        editorDraft = nil
                    }
                    return result
                },
                onCancel: { editorDraft = nil }
            )
        }
        .sheet(item: $sessionRequest) { request in
            EntertainmentSessionView(
                grant: context.grants.first { $0.id == request.id },
                context: context.planningContext,
                runningGrantID: context.runningGrant?.id,
                notificationAuthorized: context.notificationAuthorized,
                onIntents: onIntents,
                onClose: { sessionRequest = nil }
            )
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("娱乐解锁与计时")
                        .font(StudyDesign.Typography.sectionTitle)
                    Text("本地判定，不使用网络。奖励默认当天使用，一次只运行一个计时。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
                Spacer(minLength: StudyDesign.Spacing.tight)
                Button {
                    onRefresh()
                } label: {
                    Label("刷新资格", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("重新按当前完成事件计算资格")

                Button {
                    showProgress = true
                } label: {
                    Label("资格进度", systemImage: "chart.bar.doc.horizontal")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("查看每条规则的条件进度与依据事件")

                Button {
                    editorDraft = EntertainmentRuleDraft()
                } label: {
                    Label("新建规则", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("新建一条娱乐解锁规则")

                if let onClose {
                    Button("完成", action: onClose)
                        .buttonStyle(.bordered)
                }
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                statusChip(context.summary.explanation, tint: StudyDesign.Colors.info)
                if let authorized = context.notificationAuthorized, !authorized {
                    statusChip("系统通知不可用：页面内计时仍然可用", tint: StudyDesign.Colors.warning)
                }
            }
        }
        .sheet(isPresented: $showProgress) {
            EntertainmentProgressView(
                context: context,
                onRefresh: onRefresh,
                onIntents: onIntents,
                onClose: { showProgress = false }
            )
        }
    }

    private func statusChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(StudyDesign.Typography.supporting)
            .foregroundStyle(tint)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.micro)
            .background(tint.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        StudyEmptyState(
            title: "还没有娱乐规则",
            subtitle: "先创建一条规则：绑定今天的任务、或约定学习时长，达标后解锁一段娱乐时间。",
            icon: "gamecontroller",
            accentIcon: "sparkles",
            accentTint: StudyDesign.Colors.primary,
            actionLabel: "新建规则",
            action: { editorDraft = EntertainmentRuleDraft() }
        )
    }

    // MARK: 规则列表

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text("规则")
                .font(StudyDesign.Typography.cardTitle)
            ForEach(context.rules) { rule in
                ruleCard(rule)
            }
        }
    }

    private func ruleCard(_ rule: EntertainmentRule) -> some View {
        let progress = context.progress(for: rule)
        let grant = context.grant(for: rule)
        let needsAdjustment = context.adjustmentRuleIDs.contains(rule.id)

        return VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    HStack(spacing: StudyDesign.Spacing.compact) {
                        Text(rule.name.isEmpty ? "未命名规则" : rule.name)
                            .font(StudyDesign.Typography.cardTitle)
                        Text("第 \(rule.ruleVersion) 版")
                            .font(StudyDesign.Typography.supporting)
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        if !rule.isEnabled {
                            statusChip("已停用", tint: StudyDesign.Colors.labelSecondary)
                        }
                    }
                    Text("\(rule.condition.displayText) · \(rule.repeatText) · 奖励 \(rule.rewardMinutes) 分钟")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !rule.boundTargets.isEmpty {
                        Text("须全部完成：" + rule.boundTargets.map(\.displayText).joined(separator: "、"))
                            .font(StudyDesign.Typography.supporting)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("保底替代：\(rule.fallback.label)")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
                Spacer(minLength: StudyDesign.Spacing.tight)
                eligibilityChip(progress: progress, needsAdjustment: needsAdjustment, isEffectiveToday: context.isEffectiveToday(rule))
            }

            if let progress {
                progressBar(progress)
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                Button("编辑") { editorDraft = EntertainmentRuleDraft(rule: rule) }
                    .buttonStyle(.bordered)
                    .accessibilityHint("编辑规则会生成新版本，尚未开始的旧版本奖励会重新核验")

                Button(rule.isEnabled ? "停用" : "启用") {
                    onToggleRule(rule.id, !rule.isEnabled)
                }
                .buttonStyle(.bordered)

                Button("删除", role: .destructive) { onDeleteRule(rule.id) }
                    .buttonStyle(.bordered)

                Spacer(minLength: 0)

                rewardActions(grant: grant)
            }
        }
        .studyCard()
        .studyCardStroke(color: needsAdjustment ? StudyDesign.Colors.warning.opacity(0.5) : StudyDesign.Colors.accentHairline)
    }

    private func eligibilityChip(progress: RewardConditionProgress?, needsAdjustment: Bool, isEffectiveToday: Bool) -> some View {
        let text: String
        let tint: Color
        if !isEffectiveToday {
            text = "今天不生效"
            tint = StudyDesign.Colors.labelSecondary
        } else if needsAdjustment {
            text = "需要调整绑定"
            tint = StudyDesign.Colors.warning
        } else if let progress, progress.isSatisfied {
            text = "已达标"
            tint = StudyDesign.Colors.success
        } else {
            text = "未满足"
            tint = StudyDesign.Colors.labelSecondary
        }
        return statusChip(text, tint: tint)
    }

    private func progressBar(_ progress: RewardConditionProgress) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
            ProgressView(value: progress.ratio ?? 0)
                .tint(progress.isSatisfied ? StudyDesign.Colors.success : StudyDesign.Colors.primary)
                .accessibilityLabel("条件进度")
                .accessibilityValue(progress.detail)
            Text(progress.detail)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("依据 \(progress.basisEventIDs.count) 条完成事件")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
    }

    @ViewBuilder
    private func rewardActions(grant: RewardGrant?) -> some View {
        if let grant {
            switch grant.state {
            case .pending:
                Button("领取") { onIntents([.requestClaim(grantID: grant.id)]) }
                    .buttonStyle(.borderedProminent)
            case .claimed:
                // 开始计时在计时页里发起，避免同一次点击重复提交。
                Button("开始计时") { sessionRequest = SessionRequest(id: grant.id) }
                    .buttonStyle(.borderedProminent)
            case .started:
                Button("回到计时") { sessionRequest = SessionRequest(id: grant.id) }
                    .buttonStyle(.borderedProminent)
            case .finished:
                statusChip("已结束，使用 \(grant.usedMinutes) 分钟", tint: StudyDesign.Colors.labelSecondary)
            case .expired:
                statusChip("已过期", tint: StudyDesign.Colors.labelSecondary)
            case .revoked:
                statusChip("已撤销", tint: StudyDesign.Colors.danger)
            }
        } else {
            Text("达标后自动生成待领取奖励")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
    }

    // MARK: 今日奖励

    private var rewardSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text("今日奖励")
                .font(StudyDesign.Typography.cardTitle)

            Text("奖励默认当天使用，不无限累积；已领取的奖励不会因为刷新重复新增。")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)

            if context.visibleGrants.isEmpty {
                Text("今天还没有娱乐奖励。完成规则条件后会自动出现待领取奖励。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            } else {
                ForEach(context.visibleGrants) { grant in
                    grantRow(grant)
                }
            }
        }
    }

    private func grantRow(_ grant: RewardGrant) -> some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(grant.ruleSnapshot.name.isEmpty ? "娱乐奖励" : grant.ruleSnapshot.name)
                    .font(StudyDesign.Typography.body.weight(.semibold))
                Text("\(grant.grantedMinutes) 分钟 · 规则第 \(grant.ruleSnapshot.ruleVersion) 版 · 剩余 \(grant.remainingMinutes) 分钟")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                if grant.dayKey != context.dayKey {
                    Text("奖励日期：\(grant.dayKey.localDateString)")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
                Text(grant.conditionProgress.detail)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if grant.state == .revoked, let reason = grant.revocation?.reason, !reason.isEmpty {
                    Text(reason)
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if grant.state == .expired {
                    Text("仅限 \(grant.dayKey.localDateString) 使用，未使用部分已过期。")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: StudyDesign.Spacing.tight)
            VStack(alignment: .trailing, spacing: StudyDesign.Spacing.micro) {
                statusChip(grant.state.label, tint: tint(for: grant.state))
                rewardActions(grant: grant)
            }
        }
        .studyCard(fill: StudyDesign.Colors.dataBackground)
    }

    private func tint(for state: RewardGrantState) -> Color {
        switch state {
        case .pending: return StudyDesign.Colors.primary
        case .claimed: return StudyDesign.Colors.info
        case .started: return StudyDesign.Colors.success
        case .finished: return StudyDesign.Colors.labelSecondary
        case .expired: return StudyDesign.Colors.labelSecondary
        case .revoked: return StudyDesign.Colors.danger
        }
    }

    // MARK: 判定说明

    private var explanationSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Button {
                withAnimation(StudyDesign.Motion.animation(.fast)) { showExplanation.toggle() }
            } label: {
                Label(showExplanation ? "收起判定说明" : "查看判定说明", systemImage: showExplanation ? "chevron.up" : "info.circle")
                    .font(StudyDesign.Typography.supporting)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showExplanation ? "收起判定说明" : "查看判定说明")

            if showExplanation {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
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
                    if !context.evaluation.undecidableRuleRevisionIDs.isEmpty {
                        Text("• 有 \(context.evaluation.undecidableRuleRevisionIDs.count) 条规则因为只有旧版本的每日完成总数而无法判定，没有补发奖励。")
                            .font(StudyDesign.Typography.supporting)
                            .foregroundStyle(StudyDesign.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .studyCard(fill: StudyDesign.Colors.dataBackground)
            }
        }
    }

    // MARK: 计时 sheet 绑定

    /// sheet 的身份只需要奖励 ID；具体记录每次从最新上下文里取，
    /// 这样商店刷新后计时页拿到的一定是最新状态。
    struct SessionRequest: Identifiable, Hashable {
        var id: UUID
    }
}

// MARK: - 让草稿可以直接作为 sheet 的 item

extension EntertainmentRuleDraft: Identifiable {
    var id: String {
        ruleID?.uuidString ?? "new-rule-draft"
    }
}
