import Foundation

/// provider-无关的「模型 → 单价」表抽象。`ClaudePricing` / `OpenAIPricing` 各提供一个 conformer
/// （`ClaudeModelPriceTable` / `OpenAIModelPriceTable`）。`: Sendable` —— `UsageStatsService.refresh()`
/// 在 `Task.detached` 里用它。
protocol ModelPriceTable: Sendable {
    /// 把原始模型名规范成定价表 key（小写、去日期后缀等）。
    func normalize(_ model: String) -> String
    /// 查规范化后的单价；未知模型 → nil（调用方按 `isUnknownPricing` 处理）。
    func lookup(_ model: String) -> ModelUnitPricing?
    /// 给 UI 用的简短显示名（如 `Opus 4.7` / `GPT-5.5`）。识别不出 → 原样返回。
    func displayName(_ model: String) -> String
}

/// 一个模型的 per-Mtok 单价（与 `ClaudeModelPricing` 同字段，但 provider-无关）。
struct ModelUnitPricing: Equatable, Sendable {
    let inputUSDPerMTok: Double
    let outputUSDPerMTok: Double
    let cacheReadUSDPerMTok: Double
    let cacheWriteUSDPerMTok: Double

    func cost(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        (Double(input) * inputUSDPerMTok
         + Double(output) * outputUSDPerMTok
         + Double(cacheRead) * cacheReadUSDPerMTok
         + Double(cacheWrite) * cacheWriteUSDPerMTok) / 1_000_000.0
    }
}

/// 「这个 provider 的费用怎么算/怎么显示」—— 一个轻包装，取代会穿多层 view 的 `(pricing:displayName:)` tuple。
/// 只在 MainActor 的视图层用（持一个非-Sendable 闭包），不跨 actor。
struct ProviderCostContext {
    let pricing: any ModelPriceTable
    let displayName: (String) -> String
}
