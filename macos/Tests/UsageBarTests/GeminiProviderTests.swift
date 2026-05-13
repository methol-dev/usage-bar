import XCTest
@testable import UsageBar

final class GeminiProviderTests: XCTestCase {

    private func makeGeminiHome(credsJSON: String?) throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let credsJSON {
            try Data(credsJSON.utf8).write(to: dir.appendingPathComponent("oauth_creds.json"))
        }
        return ["GEMINI_HOME": dir.path]
    }

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stubSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        GeminiProviderStubURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GeminiProviderStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// fake locator 总是返回固定值（避开真机三处枚举）
    private final class FakeLocator: GeminiClientLocating {
        let result: GeminiOAuthClientLocator.Result?
        init(_ r: GeminiOAuthClientLocator.Result? = .init(clientId: "CID", clientSecret: "CSEC")) { self.result = r }
        func findClientIdSecret() -> GeminiOAuthClientLocator.Result? { result }
    }

    private func successQuotaJSON() -> String {
        #"{"userQuota":[{"model":"gemini-2.5-pro","remainingFraction":0.7,"resetTime":"2026-05-14T00:00:00Z"},{"model":"gemini-2.5-flash","remainingFraction":0.4,"resetTime":"2026-05-14T00:00:00Z"}]}"#
    }

    @MainActor
    func testNoCredentials() async throws {
        let env = try makeGeminiHome(credsJSON: nil)
        let p = GeminiProvider(environment: env, session: .shared, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertFalse(p.runtime.isConfigured)
        XCTAssertNil(p.runtime.snapshot)
        XCTAssertEqual(p.id, .gemini)
    }

    @MainActor
    func testNoOAuthClientGoesUnconfigured() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let p = GeminiProvider(environment: env, session: .shared, locator: FakeLocator(nil))
        await p.refreshNow()
        XCTAssertFalse(p.runtime.isConfigured)
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertTrue(p.runtime.lastError?.contains("gemini-cli") == true)
    }

    @MainActor
    func testSuccessFullFlow() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/v1internal:loadCodeAssist" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P","currentTier":{"id":"free"}}"#.utf8))
            }
            if path == "/v1internal:retrieveUserQuota" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(self.successQuotaJSON().utf8))
            }
            XCTFail("unexpected path: \(path)")
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertTrue(p.runtime.isConfigured)
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.label, "Pro")
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct ?? -1, 30, accuracy: 1e-6)
        XCTAssertEqual(p.runtime.snapshot?.secondaryWindow?.label, "Flash")
    }

    @MainActor
    func testUnauthorizedTriggersRefreshAndRetry() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"OLD","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        var loadCalls = 0
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}"#.utf8))
            }
            if path == "/v1internal:loadCodeAssist" {
                loadCalls += 1
                if loadCalls == 1 {
                    return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
                }
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer NEW", "重试时应带新 token")
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P","currentTier":{"id":"free"}}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(self.successQuotaJSON().utf8))
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertTrue(p.runtime.isConfigured)
        XCTAssertNotNil(p.runtime.snapshot)
    }

    @MainActor
    func testUnauthorizedRefreshFailsClearsSnapshot() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"OLD","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let session = stubSession { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertNil(p.runtime.snapshot)
        XCTAssertTrue(p.runtime.lastError?.contains("过期") == true || p.runtime.lastError?.contains("登录") == true)
    }

    @MainActor
    func testServerErrorKeepsSnapshot() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        var status = 200
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/v1internal:loadCodeAssist" {
                return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    Data(self.successQuotaJSON().utf8))
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.snapshot)
        status = 500
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.snapshot, "5xx 应保留旧 snapshot")
        XCTAssertNotNil(p.runtime.lastError)
    }

    @MainActor
    func testHistorySampleRecorded() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/v1internal:loadCodeAssist" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(self.successQuotaJSON().utf8))
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let h = UsageHistoryService(filename: "g.json", directory: try makeTmpDir())
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator(), history: h)
        await p.refreshNow()
        XCTAssertEqual(h.history.dataPoints.count, 1)
        // Pro remainingFraction 0.7 → utilization 30% → unit 0.30
        XCTAssertEqual(h.history.dataPoints.first?.pct5h ?? -1, 0.30, accuracy: 1e-6)
        // Flash 0.4 → 60% → 0.60
        XCTAssertEqual(h.history.dataPoints.first?.pct7d ?? -1, 0.60, accuracy: 1e-6)
    }

    @MainActor
    func testRefreshNowIsNotReentrant() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/v1internal:loadCodeAssist" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(self.successQuotaJSON().utf8))
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let h = UsageHistoryService(filename: "g.json", directory: try makeTmpDir())
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator(), history: h)
        async let a: Void = p.refreshNow()
        async let b: Void = p.refreshNow()
        _ = await (a, b)
        XCTAssertEqual(h.history.dataPoints.count, 1, "重入闸门：并发 refreshNow 只记一个点")
    }
}

private final class GeminiProviderStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = GeminiProviderStubURLProtocol.handler else {
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
