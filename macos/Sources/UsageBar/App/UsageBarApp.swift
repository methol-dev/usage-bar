import SwiftUI

// 注:入口不再用 `@main` —— 由 `App/main.swift` 顶层代码分流(正常启动 vs `--native-host`)。
@MainActor
struct UsageBarApp: App {
    // v0.2.5 多供应商重构：用 ProviderCoordinator 装配（内部注册 Claude provider = UsageService）。
    // Claude 的 OAuth/refresh/多账号/polling/backoff 等仍在 coordinator.claude（= UsageService）里，
    // v0.2.11：所有 provider 的后台轮询由 coordinator.startBackgroundPolling() 的统一 timer 管（含 Claude）。
    // v0.3: Claude Web 降为 Claude 的一个数据源（ADR 0010）—— 不再作为独立 provider 装配；
    // ClaudeWebProvider 由 ProviderCoordinator 内部构造并挂在 Claude 门面 `claudeGroup` 下。
    // ADR 0012: Codex 同样多源（CLI + Web）—— 注入裸 `CodexProvider` 作 `codex:`，coordinator 内部
    // 构造 `codexGroup`（挂 CodexWebProvider），`.codex` 顶层注册的是门面而非裸 provider。
    @State private var coordinator = ProviderCoordinator(claude: UsageService(),
                                                         codex: CodexProvider(),
                                                         additionalProviders: [
                                                             GeminiProvider()
                                                         ])
    @State private var historyService = UsageHistoryService()
    @State private var notificationService = NotificationService()
    @State private var appUpdater = AppUpdater()
    @State private var usageStats = UsageStatsService.shared
    @State private var codexStats = UsageStatsService(provider: .codex)

    var body: some Scene {
        MenuBarExtra {
            PopoverView(
                coordinator: coordinator,
                historyService: historyService,
                notificationService: notificationService,
                appUpdater: appUpdater,
                usageStats: usageStats,
                codexStats: codexStats
            )
        } label: {
            // 所有已启用且已注册的 provider 并排展示（按 orderedProviderIDs 顺序）
            MultiMenuBarLabel(coordinator: coordinator)
                .task {
                    // 迁移旧 "percentWithTrend" → "percentWithPace"
                    if let stored = UserDefaults.standard.string(forKey: MenuBarDisplayMode.storageKey),
                       stored == "percentWithTrend" {
                        UserDefaults.standard.set(MenuBarDisplayMode.percentWithPace.rawValue,
                                                  forKey: MenuBarDisplayMode.storageKey)
                    }
                    // 退役 v0.1.2 的 cost-usage cache（已被 ~/.config/usage-bar/data/ 取代）
                    if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                        try? FileManager.default.removeItem(at: caches.appendingPathComponent("usage-bar/cost-usage", isDirectory: true))
                    }
                    // Claude Web 源:幂等重写 Chrome native messaging host manifest（指向当前 .app 主 binary）。
                    // 仅正常启动路径走到这里（native-host 模式在 main.swift 已 exit）。
                    NativeHostInstaller.install()
                    historyService.loadHistory()
                    coordinator.claude.historyService = historyService
                    coordinator.claude.notificationService = notificationService
                    // v0.1.1: 启动期尝试复用 Claude CLI 凭证（Keychain 'Claude Code-credentials'）
                    // 内部已用 Task.detached 避免主线程阻塞
                    await coordinator.claude.retrySignIn()
                    // 首次 refresh 本机 JSONL 统计（之后随后台 tick 的 onPollTick 继续更新）
                    await usageStats.refresh()
                    await codexStats.refresh()
                    // 各 provider 的本机统计刷新随后台 tick 走 onPollTick —— 必须在 startBackgroundPolling 之前设好。
                    // Claude 挂在**门面**上（后台 tick 调的是 registry 里注册的 `.claude` = 门面）；本机 JSONL 统计
                    // 每 tick 都刷（与门面选 cli 还是 web 取数无关，故不受「命中即停」影响）。
                    coordinator.claudeGroup.onPollTick = { Task { await usageStats.refresh() } }
                    // Codex 门面（若注入）每 tick 刷本机 JSONL 统计；与门面选 cli/web 取数无关（同 Claude）。
                    coordinator.codexGroup?.onPollTick = { Task { await codexStats.refresh() } }
                    // 起统一后台 timer（覆盖所有 enabled provider，含 Claude；监听 pollingMinutes 变化自动重起）+ 立即各拉一次（这一次就拉了 Claude）。
                    coordinator.startBackgroundPolling()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(
                coordinator: coordinator,
                service: coordinator.claude,
                notificationService: notificationService,
                appUpdater: appUpdater
            )
        }
        // 窗口紧贴内容尺寸（内容已固定 width 480 + 有上限的可滚动高度）——避免窗口比内容宽一大截、
        // 内容浮在灰底里。高度有 maxHeight 上限 + Form 内部滚动，不会再占满屏。
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}
