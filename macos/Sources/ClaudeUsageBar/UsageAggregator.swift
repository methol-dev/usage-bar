import Foundation

enum UsageAggregator {
    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func localDayKey(_ d: Date) -> String { localDayFormatter.string(from: d) }

    private static let utcMonthFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"; return f
    }()
    private static let utcYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"; return f
    }()
    static func utcMonthKey(_ d: Date) -> String { utcMonthFormatter.string(from: d) }
    static func utcYearKey(_ d: Date) -> String { utcYearFormatter.string(from: d) }

    // fold 收 `normalize:` 闭包（callers 可能没有 price table，故传裸闭包）；cost 函数收 `pricing:` price table
    // ——两者本质同一件事，只是给定的形态不同。Codex collector 传 `OpenAIPricing.normalize`；Claude 默认 `ClaudePricing.normalize`。
    private static func fold(_ events: [StoredUsageEvent], key: (Date) -> String,
                            normalize: @Sendable (String) -> String) -> [String: [String: TokenSums]] {
        var out: [String: [String: TokenSums]] = [:]
        for e in events {
            let bk = key(e.ts)
            let mk = normalize(e.model)
            var bucket = out[bk] ?? [:]
            var sums = bucket[mk] ?? TokenSums()
            sums.add(e)
            bucket[mk] = sums
            out[bk] = bucket
        }
        return out
    }
    static func foldByDay(events: [StoredUsageEvent], normalize: @Sendable (String) -> String = { ClaudePricing.normalize($0) }) -> [String: [String: TokenSums]] { fold(events, key: localDayKey, normalize: normalize) }
    static func foldByMonth(events: [StoredUsageEvent], normalize: @Sendable (String) -> String = { ClaudePricing.normalize($0) }) -> [String: [String: TokenSums]] { fold(events, key: utcMonthKey, normalize: normalize) }
    static func foldByYear(events: [StoredUsageEvent], normalize: @Sendable (String) -> String = { ClaudePricing.normalize($0) }) -> [String: [String: TokenSums]] { fold(events, key: utcYearKey, normalize: normalize) }

    struct BucketCost { let usd: Double; let unknownModelCalls: Int; let perModel: [ModelCost] }
    static func usdForBucket(_ bucket: [String: TokenSums], pricing: ModelPriceTable = ClaudeModelPriceTable.shared) -> BucketCost {
        var total = 0.0, unknown = 0
        var per: [ModelCost] = []
        for (normalizedModel, s) in bucket {
            let unit = pricing.lookup(normalizedModel)
            if unit == nil { unknown += s.calls }
            let usd = unit?.cost(input: s.inputTokens, output: s.outputTokens,
                                 cacheRead: s.cacheReadInputTokens, cacheWrite: s.cacheCreationInputTokens) ?? 0
            total += usd
            per.append(ModelCost(model: normalizedModel, normalizedModel: normalizedModel, calls: s.calls,
                                 inputTokens: s.inputTokens, outputTokens: s.outputTokens,
                                 cacheReadTokens: s.cacheReadInputTokens, cacheCreationTokens: s.cacheCreationInputTokens,
                                 usd: usd, isUnknownPricing: unit == nil))
        }
        per.sort { $0.usd > $1.usd }
        return BucketCost(usd: total, unknownModelCalls: unknown, perModel: per)
    }

    static func dailySpend(from dayAggregates: [String: [String: TokenSums]], pricing: ModelPriceTable = ClaudeModelPriceTable.shared) -> [DaySpend] {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return dayAggregates.compactMap { (dayKey, bucket) -> DaySpend? in
            guard let date = f.date(from: dayKey) else { return nil }
            let c = usdForBucket(bucket, pricing: pricing)
            let calls = bucket.values.reduce(0) { $0 + $1.calls }
            let tokens = bucket.values.reduce(0) {
                $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadInputTokens + $1.cacheCreationInputTokens
            }
            return DaySpend(dayKey: dayKey, date: date, usd: c.usd, calls: calls, tokens: tokens)
        }.sorted { $0.dayKey < $1.dayKey }
    }
    static func monthlySpend(from monthAggregates: [String: [String: TokenSums]], pricing: ModelPriceTable = ClaudeModelPriceTable.shared) -> [MonthSpend] {
        monthAggregates.map { (monthKey, bucket) in
            let c = usdForBucket(bucket, pricing: pricing)
            return MonthSpend(monthKey: monthKey, usd: c.usd, calls: bucket.values.reduce(0) { $0 + $1.calls })
        }.sorted { $0.monthKey < $1.monthKey }
    }

    /// 从 raw events 列表中过滤出 ts >= cutoff 的事件，折叠计费，返回 CostSummary。
    /// windowLabel 仅用于调用方区分，不存入结构体。
    static func costForEvents(_ events: [StoredUsageEvent], since cutoff: Date, now: Date,
                              pricing: ModelPriceTable = ClaudeModelPriceTable.shared) -> CostSummary {
        let filtered = events.filter { $0.ts >= cutoff }
        guard !filtered.isEmpty else {
            return CostSummary(generatedAt: now, windowDays: 0, totalUSD: 0, perModel: [],
                               unknownModelCount: 0, parseErrorCount: 0, scannedFileCount: 0)
        }
        var merged: [String: TokenSums] = [:]
        for e in filtered {
            let mk = pricing.normalize(e.model)
            var s = merged[mk] ?? TokenSums()
            s.add(e)
            merged[mk] = s
        }
        let c = usdForBucket(merged, pricing: pricing)
        let windowDays = max(1, Int(ceil((now.timeIntervalSince(cutoff)) / 86400)))
        return CostSummary(generatedAt: now, windowDays: windowDays, totalUSD: c.usd, perModel: c.perModel,
                           unknownModelCount: c.unknownModelCalls, parseErrorCount: 0, scannedFileCount: 1)
    }

    static func rolling30dSummary(dayAggregates: [String: [String: TokenSums]], now: Date,
                                  scannedFileCount: Int = 1, parseErrorCount: Int = 0,
                                  pricing: ModelPriceTable = ClaudeModelPriceTable.shared) -> CostSummary {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var merged: [String: TokenSums] = [:]
        for (dayKey, bucket) in dayAggregates {
            guard let date = f.date(from: dayKey), date >= cutoff else { continue }
            for (mk, s) in bucket {
                var acc = merged[mk] ?? TokenSums()
                acc.calls += s.calls; acc.inputTokens += s.inputTokens; acc.outputTokens += s.outputTokens
                acc.cacheReadInputTokens += s.cacheReadInputTokens; acc.cacheCreationInputTokens += s.cacheCreationInputTokens
                merged[mk] = acc
            }
        }
        let c = usdForBucket(merged, pricing: pricing)
        return CostSummary(generatedAt: now, windowDays: 30, totalUSD: c.usd, perModel: c.perModel,
                           unknownModelCount: c.unknownModelCalls, parseErrorCount: parseErrorCount,
                           scannedFileCount: scannedFileCount)
    }
}

struct DaySpend: Equatable { let dayKey: String; let date: Date; let usd: Double; let calls: Int; let tokens: Int }
struct MonthSpend: Equatable { let monthKey: String; let usd: Double; let calls: Int }
