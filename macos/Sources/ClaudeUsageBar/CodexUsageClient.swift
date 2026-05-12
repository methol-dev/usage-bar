import Foundation

/// SC7：error 携带的信息只到「类别 + HTTP 状态码」，绝不带 response body / 凭证 / URLError userInfo 原文。
enum CodexUsageError: Error, Equatable, CustomStringConvertible {
    case unauthorized        // 401 / 403
    case server(status: Int) // 其它非 2xx
    case network             // URLError 等传输层失败
    case decode              // body 解码失败

    var description: String {
        switch self {
        case .unauthorized:        return "unauthorized"
        case .server(let status):  return "server(\(status))"   // 状态码本身不是凭证
        case .network:             return "network"
        case .decode:              return "decode"
        }
    }
}

enum CodexUsageClient {
    /// `~/.codex/config.toml` 的 `chatgpt_base_url` 覆盖本版本不支持（见 spec §5 风险 3）。
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetchUsage(credentials: CodexCredentials, session: URLSession = .shared) async throws -> CodexUsageResponse {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("usage-bar", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw CodexUsageError.network   // 不透传 error（可能含 URL/凭证片段）
        }
        guard let http = response as? HTTPURLResponse else { throw CodexUsageError.network }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403:  throw CodexUsageError.unauthorized
        default:        throw CodexUsageError.server(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            throw CodexUsageError.decode   // 不透传 DecodingError（其 context 可能含 body 片段）
        }
    }
}
