import XCTest
@testable import ClaudeUsageBar

final class OpenAIPricingTests: XCTestCase {
    func testNormalizeStripsDateSuffixAndLowercases() {
        XCTAssertEqual(OpenAIPricing.normalize("GPT-5.5"), "gpt-5.5")
        XCTAssertEqual(OpenAIPricing.normalize("gpt-5.5-2026-01-01"), "gpt-5.5")
        XCTAssertEqual(OpenAIPricing.normalize("gpt-5-20260101"), "gpt-5")
        XCTAssertEqual(OpenAIPricing.normalize("gpt-5-codex"), "gpt-5-codex")
    }
    func testLookupKnownAndUnknown() {
        XCTAssertNotNil(OpenAIPricing.lookup(model: "gpt-5.5"))
        XCTAssertNotNil(OpenAIPricing.lookup(model: "GPT-5.5"))
        XCTAssertNotNil(OpenAIPricing.lookup(model: "gpt-5-codex"))
        XCTAssertNil(OpenAIPricing.lookup(model: "gpt-9000"))
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
    }
    func testTablesConformToProtocol() {
        let openai: any ModelPriceTable = OpenAIModelPriceTable.shared
        XCTAssertEqual(openai.normalize("GPT-5.5"), "gpt-5.5")
        XCTAssertNotNil(openai.lookup("gpt-5.5"))
        XCTAssertEqual(openai.displayName("gpt-5-codex"), "GPT-5 Codex")
        // Claude adapter 也照常工作（守 Claude 零回归）
        let claude: any ModelPriceTable = ClaudeModelPriceTable.shared
        XCTAssertNotNil(claude.lookup("claude-opus-4-7"))
        XCTAssertEqual(claude.normalize("Claude-Opus-4-7-20260101"), "claude-opus-4-7")
        XCTAssertEqual(claude.displayName("claude-opus-4-7"), "Opus 4.7")
        XCTAssertNil(claude.lookup("claude-nonexistent"))
    }
}
