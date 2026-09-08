import XCTest
@testable import UsageBar

final class OpenAIPricingTests: XCTestCase {
    func testNormalizeStripsDateSuffixAndLowercases() {
        XCTAssertEqual(OpenAIPricing.normalize("GPT-5.5"), "gpt-5.5")
        XCTAssertEqual(OpenAIPricing.normalize("gpt-5.5-2026-01-01"), "gpt-5.5")
        XCTAssertEqual(OpenAIPricing.normalize("gpt-5-20260101"), "gpt-5")
        XCTAssertEqual(OpenAIPricing.normalize("gpt-5-codex"), "gpt-5-codex")
    }

    func testLookupViaCatalog() {
        // 价格查表走 ModelPricingCatalog（bundle 内真实 LiteLLM 快照）。
        XCTAssertNotNil(OpenAIModelPriceTable.shared.lookup("gpt-5"))
        XCTAssertNotNil(OpenAIModelPriceTable.shared.lookup("GPT-5"))
        XCTAssertNotNil(OpenAIModelPriceTable.shared.lookup("gpt-5-codex"))
        XCTAssertNil(OpenAIModelPriceTable.shared.lookup("definitely-not-a-real-model-zzz9000"))
    }

    func testDisplayName() {
        XCTAssertEqual(OpenAIPricing.displayName("gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(OpenAIPricing.displayName("gpt-5-codex"), "GPT-5 Codex")
        XCTAssertEqual(OpenAIPricing.displayName("o4-mini"), "o4-mini")
        XCTAssertEqual(OpenAIPricing.displayName("totally-unknown"), "totally-unknown")
    }

    func testModelUnitPricingCostFormula() {
        let p = ModelUnitPricing(inputUSDPerMTok: 1, outputUSDPerMTok: 2, cacheReadUSDPerMTok: 0.1, cacheWriteUSDPerMTok: 3)
        // 1M input × $1 + 1M output × $2 + 1M cacheRead × $0.1 + 1M cacheWrite × $3 = 6.1
        XCTAssertEqual(p.cost(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000), 6.1, accuracy: 1e-9)
        XCTAssertEqual(p.cost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), 0, accuracy: 1e-12)
        // 无 1h 单价时，1h tokens 回退 5m 价，避免按 0 计
        XCTAssertEqual(p.cost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 1_000_000), 3.0, accuracy: 1e-9)
        let with1h = ModelUnitPricing(inputUSDPerMTok: 1, outputUSDPerMTok: 2, cacheReadUSDPerMTok: 0.1,
                                      cacheWriteUSDPerMTok: 3, cacheWrite1hUSDPerMTok: 5)
        XCTAssertEqual(with1h.cost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cacheWrite1h: 1_000_000), 5.0, accuracy: 1e-9)
    }
}
