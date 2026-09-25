import Foundation

// MARK: - 学习会话与完成事件（模块 A 数据契约）
//
// 说明：
// - 学习（`StudySession`）、完成事件（`CompletionEvent`）、答题正确
//   （`StudyAssessment`）是三件不同的事，分别存储，互不派生。
// - 有效时长由 `startedAt` / `pauses` / `endedAt` 与外部传入的 `now`
//   计算得到，不额外存一份缓存，避免两个来源互相矛盾。
// - 完成事件有稳定唯一键：同一会话重复结束只产生一条记录。

// MARK: - 会话

enum StudySessionState: String, Codable, CaseIterable, Sendable {
    case running
    case paused
    case finished
    case abandoned

    var label: String {
        switch self {
        case .running: return "进行中"
        case .paused: return "已暂停"
        case .finished: return "已结束"
        case .abandoned: return "已放弃"
        }
    }

    var isActive: Bool { self == .running || self == .paused }
}

/// 一段暂停区间。`endedAt == nil` 表示仍在暂停中。
struct StudyPauseInterval: Codable, Hashable, Sendable {
    var startedAt: Date
    var endedAt: Date?

    init(startedAt: Date, endedAt: Date? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? StudyTimestamp.unspecified
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
    }
}

/// 一次学习会话。
struct StudySession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID?
    var planItemID: UUID?
    var dayKey: StudyDayKey
    var startedAt: Date
    var endedAt: Date?
    var pauses: [StudyPauseInterval]
    var state: StudySessionState
    /// 会话内累计推进的任务范围（可多次累加）。
    var progress: StudyScope
    /// 答题正确情况；与学习时长、完成范围彼此独立。
    var assessment: StudyAssessment?
    var note: String
    var abandonmentReason: String?
    /// 已应用过的事件幂等键，用于拒绝重复事件。
    var appliedEventKeys: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID? = nil,
        planItemID: UUID? = nil,
        dayKey: StudyDayKey,
        startedAt: Date,
        endedAt: Date? = nil,
        pauses: [StudyPauseInterval] = [],
        state: StudySessionState = .running,
        progress: StudyScope = .zero,
        assessment: StudyAssessment? = nil,
        note: String = "",
        abandonmentReason: String? = nil,
        appliedEventKeys: [String] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.planID = planID
        self.planItemID = planItemID
        self.dayKey = dayKey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pauses = pauses
        self.state = state
        self.progress = progress
        self.assessment = assessment
        self.note = note
        self.abandonmentReason = abandonmentReason
        self.appliedEventKeys = appliedEventKeys
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 会话的"有效截止时间"：未结束时取 `now`，已结束时取 `endedAt`。
    func effectiveEnd(asOf now: Date) -> Date {
        min(now, endedAt ?? now)
    }

    /// 有效学习时长（分钟）。
    ///
    /// 纯计算：只依赖会话自身的时间与外部传入的 `now` / `calendar`。
    func effectiveMinutes(asOf now: Date, calendar: Calendar) -> Int {
        let end = effectiveEnd(asOf: now)
        guard end > startedAt else { return 0 }
        var seconds = end.timeIntervalSince(startedAt)
        for pause in pauses {
            let pauseStart = max(pause.startedAt, startedAt)
            let pauseEnd = min(pause.endedAt ?? end, end)
            if pauseEnd > pauseStart {
                seconds -= pauseEnd.timeIntervalSince(pauseStart)
            }
        }
        return max(0, Int(floor(seconds / 60)))
    }

    /// 已结束会话的最终有效时长；未结束时返回 `nil`。
    var recordedEffectiveMinutes: Int? {
        guard let endedAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dayKey.timeZone
        return effectiveMinutes(asOf: endedAt, calendar: calendar)
    }

    /// 当前是否处于暂停中。
    var isPausedRightNow: Bool {
        state == .paused && (pauses.last?.endedAt == nil)
    }

    func hasApplied(eventKey: String) -> Bool {
        appliedEventKeys.contains(eventKey)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        planID = try container.decodeIfPresent(UUID.self, forKey: .planID)
        planItemID = try container.decodeIfPresent(UUID.self, forKey: .planItemID)
        dayKey = try container.decodeIfPresent(StudyDayKey.self, forKey: .dayKey)
            ?? StudyDayKey(date: StudyTimestamp.unspecified, timeZone: TimeZone.current)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? StudyTimestamp.unspecified
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        pauses = try container.decodeIfPresent([StudyPauseInterval].self, forKey: .pauses) ?? []
        let rawState = try container.decodeIfPresent(String.self, forKey: .state) ?? StudySessionState.running.rawValue
        state = StudySessionState(rawValue: rawState) ?? .running
        progress = try container.decodeIfPresent(StudyScope.self, forKey: .progress) ?? .zero
        assessment = try container.decodeIfPresent(StudyAssessment.self, forKey: .assessment)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        abandonmentReason = try container.decodeIfPresent(String.self, forKey: .abandonmentReason)
        appliedEventKeys = try container.decodeIfPresent([String].self, forKey: .appliedEventKeys) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? startedAt
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// 评分 / 正确率。**不参与**时长与完成范围的计算。
struct StudyAssessment: Codable, Hashable, Sendable {
    var totalQuestions: Int?
    var correctQuestions: Int?
    /// 自评 0...5（与既有 SM-2 `quality` 口径一致）。
    var selfRating: Int?

    init(totalQuestions: Int? = nil, correctQuestions: Int? = nil, selfRating: Int? = nil) {
        self.totalQuestions = totalQuestions.map { max(0, $0) }
        self.correctQuestions = correctQuestions.map { max(0, $0) }
        self.selfRating = selfRating.map { min(max($0, 0), 5) }
    }

    /// 正确率；题数为 0 或缺失时返回 `nil`（不编造 0%）。
    var accuracy: Double? {
        guard let totalQuestions, let correctQuestions, totalQuestions > 0 else { return nil }
        return Double(min(correctQuestions, totalQuestions)) / Double(totalQuestions)
    }

    var isAnswered: Bool { (totalQuestions ?? 0) > 0 }

    var isEmpty: Bool { totalQuestions == nil && correctQuestions == nil && selfRating == nil }

    var stableKey: String {
        "q:\(totalQuestions.map(String.init) ?? "-")/c:\(correctQuestions.map(String.init) ?? "-")/r:\(selfRating.map(String.init) ?? "-")"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalQuestions = try container.decodeIfPresent(Int.self, forKey: .totalQuestions).map { max(0, $0) }
        correctQuestions = try container.decodeIfPresent(Int.self, forKey: .correctQuestions).map { max(0, $0) }
        selfRating = try container.decodeIfPresent(Int.self, forKey: .selfRating).map { min(max($0, 0), 5) }
    }
}

// MARK: - 会话事件

/// 学习会话的操作事件。
///
/// 事件不直接落到 UI 或存储：`StudySessionEngine` 消费它并产出
/// 新会话状态与（可选的）完成事件，再由 G 统一提交。
enum StudySessionEvent: Hashable, Sendable {
    case start(at: Date)
    case pause(at: Date)
    case resume(at: Date)
    case updateProgress(scope: StudyScope, at: Date)
    case updateAssessment(StudyAssessment)
    case finish(at: Date, scope: StudyScope?, assessment: StudyAssessment?, note: String)
    case abandon(at: Date, reason: String)

    /// 幂等键：同一操作在相同时间点重复送达时被识别为重复。
    var idempotencyKey: String {
        switch self {
        case .start(let at):
            return "start@\(Self.epoch(at))"
        case .pause(let at):
            return "pause@\(Self.epoch(at))"
        case .resume(let at):
            return "resume@\(Self.epoch(at))"
        case .updateProgress(let scope, let at):
            return "progress@\(Self.epoch(at))|\(scope.unit.rawValue)|\(scope.amount)|\(scope.customUnitLabel ?? "-")"
        case .updateAssessment(let assessment):
            return "assessment|\(assessment.stableKey)"
        case .finish(let at, let scope, _, _):
            return "finish@\(Self.epoch(at))|\(scope.map { "\($0.unit.rawValue):\($0.amount)" } ?? "-")"
        case .abandon(let at, let reason):
            return "abandon@\(Self.epoch(at))|\(reason)"
        }
    }

    var timestamp: Date {
        switch self {
        case .start(let at), .pause(let at), .resume(let at), .abandon(let at, _):
            return at
        case .updateProgress(_, let at):
            return at
        case .updateAssessment:
            return StudyTimestamp.unspecified
        case .finish(let at, _, _, _):
            return at
        }
    }

    private static func epoch(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded())
    }
}

/// 事件被拒绝的原因（重复送达、状态不合法等）。
enum StudySessionRejection: Hashable, Sendable {
    case noActiveSession
    case alreadyFinished
    case notRunning
    case notPaused
    case duplicateEvent(ignoredKey: String)

    var message: String {
        switch self {
        case .noActiveSession: return "没有进行中的学习会话。"
        case .alreadyFinished: return "会话已经结束，重复操作已被忽略。"
        case .notRunning: return "会话当前不是进行中状态。"
        case .notPaused: return "会话当前不是暂停状态。"
        case .duplicateEvent(let key): return "重复的操作事件已被忽略：\(key)"
        }
    }
}

// MARK: - 实际时长的来源

/// 完成事件里"实际学习时长"的来源。
///
/// 需求：必须把「预计耗时 / 真实计时 / 用户手动补记 / 未记录时长」分开，
/// 不能让"点一下完成"凭空产生学习分钟数。
enum StudyDurationSource: String, Codable, CaseIterable, Sendable {
    /// 真实计时：来自学习会话的有效时长（开始/暂停/结束推导）。
    case timed
    /// 用户手动补记或修正（保留原因，见 `durationNote`）。
    case manualEntry
    /// 旧版本记录：来源未标注，但当时确实写了分钟数，按"已记录"对待。
    case legacy
    /// 未记录时长：任务可以记为完成，但**不得**贡献任何时长类奖励。
    case unrecorded

    var label: String {
        switch self {
        case .timed: return "真实计时"
        case .manualEntry: return "手动补记"
        case .legacy: return "旧记录"
        case .unrecorded: return "未记录时长"
        }
    }

    /// 是否计入"实际学习时长"（时长类奖励、报告里的实际分钟数）。
    ///
    /// 未记录时长的完成不算时长——这是"不虚构时长"的核心规则。
    var contributesRecordedMinutes: Bool { self != .unrecorded }

    /// 是否由用户主动提供。
    var isUserProvided: Bool { self == .manualEntry }
}

// MARK: - 完成事件

/// 完成事件的撤销信息。
struct CompletionRevocation: Codable, Hashable, Sendable {
    var revokedAt: Date
    var reason: String
    var revokedBy: String?

    init(revokedAt: Date, reason: String, revokedBy: String? = nil) {
        self.revokedAt = revokedAt
        self.reason = reason
        self.revokedBy = revokedBy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt) ?? StudyTimestamp.unspecified
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        revokedBy = try container.decodeIfPresent(String.self, forKey: .revokedBy)
    }
}

/// 完成事件：学习完成的唯一权威记录。
///
/// 关键约定：
/// - `completedScope`（完成范围）与 `plannedScope`（计划范围）分开，
///   由此可判定"部分完成"还是"整体完成"。
/// - `assessment` 单独存放答题正确情况，绝不影响时长与范围。
/// - `idempotencyKey` 稳定：同一会话/同一计划项重复结束不会产生第二条记录。
struct CompletionEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var idempotencyKey: String
    var sessionID: UUID?
    var planID: UUID?
    var planItemID: UUID?
    var dayKey: StudyDayKey
    /// 来源快照，保证后来任务被删除后仍可追溯"这条完成来自哪"。
    var source: DailyPlanItemSource?
    var plannedScope: StudyScope?
    var completedScope: StudyScope
    /// 完成档次：已学习 / 保底完成 / 标准完成。
    var tier: PlanCompletionTier
    var actualMinutes: Int
    /// 实际时长的来源：真实计时 / 手动补记 / 旧记录 / 未记录。
    var durationSource: StudyDurationSource
    /// 时长修正的来源说明（例如"用户补记：书上做了 40 分钟"）。仅在修正过时非空。
    var durationNote: String?
    var completedAt: Date
    var assessment: StudyAssessment?
    var note: String
    var createdAt: Date
    var revocation: CompletionRevocation?

    init(
        id: UUID,
        idempotencyKey: String,
        sessionID: UUID? = nil,
        planID: UUID? = nil,
        planItemID: UUID? = nil,
        dayKey: StudyDayKey,
        source: DailyPlanItemSource? = nil,
        plannedScope: StudyScope? = nil,
        completedScope: StudyScope,
        tier: PlanCompletionTier,
        actualMinutes: Int,
        durationSource: StudyDurationSource? = nil,
        durationNote: String? = nil,
        completedAt: Date,
        assessment: StudyAssessment? = nil,
        note: String = "",
        createdAt: Date,
        revocation: CompletionRevocation? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.sessionID = sessionID
        self.planID = planID
        self.planItemID = planItemID
        self.dayKey = dayKey
        self.source = source
        self.plannedScope = plannedScope
        self.completedScope = completedScope
        self.tier = tier
        self.actualMinutes = max(0, actualMinutes)
        // 没有显式声明来源时按分钟数推断：有分钟数=已记录，没有=未记录。
        self.durationSource = durationSource ?? (max(0, actualMinutes) > 0 ? .timed : .unrecorded)
        self.durationNote = durationNote
        self.completedAt = completedAt
        self.assessment = assessment
        self.note = note
        self.createdAt = createdAt
        self.revocation = revocation
    }

    var isRevoked: Bool { revocation != nil }

    /// 是否计入实际学习时长（未记录时长的完成不计入）。
    var hasRecordedDuration: Bool { durationSource.contributesRecordedMinutes && actualMinutes > 0 }

    /// 修改实际时长（保留来源与原因）。纯值操作。
    func correctingDuration(
        to minutes: Int,
        source: StudyDurationSource,
        reason: String
    ) -> CompletionEvent {
        var copy = self
        copy.actualMinutes = max(0, minutes)
        copy.durationSource = source
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.durationNote = trimmed.isEmpty ? "用户修正时长" : trimmed
        return copy
    }

    /// 部分完成 / 整体完成分开。无法比较时返回 `nil`（不猜）。
    var isPartialCompletion: Bool? {
        guard let plannedScope else { return nil }
        return completedScope.isPartial(relativeTo: plannedScope)
    }

    var isFullCompletion: Bool {
        guard let plannedScope, let ratio = completedScope.completionRatio(relativeTo: plannedScope) else { return false }
        return ratio >= 1
    }

    /// 撤销（纯值操作）：保留原始记录，不删除历史。
    func revoked(at date: Date, reason: String, by actor: String? = nil) -> CompletionEvent {
        var copy = self
        copy.revocation = CompletionRevocation(revokedAt: date, reason: reason, revokedBy: actor)
        return copy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey) ?? id.uuidString
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
        planID = try container.decodeIfPresent(UUID.self, forKey: .planID)
        planItemID = try container.decodeIfPresent(UUID.self, forKey: .planItemID)
        dayKey = try container.decodeIfPresent(StudyDayKey.self, forKey: .dayKey)
            ?? StudyDayKey(date: StudyTimestamp.unspecified, timeZone: TimeZone.current)
        source = try container.decodeIfPresent(DailyPlanItemSource.self, forKey: .source)
        plannedScope = try container.decodeIfPresent(StudyScope.self, forKey: .plannedScope)
        completedScope = try container.decodeIfPresent(StudyScope.self, forKey: .completedScope) ?? .zero
        let rawTier = try container.decodeIfPresent(String.self, forKey: .tier) ?? PlanCompletionTier.studied.rawValue
        tier = PlanCompletionTier(rawValue: rawTier) ?? .studied
        let decodedMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .actualMinutes) ?? 0)
        actualMinutes = decodedMinutes
        // 旧数据没有来源字段：当时确实记了分钟数，按"旧记录"计入时长；
        // 0 分钟的旧记录视为"未记录时长"，不再凭它推算学习时长。
        durationSource = try container.decodeIfPresent(StudyDurationSource.self, forKey: .durationSource)
            ?? (decodedMinutes > 0 ? .legacy : .unrecorded)
        durationNote = try container.decodeIfPresent(String.self, forKey: .durationNote)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt) ?? StudyTimestamp.unspecified
        assessment = try container.decodeIfPresent(StudyAssessment.self, forKey: .assessment)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? completedAt
        revocation = try container.decodeIfPresent(CompletionRevocation.self, forKey: .revocation)
    }
}

extension CompletionEvent {
    /// 幂等键构造规则。
    enum Key {
        /// 有会话：同一会话永远只对应一条完成事件。
        static func session(_ sessionID: UUID) -> String { "completion|session:\(sessionID.uuidString)" }
        /// 无会话（手动勾选完成）：按计划项 + 学习日去重。
        static func planItem(_ planItemID: UUID, dayKey: StudyDayKey) -> String {
            "completion|item:\(planItemID.uuidString)|\(dayKey.localDateString)@\(dayKey.timeZoneIdentifier)"
        }
        /// 既无会话也无计划项：退化为按学习日 + 时间戳去重，仍然稳定。
        static func adHoc(dayKey: StudyDayKey, at: Date) -> String {
            "completion|adhoc|\(dayKey.localDateString)@\(dayKey.timeZoneIdentifier)|\(Int(at.timeIntervalSince1970.rounded()))"
        }
    }

    /// 构造完成事件。
    ///
    /// - `id` 与 `idempotencyKey` 由稳定哈希派生：同样的输入永远得到同样的 ID，
    ///   因此"重复完成任务"不会产生第二条记录。
    /// - `plannedScope` 缺失或量纲不同时，档次记为"已学习"，绝不猜成标准完成。
    static func make(
        sessionID: UUID? = nil,
        planID: UUID? = nil,
        planItemID: UUID? = nil,
        dayKey: StudyDayKey,
        source: DailyPlanItemSource? = nil,
        plannedScope: StudyScope? = nil,
        minimumScope: StudyScope? = nil,
        completedScope: StudyScope,
        actualMinutes: Int,
        durationSource: StudyDurationSource? = nil,
        durationNote: String? = nil,
        completedAt: Date,
        assessment: StudyAssessment? = nil,
        note: String = "",
        createdAt: Date,
        idempotencyKey explicitKey: String? = nil
    ) -> CompletionEvent {
        // 显式键优先：G 用它把"会话完成"和"直接完成"归并到同一个去重键，
        // 避免同一条任务被两种入口各记一次。
        let key: String
        if let explicitKey {
            key = explicitKey
        } else if let planItemID {
            key = Key.planItem(planItemID, dayKey: dayKey)
        } else if let sessionID {
            key = Key.session(sessionID)
        } else {
            key = Key.adHoc(dayKey: dayKey, at: completedAt)
        }
        let tier: PlanCompletionTier
        if let plannedScope {
            tier = PlanCompletionTier.resolve(completed: completedScope, planned: plannedScope, minimum: minimumScope)
                ?? .studied
        } else {
            tier = .studied
        }
        return CompletionEvent(
            id: StudyStableKey.uuid(from: key),
            idempotencyKey: key,
            sessionID: sessionID,
            planID: planID,
            planItemID: planItemID,
            dayKey: dayKey,
            source: source,
            plannedScope: plannedScope,
            completedScope: completedScope,
            tier: tier,
            actualMinutes: actualMinutes,
            durationSource: durationSource,
            durationNote: durationNote,
            completedAt: completedAt,
            assessment: assessment,
            note: note,
            createdAt: createdAt
        )
    }
}

// MARK: - 稳定键

/// 稳定键工具。
///
/// 复用 B 模块的 `StableHasher`（FNV-1a，不依赖 `Hasher` 的随机盐），
/// 保证跨进程、跨启动得到同一把键。
enum StudyStableKey {
    static func uuid(from key: String) -> UUID {
        var hasher = StableHasher()
        hasher.combine(key)
        return hasher.finalize()
    }

    static func fingerprint(_ components: [String]) -> String {
        var hasher = StableHasher()
        for component in components {
            hasher.combine(component)
        }
        return hasher.finalize().uuidString
    }
}

// MARK: - StoreSnapshot 会话 / 完成事件访问器

extension StoreSnapshot {
    /// 是否已存在同幂等键的完成事件（重复完成检测）。
    func hasCompletionEvent(idempotencyKey: String) -> Bool {
        completionEvents.contains { $0.idempotencyKey == idempotencyKey }
    }

    func completionEvent(id: UUID) -> CompletionEvent? {
        completionEvents.first { $0.id == id }
    }

    /// 插入完成事件（纯值操作）。
    ///
    /// 返回 `nil` 表示"重复操作，已忽略"，调用方据此提示"已完成，未重复记录"。
    func insertingCompletionEvent(_ event: CompletionEvent) -> StoreSnapshot? {
        guard !completionEvents.contains(where: { $0.id == event.id || $0.idempotencyKey == event.idempotencyKey }) else {
            return nil
        }
        var copy = self
        copy.completionEvents.append(event)
        copy.completionEvents.sort { $0.completedAt < $1.completedAt }
        return copy
    }

    /// 撤销完成事件（保留记录本身，写入撤销信息）。
    func revokingCompletionEvent(id: UUID, at date: Date, reason: String, by actor: String? = nil) -> StoreSnapshot? {
        guard let index = completionEvents.firstIndex(where: { $0.id == id }) else { return nil }
        guard completionEvents[index].revocation == nil else { return nil }
        var copy = self
        copy.completionEvents[index] = copy.completionEvents[index].revoked(at: date, reason: reason, by: actor)
        return copy
    }

    func studySessions(forPlanItemID itemID: UUID) -> [StudySession] {
        studySessions.filter { $0.planItemID == itemID }
    }

    func activeStudySession(forPlanItemID itemID: UUID) -> StudySession? {
        studySessions.first { $0.planItemID == itemID && $0.state.isActive }
    }

    /// 按完成事件重算（唯一权威来源），并同步计划项状态。
    func recomputingPlans(from completionEvents: [CompletionEvent]) -> StoreSnapshot {
        var copy = self
        copy.dailyPlans = dailyPlans.map { $0.recomputingItemStates(from: completionEvents) }
        return copy
    }
}
