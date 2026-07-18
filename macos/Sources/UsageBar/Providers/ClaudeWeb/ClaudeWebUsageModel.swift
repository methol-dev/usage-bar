import Foundation

/// 扩展经 Native Messaging 送来、host 落盘的信封结构。
///
/// 扩展发送的形状(见 `extension/background.js`):
/// ```json
/// { "status": "ok" | "logged_out" | "no_session" | "error",
///   "ts": <epoch millis>,
///   "usage": { ...claude.ai /api/organizations/{id}/usage 原始响应... },
///   "error": "<可选,类别>" }
/// ```
/// 解析全函数化(JSONSerialization,非 Codable)—— 文件是同用户可写的非可信边界,任何畸形输入返回 nil,不崩。
struct ClaudeWebPayload: Equatable {
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
    /// claude.ai 用量接口原始响应(schema 未文档化 → 保留原始,交给 `ClaudeWebUsageMapper`)。
    let usage: [String: Any]?

    static func == (lhs: ClaudeWebPayload, rhs: ClaudeWebPayload) -> Bool {
        // usage 为任意 JSON,不参与相等性;测试只断言 status/timestamp。
        lhs.status == rhs.status && lhs.timestamp == rhs.timestamp
    }

    static func parse(_ data: Data) -> ClaudeWebPayload? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        let status = Status(rawValue: (dict["status"] as? String) ?? "") ?? .unknown
        var ts: Date?
        if let ms = (dict["ts"] as? NSNumber)?.doubleValue {
            ts = Date(timeIntervalSince1970: ms / 1000.0)     // JS Date.now() 是毫秒
        }
        return ClaudeWebPayload(status: status, timestamp: ts, usage: dict["usage"] as? [String: Any])
    }
}

/// claude.ai `/api/organizations/{id}/usage` 原始 JSON → 统一 `ProviderUsageSnapshot`。
///
/// TODO(Phase 0 spike):该网页接口**未文档化、真实 schema 未知**。下面是 best-effort 猜测映射
/// (假设它可能沿用 oauth/usage 的 five_hour / seven_day + utilization/resets_at 形状,或 session/weekly 命名);
/// 用户在自己已登录的 claude.ai 抓到真实响应后据实重写本文件。找不到任何窗口 → 返回 nil
/// (provider 退化为「已连接但无可映射数据」的骨架态)。全部按 optional 探测,坏字段不崩。
enum ClaudeWebUsageMapper {
    static func snapshot(from usage: [String: Any]?) -> ProviderUsageSnapshot? {
        guard let usage else { return nil }
        let primary = window(anyOf(usage, "five_hour", "session", "five_hour_window"),
                             label: "Session", short: "5h")
        let secondary = window(anyOf(usage, "seven_day", "weekly", "week", "seven_day_window"),
                               label: "Weekly", short: "7d")
        guard primary != nil || secondary != nil else { return nil }
        return ProviderUsageSnapshot(primaryWindow: primary, secondaryWindow: secondary)
    }

    private static func anyOf(_ dict: [String: Any], _ keys: String...) -> [String: Any]? {
        for k in keys { if let v = dict[k] as? [String: Any] { return v } }
        return nil
    }

    private static func window(_ node: [String: Any]?, label: String, short: String) -> UsageWindow? {
        guard let node else { return nil }
        // utilization 猜测:可能是 0...100 的 "utilization" 或 0...1 的 "utilization_ratio"。
        var pct: Double?
        if let u = number(node["utilization"]) { pct = u }
        else if let r = number(node["utilization_ratio"]) { pct = r * 100 }
        else if let u = number(node["used_percent"]) { pct = u }
        guard let utilization = pct else { return nil }

        var reset: Date?
        if let s = node["resets_at"] as? String { reset = isoDate(s) }
        else if let n = number(node["resets_at"]) { reset = Date(timeIntervalSince1970: n) }

        return UsageWindow(label: label, utilizationPct: utilization, resetsAt: reset, shortLabel: short)
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? {
            let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime]
            return g.date(from: s)
        }()
    }
}
