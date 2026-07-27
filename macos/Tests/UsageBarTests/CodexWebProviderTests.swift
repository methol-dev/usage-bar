import XCTest
@testable import UsageBar

@MainActor
final class CodexWebProviderTests: XCTestCase {

    /// 注入内存 payload，绕开真实 `~/.config/`。
    private struct StubLoader: CodexWebLoading {
        let payload: CodexWebPayload?
        func load() -> CodexWebPayload? { payload }
    }

    /// 可在两次 `refreshNow()` 之间改内容的 loader —— 模拟扩展重写交接文件。
    private final class MutableStubLoader: CodexWebLoading {
        var payload: CodexWebPayload?
        init(payload: CodexWebPayload?) { self.payload = payload }
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
        XCTAssertTrue(p.runtime.lastError?.contains("sign in") ?? false)
        XCTAssertNil(p.runtime.snapshot)
    }

    // no_session（存量旧扩展 / 版本错配时才会出现）→ 文案讲「没开标签页」，不是笼统的「去登录」。
    func testNoSessionSaysNoTabOpen() {
        let p = CodexWebProvider(loader: StubLoader(payload: makePayload(#"{"status":"no_session","ts":1}"#)))
        XCTAssertTrue(p.runtime.lastError?.contains("No chatgpt.com tab open") ?? false)
    }

    // 关键回归：旧版扩展仍会写 no_session。它是「暂时取不到数」而非凭证失效 ——
    // 绝不能清掉上一次的好数据，否则 app 更新、扩展没更新时那条数据丢失的路依然通着。
    func testNoSessionKeepsPreviouslyLoadedData() async {
        let fresh = Int64(Date().timeIntervalSince1970 * 1000)
        let reset = Date().timeIntervalSince1970 + 3600
        let okJSON = #"{"status":"ok","ts":\#(fresh),"usage":{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":42,"reset_at":\#(reset),"limit_window_seconds":18000}}}}"#
        var payload = makePayload(okJSON)
        let loader = MutableStubLoader(payload: payload)
        let p = CodexWebProvider(loader: loader)
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct, 42)

        payload = makePayload(#"{"status":"no_session","ts":\#(fresh)}"#)   // 旧扩展覆盖了文件
        loader.payload = payload
        await p.refreshNow()

        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct, 42, "没开标签页不该抹掉已有用量")
        XCTAssertTrue(p.isConfigured, "暂时取不到数 ≠ 未配置")
        XCTAssertTrue(p.runtime.lastError?.contains("No chatgpt.com tab open") ?? false)
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

    // ok 但过旧 → 挂陈旧错误，但**保留**最后已知数据（冷启动也是这条路径：旧写法此时 runtime 全空，
    // 用户重开 app 只剩「未登录」骨架）。门面判命中要求 lastError == nil，故仍会回退 CLI。
    func testStaleOkKeepsLastKnownDataAndReportsStale() {
        let oldMs = Int64((Date().timeIntervalSince1970 - CodexWebProvider.stalenessThreshold - 60) * 1000)
        let reset = Date().timeIntervalSince1970 + 3600
        let json = #"{"status":"ok","ts":\#(oldMs),"usage":{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":42,"reset_at":\#(reset),"limit_window_seconds":18000}}}}"#
        let fixedNow = Date()
        let p = CodexWebProvider(loader: StubLoader(payload: makePayload(json)), now: { fixedNow })
        XCTAssertTrue(p.runtime.lastError?.contains("stale") ?? false)
        XCTAssertTrue(p.isConfigured, "陈旧≠未配置：扩展确实同步过，只是数据旧了")
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct, 42, "最后已知用量不该被抹掉")
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
