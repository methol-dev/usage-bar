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
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            focusSettingsWindow()
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
private func focusSettingsWindow() {
    Task { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.last(where: { $0.isVisible && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
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
