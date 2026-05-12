import Foundation

/// 扫 `~/.codex/sessions/**/rollout-*.jsonl`（或 `$CODEX_HOME/sessions`）→ `CodexRolloutCostParser` → `UsageEventStore(provider:.codex)`。
///
/// 与 `ClaudeUsageCollector` 的区别：rollout 文件是 append-only 但**含用户完整会话/代码原文**，所以这里
/// - 游标只用来判「文件变没变」（`nextReadOffset` 返回 nil 即跳过），变了就**整文件 re-parse**，靠
///   `(msgId,reqId) = sessionId:lineIndex` 在 `UsageEventStore.mergeEvents` 里去重保证幂等；
/// - **绝不** print / NSLog / os_log（连「第几行解析失败」都不打）。见 spec SC9。
actor CodexUsageCollector: UsageCollecting {
    private let store: UsageEventStore
    private let cursor: ScanCursorStore
    private let scanRootsOverride: [URL]?
    private let fm = FileManager.default
    private var inFlight = false
    private var lastResult = CollectResult(newEventCount: 0, scannedFileCount: 0, parseErrorCount: 0, touchedDayKeys: [])

    init(store: UsageEventStore, cursor: ScanCursorStore, scanRootsOverride: [URL]? = nil) {
        self.store = store; self.cursor = cursor; self.scanRootsOverride = scanRootsOverride
    }

    func collect() async -> CollectResult {
        if inFlight { return lastResult }
        inFlight = true
        defer { inFlight = false }

        let roots = scanRootsOverride ?? Self.scanRoots()
        var collected: [StoredUsageEvent] = []
        var scannedFiles: [URL] = []
        var scanned = 0

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else { continue }
            for case let file as URL in enumerator {
                guard file.pathExtension == "jsonl" else { continue }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                scanned += 1
                scannedFiles.append(file)
                let attrs = (try? fm.attributesOfItem(atPath: file.path)) ?? [:]
                let size = (attrs[.size] as? Int) ?? 0
                let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                // nil = 没变 → 跳过；非 nil（首见 / 变大 / 变小 / mtime 回退）→ 整文件 re-parse
                guard await cursor.nextReadOffset(for: file, currentSize: size, currentMTime: mtime) != nil else { continue }
                guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let allLines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                let sessionId = CodexRolloutCostParser.sessionId(fromFileName: file.lastPathComponent)
                collected.append(contentsOf: CodexRolloutCostParser.parseFile(lines: allLines, sessionId: sessionId))
                await cursor.updateCursor(for: file, size: size, mtime: mtime, lineOffset: allLines.count)
            }
        }

        guard !collected.isEmpty else {
            await cursor.flush()
            lastResult = CollectResult(newEventCount: 0, scannedFileCount: scanned, parseErrorCount: 0, touchedDayKeys: [])
            return lastResult
        }
        let dirty = await store.mergeEvents(collected)
        let touchedDays = Set(collected.map { UsageAggregator.localDayKey($0.ts) })
        if dirty.isEmpty {
            await store.rebuildAggregates(forDayKeys: touchedDays, normalize: { OpenAIPricing.normalize($0) })
        } else {
            for f in scannedFiles { await cursor.clearCursor(for: f) }
            await store.rebuildAllAggregates(normalize: { OpenAIPricing.normalize($0) })
        }
        await cursor.flush()
        lastResult = CollectResult(newEventCount: collected.count, scannedFileCount: scanned, parseErrorCount: 0, touchedDayKeys: touchedDays)
        return lastResult
    }

    // MARK: scanRoots
    static func scanRoots() -> [URL] {
        scanRoots(env: ProcessInfo.processInfo.environment,
                  home: FileManager.default.homeDirectoryForCurrentUser,
                  fileExists: { FileManager.default.fileExists(atPath: $0) })
    }
    /// `$CODEX_HOME/sessions` 优先（若设置且存在）；否则 `~/.codex/sessions`（存在才纳入）。
    static func scanRoots(env: [String: String], home: URL, fileExists: (String) -> Bool) -> [URL] {
        var roots: [URL] = []
        if let v = env["CODEX_HOME"], !v.isEmpty {
            let url = URL(fileURLWithPath: v).appendingPathComponent("sessions", isDirectory: true)
            if fileExists(url.path) { roots.append(url) }
        }
        let dflt = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        if fileExists(dflt.path), !roots.contains(dflt) { roots.append(dflt) }
        return roots
    }
}
