import Foundation
import Observation

/// Claude 顶层 provider 的**门面**(ADR 0010)—— 把两个数据源(`.cli` = `UsageService`,
/// `.web` = `ClaudeWebProvider`)聚成一个 `.claude` provider,按用户选择 + 优先级取数,**命中即停**。
///
/// 设计要点:
/// - `registry` 里以 `.claude` 注册的是本门面;`coordinator.claude` 仍指向裸 `UsageService`(CLI 源),
///   Claude 专属登录 UX / history / notifications / polling 继续直连它,零改动。
/// - 门面自己的 `runtime` 是「当前生效源」的镜像 —— 菜单栏 label 与 popover Claude 区都读它。
/// - **命中即停**:web 优先且拿到数据时不调 cli.fetchUsage → 不打 oauth/usage(避开 429),
///   代价是此时 cli 派生的 API 趋势线 / 阈值通知暂停更新(本机 JSONL 统计仍随 tick 更新)。见 ADR 0010。
///
/// read-only + 统一 timer + runtime 范式不变;门面本身不发网络,只编排两个源。
@MainActor
@Observable
final class ClaudeProvider: UsageProvider {
    let id: ProviderID = .claude
    let runtime = ProviderRuntime()
    var onPollTick: (@MainActor () -> Void)?

    private let cliSource: any UsageProvider
    private let webSource: any UsageProvider

    /// 当前生效源(最近一次 refresh 后确定)—— UI 据此决定登录引导文案(CLI Retry vs 打开 claude.ai)。
    private(set) var activeSource: ClaudeDataSource?
    /// 用户勾选启用的源(至少一个)。Settings 改它 → 下次 refresh 生效。
    private(set) var enabledSources: Set<ClaudeDataSource>
    /// 优先级顺序(取数按此序尝试,命中即停)。
    private(set) var sourcePriority: [ClaudeDataSource]

    private let defaults: UserDefaults
    private var isRefreshing = false

    static let enabledKey = "claude.enabledSources"
    static let priorityKey = "claude.sourcePriority"
    /// 默认优先级:Web 优先(避开 oauth/usage 429 端点),拿不到再退 CLI。
    static let defaultPriority: [ClaudeDataSource] = [.web, .cli]

    /// 生产入口:CLI 源 = 裸 `UsageService`,Web 源 = `ClaudeWebProvider`。
    convenience init(cli: UsageService, web: ClaudeWebProvider,
                     defaults: UserDefaults = .standard, webAlreadyOn: Bool = false) {
        self.init(cliSource: cli, webSource: web, defaults: defaults, webAlreadyOn: webAlreadyOn)
    }

    /// 指定初始化器(测试可注入任意 `UsageProvider` 作为两个源,以确定性验证优先级/降级/backoff)。
    /// - Parameter webAlreadyOn: 首次 seed 时是否默认勾选 web 源(PR#43 曾把 `.claudeWeb` 存进
    ///   enabledProviders,或已存在扩展同步文件 → 视为用户想要 web)。仅在从未写过 enabledSources 时生效。
    init(cliSource: any UsageProvider, webSource: any UsageProvider,
         defaults: UserDefaults = .standard, webAlreadyOn: Bool = false) {
        self.cliSource = cliSource
        self.webSource = webSource
        self.defaults = defaults
        self.sourcePriority = Self.sanitizePriority(defaults.stringArray(forKey: Self.priorityKey))

        if let raw = defaults.stringArray(forKey: Self.enabledKey) {
            let parsed = Set(raw.compactMap(ClaudeDataSource.init(rawValue:)))
            self.enabledSources = parsed.isEmpty ? [.cli] : parsed
        } else {
            // 一次性 seed(幂等:下次已有 key 就不再进这里)。cli 恒在;web 视 webAlreadyOn。
            var seed: Set<ClaudeDataSource> = [.cli]
            if webAlreadyOn { seed.insert(.web) }
            self.enabledSources = seed
            defaults.set(Self.order(seed, by: self.sourcePriority).map(\.rawValue), forKey: Self.enabledKey)
            if defaults.stringArray(forKey: Self.priorityKey) == nil {
                defaults.set(self.sourcePriority.map(\.rawValue), forKey: Self.priorityKey)
            }
        }

        // 首屏同步镜像:显示最高优先级「已配置」源的当前态(web provider init 已同步读过文件)。不发网络。
        mirrorInitial()
    }

    // MARK: - UsageProvider

    var isConfigured: Bool {
        enabledSources.contains { provider(for: $0).isConfigured }
    }

    /// 只选 CLI 时透传其 429 backoff(coordinator 据此跳过 tick);只要选了 web(无 backoff)就恒可 tick。
    var nextEligibleRefresh: Date? {
        enabledByPriority == [.cli] ? cliSource.nextEligibleRefresh : nil
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        var firstConfigured: ClaudeDataSource?
        for s in enabledByPriority {
            let p = provider(for: s)
            // B1:该源仍在 backoff 窗口(cli 的 429)→ 跳过、试下一个源,绝不在 backoff 内打限流端点。
            if let due = p.nextEligibleRefresh, due > now {
                if firstConfigured == nil, p.isConfigured { firstConfigured = s }
                continue
            }
            await p.refreshNow()
            if p.isConfigured, p.runtime.snapshot != nil {
                activeSource = s
                mirror(from: p.runtime, configured: true)
                return
            }
            if firstConfigured == nil, p.isConfigured { firstConfigured = s }
        }

        // 无源产出可用快照:显示最高优先级「已配置但当前无数据/错误」源的态;否则整体未配置。
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

    /// 勾选 / 取消一个源。不允许清空到零 —— 取消最后一个时忽略(至少留一个源)。
    func setSourceEnabled(_ s: ClaudeDataSource, _ on: Bool) {
        var set = enabledSources
        if on {
            set.insert(s)
        } else {
            guard set.count > 1 else { return }
            set.remove(s)
        }
        enabledSources = set
        defaults.set(Self.order(set, by: sourcePriority).map(\.rawValue), forKey: Self.enabledKey)
    }

    /// 把某个源提到优先级最前(2 源场景下即「Prefer X first」)。
    func setPreferred(_ s: ClaudeDataSource) {
        var order = sourcePriority.filter { $0 != s }
        order.insert(s, at: 0)
        sourcePriority = order
        defaults.set(order.map(\.rawValue), forKey: Self.priorityKey)
    }

    // MARK: - internals

    /// 启用的源按当前优先级排序(refreshNow / summary 用)。
    var enabledByPriority: [ClaudeDataSource] {
        sourcePriority.filter { enabledSources.contains($0) }
    }

    private func provider(for s: ClaudeDataSource) -> any UsageProvider {
        switch s {
        case .cli: return cliSource
        case .web: return webSource
        }
    }

    /// 把某个源 runtime 的效果忠实重放进门面 runtime(D2:复制「效果」而非裸字段,保持 clearSnapshot 语义)。
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

    /// 优先级净化:去未知 rawValue、去重、补漏到全集;缺配置回默认。
    static func sanitizePriority(_ raw: [String]?) -> [ClaudeDataSource] {
        guard let raw else { return defaultPriority }
        var seen = Set<ClaudeDataSource>()
        var order = raw.compactMap(ClaudeDataSource.init(rawValue:)).filter { seen.insert($0).inserted }
        for s in defaultPriority where !seen.contains(s) { order.append(s) }
        return order
    }

    /// 把一个源集合按给定优先级排成有序数组(持久化 enabledSources 用,便于人读)。
    static func order(_ set: Set<ClaudeDataSource>, by priority: [ClaudeDataSource]) -> [ClaudeDataSource] {
        priority.filter { set.contains($0) }
    }
}
