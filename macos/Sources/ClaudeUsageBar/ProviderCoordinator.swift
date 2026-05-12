import Foundation
import Combine

/// 多 provider 的「门面」—— 持有注册表 + provider 顺序 / 启用集 / 菜单栏 provider + 非-Claude 的后台 timer + 按需 refresh。
///
/// Claude 的后台轮询 / 429 backoff / `recordDataPoint` / `checkAndNotify` 仍归 `UsageService` 自己（装配处 `claude.startPolling()`）——
/// coordinator 只统管「非-Claude provider」的统一后台 timer（v0.2.10），以及 popover 打开时的一次性刷新。
@MainActor
final class ProviderCoordinator: ObservableObject {
    /// Claude provider（一等公民，一定存在）—— 登录 UX / polling 设置等 Claude 专属 UI 直接用它。
    let claude: UsageService
    let registry: ProviderRegistry
    private let defaults: UserDefaults

    // MARK: - 持久化 key
    /// 菜单栏 provider —— 沿用旧 key（v0.2.6~v0.2.9 叫 `primaryProviderID`，老用户偏好不丢）。
    static let menuBarProviderKey = "primaryProviderID"
    static let providerOrderKey = "providerOrder"
    static let enabledProvidersKey = "enabledProviders"

    // MARK: - provider 顺序（含未注册的占位 provider；Settings 列表与 popover tab 顺序的来源）
    @Published var orderedProviderIDs: [ProviderID] {
        didSet { defaults.set(orderedProviderIDs.map(\.rawValue), forKey: Self.providerOrderKey) }
    }

    // MARK: - 启用集（Claude 恒在 —— 它承载登录 UX）
    @Published private(set) var enabledProviderIDs: Set<ProviderID> {
        didSet {
            var s = enabledProviderIDs
            s.insert(.claude)
            if s != enabledProviderIDs {
                enabledProviderIDs = s            // 补上 .claude 后 re-enter 一次；那次 s == enabledProviderIDs → 落到下面
                return
            }
            defaults.set(enabledProviderIDs.map(\.rawValue), forKey: Self.enabledProvidersKey)
            // 启用集变了 → 菜单栏 provider 可能失效（如它刚被禁用）
            if !(enabledProviderIDs.contains(menuBarProviderID) && registry.isAvailable(menuBarProviderID)) {
                menuBarProviderID = firstMenuBarEligible()
            }
        }
    }

    // MARK: - 菜单栏 provider（取代 v0.2.6 的 `primaryProviderID`；约束 ∈ enabled ∩ registered）
    @Published var menuBarProviderID: ProviderID {
        didSet {
            guard !isRevertingMenuBar else { return }
            guard menuBarProviderID != oldValue else { return }
            guard enabledProviderIDs.contains(menuBarProviderID), registry.isAvailable(menuBarProviderID) else {
                isRevertingMenuBar = true
                menuBarProviderID = oldValue      // 拒绝非法值：恢复旧值（不写 UserDefaults）
                isRevertingMenuBar = false
                return
            }
            defaults.set(menuBarProviderID.rawValue, forKey: Self.menuBarProviderKey)
        }
    }
    private var isRevertingMenuBar = false

    // MARK: - 后台 timer（非-Claude provider）
    private var backgroundTimer: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var lastBackgroundInterval: TimeInterval = 0

    init(claude: UsageService, additionalProviders: [UsageProvider] = [], defaults: UserDefaults = .standard) {
        self.claude = claude
        self.defaults = defaults
        let registry = ProviderRegistry(providers: [claude] + additionalProviders)
        self.registry = registry

        // 全部算进本地变量，再统一赋给 stored props（Swift：所有 stored props 初始化前不能经 self 读其它 prop）。

        // 顺序：读盘 → 丢不在 ProviderID.allCases 里的（实际无）→ 末尾补漏掉的（按注册表顺序）
        let storedOrder = (defaults.stringArray(forKey: Self.providerOrderKey) ?? [])
            .compactMap(ProviderID.init(rawValue:))
            .filter { ProviderID.allCases.contains($0) }
        var order = storedOrder
        var seen = Set(order)
        for id in registry.orderedIDs where !seen.contains(id) { order.append(id); seen.insert(id) }
        if order.isEmpty { order = registry.orderedIDs }

        // 启用集：读盘 → ∩ allCases → 强制含 .claude；从没存过 → 默认全 allCases
        var enabled: Set<ProviderID>
        if let storedEnabled = defaults.stringArray(forKey: Self.enabledProvidersKey) {
            enabled = Set(storedEnabled.compactMap(ProviderID.init(rawValue:)).filter { ProviderID.allCases.contains($0) })
            enabled.insert(.claude)
        } else {
            enabled = Set(ProviderID.allCases)
        }

        // 菜单栏 provider：读盘 → 校验 ∈ enabled ∩ registered，否则首个合格的（最坏 .claude）
        let registeredIDs = registry.availableIDs
        let storedMenuBar = defaults.string(forKey: Self.menuBarProviderKey).flatMap(ProviderID.init(rawValue:))
        let menuBar: ProviderID
        if let m = storedMenuBar, enabled.contains(m), registeredIDs.contains(m) {
            menuBar = m
        } else {
            menuBar = order.first(where: { enabled.contains($0) && registeredIDs.contains($0) }) ?? .claude
        }

        self.orderedProviderIDs = order
        self.enabledProviderIDs = enabled
        self.menuBarProviderID = menuBar
    }

    private func firstMenuBarEligible() -> ProviderID {
        orderedProviderIDs.first(where: { enabledProviderIDs.contains($0) && registry.isAvailable($0) }) ?? .claude
    }

    // MARK: - mutators（Settings 用）
    func setEnabled(_ id: ProviderID, _ on: Bool) {
        if id == .claude { return }                        // Claude 恒在，忽略关闭请求
        if on { enabledProviderIDs.insert(id) } else { enabledProviderIDs.remove(id) }
    }
    func moveProvider(from source: IndexSet, to dest: Int) {
        orderedProviderIDs.move(fromOffsets: source, toOffset: dest)
    }

    // MARK: - lookup
    func provider(_ id: ProviderID) -> UsageProvider? { registry.provider(id) }
    func runtime(for id: ProviderID) -> ProviderRuntime? { registry.provider(id)?.runtime }
    /// 「该 provider 是否已注册」（= 注册表里有它）—— 与「是否启用」是两回事。
    func isAvailable(_ id: ProviderID) -> Bool { registry.isAvailable(id) }
    /// popover tab 用：已注册 + 已启用，按用户排序。
    var availableIDs: [ProviderID] { orderedProviderIDs.filter { registry.isAvailable($0) && enabledProviderIDs.contains($0) } }
    /// 菜单栏 provider 的 runtime（一定非 nil —— `menuBarProviderID` 已约束为可用 provider）。
    var menuBarRuntime: ProviderRuntime { registry.provider(menuBarProviderID)?.runtime ?? claude.runtime }

    /// 拉一次某 provider 的用量（popover Refresh 按钮用）。
    func refreshNow(_ id: ProviderID) async { await registry.provider(id)?.refreshNow() }

    // MARK: - 刷新纪律
    /// Claude 的首屏是否还空（= 还没成功拉过）—— popover 打开时才据此兜一次硬拉。
    var shouldRefreshClaudeOnOpen: Bool { claude.runtime.snapshot == nil }
    /// popover 打开（content 视图首次 appear）触发一次：非-Claude 各拉一次；Claude 仅在首屏空时兜一次（避免打乱其 backoff）。
    func refreshAllEnabledOnOpen() async {
        for id in availableIDs where id != .claude { await registry.provider(id)?.refreshNow() }
        if shouldRefreshClaudeOnOpen { await claude.refreshNow() }
    }

    // MARK: - 非-Claude 的统一后台 timer
    /// 当前后台轮询间隔（跟随 `UsageService` 那个 `pollingMinutes` key，非法值 → 30min）。
    var backgroundIntervalSeconds: TimeInterval {
        let stored = defaults.integer(forKey: "pollingMinutes")
        let mins = UsageService.pollingOptions.contains(stored) ? stored : UsageService.defaultPollingMinutes
        return TimeInterval(mins * 60)
    }

    /// 装配处（`ClaudeUsageBarApp`）调用：为 Codex 设好 `onPollTick`（驱动 codexStats 刷新，回调由 App 注入）+ 起统一后台 timer + 立即各拉一次 + 监听 `pollingMinutes` 变化重起。
    func startBackgroundPolling(codexOnPollTick: @escaping @MainActor () -> Void) {
        (registry.provider(.codex) as? CodexProvider)?.onPollTick = codexOnPollTick
        rescheduleBackgroundTimer()
        onBackgroundTick()                                 // 立即一次
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            // `queue: .main` 保证在主线程，但不在 MainActor 隔离上下文 —— assumeIsolated 桥过去（safe：确在主线程）。
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.backgroundIntervalSeconds != self.lastBackgroundInterval { self.rescheduleBackgroundTimer() }
            }
        }
    }
    private func rescheduleBackgroundTimer() {
        backgroundTimer?.cancel()
        lastBackgroundInterval = backgroundIntervalSeconds
        backgroundTimer = Timer.publish(every: lastBackgroundInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.onBackgroundTick() }
    }
    /// 一次后台 tick（`internal` 以便单测直接调）：非-Claude 的 enabled provider 各 `refreshNow` + `onPollTick`。Claude 不碰（它有自己的 timer）。
    func onBackgroundTick() {
        for id in availableIDs where id != .claude {
            guard let p = registry.provider(id) else { continue }
            Task { await p.refreshNow() }
            (p as? CodexProvider)?.onPollTick?()
        }
    }
}
