import XCTest
@testable import ClaudeUsageBar

final class CodexProviderTests: XCTestCase {

    // MARK: - helpers

    /// 在临时目录里写一个 auth.json，返回模拟的 environment dict（CODEX_HOME 指向它）。
    private func makeCodexHome(authJSON: String?) throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let authJSON {
            try Data(authJSON.utf8).write(to: dir.appendingPathComponent("auth.json"))
        }
        return ["CODEX_HOME": dir.path]
    }

    /// SC7：用明显的哨兵值而非像真凭证的串；如需失败 message 也只暴露掩码。
    private func mask(_ s: String?) -> String { s == nil ? "<nil>" : "<\(s!.count)chars>" }

    private func stubSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        CodexStubURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CodexStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func decodeCodex(_ json: String) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    }

    // MARK: - 凭证解析

    func testLoadOAuthSnakeCase() throws {
        let env = try makeCodexHome(authJSON: """
        { "tokens": { "access_token": "ACCESS_SENTINEL", "refresh_token": "REFRESH_SENTINEL",
                      "id_token": "ID_SENTINEL", "account_id": "ACCT_SENTINEL" },
          "last_refresh": "2026-05-10T12:34:56.789Z" }
        """)
        let creds = try XCTUnwrap(CodexCredentialStore.load(environment: env))
        XCTAssertEqual(creds.accessToken, "ACCESS_SENTINEL", "accessToken mismatch: \(mask(creds.accessToken))")
        XCTAssertEqual(creds.refreshToken, "REFRESH_SENTINEL")
        XCTAssertEqual(creds.idToken, "ID_SENTINEL")
        XCTAssertEqual(creds.accountId, "ACCT_SENTINEL")
    }

    func testLoadOAuthCamelCase() throws {
        let env = try makeCodexHome(authJSON: """
        { "tokens": { "accessToken": "ACCESS_SENTINEL", "refreshToken": "REFRESH_SENTINEL",
                      "idToken": "ID_SENTINEL", "accountId": "ACCT_SENTINEL" } }
        """)
        let creds = try XCTUnwrap(CodexCredentialStore.load(environment: env))
        XCTAssertEqual(creds.accessToken, "ACCESS_SENTINEL")
        XCTAssertEqual(creds.accountId, "ACCT_SENTINEL")
    }

    func testLoadAPIKeyForm() throws {
        let env = try makeCodexHome(authJSON: #"{ "OPENAI_API_KEY": "KEY_SENTINEL" }"#)
        let creds = try XCTUnwrap(CodexCredentialStore.load(environment: env))
        XCTAssertEqual(creds.accessToken, "KEY_SENTINEL")
        XCTAssertNil(creds.refreshToken)
        XCTAssertNil(creds.idToken)
        XCTAssertNil(creds.accountId)
    }

    func testLoadMissingTokensThrows() throws {
        let env = try makeCodexHome(authJSON: #"{ "something_else": true }"#)
        XCTAssertThrowsError(try CodexCredentialStore.load(environment: env)) { error in
            XCTAssertTrue(error is CodexCredentialError)
        }
    }

    func testLoadInvalidJSONThrows() throws {
        let env = try makeCodexHome(authJSON: "not json {{{")
        XCTAssertThrowsError(try CodexCredentialStore.load(environment: env))
    }

    func testLoadFileAbsentReturnsNil() throws {
        let env = try makeCodexHome(authJSON: nil)   // 目录存在，auth.json 不存在
        XCTAssertNil(try CodexCredentialStore.load(environment: env))
    }

    func testLoadRespectsCodexHome() throws {
        let env = try makeCodexHome(authJSON: #"{ "OPENAI_API_KEY": "KEY_SENTINEL" }"#)
        XCTAssertNotNil(try CodexCredentialStore.load(environment: env))
        XCTAssertEqual(CodexCredentialStore.authFileURL(environment: env).lastPathComponent, "auth.json")
        XCTAssertTrue(CodexCredentialStore.authFileURL(environment: env).path.hasPrefix(env["CODEX_HOME"]!))
    }

    func testCodexCredentialErrorDescriptionHasNoRawValues() {
        for e in [CodexCredentialError.malformed, CodexCredentialError.missingTokens] {
            let s = "\(e)"
            XCTAssertFalse(s.contains("SENTINEL"))
            XCTAssertFalse(s.contains("{"))
        }
    }

    // MARK: - wham/usage 解码 + 映射

    func testDecodeFullFixtureAndMap() throws {
        let resetSession = 1_750_000_000
        let resetWeekly = 1_750_500_000
        let json = """
        { "plan_type": "plus",
          "rate_limit": {
            "primary_window":   { "used_percent": 37, "reset_at": \(resetSession), "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 12, "reset_at": \(resetWeekly),  "limit_window_seconds": 604800 } },
          "credits": { "has_credits": true, "unlimited": false, "balance": 12.34 } }
        """
        let resp = try decodeCodex(json)
        XCTAssertEqual(resp.plan, .plus)
        let (s, w) = resp.normalizedWindows()
        XCTAssertEqual(s?.windowSeconds, 18000)
        XCTAssertEqual(s?.usedPercent, 37)
        XCTAssertEqual(s?.resetAt, Date(timeIntervalSince1970: TimeInterval(resetSession)))
        XCTAssertEqual(w?.windowSeconds, 604800)

        let snap = resp.asProviderSnapshot()
        XCTAssertEqual(snap.primaryWindow?.label, "Session")
        XCTAssertEqual(snap.primaryWindow?.utilizationPct, 37)
        XCTAssertEqual(snap.primaryWindow?.windowDuration, 18000)
        XCTAssertEqual(snap.primaryWindow?.resetsAt, Date(timeIntervalSince1970: TimeInterval(resetSession)))
        XCTAssertEqual(snap.secondaryWindow?.label, "Weekly")
        XCTAssertEqual(snap.secondaryWindow?.windowDuration, 604800)
        XCTAssertTrue(snap.extraWindows.isEmpty)
        XCTAssertEqual(snap.planLabel, "Plus")
        XCTAssertEqual(snap.creditLine?.isEnabled, true)
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.remainingAmount), 12.34, accuracy: 1e-9)
        XCTAssertEqual(snap.creditLine?.isUnlimited, false)
    }

    func testNormalizeSwappedWindows() throws {
        let json = """
        { "rate_limit": {
            "primary_window":   { "used_percent": 50, "reset_at": 1, "limit_window_seconds": 604800 },
            "secondary_window": { "used_percent": 20, "reset_at": 2, "limit_window_seconds": 18000 } } }
        """
        let snap = try decodeCodex(json).asProviderSnapshot()
        XCTAssertEqual(snap.primaryWindow?.windowDuration, 18000)
        XCTAssertEqual(snap.primaryWindow?.utilizationPct, 20)
        XCTAssertEqual(snap.secondaryWindow?.windowDuration, 604800)
        XCTAssertEqual(snap.secondaryWindow?.utilizationPct, 50)
    }

    func testDecodeSingleWindow() throws {
        let json = #"{ "rate_limit": { "primary_window": { "used_percent": 5, "reset_at": 9, "limit_window_seconds": 18000 } } }"#
        let snap = try decodeCodex(json).asProviderSnapshot()
        XCTAssertEqual(snap.primaryWindow?.windowDuration, 18000)
        XCTAssertNil(snap.secondaryWindow)
    }

    func testDecodeCreditsBalanceAsString() throws {
        let json = #"{ "credits": { "has_credits": true, "unlimited": false, "balance": "8.5" } }"#
        let snap = try decodeCodex(json).asProviderSnapshot()
        XCTAssertEqual(try XCTUnwrap(snap.creditLine?.remainingAmount), 8.5, accuracy: 1e-9)
    }

    func testDecodeCreditsUnlimited() throws {
        let json = #"{ "credits": { "has_credits": true, "unlimited": true } }"#
        let snap = try decodeCodex(json).asProviderSnapshot()
        XCTAssertEqual(snap.creditLine?.isUnlimited, true)
        XCTAssertNil(snap.creditLine?.remainingAmount)
    }

    func testDecodeUnknownPlan() throws {
        let json = #"{ "plan_type": "galaxy_brain" }"#
        let resp = try decodeCodex(json)
        XCTAssertEqual(resp.plan, .unknown("galaxy_brain"))
        XCTAssertFalse(resp.plan.displayName.isEmpty)
        XCTAssertEqual(resp.asProviderSnapshot().planLabel, resp.plan.displayName)
    }

    func testDecodeEmpty() throws {
        let snap = try decodeCodex("{}").asProviderSnapshot()
        XCTAssertNil(snap.primaryWindow)
        XCTAssertNil(snap.secondaryWindow)
        XCTAssertNil(snap.creditLine)
        XCTAssertNil(snap.planLabel)
    }

    // MARK: - CodexUsageClient

    func testClientSuccess() async throws {
        let creds = CodexCredentials(accessToken: "ACCESS_SENTINEL", refreshToken: nil, idToken: nil, accountId: "ACCT_SENTINEL")
        let session = stubSession { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ACCESS_SENTINEL")
            XCTAssertEqual(req.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "ACCT_SENTINEL")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{ "plan_type": "pro", "rate_limit": { "primary_window": { "used_percent": 10, "reset_at": 5, "limit_window_seconds": 18000 } } }"#.utf8))
        }
        defer { CodexStubURLProtocol.handler = nil }
        let r = try await CodexUsageClient.fetchUsage(credentials: creds, session: session)
        XCTAssertEqual(r.plan, .pro)
        XCTAssertEqual(r.primaryWindow?.usedPercent, 10)
    }

    func testClientUnauthorized() async {
        let creds = CodexCredentials(accessToken: "ACCESS_SENTINEL", refreshToken: nil, idToken: nil, accountId: nil)
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { CodexStubURLProtocol.handler = nil }
        do {
            _ = try await CodexUsageClient.fetchUsage(credentials: creds, session: session)
            XCTFail("expected unauthorized")
        } catch let e as CodexUsageError {
            XCTAssertEqual(e, .unauthorized)
            XCTAssertFalse("\(e)".contains("SENTINEL"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testClientServerErrorOmitsBody() async {
        let creds = CodexCredentials(accessToken: "ACCESS_SENTINEL", refreshToken: nil, idToken: nil, accountId: nil)
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("SECRET_BODY".utf8))
        }
        defer { CodexStubURLProtocol.handler = nil }
        do {
            _ = try await CodexUsageClient.fetchUsage(credentials: creds, session: session)
            XCTFail("expected server error")
        } catch let e as CodexUsageError {
            if case .server(let code) = e { XCTAssertEqual(code, 503) } else { XCTFail("expected .server") }
            XCTAssertFalse("\(e)".contains("SECRET_BODY"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - CodexProvider.refreshNow()

    @MainActor
    func testProviderNoCredentials() async throws {
        let env = try makeCodexHome(authJSON: nil)
        let p = CodexProvider(environment: env, session: .shared)
        await p.refreshNow()
        XCTAssertFalse(p.runtime.isConfigured)
        XCTAssertNil(p.runtime.snapshot)
        XCTAssertNil(p.runtime.lastError)
        XCTAssertFalse(p.isConfigured)
        XCTAssertEqual(p.id, .codex)
        XCTAssertFalse(p.supportsBackgroundPolling)
    }

    @MainActor
    func testProviderSuccess() async throws {
        let env = try makeCodexHome(authJSON: #"{ "tokens": { "access_token": "ACCESS_SENTINEL" } }"#)
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{ "plan_type": "plus", "rate_limit": { "primary_window": { "used_percent": 25, "reset_at": 7, "limit_window_seconds": 18000 } } }"#.utf8))
        }
        defer { CodexStubURLProtocol.handler = nil }
        let p = CodexProvider(environment: env, session: session)
        await p.refreshNow()
        XCTAssertTrue(p.runtime.isConfigured)
        XCTAssertNil(p.runtime.lastError)
        XCTAssertNotNil(p.runtime.lastUpdated)
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct, 25)
        XCTAssertEqual(p.runtime.snapshot?.planLabel, "Plus")
    }

    @MainActor
    func testProviderUnauthorizedClearsSnapshot() async throws {
        let env = try makeCodexHome(authJSON: #"{ "tokens": { "access_token": "ACCESS_SENTINEL" } }"#)
        var status = 200
        let session = stubSession { req in
            let body = #"{ "rate_limit": { "primary_window": { "used_percent": 9, "reset_at": 1, "limit_window_seconds": 18000 } } }"#
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { CodexStubURLProtocol.handler = nil }
        let p = CodexProvider(environment: env, session: session)
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.snapshot)
        status = 401
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertFalse((p.runtime.lastError ?? "").contains("SENTINEL"))
        XCTAssertNil(p.runtime.snapshot)
    }

    @MainActor
    func testProviderServerErrorKeepsSnapshot() async throws {
        let env = try makeCodexHome(authJSON: #"{ "tokens": { "access_token": "ACCESS_SENTINEL" } }"#)
        var status = 200
        let session = stubSession { req in
            let body = #"{ "rate_limit": { "primary_window": { "used_percent": 9, "reset_at": 1, "limit_window_seconds": 18000 } } }"#
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { CodexStubURLProtocol.handler = nil }
        let p = CodexProvider(environment: env, session: session)
        await p.refreshNow()
        status = 500
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct, 9)
    }

    // MARK: - ProviderCoordinator: primaryEligibleIDs

    @MainActor
    func testCoordinatorPrimaryEligibleExcludesNonPollingProvider() throws {
        UserDefaults.standard.removeObject(forKey: ProviderCoordinator.primaryProviderKey)
        defer { UserDefaults.standard.removeObject(forKey: ProviderCoordinator.primaryProviderKey) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let claude = UsageService(credentialsStore: StoredCredentialsStore(directoryURL: dir))
        let codex = CodexProvider(environment: ["CODEX_HOME": dir.path], session: .shared)   // no auth.json → unconfigured
        let coord = ProviderCoordinator(claude: claude, additionalProviders: [codex])
        XCTAssertEqual(coord.availableIDs, [.claude, .codex])
        XCTAssertEqual(coord.primaryEligibleIDs, [.claude])
        coord.primaryProviderID = .codex
        XCTAssertEqual(coord.primaryProviderID, .claude, "非 eligible 的 primaryProviderID 应被拒绝/回退")
        XCTAssertNotEqual(UserDefaults.standard.string(forKey: ProviderCoordinator.primaryProviderKey), ProviderID.codex.rawValue)
    }
}

private final class CodexStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = CodexStubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
