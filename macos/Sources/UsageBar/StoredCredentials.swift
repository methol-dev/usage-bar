import Foundation

struct StoredCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]

    var hasRefreshToken: Bool {
        guard let refreshToken else { return false }
        return refreshToken.isEmpty == false
    }

    func needsRefresh(at now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard hasRefreshToken, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

extension StoredCredentials {
    /// CLI 只读路径专用：返回不含 refreshToken 的副本，避免持有 CLI 的 refresh token
    /// 导致 OAuth Token Rotation 使 Claude Code 被迫退出登录（issue #22）。
    func strippingRefreshToken() -> StoredCredentials {
        StoredCredentials(accessToken: accessToken, refreshToken: nil, expiresAt: expiresAt, scopes: scopes)
    }
}

struct StoredCredentialsStore {
    // v0.1.3 G3-B2: 提升 internal 让同 module 的 multi-account extension 与测试可见
    let fileManager: FileManager
    let directoryURL: URL
    let credentialsFileURL: URL
    let legacyTokenFileURL: URL
    var accountsFileURL: URL { directoryURL.appendingPathComponent("accounts.json") }

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
        self.credentialsFileURL = directoryURL.appendingPathComponent("credentials.json")
        self.legacyTokenFileURL = directoryURL.appendingPathComponent("token")
    }

    func save(_ credentials: StoredCredentials) throws {
        try ensureDirectoryExists()
        let data = try Self.encoder.encode(credentials)
        try data.write(to: credentialsFileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFileURL.path)
        try? fileManager.removeItem(at: legacyTokenFileURL)
    }

    func load(defaultScopes: [String]) -> StoredCredentials? {
        if let data = try? Data(contentsOf: credentialsFileURL),
           let credentials = try? Self.decoder.decode(StoredCredentials.self, from: data) {
            return credentials
        }

        guard let data = try? Data(contentsOf: legacyTokenFileURL),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              token.isEmpty == false else {
            return nil
        }

        return StoredCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: nil,
            scopes: defaultScopes
        )
    }

    func delete() {
        try? fileManager.removeItem(at: credentialsFileURL)
        try? fileManager.removeItem(at: legacyTokenFileURL)
    }

    func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
