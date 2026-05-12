import SwiftUI

struct PopoverView: View {
    @ObservedObject var coordinator: ProviderCoordinator
    /// Claude provider（登录 UX / polling 设置 / Sign Out 等 Claude 专属 UI 直接用它）。
    /// 单独 `@ObservedObject` —— 这样 `isAuthenticated`/`isAwaitingCode`/`accounts`/`lastError` 变化能驱动重渲染
    /// （`coordinator` 只有 `primaryProviderID` 是 `@Published`，不覆盖 `coordinator.claude` 的变化）。
    @ObservedObject var claude: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    @EnvironmentObject var usageStats: UsageStatsService
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var selectedProvider: ProviderID = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !setupComplete && !claude.isAuthenticated {
                SetupView(
                    service: claude,
                    notificationService: notificationService,
                    onComplete: { setupComplete = true }
                )
            } else if claude.isAwaitingCode {
                // v0.1.3 G2-A/G3-R3: 提升 CodeEntryView 路由到 isAuthenticated 之外，
                // 让"添加账号"流程（已 isAuthenticated + isAwaitingCode）也能看到 CodeEntry
                Text(claude.accounts.isEmpty ? "登录" : "添加账号")
                    .font(.headline)
                CodeEntryView(service: claude)
                if let error = claude.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } else {
                AccountSwitcherView(service: claude)  // accounts.count <= 1 时自隐藏
                ProviderTabBar(selection: $selectedProvider, availableIDs: coordinator.availableIDs)
                providerArea
            }
        }
        .padding()
        .frame(width: 360)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.06), .clear],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
        .task(id: selectedProvider) {
            // 切到非 Claude 的可用 provider 时拉一次（Claude 有后台 polling，不在此重拉，避免改其行为）。
            guard selectedProvider != .claude, coordinator.isAvailable(selectedProvider) else { return }
            await coordinator.refreshNow(selectedProvider)
        }
    }

    // MARK: - Provider 内容区路由

    @ViewBuilder
    private var providerArea: some View {
        if selectedProvider == .claude {
            if !claude.isAuthenticated {
                signInView
            } else {
                claudeUsageArea
            }
        } else if coordinator.isAvailable(selectedProvider),
                  let runtime = coordinator.runtime(for: selectedProvider) {
            // v0.2.6 起：泛化的 provider 用量区（Codex 等）。configured/unconfigured 由 ProviderUsageArea
            // 内部读 runtime.isConfigured 决定 —— 这样 runtime 的 @Published 变化能驱动该子树重渲染
            // （父视图 PopoverView 不必然在切 tab + 拉取后重渲染；v0.2.5 G5 nit ②）。
            ProviderUsageArea(runtime: runtime,
                              providerID: selectedProvider,
                              onBackToClaude: { selectedProvider = .claude },
                              bottomBar: { bottomBar })
        } else {
            ProviderComingSoonView(provider: selectedProvider,
                                   onBackToClaude: { selectedProvider = .claude })
        }
    }

    /// 已注册的非 Claude provider 的用量区：观察其 `ProviderRuntime`，按 `isConfigured` 二选一渲染。
    private struct ProviderUsageArea<BottomBar: View>: View {
        @ObservedObject var runtime: ProviderRuntime
        let providerID: ProviderID
        let onBackToClaude: () -> Void
        @ViewBuilder let bottomBar: () -> BottomBar

        var body: some View {
            if runtime.isConfigured {
                ProviderUsageSection(runtime: runtime)
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

    // MARK: - Claude 已登录的用量区（与重构前 usageView 内容/顺序一致）

    @ViewBuilder
    private var claudeUsageArea: some View {
        // TODO(perf): trend/pace 在 body 每次重渲染都 O(n) 重算（v0.0.9/v0.0.11 G5 R2 noted）。
        // 30 天 ~千点 history 下影响可接受；polling↑/retention↑ 至 ~万点时迁 UsageService @Published 缓存。
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

        bottomBar
    }

    // MARK: - 共用底部栏

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 12) {
            settingsButton
            Spacer()
            Button("Refresh") {
                let id = selectedProvider
                Task { await coordinator.refreshNow(id) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            if appUpdater.isConfigured {
                Button("Check for Updates…") {
                    appUpdater.checkForUpdates()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!appUpdater.canCheckForUpdates)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var signInView: some View {
        // v0.1.3: isAwaitingCode 路由已提升到 body 顶层，本 view 仅处理"未登录且未等 code"场景
        Text("Sign in to view your usage.")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        Button("Sign in with Claude") {
            claude.startOAuthFlow()
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
            settingsButton
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private var settingsButton: some View {
        SettingsLink {
            Text("Settings…")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

// MARK: - Setup (first launch)

private struct SetupView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var notificationService: NotificationService
    var onComplete: () -> Void

    var body: some View {
        Text("Welcome")
            .font(.headline)
        Text("Configure your preferences to get started.")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        Divider()

        LaunchAtLoginToggle(controlSize: .small, useSwitchStyle: true)

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SetupThresholdSlider(
                label: "5-hour window",
                value: notificationService.threshold5h,
                onChange: { notificationService.setThreshold5h($0) }
            )
            SetupThresholdSlider(
                label: "7-day window",
                value: notificationService.threshold7d,
                onChange: { notificationService.setThreshold7d($0) }
            )
            SetupThresholdSlider(
                label: "Extra usage",
                value: notificationService.thresholdExtra,
                onChange: { notificationService.setThresholdExtra($0) }
            )
        }

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Text("Polling Interval")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { service.pollingMinutes },
                set: { service.updatePollingInterval($0) }
            )) {
                ForEach(UsageService.pollingOptions, id: \.self) { mins in
                    Text(localizedPollingInterval(for: mins, locale: .autoupdatingCurrent))
                        .tag(mins)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if isDiscouragedPollingOption(service.pollingMinutes) {
                Text("Frequent polling may cause rate limiting")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }

        Divider()

        Button("Get Started") {
            onComplete()
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)

        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Subviews

private struct CodeEntryView: View {
    @ObservedObject var service: UsageService
    @State private var code = ""

    var body: some View {
        Text("Paste the code from your browser:")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        HStack(spacing: 4) {
            TextField("code#state", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { submit() }
            Button {
                if let str = NSPasteboard.general.string(forType: .string) {
                    code = str.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
        }

        HStack {
            Button("Cancel") {
                service.isAwaitingCode = false
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Submit") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty)
        }
    }

    private func submit() {
        let value = code
        Task { await service.submitOAuthCode(value) }
    }
}

private struct SetupThresholdSlider: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                Text(value > 0 ? "\(value)%" : "Off")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0)) }
                ),
                in: 0...100,
                step: 5
            )
            .controlSize(.small)
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
