import XCTest
@testable import UsageBar

final class CodexRolloutCostParserTests: XCTestCase {
    private func line(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }
    private func tokenCount(input: Int, cached: Int, output: Int, reasoning: Int = 0) -> String {
        line(["timestamp": "2026-05-12T07:00:00.000Z", "type": "event_msg",
              "payload": ["type": "token_count",
                          "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": input + output],
                                   "total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": reasoning, "total_tokens": input + output]]]])
    }
    private func turnContext(model: String) -> String {
        line(["timestamp": "2026-05-12T07:00:00.000Z", "type": "turn_context", "payload": ["model": model]])
    }
    private func tokenCountNullInfo() -> String {
        line(["timestamp": "2026-05-12T07:00:00.000Z", "type": "event_msg", "payload": ["type": "token_count", "info": NSNull(), "rate_limits": ["plan_type": "free"]]])
    }

    func testNormalSequence() {
        let lines = [
            line(["timestamp": "2026-05-12T06:59:00.000Z", "type": "session_meta", "payload": ["id": "abc"]]),
            turnContext(model: "gpt-5"),
            tokenCountNullInfo(),                                     // 跳过
            tokenCount(input: 1000, cached: 600, output: 200, reasoning: 50),
            turnContext(model: "gpt-5-codex"),
            tokenCount(input: 500, cached: 0, output: 80),
        ]
        let evs = CodexRolloutCostParser.parseFile(lines: lines, sessionId: "S1")
        XCTAssertEqual(evs.count, 2)
        XCTAssertEqual(evs[0].model, "gpt-5")
        XCTAssertEqual(evs[0].inputTokens, 400)            // 1000 - 600
        XCTAssertEqual(evs[0].cacheReadInputTokens, 600)
        XCTAssertEqual(evs[0].outputTokens, 200)
        XCTAssertEqual(evs[0].cacheCreationInputTokens, 0)
        XCTAssertEqual(evs[0].sessionId, "S1")
        XCTAssertEqual(evs[0].reqId, "3")                  // lineIndex of the token_count line
        XCTAssertEqual(evs[0].msgId, "S1:3")
        XCTAssertEqual(evs[1].model, "gpt-5-codex")
        XCTAssertEqual(evs[1].inputTokens, 500)
        XCTAssertEqual(evs[1].cacheReadInputTokens, 0)
    }
    func testCollaborationModeModel() {
        let lines = [
            line(["timestamp": "2026-05-12T07:00:00.000Z", "type": "turn_context",
                  "payload": ["collaboration_mode": ["settings": ["model": "gpt-5-mini"]]]]),
            tokenCount(input: 10, cached: 0, output: 5),
        ]
        let evs = CodexRolloutCostParser.parseFile(lines: lines, sessionId: "S")
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].model, "gpt-5-mini")
    }
    func testTokenCountBeforeAnyModel() {
        let evs = CodexRolloutCostParser.parseFile(lines: [tokenCount(input: 10, cached: 0, output: 5)], sessionId: "S")
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].model, "unknown")
    }
    func testBadJSONLinesSkipped() {
        let lines = ["not json {{", turnContext(model: "gpt-5"), "{ also bad", tokenCount(input: 10, cached: 0, output: 5)]
        let evs = CodexRolloutCostParser.parseFile(lines: lines, sessionId: "S")
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].model, "gpt-5")
        XCTAssertEqual(evs[0].reqId, "3")                  // 行号按绝对位置，不被坏行打乱
    }
    func testEmpty() { XCTAssertTrue(CodexRolloutCostParser.parseFile(lines: [], sessionId: "S").isEmpty) }
    func testSessionIdFromFileName() {
        XCTAssertEqual(CodexRolloutCostParser.sessionId(fromFileName: "rollout-2026-05-12T19-24-05-019e1bee-0948-75c3-ae1a-bab380a1ffa9.jsonl"),
                       "019e1bee-0948-75c3-ae1a-bab380a1ffa9")
        XCTAssertEqual(CodexRolloutCostParser.sessionId(fromFileName: "weird.jsonl"), "weird")
    }
    func testStoredEventHasOnlyAllowedFields() throws {
        let evs = CodexRolloutCostParser.parseFile(lines: [turnContext(model: "gpt-5"), tokenCount(input: 100, cached: 10, output: 20)], sessionId: "S")
        let data = try JSONEncoder().encode(evs[0])
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let allowed: Set<String> = ["ts", "msgId", "reqId", "sessionId", "model", "inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens", "cacheCreation5mTokens", "cacheCreation1hTokens"]
        XCTAssertTrue(Set(dict.keys).isSubset(of: allowed), "StoredUsageEvent leaked extra keys: \(Set(dict.keys).subtracting(allowed))")
    }

    // MARK: 重复发射的 token_count

    private func tokenCount(last: (Int, Int, Int), total: (Int, Int, Int)?) -> String {
        var info: [String: Any] = ["last_token_usage": ["input_tokens": last.0, "cached_input_tokens": last.1, "output_tokens": last.2]]
        if let t = total { info["total_token_usage"] = ["input_tokens": t.0, "cached_input_tokens": t.1, "output_tokens": t.2] }
        return line(["timestamp": "2026-05-12T07:00:00.000Z", "type": "event_msg", "payload": ["type": "token_count", "info": info]])
    }
    func testRepeatedEmissionWithSameTotalIsSkipped() {
        let lines = [
            turnContext(model: "gpt-5"),
            tokenCount(last: (100, 50, 10), total: (100, 50, 10)),
            tokenCount(last: (100, 50, 10), total: (100, 50, 10)),   // codex CLI 重复发射
            tokenCount(last: (120, 100, 20), total: (220, 150, 30)),
            tokenCount(last: (120, 100, 20), total: (220, 150, 30)),
        ]
        let evs = CodexRolloutCostParser.parseFile(lines: lines, sessionId: "S")
        XCTAssertEqual(evs.map(\.reqId), ["1", "3"])
    }
    func testSameLastButAdvancedTotalIsKept() {
        let lines = [
            tokenCount(last: (100, 50, 10), total: (100, 50, 10)),
            tokenCount(last: (100, 50, 10), total: (200, 100, 20)),   // 真实的第二次调用，恰好 last 相同
        ]
        XCTAssertEqual(CodexRolloutCostParser.parseFile(lines: lines, sessionId: "S").count, 2)
    }
    func testWithoutTotalFallsBackToComparingLast() {
        let lines = [tokenCount(last: (100, 50, 10), total: nil), tokenCount(last: (100, 50, 10), total: nil),
                     tokenCount(last: (90, 50, 10), total: nil)]
        XCTAssertEqual(CodexRolloutCostParser.parseFile(lines: lines, sessionId: "S").map(\.reqId), ["0", "2"])
    }
    func testDropRepeatedEmissionsOnStoredEvents() {
        func ev(_ session: String, _ idx: Int, _ input: Int, model: String = "gpt-5") -> StoredUsageEvent {
            StoredUsageEvent(ts: Date(timeIntervalSince1970: 1_780_000_000 + Double(idx)), msgId: "\(session):\(idx)", reqId: String(idx),
                             sessionId: session, model: model, inputTokens: input, outputTokens: 5,
                             cacheReadInputTokens: 0, cacheCreation5mTokens: 0)
        }
        let events = [ev("A", 13, 10), ev("A", 8, 10), ev("A", 20, 10, model: "gpt-5-mini"), ev("A", 30, 11),
                      ev("B", 2, 10), ev("B", 9, 10), ev("B", 10, 12)]
        let kept = CodexRolloutCostParser.dropRepeatedEmissions(events)
        // A: 8 留、13 是 8 的重复、20 换了模型留、30 不同留；B: 2 留、9 重复、10 留。按数值行号排序（"13" < "8" 的字典序陷阱）
        XCTAssertEqual(Set(kept.map(\.msgId)), ["A:8", "A:20", "A:30", "B:2", "B:10"])
    }
}
