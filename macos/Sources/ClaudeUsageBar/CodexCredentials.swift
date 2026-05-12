import Foundation

/// 从本机 `codex` CLI 已登录的 `~/.codex/auth.json` 读出来的凭证（**只读**——本类型永不创建/写回该文件）。
/// 两种形态：① 顶层 `OPENAI_API_KEY` → 直接当 bearer，无 refresh/account；② `tokens.{access_token,…}` OAuth。
struct CodexCredentials: Equatable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountId: String?
}

/// SC7：case 名只描述「形态问题」，不带 raw 值 / 不带可二次解析的码。
enum CodexCredentialError: Error, CustomStringConvertible {
    case malformed        // 文件存在但 JSON 解析失败
    case missingTokens    // JSON 合法但既无 OPENAI_API_KEY 又无 tokens.access_token

    var description: String {
        switch self {
        case .malformed:     return "malformed"
        case .missingTokens: return "missingTokens"
        }
    }
}

enum CodexCredentialStore {
    /// `~/.codex/auth.json`；`CODEX_HOME` 设了就用 `$CODEX_HOME/auth.json`。`environment` 注入以便测试。
    static func authFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home: URL
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            home = URL(fileURLWithPath: codexHome, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return home.appendingPathComponent("auth.json")
    }

    /// 文件不存在 → `nil`（静默，非错误）；存在但坏 → throw `CodexCredentialError`。
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexCredentials? {
        let url = authFileURL(environment: environment)
        guard let data = try? Data(contentsOf: url) else { return nil }   // 不存在 / 读不动 → nil
        return try parse(data)
    }

    /// `internal` 让 @testable 单测能直接喂 Data。
    static func parse(_ data: Data) throws -> CodexCredentials {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CodexCredentialError.malformed
        }
        if let apiKey = obj["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return CodexCredentials(accessToken: apiKey, refreshToken: nil, idToken: nil, accountId: nil)
        }
        guard let tokens = obj["tokens"] as? [String: Any] else { throw CodexCredentialError.missingTokens }
        func str(_ a: String, _ b: String) -> String? { (tokens[a] as? String) ?? (tokens[b] as? String) }
        guard let access = str("access_token", "accessToken"), !access.isEmpty else {
            throw CodexCredentialError.missingTokens
        }
        return CodexCredentials(
            accessToken: access,
            refreshToken: str("refresh_token", "refreshToken"),
            idToken: str("id_token", "idToken"),
            accountId: str("account_id", "accountId")
        )
    }
}
