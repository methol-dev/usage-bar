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

    // MARK: 长上下文阶梯价

    private func tierPricing(threshold: Int) -> ModelUnitPricing {
        ModelUnitPricing(inputUSDPerMTok: 1, outputUSDPerMTok: 10, cacheReadUSDPerMTok: 0.1, cacheWriteUSDPerMTok: 1.25,
                         cacheWrite1hUSDPerMTok: 2,
                         longContext: LongContextTier(thresholdTokens: threshold, rates: .init(
                            inputUSDPerMTok: 2, outputUSDPerMTok: 15, cacheReadUSDPerMTok: 0.2, cacheWriteUSDPerMTok: 2.5,
                            cacheWrite1hUSDPerMTok: 4)))
    }
    func testLongContextRequestsPricedWholeAtTierRate() {
        var s = TokenSums()
        s.add(ev("2026-05-11T12:00:00.000Z", input: 1_000, output: 1_000_000, cr: 199_000, msg: "small"))   // prompt 200_000，不超
        s.add(ev("2026-05-11T12:00:01.000Z", input: 1_000, output: 1_000_000, cr: 299_000, msg: "big"))     // prompt 300_000
        XCTAssertEqual(s.longContext["200000"]?.calls, 1)
        XCTAssertEqual(s.longContext["272000"]?.calls, 1)
        let usd = tierPricing(threshold: 272_000).cost(s)
        let small: Double = (1_000.0 * 1 + 1_000_000.0 * 10 + 199_000.0 * 0.1) / 1e6   // 基础价
        let big: Double = (1_000.0 * 2 + 1_000_000.0 * 15 + 299_000.0 * 0.2) / 1e6     // 整单长档价
        let expected = small + big
        XCTAssertEqual(usd, expected, accuracy: 1e-9)
    }
    func testLongContextThresholdNotTrackedFallsBackToBase() {
        var s = TokenSums()
        s.add(ev("2026-05-11T12:00:00.000Z", input: 500_000, output: 0, msg: "x"))
        XCTAssertEqual(tierPricing(threshold: 128_000).cost(s), 0.5, accuracy: 1e-9)
    }
    func testRolling30dSummaryKeepsLongContextSubBuckets() {
        let now = iso("2026-05-12T12:00:00.000Z")
        var s = TokenSums(); s.add(ev("2026-05-11T12:00:00.000Z", input: 300_000, output: 0, msg: "x"))
        let merged = UsageAggregator.rolling30dSummary(dayAggregates: ["2026-05-11": ["m": s]], now: now)
        XCTAssertEqual(merged.perModel.first?.calls, 1)
        var acc = TokenSums(); acc.merge(s); acc.merge(s)
        XCTAssertEqual(acc.longContext["272000"]?.calls, 2)
        XCTAssertEqual(acc.longContext["272000"]?.inputTokens, 600_000)
    }
    func testTokenSumsCodableRoundTripWithLongContext() throws {
        var s = TokenSums(); s.add(ev("2026-05-11T12:00:00.000Z", input: 300_000, output: 7, msg: "x"))
        let back = try JSONDecoder().decode(TokenSums.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        // 旧 agg（无 longContext 字段）可解码
        let legacy = try JSONDecoder().decode(TokenSums.self, from: Data(#"{"calls":1,"inputTokens":5,"outputTokens":0,"cacheReadInputTokens":0,"cacheCreationInputTokens":0}"#.utf8))
        XCTAssertTrue(legacy.longContext.isEmpty)
    }
}
