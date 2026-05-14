import XCTest
@testable import UsageBar

/// v0.5.1 task 6 后：旧的 OAuth refresh / 多账号 / Keychain 恢复测试全部下线，
/// 本文件只剩 backoff 相关三个 case；其他 fetchUsage 路径覆盖见
/// `UsageServiceCredentialsTests.swift`（in-memory + Keychain 重读路径）。
@MainActor
final class UsageServiceTests: XCTestCase {
    override func tearDown() {
        StubProtocol.responseProvider = nil
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

    /// v0.2.11：429 进 backoff → 下一次成功 fetch 清掉 backoff（nextEligibleRefresh 回到 nil）。
    /// v0.5.1：改造走新 fetchUsage —— cliKeychainLoader 注入有效 token + StubProtocol 模拟 429-then-200。
    func testFetchUsageSuccessClearsBackoff() async throws {
        let session = makeStubSession()
        let service = UsageService(
            session: session,
            usageEndpoint: URL(string: "https://example.invalid/usage")!
        )
        service.cliKeychainLoader = { _ in
            StoredCredentials(
                accessToken: "tok",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                scopes: ["user:profile"]
            )
        }

        var phase = 0   // 0 → 429；1+ → 200
        StubProtocol.responseProvider = { _ in
            if phase == 0 {
                let http = HTTPURLResponse(
                    url: URL(string: "x")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "120"]
                )!
                return (Data("{}".utf8), http)
            }
            let body = #"{"fiveHour":null,"sevenDay":null,"extraUsage":null}"#
            let http = HTTPURLResponse(
                url: URL(string: "x")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), http)
        }

        await service.fetchUsage()
        XCTAssertNotNil(service.nextEligibleRefresh, "429 后应进入 backoff 窗口")

        phase = 1
        await service.fetchUsage()
        XCTAssertNil(service.nextEligibleRefresh, "下一次成功 fetch 应清 backoff")
        XCTAssertNil(service.lastError)
    }

    // MARK: - helpers

    private func makeStubSession() -> URLSession {
        StubProtocol.responseProvider = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}
