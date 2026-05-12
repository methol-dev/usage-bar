import XCTest
@testable import ClaudeUsageBar

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

    func testShouldRefreshClaudeOnOpenWhenSnapshotNil() {
        let c = makeCoordinator(freshDefaults())
        XCTAssertTrue(c.shouldRefreshClaudeOnOpen)         // 全新 UsageService（未登录）→ runtime.snapshot == nil
    }

    func testRefreshAllEnabledOnOpenDoesNotCrash() async {
        let c = makeCoordinator(freshDefaults())
        await c.refreshAllEnabledOnOpen()                  // codex unconfigured → 不发网络；不崩即可
        // claude unauthenticated → refreshNow 走未登录分支、不发网络；snapshot 仍 nil
        XCTAssertNil(c.claude.runtime.snapshot)
    }

    func testOnBackgroundTickDoesNotTouchClaude() async {
        let c = makeCoordinator(freshDefaults())
        c.onBackgroundTick()
        await Task.yield(); try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(c.claude.runtime.snapshot)            // 后台 tick 只碰非-Claude
    }
}
