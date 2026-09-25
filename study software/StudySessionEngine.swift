import Foundation

// MARK: - D 模块：学习会话引擎
//
// 接口（A 定稿，不得更改签名）：
//   StudySessionEngine | 会话状态和操作事件 | 新会话状态、可选完成事件
//
// 纯计算：不读系统时钟（时间来自 `PlanningContext.now` 与事件自带时间戳）、
// 不写文件、不发通知、不改全局状态。落盘与通知由 G 的统一入口完成。
//
// 会话契约（D 模块会话要求）：
// 1. 支持开始、暂停、继续、结束、放弃。
// 2. 同一时刻只允许一个有效会话（同一计划项与整个 store 都只有一条 active）。
// 3. 累计有效时长与当前状态一起保存（`startedAt` / `pauses` / `endedAt` + 状态）。
// 4. 切后台或崩溃后不无条件把整段离线时间算作学习：
//    `interruptionCandidate` 检测中断，界面必须让用户确认中断期间是否学习。
// 5. 再次进入时恢复已保存进度（会话本身就是持久化对象，直接读回即可）。
// 6. 允许手动修正时长，但保留修正来源（`note` 里的 `manualAdjustment:` 标记）。
// 7. 完成事件只能生成一次（会话幂等键 + 事件幂等键双重去重）。
// 8. 部分完成事件记录实际完成范围（`completedScope` 与 `plannedScope` 分开）。
// 9. 答题正确情况单独记录，答错不等于没有努力。
// 10. 计时使用适合计算持续时间的时钟（`ContinuousClock`）；
//     持久化另外保存真实时间戳（`Date`）。

// MARK: - 配置

/// 会话引擎配置。
struct StudySessionEngineConfiguration: Hashable, Sendable {
    /// 中断判定的最短间隔（秒）：距上次状态更新超过该值即视为"可能被切后台/崩溃"。
    var interruptionThresholdSeconds: Double
    /// 单次会话的有效时长上限（分钟）：超过则该段被标为可疑，需要用户确认。
    var maximumSessionMinutes: Int
    /// 是否允许 `start` 之外的首次事件隐式建会话（默认否，避免凭空产生记录）。
    var allowsImplicitStart: Bool

    init(
        interruptionThresholdSeconds: Double = 120,
        maximumSessionMinutes: Int = 24 * 60,
        allowsImplicitStart: Bool = false
    ) {
        self.interruptionThresholdSeconds = max(1, interruptionThresholdSeconds)
        self.maximumSessionMinutes = max(1, maximumSessionMinutes)
        self.allowsImplicitStart = allowsImplicitStart
    }

    static let `default` = StudySessionEngineConfiguration()
}

// MARK: - 中断

/// 中断候选：切后台 / 崩溃后恢复时，需要用户确认的一段"没有心跳"的时间。
///
/// 引擎只负责**识别**，不替用户决定；确认结果由界面翻译成
/// `pause`（算作没学）或 `resume`（算作学了）两个既有事件。
struct StudySessionInterruption: Hashable, Sendable {
    /// 上一次有记录的状态更新时间（`updatedAt`）。
    var lastKnownActiveAt: Date
    /// 当前时间。
    var detectedAt: Date
    /// 中断时长（分钟，向下取整）。
    var gapMinutes: Int
    /// 中断时长（秒）。
    var gapSeconds: Double
    /// 会话当时是否处于暂停中（暂停期间的中断不算"整段离线时间"）。
    var wasPaused: Bool

    /// 是否需要用户确认这段时间是否用于学习。
    var requiresUserConfirmation: Bool { gapSeconds >= 60 && !wasPaused }

    var prompt: String {
        if wasPaused {
            return "会话中断期间处于暂停状态，暂停时间不计入有效时长。"
        }
        return "检测到中断约 \(gapMinutes) 分钟。这段时间是否在继续学习？选择「没有学习」会把这段时间排除，选择「在学」则按有效时长计入。"
    }
}

// MARK: - 计时时钟

/// 适合计算持续时间的单调时钟。
///
/// `Date` 会被系统对时、时区变更、用户改表影响，不能用来算时长；
/// 因此进程内计时使用 `ContinuousClock`（系统睡眠时也继续走），
/// 持久化则仍然保存 `Date` 时间戳（`StudySession.decoded` 的时间字段）。
///
/// 该类型不访问文件、不访问网络，纯粹是计时工具。
struct StudySessionClock: Sendable {
    private let clock = ContinuousClock()
    private let startInstant: ContinuousClock.Instant

    init() {
        self.startInstant = clock.now
    }

    private init(startInstant: ContinuousClock.Instant) {
        self.startInstant = startInstant
    }

    /// 距该时钟建立时刻的秒数（单调递增，不受系统时间调整影响）。
    var elapsedSeconds: Double {
        let duration = startInstant.duration(to: clock.now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    var elapsedMinutes: Int { max(0, Int(elapsedSeconds / 60)) }

    /// 从某个参考点继续计时（用于会话恢复后接着累计）。
    static func continuing(after seconds: Double) -> StudySessionClock {
        // 通过"把起点往前推"实现偏移，保持单调性不变。
        let clock = ContinuousClock()
        let adjusted = clock.now.advanced(by: .seconds(-max(0, seconds)))
        return StudySessionClock(startInstant: adjusted)
    }
}

// MARK: - 引擎

/// `StudySessionEngine` 的实现。
///
/// 无状态值类型；同一输入永远得到同一输出。
struct StudySessionEngineImpl: StudySessionEngine {
    var configuration: StudySessionEngineConfiguration

    init(configuration: StudySessionEngineConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: 入口

    func apply(
        _ event: StudySessionEvent,
        to session: StudySession?,
        item: PlanItemSessionContext?,
        context: PlanningContext
    ) -> StudySessionTransition {
        switch event {
        case .start(let at):
            return start(at: at, existing: session, item: item, context: context)
        case .pause(let at):
            return pause(at: at, session: session, context: context)
        case .resume(let at):
            return resume(at: at, session: session, context: context)
        case .updateProgress(let scope, let at):
            return updateProgress(scope: scope, at: at, session: session, context: context)
        case .updateAssessment(let assessment):
            return updateAssessment(assessment, session: session, context: context)
        case .finish(let at, let scope, let assessment, let note):
            return finish(at: at, scope: scope, assessment: assessment, note: note, session: session, item: item, context: context)
        case .abandon(let at, let reason):
            return abandon(at: at, reason: reason, session: session, context: context)
        }
    }

    // MARK: 开始

    private func start(
        at: Date,
        existing: StudySession?,
        item: PlanItemSessionContext?,
        context: PlanningContext
    ) -> StudySessionTransition {
        // 同一时刻只允许一个有效会话：已在跑就明确拒绝，不新建第二条记录。
        if let existing, existing.state.isActive {
            return StudySessionTransition(
                session: nil,
                rejection: .duplicateEvent(ignoredKey: "active-session:\(existing.id.uuidString)")
            )
        }
        if let existing, existing.state == .finished || existing.state == .abandoned {
            // 已结束的会话不能"复活"；需要继续学习就开新会话（完成事件按会话去重，不会重复）。
            return StudySessionTransition(session: nil, rejection: .alreadyFinished)
        }
        guard let item else {
            return StudySessionTransition(session: nil, rejection: .noActiveSession)
        }

        let key = eventKey(event: .start(at: at))
        let session = StudySession(
            id: UUID(),
            planID: item.planID,
            planItemID: item.planItemID,
            dayKey: item.dayKey,
            startedAt: at,
            endedAt: nil,
            pauses: [],
            state: .running,
            progress: .zero,
            assessment: nil,
            note: "",
            abandonmentReason: nil,
            appliedEventKeys: [key],
            createdAt: at,
            updatedAt: at
        )
        return StudySessionTransition(session: session)
    }

    // MARK: 暂停 / 继续

    private func pause(
        at: Date,
        session: StudySession?,
        context: PlanningContext
    ) -> StudySessionTransition {
        guard let session else { return StudySessionTransition(session: nil, rejection: .noActiveSession) }
        if session.state == .finished || session.state == .abandoned {
            return StudySessionTransition(session: nil, rejection: .alreadyFinished)
        }
        guard session.state == .running else {
            return StudySessionTransition(session: nil, rejection: .notRunning)
        }
        let key = eventKey(event: .pause(at: at))
        if session.hasApplied(eventKey: key) {
            return StudySessionTransition(session: nil, rejection: .duplicateEvent(ignoredKey: key))
        }

        var updated = session
        updated.pauses.append(StudyPauseInterval(startedAt: at, endedAt: nil))
        updated.state = .paused
        updated.appliedEventKeys.append(key)
        updated.updatedAt = at
        return StudySessionTransition(session: updated)
    }

    private func resume(
        at: Date,
        session: StudySession?,
        context: PlanningContext
    ) -> StudySessionTransition {
        guard let session else { return StudySessionTransition(session: nil, rejection: .noActiveSession) }
        if session.state == .finished || session.state == .abandoned {
            return StudySessionTransition(session: nil, rejection: .alreadyFinished)
        }
        let key = eventKey(event: .resume(at: at))
        if session.hasApplied(eventKey: key) {
            return StudySessionTransition(session: nil, rejection: .duplicateEvent(ignoredKey: key))
        }
        guard session.state == .paused else {
            return StudySessionTransition(session: nil, rejection: .notPaused)
        }

        var updated = session
        // 关闭最后一段打开的暂停区间。暂停期间不累计时间。
        if let index = updated.pauses.lastIndex(where: { $0.endedAt == nil }) {
            let started = updated.pauses[index].startedAt
            let end = max(at, started)
            updated.pauses[index].endedAt = end
        } else {
            // 状态是 paused 但没有打开的区间（例如旧数据）：补一段零长区间，
            // 保证有效时长计算不会把暂停时间算进去。
            updated.pauses.append(StudyPauseInterval(startedAt: at, endedAt: at))
        }
        updated.state = .running
        updated.appliedEventKeys.append(key)
        updated.updatedAt = at
        return StudySessionTransition(session: updated)
    }

    // MARK: 进度 / 评分

    private func updateProgress(
        scope: StudyScope,
        at: Date,
        session: StudySession?,
        context: PlanningContext
    ) -> StudySessionTransition {
        guard let session else { return StudySessionTransition(session: nil, rejection: .noActiveSession) }
        guard session.state.isActive else {
            return StudySessionTransition(session: nil, rejection: .alreadyFinished)
        }
        let key = eventKey(event: .updateProgress(scope: scope, at: at))
        if session.hasApplied(eventKey: key) {
            return StudySessionTransition(session: nil, rejection: .duplicateEvent(ignoredKey: key))
        }

        var updated = session
        updated.progress = Self.accumulating(updated.progress, with: scope)
        updated.appliedEventKeys.append(key)
        updated.updatedAt = at
        return StudySessionTransition(session: updated)
    }

    private func updateAssessment(
        _ assessment: StudyAssessment,
        session: StudySession?,
        context: PlanningContext
    ) -> StudySessionTransition {
        guard let session else { return StudySessionTransition(session: nil, rejection: .noActiveSession) }
        guard session.state.isActive else {
            return StudySessionTransition(session: nil, rejection: .alreadyFinished)
        }
        let key = eventKey(event: .updateAssessment(assessment))
        if session.hasApplied(eventKey: key) {
            return StudySessionTransition(session: nil, rejection: .duplicateEvent(ignoredKey: key))
        }

        var updated = session
        // 答题正确情况与学习时长、完成范围彼此独立：只覆盖评分字段。
        updated.assessment = assessment
        updated.appliedEventKeys.append(key)
        updated.updatedAt = session.updatedAt
        return StudySessionTransition(session: updated)
    }

    // MARK: 结束

    private func finish(
        at: Date,
        scope: StudyScope?,
        assessment: StudyAssessment?,
        note: String,
        session: StudySession?,
        item: PlanItemSessionContext?,
        context: PlanningContext
    ) -> StudySessionTransition {
        guard let session else { return StudySessionTransition(session: nil, rejection: .noActiveSession) }

        // 完成事件只能生成一次：已结束的会话重复 finish 一律拒绝。
        if session.state == .finished {
            return StudySessionTransition(session: nil, rejection: .alreadyFinished)
        }
        if session.state == .abandoned {
            return StudySessionTransition(session: nil, rejection: .alreadyFinished)
        }

        let key = eventKey(event: .finish(at: at, scope: scope, assessment: assessment, note: note))
        if session.hasApplied(eventKey: key) {
            return StudySessionTransition(session: nil, rejection: .duplicateEvent(ignoredKey: key))
        }

        var updated = session
        let end = max(at, session.startedAt)
        // 结束前先把仍在打开的暂停区间关掉，避免把暂停时间算作有效时长。
        if let index = updated.pauses.lastIndex(where: { $0.endedAt == nil }) {
            updated.pauses[index].endedAt = max(end, updated.pauses[index].startedAt)
        }

        let effectiveScope = scope.map { Self.merging(updated.progress, with: $0) } ?? updated.progress
        updated.progress = effectiveScope
        if let assessment, !assessment.isEmpty {
            updated.assessment = assessment
        }
        if !note.isEmpty {
            updated.note = Self.appendingNote(note, to: updated.note)
        }
        updated.endedAt = end
        updated.state = .finished
        updated.appliedEventKeys.append(key)
        updated.updatedAt = end

        let minutes = updated.effectiveMinutes(asOf: end, calendar: context.calendar)

        // 完成范围为空：这是一次没有推进内容的学习，记为"未完成"，不生成完成事件。
        guard effectiveScope.isPositive else {
            return StudySessionTransition(session: updated)
        }

        let completion = CompletionEvent.make(
            sessionID: updated.id,
            planID: item?.planID ?? updated.planID,
            planItemID: item?.planItemID ?? updated.planItemID,
            dayKey: item?.dayKey ?? updated.dayKey,
            source: item?.source,
            plannedScope: item?.plannedScope,
            minimumScope: item?.minimumScope,
            completedScope: effectiveScope,
            actualMinutes: minutes,
            completedAt: end,
            assessment: updated.assessment,
            note: updated.note,
            createdAt: end
        )

        return StudySessionTransition(session: updated, completionEvent: completion)
    }

    // MARK: 放弃

    private func abandon(
        at: Date,
        reason: String,
        session: StudySession?,
        context: PlanningContext
    ) -> StudySessionTransition {
        guard let session else { return StudySessionTransition(session: nil, rejection: .noActiveSession) }
        if session.state == .finished || session.state == .abandoned {
            return StudySessionTransition(session: nil, rejection: .alreadyFinished)
        }
        let key = eventKey(event: .abandon(at: at, reason: reason))
        if session.hasApplied(eventKey: key) {
            return StudySessionTransition(session: nil, rejection: .duplicateEvent(ignoredKey: key))
        }

        var updated = session
        let end = max(at, session.startedAt)
        if let index = updated.pauses.lastIndex(where: { $0.endedAt == nil }) {
            updated.pauses[index].endedAt = max(end, updated.pauses[index].startedAt)
        }
        updated.endedAt = end
        updated.state = .abandoned
        updated.abandonmentReason = reason
        updated.appliedEventKeys.append(key)
        updated.updatedAt = end
        // 放弃不生成完成事件：放弃不等于完成，也不等于没有努力（时长仍留在会话里）。
        return StudySessionTransition(session: updated)
    }

    // MARK: 中断检测（供界面在恢复时调用）

    /// 是否需要在恢复时询问"中断期间是否学习"。
    func interruptionCandidate(
        for session: StudySession,
        context: PlanningContext
    ) -> StudySessionInterruption? {
        guard session.state.isActive else { return nil }
        let detected = context.now
        let reference = max(session.updatedAt, session.startedAt)
        let gap = detected.timeIntervalSince(reference)
        guard gap >= configuration.interruptionThresholdSeconds else { return nil }

        return StudySessionInterruption(
            lastKnownActiveAt: reference,
            detectedAt: detected,
            gapMinutes: max(0, Int(gap / 60)),
            gapSeconds: gap,
            wasPaused: session.isPausedRightNow
        )
    }

    /// 会话有效时长是否已经超过可置信上限（需要人工确认，而不是直接采信）。
    func exceedsTrustedDuration(_ session: StudySession, context: PlanningContext) -> Bool {
        session.effectiveMinutes(asOf: context.now, calendar: context.calendar) > configuration.maximumSessionMinutes
    }

    /// 手动修正时长的**来源标记**（写进会话备注，保留修正来源）。
    static func manualAdjustmentNote(minutes: Int, actor: String? = nil, reason: String) -> String {
        let who = (actor?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "用户"
        return "manualAdjustment:\(minutes)min|by:\(who)|reason:\(reason)"
    }

    /// 中断确认结果 → 备注标记（保留"这段时间为什么算/不算"的来源）。
    static func interruptionDecisionNote(studiedDuringGap: Bool, gapMinutes: Int) -> String {
        studiedDuringGap
            ? "interruption:gap-\(gapMinutes)min|counted"
            : "interruption:gap-\(gapMinutes)min|excluded"
    }

    /// 是否有手动修正记录。
    static func hasManualAdjustment(_ session: StudySession) -> Bool {
        session.note.contains("manualAdjustment:")
    }

    // MARK: 小工具

    /// 事件幂等键。
    func eventKey(event: StudySessionEvent) -> String { event.idempotencyKey }

    /// 累加两次范围；量纲不同则不累加（宁可少算，也不做假换算）。
    static func accumulating(_ base: StudyScope, with addition: StudyScope) -> StudyScope {
        if base.isZero { return addition }
        guard base.isComparable(to: addition) else { return base }
        return StudyScope(
            unit: base.unit,
            amount: base.amount + addition.amount,
            customUnitLabel: base.customUnitLabel
        )
    }

    /// 合并结束时提交的范围与已累计范围：同量纲取较大值（用户明确提交的值优先），
    /// 不同量纲时保留已有进度，不换算。
    static func merging(_ progress: StudyScope, with submitted: StudyScope) -> StudyScope {
        if progress.isZero { return submitted }
        guard progress.isComparable(to: submitted) else { return progress }
        return StudyScope(
            unit: progress.unit,
            amount: max(progress.amount, submitted.amount),
            customUnitLabel: progress.customUnitLabel
        )
    }

    static func appendingNote(_ addition: String, to existing: String) -> String {
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else { return trimmedAddition }
        guard !trimmedAddition.isEmpty else { return trimmedExisting }
        return trimmedExisting + "\n" + trimmedAddition
    }
}

// MARK: - 恢复与展示辅助

extension StudySession {
    /// 恢复后的展示快照：进程重启后没有单调时钟，直接用持久化时间戳。
    func restartDisplayMinutes(context: PlanningContext) -> Int {
        effectiveMinutes(asOf: context.now, calendar: context.calendar)
    }

    /// 追加一条备注（纯值操作，供"手动修正来源"使用）。
    func appending(note: String) -> StudySession {
        var copy = self
        copy.note = StudySessionEngineImpl.appendingNote(note, to: copy.note)
        return copy
    }
}

extension StoreSnapshot {
    /// 全局是否已经有有效会话（同一时刻只允许一个）。
    var activeStudySessions: [StudySession] {
        studySessions.filter { $0.state.isActive }
    }

    /// 需要用户确认中断的会话（切后台 / 崩溃后恢复）。
    func sessionsAwaitingInterruptionDecision(
        engine: StudySessionEngineImpl = StudySessionEngineImpl(),
        context: PlanningContext
    ) -> [StudySession] {
        activeStudySessions.filter { engine.interruptionCandidate(for: $0, context: context) != nil }
    }
}
