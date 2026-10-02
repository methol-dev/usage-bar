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
                .appendingPathComponent("usage-bar/data", isDirectory: true)
        }
        self.provider = provider
    }

    /// ~/.config/usage-bar/
    static func defaultConfigDir() -> URL? {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar", isDirectory: true)
    }

    private var providerDir: URL { dataDir.appendingPathComponent(provider.rawValue, isDirectory: true) }
    /// agg 桶的模型 key 规范化：随 provider 走，保证任何重建入口（含 `resolvedAgg` 的自动重建）口径一致。
    private var normalize: @Sendable (String) -> String {
        if provider == .codex { return { OpenAIPricing.normalize($0) } }
        return { ClaudePricing.normalize($0) }
    }
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
    @discardableResult
    private func writeAtomic0600(_ data: Data, to url: URL) -> Bool {
        ensureDir(url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("[usage-bar] store write: \(type(of: error))")
            return false
        }
    }

    private func loadMonth(_ key: String) -> MonthDetailFile? {
        guard let data = try? Data(contentsOf: monthFileURL(key)) else { return nil }
        do { return try Self.decoder.decode(MonthDetailFile.self, from: data) }
        catch { NSLog("[usage-bar] store decode month: \(type(of: error))"); return nil }
    }
    @discardableResult
    private func saveMonth(_ file: MonthDetailFile, key: String) -> Bool {
        guard let data = try? Self.encoder.encode(file) else { return false }
        return writeAtomic0600(data, to: monthFileURL(key))
    }

    // MARK: public — 一次性存量修复

    private var migrationsURL: URL { providerDir.appendingPathComponent("migrations.json") }
    private struct MigrationsFile: Codable { var done: [String] }

    /// 对全部存量明细跑一次 `transform`（**只删不改**：返回输入的子集；跨月整体处理，同一会话可能跨月），只跑一次：
    /// 完成标记记在 `<provider>/migrations.json`，且**所有**改动的月文件写盘成功后才落标记（失败下次重试）。
    /// 改写前把被改动的月文件备份成 `<YYYY-MM>.pre-<name>.bak.json`（源 JSONL 可能已被 CLI 清理，写错无从重扫恢复）。
    /// 有改动则全量重建 agg。返回是否改动了数据。
    @discardableResult
    func runMigrationOnce(_ name: String, transform: ([StoredUsageEvent]) -> [StoredUsageEvent]) -> Bool {
        var marks = (try? Data(contentsOf: migrationsURL)).flatMap { try? Self.decoder.decode(MigrationsFile.self, from: $0) }
            ?? MigrationsFile(done: [])
        guard !marks.done.contains(name) else { return false }
        let keys = allMonthKeys()
        var before: [String: [StoredUsageEvent]] = [:]
        for k in keys {
            // 有月文件解码失败就不动（mergeEvents 那条路会处理损坏文件），下次再试
            guard let mf = loadMonth(k) else { NSLog("[usage-bar] migration \(name) deferred: month file unreadable"); return false }
            before[k] = mf.events
        }
        let after = Dictionary(grouping: transform(keys.flatMap { before[$0] ?? [] })) { Self.utcMonthKey($0.ts) }
        var changed = false
        for k in Set(keys).union(after.keys) {
            let new = (after[k] ?? []).sorted { $0.ts < $1.ts }
            guard new.count != (before[k] ?? []).count else { continue }
            changed = true
            let url = monthFileURL(k)
            if fm.fileExists(atPath: url.path) {
                let backup = providerDir.appendingPathComponent("\(k).pre-\(name).bak.json")
                try? fm.removeItem(at: backup)
                guard (try? fm.copyItem(at: url, to: backup)) != nil else { return false }
            }
            guard saveMonth(MonthDetailFile(provider: provider.rawValue, month: k, lastUpdated: Date(), events: new), key: k)
            else { return false }
        }
        if changed { rebuildAllAggregates() }
        marks.done.append(name)
        if let data = try? Self.encoder.encode(marks) { writeAtomic0600(data, to: migrationsURL) }
        return changed
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
            if parsed == nil && fm.fileExists(atPath: url.path) {
                dirty.insert(monthKey)
                // 解码失败的旧文件先挪成 .bak 再覆盖：恢复依赖「下次 collect 重扫源 JSONL」，
                // 但 Claude CLI 会清理旧 session 文件，源没了的话直接覆盖 = 该月数据永久丢失。
                let backup = url.deletingPathExtension().appendingPathExtension("bak.json")
                try? fm.removeItem(at: backup)
                try? fm.moveItem(at: url, to: backup)
            }
            var existing = parsed?.events ?? []
            var indexByKey: [String: Int] = [:]
            for (i, e) in existing.enumerated() {
                indexByKey["\(e.msgId)|\(e.reqId)"] = i
            }
            for e in newEvents {
                let k = "\(e.msgId)|\(e.reqId)"
                if let i = indexByKey[k] {
                    // 同 key 保留更新的快照（流式 JSONL 后到的一行才是终态 output）
                    if e.ts >= existing[i].ts { existing[i] = e }
                } else {
                    indexByKey[k] = existing.count
                    existing.append(e)
                }
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
            return f.schemaVersion == AggregateFile.currentSchemaVersion ? f : nil
        } catch { NSLog("[usage-bar] store decode agg: \(type(of: error))"); return nil }
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

    func rebuildAllAggregates() {
        let allEvents = allMonthKeys().flatMap { eventsForMonth($0) }
        saveAgg("day", buckets: UsageAggregator.foldByDay(events: allEvents, normalize: normalize))
        saveAgg("month", buckets: UsageAggregator.foldByMonth(events: allEvents, normalize: normalize))
        saveAgg("year", buckets: UsageAggregator.foldByYear(events: allEvents, normalize: normalize))
    }

    /// 增量重建：只读受影响的月明细文件，重算受影响的 day/month/year 桶覆盖回去。
    func rebuildAggregates(forDayKeys dayKeys: Set<String>) {
        guard !dayKeys.isEmpty else { return }
        // 任一 agg 缺失 / 旧版本 → 增量基底不可信（从空表增量会把其它日期的历史覆盖掉），改走全量重建。
        guard var day = loadAgg("day")?.buckets, var month = loadAgg("month")?.buckets,
              var year = loadAgg("year")?.buckets else {
            rebuildAllAggregates(); return
        }
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
