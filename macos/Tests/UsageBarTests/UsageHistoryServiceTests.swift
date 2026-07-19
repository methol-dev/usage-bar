import XCTest
@testable import UsageBar

@MainActor
final class UsageHistoryServiceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testInitDefaultPathUnchanged() {
        let h = UsageHistoryService()
        XCTAssertEqual(h.fileURL.lastPathComponent, "history.json")
        XCTAssertEqual(h.backupURL.lastPathComponent, "history.bak.json")
        let parent = h.fileURL.deletingLastPathComponent()
        XCTAssertEqual(parent.lastPathComponent, "usage-bar")
        XCTAssertEqual(parent.deletingLastPathComponent().lastPathComponent, ".config")
    }

    func testRecordFlushReloadCustomFile() throws {
        let h = UsageHistoryService(filename: "history-codex.json", directory: tmpDir)
        h.recordDataPoint(pct5h: 0.5, pct7d: 0.2)
        h.flushToDisk()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("history-codex.json").path))
        let h2 = UsageHistoryService(filename: "history-codex.json", directory: tmpDir)
        h2.loadHistory()
        XCTAssertEqual(h2.history.dataPoints.count, 1)
        XCTAssertEqual(h2.history.dataPoints.first?.pct5h, 0.5)
        XCTAssertEqual(h2.history.dataPoints.first?.pct7d, 0.2)
    }

    func testTwoFilenamesNoCollision() {
        let a = UsageHistoryService(filename: "history.json", directory: tmpDir)
        let b = UsageHistoryService(filename: "history-codex.json", directory: tmpDir)
        a.recordDataPoint(pct5h: 0.1, pct7d: 0.1); a.flushToDisk()
        b.recordDataPoint(pct5h: 0.9, pct7d: 0.9); b.flushToDisk()
        let a2 = UsageHistoryService(filename: "history.json", directory: tmpDir); a2.loadHistory()
        let b2 = UsageHistoryService(filename: "history-codex.json", directory: tmpDir); b2.loadHistory()
        XCTAssertEqual(a2.history.dataPoints.count, 1)
        XCTAssertEqual(a2.history.dataPoints.first?.pct5h, 0.1)
        XCTAssertEqual(b2.history.dataPoints.count, 1)
        XCTAssertEqual(b2.history.dataPoints.first?.pct5h, 0.9)
    }

    func testFlushedFileIsOwnerOnly() throws {
        let h = UsageHistoryService(filename: "history-codex.json", directory: tmpDir)
        h.recordDataPoint(pct5h: 0.3, pct7d: 0.3)
        h.flushToDisk()
        let attrs = try FileManager.default.attributesOfItem(atPath: tmpDir.appendingPathComponent("history-codex.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - 记点三防线（取整到秒 / 同刻去重 / 时序插入）—— web 源 payload 时刻落点的配套

    func testDuplicateTimestampIsSkipped() {
        let h = UsageHistoryService(filename: "history.json", directory: tmpDir)
        let ts = Date(timeIntervalSince1970: 1_752_900_000)
        h.recordDataPoint(pct5h: 0.2, pct7d: 0.3, timestamp: ts)
        h.recordDataPoint(pct5h: 0.9, pct7d: 0.9, timestamp: ts)   // 重启后重放同一 payload
        XCTAssertEqual(h.history.dataPoints.count, 1, "同时间戳不重复记（UsageDataPoint.id == timestamp）")
        XCTAssertEqual(h.history.dataPoints.first?.pct5h, 0.2, "保留先到的点")
    }

    func testTimestampFlooredToWholeSecondSurvivesReload() throws {
        let h = UsageHistoryService(filename: "history.json", directory: tmpDir)
        let ts = Date(timeIntervalSince1970: 1_752_900_000.7)
        h.recordDataPoint(pct5h: 0.5, pct7d: 0.5, timestamp: ts)
        h.flushToDisk()
        let h2 = UsageHistoryService(filename: "history.json", directory: tmpDir)
        h2.loadHistory()
        // ISO8601 编码丢亚秒——记点时已取整，重放同一 payload 时同刻判定跨重启依然命中
        h2.recordDataPoint(pct5h: 0.5, pct7d: 0.5, timestamp: ts)
        XCTAssertEqual(h2.history.dataPoints.count, 1)
        XCTAssertEqual(h2.history.dataPoints.first?.timestamp, Date(timeIntervalSince1970: 1_752_900_000))
    }

    func testEarlierTimestampInsertedInOrder() {
        let h = UsageHistoryService(filename: "history.json", directory: tmpDir)
        let base = Date(timeIntervalSince1970: 1_752_900_000)
        h.recordDataPoint(pct5h: 0.1, pct7d: 0.1, timestamp: base)
        h.recordDataPoint(pct5h: 0.3, pct7d: 0.3, timestamp: base.addingTimeInterval(600))
        // web 源的 payload 时刻可能早于已记的 CLI 点——插入后仍按时序（图表按数组序连线）
        h.recordDataPoint(pct5h: 0.2, pct7d: 0.2, timestamp: base.addingTimeInterval(300))
        XCTAssertEqual(h.history.dataPoints.map(\.pct5h), [0.1, 0.2, 0.3])
    }

    func testLoadCorruptFileMovesToBak() throws {
        try Data("{ not json".utf8).write(to: tmpDir.appendingPathComponent("history-codex.json"))
        let h = UsageHistoryService(filename: "history-codex.json", directory: tmpDir)
        h.loadHistory()
        XCTAssertTrue(h.history.dataPoints.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("history-codex.bak.json").path))
    }
}
