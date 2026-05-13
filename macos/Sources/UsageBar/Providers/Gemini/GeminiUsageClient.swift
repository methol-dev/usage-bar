import Foundation

enum GeminiUsageError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case server(status: Int)
    case network
    case decode
    case missingProject

    var description: String {
        switch self {
        case .unauthorized:    return "unauthorized"
        case .server(let s):   return "server(\(s))"
        case .network:         return "network"
        case .decode:          return "decode"
        case .missingProject:  return "missingProject"
        }
    }
}

struct GeminiCodeAssistInfo: Equatable {
    let projectId: String
    let tier: String?
}

enum GeminiUsageClient {
    static let baseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    static var loadCodeAssistURL: URL { baseURL.appendingPathComponent("/v1internal:loadCodeAssist") }
    static var retrieveUserQuotaURL: URL { baseURL.appendingPathComponent("/v1internal:retrieveUserQuota") }

    /// 调 `v1internal:loadCodeAssist` 拿 projectId(`cloudaicompanionProject`)+ tier。
    static func loadCodeAssist(credentials: GeminiCredentials,
                               session: URLSession = .shared) async throws -> GeminiCodeAssistInfo {
        let body: [String: Any] = [
            "metadata": ["pluginType": "GEMINI", "platform": "DARWIN_AMD64"],
            "cloudaicompanionProject": "default"
        ]
        let data = try await postJSON(url: loadCodeAssistURL, body: body, credentials: credentials, session: session)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GeminiUsageError.decode
        }
        guard let project = obj["cloudaicompanionProject"] as? String, !project.isEmpty else {
            throw GeminiUsageError.missingProject
        }
        let tier = (obj["currentTier"] as? [String: Any])?["id"] as? String
        return GeminiCodeAssistInfo(projectId: project, tier: tier)
    }

    /// 调 `v1internal:retrieveUserQuota`,body `{"project": "..."}`,返回 per-model 数组。
    static func retrieveUserQuota(credentials: GeminiCredentials,
                                  projectId: String,
                                  session: URLSession = .shared) async throws -> GeminiQuotaResponse {
        let data = try await postJSON(url: retrieveUserQuotaURL,
                                      body: ["project": projectId],
                                      credentials: credentials, session: session)
        do {
            return try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        } catch {
            throw GeminiUsageError.decode
        }
    }

    private static func postJSON(url: URL, body: [String: Any], credentials: GeminiCredentials,
                                 session: URLSession) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("usage-bar", forHTTPHeaderField: "User-Agent")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw GeminiUsageError.decode
        }
        let data: Data; let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GeminiUsageError.network
        }
        guard let http = response as? HTTPURLResponse else { throw GeminiUsageError.network }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw GeminiUsageError.unauthorized
        default:        throw GeminiUsageError.server(status: http.statusCode)
        }
    }
}
