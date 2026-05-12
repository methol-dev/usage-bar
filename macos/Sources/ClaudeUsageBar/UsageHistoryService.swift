import Foundation
import Combine
import AppKit

@MainActor
class UsageHistoryService: ObservableObject {
    @Published var history = UsageHistory()

    private var flushTimer: AnyCancellable?
    private var isDirty = false
    private var terminationObserver: Any?

    private static let retentionInterval: TimeInterval = 30 * 86400 // 30 days
    private static let flushInterval: TimeInterval = 300 // 5 minutes

    /// 写到哪个文件（默认 `~/.config/claude-usage-bar/history.json` —— Claude 历史；
    /// Codex 用 `history-codex.json`）。`internal` 而非 `private`：单测要断言默认路径未变。
    let fileURL: URL
    /// 解析失败时把坏文件挪走的备份名（`<base>.bak.json`），由 `fileURL` 派生。
    let backupURL: URL

    private static var defaultDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(filename: String = "history.json", directory: URL? = nil) {
        let dir: URL
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            dir = directory
        } else {
            dir = Self.defaultDirectory
        }
        self.fileURL = dir.appendingPathComponent(filename)
        self.backupURL = self.fileURL.deletingPathExtension().appendingPathExtension("bak.json")

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushToDisk()
            }
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Load

    func loadHistory() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            var loaded = try JSONDecoder.historyDecoder.decode(UsageHistory.self, from: data)
            loaded.dataPoints = pruned(loaded.dataPoints)
            history = loaded
        } catch {
            // Corrupt file — rename to .bak and start fresh
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            history = UsageHistory()
        }
    }

    // MARK: - Record

    func recordDataPoint(pct5h: Double, pct7d: Double) {
        let point = UsageDataPoint(pct5h: pct5h, pct7d: pct7d)
        history.dataPoints.append(point)
        isDirty = true
        startFlushTimerIfNeeded()
    }

    // MARK: - Flush

    func flushToDisk() {
        guard isDirty else { return }
        history.dataPoints = pruned(history.dataPoints)

        guard let data = try? JSONEncoder.historyEncoder.encode(history) else { return }
        try? data.write(to: fileURL, options: .atomic)

        isDirty = false
        flushTimer?.cancel()
        flushTimer = nil
    }

    private func startFlushTimerIfNeeded() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.publish(every: Self.flushInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.flushToDisk()
            }
    }

    // MARK: - Downsampling

    func downsampledPoints(for range: TimeRange) -> [UsageDataPoint] {
        let allPoints = history.dataPoints

        guard allPoints.count > range.targetPointCount else { return allPoints }

        let now = Date()
        let rangeStart = now.addingTimeInterval(-range.interval)
        let bucketCount = range.targetPointCount
        let bucketDuration = range.interval / Double(bucketCount)

        var buckets = [[UsageDataPoint]](repeating: [], count: bucketCount)

        for point in allPoints {
            let offset = point.timestamp.timeIntervalSince(rangeStart)
            var index = Int(offset / bucketDuration)
            if index < 0 { index = 0 }
            if index >= bucketCount { index = bucketCount - 1 }
            buckets[index].append(point)
        }

        return buckets.compactMap { bucket -> UsageDataPoint? in
            guard !bucket.isEmpty else { return nil }
            let avgPct5h = bucket.map(\.pct5h).reduce(0, +) / Double(bucket.count)
            let avgPct7d = bucket.map(\.pct7d).reduce(0, +) / Double(bucket.count)
            let avgTimestamp = bucket.map { $0.timestamp.timeIntervalSince1970 }.reduce(0, +) / Double(bucket.count)
            return UsageDataPoint(
                timestamp: Date(timeIntervalSince1970: avgTimestamp),
                pct5h: avgPct5h,
                pct7d: avgPct7d
            )
        }
    }

    // MARK: - Pruning

    private func pruned(_ points: [UsageDataPoint]) -> [UsageDataPoint] {
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)
        return points.filter { $0.timestamp >= cutoff }
    }
}

// MARK: - JSON Coding Helpers

private extension JSONDecoder {
    static let historyDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let historyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

// MARK: - v0.2.5 multi-provider refactor

/// `UsageService`（Claude provider）通过 `HistoryRecording` 协议持有它，便于单测注入 spy。
extension UsageHistoryService: HistoryRecording {}
