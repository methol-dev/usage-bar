import XCTest
@testable import UsageBar

/// SC7 安全约束：所有 mock JSON 用 'mock-' 前缀，不出现 'sk-ant-' 真实前缀；
/// 断言用 hasPrefix / count / nil-ness，不字面比较 token 字段（避免 framework
/// 失败时打印 raw value 至 test log）。
final class ClaudeCLICredentialsStrategyTests: XCTestCase {

    private func decode(_ json: String) throws -> ClaudeCLICredentialsStrategy.KeychainPayload {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ClaudeCLICredentialsStrategy.KeychainPayload.self, from: data)
    }

    func testValidPayloadDecodes() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"mock-access-1","refreshToken":"mock-refresh-1",\
        "expiresAt":1778520574000,"scopes":["user:profile","user:inference"]}}
        """
        let payload = try decode(json)
        XCTAssertTrue(payload.claudeAiOauth.accessToken.hasPrefix("mock-"))
        XCTAssertEqual(payload.claudeAiOauth.accessToken.count, 13)  // "mock-access-1"
        XCTAssertNotNil(payload.claudeAiOauth.refreshToken)
        XCTAssertEqual(payload.claudeAiOauth.scopes?.count, 2)
        XCTAssertEqual(payload.claudeAiOauth.expiresAt, 1778520574000)
    }

    func testMissingClaudeOauth() {
        let json = "{}"
        XCTAssertThrowsError(try decode(json))
    }

    func testMissingAccessToken() {
        let json = """
        {"claudeAiOauth":{"refreshToken":"mock-refresh-1","expiresAt":1778520574000}}
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testNilExpiresAtAndRefresh() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"mock-access-2"}}
        """
        let payload = try decode(json)
        XCTAssertTrue(payload.claudeAiOauth.accessToken.hasPrefix("mock-"))
        XCTAssertNil(payload.claudeAiOauth.refreshToken)
        XCTAssertNil(payload.claudeAiOauth.expiresAt)
        XCTAssertNil(payload.claudeAiOauth.scopes)
    }

    func testMillisecondToDateConversion() throws {
        // SC5 显式覆盖：1778520574000 ms → Date(timeIntervalSince1970: 1778520574.0)
        let json = """
        {"claudeAiOauth":{"accessToken":"mock-access-3","expiresAt":1778520574000}}
        """
        let payload = try decode(json)
        let expectedSeconds: TimeInterval = 1778520574.0
        let actual = payload.claudeAiOauth.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        XCTAssertNotNil(actual)
        XCTAssertEqual(actual!.timeIntervalSince1970, expectedSeconds, accuracy: 0.001)
    }

    // MARK: mcpOAuth-only 检测（Claude Code 2.1.x 起 Keychain 项可能只剩 mcpOAuth）

    func testMcpOAuthOnlyPayloadDetected() {
        let json = #"{"mcpOAuth":{"someServer":{"accessToken":"mock-mcp-1"}}}"#
        XCTAssertTrue(ClaudeCLICredentialsStrategy.isMcpOAuthOnlyPayload(Data(json.utf8)))
    }

    func testFullPayloadNotMcpOAuthOnly() {
        let json = #"{"claudeAiOauth":{"accessToken":"mock-access-4"},"mcpOAuth":{}}"#
        XCTAssertFalse(ClaudeCLICredentialsStrategy.isMcpOAuthOnlyPayload(Data(json.utf8)))
    }

    func testGarbagePayloadNotMcpOAuthOnly() {
        XCTAssertFalse(ClaudeCLICredentialsStrategy.isMcpOAuthOnlyPayload(Data("not json".utf8)))
    }

    // MARK: 文件回退（`~/.claude/.credentials.json` 与 Keychain payload 同 schema）

    func testLoadFromFileParsesCredentials() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-bar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".credentials.json")
        let json = """
        {"claudeAiOauth":{"accessToken":"mock-access-5","refreshToken":"mock-refresh-5",\
        "expiresAt":1778520574000,"scopes":["user:profile"]}}
        """
        try Data(json.utf8).write(to: file)

        let creds = ClaudeCLICredentialsStrategy.loadFromFile(file)
        XCTAssertNotNil(creds)
        XCTAssertTrue(creds?.accessToken.hasPrefix("mock-") ?? false)
        XCTAssertEqual(creds?.scopes, ["user:profile"])
        XCTAssertEqual(creds!.expiresAt!.timeIntervalSince1970, 1778520574.0, accuracy: 0.001)
    }

    func testLoadFromFileMissingReturnsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-bar-tests-missing-\(UUID().uuidString).json")
        XCTAssertNil(ClaudeCLICredentialsStrategy.loadFromFile(missing))
    }

    func testLoadFromFileExpiredTokenIgnored() throws {
        // 文件回退没有 refresh 能力：过期 token 必须丢弃，不能拿去反复打 401。
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-bar-tests-expired-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let expiredMs = Int64((Date().timeIntervalSince1970 - 60) * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"mock-access-6","expiresAt":\#(expiredMs)}}"#
        try Data(json.utf8).write(to: file)

        XCTAssertNil(ClaudeCLICredentialsStrategy.loadFromFile(file))
    }

    /// 端到端回退：CI 环境 Keychain 无 `Claude Code-credentials` 项（notFound/interactionNotAllowed
    /// 均属可回退类），loadCredentials 应落到注入的临时文件并成功返回。
    func testLoadCredentialsFallsBackToInjectedFile() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-bar-tests-fallback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let futureMs = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"mock-access-7","expiresAt":\#(futureMs),"scopes":["user:profile"]}}"#
        try Data(json.utf8).write(to: file)

        let strategy = ClaudeCLICredentialsStrategy(credentialsFileURL: file)
        let creds = try await strategy.loadCredentials(allowInteraction: false)
        XCTAssertNotNil(creds)
        XCTAssertTrue(creds?.accessToken.hasPrefix("mock-") ?? false)
    }

    // MARK: CLAUDE_CONFIG_DIR 环境变量覆盖（同 CodexCredentialStore.authFileURL 模式）

    func testDefaultCredentialsFileURLHonorsClaudeConfigDir() {
        let url = ClaudeCLICredentialsStrategy.defaultCredentialsFileURL(
            environment: ["CLAUDE_CONFIG_DIR": "/custom/claude-config"])
        XCTAssertEqual(url.path, "/custom/claude-config/.credentials.json")
    }

    func testDefaultCredentialsFileURLDefaultsToHomeDotClaude() {
        let url = ClaudeCLICredentialsStrategy.defaultCredentialsFileURL(environment: [:])
        XCTAssertTrue(url.path.hasSuffix("/.claude/.credentials.json"))
    }

    func testLoadErrorDescriptionDoesNotLeakRawValue() {
        // SC7 验证：LoadError 的 description 只输出 case 名，不带 OSStatus 数值
        XCTAssertEqual("\(ClaudeCLICredentialsStrategy.LoadError.keychainQueryFailed)", "keychainQueryFailed")
        XCTAssertEqual("\(ClaudeCLICredentialsStrategy.LoadError.payloadDecodeFailed)", "payloadDecodeFailed")
    }
}
