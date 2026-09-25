import Foundation

// MARK: - Schema 版本（集中定义，禁止在其它地方硬编码版本号）

/// 存储 schema 版本。
///
/// - 4 → 5：引入统一数据层（课表、可用时间偏好、每日计划、学习会话、完成事件、奖励）。
/// - 5 → 6：增加可持久化的用户手动学习任务。
/// - 6 → 7：手动任务改用可选到期日，旧安排日迁为到期日。
/// - 迁移步骤见 `SnapshotMigration.swift`；迁移不是"把数字改成 7"。
enum StudySchema {
    /// 当前写入磁盘的版本。
    static let currentVersion = 7
    /// 引入统一计划层的版本。
    static let planningLayerVersion = 5
    /// 持久化手动学习任务的版本。
    static let manualStudyTasksVersion = 6
    /// 手动任务可选到期日的版本。
    static let manualTaskDueDateVersion = 7
    /// 统一计划层之前最后一个版本（旧备份的基线）。
    static let legacyBaselineVersion = 4
    /// 仍然允许读取并迁移的最低版本。
    static let minimumReadableVersion = 1
    /// 版本号的字段名（探测未来版本文件时用）。
    static let versionKeyName = "schemaVersion"
}

enum DocumentKind: String, Codable, CaseIterable {
    case note = "学习笔记"
    case mistake = "错题"
    case mixed = "综合资料"
}

enum ReviewStatus: String, Codable, CaseIterable {
    case pending = "待复习"
    case done = "已完成"
    case skipped = "已跳过"
}

enum AIAnswerMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case deepPlanning

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "普通答疑"
        case .deepPlanning: return "深度规划"
        }
    }

    var maxAnswerTokens: Int {
        switch self {
        case .normal: return 2_400
        case .deepPlanning: return 4_000
        }
    }
}

enum AppAppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白天"
        case .dark: return "夜晚"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "随系统外观自动变化"
        case .light: return "始终使用明亮界面"
        case .dark: return "始终使用深色界面"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

struct AppSettings: Codable {
    var baseURL: String = "https://api.deepseek.com"
    var model: String = "deepseek-v4-flash"
    var appearanceMode: AppAppearanceMode = .system
    var remindersEnabled: Bool = true
    var defaultReminderHour: Int = 9
    var allowModelRequests: Bool = true
    var allowStructuredPlanRequests: Bool = true
    var includePersonalContextInAnswers: Bool = true
    var keepDocumentContent: Bool = true
    var answerMode: AIAnswerMode = .normal
    var maxAnalysisChunkCharacters: Int = 12_000
    var inputTokenCostPerMillion: Double = 0
    var outputTokenCostPerMillion: Double = 0

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        appearanceMode = try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? appearanceMode
        remindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? remindersEnabled
        defaultReminderHour = try container.decodeIfPresent(Int.self, forKey: .defaultReminderHour) ?? defaultReminderHour
        allowModelRequests = try container.decodeIfPresent(Bool.self, forKey: .allowModelRequests) ?? allowModelRequests
        allowStructuredPlanRequests = try container.decodeIfPresent(Bool.self, forKey: .allowStructuredPlanRequests) ?? allowStructuredPlanRequests
        includePersonalContextInAnswers = try container.decodeIfPresent(Bool.self, forKey: .includePersonalContextInAnswers) ?? includePersonalContextInAnswers
        keepDocumentContent = try container.decodeIfPresent(Bool.self, forKey: .keepDocumentContent) ?? keepDocumentContent
        answerMode = try container.decodeIfPresent(AIAnswerMode.self, forKey: .answerMode) ?? answerMode
        maxAnalysisChunkCharacters = try container.decodeIfPresent(Int.self, forKey: .maxAnalysisChunkCharacters) ?? maxAnalysisChunkCharacters
        inputTokenCostPerMillion = try container.decodeIfPresent(Double.self, forKey: .inputTokenCostPerMillion) ?? inputTokenCostPerMillion
        outputTokenCostPerMillion = try container.decodeIfPresent(Double.self, forKey: .outputTokenCostPerMillion) ?? outputTokenCostPerMillion
    }
}

struct ModelUsageStats: Codable {
    var requestCount: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var estimatedCost: Double = 0
    var lastUpdated: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? requestCount
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? inputTokens
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? outputTokens
        estimatedCost = try container.decodeIfPresent(Double.self, forKey: .estimatedCost) ?? estimatedCost
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
    }
}

struct AppDiagnosticEvent: Identifiable, Codable {
    enum Level: String, Codable {
        case info = "信息"
        case warning = "警告"
        case error = "错误"
    }

    var id = UUID()
    var createdAt = Date()
    var level: Level
    var message: String
}

struct StudyDocument: Identifiable, Codable {
    var id = UUID()
    var title: String
    var sourceName: String
    var kind: DocumentKind
    var importedAt = Date()
    var content: String

    init(
        id: UUID = UUID(),
        title: String,
        sourceName: String,
        kind: DocumentKind,
        importedAt: Date = Date(),
        content: String
    ) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.kind = kind
        self.importedAt = importedAt
        self.content = content
    }

    // 显式解码：Swift 的属性初始值**不参与**合成解码，缺字段时必须由这里兜底。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        kind = try container.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .note
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date()
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
    }
}

struct ExamGoal: Identifiable, Codable {
    var id = UUID()
    var name: String
    var examDate: Date
    var subjects: [String]
    var dailyAvailableMinutes: Int
    var targetScore: String
    var createdAt = Date()
    var isArchived = false

    var subjectText: String {
        let cleaned = subjects
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? "未填写科目" : cleaned.joined(separator: "、")
    }

    var dailyAvailableTimeText: String {
        let minutes = max(dailyAvailableMinutes, 0)
        guard minutes > 0 else { return "未填写每日可用时间" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 {
            return "\(remainingMinutes) 分钟/天"
        }
        if remainingMinutes == 0 {
            return "\(hours) 小时/天"
        }
        return "\(hours) 小时 \(remainingMinutes) 分钟/天"
    }

    func daysRemaining(now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: examDate)
        return calendar.dateComponents([.day], from: start, to: target).day ?? 0
    }

    func countdownText(now: Date = Date()) -> String {
        let days = daysRemaining(now: now)
        if days > 0 {
            return "倒计时 \(days) 天"
        }
        if days == 0 {
            return "今天考试"
        }
        return "已结束 \(abs(days)) 天"
    }

    func promptSummary(now: Date = Date()) -> String {
        [
            "\(name)：\(countdownText(now: now))，考试日期 \(examDate.formatted(date: .numeric, time: .omitted))",
            "科目：\(subjectText)",
            "每日可用时间：\(dailyAvailableTimeText)",
            "目标分数：\(targetScore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写" : targetScore)"
        ].joined(separator: "；")
    }

    init(
        id: UUID = UUID(),
        name: String,
        examDate: Date,
        subjects: [String],
        dailyAvailableMinutes: Int,
        targetScore: String,
        createdAt: Date = Date(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.examDate = examDate
        self.subjects = subjects
        self.dailyAvailableMinutes = dailyAvailableMinutes
        self.targetScore = targetScore
        self.createdAt = createdAt
        self.isArchived = isArchived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名考试"
        examDate = try container.decodeIfPresent(Date.self, forKey: .examDate) ?? Date()
        subjects = try container.decodeIfPresent([String].self, forKey: .subjects) ?? []
        dailyAvailableMinutes = try container.decodeIfPresent(Int.self, forKey: .dailyAvailableMinutes) ?? 120
        targetScore = try container.decodeIfPresent(String.self, forKey: .targetScore) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

struct KnowledgePoint: Identifiable, Codable {
    var id = UUID()
    var title: String
    var subject: String
    var summary: String
    var mastery: Double
    var createdAt = Date()

    init(
        id: UUID = UUID(),
        title: String,
        subject: String,
        summary: String,
        mastery: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.subject = subject
        self.summary = summary
        self.mastery = mastery
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        mastery = try container.decodeIfPresent(Double.self, forKey: .mastery) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct Mistake: Identifiable, Codable {
    var id = UUID()
    var question: String
    var correctAnswer: String
    var errorReason: String
    var sourceDocumentID: UUID?
    var knowledgePointIDs: [UUID]
    var createdAt = Date()

    init(
        id: UUID = UUID(),
        question: String,
        correctAnswer: String,
        errorReason: String,
        sourceDocumentID: UUID? = nil,
        knowledgePointIDs: [UUID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.question = question
        self.correctAnswer = correctAnswer
        self.errorReason = errorReason
        self.sourceDocumentID = sourceDocumentID
        self.knowledgePointIDs = knowledgePointIDs
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        correctAnswer = try container.decodeIfPresent(String.self, forKey: .correctAnswer) ?? ""
        errorReason = try container.decodeIfPresent(String.self, forKey: .errorReason) ?? ""
        sourceDocumentID = try container.decodeIfPresent(UUID.self, forKey: .sourceDocumentID)
        knowledgePointIDs = try container.decodeIfPresent([UUID].self, forKey: .knowledgePointIDs) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct ReviewTask: Identifiable, Codable {
    var id = UUID()
    var title: String
    var dueDate: Date
    var knowledgePointID: UUID?
    var mistakeID: UUID?
    var status: ReviewStatus = .pending
    var remindersEnabled: Bool = true
    var priority: Int?

    // SM-2 spaced repetition fields
    /// Easiness factor; starts at 2.5, clamped to [1.3, 2.5]
    var easinessFactor: Double = 2.5
    /// Number of successful consecutive reviews (used as `n` in SM-2)
    var repetitionCount: Int = 0
    /// The interval (in days) that was used to schedule the current review.
    /// After the first successful review this becomes 1 day; climbs exponentially.
    var intervalDays: Int = 0
    /// Quality rating from the last completed review (0-5), or nil if never reviewed.
    var lastQuality: Int? = nil
    /// When this task was last reviewed. Used by iterative AI plans to adjust tomorrow's workload.
    var lastReviewedAt: Date? = nil

    /// Returns a short summary of SM-2 state for debug / UI use.
    var sm2Description: String {
        let ef = String(format: "%.1f", easinessFactor)
        return "EF=\(ef) n=\(repetitionCount) interval=\(intervalDays)d"
    }

    init(
        id: UUID = UUID(),
        title: String,
        dueDate: Date,
        knowledgePointID: UUID? = nil,
        mistakeID: UUID? = nil,
        status: ReviewStatus = .pending,
        remindersEnabled: Bool = true,
        priority: Int? = nil,
        easinessFactor: Double = 2.5,
        repetitionCount: Int = 0,
        intervalDays: Int = 0,
        lastQuality: Int? = nil,
        lastReviewedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.knowledgePointID = knowledgePointID
        self.mistakeID = mistakeID
        self.status = status
        self.remindersEnabled = remindersEnabled
        self.priority = priority
        self.easinessFactor = easinessFactor
        self.repetitionCount = repetitionCount
        self.intervalDays = intervalDays
        self.lastQuality = lastQuality
        self.lastReviewedAt = lastReviewedAt
    }

    /// 显式解码，保证旧备份缺字段时仍能加载。
    ///
    /// 关键点：Swift 合成解码**不会**使用属性初始值——非可选属性一旦缺键就会抛
    /// `keyNotFound`。`status` / `remindersEnabled` / `easinessFactor` /
    /// `repetitionCount` / `intervalDays` 都是"有初始值但可能缺失"的字段，
    /// 因此必须在这里逐个 `decodeIfPresent` 兜底。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "未命名复习任务"
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate) ?? Date()
        knowledgePointID = try container.decodeIfPresent(UUID.self, forKey: .knowledgePointID)
        mistakeID = try container.decodeIfPresent(UUID.self, forKey: .mistakeID)
        status = try container.decodeIfPresent(ReviewStatus.self, forKey: .status) ?? .pending
        remindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? true
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        easinessFactor = try container.decodeIfPresent(Double.self, forKey: .easinessFactor) ?? 2.5
        repetitionCount = try container.decodeIfPresent(Int.self, forKey: .repetitionCount) ?? 0
        intervalDays = try container.decodeIfPresent(Int.self, forKey: .intervalDays) ?? 0
        lastQuality = try container.decodeIfPresent(Int.self, forKey: .lastQuality)
        lastReviewedAt = try container.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
    }
}

struct AnalysisDraft: Identifiable, Codable {
    var id = UUID()
    var sourceDocumentID: UUID
    var createdAt = Date()
    var summary: String
    var knowledgePoints: [DraftKnowledgePoint]
    var mistakes: [DraftMistake]
    var reviewItems: [DraftReviewItem]

    init(
        id: UUID = UUID(),
        sourceDocumentID: UUID,
        createdAt: Date = Date(),
        summary: String,
        knowledgePoints: [DraftKnowledgePoint],
        mistakes: [DraftMistake],
        reviewItems: [DraftReviewItem]
    ) {
        self.id = id
        self.sourceDocumentID = sourceDocumentID
        self.createdAt = createdAt
        self.summary = summary
        self.knowledgePoints = knowledgePoints
        self.mistakes = mistakes
        self.reviewItems = reviewItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceDocumentID = try container.decodeIfPresent(UUID.self, forKey: .sourceDocumentID) ?? UUID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        knowledgePoints = try container.decodeIfPresent([DraftKnowledgePoint].self, forKey: .knowledgePoints) ?? []
        mistakes = try container.decodeIfPresent([DraftMistake].self, forKey: .mistakes) ?? []
        reviewItems = try container.decodeIfPresent([DraftReviewItem].self, forKey: .reviewItems) ?? []
    }
}

struct DraftConfirmationResult {
    var createdKnowledgePointIDs: [UUID]
    var createdMistakeIDs: [UUID]
    var createdReviewTaskIDs: [UUID]
}

enum AIPlanPatchStatus: String, Codable {
    case applied
    case failed
}

enum AIPlanPatchOperationKind: String, Codable {
    case delete
    case reschedule
    case updatePriority
    case updateTitle
}

struct AIPlanPatchOperation: Identifiable, Codable {
    var id = UUID()
    var kind: AIPlanPatchOperationKind
    var reviewTaskID: UUID
    var reviewTaskTitle: String
    var newTitle: String?
    var newDueDate: Date?
    var newPriority: Int?
    var reason: String?

    init(
        id: UUID = UUID(),
        kind: AIPlanPatchOperationKind,
        reviewTaskID: UUID,
        reviewTaskTitle: String,
        newTitle: String? = nil,
        newDueDate: Date? = nil,
        newPriority: Int? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.reviewTaskID = reviewTaskID
        self.reviewTaskTitle = reviewTaskTitle
        self.newTitle = newTitle
        self.newDueDate = newDueDate
        self.newPriority = newPriority
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(AIPlanPatchOperationKind.self, forKey: .kind) ?? .updateTitle
        reviewTaskID = try container.decodeIfPresent(UUID.self, forKey: .reviewTaskID) ?? UUID()
        reviewTaskTitle = try container.decodeIfPresent(String.self, forKey: .reviewTaskTitle) ?? ""
        newTitle = try container.decodeIfPresent(String.self, forKey: .newTitle)
        newDueDate = try container.decodeIfPresent(Date.self, forKey: .newDueDate)
        newPriority = try container.decodeIfPresent(Int.self, forKey: .newPriority)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

struct AIPlanPatch: Identifiable, Codable {
    var id = UUID()
    var title: String
    var summary: String
    var createdAt = Date()
    var status: AIPlanPatchStatus = .applied
    var sourceUserMessageID: UUID?
    var sourceAssistantMessageID: UUID?
    var operations: [AIPlanPatchOperation]
    var appliedAt: Date?
    var updatedReviewTaskIDs: [UUID] = []
    var deletedReviewTaskIDs: [UUID] = []

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        createdAt: Date = Date(),
        status: AIPlanPatchStatus = .applied,
        sourceUserMessageID: UUID? = nil,
        sourceAssistantMessageID: UUID? = nil,
        operations: [AIPlanPatchOperation],
        appliedAt: Date? = nil,
        updatedReviewTaskIDs: [UUID] = [],
        deletedReviewTaskIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.status = status
        self.sourceUserMessageID = sourceUserMessageID
        self.sourceAssistantMessageID = sourceAssistantMessageID
        self.operations = operations
        self.appliedAt = appliedAt
        self.updatedReviewTaskIDs = updatedReviewTaskIDs
        self.deletedReviewTaskIDs = deletedReviewTaskIDs
    }

    /// 显式解码：`updatedReviewTaskIDs` / `deletedReviewTaskIDs` 是后加的字段，
    /// 旧备份里缺失属于正常情况，必须能正常加载。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        status = try container.decodeIfPresent(AIPlanPatchStatus.self, forKey: .status) ?? .applied
        sourceUserMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceUserMessageID)
        sourceAssistantMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceAssistantMessageID)
        operations = try container.decodeIfPresent([AIPlanPatchOperation].self, forKey: .operations) ?? []
        appliedAt = try container.decodeIfPresent(Date.self, forKey: .appliedAt)
        updatedReviewTaskIDs = try container.decodeIfPresent([UUID].self, forKey: .updatedReviewTaskIDs) ?? []
        deletedReviewTaskIDs = try container.decodeIfPresent([UUID].self, forKey: .deletedReviewTaskIDs) ?? []
    }
}

enum AIPlanDraftStatus: String, Codable {
    case pending
    case confirmed
    case dismissed
}

struct AIPlanDraft: Identifiable, Codable {
    var id = UUID()
    var title: String
    var summary: String
    var createdAt = Date()
    var status: AIPlanDraftStatus = .pending
    var sourceUserMessageID: UUID?
    var sourceAssistantMessageID: UUID?
    var sourceDocumentID: UUID?
    var confirmedAnalysisDraftID: UUID?
    var confirmedAt: Date?
    var planTemplate: AIPlanTemplate = .general
    var lastIterationAt: Date?
    var iterationCount: Int = 0
    var iterationNote: String?
    var createdKnowledgePointIDs: [UUID] = []
    var createdMistakeIDs: [UUID] = []
    var createdReviewTaskIDs: [UUID] = []
    var knowledgePoints: [DraftKnowledgePoint]
    var mistakes: [DraftMistake]
    var reviewItems: [DraftReviewItem]

    var isConfirmable: Bool {
        status == .pending
    }

    func makeAnalysisDraft(sourceDocumentID: UUID) -> AnalysisDraft {
        AnalysisDraft(
            sourceDocumentID: sourceDocumentID,
            summary: "\(title)\n\n\(summary)",
            knowledgePoints: knowledgePoints,
            mistakes: mistakes,
            reviewItems: reviewItems
        )
    }

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        createdAt: Date = Date(),
        status: AIPlanDraftStatus = .pending,
        sourceUserMessageID: UUID? = nil,
        sourceAssistantMessageID: UUID? = nil,
        sourceDocumentID: UUID? = nil,
        confirmedAnalysisDraftID: UUID? = nil,
        confirmedAt: Date? = nil,
        planTemplate: AIPlanTemplate = .general,
        lastIterationAt: Date? = nil,
        iterationCount: Int = 0,
        iterationNote: String? = nil,
        createdKnowledgePointIDs: [UUID] = [],
        createdMistakeIDs: [UUID] = [],
        createdReviewTaskIDs: [UUID] = [],
        knowledgePoints: [DraftKnowledgePoint],
        mistakes: [DraftMistake],
        reviewItems: [DraftReviewItem]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.status = status
        self.sourceUserMessageID = sourceUserMessageID
        self.sourceAssistantMessageID = sourceAssistantMessageID
        self.sourceDocumentID = sourceDocumentID
        self.confirmedAnalysisDraftID = confirmedAnalysisDraftID
        self.confirmedAt = confirmedAt
        self.planTemplate = planTemplate
        self.lastIterationAt = lastIterationAt
        self.iterationCount = iterationCount
        self.iterationNote = iterationNote
        self.createdKnowledgePointIDs = createdKnowledgePointIDs
        self.createdMistakeIDs = createdMistakeIDs
        self.createdReviewTaskIDs = createdReviewTaskIDs
        self.knowledgePoints = knowledgePoints
        self.mistakes = mistakes
        self.reviewItems = reviewItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        status = try container.decodeIfPresent(AIPlanDraftStatus.self, forKey: .status) ?? .pending
        sourceUserMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceUserMessageID)
        sourceAssistantMessageID = try container.decodeIfPresent(UUID.self, forKey: .sourceAssistantMessageID)
        sourceDocumentID = try container.decodeIfPresent(UUID.self, forKey: .sourceDocumentID)
        confirmedAnalysisDraftID = try container.decodeIfPresent(UUID.self, forKey: .confirmedAnalysisDraftID)
        confirmedAt = try container.decodeIfPresent(Date.self, forKey: .confirmedAt)
        planTemplate = try container.decodeIfPresent(AIPlanTemplate.self, forKey: .planTemplate) ?? .general
        lastIterationAt = try container.decodeIfPresent(Date.self, forKey: .lastIterationAt)
        iterationCount = try container.decodeIfPresent(Int.self, forKey: .iterationCount) ?? 0
        iterationNote = try container.decodeIfPresent(String.self, forKey: .iterationNote)
        createdKnowledgePointIDs = try container.decodeIfPresent([UUID].self, forKey: .createdKnowledgePointIDs) ?? []
        createdMistakeIDs = try container.decodeIfPresent([UUID].self, forKey: .createdMistakeIDs) ?? []
        createdReviewTaskIDs = try container.decodeIfPresent([UUID].self, forKey: .createdReviewTaskIDs) ?? []
        knowledgePoints = try container.decodeIfPresent([DraftKnowledgePoint].self, forKey: .knowledgePoints) ?? []
        mistakes = try container.decodeIfPresent([DraftMistake].self, forKey: .mistakes) ?? []
        reviewItems = try container.decodeIfPresent([DraftReviewItem].self, forKey: .reviewItems) ?? []
    }
}

struct DraftKnowledgePoint: Identifiable, Codable {
    var id = UUID()
    var title: String
    var subject: String
    var summary: String
    var mastery: Double

    init(id: UUID = UUID(), title: String, subject: String, summary: String, mastery: Double) {
        self.id = id
        self.title = title
        self.subject = subject
        self.summary = summary
        self.mastery = mastery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        mastery = try container.decodeIfPresent(Double.self, forKey: .mastery) ?? 0
    }
}

struct DraftMistake: Identifiable, Codable {
    var id = UUID()
    var question: String
    var correctAnswer: String
    var errorReason: String
    var relatedKnowledgeTitles: [String]

    init(id: UUID = UUID(), question: String, correctAnswer: String, errorReason: String, relatedKnowledgeTitles: [String]) {
        self.id = id
        self.question = question
        self.correctAnswer = correctAnswer
        self.errorReason = errorReason
        self.relatedKnowledgeTitles = relatedKnowledgeTitles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        correctAnswer = try container.decodeIfPresent(String.self, forKey: .correctAnswer) ?? ""
        errorReason = try container.decodeIfPresent(String.self, forKey: .errorReason) ?? ""
        relatedKnowledgeTitles = try container.decodeIfPresent([String].self, forKey: .relatedKnowledgeTitles) ?? []
    }
}

struct DraftReviewItem: Identifiable, Codable {
    var id = UUID()
    var title: String
    var dueInDays: Int
    var priority: Int?
    var relatedKnowledgeTitle: String?
    var relatedMistakeTitle: String?
    var relatedMistakeID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        dueInDays: Int,
        priority: Int? = nil,
        relatedKnowledgeTitle: String? = nil,
        relatedMistakeTitle: String? = nil,
        relatedMistakeID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.dueInDays = dueInDays
        self.priority = priority
        self.relatedKnowledgeTitle = relatedKnowledgeTitle
        self.relatedMistakeTitle = relatedMistakeTitle
        self.relatedMistakeID = relatedMistakeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        dueInDays = try container.decodeIfPresent(Int.self, forKey: .dueInDays) ?? 1
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        relatedKnowledgeTitle = try container.decodeIfPresent(String.self, forKey: .relatedKnowledgeTitle)
        relatedMistakeTitle = try container.decodeIfPresent(String.self, forKey: .relatedMistakeTitle)
        relatedMistakeID = try container.decodeIfPresent(UUID.self, forKey: .relatedMistakeID)
    }
}

struct StoreSnapshot: Codable {
    // MARK: 版本
    /// 磁盘 schema 版本。默认当前版本；集中常量见 `StudySchema`。
    var schemaVersion = StudySchema.currentVersion

    // MARK: 既有数据（保持原样，不删除、不改语义）
    var settings = AppSettings()
    var usageStats = ModelUsageStats()
    var diagnosticEvents: [AppDiagnosticEvent] = []
    var documents: [StudyDocument] = []
    var examGoals: [ExamGoal] = []
    var knowledgePoints: [KnowledgePoint] = []
    var mistakes: [Mistake] = []
    var reviewTasks: [ReviewTask] = []
    var drafts: [AnalysisDraft] = []
    var aiPlanDrafts: [AIPlanDraft] = []
    var aiPlanPatches: [AIPlanPatch] = []
    var chatMessages: [ChatHistoryMessage] = []
    var chatContextSummary: String = ""
    var chatMemorySummary = ChatMemorySummary()
    var chatContextSummaryMessageCount: Int = 0
    var chatContextSummaryUpdatedAt: Date?
    /// 旧版本的每日完成总数。**只保留**，不据此推算时长、明细或娱乐资格。
    var dailyActivityRecords: [DailyActivityRecord] = []
    var onboardingCompleted: Bool = false

    // MARK: schema 5：课表（键名与 `SchedulePersistenceKeys` 一致）
    /// 学期配置；`nil` 表示用户还没设置学期。
    var scheduleSemester: ScheduleSemester?
    /// 学期身份（ID + 名称）；与 `scheduleSemester` 一一对应。
    var semesterIdentity = SemesterIdentity()
    var scheduleCourses: [Course] = []
    var scheduleExceptions: [ScheduleException] = []
    var schedulePeriodTemplates: [PeriodTemplate] = PeriodTemplate.defaultTemplates
    /// 课程负担等级旁表（`Course` 本体不改动，见 `ScheduleModels.swift`）。
    var courseBurdenLevels: [CourseBurdenAssignment] = []

    // MARK: schema 5：可用时间偏好
    /// 作息偏好。默认是"未配置"而不是预填默认窗口，默认假设只作为解释出现。
    var availabilitySettings: AvailabilitySettings = .unconfigured
    /// 计划偏好（每日上限、自动减量开关、规划时区等）。
    var planningPreferences = PlanningPreferences()

    // MARK: schema 5：计划 / 会话 / 完成事件
    var dailyPlans: [DailyStudyPlan] = []
    var studySessions: [StudySession] = []
    var completionEvents: [CompletionEvent] = []

    // MARK: schema 6/7：持久化手动学习任务与可选到期日
    var manualStudyTasks: [ManualStudyTask] = []

    // MARK: schema 5：娱乐解锁
    var entertainmentRules: [EntertainmentRule] = []
    var rewardGrants: [RewardGrant] = []

    init() {}

    /// 显式解码：新增字段在旧备份中缺失时使用合理默认值。
    ///
    /// Swift 合成解码不会使用属性初始值，所以这里必须逐个 `decodeIfPresent`。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? settings
        usageStats = try container.decodeIfPresent(ModelUsageStats.self, forKey: .usageStats) ?? usageStats
        diagnosticEvents = try container.decodeIfPresent([AppDiagnosticEvent].self, forKey: .diagnosticEvents) ?? []
        documents = try container.decodeIfPresent([StudyDocument].self, forKey: .documents) ?? []
        examGoals = try container.decodeIfPresent([ExamGoal].self, forKey: .examGoals) ?? []
        knowledgePoints = try container.decodeIfPresent([KnowledgePoint].self, forKey: .knowledgePoints) ?? []
        mistakes = try container.decodeIfPresent([Mistake].self, forKey: .mistakes) ?? []
        reviewTasks = try container.decodeIfPresent([ReviewTask].self, forKey: .reviewTasks) ?? []
        drafts = try container.decodeIfPresent([AnalysisDraft].self, forKey: .drafts) ?? []
        aiPlanDrafts = try container.decodeIfPresent([AIPlanDraft].self, forKey: .aiPlanDrafts) ?? []
        aiPlanPatches = try container.decodeIfPresent([AIPlanPatch].self, forKey: .aiPlanPatches) ?? []
        chatMessages = try container.decodeIfPresent([ChatHistoryMessage].self, forKey: .chatMessages) ?? []
        chatContextSummary = try container.decodeIfPresent(String.self, forKey: .chatContextSummary) ?? ""
        chatMemorySummary = try container.decodeIfPresent(ChatMemorySummary.self, forKey: .chatMemorySummary) ?? ChatMemorySummary()
        chatContextSummaryMessageCount = try container.decodeIfPresent(Int.self, forKey: .chatContextSummaryMessageCount) ?? 0
        chatContextSummaryUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .chatContextSummaryUpdatedAt)
        dailyActivityRecords = try container.decodeIfPresent([DailyActivityRecord].self, forKey: .dailyActivityRecords) ?? []
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false

        // 规划层字段（schema 5/6/7）：缺失即用默认值，保证旧备份可直接加载。
        scheduleSemester = try container.decodeIfPresent(ScheduleSemester.self, forKey: .scheduleSemester)
        semesterIdentity = try container.decodeIfPresent(SemesterIdentity.self, forKey: .semesterIdentity) ?? semesterIdentity
        scheduleCourses = try container.decodeIfPresent([Course].self, forKey: .scheduleCourses) ?? []
        scheduleExceptions = try container.decodeIfPresent([ScheduleException].self, forKey: .scheduleExceptions) ?? []
        schedulePeriodTemplates = try container.decodeIfPresent([PeriodTemplate].self, forKey: .schedulePeriodTemplates)
            ?? PeriodTemplate.defaultTemplates
        courseBurdenLevels = try container.decodeIfPresent([CourseBurdenAssignment].self, forKey: .courseBurdenLevels) ?? []
        availabilitySettings = try container.decodeIfPresent(AvailabilitySettings.self, forKey: .availabilitySettings)
            ?? .unconfigured
        planningPreferences = try container.decodeIfPresent(PlanningPreferences.self, forKey: .planningPreferences)
            ?? PlanningPreferences()
        dailyPlans = try container.decodeIfPresent([DailyStudyPlan].self, forKey: .dailyPlans) ?? []
        manualStudyTasks = try container.decodeIfPresent([ManualStudyTask].self, forKey: .manualStudyTasks) ?? []
        studySessions = try container.decodeIfPresent([StudySession].self, forKey: .studySessions) ?? []
        completionEvents = try container.decodeIfPresent([CompletionEvent].self, forKey: .completionEvents) ?? []
        entertainmentRules = try container.decodeIfPresent([EntertainmentRule].self, forKey: .entertainmentRules) ?? []
        rewardGrants = try container.decodeIfPresent([RewardGrant].self, forKey: .rewardGrants) ?? []
    }

    /// 归一化到当前 schema（写入磁盘前的最后一步）。
    ///
    /// 只改版本号与结构，不改变任何业务数据。
    func normalizedToCurrentSchema() -> StoreSnapshot {
        var copy = self
        copy.schemaVersion = StudySchema.currentVersion
        return copy
    }

    func aiPlanDraft(for message: ChatHistoryMessage) -> AIPlanDraft? {
        guard let draftID = message.aiPlanDraftID else { return nil }
        return aiPlanDrafts.first { $0.id == draftID }
    }

    func pendingAIPlanDraft(for message: ChatHistoryMessage) -> AIPlanDraft? {
        guard let draft = aiPlanDraft(for: message), draft.isConfirmable else { return nil }
        return draft
    }

    var pendingAIPlanDrafts: [AIPlanDraft] {
        aiPlanDrafts
            .filter(\.isConfirmable)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func activeExamGoals(now: Date = Date()) -> [ExamGoal] {
        examGoals
            .filter { !$0.isArchived && $0.daysRemaining(now: now) >= 0 }
            .sorted {
                if $0.examDate != $1.examDate {
                    return $0.examDate < $1.examDate
                }
                return $0.createdAt > $1.createdAt
            }
    }

    func nextExamGoal(now: Date = Date()) -> ExamGoal? {
        activeExamGoals(now: now).first
    }
}

struct ChatMemorySummary: Codable, Equatable {
    var userGoals: [String] = []
    var learningLevels: [String] = []
    var preferences: [String] = []
    var plannedWork: [String] = []
    var questionsNotToRepeat: [String] = []

    var isEmpty: Bool {
        userGoals.isEmpty
            && learningLevels.isEmpty
            && preferences.isEmpty
            && plannedWork.isEmpty
            && questionsNotToRepeat.isEmpty
    }

    var promptText: String {
        guard !isEmpty else { return "" }
        return [
            section("用户目标记忆", userGoals),
            section("学习水平记忆", learningLevels),
            section("偏好记忆", preferences),
            section("已做规划记忆", plannedWork),
            section("AI 不应重复问的问题", questionsNotToRepeat)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    func mergedWithLegacySummary(_ legacySummary: String) -> ChatMemorySummary {
        let cleanedLegacy = legacySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEmpty, !cleanedLegacy.isEmpty else { return self }
        return ChatMemorySummary(plannedWork: ["历史长期摘要：\(cleanedLegacy)"])
    }

    private func section(_ title: String, _ items: [String]) -> String {
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        return "## \(title)\n" + cleaned.prefix(12).map { "- \($0)" }.joined(separator: "\n")
    }

    init(
        userGoals: [String] = [],
        learningLevels: [String] = [],
        preferences: [String] = [],
        plannedWork: [String] = [],
        questionsNotToRepeat: [String] = []
    ) {
        self.userGoals = Self.clean(userGoals)
        self.learningLevels = Self.clean(learningLevels)
        self.preferences = Self.clean(preferences)
        self.plannedWork = Self.clean(plannedWork)
        self.questionsNotToRepeat = Self.clean(questionsNotToRepeat)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userGoals = Self.clean(try container.decodeIfPresent([String].self, forKey: .userGoals) ?? [])
        learningLevels = Self.clean(try container.decodeIfPresent([String].self, forKey: .learningLevels) ?? [])
        preferences = Self.clean(try container.decodeIfPresent([String].self, forKey: .preferences) ?? [])
        plannedWork = Self.clean(try container.decodeIfPresent([String].self, forKey: .plannedWork) ?? [])
        questionsNotToRepeat = Self.clean(try container.decodeIfPresent([String].self, forKey: .questionsNotToRepeat) ?? [])
    }

    private static func clean(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            result.append(String(cleaned.prefix(220)))
        }
        return Array(result.prefix(12))
    }
}

struct DeepSeekUsage: Codable {
    var inputTokens: Int
    var outputTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens
    }
}

struct DeepSeekAnalysisPayload: Codable {
    var summary: String
    var knowledgePoints: [DeepSeekKnowledgePoint]
    var mistakes: [DeepSeekMistake]
    var reviewItems: [DeepSeekReviewItem]
}

struct DeepSeekKnowledgePoint: Codable {
    var title: String
    var subject: String?
    var summary: String
    var mastery: Double?
}

struct DeepSeekMistake: Codable {
    var question: String
    var correctAnswer: String?
    var errorReason: String
    var relatedKnowledgeTitles: [String]?
}

struct DeepSeekReviewItem: Codable {
    var title: String
    var dueInDays: Int?
    var relatedKnowledgeTitle: String?
    var relatedMistakeTitle: String?
}

struct DeepSeekAIPlanPayload: Codable {
    var isPlan: Bool?
    var title: String?
    var summary: String?
    var knowledgePoints: [DeepSeekKnowledgePoint]?
    var mistakes: [DeepSeekMistake]?
    var reviewItems: [DeepSeekAIPlanReviewItem]?
}

struct DeepSeekAIPlanReviewItem: Codable {
    var title: String
    var dueInDays: Int?
    var priority: Int?
    var relatedKnowledgeTitle: String?
    var relatedMistakeTitle: String?
}

// MARK: - Chat History

enum ChatMessageCitationKind: String, Codable {
    case document = "导入资料"
    case mistake = "错题"
    case knowledge = "知识点"
    case reviewTask = "复习任务"
    case goal = "长期目标"
}

struct ChatMessageCitation: Identifiable, Codable {
    var id = UUID()
    var kind: ChatMessageCitationKind
    var title: String
    var excerpt: String
    var sourceID: UUID?
    var promptIndex: Int

    init(
        id: UUID = UUID(),
        kind: ChatMessageCitationKind,
        title: String,
        excerpt: String,
        sourceID: UUID? = nil,
        promptIndex: Int
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.excerpt = excerpt
        self.sourceID = sourceID
        self.promptIndex = promptIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(ChatMessageCitationKind.self, forKey: .kind) ?? .document
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        sourceID = try container.decodeIfPresent(UUID.self, forKey: .sourceID)
        promptIndex = try container.decodeIfPresent(Int.self, forKey: .promptIndex) ?? 0
    }
}

struct ChatHistoryMessage: Identifiable, Codable {
    var id = UUID()
    var role: Role
    var content: String
    var createdAt = Date()
    var aiPlanDraftID: UUID?
    var citations: [ChatMessageCitation] = []

    var hasConfirmableAIPlanDraft: Bool {
        role == .assistant && aiPlanDraftID != nil
    }

    enum Role: String, Codable {
        case user
        case assistant
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        aiPlanDraftID: UUID? = nil,
        citations: [ChatMessageCitation] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.aiPlanDraftID = aiPlanDraftID
        self.citations = citations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        aiPlanDraftID = try container.decodeIfPresent(UUID.self, forKey: .aiPlanDraftID)
        citations = try container.decodeIfPresent([ChatMessageCitation].self, forKey: .citations) ?? []
    }
}

// MARK: - Daily Activity (Streak)

struct DailyActivityRecord: Identifiable, Codable {
    var dateString: String
    var completedTaskCount: Int
    var studiedAt: Date

    var id: String { dateString }

    init(date: Date = Date(), completedTaskCount: Int = 0) {
        self.dateString = Self.dateString(from: date)
        self.completedTaskCount = completedTaskCount
        self.studiedAt = date
    }

    init(dateString: String, completedTaskCount: Int = 0, studiedAt: Date) {
        self.dateString = dateString
        self.completedTaskCount = completedTaskCount
        self.studiedAt = studiedAt
    }

    /// 显式解码：旧记录缺字段时用默认值兜底。
    ///
    /// 注意：这是**旧版本的每日完成总数**，只能原样保留。
    /// 不允许据此推算学习时长、任务明细或娱乐资格。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dateString = try container.decodeIfPresent(String.self, forKey: .dateString)
            ?? Self.todayString()
        completedTaskCount = max(0, try container.decodeIfPresent(Int.self, forKey: .completedTaskCount) ?? 0)
        studiedAt = try container.decodeIfPresent(Date.self, forKey: .studiedAt) ?? StudyTimestamp.unspecified
    }

    nonisolated static func dateString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    nonisolated static func todayString() -> String {
        dateString(from: Date())
    }
}

// MARK: - Onboarding

enum OnboardingStep: String, Codable, CaseIterable {
    case welcome = "欢迎"
    case apiKey = "API Key"
    case importFirst = "导入资料"
    case done = "完成"

    var index: Int {
        switch self {
        case .welcome: return 0
        case .apiKey: return 1
        case .importFirst: return 2
        case .done: return 3
        }
    }

    var title: String {
        switch self {
        case .welcome: return "欢迎使用学习助手"
        case .apiKey: return "配置 DeepSeek API Key"
        case .importFirst: return "导入第一份学习资料"
        case .done: return "准备就绪"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "学习助手帮你分析错题、规划复习，让学习更高效。\n接下来只需几步即可开始。"
        case .apiKey:
            return "在 DeepSeek 开放平台获取 API Key 后，粘贴到下方即可。\n你的 Key 会安全存储在系统钥匙串中。"
        case .importFirst:
            return "导入你的错题、笔记或课本资料，AI 会自动分析知识点和错因。"
        case .done:
            return "一切就绪！开始你的高效学习之旅吧。"
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "graduationcap.fill"
        case .apiKey: return "key.fill"
        case .importFirst: return "doc.badge.plus"
        case .done: return "checkmark.seal.fill"
        }
    }
}
