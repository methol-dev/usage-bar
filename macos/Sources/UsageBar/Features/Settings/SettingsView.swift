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
                List {
                    ForEach(coordinator.orderedProviderIDs, id: \.self) { id in
                        ProviderRow(coordinator: coordinator, id: id)
                    }
                    .onMove { from, to in coordinator.moveProvider(from: from, to: to) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                // 行实际高度 ~52pt（registered 单行 ~48 + List inset；unregistered 双行 ~56），
                // 之前用 44 算最后一行（Gemini）会被截掉（issue: gemini 开关看不到）。
                .frame(height: CGFloat(coordinator.orderedProviderIDs.count) * 60 + 16)
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

            // Claude Web 源引导（独立 Section，仿 Updates 的「文案 + Button」；不塞进 Providers
            // 的 ProviderRow —— 那里高度按行数硬算，塞多步引导会撑破）。
            Section("Claude Web") {
                Text("Track your claude.ai subscription usage via a Chrome extension running in your own logged-in session. Cookies never leave the browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Install Chrome Extension…") {
                    if let url = URL(string: "https://github.com/methol-dev/usage-bar#claude-web-extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("After installing, enable the Claude Web provider above and keep a claude.ai tab signed in.")
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
        // 高度可缩放 + 有上限：去掉旧的 .fixedSize(vertical)（它逼窗口长到全部内容高度，叠加
        // scene 的 .contentSize 就锁死不可调、内容一多占满屏）。改为给 ideal/max 高度让 Form 内部滚动。
        // 注：SwiftUI 的固定 width 与弹性 height 分属两个不同 frame overload，不能写在一个调用里，需链式两段。
        .frame(width: 400)
        .frame(minHeight: 400, idealHeight: 540, maxHeight: 720)
        // 抓真实窗口：首次挂载即前置；state 里存起来供后续每次打开复用。
        .background(WindowAccessor { window in
            if hostWindow !== window { hostWindow = window }
            bringSettingsWindowToFront(window)
        })
        // 后续再次打开（Settings scene 复用同一窗口，makeNSView 不再触发）靠 onAppear 前置。
        .onAppear {
            bringSettingsWindowToFront(hostWindow)
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

/// 激活并前置设置窗口。accessory app 用 orderFrontRegardless 强制前置，不临时提升 activation
/// policy（避免 Dock 图标闪现）。Task{@MainActor} 一跳避开与窗口出现的时序竞争，同时让本函数
/// 保持 nonisolated —— 可从 WindowAccessor 的非隔离回调与 onAppear 两处调用而无隔离报错。
private func bringSettingsWindowToFront(_ window: NSWindow?) {
    guard let window else { return }
    Task { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
