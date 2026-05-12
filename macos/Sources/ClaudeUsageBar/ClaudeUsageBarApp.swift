import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    // v0.2.5 多供应商重构：用 ProviderCoordinator 装配（内部注册 Claude provider = UsageService）。
    // Claude 的 OAuth/refresh/多账号/polling/backoff 等仍在 coordinator.claude（= UsageService）里，
    // v0.2.11：所有 provider 的后台轮询由 coordinator.startBackgroundPolling() 的统一 timer 管（含 Claude）。
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
                    // 首次 refresh 本机 JSONL 统计（之后随后台 tick 的 onPollTick 继续更新）
                    await usageStats.refresh()
                    await codexStats.refresh()
                    // 各 provider 的本机统计刷新随后台 tick 走 onPollTick（Claude 的逻辑原在已退役的 UsageService timer 里）—— 必须在 startBackgroundPolling 之前设好。
                    coordinator.claude.onPollTick = { Task.detached { await usageStats.refresh() } }
                    coordinator.provider(.codex)?.onPollTick = { Task.detached { await codexStats.refresh() } }
                    // 起统一后台 timer（覆盖所有 enabled provider，含 Claude；监听 pollingMinutes 变化自动重起）+ 立即各拉一次（这一次就拉了 Claude）。
                    coordinator.startBackgroundPolling()
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
