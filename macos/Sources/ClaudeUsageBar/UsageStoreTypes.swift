import Foundation

// 旧 `enum UsageProvider { case claude }` 已并入 `ProviderID`（见 ProviderID.swift），
// 用作 `data/<provider>/` 目录名的语义不变（`ProviderID.claude.rawValue == "claude"`）。

/// 单次 assistant 调用的事实记录。**故意不含 content/text/contentBlocks**（隐私 schema 守护）。
struct StoredUsageEvent: Codable, Equatable {
    let ts: Date                        // ISO8601 UTC
    let msgId: String
    let reqId: String
    let sessionId: String               // 来自 jsonl 文件名的 UUID；仅供未来分账/调试，不展示给用户
    let model: String                   // 归一化前的原始 model 字符串
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
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
struct TokenSums: Codable, Equatable {
    var calls: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0

    mutating func add(_ e: StoredUsageEvent) {
        calls += 1
        inputTokens += e.inputTokens
        outputTokens += e.outputTokens
        cacheReadInputTokens += e.cacheReadInputTokens
        cacheCreationInputTokens += e.cacheCreationInputTokens
    }
}

/// data/<provider>/agg-{day,month,year}.json
/// buckets 键：day = "YYYY-MM-DD"（本地时区）/ month = "YYYY-MM"（UTC）/ year = "YYYY"（UTC）
/// 内层键 = ClaudePricing.normalize 后的 model 字符串
struct AggregateFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var provider: String
    var lastUpdated: Date
    var buckets: [String: [String: TokenSums]]
}

/// data/scan-cursor.json
struct ScanCursorFile: Codable, Equatable {
    var schemaVersion: Int = 1
    var files: [String: FileCursor]     // 键 = jsonl 绝对路径

    struct FileCursor: Codable, Equatable {
        var size: Int
        var mtime: Date
        var lineOffset: Int             // 已处理行数（下次跳过前 lineOffset 行）
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
