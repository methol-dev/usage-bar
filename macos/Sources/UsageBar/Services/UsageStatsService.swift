import Foundation
import Observation

/// 「能产出 `CollectResult` 的本机用量收集器」抽象 —— `ClaudeUsageCollector` / `CodexUsageCollector` 各 conform 一个。
/// `: Sendable` 因为 `UsageStatsService.refresh()` 在 `Task.detached` 里持有它。
protocol UsageCollecting: Sendable {
    func collect() async -> CollectResult
}

@MainActor
@Observable
final class UsageStatsService {
    static let shared = UsageStatsService()

    private(set) var rolling30d: CostSummary? = nil
    private(set) var dailySpend: [DaySpend] = []
    private(set) var monthlySpend: [MonthSpend] = []
    private(set) var recentEvents: [StoredUsageEvent] = []
    private(set) var isInitializing: Bool = true

    private let store: UsageEventStore
    private let collector: any UsageCollecting
    private let pricing: ModelPriceTable
    private var inFlight = false
    private var lastRefreshAt: Date?

    init(store: UsageEventStore, collector: any UsageCollecting, pricing: ModelPriceTable = ClaudeModelPriceTable.shared) {
        self.store = store; self.collector = collector; self.pricing = pricing
    }
    /// 生产环境便捷构造（Claude，默认 data 目录 + 默认 scanRoots）。
    convenience init() {
        let store = UsageEventStore()
        self.init(store: store, collector: ClaudeUsageCollector(store: store, cursor: ScanCursorStore()))
    }
    /// 按 provider 选 store / collector / 估价表。
    convenience init(provider: ProviderID) {
        switch provider {
        case .codex:
            let store = UsageEventStore(provider: .codex)
            self.init(store: store,
                      collector: CodexUsageCollector(store: store, cursor: ScanCursorStore(provider: .codex)),
                      pricing: OpenAIModelPriceTable.shared)
        default:
            let store = UsageEventStore()
            self.init(store: store, collector: ClaudeUsageCollector(store: store, cursor: ScanCursorStore()))
        }
    }

    /// popover 打开时调：距上次刷新不足 `minInterval` 则跳过。后台 tick 间隔（默认 30min）太长，
    /// 不在打开时补刷的话 1h/6h/1d 窗口会滞后最多一个 tick。
    func refreshIfStale(minInterval: TimeInterval = 60) async {
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < minInterval { return }
        await refresh()
    }

    func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        lastRefreshAt = Date()
        defer { inFlight = false }
        let store = self.store
        let collector = self.collector
        let pricing = self.pricing
        // 为何 collector 已是 actor 还要 detached：沿用 v0.1.2 G3 #2 工艺——把整条 actor→actor→IO 链放到
        // cooperative pool，MainActor 只在最后写回 published 那一刻参与。
        let computed: (CostSummary?, [DaySpend], [MonthSpend], [StoredUsageEvent]) = await Task.detached(priority: .utility) {
            let result = await collector.collect()
            let dayAgg = await store.readDayAggregates()
            let monthAgg = await store.readMonthAggregates()
            let daily = UsageAggregator.dailySpend(from: dayAgg, pricing: pricing)
            let monthly = UsageAggregator.monthlySpend(from: monthAgg, pricing: pricing)
            let hasData = result.scannedFileCount > 0 && !dayAgg.isEmpty
            let summary: CostSummary? = hasData
                ? UsageAggregator.rolling30dSummary(dayAggregates: dayAgg, now: Date(),
                                                    scannedFileCount: result.scannedFileCount, parseErrorCount: result.parseErrorCount,
                                                    pricing: pricing)
                : nil
            // 最近 31 天的 raw events，用于按选定时间窗口实时计算费用估算
            let cutoff = Date().addingTimeInterval(-31 * 86400)
            let farFuture = Date().addingTimeInterval(86400 * 365)
            let recent = await store.queryEvents(from: cutoff, to: farFuture)
            return (summary, daily, monthly, recent)
        }.value
        self.rolling30d = computed.0
        self.dailySpend = computed.1
        self.monthlySpend = computed.2
        self.recentEvents = computed.3
        self.isInitializing = false
    }
}
