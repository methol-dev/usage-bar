import SwiftUI

struct PopoverView: View {
    let coordinator: ProviderCoordinator
    let claude: UsageService
    let historyService: UsageHistoryService
    let notificationService: NotificationService
    let appUpdater: AppUpdater
    let usageStats: UsageStatsService
    let codexStats: UsageStatsService
    @State private var selectedProvider: ProviderID = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let claudeEnabled = coordinator.enabledProviderIDs.contains(.claude)
            if claudeEnabled && !claude.isAuthenticated {
                NotAuthenticatedView(coordinator: coordinator, claude: claude)
            } else if coordinator.availableIDs.isEmpty {
                NoProvidersView()
            } else {
                ProviderTabBar(selection: $selectedProvider, availableIDs: coordinator.availableIDs)
                ProviderAreaView(
                    selectedProvider: $selectedProvider,
                    coordinator: coordinator,
                    historyService: historyService,
                    codexStats: codexStats,
                    appUpdater: appUpdater,
                    usageStats: usageStats
                ) {
                    BottomBarView(selectedProvider: $selectedProvider,
                                  coordinator: coordinator,
                                  appUpdater: appUpdater)
                }
            }
        }
        .padding()
        .frame(width: 360)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
        // v0.2.10 刷新纪律：popover 打开（content 视图首次 appear）触发一次「刷新所有 enabled provider」；
        // 切 tab / 任何其它操作都不再触发刷新（删了原来的 `.task(id: selectedProvider)`）—— UI 立即用 runtime.snapshot 缓存渲染。
        .task { await coordinator.refreshAllEnabledOnOpen() }
        // 用户在 Settings 里禁用了当前选中 tab 的 provider → 回退到 Claude。
        .onChange(of: coordinator.availableIDs) { _, ids in
            if !ids.contains(selectedProvider) {
                selectedProvider = ids.first ?? .claude
            }
        }
        .onAppear {
            if !coordinator.availableIDs.contains(selectedProvider) {
                selectedProvider = coordinator.availableIDs.first ?? .claude
            }
        }
    }

    // MARK: - Provider 内容区路由

    private struct ProviderAreaView<BottomBar: View>: View {
        @Binding var selectedProvider: ProviderID
        let coordinator: ProviderCoordinator
        let historyService: UsageHistoryService
        let codexStats: UsageStatsService
        let appUpdater: AppUpdater
        let usageStats: UsageStatsService
        @ViewBuilder let bottomBar: () -> BottomBar

        var body: some View {
            if selectedProvider == .claude && coordinator.availableIDs.contains(.claude) {
                ClaudeUsageAreaView(coordinator: coordinator,
                                    historyService: historyService,
                                    usageStats: usageStats,
                                    appUpdater: appUpdater,
                                    bottomBar: bottomBar)
            } else if coordinator.availableIDs.contains(selectedProvider),
                      let runtime = coordinator.runtime(for: selectedProvider) {
                // v0.2.6 起：泛化的 provider 用量区（Codex 等）。configured/unconfigured 由 ProviderUsageArea
                // 内部读 runtime.isConfigured 决定（@Observable 自动追踪属性读取，驱动子树重渲染）。
                let history: (service: UsageHistoryService, primaryLabel: String, secondaryLabel: String)? =
                    (selectedProvider == .codex
                        ? (coordinator.provider(.codex) as? CodexProvider).map { ($0.history, "Session", "Weekly") }
                        : nil)
                let costStats: UsageStatsService? = (selectedProvider == .codex ? codexStats : nil)
                let costContext: ProviderCostContext? = (selectedProvider == .codex
                    ? ProviderCostContext(pricing: OpenAIModelPriceTable.shared, displayName: { OpenAIPricing.displayName($0) })
                    : nil)
                ProviderUsageArea(runtime: runtime,
                                  providerID: selectedProvider,
                                  onBackToClaude: { selectedProvider = coordinator.availableIDs.first ?? .claude },
                                  history: history,
                                  costStats: costStats,
                                  costContext: costContext,
                                  bottomBar: bottomBar)
            } else {
                ProviderComingSoonView(provider: selectedProvider,
                                       onBackToClaude: { selectedProvider = coordinator.availableIDs.first ?? .claude })
            }
        }
    }

    /// 已注册的非 Claude provider 的用量区：观察其 `ProviderRuntime`，按 `isConfigured` 二选一渲染。
    private struct ProviderUsageArea<BottomBar: View>: View {
        let runtime: ProviderRuntime
        let providerID: ProviderID
        let onBackToClaude: () -> Void
        /// 该 provider 的历史（有则显示趋势箭头 + 折线图）。nil → 退化成只有 `ProviderUsageSection`（v0.2.6 现状）。
        var history: (service: UsageHistoryService, primaryLabel: String, secondaryLabel: String)? = nil
        /// 该 provider 的本机费用统计（有则在折线图下接估算费用卡 + tab 底接消费热力图）。
        var costStats: UsageStatsService? = nil
        var costContext: ProviderCostContext? = nil
        @ViewBuilder let bottomBar: () -> BottomBar

        var body: some View {
            if runtime.isConfigured {
                if let h = history {
                    ProviderHistorySection(historyService: h.service, runtime: runtime,
                                           primaryLabel: h.primaryLabel, secondaryLabel: h.secondaryLabel,
                                           costStats: costStats, costContext: costContext)
                } else {
                    ProviderUsageSection(runtime: runtime)
                }
                if let error = runtime.lastError {
                    UsageCard {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
                if let updated = runtime.lastUpdated {
                    HStack {
                        Text("Updated \(updated, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                bottomBar()
            } else {
                ProviderUnconfiguredView(provider: providerID, onBackToClaude: onBackToClaude)
                // 无凭证时 lastError == nil（CodexProvider 走 clear()）；只有 auth.json 损坏类失败才有，
                // 那种情况也要显示，否则用户只看到「未检测到凭证」、看不到「文件无效」。
                if let error = runtime.lastError {
                    UsageCard {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.caption)
                    }
                }
                bottomBar()
            }
        }
    }

    /// 「带历史的 provider 用量区」：在 `ProviderUsageSection` 上挂趋势箭头（从 history 算）+ 额度折线图。
    private struct ProviderHistorySection: View {
        let historyService: UsageHistoryService
        let runtime: ProviderRuntime
        let primaryLabel: String
        let secondaryLabel: String
        var costStats: UsageStatsService? = nil
        var costContext: ProviderCostContext? = nil

        var body: some View {
            let pts = historyService.history.dataPoints
            let snap = runtime.snapshot
            let t5 = computeTrend(currentPct: snap?.primaryWindow?.utilizationPct, points: pts, metric: \.pct5h)
            let t7 = computeTrend(currentPct: snap?.secondaryWindow?.utilizationPct, points: pts, metric: \.pct7d)
            ProviderUsageSection(runtime: runtime, trendPrimary: t5, trendSecondary: t7)
            if let cs = costStats, let cc = costContext {
                ProviderCostArea(historyService: historyService, stats: cs, costContext: cc,
                                 primaryLabel: primaryLabel, secondaryLabel: secondaryLabel)
            } else {
                UsageCard {
                    UsageChartSectionView(historyService: historyService, recentEvents: [],
                                          primaryLabel: primaryLabel, secondaryLabel: secondaryLabel)
                }
            }
        }
    }

    /// 带本机成本数据的折线图区（含估算费用卡）+ 消费热力图（mirror `claudeUsageArea` 的对应段）。
    private struct ProviderCostArea: View {
        let historyService: UsageHistoryService
        let stats: UsageStatsService
        let costContext: ProviderCostContext
        let primaryLabel: String
        let secondaryLabel: String

        var body: some View {
            UsageCard {
                UsageChartSectionView(historyService: historyService, recentEvents: stats.recentEvents,
                                      primaryLabel: primaryLabel, secondaryLabel: secondaryLabel, costContext: costContext)
            }
            if !stats.dailySpend.isEmpty && !stats.dailySpend.allSatisfy({ $0.usd == 0 }) {
                UsageCard { UsageHeatmapView(daySpends: stats.dailySpend, isInitializing: stats.isInitializing) }
            }
        }
    }

    // MARK: - Claude 已登录的用量区（与重构前 claudeUsageArea 内容/顺序一致）

    private struct ClaudeUsageAreaView<BottomBar: View>: View {
        let coordinator: ProviderCoordinator
        let historyService: UsageHistoryService
        let usageStats: UsageStatsService
        let appUpdater: AppUpdater
        @ViewBuilder let bottomBar: () -> BottomBar

        var body: some View {
            // TODO(perf): trend/pace 在 body 每次重渲染都 O(n) 重算（v0.0.9/v0.0.11 G5 R2 noted）。
            // 30 天 ~千点 history 下影响可接受；polling↑/retention↑ 至 ~万点时迁 UsageService 缓存计算结果。
            let runtime = coordinator.claude.runtime
            let points = historyService.history.dataPoints
            let snap = runtime.snapshot
            let trend5h = computeTrend(currentPct: snap?.primaryWindow?.utilizationPct, points: points, metric: \.pct5h)
            let trend7d = computeTrend(currentPct: snap?.secondaryWindow?.utilizationPct, points: points, metric: \.pct7d)

            ProviderUsageSection(runtime: runtime, trendPrimary: trend5h, trendSecondary: trend7d)

            UsageCard {
                UsageChartSectionView(historyService: historyService, recentEvents: usageStats.recentEvents)
            }

            if !usageStats.dailySpend.isEmpty && !usageStats.dailySpend.allSatisfy({ $0.usd == 0 }) {
                UsageCard {
                    UsageHeatmapView(daySpends: usageStats.dailySpend, isInitializing: usageStats.isInitializing)
                }
            }

            if let error = runtime.lastError {
                UsageCard {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if let updaterError = appUpdater.lastError {
                UsageCard {
                    Label(updaterError, systemImage: "arrow.triangle.2.circlepath.circle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if let updated = runtime.lastUpdated {
                HStack(spacing: 12) {
                    Text("Updated \(updated, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            bottomBar()
        }
    }

    // MARK: - 共用底部栏

    private struct BottomBarView: View {
        @Binding var selectedProvider: ProviderID
        let coordinator: ProviderCoordinator
        let appUpdater: AppUpdater

        var body: some View {
            HStack(spacing: 12) {
                SettingsLink { Text("Settings…") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Spacer()
                Button("Refresh") {
                    let id = selectedProvider
                    Task { await coordinator.refreshNow(id) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                AppVersionLabel()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct AppVersionLabel: View {
        private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        var body: some View {
            if let v = version {
                Text("v\(v)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct NoProvidersView: View {
        var body: some View {
            VStack(spacing: 12) {
                Text("No providers enabled")
                    .font(.headline)
                Text("Enable at least one provider in Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                SettingsLink { Text("Open Settings") }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity)
            Divider()
            HStack {
                Spacer()
                AppVersionLabel()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct NotAuthenticatedView: View {
        let coordinator: ProviderCoordinator
        let claude: UsageService

        var body: some View {
            Text("Not signed in")
                .font(.headline)
            Text("Sign in with the Claude CLI, then tap Retry.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            Button("Retry") {
                Task { await coordinator.claude.retrySignIn() }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            if let error = claude.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Spacer()
                AppVersionLabel()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
    }
}


func colorForPct(_ pct: Double) -> Color {
    switch pct {
    case ..<0.60: return .green
    case 0.60..<0.80: return .yellow
    default: return .red
    }
}
