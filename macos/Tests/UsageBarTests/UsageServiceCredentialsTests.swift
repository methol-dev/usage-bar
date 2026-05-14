import XCTest
@testable import UsageBar

@MainActor
final class UsageServiceCredentialsTests: XCTestCase {
    /// cache 非空且未过期 → 不调 Keychain loader
    func testEnsureFreshCredentialsCacheHit() async throws {
        let service = UsageService(usageEndpoint: URL(string: "https://example.invalid/usage")!)
        var loadCount = 0
        service.cliKeychainLoader = { _ in
            loadCount += 1
            return StoredCredentials(accessToken: "t-keychain", refreshToken: nil,
                                     expiresAt: Date().addingTimeInterval(3600),
                                     scopes: ["user:profile"])
        }
        service._test_setInMemoryCredentials(StoredCredentials(
            accessToken: "t-cache", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["user:profile"]))

        let creds = await service.ensureFreshCredentials(allowInteraction: false)
        XCTAssertEqual(creds?.accessToken, "t-cache")
        XCTAssertEqual(loadCount, 0, "keychain loader 不应被调用")
        XCTAssertTrue(service.runtime.isConfigured, "cache hit 路径也应同步 isAuthenticated")
    }

    /// cache 过期 → 调 Keychain loader 拿新 token + 写回 cache
    func testEnsureFreshCredentialsCacheExpiredReloadsKeychain() async throws {
        let service = UsageService(usageEndpoint: URL(string: "https://example.invalid/usage")!)
        var loadCount = 0
        service.cliKeychainLoader = { _ in
            loadCount += 1
            return StoredCredentials(accessToken: "t-new", refreshToken: nil,
                                     expiresAt: Date().addingTimeInterval(3600),
                                     scopes: ["user:profile"])
        }
        service._test_setInMemoryCredentials(StoredCredentials(
            accessToken: "t-stale", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(-60),
            scopes: ["user:profile"]))

        let creds = await service.ensureFreshCredentials(allowInteraction: false)
        XCTAssertEqual(creds?.accessToken, "t-new")
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(service.runtime.isConfigured)
    }

    /// Keychain loader 返回 nil → cache 清空 + isConfigured=false
    func testEnsureFreshCredentialsKeychainEmptyClearsState() async throws {
        let service = UsageService(usageEndpoint: URL(string: "https://example.invalid/usage")!)
        service.cliKeychainLoader = { _ in nil }
        service._test_setInMemoryCredentials(nil)

        let creds = await service.ensureFreshCredentials(allowInteraction: false)
        XCTAssertNil(creds)
        XCTAssertFalse(service.runtime.isConfigured)
    }

    /// 401 → 清 cache → 重读 Keychain 拿新 token → 重试一次 → 200
    func testFetchUsage401ClearsCacheAndRetriesOnce() async throws {
        let session = makeStubSession()
        let service = UsageService(session: session,
                                   usageEndpoint: URL(string: "https://example.invalid/usage")!)
        let oldToken = "t-old"; let newToken = "t-new"
        var keychainSeq = [oldToken, newToken]
        service.cliKeychainLoader = { _ in
            guard !keychainSeq.isEmpty else { return nil }
            return StoredCredentials(accessToken: keychainSeq.removeFirst(),
                                     refreshToken: nil,
                                     expiresAt: Date().addingTimeInterval(3600),
                                     scopes: ["user:profile"])
        }

        var callCount = 0
        StubProtocol.responseProvider = { _ in
            callCount += 1
            if callCount == 1 {
                return (Data("{}".utf8), HTTPURLResponse(url: URL(string: "x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            let body = #"{"fiveHour":null,"sevenDay":null,"extraUsage":null}"#
            return (Data(body.utf8), HTTPURLResponse(url: URL(string: "x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        await service.fetchUsage()
        XCTAssertEqual(callCount, 2)
        XCTAssertNil(service.lastError)
        XCTAssertTrue(service.isAuthenticated)
    }

    /// Retry 按钮 → 强制重读 Keychain (allowInteraction=true 传递确认)
    func testRetrySignInForcesKeychainReload() async throws {
        let service = UsageService(usageEndpoint: URL(string: "https://example.invalid/usage")!)
        service._test_setInMemoryCredentials(StoredCredentials(
            accessToken: "t-stale-but-not-expired",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: []))
        var receivedAllowInteraction: Bool? = nil
        service.cliKeychainLoader = { allow in
            receivedAllowInteraction = allow
            return StoredCredentials(accessToken: "t-fresh", refreshToken: nil,
                                     expiresAt: Date().addingTimeInterval(3600),
                                     scopes: [])
        }

        await service.retrySignIn()
        XCTAssertEqual(receivedAllowInteraction, true, "Retry 必须传 allowInteraction=true")
        // cache 应被强制刷新即使原 cache 没过期
        let after = await service.ensureFreshCredentials(allowInteraction: false)
        XCTAssertEqual(after?.accessToken, "t-fresh")
    }

    /// 401 → 清 cache → 重读 keychain 拿到同一个 token (CLI 没 refresh) → 不再重试 → setError 过期
    func testFetchUsage401SameTokenReportsExpired() async throws {
        let session = makeStubSession()
        let service = UsageService(session: session,
                                   usageEndpoint: URL(string: "https://example.invalid/usage")!)
        service.cliKeychainLoader = { _ in
            StoredCredentials(accessToken: "t-same", refreshToken: nil,
                              expiresAt: Date().addingTimeInterval(3600),
                              scopes: ["user:profile"])
        }
        var callCount = 0
        StubProtocol.responseProvider = { _ in
            callCount += 1
            return (Data("{}".utf8), HTTPURLResponse(url: URL(string: "x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }

        await service.fetchUsage()
        XCTAssertEqual(callCount, 1, "同 token 不应重发")
        XCTAssertEqual(service.lastError, "Token expired; run `claude` to refresh.")
        XCTAssertFalse(service.runtime.isConfigured)
    }

    private func makeStubSession() -> URLSession {
        StubProtocol.responseProvider = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

final class StubProtocol: URLProtocol {
    static var responseProvider: ((URLRequest) -> (Data, HTTPURLResponse))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let provider = Self.responseProvider else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (data, http) = provider(request)
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
