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

/// 一个模型的 per-Mtok 单价（provider-无关）。`ModelPricingCatalog` 从 LiteLLM 的 per-token 价换算填充。
struct ModelUnitPricing: Equatable, Sendable {
    let inputUSDPerMTok: Double
    let outputUSDPerMTok: Double
    let cacheReadUSDPerMTok: Double
    let cacheWriteUSDPerMTok: Double
    let cacheWrite1hUSDPerMTok: Double
    /// 长上下文档（LiteLLM `*_above_<N>k_tokens`）：单次请求 prompt 超过阈值时**整单**按此档计价
    /// （OpenAI >272k、Anthropic >200k 的官方规则）。nil = 该模型无阶梯价。
    let longContext: LongContextTier?

    init(inputUSDPerMTok: Double, outputUSDPerMTok: Double, cacheReadUSDPerMTok: Double,
         cacheWriteUSDPerMTok: Double, cacheWrite1hUSDPerMTok: Double = 0, longContext: LongContextTier? = nil) {
        self.inputUSDPerMTok = inputUSDPerMTok
        self.outputUSDPerMTok = outputUSDPerMTok
        self.cacheReadUSDPerMTok = cacheReadUSDPerMTok
        self.cacheWriteUSDPerMTok = cacheWriteUSDPerMTok
        self.cacheWrite1hUSDPerMTok = cacheWrite1hUSDPerMTok
        self.longContext = longContext
    }

    func cost(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int = 0) -> Double {
        let write1hRate = cacheWrite1hUSDPerMTok > 0 ? cacheWrite1hUSDPerMTok : cacheWriteUSDPerMTok
        return (Double(input) * inputUSDPerMTok
         + Double(output) * outputUSDPerMTok
         + Double(cacheRead) * cacheReadUSDPerMTok
         + Double(cacheWrite) * cacheWriteUSDPerMTok
         + Double(cacheWrite1h) * write1hRate) / 1_000_000.0
    }

    /// 一个桶的费用：超过长上下文阈值的那部分请求（`TokenSums.longContext` 子桶）按长上下文档计价，其余按基础价。
    /// 阈值不在 `TokenSums.longContextThresholds` 里（没有对应子桶）→ 全按基础价。
    func cost(_ s: TokenSums) -> Double {
        guard let tier = longContext, let long = s.longContext[String(tier.thresholdTokens)], long.calls > 0 else {
            return cost(input: s.inputTokens, output: s.outputTokens, cacheRead: s.cacheReadInputTokens,
                        cacheWrite: s.cacheCreation5mTokens, cacheWrite1h: s.cacheCreation1hTokens)
        }
        let base = cost(input: s.inputTokens - long.inputTokens, output: s.outputTokens - long.outputTokens,
                        cacheRead: s.cacheReadInputTokens - long.cacheReadInputTokens,
                        cacheWrite: s.cacheCreation5mTokens - long.cacheCreation5mTokens,
                        cacheWrite1h: s.cacheCreation1hTokens - long.cacheCreation1hTokens)
        return base + tier.rates.cost(input: long.inputTokens, output: long.outputTokens,
                                      cacheRead: long.cacheReadInputTokens,
                                      cacheWrite: long.cacheCreation5mTokens, cacheWrite1h: long.cacheCreation1hTokens)
    }
}

/// 长上下文计价档：prompt（input + cache read + cache write）> `thresholdTokens` 的请求整单按 `rates` 计价。
struct LongContextTier: Equatable, Sendable {
    let thresholdTokens: Int
    let rates: Rates

    struct Rates: Equatable, Sendable {
        let inputUSDPerMTok: Double
        let outputUSDPerMTok: Double
        let cacheReadUSDPerMTok: Double
        let cacheWriteUSDPerMTok: Double
        let cacheWrite1hUSDPerMTok: Double

        func cost(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int) -> Double {
            ModelUnitPricing(inputUSDPerMTok: inputUSDPerMTok, outputUSDPerMTok: outputUSDPerMTok,
                             cacheReadUSDPerMTok: cacheReadUSDPerMTok, cacheWriteUSDPerMTok: cacheWriteUSDPerMTok,
                             cacheWrite1hUSDPerMTok: cacheWrite1hUSDPerMTok)
                .cost(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h)
        }
    }
}

/// 「这个 provider 的费用怎么算/怎么显示」—— 一个轻包装，取代会穿多层 view 的 `(pricing:displayName:)` tuple。
/// 只在 MainActor 的视图层用（持一个非-Sendable 闭包），不跨 actor。
struct ProviderCostContext {
    let pricing: any ModelPriceTable
    let displayName: (String) -> String
}
