import Foundation

/// 扩展经 Native Messaging 送来、host 落盘 `codex-web.json` 的信封结构（ADR 0012）。
///
/// 扩展发送的形状(见 `extension/background.js`):
/// ```json
/// { "status": "ok" | "logged_out" | "no_session" | "error",
///   "ts": <epoch millis>,
///   "provider": "codex",
///   "usage": { ...chatgpt.com /backend-api/wham/usage 原始响应... },
///   "error": "<可选,类别>" }
/// ```
/// bearer token 始终留在浏览器（扩展在 chatgpt.com 页面上下文里取 session→accessToken→wham/usage，
/// 只把用量数字回传，token 不出浏览器）。解析全函数化 —— 文件是同用户可写的非可信边界，畸形输入返回 nil，不崩。
struct CodexWebPayload: Equatable {
    enum Status: String {
        case ok
        case loggedOut = "logged_out"
        case noSession = "no_session"
        case error
        case unknown
    }

    let status: Status
    /// 扩展取数时刻(用于 staleness 判定)。缺失 → nil。
    let timestamp: Date?
    /// chatgpt.com 用量接口原始响应（`wham/usage`，与 Codex CLI 同 schema → 交给 `CodexWebUsageMapper`）。
    let usage: [String: Any]?

    static func == (lhs: CodexWebPayload, rhs: CodexWebPayload) -> Bool {
        // usage 为任意 JSON,不参与相等性;测试只断言 status/timestamp。
        lhs.status == rhs.status && lhs.timestamp == rhs.timestamp
    }

    static func parse(_ data: Data) -> CodexWebPayload? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        let status = Status(rawValue: (dict["status"] as? String) ?? "") ?? .unknown
        var ts: Date?
        if let ms = (dict["ts"] as? NSNumber)?.doubleValue {
            ts = Date(timeIntervalSince1970: ms / 1000.0)     // JS Date.now() 是毫秒
        }
        return CodexWebPayload(status: status, timestamp: ts, usage: dict["usage"] as? [String: Any])
    }
}

/// chatgpt.com `wham/usage` 原始 JSON → 统一 `ProviderUsageSnapshot`。
///
/// 与 Codex CLI 走**同一个端点、同一 schema**，故直接复用 `CodexUsageResponse` 的解码 + 归一：
/// 把 `usage` 子对象重新序列化为 `Data`，交给现成的 `CodexUsageResponse` Decodable，再 `asProviderSnapshot()`。
/// 任意畸形 / 缺字段 → nil（provider 退化为「已连接但无可映射数据」骨架态）。
enum CodexWebUsageMapper {
    static func snapshot(from usage: [String: Any]?) -> ProviderUsageSnapshot? {
        guard let usage,
              let data = try? JSONSerialization.data(withJSONObject: usage),
              let response = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) else { return nil }
        return response.asProviderSnapshot()
    }
}
