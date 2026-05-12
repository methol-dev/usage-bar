import XCTest
@testable import ClaudeUsageBar

@MainActor
final class UsageServiceMultiAccountTests: XCTestCase {
    private var tempDir: URL!
    private var store: StoredCredentialsStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("multi-acc-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = StoredCredentialsStore(directoryURL: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func makeAccount(label: String, token: String = "mock-token") -> StoredAccount {
        StoredAccount(
            id: UUID(),
            label: label,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
            credentials: StoredCredentials(accessToken: token, refreshToken: nil, expiresAt: nil, scopes: ["user:profile"])
        )
    }

    private func makeService() -> UsageService {
        UsageService(credentialsStore: store, localProfileLoader: { nil })
    }

    func testInitLoadsAccountsFromV2File() throws {
        let a = makeAccount(label: "first")
        let b = makeAccount(label: "second")
        let file = StoredAccountsFile(version: 2, activeIndex: 1, accounts: [a, b])
        try store.saveAccounts(file)
        // 双写：v1 镜像
        try store.save(b.credentials)

        let service = makeService()
        XCTAssertEqual(service.accounts.count, 2)
        XCTAssertEqual(service.activeAccountId, b.id)
        XCTAssertTrue(service.isAuthenticated)
    }

    func testInitMigratesFromV1() throws {
        try store.save(StoredCredentials(accessToken: "mock-v1", refreshToken: nil, expiresAt: nil, scopes: ["user:profile"]))

        let service = makeService()
        XCTAssertEqual(service.accounts.count, 1)
        XCTAssertEqual(service.accounts.first?.label, "账号 1")
        XCTAssertTrue(service.isAuthenticated)
    }

    func testInitEmptyAccountsUnauthenticated() {
        let service = makeService()
        XCTAssertTrue(service.accounts.isEmpty)
        XCTAssertNil(service.activeAccountId)
        XCTAssertFalse(service.isAuthenticated)
    }

    func testSwitchAccountClearsTransientState() throws {
        let a = makeAccount(label: "A", token: "mock-A")
        let b = makeAccount(label: "B", token: "mock-B")
        let file = StoredAccountsFile(version: 2, activeIndex: 0, accounts: [a, b])
        try store.saveAccounts(file)
        try store.save(a.credentials)

        let service = makeService()
        XCTAssertEqual(service.activeAccountId, a.id)
        // 模拟前账号瞬态数据
        service.lastError = "stale"

        service.switchAccount(to: b.id)

        XCTAssertEqual(service.activeAccountId, b.id)
        XCTAssertNil(service.usage)
        XCTAssertNil(service.lastError)
        XCTAssertNil(service.accountEmail)
        // 本机 JSONL 统计跨账号不清（spec 2026-05-12 §5 风险12）
    }

    func testSwitchAccountUpdatesLastUsed() throws {
        let a = makeAccount(label: "A")
        let b = makeAccount(label: "B")
        let file = StoredAccountsFile(version: 2, activeIndex: 0, accounts: [a, b])
        try store.saveAccounts(file)
        try store.save(a.credentials)

        let service = makeService()
        let bLastUsedBefore = service.accounts[1].lastUsed
        service.switchAccount(to: b.id)
        // lastUsed 应更新到 ≥ 测试开始时间
        let bLastUsedAfter = service.accounts[1].lastUsed
        XCTAssertGreaterThan(bLastUsedAfter, bLastUsedBefore)
    }

    func testSwitchAccountInvalidIdNoop() throws {
        let a = makeAccount(label: "A")
        let file = StoredAccountsFile(version: 2, activeIndex: 0, accounts: [a])
        try store.saveAccounts(file)
        try store.save(a.credentials)

        let service = makeService()
        let originalActive = service.activeAccountId
        service.switchAccount(to: UUID())  // unknown id
        XCTAssertEqual(service.activeAccountId, originalActive, "Unknown id should noop")
    }

    func testActiveIndexOutOfBoundClampedToLast() throws {
        let a = makeAccount(label: "A")
        let b = makeAccount(label: "B")
        // activeIndex 越界
        let file = StoredAccountsFile(version: 2, activeIndex: 99, accounts: [a, b])
        try store.saveAccounts(file)

        let service = makeService()
        // clamp 到 last (索引 1 = b)
        XCTAssertEqual(service.activeAccountId, b.id)
    }

    func testSignOutClearsAllAccounts() throws {
        let a = makeAccount(label: "A")
        let b = makeAccount(label: "B")
        let file = StoredAccountsFile(version: 2, activeIndex: 0, accounts: [a, b])
        try store.saveAccounts(file)
        try store.save(a.credentials)

        let service = makeService()
        XCTAssertEqual(service.accounts.count, 2)

        service.signOut()
        XCTAssertTrue(service.accounts.isEmpty)
        XCTAssertNil(service.activeAccountId)
        XCTAssertFalse(service.isAuthenticated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.accountsFileURL.path))
    }
}
