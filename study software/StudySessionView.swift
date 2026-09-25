import SwiftUI
import Combine

// MARK: - D 模块：学习会话界面
//
// 职责边界（公共约束 6：界面不直接修改快照）：
// - 本视图只接收参数（会话、计划项上下文、已计算好的分钟数）并通过回调交互；
// - 不读全局 AppStore、不写文件、不发通知、不直接改 `StoreSnapshot`；
// - 所有持久化由 G 的 `DailyPlanCoordinator` 统一入口完成。
//
// 会话计时（会话要求 9–10）：
// - 进程内的持续时长用单调时钟（`ContinuousClock`）计算，不受系统对时影响；
// - 持久化时间戳（`startedAt` / `pauses` / `endedAt`）仍是权威记录；
// - 视图每次出现都以"已保存进度 + 单调时钟增量"重建显示值，
//   因此重启后不丢失进度，也不会无条件把离线时间算作学习。

// MARK: - 展示模型

/// 会话页需要展示的计划项信息（由调用方从计划快照翻译而来）。
struct StudySessionPresentation: Hashable, Sendable {
    var planItemID: UUID
    var title: String
    var sourceLabel: String
    var plannedScope: StudyScope
    var minimumScope: StudyScope?
    var estimatedMinutes: Int
    var isPinned: Bool

    init(
        planItemID: UUID,
        title: String,
        sourceLabel: String,
        plannedScope: StudyScope,
        minimumScope: StudyScope? = nil,
        estimatedMinutes: Int = 0,
        isPinned: Bool = false
    ) {
        self.planItemID = planItemID
        self.title = title
        self.sourceLabel = sourceLabel
        self.plannedScope = plannedScope
        self.minimumScope = minimumScope
        self.estimatedMinutes = max(0, estimatedMinutes)
        self.isPinned = isPinned
    }

    /// 从计划项构造。
    init(item: DailyPlanItem) {
        self.init(
            planItemID: item.id,
            title: item.title,
            sourceLabel: item.source.kind.label,
            plannedScope: item.plannedScope,
            minimumScope: item.minimumScope,
            estimatedMinutes: item.estimatedMinutes,
            isPinned: item.isPinned
        )
    }

    /// 从计划项会话上下文构造（引擎侧使用）。
    init(context: PlanItemSessionContext) {
        self.init(
            planItemID: context.planItemID,
            title: context.title,
            sourceLabel: context.source.kind.label,
            plannedScope: context.plannedScope,
            minimumScope: context.minimumScope
        )
    }
}

/// 中断确认请求（切后台 / 崩溃后恢复）。
struct StudySessionInterruptionPrompt: Hashable, Sendable {
    var gapMinutes: Int
    var message: String
    var wasPaused: Bool

    init(gapMinutes: Int, message: String, wasPaused: Bool) {
        self.gapMinutes = max(0, gapMinutes)
        self.message = message
        self.wasPaused = wasPaused
    }

    init(interruption: StudySessionInterruption) {
        self.init(
            gapMinutes: interruption.gapMinutes,
            message: interruption.prompt,
            wasPaused: interruption.wasPaused
        )
    }
}

// MARK: - 会话视图

/// 学习会话视图：开始 / 暂停 / 继续 / 结束 / 放弃。
///
/// 由 G 在今日计划里以 `presentation` 方式接入；本视图不做任何持久化。
struct StudySessionView: View {
    /// 已保存的会话；`nil` 表示这条任务还没有开始过。
    var session: StudySession?
    /// 计划项信息。
    var presentation: StudySessionPresentation
    /// 已保存的有效时长（权威值，由调用方用持久化时间戳算出）。
    var persistedEffectiveMinutes: Int
    /// 中断确认（非空时显示确认条）。
    var interruption: StudySessionInterruptionPrompt?
    /// 引擎给出的时间建议（可选的减量提示文案）。
    var advice: String?

    var onStart: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    /// 结束并提交完成范围（实际完成的内容量）。
    var onFinish: (_ scope: StudyScope, _ assessment: StudyAssessment?, _ note: String) -> Void
    var onAbandon: (_ reason: String) -> Void
    /// 记录一次推进（不结束会话）。
    var onRecordProgress: (_ scope: StudyScope) -> Void
    /// 中断确认：`true` 表示中断期间确实在学。
    var onConfirmInterruption: ((_ studiedDuringGap: Bool) -> Void)?

    @State private var clock = StudySessionClock()
    @State private var sessionBaseMinutes: Int = 0
    @State private var tickMinutes: Int = 0
    @State private var showsFinishSheet = false
    @State private var showsAbandonDialog = false
    @State private var progressAmountText = ""
    @State private var noteText = ""
    @State private var assessmentText = ""
    @State private var correctText = ""
    @State private var selfRating: Int = 3

    init(
        session: StudySession?,
        presentation: StudySessionPresentation,
        persistedEffectiveMinutes: Int,
        interruption: StudySessionInterruptionPrompt? = nil,
        advice: String? = nil,
        onStart: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onFinish: @escaping (StudyScope, StudyAssessment?, String) -> Void,
        onAbandon: @escaping (String) -> Void,
        onRecordProgress: @escaping (StudyScope) -> Void,
        onConfirmInterruption: ((Bool) -> Void)? = nil
    ) {
        self.session = session
        self.presentation = presentation
        self.persistedEffectiveMinutes = max(0, persistedEffectiveMinutes)
        self.interruption = interruption
        self.advice = advice
        self.onStart = onStart
        self.onPause = onPause
        self.onResume = onResume
        self.onFinish = onFinish
        self.onAbandon = onAbandon
        self.onRecordProgress = onRecordProgress
        self.onConfirmInterruption = onConfirmInterruption
    }

    // MARK: 派生状态

    private var state: StudySessionState? { session?.state }

    private var isActive: Bool { session?.state.isActive ?? false }
    private var isRunning: Bool { session?.state == .running }
    private var isPaused: Bool { session?.state == .paused }

    private var progressScope: StudyScope { session?.progress ?? .zero }

    /// 显示用有效时长：已保存分钟 + 本次会话期间单调时钟的增量。
    ///
    /// 暂停中不累加（`clock` 会在暂停时重置基准）。
    private var displayMinutes: Int {
        if isPaused { return sessionBaseMinutes }
        return sessionBaseMinutes + tickMinutes
    }

    /// 已完成比例（仅同量纲时给出，量纲不同返回 `nil`，不编造百分比）。
    private var progressRatio: Double? {
        guard progressScope.isPositive else { return nil }
        return progressScope.completionRatio(relativeTo: presentation.plannedScope)
    }

    private var tierPreview: PlanCompletionTier? {
        PlanCompletionTier.resolve(
            completed: progressScope,
            planned: presentation.plannedScope,
            minimum: presentation.minimumScope
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            header
            if let interruption {
                interruptionBanner(interruption)
            }
            timerBlock
            progressBlock
            if let advice, !advice.isEmpty {
                Text(advice)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }
            controls
        }
        .padding(StudyDesign.Spacing.roomy)
        .frame(maxWidth: 520, alignment: .leading)
        .studyCard()
        .studyCardStroke()
        .onAppear(perform: handleAppear)
        .onChange(of: session?.state) { _, _ in resetClock() }
        .onChange(of: session?.id) { _, _ in handleAppear() }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            tickMinutes = isRunning ? clock.elapsedMinutes : 0
        }
        .sheet(isPresented: $showsFinishSheet) { finishSheet }
        .confirmationDialog("放弃这次学习？", isPresented: $showsAbandonDialog, titleVisibility: .visible) {
            Button("放弃并保留已学时长", role: .destructive) { onAbandon("用户主动放弃") }
            Button("取消", role: .cancel) {}
        } message: {
            Text("放弃会结束会话并保留已累计的有效时长，但不会生成完成记录。")
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                Label(presentation.sourceLabel, systemImage: sourceIcon)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                if presentation.isPinned {
                    Label("已固定", systemImage: "pin.fill")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.warning)
                }
            }
            Text(presentation.title)
                .font(StudyDesign.Typography.cardTitle)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("计划范围 \(presentation.plannedScope.displayText)\(presentation.estimatedMinutes > 0 ? " · 预计 \(presentation.estimatedMinutes) 分钟" : "")")
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
    }

    private var sourceIcon: String {
        switch presentation.sourceLabel {
        case DailyPlanItemSourceKind.reviewTask.label: return "arrow.triangle.2.circlepath"
        case DailyPlanItemSourceKind.courseReview.label: return "book.closed"
        case DailyPlanItemSourceKind.preview.label: return "eye"
        default: return "square.and.pencil"
        }
    }

    // MARK: 中断确认

    private func interruptionBanner(_ prompt: StudySessionInterruptionPrompt) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            Label("检测到中断", systemImage: "exclamationmark.triangle")
                .font(StudyDesign.Typography.cardTitle)
                .foregroundStyle(StudyDesign.Colors.warning)
            Text(prompt.message)
                .font(StudyDesign.Typography.supporting)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !prompt.wasPaused, let onConfirmInterruption {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    Button("没有学习，排除这段时间") { onConfirmInterruption(false) }
                        .buttonStyle(.bordered)
                    Button("在学，计入时长") { onConfirmInterruption(true) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyDesign.Colors.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
    }

    // MARK: 计时

    private var timerBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: StudyDesign.Spacing.standard) {
            Text(Self.minuteText(displayMinutes))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isRunning ? StudyDesign.Colors.primary : StudyDesign.Colors.labelPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateLabel)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                if isPaused {
                    Text("暂停中不计入有效时长")
                        .font(.system(size: 11))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var stateLabel: String {
        guard let state else { return "尚未开始" }
        switch state {
        case .running: return "进行中"
        case .paused: return "已暂停"
        case .finished: return "已结束"
        case .abandoned: return "已放弃"
        }
    }

    // MARK: 进度

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack {
                Text("已完成内容")
                    .font(StudyDesign.Typography.cardTitle)
                Spacer()
                Text(progressSummaryText)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }

            if let ratio = progressRatio {
                ProgressView(value: min(1, max(0, ratio)))
                    .tint(ratio >= 1 ? StudyDesign.Colors.success : StudyDesign.Colors.primary)
            }

            if isActive {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    TextField(progressPlaceholder, text: $progressAmountText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    Text(progressUnitLabel)
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    Button("记录推进") { recordProgress() }
                        .buttonStyle(.bordered)
                        .disabled(parsedProgressAmount == nil)
                }
            }

            if let tier = tierPreview, progressScope.isPositive {
                Text("当前档次：\(tier.label)")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(tier == .studied ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.success)
            }
        }
    }

    private var progressSummaryText: String {
        guard progressScope.isPositive else { return "尚未记录" }
        var text = progressScope.displayText
        if let planned = progressRatio {
            text += " / \(presentation.plannedScope.displayText)（\(Int((planned * 100).rounded()))%）"
        }
        return text
    }

    private var progressUnitLabel: String {
        progressScope.isPositive ? progressScope.unitLabel : presentation.plannedScope.unitLabel
    }

    private var progressPlaceholder: String {
        progressScope.isPositive ? "继续增加" : "本次完成"
    }

    private var parsedProgressAmount: Double? {
        let trimmed = progressAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    // MARK: 控制

    private var controls: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                if session == nil {
                    Button("开始学习") { onStart() }
                        .buttonStyle(.borderedProminent)
                } else if isRunning {
                    Button("暂停") { onPause() }
                        .buttonStyle(.bordered)
                } else if isPaused {
                    Button("继续") { onResume() }
                        .buttonStyle(.borderedProminent)
                }

                if isActive {
                    Button("完成学习") { prepareFinishSheet() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!progressScope.isPositive && parsedProgressAmount == nil)
                    Button("放弃", role: .destructive) { showsAbandonDialog = true }
                        .buttonStyle(.bordered)
                }

                Spacer(minLength: 0)
            }

            if session?.state == .finished || session?.state == .abandoned {
                Text(session?.state == .finished
                     ? "本次会话已结束，完成记录只生成一次；再次学习请重新开始。"
                     : "本次会话已放弃，已累计时长仍然保留，但没有完成记录。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }

            if let note = session?.note, !note.isEmpty {
                Text(note)
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var finishSheet: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            Text("完成这次学习")
                .font(StudyDesign.Typography.sectionTitle)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Text("实际完成的内容量（\(progressUnitLabel)）")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                TextField("例如 3", text: $progressAmountText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                if let amount = parsedProgressAmount {
                    let scope = StudyScope(
                        unit: currentUnit,
                        amount: amount,
                        customUnitLabel: presentation.plannedScope.customUnitLabel
                    )
                    Text("将记为：\(scope.displayText)（计划 \(presentation.plannedScope.displayText)）")
                        .font(StudyDesign.Typography.supporting)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Text("答题情况（可选，与学习时长分开记录）")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                HStack(spacing: StudyDesign.Spacing.tight) {
                    TextField("共几题", text: $assessmentText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                    TextField("答对几题", text: $correctText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                }
                Picker("自评", selection: $selfRating) {
                    ForEach(0...5, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text("答错不影响学习时长与完成范围。")
                    .font(.system(size: 11))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Text("备注（可选）")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                TextField("例如：第三章读到一半", text: $noteText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取消") { showsFinishSheet = false }
                    .buttonStyle(.bordered)
                Spacer()
                Button("提交完成") { submitFinish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!progressScope.isPositive && parsedProgressAmount == nil)
            }
        }
        .padding(StudyDesign.Spacing.wide)
        .frame(minWidth: 380)
    }

    // MARK: 动作

    private var currentUnit: StudyScopeUnit {
        progressScope.isPositive ? progressScope.unit : presentation.plannedScope.unit
    }

    private func handleAppear() {
        sessionBaseMinutes = persistedEffectiveMinutes
        resetClock()
    }

    private func resetClock() {
        sessionBaseMinutes = persistedEffectiveMinutes
        clock = StudySessionClock()
        tickMinutes = 0
    }

    private func recordProgress() {
        guard let amount = parsedProgressAmount else { return }
        let scope = StudyScope(
            unit: currentUnit,
            amount: amount,
            customUnitLabel: presentation.plannedScope.customUnitLabel
        )
        onRecordProgress(scope)
        progressAmountText = ""
    }

    private func prepareFinishSheet() {
        if progressAmountText.isEmpty, progressScope.isPositive {
            progressAmountText = ""
        }
        showsFinishSheet = true
    }

    private func submitFinish() {
        showsFinishSheet = false
        let amount = parsedProgressAmount
        let scope: StudyScope
        if let amount {
            scope = StudyScope(
                unit: currentUnit,
                amount: amount,
                customUnitLabel: presentation.plannedScope.customUnitLabel
            )
        } else {
            scope = progressScope
        }

        let total = Int(assessmentText.trimmingCharacters(in: .whitespacesAndNewlines))
        let correct = Int(correctText.trimmingCharacters(in: .whitespacesAndNewlines))
        let assessment = StudyAssessment(
            totalQuestions: total,
            correctQuestions: correct,
            selfRating: selfRating
        )

        onFinish(scope, assessment.isEmpty ? nil : assessment, noteText)
        noteText = ""
        assessmentText = ""
        correctText = ""
        progressAmountText = ""
    }

    static func minuteText(_ minutes: Int) -> String {
        let safe = max(0, minutes)
        if safe < 60 { return "\(safe) 分钟" }
        return "\(safe / 60) 小时 \(safe % 60) 分"
    }
}

// MARK: - 预览

#if DEBUG
struct StudySessionView_Previews: PreviewProvider {
    static var previews: some View {
        StudySessionView(
            session: nil,
            presentation: StudySessionPresentation(
                planItemID: UUID(),
                title: "复习任务：线性代数特征值",
                sourceLabel: DailyPlanItemSourceKind.reviewTask.label,
                plannedScope: .questions(5),
                minimumScope: .questions(2),
                estimatedMinutes: 15
            ),
            persistedEffectiveMinutes: 0,
            onStart: {},
            onPause: {},
            onResume: {},
            onFinish: { _, _, _ in },
            onAbandon: { _ in },
            onRecordProgress: { _ in }
        )
        .padding()
    }
}
#endif
