import XCTest
@testable import ClaudeUsageBar

@MainActor
final class UsageStatsServiceTests: XCTestCase {
    private var tmpRoot: URL!, tmpData: URL!
    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stats-test-\(UUID().uuidString)", isDirectory: true)
        tmpRoot = base.appendingPathComponent("projects", isDirectory: true)
        tmpData = base.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpData, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: tmpRoot.deletingLastPathComponent()) }

    private func line(ts: String, msg: String, req: String) -> String {
        """
        {"type":"assistant","requestId":"\(req)","timestamp":"\(ts)","message":{"id":"\(msg)","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }
    private func writeSession(_ lines: [String]) throws {
        let dir = tmpRoot.appendingPathComponent("p1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: dir.appendingPathComponent("00000000-mock-0000-0000-000000000001.jsonl"))
    }
    private func makeService() -> UsageStatsService {
        let store = UsageEventStore(dataDirOverride: tmpData)
        let cursor = ScanCursorStore(dataDirOverride: tmpData)
        return UsageStatsService(store: store, collector: ClaudeUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmpRoot]))
    }
    private func nowISO() -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC")!
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: Date())
    }

    func testRefreshPublishesRolling30dAndDailyAndMonthly() async throws {
        try writeSession([line(ts: nowISO(), msg: "msg_mock_a", req: "req_mock_a")])
        let s = makeService()
        await s.refresh()
        XCTAssertNotNil(s.rolling30d)
        XCTAssertGreaterThan(s.rolling30d!.totalUSD, 0)   // 1M input opus ≈ $15
        XCTAssertFalse(s.dailySpend.isEmpty)
        XCTAssertFalse(s.monthlySpend.isEmpty)
        XCTAssertFalse(s.isInitializing)
    }
    func testRefreshWithNoJSONLKeepsRolling30dNil() async throws {
        let s = makeService()
        await s.refresh()
        XCTAssertNil(s.rolling30d)
        XCTAssertTrue(s.dailySpend.allSatisfy { $0.usd == 0 } || s.dailySpend.isEmpty)
        XCTAssertFalse(s.isInitializing)
    }
    func testIsInitializingTrueDuringFirstRefresh() async throws {
        let s = makeService()
        XCTAssertTrue(s.isInitializing)
        await s.refresh()
        XCTAssertFalse(s.isInitializing)
    }
    func testConcurrentRefreshDoesNotCrash() async throws {
        try writeSession([line(ts: "2026-05-10T10:00:00.000Z", msg: "msg_mock_a", req: "req_mock_a")])
        let s = makeService()
        async let a: Void = s.refresh()
        async let b: Void = s.refresh()
        _ = await (a, b)
        XCTAssertFalse(s.isInitializing)
    }

    func testCodexStatsEndToEnd() async throws {
        // Codex 端到端：摆一个 rollout JSONL → UsageStatsService(collector: CodexUsageCollector, pricing: OpenAI) → refresh → 估算费用 > 0。
        let codexRoot = tmpRoot.deletingLastPathComponent().appendingPathComponent("codex/sessions", isDirectory: true)
        let codexSessions = codexRoot.appendingPathComponent("2026/05/12", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        let rollout = codexSessions.appendingPathComponent("rollout-2026-05-12T07-00-00-019e1bee-0948-75c3-ae1a-bab380a1ffa9.jsonl")
        let nowStr = ISO8601DateFormatter().string(from: Date())
        let lines = [
            #"{"timestamp":"\#(nowStr)","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"timestamp":"\#(nowStr)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"output_tokens":20000,"reasoning_output_tokens":0,"total_tokens":120000},"total_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"output_tokens":20000,"reasoning_output_tokens":0,"total_tokens":120000}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: rollout)
        let store = UsageEventStore(dataDirOverride: tmpData, provider: .codex)
        let collector = CodexUsageCollector(store: store, cursor: ScanCursorStore(dataDirOverride: tmpData, provider: .codex),
                                            scanRootsOverride: [codexRoot])
        let svc = UsageStatsService(store: store, collector: collector, pricing: OpenAIModelPriceTable.shared)
        await svc.refresh()
        XCTAssertFalse(svc.dailySpend.isEmpty)
        XCTAssertGreaterThan(svc.rolling30d?.totalUSD ?? 0, 0)   // 100k input × $1.25/Mtok + 20k output × $10/Mtok
        XCTAssertFalse(svc.recentEvents.isEmpty)
    }
}
