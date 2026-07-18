import Foundation
import Combine
import Observation

/// 多 provider 的「门面」—— 持有注册表 + provider 顺序 / 启用集 / 菜单栏可见集 + 非-Claude 的后台 timer + 按需 refresh。
///
/// v0.2.11：coordinator 持一个统一的后台 timer，覆盖**所有** enabled provider（含 Claude）—— 间隔 = `pollingMinutes`，监听 UserDefaults 变化重起。
/// Claude 的 429 backoff 由它自己的 `UsageService.fetchUsage` 记进 `backoffUntil`（暴露为 `nextEligibleRefresh`），coordinator 的 tick 在 backoff 窗口内会跳过本 provider。
@MainActor
@Observable
final class ProviderCoordinator {
    /// Claude 的 CLI 源(裸 `UsageService`)—— 登录 UX / polling 设置等 Claude 专属 UI 直接用它。
    /// 注:`.claude` 在 registry 里注册的是**门面** `claudeGroup`(多数据源),不是这个裸 service。
    let claude: UsageService
    /// Claude 顶层 provider 的门面(CLI + Web 两数据源,ADR 0010)—— Settings 数据源控件 / Claude 区读它。
    let claudeGroup: MultiSourceProvider
    let registry: ProviderRegistry
    private let defaults: UserDefaults

    // MARK: - 持久化 key
    static let providerOrderKey = "providerOrder"
    static let enabledProvidersKey = "enabledProviders"
    static let menuBarVisibleProvidersKey = "menuBarVisibleProviders"

    // MARK: - provider 顺序（含未注册的占位 provider；Settings 列表与 popover tab 顺序的来源）
    var orderedProviderIDs: [ProviderID] {
        didSet { defaults.set(orderedProviderIDs.map(\.rawValue), forKey: Self.providerOrderKey) }
    }

    // MARK: - 启用集
    private(set) var enabledProviderIDs: Set<ProviderID> {
        didSet { defaults.set(enabledProviderIDs.map(\.rawValue), forKey: Self.enabledProvidersKey) }
    }

    // MARK: - 菜单栏可见集（独立于启用集；用户可逐个控制是否在菜单栏显示）
    private(set) var menuBarVisibleProviderIDs: Set<ProviderID> {
        didSet { defaults.set(menuBarVisibleProviderIDs.map(\.rawValue), forKey: Self.menuBarVisibleProvidersKey) }
    }

    // MARK: - 后台 timer（非-Claude provider）
    private var backgroundTimer: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var lastBackgroundInterval: TimeInterval = 0

    // MARK: - Claude Web 控制通道（ADR 0011）
    static let webSyncNonceKey = "claude.web.syncNonce"
    /// 单调自增：app 端「Refresh」时 +1，写进 control 文件；扩展见 nonce 变化即立即取数一次。持久化以跨重启。
    private var webSyncNonce: Int = 0
    /// 独立的控制发布 timer —— 每 ~2min 重写 control 文件刷新 `ts`（liveness），与 pollingMinutes 解耦，
    /// 使「app 关/崩 → 扩展 ~5min 内判定陈旧休眠」而非拖到 2×pollingMinutes。
    private var controlTimer: AnyCancellable?
    static let controlPublishInterval: TimeInterval = 120
    /// 控制文件的实际写入器（可注入，单测置为 no-op 以免写真实 `~/.config`）。
    var controlWriter: (ClaudeWebControl) -> Void = { ClaudeWebControlStore.write($0) }

    /// 监听扩展写入 `claude-web.json` 的快 timer —— 让 app 的「最近更新」紧跟扩展取数，
    /// 而非拖到 pollingMinutes 的后台 tick（那会让显示陈旧度最高逼近一个 pollingMinutes）。
    private var webFileTimer: AnyCancellable?
    private var lastWebFileModified: Date?
    static let webFileWatchInterval: TimeInterval = 15

    /// 每次后台 tick 的「附带副作用」——默认让模型价格目录按 3h 节流自刷新。可注入便于单测。
    var onTickSideEffects: () -> Void = { ModelPricingCatalog.shared.refreshIfStale(now: Date()) }

    init(claude: UsageService, additionalProviders: [UsageProvider] = [], defaults: UserDefaults = .standard,
         firstLaunchDetector: () -> Set<ProviderID> = { AIToolDetector.detect() }) {
        self.claude = claude
        self.defaults = defaults
        self.webSyncNonce = defaults.integer(forKey: Self.webSyncNonceKey)   // 未写过 → 0

        // 顶层 provider 集合:`.claudeWeb` 降为 Claude 的子源(ADR 0010),不再作为顶层 tab/菜单项 ——
        // 从排序 / 启用 / 菜单栏可见三个持久集合里一律排除(PR#43 存量里的 "claude-web" 读时被过滤掉)。
        let topLevel = ProviderID.allCases.filter { $0 != .claudeWeb }

        // Claude 门面:内部持 CLI(= claude)+ Web 两个数据源,按用户选择/优先级取数(命中即停)。
        // web 是否默认勾选:PR#43 曾把 `.claudeWeb` 存进 enabledProviders,或已存在扩展同步文件 → 视为想要 web。
        let legacyWebEnabled = (defaults.stringArray(forKey: Self.enabledProvidersKey) ?? [])
            .contains(ProviderID.claudeWeb.rawValue)
        let webFilePresent = FileManager.default.fileExists(atPath: ClaudeWebStore.fileURL.path)
        let group = MultiSourceProvider(id: .claude, cliSource: claude, webSource: ClaudeWebProvider(),
                                        defaults: defaults, webAlreadyOn: legacyWebEnabled || webFilePresent)
        self.claudeGroup = group

        // 注册表:`.claude` 注册**门面**(非裸 UsageService);web 不作为顶层注册。orderedIDs 用去 claudeWeb 的顶层集。
        let registry = ProviderRegistry(providers: [group] + additionalProviders, orderedIDs: topLevel)
        self.registry = registry

        // 全部算进本地变量，再统一赋给 stored props（Swift：所有 stored props 初始化前不能经 self 读其它 prop）。

        // 顺序：读盘 → 只留顶层 id → 末尾补漏掉的（按注册表顺序）
        let storedOrder = (defaults.stringArray(forKey: Self.providerOrderKey) ?? [])
            .compactMap(ProviderID.init(rawValue:))
            .filter { topLevel.contains($0) }
        var order = storedOrder
        var seen = Set(order)
        for id in registry.orderedIDs where !seen.contains(id) { order.append(id); seen.insert(id) }
        if order.isEmpty { order = registry.orderedIDs }

        // 首次启动（key 未写过时才调用检测器，结果缓存在 cache 里供两处复用）。
        // 两个 key 独立存盘，任一缺失才调一次检测器；两个都存在时跳过，不调检测器。
        // detector 结果 ∩ 顶层集：剥掉 claudeWeb 等非顶层 id（web 的默认开启走门面的 webAlreadyOn seed）。
        var _firstLaunchCache: Set<ProviderID>? = nil
        func firstLaunchSet() -> Set<ProviderID> {
            if let cached = _firstLaunchCache { return cached }
            let d = firstLaunchDetector().intersection(Set(topLevel))
            let result = d.isEmpty ? Set(topLevel) : d
            _firstLaunchCache = result
            return result
        }

        // 启用集：读盘 → ∩ 顶层集；从没存过 → 首次启动检测结果
        var enabled: Set<ProviderID>
        if let storedEnabled = defaults.stringArray(forKey: Self.enabledProvidersKey) {
            enabled = Set(storedEnabled.compactMap(ProviderID.init(rawValue:)).filter { topLevel.contains($0) })
        } else {
            enabled = firstLaunchSet()
        }

        // 菜单栏可见集：读盘 → ∩ 顶层集；从没存过 → 首次启动检测结果（与 enabled 共享缓存）
        let menuBarVisible: Set<ProviderID>
        if let stored = defaults.stringArray(forKey: Self.menuBarVisibleProvidersKey) {
            menuBarVisible = Set(stored.compactMap(ProviderID.init(rawValue:)).filter { topLevel.contains($0) })
        } else {
            menuBarVisible = firstLaunchSet()
        }

        self.orderedProviderIDs = order
        self.enabledProviderIDs = enabled
        self.menuBarVisibleProviderIDs = menuBarVisible
    }

    // MARK: - mutators（Settings 用）
    func setEnabled(_ id: ProviderID, _ on: Bool) {
        if on { enabledProviderIDs.insert(id) } else { enabledProviderIDs.remove(id) }
        // Claude 顶层启用态影响扩展的 paused —— 立即重发 control。
        if id == .claude { publishClaudeWebControl() }
    }
    func setMenuBarVisible(_ id: ProviderID, _ on: Bool) {
        if on { menuBarVisibleProviderIDs.insert(id) } else { menuBarVisibleProviderIDs.remove(id) }
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
    /// 实际在菜单栏显示的 IDs：menuBarVisible ∩ availableIDs（enabled + registered），按用户排序。
    var menuBarVisibleIDs: [ProviderID] {
        orderedProviderIDs.filter {
            menuBarVisibleProviderIDs.contains($0) &&
            registry.isAvailable($0) &&
            enabledProviderIDs.contains($0)
        }
    }

    /// 拉一次某 provider 的用量（popover Refresh 按钮用 —— 唯一调用点，见 PopoverView 底栏）。
    /// 对 Claude:这是**用户主动**的同步入口,顺带 bump syncNonce → 让扩展 ≤1min 内真去 claude.ai 拉一次
    /// （后台 tick 走 `registry.provider(.claude)?.refreshNow()`，不经此路，故不会每 tick 误 bump）。
    func refreshNow(_ id: ProviderID) async {
        if id == .claude { publishClaudeWebControl(bumpSyncNonce: true) }
        await registry.provider(id)?.refreshNow()
    }

    // MARK: - Claude Web 控制通道发布（ADR 0011）
    /// 写 control 文件(paused / intervalSeconds / syncNonce / ts)。`bumpSyncNonce` 用于用户主动同步。
    /// paused = 「Claude 顶层未启用」或「Web 源未启用」——两者任一都让扩展停掉 claude.ai 取数。
    func publishClaudeWebControl(bumpSyncNonce: Bool = false) {
        if bumpSyncNonce {
            webSyncNonce &+= 1
            defaults.set(webSyncNonce, forKey: Self.webSyncNonceKey)
        }
        controlWriter(currentClaudeWebControl())
    }

    /// claude-web.json 的最后修改时刻（缺失 → nil）。
    private func webFileModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: ClaudeWebStore.fileURL.path))?[.modificationDate] as? Date
    }

    /// 快 timer 回调:文件 mtime 变了(扩展刚落盘新数据)就经**门面**重读一次 —— 不 bump nonce、不 ping 扩展,
    /// 只把新数据反映进 runtime / 菜单栏 / 显示。仅在 web 源实际启用时才看。
    private func pollWebFileFreshness() {
        guard enabledProviderIDs.contains(.claude), claudeGroup.enabledSources.contains(.web) else { return }
        guard let mod = webFileModificationDate(), mod != lastWebFileModified else { return }
        lastWebFileModified = mod
        Task { await claudeGroup.refreshNow() }
    }

    /// 计算当前应发布的控制配置（纯函数，便于单测）。
    /// paused = 「Claude 顶层未启用」或「Web 源未启用」——两者任一都让扩展停掉 claude.ai 取数。
    func currentClaudeWebControl() -> ClaudeWebControl {
        let webActive = enabledProviderIDs.contains(.claude) && claudeGroup.enabledSources.contains(.web)
        return ClaudeWebControl(
            paused: !webActive,
            intervalSeconds: Int(backgroundIntervalSeconds),
            syncNonce: webSyncNonce,
            ts: Date().timeIntervalSince1970
        )
    }

    // MARK: - 刷新纪律
    /// popover 打开（content 视图 appear）触发一次：对每个 enabled provider，仅在尚无数据（snapshot == nil）时才拉，
    /// 已有缓存 snapshot 的跳过——刷新由后台 timer 驱动，不因 popover 开关而触发。
    func refreshAllEnabledOnOpen() async {
        for id in availableIDs {
            guard let p = registry.provider(id) else { continue }
            if let due = p.nextEligibleRefresh, due > Date() { continue }
            guard p.runtime.snapshot == nil else { continue }
            await p.refreshNow()
        }
    }

    // MARK: - 非-Claude 的统一后台 timer
    /// 当前后台轮询间隔（跟随 `UsageService` 那个 `pollingMinutes` key，非法值 → 30min）。
    var backgroundIntervalSeconds: TimeInterval {
        let stored = defaults.integer(forKey: "pollingMinutes")
        let mins = UsageService.pollingOptions.contains(stored) ? stored : UsageService.defaultPollingMinutes
        return TimeInterval(mins * 60)
    }

    /// 装配处（`UsageBarApp`）调用：起统一后台 timer（覆盖所有 enabled provider，含 Claude）+ 立即各拉一次 + 监听 `pollingMinutes` 变化重起。
    /// 各 provider 的 `onPollTick`（驱动其本机统计刷新）由装配处在调本方法**之前**单独设好。
    func startBackgroundPolling() {
        rescheduleBackgroundTimer()
        onBackgroundTick()                                 // 立即一次
        // Claude Web 控制通道:门面源变化(Settings 勾选/优先级)即时重发 control;并起一个 ~2min 的
        // liveness timer 持续刷新 control.ts(与 pollingMinutes 解耦)。启动即发一次初始 control。
        claudeGroup.onConfigChanged = { [weak self] in self?.publishClaudeWebControl() }
        publishClaudeWebControl()
        controlTimer = Timer.publish(every: Self.controlPublishInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.publishClaudeWebControl() }
        // 快速文件监听:扩展落盘 claude-web.json 后 ~15s 内 app 就重读并刷新显示(经门面,不 bump nonce)。
        // 记初始 mtime,避开启动后一次多余重读(onBackgroundTick 启动时已读过一次)。
        lastWebFileModified = webFileModificationDate()
        webFileTimer = Timer.publish(every: Self.webFileWatchInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollWebFileFreshness() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            // `queue: .main` 保证在主线程，但不在 MainActor 隔离上下文 —— assumeIsolated 桥过去（safe：确在主线程）。
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.backgroundIntervalSeconds != self.lastBackgroundInterval {
                    self.rescheduleBackgroundTimer()
                    self.publishClaudeWebControl()   // intervalSeconds 变了,即时告知扩展
                }
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
    /// 一次后台 tick（`internal` 以便单测直接调）：对每个 enabled provider（含 Claude），若 `nextEligibleRefresh` 还在未来（= 还在 429 backoff 窗口里）则跳过这一 tick；
    /// 否则 `refreshNow()` + `onPollTick?()`（驱动该 provider 的本机统计刷新）。
    /// 注：`Task { await p.refreshNow() }` 对 Claude 故意不持有 / 不可 cancel —— 账号切换时这个在飞的 tick 不被 cancel，但 `fetchUsage` 入口 + 写值前都有 `accountSwitchEpoch` 比对兜底（陈旧响应被丢弃）。
    func onBackgroundTick() {
        for id in availableIDs {
            guard let p = registry.provider(id) else { continue }
            if let due = p.nextEligibleRefresh, due > Date() { continue }
            Task { await p.refreshNow() }
            p.onPollTick?()
        }
        onTickSideEffects()
        // 无条件重发 control(刷新 ts + 反映当前 paused/interval)—— 放在 provider 循环外,
        // 即使 Claude 被禁用 / 在 backoff 也照发(那正是要告诉扩展 paused 的时候)。
        publishClaudeWebControl()
    }
}
