import XCTest
@testable import UsageBar

@MainActor
final class ProviderCoordinatorTests: XCTestCase {
    /// 顶层 provider 集合 —— ADR 0010/0012 起 `.claudeWeb` / `.codexWeb` 降为子源，不进 coordinator 的三个持久集合。
    private let topLevel = ProviderID.allCases.filter { $0 != .claudeWeb && $0 != .codexWeb }

    private func freshDefaults() -> UserDefaults {
        let name = "coord-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    /// claude = 真 UsageService（cliKeychainLoader stub → nil，等价未登录、不发网络）；codex = 真 CodexProvider（CODEX_HOME 指向不存在路径 → unconfigured）。
    /// v0.5.1：StoredCredentialsStore 已下线 —— 凭证只走 in-memory cache + Keychain loader，loader stub 返回 nil 即 unconfigured。
    /// firstLaunchDetector 注入全集，保持现有测试与"首次启动检测"逻辑解耦。
    private func makeCoordinator(_ d: UserDefaults, withCodex: Bool = true) -> ProviderCoordinator {
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        let extras: [UsageProvider] = withCodex
            ? [CodexProvider(environment: ["CODEX_HOME": "/nonexistent-\(UUID().uuidString)"], defaults: d)]
            : []
        let c = ProviderCoordinator(claude: claude, additionalProviders: extras, defaults: d,
                                    firstLaunchDetector: { Set(ProviderID.allCases) })
        c.controlWriter = { _ in }   // 单测不写真实 ~/.config/usage-bar/claude-web-control.json
        return c
    }

    func testDefaultOrderAndEnabled() {
        let c = makeCoordinator(freshDefaults())
        XCTAssertEqual(c.orderedProviderIDs, topLevel)
        XCTAssertTrue(c.enabledProviderIDs.isSuperset(of: [.claude, .codex]))
        XCTAssertEqual(c.availableIDs, [.claude, .codex])
        XCTAssertTrue(Set(c.menuBarVisibleIDs).isSuperset(of: [.claude, .codex]))
    }

    func testReadStoredOrderFiltersAndAppends() {
        let d = freshDefaults()
        d.set(["codex", "claude", "bogus", "gemini"], forKey: "providerOrder")
        let c = makeCoordinator(d)
        XCTAssertEqual(Set(c.orderedProviderIDs), Set(topLevel))
        XCTAssertEqual(Array(c.orderedProviderIDs.prefix(3)), [.codex, .claude, .gemini])
    }

    func testDisablingCodexRemovesFromAvailable() {
        let c = makeCoordinator(freshDefaults())
        c.setEnabled(.codex, false)
        XCTAssertFalse(c.enabledProviderIDs.contains(.codex))
        XCTAssertFalse(c.availableIDs.contains(.codex))
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
        XCTAssertEqual(c.claude.runtime.lastError, "Sign in with Claude CLI, then tap Retry")   // Claude 被拉过（首屏空 → 兜一次）
    }

    // 修复 issue #10：有 snapshot 的 non-Claude provider 在 popover 打开时不再刷。
    func testRefreshAllEnabledOnOpenSkipsNonClaudeWhenSnapshotPresent() async {
        let d = freshDefaults()
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        let stub = StubProviderForCoordTest(id: .cursor)
        stub.runtime.setSuccess(snapshot: ProviderUsageSnapshot())  // 已有数据
        let c = ProviderCoordinator(claude: claude, additionalProviders: [stub], defaults: d)
        await c.refreshAllEnabledOnOpen()
        XCTAssertEqual(stub.refreshNowCallCount, 0, "snapshot 非 nil 时不应再拉")
    }

    // v0.2.11：onBackgroundTick 现在也 tick Claude（不再特判跳过）—— 用「未登录 UsageService → refreshNow→fetchUsage 走未登录分支、设 lastError = "Sign in with Claude CLI, then tap Retry"」间接验证它被 tick 到了。
    func testOnBackgroundTickAlsoTicksClaude() async {
        let c = makeCoordinator(freshDefaults())
        c.onBackgroundTick()
        await Task.yield(); try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(c.claude.runtime.lastError, "Sign in with Claude CLI, then tap Retry")   // 被 tick 到了（v0.2.10 之前 onBackgroundTick 不会碰 Claude）
    }

    // backoff 窗口内的 provider 这一 tick 被跳过；窗口过后被 tick。
    func testBackoffWindowSkipsProvider() async {
        let d = freshDefaults()
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        let stub = StubProviderForCoordTest(id: .cursor)   // cursor 默认 enabled、注册进去
        let c = ProviderCoordinator(claude: claude, additionalProviders: [stub], defaults: d,
                                    firstLaunchDetector: { Set(ProviderID.allCases) })
        c.controlWriter = { _ in }
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

    // MARK: - Task 1（本 spec）：Claude 可禁用

    func testClaudeCanBeDisabled() {
        let c = makeCoordinator(freshDefaults())
        c.setEnabled(.claude, false)
        XCTAssertFalse(c.enabledProviderIDs.contains(.claude))
        XCTAssertFalse(c.availableIDs.contains(.claude))
    }

    func testAllProvidersDisabledYieldsEmptyAvailableIDs() {
        let c = makeCoordinator(freshDefaults(), withCodex: false)
        c.setEnabled(.claude, false)
        XCTAssertTrue(c.availableIDs.isEmpty)
    }

    // MARK: - Task 1：menuBarVisible

    func testMenuBarVisibleDefaultsToAllCases() {
        let c = makeCoordinator(freshDefaults())
        XCTAssertEqual(c.menuBarVisibleProviderIDs, Set(topLevel))
    }

    func testSetMenuBarVisibleFalseRemovesFromSet() {
        let d = freshDefaults()
        let c = makeCoordinator(d)
        c.setMenuBarVisible(.codex, false)
        XCTAssertFalse(c.menuBarVisibleProviderIDs.contains(.codex))
        let stored = Set((d.stringArray(forKey: "menuBarVisibleProviders") ?? [])
            .compactMap(ProviderID.init(rawValue:)))
        XCTAssertFalse(stored.contains(.codex), "应持久化到 UserDefaults")
    }

    func testMenuBarVisibleIDsExcludesDisabledProvider() {
        let c = makeCoordinator(freshDefaults())
        c.setEnabled(.codex, false)
        XCTAssertFalse(c.menuBarVisibleIDs.contains(.codex), "disabled → 不在 menuBarVisibleIDs")
    }

    func testMenuBarVisibleIDsExcludesUnregisteredProvider() {
        let c = makeCoordinator(freshDefaults(), withCodex: false)
        XCTAssertFalse(c.menuBarVisibleIDs.contains(.codex), "未注册 → 不在 menuBarVisibleIDs")
    }

    func testMenuBarVisibleIDsExcludesExplicitlyHiddenProvider() {
        let c = makeCoordinator(freshDefaults())
        c.setMenuBarVisible(.codex, false)
        XCTAssertFalse(c.menuBarVisibleIDs.contains(.codex), "menuBarVisible=false → 不在 menuBarVisibleIDs")
    }

    func testDisablingClaudeRemovesFromMenuBarVisibleIDs() {
        let c = makeCoordinator(freshDefaults())
        XCTAssertTrue(c.menuBarVisibleIDs.contains(.claude))
        c.setEnabled(.claude, false)
        XCTAssertFalse(c.menuBarVisibleIDs.contains(.claude))
    }

    func testMenuBarVisibleIDsRespectOrderedProviderIDs() {
        let d = freshDefaults()
        d.set(["codex", "claude"], forKey: "providerOrder")
        let c = makeCoordinator(d)
        let ids = c.menuBarVisibleIDs
        if ids.count >= 2 {
            XCTAssertEqual(ids[0], .codex)
            XCTAssertEqual(ids[1], .claude)
        }
    }

    // MARK: - issue #34：首次启动工具检测

    func testFirstLaunchDetectsInstalledProviders() {
        let d = freshDefaults()
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        let codex = CodexProvider(environment: ["CODEX_HOME": "/nonexistent-\(UUID().uuidString)"], defaults: d)
        let c = ProviderCoordinator(claude: claude, additionalProviders: [codex], defaults: d,
                                    firstLaunchDetector: { [.codex] })
        XCTAssertEqual(c.enabledProviderIDs, [.codex], "首次启动只启用检测到的工具")
        XCTAssertEqual(c.menuBarVisibleProviderIDs, [.codex], "menuBarVisible 同步首次检测结果")
        XCTAssertFalse(c.availableIDs.contains(.claude), "claude 未被检测到，不在 availableIDs")
    }

    func testStoredKeySkipsDetection() {
        let d = freshDefaults()
        // 预存 enabledProviders key（= 非首次启动），detector 返回空集不应影响结果
        d.set(["claude", "codex"], forKey: ProviderCoordinator.enabledProvidersKey)
        d.set(["claude", "codex"], forKey: ProviderCoordinator.menuBarVisibleProvidersKey)
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        var detectorCalled = false
        let c = ProviderCoordinator(claude: claude, additionalProviders: [], defaults: d,
                                    firstLaunchDetector: { detectorCalled = true; return [] })
        _ = c.enabledProviderIDs
        XCTAssertFalse(detectorCalled, "key 已存盘时不应调用 firstLaunchDetector")
        XCTAssertTrue(c.enabledProviderIDs.contains(.claude))
    }

    func testUnregisteredDetectedProviderNotInAvailableIDs() {
        let d = freshDefaults()
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        // 检测结果含 cursor（未注册 provider），不应出现在 availableIDs
        let c = ProviderCoordinator(claude: claude, additionalProviders: [], defaults: d,
                                    firstLaunchDetector: { [.claude, .cursor] })
        XCTAssertTrue(c.enabledProviderIDs.contains(.cursor), "cursor 被检测到、进入 enabledSet")
        XCTAssertFalse(c.availableIDs.contains(.cursor), "cursor 未注册，不在 availableIDs")
    }

    func testFirstLaunchEmptyDetectionFallsBackToAllCases() {
        let d = freshDefaults()
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        // 空检测结果 → fallback 全启用，防 UI 空白
        let c = ProviderCoordinator(claude: claude, additionalProviders: [], defaults: d,
                                    firstLaunchDetector: { [] })
        XCTAssertEqual(c.enabledProviderIDs, Set(topLevel))
        XCTAssertEqual(c.menuBarVisibleProviderIDs, Set(topLevel))
    }

    // MARK: - ADR 0012：Codex 门面注入 + 每 provider 控制通道

    /// 注入 `codex:` → coordinator 内部构造 codexGroup（多源门面），`.codex` 顶层注册的是门面。
    private func makeWithCodexGroup(_ d: UserDefaults) -> ProviderCoordinator {
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        let codex = CodexProvider(environment: ["CODEX_HOME": "/nonexistent-\(UUID().uuidString)"], defaults: d)
        let c = ProviderCoordinator(claude: claude, codex: codex, additionalProviders: [], defaults: d,
                                    firstLaunchDetector: { Set(ProviderID.allCases) })
        c.controlWriter = { _ in }
        return c
    }

    func testCodexGroupInjectedAndRegistered() {
        let c = makeWithCodexGroup(freshDefaults())
        XCTAssertNotNil(c.codexGroup, "注入 codex → 构建门面")
        XCTAssertNotNil(c.codexCLI)
        XCTAssertTrue(c.availableIDs.contains(.codex))
        XCTAssertNotNil(c.group(for: .codex))
        XCTAssertNotNil(c.group(for: .claude))
        XCTAssertNil(c.group(for: .gemini), "单源 provider 无门面")
        XCTAssertEqual(c.webCapableProviders, [.claude, .codex])
    }

    func testEnvelopeCarriesPerProviderControl() {
        let d = freshDefaults()
        let c = makeWithCodexGroup(d)
        c.codexGroup?.setSourceEnabled(.web, true)   // 启用 codex web 源 → 不暂停
        let env = c.currentWebControlEnvelope()
        XCTAssertNotNil(env.byProvider["claude"])
        XCTAssertNotNil(env.byProvider["codex"])
        XCTAssertEqual(env.paused, env.byProvider["claude"]?.paused, "顶层扁平 = Claude（backcompat）")
        XCTAssertEqual(env.byProvider["codex"]?.paused, false, "codex 顶层启用 + web 源启用 → 不暂停")
    }

    func testCodexControlPausedWhenWebSourceDisabled() {
        let d = freshDefaults()
        d.set(["cli"], forKey: MultiSourceProvider.enabledKey(for: .codex))   // 只启用 codex 的 cli 源
        let c = makeWithCodexGroup(d)
        XCTAssertFalse(c.codexGroup?.enabledSources.contains(.web) ?? true)
        XCTAssertEqual(c.currentWebControlEnvelope().byProvider["codex"]?.paused, true)
    }

    func testCodexRefreshBumpsOnlyCodexNonce() async {
        let d = freshDefaults()
        let c = makeWithCodexGroup(d)
        XCTAssertEqual(c.currentWebControlEnvelope().byProvider["codex"]?.syncNonce, 0)
        XCTAssertEqual(c.currentClaudeWebControl().syncNonce, 0)

        await c.refreshNow(.codex)   // 只 bump codex nonce
        XCTAssertEqual(c.currentWebControlEnvelope().byProvider["codex"]?.syncNonce, 1)
        XCTAssertEqual(c.currentClaudeWebControl().syncNonce, 0, "Claude nonce 不受影响")
        XCTAssertEqual(d.integer(forKey: ProviderCoordinator.nonceKey(for: .codex)), 1, "codex nonce 持久化")
    }

    func testCodexNonceRestoredFromDefaults() {
        let d = freshDefaults()
        d.set(4, forKey: ProviderCoordinator.nonceKey(for: .codex))
        let c = makeWithCodexGroup(d)
        XCTAssertEqual(c.currentWebControlEnvelope().byProvider["codex"]?.syncNonce, 4)
    }

    /// 未注入 codex → 无 codexGroup，byProvider 只含 claude（旧行为/单源测试路径）。
    func testNoCodexGroupWhenNotInjected() {
        let claude = UsageService()
        claude.cliKeychainLoader = { _ in nil }
        let c = ProviderCoordinator(claude: claude, additionalProviders: [], defaults: freshDefaults())
        c.controlWriter = { _ in }
        XCTAssertNil(c.codexGroup)
        XCTAssertEqual(c.webCapableProviders, [.claude])
        XCTAssertNil(c.currentWebControlEnvelope().byProvider["codex"])
    }
}

/// 给 `ProviderCoordinatorTests` 用的最小 provider（带 refreshNow 计数 + nextEligibleRefresh override）。
private final class StubProviderForCoordTest: UsageProvider {
    let id: ProviderID
    var isConfigured = true
    let runtime = ProviderRuntime(isConfigured: true)
    var onPollTick: (@MainActor () -> Void)? = nil
    var nextEligibleRefreshOverride: Date? = nil
    var nextEligibleRefresh: Date? { nextEligibleRefreshOverride }
    private(set) var refreshNowCallCount = 0
    init(id: ProviderID) { self.id = id }
    func refreshNow() async { refreshNowCallCount += 1 }
}
