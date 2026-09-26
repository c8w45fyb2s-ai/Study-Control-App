import Combine
import Foundation

enum StoreChangeResult: Equatable, Sendable {
    case saved
    case unchanged
    case failed(String)

    var mayCloseEditor: Bool {
        switch self {
        case .saved, .unchanged: return true
        case .failed: return false
        }
    }

    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var snapshot = StoreSnapshot()
    @Published var apiKey: String = ""
    /// Unsaved settings draft lives above SettingsView so navigating away does not
    /// discard a partially entered key. It is never written outside Keychain until save.
    @Published var settingsDraftAPIKey: String = ""
    @Published var statusMessage = "准备就绪"
    @Published var isBusy = false
    @Published var selectedDraftID: UUID?
    @Published var chatQuestion = ""
    @Published var chatAnswer = ""
    @Published var chatContexts: [RetrievedStudyContext] = []
    @Published var navigateToTab: String = ""
    @Published var navigateToSection: String = ""
    @Published var activeAIRequestTitle = ""
    @Published var checkInCelebrationTrigger = 0

    /// 运行时环境：决定存储位置与是否允许系统通知。
    ///
    /// 测试与验收通过 `STUDYCOMPANION_STORE_DIR` 或 `STUDYCOMPANION_TEST_MODE`
    /// 注入独立目录，绝不读写用户真实的 `store.json`。
    let environment: StudyRuntimeEnvironment
    private let persistence: SnapshotFileStore?
    private let underlyingAITransport: (any AIHTTPTransporting)?
    private let keychainStore: any AIKeychainStoring
    /// 存储初始化失败的原因。`nil` 表示初始化成功。
    ///
    /// 刻意不吞掉：`try?` 会让"存储不可用"退化成"静默不保存还提示成功"。
    private let persistenceInitializationError: String?
    /// 统一计划协调器（G 的集成层；算法仍由 C/D/E 模块提供）。
    private let coordinator: StudyPlanCoordinator
    /// 最近一次前台激活时看到的学习日，用于"前台跨日刷新"。
    private var lastActiveDayKey: StudyDayKey?
    private var lastKnownTimeZoneIdentifier: String
    private var lastSavedStoreURLDescription: String
    private var isHandlingForegroundActivation = false
    private var activeCredentialScope = ""

    /// 上一次成功落盘的快照。旧写入路径写盘失败时回滚到它，
    /// 避免出现"内存已改、磁盘没改、界面提示成功"的分裂状态。
    private var lastPersistedSnapshot = StoreSnapshot()
    /// 最近一次写入失败的信息，供界面显示可理解的错误并重试。
    private(set) var lastWriteFailure: WriteFailure?

    /// 一次写入失败的诊断信息。
    struct WriteFailure: Equatable, Sendable {
        var reason: String
        var path: String
        /// 存储是否还有救（初始化失败 = 需要先修目录/权限；写入失败 = 可重试）。
        var isRetryable: Bool
    }

    /// 进程内的会话心跳（每 30 秒把 `updatedAt` 推进到"此刻"，**不写盘**）。
    ///
    /// 作用：保证"前台连续学习"不会被误判成中断；而崩溃后磁盘上的
    /// `updatedAt` 仍然是旧的，于是未知离线时间会被正确识别为待确认中断。
    private var sessionHeartbeatTask: Task<Void, Never>?
    private let sessionHeartbeatIntervalSeconds: UInt64 = 30

    private var activeAIRequestTask: Task<Void, Never>?
    private let chatCompressionRecentMessageCount = 10
    private let chatCompressionMessageThreshold = 18
    private let chatCompressionCharacterThreshold = 16_000

    convenience init() {
        self.init(environment: StudyRuntimeEnvironment.resolve(), keychainStore: SystemAIKeychainStore())
    }

    convenience init(keychainStore: any AIKeychainStoring) {
        self.init(environment: StudyRuntimeEnvironment.resolve(), keychainStore: keychainStore)
    }

    convenience init(environment: StudyRuntimeEnvironment, underlyingAITransport: (any AIHTTPTransporting)? = nil) {
        self.init(environment: environment, underlyingAITransport: underlyingAITransport, keychainStore: SystemAIKeychainStore())
    }

    init(environment: StudyRuntimeEnvironment, underlyingAITransport: (any AIHTTPTransporting)? = nil, keychainStore: any AIKeychainStoring) {
        self.environment = environment
        self.underlyingAITransport = underlyingAITransport
        self.keychainStore = keychainStore
        self.coordinator = StudyPlanCoordinator(engines: StudyEngineRegistry.production())

        var store: SnapshotFileStore?
        var initializationError: String?
        do {
            store = try SnapshotFileStore(location: environment.storeLocation)
        } catch {
            initializationError = SnapshotFileStore.describe(error)
        }
        self.persistence = store
        self.persistenceInitializationError = initializationError

        self.lastKnownTimeZoneIdentifier = TimeZone.current.identifier
        self.lastSavedStoreURLDescription = environment.storeLocation.storeURL.path
        load()
        let initialConnection = AIConnectionConfiguration(settings: snapshot.settings)
        activeCredentialScope = initialConnection.credentialScope
        let canMigrateLegacyCredential = snapshot.settings.legacyCredentialMigrationPending
        apiKey = keychainStore.loadAPIKey(for: initialConnection, allowLegacyFallback: canMigrateLegacyCredential)
        settingsDraftAPIKey = apiKey
        if canMigrateLegacyCredential && keychainStore.hasScopedCredential(for: initialConnection) {
            snapshot.settings.legacyCredentialMigrationPending = false
            _ = save()
        }

        if let initializationError {
            // 存储不可用时必须让用户看到，而不是"看起来一切正常但什么都没保存"。
            self.lastWriteFailure = WriteFailure(
                reason: initializationError,
                path: environment.storeLocation.storeURL.path,
                isRetryable: false
            )
            self.statusMessage = "本地存储不可用：\(initializationError)"
        }
    }

    /// 本地存储当前是否可用。
    var isStorageAvailable: Bool { persistence != nil && persistenceInitializationError == nil }

    /// 面向界面的存储错误说明（没有错误时为 `nil`）。
    var storageErrorMessage: String? {
        guard let failure = lastWriteFailure else { return nil }
        return failure.isRetryable
            ? "保存失败：\(failure.reason)。数据未写入，可以重试。"
            : "本地存储不可用：\(failure.reason)。未写入任何数据，请检查目录权限（\(failure.path)）。"
    }

    /// 重试一次写入（用于"存储暂时不可写"之后）。
    func retryPersistence() {
        guard let failure = lastWriteFailure else {
            statusMessage = "没有需要重试的写入。"
            return
        }
        guard isStorageAvailable else {
            statusMessage = "本地存储仍不可用：\(failure.reason)。请先修复目录权限后重开应用。"
            return
        }
        if persist(snapshot, rollbackOnFailure: false) {
            statusMessage = "本地存储已恢复，数据已保存。"
            recordEvent(.info, "重试保存成功")
        }
    }

    /// 删除任务会改变绑定奖励资格；把任务删除与未使用奖励核验合并为一次本地写入。
    private func saveWithRewardReevaluation(now: Date = Date()) -> Bool {
        let context = snapshot.planningContext(now: now)
        let result = coordinator.coordinate(.refresh(dayKey: context.todayKey), state: snapshot, context: context)
        snapshot = result.snapshot
        return save()
    }

    // MARK: - 今日计划（与"待复习池"区分）

    /// 当前生效的今日计划。与 `todayTasks`（待复习池）是两份不同的数据：
    /// `todayTasks` 表示"哪些复习任务到期了"，`todayPlan` 表示"今天实际安排执行什么"。
    var todayPlan: DailyStudyPlan? {
        let context = snapshot.planningContext(now: Date())
        return StudyPlanCoordinator.activePlan(in: snapshot, dayKey: context.todayKey)
    }

    /// 学习报告按周期汇总有效完成事件，并单独保留旧版汇总记录。
    ///
    /// 与首页、今日计划、娱乐资格共用同一份完成事件（统一状态来源）。
    func activityReport(period: StudyReportPeriod, now: Date = Date()) -> StudyActivityReport {
        let days: Int
        switch period {
        case .week: days = 7
        case .month: days = 30
        }
        return StudyActivityReport.make(from: snapshot, periodDays: days, now: now)
    }

    /// 今日计划的执行项（按安排时间排序）。计划未生成时为空数组。
    var todayPlanItems: [DailyPlanItem] {
        guard let plan = todayPlan else { return [] }
        return plan.items.sorted { lhs, rhs in
            switch (lhs.scheduledStart, rhs.scheduledStart) {
            case let (left?, right?): return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.createdAt < rhs.createdAt
            }
        }
    }

    /// 今日计划中尚未完成的任务数（用于首页展示，不改变 `todayTasks` 的含义）。
    var todayPlanPendingCount: Int {
        todayPlanItems.filter { $0.status == .pending || $0.status == .inProgress }.count
    }

    /// 今日计划是否因为引擎未接入等原因不可用。
    var planEngineAvailabilityMessage: String? {
        let missing = coordinator.engines.missingModules
        guard !missing.isEmpty else { return nil }
        return "尚未接入：\(missing.joined(separator: "、"))。今日计划的生成、减量与娱乐奖励评估在接入前不可用，其余功能不受影响。"
    }

    var settings: AppSettings {
        snapshot.settings
    }

    var isAIConnectionReady: Bool {
        let configuration = AIConnectionConfiguration(settings: snapshot.settings)
        do {
            try AIConnectionConfiguration.validate(configuration, apiKey: apiKey)
            return true
        } catch {
            return false
        }
    }

    var selectedDraft: AnalysisDraft? {
        snapshot.drafts.first { $0.id == selectedDraftID } ?? snapshot.drafts.first
    }

    /// **待复习池**：今天到期（含逾期）的复习任务。
    ///
    /// 语义审查结论：这是"哪些复习任务到期了"，不是"今天实际执行什么"。
    /// 首页/内容页对它的用法（数量、列表、空状态）都是待复习池口径，因此保持不变。
    /// 今日执行计划是另一份数据，见 `todayPlan` / `todayPlanItems`。
    var todayTasks: [ReviewTask] {
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(60 * 60 * 24)
        return snapshot.reviewTasks
            .filter { $0.status == .pending && $0.dueDate < end }
            .sorted {
                if ($0.priority ?? 0) != ($1.priority ?? 0) {
                    return ($0.priority ?? 0) > ($1.priority ?? 0)
                }
                return $0.dueDate < $1.dueDate
            }
    }

    var storageStatusMessage: String {
        return "本地存储模式"
    }

    var streakDays: Int {
        calculateStreak()
    }

    var todayActivityRecord: DailyActivityRecord? {
        snapshot.dailyActivityRecords.first { $0.dateString == DailyActivityRecord.todayString() }
    }

    var todayCompletedTaskCount: Int {
        todayActivityRecord?.completedTaskCount ?? 0
    }

    var hasCheckedInToday: Bool {
        todayCompletedTaskCount > 0
    }

    var diagnosticEvents: [AppDiagnosticEvent] {
        snapshot.diagnosticEvents.sorted { $0.createdAt > $1.createdAt }
    }

    var availableBackups: [BackupInfo] {
        persistence?.availableBackups() ?? []
    }

    var onboardingCompleted: Bool {
        get { snapshot.onboardingCompleted }
        set {
            snapshot.onboardingCompleted = newValue
            save()
        }
    }

    var hasActiveAIRequest: Bool {
        activeAIRequestTask != nil
    }

    func cancelAIRequest() {
        activeAIRequestTask?.cancel()
        activeAIRequestTask = nil
        isBusy = false
        activeAIRequestTitle = ""
        statusMessage = "已取消当前 AI 请求"
    }

    func estimatedInputTokens(for text: String) -> Int {
        max(1, Int((Double(text.count) / 3.2).rounded(.up)))
    }

    func estimatedAnalysisTokenText(for documents: [StudyDocument]) -> String {
        let chunkSize = max(snapshot.settings.maxAnalysisChunkCharacters, 2_000)
        let chunkCount = documents.reduce(0) { partial, document in
            partial + max(1, Int(ceil(Double(document.content.count) / Double(chunkSize))))
        }
        return chunkCount <= documents.count ? "\(documents.count) 份资料待分析" : "\(documents.count) 份资料较长，将分段分析"
    }

    // MARK: - Editing

    func updateKnowledgePoint(_ point: KnowledgePoint, title: String, subject: String, summary: String, mastery: Double) {
        guard let index = snapshot.knowledgePoints.firstIndex(where: { $0.id == point.id }) else { return }
        snapshot.knowledgePoints[index].title = title
        snapshot.knowledgePoints[index].subject = subject
        snapshot.knowledgePoints[index].summary = summary
        snapshot.knowledgePoints[index].mastery = min(max(mastery, 0), 1)
        guard save() else { return }
        statusMessage = "知识点已更新：\(title)"
    }

    func updateMistake(_ mistake: Mistake, question: String, correctAnswer: String, errorReason: String) {
        guard let index = snapshot.mistakes.firstIndex(where: { $0.id == mistake.id }) else { return }
        snapshot.mistakes[index].question = question
        snapshot.mistakes[index].correctAnswer = correctAnswer
        snapshot.mistakes[index].errorReason = errorReason
        guard save() else { return }
        statusMessage = "错题已更新"
    }

    func updateReviewTask(_ task: ReviewTask, title: String, dueDate: Date, priority: Int?) {
        guard let index = snapshot.reviewTasks.firstIndex(where: { $0.id == task.id }) else { return }
        let oldRemindersEnabled = snapshot.reviewTasks[index].remindersEnabled
        snapshot.reviewTasks[index].title = title
        snapshot.reviewTasks[index].dueDate = dueDate
        snapshot.reviewTasks[index].priority = priority
        guard save() else { return }

        _ = oldRemindersEnabled
        requestReminderSync()
        statusMessage = "复习任务已更新：\(title)"
    }

    func updateSettings(
        baseURL: String,
        model: String,
        servicePreset: AIServicePreset,
        protocolKind: AIProtocolKind,
        authMode: AIAuthMode,
        chatTokenParameter: AIChatTokenParameter,
        anthropicOutputTokenLimit: Int?,
        temperature: Double?,
        useNativeJSONMode: Bool,
        remindersEnabled: Bool,
        defaultReminderHour: Int,
        apiKey: String,
        allowModelRequests: Bool,
        allowStructuredPlanRequests: Bool,
        includePersonalContextInAnswers: Bool,
        keepDocumentContent: Bool,
        answerMode: AIAnswerMode,
        maxAnalysisChunkCharacters: Int,
        inputTokenCostPerMillion: Double,
        outputTokenCostPerMillion: Double
    ) -> Bool {
        let oldRemindersEnabled = snapshot.settings.remindersEnabled
        var candidate = snapshot
        candidate.settings.baseURL = baseURL
        candidate.settings.model = model
        candidate.settings.servicePreset = servicePreset
        candidate.settings.protocolKind = protocolKind
        candidate.settings.authMode = authMode
        candidate.settings.legacyCredentialMigrationPending = false
        candidate.settings.chatTokenParameter = chatTokenParameter
        candidate.settings.anthropicOutputTokenLimit = anthropicOutputTokenLimit.map { min(max($0, 1), 128_000) }
        candidate.settings.temperature = temperature
        candidate.settings.useNativeJSONMode = useNativeJSONMode
        candidate.settings.remindersEnabled = remindersEnabled
        candidate.settings.defaultReminderHour = min(max(defaultReminderHour, 0), 23)
        candidate.settings.allowModelRequests = allowModelRequests
        candidate.settings.allowStructuredPlanRequests = allowStructuredPlanRequests
        candidate.settings.includePersonalContextInAnswers = includePersonalContextInAnswers
        candidate.settings.keepDocumentContent = keepDocumentContent
        candidate.settings.answerMode = answerMode
        candidate.settings.maxAnalysisChunkCharacters = min(max(maxAnalysisChunkCharacters, 2_000), 24_000)
        candidate.settings.inputTokenCostPerMillion = max(inputTokenCostPerMillion, 0)
        candidate.settings.outputTokenCostPerMillion = max(outputTokenCostPerMillion, 0)

        let connection = AIConnectionConfiguration(settings: candidate.settings)
        do {
            try AIConnectionConfiguration.validateForSaving(connection)
        } catch {
            statusMessage = "设置未保存：\(error.localizedDescription)"
            recordEvent(.error, "AI 服务设置校验失败：\(error.localizedDescription)", shouldSave: false)
            return false
        }

        // Local preferences do not need Keychain access when the connection and
        // credential are unchanged (including an unconfigured, offline install).
        var previousCredentialState: AIKeychainCredentialState?
        if connection.credentialScope != activeCredentialScope || apiKey != self.apiKey {
            do {
                previousCredentialState = try keychainStore.credentialState(for: connection)
            } catch {
                statusMessage = "无法读取当前连接的 Keychain 凭据，设置未保存：\(error.localizedDescription)"
                recordEvent(.error, "读取 AI 服务密钥失败：\(error.localizedDescription)", shouldSave: false)
                return false
            }

            do {
                try keychainStore.saveAPIKey(apiKey, for: connection)
            } catch {
                do {
                    if let previousCredentialState {
                        try keychainStore.restoreCredentialState(previousCredentialState, for: connection)
                    }
                    statusMessage = "AI 服务密钥保存失败，设置未更改：\(error.localizedDescription)"
                    recordEvent(.error, "保存 AI 服务密钥失败：\(error.localizedDescription)", shouldSave: false)
                } catch {
                    statusMessage = "AI 服务密钥保存失败，设置未更改；且旧密钥恢复失败：\(error.localizedDescription)"
                    recordEvent(.error, "保存 AI 服务密钥失败且恢复旧密钥失败：\(error.localizedDescription)", shouldSave: false)
                }
                return false
            }
        }

        // 把本次成功事件放进候选快照一起写盘。失败诊断由 persist 以 shouldSave:false
        // 记录，避免保存流程中的诊断再次隐式触发一次写盘。
        candidate.diagnosticEvents.insert(
            AppDiagnosticEvent(level: .info, message: "AI 服务设置已保存"),
            at: 0
        )
        if candidate.diagnosticEvents.count > 80 {
            candidate.diagnosticEvents = Array(candidate.diagnosticEvents.prefix(80))
        }
        let normalizedCandidate = candidate.normalizedToCurrentSchema()
        guard persist(normalizedCandidate, rollbackOnFailure: false) else {
            do {
                if let previousCredentialState {
                    try keychainStore.restoreCredentialState(previousCredentialState, for: connection)
                }
                statusMessage = "设置未保存，仍使用旧连接。\(storageErrorMessage ?? "本地存储写入失败。")"
            } catch {
                let storageFailure = storageErrorMessage ?? "本地存储写入失败。"
                statusMessage = "设置未保存，仍使用旧连接；但 Keychain 中候选密钥恢复失败：\(error.localizedDescription) 设置写盘错误：\(storageFailure)"
                recordEvent(.error, "设置写盘失败后恢复旧密钥失败：\(error.localizedDescription)", shouldSave: false)
            }
            return false
        }

        // 只有 Keychain 与快照都成功后，才一起发布新的运行时连接状态。
        snapshot = normalizedCandidate
        self.apiKey = apiKey
        settingsDraftAPIKey = apiKey
        activeCredentialScope = connection.credentialScope
        statusMessage = "设置已保存"

        if oldRemindersEnabled != remindersEnabled {
            if remindersEnabled {
                // 首次启用提醒时才请求系统权限；普通刷新不会再弹窗。
                Task {
                    let granted = await NotificationScheduler.requestAuthorizationIfNeeded()
                    if !granted {
                        statusMessage = "没有通知权限：提醒不会弹出，学习功能不受影响。"
                    }
                    await synchronizeReminders()
                }
            } else {
                requestReminderSync()
            }
        } else if remindersEnabled {
            reschedulePendingNotifications()
        }

        return true
    }

    // MARK: - 计划重新评估（自动触发）
    //
    // 需求 5：把两类事件分开，避免"刷新状态"被误当成"已经重排"。
    //
    // · 只改状态、不影响怎么排的事件：完成／撤销完成、领取／开始／结束娱乐计时。
    //   它们走 `PlanCoordinationEvent.refresh`，只重算完成与奖励资格，**不重排**。
    // · 会改变"排什么、排多少、什么时候排"的事件：
    //   新的一天、首次进入但没有有效计划、课程／课表例外增删改、作息与每日上限变更、
    //   精力调整、确认导入的新任务、导入或恢复备份。
    //   它们必须走 `regeneratePlan`（重新计算安排）。
    //
    // 重复触发是安全的：输入指纹没变时协调器会复用现有计划，不会新建版本或重复建任务。

    /// 计划重新评估的原因。
    enum PlanReevaluationReason: String, Sendable {
        case firstEntryWithoutPlan
        case newStudyDay
        case scheduleChanged
        case availabilityChanged
        case budgetChanged
        case energyChanged
        case tasksConfirmed
        case dataRestored

        var label: String {
            switch self {
            case .firstEntryWithoutPlan: return "首次进入且今天还没有计划"
            case .newStudyDay: return "进入新的学习日"
            case .scheduleChanged: return "课表变化"
            case .availabilityChanged: return "作息变化"
            case .budgetChanged: return "预算设置变化"
            case .energyChanged: return "精力调整"
            case .tasksConfirmed: return "确认了新任务"
            case .dataRestored: return "导入或恢复数据"
            }
        }
    }

    /// 请求一次计划重新评估（不阻塞调用方，用于保存类操作之后）。
    func requestPlanReevaluation(_ reason: PlanReevaluationReason, now: Date = Date()) {
        Task { await reevaluateTodayPlan(reason: reason, now: now) }
    }

    /// 用当前快照重新评估今日计划。
    ///
    /// - 引擎未接入等硬缺口：只记诊断，不打断用户当前操作；
    /// - 输入未变：沿用旧计划，不写盘、不改状态提示；
    /// - 有变化：走统一提交（先落盘、再通知），保存失败时界面不会提示成功。
    @discardableResult
    func reevaluateTodayPlan(
        reason: PlanReevaluationReason,
        now: Date = Date(),
        announcesResult: Bool = false
    ) async -> PlanCoordinationResult? {
        guard !isBusy else { return nil }
        let context = snapshot.planningContext(now: now)
        let result = coordinator.coordinate(
            .regeneratePlan(dayKey: context.todayKey, force: false),
            state: snapshot,
            context: context
        )

        if let rejection = result.rejection {
            recordEvent(.warning, "自动重新规划未执行（\(reason.label)）：\(rejection.message)", shouldSave: false)
            if announcesResult { statusMessage = rejection.message }
            return result
        }

        guard result.didChange else {
            if announcesResult { statusMessage = result.statusMessage }
            return result
        }

        let saved = await commit(
            result.snapshot,
            status: result.statusMessage,
            reminderChanges: result.reminderChanges,
            now: now
        )
        if saved {
            recordEvent(.info, "已按\(reason.label)重新规划今日计划")
        }
        return result
    }

    /// 今天是否已经有生效的计划。
    var hasActivePlanToday: Bool {
        let context = snapshot.planningContext(now: Date())
        return StudyPlanCoordinator.activePlan(in: snapshot, dayKey: context.todayKey) != nil
    }

    // MARK: - 课表 / 作息 / 娱乐规则（B、E 模块视图的回调入口）
    //
    // 视图只提交"新值"，由这里统一执行
    // 「基于当前快照计算 → 保存完整快照 → 保存成功后才确认成功」的顺序。

    /// 统一的"值写入"通道。
    ///
    /// `transform` 返回要展示的细节；返回 `nil` 表示没有变化（不写盘）。
    ///
    /// `reevaluatesPlan = true` 表示这次写入会改变"今天排什么"（课程、作息、预算、精力），
    /// 保存成功后自动重新评估今日计划；没有变化时不会新建版本。
    @discardableResult
    func applyStoreChange(
        statusPrefix: String,
        reevaluatesPlan: Bool = false,
        reevaluatesRewards: Bool = false,
        reevaluationReason: PlanReevaluationReason = .scheduleChanged,
        now: Date = Date(),
        _ transform: (inout StoreSnapshot, Date) -> String?
    ) -> StoreChangeResult {
        var candidate = snapshot
        guard let detail = transform(&candidate, now) else {
            statusMessage = "没有需要保存的变化。"
            return .unchanged
        }
        let summary = detail.isEmpty ? statusPrefix : "\(statusPrefix)：\(detail)"
        if reevaluatesRewards {
            let context = candidate.planningContext(now: now)
            candidate = coordinator.coordinate(
                .refresh(dayKey: context.todayKey),
                state: candidate,
                context: context
            ).snapshot
        }
        let saved = persistAndPublish(candidate, status: summary)
        if saved {
            if reevaluatesPlan {
                requestPlanReevaluation(reevaluationReason, now: now)
            }
            // 规则和绑定任务的提交在同一份候选快照里完成资格核验。
            if !reevaluatesRewards { requestRewardReevaluation(now: now) }
            return .saved
        }
        return .failed(lastWriteFailure?.reason ?? "保存失败，请修复本地存储后重试。")
    }

    @discardableResult
    func saveSemester(_ semester: ScheduleSemester, now: Date = Date()) -> StoreChangeResult {
        applyStoreChange(statusPrefix: "学期已保存", reevaluatesPlan: true, reevaluationReason: .scheduleChanged, now: now) { snapshot, now in
            guard snapshot.scheduleSemester != semester else { return nil }
            snapshot.scheduleSemester = semester
            if snapshot.semesterIdentity.createdAt == StudyTimestamp.unspecified {
                snapshot.semesterIdentity.createdAt = now
            }
            return "\(semester.weekCount) 周"
        }
    }

    @discardableResult
    func saveCourse(_ course: Course, now: Date = Date()) -> StoreChangeResult {
        applyStoreChange(statusPrefix: "课程已保存", reevaluatesPlan: true, reevaluationReason: .scheduleChanged, now: now) { snapshot, _ in
            if let index = snapshot.scheduleCourses.firstIndex(where: { $0.id == course.id }) {
                guard snapshot.scheduleCourses[index] != course else { return nil }
                snapshot.scheduleCourses[index] = course
            } else {
                snapshot.scheduleCourses.append(course)
            }
            snapshot.scheduleCourses.sort { $0.name < $1.name }
            return course.name
        }
    }

    @discardableResult
    func deleteCourse(id: UUID, now: Date = Date()) -> StoreChangeResult {
        applyStoreChange(statusPrefix: "课程已删除", reevaluatesPlan: true, reevaluationReason: .scheduleChanged, now: now) { snapshot, _ in
            guard let index = snapshot.scheduleCourses.firstIndex(where: { $0.id == id }) else { return nil }
            let name = snapshot.scheduleCourses[index].name
            snapshot.scheduleCourses.remove(at: index)
            // 关联的排课例外一并清理，避免留下指向已删课程的孤儿例外。
            snapshot.scheduleExceptions.removeAll { $0.courseID == id }
            snapshot.courseBurdenLevels.removeAll { $0.courseID == id }
            return name
        }
    }

    @discardableResult
    func saveScheduleException(_ exception: ScheduleException, now: Date = Date()) -> StoreChangeResult {
        saveScheduleExceptions([exception], now: now)
    }

    /// 原子保存一组课表例外，用于一次调课产生停课 + 补课等多条记录的业务操作。
    @discardableResult
    func saveScheduleExceptions(_ exceptions: [ScheduleException], now: Date = Date()) -> StoreChangeResult {
        guard !exceptions.isEmpty else { return .unchanged }
        return applyStoreChange(statusPrefix: "课表例外已保存", reevaluatesPlan: true, reevaluationReason: .scheduleChanged, now: now) { snapshot, _ in
            var changed = false
            for exception in exceptions {
                if let index = snapshot.scheduleExceptions.firstIndex(where: { $0.id == exception.id }) {
                    guard snapshot.scheduleExceptions[index] != exception else { continue }
                    snapshot.scheduleExceptions[index] = exception
                } else {
                    snapshot.scheduleExceptions.append(exception)
                }
                changed = true
            }
            guard changed else { return nil }
            snapshot.scheduleExceptions.sort { $0.date < $1.date }
            return exceptions.map(\.summaryLine).joined(separator: "、")
        }
    }

    @discardableResult
    func deleteScheduleException(id: UUID, now: Date = Date()) -> StoreChangeResult {
        applyStoreChange(statusPrefix: "课表例外已删除", reevaluatesPlan: true, reevaluationReason: .scheduleChanged, now: now) { snapshot, _ in
            guard snapshot.scheduleExceptions.contains(where: { $0.id == id }) else { return nil }
            snapshot.scheduleExceptions.removeAll { $0.id == id }
            return ""
        }
    }

    func saveCourseBurden(_ level: CourseBurdenLevel, courseID: UUID, now: Date = Date()) {
        applyStoreChange(statusPrefix: "课程负担等级已保存", reevaluatesPlan: true, reevaluationReason: .scheduleChanged, now: now) { snapshot, now in
            let updated = snapshot.settingCourseBurdenLevel(level, forCourseID: courseID, at: now)
            guard updated.courseBurdenLevels != snapshot.courseBurdenLevels else { return nil }
            snapshot = updated
            return level.label
        }
    }

    /// 保存作息（学习窗口、睡眠、固定占用、缓冲）。
    @discardableResult
    func saveAvailabilitySettings(_ settings: AvailabilitySettings, now: Date = Date()) -> StoreChangeResult {
        applyStoreChange(statusPrefix: "作息已保存", reevaluatesPlan: true, reevaluationReason: .availabilityChanged, now: now) { snapshot, _ in
            guard snapshot.availabilitySettings != settings else { return nil }
            snapshot.availabilitySettings = settings
            return "已更新学习窗口与睡眠时段"
        }
    }

    /// 保存计划偏好（每日上限、自动减量、规划时区）。
    func savePlanningPreferences(_ preferences: PlanningPreferences, now: Date = Date()) {
        applyStoreChange(statusPrefix: "计划偏好已保存", reevaluatesPlan: true, reevaluationReason: .budgetChanged, now: now) { snapshot, _ in
            guard snapshot.planningPreferences != preferences else { return nil }
            snapshot.planningPreferences = preferences
            return "每日上限 \(preferences.dailyCapMinutes.map { "\($0) 分钟" } ?? "不限")，自动减量\(preferences.autoReduceEnabled ? "已开启" : "已关闭")"
        }
    }

    /// 当前精力档位。`nil` 表示没有手动设置，规划时按课表负担自动估计。
    var todayEnergyLevel: StudyEnergyLevel? {
        snapshot.planningPreferences.energyLevelIdentifier.flatMap(StudyEnergyLevel.init(rawValue:))
    }

    /// 手动设置精力档位（`nil` = 恢复为按课表估计）。
    ///
    /// 会触发计划重新评估：精力变化直接改变今天的预算。
    func setEnergyLevel(_ level: StudyEnergyLevel?, now: Date = Date()) {
        var preferences = snapshot.planningPreferences
        let normalized = PlanningPreferences.normalizedEnergyIdentifier(level?.rawValue)
        guard normalized != preferences.energyLevelIdentifier else { return }
        preferences.energyLevelIdentifier = normalized
        applyStoreChange(
            statusPrefix: "精力已更新",
            reevaluatesPlan: true,
            reevaluationReason: .energyChanged,
            now: now
        ) { snapshot, _ in
            snapshot.planningPreferences = preferences
            return level?.label ?? "按课表自动估计"
        }
    }

    @discardableResult
    func savePeriodTemplates(_ templates: [PeriodTemplate], now: Date = Date()) -> StoreChangeResult {
        applyStoreChange(statusPrefix: "节次模板已保存", reevaluatesPlan: true, reevaluationReason: .scheduleChanged, now: now) { snapshot, _ in
            guard snapshot.schedulePeriodTemplates != templates else { return nil }
            snapshot.schedulePeriodTemplates = templates.sorted { $0.start.minutes < $1.start.minutes }
            return "\(templates.count) 个节次"
        }
    }

    /// 作息设置页的单一保存动作：作息与节次模板要么一起落盘，要么都不发布。
    @discardableResult
    func saveAvailabilityAndPeriodTemplates(
        settings: AvailabilitySettings,
        templates: [PeriodTemplate],
        now: Date = Date()
    ) -> StoreChangeResult {
        let sortedTemplates = templates.sorted { $0.start.minutes < $1.start.minutes }
        return applyStoreChange(
            statusPrefix: "作息与节次模板已保存",
            reevaluatesPlan: true,
            reevaluationReason: .availabilityChanged,
            now: now
        ) { snapshot, _ in
            guard snapshot.availabilitySettings != settings || snapshot.schedulePeriodTemplates != sortedTemplates else { return nil }
            snapshot.availabilitySettings = settings
            snapshot.schedulePeriodTemplates = sortedTemplates
            return "已更新学习窗口、睡眠时段与节次模板"
        }
    }

    /// 新增或更新手动学习任务；先保存任务，再重新评估今日计划与奖励。
    @discardableResult
    func saveManualStudyTask(_ task: ManualStudyTask, now: Date = Date()) -> StoreChangeResult {
        guard ManualStudyTask.estimatedMinutesRange.contains(task.estimatedMinutes) else {
            return .failed("预计分钟必须在 \(ManualStudyTask.estimatedMinutesRange.lowerBound)–\(ManualStudyTask.estimatedMinutesRange.upperBound) 之间。")
        }
        let normalized = ManualStudyTask(
            id: task.id,
            title: task.title,
            note: task.note,
            dueDate: task.dueDate,
            estimatedMinutes: task.estimatedMinutes,
            createdAt: task.createdAt
        )
        guard !normalized.title.isEmpty else { return .failed("请输入任务名称。") }
        return applyStoreChange(
            statusPrefix: "手动任务已保存",
            reevaluatesPlan: true,
            reevaluatesRewards: true,
            reevaluationReason: .tasksConfirmed,
            now: now
        ) { snapshot, _ in
            if let index = snapshot.manualStudyTasks.firstIndex(where: { $0.id == normalized.id }) {
                guard snapshot.manualStudyTasks[index] != normalized else { return nil }
                snapshot.manualStudyTasks[index] = normalized
            } else {
                snapshot.manualStudyTasks.append(normalized)
            }
            // 手动任务由容量引擎安排，不作为固定项绕过每日预算。
            // 旧版本中固定的待办项也在编辑时解除固定，确保新字段重新参与排期。
            for planIndex in snapshot.dailyPlans.indices where snapshot.dailyPlans[planIndex].isActive {
                for itemIndex in snapshot.dailyPlans[planIndex].items.indices {
                    let item = snapshot.dailyPlans[planIndex].items[itemIndex]
                    if item.source.manualTaskID == normalized.id && item.status == .pending {
                        snapshot.dailyPlans[planIndex].items[itemIndex].isPinned = false
                    }
                }
            }
            snapshot.manualStudyTasks.sort(by: ManualStudyTask.precedesInCandidateOrder)
            return normalized.title
        }
    }

    /// 删除手动任务定义；既有完成事件与计划审计历史继续保留。
    @discardableResult
    func deleteManualStudyTask(id: UUID, now: Date = Date()) -> StoreChangeResult {
        applyStoreChange(
            statusPrefix: "手动任务已删除",
            reevaluatesPlan: true,
            reevaluatesRewards: true,
            reevaluationReason: .tasksConfirmed,
            now: now
        ) { snapshot, _ in
            guard let task = snapshot.manualStudyTasks.first(where: { $0.id == id }) else { return nil }
            snapshot.manualStudyTasks.removeAll { $0.id == id }
            for planIndex in snapshot.dailyPlans.indices where snapshot.dailyPlans[planIndex].isActive {
                for itemIndex in snapshot.dailyPlans[planIndex].items.indices {
                    let item = snapshot.dailyPlans[planIndex].items[itemIndex]
                    if item.source.manualTaskID == id && item.status == .pending {
                        snapshot.dailyPlans[planIndex].items[itemIndex].isPinned = false
                    }
                }
            }
            return task.title
        }
    }

    /// 保存娱乐规则。编辑已有规则会生成新版本，历史奖励仍绑定当时的规则版本。
    ///
    /// E 模块补充的可选参数（生效区间 / 每周重复 / 指定实例绑定 / 启用状态）都有默认值，
    /// 旧调用点行为不变。只有"规则内容"变化才会生成新版本：单纯启用/停用只改状态，
    /// 避免"关掉再打开就多领一次奖励"。
    @discardableResult
    func saveEntertainmentRule(
        name: String,
        condition: EntertainmentUnlockCondition,
        fallback: EntertainmentFallbackMode,
        rewardMinutes: Int,
        ruleID: UUID? = nil,
        effectiveFrom: StudyDayKey? = nil,
        effectiveUntil: StudyDayKey? = nil,
        repeatWeekdays: [Int]? = nil,
        targets: [EntertainmentTargetBinding]? = nil,
        isEnabled: Bool = true,
        now: Date = Date()
    ) -> StoreChangeResult {
        return applyStoreChange(statusPrefix: "娱乐规则已保存", reevaluatesRewards: true, now: now) { snapshot, now in
            if let ruleID, let index = snapshot.entertainmentRules.firstIndex(where: { $0.id == ruleID }) {
                let existing = snapshot.entertainmentRules[index]
                let normalizedTargets = (targets?.isEmpty ?? true) ? nil : targets
                let normalizedWeekdays = (repeatWeekdays?.isEmpty ?? true) ? nil : repeatWeekdays?.sorted()
                let contentChanged = existing.name != name
                    || existing.effectiveFrom != effectiveFrom
                    || existing.effectiveUntil != effectiveUntil
                    || existing.condition != condition
                    || existing.targets != normalizedTargets
                    || existing.repeatWeekdays != normalizedWeekdays
                    || existing.fallback != fallback
                    || existing.rewardMinutes != max(0, rewardMinutes)

                if contentChanged {
                    let revised = existing.revised(
                        name: name,
                        effectiveFrom: .some(effectiveFrom),
                        effectiveUntil: .some(effectiveUntil),
                        condition: condition,
                        targets: .some(normalizedTargets),
                        repeatWeekdays: .some(normalizedWeekdays),
                        fallback: fallback,
                        rewardMinutes: rewardMinutes,
                        isEnabled: isEnabled,
                        at: now
                    )
                    snapshot.entertainmentRules[index] = revised
                    return "\(revised.name)（第 \(revised.ruleVersion) 版）"
                }

                // 只有启用状态变化：不生成新版本，历史奖励与发放键都不受影响。
                guard existing.isEnabled != isEnabled else { return nil }
                var toggled = existing
                toggled.isEnabled = isEnabled
                toggled.updatedAt = now
                snapshot.entertainmentRules[index] = toggled
                return "\(toggled.name)\(isEnabled ? "已启用" : "已停用")"
            }
            let rule = EntertainmentRule(
                name: name,
                effectiveFrom: effectiveFrom,
                effectiveUntil: effectiveUntil,
                condition: condition,
                targets: targets,
                repeatWeekdays: repeatWeekdays,
                fallback: fallback,
                rewardMinutes: rewardMinutes,
                isEnabled: isEnabled,
                createdAt: now,
                updatedAt: now
            )
            snapshot.entertainmentRules.append(rule)
            return rule.name
        }
    }

    /// 启用 / 停用娱乐规则。不产生新版本（内容没变，不该重新发放奖励）。
    func setEntertainmentRuleEnabled(id: UUID, isEnabled: Bool, now: Date = Date()) {
        applyStoreChange(statusPrefix: "娱乐规则状态已更新", reevaluatesRewards: true, now: now) { snapshot, now in
            guard let index = snapshot.entertainmentRules.firstIndex(where: { $0.id == id }) else { return nil }
            guard snapshot.entertainmentRules[index].isEnabled != isEnabled else { return nil }
            snapshot.entertainmentRules[index].isEnabled = isEnabled
            snapshot.entertainmentRules[index].updatedAt = now
            let name = snapshot.entertainmentRules[index].name
            return "\(name)\(isEnabled ? "已启用" : "已停用")"
        }
    }

    func deleteEntertainmentRule(id: UUID, now: Date = Date()) {
        applyStoreChange(statusPrefix: "娱乐规则已删除", reevaluatesRewards: true, now: now) { snapshot, _ in
            guard snapshot.entertainmentRules.contains(where: { $0.id == id }) else { return nil }
            snapshot.entertainmentRules.removeAll { $0.id == id }
            return ""
        }
    }

    /// 把过去学习日里没用完的奖励标记为已过期：默认当天使用，不无限累积。
    ///
    /// 已开始 / 已使用的奖励不动（保留历史，不伪造倒退）。
    func expireStaleRewardGrants(now: Date = Date()) {
        requestRewardReevaluation(now: now)
    }

    // MARK: - 娱乐领取 / 计时

    @discardableResult
    func claimReward(grantID: UUID, now: Date = Date()) async -> PlanActionOutcome {
        await performPlanAction(.claimReward(grantID: grantID), now: now)
    }

    @discardableResult
    func startReward(grantID: UUID, now: Date = Date()) async -> PlanActionOutcome {
        await performPlanAction(.startReward(grantID: grantID), now: now)
    }

    @discardableResult
    func finishReward(grantID: UUID, usedMinutes: Int, now: Date = Date()) async -> PlanActionOutcome {
        // 取消提醒由协调器产出意图、统一入口执行（不再直接操作通知中心），
        // 这样测试模式下不会有任何真实通知副作用。
        await performPlanAction(.finishReward(grantID: grantID, usedMinutes: usedMinutes), now: now)
    }

    /// 应用 E 模块计时引擎返回的意图：落盘走统一提交，通知由这里发出。
    ///
    /// 算法只产出意图，界面只调用这一个入口；没有通知权限时通知会自动失败，
    /// 页面内计时（剩余时长由时间戳推导）不受影响。
    @discardableResult
    func applyEntertainmentIntents(_ intents: [EntertainmentSessionIntent], now: Date = Date()) async -> PlanActionOutcome? {
        var last: PlanActionOutcome?
        for intent in intents {
            switch intent {
            case .requestClaim(let grantID):
                last = await claimReward(grantID: grantID, now: now)
            case .requestStart(let grantID):
                last = await startReward(grantID: grantID, now: now)
            case .requestFinish(let grantID, let usedMinutes):
                last = await finishReward(grantID: grantID, usedMinutes: usedMinutes, now: now)
            case .scheduleEndNotification(let grantID, let fireDate, let title):
                await NotificationScheduler.scheduleEntertainmentEnd(
                    grantID: grantID,
                    title: title,
                    fireDate: fireDate,
                    environment: environment,
                    now: now
                )
            case .cancelEndNotification(let grantID, let title):
                // 统一身份：排程与取消都用「类型 + grantID」，不再有标题哈希这一套。
                _ = title
                await NotificationScheduler.apply(
                    [
                        ReminderChangeRequest(
                            action: .cancel,
                            planItemID: nil,
                            fireDate: nil,
                            title: "",
                            kind: .entertainmentEnd,
                            businessID: grantID.uuidString
                        )
                    ],
                    environment: environment,
                    now: now
                )
            }
        }
        return last
    }

    /// 今日可领取 / 进行中的娱乐奖励。
    var todayRewardGrants: [RewardGrant] {
        let context = snapshot.planningContext(now: Date())
        return snapshot.rewardGrants(on: context.todayKey).sorted { $0.grantedAt < $1.grantedAt }
    }

    func updateAppearanceMode(_ appearanceMode: AppAppearanceMode) {
        guard snapshot.settings.appearanceMode != appearanceMode else { return }
        snapshot.settings.appearanceMode = appearanceMode
        guard save() else { return }
        statusMessage = "界面外观已切换为\(appearanceMode.label)"
    }

    func updatePersonalContextInAnswers(_ enabled: Bool) {
        guard snapshot.settings.includePersonalContextInAnswers != enabled else { return }
        snapshot.settings.includePersonalContextInAnswers = enabled
        guard save() else { return }
        statusMessage = enabled ? "答疑将引用个人资料" : "答疑已切换为通用回答"
    }

    @discardableResult
    func upsertExamGoal(
        _ goal: ExamGoal? = nil,
        name: String,
        examDate: Date,
        subjectsText: String,
        dailyAvailableMinutes: Int,
        targetScore: String
    ) -> Bool {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subjects = subjectsText
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanedTargetScore = targetScore.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedName.isEmpty else {
            statusMessage = "考试名称不能为空"
            return false
        }

        guard !subjects.isEmpty else {
            statusMessage = "至少填写一个考试科目"
            return false
        }

        let normalizedMinutes = min(max(dailyAvailableMinutes, 15), 720)
        let updated = ExamGoal(
            id: goal?.id ?? UUID(),
            name: cleanedName,
            examDate: examDate,
            subjects: subjects,
            dailyAvailableMinutes: normalizedMinutes,
            targetScore: cleanedTargetScore,
            createdAt: goal?.createdAt ?? Date(),
            isArchived: goal?.isArchived ?? false
        )

        if let goal,
           let index = snapshot.examGoals.firstIndex(where: { $0.id == goal.id }) {
            snapshot.examGoals[index] = updated
            statusMessage = "考试目标已更新：\(updated.name)"
            recordEvent(.info, "考试目标已更新：\(updated.promptSummary())", shouldSave: false)
        } else {
            snapshot.examGoals.insert(updated, at: 0)
            statusMessage = "考试目标已新增：\(updated.name)"
            recordEvent(.info, "考试目标已新增：\(updated.promptSummary())", shouldSave: false)
        }

        // 写盘失败时内存已回滚：不能返回 true，否则界面会以为已经保存。
        guard save() else { return false }
        return true
    }

    func archiveExamGoal(_ goal: ExamGoal) {
        guard let index = snapshot.examGoals.firstIndex(where: { $0.id == goal.id }) else { return }
        snapshot.examGoals[index].isArchived = true
        guard save() else { return }
        statusMessage = "已归档考试目标：\(goal.name)"
        recordEvent(.info, "归档考试目标：\(goal.name)")
    }

    func unarchiveExamGoal(_ goal: ExamGoal) {
        guard let index = snapshot.examGoals.firstIndex(where: { $0.id == goal.id }) else { return }
        snapshot.examGoals[index].isArchived = false
        guard save() else { return }
        statusMessage = "已恢复考试目标：\(goal.name)"
        recordEvent(.info, "恢复考试目标：\(goal.name)")
    }

    func deleteExamGoal(_ goal: ExamGoal) {
        snapshot.examGoals.removeAll { $0.id == goal.id }
        guard save() else { return }
        statusMessage = "已删除考试目标：\(goal.name)"
        recordEvent(.info, "删除考试目标：\(goal.name)")
    }

    func importAndAnalyze(url: URL, kind: DocumentKind) {
        startAIRequest("正在导入并分析...") {
            await self.runBusy("正在导入并分析...") { [self] in
                let isAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if isAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let content = try await DocumentProcessor.readContent(from: url)
                let document = StudyDocument(
                    title: url.deletingPathExtension().lastPathComponent,
                    sourceName: url.lastPathComponent,
                    kind: kind,
                    content: snapshot.settings.keepDocumentContent ? content : "已根据隐私设置不保存导入原文。"
                )
                snapshot.documents.insert(document, at: 0)
                save()

                try await analyzeAndStoreDraft(for: document, content: content, kind: kind)
            }
        }
    }

    @discardableResult
    func addManualDocument(title: String, content: String, kind: DocumentKind) -> StudyDocument? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let storedContent = snapshot.settings.keepDocumentContent ? content : "已根据隐私设置不保存手动输入原文。"
        let document = StudyDocument(title: title, sourceName: "手动输入", kind: kind, content: storedContent)
        snapshot.documents.insert(document, at: 0)
        guard save() else { return nil }
        statusMessage = "资料已保存"
        return document
    }

    func analyzeDocument(_ document: StudyDocument) {
        startAIRequest("正在分析...") {
            await self.runBusy("正在分析...") { [self] in
                try await analyzeAndStoreDraft(for: document, content: document.content, kind: document.kind)
            }
        }
    }

    func analyzeDocuments(_ documents: [StudyDocument]) {
        let documents = documents.filter { document in
            snapshot.documents.contains { $0.id == document.id }
        }
        guard !documents.isEmpty else {
            statusMessage = "请先选择要分析的资料"
            return
        }

        startAIRequest("正在分析 \(documents.count) 份资料...") {
            await self.runBusy("正在分析 \(documents.count) 份资料...") { [self] in
                guard snapshot.settings.allowModelRequests else {
                    statusMessage = "已关闭 AI 请求：请在隐私设置中开启后再分析"
                    return
                }
                guard isAIConnectionReady else {
                    statusMessage = "当前 AI 服务尚未就绪：请在设置中补全连接配置后再分析。"
                    return
                }

                for (index, document) in documents.enumerated() {
                    statusMessage = "正在分析 \(index + 1)/\(documents.count)：\(document.title)"
                    try await analyzeAndStoreDraft(for: document, content: document.content, kind: document.kind)
                }

                statusMessage = "已完成 \(documents.count) 份资料分析，等待你确认"
            }
        }
    }

    @discardableResult
    func confirmDraft(_ draft: AnalysisDraft) -> DraftConfirmationResult {
        var titleToID: [String: UUID] = Dictionary(uniqueKeysWithValues: snapshot.knowledgePoints.map { ($0.title, $0.id) })
        var createdKnowledgePointIDs: [UUID] = []

        for item in draft.knowledgePoints {
            if let existingID = titleToID[item.title],
               let index = snapshot.knowledgePoints.firstIndex(where: { $0.id == existingID }) {
                snapshot.knowledgePoints[index].summary = item.summary
                snapshot.knowledgePoints[index].mastery = min(snapshot.knowledgePoints[index].mastery, item.mastery)
            } else {
                let point = KnowledgePoint(title: item.title, subject: item.subject, summary: item.summary, mastery: item.mastery)
                snapshot.knowledgePoints.insert(point, at: 0)
                titleToID[item.title] = point.id
                createdKnowledgePointIDs.append(point.id)
            }
        }

        var mistakeIDsByDraftID: [UUID: UUID] = [:]
        let mistakes = draft.mistakes.map { item in
            let id = UUID()
            mistakeIDsByDraftID[item.id] = id
            return Mistake(
                id: id,
                question: item.question,
                correctAnswer: item.correctAnswer,
                errorReason: item.errorReason,
                sourceDocumentID: draft.sourceDocumentID,
                knowledgePointIDs: item.relatedKnowledgeTitles.compactMap { titleToID[$0] }
            )
        }
        snapshot.mistakes.insert(contentsOf: mistakes, at: 0)

        let tasks = ReviewPlanner.makeTasks(for: draft, titleToID: titleToID, mistakeIDsByDraftID: mistakeIDsByDraftID)
        snapshot.reviewTasks.insert(contentsOf: tasks, at: 0)
        snapshot.drafts.removeAll { $0.id == draft.id }
        selectedDraftID = snapshot.drafts.first?.id
        // 保存失败时草稿不会被消耗，返回空结果让界面保持可重试状态。
        guard save() else {
            return DraftConfirmationResult(
                createdKnowledgePointIDs: [],
                createdMistakeIDs: [],
                createdReviewTaskIDs: []
            )
        }

        requestReminderSync()

        statusMessage = "已确认：新增 \(createdKnowledgePointIDs.count) 个知识点、\(mistakes.count) 道错题、\(tasks.count) 个复习任务" + budgetCheckSuffix()

        // 新任务会改变"今天排什么"：确认后立即重新评估，未开始的部分自动纳入安排。
        if !tasks.isEmpty {
            requestPlanReevaluation(.tasksConfirmed)
        }

        return DraftConfirmationResult(
            createdKnowledgePointIDs: createdKnowledgePointIDs,
            createdMistakeIDs: mistakes.map(\.id),
            createdReviewTaskIDs: tasks.map(\.id)
        )
    }

    func deleteDraft(_ draft: AnalysisDraft) {
        snapshot.drafts.removeAll { $0.id == draft.id }
        selectedDraftID = snapshot.drafts.first?.id
        guard save() else { return }
        statusMessage = "草稿已删除"
    }

    func deleteDocument(_ document: StudyDocument) {
        let linkedMistakeIDs = Set(snapshot.mistakes
            .filter { $0.sourceDocumentID == document.id }
            .map(\.id))

        snapshot.documents.removeAll { $0.id == document.id }
        snapshot.drafts.removeAll { $0.sourceDocumentID == document.id }
        snapshot.mistakes.removeAll { $0.sourceDocumentID == document.id }
        snapshot.reviewTasks.removeAll { task in
            if let mistakeID = task.mistakeID, linkedMistakeIDs.contains(mistakeID) {
                return true
            }
            return false
        }

        if let selectedDraftID, !snapshot.drafts.contains(where: { $0.id == selectedDraftID }) {
            self.selectedDraftID = snapshot.drafts.first?.id
        }

        guard saveWithRewardReevaluation() else { return }
        requestReminderSync()
        statusMessage = "已删除资料：\(document.title)"
        recordEvent(.info, "删除资料：\(document.title)")
        // 删除任务会改变娱乐解锁条件；状态与资格核验在同一次本地提交中保存。
    }

    func deleteKnowledgePoint(_ point: KnowledgePoint) {
        snapshot.knowledgePoints.removeAll { $0.id == point.id }
        for index in snapshot.mistakes.indices {
            snapshot.mistakes[index].knowledgePointIDs.removeAll { $0 == point.id }
        }
        snapshot.reviewTasks.removeAll { $0.knowledgePointID == point.id }

        guard saveWithRewardReevaluation() else { return }
        requestReminderSync()
        statusMessage = "已删除知识点：\(point.title)"
        recordEvent(.info, "删除知识点：\(point.title)")
        // 删除任务会改变娱乐解锁条件；状态与资格核验在同一次本地提交中保存。
    }

    func deleteMistake(_ mistake: Mistake) {
        let linkedTaskIDs = linkedReviewTaskIDs(for: mistake)

        snapshot.mistakes.removeAll { $0.id == mistake.id }
        snapshot.reviewTasks.removeAll { linkedTaskIDs.contains($0.id) }

        guard saveWithRewardReevaluation() else { return }
        requestReminderSync()
        statusMessage = "已删除错题：\(ReviewPlanner.shortTitle(mistake.question))"
        recordEvent(.info, "删除错题：\(ReviewPlanner.shortTitle(mistake.question))")
        // 删除任务会改变娱乐解锁条件；状态与资格核验在同一次本地提交中保存。
    }

    func deleteReviewTask(_ task: ReviewTask) {
        snapshot.reviewTasks.removeAll { $0.id == task.id }
        guard saveWithRewardReevaluation() else { return }
        requestReminderSync()
        statusMessage = "已删除复习任务：\(task.title)"
        recordEvent(.info, "删除复习任务：\(task.title)")
        // 解锁条件依赖具体任务时必须重新评估，并与删除操作原子提交。
    }

    @discardableResult
    func refreshIterativeAIPlans(now: Date = Date(), updateStatus: Bool = true) -> Int {
        var updatedSnapshot = snapshot
        let results = AIPlanIterationEngine.refresh(snapshot: &updatedSnapshot, now: now)
        guard !results.isEmpty else { return 0 }

        // AI 迭代不得覆盖正在进行、已完成与用户固定的任务。
        updatedSnapshot = restoringProtectedPlanItems(in: updatedSnapshot)

        snapshot = updatedSnapshot
        guard save() else { return 0 }

        let adjustedTaskIDs = Set(results.flatMap(\.adjustedReviewTaskIDs))
        requestReminderSync()

        if updateStatus {
            let taskCount = adjustedTaskIDs.count
            statusMessage = "AI 计划已滚动调整：\(taskCount) 个任务"
        }

        return adjustedTaskIDs.count
    }

    /// AI 迭代不得覆盖的受保护计划项：正在进行、已完成、用户固定。
    ///
    /// 以当前内存快照为准逐条恢复；只恢复这些受保护条目，其余变化保留。
    private func restoringProtectedPlanItems(in candidate: StoreSnapshot) -> StoreSnapshot {
        let protectedItems = snapshot.dailyPlans
            .flatMap(\.items)
            .filter { $0.isPinned || $0.status == .completed || $0.status == .inProgress }
        guard !protectedItems.isEmpty else { return candidate }

        var result = candidate
        for item in protectedItems {
            for planIndex in result.dailyPlans.indices {
                guard let itemIndex = result.dailyPlans[planIndex].items.firstIndex(where: { $0.id == item.id }) else { continue }
                result.dailyPlans[planIndex].items[itemIndex] = item
            }
        }
        return result
    }

    /// AI 生成的计划必须经过时间预算检查（只提示，不删改任务）。
    private func budgetCheckSuffix(now: Date = Date()) -> String {
        let check = StudyBudgetChecker.check(state: snapshot, now: now)
        guard !check.isWithinBudget else { return "" }
        recordEvent(.warning, check.summary, shouldSave: false)
        return " " + check.summary
    }

    @discardableResult
    func applyAIPlanPatch(
        _ patch: AIPlanPatch,
        sourceUserMessageID: UUID? = nil,
        sourceAssistantMessageID: UUID? = nil,
        updateStatus: Bool = true
    ) -> AIPlanPatchApplicationResult {
        var patchWithSource = patch
        patchWithSource.sourceUserMessageID = sourceUserMessageID ?? patch.sourceUserMessageID
        patchWithSource.sourceAssistantMessageID = sourceAssistantMessageID ?? patch.sourceAssistantMessageID

        let result = AIPlanPatchEngine.apply(patchWithSource, to: &snapshot)
        snapshot = restoringProtectedPlanItems(in: snapshot)
        guard save() else { return result }

        requestReminderSync()

        if updateStatus {
            statusMessage = result.summary + budgetCheckSuffix()
        }
        recordEvent(.info, "\(result.patch.title)：\(result.summary)")
        return result
    }

    func setReminderEnabled(_ task: ReviewTask, enabled: Bool) {
        guard let index = snapshot.reviewTasks.firstIndex(where: { $0.id == task.id }) else { return }
        snapshot.reviewTasks[index].remindersEnabled = enabled
        guard save() else { return }

        // 单任务开关也是统一入口的一部分：同步时按 remindersEnabled 过滤。
        requestReminderSync()
    }

    private func linkedReviewTaskIDs(for mistake: Mistake) -> Set<UUID> {
        let legacyTaskTitle = "重做错题：\(ReviewPlanner.shortTitle(mistake.question))"
        return Set(snapshot.reviewTasks.compactMap { task in
            if task.mistakeID == mistake.id || task.title == legacyTaskTitle {
                return task.id
            }
            return nil
        })
    }

    func postpone(_ task: ReviewTask, days: Int = 1) {
        guard let index = snapshot.reviewTasks.firstIndex(where: { $0.id == task.id }) else { return }
        let newDate = ReviewPlanner.reviewDueDate(
            byAddingDays: max(days, 1),
            to: snapshot.reviewTasks[index].dueDate
        )
        snapshot.reviewTasks[index].dueDate = newDate
        snapshot.reviewTasks[index].status = .pending
        guard save() else { return }

        requestReminderSync()
    }

    @discardableResult
    func applySmartLoadBalancing() -> StudyLoadBalanceApplyResult {
        let result = StudyLoadBalancer.apply(to: &snapshot)
        guard !result.movedTaskIDs.isEmpty else {
            statusMessage = result.summary
            recordEvent(.info, result.summary)
            return result
        }

        guard save() else {
            // 写盘失败：内存已回滚，界面必须看到"没有移动任何任务"。
            return StudyLoadBalanceApplyResult(
                movedTaskIDs: [],
                proposals: [],
                beforeOverloadedDayCount: result.beforeOverloadedDayCount,
                afterOverloadedDayCount: result.beforeOverloadedDayCount
            )
        }
        requestReminderSync()
        statusMessage = result.summary
        recordEvent(.info, result.summary)
        return result
    }

    func reloadStoredData(silently: Bool = false) {
        guard !isBusy else { return }

        // 刷新/磁盘重载不能覆盖尚未保存的**今天**会话状态。
        // 跨日遗留会话不能阻止刷新——否则它们会一边挡住刷新、一边从首页消失（需求 6）。
        if todayActiveSession != nil {
            if !silently {
                statusMessage = "今天的计时还在进行中，已跳过本次磁盘重载。"
            }
            return
        }

        do {
            guard let loaded = try persistence?.loadWithReport() else {
                if !silently {
                    statusMessage = "本地还没有数据文件"
                }
                return
            }
            snapshot = loaded.snapshot
            refreshAIConnectionCredentialIfNeeded()
            refreshIterativeAIPlans(updateStatus: false)
            if !silently {
                statusMessage = "已刷新本地数据"
                recordEvent(.info, "已刷新本地数据")
            }
        } catch {
            statusMessage = "刷新数据失败：\(error.localizedDescription)"
            recordEvent(.error, "刷新数据失败：\(error.localizedDescription)")
        }
    }

    func importBackup(url: URL) {
        do {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard var imported = try persistence?.importSnapshot(from: url) else { return }
            imported = imported.normalizedToCurrentSchema()
            imported.settings.legacyCredentialMigrationPending = false
            imported.diagnosticEvents.insert(AppDiagnosticEvent(level: .info, message: "从备份导入数据"), at: 0)
            Task {
                let saved = await commit(imported, status: "已导入备份", reminderChanges: [], now: Date())
                if saved {
                    await synchronizeReminders(now: Date())
                    // 导入会整体替换数据：必须按新数据重新评估今天的计划。
                    await reevaluateTodayPlan(reason: .dataRestored, now: Date())
                }
            }
        } catch {
            statusMessage = "导入备份失败：\(error.localizedDescription)"
            recordEvent(.error, "导入备份失败：\(error.localizedDescription)")
        }
    }

    func restoreFromBackup(index: Int, label: String) {
        do {
            guard var recovered = try persistence?.restoreFromBackup(index: index) else {
                statusMessage = "未找到备份 #\(index)"
                recordEvent(.warning, "尝试恢复备份 #\(index)，但文件不存在")
                return
            }
            recovered = recovered.normalizedToCurrentSchema()
            recovered.settings.legacyCredentialMigrationPending = false
            recovered.diagnosticEvents.insert(
                AppDiagnosticEvent(level: .warning, message: "从备份 #\(index) (\(label)) 还原数据"),
                at: 0
            )
            Task {
                let saved = await commit(recovered, status: "已从备份 #\(index) (\(label)) 恢复", reminderChanges: [], now: Date())
                if saved {
                    await synchronizeReminders(now: Date())
                    recordEvent(.info, "从备份 #\(index) 恢复成功")
                    await reevaluateTodayPlan(reason: .dataRestored, now: Date())
                }
            }
        } catch {
            statusMessage = "恢复失败：\(error.localizedDescription)"
            recordEvent(.error, "恢复备份 #\(index) 失败：\(error.localizedDescription)")
        }
    }

    func restoreRecoverySnapshot() {
        let backups = availableBackups
        guard let first = backups.first else {
            statusMessage = "没有可用的恢复点"
            recordEvent(.warning, "尝试恢复，但没有可用恢复点")
            return
        }
        let label = first.date.formatted(date: .abbreviated, time: .shortened)
        restoreFromBackup(index: first.index, label: label)
    }

    func resetUsageStats() {
        snapshot.usageStats = ModelUsageStats()
        guard save() else { return }
        statusMessage = "模型费用统计已清零"
        recordEvent(.info, "模型费用统计已清零")
    }

    func clearDiagnosticEvents() {
        snapshot.diagnosticEvents.removeAll()
        guard save() else { return }
        statusMessage = "诊断记录已清空"
    }

    func runDataHealthCheck() {
        let issues = dataHealthIssues()
        if issues.isEmpty {
            statusMessage = "数据体检通过"
            recordEvent(.info, "数据体检通过")
        } else {
            let summary = issues.prefix(6).joined(separator: "；")
            statusMessage = "数据体检发现 \(issues.count) 个问题"
            recordEvent(.warning, "数据体检发现 \(issues.count) 个问题：\(summary)")
        }
    }

    func makeBackupDocument() -> ExportDocument {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 备份必须写成当前 schema；写入方不做降级，避免导入时被迫走错误的迁移路径。
        let exportSnapshot = snapshot.normalizedToCurrentSchema()
        let data = (try? encoder.encode(exportSnapshot)) ?? Data()
        return ExportDocument(data: data)
    }

    func makePrivacyBackupDocument() -> ExportDocument {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var exportSnapshot = snapshot.normalizedToCurrentSchema()
        exportSnapshot.diagnosticEvents = []
        exportSnapshot.documents = exportSnapshot.documents.map { document in
            var redacted = document
            redacted.content = "隐私导出已省略原文内容。"
            return redacted
        }
        let data = (try? encoder.encode(exportSnapshot)) ?? Data()
        return ExportDocument(data: data)
    }

    func makeMarkdownExportDocument() -> ExportDocument {
        ExportDocument(text: makeMarkdownExport())
    }

    func makeAnkiExportDocument() -> ExportDocument {
        ExportDocument(text: makeAnkiTSVExport())
    }

    func askQuestion() {
        let question = chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let previousChatMessages = snapshot.chatMessages
        let userMessage = ChatHistoryMessage(role: .user, content: question)
        snapshot.chatMessages.append(userMessage)
        chatQuestion = ""
        guard save() else { return }
        startAIRequest("正在检索个人资料...") {
            await self.runBusy("正在检索个人资料...", showsChatResponseOnRefusal: true) { [self] in
                if let patch = AIPlanPatchEngine.makeRuleBasedPatch(command: question, snapshot: snapshot) {
                    var assistantMessage = ChatHistoryMessage(role: .assistant, content: "")
                    let result = applyAIPlanPatch(
                        patch,
                        sourceUserMessageID: userMessage.id,
                        sourceAssistantMessageID: assistantMessage.id,
                        updateStatus: false
                    )
                    let answerText = makeAIPlanPatchAnswer(from: result)
                    assistantMessage.content = answerText
                    chatAnswer = answerText
                    snapshot.chatMessages.append(assistantMessage)
                    save()
                    statusMessage = result.summary
                    return
                }

                guard snapshot.settings.allowModelRequests else {
                    statusMessage = "已关闭 AI 请求：请在隐私设置中开启后再提问"
                    return
                }
                guard isAIConnectionReady else {
                    statusMessage = "当前 AI 服务尚未就绪：请在设置中补全连接配置后再提问。"
                    return
                }
                chatAnswer = ""
                chatContexts = []
                refreshIterativeAIPlans(updateStatus: false)
                let retrievalQuery = makeRetrievalQuery(question: question, chatHistory: previousChatMessages)
                let retrieval = StudyContextRetriever.retrieve(query: retrievalQuery, snapshot: snapshot)
                let shouldUseContext = snapshot.settings.includePersonalContextInAnswers
                chatContexts = shouldUseContext ? retrieval.items : []
                if shouldUseContext {
                    statusMessage = retrieval.items.isEmpty ? "未检索到直接相关资料，正在生成通用解释..." : "已检索到 \(retrieval.items.count) 条个人资料，正在生成答案..."
                } else {
                    statusMessage = "隐私设置已关闭个人资料引用，正在生成通用解释..."
                }
                let studyState = makeChatStudyStateContext()
                let chatPromptContext = try await makeCompressedChatPromptContext(
                    from: previousChatMessages,
                    studyState: studyState
                )
                let client = try makeClient()
                let result = try await client.answer(
                    question: question,
                    context: shouldUseContext ? retrieval.promptContext : "",
                    studyState: studyState,
                    chatHistory: chatPromptContext.recentMessages,
                    compressedContextSummary: chatPromptContext.summary,
                    answerMode: snapshot.settings.answerMode
                )
                recordUsage(result.usage, pricing: client.pricing)
                let contextCharCount = shouldUseContext ? retrieval.promptContext.count : 0
                let truncatedNote = contextCharCount > 30_000 ? "\n\n（部分个人资料因长度限制已截断）" : ""
                let citations = shouldUseContext ? retrieval.citations : []
                let answerText = result.answer + makeCitationTail(from: citations) + truncatedNote
                chatAnswer = answerText
                var assistantMessage = ChatHistoryMessage(role: .assistant, content: answerText, citations: citations)

                if snapshot.settings.allowStructuredPlanRequests,
                   AIPlanDraftIntent.shouldAttempt(question: question, answer: result.answer) {
                    statusMessage = "正在整理可确认的规划草稿..."
                   if let planDraft = try await makeAIPlanDraftIfPossible(
                        question: question,
                        answer: result.answer,
                        context: shouldUseContext ? retrieval.promptContext : "",
                        studyState: studyState,
                        sourceUserMessageID: userMessage.id,
                        sourceAssistantMessageID: assistantMessage.id
                    ) {
                        assistantMessage.aiPlanDraftID = planDraft.id
                        snapshot.aiPlanDrafts.insert(planDraft, at: 0)
                    }
                }

                snapshot.chatMessages.append(assistantMessage)
                save()
                let hasPlanDraft = assistantMessage.aiPlanDraftID != nil
                if hasPlanDraft {
                    statusMessage = shouldUseContext && !retrieval.items.isEmpty
                        ? "答疑完成：引用 \(retrieval.items.count) 条个人资料，并生成待确认规划草稿"
                        : "答疑完成：已生成待确认规划草稿"
                } else {
                    statusMessage = shouldUseContext && !retrieval.items.isEmpty ? "答疑完成：引用 \(retrieval.items.count) 条个人资料" : "答疑完成"
                }
            }
        }
    }

    func makeClient() throws -> AIClient {
        guard snapshot.settings.allowModelRequests else {
            throw AIError.invalidConfiguration("已关闭模型请求：当前操作不会发送到 AI 服务。")
        }
        return try AIClientFactory.make(settings: snapshot.settings, apiKey: apiKey, underlyingTransport: underlyingAITransport)
    }

    // MARK: - Chat History

    func clearChatHistory() {
        snapshot.chatMessages.removeAll()
        snapshot.chatContextSummary = ""
        snapshot.chatMemorySummary = ChatMemorySummary()
        snapshot.chatContextSummaryMessageCount = 0
        snapshot.chatContextSummaryUpdatedAt = nil
        chatAnswer = ""
        chatContexts = []
        guard save() else { return }
        statusMessage = "聊天记录已清空"
    }

    func requestAIPlanDraftConfirmation(_ draft: AIPlanDraft) {
        guard let index = snapshot.aiPlanDrafts.firstIndex(where: { $0.id == draft.id && $0.status == .pending }) else {
            statusMessage = "这份规划草稿已经不是待确认状态"
            return
        }

        var planDraft = snapshot.aiPlanDrafts[index]
        let document = makeAIPlanDocument(from: planDraft)
        snapshot.documents.insert(document, at: 0)

        let analysisDraft = planDraft.makeAnalysisDraft(sourceDocumentID: document.id)
        planDraft.status = .confirmed
        planDraft.sourceDocumentID = document.id
        planDraft.confirmedAnalysisDraftID = analysisDraft.id
        planDraft.confirmedAt = Date()
        snapshot.aiPlanDrafts[index] = planDraft

        let confirmation = confirmDraft(analysisDraft)
        if let confirmedIndex = snapshot.aiPlanDrafts.firstIndex(where: { $0.id == planDraft.id }) {
            snapshot.aiPlanDrafts[confirmedIndex].createdKnowledgePointIDs = confirmation.createdKnowledgePointIDs
            snapshot.aiPlanDrafts[confirmedIndex].createdMistakeIDs = confirmation.createdMistakeIDs
            snapshot.aiPlanDrafts[confirmedIndex].createdReviewTaskIDs = confirmation.createdReviewTaskIDs
            save()
        }
    }

    @discardableResult
    func updateAIPlanDraft(_ draft: AIPlanDraft) -> Bool {
        guard let index = snapshot.aiPlanDrafts.firstIndex(where: { $0.id == draft.id && $0.status == .pending }) else {
            statusMessage = "这份规划草稿已经不是待确认状态"
            return false
        }

        var updated = draft
        updated.status = .pending
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.summary = updated.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.reviewItems = updated.reviewItems.map { item in
            DraftReviewItem(
                id: item.id,
                title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                dueInDays: min(max(item.dueInDays, 0), 365),
                priority: item.priority.map { min(max($0, 0), 5) },
                relatedKnowledgeTitle: normalizedPlanDraftReference(item.relatedKnowledgeTitle),
                relatedMistakeTitle: normalizedPlanDraftReference(item.relatedMistakeTitle),
                relatedMistakeID: item.relatedMistakeID
            )
        }

        guard !updated.title.isEmpty,
              updated.reviewItems.allSatisfy({ !$0.title.isEmpty }) else {
            statusMessage = "规划标题和任务标题不能为空"
            return false
        }

        snapshot.aiPlanDrafts[index] = updated
        guard save() else { return false }
        statusMessage = "AI 规划草稿已保存：\(updated.title)"
        return true
    }

    @discardableResult
    func dismissAIPlanDraft(_ draft: AIPlanDraft) -> Bool {
        guard let index = snapshot.aiPlanDrafts.firstIndex(where: { $0.id == draft.id && $0.status == .pending }) else {
            statusMessage = "这份规划草稿已经不是待确认状态"
            return false
        }

        snapshot.aiPlanDrafts[index].status = .dismissed
        guard save() else { return false }
        statusMessage = "已忽略 AI 规划草稿：\(draft.title)"
        return true
    }

    private func normalizedPlanDraftReference(_ title: String?) -> String? {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    private func makeAIPlanDocument(from draft: AIPlanDraft) -> StudyDocument {
        StudyDocument(
            title: draft.title,
            sourceName: "AI 对话生成规划",
            kind: .mixed,
            content: snapshot.settings.keepDocumentContent ? makeAIPlanDocumentContent(from: draft) : "已根据隐私设置不保存 AI 规划原文。"
        )
    }

    private func makeAIPlanDocumentContent(from draft: AIPlanDraft) -> String {
        var lines: [String] = [
            "# \(draft.title)",
            "",
            draft.summary,
            "",
            "## 知识点"
        ]

        if draft.knowledgePoints.isEmpty {
            lines.append("暂无知识点。")
        } else {
            for point in draft.knowledgePoints {
                lines.append("- \(point.subject)：\(point.title)（掌握度 \(Int(point.mastery * 100))%）")
                lines.append("  \(point.summary)")
            }
        }

        lines.append(contentsOf: ["", "## 复习任务"])
        if draft.reviewItems.isEmpty {
            lines.append("暂无复习任务。")
        } else {
            for item in draft.reviewItems {
                let dueText = item.dueInDays == 0 ? "今天" : "\(item.dueInDays) 天后"
                let priorityText = item.priority.map { "，优先级 \($0)" } ?? ""
                let relatedKnowledgeText = item.relatedKnowledgeTitle.map { "，关联知识点：\($0)" } ?? ""
                let relatedMistakeText = item.relatedMistakeTitle.map { "，关联错题：\($0)" } ?? ""
                lines.append("- \(item.title)：\(dueText)\(priorityText)\(relatedKnowledgeText)\(relatedMistakeText)")
            }
        }

        lines.append(contentsOf: ["", "## 错题/薄弱项"])
        if draft.mistakes.isEmpty {
            lines.append("暂无错题。")
        } else {
            for mistake in draft.mistakes {
                lines.append("- \(mistake.question)")
                lines.append("  答案：\(mistake.correctAnswer)")
                lines.append("  原因：\(mistake.errorReason)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func makeAIPlanDraftIfPossible(
        question: String,
        answer: String,
        context: String,
        studyState: String,
        sourceUserMessageID: UUID,
        sourceAssistantMessageID: UUID
    ) async throws -> AIPlanDraft? {
        do {
            let planTemplate = planTemplateForCurrentGoal(question: question, answer: answer)
            let client = try makeClient()
            let result = try await client.makeAIPlanDraft(
                question: question,
                answer: answer,
                context: context,
                studyState: studyState,
                planTemplate: planTemplate
            )
            recordUsage(result.usage, pricing: client.pricing)
            return makeAIPlanDraft(
                from: result.payload,
                planTemplate: planTemplate,
                sourceUserMessageID: sourceUserMessageID,
                sourceAssistantMessageID: sourceAssistantMessageID
            )
        } catch let refusal as AIModelRefusal {
            throw refusal
        } catch {
            recordEvent(.warning, "AI 规划草稿结构化失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func planTemplateForCurrentGoal(question: String, answer: String, now: Date = Date()) -> AIPlanTemplate {
        let inferred = AIPlanDraftIntent.template(for: question, answer: answer)
        guard let goal = snapshot.nextExamGoal(now: now) else {
            return inferred
        }

        let daysRemaining = goal.daysRemaining(now: now)
        if daysRemaining <= 0 {
            return .today
        }
        if daysRemaining <= 6 {
            return .week
        }
        if daysRemaining <= 30 {
            return .thirtyDays
        }
        return inferred == .today || inferred == .week || inferred == .thirtyDays ? inferred : .general
    }

    private func makeAIPlanPatchAnswer(from result: AIPlanPatchApplicationResult) -> String {
        guard result.affectedCount > 0 else {
            return "我看了一下现有复习任务，但没有找到能安全修改的项目。你可以说得更具体一点，比如“把明天的 C 语言任务顺延 1 天”或“把 C 语言优先级提高”。"
        }

        var lines: [String] = [
            result.summary,
            "",
            result.patch.summary
        ]

        if result.skippedOperationCount > 0 {
            lines.append("有 \(result.skippedOperationCount) 个候选任务已经不存在或无法修改，已自动跳过。")
        }

        lines.append("你可以去“复习计划”或“今日”页面查看调整后的任务。")
        return lines.joined(separator: "\n")
    }

    private func makeCitationTail(from citations: [ChatMessageCitation]) -> String {
        let visibleCitations = Array(citations.prefix(5))
        guard !visibleCitations.isEmpty else { return "" }

        let sourceText = visibleCitations
            .map { citation in
                "[资料 \(citation.promptIndex)] \(citation.kind.rawValue)：\(citation.title)"
            }
            .joined(separator: "；")
        return "\n\n参考来源：\(sourceText)"
    }

    private func makeAIPlanDraft(
        from payload: AIPlanPayload,
        planTemplate: AIPlanTemplate,
        sourceUserMessageID: UUID,
        sourceAssistantMessageID: UUID
    ) -> AIPlanDraft? {
        guard payload.isPlan == true else { return nil }

        let knowledgePoints = (payload.knowledgePoints ?? [])
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                DraftKnowledgePoint(
                    title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    subject: ($0.subject ?? "未分类").trimmingCharacters(in: .whitespacesAndNewlines),
                    summary: $0.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                    mastery: min(max($0.mastery ?? 0.4, 0), 1)
                )
            }

        let mistakes = (payload.mistakes ?? [])
            .filter { !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                DraftMistake(
                    question: $0.question.trimmingCharacters(in: .whitespacesAndNewlines),
                    correctAnswer: ($0.correctAnswer ?? "待补充").trimmingCharacters(in: .whitespacesAndNewlines),
                    errorReason: $0.errorReason.trimmingCharacters(in: .whitespacesAndNewlines),
                    relatedKnowledgeTitles: $0.relatedKnowledgeTitles ?? []
                )
            }

        let reviewItems = (payload.reviewItems ?? [])
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                let relatedMistakeTitle = $0.relatedMistakeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                return DraftReviewItem(
                    title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    dueInDays: planTemplate.normalizedDueInDays($0.dueInDays ?? defaultDueInDays(for: planTemplate)),
                    priority: $0.priority.map { min(max($0, 0), 5) },
                    relatedKnowledgeTitle: normalizedPlanDraftReference($0.relatedKnowledgeTitle),
                    relatedMistakeTitle: relatedMistakeTitle?.isEmpty == false ? relatedMistakeTitle : nil,
                    relatedMistakeID: relatedDraftMistakeID(for: relatedMistakeTitle, in: mistakes)
                )
            }

        guard !reviewItems.isEmpty || !knowledgePoints.isEmpty || !mistakes.isEmpty else {
            return nil
        }

        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provisionalDraft = AIPlanDraft(
            title: title?.isEmpty == false ? title! : "AI 生成复习规划",
            summary: summary?.isEmpty == false ? summary! : "根据本次对话生成的\(planTemplate.label)草稿。",
            sourceUserMessageID: sourceUserMessageID,
            sourceAssistantMessageID: sourceAssistantMessageID,
            planTemplate: planTemplate,
            knowledgePoints: knowledgePoints,
            mistakes: mistakes,
            reviewItems: reviewItems
        )
        let validation = AIPlanDraftQualityValidator.validate(provisionalDraft)
        if !validation.notes.isEmpty {
            recordEvent(.info, "AI 规划草稿质量校验：\(validation.notes.joined(separator: "；"))")
        }
        if validation.draft == nil {
            recordEvent(.warning, "AI 规划草稿未通过质量校验：\(validation.notes.joined(separator: "；"))")
        }
        return validation.draft
    }

    private func defaultDueInDays(for planTemplate: AIPlanTemplate) -> Int {
        switch planTemplate {
        case .today: return 0
        case .week: return 1
        case .thirtyDays: return 7
        case .general: return 1
        }
    }

    private func makeCompressedChatPromptContext(
        from chatHistory: [ChatHistoryMessage],
        studyState: String
    ) async throws -> ChatPromptContext {
        if snapshot.chatContextSummaryMessageCount > chatHistory.count {
            snapshot.chatContextSummary = ""
            snapshot.chatMemorySummary = ChatMemorySummary()
            snapshot.chatContextSummaryMessageCount = 0
            snapshot.chatContextSummaryUpdatedAt = nil
            save()
        }

        let effectiveMemory = snapshot.chatMemorySummary.mergedWithLegacySummary(snapshot.chatContextSummary)
        let memoryPromptText = effectiveMemory.promptText

        let summarizedCount = min(snapshot.chatContextSummaryMessageCount, chatHistory.count)
        let unsummarizedMessages = Array(chatHistory.dropFirst(summarizedCount))
        let unsummarizedCharacterCount = unsummarizedMessages.reduce(0) { $0 + $1.content.count }
        let shouldCompress = unsummarizedMessages.count > chatCompressionMessageThreshold
            || unsummarizedCharacterCount > chatCompressionCharacterThreshold

        guard shouldCompress else {
            return ChatPromptContext(
                summary: memoryPromptText,
                recentMessages: unsummarizedMessages
            )
        }

        let keepRecentCount = min(chatCompressionRecentMessageCount, chatHistory.count)
        let targetSummaryCount = max(0, chatHistory.count - keepRecentCount)
        guard targetSummaryCount > summarizedCount else {
            return ChatPromptContext(
                summary: memoryPromptText,
                recentMessages: Array(chatHistory.dropFirst(summarizedCount))
            )
        }

        let messagesToCompress = Array(chatHistory[summarizedCount..<targetSummaryCount])
        statusMessage = "正在压缩较早的对话上下文..."

        do {
            let client = try makeClient()
            let result = try await client.compressChatContext(
                existingMemory: effectiveMemory,
                messages: messagesToCompress,
                studyState: studyState
            )
            recordUsage(result.usage, pricing: client.pricing)
            snapshot.chatContextSummary = result.summary
            snapshot.chatMemorySummary = result.memory
            snapshot.chatContextSummaryMessageCount = targetSummaryCount
            snapshot.chatContextSummaryUpdatedAt = Date()
            save()
            statusMessage = "已压缩较早对话，正在生成答案..."

            return ChatPromptContext(
                summary: snapshot.chatMemorySummary.promptText,
                recentMessages: Array(chatHistory.suffix(keepRecentCount))
            )
        } catch let refusal as AIModelRefusal {
            throw refusal
        } catch {
            recordEvent(.warning, "自动压缩对话上下文失败，已改用近期原文上下文：\(error.localizedDescription)")
            return ChatPromptContext(
                summary: memoryPromptText,
                recentMessages: Array(chatHistory.suffix(chatCompressionMessageThreshold))
            )
        }
    }

    private func makeRetrievalQuery(question: String, chatHistory: [ChatHistoryMessage]) -> String {
        let recentUserTurns = chatHistory
            .filter { $0.role == .user }
            .suffix(3)
            .map(\.content)
        return (recentUserTurns + [question])
            .map { $0.compactedForStudyText(limit: 600) }
            .joined(separator: "\n")
    }

    private func makeChatStudyStateContext(now: Date = Date()) -> String {
        let profileSummary = StudyProfileSummary.make(from: snapshot, now: now)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let pendingTasks = snapshot.reviewTasks.filter { $0.status == .pending }
        let overdueCount = pendingTasks.filter { $0.dueDate < todayStart }.count
        let dueTodayCount = pendingTasks.filter { todayStart <= $0.dueDate && $0.dueDate < tomorrowStart }.count
        let weakKnowledge = snapshot.knowledgePoints
            .sorted {
                if $0.mastery != $1.mastery {
                    return $0.mastery < $1.mastery
                }
                return $0.createdAt > $1.createdAt
            }
            .prefix(10)
        let upcomingTasks = pendingTasks
            .sorted {
                if ($0.priority ?? 0) != ($1.priority ?? 0) {
                    return ($0.priority ?? 0) > ($1.priority ?? 0)
                }
                return $0.dueDate < $1.dueDate
            }
            .prefix(14)
        let recentMistakes = snapshot.mistakes
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(8)
        let recentDocuments = snapshot.documents
            .sorted { $0.importedAt > $1.importedAt }
            .prefix(6)

        var lines: [String] = [
            profileSummary.promptText,
            "",
            "## 原始学习数据补充",
            "当前日期：\(now.formatted(date: .numeric, time: .omitted))",
            "资料数量：\(snapshot.documents.count)；知识点：\(snapshot.knowledgePoints.count)；错题：\(snapshot.mistakes.count)；复习任务：\(snapshot.reviewTasks.count)；待确认草稿：\(snapshot.drafts.count + snapshot.pendingAIPlanDrafts.count)",
            "待复习任务：\(pendingTasks.count)；逾期：\(overdueCount)；今日到期：\(dueTodayCount)；连续学习：\(streakDays) 天"
        ]

        let activeGoals = snapshot.activeExamGoals(now: now)
        lines.append("")
        lines.append("已设置考试目标：")
        if activeGoals.isEmpty {
            lines.append("暂无明确考试目标。")
        } else {
            for goal in activeGoals.prefix(3) {
                lines.append("- \(goal.promptSummary(now: now))")
            }
            if let nearest = activeGoals.first {
                let days = max(nearest.daysRemaining(now: now), 0)
                lines.append("规划硬约束：优先围绕最近目标「\(nearest.name)」安排；任务 dueInDays 不应超过 \(days)，每日任务量需匹配 \(nearest.dailyAvailableTimeText)。")
            }
        }

        lines.append("")
        lines.append("薄弱/最近知识点：")
        if weakKnowledge.isEmpty {
            lines.append("暂无知识点。")
        } else {
            for point in weakKnowledge {
                lines.append("- \(point.subject)｜\(point.title)：掌握度 \(Int(point.mastery * 100))%，\(point.summary.compactedForStudyText(limit: 180))")
            }
        }

        lines.append("")
        lines.append("近期/高优先级复习任务：")
        if upcomingTasks.isEmpty {
            lines.append("暂无待复习任务。")
        } else {
            for task in upcomingTasks {
                lines.append("- \(reviewTaskPromptLine(task))")
            }
        }

        lines.append("")
        lines.append("最近错题：")
        if recentMistakes.isEmpty {
            lines.append("暂无错题。")
        } else {
            for mistake in recentMistakes {
                let titles = mistake.knowledgePointIDs.compactMap { id in
                    snapshot.knowledgePoints.first { $0.id == id }?.title
                }
                let related = titles.isEmpty ? "未关联知识点" : titles.joined(separator: "、")
                lines.append("- \(mistake.question.compactedForStudyText(limit: 180))；错因：\(mistake.errorReason.compactedForStudyText(limit: 160))；关联：\(related)")
            }
        }

        lines.append("")
        lines.append("最近导入资料：")
        if recentDocuments.isEmpty {
            lines.append("暂无资料。")
        } else {
            for document in recentDocuments {
                lines.append("- \(document.kind.rawValue)｜\(document.title)：\(document.importedAt.formatted(date: .abbreviated, time: .omitted))")
            }
        }

        if !snapshot.drafts.isEmpty {
            lines.append("")
            lines.append("待确认草稿提醒：有 \(snapshot.drafts.count + snapshot.pendingAIPlanDrafts.count) 个分析或规划草稿尚未确认，做规划时需要提醒用户先确认或筛选。")
        }

        return lines.joined(separator: "\n")
    }

    private func reviewTaskPromptLine(_ task: ReviewTask) -> String {
        let dueText = task.dueDate.formatted(date: .abbreviated, time: .omitted)
        let priorityText = task.priority.map { "优先级 \($0)" } ?? "未设优先级"
        var linked: [String] = []
        if let knowledgePointID = task.knowledgePointID,
           let point = snapshot.knowledgePoints.first(where: { $0.id == knowledgePointID }) {
            linked.append("知识点：\(point.title)")
        }
        if let mistakeID = task.mistakeID,
           let mistake = snapshot.mistakes.first(where: { $0.id == mistakeID }) {
            linked.append("错题：\(mistake.question.compactedForStudyText(limit: 80))")
        }
        let linkedText = linked.isEmpty ? "未关联资料" : linked.joined(separator: "；")
        return "\(task.title)：\(dueText)，\(priorityText)，\(task.sm2Description)，\(linkedText)"
    }

    // MARK: - Streak

    private struct DailyCheckInResult {
        var completedTaskCount: Int
        var didCheckInToday: Bool
    }

    private func calculateStreak() -> Int {
        let recordSet = Set(snapshot.dailyActivityRecords
            .filter { $0.completedTaskCount > 0 }
            .map { $0.dateString })
        guard !recordSet.isEmpty else { return 0 }

        let calendar = Calendar.current
        let today = DailyActivityRecord.todayString()
        let yesterday = DailyActivityRecord.dateString(from: calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date())

        // Streak must include today or yesterday to be active
        guard recordSet.contains(today) || recordSet.contains(yesterday) else { return 0 }

        // Walk backwards from today, counting consecutive days with records.
        // Stop at the first gap — a missing day breaks the streak.
        var streak = 0
        var date = Date()
        while true {
            let check = DailyActivityRecord.dateString(from: date)
            if recordSet.contains(check) {
                streak += 1
            } else {
                // Gap detected: the streak is broken.
                break
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return streak
    }

    /// 当日打卡的**纯值**累加：写进候选快照，与完成事件同一次提交落盘。
    ///
    /// 这样不会出现"完成记录已保存、打卡另存失败"的分裂状态（需求 9）。
    /// 口径保持与旧实现一致：按旧版每日完成总数累加，供连续天数/打卡展示。
    private static func applyingDailyActivity(
        to state: inout StoreSnapshot,
        at date: Date
    ) -> DailyCheckInResult {
        let dayString = DailyActivityRecord.dateString(from: date)
        let wasCheckedInToday = (state.dailyActivityRecords.first { $0.dateString == dayString }?.completedTaskCount ?? 0) > 0
        let completedTaskCount: Int
        if let index = state.dailyActivityRecords.firstIndex(where: { $0.dateString == dayString }) {
            state.dailyActivityRecords[index].completedTaskCount += 1
            state.dailyActivityRecords[index].studiedAt = date
            completedTaskCount = state.dailyActivityRecords[index].completedTaskCount
        } else {
            state.dailyActivityRecords.append(DailyActivityRecord(date: date, completedTaskCount: 1))
            completedTaskCount = 1
        }
        if state.dailyActivityRecords.count > 400 {
            state.dailyActivityRecords = Array(state.dailyActivityRecords.suffix(400))
        }
        return DailyCheckInResult(
            completedTaskCount: completedTaskCount,
            didCheckInToday: !wasCheckedInToday
        )
    }

    private func checkInStatusSuffix(for activity: DailyCheckInResult) -> String {
        if activity.didCheckInToday {
            return " · 今日打卡成功"
        }
        return " · 今日已打卡 \(activity.completedTaskCount) 项"
    }

    /// 重新同步全部提醒（设置变更、导入恢复、前台激活时调用）。
    ///
    /// 只安排有限的近期提醒：优先今日计划里的"下一项"，没有计划时退化为最近的
    /// 到期复习任务。既不做集中轰炸，也不会因为提醒失败影响已保存的业务数据。
    func synchronizeReminders(now: Date = Date()) async {
        let context = snapshot.planningContext(now: now)

        var changes: [ReminderChangeRequest] = [ReminderChangeRequest(action: .cancelAll)]

        if snapshot.settings.remindersEnabled {
            let limit = coordinator.maximumScheduledReminders
            if let plan = StudyPlanCoordinator.activePlan(in: snapshot, dayKey: context.todayKey) {
                // 计划路径：只提醒"下一项"，并且尊重单任务开关。
                let requests = coordinator
                    .reminderChanges(for: plan, state: snapshot, context: context)
                    .filter { $0.action != .cancelAll }
                    .filter { request in
                        guard let planItemID = request.planItemID,
                              let item = plan.items.first(where: { $0.id == planItemID }) else { return true }
                        return isReminderAllowed(for: item, in: snapshot)
                    }
                changes.append(contentsOf: requests.prefix(limit))
            } else {
                // 没有今日计划时的兜底：最近的到期复习任务，且必须落在可提醒时间。
                let upcoming = snapshot.reviewTasks
                    .filter { $0.status == .pending && $0.remindersEnabled && $0.dueDate > now }
                    .sorted { $0.dueDate < $1.dueDate }
                    .prefix(limit)
                for task in upcoming {
                    guard let fireDate = usableReminderDate(preferred: task.dueDate, state: snapshot, context: context) else {
                        // 没有合适的提醒时间（例如整段都在睡眠/课程里）→ 不安排。
                        continue
                    }
                    changes.append(
                        ReminderChangeRequest(
                            action: .schedule,
                            planItemID: nil,
                            fireDate: fireDate,
                            title: task.title,
                            kind: .reviewTask,
                            businessID: task.id.uuidString
                        )
                    )
                }
            }
        }

        await applyReminderChanges(changes, now: now)
    }

    /// 单任务开关 + 来源任务开关：任一关闭都不安排提醒。
    private func isReminderAllowed(for item: DailyPlanItem, in state: StoreSnapshot) -> Bool {
        guard let reviewTaskID = item.source.reviewTaskID,
              let task = state.reviewTasks.first(where: { $0.id == reviewTaskID }) else {
            return true
        }
        return task.remindersEnabled && task.status == .pending
    }

    /// 把提醒时间挪到"可用时间"；找不到就返回 `nil`（宁可不提醒，也不在睡眠/上课时打扰）。
    private func usableReminderDate(
        preferred: Date,
        state: StoreSnapshot,
        context: PlanningContext
    ) -> Date? {
        var candidate = max(preferred, now(context))
        let deadline = context.calendar.date(byAdding: .hour, value: 18, to: candidate) ?? candidate
        while candidate <= deadline {
            if !StudyPlanCoordinator.isProtected(candidate, state: state, context: context) {
                return candidate
            }
            guard let next = context.calendar.date(byAdding: .minute, value: 15, to: candidate) else { return nil }
            candidate = next
        }
        return nil
    }

    private func now(_ context: PlanningContext) -> Date { context.now }

    /// 兼容旧调用点。
    private func reschedulePendingNotifications() {
        requestReminderSync()
    }

    /// 统一的提醒同步入口（收拢所有逐条排程，需求 11）。
    ///
    /// 特性：
    /// - 多次请求合并成一次执行；
    /// - 后发起的同步会让先前作废，旧请求不会覆盖新计划的提醒；
    /// - 业务保存成功后才调用；通知失败只记录，不回滚数据。
    private var reminderSyncTask: Task<Void, Never>?

    func requestReminderSync(now: Date = Date()) {
        reminderSyncTask?.cancel()
        reminderSyncTask = Task { [weak self] in
            // 轻微延迟，把同一批操作里的多次请求合并成一次同步。
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.synchronizeReminders(now: now)
        }
    }

    // MARK: - 生命周期与日期

    /// 应用进入前台：检查日期与计划有效性，前台跨日立即刷新（不只依赖下一次启动）。
    ///
    /// 同时处理时区/系统时间变化：重新评估未来安排，但**不会**让既有奖励重复发放
    /// （发放键包含学习日与规则版本）。
    func handleForegroundActivation(now: Date = Date()) async {
        guard !isBusy, !isHandlingForegroundActivation else { return }
        isHandlingForegroundActivation = true
        defer { isHandlingForegroundActivation = false }

        let context = snapshot.planningContext(now: now)
        let todayKey = context.todayKey
        let currentZone = TimeZone.current.identifier
        let didCrossDay = lastActiveDayKey != nil && lastActiveDayKey != todayKey
        let didChangeTimeZone = currentZone != lastKnownTimeZoneIdentifier

        lastActiveDayKey = todayKey
        lastKnownTimeZoneIdentifier = currentZone

        // 前台激活：立刻开始进程内心跳，避免连续学习被误判为中断。
        refreshSessionHeartbeat()

        // 娱乐状态结算：计时到期与奖励过期都在这里收敛，不依赖用户进入设置页（需求 8）。
        await settleEntertainmentState(now: now)

        // 今天还有未结束的计时：不做任何可能覆盖会话的重算，只同步提醒。
        // 但跨日遗留会话不阻止刷新与规划——它们会在首页单独提示处理（需求 6）。
        if todayActiveSession != nil {
            await synchronizeReminders(now: now)
            return
        }

        // 需求 4/5：跨日或时区变化时，"只刷新状态"是不够的——必须重新规划。
        // 先落盘状态重算（完成事件与奖励资格），再重新计算今天的安排。
        if didCrossDay || didChangeTimeZone {
            let refreshed = coordinator.coordinate(.refresh(dayKey: todayKey), state: snapshot, context: context)
            let saved = await commit(
                refreshed.snapshot,
                status: refreshed.statusMessage,
                reminderChanges: refreshed.reminderChanges,
                now: now
            )
            guard saved else { return }

            if didCrossDay {
                recordEvent(.info, "前台跨日：\(todayKey.localDateString)", shouldSave: false)
                await reevaluateTodayPlan(reason: .newStudyDay, now: now, announcesResult: true)
            } else {
                recordEvent(.warning, "检测到时区变化：\(currentZone)", shouldSave: false)
                await reevaluateTodayPlan(reason: .availabilityChanged, now: now, announcesResult: true)
            }
            return
        }

        // 当天首次进入且今天还没有有效计划 → 自动生成，用户不必重启或手动点按钮。
        if !hasActivePlanToday {
            await reevaluateTodayPlan(reason: .firstEntryWithoutPlan, now: now)
            return
        }

        await synchronizeReminders(now: now)
    }

    private func analyzeAndStoreDraft(for document: StudyDocument, content: String, kind: DocumentKind) async throws {
        guard snapshot.settings.allowModelRequests else {
            statusMessage = "已关闭 AI 请求：资料已保存，未发送给模型分析"
            return
        }
        guard isAIConnectionReady else {
            statusMessage = "当前 AI 服务尚未就绪：资料已保存，请在设置中补全连接配置。"
            return
        }
        let chunks = makeAnalysisChunks(from: content)
        statusMessage = "正在准备分析：\(document.title)"
        let client = try makeClient()

        var payloads: [AIAnalysisPayload] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            statusMessage = chunks.count == 1
                ? "正在分析：\(document.title)"
                : "正在分析 \(index + 1)/\(chunks.count)：\(document.title)"
            let result = try await client.analyze(content: chunk, kind: kind)
            recordUsage(result.usage, pricing: client.pricing)
            payloads.append(result.payload)
        }
        let mergedPayload = mergeAnalysisPayloads(payloads)
        var draft = makeDraft(from: mergedPayload, sourceDocumentID: document.id)
        if chunks.count > 1 {
            draft.summary += "\n\n（资料共 \(content.count) 字符，已分 \(chunks.count) 块完整分析。）"
        }
        snapshot.drafts.insert(draft, at: 0)
        selectedDraftID = draft.id
        guard save() else { return }
        statusMessage = "分析完成，等待你确认"
    }

    private func makeAnalysisChunks(from content: String) -> [String] {
        let chunkSize = min(max(snapshot.settings.maxAnalysisChunkCharacters, 2_000), 24_000)
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [""] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    private func mergeAnalysisPayloads(_ payloads: [AIAnalysisPayload]) -> AIAnalysisPayload {
        guard !payloads.isEmpty else {
            return AIAnalysisPayload(summary: "暂无分析结果。", knowledgePoints: [], mistakes: [], reviewItems: [])
        }

        var knowledgeByTitle: [String: AIKnowledgePoint] = [:]
        var mistakesByQuestion: [String: AIMistake] = [:]
        var reviewItemsByTitle: [String: AIReviewItem] = [:]

        for payload in payloads {
            for point in payload.knowledgePoints where !point.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let existing = knowledgeByTitle[point.title] {
                    knowledgeByTitle[point.title] = AIKnowledgePoint(
                        title: point.title,
                        subject: point.subject ?? existing.subject,
                        summary: [existing.summary, point.summary].filter { !$0.isEmpty }.joined(separator: "；"),
                        mastery: min(existing.mastery ?? 0.4, point.mastery ?? 0.4)
                    )
                } else {
                    knowledgeByTitle[point.title] = point
                }
            }
            for mistake in payload.mistakes where !mistake.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mistakesByQuestion[mistake.question] = mistake
            }
            for item in payload.reviewItems where !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reviewItemsByTitle[item.title] = item
            }
        }

        let summary = payloads
            .map(\.summary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return AIAnalysisPayload(
            summary: summary.isEmpty ? "已完成分块分析。" : summary,
            knowledgePoints: Array(knowledgeByTitle.values).sorted { $0.title < $1.title },
            mistakes: Array(mistakesByQuestion.values).sorted { $0.question < $1.question },
            reviewItems: Array(reviewItemsByTitle.values).sorted { ($0.dueInDays ?? 1) < ($1.dueInDays ?? 1) }
        )
    }

    private func makeDraft(from payload: AIAnalysisPayload, sourceDocumentID: UUID) -> AnalysisDraft {
        let knowledgePoints = payload.knowledgePoints.map {
            DraftKnowledgePoint(
                title: $0.title,
                subject: $0.subject ?? "未分类",
                summary: $0.summary,
                mastery: min(max($0.mastery ?? 0.4, 0), 1)
            )
        }

        let mistakes = payload.mistakes.map {
            DraftMistake(
                question: $0.question,
                correctAnswer: $0.correctAnswer ?? "待补充",
                errorReason: $0.errorReason,
                relatedKnowledgeTitles: $0.relatedKnowledgeTitles ?? []
            )
        }

        let reviewItems = payload.reviewItems.map {
            DraftReviewItem(
                title: $0.title,
                dueInDays: max($0.dueInDays ?? 1, 0),
                relatedKnowledgeTitle: $0.relatedKnowledgeTitle,
                relatedMistakeTitle: $0.relatedMistakeTitle,
                relatedMistakeID: relatedDraftMistakeID(for: $0.relatedMistakeTitle, in: mistakes)
            )
        }

        return AnalysisDraft(
            sourceDocumentID: sourceDocumentID,
            summary: payload.summary,
            knowledgePoints: knowledgePoints,
            mistakes: mistakes,
            reviewItems: reviewItems
        )
    }

    private func relatedDraftMistakeID(for title: String?, in mistakes: [DraftMistake]) -> UUID? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        let normalizedTitle = normalizedDraftReference(title)
        return mistakes.first { mistake in
            let normalizedQuestion = normalizedDraftReference(mistake.question)
            return normalizedQuestion == normalizedTitle
                || normalizedQuestion.contains(normalizedTitle)
                || normalizedTitle.contains(normalizedQuestion)
        }?.id
    }

    private func normalizedDraftReference(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private func runBusy(
        _ message: String,
        showsChatResponseOnRefusal: Bool = false,
        operation: @escaping () async throws -> Void
    ) async {
        isBusy = true
        activeAIRequestTitle = message
        statusMessage = message
        defer {
            isBusy = false
            activeAIRequestTitle = ""
        }
        do {
            try Task.checkCancellation()
            try await operation()
        } catch is CancellationError {
            statusMessage = "已取消当前 AI 请求"
        } catch let refusal as AIModelRefusal {
            recordAIRefusalUsage(refusal)
            statusMessage = refusal.errorDescription ?? "当前 AI 服务拒绝了请求。"
            recordEvent(.warning, statusMessage, shouldSave: false)
            if showsChatResponseOnRefusal {
                chatAnswer = refusal.message
                if snapshot.chatMessages.last?.role == .user {
                    snapshot.chatMessages.append(ChatHistoryMessage(role: .assistant, content: refusal.message))
                    save()
                }
            }
        } catch {
            statusMessage = error.localizedDescription
            recordEvent(.error, error.localizedDescription)
        }
    }

    private func startAIRequest(_ title: String, operation: @escaping () async -> Void) {
        activeAIRequestTask?.cancel()
        activeAIRequestTitle = title
        activeAIRequestTask = Task { [weak self] in
            await operation()
            await MainActor.run {
                if self?.activeAIRequestTask?.isCancelled == false {
                    self?.activeAIRequestTask = nil
                } else if self?.activeAIRequestTask != nil {
                    self?.activeAIRequestTask = nil
                }
            }
        }
    }

    private func load() {
        guard let persistence else {
            statusMessage = "无法创建本地存储：\(environment.storeLocation.directory.path)"
            recordEvent(.error, "无法创建本地存储目录：\(environment.storeLocation.directory.path)", shouldSave: false)
            return
        }
        do {
            guard let loaded = try persistence.loadWithReport() else {
                // 首次启动：保持空快照。隔离目录会记录来源，便于确认没有碰到真实数据。
                if environment.isIsolatedStore {
                    recordEvent(.info, "使用隔离数据目录：\(environment.storeLocationOrigin)", shouldSave: false)
                }
                return
            }
            // 版本归一由存储层的迁移完成，这里不再手工改 schemaVersion。
            snapshot = loaded.snapshot
            if !loaded.report.isNoOp {
                let steps = loaded.report.appliedSteps.joined(separator: "、")
                recordEvent(
                    .info,
                    "本地数据已迁移：v\(loaded.report.fromVersion) → v\(loaded.report.toVersion)（\(steps)）",
                    shouldSave: false
                )
            }
            // 只在内存里滚动 AI 计划，不写盘。
            refreshIterativeAIPlans(updateStatus: false)
            // 重启后如果还有有效会话（例如崩溃），恢复心跳，并把中断交给用户确认。
            refreshSessionHeartbeat()
        } catch {
            statusMessage = "读取本地数据失败：\(error.localizedDescription)"
            recordEvent(.error, "读取本地数据失败：\(error.localizedDescription)", shouldSave: false)
        }
    }

    /// 保存当前内存快照（旧写入路径的统一收口）。
    ///
    /// 语义（需求 8/10）：
    /// - 存储对象不存在 → **明确失败**，绝不用 `try?` 跳过保存还返回成功；
    /// - 写盘失败 → 回滚内存到上一次成功落盘的状态，并给出可理解的原因；
    /// - 返回 `false` 时调用方不得再提示成功、不得发通知。
    @discardableResult
    private func save() -> Bool {
        persist(snapshot, rollbackOnFailure: true)
    }

    /// 统一的落盘实现。
    ///
    /// - Parameter rollbackOnFailure: 旧路径（先在内存里改）失败时必须回滚；
    ///   统一提交路径传入 `false`（候选快照是副本，失败时内存本来就没变）。
    @discardableResult
    private func persist(_ candidate: StoreSnapshot, rollbackOnFailure: Bool) -> Bool {
        let normalized = candidate.normalizedToCurrentSchema()

        guard let persistence else {
            let reason = persistenceInitializationError ?? "本地存储不可用"
            if rollbackOnFailure { snapshot = lastPersistedSnapshot }
            lastWriteFailure = WriteFailure(
                reason: reason,
                path: environment.storeLocation.storeURL.path,
                isRetryable: false
            )
            statusMessage = "保存失败，本次修改未生效：\(reason)"
            recordEvent(.error, "写入被拒绝（存储不可用）：\(reason)", shouldSave: false)
            return false
        }

        do {
            try persistence.save(normalized)
            lastPersistedSnapshot = normalized
            lastWriteFailure = nil
            return true
        } catch {
            let reason = SnapshotFileStore.describe(error)
            if rollbackOnFailure { snapshot = lastPersistedSnapshot }
            lastWriteFailure = WriteFailure(reason: reason, path: persistence.storeURL.path, isRetryable: true)
            statusMessage = "保存失败，本次修改未生效：\(reason)"
            recordEvent(.error, "保存失败：\(reason)", shouldSave: false)
            return false
        }
    }

    // MARK: - 统一提交入口（状态提交顺序）
    //
    // 1. 由协调器/调用方基于当前快照计算新状态；
    // 2. 新状态里同时包含会话、完成事件、计划与奖励资格；
    // 3. 先把**完整快照**写盘；写盘失败 → 界面不得提示成功，也不改内存状态；
    // 4. 写盘成功后更新界面并给出成功提示；
    // 5. 再同步系统通知；
    // 6. 通知失败单独记录为诊断事件，**不回滚**已经保存的学习/奖励记录。

    @discardableResult
    func commit(
        _ candidate: StoreSnapshot,
        status: String,
        reminderChanges: [ReminderChangeRequest] = [],
        now: Date = Date()
    ) async -> Bool {
        // 落盘与内存发布是同步完成的（在任何 await 之前），
        // 因此 macOS 多窗口并发提交同一份状态时不会互相覆盖。
        guard persistAndPublish(candidate, status: status) else { return false }
        await applyReminderChanges(reminderChanges, now: now)
        return true
    }

    /// 同步部分：归一化 → 写盘 → 成功后发布内存状态。失败时不改内存状态。
    @discardableResult
    private func persistAndPublish(_ candidate: StoreSnapshot, status: String) -> Bool {
        let normalized = candidate.normalizedToCurrentSchema()
        guard persist(normalized, rollbackOnFailure: false) else { return false }
        snapshot = normalized
        refreshAIConnectionCredentialIfNeeded()
        if !status.isEmpty {
            statusMessage = status
        }
        return true
    }

    private func refreshAIConnectionCredentialIfNeeded() {
        let configuration = AIConnectionConfiguration(settings: snapshot.settings)
        guard configuration.credentialScope != activeCredentialScope else { return }
        activeCredentialScope = configuration.credentialScope
        apiKey = keychainStore.loadAPIKey(for: configuration, allowLegacyFallback: false)
        settingsDraftAPIKey = apiKey
    }

    func loadAPIKey(for configuration: AIConnectionConfiguration) -> String {
        keychainStore.loadAPIKey(for: configuration, allowLegacyFallback: false)
    }

    /// 应用协调器产出的通知意图。失败只记录，不影响已提交的数据。
    private func applyReminderChanges(_ changes: [ReminderChangeRequest], now: Date) async {
        guard !changes.isEmpty else { return }
        let report = await NotificationScheduler.apply(changes, environment: environment, now: now)
        for failure in report.failures {
            recordEvent(.warning, "通知安排失败（\(failure.identifier)）：\(failure.reason)", shouldSave: false)
        }
    }

    /// 一次计划动作的完整结果：协调器结果 + **实际提交结果**。
    ///
    /// 需求：调用方必须能区分"算出来了"和"真的保存了"。
    /// `didPersist == false` 时界面不得显示已完成/已领取，也不得关闭编辑界面。
    struct PlanActionOutcome {
        var coordination: PlanCoordinationResult
        /// 是否真的写盘成功。
        var didPersist: Bool
        /// 存储当前是否可用（不可用时重试也没用，需要先修目录权限）。
        var isStorageAvailable: Bool
        /// 失败原因（成功时为 `nil`）。
        var errorMessage: String?

        var didChange: Bool { coordination.didChange }
        var statusMessage: String { coordination.statusMessage }
        var rejection: PlanCoordinationRejection? { coordination.rejection }
        var reminderChanges: [ReminderChangeRequest] { coordination.reminderChanges }
        /// 只有真正落盘后才允许界面使用的新状态。
        var persistedSnapshot: StoreSnapshot? { didPersist ? coordination.snapshot : nil }
    }

    /// 统一的计划动作入口：生成/刷新计划、开始/暂停/恢复学习、提交/撤销完成、
    /// 减量、领取/开始/结束娱乐。所有写入最终都经过 `commit`。
    @discardableResult
    func performPlanAction(_ event: PlanCoordinationEvent, now: Date = Date()) async -> PlanActionOutcome {
        let context = snapshot.planningContext(now: now)
        let result = coordinator.coordinate(event, state: snapshot, context: context)

        if let rejection = result.rejection {
            statusMessage = rejection.message
            return PlanActionOutcome(
                coordination: result,
                didPersist: false,
                isStorageAvailable: isStorageAvailable,
                errorMessage: rejection.message
            )
        }

        guard result.didChange else {
            if !result.statusMessage.isEmpty {
                statusMessage = result.statusMessage
            }
            return PlanActionOutcome(
                coordination: result,
                didPersist: false,
                isStorageAvailable: isStorageAvailable,
                errorMessage: nil
            )
        }

        // 需求 9：完成事件、计划状态、奖励资格与打卡统计在同一次提交里落盘。
        // 只要这次动作真的插入了完成事件，就把当日打卡一起写进同一份候选快照，
        // 不会出现"完成记录已保存、打卡另存失败"的分裂状态。
        var candidate = result.snapshot
        var status = result.statusMessage
        if result.mutations.contains(where: { $0.kind == .insertCompletion }) {
            let activity = Self.applyingDailyActivity(to: &candidate, at: now)
            if activity.didCheckInToday {
                checkInCelebrationTrigger += 1
            }
            status += checkInStatusSuffix(for: activity)
        }

        let saved = await commit(
            candidate,
            status: status,
            reminderChanges: result.reminderChanges,
            now: now
        )
        guard saved else {
            // 保存失败：不发布成功状态、不发通知，把失败原因原样交给调用方。
            return PlanActionOutcome(
                coordination: result,
                didPersist: false,
                isStorageAvailable: isStorageAvailable,
                errorMessage: lastWriteFailure?.reason ?? "保存失败"
            )
        }
        lastActiveDayKey = context.todayKey
        refreshSessionHeartbeat()
        return PlanActionOutcome(
            coordination: result,
            didPersist: true,
            isStorageAvailable: true,
            errorMessage: nil
        )
    }

    /// 生成或刷新今日计划。
    @discardableResult
    func regenerateTodayPlan(force: Bool = false, now: Date = Date()) async -> PlanActionOutcome {
        let context = snapshot.planningContext(now: now)
        return await performPlanAction(.regeneratePlan(dayKey: context.todayKey, force: force), now: now)
    }

    /// 开始 / 暂停 / 恢复 / 结束学习会话。
    @discardableResult
    func startStudySession(planItemID: UUID, now: Date = Date()) async -> PlanActionOutcome {
        await performPlanAction(.startSession(planItemID: planItemID), now: now)
    }

    @discardableResult
    func pauseStudySession(sessionID: UUID, now: Date = Date()) async -> PlanActionOutcome {
        await performPlanAction(.pauseSession(sessionID: sessionID), now: now)
    }

    @discardableResult
    func resumeStudySession(sessionID: UUID, now: Date = Date()) async -> PlanActionOutcome {
        await performPlanAction(.resumeSession(sessionID: sessionID), now: now)
    }

    @discardableResult
    func finishStudySession(
        sessionID: UUID,
        scope: StudyScope?,
        assessment: StudyAssessment? = nil,
        note: String = "",
        now: Date = Date()
    ) async -> PlanActionOutcome {
        await performPlanAction(.finishSession(sessionID: sessionID, scope: scope, assessment: assessment, note: note), now: now)
    }

    /// 直接完成一个计划项（界面上的"完成"按钮）。
    @discardableResult
    func completePlanItem(
        planItemID: UUID,
        scope: StudyScope,
        minutes: Int,
        assessment: StudyAssessment? = nil,
        note: String = "",
        now: Date = Date()
    ) async -> PlanActionOutcome {
        await performPlanAction(
            .completeItemDirectly(planItemID: planItemID, scope: scope, minutes: minutes, assessment: assessment, note: note),
            now: now
        )
    }

    /// 撤销一次完成记录（保留历史，只写撤销信息）。
    @discardableResult
    func revokeCompletion(completionID: UUID, reason: String, now: Date = Date()) async -> PlanActionOutcome {
        await performPlanAction(.revokeCompletion(completionID: completionID, reason: reason), now: now)
    }

    // MARK: - 减量预览 / 应用 / 撤销（需求 2、4、5）
    //
    // 预览与应用走**同一条**计算路径：同一份策略配置、同一份剩余容量口径、
    // 同一个计划版本。这样不会出现"预览是保底、应用成轻量"。

    /// 一次减量预览：容量口径 + 策略提案 + 计划版本 + 娱乐影响。
    struct MinimumPlanPreview {
        var capacity: StudyRemainingCapacity
        var proposal: MinimumPlanProposal
        /// 预览所依据的计划身份与版本（应用时用于拒绝过期预览）。
        var planID: UUID
        var planVersion: Int
        var dayKey: StudyDayKey
        /// E 的娱乐影响预估（没接入或无规则时为空）。
        var entertainmentImpact: [EntertainmentReductionImpact]
        var ruleNames: [UUID: String]

        var isRestSuggestion: Bool { proposal.isRestSuggestion }
        /// 展示用：预览档位（与应用后的档位一致）。
        var mode: DailyPlanMode {
            proposal.isRestSuggestion ? .rest : proposal.plan.mode
        }
    }

    /// 今天的可用容量（统一口径：连续空档 + 每日剩余额度）。
    func remainingCapacity(for dayKey: StudyDayKey? = nil, now: Date = Date()) -> StudyRemainingCapacity {
        let context = snapshot.planningContext(now: now)
        let target = dayKey ?? context.todayKey
        let schedule = snapshot.scheduleForComputation
        let availability = AvailabilityCalculator.availability(
            on: target.startOfDay(calendar: context.calendar) ?? context.now,
            schedule: schedule,
            preferences: snapshot.availabilityPreferences,
            now: context.now
        )
        return StudyCapacityPlanner.remainingCapacity(
            state: snapshot,
            availability: availability,
            context: context,
            minimumUsefulMinutes: StudyEngineRegistry.minimumPlanConfiguration(for: snapshot).minimumUsefulMinutes
        )
    }

    /// 生成减量预览。界面只负责展示，不自己算方案。
    func minimumPlanPreview(now: Date = Date()) -> MinimumPlanPreview? {
        let context = snapshot.planningContext(now: now)
        let dayKey = context.todayKey
        guard let plan = StudyPlanCoordinator.activePlan(in: snapshot, dayKey: dayKey) else { return nil }

        guard let policy = StudyEngineRegistry.makeMinimumPlanPolicy(for: snapshot, isManual: true) else {
            return nil
        }
        let capacity = remainingCapacity(for: dayKey, now: now)
        let splittable = Set(plan.items.filter(\.isSplittable).map(\.id))
        let proposal = policy.reduce(
            plan: plan,
            remainingMinutes: capacity.effectiveMinutes,
            splittableItemIDs: splittable,
            context: context
        )

        let rules = snapshot.entitlementRules(on: dayKey)
        let impacts = EntertainmentRewardImpactAdvisor.impacts(
            rules: rules,
            plan: plan,
            minimumPlan: proposal.plan,
            completions: snapshot.completionEvents,
            summary: snapshot.dailySummary(for: dayKey),
            context: context
        )
        var names: [UUID: String] = [:]
        for rule in rules { names[rule.id] = rule.name }

        return MinimumPlanPreview(
            capacity: capacity,
            proposal: proposal,
            planID: plan.id,
            planVersion: plan.version,
            dayKey: dayKey,
            entertainmentImpact: impacts,
            ruleNames: names
        )
    }

    /// 应用减量方案（带预览版本校验）。
    @discardableResult
    func applyMinimumPlan(
        remainingMinutes: Int? = nil,
        expectedPlanID: UUID? = nil,
        expectedVersion: Int? = nil,
        now: Date = Date()
    ) async -> PlanActionOutcome {
        let context = snapshot.planningContext(now: now)
        // 没有显式传剩余时间时，用统一口径的容量（与预览一致）。
        let minutes = remainingMinutes ?? remainingCapacity(for: context.todayKey, now: now).effectiveMinutes
        let result = coordinator.coordinate(
            .applyMinimumPlan(
                dayKey: context.todayKey,
                remainingMinutes: minutes,
                expectedPlanID: expectedPlanID,
                expectedVersion: expectedVersion
            ),
            state: snapshot,
            context: context
        )
        return await commitPlanResult(
            result,
            expectedPlanID: expectedPlanID,
            expectedVersion: expectedVersion,
            minutes: minutes,
            now: now
        )
    }

    /// 走协调器的减量路径（带预览版本校验），再统一提交。
    private func commitPlanResult(
        _ result: PlanCoordinationResult,
        expectedPlanID: UUID?,
        expectedVersion: Int?,
        minutes: Int,
        now: Date
    ) async -> PlanActionOutcome {
        // 版本校验由协调器的 reduceToMinimum 负责；这里只需按结果提交。
        _ = (expectedPlanID, expectedVersion, minutes)
        if let rejection = result.rejection {
            statusMessage = rejection.message
            return PlanActionOutcome(coordination: result, didPersist: false, isStorageAvailable: isStorageAvailable, errorMessage: rejection.message)
        }
        guard result.didChange else {
            if !result.statusMessage.isEmpty { statusMessage = result.statusMessage }
            return PlanActionOutcome(coordination: result, didPersist: false, isStorageAvailable: isStorageAvailable, errorMessage: nil)
        }
        let saved = await commit(
            result.snapshot,
            status: result.statusMessage,
            reminderChanges: result.reminderChanges,
            now: now
        )
        guard saved else {
            return PlanActionOutcome(coordination: result, didPersist: false, isStorageAvailable: isStorageAvailable, errorMessage: lastWriteFailure?.reason ?? "保存失败")
        }
        refreshSessionHeartbeat()
        return PlanActionOutcome(coordination: result, didPersist: true, isStorageAvailable: true, errorMessage: nil)
    }

    /// 带版本校验的应用（界面在拿到预览后调用）。
    @discardableResult
    func applyMinimumPlan(preview: MinimumPlanPreview, now: Date = Date()) async -> PlanActionOutcome {
        let context = snapshot.planningContext(now: now)
        let result = coordinator.coordinate(
            .applyMinimumPlan(
                dayKey: preview.dayKey,
                remainingMinutes: preview.capacity.effectiveMinutes,
                expectedPlanID: preview.planID,
                expectedVersion: preview.planVersion
            ),
            state: snapshot,
            context: context
        )
        return await commitPlanResult(
            result,
            expectedPlanID: preview.planID,
            expectedVersion: preview.planVersion,
            minutes: preview.capacity.effectiveMinutes,
            now: now
        )
    }

    /// 撤销最近一次减量。
    @discardableResult
    func undoMinimumPlan(now: Date = Date()) async -> PlanActionOutcome {
        let context = snapshot.planningContext(now: now)
        let result = coordinator.coordinate(
            .undoMinimumPlan(dayKey: context.todayKey),
            state: snapshot,
            context: context
        )
        return await commitPlanResult(
            result,
            expectedPlanID: nil,
            expectedVersion: nil,
            minutes: 0,
            now: now
        )
    }

    /// 当前计划是否有明确且仍然有效的减量恢复目标。
    var canUndoMinimumPlan: Bool {
        guard let plan = todayPlan,
              plan.isUndoableReduction,
              let targetID = plan.reductionUndoTargetPlanID,
              let target = snapshot.dailyPlans.first(where: { $0.id == targetID }) else { return false }
        return target.dayKey == plan.dayKey
            && target.status == .superseded
            && target.version < plan.version
    }

    // MARK: - 奖励重评与娱乐结算（需求 7、8）

    /// 请求一次奖励重评（不阻塞调用方，用于保存类操作之后）。
    func requestRewardReevaluation(now: Date = Date()) {
        Task { await reevaluateRewards(now: now) }
    }

    /// 重新评估奖励资格并落盘（规则变化 / 删任务 / 撤销完成 / 减量 / 跨日后调用）。
    @discardableResult
    func reevaluateRewards(now: Date = Date()) async -> Bool {
        let context = snapshot.planningContext(now: now)
        let result = coordinator.coordinate(.refresh(dayKey: context.todayKey), state: snapshot, context: context)
        guard result.didChange else { return true }
        return await commit(result.snapshot, status: "", reminderChanges: [], now: now)
    }

    /// 娱乐状态结算：过期未使用的奖励标记过期、超时的计时结束。
    ///
    /// 在启动、返回前台、跨日时调用——不依赖用户进入设置页。
    @discardableResult
    func settleEntertainmentState(now: Date = Date()) async -> Bool {
        var candidate = snapshot
        var changed = false
        let context = snapshot.planningContext(now: now)

        // 计时已经超过奖励时长 → 自动结束，避免"永远在计时"。
        for index in candidate.rewardGrants.indices where candidate.rewardGrants[index].state == .started {
            let grant = candidate.rewardGrants[index]
            guard let startedAt = grant.startedAt else { continue }
            let used = context.minutes(from: startedAt, to: now)
            if used >= grant.grantedMinutes {
                candidate.rewardGrants[index].state = .finished
                candidate.rewardGrants[index].endedAt = now
                candidate.rewardGrants[index].usedMinutes = min(used, grant.grantedMinutes)
                changed = true
            }
        }

        if changed {
            guard await commit(candidate, status: "", reminderChanges: [], now: now) else { return false }
        }
        // 3) 结算后重评资格（撤销完成 / 删除任务 / 规则变化都会在这里收敛）。
        await reevaluateRewards(now: now)
        return true
    }

    // MARK: - 娱乐操作（首页 / 娱乐页 / 设置页统一入口）

    /// 一次娱乐只安排一次提醒；这里集中处理，页面不直接调通知。
    @discardableResult
    func performRewardOperation(
        _ operation: PlanCoordinationEvent,
        now: Date = Date()
    ) async -> PlanActionOutcome {
        await performPlanAction(operation, now: now)
    }

    // MARK: - 会话操作入口（放弃 / 进度 / 时长修正 / 中断确认 / 心跳）

    /// 放弃学习（与"暂停"不同：会话结束并记录原因，不产生完成事件）。
    @discardableResult
    func abandonStudySession(sessionID: UUID, reason: String = "用户主动放弃", now: Date = Date()) async -> PlanActionOutcome {
        await commitSessionOperation(
            coordinator.abandonSession(sessionID: sessionID, reason: reason, state: snapshot, context: snapshot.planningContext(now: now)),
            now: now
        )
    }

    /// 保存部分进度。
    @discardableResult
    func saveStudySessionProgress(sessionID: UUID, scope: StudyScope, now: Date = Date()) async -> PlanActionOutcome {
        await commitSessionOperation(
            coordinator.saveSessionProgress(sessionID: sessionID, scope: scope, state: snapshot, context: snapshot.planningContext(now: now)),
            now: now
        )
    }

    /// 手动修正时长（保留来源与原因）。
    @discardableResult
    func adjustStudySessionDuration(
        sessionID: UUID,
        targetMinutes: Int,
        reason: String,
        now: Date = Date()
    ) async -> PlanActionOutcome {
        await commitSessionOperation(
            coordinator.adjustSessionDuration(
                sessionID: sessionID,
                targetMinutes: targetMinutes,
                reason: reason,
                state: snapshot,
                context: snapshot.planningContext(now: now)
            ),
            now: now
        )
    }

    /// 确认中断期间是否在学。
    @discardableResult
    func resolveStudyInterruption(
        sessionID: UUID,
        studiedDuringGap: Bool,
        now: Date = Date()
    ) async -> PlanActionOutcome {
        await commitSessionOperation(
            coordinator.resolveInterruption(
                sessionID: sessionID,
                studiedDuringGap: studiedDuringGap,
                state: snapshot,
                context: snapshot.planningContext(now: now)
            ),
            now: now
        )
    }

    /// 会话类操作的统一提交：先落盘，成功后才发布状态与通知。
    @discardableResult
    private func commitSessionOperation(_ result: PlanCoordinationResult, now: Date) async -> PlanActionOutcome {
        if let rejection = result.rejection {
            statusMessage = rejection.message
            return PlanActionOutcome(coordination: result, didPersist: false, isStorageAvailable: isStorageAvailable, errorMessage: rejection.message)
        }
        guard result.didChange else {
            if !result.statusMessage.isEmpty { statusMessage = result.statusMessage }
            return PlanActionOutcome(coordination: result, didPersist: false, isStorageAvailable: isStorageAvailable, errorMessage: nil)
        }
        let saved = await commit(result.snapshot, status: result.statusMessage, reminderChanges: result.reminderChanges, now: now)
        guard saved else {
            return PlanActionOutcome(
                coordination: result,
                didPersist: false,
                isStorageAvailable: isStorageAvailable,
                errorMessage: lastWriteFailure?.reason ?? "保存失败"
            )
        }
        return PlanActionOutcome(coordination: result, didPersist: true, isStorageAvailable: true, errorMessage: nil)
    }

    /// 手动补记/修正一条已完成记录的时长（保留来源与原因）。
    ///
    /// 这是"未记录时长"的唯一补正入口：补记后来源变为「手动补记」，
    /// 会计入实际学习时长与时长类奖励；原因写进 `durationNote`。
    @discardableResult
    func recordManualDuration(
        completionID: UUID,
        minutes: Int,
        reason: String,
        now: Date = Date()
    ) async -> Bool {
        guard let index = snapshot.completionEvents.firstIndex(where: { $0.id == completionID }) else {
            statusMessage = "找不到这条完成记录。"
            return false
        }
        guard !snapshot.completionEvents[index].isRevoked else {
            statusMessage = "这条完成记录已经撤销，不能再补记时长。"
            return false
        }

        var candidate = snapshot
        let corrected = candidate.completionEvents[index].correctingDuration(
            to: max(0, minutes),
            source: .manualEntry,
            reason: reason
        )
        candidate.completionEvents[index] = corrected

        // 时长变化会改变时长类奖励资格：在同一次提交里重算。
        let dayKey = corrected.dayKey
        let refreshed = coordinator.coordinate(.refresh(dayKey: dayKey), state: candidate, context: snapshot.planningContext(now: now))
        let saved = await commit(
            refreshed.snapshot,
            status: "已把时长补记为 \(max(0, minutes)) 分钟（\(reason)）。",
            reminderChanges: [],
            now: now
        )
        guard saved else { return false }
        recordEvent(.info, "补记学习时长：\(max(0, minutes)) 分钟（\(reason)）")
        return true
    }

    // MARK: - 中断恢复与跨日遗留会话

    /// 今天正在进行的会话（首页计时区显示它）。
    var todayActiveSession: StudySession? {
        let context = snapshot.planningContext(now: Date())
        return snapshot.studySessions.first { $0.state.isActive && $0.dayKey == context.todayKey }
    }

    /// 昨天或更早遗留的、仍在进行中的会话。
    ///
    /// 它们**必须**可见可处理：既不能悄悄隐藏，也不能因为存在就阻止刷新（需求 6）。
    var staleActiveSessions: [StudySession] {
        let context = snapshot.planningContext(now: Date())
        return snapshot.studySessions
            .filter { $0.state.isActive && $0.dayKey != context.todayKey }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// 需要用户确认"中断期间是否学习"的会话（含跨日遗留的）。
    func sessionsAwaitingInterruptionDecision(now: Date = Date()) -> [(session: StudySession, interruption: StudySessionInterruption)] {
        let context = snapshot.planningContext(now: now)
        let engine = StudySessionEngineImpl()
        return snapshot.studySessions
            .filter { $0.state.isActive }
            .compactMap { session in
                engine.interruptionCandidate(for: session, context: context).map { (session, $0) }
            }
            .sorted { $0.interruption.gapSeconds > $1.interruption.gapSeconds }
    }

    /// 按当前是否存在有效会话，启动/停止进程内心跳。
    func refreshSessionHeartbeat() {
        let hasActiveSession = snapshot.studySessions.contains { $0.state.isActive }
        guard hasActiveSession else {
            sessionHeartbeatTask?.cancel()
            sessionHeartbeatTask = nil
            return
        }
        guard sessionHeartbeatTask == nil else { return }
        let interval = sessionHeartbeatIntervalSeconds
        sessionHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.touchSessionHeartbeat()
            }
        }
    }

    /// 只改内存的心跳：让"我们一直在前台看着这段计时"成为事实。
    private func touchSessionHeartbeat() {
        let now = Date()
        var changed = false
        for index in snapshot.studySessions.indices where snapshot.studySessions[index].state.isActive {
            snapshot.studySessions[index].updatedAt = now
            changed = true
        }
        if !changed {
            refreshSessionHeartbeat()
        }
    }

    /// 记录一次"进程仍然活着"的心跳。
    ///
    /// 切后台/失活时调用：把 `updatedAt` 推进到现在，这样崩溃或重启后
    /// 未知离线时间只会从最后一次心跳开始算，而不会把整段都当成学习时间。
    func markSessionHeartbeat(now: Date = Date()) {
        let active = snapshot.studySessions.filter { $0.state.isActive }
        guard !active.isEmpty else { return }
        var candidate = snapshot
        var changed = false
        for index in candidate.studySessions.indices where candidate.studySessions[index].state.isActive {
            candidate.studySessions[index].updatedAt = now
            changed = true
        }
        guard changed else { return }
        // 心跳失败不打断用户：只记录，等下一次真实写入时一并落盘。
        if persistAndPublish(candidate, status: "") {
            snapshot = candidate
        }
    }

    /// 结束一条跨日遗留会话：按**它自己的学习日**归档，不会给今天重复发奖。
    @discardableResult
    func finishStaleSession(sessionID: UUID, now: Date = Date()) async -> PlanActionOutcome {
        guard let session = snapshot.studySessions.first(where: { $0.id == sessionID }) else {
            let failure = PlanCoordinationResult(
                snapshot: snapshot,
                statusMessage: "找不到这条会话。",
                didChange: false,
                rejection: .unknownSession(sessionID)
            )
            return PlanActionOutcome(coordination: failure, didPersist: false, isStorageAvailable: isStorageAvailable, errorMessage: failure.statusMessage)
        }
        let context = snapshot.planningContext(now: now)
        // 完成事件归属会话原本的学习日：奖励按那一天结算，不与今天混算。
        let closingContext = PlanningContext(
            now: context.now,
            timeZone: session.dayKey.timeZone,
            locale: context.locale
        )
        return await performPlanAction(
            .finishSession(sessionID: sessionID, scope: session.progress.isPositive ? session.progress : nil, assessment: nil, note: "跨日遗留会话，用户手动结束"),
            now: closingContext.now
        )
    }

    // MARK: - 旧业务完成入口（复习列表 / 错题页）
    //
    // 所有完成入口都走同一份完成事件；"完整复习"才按原规则进入 SM-2，
    // "部分练习"不会被当成完整成功复习。

    /// 复习列表：完成一次复习并给出评分。
    func rateReview(_ task: ReviewTask, quality: ReviewPlanner.Quality) {
        Task { await completeReview(task, quality: quality) }
    }

    /// 兼容入口：与 `rateReview(.good)` 等价。
    func markDone(_ task: ReviewTask) {
        rateReview(task, quality: .good)
    }

    /// 完成一次复习（可直接 await，便于测试与明确的成功/失败处理）。
    @discardableResult
    func completeReview(
        _ task: ReviewTask,
        quality: ReviewPlanner.Quality,
        now: Date = Date()
    ) async -> PlanActionOutcome {
        let context = snapshot.planningContext(now: now)
        let dayKey = context.todayKey
        let ratio = snapshot.availabilityPreferences.planning.minimumScopeRatio

        // 复习列表是"不计时的直接完成"：**不能**把预计耗时写成实际学习时间。
        // 时长按"未记录"落库，任务仍然算完成，但不贡献任何时长类奖励（需求 1）。
        let result = coordinator.completeDirect(
            key: StudyCompletionKey.reviewTask(task.id, dayKey: dayKey),
            dayKey: dayKey,
            source: .reviewTask(task.id, knowledgePointID: task.knowledgePointID),
            plannedScope: .tasks(1),
            minimumScope: .tasks(ratio),
            completedScope: .tasks(1),
            minutes: 0,
            durationSource: .unrecorded,
            durationNote: "复习列表直接标记完成，未计时；预计 \(PlanCandidateBuilder.defaultReviewTaskMinutes) 分钟仅为安排用估算。",
            assessment: StudyAssessment(selfRating: quality.rawValue),
            note: "",
            state: snapshot,
            context: context,
            successMessage: "\(quality.shortLabel) — 已记录本次复习（未计时）"
        )

        if let rejection = result.rejection {
            statusMessage = rejection.message
            return PlanActionOutcome(coordination: result, didPersist: false, isStorageAvailable: isStorageAvailable, errorMessage: rejection.message)
        }

        // 完成事件 + 打卡 + 计划状态 + 奖励资格：一次提交、一份完整快照（需求 9）。
        var candidate = result.snapshot
        let activity = Self.applyingDailyActivity(to: &candidate, at: now)
        if activity.didCheckInToday {
            checkInCelebrationTrigger += 1
        }

        let saved = await commit(
            candidate,
            status: result.statusMessage + checkInStatusSuffix(for: activity),
            reminderChanges: result.reminderChanges,
            now: now
        )
        guard saved else {
            return PlanActionOutcome(coordination: result, didPersist: false, isStorageAvailable: isStorageAvailable, errorMessage: lastWriteFailure?.reason ?? "保存失败")
        }
        return PlanActionOutcome(coordination: result, didPersist: true, isStorageAvailable: true, errorMessage: nil)
    }

    /// 错题页：完成一次错题。
    ///
    /// 保留原有语义（这是用户可见的旧行为，不能改）：
    /// - 关联的复习任务标记为已完成，并记录本次复习评分与时间；
    /// - 该错题从错题列表移除；
    /// - 取消这些任务的本地提醒，并记一次当日打卡。
    ///
    /// 新增强化：同一份动作还会写入统一的完成事件（可追溯、可撤销、可参与奖励评估）。
    func completeMistake(_ mistake: Mistake) {
        Task { await performMistakeCompletion(mistake) }
    }

    private func performMistakeCompletion(_ mistake: Mistake, now: Date = Date()) async {
        let context = snapshot.planningContext(now: now)
        let dayKey = context.todayKey
        let ratio = snapshot.availabilityPreferences.planning.minimumScopeRatio
        let linkedTaskIDs = linkedReviewTaskIDs(for: mistake)

        // 错题页同样是"直接完成、不计时"：时长为 0 且来源为未记录。
        let result = coordinator.completeDirect(
            key: StudyCompletionKey.mistake(mistake.id, dayKey: dayKey),
            dayKey: dayKey,
            source: DailyPlanItemSource(kind: .manual, manualNote: "错题练习：\(ReviewPlanner.shortTitle(mistake.question))"),
            plannedScope: .tasks(1),
            minimumScope: .tasks(ratio),
            completedScope: .tasks(1),
            minutes: 0,
            durationSource: .unrecorded,
            durationNote: "错题页直接标记完成，未计时。",
            assessment: nil,
            note: "错题练习",
            state: snapshot,
            context: context,
            successMessage: "已完成错题：\(ReviewPlanner.shortTitle(mistake.question))"
        )

        if let rejection = result.rejection {
            statusMessage = rejection.message
            return
        }

        // 原有可见语义：关联复习任务完成 + 错题出列。
        var candidate = result.snapshot
        for index in candidate.reviewTasks.indices where linkedTaskIDs.contains(candidate.reviewTasks[index].id) {
            candidate.reviewTasks[index].status = .done
            candidate.reviewTasks[index].lastQuality = ReviewPlanner.Quality.good.rawValue
            candidate.reviewTasks[index].lastReviewedAt = now
        }
        candidate.mistakes.removeAll { $0.id == mistake.id }

        // 打卡与完成事件同一次提交（需求 9）。
        let activity = Self.applyingDailyActivity(to: &candidate, at: now)
        if activity.didCheckInToday {
            checkInCelebrationTrigger += 1
        }

        let saved = await commit(
            candidate,
            status: result.statusMessage + checkInStatusSuffix(for: activity),
            reminderChanges: result.reminderChanges,
            now: now
        )
        guard saved else { return }

        requestReminderSync()
        recordEvent(.info, "完成错题：\(ReviewPlanner.shortTitle(mistake.question))")
    }

    func recordAIRefusalUsage(_ refusal: AIModelRefusal) {
        recordUsage(refusal.usage, pricing: refusal.pricing)
    }

    private func recordUsage(_ usage: AIUsage?, pricing: AIUsagePricing) {
        guard let usage else { return }
        snapshot.usageStats.requestCount += 1
        snapshot.usageStats.inputTokens += usage.inputTokens
        snapshot.usageStats.outputTokens += usage.outputTokens
        snapshot.usageStats.estimatedCost +=
            Double(usage.inputTokens) / 1_000_000 * pricing.inputPerMillion +
            Double(usage.outputTokens) / 1_000_000 * pricing.outputPerMillion
        snapshot.usageStats.lastUpdated = Date()
        guard save() else { return }
    }

    private func makeMarkdownExport() -> String {
        var lines: [String] = [
            "# 学习助手数据导出",
            "",
            "- 导出时间：\(Date().formatted(date: .abbreviated, time: .shortened))",
            "- 资料：\(snapshot.documents.count)",
            "- 考试目标：\(snapshot.examGoals.filter { !$0.isArchived }.count)",
            "- 知识点：\(snapshot.knowledgePoints.count)",
            "- 错题：\(snapshot.mistakes.count)",
            "- 复习任务：\(snapshot.reviewTasks.count)",
            "",
            "## 考试目标"
        ]

        let activeGoals = snapshot.activeExamGoals()
        if activeGoals.isEmpty {
            lines.append("暂无考试目标。")
        } else {
            for goal in activeGoals {
                lines.append("- \(goal.promptSummary())")
            }
        }

        lines.append(contentsOf: [
            "",
            "## 知识点"
        ])

        if snapshot.knowledgePoints.isEmpty {
            lines.append("暂无知识点。")
        } else {
            for item in snapshot.knowledgePoints {
                lines.append(contentsOf: [
                    "",
                    "### \(item.title)",
                    "- 学科：\(item.subject)",
                    "- 掌握度：\(Int(item.mastery * 100))%",
                    "",
                    item.summary
                ])
            }
        }

        lines.append(contentsOf: ["", "## 错题"])
        if snapshot.mistakes.isEmpty {
            lines.append("暂无错题。")
        } else {
            for item in snapshot.mistakes {
                lines.append(contentsOf: [
                    "",
                    "### \(item.question)",
                    "- 正确答案：\(item.correctAnswer)",
                    "- 错因：\(item.errorReason)"
                ])
            }
        }

        lines.append(contentsOf: ["", "## 复习计划"])
        if snapshot.reviewTasks.isEmpty {
            lines.append("暂无复习任务。")
        } else {
            for task in snapshot.reviewTasks.sorted(by: { $0.dueDate < $1.dueDate }) {
                lines.append("- \(task.title)：\(task.status.rawValue)，\(task.dueDate.formatted(date: .abbreviated, time: .shortened))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func makeAnkiTSVExport() -> String {
        var lines: [String] = [
            "# Anki 导出 — 学习助手",
            "# 每行格式：Front<Tab>Back<Tab>Tags",
            "# 第一行是列标题，Anki 导入时选\"分隔符：制表符\"，勾选\"允许字段中使用 HTML\"",
            "",
            "#separator:tab",
            "#html:true",
            "Front\tBack\tTags"
        ]

        for item in snapshot.mistakes {
            let front = escapeTSV("\(item.question)")
            let back = escapeTSV("<b>正确答案：</b>\(item.correctAnswer)<br><br><b>错因分析：</b>\(item.errorReason)")
            let subjectTags = item.knowledgePointIDs.compactMap { id in
                snapshot.knowledgePoints.first { $0.id == id }?.subject
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            let allTags = (["学习助手_错题"] + Array(Set(subjectTags)).sorted())
                .map { $0.replacingOccurrences(of: " ", with: "_") }
                .joined(separator: " ")
            lines.append("\(front)\t\(back)\t\(allTags)")
        }

        for item in snapshot.knowledgePoints {
            let front = escapeTSV("\(item.subject)：\(item.title)")
            let back = escapeTSV("\(item.summary)<br><br><b>掌握度：</b>\(Int(item.mastery * 100))%")
            let tags = ["学习助手_知识点", item.subject.replacingOccurrences(of: " ", with: "_")]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            lines.append("\(front)\t\(back)\t\(tags)")
        }

        if snapshot.mistakes.isEmpty && snapshot.knowledgePoints.isEmpty {
            lines.append("（暂无可导出的内容）\t\t")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func escapeTSV(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\t", with: "    ")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "")
    }

    private func dataHealthIssues() -> [String] {
        var issues: [String] = []
        let documentIDs = Set(snapshot.documents.map(\.id))
        let knowledgeIDs = Set(snapshot.knowledgePoints.map(\.id))
        let mistakeIDs = Set(snapshot.mistakes.map(\.id))

        if snapshot.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("AI 服务 Base URL 为空")
        }

        if snapshot.settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("AI 服务模型 ID 为空")
        }

        if !(0...23).contains(snapshot.settings.defaultReminderHour) {
            issues.append("默认提醒时间超出 0-23")
        }

        for draft in snapshot.drafts where !documentIDs.contains(draft.sourceDocumentID) {
            issues.append("草稿缺少来源资料：\(draft.summary)")
        }

        for draft in snapshot.aiPlanDrafts where draft.status == .confirmed {
            if let sourceDocumentID = draft.sourceDocumentID, !documentIDs.contains(sourceDocumentID) {
                issues.append("AI 规划缺少来源资料：\(draft.title)")
            }
            if !draft.createdKnowledgePointIDs.isEmpty {
                let missingCount = draft.createdKnowledgePointIDs.filter { !knowledgeIDs.contains($0) }.count
                if missingCount > 0 {
                    issues.append("AI 规划记录了不存在的知识点：\(draft.title)")
                }
            }
            if !draft.createdMistakeIDs.isEmpty {
                let missingCount = draft.createdMistakeIDs.filter { !mistakeIDs.contains($0) }.count
                if missingCount > 0 {
                    issues.append("AI 规划记录了不存在的错题：\(draft.title)")
                }
            }
        }

        for mistake in snapshot.mistakes {
            if let sourceID = mistake.sourceDocumentID, !documentIDs.contains(sourceID) {
                issues.append("错题来源资料不存在：\(mistake.question)")
            }
            let missingKnowledgeCount = mistake.knowledgePointIDs.filter { !knowledgeIDs.contains($0) }.count
            if missingKnowledgeCount > 0 {
                issues.append("错题关联了不存在的知识点：\(mistake.question)")
            }
        }

        for task in snapshot.reviewTasks {
            if let knowledgePointID = task.knowledgePointID, !knowledgeIDs.contains(knowledgePointID) {
                issues.append("复习任务关联了不存在的知识点：\(task.title)")
            }
            if let mistakeID = task.mistakeID, !mistakeIDs.contains(mistakeID) {
                issues.append("复习任务关联了不存在的错题：\(task.title)")
            }
        }

        let reviewTaskIDs = Set(snapshot.reviewTasks.map(\.id))
        for draft in snapshot.aiPlanDrafts where draft.status == .confirmed && !draft.createdReviewTaskIDs.isEmpty {
            let missingCount = draft.createdReviewTaskIDs.filter { !reviewTaskIDs.contains($0) }.count
            if missingCount > 0 {
                issues.append("AI 规划记录了不存在的复习任务：\(draft.title)")
            }
        }

        return issues
    }

    private func recordEvent(_ level: AppDiagnosticEvent.Level, _ message: String, shouldSave: Bool = true) {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        snapshot.diagnosticEvents.insert(AppDiagnosticEvent(level: level, message: String(cleaned.prefix(500))), at: 0)
        if snapshot.diagnosticEvents.count > 80 {
            snapshot.diagnosticEvents = Array(snapshot.diagnosticEvents.prefix(80))
        }
        if shouldSave {
            save()
        }
    }

    func navigateToImport() {
        navigateToTab = "importData"
        navigateToSection = "导入"
    }

    func navigateToDrafts() {
        navigateToTab = "more"
        navigateToSection = "待确认"
    }

    func navigateToReviews() {
        navigateToTab = "reviews"
        navigateToSection = "复习计划"
    }

    func navigateToExamGoals() {
        navigateToTab = "more"
        navigateToSection = "考试目标"
    }

    func navigateToSettings() {
        navigateToTab = "more"
        navigateToSection = "设置"
    }

    func navigateToChat() {
        navigateToTab = "chat"
        navigateToSection = "学习答疑"
    }

    func navigateToCitation(_ citation: ChatMessageCitation) {
        switch citation.kind {
        case .document:
            navigateToTab = "importData"
            navigateToSection = "导入"
        case .mistake:
            navigateToTab = "more"
            navigateToSection = "错题"
        case .knowledge:
            navigateToTab = "more"
            navigateToSection = "知识点"
        case .reviewTask:
            navigateToTab = "reviews"
            navigateToSection = "复习计划"
        case .goal:
            navigateToTab = "chat"
            navigateToSection = "学习答疑"
        }
    }
}

private struct ChatPromptContext {
    var summary: String
    var recentMessages: [ChatHistoryMessage]
}
