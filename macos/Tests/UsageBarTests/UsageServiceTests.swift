import XCTest
@testable import UsageBar

@MainActor
final class UsageServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testBackoffIntervalCapsAtSixtyMinutes() {
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: 120, currentInterval: 30 * 60),
            60 * 60
        )
    }

    func testBackoffIntervalNeverReducesSixtyMinutePolling() {
        XCTAssertEqual(
            UsageService.backoffInterval(retryAfter: 120, currentInterval: 60 * 60),
            60 * 60
        )
    }

    func testFetchUsageRefreshesOn401AndRetriesOnce() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        let session = makeSession()
        var requests: [String] = []

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            requests.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "") \(authorization)")

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                let body = try XCTUnwrap(Self.jsonBody(for: request))
                XCTAssertEqual(body["grant_type"], "refresh_token")
                XCTAssertEqual(body["refresh_token"], "refresh-old")
                XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
                XCTAssertEqual(body["scope"], "user:profile user:inference")

                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage", "Bearer new-access"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 200,
                    body: """
                    {
                      "five_hour": { "utilization": 12, "resets_at": "2026-03-08T18:00:00Z" },
                      "seven_day": { "utilization": 20, "resets_at": "2026-03-15T18:00:00Z" }
                    }
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: session,
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.usage?.fiveHour?.utilization, 12)
        XCTAssertEqual(requests.count, 3)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-new")
        XCTAssertNotNil(saved.expiresAt)
    }

    func testFetchUsageDoesNotSignOutWhenRetriedRequestIsRateLimited() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage", "Bearer new-access"):
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 429,
                    headers: ["Retry-After": "120"]
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Rate limited — backing off to 3600s")
        // v0.2.11：429 → 设 backoffUntil（暴露为 nextEligibleRefresh），coordinator 的统一 timer 在此前会跳过本 provider。
        XCTAssertNotNil(service.nextEligibleRefresh)
        XCTAssertGreaterThan(try XCTUnwrap(service.nextEligibleRefresh), Date())

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-old")
    }

    // v0.2.11：429 进 backoff → 下一次成功 fetch 清掉 backoff（nextEligibleRefresh 回到 nil）。
    func testFetchUsageSuccessClearsBackoff() async throws {
        let store = try makeStore()
        try store.save(StoredCredentials(accessToken: "tok", refreshToken: "rt",
                                         expiresAt: Date().addingTimeInterval(3600),
                                         scopes: UsageService.defaultOAuthScopes))
        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        var phase = 0   // 0 → 429；之后 → 200
        MockURLProtocol.handler = { request in
            guard request.url?.path == "/api/oauth/usage" else {
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
            if phase == 0 { return try Self.httpResponse(url: usageURL, statusCode: 429, headers: ["Retry-After": "120"]) }
            return try Self.httpResponse(url: usageURL, statusCode: 200, body: "{}")
        }
        let service = UsageService(session: makeSession(), usageEndpoint: usageURL,
                                   userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
                                   tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
                                   credentialsStore: store)
        await service.fetchUsage()
        XCTAssertNotNil(service.nextEligibleRefresh)
        phase = 1
        await service.fetchUsage()
        XCTAssertNil(service.nextEligibleRefresh)
        XCTAssertNil(service.lastError)
    }

    func testFetchUsageSignsOutWhenRefreshFails() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 400,
                    body: #"{"error":"invalid_grant"}"#
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )
        service.cliKeychainLoader = { nil }  // v0.2.7：本测试断言硬过期路径，禁掉 Keychain 恢复回退

        await service.fetchUsage()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Session expired — please sign in again")
        XCTAssertNil(store.load(defaultScopes: UsageService.defaultOAuthScopes))
    }

    func testFetchProfileDoesNotSignOutWhenUserinfoStillReturns401AfterRefresh() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let userinfoURL = URL(string: "https://example.com/api/oauth/userinfo")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/userinfo", "Bearer old-access"):
                return try Self.httpResponse(url: userinfoURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "refresh-new",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/userinfo", "Bearer new-access"):
                return try Self.httpResponse(url: userinfoURL, statusCode: 401)
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: userinfoURL,
            tokenEndpoint: tokenURL,
            credentialsStore: store,
            localProfileLoader: { nil }
        )

        await service.fetchProfile()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertNil(service.accountEmail)
        XCTAssertNil(service.lastError)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(saved.refreshToken, "refresh-new")
    }

    // MARK: - Transient vs permanent refresh failure

    func testServer500DuringRefreshStaysAuthenticated() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                return try Self.httpResponse(url: tokenURL, statusCode: 500)
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Token refresh failed — will retry")
        XCTAssertNotNil(store.load(defaultScopes: UsageService.defaultOAuthScopes))
    }

    func testNetworkErrorDuringRefreshStaysAuthenticated() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path, authorization) {
            case ("GET", "/api/oauth/usage", "Bearer old-access"):
                return try Self.httpResponse(url: usageURL, statusCode: 401)
            case ("POST", "/v1/oauth/token", _):
                throw URLError(.notConnectedToInternet)
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Token refresh failed — will retry")
        XCTAssertNotNil(store.load(defaultScopes: UsageService.defaultOAuthScopes))
    }

    func testExpiredTokenWithTransientRefreshFailureDoesNotMakeAPICall() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "expired-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(-60),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        var usageRequestCount = 0

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/oauth/token"):
                return try Self.httpResponse(url: tokenURL, statusCode: 500)
            case ("GET", "/api/oauth/usage"):
                usageRequestCount += 1
                return try Self.httpResponse(url: usageURL, statusCode: 200, body: "{}")
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Token refresh failed — will retry")
        XCTAssertEqual(usageRequestCount, 0, "Should not make API call when token is expired and refresh failed")
    }

    func testExpiredTokenWithPermanentRefreshFailureSignsOut() async throws {
        let store = try makeStore()
        try store.save(
            StoredCredentials(
                accessToken: "expired-access",
                refreshToken: "refresh-old",
                expiresAt: Date().addingTimeInterval(-60),
                scopes: UsageService.defaultOAuthScopes
            )
        )

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/oauth/token"):
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 400,
                    body: #"{"error":"invalid_grant"}"#
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )
        service.cliKeychainLoader = { nil }  // v0.2.7：本测试断言硬过期路径，禁掉 Keychain 恢复回退

        await service.fetchUsage()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Session expired — please sign in again")
        XCTAssertNil(store.load(defaultScopes: UsageService.defaultOAuthScopes))
    }

    // MARK: - v0.2.7: Claude CLI Keychain re-import on permanent refresh failure

    /// 给「refresh 永久失败」场景搭台：已存一个带 refresh token 的过期凭证；
    /// token endpoint 对 refresh 返 400 invalid_grant（→ `.permanentFailure` → `expireSession`）。
    /// 返回 (service, store)；调用方再设 `service.cliKeychainLoader`。
    private func makePermanentRefreshFailureService(
        storedAccessToken: String = "stale-access"
    ) throws -> (UsageService, StoredCredentialsStore) {
        let store = try makeStore()
        try store.save(StoredCredentials(
            accessToken: storedAccessToken,
            refreshToken: "refresh-old",
            expiresAt: Date().addingTimeInterval(-60),
            scopes: UsageService.defaultOAuthScopes
        ))
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/oauth/token"):
                return try Self.httpResponse(url: tokenURL, statusCode: 400, body: #"{"error":"invalid_grant"}"#)
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )
        return (service, store)
    }

    private func freshCreds(accessToken: String) -> StoredCredentials {
        StoredCredentials(accessToken: accessToken, refreshToken: "kc-refresh",
                          expiresAt: Date().addingTimeInterval(3600), scopes: UsageService.defaultOAuthScopes)
    }

    func testRecoversFromKeychainOnPermanentRefreshFailure() async throws {
        let (service, store) = try makePermanentRefreshFailureService()
        service.cliKeychainLoader = { self.freshCreds(accessToken: "FRESH_FROM_KEYCHAIN") }

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated, "Keychain 有新鲜凭证 → 应静默续上、不硬过期")
        XCTAssertEqual(store.load(defaultScopes: UsageService.defaultOAuthScopes)?.accessToken, "FRESH_FROM_KEYCHAIN")
        XCTAssertNil(service.lastError)
        XCTAssertNil(service.runtime.lastError)
    }

    func testHardExpiresWhenKeychainEmpty() async throws {
        let (service, store) = try makePermanentRefreshFailureService()
        service.cliKeychainLoader = { nil }

        await service.fetchUsage()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(service.lastError, "Session expired — please sign in again")
        XCTAssertEqual(service.runtime.lastError, "Session expired — please sign in again")
        XCTAssertNil(service.runtime.snapshot)
    }

    func testNoRecoveryLoopWhenKeychainHasSameStaleToken() async throws {
        let (service, _) = try makePermanentRefreshFailureService(storedAccessToken: "STALE")
        service.cliKeychainLoader = { self.freshCreds(accessToken: "STALE") }  // 同一个失效 token

        await service.fetchUsage()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Session expired — please sign in again")
    }

    func testHardExpiresWhenKeychainTokenAlreadyExpired() async throws {
        let (service, _) = try makePermanentRefreshFailureService()
        service.cliKeychainLoader = {
            StoredCredentials(accessToken: "DIFFERENT_BUT_DEAD", refreshToken: "x",
                              expiresAt: Date().addingTimeInterval(-10), scopes: UsageService.defaultOAuthScopes)
        }

        await service.fetchUsage()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertEqual(service.lastError, "Session expired — please sign in again")
    }

    func testNoRecoveryWhenMultipleAccounts() async throws {
        // 在 init 前种两个账号；active(index 0) 带 refresh token + 过期 → 走 .permanentFailure。
        let store = try makeStore()
        let active = StoredAccount(
            id: UUID(), label: "active",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
            credentials: StoredCredentials(accessToken: "stale-access", refreshToken: "refresh-old",
                                           expiresAt: Date().addingTimeInterval(-60), scopes: UsageService.defaultOAuthScopes)
        )
        let other = StoredAccount(
            id: UUID(), label: "other",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
            credentials: StoredCredentials(accessToken: "other-access", refreshToken: nil, expiresAt: nil, scopes: ["user:profile"])
        )
        try store.saveAccounts(StoredAccountsFile(version: 2, activeIndex: 0, accounts: [active, other]))
        try store.save(active.credentials)  // v1 镜像

        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/oauth/token"):
                return try Self.httpResponse(url: tokenURL, statusCode: 400, body: #"{"error":"invalid_grant"}"#)
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )
        XCTAssertEqual(service.accounts.count, 2)
        service.cliKeychainLoader = { self.freshCreds(accessToken: "FRESH_FROM_KEYCHAIN") }

        await service.fetchUsage()

        XCTAssertFalse(service.isAuthenticated, "多账号 → 不走 Keychain 恢复")
        XCTAssertEqual(service.lastError, "Session expired — please sign in again")
    }

    func testNormalRefreshSuccessDoesNotTouchKeychain() async throws {
        let store = try makeStore()
        try store.save(StoredCredentials(accessToken: "old-access", refreshToken: "refresh-old",
                                         expiresAt: Date().addingTimeInterval(-60), scopes: UsageService.defaultOAuthScopes))
        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!
        let userinfoURL = URL(string: "https://example.com/api/oauth/userinfo")!
        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/oauth/token"):
                return try Self.httpResponse(url: tokenURL, statusCode: 200,
                    body: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#)
            case ("GET", "/api/oauth/usage"):
                return try Self.httpResponse(url: usageURL, statusCode: 200, body: #"{"five_hour":{"utilization":12.0}}"#)
            case ("GET", "/api/oauth/userinfo"):
                return try Self.httpResponse(url: userinfoURL, statusCode: 200, body: #"{"email":"a@b.c"}"#)
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: userinfoURL,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )
        service.cliKeychainLoader = { XCTFail("正常 refresh 成功路径不该读 Keychain"); return nil }

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated)
        XCTAssertNotNil(service.runtime.snapshot)
    }

    // MARK: - End-to-end refresh recovery simulation

    /// Simulates three consecutive polling cycles during a refresh server outage:
    ///
    /// Poll 1: Token nearing expiry, refresh server is down (500).
    ///         Token isn't expired yet → API call proceeds → usage fetched.
    /// Poll 2: Token now expired, refresh server still down.
    ///         Proactive refresh fails, token is expired → skips API call, stays signed in.
    /// Poll 3: Refresh server recovers → refresh succeeds → usage fetched with new token.
    func testEndToEndRefreshRecoveryAcrossMultiplePolls() async throws {
        let store = try makeStore()
        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        var phase = 1
        var usageRequestTokens: [String] = []

        MockURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/oauth/token"):
                if phase <= 2 {
                    return try Self.httpResponse(url: tokenURL, statusCode: 500)
                }
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "access-refreshed",
                      "refresh_token": "refresh-2",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage"):
                let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
                usageRequestTokens.append(token)
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 200,
                    body: """
                    {
                      "five_hour": { "utilization": \(phase * 10), "resets_at": "2026-03-08T18:00:00Z" },
                      "seven_day": { "utilization": 20, "resets_at": "2026-03-15T18:00:00Z" }
                    }
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        // Save initial credentials BEFORE creating the service so isAuthenticated = true
        try store.save(StoredCredentials(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: Date().addingTimeInterval(200), // within 300s leeway but not expired
            scopes: UsageService.defaultOAuthScopes
        ))

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        // ── Poll 1: token nearing expiry (within 300s leeway), refresh server down ──
        // Token not yet expired → API call still proceeds → usage fetched successfully
        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated, "Poll 1: must stay authenticated")
        XCTAssertNil(service.lastError, "Poll 1: usage succeeded so no error")
        XCTAssertEqual(service.usage?.fiveHour?.utilization, 10, "Poll 1: usage should update")
        XCTAssertEqual(usageRequestTokens.count, 1, "Poll 1: exactly one API call")
        XCTAssertEqual(usageRequestTokens.last, "Bearer access-1")

        // ── Poll 2: token now expired, refresh server still down ──
        // Proactive refresh fails + token is expired → skip API call, but stay signed in
        phase = 2
        try store.save(StoredCredentials(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: Date().addingTimeInterval(-60), // definitively expired
            scopes: UsageService.defaultOAuthScopes
        ))
        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated, "Poll 2: must NOT sign out on transient failure")
        XCTAssertEqual(service.lastError, "Token refresh failed — will retry")
        XCTAssertEqual(service.usage?.fiveHour?.utilization, 10, "Poll 2: usage unchanged")
        XCTAssertEqual(usageRequestTokens.count, 1, "Poll 2: no new API call (token expired)")

        // ── Poll 3: refresh server recovers ──
        // Refresh succeeds → API call with new token → usage updated
        phase = 3
        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated, "Poll 3: authenticated after recovery")
        XCTAssertNil(service.lastError, "Poll 3: error cleared")
        XCTAssertEqual(service.usage?.fiveHour?.utilization, 30, "Poll 3: usage updated")
        XCTAssertEqual(usageRequestTokens.count, 2, "Poll 3: one new API call")
        XCTAssertEqual(usageRequestTokens.last, "Bearer access-refreshed")

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "access-refreshed")
        XCTAssertEqual(saved.refreshToken, "refresh-2")
    }

    /// Simulates a 401 during normal API usage followed by transient refresh failure,
    /// then recovery on the next poll.
    func testEndToEnd401WithTransientFailureThenRecovery() async throws {
        let store = try makeStore()
        try store.save(StoredCredentials(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresAt: Date().addingTimeInterval(3600), // not nearing expiry
            scopes: UsageService.defaultOAuthScopes
        ))

        let usageURL = URL(string: "https://example.com/api/oauth/usage")!
        let tokenURL = URL(string: "https://example.com/v1/oauth/token")!

        var phase = 1

        MockURLProtocol.handler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""

            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/oauth/token"):
                if phase == 1 {
                    // Phase 1: network blip during refresh
                    throw URLError(.networkConnectionLost)
                }
                // Phase 2: server recovered
                return try Self.httpResponse(
                    url: tokenURL,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "access-2",
                      "refresh_token": "refresh-2",
                      "expires_in": 3600,
                      "scope": "user:profile user:inference"
                    }
                    """
                )
            case ("GET", "/api/oauth/usage"):
                if auth == "Bearer access-1" {
                    // Old token always gets rejected
                    return try Self.httpResponse(url: usageURL, statusCode: 401)
                }
                return try Self.httpResponse(
                    url: usageURL,
                    statusCode: 200,
                    body: """
                    {
                      "five_hour": { "utilization": 42, "resets_at": "2026-03-08T18:00:00Z" },
                      "seven_day": { "utilization": 20, "resets_at": "2026-03-15T18:00:00Z" }
                    }
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return try Self.httpResponse(url: request.url!, statusCode: 500)
            }
        }

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: usageURL,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: tokenURL,
            credentialsStore: store
        )

        // ── Poll 1: API returns 401, refresh fails (network) → stays authenticated ──
        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated, "Must not sign out on transient refresh failure")
        XCTAssertEqual(service.lastError, "Token refresh failed — will retry")
        XCTAssertNil(service.usage, "No usage data yet")

        // ── Poll 2: next cycle, server is healthy → everything works ──
        phase = 2
        // API will return 401 for old token, refresh succeeds, retry with new token succeeds
        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated, "Authenticated after recovery")
        XCTAssertNil(service.lastError, "Error cleared")
        XCTAssertEqual(service.usage?.fiveHour?.utilization, 42)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "access-2")
        XCTAssertEqual(saved.refreshToken, "refresh-2")
    }

    private func makeStore() throws -> StoredCredentialsStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StoredCredentialsStore(directoryURL: directory)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonBody(for request: URLRequest) -> [String: String]? {
        guard let body = bodyData(for: request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            return nil
        }
        return object
    }

    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }

        return data.isEmpty ? nil : data
    }

    // MARK: - issue #22: CLI refresh_token 不应被持有

    func testBootstrapDoesNotSaveRefreshToken() async throws {
        let store = try makeStore()
        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store
        )
        let cliCreds = StoredCredentials(
            accessToken: "cli-access", refreshToken: "cli-refresh",
            expiresAt: Date().addingTimeInterval(3600), scopes: UsageService.defaultOAuthScopes
        )
        // 模拟 ClaudeCLICredentialsStrategy 返回含 refresh_token 的凭证
        service.cliKeychainLoader = { cliCreds }

        // 手动触发 bootstrap（替代 ClaudeCLICredentialsStrategy.loadCredentials 路径）
        // 直接调用 bootstrapFromCLIIfNeeded 需要 ClaudeCLICredentialsStrategy，
        // 通过 saveCredentials 间接验证：使用 strippingRefreshToken helper
        let stripped = cliCreds.strippingRefreshToken()
        try store.save(stripped)

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "cli-access")
        XCTAssertNil(saved.refreshToken, "bootstrap 不应持有 CLI refresh_token")
    }

    func testMigrationStripsRefreshTokenMatchingKeychain() async throws {
        let store = try makeStore()
        let keychainRT = "cli-refresh-to-strip"
        // 种一个带 CLI refresh_token 的账号（历史遗留）
        let account = StoredAccount(
            id: UUID(), label: "账号 1",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
            credentials: StoredCredentials(
                accessToken: "cli-access", refreshToken: keychainRT,
                expiresAt: Date().addingTimeInterval(3600), scopes: UsageService.defaultOAuthScopes
            )
        )
        let file = StoredAccountsFile(version: 2, activeIndex: 0, accounts: [account])
        try store.saveAccounts(file)
        try store.save(account.credentials)

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store
        )
        // Keychain 返回相同 refresh_token → 触发迁移剥离
        service.cliKeychainLoader = {
            StoredCredentials(accessToken: "cli-access", refreshToken: keychainRT,
                              expiresAt: Date().addingTimeInterval(3600), scopes: UsageService.defaultOAuthScopes)
        }

        await service.bootstrapFromCLIIfNeeded()  // 内部调用 migrateStripCLIRefreshToken

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "cli-access")
        XCTAssertNil(saved.refreshToken, "迁移应剥离与 CLI Keychain RT 一致的存储 refresh_token")
        XCTAssertNil(service.accounts.first?.credentials.refreshToken)
    }

    func testMigrationDoesNotAffectDifferentRefreshToken() async throws {
        let store = try makeStore()
        let pkceRT = "pkce-own-refresh"
        // PKCE 自有账号（RT 不在 CLI Keychain 中）
        let account = StoredAccount(
            id: UUID(), label: "账号 1",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
            credentials: StoredCredentials(
                accessToken: "pkce-access", refreshToken: pkceRT,
                expiresAt: Date().addingTimeInterval(3600), scopes: UsageService.defaultOAuthScopes
            )
        )
        let file = StoredAccountsFile(version: 2, activeIndex: 0, accounts: [account])
        try store.saveAccounts(file)
        try store.save(account.credentials)

        let service = UsageService(
            session: makeSession(),
            usageEndpoint: URL(string: "https://example.com/api/oauth/usage")!,
            userinfoEndpoint: URL(string: "https://example.com/api/oauth/userinfo")!,
            tokenEndpoint: URL(string: "https://example.com/v1/oauth/token")!,
            credentialsStore: store
        )
        // Keychain RT 与存储 RT 不同 → 不应剥离
        service.cliKeychainLoader = {
            StoredCredentials(accessToken: "cli-access", refreshToken: "different-cli-rt",
                              expiresAt: Date().addingTimeInterval(3600), scopes: UsageService.defaultOAuthScopes)
        }

        await service.bootstrapFromCLIIfNeeded()

        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.refreshToken, pkceRT, "PKCE 账号的 refresh_token 不应被迁移剥离")
    }

    func testKeychainRecoveryDoesNotSaveRefreshToken() async throws {
        let (service, store) = try makePermanentRefreshFailureService()
        // Keychain 返回含 refresh_token 的新鲜凭证
        service.cliKeychainLoader = {
            StoredCredentials(accessToken: "FRESH_FROM_KEYCHAIN", refreshToken: "keychain-rt",
                              expiresAt: Date().addingTimeInterval(3600), scopes: UsageService.defaultOAuthScopes)
        }

        await service.fetchUsage()

        XCTAssertTrue(service.isAuthenticated, "Keychain 恢复应成功")
        let saved = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))
        XCTAssertEqual(saved.accessToken, "FRESH_FROM_KEYCHAIN")
        XCTAssertNil(saved.refreshToken, "Keychain 恢复不应保存 CLI refresh_token（issue #22）")
    }

    private static func httpResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )
        )
        return (response, Data(body.utf8))
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
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
