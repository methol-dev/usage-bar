import XCTest
@testable import UsageBar

@MainActor
final class CodexWebProviderTests: XCTestCase {

    /// 注入内存 payload，绕开真实 `~/.config/`。
    private struct StubLoader: CodexWebLoading {
        let payload: CodexWebPayload?
        func load() -> CodexWebPayload? { payload }
    }

    private func makePayload(_ json: String) -> CodexWebPayload {
        CodexWebPayload.parse(Data(json.utf8))!
    }

    // 文件缺失（扩展没装/没同步过）→ 未配置、无 snapshot。
    func testMissingFileIsUnconfigured() {
        let p = CodexWebProvider(loader: StubLoader(payload: nil))
        XCTAssertFalse(p.isConfigured)
        XCTAssertNil(p.runtime.snapshot)
    }

    // logged_out → 未配置 + 引导文案。
    func testLoggedOutIsUnconfiguredWithHint() {
        let p = CodexWebProvider(loader: StubLoader(payload: makePayload(#"{"status":"logged_out","ts":1}"#)))
        XCTAssertFalse(p.isConfigured)
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertNil(p.runtime.snapshot)
    }

    // ok 且新鲜 → 已配置 + 有 snapshot（wham/usage 与 CLI 同 schema，5h 窗口 → primary）。
    func testFreshOkIsConfiguredWithSnapshot() async {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let reset = Date().timeIntervalSince1970 + 3600
        let json = #"{"status":"ok","ts":\#(ms),"usage":{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":30,"reset_at":\#(reset),"limit_window_seconds":18000}}}}"#
        let p = CodexWebProvider(loader: StubLoader(payload: makePayload(json)))
        await p.refreshNow()
        XCTAssertTrue(p.isConfigured)
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct, 30)
        XCTAssertEqual(p.runtime.snapshot?.planLabel, "Pro")
        XCTAssertNil(p.runtime.lastError)
    }

    // ok 但过旧 → 陈旧错误，不误报为「新鲜已配置」。
    func testStaleOkReportsStale() {
        let oldMs = Int64((Date().timeIntervalSince1970 - CodexWebProvider.stalenessThreshold - 60) * 1000)
        let json = #"{"status":"ok","ts":\#(oldMs),"usage":{"plan_type":"pro"}}"#
        let fixedNow = Date()
        let p = CodexWebProvider(loader: StubLoader(payload: makePayload(json)), now: { fixedNow })
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertTrue(p.runtime.lastError?.contains("stale") ?? false)
    }

    // ok 但 usage 无可映射窗口 → 仍已配置 + 空快照（骨架态），不报错。
    func testOkWithUnmappableUsageIsConfiguredSkeleton() {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let json = #"{"status":"ok","ts":\#(ms),"usage":{"totally":"unknown"}}"#
        let p = CodexWebProvider(loader: StubLoader(payload: makePayload(json)))
        XCTAssertTrue(p.isConfigured)
        XCTAssertNil(p.runtime.lastError)
        XCTAssertNil(p.runtime.snapshot?.primaryWindow)
    }

    func testProviderIDIsCodexWeb() {
        let p = CodexWebProvider(loader: StubLoader(payload: nil))
        XCTAssertEqual(p.id, .codexWeb)
        XCTAssertEqual(p.id.displayName, "Codex Web")
    }

    // 畸形 JSON（非可信文件）→ parse 返回 nil，不崩。
    func testMalformedJSONParsesToNil() {
        XCTAssertNil(CodexWebPayload.parse(Data("{ not json".utf8)))
        XCTAssertNil(CodexWebPayload.parse(Data("[1,2,3]".utf8)))
    }

    // "prolite" plan_type → Pro Lite（ADR 0012 补齐）。
    func testProLitePlanMaps() {
        XCTAssertEqual(CodexPlan(rawValue: "prolite").displayName, "Pro Lite")
        XCTAssertEqual(CodexPlan(rawValue: "pro_lite"), .proLite)
    }
}
