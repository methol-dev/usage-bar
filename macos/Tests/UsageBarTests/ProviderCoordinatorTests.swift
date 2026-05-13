import XCTest
@testable import UsageBar

@MainActor
final class ProviderCoordinatorTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "coord-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    private func tmpDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// claude = 真 UsageService（凭证目录指向临时空目录 → 未登录、不发网络）；codex = 真 CodexProvider（CODEX_HOME 指向不存在路径 → unconfigured）。
    private func makeCoordinator(_ d: UserDefaults, withCodex: Bool = true) -> ProviderCoordinator {
        let claude = UsageService(credentialsStore: StoredCredentialsStore(directoryURL: tmpDir()))
        let extras: [UsageProvider] = withCodex
            ? [CodexProvider(environment: ["CODEX_HOME": "/nonexistent-\(UUID().uuidString)"], defaults: d)]
            : []
        return ProviderCoordinator(claude: claude, additionalProviders: extras, defaults: d)
    }

    func testDefaultOrderAndEnabled() {
        let c = makeCoordinator(freshDefaults())
        XCTAssertEqual(c.orderedProviderIDs, ProviderID.allCases)
        XCTAssertTrue(c.enabledProviderIDs.isSuperset(of: [.claude, .codex]))
        XCTAssertEqual(c.availableIDs, [.claude, .codex])
        XCTAssertEqual(c.menuBarProviderID, .claude)
    }

    func testReadStoredOrderFiltersAndAppends() {
        let d = freshDefaults()
        d.set(["codex", "claude", "bogus", "gemini"], forKey: "providerOrder")
        let c = makeCoordinator(d)
        XCTAssertEqual(Set(c.orderedProviderIDs), Set(ProviderID.allCases))
        XCTAssertEqual(Array(c.orderedProviderIDs.prefix(3)), [.codex, .claude, .gemini])
    }

    func testSetEnabledClaudeIsNoOp() {
        let c = makeCoordinator(freshDefaults())
        c.setEnabled(.claude, false)
        XCTAssertTrue(c.enabledProviderIDs.contains(.claude))
        XCTAssertTrue(c.availableIDs.contains(.claude))
    }

    func testDisablingCodexRemovesFromAvailable() {
        let c = makeCoordinator(freshDefaults())
        c.setEnabled(.codex, false)
        XCTAssertFalse(c.enabledProviderIDs.contains(.codex))
        XCTAssertFalse(c.availableIDs.contains(.codex))
    }

    func testDisablingMenuBarProviderMovesIt() {
        let d = freshDefaults(); d.set("codex", forKey: "primaryProviderID")
        let c = makeCoordinator(d)
        XCTAssertEqual(c.menuBarProviderID, .codex)        // 注册 + enabled → 接受
        c.setEnabled(.codex, false)
        XCTAssertEqual(c.menuBarProviderID, .claude)       // 跳到首个 enabled+registered
    }

    func testMoveProviderPersists() {
        let d = freshDefaults()
        let c = makeCoordinator(d)
        let first = c.orderedProviderIDs[0], second = c.orderedProviderIDs[1]
        c.moveProvider(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(c.orderedProviderIDs[0], second)
        XCTAssertEqual(c.orderedProviderIDs[1], first)
        XCTAssertEqual(d.stringArray(forKey: "providerOrder"), c.orderedProviderIDs.map(\.rawValue))
    }

    func testMenuBarProviderIDRejectsUnregistered() {
        let c = makeCoordinator(freshDefaults())
        c.menuBarProviderID = .cursor                      // 未注册 → 拒绝、回退
        XCTAssertEqual(c.menuBarProviderID, .claude)
    }

    func testMenuBarProviderIDRejectsDisabled() {
        let c = makeCoordinator(freshDefaults())
        c.setEnabled(.codex, false)
        c.menuBarProviderID = .codex                       // 注册但 disabled → 拒绝、回退
        XCTAssertEqual(c.menuBarProviderID, .claude)
    }

    func testInitFallbackOnIllegalStoredMenuBar() {
        let d = freshDefaults(); d.set("gemini", forKey: "primaryProviderID")   // 未注册
        let c = makeCoordinator(d)
        XCTAssertEqual(c.menuBarProviderID, .claude)
    }

    // MARK: - Task 5：刷新纪律 + 后台 timer

    func testBackgroundIntervalFollowsPollingMinutes() {
        let d = freshDefaults()
        let c = makeCoordinator(d)
        XCTAssertEqual(c.backgroundIntervalSeconds, TimeInterval(30 * 60))   // 默认
        d.set(5, forKey: "pollingMinutes")
        XCTAssertEqual(c.backgroundIntervalSeconds, TimeInterval(5 * 60))
        d.set(7, forKey: "pollingMinutes")                                   // 非法 → 30
        XCTAssertEqual(c.backgroundIntervalSeconds, TimeInterval(30 * 60))
    }

    func testRefreshAllEnabledOnOpenTicksClaudeWhenSnapshotNil() async {
        let c = makeCoordinator(freshDefaults())
        await c.refreshAllEnabledOnOpen()                  // codex unconfigured → 不发网络；claude snapshot==nil → 被拉一次
        XCTAssertNil(c.claude.runtime.snapshot)
        XCTAssertEqual(c.claude.runtime.lastError, "Not signed in")   // Claude 被拉过（首屏空 → 兜一次）
    }

    // 修复 issue #10：有 snapshot 的 non-Claude provider 在 popover 打开时不再刷。
    func testRefreshAllEnabledOnOpenSkipsNonClaudeWhenSnapshotPresent() async {
        let d = freshDefaults()
        let claude = UsageService(credentialsStore: StoredCredentialsStore(directoryURL: tmpDir()))
        let stub = StubProviderForCoordTest(id: .cursor)
        stub.runtime.setSuccess(snapshot: ProviderUsageSnapshot())  // 已有数据
        let c = ProviderCoordinator(claude: claude, additionalProviders: [stub], defaults: d)
        await c.refreshAllEnabledOnOpen()
        XCTAssertEqual(stub.refreshNowCallCount, 0, "snapshot 非 nil 时不应再拉")
    }

    // v0.2.11：onBackgroundTick 现在也 tick Claude（不再特判跳过）—— 用「未登录 UsageService → refreshNow→fetchUsage 走未登录分支、设 lastError = "Not signed in"」间接验证它被 tick 到了。
    func testOnBackgroundTickAlsoTicksClaude() async {
        let c = makeCoordinator(freshDefaults())
        c.onBackgroundTick()
        await Task.yield(); try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(c.claude.runtime.lastError, "Not signed in")   // 被 tick 到了（v0.2.10 之前 onBackgroundTick 不会碰 Claude）
    }

    // backoff 窗口内的 provider 这一 tick 被跳过；窗口过后被 tick。
    func testBackoffWindowSkipsProvider() async {
        let d = freshDefaults()
        let claude = UsageService(credentialsStore: StoredCredentialsStore(directoryURL: tmpDir()))
        let stub = StubProviderForCoordTest(id: .cursor)   // cursor 默认 enabled、注册进去
        let c = ProviderCoordinator(claude: claude, additionalProviders: [stub], defaults: d)
        XCTAssertTrue(c.availableIDs.contains(.cursor))

        stub.nextEligibleRefreshOverride = Date().addingTimeInterval(3600)   // 还在 backoff 窗口
        c.onBackgroundTick()
        await Task.yield(); try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stub.refreshNowCallCount, 0)

        stub.nextEligibleRefreshOverride = nil                                // 窗口已过
        c.onBackgroundTick()
        await Task.yield(); try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stub.refreshNowCallCount, 1)
    }

    // 每次后台 tick 都会调 onTickSideEffects（默认让 ModelPricingCatalog 按 3h 节流自刷新）。
    func testBackgroundTickInvokesPricingRefreshHook() {
        let c = makeCoordinator(freshDefaults())
        var called = 0
        c.onTickSideEffects = { called += 1 }
        c.onBackgroundTick()
        XCTAssertGreaterThanOrEqual(called, 1)
        c.onBackgroundTick()
        XCTAssertGreaterThanOrEqual(called, 2)
    }
}

/// 给 `ProviderCoordinatorTests` 用的最小 provider（带 refreshNow 计数 + nextEligibleRefresh override）。
private final class StubProviderForCoordTest: UsageProvider {
    let id: ProviderID
    var isConfigured = true
    var supportsBackgroundPolling = false
    let runtime = ProviderRuntime(isConfigured: true)
    var onPollTick: (@MainActor () -> Void)? = nil
    var nextEligibleRefreshOverride: Date? = nil
    var nextEligibleRefresh: Date? { nextEligibleRefreshOverride }
    private(set) var refreshNowCallCount = 0
    init(id: ProviderID) { self.id = id }
    func refreshNow() async { refreshNowCallCount += 1 }
}
