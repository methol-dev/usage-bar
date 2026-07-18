import XCTest
@testable import UsageBar

/// ClaudeProvider 门面（ADR 0010）：多数据源优先级降级、命中即停、backoff 感知（B1）、seed/迁移、config 净化。
@MainActor
final class ClaudeProviderTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "claude-src-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func snap(_ pct: Double) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(primaryWindow: UsageWindow(utilizationPct: pct))
    }

    /// 预置 enabled + priority，避免依赖 seed。
    private func withSources(_ d: UserDefaults, enabled: [String], priority: [String]) {
        d.set(enabled, forKey: ClaudeProvider.enabledKey)
        d.set(priority, forKey: ClaudeProvider.priorityKey)
    }

    // MARK: - 优先级 / 降级 / 命中即停

    func testWebPreferredHitStopsAtWeb() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let web = StubSource(id: .claudeWeb, configured: true); web.runtime.setSuccess(snapshot: snap(20))
        let cli = StubSource(id: .claude, configured: true); cli.runtime.setSuccess(snapshot: snap(80))
        let g = ClaudeProvider(cliSource: cli, webSource: web, defaults: d)

        await g.refreshNow()

        XCTAssertEqual(g.activeSource, .web)
        XCTAssertEqual(g.runtime.snapshot?.primaryWindow?.utilizationPct, 20)   // 用 web 的
        XCTAssertEqual(web.refreshNowCallCount, 1)
        XCTAssertEqual(cli.refreshNowCallCount, 0, "命中 web 即停，不应再拉 cli")
    }

    func testFallsBackToCLIWhenWebUnconfigured() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let web = StubSource(id: .claudeWeb, configured: false)         // web 未配置 → 无快照
        let cli = StubSource(id: .claude, configured: true); cli.runtime.setSuccess(snapshot: snap(55))
        let g = ClaudeProvider(cliSource: cli, webSource: web, defaults: d)

        await g.refreshNow()

        XCTAssertEqual(g.activeSource, .cli)
        XCTAssertEqual(g.runtime.snapshot?.primaryWindow?.utilizationPct, 55)
        XCTAssertEqual(web.refreshNowCallCount, 1, "web 优先，先试它")
        XCTAssertEqual(cli.refreshNowCallCount, 1, "web 拿不到 → 回退 cli")
    }

    // B1：cli 在 backoff 窗口内，即使被作为 fallback 也**绝不**被拉（不打限流端点），用其已有快照兜底。
    func testBackoffSkipsCLIInFallback() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let web = StubSource(id: .claudeWeb, configured: false)                 // web 失败
        let cli = StubSource(id: .claude, configured: true); cli.runtime.setSuccess(snapshot: snap(42))
        cli.nextEligibleRefreshOverride = Date().addingTimeInterval(3600)       // cli 还在 429 backoff
        let g = ClaudeProvider(cliSource: cli, webSource: web, defaults: d)

        await g.refreshNow()

        XCTAssertEqual(cli.refreshNowCallCount, 0, "B1：backoff 窗口内绝不拉 cli")
        XCTAssertEqual(g.activeSource, .cli, "回退到 cli 的既有快照")
        XCTAssertEqual(g.runtime.snapshot?.primaryWindow?.utilizationPct, 42)
    }

    func testNextEligibleRefreshOnlyPropagatesWhenCLIOnly() {
        let d = freshDefaults()
        let web = StubSource(id: .claudeWeb, configured: true)
        let cli = StubSource(id: .claude, configured: true)
        let backoff = Date().addingTimeInterval(1800)
        cli.nextEligibleRefreshOverride = backoff

        // 只选 cli → 透传 backoff
        withSources(d, enabled: ["cli"], priority: ["cli", "web"])
        let onlyCLI = ClaudeProvider(cliSource: cli, webSource: web, defaults: d)
        XCTAssertEqual(onlyCLI.nextEligibleRefresh, backoff)

        // 选了 web（无 backoff）→ 恒可 tick
        let d2 = freshDefaults()
        withSources(d2, enabled: ["web", "cli"], priority: ["web", "cli"])
        let both = ClaudeProvider(cliSource: cli, webSource: web, defaults: d2)
        XCTAssertNil(both.nextEligibleRefresh)
    }

    func testNoConfiguredSourceIsUnconfigured() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let web = StubSource(id: .claudeWeb, configured: false)
        let cli = StubSource(id: .claude, configured: false)
        let g = ClaudeProvider(cliSource: cli, webSource: web, defaults: d)

        await g.refreshNow()

        XCTAssertFalse(g.isConfigured)
        XCTAssertNil(g.runtime.snapshot)
    }

    func testIsConfiguredReflectsEnabledSourcesOnly() {
        let d = freshDefaults()
        withSources(d, enabled: ["cli"], priority: ["web", "cli"])   // 只启用 cli
        let web = StubSource(id: .claudeWeb, configured: true)        // web 配置了但没启用
        let cli = StubSource(id: .claude, configured: false)
        let g = ClaudeProvider(cliSource: cli, webSource: web, defaults: d)
        XCTAssertFalse(g.isConfigured, "web 已配置但未启用 → 不算数")

        g.setSourceEnabled(.web, true)
        XCTAssertTrue(g.isConfigured)
    }

    // MARK: - seed / 迁移

    func testSeedWebOnWhenWebAlreadyOn() {
        let d = freshDefaults()
        let g = ClaudeProvider(cliSource: StubSource(id: .claude, configured: false),
                               webSource: StubSource(id: .claudeWeb, configured: false),
                               defaults: d, webAlreadyOn: true)
        XCTAssertEqual(g.enabledSources, [.cli, .web])
        XCTAssertEqual(d.stringArray(forKey: ClaudeProvider.enabledKey).map(Set.init),
                       Set(["cli", "web"]))
    }

    func testSeedDefaultsToCLIOnlyWhenWebOff() {
        let d = freshDefaults()
        let g = ClaudeProvider(cliSource: StubSource(id: .claude, configured: false),
                               webSource: StubSource(id: .claudeWeb, configured: false),
                               defaults: d, webAlreadyOn: false)
        XCTAssertEqual(g.enabledSources, [.cli])
    }

    func testStoredEnabledSourcesSkipsSeed() {
        let d = freshDefaults()
        d.set(["web"], forKey: ClaudeProvider.enabledKey)
        let g = ClaudeProvider(cliSource: StubSource(id: .claude, configured: false),
                               webSource: StubSource(id: .claudeWeb, configured: false),
                               defaults: d, webAlreadyOn: false)   // webAlreadyOn 被忽略（已有 key）
        XCTAssertEqual(g.enabledSources, [.web])
    }

    // MARK: - Settings mutators

    func testSetSourceEnabledCannotEmptyToZero() {
        let d = freshDefaults()
        withSources(d, enabled: ["cli"], priority: ["cli", "web"])
        let g = ClaudeProvider(cliSource: StubSource(id: .claude, configured: true),
                               webSource: StubSource(id: .claudeWeb, configured: false), defaults: d)
        g.setSourceEnabled(.cli, false)   // 取消最后一个 → 忽略
        XCTAssertEqual(g.enabledSources, [.cli])
    }

    func testSetPreferredMovesToFront() {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let g = ClaudeProvider(cliSource: StubSource(id: .claude, configured: true),
                               webSource: StubSource(id: .claudeWeb, configured: true), defaults: d)
        g.setPreferred(.cli)
        XCTAssertEqual(g.sourcePriority.first, .cli)
        XCTAssertEqual(g.enabledByPriority, [.cli, .web])
        XCTAssertEqual(d.stringArray(forKey: ClaudeProvider.priorityKey)?.first, "cli")
    }

    // MARK: - config 净化

    func testSanitizePriorityDropsUnknownDedupAndFills() {
        XCTAssertEqual(ClaudeProvider.sanitizePriority(nil), [.web, .cli])                 // 缺 → 默认
        XCTAssertEqual(ClaudeProvider.sanitizePriority(["cli", "bogus", "cli"]), [.cli, .web]) // 去未知/去重/补漏
        XCTAssertEqual(ClaudeProvider.sanitizePriority(["web"]), [.web, .cli])             // 补漏 cli
    }
}

/// 可控数据源桩：预置 isConfigured / runtime / backoff，refreshNow 计数（+ 可选副作用）。
@MainActor
private final class StubSource: UsageProvider {
    let id: ProviderID
    var isConfigured: Bool
    let runtime = ProviderRuntime()
    var onPollTick: (@MainActor () -> Void)? = nil
    var nextEligibleRefreshOverride: Date? = nil
    var nextEligibleRefresh: Date? { nextEligibleRefreshOverride }
    private(set) var refreshNowCallCount = 0
    var onRefresh: (@MainActor (StubSource) -> Void)? = nil

    init(id: ProviderID, configured: Bool) {
        self.id = id
        self.isConfigured = configured
    }

    func refreshNow() async {
        refreshNowCallCount += 1
        onRefresh?(self)
    }
}
