import Foundation

/// 解析 OpenAI codex CLI 的 rollout JSONL（`~/.codex/sessions/**/rollout-*.jsonl`）抽 token 用量。
///
/// **状态机**：模型名出现在 `turn_context` 行（`payload.model` 或 `payload.collaboration_mode.settings.model`）、
/// token 出现在后续 `event_msg` / `token_count` 行的 `payload.info.last_token_usage` —— 边走边跟踪「当前模型」。
///
/// 落出来的只有 `StoredUsageEvent`（token 计数 + 模型名 + 时间 + 合成 id）—— **绝不**碰 rollout 里的对话/代码原文，
/// 也不写任何日志输出（rollout 文件含用户完整会话；连「第几行解析失败」都不打）。见 spec SC9。
enum CodexRolloutCostParser {
    /// `lines`：rollout 文件的全部行（含坏行）；`sessionId`：文件名里的 UUID（见 `sessionId(fromFileName:)`）。
    /// `reqId` / `msgId` 用**绝对行号**（含被跳过的行）—— 这样整文件 re-parse 时同一行始终映射到同一 id，
    /// `UsageEventStore.mergeEvents` 的 `(msgId,reqId)` 去重才幂等。
    static func parseFile(lines: [String], sessionId: String) -> [StoredUsageEvent] {
        var currentModel: String?
        var lastUsageKey: [Int]?
        var out: [StoredUsageEvent] = []
        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }   // 坏行：静默跳过，不抛、不打日志
            let payload = obj["payload"] as? [String: Any]
            // ① 模型行
            if let m = (payload?["model"] as? String)
                ?? ((payload?["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any])?["model"] as? String,
               !m.isEmpty {
                currentModel = m
            }
            // ② token_count 事件 —— info==null（仅含 rate_limits）的不算一次调用，跳过
            guard (obj["type"] as? String) == "event_msg",
                  (payload?["type"] as? String) == "token_count",
                  let info = payload?["info"] as? [String: Any],
                  let lt = info["last_token_usage"] as? [String: Any]
            else { continue }
            // codex CLI 会把同一次调用的 token_count 连发两遍（total_token_usage 不变）—— 累计量没前进就是重复发射，跳过。
            // 无 total 的旧格式退化为比较 last_token_usage。
            let usageKey = usageKey(info["total_token_usage"] as? [String: Any] ?? lt)
            if usageKey == lastUsageKey { continue }
            lastUsageKey = usageKey
            let inputAll = intValue(lt["input_tokens"])
            let cached = intValue(lt["cached_input_tokens"])
            let output = intValue(lt["output_tokens"])
            let ts = (obj["timestamp"] as? String).flatMap(Self.iso8601) ?? Date()
            out.append(StoredUsageEvent(
                ts: ts,
                msgId: "\(sessionId):\(idx)",
                reqId: String(idx),
                sessionId: sessionId,
                model: currentModel ?? "unknown",
                inputTokens: max(inputAll - cached, 0),     // input_tokens 含 cached_input_tokens，拆出非缓存部分
                outputTokens: max(output, 0),               // output_tokens 已含 reasoning_output_tokens
                cacheReadInputTokens: max(cached, 0),
                cacheCreation5mTokens: 0,                   // OpenAI 自动 prompt caching，无 cache-write 口径
                cacheCreation1hTokens: 0
            ))
        }
        return out
    }

    /// 存量修复用：旧版解析器把 codex CLI 重复发射的 token_count 都记成了调用。rollout 源文件可能已被 codex 清理
    /// （0.154 起迁进 sqlite），无法重扫，只能在已存事件上去重：同一会话按行号排序，与前一条 token 事件
    /// （model + 各 token 数）完全相同 → 视为重复发射丢弃。真实的相邻两次调用 token 完全一致几乎不可能（cached 单调增长）。
    static func dropRepeatedEmissions(_ events: [StoredUsageEvent]) -> [StoredUsageEvent] {
        var out: [StoredUsageEvent] = []
        for (_, session) in Dictionary(grouping: events, by: \.sessionId) {
            var prev: StoredUsageEvent?
            for e in session.sorted(by: { (Int($0.reqId) ?? 0) < (Int($1.reqId) ?? 0) }) {
                defer { prev = e }
                if let p = prev, p.model == e.model, p.inputTokens == e.inputTokens, p.outputTokens == e.outputTokens,
                   p.cacheReadInputTokens == e.cacheReadInputTokens,
                   p.cacheCreation5mTokens == e.cacheCreation5mTokens, p.cacheCreation1hTokens == e.cacheCreation1hTokens {
                    continue
                }
                out.append(e)
            }
        }
        return out
    }

    /// 从 `rollout-<ISO8601>-<uuid>.jsonl` 取末尾的 UUID；取不到就用去扩展名的文件名兜底。
    static func sessionId(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        if let r = base.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                              options: .regularExpression) {
            return String(base[r])
        }
        return base
    }

    private static func usageKey(_ u: [String: Any]) -> [Int] {
        ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"].map { intValue(u[$0]) }
    }

    private static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    private static let iso8601Fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func iso8601(_ s: String) -> Date? {
        iso8601Fmt.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
