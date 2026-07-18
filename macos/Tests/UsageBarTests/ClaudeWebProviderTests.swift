import XCTest
@testable import UsageBar

@MainActor
final class ClaudeWebProviderTests: XCTestCase {

    /// 注入内存 payload，绕开真实 `~/.config/`。
    private struct StubLoader: ClaudeWebLoading {
        let payload: ClaudeWebPayload?
        func load() -> ClaudeWebPayload? { payload }
    }

    private func makePayload(_ json: String) -> ClaudeWebPayload {
        ClaudeWebPayload.parse(Data(json.utf8))!
    }

    // 文件缺失（扩展没装/没同步过）→ 未配置、无 snapshot。
    func testMissingFileIsUnconfigured() {
        let p = ClaudeWebProvider(loader: StubLoader(payload: nil))
        XCTAssertFalse(p.isConfigured)
        XCTAssertNil(p.runtime.snapshot)
    }

    // logged_out → 未配置 + 引导文案。
    func testLoggedOutIsUnconfiguredWithHint() {
        let p = ClaudeWebProvider(loader: StubLoader(payload: makePayload(#"{"status":"logged_out","ts":1}"#)))
        XCTAssertFalse(p.isConfigured)
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertNil(p.runtime.snapshot)
    }

    // ok 且新鲜 → 已配置 + 有 snapshot（映射到窗口）。
    func testFreshOkIsConfiguredWithSnapshot() async {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let json = #"{"status":"ok","ts":\#(ms),"usage":{"five_hour":{"utilization":30}}}"#
        let p = ClaudeWebProvider(loader: StubLoader(payload: makePayload(json)))
        await p.refreshNow()
        XCTAssertTrue(p.isConfigured)
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct, 30)
        XCTAssertNil(p.runtime.lastError)
    }

    // ok 但过旧 → 陈旧错误，不误报为「新鲜已配置」。
    func testStaleOkReportsStale() {
        let oldMs = Int64((Date().timeIntervalSince1970 - ClaudeWebProvider.stalenessThreshold - 60) * 1000)
        let json = #"{"status":"ok","ts":\#(oldMs),"usage":{"five_hour":{"utilization":30}}}"#
        // 固定 now 保证判定确定性。
        let fixedNow = Date()
        let p = ClaudeWebProvider(loader: StubLoader(payload: makePayload(json)), now: { fixedNow })
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertTrue(p.runtime.lastError?.contains("stale") ?? false)
    }

    // ok 但 usage 无可映射窗口（Phase 0 前的空映射）→ 仍已配置 + 空快照（骨架态），不报错。
    func testOkWithUnmappableUsageIsConfiguredSkeleton() {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let json = #"{"status":"ok","ts":\#(ms),"usage":{"totally":"unknown"}}"#
        let p = ClaudeWebProvider(loader: StubLoader(payload: makePayload(json)))
        XCTAssertTrue(p.isConfigured)
        XCTAssertNil(p.runtime.lastError)
        XCTAssertNil(p.runtime.snapshot?.primaryWindow)
    }

    // 重入闸门：refreshNow 期间再次调用直接 return（不崩、不重复）。
    func testProviderIDIsClaudeWeb() {
        let p = ClaudeWebProvider(loader: StubLoader(payload: nil))
        XCTAssertEqual(p.id, .claudeWeb)
        XCTAssertEqual(p.id.displayName, "Claude Web")
    }
}
