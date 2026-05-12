import Foundation

/// OpenAI 模型的 list-price 估价表，给 Codex tab 的「估算费用卡」用。
///
/// ⚠️ **这些是 best-effort 估算**（按 OpenAI 各模型的 list price 推算的 per-Mtok 价）—— **不是真实账单**。
/// ChatGPT / Codex 套餐（Free / Plus / Pro）是「套餐包额度」计费，没有按 token 收费的口径；
/// Codex tab 的 USD 跟 Claude tab 一样是合成估算（Claude tab 也是 list price 估算）。
/// 过期了/有确切来源了改这张表，并把对应项的 `// UNVERIFIED` 去掉。
/// `cacheWriteUSDPerMTok` 一律 0：OpenAI 的 prompt caching 是自动的，没有 cache-write 计费。
enum OpenAIPricing {
    static let snapshotDate = "2026-05-12"

    /// key 必须是 `normalize(_:)` 后的小写名。
    private static let table: [String: ModelUnitPricing] = [
        "gpt-5.5":     .init(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 0), // UNVERIFIED — list-price estimate
        "gpt-5.1":     .init(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 0), // UNVERIFIED — list-price estimate
        "gpt-5":       .init(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 0), // UNVERIFIED — list-price estimate
        "gpt-5-codex": .init(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 0), // UNVERIFIED — list-price estimate
        "gpt-5-mini":  .init(inputUSDPerMTok: 0.25, outputUSDPerMTok: 2.0,  cacheReadUSDPerMTok: 0.025, cacheWriteUSDPerMTok: 0), // UNVERIFIED — list-price estimate
        "gpt-5-nano":  .init(inputUSDPerMTok: 0.05, outputUSDPerMTok: 0.4,  cacheReadUSDPerMTok: 0.005, cacheWriteUSDPerMTok: 0), // UNVERIFIED — list-price estimate
        "o3":          .init(inputUSDPerMTok: 2.0,  outputUSDPerMTok: 8.0,  cacheReadUSDPerMTok: 0.5,   cacheWriteUSDPerMTok: 0), // UNVERIFIED — list-price estimate
        "o4-mini":     .init(inputUSDPerMTok: 1.1,  outputUSDPerMTok: 4.4,  cacheReadUSDPerMTok: 0.275, cacheWriteUSDPerMTok: 0), // UNVERIFIED — list-price estimate
    ]

    /// 去尾部日期后缀（`-YYYY-MM-DD` 带短横线形式 —— OpenAI API 模型串常用；也兼容 `-YYYYMMDD`）+ 小写。
    static func normalize(_ model: String) -> String {
        let lower = model.lowercased()
        if let r = lower.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            return String(lower[..<r.lowerBound])
        }
        if let r = lower.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(lower[..<r.lowerBound])
        }
        return lower
    }

    static func lookup(model: String) -> ModelUnitPricing? { table[normalize(model)] }

    static func displayName(_ model: String) -> String {
        switch normalize(model) {
        case "gpt-5.5": return "GPT-5.5"
        case "gpt-5.1": return "GPT-5.1"
        case "gpt-5": return "GPT-5"
        case "gpt-5-codex": return "GPT-5 Codex"
        case "gpt-5-mini": return "GPT-5 mini"
        case "gpt-5-nano": return "GPT-5 nano"
        case "o3": return "o3"
        case "o4-mini": return "o4-mini"
        default: return model   // 未知 → 原样
        }
    }
}

struct OpenAIModelPriceTable: ModelPriceTable {
    static let shared = OpenAIModelPriceTable()
    func normalize(_ model: String) -> String { OpenAIPricing.normalize(model) }
    func lookup(_ model: String) -> ModelUnitPricing? { OpenAIPricing.lookup(model: model) }
    func displayName(_ model: String) -> String { OpenAIPricing.displayName(model) }
}
