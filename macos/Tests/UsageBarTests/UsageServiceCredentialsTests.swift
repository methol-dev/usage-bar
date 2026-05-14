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
}
