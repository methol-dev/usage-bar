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
        d.set(enabled, forKey: MultiSourceProvider.enabledKey(for: .claude))
        d.set(priority, forKey: MultiSourceProvider.priorityKey(for: .claude))
    }

    // MARK: - 优先级 / 降级 / 命中即停

    func testWebPreferredHitStopsAtWeb() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let web = StubSource(id: .claudeWeb, configured: true); web.runtime.setSuccess(snapshot: snap(20))
        let cli = StubSource(id: .claude, configured: true); cli.runtime.setSuccess(snapshot: snap(80))
        let g = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)

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
        let g = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)

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
        let g = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)

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
        let onlyCLI = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)
        XCTAssertEqual(onlyCLI.nextEligibleRefresh, backoff)

        // 选了 web（无 backoff）→ 恒可 tick
        let d2 = freshDefaults()
        withSources(d2, enabled: ["web", "cli"], priority: ["web", "cli"])
        let both = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d2)
        XCTAssertNil(both.nextEligibleRefresh)
    }

    func testNoConfiguredSourceIsUnconfigured() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let web = StubSource(id: .claudeWeb, configured: false)
        let cli = StubSource(id: .claude, configured: false)
        let g = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)

        await g.refreshNow()

        XCTAssertFalse(g.isConfigured)
        XCTAssertNil(g.runtime.snapshot)
    }

    func testIsConfiguredReflectsEnabledSourcesOnly() {
        let d = freshDefaults()
        withSources(d, enabled: ["cli"], priority: ["web", "cli"])   // 只启用 cli
        let web = StubSource(id: .claudeWeb, configured: true)        // web 配置了但没启用
        let cli = StubSource(id: .claude, configured: false)
        let g = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)
        XCTAssertFalse(g.isConfigured, "web 已配置但未启用 → 不算数")

        g.setSourceEnabled(.web, true)
        XCTAssertTrue(g.isConfigured)
    }

    // MARK: - seed / 迁移

    func testSeedWebOnWhenWebAlreadyOn() {
        let d = freshDefaults()
        let g = MultiSourceProvider(id: .claude, cliSource: StubSource(id: .claude, configured: false),
                               webSource: StubSource(id: .claudeWeb, configured: false),
                               defaults: d, webAlreadyOn: true)
        XCTAssertEqual(g.enabledSources, [.cli, .web])
        XCTAssertEqual(d.stringArray(forKey: MultiSourceProvider.enabledKey(for: .claude)).map(Set.init),
                       Set(["cli", "web"]))
    }

    func testSeedDefaultsToCLIOnlyWhenWebOff() {
        let d = freshDefaults()
        let g = MultiSourceProvider(id: .claude, cliSource: StubSource(id: .claude, configured: false),
                               webSource: StubSource(id: .claudeWeb, configured: false),
                               defaults: d, webAlreadyOn: false)
        XCTAssertEqual(g.enabledSources, [.cli])
    }

    func testStoredEnabledSourcesSkipsSeed() {
        let d = freshDefaults()
        d.set(["web"], forKey: MultiSourceProvider.enabledKey(for: .claude))
        let g = MultiSourceProvider(id: .claude, cliSource: StubSource(id: .claude, configured: false),
                               webSource: StubSource(id: .claudeWeb, configured: false),
                               defaults: d, webAlreadyOn: false)   // webAlreadyOn 被忽略（已有 key）
        XCTAssertEqual(g.enabledSources, [.web])
    }

    // MARK: - Settings mutators

    func testSetSourceEnabledCannotEmptyToZero() {
        let d = freshDefaults()
        withSources(d, enabled: ["cli"], priority: ["cli", "web"])
        let g = MultiSourceProvider(id: .claude, cliSource: StubSource(id: .claude, configured: true),
                               webSource: StubSource(id: .claudeWeb, configured: false), defaults: d)
        g.setSourceEnabled(.cli, false)   // 取消最后一个 → 忽略
        XCTAssertEqual(g.enabledSources, [.cli])
    }

    func testSetPreferredMovesToFront() {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let g = MultiSourceProvider(id: .claude, cliSource: StubSource(id: .claude, configured: true),
                               webSource: StubSource(id: .claudeWeb, configured: true), defaults: d)
        g.setPreferred(.cli)
        XCTAssertEqual(g.sourcePriority.first, .cli)
        XCTAssertEqual(g.enabledByPriority, [.cli, .web])
        XCTAssertEqual(d.stringArray(forKey: MultiSourceProvider.priorityKey(for: .claude))?.first, "cli")
    }

    // MARK: - Web 快照回推（历史采样 / 阈值通知副作用挂钩）

    func testWebHitFiresOnWebSnapshotOncePerPayloadTimestamp() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let ts = Date(timeIntervalSince1970: 1_752_900_000.5)
        let web = StubSource(id: .claudeWeb, configured: true)
        web.runtime.setSuccess(snapshot: snap(20), at: ts)
        let cli = StubSource(id: .claude, configured: true)
        let g = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)
        var received: [(pct: Double?, ts: Date)] = []
        g.onWebSnapshot = { s, t in received.append((s.primaryWindow?.utilizationPct, t)) }

        await g.refreshNow()
        await g.refreshNow()   // 重读未变化的落盘数据（同 payload ts）→ 不重复回推

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.pct, 20)
        XCTAssertEqual(received.first?.ts, ts, "回推携带 payload 时刻，记点落在数据真实产生的位置")

        web.runtime.setSuccess(snapshot: snap(25), at: ts.addingTimeInterval(900))   // 扩展新同步
        await g.refreshNow()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last?.pct, 25)
    }

    func testWebSampleDedupSurvivesRestart() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let ts = Date(timeIntervalSince1970: 1_752_900_000.5)
        let web = StubSource(id: .claudeWeb, configured: true)
        web.runtime.setSuccess(snapshot: snap(20), at: ts)
        let cli = StubSource(id: .claude, configured: true)

        let g1 = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)
        var count1 = 0
        g1.onWebSnapshot = { _, _ in count1 += 1 }
        await g1.refreshNow()
        XCTAssertEqual(count1, 1)

        // 模拟 app 重启：同一 defaults 新建门面，同一份落盘数据不重复记点
        let g2 = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)
        var count2 = 0
        g2.onWebSnapshot = { _, _ in count2 += 1 }
        await g2.refreshNow()
        XCTAssertEqual(count2, 0, "去重时间戳已持久化，重启后同 payload ts 不重复回推")
    }

    func testCLIHitDoesNotFireOnWebSnapshot() async {
        let d = freshDefaults()
        withSources(d, enabled: ["cli"], priority: ["cli", "web"])
        let web = StubSource(id: .claudeWeb, configured: false)
        let cli = StubSource(id: .claude, configured: true)
        cli.runtime.setSuccess(snapshot: snap(60))
        let g = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)
        var fired = 0
        g.onWebSnapshot = { _, _ in fired += 1 }

        await g.refreshNow()

        XCTAssertEqual(g.activeSource, .cli)
        XCTAssertEqual(fired, 0, "cli 命中时其内部已自记历史，不回推（避免双记）")
    }

    func testStaleWebFallsBackToCLIWithoutFiring() async {
        let d = freshDefaults()
        withSources(d, enabled: ["web", "cli"], priority: ["web", "cli"])
        let web = StubSource(id: .claudeWeb, configured: true)
        web.runtime.setSuccess(snapshot: snap(20))
        web.runtime.setError("Claude Web data is stale — is the extension still running?", clearSnapshot: false)
        let cli = StubSource(id: .claude, configured: true)
        cli.runtime.setSuccess(snapshot: snap(70))
        let g = MultiSourceProvider(id: .claude, cliSource: cli, webSource: web, defaults: d)
        var fired = 0
        g.onWebSnapshot = { _, _ in fired += 1 }

        await g.refreshNow()

        XCTAssertEqual(cli.refreshNowCallCount, 1, "stale web 不算命中 → 回退 cli 取数，图表不断线")
        XCTAssertEqual(g.activeSource, .cli)
        XCTAssertEqual(g.runtime.snapshot?.primaryWindow?.utilizationPct, 70)
        XCTAssertEqual(fired, 0, "带错误的 web 快照不回推")
    }

    // MARK: - historySample 映射（web 回推与 Codex CLI 自记共用）

    func testHistorySampleMapping() {
        XCTAssertNil(ProviderUsageSnapshot().historySample, "两个窗口都缺 → 不记点")

        let both = ProviderUsageSnapshot(primaryWindow: UsageWindow(utilizationPct: 33),
                                         secondaryWindow: UsageWindow(utilizationPct: 44))
        XCTAssertEqual(both.historySample?.pct5h, 0.33)
        XCTAssertEqual(both.historySample?.pct7d, 0.44)

        let onlySecondary = ProviderUsageSnapshot(secondaryWindow: UsageWindow(utilizationPct: 150))
        XCTAssertEqual(onlySecondary.historySample?.pct5h, 0, "缺失窗口按 0 记")
        XCTAssertEqual(onlySecondary.historySample?.pct7d, 1.0, "范围外值 clamp 到 0...1")
    }

    // MARK: - config 净化

    func testSanitizePriorityDropsUnknownDedupAndFills() {
        XCTAssertEqual(MultiSourceProvider.sanitizePriority(nil), [.web, .cli])                 // 缺 → 默认
        XCTAssertEqual(MultiSourceProvider.sanitizePriority(["cli", "bogus", "cli"]), [.cli, .web]) // 去未知/去重/补漏
        XCTAssertEqual(MultiSourceProvider.sanitizePriority(["web"]), [.web, .cli])             // 补漏 cli
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
