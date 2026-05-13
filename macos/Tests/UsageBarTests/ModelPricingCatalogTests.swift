import XCTest
@testable import UsageBar

final class ModelPricingCatalogTests: XCTestCase {

    /// 写一个文件到唯一临时目录，返回 URL（测试结束自动清理）。
    private func tempJSON(_ contents: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("prices.json")
        try! contents.data(using: .utf8)!.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private static let sampleJSON = """
    {
      "sample_spec": {"input_cost_per_token": 9.9, "output_cost_per_token": 9.9},
      "gpt-5": {"input_cost_per_token": 0.00000125, "output_cost_per_token": 0.00001, "cache_read_input_token_cost": 0.000000125},
      "gpt-5-codex": {"input_cost_per_token": 0.00000125, "output_cost_per_token": 0.00001},
      "gpt-5-mini": {"input_cost_per_token": 0.00000025, "output_cost_per_token": 0.000002},
      "claude-opus-4-20250514": {"input_cost_per_token": 0.000015, "output_cost_per_token": 0.000075, "cache_read_input_token_cost": 0.0000015, "cache_creation_input_token_cost": 0.00001875},
      "openai/gpt-4o": {"input_cost_per_token": 0.0000025, "output_cost_per_token": 0.00001},
      "azure/gpt-4o": {"input_cost_per_token": 0.0000099, "output_cost_per_token": 0.0000099},
      "broken-model": {"input_cost_per_token": "not-a-number"}
    }
    """

    func testParsesPerTokenIntoPerMTokAndSkipsSampleSpec() {
        // tempJSON fixture 远小于 50KB → 必须用 minBytesOverride: 0 绕过下限
        let cat = ModelPricingCatalog(cacheURL: tempJSON(Self.sampleJSON), bundledURL: nil, minBytesOverride: 0)
        XCTAssertTrue(cat.isLoaded)
        let p = cat.unitPricing(rawModel: "gpt-5")
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.inputUSDPerMTok ?? 0, 1.25, accuracy: 1e-9)        // 0.00000125 × 1e6
        XCTAssertEqual(p?.outputUSDPerMTok ?? 0, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p?.cacheReadUSDPerMTok ?? 0, 0.125, accuracy: 1e-9)
        XCTAssertEqual(p?.cacheWriteUSDPerMTok ?? -1, 0.0, accuracy: 1e-12)  // 缺 cache_creation → 0
        XCTAssertNil(cat.unitPricing(rawModel: "sample_spec"))               // 非模型键不进表
        XCTAssertNil(cat.unitPricing(rawModel: "broken-model"))             // 字段非数 → 跳过该 key
    }

    func testCachePreferredOverBundled() {
        let cache = tempJSON(#"{"gpt-5":{"input_cost_per_token":0.000002,"output_cost_per_token":0.000002}}"#)
        let bundled = tempJSON(Self.sampleJSON)
        let cat = ModelPricingCatalog(cacheURL: cache, bundledURL: bundled, minBytesOverride: 0)
        XCTAssertEqual(cat.unitPricing(rawModel: "gpt-5")?.inputUSDPerMTok ?? 0, 2.0, accuracy: 1e-9) // 缓存值，不是 1.25
    }

    func testCorruptCacheFallsBackToBundled() {
        let cat = ModelPricingCatalog(cacheURL: tempJSON("{ this is not json"), bundledURL: tempJSON(Self.sampleJSON), minBytesOverride: 0)
        XCTAssertTrue(cat.isLoaded)
        XCTAssertNotNil(cat.unitPricing(rawModel: "gpt-5"))
    }

    func testTooSmallFileRejectedByMinBytes() {
        // 不绕过下限：sampleJSON < 50KB → loadParsed 返回 nil → 没有可用源 → 空表
        let cat = ModelPricingCatalog(cacheURL: tempJSON(Self.sampleJSON), bundledURL: nil)
        XCTAssertFalse(cat.isLoaded)
        XCTAssertNil(cat.unitPricing(rawModel: "gpt-5"))
    }

    func testBothSourcesMissingGivesEmptyTable() {
        let cat = ModelPricingCatalog(cacheURL: nil, bundledURL: nil)
        XCTAssertFalse(cat.isLoaded)
        XCTAssertNil(cat.unitPricing(rawModel: "gpt-5"))
    }

    func testPrefixMatchPrefersNonForeignRoute() {
        // sampleJSON 里同时有 "openai/gpt-4o"(2.5) 和 "azure/gpt-4o"(9.9)；查 "gpt-4o"：候选链步骤 5 生成
        // "openai/gpt-4o" → 精确命中(2.5)，不会落到前缀匹配里的 azure 那条。
        let cat = ModelPricingCatalog(cacheURL: tempJSON(Self.sampleJSON), bundledURL: nil, minBytesOverride: 0)
        XCTAssertEqual(cat.unitPricing(rawModel: "gpt-4o")?.inputUSDPerMTok ?? 0, 2.5, accuracy: 1e-9)
    }

    func testBundledSnapshotIsLoadable() {
        let url = ModelPricingCatalog.defaultBundledURL
        XCTAssertNotNil(url, "bundled litellm_model_prices.json must be in the resource bundle")
        let cat = ModelPricingCatalog(cacheURL: nil, bundledURL: url)
        XCTAssertTrue(cat.isLoaded)
        XCTAssertNotNil(cat.unitPricing(rawModel: "gpt-4o"))
        XCTAssertNotNil(cat.unitPricing(rawModel: "claude-opus-4-7"))
    }

    // MARK: - refreshIfStale

    private static let validDownloadJSON = #"{"gpt-5":{"input_cost_per_token":0.000003,"output_cost_per_token":0.000003}}"#

    private func dirURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 轮询等待 `condition` 为真（最多 `timeout` 秒）；用于等 `refreshIfStale` 的后台 detach task 落盘完成，
    /// 比固定 `sleep`/`asyncAfter` 抗 CI 慢机器 flaky。
    private func waitUntil(_ timeout: TimeInterval = 3.0, file: StaticString = #file, line: UInt = #line,
                          _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "waitUntil timed out", file: file, line: line)
    }

    func testRefreshSkippedWhenFresh() {
        let dir = dirURL()
        let cacheURL = dir.appendingPathComponent("p.json")
        let metaURL = dir.appendingPathComponent("p.meta.json")
        try! Self.sampleJSON.data(using: .utf8)!.write(to: cacheURL)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try! ("{\"fetched_at\":\"" + ISO8601DateFormatter().string(from: t0) + "\"}").data(using: .utf8)!.write(to: metaURL)
        var downloadCalled = false
        let cat = ModelPricingCatalog(cacheURL: cacheURL, bundledURL: nil, metaURL: metaURL,
                                      now: { t0 }, downloader: { cb in downloadCalled = true; cb(nil) },
                                      minBytesOverride: 0)
        cat.refreshIfStale(now: t0.addingTimeInterval(2 * 3600))   // 2h 后，未到 3h
        XCTAssertFalse(downloadCalled)
    }

    func testRefreshTriggersWhenStaleAndWritesCacheAndMeta() {
        let dir = dirURL()
        let cacheURL = dir.appendingPathComponent("p.json")
        let metaURL = dir.appendingPathComponent("p.meta.json")
        try! Self.sampleJSON.data(using: .utf8)!.write(to: cacheURL)   // 旧内容：gpt-5 input 1.25
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let exp = expectation(description: "download invoked")
        let cat = ModelPricingCatalog(cacheURL: cacheURL, bundledURL: nil, metaURL: metaURL,
                                      now: { t },
                                      downloader: { cb in cb(Self.validDownloadJSON.data(using: .utf8)); exp.fulfill() },
                                      minBytesOverride: 0)
        cat.refreshIfStale(now: t)        // 无 meta → 视为从未抓取 → 触发
        wait(for: [exp], timeout: 2.0)
        waitUntil { !cat.isRefreshInFlightForTesting }      // 等后台 detach task 落盘 + 重建表完成
        XCTAssertEqual(cat.unitPricing(rawModel: "gpt-5")?.inputUSDPerMTok ?? 0, 3.0, accuracy: 1e-9) // 新值
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))) as? [String: Any]
        XCTAssertEqual(meta?["fetched_at"] as? String, ISO8601DateFormatter().string(from: t))
    }

    func testRefreshWithBadDownloadKeepsOldCacheAndNoMeta() {
        let dir = dirURL()
        let cacheURL = dir.appendingPathComponent("p.json")
        let metaURL = dir.appendingPathComponent("p.meta.json")
        try! Self.sampleJSON.data(using: .utf8)!.write(to: cacheURL)
        let exp = expectation(description: "download invoked")
        let cat = ModelPricingCatalog(cacheURL: cacheURL, bundledURL: nil, metaURL: metaURL,
                                      downloader: { cb in cb("not json at all".data(using: .utf8)); exp.fulfill() },
                                      minBytesOverride: 0)
        cat.refreshIfStale(now: Date(timeIntervalSince1970: 1_800_000_000))
        wait(for: [exp], timeout: 2.0)
        waitUntil { !cat.isRefreshInFlightForTesting }      // 等后台 detach task 跑完（坏数据 → 提前 return，但 defer 仍复位 flag）
        XCTAssertEqual(cat.unitPricing(rawModel: "gpt-5")?.inputUSDPerMTok ?? 0, 1.25, accuracy: 1e-9) // 旧值不变
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path))                            // 没写 meta
    }
}
