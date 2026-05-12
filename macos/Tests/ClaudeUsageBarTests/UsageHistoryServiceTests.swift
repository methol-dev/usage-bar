import XCTest
@testable import ClaudeUsageBar

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
        XCTAssertEqual(parent.lastPathComponent, "claude-usage-bar")
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

    func testLoadCorruptFileMovesToBak() throws {
        try Data("{ not json".utf8).write(to: tmpDir.appendingPathComponent("history-codex.json"))
        let h = UsageHistoryService(filename: "history-codex.json", directory: tmpDir)
        h.loadHistory()
        XCTAssertTrue(h.history.dataPoints.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("history-codex.bak.json").path))
    }
}
