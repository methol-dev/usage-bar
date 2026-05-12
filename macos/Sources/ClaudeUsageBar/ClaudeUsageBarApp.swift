import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    // v0.2.5 多供应商重构：用 ProviderCoordinator 装配（内部注册 Claude provider = UsageService）。
    // Claude 的 OAuth/refresh/多账号/polling/backoff 等仍在 coordinator.claude（= UsageService）里，
    // coordinator 本版本不跑 timer——polling 仍由 coordinator.claude.startPolling() 起。
    @StateObject private var coordinator = ProviderCoordinator(claude: UsageService(),
                                                               additionalProviders: [CodexProvider()])
    @StateObject private var historyService = UsageHistoryService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var appUpdater = AppUpdater()
    @StateObject private var usageStats = UsageStatsService.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                coordinator: coordinator,
                claude: coordinator.claude,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater
            )
            .environmentObject(usageStats)
        } label: {
            MenuBarLabel(
                runtime: coordinator.primaryRuntime,
                historyService: historyService,
                showTrend: coordinator.primaryProviderID == .claude
            )
                .task {
                    // 退役 v0.1.2 的 cost-usage cache（已被 ~/.config/claude-usage-bar/data/ 取代）
                    if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                        try? FileManager.default.removeItem(at: caches.appendingPathComponent("claude-usage-bar/cost-usage", isDirectory: true))
                    }
                    historyService.loadHistory()
                    coordinator.claude.historyService = historyService
                    coordinator.claude.notificationService = notificationService
                    // v0.1.1: 启动期尝试复用 Claude CLI 凭证（Keychain 'Claude Code-credentials'）
                    // 内部已用 Task.detached 避免主线程阻塞
                    await coordinator.claude.bootstrapFromCLIIfNeeded()
                    // bootstrap 成功或本来已 sign in 的用户：标记 setup 完成不显示 SetupView
                    if coordinator.claude.isAuthenticated && !UserDefaults.standard.bool(forKey: "setupComplete") {
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                    }
                    // 首次 refresh 本机 JSONL 统计（polling timer 内会继续更新）
                    await usageStats.refresh()
                    coordinator.claude.startPolling()
                    // Codex provider 的 5 分钟轻量采样（给 popover 的趋势箭头 / 折线图供数）；
                    // 它 supportsBackgroundPolling 仍 false（不上菜单栏），但有自己的 refresh timer。
                    if let codex = coordinator.provider(.codex) as? CodexProvider {
                        codex.startPolling()
                    }
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(
                coordinator: coordinator,
                service: coordinator.claude,
                notificationService: notificationService
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}
