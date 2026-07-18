import SwiftUI
import ServiceManagement

@MainActor
struct SettingsWindowContent: View {
    let coordinator: ProviderCoordinator
    let service: UsageService
    let notificationService: NotificationService
    let appUpdater: AppUpdater
    // @AppStorage 直接绑定 enum（G5 review B1 修订）
    @AppStorage(MenuBarDisplayMode.storageKey) private var menubarMode: MenuBarDisplayMode = .icon
    // v0.2.2: Sparkle 双通道
    @AppStorage(UpdateChannel.storageKey) private var rawChannel: String = UpdateChannel.defaultChannel.rawValue
    // 承载本视图的真实 NSWindow（由 WindowAccessor 抓取）—— 用于可靠前置，替代靠猜的旧逻辑。
    @State private var hostWindow: NSWindow?

    var body: some View {
        Form {
            Section("General") {
                LaunchAtLoginToggle()

                Picker("Menubar Display", selection: $menubarMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("Polling Interval", selection: Binding(
                    get: { service.pollingMinutes },
                    set: { service.updatePollingInterval($0) }
                )) {
                    ForEach(UsageService.pollingOptions, id: \.self) { mins in
                        Text(pollingOptionLabel(for: mins))
                            .tag(mins)
                    }
                }
            }

            Section("Providers") {
                // .plain + 隐藏 List 自带背景 → 行铺满 Section 宽度，不再是 .inset 的浮动窄白卡；
                // 高度按行数撑满 + 禁 List 内部滚动，避免与外层 Form 的滚动嵌套。拖拽排序（onMove）保留。
                List {
                    ForEach(coordinator.orderedProviderIDs, id: \.self) { id in
                        ProviderRow(coordinator: coordinator, id: id)
                    }
                    .onMove { from, to in coordinator.moveProvider(from: from, to: to) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(coordinator.orderedProviderIDs.count) * 56 + 8)
            }

            Section("Notifications") {
                ThresholdSlider(
                    label: "5-hour window",
                    value: notificationService.threshold5h,
                    onChange: { notificationService.setThreshold5h($0) }
                )
                ThresholdSlider(
                    label: "7-day window",
                    value: notificationService.threshold7d,
                    onChange: { notificationService.setThreshold7d($0) }
                )
                ThresholdSlider(
                    label: "Extra usage",
                    value: notificationService.thresholdExtra,
                    onChange: { notificationService.setThresholdExtra($0) }
                )
            }

            // Claude Web 数据源引导（独立 Section，仿 Updates 的「文案 + Button」；不塞进 Providers
            // 的 ProviderRow —— 那里高度按行数硬算，塞多步引导会撑破）。
            Section("Claude Web Source") {
                Text("Track your claude.ai subscription usage via a Chrome extension running in your own logged-in session. It's a data source for Claude — cookies never leave the browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Install Chrome Extension…") {
                    if let url = URL(string: "https://github.com/methol-dev/usage-bar#claude-web-extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("After installing, enable the Web source for Claude above (Claude row → Sources) and keep a claude.ai tab signed in.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // v0.2.2: 更新通道（G3-N1 位置：Notifications 之后 / Account 之前）
            Section("Updates") {
                Picker("Channel", selection: $rawChannel) {
                    ForEach(UpdateChannel.allCases) { ch in
                        Text(ch.displayName).tag(ch.rawValue)
                    }
                }
                .onAppear {
                    // G5 R1: 净化未知 rawValue → defaultChannel（用户手动 defaults write canary 等场景）
                    if UpdateChannel(rawValue: rawChannel) == nil {
                        rawChannel = UpdateChannel.defaultChannel.rawValue
                    }
                }
                Text("Beta includes pre-release builds for testing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appUpdater.isConfigured {
                    Button("Check for Updates…") {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)
                }
            }

        }
        .formStyle(.grouped)
        // 固定宽度 480（scene 用 .contentSize 让窗口紧贴内容，不再比内容宽一大截、内容浮在灰底里）。
        // 高度 min/ideal/max 有上限 + Form 内部滚动，避免占满屏。width 与 height 分属两个 frame overload，链式两段。
        .frame(width: 480)
        .frame(minHeight: 440, idealHeight: 620, maxHeight: 780)
        // 抓真实窗口：首次挂载即激活前置；关窗恢复 accessory（observer 只注册一次）。
        .background(WindowAccessor { window in
            if hostWindow !== window {
                hostWindow = window
                registerRestorePolicyOnClose(window)
            }
            activateSettingsWindow(window)
        })
        // 后续再次打开（Settings scene 复用同一窗口，makeNSView 不再触发）靠 onAppear 激活。
        .onAppear {
            activateSettingsWindow(hostWindow)
        }
    }
}

/// 抓取承载 SwiftUI 视图的真实 NSWindow —— 替代靠「最后一个可见窗口」猜测的旧逻辑。
/// menu bar app 是 accessory(LSUIElement) 进程，设置窗口默认生成在最前台 app 之后，
/// 必须拿到窗口本体才能可靠前置。
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 打开设置时把 app 临时提为前台（.regular）—— accessory(LSUIElement) app 不这么做，窗口成不了 key，
/// 所有控件（开关 / 交通灯）会渲染成非活跃灰、accent 蓝不显示（这正是「选中没蓝」的根因）。
/// 关窗时恢复 .accessory（见 registerRestorePolicyOnClose）。代价：设置开着时 Dock 临时出现一个图标
/// —— 菜单栏 app 的标准做法，远好于灰死的控件。Task{@MainActor} 一跳避开与窗口出现的时序竞争。
private func activateSettingsWindow(_ window: NSWindow?) {
    guard let window else { return }
    Task { @MainActor in
        if NSApp.activationPolicy() != .regular { _ = NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// 设置窗关闭 → 恢复 accessory（移除临时 Dock 图标）。observer 只注册一次（窗口被 Settings scene 复用）。
/// nonisolated：从 WindowAccessor 的非隔离回调调用。observer 在 queue:.main 上跑（确在主线程），
/// 故用 MainActor.assumeIsolated 同步桥到 MainActor 调 NSApp（同 ProviderCoordinator 的 defaults observer）。
private func registerRestorePolicyOnClose(_ window: NSWindow) {
    // 不保存 token：observer 随窗口生命周期存活（窗口被 Settings scene 复用、常驻），无需 remove。
    _ = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
        MainActor.assumeIsolated {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
private struct ProviderRow: View {
    let coordinator: ProviderCoordinator
    let id: ProviderID

    var body: some View {
        let registered = coordinator.isAvailable(id)
        let enabled = coordinator.enabledProviderIDs.contains(id)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id.displayName)
                    .foregroundStyle(registered ? .primary : .secondary)
                if !registered {
                    Text("coming soon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // 数据来源:Claude 有多个源(CLI + Web)→ 可多选 + 调优先级;其余单源 provider 置灰。
            SourceControl(coordinator: coordinator, id: id)
                .disabled(!registered)
            Spacer()
            Toggle(isOn: Binding(
                get: { coordinator.menuBarVisibleProviderIDs.contains(id) },
                set: { coordinator.setMenuBarVisible(id, $0) }
            )) {
                Image(systemName: "menubar.rectangle")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(!enabled || !registered)
            .help("Show in menu bar")
            // 未注册 provider 在 UI 上显示为 OFF（enabledProviderIDs 里的值保留，等接入时自动恢复）
            Toggle("", isOn: Binding(
                get: { enabled && registered },
                set: { coordinator.setEnabled(id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!registered)
        }
        .frame(minHeight: 44)
    }
}

/// 数据来源控件（ADR 0010）：Claude 是多源（CLI + Web），给一个 Menu 勾选启用哪些源 + 选优先谁；
/// 单源 provider（Codex/Gemini/…）只显示置灰占位（当前唯一来源，不可改）。
@MainActor
private struct SourceControl: View {
    let coordinator: ProviderCoordinator
    let id: ProviderID

    var body: some View {
        if id == .claude {
            let group = coordinator.claudeGroup
            Menu {
                ForEach(UsageSource.allCases) { src in
                    Toggle(src.displayName, isOn: Binding(
                        get: { group.enabledSources.contains(src) },
                        set: { group.setSourceEnabled(src, $0) }
                    ))
                }
                Divider()
                Picker("Prefer", selection: Binding(
                    get: { group.enabledByPriority.first ?? group.sourcePriority.first ?? .web },
                    set: { group.setPreferred($0) }
                )) {
                    ForEach(UsageSource.allCases) { Text($0.displayName).tag($0) }
                }
            } label: {
                chip(summary(group), interactive: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose which data sources to use for Claude and their priority")
        } else {
            // 单源:置灰 chip 占位。
            chip("Single source", interactive: false)
                .help("This provider has a single data source")
        }
    }

    /// 数据来源 chip —— 带边框的胶囊,读起来像可点控件(取代原先飘忽的纯文字 Label)。
    @ViewBuilder
    private func chip(_ text: String, interactive: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
            Text(text).font(.caption)
            if interactive {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).opacity(0.6)
            }
        }
        .foregroundStyle(interactive ? Color.primary : Color.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    /// 例如「Web › CLI」——按优先级列出已启用的源。
    private func summary(_ g: MultiSourceProvider) -> String {
        let names = g.enabledByPriority.map { $0 == .web ? "Web" : "CLI" }
        return names.isEmpty ? "Sources" : names.joined(separator: " › ")
    }
}

@MainActor
struct LaunchAtLoginToggle: View {
    @State private var model: LaunchAtLoginModel
    private let controlSize: ControlSize
    private let useSwitchStyle: Bool

    init(
        controlSize: ControlSize = .regular,
        useSwitchStyle: Bool = false,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        _model = State(
            wrappedValue: LaunchAtLoginModel(bundleURL: bundleURL)
        )
        self.controlSize = controlSize
        self.useSwitchStyle = useSwitchStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toggle

            if let message = model.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var toggle: some View {
        let baseToggle = Toggle("Launch at Login", isOn: Binding(
            get: { model.isEnabled },
            set: { model.setEnabled($0) }
        ))
        .disabled(!model.isSupported)
        .controlSize(controlSize)

        if useSwitchStyle {
            baseToggle.toggleStyle(.switch)
        } else {
            baseToggle
        }
    }
}


func supportsLaunchAtLoginManagement(
    appURL: URL = Bundle.main.bundleURL,
    installDirectories: [URL] = launchAtLoginInstallDirectories()
) -> Bool {
    let normalizedAppURL = appURL.resolvingSymlinksInPath().standardizedFileURL

    return installDirectories.contains { directory in
        let normalizedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let directoryPath = normalizedDirectory.path
        let appPath = normalizedAppURL.path

        return appPath == directoryPath || appPath.hasPrefix(directoryPath + "/")
    }
}

func launchAtLoginInstallDirectories(fileManager: FileManager = .default) -> [URL] {
    [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
    ]
}

private struct ThresholdSlider: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        LabeledContent {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { onChange(Int($0)) }
                ),
                in: 0...100,
                step: 5
            )
        } label: {
            Text(label)
            Text(value > 0 ? "\(value)%" : "Off")
                .foregroundStyle(.secondary)
        }
        .alignmentGuide(.firstTextBaseline) { d in
            d[VerticalAlignment.center]
        }
    }
}
