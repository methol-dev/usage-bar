import Foundation
import Observation

/// 多数据源 provider 的**门面**（ADR 0010，ADR 0012 泛化）—— 把两个数据源（`.cli` + `.web`）聚成一个
/// 顶层 provider，按用户选择 + 优先级取数，**命中即停**。Claude 与 Codex 各构造一个实例。
///
/// 设计要点：
/// - `registry` 里以 `id` 注册的是本门面；对应的裸 CLI provider（`UsageService` / `CodexProvider`）仍被
///   coordinator 单独持有（登录 UX / history / notifications / polling 直连它，零改动）。
/// - 门面自己的 `runtime` 是「当前生效源」的镜像 —— 菜单栏 label 与 popover 用量区都读它。
/// - **命中即停**：web 优先且拿到数据时不调 cli 取数（避开限流端点）。带错误的源（陈旧 / 同步失败）
///   不算命中 —— 继续试下一源（stale web 自动回退 cli，图表不断线）。web 命中时 cli 内部的历史采样 /
///   阈值通知不会跑，由门面经 `onWebSnapshot` 回推给装配处补记（见 ADR 0010；原「趋势线暂停」的代价已消除）。
///
/// read-only + 统一 timer + runtime 范式不变；门面本身不发网络，只编排两个源。
@MainActor
@Observable
final class MultiSourceProvider: UsageProvider {
    let id: ProviderID
    let runtime = ProviderRuntime()
    var onPollTick: (@MainActor () -> Void)?
    /// 源选择 / 优先级变化时回调（coordinator 用来即时重发该 provider 的 Web 控制配置，ADR 0011）。
    var onConfigChanged: (@MainActor () -> Void)?
    /// Web 源命中且数据比上次新（payload 同步时间戳变化）时回调，携带快照 + payload 时刻 ——
    /// 装配处挂历史采样 / 阈值通知副作用（CLI 命中时其内部已自记，不经此路，避免双记）。
    var onWebSnapshot: (@MainActor (ProviderUsageSnapshot, Date) -> Void)?

    private let cliSource: any UsageProvider
    private let webSource: any UsageProvider

    /// 当前生效源（最近一次 refresh 后确定）—— UI 据此决定登录引导文案（CLI Retry vs 打开网页）。
    private(set) var activeSource: UsageSource?
    /// 用户勾选启用的源（至少一个）。Settings 改它 → 下次 refresh 生效。
    private(set) var enabledSources: Set<UsageSource>
    /// 优先级顺序（取数按此序尝试，命中即停）。
    private(set) var sourcePriority: [UsageSource]

    private let defaults: UserDefaults
    private var isRefreshing = false
    /// 最近一次经 `onWebSnapshot` 回推的 payload 时间戳（epoch 秒）。持久化到 UserDefaults：
    /// 重启后同一份未变化的落盘数据不重复记点（`UsageDataPoint.id == timestamp`，重复记会撞身份）。
    /// 存 / 比较都用 `timeIntervalSince1970` 原始 Double，不经 Date 往返，避免精度损失导致去重失效。
    private var lastWebSampleTs: TimeInterval?

    /// 持久化 key 按 provider 分隔（`claude.enabledSources` / `codex.enabledSources`）——
    /// Claude 的 rawValue == "claude" → 与旧静态 key 一致，零迁移。
    static func enabledKey(for id: ProviderID) -> String { "\(id.rawValue).enabledSources" }
    static func priorityKey(for id: ProviderID) -> String { "\(id.rawValue).sourcePriority" }
    static func lastWebSampleKey(for id: ProviderID) -> String { "\(id.rawValue).web.lastSampleTs" }
    /// 默认优先级：Web 优先（避开限流端点），拿不到再退 CLI。
    static let defaultPriority: [UsageSource] = [.web, .cli]

    /// 指定初始化器。测试可注入任意 `UsageProvider` 作为两个源，以确定性验证优先级/降级/backoff。
    /// - Parameter webAlreadyOn: 首次 seed 时是否默认勾选 web 源（存在扩展同步文件 → 视为用户想要 web）。
    ///   仅在从未写过 enabledSources 时生效。
    init(id: ProviderID, cliSource: any UsageProvider, webSource: any UsageProvider,
         defaults: UserDefaults = .standard, webAlreadyOn: Bool = false) {
        self.id = id
        self.cliSource = cliSource
        self.webSource = webSource
        self.defaults = defaults
        self.sourcePriority = Self.sanitizePriority(defaults.stringArray(forKey: Self.priorityKey(for: id)))
        self.lastWebSampleTs = defaults.object(forKey: Self.lastWebSampleKey(for: id)) as? Double

        if let raw = defaults.stringArray(forKey: Self.enabledKey(for: id)) {
            let parsed = Set(raw.compactMap(UsageSource.init(rawValue:)))
            self.enabledSources = parsed.isEmpty ? [.cli] : parsed
        } else {
            // 一次性 seed（幂等：下次已有 key 就不再进这里）。cli 恒在；web 视 webAlreadyOn。
            var seed: Set<UsageSource> = [.cli]
            if webAlreadyOn { seed.insert(.web) }
            self.enabledSources = seed
            defaults.set(Self.order(seed, by: self.sourcePriority).map(\.rawValue), forKey: Self.enabledKey(for: id))
            if defaults.stringArray(forKey: Self.priorityKey(for: id)) == nil {
                defaults.set(self.sourcePriority.map(\.rawValue), forKey: Self.priorityKey(for: id))
            }
        }

        // 首屏同步镜像：显示最高优先级「已配置」源的当前态（web provider init 已同步读过文件）。不发网络。
        mirrorInitial()
    }

    // MARK: - UsageProvider

    var isConfigured: Bool {
        enabledSources.contains { provider(for: $0).isConfigured }
    }

    /// 只选 CLI 时透传其 429 backoff（coordinator 据此跳过 tick）；只要选了 web（无 backoff）就恒可 tick。
    var nextEligibleRefresh: Date? {
        enabledByPriority == [.cli] ? cliSource.nextEligibleRefresh : nil
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        var firstConfigured: UsageSource?
        for s in enabledByPriority {
            let p = provider(for: s)
            // 该源仍在 backoff 窗口（cli 的 429）→ 跳过、试下一个源，绝不在 backoff 内打限流端点。
            if let due = p.nextEligibleRefresh, due > now {
                if firstConfigured == nil, p.isConfigured { firstConfigured = s }
                continue
            }
            await p.refreshNow()
            // 命中 = 已配置 + 有快照 + **无错误**。带错的源（web 陈旧 >1h / 同步失败，snapshot 被保留）
            // 不算命中 —— 继续试下一源，stale web 不再无限占住门面、饿死 cli（图表随之断线）。
            if p.isConfigured, p.runtime.snapshot != nil, p.runtime.lastError == nil {
                activeSource = s
                mirror(from: p.runtime, configured: true)
                pushWebSampleIfFresh(s, p)
                return
            }
            if firstConfigured == nil, p.isConfigured { firstConfigured = s }
        }

        // 无源产出可用快照：显示最高优先级「已配置但当前无数据/错误」源的态；否则整体未配置。
        if let s = firstConfigured {
            activeSource = s
            mirror(from: provider(for: s).runtime, configured: true)
        } else {
            activeSource = enabledByPriority.first
            runtime.setConfigured(false)
            runtime.clear()
        }
    }

    // MARK: - Settings mutators

    /// 勾选 / 取消一个源。不允许清空到零 —— 取消最后一个时忽略（至少留一个源）。
    func setSourceEnabled(_ s: UsageSource, _ on: Bool) {
        var set = enabledSources
        if on {
            set.insert(s)
        } else {
            guard set.count > 1 else { return }
            set.remove(s)
        }
        enabledSources = set
        defaults.set(Self.order(set, by: sourcePriority).map(\.rawValue), forKey: Self.enabledKey(for: id))
        onConfigChanged?()
    }

    /// 把某个源提到优先级最前（2 源场景下即「Prefer X first」）。
    func setPreferred(_ s: UsageSource) {
        var order = sourcePriority.filter { $0 != s }
        order.insert(s, at: 0)
        sourcePriority = order
        defaults.set(order.map(\.rawValue), forKey: Self.priorityKey(for: id))
        onConfigChanged?()
    }

    // MARK: - internals

    /// 启用的源按当前优先级排序（refreshNow / summary 用）。
    var enabledByPriority: [UsageSource] {
        sourcePriority.filter { enabledSources.contains($0) }
    }

    private func provider(for s: UsageSource) -> any UsageProvider {
        switch s {
        case .cli: return cliSource
        case .web: return webSource
        }
    }

    /// Web 源命中后回推快照（历史采样 / 阈值通知副作用在装配处）。按 payload 时间戳去重：
    /// 后台 tick / 文件监听重读**未变化**的落盘数据不重复触发；时间戳持久化，跨重启同样不重复。
    private func pushWebSampleIfFresh(_ s: UsageSource, _ p: any UsageProvider) {
        guard s == .web,
              let snap = p.runtime.snapshot,
              let ts = p.runtime.lastUpdated,
              ts.timeIntervalSince1970 != lastWebSampleTs else { return }
        lastWebSampleTs = ts.timeIntervalSince1970
        defaults.set(ts.timeIntervalSince1970, forKey: Self.lastWebSampleKey(for: id))
        onWebSnapshot?(snap, ts)
    }

    /// 把某个源 runtime 的效果忠实重放进门面 runtime（复制「效果」而非裸字段，保持 clearSnapshot 语义）。
    private func mirror(from src: ProviderRuntime, configured: Bool) {
        runtime.setConfigured(configured)
        if let snap = src.snapshot {
            runtime.setSuccess(snapshot: snap, at: src.lastUpdated ?? Date())
            if let err = src.lastError { runtime.setError(err, clearSnapshot: false) }
        } else if let err = src.lastError {
            runtime.setError(err, clearSnapshot: true)
        } else {
            runtime.clear()
        }
    }

    private func mirrorInitial() {
        for s in enabledByPriority where provider(for: s).isConfigured {
            activeSource = s
            mirror(from: provider(for: s).runtime, configured: true)
            return
        }
        activeSource = enabledByPriority.first
        runtime.setConfigured(false)
    }

    // MARK: - config sanitize (static，便于单测)

    /// 优先级净化：去未知 rawValue、去重、补漏到全集；缺配置回默认。
    static func sanitizePriority(_ raw: [String]?) -> [UsageSource] {
        guard let raw else { return defaultPriority }
        var seen = Set<UsageSource>()
        var order = raw.compactMap(UsageSource.init(rawValue:)).filter { seen.insert($0).inserted }
        for s in defaultPriority where !seen.contains(s) { order.append(s) }
        return order
    }

    /// 把一个源集合按给定优先级排成有序数组（持久化 enabledSources 用，便于人读）。
    static func order(_ set: Set<UsageSource>, by priority: [UsageSource]) -> [UsageSource] {
        priority.filter { set.contains($0) }
    }
}
