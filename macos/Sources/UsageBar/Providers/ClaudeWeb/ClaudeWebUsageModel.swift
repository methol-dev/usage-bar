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
/// 依据真实响应定稿(2026-07,owner 抓取):
/// - `five_hour.utilization`(0...100)+ `resets_at` → 主窗口(Session/5h);
/// - `seven_day.utilization` + `resets_at` → 次窗口(Weekly/7d);
/// - `seven_day_opus` / `seven_day_sonnet`(非 null 且有 utilization)→ per-model 额外行;
/// - `extra_usage`(is_enabled/utilization/used_credits/monthly_limit,分→元 /100),否则回退 `spend`
///   (enabled/percent/used.amount_minor÷10^exponent)→ 额度线。
///
/// 全按 optional 探测,坏 / 缺字段不崩。任何窗口都拿不到 → nil(provider 退化为「已连接但无可映射数据」骨架态)。
enum ClaudeWebUsageMapper {
    static func snapshot(from usage: [String: Any]?) -> ProviderUsageSnapshot? {
        guard let usage else { return nil }
        let primary = window(usage["five_hour"] as? [String: Any], label: "Session", short: "5h",
                             duration: 5 * 60 * 60)
        let secondary = window(usage["seven_day"] as? [String: Any], label: "Weekly", short: "7d",
                               duration: 7 * 24 * 60 * 60)
        let extras = perModelWindows(usage)
        let credit = creditLine(usage)
        guard primary != nil || secondary != nil || !extras.isEmpty || credit != nil else { return nil }
        return ProviderUsageSnapshot(primaryWindow: primary, secondaryWindow: secondary,
                                     extraWindows: extras, creditLine: credit)
    }

    /// per-model 行(seven_day_opus / seven_day_sonnet)—— 仅在存在且有 utilization 时显示,复用 7d 时长。
    private static func perModelWindows(_ usage: [String: Any]) -> [NamedUsageWindow] {
        var out: [NamedUsageWindow] = []
        for (key, id, title) in [("seven_day_opus", "opus", "Opus"), ("seven_day_sonnet", "sonnet", "Sonnet")] {
            if let node = usage[key] as? [String: Any],
               let w = window(node, label: title, short: title, duration: 7 * 24 * 60 * 60) {
                out.append(NamedUsageWindow(id: id, title: title, window: w))
            }
        }
        return out
    }

    /// 额度线:优先 `extra_usage`(与 CLI 同形状,金额分→元/美元 /100);其次 `spend`(amount_minor÷10^exponent)。
    /// 两者都无有效数据 → nil(不渲染额度行)。
    private static func creditLine(_ usage: [String: Any]) -> CreditLine? {
        if let e = usage["extra_usage"] as? [String: Any] {
            let enabled = (e["is_enabled"] as? Bool) ?? false
            let util = number(e["utilization"])
            let used = number(e["used_credits"]).map { $0 / 100 }
            let limit = number(e["monthly_limit"]).map { $0 / 100 }
            if enabled || util != nil || used != nil || limit != nil {
                return CreditLine(isEnabled: enabled, utilizationPct: util, usedAmount: used, limitAmount: limit)
            }
        }
        if let s = usage["spend"] as? [String: Any] {
            let enabled = (s["enabled"] as? Bool) ?? false
            let used = spendAmount(s["used"])
            if enabled || (used ?? 0) > 0 {
                return CreditLine(isEnabled: enabled, utilizationPct: number(s["percent"]), usedAmount: used)
            }
        }
        return nil
    }

    /// `spend.used = { amount_minor, currency, exponent }` → 主单位金额。
    private static func spendAmount(_ any: Any?) -> Double? {
        guard let node = any as? [String: Any], let minor = number(node["amount_minor"]) else { return nil }
        let exponent = number(node["exponent"]) ?? 2
        return minor / pow(10.0, exponent)
    }

    private static func window(_ node: [String: Any]?, label: String, short: String,
                               duration: TimeInterval) -> UsageWindow? {
        guard let node, let utilization = number(node["utilization"]) else { return nil }
        var reset: Date?
        if let s = node["resets_at"] as? String { reset = isoDate(s) }
        else if let n = number(node["resets_at"]) { reset = Date(timeIntervalSince1970: n) }
        return UsageWindow(label: label, utilizationPct: utilization, resetsAt: reset,
                           windowDuration: duration, shortLabel: short)
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// 解析 claude.ai 的 `resets_at`(ISO8601,可能带 6 位小数秒 + 偏移,如 `2026-07-18T16:09:59.774291+00:00`)。
    /// ISO8601DateFormatter 的 `.withFractionalSeconds` 只稳认 3 位小数,故加「剥小数秒再解析」兜底。
    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            var stripped = s
            stripped.removeSubrange(r)
            return f.date(from: stripped)   // formatOptions 仍为 .withInternetDateTime
        }
        return nil
    }
}
