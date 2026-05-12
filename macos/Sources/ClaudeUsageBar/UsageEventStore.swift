import Foundation

actor UsageEventStore {
    private let dataDir: URL
    private let provider: ProviderID
    private let fm = FileManager.default

    init(dataDirOverride: URL? = nil, provider: ProviderID = .claude) {
        if let o = dataDirOverride {
            self.dataDir = o
        } else if let cfg = UsageEventStore.defaultConfigDir() {
            self.dataDir = cfg.appendingPathComponent("data", isDirectory: true)
        } else {
            self.dataDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("claude-usage-bar/data", isDirectory: true)
        }
        self.provider = provider
    }

    /// ~/.config/claude-usage-bar/
    static func defaultConfigDir() -> URL? {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar", isDirectory: true)
    }

    private var providerDir: URL { dataDir.appendingPathComponent(provider.rawValue, isDirectory: true) }
    private func monthFileURL(_ key: String) -> URL { providerDir.appendingPathComponent("\(key).json") }

    // MARK: month key (UTC)
    private static let utcMonthFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"; return f
    }()
    static func utcMonthKey(_ d: Date) -> String { utcMonthFormatter.string(from: d) }

    // MARK: codec
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    private func ensureDir(_ url: URL) {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }
    private func writeAtomic0600(_ data: Data, to url: URL) {
        ensureDir(url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[claude-usage-bar] store write: \(type(of: error))")
        }
    }

    private func loadMonth(_ key: String) -> MonthDetailFile? {
        guard let data = try? Data(contentsOf: monthFileURL(key)) else { return nil }
        do { return try Self.decoder.decode(MonthDetailFile.self, from: data) }
        catch { NSLog("[claude-usage-bar] store decode month: \(type(of: error))"); return nil }
    }
    private func saveMonth(_ file: MonthDetailFile, key: String) {
        guard let data = try? Self.encoder.encode(file) else { return }
        writeAtomic0600(data, to: monthFileURL(key))
    }

    // MARK: public — merge
    @discardableResult
    func mergeEvents(_ events: [StoredUsageEvent]) -> Set<String> {
        guard !events.isEmpty else { return [] }
        var dirty: Set<String> = []
        let grouped = Dictionary(grouping: events) { Self.utcMonthKey($0.ts) }
        for (monthKey, newEvents) in grouped {
            let url = monthFileURL(monthKey)
            let parsed = loadMonth(monthKey)
            if parsed == nil && fm.fileExists(atPath: url.path) { dirty.insert(monthKey) }
            var existing = parsed?.events ?? []
            var seen = Set(existing.map { "\($0.msgId)|\($0.reqId)" })
            for e in newEvents {
                let k = "\(e.msgId)|\(e.reqId)"
                if seen.contains(k) { continue }
                seen.insert(k); existing.append(e)
            }
            existing.sort { $0.ts < $1.ts }
            saveMonth(MonthDetailFile(provider: provider.rawValue, month: monthKey,
                                      lastUpdated: Date(), events: existing), key: monthKey)
        }
        return dirty
    }

    // MARK: public — query
    func queryEvents(from: Date, to: Date) -> [StoredUsageEvent] {
        guard fm.fileExists(atPath: providerDir.path) else { return [] }
        let fromKey = Self.utcMonthKey(from), toKey = Self.utcMonthKey(to)
        guard let files = try? fm.contentsOfDirectory(at: providerDir, includingPropertiesForKeys: nil) else { return [] }
        var result: [StoredUsageEvent] = []
        for f in files where f.pathExtension == "json" {
            let name = f.deletingPathExtension().lastPathComponent  // "YYYY-MM" or "agg-day" ...
            // 用 !hasPrefix("agg") 明确排除 agg-* 文件（"agg-day" 也是 7 字符，光靠 count 不够稳）
            guard !name.hasPrefix("agg"), name.count == 7, name <= toKey, name >= fromKey else { continue }
            if let mf = loadMonth(name) {
                result.append(contentsOf: mf.events.filter { $0.ts >= from && $0.ts < to })
            }
        }
        return result.sorted { $0.ts < $1.ts }
    }

    // MARK: 内部访问器
    func allMonthKeys() -> [String] {
        guard let files = try? fm.contentsOfDirectory(at: providerDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0.count == 7 && $0.contains("-") && !$0.hasPrefix("agg") }
            .sorted()
    }
    func eventsForMonth(_ key: String) -> [StoredUsageEvent] { loadMonth(key)?.events ?? [] }

    // MARK: aggregates
    private func aggFileURL(_ kind: String) -> URL { providerDir.appendingPathComponent("agg-\(kind).json") }

    private func loadAgg(_ kind: String) -> AggregateFile? {
        guard let data = try? Data(contentsOf: aggFileURL(kind)) else { return nil }
        do {
            let f = try Self.decoder.decode(AggregateFile.self, from: data)
            return f.schemaVersion == 1 ? f : nil
        } catch { NSLog("[claude-usage-bar] store decode agg: \(type(of: error))"); return nil }
    }
    private func saveAgg(_ kind: String, buckets: [String: [String: TokenSums]]) {
        let f = AggregateFile(provider: provider.rawValue, lastUpdated: Date(), buckets: buckets)
        guard let data = try? Self.encoder.encode(f) else { return }
        writeAtomic0600(data, to: aggFileURL(kind))
    }

    func readDayAggregates() -> [String: [String: TokenSums]] { resolvedAgg("day") }
    func readMonthAggregates() -> [String: [String: TokenSums]] { resolvedAgg("month") }
    func readYearAggregates() -> [String: [String: TokenSums]] { resolvedAgg("year") }
    private func resolvedAgg(_ kind: String) -> [String: [String: TokenSums]] {
        if let f = loadAgg(kind) { return f.buckets }
        rebuildAllAggregates()
        return loadAgg(kind)?.buckets ?? [:]
    }

    func rebuildAllAggregates(normalize: @Sendable (String) -> String = { ClaudePricing.normalize($0) }) {
        let allEvents = allMonthKeys().flatMap { eventsForMonth($0) }
        saveAgg("day", buckets: UsageAggregator.foldByDay(events: allEvents, normalize: normalize))
        saveAgg("month", buckets: UsageAggregator.foldByMonth(events: allEvents, normalize: normalize))
        saveAgg("year", buckets: UsageAggregator.foldByYear(events: allEvents, normalize: normalize))
    }

    /// 增量重建：只读受影响的月明细文件，重算受影响的 day/month/year 桶覆盖回去。
    func rebuildAggregates(forDayKeys dayKeys: Set<String>, normalize: @Sendable (String) -> String = { ClaudePricing.normalize($0) }) {
        guard !dayKeys.isEmpty else { return }
        let dayFmt = DateFormatter(); dayFmt.calendar = Calendar(identifier: .gregorian)
        dayFmt.timeZone = TimeZone.current; dayFmt.locale = Locale(identifier: "en_US_POSIX"); dayFmt.dateFormat = "yyyy-MM-dd"
        var candidateMonths = Set<String>()
        for dk in dayKeys {
            guard let start = dayFmt.date(from: dk) else { continue }
            let end = start.addingTimeInterval(24 * 3600 - 1)
            candidateMonths.insert(Self.utcMonthKey(start))
            candidateMonths.insert(Self.utcMonthKey(end))
        }
        let candidateYears = Set(candidateMonths.map { String($0.prefix(4)) })
        let monthsToLoad = Set(allMonthKeys().filter { mk in
            candidateMonths.contains(mk) || candidateYears.contains(String(mk.prefix(4)))
        })
        let loadedEvents = monthsToLoad.flatMap { eventsForMonth($0) }
        let touchedEvents = loadedEvents.filter { dayKeys.contains(UsageAggregator.localDayKey($0.ts)) }
        let touchedMonthKeys = Set(touchedEvents.map { UsageAggregator.utcMonthKey($0.ts) })
        let touchedYearKeys = Set(touchedEvents.map { UsageAggregator.utcYearKey($0.ts) })

        var day = loadAgg("day")?.buckets ?? [:]
        var month = loadAgg("month")?.buckets ?? [:]
        var year = loadAgg("year")?.buckets ?? [:]
        for k in dayKeys { day[k] = nil }
        for k in touchedMonthKeys { month[k] = nil }
        for k in touchedYearKeys { year[k] = nil }
        let monthEvents = loadedEvents.filter { touchedMonthKeys.contains(UsageAggregator.utcMonthKey($0.ts)) }
        let yearEvents = loadedEvents.filter { touchedYearKeys.contains(UsageAggregator.utcYearKey($0.ts)) }
        for (k, v) in UsageAggregator.foldByDay(events: touchedEvents, normalize: normalize) { day[k] = v }
        for (k, v) in UsageAggregator.foldByMonth(events: monthEvents, normalize: normalize) { month[k] = v }
        for (k, v) in UsageAggregator.foldByYear(events: yearEvents, normalize: normalize) { year[k] = v }
        saveAgg("day", buckets: day); saveAgg("month", buckets: month); saveAgg("year", buckets: year)
    }
}
