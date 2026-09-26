import SwiftUI
import UniformTypeIdentifiers

private enum ModelConnectionTestState: Equatable {
    case idle
    case running
    case success
    case failure(String)
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @SceneStorage("settings.draft.baseURL") private var baseURL = ""
    @SceneStorage("settings.draft.model") private var model = ""
    @SceneStorage("settings.draft.servicePreset") private var servicePresetRaw = AIServicePreset.deepSeek.rawValue
    @SceneStorage("settings.draft.protocolKind") private var protocolKindRaw = AIProtocolKind.openAIChatCompletions.rawValue
    @SceneStorage("settings.draft.authMode") private var authModeRaw = AIAuthMode.providerKey.rawValue
    @SceneStorage("settings.draft.chatTokenParameter") private var chatTokenParameterRaw = AIChatTokenParameter.maxTokens.rawValue
    @SceneStorage("settings.draft.anthropicOutputLimitText") private var anthropicOutputTokenLimitText = "4096"
    @SceneStorage("settings.draft.useAnthropicOutputLimit") private var useAnthropicOutputLimit = false
    @SceneStorage("settings.draft.temperature") private var temperatureText = ""
    @SceneStorage("settings.draft.useNativeJSONMode") private var useNativeJSONMode = false
    @SceneStorage("settings.draft.remindersEnabled") private var remindersEnabled = true
    @SceneStorage("settings.draft.defaultReminderHour") private var defaultReminderHour = 9
    @SceneStorage("settings.draft.allowModelRequests") private var allowModelRequests = true
    @SceneStorage("settings.draft.allowStructuredPlanRequests") private var allowStructuredPlanRequests = true
    @SceneStorage("settings.draft.includePersonalContext") private var includePersonalContextInAnswers = true
    @SceneStorage("settings.draft.keepDocumentContent") private var keepDocumentContent = true
    @SceneStorage("settings.draft.maxChunkCharacters") private var maxAnalysisChunkCharacters = 12_000
    @SceneStorage("settings.draft.inputTokenCost") private var inputTokenCostPerMillion = 0.0
    @SceneStorage("settings.draft.outputTokenCost") private var outputTokenCostPerMillion = 0.0
    @SceneStorage("settings.draft.appearanceMode") private var appearanceModeRaw = AppAppearanceMode.system.rawValue
    @SceneStorage("settings.draft.answerMode") private var answerModeRaw = AIAnswerMode.normal.rawValue
    @SceneStorage("settings.draft.loaded") private var hasLoadedSettingsDraft = false
    @State private var connectionTestState: ModelConnectionTestState = .idle
    @State private var isExportingBackup = false
    @State private var isExportingPrivacyBackup = false
    @State private var isExportingMarkdown = false
    @State private var isExportingAnki = false
    @State private var isImportingBackup = false
    @State private var showAdvancedSettings = false
    @State private var showModelConnection = false
    @State private var showUsageDetails = false
    @State private var showDataTools = false
    @State private var showAnswerModeDetails = false
    @State private var showPrivacyDetails = false
    @State private var showReminderDetails = false

    // MARK: 课表 / 作息入口（G 接入）
    @State private var isShowingTimetable = false
    @State private var isShowingAvailabilitySettings = false
    @State private var isShowingEntertainment = false
    @State private var entertainmentNotificationAuthorized: Bool?

    var body: some View {
        settingsContent
        .navigationTitle("设置")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .dismissKeyboardOnTapOutside()
        .scrollDismissesKeyboard(.interactively)
        .fileExporter(
            isPresented: $isExportingBackup,
            document: store.makeBackupDocument(),
            contentType: .json,
            defaultFilename: "StudyCompanionBackup.json"
        ) { result in
            if case .failure(let error) = result {
                store.statusMessage = "导出备份失败：\(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExportingPrivacyBackup,
            document: store.makePrivacyBackupDocument(),
            contentType: .json,
            defaultFilename: "StudyCompanionPrivacyBackup.json"
        ) { result in
            if case .failure(let error) = result {
                store.statusMessage = "导出隐私备份失败：\(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExportingMarkdown,
            document: store.makeMarkdownExportDocument(),
            contentType: .plainText,
            defaultFilename: "StudyCompanionExport.md"
        ) { result in
            if case .failure(let error) = result {
                store.statusMessage = "导出汇总失败：\(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isExportingAnki,
            document: store.makeAnkiExportDocument(),
            contentType: .tabSeparatedText,
            defaultFilename: "StudyCompanionAnki.tsv"
        ) { result in
            if case .failure(let error) = result {
                store.statusMessage = "导出 Anki 牌组失败：\(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    store.importBackup(url: url)
                }
            case .failure(let error):
                store.statusMessage = "导入备份失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $isShowingTimetable) {
            TimetableSheetHost(isPresented: $isShowingTimetable)
        }
        .sheet(isPresented: $isShowingAvailabilitySettings) {
            NavigationStack {
                availabilitySheet
            }
#if os(macOS)
            .frame(minWidth: 900, minHeight: 680)
#endif
        }
        .sheet(isPresented: $isShowingEntertainment) {
            NavigationStack {
                entertainmentSheet
            }
#if os(macOS)
            .frame(minWidth: 900, minHeight: 700)
#endif
        }
        .onAppear {
            guard !hasLoadedSettingsDraft else { return }
            baseURL = store.settings.baseURL
            model = store.settings.model
            servicePresetRaw = store.settings.servicePreset.rawValue
            protocolKindRaw = store.settings.protocolKind.rawValue
            authModeRaw = store.settings.authMode.rawValue
            chatTokenParameterRaw = store.settings.chatTokenParameter.rawValue
            useAnthropicOutputLimit = store.settings.anthropicOutputTokenLimit != nil
            anthropicOutputTokenLimitText = String(store.settings.anthropicOutputTokenLimit ?? AIOutputBudget.documentAnalysis)
            temperatureText = store.settings.temperature.map { String($0) } ?? ""
            useNativeJSONMode = store.settings.useNativeJSONMode
            store.settingsDraftAPIKey = store.apiKey
            remindersEnabled = store.settings.remindersEnabled
            defaultReminderHour = store.settings.defaultReminderHour
            allowModelRequests = store.settings.allowModelRequests
            allowStructuredPlanRequests = store.settings.allowStructuredPlanRequests
            includePersonalContextInAnswers = store.settings.includePersonalContextInAnswers
            keepDocumentContent = store.settings.keepDocumentContent
            appearanceModeRaw = store.settings.appearanceMode.rawValue
            answerModeRaw = store.settings.answerMode.rawValue
            maxAnalysisChunkCharacters = store.settings.maxAnalysisChunkCharacters
            inputTokenCostPerMillion = store.settings.inputTokenCostPerMillion
            outputTokenCostPerMillion = store.settings.outputTokenCostPerMillion
            hasLoadedSettingsDraft = true
        }
        .onChange(of: trimmedBaseURL) { _, _ in refreshDraftCredentialForConnectionChange() }
        .onChange(of: protocolKindRaw) { _, _ in refreshDraftCredentialForConnectionChange() }
        .onChange(of: authModeRaw) { _, _ in refreshDraftCredentialForConnectionChange() }
    }

    private var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedModelName: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var servicePreset: AIServicePreset { AIServicePreset(rawValue: servicePresetRaw) ?? .custom }
    private var protocolKind: AIProtocolKind { AIProtocolKind(rawValue: protocolKindRaw) ?? .openAIChatCompletions }
    private var authMode: AIAuthMode { AIAuthMode(rawValue: authModeRaw) ?? .providerKey }
    private var chatTokenParameter: AIChatTokenParameter { AIChatTokenParameter(rawValue: chatTokenParameterRaw) ?? .maxTokens }
    private var parsedTemperature: Double? {
        let cleaned = temperatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : Double(cleaned)
    }
    private var parsedAnthropicOutputTokenLimit: Int? {
        guard useAnthropicOutputLimit else { return nil }
        return Int(anthropicOutputTokenLimitText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var draftAppSettings: AppSettings {
        var value = store.settings
        value.baseURL = trimmedBaseURL
        value.model = trimmedModelName
        value.servicePreset = servicePreset
        value.protocolKind = protocolKind
        value.authMode = authMode
        value.chatTokenParameter = chatTokenParameter
        value.anthropicOutputTokenLimit = parsedAnthropicOutputTokenLimit
        value.temperature = parsedTemperature
        value.useNativeJSONMode = useNativeJSONMode
        return value
    }

    private func refreshDraftCredentialForConnectionChange() {
        guard hasLoadedSettingsDraft else { return }
        let configuration = AIConnectionConfiguration(settings: draftAppSettings)
        store.settingsDraftAPIKey = store.loadAPIKey(for: configuration)
        connectionTestState = .idle
    }

    private var settingsValidationMessage: String? {
        do {
            try AIConnectionConfiguration.validateForSaving(AIConnectionConfiguration(settings: draftAppSettings))
            if !temperatureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               parsedTemperature == nil {
                return "temperature 必须是 0 到 2 之间的数字，或留空。"
            }
            if useAnthropicOutputLimit,
               parsedAnthropicOutputTokenLimit == nil || !(1...128_000).contains(parsedAnthropicOutputTokenLimit ?? 0) {
                return "Anthropic 最大输出预算需要填写 1 到 128000 之间的整数，或关闭自定义预算使用业务默认值。"
            }
            return nil
        } catch { return error.localizedDescription }
    }

    private var connectionValidationMessage: String? {
        if let settingsValidationMessage { return settingsValidationMessage }
        do {
            try AIConnectionConfiguration.validate(
                AIConnectionConfiguration(settings: draftAppSettings),
                apiKey: store.settingsDraftAPIKey
            )
            return nil
        } catch { return error.localizedDescription }
    }

    private var settingsSaveHelp: String {
        if let settingsValidationMessage {
            return settingsValidationMessage
        }
        if !hasSettingsChanges {
            return "当前设置已保存，无需重复保存。"
        }
        return "保存当前设置"
    }

    private var hasSettingsChanges: Bool {
        trimmedBaseURL != store.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        || trimmedModelName != store.settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        || servicePreset != store.settings.servicePreset
        || protocolKind != store.settings.protocolKind
        || authMode != store.settings.authMode
        || chatTokenParameter != store.settings.chatTokenParameter
        || parsedAnthropicOutputTokenLimit != store.settings.anthropicOutputTokenLimit
        || parsedTemperature != store.settings.temperature
        || useNativeJSONMode != store.settings.useNativeJSONMode
        || store.settingsDraftAPIKey != store.apiKey
        || remindersEnabled != store.settings.remindersEnabled
        || defaultReminderHour != store.settings.defaultReminderHour
        || allowModelRequests != store.settings.allowModelRequests
        || allowStructuredPlanRequests != store.settings.allowStructuredPlanRequests
        || includePersonalContextInAnswers != store.settings.includePersonalContextInAnswers
        || keepDocumentContent != store.settings.keepDocumentContent
        || answerMode != store.settings.answerMode
        || maxAnalysisChunkCharacters != store.settings.maxAnalysisChunkCharacters
        || inputTokenCostPerMillion != store.settings.inputTokenCostPerMillion
        || outputTokenCostPerMillion != store.settings.outputTokenCostPerMillion
    }

    private var canSaveSettings: Bool {
        hasSettingsChanges && settingsValidationMessage == nil
    }

    @ViewBuilder
    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                StudyPageHeader(
                    title: "设置",
                    subtitle: "集中管理界面、答疑、提醒、模型连接和本地数据。",
                    icon: "gearshape.fill"
                )

                SettingsSectionGroup(title: "常用偏好", subtitle: "外观、答疑、隐私和提醒。") {
                    appearanceCard
                    usageStatsCard
                    privacyCard
                    remindersCard
                }

                SettingsSectionGroup(title: "课表与作息", subtitle: "课程、停课换课例外与每日学习窗口。") {
                    scheduleCard
                }

                SettingsSectionGroup(title: "娱乐解锁", subtitle: "达标后解锁娱乐时间；本地判定，不使用网络。") {
                    entertainmentCard
                }

                SettingsSectionGroup(title: "高级与数据", subtitle: "模型连接、导出和维护。") {
                    aiConfigCard
                    dataCard
                    advancedEntryCard
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .background(StudyDesign.Gradients.pageBackdrop)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasSettingsChanges {
                SettingsSaveBar(
                    message: settingsSaveHelp,
                    canSave: canSaveSettings,
                    action: saveSettings
                )
                .padding(.horizontal, StudyDesign.Spacing.wide)
                .padding(.bottom, StudyDesign.Spacing.tight)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(StudyDesign.Motion.animation(.fast), value: hasSettingsChanges)
    }

    private var appearanceSelection: Binding<AppAppearanceMode> {
        Binding {
            appearanceMode
        } set: { newMode in
            appearanceModeRaw = newMode.rawValue
            store.updateAppearanceMode(newMode)
        }
    }

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    private var answerMode: AIAnswerMode {
        AIAnswerMode(rawValue: answerModeRaw) ?? .normal
    }

    private var answerModeSelection: Binding<AIAnswerMode> {
        Binding {
            answerMode
        } set: { newMode in
            answerModeRaw = newMode.rawValue
        }
    }

    // MARK: - 外观卡

    private var appearanceCard: some View {
        SettingsPanel(
            icon: "paintpalette.fill",
            title: "界面外观",
            subtitle: "\(appearanceMode.label) · 外观会立即应用。",
            tint: StudyDesign.Colors.primary
        ) {
            SettingsAppearanceSelector(selection: appearanceSelection)
        }
    }

    // MARK: - AI 配置卡

    private var aiConfigCard: some View {
        SettingsPanel(
            icon: "brain.head.profile",
            title: "模型连接",
            subtitle: "API Key、端点和模型名称。",
            tint: StudyDesign.Colors.info
        ) {
            VStack(spacing: StudyDesign.Spacing.tight) {
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        showModelConnection.toggle()
                    }
                } label: {
                    SettingsActionRowLabel(title: showModelConnection ? "收起连接配置" : "配置模型连接", icon: showModelConnection ? "chevron.up" : "arrow.right")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showModelConnection ? "收起模型连接配置" : "配置模型连接")

                if showModelConnection {
                    VStack(spacing: StudyDesign.Spacing.tight) {
                        Picker("厂商预设", selection: $servicePresetRaw) {
                            ForEach(AIServicePreset.allCases) { preset in Text(preset.label).tag(preset.rawValue) }
                        }
                        Picker("接口协议", selection: $protocolKindRaw) {
                            ForEach(AIProtocolKind.allCases) { kind in Text(kind.label).tag(kind.rawValue) }
                        }
                        Button("应用厂商默认地址与协议") { applySelectedServicePreset() }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityHint("厂商预设只填充默认地址、协议和鉴权方式，可继续修改全部字段。")

                        Picker("鉴权方式", selection: $authModeRaw) {
                            ForEach(AIAuthMode.allCases) { mode in Text(mode.label).tag(mode.rawValue) }
                        }
                        SettingsTextFieldRow(title: "Base URL（API 根地址）", text: $baseURL, prompt: "例如 https://api.openai.com/v1")
                            .settingsURLInputBehavior()
                        Text("输入 API 根地址，可保留代理路径前缀；不要填写密钥。若粘贴了完整接口地址，应用会移除已知接口路径。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SettingsTextFieldRow(title: "模型 ID", text: $model, prompt: "手动输入服务支持的模型 ID")
                            .settingsPlainTextInputBehavior()
                        if authMode == .providerKey {
                            SettingsSecureFieldRow(title: "API Key", text: $store.settingsDraftAPIKey, prompt: "仅保存在 Keychain")
                                .settingsPlainTextInputBehavior()
                        } else {
                            Text("已明确选择无需鉴权；仅用于本地服务或你信任且允许无鉴权的端点。")
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.warning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if protocolKind == .openAIChatCompletions {
                            Picker("输出长度参数", selection: $chatTokenParameterRaw) {
                                ForEach(AIChatTokenParameter.allCases) { item in Text(item.label).tag(item.rawValue) }
                            }
                        }
                        if protocolKind == .anthropicMessages {
                            Toggle("自定义最大输出预算", isOn: $useAnthropicOutputLimit)
                            if useAnthropicOutputLimit {
                                SettingsTextFieldRow(title: "Anthropic 最大输出预算（tokens）", text: $anthropicOutputTokenLimitText, prompt: "例如 16000")
#if os(iOS)
                                    .keyboardType(.numberPad)
#endif
                                    .settingsPlainTextInputBehavior()
                                Text("这是每次请求允许生成的最大输出 token 数，不保证模型一定输出这么长。")
                                    .font(.caption)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("未设置时，按答疑、资料分析、计划和记忆压缩等业务使用各自的默认输出预算。")
                                    .font(.caption)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        SettingsTextFieldRow(title: "temperature（可选）", text: $temperatureText, prompt: "留空使用服务默认值")
                            .settingsPlainTextInputBehavior()
                        if protocolKind != .anthropicMessages {
                            Toggle("请求原生 JSON 输出模式", isOn: $useNativeJSONMode)
                                .disabled(!(protocolKind == .openAIChatCompletions || protocolKind == .openAIResponses || protocolKind == .geminiGenerateContent))
                                .accessibilityHint("仅对支持此能力的接口发送 JSON 模式参数；关闭后仍使用提示词、解析和一次修复。")
                        }
                        if let settingsValidationMessage {
                            Label(settingsValidationMessage, systemImage: "exclamationmark.triangle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(StudyDesign.Colors.warning)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("API Key 仅保存在与接口协议和服务地址绑定的系统 Keychain 项目中，不写入备份。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: StudyDesign.Spacing.tight) {
                            Button {
                                testModelConnection()
                            } label: {
                                StudyActionPillLabel(
                                    title: connectionTestState == .running ? "正在测试" : "测试连接",
                                    systemImage: connectionTestState == .running ? "arrow.triangle.2.circlepath" : "network"
                                )
                            }
                            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.info, prominence: .secondary, minWidth: 108))
                            .disabled(connectionTestState == .running || connectionValidationMessage != nil)
                            .accessibilityHint("使用当前未保存的协议、地址、模型和鉴权方式发送真实的最小生成请求。")

                            if connectionTestState != .idle {
                                modelConnectionTestResult
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func saveSettings() {
        guard store.updateSettings(
            baseURL: trimmedBaseURL,
            model: trimmedModelName,
            servicePreset: servicePreset,
            protocolKind: protocolKind,
            authMode: authMode,
            chatTokenParameter: chatTokenParameter,
            anthropicOutputTokenLimit: parsedAnthropicOutputTokenLimit,
            temperature: parsedTemperature,
            useNativeJSONMode: useNativeJSONMode,
            remindersEnabled: remindersEnabled,
            defaultReminderHour: defaultReminderHour,
            apiKey: store.settingsDraftAPIKey,
            allowModelRequests: allowModelRequests,
            allowStructuredPlanRequests: allowStructuredPlanRequests,
            includePersonalContextInAnswers: includePersonalContextInAnswers,
            keepDocumentContent: keepDocumentContent,
            answerMode: answerMode,
            maxAnalysisChunkCharacters: maxAnalysisChunkCharacters,
            inputTokenCostPerMillion: inputTokenCostPerMillion,
            outputTokenCostPerMillion: outputTokenCostPerMillion
        ) else { return }
        connectionTestState = .idle
    }

    private func testModelConnection() {
        guard connectionValidationMessage == nil else { return }
        let key = store.settingsDraftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        connectionTestState = .running
        Task {
            do {
                let client = try AIClientFactory.make(settings: draftAppSettings, apiKey: key)
                try await client.testConnection()
                connectionTestState = .success
                StudyAccessibility.announce("模型连接成功")
            } catch {
                if let refusal = error as? AIModelRefusal {
                    store.recordAIRefusalUsage(refusal)
                }
                connectionTestState = .failure(error.localizedDescription)
                StudyAccessibility.announce("模型连接失败：\(error.localizedDescription)")
            }
        }
    }

    private func applySelectedServicePreset() {
        let oldDefaults = store.settings.servicePreset.defaults
        let defaults = servicePreset.defaults
        protocolKindRaw = defaults.protocolKind.rawValue
        baseURL = defaults.baseURL
        authModeRaw = defaults.authMode.rawValue
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model == store.settings.model && model == oldDefaults.model) {
            model = defaults.model
        }
        connectionTestState = .idle
    }

    @ViewBuilder
    private var modelConnectionTestResult: some View {
        switch connectionTestState {
        case .idle:
            EmptyView()
        case .running:
            Label("正在验证端点与模型", systemImage: "hourglass")
                .foregroundStyle(StudyDesign.Colors.info)
        case .success:
            Label("连接成功", systemImage: "checkmark.circle.fill")
                .foregroundStyle(StudyDesign.Colors.success)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(StudyDesign.Colors.danger)
                .lineLimit(2)
        }
    }

    // MARK: - 隐私卡

    private var privacyCard: some View {
        SettingsPanel(
            icon: "hand.raised.fill",
            title: "隐私",
            subtitle: allowModelRequests ? "模型请求已开启。" : "模型请求已关闭。",
            tint: StudyDesign.Colors.primary
        ) {
            VStack(spacing: StudyDesign.Spacing.tight) {
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        showPrivacyDetails.toggle()
                    }
                } label: {
                    SettingsActionRowLabel(title: showPrivacyDetails ? "收起隐私选项" : "管理隐私选项", icon: showPrivacyDetails ? "chevron.up" : "hand.raised")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPrivacyDetails ? "收起隐私选项" : "管理隐私选项")

                if showPrivacyDetails {
                    VStack(spacing: StudyDesign.Spacing.tight) {
                        SettingsToggleRow(title: "允许模型请求", subtitle: "资料分析、答疑和规划可以调用模型。", tint: StudyDesign.Colors.info, isOn: $allowModelRequests)
                        SettingsToggleRow(title: "允许结构化规划", subtitle: "允许额外请求 AI 生成可确认的复习计划。", tint: StudyDesign.Colors.secondary, isOn: $allowStructuredPlanRequests)
                            .disabled(!allowModelRequests)
                            .opacity(allowModelRequests ? 1 : 0.52)
                            .help(allowModelRequests ? "开启或关闭结构化规划请求" : "先开启允许模型请求后，再使用结构化规划。")
                            .accessibilityHint(allowModelRequests ? "开启或关闭结构化规划请求" : "先开启允许模型请求后，再使用结构化规划。")
                        SettingsToggleRow(title: "答疑引用个人资料", subtitle: "回答问题时检索错题、笔记和知识点。", tint: StudyDesign.Colors.secondary, isOn: $includePersonalContextInAnswers)
                        SettingsToggleRow(title: "本地保存导入原文", subtitle: "便于后续重新分析和检索。", tint: StudyDesign.Colors.success, isOn: $keepDocumentContent)
                        Text("关闭模型请求后，资料仍可保存在本地，但不会发送给当前 AI 服务。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - 提醒卡

    private var remindersCard: some View {
        SettingsPanel(
            icon: "bell.fill",
            title: "提醒",
            subtitle: remindersEnabled ? "复习提醒 \(defaultReminderHour):00。" : "复习提醒已关闭。",
            tint: StudyDesign.Colors.primary
        ) {
            VStack(spacing: StudyDesign.Spacing.tight) {
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        showReminderDetails.toggle()
                    }
                } label: {
                    SettingsActionRowLabel(title: showReminderDetails ? "收起提醒选项" : "管理提醒", icon: showReminderDetails ? "chevron.up" : "bell")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showReminderDetails ? "收起提醒选项" : "管理提醒")

                if showReminderDetails {
                    VStack(spacing: StudyDesign.Spacing.tight) {
                        SettingsToggleRow(title: "复习提醒", subtitle: "到期当天发送本地通知。", tint: StudyDesign.Colors.warning, isOn: $remindersEnabled)
                        SettingsStepperRow(
                            title: "默认时间",
                            subtitle: "本地通知触达时间",
                            valueText: "\(defaultReminderHour):00",
                            value: $defaultReminderHour,
                            range: 0...23,
                            step: 1,
                            tint: StudyDesign.Colors.warning
                        )
                        .disabled(!remindersEnabled)
                        .opacity(remindersEnabled ? 1 : 0.52)
                        .help(remindersEnabled ? "调整默认提醒时间" : "先开启复习提醒后，再调整默认时间。")
                        .accessibilityHint(remindersEnabled ? "调整默认提醒时间" : "先开启复习提醒后，再调整默认时间。")
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - 课表 / 作息 / 今日计划 / 娱乐

    private var scheduleSubtitle: String {
        if store.snapshot.isSemesterConfigured {
            let courseCount = store.snapshot.scheduleCourses.count
            let exceptionCount = store.snapshot.scheduleExceptions.count
            let routine = store.snapshot.availabilitySettings.hasExplicitRoutine ? "已设置作息" : "尚未设置作息（会按默认假设提示）"
            return "\(courseCount) 门课程 · \(exceptionCount) 条例外 · \(routine)"
        }
        return "尚未设置学期。设置后才能把课程与作息纳入今日计划。"
    }

    private var scheduleCard: some View {
        SettingsPanel(
            icon: "calendar.badge.clock",
            title: "课程表与作息",
            subtitle: scheduleSubtitle,
            tint: StudyDesign.Colors.info
        ) {
            VStack(spacing: StudyDesign.Spacing.tight) {
                Button {
                    isShowingTimetable = true
                } label: {
                    SettingsActionRowLabel(title: "打开课程表（课程 / 停课换课 / 学期）", icon: "calendar")
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开课程表页面编辑课程与课表例外")

                Button {
                    isShowingAvailabilitySettings = true
                } label: {
                    SettingsActionRowLabel(title: "学习窗口、睡眠与固定占用", icon: "moon.zzz")
                }
                .buttonStyle(.plain)
                .accessibilityHint("设置每天可用于学习的时间段")
            }
        }
    }

    private var entertainmentSubtitle: String {
        let planningContext = store.snapshot.planningContext(now: Date())
        let rules = store.snapshot.entitlementRules(on: planningContext.todayKey)
        guard !rules.isEmpty else {
            return "还没有生效的娱乐规则。创建规则后，达标即可解锁娱乐时间。"
        }
        let claimable = store.snapshot.pendingRewardGrants(on: planningContext.todayKey).count
        var parts = ["今天 \(rules.count) 条生效规则"]
        parts.append(claimable > 0 ? "\(claimable) 条待领取" : "没有待领取奖励")
        if EntertainmentSessionEngine.runningGrant(in: store.snapshot.rewardGrants) != nil {
            parts.append("正在计时")
        }
        return parts.joined(separator: " · ")
    }

    /// 娱乐解锁入口（E 模块视图，仅通过回调写入）。
    private var entertainmentCard: some View {
        SettingsPanel(
            icon: "gamecontroller",
            title: "娱乐解锁与计时",
            subtitle: entertainmentSubtitle,
            tint: StudyDesign.Colors.primary
        ) {
            VStack(spacing: StudyDesign.Spacing.tight) {
                Button {
                    isShowingEntertainment = true
                } label: {
                    SettingsActionRowLabel(title: "打开娱乐规则与今日奖励", icon: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)
                .accessibilityHint("管理娱乐解锁规则、领取奖励并查看计时")
            }
        }
    }

    private var entertainmentSheet: some View {
        let planningContext = store.snapshot.planningContext(now: Date())
        return ScrollView(.vertical) {
            EntertainmentRulesView(
                context: store.snapshot.entertainmentContext(
                    context: planningContext,
                    notificationAuthorized: entertainmentNotificationAuthorized
                ),
                onSaveRule: { draft in
                    store.saveEntertainmentRule(
                        name: draft.name,
                        condition: draft.condition,
                        fallback: draft.fallback,
                        rewardMinutes: draft.rewardMinutes,
                        ruleID: draft.ruleID,
                        effectiveFrom: draft.effectiveFromValue,
                        effectiveUntil: draft.effectiveUntilValue,
                        repeatWeekdays: draft.repeatWeekdays,
                        targets: draft.preset == .designatedTasks && !draft.targets.isEmpty ? draft.targets : nil,
                        isEnabled: draft.isEnabled
                    )
                },
                onDeleteRule: { store.deleteEntertainmentRule(id: $0) },
                onToggleRule: { id, enabled in store.setEntertainmentRuleEnabled(id: id, isEnabled: enabled) },
                onRefresh: { refreshEntertainment() },
                onIntents: { intents in
                    Task { await store.applyEntertainmentIntents(intents) }
                },
                onClose: { isShowingEntertainment = false }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
#if os(iOS)
        .navigationTitle("娱乐解锁")
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear {
            refreshEntertainment()
            Task {
                entertainmentNotificationAuthorized = await EntertainmentNotificationAvailability.isAuthorized()
            }
        }
    }

    /// 刷新娱乐资格：走统一计划协调入口，不直接改快照。
    private func refreshEntertainment() {
        let planningContext = store.snapshot.planningContext(now: Date())
        Task {
            await store.performPlanAction(.refresh(dayKey: planningContext.todayKey))
        }
    }

    private var availabilitySheet: some View {
        AvailabilitySettingsView(
            semester: store.snapshot.scheduleSemester ?? .fallback,
            settings: store.snapshot.availabilitySettings,
            courses: store.snapshot.scheduleCourses,
            exceptions: store.snapshot.scheduleExceptions,
            now: Date(),
            periodTemplates: store.snapshot.schedulePeriodTemplates,
            onSaveSettings: { settings, templates in
                store.saveAvailabilityAndPeriodTemplates(settings: settings, templates: templates)
            },
            onCancel: { isShowingAvailabilitySettings = false }
        )
    }

    // MARK: - 费用统计卡

    private var usageStatsCard: some View {
        SettingsPanel(
            icon: "chart.bar.xaxis",
            title: "答疑模式",
            subtitle: answerMode.label,
            tint: StudyDesign.Colors.info
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        showAnswerModeDetails.toggle()
                    }
                } label: {
                    SettingsActionRowLabel(title: showAnswerModeDetails ? "收起答疑偏好" : "更改答疑偏好", icon: showAnswerModeDetails ? "chevron.up" : "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showAnswerModeDetails ? "收起答疑偏好" : "更改答疑偏好")

                if showAnswerModeDetails {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                        SettingsAnswerModeSelector(selection: answerModeSelection)

                        Button {
                            withAnimation(StudyDesign.Motion.animation(.fast)) {
                                showUsageDetails.toggle()
                            }
                        } label: {
                            SettingsActionRowLabel(title: showUsageDetails ? "收起统计详情" : "查看统计详情", icon: showUsageDetails ? "chevron.up" : "chart.bar.xaxis")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showUsageDetails ? "收起模型统计详情" : "查看模型统计详情")

                        if showUsageDetails {
                            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                                SettingsStepperRow(
                                    title: "长资料处理",
                                    subtitle: "单次读取上限",
                                    valueText: "\(maxAnalysisChunkCharacters) 字符",
                                    value: $maxAnalysisChunkCharacters,
                                    range: 2_000...24_000,
                                    step: 1_000,
                                    tint: StudyDesign.Colors.info
                                )

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
                                    SettingsMetricTile(title: "请求次数", value: "\(store.snapshot.usageStats.requestCount)")
                                    SettingsMetricTile(title: "输入 Token", value: "\(store.snapshot.usageStats.inputTokens)")
                                    SettingsMetricTile(title: "输出 Token", value: "\(store.snapshot.usageStats.outputTokens)")
                                    SettingsMetricTile(title: "预估费用", value: store.snapshot.usageStats.estimatedCost.formatted(.currency(code: "CNY")))
                                }

                                SettingsNumberFieldRow(
                                    title: "输入单价",
                                    subtitle: "每百万 Token",
                                    value: $inputTokenCostPerMillion
                                )
                                SettingsNumberFieldRow(
                                    title: "输出单价",
                                    subtitle: "每百万 Token",
                                    value: $outputTokenCostPerMillion
                                )

                                if store.hasActiveAIRequest {
                                    HStack(spacing: StudyDesign.Spacing.normal) {
                                        ProgressView()
                                        Text(store.activeAIRequestTitle.isEmpty ? "AI 请求进行中" : store.activeAIRequestTitle)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                        Spacer()
                                        Button("取消") {
                                            store.cancelAIRequest()
                                        }
                                        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.danger, prominence: .soft, size: .compact))
                                        .help("取消当前 AI 请求")
                                        .accessibilityLabel("取消当前 AI 请求")
                                        .accessibilityHint("停止正在进行的模型分析或生成。")
                                    }
                                    .settingsRowChrome()
                                }

                                if let lastUpdated = store.snapshot.usageStats.lastUpdated {
                                    SettingsInfoRow(
                                        title: "最近统计",
                                        value: lastUpdated.formatted(date: .abbreviated, time: .shortened),
                                        icon: "clock"
                                    )
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - 数据卡

    private var dataCard: some View {
        SettingsPanel(
            icon: "externaldrive.fill",
            title: "数据",
            subtitle: "本地资料、备份和导出。",
            tint: StudyDesign.Colors.secondary
        ) {
            VStack(spacing: StudyDesign.Spacing.tight) {
                SettingsInfoRow(title: "存储状态", value: store.storageStatusMessage, icon: "internaldrive")
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        showDataTools.toggle()
                    }
                } label: {
                    SettingsActionRowLabel(title: showDataTools ? "收起数据工具" : "打开数据工具", icon: showDataTools ? "chevron.up" : "externaldrive")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showDataTools ? "收起数据工具" : "打开数据工具")

                if showDataTools {
                    VStack(spacing: StudyDesign.Spacing.tight) {
                        dataAction(label: "刷新本地数据", icon: "arrow.clockwise") {
                            store.reloadStoredData()
                        }
                        dataAction(label: "导出完整备份", icon: "square.and.arrow.up") {
                            isExportingBackup = true
                        }
                        dataAction(label: "导出隐私备份", icon: "lock.doc") {
                            isExportingPrivacyBackup = true
                        }
                        dataAction(label: "导入完整备份", icon: "square.and.arrow.down") {
                            isImportingBackup = true
                        }
                        dataAction(label: "导出 Markdown 汇总", icon: "doc.text") {
                            isExportingMarkdown = true
                        }
                        dataAction(label: "导出 Anki 牌组", icon: "rectangle.stack") {
                            isExportingAnki = true
                        }
                        Text("完整备份不包含 Keychain 中的 API Key。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func dataAction(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsActionRowLabel(title: label, icon: icon)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint("执行\(label)操作")
    }

    // MARK: - 高级维护入口卡

    private var advancedEntryCard: some View {
        SettingsPanel(
            icon: "wrench.and.screwdriver.fill",
            title: "高级维护",
            subtitle: "备份恢复、诊断记录和费用统计重置。",
            tint: StudyDesign.Colors.labelSecondary
        ) {
            Button {
                showAdvancedSettings = true
            } label: {
                SettingsActionRowLabel(title: "打开高级维护", icon: "arrow.right")
            }
            .buttonStyle(.plain)
            .help("打开高级维护")
            .accessibilityLabel("打开高级维护")
            .accessibilityHint("进入备份恢复、诊断记录和费用统计重置。")
            .sheet(isPresented: $showAdvancedSettings) {
                NavigationStack {
                    AdvancedSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("完成") { showAdvancedSettings = false }
                                    .help("关闭高级维护")
                                    .accessibilityLabel("关闭高级维护")
                            }
                        }
                }
#if os(macOS)
                .frame(width: 520, height: 560)
#endif
            }
        }
    }
}

private struct SettingsSaveBar: View {
    let message: String
    let canSave: Bool
    let action: () -> Void

    private var tint: Color {
        canSave ? StudyDesign.Colors.info : StudyDesign.Colors.warning
    }

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            Image(systemName: canSave ? "square.and.arrow.down.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                        .stroke(tint.opacity(0.18), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(canSave ? "有未保存的设置" : "需要修正后保存")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            Button(action: action) {
                StudyActionPillLabel(title: "保存设置", systemImage: "checkmark")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, minWidth: 118))
            .disabled(!canSave)
            .keyboardShortcut("s", modifiers: .command)
            .help(message)
            .accessibilityLabel("保存设置")
            .accessibilityHint(message)
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.chromeBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.large))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.large)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.elevated.color.opacity(0.36), radius: 6, y: 2)
        .accessibilityElement(children: .contain)
    }
}

private struct SettingsSectionGroup<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, StudyDesign.Spacing.micro)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsPanel<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                            .fill(StudyDesign.Colors.dataBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                            .stroke(tint.opacity(0.18), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.72), lineWidth: 1)
        )
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    @Binding var text: String
    let prompt: String
    var autoFocus = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .focused($isFocused)
                .accessibilityLabel(title)
        }
        .settingsRowChrome(isFocused: isFocused)
        .onAppear {
            guard autoFocus else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                isFocused = true
            }
        }
    }
}

private struct SettingsSecureFieldRow: View {
    let title: String
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            SecureField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .focused($isFocused)
                .accessibilityLabel(title)
        }
        .settingsRowChrome(isFocused: isFocused)
    }
}

private struct SettingsNumberFieldRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }

            Spacer()

            TextField("0", value: $value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .frame(width: 86)
                .focused($isFocused)
                .accessibilityLabel(title)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
        }
        .settingsRowChrome(isFocused: isFocused)
    }
}

private struct SettingsAnswerModeSelector: View {
    @Binding var selection: AIAnswerMode

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(alignment: .firstTextBaseline) {
                Text("答疑模式")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Spacer()
                Text(selection.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.info)
            }

            HStack(spacing: StudyDesign.Spacing.compact) {
                ForEach(AIAnswerMode.allCases) { mode in
                    SettingsModeChip(
                        title: mode.label,
                        isSelected: mode == selection
                    ) {
                        selection = mode
                    }
                }
            }
        }
        .settingsRowChrome()
    }
}

private struct SettingsAppearanceSelector: View {
    @Binding var selection: AppAppearanceMode

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack(spacing: StudyDesign.Spacing.compact) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    SettingsAppearanceSegment(
                        mode: mode,
                        isSelected: mode == selection
                    ) {
                        selection = mode
                    }
                }
            }

            Text("外观会立即应用：\(selection.subtitle)")
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsRowChrome()
    }
}

private struct SettingsAppearanceSegment: View {
    let mode: AppAppearanceMode
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: StudyDesign.Spacing.compact) {
                Image(systemName: mode.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : StudyDesign.Colors.primary)
                    .frame(height: 18)
                Text(mode.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? .white : StudyDesign.Colors.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.horizontal, StudyDesign.Spacing.compact)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .fill(isSelected ? StudyDesign.Colors.primary : StudyDesign.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(isSelected ? .white.opacity(0.22) : StudyDesign.Colors.inputHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .settingsFocusRing(isFocused: isFocused, shape: .roundedRectangle)
        .help(isSelected ? "\(mode.label)，当前外观" : "切换为\(mode.label)")
        .accessibilityLabel(mode.label)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint(isSelected ? "当前外观模式。" : "切换界面外观模式。")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsModeChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : StudyDesign.Colors.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
                .padding(.vertical, StudyDesign.Spacing.compact)
                .padding(.horizontal, StudyDesign.Spacing.compact)
                .background(
                    Capsule()
                        .fill(isSelected ? StudyDesign.Colors.primary : StudyDesign.Colors.cardBackground)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? .white.opacity(0.18) : StudyDesign.Colors.inputHairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .iOSTouchTarget()
        .settingsFocusRing(isFocused: isFocused, shape: .capsule)
        .help(isSelected ? "\(title)，已选中" : "选择\(title)")
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint("切换设置选项。")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsStepperRow: View {
    let title: String
    let subtitle: String
    let valueText: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    valueBadge
                    stepperControl
                }

                VStack(alignment: .trailing, spacing: StudyDesign.Spacing.compact) {
                    valueBadge
                    stepperControl
                }
            }
        }
        .settingsRowChrome()
    }

    private var valueBadge: some View {
        Text(valueText)
            .font(.caption.weight(.bold))
            .foregroundStyle(StudyDesign.Colors.labelPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .frame(minWidth: 86)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(StudyDesign.Colors.cardBackground, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(StudyDesign.Colors.accentHairline.opacity(0.48), lineWidth: 1)
            )
    }

    private var stepperControl: some View {
        Stepper(value: $value, in: range, step: step) {
            EmptyView()
        }
        .labelsHidden()
        .tint(tint)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    var tint: Color = StudyDesign.Colors.info
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(tint)
        .settingsRowChrome()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }
}

private struct SettingsMetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.36), lineWidth: 1)
        )
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(StudyDesign.Colors.inputBackground))
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .settingsRowChrome()
    }
}

private struct SettingsActionRowLabel: View {
    let title: String
    let icon: String
    var tint: Color = StudyDesign.Colors.info
    var emphasizesTitle: Bool = false

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.10)))
                .overlay(
                    Circle()
                        .stroke(tint.opacity(0.18), lineWidth: 1)
                )
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(emphasizesTitle ? tint : StudyDesign.Colors.labelPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
        .settingsRowChrome()
    }
}

private extension View {
    @ViewBuilder
    func settingsPlainTextInputBehavior() -> some View {
#if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#else
        self
#endif
    }

    @ViewBuilder
    func settingsURLInputBehavior() -> some View {
#if os(iOS)
        self
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#else
        self
#endif
    }

    func settingsRowChrome(isFocused: Bool = false) -> some View {
        self
            .padding(.horizontal, StudyDesign.Spacing.normal)
            .padding(.vertical, StudyDesign.Spacing.tight)
            .background(
                StudyDesign.Colors.inputBackground,
                in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(isFocused ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline, lineWidth: isFocused ? 2 : 1)
            )
            .shadow(color: isFocused ? StudyDesign.Colors.primary.opacity(0.18) : .clear, radius: 4)
    }

    @ViewBuilder
    func settingsFocusRing(isFocused: Bool, shape: SettingsFocusShape) -> some View {
        if isFocused {
            switch shape {
            case .capsule:
                self.overlay(Capsule().stroke(StudyDesign.Colors.primary, lineWidth: 2).padding(-3))
            case .roundedRectangle:
                self.overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(StudyDesign.Colors.primary, lineWidth: 2)
                        .padding(-3)
                )
            }
        } else {
            self
        }
    }
}

private enum SettingsFocusShape {
    case capsule
    case roundedRectangle
}

private struct AdvancedMaintenanceHeader: View {
    let backupCount: Int
    let diagnosticCount: Int
    let schemaVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.info)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                            .fill(StudyDesign.Colors.inputBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                            .stroke(StudyDesign.Colors.info.opacity(0.18), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("维护控制台")
                        .font(.title2.weight(.semibold))
                    Text("恢复备份、运行诊断，并管理需要谨慎处理的数据统计。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                AdvancedMaintenanceMetric(title: "备份", value: "\(backupCount)", icon: "clock.arrow.circlepath", tint: StudyDesign.Colors.secondary)
                AdvancedMaintenanceMetric(title: "诊断", value: "\(diagnosticCount)", icon: "stethoscope", tint: StudyDesign.Colors.info)
                AdvancedMaintenanceMetric(title: "版本", value: "\(schemaVersion)", icon: "number", tint: StudyDesign.Colors.labelSecondary)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.76), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

private struct AdvancedMaintenanceMetric: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                .fill(StudyDesign.Colors.inputBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.42), lineWidth: 1)
        )
    }
}

private struct AdvancedEmptyRow: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(StudyDesign.Colors.inputBackground))

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)
        }
        .settingsRowChrome()
    }
}

struct ExamGoalsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var examGoalEditor: ExamGoalEditorPresentation?

    private var activeGoals: [ExamGoal] {
        store.snapshot.activeExamGoals()
    }

    private var archivedGoals: [ExamGoal] {
        store.snapshot.examGoals
            .filter(\.isArchived)
            .sorted { $0.examDate > $1.examDate }
    }

    private var nearestActiveGoal: ExamGoal? {
        activeGoals.min { $0.daysRemaining() < $1.daysRemaining() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.relaxed) {
                ExamGoalOverviewHeader(
                    activeCount: activeGoals.count,
                    archivedCount: archivedGoals.count,
                    nearestGoal: nearestActiveGoal
                ) {
                    examGoalEditor = ExamGoalEditorPresentation(goal: nil)
                }

                if activeGoals.isEmpty {
                    ExamGoalEmptyState {
                        examGoalEditor = ExamGoalEditorPresentation(goal: nil)
                    }
                } else {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
                        HStack(alignment: .center) {
                            Text("进行中")
                                .font(.headline.weight(.semibold))
                            Spacer()
                            Button {
                                examGoalEditor = ExamGoalEditorPresentation(goal: nil)
                            } label: {
                                StudyActionPillLabel(title: "新增", systemImage: "plus")
                            }
                            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))
                            .help("新增考试目标")
                            .accessibilityLabel("新增考试目标")
                            .accessibilityHint("打开考试目标编辑器")
                        }

                        ForEach(activeGoals) { goal in
                            ExamGoalSettingsRow(goal: goal) {
                                examGoalEditor = ExamGoalEditorPresentation(goal: goal)
                            }
                        }
                    }
                }

                if !archivedGoals.isEmpty {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.standard) {
                        Text("已归档")
                            .font(.headline.weight(.semibold))
                        ForEach(archivedGoals) { goal in
                            ExamGoalSettingsRow(goal: goal) {
                                examGoalEditor = ExamGoalEditorPresentation(goal: goal)
                            }
                        }
                    }
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .studyScrollBottomComfort()
        }
        .navigationTitle("考试目标")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .sheet(item: $examGoalEditor) { presentation in
            ExamGoalEditSheet(presentation: presentation)
#if os(macOS)
                .frame(width: 520, height: 560)
#endif
        }
        .dismissKeyboardOnTapOutside()
        .scrollDismissesKeyboard(.interactively)
    }
}

struct ExamGoalEditorPresentation: Identifiable {
    let id = UUID()
    var goal: ExamGoal?
}

private struct ExamGoalOverviewHeader: View {
    let activeCount: Int
    let archivedCount: Int
    let nearestGoal: ExamGoal?
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                StudyPageHeader(
                    title: "考试目标",
                    subtitle: "用倒计时、每日可用时间和科目范围约束 AI 规划，让复习节奏更可信。",
                    icon: "flag.checkered"
                )

                Button(action: onAdd) {
                    StudyActionPillLabel(title: "新增目标", systemImage: "plus")
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact))
                .accessibilityLabel("新增考试目标")
                .accessibilityHint("打开考试目标编辑器")
            }

            HStack(spacing: StudyDesign.Spacing.tight) {
                ExamGoalHeaderMetric(title: "进行中", value: "\(activeCount)", icon: "flag.fill", tint: activeCount > 0 ? StudyDesign.Colors.warning : StudyDesign.Colors.labelSecondary)
                ExamGoalHeaderMetric(title: "最近目标", value: nearestGoal?.countdownText() ?? "未设置", icon: "calendar.badge.clock", tint: StudyDesign.Colors.secondary)
                ExamGoalHeaderMetric(title: "已归档", value: "\(archivedCount)", icon: "archivebox.fill", tint: StudyDesign.Colors.labelSecondary)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.70), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

private struct ExamGoalHeaderMetric: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                        .fill(StudyDesign.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                                .stroke(tint.opacity(0.14), lineWidth: 1)
                        )
                )

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.40), lineWidth: 1)
        )
    }
}

private struct ExamGoalEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: "flag.checkered")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                            .fill(StudyDesign.Colors.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                    .stroke(StudyDesign.Colors.warning.opacity(0.16), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text("还没有考试目标")
                        .font(.headline.weight(.semibold))
                    Text("新增后，今日页会显示倒计时，AI 规划会按剩余天数和每日可用时间分配任务。")
                        .font(.footnote)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onAdd) {
                StudyActionPillLabel(title: "新增考试目标", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary))
            .help("新增考试目标")
            .accessibilityLabel("新增考试目标")
            .accessibilityHint("打开考试目标编辑器。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.68), lineWidth: 1)
        )
    }
}

private struct ExamGoalSettingsRow: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingDeleteConfirmation = false
    let goal: ExamGoal
    let onEdit: () -> Void

    private var daysRemaining: Int {
        goal.daysRemaining()
    }

    private var goalTint: Color {
        if goal.isArchived {
            return StudyDesign.Colors.labelSecondary
        }
        if daysRemaining < 0 {
            return StudyDesign.Colors.labelSecondary
        }
        if daysRemaining <= 7 {
            return StudyDesign.Colors.danger
        }
        if daysRemaining <= 30 {
            return StudyDesign.Colors.warning
        }
        return StudyDesign.Colors.info
    }

    private var countdownValue: String {
        if goal.isArchived {
            return "归档"
        }
        if daysRemaining < 0 {
            return "\(abs(daysRemaining))"
        }
        if daysRemaining == 0 {
            return "今"
        }
        return "\(daysRemaining)"
    }

    private var countdownLabel: String {
        if goal.isArchived {
            return "已归档"
        }
        if daysRemaining < 0 {
            return "天前结束"
        }
        if daysRemaining == 0 {
            return "今天考试"
        }
        return "天后考试"
    }

    private var targetScoreText: String {
        let cleaned = goal.targetScore.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未填写" : cleaned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                countdownBadge

                VStack(alignment: .leading, spacing: 4) {
                    Label(goal.isArchived ? "目标档案" : "目标进行中", systemImage: goal.isArchived ? "archivebox.fill" : "flag.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(goalTint)
                        .lineLimit(1)
                    Text(goal.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(goal.examDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
                .layoutPriority(1)

                Spacer()

                Menu {
                    Button("编辑") {
                        onEdit()
                    }
                    Button(goal.isArchived ? "恢复进行中" : "归档") {
                        if goal.isArchived {
                            store.unarchiveExamGoal(goal)
                        } else {
                            store.archiveExamGoal(goal)
                        }
                    }
                    Button("删除", role: .destructive) {
                        isShowingDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
                .accessibilityLabel("管理考试目标 \(goal.name)")
                .accessibilityHint("打开编辑、归档和删除操作")
                .help("管理考试目标")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    ExamGoalSignalTile(title: "科目", value: goal.subjectText, icon: "books.vertical.fill", tint: StudyDesign.Colors.secondary)
                    ExamGoalSignalTile(title: "每日投入", value: goal.dailyAvailableTimeText, icon: "clock.fill", tint: StudyDesign.Colors.warning)
                    ExamGoalSignalTile(title: "目标", value: targetScoreText, icon: "target", tint: StudyDesign.Colors.success)
                }

                VStack(spacing: StudyDesign.Spacing.tight) {
                    ExamGoalSignalTile(title: "科目", value: goal.subjectText, icon: "books.vertical.fill", tint: StudyDesign.Colors.secondary)
                    ExamGoalSignalTile(title: "每日投入", value: goal.dailyAvailableTimeText, icon: "clock.fill", tint: StudyDesign.Colors.warning)
                    ExamGoalSignalTile(title: "目标", value: targetScoreText, icon: "target", tint: StudyDesign.Colors.success)
                }
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.cardBackground)
                .overlay(alignment: .topLeading) {
                    LinearGradient(
                        colors: [
                            goalTint.opacity(goal.isArchived ? 0.035 : 0.07),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: 220, height: 110)
                    .allowsHitTesting(false)
                }
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(goalTint.opacity(goal.isArchived ? 0.14 : 0.20), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro)
                .fill(goalTint.opacity(goal.isArchived ? 0.34 : 0.82))
                .frame(width: 4)
                .padding(.vertical, StudyDesign.Spacing.normal)
        }
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
        .opacity(goal.isArchived ? 0.74 : 1)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("编辑", systemImage: "pencil")
            }

            Button {
                if goal.isArchived {
                    store.unarchiveExamGoal(goal)
                } else {
                    store.archiveExamGoal(goal)
                }
            } label: {
                Label(goal.isArchived ? "恢复进行中" : "归档", systemImage: goal.isArchived ? "tray.and.arrow.up" : "archivebox")
            }

            Button(role: .destructive) {
                isShowingDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(goal.name)，\(goal.countdownText())，科目 \(goal.subjectText)")
        .alert("删除这个考试目标？", isPresented: $isShowingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                store.deleteExamGoal(goal)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除“\(goal.name)”及其考试日期、科目和目标信息。")
        }
    }

    private var countdownBadge: some View {
        VStack(spacing: 1) {
            Text(countdownValue)
                .font(.system(size: goal.isArchived ? 16 : 26, weight: .bold, design: .rounded))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.62)

            Text(countdownLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(goalTint)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .frame(minWidth: 72, minHeight: 64)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(goalTint.opacity(goal.isArchived ? 0.18 : 0.24), lineWidth: 1)
        )
    }
}

private struct ExamGoalSignalTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(StudyDesign.Colors.inputBackground))
                .overlay(Circle().stroke(tint.opacity(0.16), lineWidth: 1))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct ExamGoalEditSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let presentation: ExamGoalEditorPresentation
    private let initialName: String
    private let initialExamDate: Date
    private let initialSubjectsText: String
    private let initialDailyAvailableMinutes: Int
    private let initialTargetScore: String

    @State private var name: String
    @State private var examDate: Date
    @State private var subjectsText: String
    @State private var dailyAvailableMinutes: Int
    @State private var targetScore: String
    @State private var isShowingDiscardConfirmation = false

    init(presentation: ExamGoalEditorPresentation) {
        self.presentation = presentation
        let goal = presentation.goal
        let fallbackExamDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        let initialName = goal?.name ?? ""
        let initialExamDate = goal?.examDate ?? fallbackExamDate
        let initialSubjectsText = goal?.subjects.joined(separator: "，") ?? ""
        let initialDailyAvailableMinutes = goal?.dailyAvailableMinutes ?? 120
        let initialTargetScore = goal?.targetScore ?? ""
        self.initialName = initialName
        self.initialExamDate = initialExamDate
        self.initialSubjectsText = initialSubjectsText
        self.initialDailyAvailableMinutes = initialDailyAvailableMinutes
        self.initialTargetScore = initialTargetScore
        _name = State(initialValue: initialName)
        _examDate = State(initialValue: initialExamDate)
        _subjectsText = State(initialValue: initialSubjectsText)
        _dailyAvailableMinutes = State(initialValue: initialDailyAvailableMinutes)
        _targetScore = State(initialValue: initialTargetScore)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSubjects: [String] {
        subjectsText
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var trimmedTargetScore: String {
        targetScore.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        validationMessage == nil
    }

    private var saveHelpText: String {
        validationMessage ?? "保存考试目标"
    }

    private var validationMessage: String? {
        if trimmedName.isEmpty {
            return "考试名称不能为空"
        }
        if normalizedSubjects.isEmpty {
            return "至少填写一个考试科目"
        }
        return nil
    }

    private var hasUnsavedChanges: Bool {
        trimmedName != initialName.trimmingCharacters(in: .whitespacesAndNewlines)
            || !Calendar.current.isDate(examDate, inSameDayAs: initialExamDate)
            || normalizedSubjects != normalizedSubjects(from: initialSubjectsText)
            || dailyAvailableMinutes != initialDailyAvailableMinutes
            || trimmedTargetScore != initialTargetScore.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                    ExamGoalEditHero(
                        isNew: presentation.goal == nil,
                        countdownText: countdownText
                    )

                    SettingsPanel(
                        icon: "flag.checkered",
                        title: "目标信息",
                        subtitle: "这些信息会影响今日页倒计时和 AI 规划的任务节奏。",
                        tint: StudyDesign.Colors.warning
                    ) {
                        SettingsTextFieldRow(title: "考试名称", text: $name, prompt: "例如：考研复试", autoFocus: true)
                        ExamGoalDateRow(date: $examDate)
                        SettingsTextFieldRow(title: "科目", text: $subjectsText, prompt: "用逗号分隔，例如：英语，数学")
                        SettingsTextFieldRow(title: "目标分数", text: $targetScore, prompt: "例如：80+ / 过线 / 140 分")
                        if let validationMessage {
                            ExamGoalValidationHint(message: validationMessage)
                        }
                    }

                    SettingsPanel(
                        icon: "clock.badge.checkmark",
                        title: "每日投入",
                        subtitle: "用更真实的学习容量约束计划，避免把任务压成一团。",
                        tint: StudyDesign.Colors.secondary
                    ) {
                        ExamGoalDailyTimeRow(
                            dailyAvailableMinutes: $dailyAvailableMinutes,
                            dailyAvailableTimeText: dailyAvailableTimeText
                        )
                    }
                }
                .padding(StudyDesign.Spacing.wide)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StudyDesign.Gradients.pageBackdrop)
            .navigationTitle(presentation.goal == nil ? "新增考试目标" : "编辑考试目标")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelEditing()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.upsertExamGoal(
                            presentation.goal,
                            name: trimmedName,
                            examDate: examDate,
                            subjectsText: normalizedSubjects.joined(separator: "，"),
                            dailyAvailableMinutes: dailyAvailableMinutes,
                            targetScore: trimmedTargetScore
                        ) {
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .help(saveHelpText)
                    .accessibilityHint(saveHelpText)
                }
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .confirmationDialog("放弃未保存的修改？", isPresented: $isShowingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("当前考试目标还有未保存的修改。")
        }
    }

    private func normalizedSubjects(from value: String) -> [String] {
        value
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func cancelEditing() {
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private var countdownText: String {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: examDate)
        ).day ?? 0
        if days < 0 {
            return "已过期"
        }
        if days == 0 {
            return "今天考试"
        }
        return "倒计时 \(days) 天"
    }

    private var dailyAvailableTimeText: String {
        let hours = dailyAvailableMinutes / 60
        let minutes = dailyAvailableMinutes % 60
        if hours == 0 {
            return "\(minutes) 分钟"
        }
        if minutes == 0 {
            return "\(hours) 小时"
        }
        return "\(hours) 小时 \(minutes) 分钟"
    }
}

private struct ExamGoalValidationHint: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .stroke(StudyDesign.Colors.warning.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct ExamGoalEditHero: View {
    let isNew: Bool
    let countdownText: String

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: isNew ? "flag.badge.plus" : "flag.checkered")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                            .fill(StudyDesign.Colors.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                                    .stroke(StudyDesign.Colors.warning.opacity(0.16), lineWidth: 1)
                            )
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text(isNew ? "建立考试节奏" : "校准考试节奏")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text("把截止日期、科目和每天可用时间放进同一个目标档案里。")
                        .font(.footnote)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Text(countdownText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, StudyDesign.Spacing.compact)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(StudyDesign.Colors.inputBackground))
                    .overlay(Capsule().stroke(StudyDesign.Colors.accentHairline.opacity(0.62), lineWidth: 1))
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.62), lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

private struct ExamGoalDateRow: View {
    @Binding var date: Date

    var body: some View {
        StudyDateControl(
            title: "考试日期",
            subtitle: "用于倒计时和复习节奏推算",
            icon: "calendar.badge.clock",
            tint: StudyDesign.Colors.warning,
            date: $date,
            displayedComponents: .date
        )
    }
}

private struct ExamGoalDailyTimeRow: View {
    @Binding var dailyAvailableMinutes: Int
    let dailyAvailableTimeText: String

    private var canDecrease: Bool {
        dailyAvailableMinutes > 15
    }

    private var canIncrease: Bool {
        dailyAvailableMinutes < 720
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.micro) {
                    Text("每天可投入")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text("AI 规划会按这个容量分配每日任务量。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }

                Spacer(minLength: StudyDesign.Spacing.tight)

                Text(dailyAvailableTimeText)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(StudyDesign.Colors.secondary)
            }

            DailyCapacityRail(
                minutes: dailyAvailableMinutes,
                tint: StudyDesign.Colors.secondary
            )

            HStack {
                Button {
                    dailyAvailableMinutes = max(15, dailyAvailableMinutes - 15)
                } label: {
                    Label("减少", systemImage: "minus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.labelSecondary, prominence: .soft, size: .compact))
                .disabled(!canDecrease)
                .help(canDecrease ? "减少 15 分钟" : "已达到最小每日投入")
                .accessibilityLabel("减少每日投入时间")
                .accessibilityHint(canDecrease ? "减少 15 分钟" : "已达到最小每日投入")

                Spacer()

                Text("\(dailyAvailableMinutes / 15) 个 15 分钟块")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .monospacedDigit()

                Spacer()

                Button {
                    dailyAvailableMinutes = min(720, dailyAvailableMinutes + 15)
                } label: {
                    Label("增加", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .soft, size: .compact))
                .disabled(!canIncrease)
                .help(canIncrease ? "增加 15 分钟" : "已达到最大每日投入")
                .accessibilityLabel("增加每日投入时间")
                .accessibilityHint(canIncrease ? "增加 15 分钟" : "已达到最大每日投入")
            }
        }
        .settingsRowChrome()
        .accessibilityElement(children: .contain)
    }
}

private struct DailyCapacityRail: View {
    let minutes: Int
    let tint: Color

    private var ratio: Double {
        let clampedMinutes = Swift.min(Swift.max(minutes, 15), 720)
        return Double(clampedMinutes - 15) / Double(720 - 15)
    }

    private var filledSegments: Int {
        Int(ceil(ratio * 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            HStack(spacing: 4) {
                ForEach(1...12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                        .fill(index <= max(filledSegments, 1) ? tint : StudyDesign.Colors.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                                .stroke(StudyDesign.Colors.accentHairline.opacity(index <= max(filledSegments, 1) ? 0.0 : 0.42), lineWidth: 1)
                        )
                        .frame(height: 12)
                }
            }

            HStack {
                Text("轻量")
                Spacer()
                Text("标准")
                Spacer()
                Text("冲刺")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
        .padding(StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.42), lineWidth: 1)
        )
        .accessibilityLabel("每日投入容量 \(minutes) 分钟")
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showClearCostAlert = false
    @State private var showClearDiagnosticsAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                AdvancedMaintenanceHeader(
                    backupCount: store.availableBackups.count,
                    diagnosticCount: store.diagnosticEvents.count,
                    schemaVersion: store.snapshot.schemaVersion
                )

                backupPanel
                diagnosticsPanel
                dangerPanel
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studyScrollBottomComfort()
        }
        .background(StudyDesign.Gradients.pageBackdrop)
        .navigationTitle("高级维护")
    }

    private var backupPanel: some View {
        SettingsPanel(
            icon: "clock.arrow.circlepath",
            title: "备份恢复",
            subtitle: "自动保留最近的本地备份版本。",
            tint: StudyDesign.Colors.secondary
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                if store.availableBackups.isEmpty {
                    AdvancedEmptyRow(
                        title: "暂无自动备份",
                        subtitle: "每次保存数据时会自动生成轮转备份，最多保留 5 个版本。",
                        icon: "tray"
                    )
                } else {
                    Text("最近 \(store.availableBackups.count) 个备份版本")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)

                    ForEach(store.availableBackups) { backup in
                        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
                            Text("#\(backup.index)")
                                .font(.headline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(StudyDesign.Colors.secondary)
                                .frame(width: 40, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("自动备份")
                                    .font(.subheadline.weight(.semibold))
                                Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            }

                            Spacer(minLength: StudyDesign.Spacing.tight)

                            Button {
                                let label = backup.date.formatted(date: .abbreviated, time: .shortened)
                                store.restoreFromBackup(index: backup.index, label: label)
                            } label: {
                                StudyActionPillLabel(title: "恢复", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.secondary, prominence: .secondary, size: .compact))
                            .help("恢复备份 #\(backup.index)")
                            .accessibilityLabel("恢复备份 #\(backup.index)")
                            .accessibilityHint("用这个自动备份覆盖当前本地数据")
                        }
                        .settingsRowChrome()
                    }
                }
            }
        }
    }

    private var diagnosticsPanel: some View {
        SettingsPanel(
            icon: "stethoscope",
            title: "诊断",
            subtitle: "检查本地数据版本和最近健康记录。",
            tint: StudyDesign.Colors.info
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                SettingsInfoRow(title: "数据版本", value: "\(store.snapshot.schemaVersion)", icon: "number")

                Button {
                    store.runDataHealthCheck()
                } label: {
                    SettingsActionRowLabel(title: "运行数据体检", icon: "stethoscope")
                }
                .buttonStyle(.plain)
                .help("运行数据体检")
                .accessibilityLabel("运行数据体检")
                .accessibilityHint("检查本地数据状态并记录诊断结果")

                if store.diagnosticEvents.isEmpty {
                    AdvancedEmptyRow(title: "暂无诊断记录", subtitle: "运行体检后会在这里显示最近的诊断结果。", icon: "checkmark.seal")
                } else {
                    ForEach(Array(store.diagnosticEvents.prefix(5))) { event in
                        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                            HStack {
                                Text(event.level.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(event.level == .warning ? StudyDesign.Colors.warning : StudyDesign.Colors.info)
                                Spacer()
                                Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            }
                            Text(event.message)
                                .font(.footnote)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }
                        .settingsRowChrome()
                    }

                    Button(role: .destructive) {
                        showClearDiagnosticsAlert = true
                    } label: {
                        SettingsActionRowLabel(
                            title: "清空诊断记录",
                            icon: "trash",
                            tint: StudyDesign.Colors.danger,
                            emphasizesTitle: true
                        )
                    }
                    .buttonStyle(.plain)
                    .help("清空诊断记录")
                    .accessibilityLabel("清空诊断记录")
                    .accessibilityHint("需要确认，清空后不可撤销")
                    .alert("确认清空", isPresented: $showClearDiagnosticsAlert) {
                        Button("取消", role: .cancel) {}
                        Button("清空", role: .destructive) {
                            store.clearDiagnosticEvents()
                        }
                    } message: {
                        Text("将删除所有诊断记录，此操作不可撤销。")
                    }
                }
            }
        }
    }

    private var dangerPanel: some View {
        SettingsPanel(
            icon: "exclamationmark.triangle.fill",
            title: "危险操作",
            subtitle: "这些操作会清空统计数据，请谨慎使用。",
            tint: StudyDesign.Colors.danger
        ) {
            Button(role: .destructive) {
                showClearCostAlert = true
            } label: {
                SettingsActionRowLabel(
                    title: "清空费用统计",
                    icon: "trash",
                    tint: StudyDesign.Colors.danger,
                    emphasizesTitle: true
                )
            }
            .buttonStyle(.plain)
            .help("清空费用统计")
            .accessibilityLabel("清空费用统计")
            .accessibilityHint("需要确认，清空后不可撤销")
            .alert("确认清空", isPresented: $showClearCostAlert) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    store.resetUsageStats()
                }
            } message: {
                Text("将清零所有请求次数、Token 用量和预估费用，此操作不可撤销。")
            }
        }
    }
}
