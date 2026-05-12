import Foundation

/// 解析 OpenAI codex CLI 的 rollout JSONL（`~/.codex/sessions/**/rollout-*.jsonl`）抽 token 用量。
///
/// **状态机**：模型名出现在 `turn_context` 行（`payload.model` 或 `payload.collaboration_mode.settings.model`）、
/// token 出现在后续 `event_msg` / `token_count` 行的 `payload.info.last_token_usage` —— 边走边跟踪「当前模型」。
///
/// 落出来的只有 `StoredUsageEvent`（token 计数 + 模型名 + 时间 + 合成 id）—— **绝不**碰 rollout 里的对话/代码原文，
/// 也不 print / NSLog / os_log（rollout 文件含用户完整会话；连「第几行解析失败」都不打）。见 spec SC9。
enum CodexRolloutCostParser {
    /// `lines`：rollout 文件的全部行（含坏行）；`sessionId`：文件名里的 UUID（见 `sessionId(fromFileName:)`）。
    /// `reqId` / `msgId` 用**绝对行号**（含被跳过的行）—— 这样整文件 re-parse 时同一行始终映射到同一 id，
    /// `UsageEventStore.mergeEvents` 的 `(msgId,reqId)` 去重才幂等。
    static func parseFile(lines: [String], sessionId: String) -> [StoredUsageEvent] {
        var currentModel: String?
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
                cacheCreationInputTokens: 0                 // OpenAI 自动 prompt caching，无 cache-write 口径
            ))
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
