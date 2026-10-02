import XCTest
@testable import UsageBar

final class JSONLCostParserTests: XCTestCase {
    private let validAssistantLine = #"""
    {"type":"assistant","requestId":"req_mock_1","timestamp":"2026-05-11T09:24:52.422Z","sessionId":"sess_mock","message":{"id":"msg_mock_1","model":"claude-opus-4-7","role":"assistant","usage":{"input_tokens":6,"output_tokens":619,"cache_creation_input_tokens":26254,"cache_read_input_tokens":15896},"content":[{"type":"text","text":"this should never be parsed by our schema"}]}}
    """#

    func testValidAssistantLineDecodes() throws {
        let event = try JSONLCostParser.parseLine(validAssistantLine)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.messageId, "msg_mock_1")
        XCTAssertEqual(event?.requestId, "req_mock_1")
        XCTAssertEqual(event?.model, "claude-opus-4-7")
        XCTAssertEqual(event?.inputTokens, 6)
        XCTAssertEqual(event?.outputTokens, 619)
        XCTAssertEqual(event?.cacheCreationInputTokens, 26254)
        XCTAssertEqual(event?.cacheCreation5mTokens, 26254)
        XCTAssertEqual(event?.cacheCreation1hTokens, 0)
        XCTAssertEqual(event?.cacheReadInputTokens, 15896)
    }

    func testCacheCreationNestedSplits5mAnd1h() throws {
        let line = #"""
        {"type":"assistant","requestId":"req_mock_1","timestamp":"2026-05-11T09:24:52.422Z","message":{"id":"msg_mock_1","model":"claude-opus-4-7","usage":{"input_tokens":6,"output_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":40,"ephemeral_1h_input_tokens":60}}}}
        """#
        let event = try JSONLCostParser.parseLine(line)
        XCTAssertEqual(event?.cacheCreation5mTokens, 40)
        XCTAssertEqual(event?.cacheCreation1hTokens, 60)
        XCTAssertEqual(event?.cacheCreationInputTokens, 100)
    }

    func testCacheCreationMissingNestedUsesTopLevelAs5m() throws {
        let line = #"""
        {"type":"assistant","requestId":"req_mock_1","timestamp":"2026-05-11T09:24:52.422Z","message":{"id":"msg_mock_1","model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":77,"cache_read_input_tokens":0}}}
        """#
        let event = try JSONLCostParser.parseLine(line)
        XCTAssertEqual(event?.cacheCreation5mTokens, 77)
        XCTAssertEqual(event?.cacheCreation1hTokens, 0)
    }

    func testNonAssistantTypeReturnsNil() throws {
        let userLine = #"{"type":"user","timestamp":"2026-05-11T09:24:52.000Z","message":{"id":"x","model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"requestId":"r"}"#
        XCTAssertNil(try JSONLCostParser.parseLine(userLine))
    }

    func testEmptyLineReturnsNil() throws {
        XCTAssertNil(try JSONLCostParser.parseLine(""))
        XCTAssertNil(try JSONLCostParser.parseLine("   \n  "))
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try JSONLCostParser.parseLine("not json {"))
    }

    func testMissingRequiredFieldThrows() {
        // type=assistant but no message.usage
        let bad = #"{"type":"assistant","requestId":"r","timestamp":"2026-05-11T09:24:52.000Z","message":{"id":"x","model":"y"}}"#
        XCTAssertThrowsError(try JSONLCostParser.parseLine(bad))
    }

    /// SC7 关键守护：mock JSONL 含 message.content 字段，确认 JSONLUsageEvent 完全不暴露此信息。
    func testEnvelopeDoesNotDecodeContentField() throws {
        let event = try JSONLCostParser.parseLine(validAssistantLine)
        XCTAssertNotNil(event)
        // JSONLUsageEvent 类型本身不该有 content 属性 — 用 Mirror 反射验证
        let mirror = Mirror(reflecting: event!)
        let propertyNames = mirror.children.compactMap { $0.label }
        XCTAssertFalse(propertyNames.contains("content"), "JSONLUsageEvent 不应含 content 属性 (SC7 隐私守护)")
        XCTAssertFalse(propertyNames.contains("contentBlocks"))
        XCTAssertFalse(propertyNames.contains("text"))
    }

    func testIso8601WithoutFractionalParses() throws {
        let line = #"""
        {"type":"assistant","requestId":"r","timestamp":"2026-05-11T09:24:52Z","message":{"id":"m","model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """#
        let event = try JSONLCostParser.parseLine(line)
        XCTAssertNotNil(event)
    }

    func testRequestIdFallbackToMessageId() throws {
        let lineNoReqId = #"""
        {"type":"assistant","timestamp":"2026-05-11T09:24:52Z","message":{"id":"msg_only","model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """#
        let event = try JSONLCostParser.parseLine(lineNoReqId)
        XCTAssertEqual(event?.requestId, "msg_only")
    }

    func testSyntheticPlaceholderIsNotACall() throws {
        let line = #"{"type":"assistant","timestamp":"2026-05-11T09:24:52.422Z","isApiErrorMessage":true,"message":{"id":"msg_mock_s","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
        XCTAssertNil(try JSONLCostParser.parseLine(line))
    }
}
