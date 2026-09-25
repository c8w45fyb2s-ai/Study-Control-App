import SwiftUI

// MARK: - E 模块：娱乐计时页
//
// 关键点：
// - 剩余时长完全由持久化的 `startedAt` + `grantedMinutes` − `usedMinutes` 推导；
//   界面定时器只负责"重画"，不负责计时。切后台、锁屏、重启后回来自动一致。
// - 所有副作用（落盘 / 通知）都通过 `onIntents` 交给 G。
// - 没有通知权限时页面内计时照常可用。

struct EntertainmentSessionView: View {
    /// 当前奖励；为 `nil` 表示这条奖励已经不在今天的记录里。
    var grant: RewardGrant?
    var context: PlanningContext
    var runningGrantID: UUID?
    var notificationAuthorized: Bool?
    var onIntents: ([EntertainmentSessionIntent]) -> Void
    var onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var lastRefreshSignature = ""

    var body: some View {
        NavigationStack {
            Group {
                if let grant {
                    content(for: grant)
                } else {
                    StudyEmptyState(
                        title: "找不到这条娱乐奖励",
                        subtitle: "奖励记录已经变化（可能是过期或已撤销），请回到列表刷新。",
                        icon: "questionmark.circle",
                        accentIcon: "exclamationmark.triangle",
                        accentTint: StudyDesign.Colors.warning
                    )
                    .padding(StudyDesign.Spacing.roomy)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onClose)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            // 回到前台：按保存的时间重算，必要时自动结算（不依赖后台定时器）。
            if newPhase == .active { refreshIfNeeded() }
        }
        .onAppear { refreshIfNeeded() }
    }

    // MARK: 内容

    private var title: String {
        guard let name = grant?.ruleSnapshot.name, !name.isEmpty else { return "娱乐计时" }
        return name
    }

    /// 按钮按下瞬间的规划上下文。
    ///
    /// 视图是"外部时间源"：算法只接收传入的 now，自己在内部不读系统时钟。
    private func liveContext() -> PlanningContext {
        PlanningContext(
            now: Date(),
            timeZone: context.timeZone,
            calendarIdentifier: context.calendar.identifier,
            locale: context.locale
        )
    }

    private func content(for grant: RewardGrant) -> some View {
        // 只用于"重画"的时间轴：真正的剩余时长由引擎按传入的 now 计算。
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let snapshot = EntertainmentSessionEngine.snapshot(
                for: grant,
                at: timeline.date,
                context: context,
                runningGrantID: runningGrantID
            )
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                timerCard(snapshot)
                detailCard(snapshot, grant: grant)
                actionRow(snapshot, grant: grant)
                noticeCard(snapshot, grant: grant)
            }
            .padding(StudyDesign.Spacing.roomy)
            .frame(maxWidth: StudyDesign.Layout.readingMaxWidth, alignment: .leading)
        }
    }

    private func timerCard(_ snapshot: EntertainmentTimerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Text(timeText(snapshot.remainingSeconds))
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(snapshot.state == .running ? StudyDesign.Colors.success : StudyDesign.Colors.labelPrimary)
                .accessibilityLabel("剩余时间")
                .accessibilityValue("\(snapshot.remainingMinutesCeiling) 分钟")

            Text(snapshot.statusText)
                .font(StudyDesign.Typography.body)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(value: progressValue(snapshot))
                .tint(StudyDesign.Colors.success)
                .accessibilityLabel("已用时间进度")
        }
        .studyCard()
    }

    private func detailCard(_ snapshot: EntertainmentTimerSnapshot, grant: RewardGrant) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
            row("状态", snapshot.state.label)
            row("本次时长", "\(snapshot.grantedMinutes) 分钟")
            row("已用", "\(snapshot.elapsedSeconds / 60) 分钟（\(snapshot.elapsedSeconds) 秒）")
            row("所属学习日", snapshot.dayKey.localDateString)
            if let endsAt = snapshot.endsAt {
                row("预计结束", timeString(endsAt))
            }
            if !grant.conditionProgress.detail.isEmpty {
                row("解锁依据", grant.conditionProgress.detail)
            }
            row("规则版本", "第 \(snapshot.ruleVersion) 版")
        }
        .studyCard(fill: StudyDesign.Colors.dataBackground)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Text(title)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func actionRow(_ snapshot: EntertainmentTimerSnapshot, grant: RewardGrant) -> some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            switch snapshot.state {
            case .notStarted:
                Button {
                    onIntents(EntertainmentSessionEngine.step(
                        .claim,
                        grant: grant,
                        at: liveContext().now,
                        context: liveContext(),
                        runningGrantID: runningGrantID
                    ).intents)
                } label: {
                    Label("领取", systemImage: "hand.raised")
                }
                .buttonStyle(.bordered)
                .disabled(grant.state != .pending)

                Button {
                    onIntents(EntertainmentSessionEngine.step(
                        .start,
                        grant: grant,
                        at: liveContext().now,
                        context: liveContext(),
                        runningGrantID: runningGrantID
                    ).intents)
                } label: {
                    Label("开始计时", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!snapshot.canStart)

            case .running:
                Button {
                    onIntents(EntertainmentSessionEngine.step(
                        .finish,
                        grant: grant,
                        at: liveContext().now,
                        context: liveContext(),
                        runningGrantID: runningGrantID
                    ).intents)
                } label: {
                    Label("结束计时", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("按已用时间结算，未使用的部分不再保留")

            case .finished:
                Label("已结束", systemImage: "checkmark.circle")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)

            case .revoked:
                Label("奖励已撤销", systemImage: "xmark.circle")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.danger)

            case .unavailable:
                Label("仅限当天使用", systemImage: "clock.badge.exclamationmark")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.warning)
            }
            Spacer(minLength: 0)
        }
    }

    private func noticeCard(_ snapshot: EntertainmentTimerSnapshot, grant: RewardGrant) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
            if let notificationAuthorized, !notificationAuthorized {
                Label("系统通知不可用：到点提醒不会弹出，但页面内剩余时长照常计算。", systemImage: "bell.slash")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if runningGrantID != nil, runningGrantID != grant.id {
                Label("当前还有另一条娱乐计时在运行，结束它之后才能开始这条。", systemImage: "exclamationmark.triangle")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("时间由保存的开始时刻与已用时长推导，切到后台或重启后仍然一致。", systemImage: "clock.arrow.circlepath")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.state == .unavailable {
                Label("奖励默认当天使用，过期不会累积。", systemImage: "calendar.badge.exclamationmark")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .studyCard(fill: StudyDesign.Colors.pageBackground)
    }

    // MARK: 派生

    private func progressValue(_ snapshot: EntertainmentTimerSnapshot) -> Double {
        let total = max(1, snapshot.grantedMinutes * 60)
        return min(1, max(0, Double(snapshot.elapsedSeconds) / Double(total)))
    }

    private func timeText(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = context.timeZone
        formatter.locale = context.locale
        return formatter.string(from: date)
    }

    /// 刷新：到点或跨天时自动结算，并且同一状态只提交一次，避免重复写入。
    private func refreshIfNeeded() {
        guard let grant else { return }
        let live = liveContext()
        let transition = EntertainmentSessionEngine.step(
            .refresh,
            grant: grant,
            at: live.now,
            context: live,
            runningGrantID: runningGrantID
        )
        guard !transition.intents.isEmpty else { return }
        let signature = transition.intents.map(describe).joined(separator: "|")
        guard signature != lastRefreshSignature else { return }
        lastRefreshSignature = signature
        onIntents(transition.intents)
    }

    private func describe(_ intent: EntertainmentSessionIntent) -> String {
        switch intent {
        case .requestClaim(let grantID): return "claim:\(grantID.uuidString)"
        case .requestStart(let grantID): return "start:\(grantID.uuidString)"
        case .requestFinish(let grantID, let usedMinutes): return "finish:\(grantID.uuidString):\(usedMinutes)"
        case .scheduleEndNotification(let grantID, let fireDate, _):
            return "schedule:\(grantID.uuidString):\(Int(fireDate.timeIntervalSince1970))"
        case .cancelEndNotification(let grantID, _): return "cancel:\(grantID.uuidString)"
        }
    }
}
