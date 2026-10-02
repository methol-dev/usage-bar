import XCTest
@testable import UsageBar

final class UsageEventStoreTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usagebar-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)!
    }
    private func event(ts: String, msg: String = "msg_mock_1", req: String = "req_mock_1",
                       model: String = "claude-opus-4-7", input: Int = 100, output: Int = 50,
                       cache5m: Int = 0, cache1h: Int = 0) -> StoredUsageEvent {
        StoredUsageEvent(ts: iso(ts), msgId: msg, reqId: req, sessionId: "00000000-mock-0000-0000-000000000000",
                         model: model, inputTokens: input, outputTokens: output,
                         cacheReadInputTokens: 0, cacheCreation5mTokens: cache5m, cacheCreation1hTokens: cache1h)
    }

    func testMergeEventsDeduplicatesByMsgIdAndReqId() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        let dup = Array(repeating: event(ts: "2026-05-11T10:00:00.000Z"), count: 5)
        _ = await store.mergeEvents(dup)
        let got = await store.queryEvents(from: iso("2026-05-01T00:00:00.000Z"), to: iso("2026-06-01T00:00:00.000Z"))
        XCTAssertEqual(got.count, 1)
    }

    func testMergeEventsSplitsAcrossUTCMonths() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        _ = await store.mergeEvents([
            event(ts: "2026-04-30T23:00:00.000Z", msg: "msg_mock_apr", req: "req_mock_apr"),
            event(ts: "2026-05-01T01:00:00.000Z", msg: "msg_mock_may", req: "req_mock_may"),
        ])
        let aprPath = tmpDir.appendingPathComponent("claude/2026-04.json")
        let mayPath = tmpDir.appendingPathComponent("claude/2026-05.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aprPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mayPath.path))
    }

    func testMonthFilePermissionsAre0600() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        _ = await store.mergeEvents([event(ts: "2026-05-11T10:00:00.000Z")])
        let path = tmpDir.appendingPathComponent("claude/2026-05.json").path
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(perms.int16Value, 0o600)
    }

    func testMonthFileCodableRoundTripPreservesEvents() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        let e1 = event(ts: "2026-05-11T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a")
        let e2 = event(ts: "2026-05-12T11:00:00.000Z", msg: "msg_mock_b", req: "req_mock_b", model: "claude-haiku-4-5")
        _ = await store.mergeEvents([e1, e2])
        // 二次 merge 一条已存在 + 一条新 → 仍只 3 条
        let e3 = event(ts: "2026-05-13T12:00:00.000Z", msg: "msg_mock_c", req: "req_mock_c")
        _ = await store.mergeEvents([e1, e3])
        let got = await store.queryEvents(from: iso("2026-05-01T00:00:00.000Z"), to: iso("2026-06-01T00:00:00.000Z"))
        XCTAssertEqual(Set(got.map(\.msgId)), ["msg_mock_a", "msg_mock_b", "msg_mock_c"])
    }

    func testRebuildAggregatesFromDetailMatchesReadback() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        _ = await store.mergeEvents([
            event(ts: "2026-05-11T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a"),
            event(ts: "2026-05-12T10:00:00.000Z", msg: "msg_mock_b", req: "req_mock_b", model: "claude-haiku-4-5"),
        ])
        await store.rebuildAllAggregates()
        let day = await store.readDayAggregates()
        XCTAssertGreaterThanOrEqual(day.keys.count, 1)
        let month = await store.readMonthAggregates()
        XCTAssertEqual(month["2026-05"]?.values.reduce(0) { $0 + $1.calls }, 2)
        let year = await store.readYearAggregates()
        XCTAssertEqual(year["2026"]?.values.reduce(0) { $0 + $1.calls }, 2)
        let aggPath = tmpDir.appendingPathComponent("claude/agg-day.json").path
        let perms = try FileManager.default.attributesOfItem(atPath: aggPath)[.posixPermissions] as! NSNumber
        XCTAssertEqual(perms.int16Value, 0o600)
    }
    func testRebuildAggregatesForDayKeysOnlyTouchesThoseBuckets() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        _ = await store.mergeEvents([event(ts: "2026-05-11T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a")])
        await store.rebuildAllAggregates()
        _ = await store.mergeEvents([event(ts: "2026-05-12T10:00:00.000Z", msg: "msg_mock_b", req: "req_mock_b")])
        await store.rebuildAggregates(forDayKeys: [UsageAggregator.localDayKey(iso("2026-05-12T10:00:00.000Z"))])
        let day = await store.readDayAggregates()
        let totalCalls = day.values.flatMap { $0.values }.reduce(0) { $0 + $1.calls }
        XCTAssertEqual(totalCalls, 2)
    }
    func testMergeEventsLaterSnapshotReplacesEarlier() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        _ = await store.mergeEvents([event(ts: "2026-05-11T10:00:00.000Z", output: 4)])
        _ = await store.mergeEvents([event(ts: "2026-05-11T10:00:01.000Z", output: 644)])
        let got = await store.queryEvents(from: iso("2026-05-01T00:00:00.000Z"), to: iso("2026-06-01T00:00:00.000Z"))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.outputTokens, 644)
    }

    func testMergeEventsEarlierSnapshotDoesNotReplaceLater() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        _ = await store.mergeEvents([event(ts: "2026-05-11T10:00:01.000Z", output: 644)])
        _ = await store.mergeEvents([event(ts: "2026-05-11T10:00:00.000Z", output: 4)])
        let got = await store.queryEvents(from: iso("2026-05-01T00:00:00.000Z"), to: iso("2026-06-01T00:00:00.000Z"))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.outputTokens, 644)
    }

    func testMergeEventsSameTimestampKeepsIncoming() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        _ = await store.mergeEvents([event(ts: "2026-05-11T10:00:00.000Z", output: 4, cache5m: 10)])
        _ = await store.mergeEvents([event(ts: "2026-05-11T10:00:00.000Z", output: 4, cache5m: 10, cache1h: 99)])
        let got = await store.queryEvents(from: iso("2026-05-01T00:00:00.000Z"), to: iso("2026-06-01T00:00:00.000Z"))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.cacheCreation1hTokens, 99)
    }

    func testDecodesLegacyMonthFileWithoutCacheSplit() throws {
        let json = """
        {"schemaVersion":1,"provider":"claude","month":"2026-05","lastUpdated":"2026-05-11T10:00:00Z",
         "events":[{"ts":"2026-05-11T10:00:00Z","msgId":"msg_mock_1","reqId":"req_mock_1",
         "sessionId":"00000000-mock-0000-0000-000000000000","model":"claude-opus-4-7",
         "inputTokens":1,"outputTokens":2,"cacheReadInputTokens":3,"cacheCreationInputTokens":40}]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(MonthDetailFile.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(file.events.count, 1)
        XCTAssertEqual(file.events[0].cacheCreation5mTokens, 40)
        XCTAssertEqual(file.events[0].cacheCreation1hTokens, 0)
        XCTAssertEqual(file.events[0].cacheCreationInputTokens, 40)
    }

    func testCorruptedMonthFileTreatedAsEmpty() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        let dir = tmpDir.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ not valid json".data(using: .utf8)!.write(to: dir.appendingPathComponent("2026-05.json"))
        let dirty = await store.mergeEvents([event(ts: "2026-05-11T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a")])
        XCTAssertTrue(dirty.contains("2026-05"))
        let got = await store.queryEvents(from: iso("2026-05-01T00:00:00.000Z"), to: iso("2026-06-01T00:00:00.000Z"))
        XCTAssertEqual(got.count, 1)
    }

    // MARK: 一次性存量修复

    private func monthFiles() -> [String] {
        let dir = tmpDir.appendingPathComponent("claude")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func testRunMigrationOnceRemovesBacksUpAndRunsOnlyOnce() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        await store.mergeEvents([event(ts: "2026-04-30T23:00:00.000Z", msg: "a", req: "a"),
                                 event(ts: "2026-05-01T01:00:00.000Z", msg: "b", req: "b", model: "<synthetic>"),
                                 event(ts: "2026-05-01T02:00:00.000Z", msg: "c", req: "c")])
        await store.rebuildAllAggregates()
        var calls = 0
        let changed = await store.runMigrationOnce("drop-x") { evs in calls += 1; return evs.filter { $0.model != "<synthetic>" } }
        XCTAssertTrue(changed)
        let left = await store.queryEvents(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(left.map(\.msgId), ["a", "c"])
        // 只有被改动的 05 月有备份；agg 已重建
        XCTAssertTrue(monthFiles().contains("2026-05.pre-drop-x.bak.json"))
        XCTAssertFalse(monthFiles().contains("2026-04.pre-drop-x.bak.json"))
        let monthAgg = await store.readMonthAggregates()
        XCTAssertEqual(monthAgg["2026-05"]?.values.reduce(0) { $0 + $1.calls }, 1)
        // 备份文件不被当成月文件
        let keys = await store.allMonthKeys()
        XCTAssertEqual(keys, ["2026-04", "2026-05"])
        // 第二次不再执行（新 store 实例同样读到标记）
        let again = await UsageEventStore(dataDirOverride: tmpDir).runMigrationOnce("drop-x") { evs in calls += 1; return [] }
        XCTAssertFalse(again)
        XCTAssertEqual(calls, 1)
        let final = await store.queryEvents(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(final.count, 2)
    }

    func testRunMigrationSkipsWhenMonthFileCorrupted() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        await store.mergeEvents([event(ts: "2026-05-01T01:00:00.000Z")])
        try Data("{bad".utf8).write(to: tmpDir.appendingPathComponent("claude/2026-04.json"))
        let changed = await store.runMigrationOnce("drop-all") { _ in [] }
        XCTAssertFalse(changed)
        // 没落标记 → 修好后会重试
        try FileManager.default.removeItem(at: tmpDir.appendingPathComponent("claude/2026-04.json"))
        let retried = await store.runMigrationOnce("drop-all") { _ in [] }
        XCTAssertTrue(retried)
    }

    func testIncrementalRebuildWithStaleAggFallsBackToFullRebuild() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir)
        await store.mergeEvents([event(ts: "2026-04-10T12:00:00.000Z", msg: "old", req: "old"),
                                 event(ts: "2026-05-12T12:00:00.000Z", msg: "new", req: "new")])
        await store.rebuildAllAggregates()
        // 模拟升级前的旧版本 agg 文件
        for kind in ["day", "month", "year"] {
            let url = tmpDir.appendingPathComponent("claude/agg-\(kind).json")
            var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            obj["schemaVersion"] = 2
            try JSONSerialization.data(withJSONObject: obj).write(to: url)
        }
        await store.rebuildAggregates(forDayKeys: [UsageAggregator.localDayKey(iso("2026-05-12T12:00:00.000Z"))])
        let day = await store.readDayAggregates()
        XCTAssertNotNil(day[UsageAggregator.localDayKey(iso("2026-04-10T12:00:00.000Z"))], "旧日期的历史不能因增量重建丢失")
    }

    func testCodexStoreAutoRebuildUsesOpenAINormalize() async throws {
        let store = UsageEventStore(dataDirOverride: tmpDir, provider: .codex)
        await store.mergeEvents([event(ts: "2026-05-12T12:00:00.000Z", model: "gpt-5-2025-08-07")])
        let month = await store.readMonthAggregates()   // agg 不存在 → 自动重建
        XCTAssertEqual(month["2026-05"]?.keys.first, "gpt-5")
    }
}
