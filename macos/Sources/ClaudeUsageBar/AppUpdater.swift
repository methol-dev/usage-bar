import Foundation
import Sparkle

/// SPUUpdaterDelegate 独立 impl（避免 AppUpdater 必须转 NSObject + 解决 nonisolated/MainActor 冲突）。
/// Sparkle 可能从非 main 线程调用 delegate；UserDefaults.standard / suiteName 都是 thread-safe API。
final class UpdaterDelegateImpl: NSObject, SPUUpdaterDelegate {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let channel = UpdateChannel.current(defaults: defaults)
        return UpdateChannel.allowedChannelStrings(for: channel)
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var lastError: String?

    private let updaterController: SPUStandardUpdaterController
    private let delegateImpl: UpdaterDelegateImpl  // 必须 strong hold，Sparkle 内部 weak
    private var canCheckObservation: NSKeyValueObservation?

    /// v0.2.2: defaults 注入 seam 让测试可用 UserDefaults(suiteName:) 隔离 storage
    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        self.isConfigured = !(feedURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !(publicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        // v0.2.2: delegate impl 独立 class，避免 AppUpdater 转 NSObject 牵连 KVO/Combine 生命周期
        let delegateImpl = UpdaterDelegateImpl(defaults: defaults)
        self.delegateImpl = delegateImpl
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegateImpl,
            userDriverDelegate: nil
        )

        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = canCheck
            }
        }

        guard isConfigured else { return }
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        guard isConfigured else {
            lastError = "Updater is not configured for this build"
            return
        }
        updaterController.checkForUpdates(nil)
    }

    /// 测试入口：暴露 delegate 实例供 AppUpdaterChannelTests 直接调用 allowedChannels(for:)
    func _testDelegate() -> UpdaterDelegateImpl { delegateImpl }
}
