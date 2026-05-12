import Foundation

/// 已注册的 provider 集合。当前只注册 Claude（见 ADR 0005 —— 其余 provider 逐步对接，
/// v0.2.6 加 Codex）。某个 `ProviderID` 在 popover 顶部 tab 里「可用 / 占位」由这里
/// 是否注册了对应 `UsageProvider` 决定。
@MainActor
struct ProviderRegistry {
    /// tab 的固定排序（含未注册的占位 provider）。
    let orderedIDs: [ProviderID]
    private let providersByID: [ProviderID: UsageProvider]

    init(providers: [UsageProvider], orderedIDs: [ProviderID] = ProviderID.allCases) {
        self.orderedIDs = orderedIDs
        self.providersByID = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func provider(_ id: ProviderID) -> UsageProvider? { providersByID[id] }
    func isAvailable(_ id: ProviderID) -> Bool { providersByID[id] != nil }

    /// 已注册（= 可用）的 provider id，按 `orderedIDs` 顺序。
    var availableIDs: [ProviderID] { orderedIDs.filter { providersByID[$0] != nil } }
}
