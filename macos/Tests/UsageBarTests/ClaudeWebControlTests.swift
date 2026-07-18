import XCTest
@testable import UsageBar

/// ADR 0011 反向控制通道:控制模型编解码、host 分派/回传 response、coordinator 控制配置计算。
final class ClaudeWebControlTests: XCTestCase {

    // MARK: - ClaudeWebControl 编解码

    func testControlCodableRoundTrip() throws {
        let control = ClaudeWebControl(paused: true, intervalSeconds: 300, syncNonce: 7, ts: 1_700_000_000)
        let data = try JSONEncoder().encode(control)
        let back = try JSONDecoder().decode(ClaudeWebControl.self, from: data)
        XCTAssertEqual(control, back)
    }

    // MARK: - host 分派

    func testIsPollMessage() {
        XCTAssertTrue(ClaudeWebNativeHost.isPollMessage(["type": "poll"]))
        XCTAssertFalse(ClaudeWebNativeHost.isPollMessage(["status": "ok"]))
        XCTAssertFalse(ClaudeWebNativeHost.isPollMessage(["type": "sync"]))
        XCTAssertFalse(ClaudeWebNativeHost.isPollMessage([:]))
    }

    // MARK: - host response 始终是合法 JSON

    func testResponseBodyWithNullControlIsValidJSON() throws {
        let body = ClaudeWebNativeHost.responseBody(ok: true, controlBytes: nil)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["ok"] as? Bool, true)
        XCTAssertTrue(obj["control"] is NSNull)
    }

    func testResponseBodyEmbedsControlJSON() throws {
        let controlBytes = Data(#"{"paused":true,"syncNonce":3}"#.utf8)
        let body = ClaudeWebNativeHost.responseBody(ok: true, controlBytes: controlBytes)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["ok"] as? Bool, true)
        let control = try XCTUnwrap(obj["control"] as? [String: Any])
        XCTAssertEqual(control["paused"] as? Bool, true)
        XCTAssertEqual(control["syncNonce"] as? Int, 3)
    }

    func testResponseBodyOkFalse() throws {
        let body = ClaudeWebNativeHost.responseBody(ok: false, controlBytes: nil)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["ok"] as? Bool, false)
    }

    // MARK: - coordinator 控制配置计算

    @MainActor
    private func makeCoordinator(_ d: UserDefaults) -> ProviderCoordinator {
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        return ProviderCoordinator(claude: claude, additionalProviders: [], defaults: d,
                                   firstLaunchDetector: { Set(ProviderID.allCases) })
    }

    private func freshDefaults() -> UserDefaults {
        let name = "webctl-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @MainActor
    func testControlPausedWhenWebSourceDisabled() {
        let d = freshDefaults()
        let c = makeCoordinator(d)
        // 默认 seed 只启用 cli 源 → web 未启用 → paused。
        XCTAssertFalse(c.claudeGroup.enabledSources.contains(.web))
        XCTAssertTrue(c.currentClaudeWebControl().paused)

        c.claudeGroup.setSourceEnabled(.web, true)
        XCTAssertFalse(c.currentClaudeWebControl().paused, "Claude 顶层启用 + Web 源启用 → 不暂停")
    }

    @MainActor
    func testControlPausedWhenClaudeTopLevelDisabled() {
        let d = freshDefaults()
        let c = makeCoordinator(d)
        c.claudeGroup.setSourceEnabled(.web, true)
        XCTAssertFalse(c.currentClaudeWebControl().paused)

        c.setEnabled(.claude, false)   // 关掉整个 Claude → 也应暂停扩展
        XCTAssertTrue(c.currentClaudeWebControl().paused)
    }

    @MainActor
    func testControlIntervalFollowsPollingMinutes() {
        let d = freshDefaults()
        d.set(5, forKey: "pollingMinutes")
        let c = makeCoordinator(d)
        XCTAssertEqual(c.currentClaudeWebControl().intervalSeconds, 5 * 60)
    }

    @MainActor
    func testBumpSyncNoncePersistsAndIncrements() {
        let d = freshDefaults()
        let c = makeCoordinator(d)
        XCTAssertEqual(c.currentClaudeWebControl().syncNonce, 0)

        c.publishClaudeWebControl(bumpSyncNonce: true)
        XCTAssertEqual(c.currentClaudeWebControl().syncNonce, 1)
        XCTAssertEqual(d.integer(forKey: ProviderCoordinator.webSyncNonceKey), 1, "nonce 应持久化以跨重启")

        c.publishClaudeWebControl(bumpSyncNonce: true)
        XCTAssertEqual(c.currentClaudeWebControl().syncNonce, 2)
    }

    @MainActor
    func testNonceRestoredFromDefaults() {
        let d = freshDefaults()
        d.set(9, forKey: ProviderCoordinator.webSyncNonceKey)
        let c = makeCoordinator(d)
        XCTAssertEqual(c.currentClaudeWebControl().syncNonce, 9, "重启后从 UserDefaults 恢复 nonce")
    }
}
