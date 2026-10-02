import Foundation

// 旧 `enum UsageProvider { case claude }` 已并入 `ProviderID`（见 ProviderID.swift），
// 用作 `data/<provider>/` 目录名的语义不变（`ProviderID.claude.rawValue == "claude"`）。

/// 单次 assistant 调用的事实记录。**故意不含 content/text/contentBlocks**（隐私 schema 守护）。
struct StoredUsageEvent: Equatable {
    let ts: Date                        // ISO8601 UTC
    let msgId: String
    let reqId: String
    let sessionId: String               // 来自 jsonl 文件名的 UUID；仅供未来分账/调试，不展示给用户
    let model: String                   // 归一化前的原始 model 字符串
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreation5mTokens: Int
    let cacheCreation1hTokens: Int
    var cacheCreationInputTokens: Int { cacheCreation5mTokens + cacheCreation1hTokens }

    init(ts: Date, msgId: String, reqId: String, sessionId: String, model: String,
         inputTokens: Int, outputTokens: Int, cacheReadInputTokens: Int,
         cacheCreation5mTokens: Int, cacheCreation1hTokens: Int = 0) {
        self.ts = ts; self.msgId = msgId; self.reqId = reqId; self.sessionId = sessionId
        self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
    }
}

/// data/<provider>/<YYYY>-<MM>.json
struct MonthDetailFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var provider: String
    var month: String                   // "YYYY-MM"，仅供人读；load 时以文件名为准
    var lastUpdated: Date
    var events: [StoredUsageEvent]
}

/// agg 文件桶里某个 model 的累积。
struct TokenSums: Equatable {
    /// 长上下文计价阈值（LiteLLM `*_above_<N>k_tokens`：Anthropic 200k、OpenAI 272k）。
    /// 单次请求 prompt 超过阈值时额外计入对应子桶，计价时这部分整单按长上下文档算（见 `ModelUnitPricing.cost(_:)`）。
    static let longContextThresholds = [200_000, 272_000]

    var calls: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var cacheCreation5mTokens: Int = 0
    var cacheCreation1hTokens: Int = 0
    var cacheCreationInputTokens: Int = 0
    /// 键 = 阈值（十进制字符串，JSON 对象键需为字符串）；值 = prompt 超过该阈值的请求的累计（其自身 longContext 恒空）。
    var longContext: [String: TokenSums] = [:]

    init() {}

    /// 单个事件的计数（calls = 1，不含 longContext 子桶）。
    private init(_ e: StoredUsageEvent) {
        calls = 1
        inputTokens = e.inputTokens
        outputTokens = e.outputTokens
        cacheReadInputTokens = e.cacheReadInputTokens
        cacheCreation5mTokens = e.cacheCreation5mTokens
        cacheCreation1hTokens = e.cacheCreation1hTokens
        cacheCreationInputTokens = e.cacheCreationInputTokens
    }

    mutating func add(_ e: StoredUsageEvent) {
        let one = TokenSums(e)
        // usage 全 0 的不是一次计费调用（如 Claude CLI 在 API 报错时写的 `<synthetic>` 占位消息）
        guard one.inputTokens + one.outputTokens + one.cacheReadInputTokens + one.cacheCreationInputTokens > 0 else { return }
        merge(one)
        let prompt = e.inputTokens + e.cacheReadInputTokens + e.cacheCreationInputTokens
        for t in Self.longContextThresholds where prompt > t {
            longContext[String(t), default: TokenSums()].merge(one)
        }
    }

    mutating func merge(_ o: TokenSums) {
        calls += o.calls
        inputTokens += o.inputTokens
        outputTokens += o.outputTokens
        cacheReadInputTokens += o.cacheReadInputTokens
        cacheCreation5mTokens += o.cacheCreation5mTokens
        cacheCreation1hTokens += o.cacheCreation1hTokens
        cacheCreationInputTokens += o.cacheCreationInputTokens
        for (k, v) in o.longContext { longContext[k, default: TokenSums()].merge(v) }
    }

    /// 标量计数相减（不含 longContext 子桶），用于从总量里扣掉长上下文那部分。
    func subtracting(_ o: TokenSums) -> TokenSums {
        var r = TokenSums()
        r.calls = calls - o.calls
        r.inputTokens = inputTokens - o.inputTokens
        r.outputTokens = outputTokens - o.outputTokens
        r.cacheReadInputTokens = cacheReadInputTokens - o.cacheReadInputTokens
        r.cacheCreation5mTokens = cacheCreation5mTokens - o.cacheCreation5mTokens
        r.cacheCreation1hTokens = cacheCreation1hTokens - o.cacheCreation1hTokens
        r.cacheCreationInputTokens = cacheCreationInputTokens - o.cacheCreationInputTokens
        return r
    }
}

/// data/<provider>/agg-{day,month,year}.json
/// buckets 键：day = "YYYY-MM-DD"（本地时区）/ month = "YYYY-MM"（UTC）/ year = "YYYY"（UTC）
/// 内层键 = ClaudePricing.normalize 后的 model 字符串
struct AggregateFile: Codable, Equatable {
    /// v3：TokenSums 增加 longContext 子桶。版本不符的旧文件读出为 nil → 全量重建。
    static let currentSchemaVersion = 3
    var schemaVersion: Int = AggregateFile.currentSchemaVersion
    var provider: String
    var lastUpdated: Date
    var buckets: [String: [String: TokenSums]]
}

/// data/scan-cursor.json
struct ScanCursorFile: Codable, Equatable {
    static let currentSchemaVersion = 2
    var schemaVersion: Int = 2
    var files: [String: FileCursor]     // 键 = jsonl 绝对路径

    struct FileCursor: Codable, Equatable {
        var size: Int
        var mtime: Date
        var lineOffset: Int             // 已处理行数（下次跳过前 lineOffset 行）
    }
}

extension StoredUsageEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case ts, msgId, reqId, sessionId, model
        case inputTokens, outputTokens, cacheReadInputTokens
        case cacheCreationInputTokens, cacheCreation5mTokens, cacheCreation1hTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(Date.self, forKey: .ts)
        msgId = try c.decode(String.self, forKey: .msgId)
        reqId = try c.decode(String.self, forKey: .reqId)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        model = try c.decode(String.self, forKey: .model)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheReadInputTokens = try c.decode(Int.self, forKey: .cacheReadInputTokens)
        let legacy = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        if let c5 = try c.decodeIfPresent(Int.self, forKey: .cacheCreation5mTokens) {
            cacheCreation5mTokens = c5
            cacheCreation1hTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreation1hTokens) ?? 0
        } else {
            cacheCreation5mTokens = legacy
            cacheCreation1hTokens = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(msgId, forKey: .msgId)
        try c.encode(reqId, forKey: .reqId)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(model, forKey: .model)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadInputTokens, forKey: .cacheReadInputTokens)
        try c.encode(cacheCreation5mTokens, forKey: .cacheCreation5mTokens)
        try c.encode(cacheCreation1hTokens, forKey: .cacheCreation1hTokens)
        try c.encode(cacheCreationInputTokens, forKey: .cacheCreationInputTokens)
    }
}

extension TokenSums: Codable {
    enum CodingKeys: String, CodingKey {
        case calls, inputTokens, outputTokens, cacheReadInputTokens
        case cacheCreationInputTokens, cacheCreation5mTokens, cacheCreation1hTokens
        case longContext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        longContext = try c.decodeIfPresent([String: TokenSums].self, forKey: .longContext) ?? [:]
        calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
        let legacy = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        if let c5 = try c.decodeIfPresent(Int.self, forKey: .cacheCreation5mTokens) {
            cacheCreation5mTokens = c5
            cacheCreation1hTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreation1hTokens) ?? 0
            cacheCreationInputTokens = cacheCreation5mTokens + cacheCreation1hTokens
        } else {
            cacheCreation5mTokens = legacy
            cacheCreation1hTokens = 0
            cacheCreationInputTokens = legacy
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(calls, forKey: .calls)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadInputTokens, forKey: .cacheReadInputTokens)
        try c.encode(cacheCreation5mTokens, forKey: .cacheCreation5mTokens)
        try c.encode(cacheCreation1hTokens, forKey: .cacheCreation1hTokens)
        try c.encode(cacheCreationInputTokens, forKey: .cacheCreationInputTokens)
        if !longContext.isEmpty { try c.encode(longContext, forKey: .longContext) }
    }
}

struct ModelCost: Codable, Equatable {
    let model: String
    let normalizedModel: String
    let calls: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let usd: Double
    let isUnknownPricing: Bool
}

struct CostSummary: Codable, Equatable {
    let generatedAt: Date
    let windowDays: Int
    let totalUSD: Double
    let perModel: [ModelCost]
    let unknownModelCount: Int
    let parseErrorCount: Int
    let scannedFileCount: Int
}
