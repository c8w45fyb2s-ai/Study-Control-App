import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 完成反馈闸门：同一触发只播放一次，同一时刻只允许一个浮层。
    @State private var feedbackGate = StudyHomeFeedbackGate()
    @State private var floatingSparkBurstTrigger = 0
    @State private var showCheckInCelebration = false
    @State private var sessionSheetItem: DailyPlanItem?
    @State private var showAdjustmentSheet = false
    @State private var showFullPlanSheet = false
    /// 界面内显示的操作反馈或错误提示，不写入快照。
    @State private var actionNote: String?

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                    // 区域 1：今日概览
                    TodayPlanSummaryView(
                        overview: overview,
                        dateText: dateText,
                        onAdjustToday: { showAdjustmentSheet = true },
                        onOpenPlan: { store.studyOpenSection(.planningHome) },
                        onOpenFullPlan: { showFullPlanSheet = true }
                    )

                    // 区域 1.5：计时与恢复（中断确认 / 跨日遗留会话 / 放弃与进度）
                    StudySessionRecoveryCard()

                    // 区域 2：接下来做
                    NextStudyTaskView(
                        nextSteps: nextSteps,
                        primaryAction: primaryAction,
                        onPerformPrimary: { action in perform(primary: action) },
                        onPause: { runSessionAction { id in await store.pauseStudySession(sessionID: id) } },
                        onResume: { runSessionAction { id in await store.resumeStudySession(sessionID: id) } },
                        onOpenSession: openSessionSheet,
                        onOpenAllTasks: { store.navigateToReviews() },
                        onOpenPlan: { store.studyOpenSection(.planningHome) }
                    )

                    // 区域 3：娱乐与休息
                    TodayEntertainmentSummaryView(
                        entertainment: entertainment,
                        isActionPrimary: StudyHomePresenter.entertainmentActionIsPrimary(
                            pagePrimary: primaryAction,
                            entertainment: entertainment
                        ),
                        onPerformAction: { action in perform(primary: action) },
                        onOpenRules: { store.studyOpenSection(.entertainmentRules) }
                    )

                    // 以下只是附注行，不是第四个核心区域，也不隐藏任何本地任务。
                    if let actionNote {
                        StudyHomeNoticeLine(
                            text: actionNote,
                            systemImage: "exclamationmark.bubble",
                            tint: StudyDesign.Colors.warning,
                            actionTitle: "知道了"
                        ) {
                            self.actionNote = nil
                        }
                    }

                    if let recoveryLine {
                        StudyHomeNoticeLine(
                            text: recoveryLine,
                            systemImage: "arrow.counterclockwise.circle",
                            tint: StudyDesign.Colors.danger,
                            actionTitle: "打开设置"
                        ) {
                            store.navigateToSettings()
                        }
                    }

                    if actionNote == nil, recoveryLine == nil, store.statusMessage != "准备就绪", !store.statusMessage.isEmpty {
                        Text(store.statusMessage)
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("状态：\(store.statusMessage)")
                    }
                }
                .padding(StudyDesign.Spacing.wide)
                .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                // 悬浮标签栏会压住内容，这里留出足够底部空间（仅 iOS 生效）。
                .studyScrollBottomComfort(StudyDesign.Spacing.section * 2)
            }
            .dismissKeyboardOnTapOutside()
            .scrollDismissesKeyboard(.interactively)

            if showCheckInCelebration {
                CheckInFloatingCelebration(
                    completedCount: store.todayCompletedTaskCount,
                    sparkBurstTrigger: floatingSparkBurstTrigger,
                    reduceMotion: reduceMotion
                )
                .padding(.horizontal, StudyDesign.Spacing.wide)
                .padding(.top, StudyDesign.Spacing.roomy)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                    removal: .scale(scale: 0.98, anchor: .top).combined(with: .opacity)
                ))
                .zIndex(5)
            }
        }
        .background(DashboardCommandBackground())
        .onChange(of: store.checkInCelebrationTrigger) { _, trigger in
            playFeedback(trigger: trigger)
        }
        .sheet(item: $sessionSheetItem) { item in
            sessionSheet(for: item)
        }
        .sheet(isPresented: $showFullPlanSheet) {
            TodayPlanDetailSheet()
                .environmentObject(store)
#if os(macOS)
                .frame(minWidth: 720, minHeight: 640)
#endif
        }
        .sheet(isPresented: $showAdjustmentSheet) {
            adjustmentSheet
        }
#if os(iOS)
        .sensoryFeedback(.success, trigger: floatingSparkBurstTrigger)
#endif
    }

    // MARK: - 真实数据（统一状态来源：计划 + 完成事件）

    /// 视图显示用的当前时间；所有算法仍通过 `PlanningContext` 接收它。
    private var now: Date { Date() }

    private var context: PlanningContext { store.snapshot.planningContext(now: now) }

    private var plan: DailyStudyPlan? { store.todayPlan }

    private var items: [DailyPlanItem] { store.todayPlanItems }

    private var summary: DailyStudySummary { store.snapshot.dailySummary(for: context.todayKey) }

    /// 今天正在进行的会话（不显示别的学习日遗留的会话）。
    private var activeSession: StudySession? {
        store.snapshot.studySessions.first { $0.state.isActive && $0.dayKey == context.todayKey }
    }

    private var availability: AvailabilityDay? {
        guard let schedule = store.snapshot.schedule else { return nil }
        return AvailabilityCalculator.availability(
            on: now,
            schedule: schedule,
            preferences: store.snapshot.availabilityPreferences,
            now: now
        )
    }

    private var isModelConfigured: Bool {
        store.snapshot.settings.allowModelRequests
            && store.isAIConnectionReady
    }

    private var nextSteps: StudyHomeNextSteps {
        StudyHomePresenter.nextSteps(
            items: items,
            activeSession: activeSession,
            now: now,
            context: context,
            upcomingLimit: 2
        )
    }

    /// E 的奖励评估（纯计算、只读）：用于首页显示真实的解锁条件进度。
    ///
    /// 引擎从 G 的注册表取；没有引擎时返回 nil，界面只显示规则文字，不自行推算资格。
    private var rewardEvaluation: RewardEvaluation? {
        guard let evaluator = StudyEngineRegistry.production().rewardEvaluator else { return nil }
        return evaluator.evaluate(
            rules: store.snapshot.entitlementRules(on: context.todayKey),
            plan: plan,
            completions: store.snapshot.completionEvents,
            grants: store.snapshot.rewardGrants,
            summary: summary,
            context: context
        )
    }

    private var entertainment: StudyHomeEntertainment {
        StudyHomePresenter.entertainment(
            rules: store.snapshot.entitlementRules(on: context.todayKey),
            grants: store.snapshot.rewardGrants,
            progress: rewardEvaluation?.progress ?? [],
            summary: summary,
            isWithinRestWindow: StudyHomePresenter.isWithinRestWindow(
                now: now,
                dayKey: context.todayKey,
                settings: store.snapshot.availabilitySettings,
                context: context
            )
        )
    }

    private var overview: StudyHomeOverview {
        StudyHomePresenter.overview(
            plan: plan,
            summary: summary,
            isSemesterConfigured: store.snapshot.isSemesterConfigured,
            planEngineMessage: store.planEngineAvailabilityMessage,
            isModelConfigured: isModelConfigured,
            examLine: StudyHomePresenter.examLine(
                goal: store.snapshot.nextExamGoal(now: now),
                plan: plan,
                now: now,
                context: context
            )
        )
    }

    private var primaryAction: StudyHomePrimaryAction {
        StudyHomePresenter.pagePrimaryAction(
            nextSteps: nextSteps,
            activeSession: activeSession,
            entertainment: entertainment
        )
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        formatter.timeZone = context.timeZone
        return formatter.string(from: now)
    }

    /// 加载失败 / 数据恢复提示（取最近 7 天里最新的一条非信息级诊断）。
    private var recoveryLine: String? {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        guard let event = store.snapshot.diagnosticEvents.first(where: { $0.level != .info && $0.createdAt >= cutoff }) else {
            return nil
        }
        let prefix = event.level == .error ? "上次操作失败" : "注意"
        return "\(prefix)：\(event.message)"
    }

    /// 当前会话的中断提示（真的由 D 的引擎判定，不是写死的 nil）。
    private func interruptionPrompt(for session: StudySession?) -> StudySessionInterruptionPrompt? {
        guard let session else { return nil }
        let engine = StudySessionEngineImpl()
        guard let candidate = engine.interruptionCandidate(for: session, context: context) else { return nil }
        return StudySessionInterruptionPrompt(interruption: candidate)
    }

    // MARK: - 动作

    private func perform(primary action: StudyHomePrimaryAction) {
        switch action {
        case .startStudy(let itemID):
            if let item = items.first(where: { $0.id == itemID }) {
                sessionSheetItem = item
            } else {
                actionNote = "这条任务已经不在今日计划里了，请在「计划」页刷新计划。"
            }

        case .resumeSession(let sessionID):
            runSession(id: sessionID) { id in await store.resumeStudySession(sessionID: id) }

        case .finishSession(let sessionID):
            Task { _ = await store.finishStudySession(sessionID: sessionID, scope: nil) }

        case .claimReward(let grantID):
            Task { _ = await store.claimReward(grantID: grantID) }

        case .startReward(let grantID):
            Task { _ = await store.startReward(grantID: grantID) }

        case .finishReward(let grantID):
            let started = store.snapshot.rewardGrant(id: grantID)?.startedAt ?? now
            let usedMinutes = max(0, context.minutes(from: started, to: now))
            Task { _ = await store.finishReward(grantID: grantID, usedMinutes: usedMinutes) }

        case .none:
            break
        }
    }

    private func runSessionAction(_ body: @escaping (UUID) async -> Void) {
        guard let session = activeSession else {
            actionNote = "找不到进行中的学习会话，可能已经结束。"
            return
        }
        runSession(id: session.id, body)
    }

    private func runSession(id: UUID, _ body: @escaping (UUID) async -> Void) {
        Task { await body(id) }
    }

    private func openSessionSheet() {
        guard
            let session = activeSession,
            let itemID = session.planItemID,
            let item = items.first(where: { $0.id == itemID })
        else {
            actionNote = "当前没有进行中的学习会话，请先在「接下来做」里开始一项任务。"
            return
        }
        sessionSheetItem = item
    }

    // MARK: - 学习会话（D 的界面 + G 的统一入口）

    @ViewBuilder
    private func sessionSheet(for item: DailyPlanItem) -> some View {
        let session = store.snapshot.activeStudySession(forPlanItemID: item.id)
        let persistedMinutes = session?.effectiveMinutes(asOf: now, calendar: context.calendar) ?? 0

        StudySessionView(
            session: session,
            presentation: StudySessionPresentation(item: item),
            persistedEffectiveMinutes: persistedMinutes,
            interruption: interruptionPrompt(for: session),
            advice: nil,
            onStart: {
                Task { _ = await store.startStudySession(planItemID: item.id) }
            },
            onPause: {
                runSessionAction { id in await store.pauseStudySession(sessionID: id) }
            },
            onResume: {
                runSessionAction { id in await store.resumeStudySession(sessionID: id) }
            },
            onFinish: { scope, assessment, note in
                // 只有真正保存成功才关闭计时界面（需求 8：保存失败不关闭必要界面）。
                Task {
                    guard let sessionID = store.snapshot.activeStudySession(forPlanItemID: item.id)?.id else {
                        actionNote = "找不到进行中的会话，无法结束。"
                        return
                    }
                    let outcome = await store.finishStudySession(
                        sessionID: sessionID,
                        scope: scope,
                        assessment: assessment,
                        note: note
                    )
                    if outcome.didPersist {
                        sessionSheetItem = nil
                    } else {
                        actionNote = outcome.errorMessage ?? "保存失败，本次学习没有记录，请重试。"
                    }
                }
            },
            onAbandon: { reason in
                Task {
                    guard let sessionID = store.snapshot.activeStudySession(forPlanItemID: item.id)?.id else {
                        actionNote = "找不到进行中的会话。"
                        return
                    }
                    let outcome = await store.abandonStudySession(
                        sessionID: sessionID,
                        reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "用户在计时界面放弃" : reason
                    )
                    if outcome.didPersist {
                        sessionSheetItem = nil
                    } else {
                        actionNote = outcome.errorMessage ?? "放弃失败，本次操作没有写入，请重试。"
                    }
                }
            },
            onRecordProgress: { scope in
                Task {
                    guard let sessionID = store.snapshot.activeStudySession(forPlanItemID: item.id)?.id else {
                        actionNote = "找不到进行中的会话，无法记录进度。"
                        return
                    }
                    let outcome = await store.saveStudySessionProgress(sessionID: sessionID, scope: scope)
                    if !outcome.didPersist, outcome.didChange {
                        actionNote = outcome.errorMessage ?? "进度没有保存成功，请重试。"
                    }
                }
            },
            onConfirmInterruption: { studiedDuringGap in
                Task {
                    guard let sessionID = store.snapshot.activeStudySession(forPlanItemID: item.id)?.id else { return }
                    _ = await store.resolveStudyInterruption(sessionID: sessionID, studiedDuringGap: studiedDuringGap)
                }
            }
        )
#if os(iOS)
        .presentationDetents([.large])
#endif
    }

    // MARK: - 调整今天（D 的调整面板 + G 的统一入口）

    @ViewBuilder
    private var adjustmentSheet: some View {
        if let preview = store.minimumPlanPreview() {
            PlanAdjustmentSheet(
                proposal: preview.proposal,
                // 需求 4：接入 E 已实现的娱乐影响计算（不在界面里自己推算）。
                entertainmentImpact: preview.entertainmentImpact.isEmpty
                    ? .unavailable
                    : .evaluated(preview.entertainmentImpact),
                remainingMinutes: preview.capacity.effectiveMinutes,
                onApply: {
                    Task {
                        let outcome = await store.applyMinimumPlan(preview: preview)
                        if outcome.didPersist {
                            showAdjustmentSheet = false
                        } else {
                            // 预览过期或保存失败：保留面板，不悄悄应用另一个方案。
                            actionNote = outcome.errorMessage ?? "方案没有保存成功，请重试。"
                        }
                    }
                },
                onKeepCurrentPlan: { showAdjustmentSheet = false }
            )
#if os(iOS)
            .presentationDetents([.medium, .large])
#endif
        } else {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                Text("今天还没有生成计划")
                    .font(StudyDesign.Typography.sectionTitle)
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text("先生成今日计划，才能把任务压到轻量或保底。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Button("关闭") { showAdjustmentSheet = false }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
            }
            .padding(StudyDesign.Spacing.wide)
        }
    }

    // MARK: - 完成反馈（单浮层 + 去重）

    private func playFeedback(trigger: Int) {
        guard store.hasCheckedInToday else { return }
        guard feedbackGate.begin(trigger: trigger) else { return }

        floatingSparkBurstTrigger += 1

        if reduceMotion {
            showCheckInCelebration = true
            scheduleFeedbackHide(trigger: trigger, after: 1.4)
            return
        }

        withAnimation(StudyDesign.Motion.animation(.spring)) {
            showCheckInCelebration = true
        }
        scheduleFeedbackHide(trigger: trigger, after: 2.1)
    }

    private func scheduleFeedbackHide(trigger: Int, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard feedbackGate.visibleTrigger == trigger else { return }
            withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.normal)) {
                showCheckInCelebration = false
            }
            feedbackGate.end(trigger: trigger)
        }
    }
}

// MARK: - 页面背景

private struct DashboardCommandBackground: View {
    var body: some View {
        StudyDesign.Colors.contentBackground
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - 打卡反馈

private struct CheckInSparkBurst: View {
    let trigger: Int
    let reduceMotion: Bool
    @State private var isVisible = false
    @State private var isExpanded = false

    private struct Spark: Identifiable {
        let id: Int
        let angle: Double
        let distance: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private let sparks: [Spark] = [
        Spark(id: 0, angle: -88, distance: 36, width: 4, height: 12),
        Spark(id: 1, angle: -48, distance: 34, width: 3, height: 10),
        Spark(id: 2, angle: -18, distance: 38, width: 4, height: 11),
        Spark(id: 3, angle: 24, distance: 32, width: 3, height: 10),
        Spark(id: 4, angle: 62, distance: 36, width: 4, height: 12),
        Spark(id: 5, angle: 108, distance: 34, width: 3, height: 10),
        Spark(id: 6, angle: 154, distance: 38, width: 4, height: 11),
        Spark(id: 7, angle: 208, distance: 32, width: 3, height: 10)
    ]

    var body: some View {
        ZStack {
            ForEach(sparks) { spark in
                Capsule()
                    .fill(sparkColor(for: spark.id))
                    .frame(width: spark.width, height: spark.height)
                    .scaleEffect(isExpanded ? 1 : 0.18)
                    .opacity(isVisible ? (isExpanded ? 0.10 : 0.82) : 0)
                    .rotationEffect(.degrees(spark.angle + (isExpanded ? 18 : 0)))
                    .offset(isExpanded ? offset(for: spark) : .zero)
                    .animation(
                        reduceMotion ? nil :
                            StudyDesign.Motion.animation(.spring)
                            .delay(Double(spark.id) * 0.018),
                        value: isExpanded
                    )
            }
        }
        .frame(width: 118, height: 118)
        .onChange(of: trigger) { _, _ in
            playBurst()
        }
    }

    private func playBurst() {
        guard !reduceMotion else { return }
        isVisible = false
        isExpanded = false
        DispatchQueue.main.async {
            isVisible = true
            DispatchQueue.main.async {
                isExpanded = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            isVisible = false
            isExpanded = false
        }
    }

    private func offset(for spark: Spark) -> CGSize {
        let radians: Double = spark.angle * .pi / 180
        return CGSize(
            width: CGFloat(cos(radians)) * spark.distance,
            height: CGFloat(sin(radians)) * spark.distance
        )
    }

    private func sparkColor(for index: Int) -> Color {
        switch index % 5 {
        case 0:
            return StudyDesign.Colors.warning.opacity(0.72)
        case 1:
            return StudyDesign.Colors.info.opacity(0.48)
        case 2:
            return StudyDesign.Colors.primary.opacity(0.42)
        case 3:
            return StudyDesign.Colors.success.opacity(0.66)
        default:
            return StudyDesign.Colors.cardBackground
        }
    }
}

private struct CheckInFloatingCelebration: View {
    let completedCount: Int
    let sparkBurstTrigger: Int
    let reduceMotion: Bool
    @State private var badgeScale: CGFloat = 0.86
    @State private var badgeRotation: Double = -8
    @State private var glowScale: CGFloat = 0.62
    @State private var glowOpacity: Double = 0

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                StudyDesign.Colors.success.opacity(glowOpacity * 0.24),
                                StudyDesign.Colors.info.opacity(glowOpacity * 0.06),
                                .clear
                            ],
                            center: .center,
                            startRadius: 5,
                            endRadius: 58
                        )
                    )
                    .frame(width: 98, height: 98)
                    .scaleEffect(glowScale)
                    .allowsHitTesting(false)

                CheckInSparkBurst(trigger: sparkBurstTrigger, reduceMotion: reduceMotion)
                    .frame(width: 104, height: 104)
                    .allowsHitTesting(false)

                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 31, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    StudyDesign.Colors.success.opacity(0.88),
                                    StudyDesign.Colors.info.opacity(0.54)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(StudyDesign.Colors.elevatedBackground))
                        .overlay(Circle().stroke(StudyDesign.Colors.success.opacity(0.12), lineWidth: 1))

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white, StudyDesign.Colors.success)
                        .background(Circle().fill(StudyDesign.Colors.elevatedBackground))
                        .offset(x: 3, y: 3)
                }
                .shadow(color: StudyDesign.Colors.success.opacity(0.075), radius: 7, y: 3)
                .scaleEffect(badgeScale)
                .rotationEffect(.degrees(badgeRotation))
            }
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text("今日打卡成功")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)

                Text("已完成 \(completedCount) 项复习，继续保持节奏。")
                    .font(.subheadline)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)
        }
        .padding(.horizontal, StudyDesign.Spacing.normal)
        .padding(.vertical, StudyDesign.Spacing.tight)
        .frame(maxWidth: 380)
        .background(StudyDesign.Colors.elevatedBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.large)
                .stroke(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.success.opacity(0.26),
                            StudyDesign.Colors.info.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: StudyDesign.Shadow.card.color.opacity(0.70), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日打卡成功，已完成 \(completedCount) 项复习")
        .onAppear {
            playEntrance()
        }
        .onChange(of: sparkBurstTrigger) { _, _ in
            playEntrance()
        }
    }

    private func playEntrance() {
        guard !reduceMotion else {
            badgeScale = 1
            badgeRotation = 0
            glowScale = 1
            glowOpacity = 0.26
            return
        }

        badgeScale = 0.86
        badgeRotation = -8
        glowScale = 0.62
        glowOpacity = 0

        withAnimation(StudyDesign.Motion.animation(.spring)) {
            badgeScale = 1.12
            badgeRotation = 5
            glowScale = 1.08
            glowOpacity = 0.34
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(StudyDesign.Motion.animation(.spring)) {
                badgeScale = 1
                badgeRotation = 0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            withAnimation(StudyDesign.Motion.animation(.normal)) {
                glowOpacity = 0.10
                glowScale = 1.18
            }
        }
    }
}
