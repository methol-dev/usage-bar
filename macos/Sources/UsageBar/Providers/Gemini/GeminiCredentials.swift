import Foundation

/// 从本机 gemini-cli 已登录的 `~/.gemini/oauth_creds.json` 读出来的凭证。
/// 字段对齐 google-auth-library 的 `Credentials` 接口（见 gemini-cli `packages/core/src/code_assist/oauth2.ts`）。
/// 本 spec 阶段：**只读**；refresh 在 Task 3 实现。
struct GeminiCredentials: Equatable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String?
    /// `expiry_date` 上游用毫秒 epoch；此处统一转 Swift `Date`（秒）。
    var expiryDate: Date?
    var idToken: String?
    var scope: String?

    /// `expiryDate` 已过期（留 60s 缓冲），返回 true。`expiryDate` 缺失也算需刷新（谨慎）。
    func isExpired(now: Date = Date()) -> Bool {
        guard let exp = expiryDate else { return true }
        return exp.timeIntervalSince(now) < 60
    }
}

enum GeminiCredentialError: Error, CustomStringConvertible {
    case malformed
    case missingAccessToken

    var description: String {
        switch self {
        case .malformed:           return "malformed"
        case .missingAccessToken:  return "missingAccessToken"
        }
    }
}

enum GeminiCredentialStore {
    /// `~/.gemini/oauth_creds.json`；`GEMINI_HOME` 设了就用 `$GEMINI_HOME/oauth_creds.json`。
    static func credsFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home: URL
        if let geminiHome = environment["GEMINI_HOME"], !geminiHome.isEmpty {
            home = URL(fileURLWithPath: geminiHome, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
        }
        return home.appendingPathComponent("oauth_creds.json")
    }

    /// 文件不存在 → nil（静默）；存在但坏 → throw `GeminiCredentialError`。
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> GeminiCredentials? {
        let url = credsFileURL(environment: environment)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> GeminiCredentials {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GeminiCredentialError.malformed
        }
        guard let accessToken = obj["access_token"] as? String, !accessToken.isEmpty else {
            throw GeminiCredentialError.missingAccessToken
        }
        let expiry: Date?
        if let ms = obj["expiry_date"] as? Double {
            expiry = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let ms = obj["expiry_date"] as? Int {
            expiry = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        } else {
            expiry = nil
        }
        return GeminiCredentials(
            accessToken: accessToken,
            refreshToken: obj["refresh_token"] as? String,
            tokenType: obj["token_type"] as? String,
            expiryDate: expiry,
            idToken: obj["id_token"] as? String,
            scope: obj["scope"] as? String
        )
    }
}

enum GeminiRefreshError: Error, CustomStringConvertible {
    case missingRefreshToken
    case unauthorized          // 400 / 401
    case server(status: Int)
    case network
    case decode

    var description: String {
        switch self {
        case .missingRefreshToken: return "missingRefreshToken"
        case .unauthorized:        return "unauthorized"
        case .server(let s):       return "server(\(s))"
        case .network:             return "network"
        case .decode:              return "decode"
        }
    }
}

extension GeminiCredentialStore {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// 用 refresh_token 换新 access_token。成功后**原子**写回 `oauth_creds.json`（0600）；
    /// 失败不动文件。
    static func refresh(credentials creds: GeminiCredentials,
                        clientId: String,
                        clientSecret: String,
                        session: URLSession = .shared,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        now: Date = Date()) async throws -> GeminiCredentials {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            throw GeminiRefreshError.missingRefreshToken
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyParams = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        req.httpBody = Data(formEncode(bodyParams).utf8)

        let data: Data; let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GeminiRefreshError.network
        }
        guard let http = response as? HTTPURLResponse else { throw GeminiRefreshError.network }
        switch http.statusCode {
        case 200..<300: break
        case 400, 401, 403: throw GeminiRefreshError.unauthorized
        default: throw GeminiRefreshError.server(status: http.statusCode)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int?
            let token_type: String?
            let id_token: String?
            let scope: String?
            let refresh_token: String?
        }
        let parsed: TokenResponse
        do {
            parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GeminiRefreshError.decode
        }

        var updated = creds
        updated.accessToken = parsed.access_token
        if let exp = parsed.expires_in { updated.expiryDate = now.addingTimeInterval(TimeInterval(exp)) }
        if let t = parsed.token_type { updated.tokenType = t }
        if let id = parsed.id_token { updated.idToken = id }
        if let s = parsed.scope { updated.scope = s }
        if let r = parsed.refresh_token, !r.isEmpty { updated.refreshToken = r }   // Google 偶尔会回新 refresh_token

        try writeAtomically(credentials: updated, environment: environment)
        return updated
    }

    /// 写回 oauth_creds.json：tmp + rename + 0600 权限。schema 与 gemini-cli 完全一致。
    static func writeAtomically(credentials: GeminiCredentials,
                                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let dst = credsFileURL(environment: environment)
        let dir = dst.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json: [String: Any] = ["access_token": credentials.accessToken]
        if let r = credentials.refreshToken { json["refresh_token"] = r }
        if let t = credentials.tokenType { json["token_type"] = t }
        if let exp = credentials.expiryDate {
            json["expiry_date"] = Int(exp.timeIntervalSince1970 * 1000)
        }
        if let id = credentials.idToken { json["id_token"] = id }
        if let s = credentials.scope { json["scope"] = s }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let tmp = dir.appendingPathComponent("oauth_creds.json.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        // 替换：_ = result 防 ranking 警告；若 dst 不存在，replaceItem 会直接创建。
        if FileManager.default.fileExists(atPath: dst.path) {
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: dst)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
    }

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}
