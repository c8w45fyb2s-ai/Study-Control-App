import Foundation
import UserNotifications

// MARK: - G 模块：本地通知调度
//
// 设计约束（G 的通知要求）：
// - **稳定 ID**：同一条提醒在多次刷新后仍是同一个 identifier，不会重复堆积。
// - **权限只请求一次**：首次启用提醒时请求；普通刷新只查询状态，不再弹窗。
// - **无权限可用**：拒绝或不可用时静默降级，所有业务功能照常工作。
// - **数量上限**：只安排有限的近期提醒（由协调器决定，默认 3 条 + 1 条汇总），
//   避免系统通知上限与"为大量逾期任务集中轰炸"。
// - **失败可诊断**：返回 `NotificationSyncReport`，由调用方单独记录，
//   **不回滚**已经保存的学习或奖励记录。
//
// 本类型不做业务判断（哪些任务、什么时间提醒由 `StudyPlanCoordinator` 决定）。

/// 一次通知同步的结果。
struct NotificationSyncReport: Sendable {
    struct Failure: Sendable {
        var identifier: String
        var reason: String
    }

    /// 是否已获得通知权限。
    var isAuthorized: Bool = false
    /// 是否因为环境（测试 / 显式关闭）跳过了系统通知。
    var didSkipBecauseDisabled: Bool = false
    var scheduledCount: Int = 0
    var cancelledCount: Int = 0
    /// 单条提醒失败的原因（不抛错，不影响业务提交）。
    var failures: [Failure] = []
    /// 请求过的标识（用于诊断与去重检查）。
    var scheduledIdentifiers: [String] = []
    /// 本次同步在中途被更新的一次同步取代（旧请求不再影响通知）。
    var wasSuperseded: Bool = false

    var hasFailures: Bool { !failures.isEmpty }

    var summaryText: String {
        if didSkipBecauseDisabled { return "已跳过系统通知（当前环境未启用通知）。" }
        if !isAuthorized { return "没有通知权限：提醒未安排，学习与奖励功能不受影响。" }
        var parts: [String] = []
        if scheduledCount > 0 { parts.append("已安排 \(scheduledCount) 条提醒") }
        if cancelledCount > 0 { parts.append("已清理 \(cancelledCount) 条旧提醒") }
        if hasFailures { parts.append("\(failures.count) 条提醒安排失败") }
        return parts.isEmpty ? "提醒没有变化。" : parts.joined(separator: "，") + "。"
    }
}

enum NotificationScheduler {
    // MARK: 稳定 ID 前缀

    // MARK: 权限状态（进程内缓存，避免反复弹窗）

    private static let lock = NSLock()
    private static var cachedAuthorization: UNAuthorizationStatus = .notDetermined
    private static var didRequestAuthorization = false

    private static func store(_ status: UNAuthorizationStatus) {
        lock.lock()
        cachedAuthorization = status
        lock.unlock()
    }

    private static var isAlreadyRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didRequestAuthorization
    }

    private static func markRequested() {
        lock.lock()
        didRequestAuthorization = true
        lock.unlock()
    }

    /// 查询（不请求）当前授权状态。
    @discardableResult
    static func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        store(settings.authorizationStatus)
        return settings.authorizationStatus
    }

    /// 首次启用提醒时请求授权；已经请求过就不再弹窗。
    @discardableResult
    static func requestAuthorizationIfNeeded(force: Bool = false) async -> Bool {
        let status = await refreshAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            if !force && isAlreadyRequested { return false }
            markRequested()
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshAuthorizationStatus()
            return granted
        @unknown default:
            return false
        }
    }

    /// 兼容旧入口：显式请求授权。
    static func requestAuthorization() async -> Bool {
        await requestAuthorizationIfNeeded(force: true)
    }

    // MARK: 统一入口（由 AppStore 在保存成功后调用）

    /// 应用协调器产出的通知意图。
    ///
    /// 执行顺序与并发规则（需求 10）：
    /// - 只在业务保存成功后被调用（调用方负责）；
    /// - 每次调用占用一个新的同步代次，后发起的同步会让先前的同步作废，
    ///   因此旧请求不会覆盖新计划的提醒；
    /// - 同一批次内按稳定标识去重：同一条提醒在一次同步里只安排一次；
    /// - 失败逐条记录，交给调用方写诊断，不回滚任何已保存的数据。
    ///
    /// - Parameter now: 外部注入的当前时间（统一时间处理）。
    @discardableResult
    static func apply(
        _ changes: [ReminderChangeRequest],
        environment: StudyRuntimeEnvironment,
        now: Date = Date()
    ) async -> NotificationSyncReport {
        var report = NotificationSyncReport()
        guard environment.allowsSystemNotifications else {
            report.didSkipBecauseDisabled = true
            return report
        }
        guard !changes.isEmpty else {
            report.isAuthorized = true
            return report
        }

        let generation = beginGeneration()
        let center = UNUserNotificationCenter.current()
        var authorized = false
        var authorizationChecked = false

        let batch = ReminderBatch.make(from: changes)
        let scheduledChanges = batch.scheduledChanges

        if batch.cancelsAllManaged {
            let managed = await managedIdentifiers()
            let removable = managed.filter { !scheduledChanges.keys.contains($0) }
            if !removable.isEmpty {
                guard isCurrent(generation) else { return reportMarkingStale(report) }
                center.removePendingNotificationRequests(withIdentifiers: removable)
                report.cancelledCount += removable.count
            }
        }

        for identifier in batch.cancelledIdentifiers {
            guard isCurrent(generation) else { return reportMarkingStale(report) }
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            report.cancelledCount += 1
        }

        for (identifier, change) in scheduledChanges.sorted(by: { $0.key < $1.key }) {
            if !authorizationChecked {
                authorized = await requestAuthorizationIfNeeded()
                authorizationChecked = true
                report.isAuthorized = authorized
            }
            guard authorized else { continue }

            guard let fireDate = change.fireDate, fireDate > now else {
                // 没有合适的提醒时间：取消这条提醒，而不是硬安排一个过去的时间。
                guard isCurrent(generation) else { return reportMarkingStale(report) }
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                report.cancelledCount += 1
                continue
            }
            guard isCurrent(generation) else { return reportMarkingStale(report) }

            let content = UNMutableNotificationContent()
            content.title = change.kind == .entertainmentEnd ? "娱乐时间到" : "学习提醒"
            content.body = change.title.isEmpty ? "该学习了" : change.title
            content.sound = .default

            do {
                try await addOrThrow(identifier: identifier, content: content, fireDate: fireDate)
                guard isCurrent(generation) else { return reportMarkingStale(report) }
                report.scheduledCount += 1
                report.scheduledIdentifiers.append(identifier)
            } catch {
                report.failures.append(
                    NotificationSyncReport.Failure(identifier: identifier, reason: error.localizedDescription)
                )
            }
        }

        if !authorizationChecked {
            report.isAuthorized = await requestAuthorizationIfNeeded()
        }
        return report
    }

    /// 被更新的一次同步取代时，如实标记而不是照旧执行。
    private static func reportMarkingStale(_ report: NotificationSyncReport) -> NotificationSyncReport {
        var updated = report
        updated.wasSuperseded = true
        return updated
    }

    /// 娱乐计时到期提醒（稳定的 grant ID）。
    @discardableResult
    static func scheduleEntertainmentEnd(
        grantID: UUID,
        title: String,
        fireDate: Date,
        environment: StudyRuntimeEnvironment,
        now: Date = Date()
    ) async -> NotificationSyncReport {
        guard fireDate > now else { return NotificationSyncReport(isAuthorized: true) }
        let request = ReminderChangeRequest(
            action: .schedule,
            planItemID: nil,
            fireDate: fireDate,
            title: title,
            kind: .entertainmentEnd,
            businessID: grantID.uuidString
        )
        return await apply([request], environment: environment, now: now)
    }

    // MARK: 查询

    /// 当前挂起的提醒标识。
    static func pendingIdentifiers() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    /// 指定前缀的挂起提醒标识。
    static func pendingIdentifiers(matching kind: ReminderKind) async -> [String] {
        await pendingIdentifiers().filter { $0.hasPrefix(kind.identifierPrefix) }
    }

    /// 所有由本 App 统一管理的提醒标识（覆盖全部类型）。
    static func managedIdentifiers() async -> [String] {
        await pendingIdentifiers().filter { isManaged(identifier: $0) }
    }

    // MARK: 内部

    /// 该类型是否由通知调度统一管理。
    static func isManaged(identifier: String) -> Bool {
        ReminderKind.allCases.contains { identifier.hasPrefix($0.identifierPrefix) }
    }

    // MARK: 并发同步保护

    /// 同步代次：后发起的同步会让先前的同步作废，避免旧请求覆盖新计划的提醒。
    private static var applyGeneration = 0

    private static func beginGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        applyGeneration += 1
        return applyGeneration
    }

    private static func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == applyGeneration
    }

    // MARK: 写入系统通知

    private static func addOrThrow(
        identifier: String,
        content: UNMutableNotificationContent,
        fireDate: Date,
        calendar: Calendar = Calendar.current
    ) async throws {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }
}
