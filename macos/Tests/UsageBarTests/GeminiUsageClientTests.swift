import XCTest
@testable import UsageBar

final class GeminiUsageClientTests: XCTestCase {

    private func stubSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        GeminiAPIStubURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GeminiAPIStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeCreds() -> GeminiCredentials {
        GeminiCredentials(accessToken: "ACCESS_SENTINEL", refreshToken: "R", tokenType: "Bearer",
                          expiryDate: Date().addingTimeInterval(3600), idToken: nil, scope: nil)
    }

    func testLoadCodeAssistSuccess() async throws {
        let session = stubSession { req in
            XCTAssertEqual(req.url?.host, "cloudcode-pa.googleapis.com")
            XCTAssertEqual(req.url?.path, "/v1internal:loadCodeAssist")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ACCESS_SENTINEL")
            let body = #"{"cloudaicompanionProject":"my-proj-123","currentTier":{"id":"free"}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        let result = try await GeminiUsageClient.loadCodeAssist(credentials: makeCreds(), session: session)
        XCTAssertEqual(result.projectId, "my-proj-123")
        XCTAssertEqual(result.tier, "free")
    }

    func testRetrieveUserQuotaSuccess() async throws {
        let session = stubSession { req in
            XCTAssertEqual(req.url?.path, "/v1internal:retrieveUserQuota")
            // URLProtocol path 的 body 可能在 httpBodyStream;读 stream 兜底(同 Task 3 经验)
            let body: String = {
                if let body = req.httpBody { return String(data: body, encoding: .utf8) ?? "" }
                if let stream = req.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let n = stream.read(&buf, maxLength: buf.count)
                        if n <= 0 { break }; data.append(buf, count: n)
                    }
                    return String(data: data, encoding: .utf8) ?? ""
                }
                return ""
            }()
            XCTAssertTrue(body.contains("\"project\":\"my-proj-123\""))
            let resp = #"{"userQuota":[{"model":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2026-05-14T00:00:00Z"}]}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        let resp = try await GeminiUsageClient.retrieveUserQuota(credentials: makeCreds(), projectId: "my-proj-123", session: session)
        XCTAssertEqual(resp.userQuota.count, 1)
        XCTAssertEqual(resp.userQuota.first?.model, "gemini-2.5-pro")
    }

    func testUnauthorizedThrows() async {
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        do {
            _ = try await GeminiUsageClient.loadCodeAssist(credentials: makeCreds(), session: session)
            XCTFail("expected unauthorized")
        } catch GeminiUsageError.unauthorized {
            // ok
        } catch { XCTFail("wrong: \(error)") }
    }

    func testServerErrorOmitsBody() async {
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("SECRET_BODY".utf8))
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        do {
            _ = try await GeminiUsageClient.loadCodeAssist(credentials: makeCreds(), session: session)
            XCTFail("expected server")
        } catch let e as GeminiUsageError {
            if case .server(let s) = e { XCTAssertEqual(s, 503) } else { XCTFail("expected .server") }
            XCTAssertFalse("\(e)".contains("SECRET_BODY"))
            XCTAssertFalse("\(e)".contains("SENTINEL"))
        } catch { XCTFail("wrong: \(error)") }
    }

    func testLoadCodeAssistMissingProjectThrows() async {
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"currentTier":{"id":"free"}}"#.utf8))
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        do {
            _ = try await GeminiUsageClient.loadCodeAssist(credentials: makeCreds(), session: session)
            XCTFail("expected missing project")
        } catch GeminiUsageError.missingProject {
            // ok
        } catch { XCTFail("wrong: \(error)") }
    }
}

private final class GeminiAPIStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = GeminiAPIStubURLProtocol.handler else {
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
