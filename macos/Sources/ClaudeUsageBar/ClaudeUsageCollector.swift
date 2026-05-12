import Foundation

struct CollectResult {
    let newEventCount: Int
    let scannedFileCount: Int
    let parseErrorCount: Int
    let touchedDayKeys: Set<String>
}

actor ClaudeUsageCollector: UsageCollecting {
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
        var scanned = 0, parseErrors = 0

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
                guard let offset = await cursor.nextReadOffset(for: file, currentSize: size, currentMTime: mtime) else { continue }
                guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let endsWithNL = raw.hasSuffix("\n")
                let allLines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                let usableCount = endsWithNL ? allLines.count : max(allLines.count - 1, offset)
                let sessionId = file.deletingPathExtension().lastPathComponent
                if offset < usableCount {
                    for i in offset..<usableCount {
                        do {
                            guard let ev = try JSONLCostParser.parseLine(allLines[i]) else { continue }
                            collected.append(StoredUsageEvent(
                                ts: ev.timestamp, msgId: ev.messageId, reqId: ev.requestId, sessionId: sessionId,
                                model: ev.model, inputTokens: ev.inputTokens, outputTokens: ev.outputTokens,
                                cacheReadInputTokens: ev.cacheReadInputTokens, cacheCreationInputTokens: ev.cacheCreationInputTokens))
                        } catch {
                            parseErrors += 1
                            NSLog("[claude-usage-bar] usage collect: \(type(of: error))")
                        }
                    }
                }
                await cursor.updateCursor(for: file, size: size, mtime: mtime, lineOffset: usableCount)
            }
        }

        guard !collected.isEmpty else {
            await cursor.flush()
            lastResult = CollectResult(newEventCount: 0, scannedFileCount: scanned, parseErrorCount: parseErrors, touchedDayKeys: [])
            return lastResult
        }
        let dirty = await store.mergeEvents(collected)
        let touchedDays = Set(collected.map { UsageAggregator.localDayKey($0.ts) })
        if dirty.isEmpty {
            await store.rebuildAggregates(forDayKeys: touchedDays)
        } else {
            for f in scannedFiles { await cursor.clearCursor(for: f) }
            await store.rebuildAllAggregates()
        }
        await cursor.flush()
        lastResult = CollectResult(newEventCount: collected.count, scannedFileCount: scanned, parseErrorCount: parseErrors, touchedDayKeys: touchedDays)
        return lastResult
    }

    // MARK: scanRoots（从 v0.1.2 LocalCostScanner 复制；LocalCostScanner.swift Task 7 删除）
    static func scanRoots() -> [URL] {
        scanRoots(env: ProcessInfo.processInfo.environment,
                  home: FileManager.default.homeDirectoryForCurrentUser,
                  fileExists: { FileManager.default.fileExists(atPath: $0) })
    }
    static func scanRoots(env: [String: String], home: URL, fileExists: (String) -> Bool) -> [URL] {
        var roots: [URL] = []
        if let v = env["CLAUDE_CONFIG_DIR"], !v.isEmpty {
            for path in v.split(separator: ":") {
                let url = URL(fileURLWithPath: String(path)).appendingPathComponent("projects", isDirectory: true)
                if fileExists(url.path) { roots.append(url) }
            }
        }
        let xdg = home.appendingPathComponent(".config/claude/projects", isDirectory: true)
        if fileExists(xdg.path) { roots.append(xdg) }
        let legacy = home.appendingPathComponent(".claude/projects", isDirectory: true)
        if fileExists(legacy.path) { roots.append(legacy) }
        return roots
    }
}
