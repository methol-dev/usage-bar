import Foundation

/// 多 provider 的「门面」—— 持有注册表 + 主 provider 选择 + 按需 refresh。
///
/// 本版本（v0.2.5）coordinator **不自己跑 timer**：Claude 的后台轮询 / backoff /
/// `recordDataPoint` / `checkAndNotify` 仍归 `UsageService` 自己（装配处 `startPolling()`）。
/// coordinator 只负责：注册查找、`primaryProviderID`（哪个 provider 上菜单栏 label）、`refreshNow`。
@MainActor
final class ProviderCoordinator: ObservableObject {
    /// Claude provider（一等公民，一定存在）—— 给登录 UX / polling 设置 / Sign Out 等 Claude 专属 UI 用。
    let claude: UsageService
    let registry: ProviderRegistry

    /// 哪个 provider 驱动菜单栏 label。持久化在 UserDefaults；只接受 `primaryEligibleIDs` 里的 provider
    /// （即支持后台轮询的），否则回退 / 拒绝。
    /// （故意用 `@Published` + 手动 UserDefaults 而非 `@AppStorage` —— `@AppStorage` 在
    /// `ObservableObject` 里不触发 `objectWillChange`。）
    @Published var primaryProviderID: ProviderID {
        didSet {
            guard !isRevertingPrimary else { return }
            guard primaryProviderID != oldValue else { return }
            guard primaryEligibleIDs.contains(primaryProviderID) else {
                isRevertingPrimary = true
                primaryProviderID = oldValue   // 拒绝非 eligible：恢复旧值（不写 UserDefaults）
                isRevertingPrimary = false
                return
            }
            UserDefaults.standard.set(primaryProviderID.rawValue, forKey: Self.primaryProviderKey)
        }
    }
    private var isRevertingPrimary = false
    static let primaryProviderKey = "primaryProviderID"

    init(claude: UsageService, additionalProviders: [UsageProvider] = []) {
        self.claude = claude
        let registry = ProviderRegistry(providers: [claude] + additionalProviders)
        self.registry = registry
        let stored = UserDefaults.standard.string(forKey: Self.primaryProviderKey)
            .flatMap(ProviderID.init(rawValue:))
        // `primaryEligibleIDs` 是 self 上的计算属性，不能在 stored 属性全初始化前用；这里直接用本地 registry 算。
        let eligible = registry.availableIDs.filter { registry.provider($0)?.supportsBackgroundPolling == true }
        if let stored, eligible.contains(stored) {
            self.primaryProviderID = stored
        } else {
            self.primaryProviderID = .claude
        }
    }

    func provider(_ id: ProviderID) -> UsageProvider? { registry.provider(id) }
    func runtime(for id: ProviderID) -> ProviderRuntime? { registry.provider(id)?.runtime }
    func isAvailable(_ id: ProviderID) -> Bool { registry.isAvailable(id) }
    var availableIDs: [ProviderID] { registry.availableIDs }

    /// 「菜单栏 primary 候选」= `supportsBackgroundPolling == true` 的已注册 provider —— 即既有稳定后台数据源、
    /// 又能在菜单栏 provider-aware 地渲染（否则菜单栏会显示陈旧数字或 Claude 专属图标）。
    /// v0.2.6/v0.2.8：仍只 Claude 满足（Codex v0.2.8 起有自己的 5 分钟采样 timer，但菜单栏渲染未 provider-aware，故 flag 仍 false）。
    var primaryEligibleIDs: [ProviderID] {
        registry.availableIDs.filter { registry.provider($0)?.supportsBackgroundPolling == true }
    }

    /// 主 provider 的 runtime（一定非 nil —— `primaryProviderID` 已约束为可用 provider）。
    var primaryRuntime: ProviderRuntime { registry.provider(primaryProviderID)?.runtime ?? claude.runtime }

    /// 拉一次某 provider 的用量（popover Refresh 按钮 / 切 tab 用）。provider 内部可做节流。
    func refreshNow(_ id: ProviderID) async { await registry.provider(id)?.refreshNow() }
}
