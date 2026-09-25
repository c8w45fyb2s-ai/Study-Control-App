import Foundation

// MARK: - G 模块：运行时环境与数据路径隔离
//
// 约束（公共开发约束 3）：
// 开发与测试必须使用独立的临时存储，绝不读写用户真实的 `store.json`。
//
// 实现方式：
// - 默认（正式运行）：`~/Library/Application Support/StudyCompanion`。
// - 设置了 `STUDYCOMPANION_STORE_DIR`：使用该目录（自动化测试 / 手动验收）。
// - 设置了 `STUDYCOMPANION_TEST_MODE=1`：自动落到系统临时目录下的独立子目录，
//   并且关闭系统通知，避免测试期间弹出真实提醒。
//
// 这个类型只做"路径与环境判定"，不读写文件、不修改全局状态。

/// 运行环境开关。
struct StudyRuntimeEnvironment: Sendable {
    /// 是否处于隔离测试模式。
    var isTestMode: Bool
    /// 是否允许使用系统通知（测试模式下强制关闭）。
    var allowsSystemNotifications: Bool
    /// 存储位置。
    var storeLocation: SnapshotStoreLocation
    /// 判定来源说明，用于诊断记录（例如"使用了 STUDYCOMPANION_STORE_DIR"）。
    var storeLocationOrigin: String

    static let storeDirectoryEnvironmentKey = "STUDYCOMPANION_STORE_DIR"
    static let testModeEnvironmentKey = "STUDYCOMPANION_TEST_MODE"
    static let disableNotificationsEnvironmentKey = "STUDYCOMPANION_DISABLE_NOTIFICATIONS"

    /// 从进程环境解析。
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> StudyRuntimeEnvironment {
        let testMode = isEnabled(environment[testModeEnvironmentKey])
        let notificationsDisabled = isEnabled(environment[disableNotificationsEnvironmentKey])

        let explicitDirectory = environment[storeDirectoryEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let explicitDirectory, !explicitDirectory.isEmpty {
            let url = URL(fileURLWithPath: (explicitDirectory as NSString).expandingTildeInPath, isDirectory: true)
            return StudyRuntimeEnvironment(
                isTestMode: testMode,
                allowsSystemNotifications: !testMode && !notificationsDisabled,
                storeLocation: SnapshotStoreLocation(directory: url),
                storeLocationOrigin: "\(storeDirectoryEnvironmentKey)=\(url.path)"
            )
        }

        if testMode {
            // 每次启动一个独立子目录，测试之间不会互相污染，也绝不触碰真实数据。
            let base = fileManager.temporaryDirectory
                .appendingPathComponent("StudyCompanionIsolated", isDirectory: true)
            let directory = base.appendingPathComponent(ProcessInfo.processInfo.processIdentifier.description, isDirectory: true)
            return StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: SnapshotStoreLocation(directory: directory),
                storeLocationOrigin: "\(testModeEnvironmentKey)=1（隔离临时目录）"
            )
        }

        return StudyRuntimeEnvironment(
            isTestMode: false,
            allowsSystemNotifications: !notificationsDisabled,
            storeLocation: .applicationSupport(fileManager: fileManager),
            storeLocationOrigin: "默认 Application Support"
        )
    }

    /// 是否为"隔离数据路径"（测试或显式指定）。
    var isIsolatedStore: Bool {
        isTestMode || storeLocationOrigin.hasPrefix(Self.storeDirectoryEnvironmentKey)
    }

    private static func isEnabled(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["1", "true", "yes", "y", "on"].contains(raw)
    }
}
