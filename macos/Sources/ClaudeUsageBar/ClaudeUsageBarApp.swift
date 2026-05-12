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
    @StateObject private var codexStats = UsageStatsService(provider: .codex)

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                coordinator: coordinator,
                claude: coordinator.claude,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater,
                codexStats: codexStats
            )
            .environmentObject(usageStats)
        } label: {
            MenuBarLabel(
                runtime: coordinator.menuBarRuntime,
                historyService: historyService,
                showTrend: coordinator.menuBarProviderID == .claude,
                providerID: coordinator.menuBarProviderID
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
                    await codexStats.refresh()
                    coordinator.claude.startPolling()
                    // 非-Claude provider 的统一后台 timer（与 Claude 用同一个 `pollingMinutes`）：每 tick 各 refreshNow + onPollTick；
                    // Codex 的 onPollTick 驱动 codexStats（本机 session 扫描）走同一节奏。Claude 的 timer/backoff 仍归 UsageService。
                    coordinator.startBackgroundPolling(codexOnPollTick: { Task.detached { await codexStats.refresh() } })
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
