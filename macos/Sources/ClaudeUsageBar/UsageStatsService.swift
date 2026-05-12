import Foundation
import Combine

@MainActor
final class UsageStatsService: ObservableObject {
    @Published private(set) var rolling30d: CostSummary? = nil
    @Published private(set) var dailySpend: [DaySpend] = []
    @Published private(set) var monthlySpend: [MonthSpend] = []
    @Published private(set) var isInitializing: Bool = true

    private let store: UsageEventStore
    private let collector: ClaudeUsageCollector
    private var inFlight = false

    init(store: UsageEventStore, collector: ClaudeUsageCollector) {
        self.store = store; self.collector = collector
    }
    /// 生产环境便捷构造（默认 data 目录 + 默认 scanRoots）。
    convenience init() {
        let store = UsageEventStore()
        self.init(store: store, collector: ClaudeUsageCollector(store: store, cursor: ScanCursorStore()))
    }

    func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let store = self.store
        let collector = self.collector
        // 为何 collector 已是 actor 还要 detached：沿用 v0.1.2 G3 #2 工艺——把整条 actor→actor→IO 链放到
        // cooperative pool，MainActor 只在最后写回 published 那一刻参与。
        let computed: (CostSummary?, [DaySpend], [MonthSpend]) = await Task.detached(priority: .utility) {
            let result = await collector.collect()
            let dayAgg = await store.readDayAggregates()
            let monthAgg = await store.readMonthAggregates()
            let daily = UsageAggregator.dailySpend(from: dayAgg)
            let monthly = UsageAggregator.monthlySpend(from: monthAgg)
            let hasData = result.scannedFileCount > 0 && !dayAgg.isEmpty
            let summary: CostSummary? = hasData
                ? UsageAggregator.rolling30dSummary(dayAggregates: dayAgg, now: Date(),
                                                    scannedFileCount: result.scannedFileCount, parseErrorCount: result.parseErrorCount)
                : nil
            return (summary, daily, monthly)
        }.value
        self.rolling30d = computed.0
        self.dailySpend = computed.1
        self.monthlySpend = computed.2
        self.isInitializing = false
    }
}
