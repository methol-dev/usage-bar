import XCTest
@testable import UsageBar

final class ClaudeUsageCollectorTests: XCTestCase {
    private var tmpRoot: URL!     // 模拟 ~/.claude/projects
    private var tmpData: URL!     // 模拟 ~/.config/usage-bar/data
    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collector-test-\(UUID().uuidString)", isDirectory: true)
        tmpRoot = base.appendingPathComponent("projects", isDirectory: true)
        tmpData = base.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpData, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmpRoot.deletingLastPathComponent()) }

    private func assistantLine(ts: String, msg: String, req: String, model: String = "claude-opus-4-7", input: Int = 100, output: Int = 50) -> String {
        """
        {"type":"assistant","requestId":"\(req)","timestamp":"\(ts)","message":{"id":"\(msg)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }
    private func writeSession(_ dir: String, _ uuid: String, lines: [String], trailingNewline: Bool = true) throws -> URL {
        let projDir = tmpRoot.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let f = projDir.appendingPathComponent("\(uuid).jsonl")
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).data(using: .utf8)!.write(to: f)
        return f
    }
    private func makeCollector() -> ClaudeUsageCollector {
        ClaudeUsageCollector(store: UsageEventStore(dataDirOverride: tmpData),
                             cursor: ScanCursorStore(dataDirOverride: tmpData),
                             scanRootsOverride: [tmpRoot])
    }

    func testFirstScanBackfillsAllHistoryAcrossMonths() async throws {
        _ = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [
            assistantLine(ts: "2026-04-15T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a"),
            assistantLine(ts: "2026-05-15T10:00:00.000Z", msg: "msg_mock_b", req: "req_mock_b"),
        ])
        let r = await makeCollector().collect()
        XCTAssertEqual(r.newEventCount, 2)
        XCTAssertEqual(r.scannedFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpData.appendingPathComponent("claude/2026-04.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpData.appendingPathComponent("claude/2026-05.json").path))
    }
    func testIncrementalSecondScanOnlyCountsNewLines() async throws {
        let store = UsageEventStore(dataDirOverride: tmpData)
        let cursor = ScanCursorStore(dataDirOverride: tmpData)
        let f = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a"),
        ])
        let c1 = ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot])
        let n1 = await c1.collect().newEventCount
        XCTAssertEqual(n1, 1)
        var content = try String(contentsOf: f, encoding: .utf8)
        content += assistantLine(ts: "2026-05-11T10:00:00.000Z", msg: "msg_mock_b", req: "req_mock_b") + "\n"
        try content.data(using: .utf8)!.write(to: f)
        let c2 = ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot])
        let n2 = await c2.collect().newEventCount
        XCTAssertEqual(n2, 1)
    }
    func testNoNewEventsReturnsZeroAndNoWrite() async throws {
        _ = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a"),
        ])
        let store = UsageEventStore(dataDirOverride: tmpData), cursor = ScanCursorStore(dataDirOverride: tmpData)
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        let monthPath = tmpData.appendingPathComponent("claude/2026-05.json").path
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: monthPath)[.modificationDate] as! Date
        let r = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        XCTAssertEqual(r.newEventCount, 0)
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: monthPath)[.modificationDate] as! Date
        XCTAssertEqual(mtimeBefore, mtimeAfter)
    }
    func testPartialLastLineNotConsumed() async throws {
        let store = UsageEventStore(dataDirOverride: tmpData), cursor = ScanCursorStore(dataDirOverride: tmpData)
        let f = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a"),
            #"{"type":"assistant","requestId":"req_mock_b","timestamp":"2026-05-11T10:"#,
        ], trailingNewline: false)
        let r1 = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        XCTAssertEqual(r1.newEventCount, 1)
        try (assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a") + "\n"
            + assistantLine(ts: "2026-05-11T10:00:00.000Z", msg: "msg_mock_b", req: "req_mock_b") + "\n").data(using: .utf8)!.write(to: f)
        let r2 = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        XCTAssertEqual(r2.newEventCount, 1)
    }
    func testParseErrorDoesNotAbortScan() async throws {
        _ = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [
            "{ garbage",
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a"),
        ])
        let r = await makeCollector().collect()
        XCTAssertEqual(r.newEventCount, 1)
        XCTAssertGreaterThanOrEqual(r.parseErrorCount, 1)
    }
    func testDeduplicatesAcrossRepeatedCollect() async throws {
        let store = UsageEventStore(dataDirOverride: tmpData), cursor = ScanCursorStore(dataDirOverride: tmpData)
        _ = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: Array(repeating:
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a"), count: 4))
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        let got = await store.queryEvents(from: ISO8601DateFormatter().date(from: "2026-05-01T00:00:00Z")!,
                                          to: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!)
        XCTAssertEqual(got.count, 1)
    }

    func testStreamingLaterLineReplacesPartialOutput() async throws {
        let store = UsageEventStore(dataDirOverride: tmpData)
        let cursor = ScanCursorStore(dataDirOverride: tmpData)
        _ = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a", output: 4),
            assistantLine(ts: "2026-05-10T10:00:02.000Z", msg: "msg_mock_a", req: "req_mock_a", output: 644),
        ])
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        let fmt = ISO8601DateFormatter()
        let events = await store.queryEvents(from: fmt.date(from: "2026-05-01T00:00:00Z")!,
                                             to: fmt.date(from: "2026-06-01T00:00:00Z")!)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outputTokens, 644)
    }

    func testIncrementalStreamAppendReplacesStoredPartial() async throws {
        let store = UsageEventStore(dataDirOverride: tmpData)
        let cursor = ScanCursorStore(dataDirOverride: tmpData)
        let f = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a", output: 4),
        ])
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        var content = try String(contentsOf: f, encoding: .utf8)
        content += assistantLine(ts: "2026-05-10T10:00:03.000Z", msg: "msg_mock_a", req: "req_mock_a", output: 644) + "\n"
        try content.data(using: .utf8)!.write(to: f)
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        let fmt = ISO8601DateFormatter()
        let events = await store.queryEvents(from: fmt.date(from: "2026-05-01T00:00:00Z")!,
                                             to: fmt.date(from: "2026-06-01T00:00:00Z")!)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.outputTokens, 644)
    }

    func testCollectsSplitCacheWriteTokens() async throws {
        let store = UsageEventStore(dataDirOverride: tmpData)
        let cursor = ScanCursorStore(dataDirOverride: tmpData)
        let line = #"{"type":"assistant","requestId":"req_mock_a","timestamp":"2026-05-10T10:00:00.000Z","message":{"id":"msg_mock_a","model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":40,"ephemeral_1h_input_tokens":60}}}}"#
        _ = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [line])
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        let fmt = ISO8601DateFormatter()
        let events = await store.queryEvents(from: fmt.date(from: "2026-05-01T00:00:00Z")!,
                                             to: fmt.date(from: "2026-06-01T00:00:00Z")!)
        XCTAssertEqual(events.first?.cacheCreation5mTokens, 40)
        XCTAssertEqual(events.first?.cacheCreation1hTokens, 60)
    }

    /// 钉住"会话源文件被删除后，已统计到 store 的事件不会丢失"的保证。
    /// mergeEvents 后到覆盖同 key，rebuildAggregates 从落盘月明细重算——源 jsonl 删除不影响 store。
    func testDeletedSourceFileKeepsStoredEvents() async throws {
        let store = UsageEventStore(dataDirOverride: tmpData)
        let cursor = ScanCursorStore(dataDirOverride: tmpData)

        // 写入一个 session jsonl，包含一条事件
        let f = try writeSession("p1", "00000000-mock-0000-0000-000000000099", lines: [
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_del_test", req: "req_del_test"),
        ])

        // 第一次 collect → 事件写入 store
        let r1 = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        XCTAssertEqual(r1.newEventCount, 1)

        // 确认事件已存在
        let fmt = ISO8601DateFormatter()
        let eventsBefore = await store.queryEvents(
            from: fmt.date(from: "2026-05-01T00:00:00Z")!,
            to: fmt.date(from: "2026-06-01T00:00:00Z")!)
        XCTAssertEqual(eventsBefore.count, 1)
        XCTAssertEqual(eventsBefore.first?.msgId, "msg_del_test")

        // 删除源 jsonl
        try FileManager.default.removeItem(at: f)

        // 第二次 collect（源文件已不存在）
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()

        // 已统计事件应仍然存在
        let eventsAfter = await store.queryEvents(
            from: fmt.date(from: "2026-05-01T00:00:00Z")!,
            to: fmt.date(from: "2026-06-01T00:00:00Z")!)
        XCTAssertEqual(eventsAfter.count, 1, "删除源文件后，已收集的事件不应从 store 中消失")
        XCTAssertEqual(eventsAfter.first?.msgId, "msg_del_test")
    }

    func testCorruptedMonthFileTriggersCursorResetAndRecovery() async throws {
        let store = UsageEventStore(dataDirOverride: tmpData)
        let cursor = ScanCursorStore(dataDirOverride: tmpData)
        let f = try writeSession("p1", "00000000-mock-0000-0000-000000000001", lines: [
            assistantLine(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a"),
        ])

        // 第一次 collect：写入 1 个事件，游标推进到 line 1
        let r1 = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()
        XCTAssertEqual(r1.newEventCount, 1)

        // 损坏月明细文件，模拟 mergeEvents 返回非空 dirty set 的场景
        let monthFile = tmpData.appendingPathComponent("claude/2026-05.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: monthFile.path), "月明细文件应已存在")
        try "{ not json".data(using: .utf8)!.write(to: monthFile)

        // 追加第二行到同一个 jsonl 文件
        var content = try String(contentsOf: f, encoding: .utf8)
        content += assistantLine(ts: "2026-05-10T11:00:00.000Z", msg: "msg_mock_b", req: "req_mock_b") + "\n"
        try content.data(using: .utf8)!.write(to: f)

        // 第二次 collect：mergeEvents 会遇到损坏的月文件 → dirty 非空 → 清掉游标 → rebuildAllAggregates
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()

        // 第三次 collect：游标已被清除，从头全量重读，两个事件都应被重新写入
        _ = await ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]).collect()

        let fmt = ISO8601DateFormatter()
        let events = await store.queryEvents(
            from: fmt.date(from: "2026-05-01T00:00:00Z")!,
            to: fmt.date(from: "2026-06-01T00:00:00Z")!)
        let msgIds = Set(events.map { $0.msgId })
        XCTAssertTrue(msgIds.contains("msg_mock_a"), "msg_mock_a 应在恢复后可查询")
        XCTAssertTrue(msgIds.contains("msg_mock_b"), "msg_mock_b 应在恢复后可查询")
        XCTAssertEqual(events.count, 2)
    }
}
