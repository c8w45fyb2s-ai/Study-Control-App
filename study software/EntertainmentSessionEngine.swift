import Foundation

// MARK: - E 模块：娱乐计时引擎
//
// 本文件是 E 模块内部的计时工具，仍然遵守公共约束：
// - 纯计算：不写文件、不发通知、不改全局 AppStore；
// - 所有时间由调用方传入，绝不自己调用 `Date()`；
// - 需要落盘 / 发通知时，只返回**意图**（`EntertainmentSessionIntent`），由 G 执行。
//
// 三条产品约束：
// 1. 剩余时长完全由「持久化的 `startedAt` + `grantedMinutes` − `usedMinutes`」推导，
//    切后台、锁屏、杀进程后重新进入都会按保存的时间重算，不依赖常驻定时器。
// 2. 默认当天使用：跨学习日的奖励拒绝开始，避免无限累积。
// 3. 一次只允许一个娱乐计时。

// MARK: - 状态

enum EntertainmentSessionState: String, Codable, Hashable, Sendable {
    /// 已领取/待领取，尚未开始。
    case notStarted
    /// 正在计时。
    case running
    /// 已经结束。
    case finished
    /// 已撤销（依据的学习完成被撤销）。
    case revoked
    /// 当天不可用：奖励属于其他学习日，或已过期。
    case unavailable

    var label: String {
        switch self {
        case .notStarted: return "未开始"
        case .running: return "娱乐中"
        case .finished: return "已结束"
        case .revoked: return "已撤销"
        case .unavailable: return "已失效"
        }
    }
}

/// 某一时刻的计时快照（由持久化字段推导，不依赖内存定时器）。
struct EntertainmentTimerSnapshot: Hashable, Sendable {
    var grantID: UUID
    var ruleName: String
    var ruleVersion: Int
    var dayKey: StudyDayKey
    var grantedMinutes: Int
    var usedMinutes: Int
    var state: EntertainmentSessionState
    var startedAt: Date?
    var endsAt: Date?
    var elapsedSeconds: Int
    var remainingSeconds: Int
    /// 该奖励是否属于"今天"，只有当天可用。
    var isUsableToday: Bool
    var canStart: Bool
    /// 面向界面的说明文案。
    var statusText: String

    var remainingMinutesCeiling: Int {
        Int((Double(remainingSeconds) / 60).rounded(.up))
    }
}

// MARK: - 操作与意图

enum EntertainmentSessionAction: String, Codable, Hashable, Sendable {
    case claim
    case start
    case finish
    /// 页面刷新 / 回到前台 / 到点。
    case refresh
}

/// 需要 G 执行的副作用意图。算法本身不落盘、不发通知。
enum EntertainmentSessionIntent: Hashable, Sendable {
    case requestClaim(grantID: UUID)
    case requestStart(grantID: UUID)
    case requestFinish(grantID: UUID, usedMinutes: Int)
    case scheduleEndNotification(grantID: UUID, fireDate: Date, title: String)
    case cancelEndNotification(grantID: UUID, title: String)

    var isNotificationIntent: Bool {
        switch self {
        case .scheduleEndNotification, .cancelEndNotification: return true
        default: return false
        }
    }
}

struct EntertainmentSessionTransition: Hashable, Sendable {
    var snapshot: EntertainmentTimerSnapshot
    var intents: [EntertainmentSessionIntent]
    var rejection: String?
    var statusText: String

    init(
        snapshot: EntertainmentTimerSnapshot,
        intents: [EntertainmentSessionIntent] = [],
        rejection: String? = nil,
        statusText: String = ""
    ) {
        self.snapshot = snapshot
        self.intents = intents
        self.rejection = rejection
        self.statusText = statusText
    }

    var didRequestChange: Bool { !intents.isEmpty }
}

// MARK: - 引擎

struct EntertainmentSessionEngine {

    /// 到点提醒的统一标题。
    ///
    /// 提醒标识由标题派生（契约的 `ReminderChangeRequest` 没有 grantID 字段），
    /// 因此排期与取消必须使用同一个标题，否则取消不掉。
    static func endNotificationTitle(ruleName: String) -> String {
        "娱乐时间到（\(ruleName)）"
    }

    // MARK: 纯推导

    /// 已计入的有效秒数：结束时写入的 `usedMinutes` 加上当前运行段的时长。
    static func elapsedSeconds(for grant: RewardGrant, at now: Date) -> Int {
        let totalSeconds = max(0, grant.grantedMinutes) * 60
        var elapsed = max(0, grant.usedMinutes) * 60
        if grant.state == .started, let startedAt = grant.startedAt {
            elapsed += max(0, Int(now.timeIntervalSince(startedAt).rounded(.down)))
        }
        return min(elapsed, totalSeconds)
    }

    static func remainingSeconds(for grant: RewardGrant, at now: Date) -> Int {
        max(0, max(0, grant.grantedMinutes) * 60 - elapsedSeconds(for: grant, at: now))
    }

    /// 预计结束时刻；未在计时中返回 `nil`。
    static func endsAt(for grant: RewardGrant) -> Date? {
        guard grant.state == .started, let startedAt = grant.startedAt else { return nil }
        let totalSeconds = max(0, grant.grantedMinutes) * 60
        let alreadySeconds = max(0, grant.usedMinutes) * 60
        return startedAt.addingTimeInterval(Double(max(0, totalSeconds - alreadySeconds)))
    }

    /// 该奖励是否还能使用：未撤销、未结束、且属于今天。
    static func isUsableToday(_ grant: RewardGrant, context: PlanningContext) -> Bool {
        guard !grant.isRevoked else { return false }
        guard grant.state == .pending || grant.state == .claimed || grant.state == .started else { return false }
        return grant.dayKey == context.todayKey
    }

    static func state(of grant: RewardGrant, context: PlanningContext) -> EntertainmentSessionState {
        if grant.isRevoked || grant.state == .revoked { return .revoked }
        switch grant.state {
        case .pending, .claimed:
            return grant.dayKey == context.todayKey ? .notStarted : .unavailable
        case .started:
            // 已经开始的计时不因跨日或规则版本变化而失去结束入口。
            return .running
        case .finished:
            return .finished
        case .expired:
            return .unavailable
        case .revoked:
            return .revoked
        }
    }

    /// 正在计时的奖励（一次只允许一个）。
    static func runningGrant(in grants: [RewardGrant]) -> RewardGrant? {
        grants.first { $0.state == .started && !$0.isRevoked }
    }

    /// 仍然挂在过去学习日、且从未结束的奖励：可以标记为已过期（不无限累积）。
    static func staleGrantIDs(in grants: [RewardGrant], before dayKey: StudyDayKey) -> [UUID] {
        grants
            .filter { ($0.state == .pending || $0.state == .claimed) && $0.dayKey < dayKey && !$0.isRevoked }
            .map(\.id)
    }

    // MARK: 快照

    static func snapshot(
        for grant: RewardGrant,
        at now: Date,
        context: PlanningContext,
        runningGrantID: UUID?
    ) -> EntertainmentTimerSnapshot {
        let state = state(of: grant, context: context)
        let elapsed = elapsedSeconds(for: grant, at: now)
        let remaining = max(0, max(0, grant.grantedMinutes) * 60 - elapsed)
        let usable = isUsableToday(grant, context: context)

        var canStart = usable && remaining > 0 && state != .finished
        if let runningGrantID, runningGrantID != grant.id { canStart = false }

        let statusText: String
        switch state {
        case .running:
            statusText = remaining > 0
                ? "娱乐中，剩余 \(Int((Double(remaining) / 60).rounded(.up))) 分钟。"
                : "娱乐时间已用完。"
        case .notStarted:
            statusText = "可领取 \(grant.grantedMinutes) 分钟。"
        case .finished:
            statusText = "已结束，本次使用 \(grant.usedMinutes) 分钟。"
        case .revoked:
            statusText = "奖励已撤销：\(grant.revocation?.reason ?? "依据的学习完成被撤销")。"
        case .unavailable:
            statusText = "仅限当天使用，该奖励属于 \(grant.dayKey.localDateString)，已失效。"
        }

        return EntertainmentTimerSnapshot(
            grantID: grant.id,
            ruleName: grant.ruleSnapshot.name,
            ruleVersion: grant.ruleVersion,
            dayKey: grant.dayKey,
            grantedMinutes: grant.grantedMinutes,
            usedMinutes: grant.usedMinutes,
            state: state,
            startedAt: grant.startedAt,
            endsAt: endsAt(for: grant),
            elapsedSeconds: elapsed,
            remainingSeconds: remaining,
            isUsableToday: usable,
            canStart: canStart,
            statusText: statusText
        )
    }

    // MARK: 操作

    static func step(
        _ action: EntertainmentSessionAction,
        grant: RewardGrant,
        at now: Date,
        context: PlanningContext,
        runningGrantID: UUID?
    ) -> EntertainmentSessionTransition {
        let current = snapshot(for: grant, at: now, context: context, runningGrantID: runningGrantID)

        switch action {
        case .claim:
            if current.state == .revoked {
                return EntertainmentSessionTransition(snapshot: current, intents: [], rejection: current.statusText, statusText: current.statusText)
            }
            if current.state == .notStarted, grant.state == .claimed {
                return EntertainmentSessionTransition(snapshot: current, intents: [], rejection: nil, statusText: "奖励已经领取。")
            }
            guard current.state == .notStarted else {
                return EntertainmentSessionTransition(snapshot: current, intents: [], rejection: current.statusText, statusText: current.statusText)
            }
            return EntertainmentSessionTransition(
                snapshot: current,
                intents: [.requestClaim(grantID: grant.id)],
                statusText: "已领取「\(current.ruleName)」\(current.grantedMinutes) 分钟。"
            )

        case .start:
            if current.state == .revoked || current.state == .unavailable || current.state == .finished {
                return EntertainmentSessionTransition(snapshot: current, rejection: current.statusText, statusText: current.statusText)
            }
            if current.state == .running {
                return EntertainmentSessionTransition(snapshot: current, statusText: "「\(current.ruleName)」已经在计时中。")
            }
            if let runningGrantID {
                if runningGrantID == grant.id {
                    // 调用方说"这条正在计时"，以它为准：不重复开始、不重复排提醒。
                    return EntertainmentSessionTransition(snapshot: current, statusText: "「\(current.ruleName)」已经在计时中。")
                }
                let message = "同一时间只能运行一个娱乐计时，请先结束当前计时。"
                return EntertainmentSessionTransition(snapshot: current, rejection: message, statusText: message)
            }
            guard current.remainingSeconds > 0 else {
                let message = "剩余时长为 0，无法开始。"
                return EntertainmentSessionTransition(snapshot: current, intents: [], rejection: message, statusText: message)
            }

            var intents: [EntertainmentSessionIntent] = [.requestStart(grantID: grant.id)]
            // 到时提醒只是"需求"：没有通知权限时页面内计时照常工作。
            let fireDate = now.addingTimeInterval(Double(current.remainingSeconds))
            intents.append(.scheduleEndNotification(
                grantID: grant.id,
                fireDate: fireDate,
                title: endNotificationTitle(ruleName: current.ruleName)
            ))
            return EntertainmentSessionTransition(
                snapshot: current,
                intents: intents,
                statusText: "开始「\(current.ruleName)」，共 \(current.remainingMinutesCeiling) 分钟。"
            )

        case .finish:
            if grant.state == .started, !grant.isRevoked {
                let usedMinutes = min(current.grantedMinutes, current.snapshotUsedMinutesCeiling)
                return EntertainmentSessionTransition(
                    snapshot: current,
                    intents: [
                        .requestFinish(grantID: grant.id, usedMinutes: usedMinutes),
                        .cancelEndNotification(grantID: grant.id, title: endNotificationTitle(ruleName: current.ruleName))
                    ],
                    statusText: "结束娱乐计时，本次使用 \(usedMinutes) 分钟。"
                )
            }
            if current.state == .finished {
                return EntertainmentSessionTransition(snapshot: current, statusText: "这次娱乐已经结束。")
            }
            return EntertainmentSessionTransition(snapshot: current, rejection: "还没有开始计时。", statusText: "还没有开始计时。")

        case .refresh:
            let shouldAutoFinish = grant.state == .started && !grant.isRevoked
                && (current.remainingSeconds == 0 || !current.isUsableToday)
            if shouldAutoFinish {
                // 到时或跨天：结束计时并取消提醒。剩余时长由时间戳算出，不依赖界面定时器。
                let usedMinutes = min(current.grantedMinutes, current.snapshotUsedMinutesCeiling)
                return EntertainmentSessionTransition(
                    snapshot: current,
                    intents: [
                        .requestFinish(grantID: grant.id, usedMinutes: usedMinutes),
                        .cancelEndNotification(grantID: grant.id, title: endNotificationTitle(ruleName: current.ruleName))
                    ],
                    statusText: current.remainingSeconds == 0 ? "娱乐时间已用完，自动结束。" : "该奖励已跨天失效，自动结束计时。"
                )
            }
            if current.state == .unavailable, grant.state == .pending || grant.state == .claimed {
                return EntertainmentSessionTransition(
                    snapshot: current,
                    intents: [.cancelEndNotification(grantID: grant.id, title: endNotificationTitle(ruleName: current.ruleName))],
                    statusText: current.statusText
                )
            }
            return EntertainmentSessionTransition(snapshot: current, statusText: current.statusText)
        }
    }
}

private extension EntertainmentTimerSnapshot {
    /// 已经过完整分钟数（向上取整），用于结束时的记账。
    var snapshotUsedMinutesCeiling: Int {
        Int((Double(elapsedSeconds) / 60).rounded(.up))
    }
}
