import XCTest
@testable import UsageBar

final class GeminiCredentialsTests: XCTestCase {

    private func makeGeminiHome(credsJSON: String?) throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let credsJSON {
            try Data(credsJSON.utf8).write(to: dir.appendingPathComponent("oauth_creds.json"))
        }
        return ["GEMINI_HOME": dir.path]
    }

    func testLoadAllFields() throws {
        let env = try makeGeminiHome(credsJSON: """
        { "access_token": "ACCESS_SENTINEL",
          "refresh_token": "REFRESH_SENTINEL",
          "token_type": "Bearer",
          "expiry_date": 1750000000000,
          "id_token": "ID_SENTINEL",
          "scope": "https://www.googleapis.com/auth/cloud-platform" }
        """)
        let creds = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        XCTAssertEqual(creds.accessToken, "ACCESS_SENTINEL")
        XCTAssertEqual(creds.refreshToken, "REFRESH_SENTINEL")
        XCTAssertEqual(creds.tokenType, "Bearer")
        XCTAssertEqual(creds.expiryDate, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(creds.idToken, "ID_SENTINEL")
        XCTAssertEqual(creds.scope, "https://www.googleapis.com/auth/cloud-platform")
    }

    func testLoadMinimalFields() throws {
        let env = try makeGeminiHome(credsJSON: """
        { "access_token": "ACCESS_SENTINEL", "token_type": "Bearer" }
        """)
        let creds = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        XCTAssertEqual(creds.accessToken, "ACCESS_SENTINEL")
        XCTAssertNil(creds.refreshToken)
        XCTAssertNil(creds.expiryDate)
    }

    func testLoadMissingAccessTokenThrows() throws {
        let env = try makeGeminiHome(credsJSON: #"{ "refresh_token": "R" }"#)
        XCTAssertThrowsError(try GeminiCredentialStore.load(environment: env)) { error in
            XCTAssertTrue(error is GeminiCredentialError)
        }
    }

    func testLoadInvalidJSONThrows() throws {
        let env = try makeGeminiHome(credsJSON: "not json {{{")
        XCTAssertThrowsError(try GeminiCredentialStore.load(environment: env))
    }

    func testLoadFileAbsentReturnsNil() throws {
        let env = try makeGeminiHome(credsJSON: nil)
        XCTAssertNil(try GeminiCredentialStore.load(environment: env))
    }

    func testLoadRespectsGeminiHome() throws {
        let env = try makeGeminiHome(credsJSON: #"{ "access_token": "A", "token_type": "Bearer" }"#)
        XCTAssertNotNil(try GeminiCredentialStore.load(environment: env))
        XCTAssertEqual(GeminiCredentialStore.credsFileURL(environment: env).lastPathComponent, "oauth_creds.json")
        XCTAssertTrue(GeminiCredentialStore.credsFileURL(environment: env).path.hasPrefix(env["GEMINI_HOME"]!))
    }

    func testCredentialErrorDescriptionHasNoRawValues() {
        for e in [GeminiCredentialError.malformed, GeminiCredentialError.missingAccessToken] {
            let s = "\(e)"
            XCTAssertFalse(s.contains("SENTINEL"))
            XCTAssertFalse(s.contains("{"))
        }
    }
}

extension GeminiCredentialsTests {

    private func stubSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        GeminiOAuthStubURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GeminiOAuthStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// URLSession 走 URLProtocol 时 POST 的 `httpBody` 常被转成 `httpBodyStream`，这里兜底两端。
    fileprivate static func bodyString(from req: URLRequest) -> String {
        if let d = req.httpBody { return String(data: d, encoding: .utf8) ?? "" }
        guard let stream = req.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var collected = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: 4096)
            if n <= 0 { break }
            collected.append(buf, count: n)
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    func testRefreshSuccessUpdatesAccessTokenAndExpiry() async throws {
        let env = try makeGeminiHome(credsJSON: """
        { "access_token": "OLD", "refresh_token": "REFRESH_SENTINEL", "token_type": "Bearer" }
        """)
        let session = stubSession { req in
            XCTAssertEqual(req.url?.absoluteString, "https://oauth2.googleapis.com/token")
            XCTAssertEqual(req.httpMethod, "POST")
            let body = GeminiCredentialsTests.bodyString(from: req)
            XCTAssertTrue(body.contains("refresh_token=REFRESH_SENTINEL"))
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("client_id=CID"))
            XCTAssertTrue(body.contains("client_secret=CSEC"))
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}"#.utf8))
        }
        defer { GeminiOAuthStubURLProtocol.handler = nil }

        let old = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        let updated = try await GeminiCredentialStore.refresh(credentials: old, clientId: "CID", clientSecret: "CSEC", session: session, environment: env)
        XCTAssertEqual(updated.accessToken, "NEW")
        XCTAssertEqual(updated.refreshToken, "REFRESH_SENTINEL", "refresh_token 未变（响应里没回则保留）")
        XCTAssertNotNil(updated.expiryDate)

        // 写回后再 load，应是新值。
        let reloaded = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        XCTAssertEqual(reloaded.accessToken, "NEW")
    }

    func testRefreshUnauthorizedThrows() async throws {
        let env = try makeGeminiHome(credsJSON: #"{ "access_token": "OLD", "refresh_token": "R", "token_type": "Bearer" }"#)
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        defer { GeminiOAuthStubURLProtocol.handler = nil }
        let old = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        do {
            _ = try await GeminiCredentialStore.refresh(credentials: old, clientId: "CID", clientSecret: "CSEC", session: session, environment: env)
            XCTFail("expected unauthorized")
        } catch GeminiRefreshError.unauthorized {
            // ok
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRefreshMissingRefreshTokenThrows() async throws {
        let env = try makeGeminiHome(credsJSON: #"{ "access_token": "OLD", "token_type": "Bearer" }"#)
        let old = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        do {
            _ = try await GeminiCredentialStore.refresh(credentials: old, clientId: "CID", clientSecret: "CSEC", session: .shared, environment: env)
            XCTFail("expected missingRefreshToken")
        } catch GeminiRefreshError.missingRefreshToken {
            // ok
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRefreshAtomicWriteDoesNotLeavePartialFile() async throws {
        let env = try makeGeminiHome(credsJSON: #"{ "access_token": "OLD", "refresh_token": "R", "token_type": "Bearer" }"#)
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}"#.utf8))
        }
        defer { GeminiOAuthStubURLProtocol.handler = nil }
        let old = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        _ = try await GeminiCredentialStore.refresh(credentials: old, clientId: "CID", clientSecret: "CSEC", session: session, environment: env)
        // 临时文件不应残留
        let dir = URL(fileURLWithPath: env["GEMINI_HOME"]!)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("oauth_creds.json.") }
        XCTAssertTrue(leftovers.isEmpty, "残留临时文件：\(leftovers)")
    }
}

// 复用一个 URLProtocol stub（避免与其它 test 类的 stub 冲突）
private final class GeminiOAuthStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = GeminiOAuthStubURLProtocol.handler else {
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
