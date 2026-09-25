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
            && !store.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

private struct DashboardSetupSecondaryAction: View {
    let onImport: () -> Void

    var body: some View {
#if os(iOS)
        iOSSetupGuide
#else
        desktopSecondaryAction
#endif
    }

#if os(iOS)
    private var iOSSetupGuide: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.secondary)
                    .frame(width: 38, height: 38)
                    .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .stroke(StudyDesign.Colors.secondary.opacity(0.16), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("3 步开始学习")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text("连接模型后即可完成从资料到复习的完整流程。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: StudyDesign.Spacing.tight) {
                setupStep(
                    number: 1,
                    title: "连接模型",
                    detail: "在设置中开启模型并填写 API Key",
                    icon: "key.fill",
                    tint: StudyDesign.Colors.info
                )
                setupStep(
                    number: 2,
                    title: "导入资料",
                    detail: "添加错题、讲义或笔记，本地保存不受影响",
                    icon: "doc.badge.plus",
                    tint: StudyDesign.Colors.secondary
                )
                setupStep(
                    number: 3,
                    title: "确认并复习",
                    detail: "确认 AI 整理结果，生成知识点和复习计划",
                    icon: "checkmark.seal.fill",
                    tint: StudyDesign.Colors.success
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    capabilityPill("资料分析", icon: "doc.text.magnifyingglass")
                    capabilityPill("个性复习", icon: "calendar.badge.clock")
                    capabilityPill("学习答疑", icon: "bubble.left.and.bubble.right")
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    capabilityPill("资料分析", icon: "doc.text.magnifyingglass")
                    capabilityPill("个性复习", icon: "calendar.badge.clock")
                    capabilityPill("学习答疑", icon: "bubble.left.and.bubble.right")
                }
            }

            Button(action: onImport) {
                Label("先导入本地资料", systemImage: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(StudyDesign.Colors.secondary)
            .accessibilityHint("即使尚未配置模型，也可以先把资料保存在本地")
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Gradients.featureSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(StudyDesign.Colors.secondary.opacity(0.48))
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.52), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .accessibilityElement(children: .contain)
    }

    private func setupStep(number: Int, title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.10)))
                .overlay(Circle().stroke(tint.opacity(0.18), lineWidth: 1))

            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(number) 步，\(title)，\(detail)")
    }

    private func capabilityPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.labelSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, StudyDesign.Spacing.compact)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(StudyDesign.Colors.elevatedBackground, in: Capsule())
            .overlay(Capsule().stroke(StudyDesign.Colors.accentHairline, lineWidth: 1))
    }
#else
    private var desktopSecondaryAction: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: "doc.badge.plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.secondary)
                .frame(width: 34, height: 34)
                .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .stroke(StudyDesign.Colors.secondary.opacity(0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text("也可以先保存本地资料")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text("添加文件或手动输入，配置模型后再分析。")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            Button(action: onImport) {
                StudyActionPillLabel(title: "导入", systemImage: "arrow.right")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .soft, size: .compact, minWidth: 76))
            .accessibilityLabel("导入资料")
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.elevatedBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
#endif
}

private struct DashboardTodayQueueSection: View {
    let tasks: [ReviewTask]
    let completedCount: Int
    let hasCheckedInToday: Bool
    let onShowAll: () -> Void

    private var totalCount: Int {
        max(tasks.count + completedCount, tasks.count)
    }

    private var progress: Double {
        guard totalCount > 0 else { return hasCheckedInToday ? 1 : 0 }
        return min(1, Double(completedCount) / Double(totalCount))
    }

    private var progressPercent: Int {
        Int((progress * 100).rounded())
    }

    private var overdueCount: Int {
        let now = Date()
        return tasks.filter { $0.dueDate < now }.count
    }

    private var focusTint: Color {
        overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.warning
    }

    private var statusTitle: String {
        if overdueCount > 0 {
            return "\(overdueCount) 项需优先"
        }
        if hasCheckedInToday {
            return "已打卡，继续清队列"
        }
        return "按优先级推进"
    }

    private var firstTaskTitle: String {
        tasks.first?.title ?? "待处理任务"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
            headerPanel

            ForEach(tasks) { task in
                ReviewTaskRow(task: task)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("今日复习队列，待处理 \(tasks.count) 项，已完成 \(completedCount) 项，完成率 \(progressPercent)%")
        .accessibilityHint("查看今天到期的复习任务，并进入任务评分、延期或提醒设置。")
    }

    private var headerPanel: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                progressRing

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("今日复习队列")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelPrimary)
                    Text(firstTaskTitle)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

#if os(macOS)
                Button {
                    onShowAll()
                } label: {
                    StudyActionPillLabel(title: "查看全部", systemImage: "arrow.right")
                }
                .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
                .help("查看全部复习任务")
                .accessibilityLabel("查看全部复习任务")
                .accessibilityHint("打开复习页，查看今天和后续的复习队列。")
#endif
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    queueMetric(title: "待处理", value: "\(tasks.count)", icon: "tray.full", tint: focusTint)
                    queueMetric(title: "已完成", value: "\(completedCount)", icon: "checkmark.seal.fill", tint: StudyDesign.Colors.success)
                    queueMetric(title: "需优先", value: "\(overdueCount)", icon: "clock.badge.exclamationmark", tint: overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelSecondary)
                }

                VStack(spacing: StudyDesign.Spacing.tight) {
                    queueMetric(title: "待处理", value: "\(tasks.count)", icon: "tray.full", tint: focusTint)
                    queueMetric(title: "已完成", value: "\(completedCount)", icon: "checkmark.seal.fill", tint: StudyDesign.Colors.success)
                    queueMetric(title: "需优先", value: "\(overdueCount)", icon: "clock.badge.exclamationmark", tint: overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelSecondary)
                }
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Gradients.featureSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(focusTint)
                .frame(width: 4)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(StudyDesign.Colors.surfaceFillDeep, lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0.05, CGFloat(progress)))
                .stroke(
                    focusTint,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(progressPercent)%")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text("完成")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }
        }
        .frame(width: 56, height: 56)
    }

    private func queueMetric(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            LinearGradient(
                colors: [
                    StudyDesign.Colors.elevatedBackground,
                    StudyDesign.Colors.dataBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .help("\(title)：\(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)：\(value)")
    }
}

// MARK: - Study Trend Charts (see StudyCharts.swift)

#if os(iOS)
private struct DashboardReportDisclosure: View {
    let report: StudyProgressReport
    @Binding var selectedPeriod: StudyReportPeriod
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            Button {
                withAnimation(StudyDesign.Motion.animation(.normal)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                                .fill(StudyDesign.Colors.secondary.opacity(0.10))
                        )

                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                        Text(report.period.detailTitle)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                            .lineLimit(1)
                        Text(report.summarySentence)
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .lineLimit(isExpanded ? 2 : 1)
                            .minimumScaleFactor(0.88)
                    }

                    Spacer(minLength: StudyDesign.Spacing.tight)

                    VStack(alignment: .trailing, spacing: StudyDesign.Spacing.micro) {
                        Text("\(report.completionRatePercent)%")
                            .font(.headline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(StudyDesign.Colors.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .frame(minWidth: 44, alignment: .trailing)
                }
                .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
                .padding(StudyDesign.Spacing.normal)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                        .fill(StudyDesign.Gradients.panelSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                        .stroke(StudyDesign.Colors.accentHairline.opacity(0.78), lineWidth: 1)
                )
                .shadow(color: StudyDesign.Shadow.card.color.opacity(0.78), radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起学习报告" : "展开学习报告")
            .accessibilityHint("显示或隐藏学习报告详情")
            .help(isExpanded ? "收起学习报告" : "展开学习报告")

            if isExpanded {
                StudyReportSummaryCard(
                    report: report,
                    selectedPeriod: $selectedPeriod
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
#endif

private struct StudyReportSummaryCard: View {
    let report: StudyProgressReport
    @Binding var selectedPeriod: StudyReportPeriod
    @Namespace private var periodNamespace

    var body: some View {
#if os(iOS)
        iOSReportCard
#else
        desktopReportCard
#endif
    }

#if os(iOS)
    private var iOSReportCard: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                            .fill(StudyDesign.Colors.secondary.opacity(0.10))
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(report.period.detailTitle)
                        .font(.headline.weight(.semibold))
                    Text("\(report.startDate.formatted(date: .abbreviated, time: .omitted)) - \(report.generatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                StudyReportPeriodControl(
                    selectedPeriod: $selectedPeriod,
                    namespace: periodNamespace
                )
            }

            Text(report.summarySentence)
                .font(.footnote)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                HStack {
                    Text("完成率")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    Spacer()
                    Text("\(report.completionRatePercent)%")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(StudyDesign.Colors.secondary)
                }

                ProgressView(value: min(max(report.completionRate, 0), 1))
                    .tint(StudyDesign.Colors.secondary)
                    .accessibilityLabel("完成率")
                    .accessibilityValue("\(report.completionRatePercent)%")
            }
            .padding(StudyDesign.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .fill(
                        LinearGradient(
                            colors: [
                                StudyDesign.Colors.elevatedBackground,
                                StudyDesign.Colors.dataBackground
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    StudyReportSignalMetric(title: "已完成", value: "\(report.completedCount)", icon: "bolt.fill", tint: StudyDesign.Colors.success)
                    StudyReportSignalMetric(title: "逾期", value: "\(report.overdueTaskCount)", icon: "clock.badge.exclamationmark", tint: report.overdueTaskCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.secondary)
                }

                VStack(spacing: StudyDesign.Spacing.tight) {
                    StudyReportSignalMetric(title: "已完成", value: "\(report.completedCount)", icon: "bolt.fill", tint: StudyDesign.Colors.success)
                    StudyReportSignalMetric(title: "逾期", value: "\(report.overdueTaskCount)", icon: "clock.badge.exclamationmark", tint: report.overdueTaskCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.secondary)
                }
            }

            HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
                Label("薄弱：\(report.topWeakSubjectText)", systemImage: "target")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: StudyDesign.Spacing.tight)

                NavigationLink {
                    StudyReportDetailView(report: report)
                } label: {
                    Label("详情", systemImage: "arrow.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudyDesign.Colors.secondary)
                .help("查看完整学习报告")
                .accessibilityLabel("查看完整学习报告")
                .accessibilityHint("打开报告详情")
            }
            .padding(StudyDesign.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .fill(
                        LinearGradient(
                            colors: [
                                StudyDesign.Colors.elevatedBackground,
                                StudyDesign.Colors.dataBackground
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .fill(StudyDesign.Gradients.panelSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(report.period.detailTitle)，完成率 \(report.completionRatePercent)%，已完成 \(report.completedCount) 项，逾期 \(report.overdueTaskCount) 项")
    }
#endif

    private var desktopReportCard: some View {
        ListCard(tint: StudyDesign.Colors.secondary) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        Label(report.period.detailTitle, systemImage: "chart.bar.doc.horizontal")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        Text(report.summarySentence)
                            .font(.footnote)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: StudyDesign.Spacing.tight)

                    StudyReportPeriodControl(
                        selectedPeriod: $selectedPeriod,
                        namespace: periodNamespace
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
                    StudyReportMiniMetric(title: "完成率", value: "\(report.completionRatePercent)%", icon: "checkmark.circle", tint: StudyDesign.Colors.success)
                    StudyReportMiniMetric(title: "已完成", value: "\(report.completedCount)", icon: "bolt.fill", tint: StudyDesign.Colors.success)
                    StudyReportMiniMetric(title: "逾期", value: "\(report.overdueTaskCount)", icon: "clock.badge.exclamationmark", tint: report.overdueTaskCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.secondary)
                    StudyReportMiniMetric(title: "薄弱科目", value: report.topWeakSubjectText, icon: "target", tint: StudyDesign.Colors.warning)
                }

                HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
                    Label(report.topErrorPatternText, systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)

                    Spacer()

                    NavigationLink {
                        StudyReportDetailView(report: report)
                    } label: {
                        StudyActionPillLabel(title: "查看报告", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(StudyActionPillButtonStyle(prominence: .secondary))
                    .help("查看完整学习报告")
                    .accessibilityLabel("查看完整学习报告")
                    .accessibilityHint("打开报告详情")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(report.period.detailTitle)，完成率 \(report.completionRatePercent)%，已完成 \(report.completedCount) 项，逾期 \(report.overdueTaskCount) 项")
    }
}

private struct StudyReportPeriodControl: View {
    @Binding var selectedPeriod: StudyReportPeriod
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StudyReportPeriod.allCases) { period in
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        selectedPeriod = period
                    }
                } label: {
                    Text(period.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedPeriod == period ? StudyDesign.Colors.labelPrimary : StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(minWidth: 44)
                        .padding(.vertical, 6)
                        .background {
                            if selectedPeriod == period {
                                Capsule()
                                    .fill(StudyDesign.Colors.cardBackground)
                                    .overlay(
                                        Capsule()
                                            .stroke(StudyDesign.Colors.primary, lineWidth: 2)
                                    )
                                    .matchedGeometryEffect(id: "report-period", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .iOSTouchTarget()
                .help(selectedPeriod == period ? "\(period.title)，已选中" : "切换到\(period.title)报告")
                .accessibilityLabel(period.title)
                .accessibilityValue(selectedPeriod == period ? "已选中" : "未选中")
                .accessibilityHint("切换报告周期")
                .accessibilityAddTraits(selectedPeriod == period ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            Capsule()
                .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
        )
        .accessibilityLabel("报告周期")
        .accessibilityElement(children: .contain)
    }
}

#if os(iOS)
private struct StudyReportSignalMetric: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: StudyDesign.Spacing.compact) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                            .fill(tint.opacity(0.10))
                    )

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        )
    }
}
#endif

private struct StudyReportMiniMetric: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .lineLimit(1)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        )
    }
}

struct StudyReportDetailView: View {
    let report: StudyProgressReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                header
                metricGrid
                weakSubjectsSection
                errorPatternsSection
                suggestionsSection
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studyScrollBottomComfort()
        }
        .navigationTitle(report.period.detailTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .background(StudyDesign.Gradients.pageBackdrop)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "chart.bar.doc.horizontal.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.info)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                            .fill(StudyDesign.Gradients.semanticWash(StudyDesign.Colors.info).opacity(0.20))
                            .overlay(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                                    .stroke(StudyDesign.Colors.info.opacity(0.18), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(report.period.detailTitle)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text("\(report.startDate.formatted(date: .abbreviated, time: .omitted)) - \(report.generatedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(report.completionRatePercent)%")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(report.completionRatePercent >= 80 ? StudyDesign.Colors.success : StudyDesign.Colors.warning)
                        .monospacedDigit()
                    Text("完成率")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
            }

            Text(report.summarySentence)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(value: min(max(report.completionRate, 0), 1))
                .tint(report.completionRatePercent >= 80 ? StudyDesign.Colors.success : StudyDesign.Colors.warning)
                .padding(.top, StudyDesign.Spacing.micro)
                .accessibilityLabel("完成率")
                .accessibilityValue("\(report.completionRatePercent)%")
        }
        .padding(StudyDesign.Spacing.roomy)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.elevatedBackground,
                            StudyDesign.Colors.dataBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                .fill(StudyDesign.Colors.info.opacity(0.62))
                .frame(width: 4)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.68), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: StudyDesign.Spacing.normal)], spacing: StudyDesign.Spacing.normal) {
            InfoCard(title: "完成率", value: "\(report.completionRatePercent)%", icon: "checkmark.circle", tint: StudyDesign.Colors.success, subtitle: "已完成 / 应完成")
            InfoCard(title: "完成任务", value: "\(report.completedCount)", icon: "bolt.fill", tint: StudyDesign.Colors.success, subtitle: report.period.title)
            InfoCard(title: "未完成到期", value: "\(report.dueUnfinishedCount)", icon: "tray.full", tint: StudyDesign.Colors.warning, subtitle: "本周期内")
            InfoCard(title: "逾期任务", value: "\(report.overdueTaskCount)", icon: "clock.badge.exclamationmark", tint: report.overdueTaskCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.secondary, subtitle: "当前仍待处理")
        }
    }

    @ViewBuilder
    private var weakSubjectsSection: some View {
        reportSection(title: "薄弱科目诊断", icon: "target", tint: StudyDesign.Colors.warning) {
            if report.weakSubjects.isEmpty {
                StudyReportEmptyLine(text: "暂无低掌握度知识点。继续完成复习后，这里会按科目自动排序。", icon: "checkmark.seal.fill", tint: StudyDesign.Colors.success)
            } else {
                VStack(spacing: StudyDesign.Spacing.tight) {
                    ForEach(report.weakSubjects) { subject in
                        StudyReportWeakSubjectRow(subject: subject)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var errorPatternsSection: some View {
        reportSection(title: "反复错误类型", icon: "exclamationmark.triangle", tint: StudyDesign.Colors.danger) {
            if report.repeatedErrorPatterns.isEmpty {
                StudyReportEmptyLine(text: "暂无可归类的高频错误。导入错题并填写错因后，系统会自动聚合类型。", icon: "tray.and.arrow.down.fill", tint: StudyDesign.Colors.info)
            } else {
                VStack(spacing: StudyDesign.Spacing.tight) {
                    ForEach(report.repeatedErrorPatterns) { pattern in
                        StudyReportErrorPatternRow(pattern: pattern)
                    }
                }
            }
        }
    }

    private var suggestionsSection: some View {
        reportSection(title: "下周建议", icon: "sparkles", tint: StudyDesign.Colors.success) {
            VStack(spacing: StudyDesign.Spacing.tight) {
                ForEach(report.nextSuggestions) { suggestion in
                    StudyReportSuggestionRow(suggestion: suggestion, tint: suggestionTint(for: suggestion.icon))
                }
            }
        }
    }

    private func reportSection<Content: View>(title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        ListCard(tint: tint) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    Image(systemName: icon)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                .fill(StudyDesign.Gradients.semanticWash(tint).opacity(0.20))
                                .overlay(
                                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                        .stroke(tint.opacity(0.16), lineWidth: 1)
                                )
                        )

                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                }

                content()
            }
        }
    }

    private func suggestionTint(for icon: String) -> Color {
        switch icon {
        case "clock.badge.exclamationmark":
            return StudyDesign.Colors.danger
        case "target", "exclamationmark.triangle":
            return StudyDesign.Colors.warning
        case "checkmark.seal":
            return StudyDesign.Colors.success
        default:
            return StudyDesign.Colors.info
        }
    }
}

private struct StudyReportWeakSubjectRow: View {
    let subject: StudyProgressReport.WeakSubject

    private var masteryPercent: Int {
        Int((subject.averageMastery * 100).rounded())
    }

    private var titlesText: String {
        subject.representativeTitles.isEmpty ? "暂无代表知识点" : subject.representativeTitles.joined(separator: "、")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.tight) {
                Text(subject.subject)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)

                Spacer(minLength: StudyDesign.Spacing.tight)

                Text("\(masteryPercent)%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .monospacedDigit()
                    .padding(.horizontal, StudyDesign.Spacing.tight)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(StudyDesign.Colors.warning.opacity(0.10)))
                    .overlay(Capsule().stroke(StudyDesign.Colors.warning.opacity(0.18), lineWidth: 1))
            }

            ProgressView(value: min(max(subject.averageMastery, 0), 1))
                .tint(StudyDesign.Colors.warning)

            HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
                Image(systemName: "lightbulb.min.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(StudyDesign.Colors.warning.opacity(0.10)))

                Text("\(subject.weakKnowledgeCount) 个薄弱知识点：\(titlesText)")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                .fill(StudyDesign.Colors.warning.opacity(0.52))
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

private struct StudyReportErrorPatternRow: View {
    let pattern: StudyProgressReport.ErrorPattern

    private var exampleText: String {
        pattern.examples.isEmpty ? "暂无代表例题" : "例：\(pattern.examples.joined(separator: "；"))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            VStack(spacing: 2) {
                Text("\(pattern.count)")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.danger)
                    .monospacedDigit()
                Text("次")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }
            .frame(width: 42)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .fill(StudyDesign.Colors.danger.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(StudyDesign.Colors.danger.opacity(0.16), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text(pattern.type)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)

                Text(exampleText)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                .fill(StudyDesign.Colors.danger.opacity(0.50))
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

private struct StudyReportSuggestionRow: View {
    let suggestion: StudyProgressReport.UpcomingFocus
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: suggestion.icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                        .fill(StudyDesign.Gradients.semanticWash(tint).opacity(0.20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(suggestion.reason)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                .fill(tint.opacity(0.50))
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

private struct StudyReportEmptyLine: View {
    let text: String
    var icon: String = "info.circle.fill"
    var tint: Color = StudyDesign.Colors.info

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: icon)
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.10)))
                .overlay(Circle().stroke(tint.opacity(0.16), lineWidth: 1))

            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: StudyDesign.Spacing.tight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.cardBackground,
                            StudyDesign.Colors.inputBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

private struct ExamGoalCountdownCard: View {
    @EnvironmentObject private var store: AppStore
    let goal: ExamGoal?

    private var daysRemaining: Int {
        max(goal?.daysRemaining() ?? 0, 0)
    }

    private var progress: Double {
        guard let goal else { return 0 }
        let calendar = Calendar.current
        let created = calendar.startOfDay(for: goal.createdAt)
        let exam = calendar.startOfDay(for: goal.examDate)
        let today = calendar.startOfDay(for: Date())
        let total = max(calendar.dateComponents([.day], from: created, to: exam).day ?? 1, 1)
        let elapsed = min(max(calendar.dateComponents([.day], from: created, to: today).day ?? 0, 0), total)
        return Double(elapsed) / Double(total)
    }

    var body: some View {
        Group {
#if os(iOS)
            iOSGoalContent
#else
            desktopGoalContent
#endif
        }
        .padding(StudyDesign.Spacing.normal)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                .fill(goalTint.opacity(goal == nil ? 0.34 : 0.62))
                .frame(width: 4)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(goal == nil ? StudyDesign.Colors.accentHairline : goalTint.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var goalTint: Color {
        goal == nil ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.warning
    }

    private var cardBackground: some ShapeStyle {
        StudyDesign.Gradients.featureSurface
    }

    private var goalIcon: some View {
        Image(systemName: "flag.checkered")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(goalTint)
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .fill(StudyDesign.Gradients.semanticWash(goalTint).opacity(goal == nil ? 0.16 : 0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                            .stroke(goalTint.opacity(0.16), lineWidth: 1)
                    )
            )
    }

    private var progressTrack: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StudyDesign.Colors.surfaceFillDeep.opacity(0.56))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [goalTint.opacity(0.72), goalTint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 7)
    }

    private var countdownBadge: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(daysRemaining)")
                .font(.title3.weight(.bold))
                .foregroundStyle(goalTint)
                .monospacedDigit()
            Text("天")
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            LinearGradient(
                colors: [
                    StudyDesign.Colors.elevatedBackground,
                    StudyDesign.Colors.dataBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .accessibilityLabel("剩余 \(daysRemaining) 天")
    }

    private func goalSignal(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(tint.opacity(0.10)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            LinearGradient(
                colors: [
                    StudyDesign.Colors.elevatedBackground,
                    StudyDesign.Colors.dataBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }

#if os(iOS)
    private var iOSGoalContent: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                goalIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(goal?.name ?? "设置考试目标")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text(goalSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(goal == nil ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.warning)
                        .lineLimit(2)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)
                if goal != nil {
                    countdownBadge
                } else {
                    goalAction
                }
            }

            if goal != nil {
                progressTrack

                HStack(spacing: StudyDesign.Spacing.tight) {
                    goalSignal(title: "科目", value: goal?.subjectText ?? "未设置", icon: "books.vertical.fill", tint: StudyDesign.Colors.info)
                    goalSignal(title: "每日", value: goal?.dailyAvailableTimeText ?? "未设置", icon: "clock.fill", tint: StudyDesign.Colors.warning)
                }
            } else {
                Text(goalDetailText)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)
            }
        }
    }
#else
    private var desktopGoalContent: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            goalIcon

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    Text(goal?.name ?? "设置考试目标")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text(goalSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(goal == nil ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.warning)
                }

                if goal != nil {
                    progressTrack
                } else {
                    Text(goalDetailText)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: StudyDesign.Spacing.normal)

            if goal != nil {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    goalSignal(title: "科目", value: goal?.subjectText ?? "未设置", icon: "books.vertical.fill", tint: StudyDesign.Colors.info)
                        .frame(width: 132)
                    goalSignal(title: "每日", value: goal?.dailyAvailableTimeText ?? "未设置", icon: "clock.fill", tint: StudyDesign.Colors.warning)
                        .frame(width: 118)
                    countdownBadge
                }
            } else {
                goalAction
            }
        }
    }
#endif

    private var goalSubtitle: String {
        guard let goal else {
            return "让 AI 规划按倒计时和每日可用时间分配任务"
        }
        return "\(goal.countdownText()) · \(goal.examDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private var goalDetailText: String {
        guard let goal else {
            return "填写考试名称、日期、科目、每日时间和目标分数。"
        }
        return "科目：\(goal.subjectText)"
    }

    private var accessibilityText: String {
        guard let goal else {
            return "尚未设置考试目标，可前往设置新增考试目标"
        }
        return "\(goal.name)，\(goal.countdownText())，科目 \(goal.subjectText)，每天 \(goal.dailyAvailableTimeText)"
    }

    @ViewBuilder
    private var goalAction: some View {
#if os(macOS)
        Button {
            store.navigateToExamGoals()
        } label: {
            StudyActionPillLabel(title: "设置", systemImage: "arrow.right")
        }
        .buttonStyle(StudyActionPillButtonStyle(prominence: .soft, size: .compact))
        .help("打开考试目标设置")
        .accessibilityLabel("打开考试目标")
        .accessibilityHint("设置或编辑考试目标")
#else
        NavigationLink {
            ExamGoalsView()
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
                .frame(width: 28, height: 28)
                .background(
                    LinearGradient(
                        colors: [
                            StudyDesign.Colors.elevatedBackground,
                            StudyDesign.Colors.dataBackground
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开考试目标")
        .accessibilityHint(goal == nil ? "新增考试目标" : "查看或编辑考试目标")
        .help("打开考试目标")
#endif
    }
}

// MARK: - iOS Dashboard
#if os(iOS)
struct IOSDashboardWorkbench: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                inlineStat(title: "掌握", value: "\(masteryPercent)%", icon: "target", tint: StudyDesign.Colors.success)
                inlineStat(title: "连续", value: "\(store.streakDays) 天", icon: "flame.fill", tint: StudyDesign.Colors.warning)
                inlineStat(title: "错题", value: "\(store.snapshot.mistakes.count)", icon: AppSection.mistakes.icon, tint: StudyDesign.Colors.danger)
                inlineStat(title: "待确认", value: "\(totalDraftCount)", icon: AppSection.drafts.icon, tint: StudyDesign.Colors.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: StudyDesign.Spacing.tight) {
                inlineStat(title: "掌握", value: "\(masteryPercent)%", icon: "target", tint: StudyDesign.Colors.success)
                inlineStat(title: "连续", value: "\(store.streakDays) 天", icon: "flame.fill", tint: StudyDesign.Colors.warning)
                inlineStat(title: "错题", value: "\(store.snapshot.mistakes.count)", icon: AppSection.mistakes.icon, tint: StudyDesign.Colors.danger)
                inlineStat(title: "待确认", value: "\(totalDraftCount)", icon: AppSection.drafts.icon, tint: StudyDesign.Colors.secondary)
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.normal)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("学习概览，掌握率 \(masteryPercent)%，连续学习 \(store.streakDays) 天，错题 \(store.snapshot.mistakes.count)，待确认 \(totalDraftCount)")
    }

    private var totalDraftCount: Int {
        store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count
    }

    private var masteryPercent: Int {
        let points = store.snapshot.knowledgePoints
        guard !points.isEmpty else { return 0 }
        let average = points.reduce(0) { $0 + min(max($1.mastery, 0), 1) } / Double(points.count)
        return Int((average * 100).rounded())
    }

    private func inlineStat(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.compact)
        .padding(.vertical, 6)
        .help("\(title)：\(value)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)：\(value)")
    }
}
#endif

// MARK: - Dashboard Command Center

#if os(macOS)
private struct DashboardMetricGrid: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Metric: Identifiable {
        let id: String
        let title: String
        let value: Int
        var suffix = ""
        let icon: String
        let tint: Color
        let subtitle: String
    }

    private var metrics: [Metric] {
        [
            Metric(
                id: "today-review",
                title: "今日复习",
                value: store.todayTasks.count,
                icon: "calendar.badge.clock",
                tint: store.todayTasks.isEmpty ? StudyDesign.Colors.success : StudyDesign.Colors.warning,
                subtitle: "待处理"
            ),
            Metric(
                id: "today-check-in",
                title: "今日打卡",
                value: store.todayCompletedTaskCount,
                suffix: " 项",
                icon: "checkmark.seal.fill",
                tint: store.hasCheckedInToday ? StudyDesign.Colors.success : StudyDesign.Colors.secondary,
                subtitle: store.hasCheckedInToday ? "已打卡" : "完成 1 项复习"
            ),
            Metric(
                id: "mastery",
                title: "掌握率",
                value: masteryPercent,
                suffix: "%",
                icon: "target",
                tint: StudyDesign.Colors.success,
                subtitle: "知识点平均"
            ),
            Metric(
                id: "streak",
                title: "连续学习",
                value: store.streakDays,
                suffix: " 天",
                icon: "flame.fill",
                tint: StudyDesign.Colors.warning,
                subtitle: "保持节奏"
            ),
            Metric(
                id: "mistakes",
                title: "错题",
                value: store.snapshot.mistakes.count,
                icon: "xmark.circle",
                tint: StudyDesign.Colors.danger,
                subtitle: "待巩固"
            ),
            Metric(
                id: "drafts",
                title: "待确认",
                value: store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count,
                icon: "checklist.unchecked",
                tint: StudyDesign.Colors.secondary,
                subtitle: "分析与规划"
            )
        ]
    }

    private var masteryPercent: Int {
        let points = store.snapshot.knowledgePoints
        guard !points.isEmpty else { return 0 }
        let average = points.reduce(0) { $0 + min(max($1.mastery, 0), 1) } / Double(points.count)
        return Int((average * 100).rounded())
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                metricGrid(columnCount: 2)
            } else {
                ViewThatFits(in: .horizontal) {
                    metricGrid(columnCount: 3)
                        .frame(minWidth: 660)
                    metricGrid(columnCount: 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("学习数据概览")
    }

    private func metricGrid(columnCount: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: StudyDesign.Spacing.tight, alignment: .top),
                count: columnCount
            ),
            alignment: .leading,
            spacing: StudyDesign.Spacing.tight
        ) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                DashboardMetricCard(
                    title: metric.title,
                    value: metric.value,
                    suffix: metric.suffix,
                    icon: metric.icon,
                    tint: metric.tint,
                    subtitle: metric.subtitle
                )
                .dashboardStagger(index: index)
            }
        }
    }
}
#endif

private struct DashboardMetricCard: View {
    let title: String
    let value: Int
    var suffix: String = ""
    let icon: String
    var tint: Color = StudyDesign.Colors.secondary
    var subtitle: String? = nil

    var body: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(metricIconBackground)

                Spacer(minLength: StudyDesign.Spacing.micro)

                Text("\(value)\(suffix)")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.numericText())
                    .animation(StudyDesign.Motion.animation(.normal), value: value)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .dashboardMetricChrome(tint: tint)
        .help(accessibilitySummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
#else
        HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(metricIconBackground)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: StudyDesign.Spacing.micro)

            Text("\(value)\(suffix)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
                .animation(StudyDesign.Motion.animation(.normal), value: value)
        }
        .frame(minHeight: 62)
        .padding(.horizontal, StudyDesign.Spacing.normal)
        .padding(.vertical, StudyDesign.Spacing.tight)
        .dashboardMetricChrome(tint: tint)
        .help(accessibilitySummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
#endif
    }

    private var accessibilitySummary: String {
        if let subtitle {
            return "\(title)：\(value)\(suffix)，\(subtitle)"
        }
        return "\(title)：\(value)\(suffix)"
    }

    private var metricIconBackground: some View {
        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
            .fill(StudyDesign.Colors.dataBackground)
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                    .fill(tint.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                    .stroke(tint.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct DashboardMetricChromeModifier: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                StudyDesign.Colors.elevatedBackground,
                                StudyDesign.Colors.dataBackground
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .topLeading) {
                        Rectangle()
                            .fill(tint.opacity(0.028))
                            .frame(width: 96, height: 64)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
            .overlay(alignment: .bottomLeading) {
                Capsule()
                    .fill(tint.opacity(0.22))
                    .frame(width: 34, height: 2)
                    .padding(.leading, StudyDesign.Spacing.normal)
                    .padding(.bottom, 1)
            }
            .shadow(color: StudyDesign.Shadow.card.color.opacity(0.42), radius: 5, y: 1)
    }
}

private extension View {
    func dashboardMetricChrome(tint: Color) -> some View {
        modifier(DashboardMetricChromeModifier(tint: tint))
    }
}

private struct DashboardStaggerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 14)
            .scaleEffect(isVisible ? 1 : 0.985)
            .onAppear {
                guard !isVisible else { return }
                if reduceMotion {
                    isVisible = true
                } else {
                    withAnimation(StudyDesign.Motion.animation(.heroReveal).delay(Double(index) * 0.055)) {
                        isVisible = true
                    }
                }
            }
    }
}

private extension View {
    func dashboardStagger(index: Int) -> some View {
        modifier(DashboardStaggerModifier(index: index))
    }
}

private struct DashboardCommandBackground: View {
    var body: some View {
        StudyDesign.Colors.contentBackground
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

struct TodayReviewView: View {
    @EnvironmentObject private var store: AppStore

    private var pendingTasks: [ReviewTask] {
        store.todayTasks
    }

    private var queuedTasks: [ReviewTask] {
        Array(pendingTasks.dropFirst())
    }

    private var completedCount: Int {
        store.todayCompletedTaskCount
    }

    private var sessionTotal: Int {
        max(completedCount + pendingTasks.count, pendingTasks.count)
    }

    private var progress: Double {
        guard sessionTotal > 0 else { return store.hasCheckedInToday ? 1 : 0 }
        return min(1, Double(completedCount) / Double(sessionTotal))
    }

    private var overdueCount: Int {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return pendingTasks.filter { $0.dueDate < startOfToday }.count
    }

    var body: some View {
        content
            .navigationTitle("开始复习")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StudyDesign.Spacing.chatInner) {
                TodayReviewSessionHeader(
                    pendingCount: pendingTasks.count,
                    completedCount: completedCount,
                    totalCount: sessionTotal,
                    overdueCount: overdueCount,
                    progress: progress,
                    hasCheckedInToday: store.hasCheckedInToday
                )

                if pendingTasks.isEmpty {
                    StudyEmptyState(
                        title: store.hasCheckedInToday ? "今日打卡已完成" : "今日复习已完成",
                        subtitle: store.hasCheckedInToday ? "今天已完成 \(store.todayCompletedTaskCount) 项复习。新的任务到期后会出现在这里。" : "没有待处理任务了。新的复习任务到期后会出现在这里。",
                        icon: "checkmark.seal.fill",
                        accentIcon: "sparkles",
                        accentTint: StudyDesign.Colors.success
                    )
                } else {
                    TodayReviewSectionHeader(
                        title: "当前任务",
                        subtitle: overdueCount > 0 ? "\(overdueCount) 项已过期，建议先处理" : "完成后选择本次复习质量，系统会安排下一次时间",
                        icon: "scope"
                    )

                    if let firstTask = pendingTasks.first {
                        ReviewTaskRow(task: firstTask)
                    }

                    if !queuedTasks.isEmpty {
                        TodayReviewSectionHeader(
                            title: "接下来的任务",
                            subtitle: "\(queuedTasks.count) 项在队列中",
                            icon: "list.bullet.rectangle"
                        )
                        .padding(.top, StudyDesign.Spacing.tight)

                        ForEach(queuedTasks) { task in
                            ReviewTaskRow(task: task)
                        }
                    }

                    if pendingTasks.count == 1 {
                        TodayReviewFocusHint()
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

private struct TodayReviewSessionHeader: View {
    let pendingCount: Int
    let completedCount: Int
    let totalCount: Int
    let overdueCount: Int
    let progress: Double
    let hasCheckedInToday: Bool

    private var progressPercent: Int {
        Int((progress * 100).rounded())
    }

    private var focusTint: Color {
        if overdueCount > 0 {
            return StudyDesign.Colors.danger
        }
        if pendingCount == 0 {
            return StudyDesign.Colors.success
        }
        return StudyDesign.Colors.warning
    }

    private var statusTitle: String {
        if hasCheckedInToday {
            return "今日节奏已点亮"
        }
        if overdueCount > 0 {
            return "\(overdueCount) 项需要优先处理"
        }
        if pendingCount > 0 {
            return "保持一次专注复习"
        }
        return "今日复习已清空"
    }

    private var statusSubtitle: String {
        if hasCheckedInToday {
            return "已完成 \(completedCount) 项，后续到期任务会继续进入这里。"
        }
        if pendingCount > 0 {
            return "先处理最上方任务，再按感觉评分；复习间隔会自动更新。"
        }
        return "没有新的到期任务，可以回到知识库巩固薄弱点。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                ZStack {
                    Circle()
                        .stroke(StudyDesign.Colors.surfaceFillDeep, lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: max(0.04, CGFloat(progress)))
                        .stroke(
                            focusTint,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 1) {
                        Text("\(progressPercent)%")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                        Text("完成")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    }
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("今日专注复习")
                        .font(.title2.weight(.semibold))
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelPrimary)
                    Text(statusSubtitle)
                        .font(.footnote)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    TodayReviewStatTile(title: "待处理", value: "\(pendingCount)", icon: "tray.full", tint: pendingCount == 0 ? StudyDesign.Colors.success : StudyDesign.Colors.warning)
                    TodayReviewStatTile(title: "已完成", value: "\(completedCount)", icon: "checkmark.seal.fill", tint: StudyDesign.Colors.success)
                    TodayReviewStatTile(title: "需优先", value: "\(overdueCount)", icon: "clock.badge.exclamationmark", tint: overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelSecondary)
                }

                VStack(spacing: StudyDesign.Spacing.tight) {
                    TodayReviewStatTile(title: "待处理", value: "\(pendingCount)", icon: "tray.full", tint: pendingCount == 0 ? StudyDesign.Colors.success : StudyDesign.Colors.warning)
                    TodayReviewStatTile(title: "已完成", value: "\(completedCount)", icon: "checkmark.seal.fill", tint: StudyDesign.Colors.success)
                    TodayReviewStatTile(title: "需优先", value: "\(overdueCount)", icon: "clock.badge.exclamationmark", tint: overdueCount > 0 ? StudyDesign.Colors.danger : StudyDesign.Colors.labelSecondary)
                }
            }
        }
        .padding(StudyDesign.Spacing.relaxed)
        .background(StudyDesign.Gradients.featureSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(focusTint)
                .frame(width: 4)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日专注复习，完成率 \(progressPercent)%，待处理 \(pendingCount) 项，已完成 \(completedCount) 项")
    }
}

private struct TodayReviewStatTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .fill(
                            LinearGradient(
                                colors: [
                                    StudyDesign.Colors.elevatedBackground,
                                    StudyDesign.Colors.dataBackground
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            LinearGradient(
                colors: [
                    StudyDesign.Colors.elevatedBackground,
                    StudyDesign.Colors.dataBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

private struct TodayReviewSectionHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.warning)
                .frame(width: 28, height: 28)
                .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)
        }
        .padding(.top, StudyDesign.Spacing.tight)
    }
}

private struct TodayReviewFocusHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.secondary)
                .frame(width: 28, height: 28)
                .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text("完成这一项就能打卡")
                    .font(.subheadline.weight(.semibold))
                Text("评分后，任务会根据记忆强度自动进入下一次复习。")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }

            Spacer()
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Gradients.panelSurface, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
    }
}

// MARK: - Dashboard Hero Banner

struct DashboardHeroBanner: View {
    /// Number of pending reviews that are due today (including overdue tasks).
    let taskCount: Int
    /// Number of all pending review tasks, used only to describe the future queue.
    var allPendingCount: Int = 0
    /// Number of reviews completed today. Together with `taskCount`, this forms
    /// the single "today" denominator used by the headline and progress ring.
    var doneTodayCount: Int = 0
    var hasCheckedInToday: Bool = false
    var checkInCelebrationTrigger: Int = 0
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var animatedRingFraction: CGFloat = 0
    @State private var sparkBurstTrigger = 0
    @State private var lastPlayedCheckInTrigger = 0
    @State private var checkInSealScale: CGFloat = 1

    private enum HeroWorkflowState {
        case modelDisabled
        case missingAPIKey
        case waitingDrafts(Int)
        case checkedIn
        case dueReviews
        case futureReviews(Int)
        case emptyLibrary
        case missingGoal
        case steady
    }

    private enum HeroActionKind: Equatable {
        case todayReview
        case importData
        case drafts
        case reviews
        case examGoals
        case settings
        case chat
    }

    private struct HeroPrimaryAction {
        let title: String
        let icon: String
        let hint: String
        let variant: DashboardHeroActionButton.Variant
        let kind: HeroActionKind
    }

    // MARK: - Time-of-day

    private enum TimeSlot {
        case morning, midday, evening
    }

    private var timeSlot: TimeSlot {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11:  return .morning
        case 11..<18: return .midday
        default:      return .evening
        }
    }

    private var gradient: LinearGradient {
        let colors: [Color]
        if colorScheme == .dark {
            colors = [
                StudyDesign.Colors.featureBackground,
                StudyDesign.Colors.elevatedBackground
            ]
        } else {
            colors = [
                StudyDesign.Colors.featureBackground,
                StudyDesign.Colors.elevatedBackground
            ]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Copy

    private var workflowState: HeroWorkflowState {
        if !store.snapshot.settings.allowModelRequests {
            return .modelDisabled
        }

        if store.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingAPIKey
        }

        let draftCount = store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count
        if draftCount > 0 {
            return .waitingDrafts(draftCount)
        }

        if hasCheckedInToday {
            return .checkedIn
        }

        if taskCount > 0 {
            return .dueReviews
        }

        if allPendingCount > 0 {
            return .futureReviews(allPendingCount)
        }

        let hasLearningAssets = !store.snapshot.documents.isEmpty
            || !store.snapshot.knowledgePoints.isEmpty
            || !store.snapshot.mistakes.isEmpty
        if !hasLearningAssets {
            return .emptyLibrary
        }

        if store.snapshot.nextExamGoal() == nil {
            return .missingGoal
        }

        return .steady
    }

    private var title: String {
        switch workflowState {
        case .modelDisabled:
            return "先开启模型请求"
        case .missingAPIKey:
            return "先配置 API Key"
        case .waitingDrafts(let count):
            return "有 \(count) 个结果待确认"
        case .checkedIn:
            return "今日打卡成功"
        case .dueReviews:
            return "今天共 \(todayTotalCount) 项复习"
        case .futureReviews:
            return "后续复习已排好"
        case .emptyLibrary:
            return "先导入第一份资料"
        case .missingGoal:
            return "设置考试目标"
        case .steady:
            return "今天节奏很好"
        }
    }

    private var subtitle: String {
        switch workflowState {
        case .modelDisabled:
            return "资料分析和答疑现在不会调用模型，开启后才能继续 AI 流程。"
        case .missingAPIKey:
            return "配置后才能分析资料、生成计划和答疑。"
        case .waitingDrafts:
            return "确认后会沉淀为知识点、错题和复习任务。"
        case .checkedIn:
            return "已完成 \(doneTodayCount) 项复习，连续学习保持中。"
        case .dueReviews:
            return "完成 1 项复习即可打卡。"
        case .futureReviews(let count):
            return "\(count) 项复习在队列里，今天暂无到期任务。"
        case .emptyLibrary:
            return "导入错题或笔记后，AI 会整理出可复习内容。"
        case .missingGoal:
            return "有目标后，AI 可以按倒计时和每日时间安排任务。"
        case .steady:
            return "可以让学习助手整理薄弱点，或继续导入新资料。"
        }
    }

    private var primaryAction: HeroPrimaryAction {
        switch workflowState {
        case .modelDisabled, .missingAPIKey:
            return HeroPrimaryAction(
                title: "去设置",
                icon: "gearshape.fill",
                hint: "打开设置完成模型连接",
                variant: .primary,
                kind: .settings
            )
        case .waitingDrafts:
            return HeroPrimaryAction(
                title: "去确认",
                icon: "checklist.unchecked",
                hint: "打开待确认工作台",
                variant: .primary,
                kind: .drafts
            )
        case .checkedIn:
            return HeroPrimaryAction(
                title: "继续复习",
                icon: "play.fill",
                hint: "打开复习队列",
                variant: .primary,
                kind: .reviews
            )
        case .dueReviews:
            return HeroPrimaryAction(
                title: "开始复习",
                icon: "play.fill",
                hint: "打开今日复习队列",
                variant: .primary,
                kind: .todayReview
            )
        case .futureReviews:
            return HeroPrimaryAction(
                title: "查看计划",
                icon: "calendar",
                hint: "打开复习计划",
                variant: .primary,
                kind: .reviews
            )
        case .emptyLibrary:
            return HeroPrimaryAction(
                title: "导入资料",
                icon: "doc.badge.plus",
                hint: "前往导入页添加资料",
                variant: .primary,
                kind: .importData
            )
        case .missingGoal:
            return HeroPrimaryAction(
                title: "设目标",
                icon: "flag.checkered",
                hint: "打开考试目标设置",
                variant: .primary,
                kind: .examGoals
            )
        case .steady:
            return HeroPrimaryAction(
                title: "问答疑",
                icon: "bubble.left.and.bubble.right.fill",
                hint: "打开学习答疑",
                variant: .secondary,
                kind: .chat
            )
        }
    }

    private var emblem: String {
        switch timeSlot {
        case .morning: return "sun.horizon.fill"
        case .midday:  return "sun.max.fill"
        case .evening: return "moon.stars.fill"
        }
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? .white : StudyDesign.Colors.labelPrimary
    }

    private var supportingForegroundColor: Color {
        colorScheme == .dark ? .white.opacity(0.62) : StudyDesign.Colors.labelSecondary
    }

    private var heroAccentColor: Color {
        switch workflowState {
        case .modelDisabled, .missingAPIKey:
            return StudyDesign.Colors.info
        case .waitingDrafts:
            return StudyDesign.Colors.secondary
        case .checkedIn:
            return StudyDesign.Colors.success
        case .dueReviews:
            return StudyDesign.Colors.secondary
        case .futureReviews:
            return StudyDesign.Colors.success
        case .emptyLibrary, .missingGoal:
            return StudyDesign.Colors.warning
        case .steady:
            return StudyDesign.Colors.secondary
        }
    }

    private var ringTrackColor: Color {
        colorScheme == .dark ? StudyDesign.Colors.dataBackground : StudyDesign.Colors.surfaceFillDeep.opacity(0.72)
    }

    private var ringValueColor: Color {
        colorScheme == .dark ? .white : heroAccentColor.opacity(0.82)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.roomy) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    HStack(spacing: StudyDesign.Spacing.compact) {
                        Text("\(timeGreeting) · 今日学习")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(supportingForegroundColor)

                    StudyPageHeader(
                        title: title,
                        subtitle: subtitle,
                        icon: emblem,
                        tint: heroAccentColor,
                        titleColor: foregroundColor,
                        subtitleColor: supportingForegroundColor
                    )

                    heroSignalStrip

                    HStack(spacing: StudyDesign.Spacing.tight) {
                        primaryActionControl
                    }
                    .padding(.top, StudyDesign.Spacing.micro)
                }

                Spacer()

                if hasCheckedInToday {
                    ZStack {
                        CheckInSparkBurst(trigger: sparkBurstTrigger, reduceMotion: reduceMotion)
                            .allowsHitTesting(false)
                        checkInSeal
                    }
                } else if todayTotalCount > 0 {
                    energyRing
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, StudyDesign.Spacing.roomy)
            .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .background(gradient)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(alignment: .topTrailing) {
            DashboardHeroScanBeam(tint: heroAccentColor.opacity(colorScheme == .dark ? 0.055 : 0.022))
                .blendMode(.normal)
                .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(heroAccentColor.opacity(colorScheme == .dark ? 0.42 : 0.30))
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .overlay {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(
                    colorScheme == .dark
                        ? .white.opacity(0.08)
                        : StudyDesign.Colors.accentHairline,
                    lineWidth: 1
                )
        }
        .shadow(
            color: StudyDesign.Shadow.card.color.opacity(colorScheme == .dark ? 0.82 : 0.70),
            radius: bannerShadowRadius,
            y: bannerShadowY
        )
        .onAppear {
            drawRing(to: ringFraction, fromZero: true)
        }
        .onChange(of: ringFraction) { _, newValue in
            drawRing(to: newValue, fromZero: false)
        }
        .onChange(of: checkInCelebrationTrigger) { _, trigger in
            handleCheckInAnimation(trigger: trigger)
        }
        .onChange(of: hasCheckedInToday) { _, checkedIn in
            if !checkedIn {
                lastPlayedCheckInTrigger = 0
                checkInSealScale = 1
            }
        }
#if os(iOS)
        .sensoryFeedback(.success, trigger: sparkBurstTrigger)
#endif
    }

    // MARK: - Energy ring

    @ViewBuilder
    private var primaryActionControl: some View {
        let action = primaryAction
#if os(iOS)
        if action.kind == .todayReview {
            NavigationLink {
                TodayReviewView()
            } label: {
                DashboardHeroActionButton(
                    title: action.title,
                    icon: action.icon,
                    variant: action.variant,
                    accessibilityHint: action.hint
                )
            }
            .buttonStyle(DashboardHeroPressStyle())
        } else {
            Button {
                performPrimaryAction(action.kind)
            } label: {
                DashboardHeroActionButton(
                    title: action.title,
                    icon: action.icon,
                    variant: action.variant,
                    accessibilityHint: action.hint
                )
            }
            .buttonStyle(DashboardHeroPressStyle())
        }
#else
        Button {
            performPrimaryAction(action.kind)
        } label: {
            DashboardHeroActionButton(
                title: action.title,
                icon: action.icon,
                variant: action.variant,
                accessibilityHint: action.hint
            )
        }
        .buttonStyle(DashboardHeroPressStyle())
#endif
    }

    private func performPrimaryAction(_ kind: HeroActionKind) {
        switch kind {
        case .todayReview, .reviews:
            store.navigateToReviews()
        case .importData:
            store.navigateToImport()
        case .drafts:
            store.navigateToDrafts()
        case .examGoals:
            store.navigateToExamGoals()
        case .settings:
            store.navigateToSettings()
        case .chat:
            store.navigateToChat()
        }
    }

    private var heroSignalStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudyDesign.Spacing.compact) {
                DashboardHeroSignalChip(title: "待复习", value: "\(taskCount)", icon: "calendar.badge.clock", tint: taskCount > 0 ? StudyDesign.Colors.secondary : StudyDesign.Colors.labelSecondary)
                DashboardHeroSignalChip(title: "完成", value: "\(doneTodayCount)", icon: "checkmark.seal.fill", tint: hasCheckedInToday ? StudyDesign.Colors.success : StudyDesign.Colors.labelSecondary)
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                DashboardHeroSignalChip(title: "待复习", value: "\(taskCount)", icon: "calendar.badge.clock", tint: taskCount > 0 ? StudyDesign.Colors.secondary : StudyDesign.Colors.labelSecondary)
                DashboardHeroSignalChip(title: "完成", value: "\(doneTodayCount)", icon: "checkmark.seal.fill", tint: hasCheckedInToday ? StudyDesign.Colors.success : StudyDesign.Colors.labelSecondary)
            }
        }
        .padding(.top, StudyDesign.Spacing.micro)
    }

    private var todayTotalCount: Int {
        max(taskCount + doneTodayCount, 0)
    }

    private var ringFraction: CGFloat {
        let total = CGFloat(todayTotalCount)
        guard total > 0 else { return 0 }
        return min(max(CGFloat(doneTodayCount) / total, 0), 1)
    }

    private var energyRing: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(ringTrackColor, lineWidth: 5)
                .frame(width: 64, height: 64)

            // Filled track
            Circle()
                .trim(from: 0, to: animatedRingFraction)
                .stroke(
                    ringValueColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 64, height: 64)
                .shadow(color: ringValueColor.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: ringShadowRadius)

            VStack(spacing: 0) {
                Text("\(doneTodayCount)/\(todayTotalCount)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(foregroundColor)
                    .contentTransition(.numericText())
                    .animation(StudyDesign.Motion.animation(.normal), value: doneTodayCount)
                Text("今日进度")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(supportingForegroundColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日复习进度，已完成 \(doneTodayCount) 项，共 \(todayTotalCount) 项")
    }

    private var checkInSeal: some View {
        VStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34, weight: .semibold))
            Text("\(doneTodayCount) 项")
                .font(.caption.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(foregroundColor)
        .frame(width: 72, height: 72)
        .background(Circle().fill(heroAccentColor.opacity(colorScheme == .dark ? 0.16 : 0.075)))
        .overlay(Circle().stroke(heroAccentColor.opacity(colorScheme == .dark ? 0.22 : 0.13), lineWidth: 1))
        .scaleEffect(reduceMotion ? 1 : checkInSealScale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日打卡成功，已完成 \(doneTodayCount) 项复习")
    }

    private func handleCheckInAnimation(trigger: Int) {
        guard trigger > 0, trigger != lastPlayedCheckInTrigger, hasCheckedInToday else { return }
        lastPlayedCheckInTrigger = trigger
        guard !reduceMotion else { return }

        sparkBurstTrigger += 1
        checkInSealScale = 0.92
        withAnimation(StudyDesign.Motion.animation(.spring)) {
            checkInSealScale = 1.08
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(StudyDesign.Motion.animation(.spring)) {
                checkInSealScale = 1
            }
        }
    }

    private func drawRing(to target: CGFloat, fromZero: Bool) {
        if reduceMotion {
            animatedRingFraction = target
            return
        }
        if fromZero {
            animatedRingFraction = 0
        }
        withAnimation(StudyDesign.Motion.animation(.heroReveal).delay(fromZero ? 0.18 : 0)) {
            animatedRingFraction = target
        }
    }

    private var timeGreeting: String {
        switch timeSlot {
        case .morning: return "早上好"
        case .midday:  return "下午好"
        case .evening: return "晚上好"
        }
    }

    private var bannerShadowRadius: CGFloat {
#if os(iOS)
        7
#else
        12
#endif
    }

    private var bannerShadowY: CGFloat {
#if os(iOS)
        3
#else
        4
#endif
    }

    private var ringShadowRadius: CGFloat {
#if os(iOS)
        2.5
#else
        5
#endif
    }
}

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
        let radians = spark.angle * .pi / 180
        return CGSize(
            width: cos(radians) * spark.distance,
            height: sin(radians) * spark.distance
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

private struct DashboardHeroSignalChip: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
        }
        .padding(.horizontal, StudyDesign.Spacing.compact)
        .padding(.vertical, 5)
        .background(StudyDesign.Colors.dataBackground, in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct DashboardHeroActionButton: View {
    enum Variant {
        case primary
        case secondary
    }

    let title: String
    let icon: String
    let variant: Variant
    var accessibilityHint = ""
    @Environment(\.colorScheme) private var colorScheme

    private var foreground: Color {
        if colorScheme == .dark {
            switch variant {
            case .primary:
                return .white.opacity(0.94)
            case .secondary:
                return .white.opacity(0.88)
            }
        } else {
            switch variant {
            case .primary:
                return .white
            case .secondary:
                return StudyDesign.Colors.labelPrimary
            }
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 15, height: 15)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(buttonBackground)
        .overlay(buttonStroke)
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
        .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
        .help(accessibilityHint.isEmpty ? title : accessibilityHint)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if colorScheme == .dark {
            switch variant {
            case .primary:
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .fill(
                        LinearGradient(
                            colors: [
                                StudyDesign.Colors.primary.opacity(0.78),
                                StudyDesign.Colors.primary.opacity(0.58)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            case .secondary:
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .fill(StudyDesign.Colors.inputBackground)
            }
        } else {
            switch variant {
            case .primary:
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .fill(StudyDesign.Colors.primary)
            case .secondary:
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .fill(
                        LinearGradient(
                            colors: [
                                StudyDesign.Colors.elevatedBackground,
                                StudyDesign.Colors.dataBackground
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private var buttonStroke: some View {
        if colorScheme == .dark {
            switch variant {
            case .primary:
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .stroke(StudyDesign.Colors.primary.opacity(0.18), lineWidth: 1)
            case .secondary:
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
            }
        } else {
            switch variant {
            case .primary:
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .stroke(StudyDesign.Colors.primary.opacity(0.16), lineWidth: 1)
            case .secondary:
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .stroke(StudyDesign.Colors.inputHairline, lineWidth: 1)
            }
        }
    }
}

private struct DashboardHeroPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(StudyDesign.Motion.animation(.fast), value: configuration.isPressed)
    }
}

private struct DashboardHeroScanBeam: View {
    let tint: Color

    @ViewBuilder
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(scanGradient)
                .frame(width: size.width * 0.58, height: size.height)
                .offset(x: size.width * 0.42)
        }
    }

    private var scanGradient: LinearGradient {
        LinearGradient(
            colors: [
                .clear,
                tint.opacity(0.42),
                tint.opacity(0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
