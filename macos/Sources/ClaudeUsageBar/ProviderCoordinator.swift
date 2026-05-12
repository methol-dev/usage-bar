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

    /// 哪个 provider 驱动菜单栏 label。持久化在 UserDefaults；只接受当前可用的 provider，否则回退 `.claude`。
    /// （故意用 `@Published` + 手动 UserDefaults 而非 `@AppStorage` —— `@AppStorage` 在
    /// `ObservableObject` 里不触发 `objectWillChange`。）
    @Published var primaryProviderID: ProviderID {
        didSet {
            guard primaryProviderID != oldValue else { return }
            UserDefaults.standard.set(primaryProviderID.rawValue, forKey: Self.primaryProviderKey)
        }
    }
    static let primaryProviderKey = "primaryProviderID"

    init(claude: UsageService, additionalProviders: [UsageProvider] = []) {
        self.claude = claude
        let registry = ProviderRegistry(providers: [claude] + additionalProviders)
        self.registry = registry
        let stored = UserDefaults.standard.string(forKey: Self.primaryProviderKey)
            .flatMap(ProviderID.init(rawValue:))
        if let stored, registry.isAvailable(stored) {
            self.primaryProviderID = stored
        } else {
            self.primaryProviderID = .claude
        }
    }

    func provider(_ id: ProviderID) -> UsageProvider? { registry.provider(id) }
    func runtime(for id: ProviderID) -> ProviderRuntime? { registry.provider(id)?.runtime }
    func isAvailable(_ id: ProviderID) -> Bool { registry.isAvailable(id) }
    var availableIDs: [ProviderID] { registry.availableIDs }

    /// 主 provider 的 runtime（一定非 nil —— `primaryProviderID` 已约束为可用 provider）。
    var primaryRuntime: ProviderRuntime { registry.provider(primaryProviderID)?.runtime ?? claude.runtime }

    /// 拉一次某 provider 的用量（popover Refresh 按钮 / 切 tab 用）。provider 内部可做节流。
    func refreshNow(_ id: ProviderID) async { await registry.provider(id)?.refreshNow() }
}
