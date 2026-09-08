import XCTest
@testable import UsageBar

final class UsageAggregatorTests: XCTestCase {
    private func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)!
    }
    private func ev(_ ts: String, model: String = "claude-opus-4-7", input: Int = 1, output: Int = 1,
                    cr: Int = 0, cc: Int = 0, msg: String = UUID().uuidString) -> StoredUsageEvent {
        StoredUsageEvent(ts: iso(ts), msgId: "msg_mock_\(msg)", reqId: "req_mock_\(msg)",
                         sessionId: "00000000-mock-0000-0000-000000000000", model: model,
                         inputTokens: input, outputTokens: output, cacheReadInputTokens: cr, cacheCreation5mTokens: cc)
    }

    func testFoldByDayKeysUseLocalTimeZone() {
        // 12:00Z 和 12:30Z 在所有现实时区（UTC-12…UTC+14）均落在同一本地日历日
        let events = [ev("2026-05-11T12:00:00.000Z", msg: "a"), ev("2026-05-11T12:30:00.000Z", msg: "b")]
        let byDay = UsageAggregator.foldByDay(events: events)
        XCTAssertEqual(byDay.keys.count, 1)
        XCTAssertEqual(byDay.values.first?["claude-opus-4-7"]?.calls, 2)
    }
    func testFoldByMonthAndYearUseUTC() {
        let events = [ev("2026-04-30T23:30:00.000Z", msg: "x"), ev("2026-05-01T00:30:00.000Z", msg: "y")]
        XCTAssertEqual(Set(UsageAggregator.foldByMonth(events: events).keys), ["2026-04", "2026-05"])
        XCTAssertEqual(Set(UsageAggregator.foldByYear(events: events).keys), ["2026"])
    }
    func testUsdForBucketSumsCostsFromCatalog() {
        var sums = TokenSums()
        sums.calls = 1; sums.inputTokens = 1_000_000; sums.outputTokens = 1_000_000
        sums.cacheReadInputTokens = 1_000_000; sums.cacheCreation5mTokens = 1_000_000
        let bucket: [String: TokenSums] = ["claude-opus-4-7": sums]
        let r = UsageAggregator.usdForBucket(bucket)
        XCTAssertEqual(r.unknownModelCalls, 0)               // bundle 内快照能查到 claude-opus-4-7
        XCTAssertGreaterThan(r.usd, 0)
        // 1M of each token type → usd 应等于该模型四项 per-Mtok 单价之和（验证 usdForBucket → catalog 的 plumbing，不硬编码金额）
        guard let p = ClaudeModelPriceTable.shared.lookup("claude-opus-4-7") else { return XCTFail("claude-opus-4-7 not in bundled snapshot") }
        XCTAssertEqual(r.usd, p.inputUSDPerMTok + p.outputUSDPerMTok + p.cacheReadUSDPerMTok + p.cacheWriteUSDPerMTok, accuracy: 1e-6)
    }
    func testUsdForBucketUses1hCacheWriteRate() {
        var sums = TokenSums()
        sums.calls = 1; sums.cacheCreation1hTokens = 1_000_000
        let r = UsageAggregator.usdForBucket(["claude-opus-4-7": sums])
        guard let p = ClaudeModelPriceTable.shared.lookup("claude-opus-4-7") else { return XCTFail("claude-opus-4-7 not in bundled snapshot") }
        XCTAssertGreaterThan(p.cacheWrite1hUSDPerMTok, p.cacheWriteUSDPerMTok)
        XCTAssertEqual(r.usd, p.cacheWrite1hUSDPerMTok, accuracy: 1e-6)
        XCTAssertNotEqual(r.usd, p.cacheWriteUSDPerMTok, accuracy: 1e-6)
    }
    func testUnknownModelContributesZeroUSDAndCountsCalls() {
        var sums = TokenSums(); sums.calls = 3; sums.inputTokens = 1_000_000
        let bucket: [String: TokenSums] = ["fake-model-99": sums]
        let r = UsageAggregator.usdForBucket(bucket)
        XCTAssertEqual(r.usd, 0, accuracy: 1e-9)
        XCTAssertEqual(r.unknownModelCalls, 3)
    }
    func testRolling30dSummaryWindowBoundary() {
        let now = iso("2026-05-12T12:00:00.000Z")
        let dayAgg: [String: [String: TokenSums]] = [
            "2026-04-20": ["claude-opus-4-7": { var s = TokenSums(); s.calls = 1; s.inputTokens = 1_000_000; return s }()],
            "2026-04-01": ["claude-opus-4-7": { var s = TokenSums(); s.calls = 1; s.inputTokens = 1_000_000; return s }()],
        ]
        let summary = UsageAggregator.rolling30dSummary(dayAggregates: dayAgg, now: now)
        XCTAssertEqual(summary.windowDays, 30)
        XCTAssertGreaterThan(summary.totalUSD, 0)
        XCTAssertEqual(summary.perModel.reduce(0) { $0 + $1.calls }, 1)
    }
}
