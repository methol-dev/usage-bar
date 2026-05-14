import XCTest
@testable import UsageBar

/// v0.2.5 多供应商架构重构 —— 统一模型 + Claude 映射的测试。
/// （阶段 A2 会往本文件追加 registry/coordinator/runtime/spy 用例。）
final class ProviderAbstractionTests: XCTestCase {

    private func decodeUsage(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    /// 构造一个不发网络/不读宿主机 Keychain 的 `UsageService`（cliKeychainLoader stub 返回 nil）。
    /// v0.5.1：StoredCredentialsStore 已下线 —— 凭证只走 in-memory cache + Keychain loader。
    @MainActor
    private func makeBareService() throws -> UsageService {
        let service = UsageService()
        service.cliKeychainLoader = { _ in nil }
        return service
    }

    // MARK: - UsageResponse → ProviderUsageSnapshot 映射（SC5-b：等价于重构前后字段快照对比）

    func testMapFullFixture() throws {
        let json = """
        {
          "five_hour":       { "utilization": 42.0, "resets_at": "2099-01-01T23:44:00Z" },
          "seven_day":       { "utilization": 73.0, "resets_at": "2099-01-08T00:00:00Z" },
          "seven_day_opus":  { "utilization": 12.5, "resets_at": "2099-01-08T00:00:00Z" },
          "seven_day_sonnet":{ "utilization": 5.0,  "resets_at": "2099-01-08T00:00:00Z" },
          "extra_usage":     { "is_enabled": true, "utilization": 30.0, "used_credits": 1469, "monthly_limit": 5000 }
        }
        """
        let snap = try decodeUsage(json).asProviderSnapshot()

        XCTAssertEqual(snap.primaryWindow?.label, "Session")
        XCTAssertEqual(snap.primaryWindow?.utilizationPct, 42.0)
        XCTAssertEqual(snap.primaryWindow?.windowDuration, 5 * 60 * 60)
        XCTAssertNotNil(snap.primaryWindow?.resetsAt)

        XCTAssertEqual(snap.secondaryWindow?.label, "Weekly")
        XCTAssertEqual(snap.secondaryWindow?.utilizationPct, 73.0)
        XCTAssertEqual(snap.secondaryWindow?.windowDuration, 7 * 24 * 60 * 60)

        XCTAssertEqual(snap.extraWindows.map(\.id), ["opus", "sonnet"])
        XCTAssertEqual(snap.extraWindows.map(\.title), ["Opus", "Sonnet"])
        XCTAssertEqual(snap.extraWindows.first?.window.utilizationPct, 12.5)
        XCTAssertEqual(snap.extraWindows.last?.window.utilizationPct, 5.0)
        XCTAssertEqual(snap.extraWindows.first?.window.windowDuration, 7 * 24 * 60 * 60)

        XCTAssertEqual(snap.creditLine?.isEnabled, true)
        XCTAssertEqual(snap.creditLine?.utilizationPct, 30.0)
        // 分 → 元换算：1469 分 → 14.69 元；5000 分 → 50.00 元
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.usedAmount), 14.69, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.limitAmount), 50.0, accuracy: 1e-9)

        XCTAssertNil(snap.planLabel)
    }

    func testMapResetAtIsParsedToDate() throws {
        let json = #"{ "five_hour": { "utilization": 10.0, "resets_at": "2099-01-01T23:44:00Z" } }"#
        let snap = try decodeUsage(json).asProviderSnapshot()
        let expected = ISO8601DateFormatter().date(from: "2099-01-01T23:44:00Z")
        XCTAssertEqual(snap.primaryWindow?.resetsAt, expected)
    }

    func testMapMissingFields() throws {
        let json = #"{ "five_hour": { "utilization": 20.0 } }"#
        let snap = try decodeUsage(json).asProviderSnapshot()
        XCTAssertEqual(snap.primaryWindow?.utilizationPct, 20.0)
        XCTAssertNil(snap.primaryWindow?.resetsAt)
        XCTAssertNil(snap.secondaryWindow)
        XCTAssertTrue(snap.extraWindows.isEmpty)
        XCTAssertNil(snap.creditLine)
        XCTAssertNil(snap.planLabel)
    }

    func testMapEmptyResponse() throws {
        let snap = try decodeUsage("{}").asProviderSnapshot()
        XCTAssertNil(snap.primaryWindow)
        XCTAssertNil(snap.secondaryWindow)
        XCTAssertTrue(snap.extraWindows.isEmpty)
        XCTAssertNil(snap.creditLine)
    }

    /// 保留旧 popover 逻辑：Opus 行只在 `seven_day_opus.utilization != nil` 时显示；
    /// Opus 不显示则 Sonnet 也不显示。
    func testMapOpusWithoutUtilizationExcludesPerModel() throws {
        let json = """
        {
          "seven_day_opus":  { "resets_at": "2099-01-08T00:00:00Z" },
          "seven_day_sonnet":{ "utilization": 5.0, "resets_at": "2099-01-08T00:00:00Z" }
        }
        """
        let snap = try decodeUsage(json).asProviderSnapshot()
        XCTAssertTrue(snap.extraWindows.isEmpty)
    }

    func testMapExtraUsageDisabled() throws {
        let json = #"{ "extra_usage": { "is_enabled": false } }"#
        let snap = try decodeUsage(json).asProviderSnapshot()
        XCTAssertEqual(snap.creditLine?.isEnabled, false)
        XCTAssertNil(snap.creditLine?.usedAmount)
        XCTAssertNil(snap.creditLine?.limitAmount)
    }

    // MARK: - ProviderRuntime 状态机

    @MainActor
    func testProviderRuntimeSuccessThenError() {
        let rt = ProviderRuntime(isConfigured: false)
        XCTAssertNil(rt.snapshot)
        XCTAssertNil(rt.lastUpdated)
        XCTAssertFalse(rt.isConfigured)

        rt.setConfigured(true)
        XCTAssertTrue(rt.isConfigured)

        let snap = ProviderUsageSnapshot(primaryWindow: UsageWindow(utilizationPct: 50))
        rt.setSuccess(snapshot: snap)
        XCTAssertEqual(rt.snapshot, snap)
        XCTAssertNotNil(rt.lastUpdated)
        XCTAssertNil(rt.lastError)

        // 网络类失败：保留旧 snapshot
        rt.setError("network blip", clearSnapshot: false)
        XCTAssertEqual(rt.snapshot, snap)
        XCTAssertEqual(rt.lastError, "network blip")

        // 凭证类失败：清旧 snapshot
        rt.setError("expired", clearSnapshot: true)
        XCTAssertNil(rt.snapshot)
        XCTAssertEqual(rt.lastError, "expired")

        rt.clear()
        XCTAssertNil(rt.snapshot)
        XCTAssertNil(rt.lastUpdated)
        XCTAssertNil(rt.lastError)
    }

    // MARK: - ProviderRegistry / ProviderCoordinator

    @MainActor
    func testRegistryClaudeOnly() throws {
        let claude = try makeBareService()
        let registry = ProviderRegistry(providers: [claude])
        XCTAssertEqual(registry.orderedIDs, ProviderID.allCases)
        XCTAssertEqual(registry.availableIDs, [.claude])
        XCTAssertTrue(registry.isAvailable(.claude))
        XCTAssertFalse(registry.isAvailable(.codex))
        XCTAssertTrue(registry.provider(.claude) === claude)
        XCTAssertNil(registry.provider(.gemini))
    }

    @MainActor
    func testCoordinatorDefaultsToClaude() throws {
        let d = UserDefaults(suiteName: "abs-coord-\(UUID().uuidString)")!
        let claude = try makeBareService()
        let coord = ProviderCoordinator(claude: claude, defaults: d)
        XCTAssertTrue(coord.menuBarVisibleIDs.contains(.claude))
        XCTAssertEqual(coord.availableIDs, [.claude])
        XCTAssertTrue(coord.claude === claude)
    }

    @MainActor
    func testCoordinatorMenuBarVisibleIDsTracksEnabledAndVisible() throws {
        let name = "abs-coord-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name)
        let claude = try makeBareService()
        // 任何「已注册 + 已启用 + 菜单栏可见」的 provider 都会出现在 menuBarVisibleIDs。
        let stub = StubProvider(id: .codex)
        let coord = ProviderCoordinator(claude: claude, additionalProviders: [stub], defaults: d)
        XCTAssertEqual(Set(coord.availableIDs), Set([.claude, .codex]))
        XCTAssertTrue(Set(coord.menuBarVisibleIDs).isSuperset(of: [.claude, .codex]))

        // 隐藏 codex → 不再出现在 menuBarVisibleIDs
        coord.setMenuBarVisible(.codex, false)
        XCTAssertFalse(coord.menuBarVisibleIDs.contains(.codex))
        XCTAssertTrue(coord.menuBarVisibleIDs.contains(.claude))

        // 新建 coordinator 应从 UserDefaults 恢复（codex 被隐藏的状态持久化）
        let coord2 = ProviderCoordinator(claude: try makeBareService(), additionalProviders: [StubProvider(id: .codex)], defaults: d)
        XCTAssertFalse(coord2.menuBarVisibleIDs.contains(.codex))
        XCTAssertTrue(coord2.menuBarVisibleIDs.contains(.claude))
    }

    // MARK: - SC5-c：一次成功 fetch 后 recordDataPoint / checkAndNotify 仍被调用

    @MainActor
    func testSuccessfulFetchStillRecordsHistoryAndNotifies() async throws {
        let usageURL = URL(string: "https://example.test/api/oauth/usage")!
        StubURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(url: usageURL, statusCode: 200, httpVersion: nil, headerFields: [:])!
            let body = #"{ "five_hour": { "utilization": 33, "resets_at": "2099-03-08T18:00:00Z" }, "seven_day": { "utilization": 44, "resets_at": "2099-03-15T18:00:00Z" } }"#
            return (resp, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        // v0.5.1：凭证走 in-memory cache + Keychain loader stub；返回未过期 token → 直接进 200 主路径。
        let service = UsageService(
            session: URLSession(configuration: config),
            usageEndpoint: usageURL
        )
        service.cliKeychainLoader = { _ in
            StoredCredentials(
                accessToken: "tok",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                scopes: ["user:profile"]
            )
        }
        let historySpy = HistorySpy()
        let notifySpy = NotifySpy()
        service.historyService = historySpy
        service.notificationService = notifySpy

        await service.fetchUsage()

        XCTAssertEqual(historySpy.recordCount, 1, "fetch 成功后应记录一个历史点")
        XCTAssertEqual(notifySpy.notifyCount, 1, "fetch 成功后应做一次阈值检查")
        XCTAssertNil(service.runtime.lastError)
        XCTAssertNotNil(service.runtime.lastUpdated)
        XCTAssertEqual(service.runtime.snapshot?.primaryWindow?.utilizationPct, 33)
        XCTAssertEqual(service.runtime.snapshot?.secondaryWindow?.utilizationPct, 44)

        StubURLProtocol.handler = nil
    }
}

// MARK: - Test doubles

@MainActor
private final class StubProvider: UsageProvider {
    let id: ProviderID
    var isConfigured: Bool = true
    let runtime = ProviderRuntime(isConfigured: true)
    var onPollTick: (@MainActor () -> Void)? = nil
    /// 测试可设：让 coordinator 的 tick 跳过本 stub（模拟 backoff 窗口）。
    var nextEligibleRefreshOverride: Date? = nil
    var nextEligibleRefresh: Date? { nextEligibleRefreshOverride }
    private(set) var refreshNowCallCount = 0
    init(id: ProviderID) { self.id = id }
    func refreshNow() async { refreshNowCallCount += 1 }
}

@MainActor
private final class HistorySpy: HistoryRecording {
    private(set) var recordCount = 0
    func recordDataPoint(pct5h: Double, pct7d: Double) { recordCount += 1 }
}

@MainActor
private final class NotifySpy: UsageNotifying {
    private(set) var notifyCount = 0
    func checkAndNotify(pct5h: Double, pct7d: Double, pctExtra: Double) { notifyCount += 1 }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
