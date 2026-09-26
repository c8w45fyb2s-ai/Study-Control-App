import SwiftUI
import UniformTypeIdentifiers

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStep: OnboardingStep = .welcome
    @State private var apiKeyInput: String = ""
    @State private var baseURL: String = "https://api.deepseek.com"
    @State private var model: String = ""
    @State private var servicePreset: AIServicePreset = .deepSeek
    @State private var protocolKind: AIProtocolKind = .openAIChatCompletions
    @State private var authMode: AIAuthMode = .providerKey
    @State private var showImporter = false
    var onComplete: () -> Void

    private var steps: [OnboardingStep] {
        Array(OnboardingStep.allCases)
    }

    private var currentStepIndex: Int {
        steps.firstIndex(of: currentStep) ?? 0
    }

    private var trimmedAPIKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var onboardingValidationMessage: String? {
        guard currentStep == .apiKey else { return nil }

        var draft = AppSettings()
        draft.baseURL = trimmedBaseURL
        draft.model = trimmedModel
        draft.servicePreset = servicePreset
        draft.protocolKind = protocolKind
        draft.authMode = authMode
        do {
            try AIConnectionConfiguration.validate(AIConnectionConfiguration(settings: draft), apiKey: trimmedAPIKey)
        } catch AIError.missingAPIKey {
            return "请输入当前 AI 服务的 API Key，或选择暂时跳过；本地服务可改选无需鉴权。"
        } catch { return error.localizedDescription }
        return nil
    }

    private var isNextButtonDisabled: Bool {
        onboardingValidationMessage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressHeader(
                currentIndex: currentStepIndex,
                total: steps.count,
                stepTitle: currentStep.rawValue,
                tint: tint(for: currentStep)
            )
            .padding(.horizontal, StudyDesign.Spacing.wide)
            .padding(.top, StudyDesign.Spacing.roomy)

            TabView(selection: $currentStep) {
                ForEach(steps, id: \.self) { step in
                    onboardingPage(for: step)
                        .tag(step)
                }
            }
#if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
#endif

            bottomBar
        }
        .frame(maxWidth: 620, minHeight: 520)
        .background(StudyDesign.Gradients.pageBackdrop)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: DocumentProcessor.supportedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importAndAnalyze(url: url, kind: .mixed)
                showCompletionStep()
            }
        }
    }

    // MARK: - Page

    @ViewBuilder
    private func onboardingPage(for step: OnboardingStep) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.relaxed) {
                OnboardingHeroPanel(
                    step: step,
                    icon: step.icon,
                    accentIcon: accentIcon(for: step),
                    title: step.title,
                    subtitle: step.subtitle,
                    tint: tint(for: step)
                )

                if step == .apiKey {
                    OnboardingCredentialPanel(
                        apiKeyInput: $apiKeyInput,
                        baseURL: $baseURL,
                        model: $model,
                        servicePreset: $servicePreset,
                        protocolKind: $protocolKind,
                        authMode: $authMode
                    )
                }
            }
            .padding(.horizontal, StudyDesign.Spacing.wide)
            .padding(.vertical, StudyDesign.Spacing.relaxed)
        }
#if os(iOS)
        .scrollIndicators(.hidden)
#endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accentIcon(for step: OnboardingStep) -> String {
        switch step {
        case .welcome:    return "sparkles"
        case .apiKey:     return "lock.shield.fill"
        case .importFirst: return "arrow.down.doc.fill"
        case .done:       return "checkmark"
        }
    }

    private func tint(for step: OnboardingStep) -> Color {
        switch step {
        case .welcome:
            return StudyDesign.Colors.warning
        case .apiKey:
            return StudyDesign.Colors.info
        case .importFirst:
            return StudyDesign.Colors.secondary
        case .done:
            return StudyDesign.Colors.success
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            if let onboardingValidationMessage {
                OnboardingValidationHint(message: onboardingValidationMessage)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    previousStepButton
                    Spacer(minLength: StudyDesign.Spacing.tight)
                    skipButton
                    nextStepButton
                }

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    HStack(spacing: StudyDesign.Spacing.tight) {
                        previousStepButton
                        Spacer(minLength: StudyDesign.Spacing.tight)
                        skipButton
                    }

                    HStack {
                        Spacer(minLength: 0)
                        nextStepButton
                    }
                }
            }
        }
        .padding(.horizontal, StudyDesign.Spacing.onboardingX)
        .padding(.vertical, StudyDesign.Spacing.normal)
        .background(
            StudyDesign.Colors.chromeBackground
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(StudyDesign.Colors.accentHairline.opacity(0.68))
                        .frame(height: 1)
                }
        )
    }

    @ViewBuilder
    private var previousStepButton: some View {
        if currentStep != .welcome {
            Button {
                goToPrevious()
            } label: {
                StudyActionPillLabel(title: "上一步", systemImage: "chevron.left")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .soft, size: .compact, minWidth: 86))
            .help("返回上一步")
            .accessibilityLabel("返回上一步")
            .accessibilityHint("回到上一段新手引导")
        }
    }

    @ViewBuilder
    private var skipButton: some View {
        if currentStep != .welcome {
            Button {
                skipOnboarding()
            } label: {
                StudyActionPillLabel(title: "暂时跳过", systemImage: "forward")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.labelSecondary, prominence: .soft, size: .compact, minWidth: 104))
            .help("暂时跳过新手引导")
            .accessibilityLabel("暂时跳过新手引导")
            .accessibilityHint("跳过后仍可在设置中补充模型和资料")
        }
    }

    private var nextStepButton: some View {
        Button {
            advance()
        } label: {
            StudyActionPillLabel(title: nextButtonLabel, systemImage: nextButtonIcon)
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .regular, minWidth: 112))
        .disabled(isNextButtonDisabled)
        .help(onboardingValidationMessage ?? nextButtonLabel)
        .accessibilityLabel(nextButtonLabel)
        .accessibilityHint(onboardingValidationMessage ?? "继续新手引导")
    }

    private var nextButtonLabel: String {
        switch currentStep {
        case .welcome:    return "下一步"
        case .apiKey:     return "下一步"
        case .importFirst: return "选择文件"
        case .done:       return "开始使用"
        }
    }

    private var nextButtonIcon: String {
        switch currentStep {
        case .welcome, .apiKey:
            return "arrow.right"
        case .importFirst:
            return "doc.badge.plus"
        case .done:
            return "checkmark"
        }
    }

    // MARK: - Navigation

    private func goToPrevious() {
        guard let idx = steps.firstIndex(of: currentStep), idx > 0 else { return }
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast)) {
            currentStep = steps[idx - 1]
        }
    }

    private func advance() {
        guard !isNextButtonDisabled else { return }

        // Save API key before moving on
        if currentStep == .apiKey {
            guard store.updateSettings(
                baseURL: trimmedBaseURL, model: trimmedModel,
                servicePreset: servicePreset, protocolKind: protocolKind, authMode: authMode,
                chatTokenParameter: store.settings.chatTokenParameter,
                anthropicOutputTokenLimit: store.settings.anthropicOutputTokenLimit,
                temperature: store.settings.temperature,
                useNativeJSONMode: store.settings.useNativeJSONMode,
                remindersEnabled: true, defaultReminderHour: 9, apiKey: trimmedAPIKey,
                allowModelRequests: true,
                allowStructuredPlanRequests: true,
                includePersonalContextInAnswers: true,
                keepDocumentContent: true,
                answerMode: store.settings.answerMode,
                maxAnalysisChunkCharacters: store.settings.maxAnalysisChunkCharacters,
                inputTokenCostPerMillion: store.settings.inputTokenCostPerMillion,
                outputTokenCostPerMillion: store.settings.outputTokenCostPerMillion
            ) else { return }
        }

        // Import step opens file picker; completion advances to .done
        if currentStep == .importFirst {
            showImporter = true
            // Import success advances to the completion page. Cancelling keeps
            // this step visible so the user can choose a file or skip explicitly.
            return
        }

        // Done → complete onboarding
        if currentStep == .done {
            completeOnboarding()
            return
        }

        // Otherwise advance to next step
        guard let idx = steps.firstIndex(of: currentStep), idx < steps.count - 1 else {
            completeOnboarding()
            return
        }
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast)) {
            currentStep = steps[idx + 1]
        }
    }

    private func skipOnboarding() {
        completeOnboarding()
    }

    private func showCompletionStep() {
        withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast)) {
            currentStep = .done
        }
    }

    private func completeOnboarding() {
        store.onboardingCompleted = true
        onComplete()
    }
}

private struct OnboardingProgressHeader: View {
    let currentIndex: Int
    let total: Int
    let stepTitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    Image(systemName: "graduationcap.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous).fill(StudyDesign.Colors.inputBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                                .stroke(tint.opacity(0.18), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                        Text("学习助手设置台")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        Text("连接模型，导入资料")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: StudyDesign.Spacing.micro) {
                    Text("步骤 \(currentIndex + 1) / \(total)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                    Text(stepTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
                .padding(.horizontal, StudyDesign.Spacing.tight)
                .padding(.vertical, StudyDesign.Spacing.compact)
                .background(Capsule().fill(StudyDesign.Colors.inputBackground))
                .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 1))
            }

            Capsule()
                .fill(StudyDesign.Colors.surfaceFillDeep.opacity(0.72))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .scaleEffect(x: progressFraction, anchor: .leading)
                }

            HStack(spacing: StudyDesign.Spacing.tight) {
                ForEach(Array(stepLabels.prefix(total).enumerated()), id: \.offset) { index, label in
                    Text(label.title)
                        .font(.caption2.weight(index == currentIndex ? .bold : .semibold))
                        .foregroundStyle(index == currentIndex ? StudyDesign.Colors.labelPrimary : StudyDesign.Colors.labelTertiary)
                        .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : (index == total - 1 ? .trailing : .center))
                }
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .help("步骤 \(currentIndex + 1) / \(total)：\(stepTitle)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("新手引导进度，步骤 \(currentIndex + 1) / \(total)，\(stepTitle)")
    }

    private var stepLabels: [(number: String, title: String)] {
        [
            ("01", "欢迎"),
            ("02", "连接"),
            ("03", "资料"),
            ("04", "完成")
        ]
    }

    private var progressFraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(currentIndex + 1) / CGFloat(total)
    }
}

private struct OnboardingHeroPanel: View {
    let step: OnboardingStep
    let icon: String
    let accentIcon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.roomy) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
                    Text(stageLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                        .textCase(.uppercase)

                    Text(title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: StudyDesign.Spacing.normal)

                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous)
                        .fill(StudyDesign.Colors.inputBackground)
                        .frame(width: 86, height: 86)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(tint)
                                .frame(width: 4)
                                .padding(.vertical, StudyDesign.Spacing.tight)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous)
                                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                        )

                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(tint)

                    Image(systemName: accentIcon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(StudyDesign.Colors.cardBackground))
                        .overlay(Circle().stroke(tint.opacity(0.22), lineWidth: 1))
                        .offset(x: 6, y: 6)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
                ForEach(Array(stageSignals.enumerated()), id: \.offset) { _, signal in
                    OnboardingHeroSignal(title: signal.title, value: signal.value, icon: signal.icon, tint: tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.roomy)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous)
                    .fill(StudyDesign.Colors.cardBackground)
                RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous)
                    .fill(StudyDesign.Gradients.semanticWash(tint).opacity(0.22))
                Rectangle()
                    .fill(tint)
                    .frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.large, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.large)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .help("\(title)：\(subtitle)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(subtitle)")
    }

    private var stageLabel: String {
        switch step {
        case .welcome: return "开始设置"
        case .apiKey: return "模型连接"
        case .importFirst: return "导入资料"
        case .done: return "准备完成"
        }
    }

    private var stageSignals: [(title: String, value: String, icon: String)] {
        switch step {
        case .welcome:
            return [("目标", "错题到计划", "target"), ("节奏", "每日复习", "calendar"), ("记忆", "长期跟踪", "chart.line.uptrend.xyaxis")]
        case .apiKey:
            return [("密钥", "钥匙串保存", "lock.fill"), ("端点", "当前服务", "network"), ("模式", "个人资料检索", "person.text.rectangle")]
        case .importFirst:
            return [("输入", "资料解析", "doc.text.magnifyingglass"), ("提取", "知识点", "point.3.connected.trianglepath.dotted"), ("生成", "复习任务", "checklist")]
        case .done:
            return [("连接", "就绪", "checkmark.seal.fill"), ("资料", "可扩展", "tray.full.fill"), ("规划", "可启动", "sparkles")]
        }
    }
}

private struct OnboardingCredentialPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdvancedConnection = false
    @Binding var apiKeyInput: String
    @Binding var baseURL: String
    @Binding var model: String
    @Binding var servicePreset: AIServicePreset
    @Binding var protocolKind: AIProtocolKind
    @Binding var authMode: AIAuthMode

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
                Label("模型连接", systemImage: "lock.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)

                Spacer()

                Text("本地安全存储")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.success)
                    .padding(.horizontal, StudyDesign.Spacing.tight)
                    .padding(.vertical, StudyDesign.Spacing.micro)
                    .background(Capsule().fill(StudyDesign.Colors.cardBackground))
                    .overlay(Capsule().stroke(StudyDesign.Colors.success.opacity(0.16), lineWidth: 1))
            }

            Picker("厂商预设", selection: $servicePreset) {
                ForEach(AIServicePreset.allCases) { preset in Text(preset.label).tag(preset) }
            }
            Picker("接口协议", selection: $protocolKind) {
                ForEach(AIProtocolKind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            Button("应用厂商默认地址与协议") {
                let defaults = servicePreset.defaults
                protocolKind = defaults.protocolKind
                baseURL = defaults.baseURL
                authMode = defaults.authMode
                if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == AIServicePreset.deepSeek.defaults.model {
                    model = defaults.model
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .trailing)
            Picker("鉴权方式", selection: $authMode) {
                ForEach(AIAuthMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            if authMode == .providerKey {
                OnboardingSecureFieldRow(
                    title: "当前 AI 服务 API Key",
                    text: $apiKeyInput,
                    prompt: "粘贴 API Key",
                    icon: "key.horizontal.fill",
                    tint: StudyDesign.Colors.success,
                    isTechnicalInput: true
                )
            } else {
                Text("无需鉴权仅适用于本地服务或明确允许匿名访问的服务。")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.warning)
            }

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Button {
                    withAnimation(reduceMotion ? nil : StudyDesign.Motion.animation(.fast)) {
                        showAdvancedConnection.toggle()
                    }
                } label: {
                    HStack(spacing: StudyDesign.Spacing.tight) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StudyDesign.Colors.info)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(StudyDesign.Colors.cardBackground))

                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                            Text("高级连接设置")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                            Text("设置 API 根地址、模型 ID 和协议参数")
                                .font(.caption2)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }

                        Spacer(minLength: StudyDesign.Spacing.tight)

                        Image(systemName: showAdvancedConnection ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .iOSTouchTarget()
                .accessibilityLabel(showAdvancedConnection ? "收起高级连接设置" : "展开高级连接设置")

                if showAdvancedConnection {
                    OnboardingTextFieldRow(
                        title: "Base URL",
                        text: $baseURL,
                        prompt: "API 根地址，例如 https://api.openai.com/v1",
                        icon: "network",
                        tint: StudyDesign.Colors.info,
                        isTechnicalInput: true,
                        isURLInput: true
                    )

                    OnboardingTextFieldRow(
                        title: "模型 ID（手动输入）",
                        text: $model,
                        prompt: "输入服务支持的模型 ID",
                        icon: "brain.head.profile",
                        tint: StudyDesign.Colors.secondary,
                        isTechnicalInput: true
                    )
                }
            }
            .padding(StudyDesign.Spacing.tight)
            .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(
            LinearGradient(
                colors: [
                    StudyDesign.Colors.cardBackground,
                    StudyDesign.Colors.inputBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                .fill(StudyDesign.Colors.success.opacity(0.72))
                .frame(width: 3)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .help("填写模型连接信息")
        .accessibilityElement(children: .contain)
        .onChange(of: baseURL) { _, _ in apiKeyInput = "" }
        .onChange(of: protocolKind) { _, _ in apiKeyInput = "" }
        .onChange(of: authMode) { _, _ in apiKeyInput = "" }
    }
}

private struct OnboardingTextFieldRow: View {
    @FocusState private var isFocused: Bool
    let title: String
    @Binding var text: String
    let prompt: String
    let icon: String
    var tint: Color = StudyDesign.Colors.info
    var isTechnicalInput = false
    var isURLInput = false

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(fieldIconColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(StudyDesign.Colors.cardBackground))
                .overlay(Circle().stroke(fieldIconStroke, lineWidth: isFocused ? 2 : 1))

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .focused($isFocused)
                    .autocorrectionDisabled(isTechnicalInput || isURLInput)
                    .help(title)
                    .accessibilityLabel(title)
                    .accessibilityValue(text.isEmpty ? "未输入" : text)
                    .accessibilityHint(isURLInput ? "输入服务地址" : "输入\(title)")
                    .iOSTouchTarget()
#if os(iOS)
                    .keyboardType(isURLInput ? .URL : .default)
                    .textInputAutocapitalization(isTechnicalInput || isURLInput ? .never : .sentences)
                    .submitLabel(.done)
#endif
            }
        }
        .onboardingFieldChrome(tint: tint, isFocused: isFocused, hasContent: !text.isEmpty)
    }

    private var fieldIconColor: Color {
        if isFocused { return StudyDesign.Colors.primary }
        return text.isEmpty ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.labelPrimary
    }

    private var fieldIconStroke: Color {
        if isFocused { return StudyDesign.Colors.primary }
        return text.isEmpty ? StudyDesign.Colors.accentHairline : tint.opacity(0.24)
    }
}

private struct OnboardingValidationHint: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.warning)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                StudyDesign.Colors.inputBackground,
                in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
    }
}

private struct OnboardingSecureFieldRow: View {
    @FocusState private var isFocused: Bool
    let title: String
    @Binding var text: String
    let prompt: String
    let icon: String
    var tint: Color = StudyDesign.Colors.success
    var isTechnicalInput = false

    var body: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(fieldIconColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(StudyDesign.Colors.cardBackground))
                .overlay(Circle().stroke(fieldIconStroke, lineWidth: isFocused ? 2 : 1))

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                SecureField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .focused($isFocused)
                    .autocorrectionDisabled(isTechnicalInput)
                    .help(title)
                    .accessibilityLabel(title)
                    .accessibilityValue(text.isEmpty ? "未输入" : "已输入")
                    .accessibilityHint("输入\(title)")
                    .iOSTouchTarget()
#if os(iOS)
                    .textInputAutocapitalization(isTechnicalInput ? .never : .sentences)
                    .submitLabel(.done)
#endif
            }
        }
        .onboardingFieldChrome(tint: tint, isFocused: isFocused, hasContent: !text.isEmpty)
    }

    private var fieldIconColor: Color {
        if isFocused { return StudyDesign.Colors.primary }
        return text.isEmpty ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.labelPrimary
    }

    private var fieldIconStroke: Color {
        if isFocused { return StudyDesign.Colors.primary }
        return text.isEmpty ? StudyDesign.Colors.accentHairline : tint.opacity(0.24)
    }
}

private struct OnboardingHeroSignal: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(StudyDesign.Colors.cardBackground))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Text(value)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.54), lineWidth: 1)
        )
    }
}

private extension View {
    func onboardingFieldChrome(tint: Color, isFocused: Bool, hasContent: Bool) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(StudyDesign.Spacing.normal)
            .background(
                LinearGradient(
                    colors: [
                        isFocused ? StudyDesign.Colors.inputBackground : (hasContent ? StudyDesign.Colors.inputBackground : StudyDesign.Colors.cardBackground),
                        isFocused ? StudyDesign.Colors.cardBackground : (hasContent ? StudyDesign.Colors.cardBackground : StudyDesign.Colors.inputBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                    .stroke(
                        isFocused ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                    .fill(isFocused ? StudyDesign.Colors.primary : tint.opacity(hasContent ? 0.52 : 0.24))
                    .frame(width: 2)
                    .padding(.vertical, StudyDesign.Spacing.tight)
            }
            .shadow(
                color: isFocused ? StudyDesign.Colors.primary.opacity(0.16) : StudyDesign.Shadow.card.color.opacity(hasContent ? 0.82 : 0.52),
                radius: isFocused ? 6 : (hasContent ? 4 : 2),
                y: isFocused ? 0 : 1
            )
    }
}
