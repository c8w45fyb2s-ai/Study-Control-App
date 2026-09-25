import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct StudyCompanionApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("学习助手") {
                ContentView()
                    .environmentObject(store)
                    .tint(StudyDesign.Colors.primary)
                    .preferredColorScheme(store.settings.appearanceMode.preferredColorScheme)
                    .task { await store.handleForegroundActivation() }
                    .onChange(of: scenePhase) { _, phase in
                        switch phase {
                        case .active:
                            // 前台激活：检查日期、时区与计划有效性，必要时立即刷新。
                            Task { await store.handleForegroundActivation() }
                        case .inactive, .background:
                            // 失活/切后台：把会话心跳推进到"此刻"，
                            // 这样崩溃或重启后未知离线时间只从最后一次心跳开始算。
                            store.markSessionHeartbeat()
                        @unknown default:
                            break
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                        // 前台跨日由系统日历通知立刻触发，不依赖零点后台执行。
                        Task { await store.handleForegroundActivation() }
                    }
                    .onReceive(significantTimeChangePublisher) { _ in
                        // 时区/系统时间变化：重新评估未来安排。
                        Task { await store.handleForegroundActivation() }
                    }
#if os(macOS)
                .frame(minWidth: 920, minHeight: 640)
#endif
        }
#if os(macOS)
        .windowStyle(.titleBar)
#endif
    }

    /// 系统时间/时区变化通知：iOS 与 macOS 使用不同的通知名。
    private var significantTimeChangePublisher: NotificationCenter.Publisher {
        #if os(iOS)
        return NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
        #else
        return NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)
        #endif
    }
}

private extension AppAppearanceMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
