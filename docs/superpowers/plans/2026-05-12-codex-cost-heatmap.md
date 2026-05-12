# Codex 本机成本扫描 + 消费热力图 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Codex tab 补齐「估算费用卡 + 消费热力图」对齐 Claude tab；为此把定价层抽成协议、加 OpenAI 估价表、写 Codex rollout 解析器 + collector、`UsageStatsService` per-provider、并去掉 Codex 的「Plan」卡 —— 全程 Claude / 既有行为零回归。

**Architecture:** `ModelPriceTable` 协议（`ClaudePricing` 不动，加 `ClaudeModelPriceTable` 适配器；`UsageAggregator`/`UsageEventStore.rebuild*`/`LocalCostCard` 加 Claude-默认参数）+ `OpenAIPricing` 估价表 + `CodexRolloutCostParser`（状态机）+ `CodexUsageCollector`（扫 `~/.codex/sessions/**`，cursor 只判「变没变」+ 整文件 re-parse，写 `UsageEventStore(provider:.codex)`）+ `UsageStatsService(pricing:, collector: any UsageCollecting)` + `convenience init(provider:)` + App 里第二个 `@StateObject codexStats` + `CodexProvider.onPollTick` + `PopoverView.ProviderHistorySection` 接 cost/heatmap。

**Tech Stack:** Swift 5.9 / SwiftUI / Swift Charts / actor + async / `JSONSerialization` / XCTest。命令用绝对路径（`cd /Users/methol/data/code-methol/usage-bar/macos` 或 repo 根）。

> 对应 spec：[`../specs/2026-05-12-codex-cost-heatmap.md`](../specs/2026-05-12-codex-cost-heatmap.md)（G2 approved-after-revisions）。机械细节（每个文件的精确改法）以 spec §3.1 为准；本 plan 给关键/有风险的代码 + 任务拆分 + 验证步骤。SC9 安全约束：`CodexRolloutCostParser` / `CodexUsageCollector` 里**不出现** `print`/`NSLog`/`os_log`，落盘只有 `StoredUsageEvent`/`ScanCursorFile`，测试 fixture 用明显假整数。

---

## File Structure（见 spec §3.1 / §4 的完整迁移表）

新建：`ModelPricing.swift`、`OpenAIPricing.swift`、`CodexRolloutCostParser.swift`、`CodexUsageCollector.swift`；测试 `OpenAIPricingTests.swift`、`CodexRolloutCostParserTests.swift`、`CodexUsageCollectorTests.swift`。
改：`ClaudePricing.swift`、`UsageAggregator.swift`、`UsageEventStore.swift`、`ScanCursorStore.swift`、`UsageStatsService.swift`、`LocalCostCard.swift`、`ProviderUsageSection.swift`、`UsageChartView.swift`、`PopoverView.swift`、`CodexProvider.swift`、`ClaudeUsageBarApp.swift`；测试 `UsageStatsServiceTests.swift` 追加。

---

## Task 1: 定价层泛化（`ModelPriceTable` + `OpenAIPricing`），Claude 零回归

**Files:** Create `ModelPricing.swift`, `OpenAIPricing.swift`, `Tests/.../OpenAIPricingTests.swift`; Modify `ClaudePricing.swift`, `UsageAggregator.swift`, `UsageEventStore.swift`, `LocalCostCard.swift`.

- [ ] **Step 1: 写 `OpenAIPricingTests.swift`（失败测试）**

```swift
import XCTest
@testable import ClaudeUsageBar

final class OpenAIPricingTests: XCTestCase {
    func testNormalizeStripsDateSuffixAndLowercases() {
        XCTAssertEqual(OpenAIPricing.normalize("GPT-5.5"), "gpt-5.5")
        XCTAssertEqual(OpenAIPricing.normalize("gpt-5.5-2026-01-01"), "gpt-5.5")
        XCTAssertEqual(OpenAIPricing.normalize("gpt-5-codex"), "gpt-5-codex")
    }
    func testLookupKnownAndUnknown() {
        XCTAssertNotNil(OpenAIPricing.lookup(model: "gpt-5.5"))
        XCTAssertNotNil(OpenAIPricing.lookup(model: "gpt-5-codex"))
        XCTAssertNil(OpenAIPricing.lookup(model: "gpt-9000"))
    }
    func testDisplayName() {
        XCTAssertEqual(OpenAIPricing.displayName("gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(OpenAIPricing.displayName("gpt-5-codex"), "GPT-5 Codex")
        XCTAssertEqual(OpenAIPricing.displayName("o4-mini"), "o4-mini")
    }
    func testModelUnitPricingCost() {
        let p = ModelUnitPricing(inputUSDPerMTok: 1, outputUSDPerMTok: 2, cacheReadUSDPerMTok: 0.1, cacheWriteUSDPerMTok: 0)
        XCTAssertEqual(p.cost(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 0), 3.1, accuracy: 1e-9)
    }
    func testTableConformsToProtocol() {
        let t: any ModelPriceTable = OpenAIModelPriceTable.shared
        XCTAssertEqual(t.normalize("GPT-5.5"), "gpt-5.5")
        XCTAssertNotNil(t.lookup("gpt-5.5"))
        // ClaudeModelPriceTable still works:
        XCTAssertNotNil(ClaudeModelPriceTable.shared.lookup("claude-opus-4-7"))
    }
}
```

- [ ] **Step 2: 跑确认失败** — `cd /Users/methol/data/code-methol/usage-bar/macos && swift test --filter OpenAIPricingTests` → 编译失败（`OpenAIPricing`/`ModelUnitPricing`/`OpenAIModelPriceTable`/`ClaudeModelPriceTable` 不存在）。

- [ ] **Step 3: 新建 `ModelPricing.swift`**

```swift
import Foundation

/// provider-无关的「模型→单价」表抽象。`ClaudePricing` / `OpenAIPricing` 各提供一个 conformer。
/// `: Sendable` —— `UsageStatsService.refresh()` 在 `Task.detached` 里用它。
protocol ModelPriceTable: Sendable {
    func normalize(_ model: String) -> String
    func lookup(_ model: String) -> ModelUnitPricing?
    func displayName(_ model: String) -> String
}

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

/// 「这个 provider 的费用怎么显示」—— 取代会穿多层 view 的 `(pricing:displayName:)` tuple。
struct ProviderCostContext {
    let pricing: any ModelPriceTable
    let displayName: (String) -> String
}
```

- [ ] **Step 4: 改 `ClaudePricing.swift` —— 加适配器（表/静态方法字节不动）**

在文件末尾追加：
```swift
/// `ModelPriceTable` 适配器 —— 转发到既有静态方法，`lookup` 把 `ClaudeModelPricing` 映成 `ModelUnitPricing`。
struct ClaudeModelPriceTable: ModelPriceTable {
    static let shared = ClaudeModelPriceTable()
    func normalize(_ model: String) -> String { ClaudePricing.normalize(model) }
    func displayName(_ model: String) -> String { ClaudePricing.displayName(model) }
    func lookup(_ model: String) -> ModelUnitPricing? {
        guard let p = ClaudePricing.lookup(model: model) else { return nil }
        return ModelUnitPricing(inputUSDPerMTok: p.inputUSDPerMTok,
                                outputUSDPerMTok: p.outputUSDPerMTok,
                                cacheReadUSDPerMTok: p.cacheReadUSDPerMTok,
                                cacheWriteUSDPerMTok: p.cacheWriteUSDPerMTok)
    }
}
```
（确认 `ClaudeModelPricing` 的字段名 —— Explore 报告是 `inputUSDPerMTok` / `outputUSDPerMTok` / `cacheReadUSDPerMTok` / `cacheWriteUSDPerMTok`；实施时读文件核对，名字不一致就照实际改。）

- [ ] **Step 5: 新建 `OpenAIPricing.swift`**

```swift
import Foundation

/// OpenAI 模型的 list-price 估价表。
/// ⚠️ 这些是 best-effort 估算（按 OpenAI 各模型的 list price 推算的 per-Mtok 价），**不是真实账单**——
/// Codex / ChatGPT 套餐（Free/Plus/Pro）是「套餐包额度」计费；Codex tab 的 USD 与 Claude tab 一样是合成估算。
/// 过期了改这张表。`cacheWriteUSDPerMTok` 一律 0（OpenAI 自动 prompt caching，无 cache-write 计费）。
enum OpenAIPricing {
    static let snapshotDate = "2026-05-12"

    private static let table: [String: ModelUnitPricing] = [
        // key 必须是 normalize 后的小写名。每项 // UNVERIFIED — list-price estimate
        "gpt-5.5":      .init(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 0), // UNVERIFIED
        "gpt-5.1":      .init(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 0), // UNVERIFIED
        "gpt-5":        .init(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 0), // UNVERIFIED
        "gpt-5-codex":  .init(inputUSDPerMTok: 1.25, outputUSDPerMTok: 10.0, cacheReadUSDPerMTok: 0.125, cacheWriteUSDPerMTok: 0), // UNVERIFIED
        "gpt-5-mini":   .init(inputUSDPerMTok: 0.25, outputUSDPerMTok: 2.0,  cacheReadUSDPerMTok: 0.025, cacheWriteUSDPerMTok: 0), // UNVERIFIED
        "gpt-5-nano":   .init(inputUSDPerMTok: 0.05, outputUSDPerMTok: 0.4,  cacheReadUSDPerMTok: 0.005, cacheWriteUSDPerMTok: 0), // UNVERIFIED
        "o3":           .init(inputUSDPerMTok: 2.0,  outputUSDPerMTok: 8.0,  cacheReadUSDPerMTok: 0.5,   cacheWriteUSDPerMTok: 0), // UNVERIFIED
        "o4-mini":      .init(inputUSDPerMTok: 1.1,  outputUSDPerMTok: 4.4,  cacheReadUSDPerMTok: 0.275, cacheWriteUSDPerMTok: 0), // UNVERIFIED
    ]

    /// 去尾部日期后缀（`-YYYY-MM-DD` 或 `-YYYYMMDD`）+ 小写。
    static func normalize(_ model: String) -> String {
        let lower = model.lowercased()
        // -YYYY-MM-DD
        if let r = lower.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            return String(lower[..<r.lowerBound])
        }
        // -YYYYMMDD
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
        default: return model   // 原样（未知）
        }
    }
}

struct OpenAIModelPriceTable: ModelPriceTable {
    static let shared = OpenAIModelPriceTable()
    func normalize(_ model: String) -> String { OpenAIPricing.normalize(model) }
    func lookup(_ model: String) -> ModelUnitPricing? { OpenAIPricing.lookup(model: model) }
    func displayName(_ model: String) -> String { OpenAIPricing.displayName(model) }
}
```

- [ ] **Step 6: 改 `UsageAggregator.swift`** —— 给 `usdForBucket` / `dailySpend` / `monthlySpend` / `costForEvents` / `rolling30dSummary` 加 `pricing: ModelPriceTable = ClaudeModelPriceTable.shared`，给 `foldByDay/foldByMonth/foldByYear` 加 `normalize: @Sendable (String)->String = { ClaudePricing.normalize($0) }`；把内部写死的 `ClaudePricing.normalize` 换成参数 `normalize`，`ClaudePricing.lookup(model:)` 换成 `pricing.lookup(_:)`、`ClaudePricing.cost(for:input:output:cacheRead:cacheWrite:)` 换成 `(pricing.lookup(m) ?? <zero>)`?? —— 注意 `ClaudePricing.cost(for: ClaudeModelPricing?, ...)` 接受 nil（未知 → 0）；`ModelUnitPricing` 没有「nil 版本」，所以写：`let unit = pricing.lookup(normalizedModel); let usd = unit?.cost(input:..., output:..., cacheRead:..., cacheWrite:...) ?? 0; let isUnknown = (unit == nil)`。读 `UsageAggregator.swift` 现有 `usdForBucket` 实现照搬这个结构。其余（`dailySpend`/`monthlySpend` 只是聚合金额、`costForEvents`/`rolling30dSummary` 内部调 `usdForBucket`/fold —— 把 `pricing`/`normalize` 一路透传）不动。

- [ ] **Step 7: 改 `UsageEventStore.swift`** —— `rebuildAllAggregates(normalize: @Sendable (String)->String = { ClaudePricing.normalize($0) })` 与 `rebuildAggregates(forDayKeys: Set<String>, normalize: @Sendable (String)->String = { ClaudePricing.normalize($0) })`：把 `normalize` 透传给它们内部调的 `UsageAggregator.foldBy*`。读现有这两个方法体照改。其余不动。

- [ ] **Step 8: 改 `LocalCostCard.swift`** —— `struct LocalCostCard` 加 `var displayName: (String) -> String = { ClaudePricing.displayName($0) }`；把 `Text(ClaudePricing.displayName(row.normalizedModel))` 改成 `Text(displayName(row.normalizedModel))`。

- [ ] **Step 9: build + 全量 test（G4 + 守 SC8 零回归）**

Run: `cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release && swift test`
Expected: build OK；全部 tests PASS（既有 `UsageAggregatorTests` / `ClaudePricingTests` / `UsageEventStoreTests` / `UsageStatsServiceTests`(Claude) 不动全绿 + 新 `OpenAIPricingTests` 绿）。

- [ ] **Step 10: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/ClaudeUsageBar/{ModelPricing,OpenAIPricing,ClaudePricing,UsageAggregator,UsageEventStore,LocalCostCard}.swift macos/Tests/ClaudeUsageBarTests/OpenAIPricingTests.swift
git commit -m "feat: v0.2.9 — 抽 ModelPriceTable 协议 + OpenAIPricing 估价表；UsageAggregator/UsageEventStore.rebuild*/LocalCostCard 加 Claude-默认参数（Claude 零回归）[spec:2026-05-12-codex-cost-heatmap]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `CodexRolloutCostParser`

**Files:** Create `CodexRolloutCostParser.swift`, `Tests/.../CodexRolloutCostParserTests.swift`.

- [ ] **Step 1: 写 `CodexRolloutCostParserTests.swift`（失败测试）** —— 见 spec §3.3 的 `CodexRolloutCostParserTests` 清单，写成实际 XCTest：

```swift
import XCTest
@testable import ClaudeUsageBar

final class CodexRolloutCostParserTests: XCTestCase {
    private func line(_ obj: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! }
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
        let allowed: Set<String> = ["ts", "msgId", "reqId", "sessionId", "model", "inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"]
        XCTAssertTrue(Set(dict.keys).isSubset(of: allowed), "StoredUsageEvent leaked extra keys: \(Set(dict.keys).subtracting(allowed))")
    }
}
```

> 注：`StoredUsageEvent` 的 `Codable` key 名以 `UsageStoreTypes.swift` 实际为准（Explore 报告是 `ts/msgId/reqId/sessionId/model/inputTokens/outputTokens/cacheReadInputTokens/cacheCreationInputTokens`）—— 实施时读文件核对，`allowed` 集合照实际填。`testNormalSequence` 里 `reqId == "3"` 取决于行号从 0 起：lines[0]=session_meta, [1]=turn_context, [2]=token_count(null,跳过), [3]=token_count → reqId "3"。

- [ ] **Step 2: 跑确认失败** — `swift test --filter CodexRolloutCostParserTests` → 编译失败。

- [ ] **Step 3: 新建 `CodexRolloutCostParser.swift`**

```swift
import Foundation

/// 解析 OpenAI codex CLI 的 rollout JSONL（`~/.codex/sessions/**/rollout-*.jsonl`）抽 token 用量。
/// **状态机**：模型名出现在 `turn_context` 行、token 出现在后续 `event_msg/token_count` 行 → 边走边跟踪「当前模型」。
/// 落出来的只有 `StoredUsageEvent`（token 计数 + 模型名 + 时间 + 合成 id）—— 不碰 rollout 里的对话/代码原文（SC9）。
enum CodexRolloutCostParser {
    static func parseFile(lines: [String], sessionId: String) -> [StoredUsageEvent] {
        var currentModel: String? = nil
        var out: [StoredUsageEvent] = []
        for (idx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }   // 坏行跳过、不抛
            let payload = obj["payload"] as? [String: Any]
            // ① 模型行（turn_context.payload.model 或 collaboration_mode.settings.model）
            if let m = (payload?["model"] as? String)
                ?? ((payload?["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any])?["model"] as? String,
               !m.isEmpty {
                currentModel = m
            }
            // ② token_count 事件
            guard (obj["type"] as? String) == "event_msg",
                  (payload?["type"] as? String) == "token_count",
                  let info = payload?["info"] as? [String: Any],   // info==null → 不是 [String:Any] → 跳过
                  let lt = info["last_token_usage"] as? [String: Any]
            else { continue }
            let inputAll = (lt["input_tokens"] as? Int) ?? 0
            let cached = (lt["cached_input_tokens"] as? Int) ?? 0
            let output = (lt["output_tokens"] as? Int) ?? 0
            let ts = (obj["timestamp"] as? String).flatMap(Self.iso8601) ?? Date()
            out.append(StoredUsageEvent(
                ts: ts,
                msgId: "\(sessionId):\(idx)",
                reqId: String(idx),
                sessionId: sessionId,
                model: currentModel ?? "unknown",
                inputTokens: max(inputAll - cached, 0),
                outputTokens: max(output, 0),
                cacheReadInputTokens: max(cached, 0),
                cacheCreationInputTokens: 0
            ))
        }
        return out
    }

    static func sessionId(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        if let r = base.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) {
            return String(base[r])
        }
        return base
    }

    private static let iso8601Fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func iso8601(_ s: String) -> Date? {
        iso8601Fmt.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
```

> ⚠️ 实施时核对 `StoredUsageEvent` 的初始化器签名（参数名/顺序）与 `UsageStoreTypes.swift` 一致；若 `JSONSerialization` 把整数解析成 `NSNumber` 而 `as? Int` 失败，改成 `(lt["input_tokens"] as? NSNumber)?.intValue ?? 0`（Foundation JSON 数字一般能 `as? Int`，但保险起见实测）。

- [ ] **Step 4: 跑确认通过** — `swift test --filter CodexRolloutCostParserTests` → all PASS（若 `reqId`/字段名/数字桥接有出入，按上面注释调）。

- [ ] **Step 5: build + 全量 test** — `swift build -c release && swift test` → 全绿。

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/CodexRolloutCostParser.swift macos/Tests/ClaudeUsageBarTests/CodexRolloutCostParserTests.swift
git commit -m "feat: v0.2.9 — CodexRolloutCostParser：状态机解析 ~/.codex/sessions rollout JSONL（turn_context.model + token_count.last_token_usage → StoredUsageEvent，只抽 token/model/ts，不碰对话原文）[spec:2026-05-12-codex-cost-heatmap]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `ScanCursorStore` per-provider + `CodexUsageCollector`

**Files:** Modify `ScanCursorStore.swift`; Create `CodexUsageCollector.swift`, `Tests/.../CodexUsageCollectorTests.swift`.

- [ ] **Step 1: 改 `ScanCursorStore.swift`** —— `init(dataDirOverride: URL? = nil, provider: ProviderID = .claude)`；cursor 文件名 `provider == .claude ? "scan-cursor.json" : "scan-cursor-\(provider.rawValue).json"`，仍放在原 `dataDir`。其余不动。读现有 `init` 照改。

- [ ] **Step 2: 写 `CodexUsageCollectorTests.swift`（失败测试）** —— 见 spec §3.3 清单：

```swift
import XCTest
@testable import ClaudeUsageBar

final class CodexUsageCollectorTests: XCTestCase {
    private var tmp: URL!
    private var sessionsDir: URL!
    private var rolloutFile: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        sessionsDir = tmp.appendingPathComponent("sessions/2026/05/12", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        rolloutFile = sessionsDir.appendingPathComponent("rollout-2026-05-12T07-00-00-019e1bee-0948-75c3-ae1a-bab380a1ffa9.jsonl")
        let lines = [
            #"{"timestamp":"2026-05-12T07:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-05-12T07:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":300,"reasoning_output_tokens":0,"total_tokens":1300},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":300,"reasoning_output_tokens":0,"total_tokens":1300}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: rolloutFile)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeCollector() -> (CodexUsageCollector, UsageEventStore) {
        let store = UsageEventStore(dataDirOverride: tmp, provider: .codex)
        let cursor = ScanCursorStore(dataDirOverride: tmp, provider: .codex)
        return (CodexUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmp.appendingPathComponent("sessions")]), store)
    }

    func testCollectFindsEventsAndAggregates() async throws {
        let (c, store) = makeCollector()
        let r1 = await c.collect()
        XCTAssertGreaterThan(r1.newEventCount, 0)
        let day = await store.readDayAggregates()
        XCTAssertFalse(day.isEmpty)
    }
    func testSecondCollectSkipsUnchangedFile() async throws {
        let (c, _) = makeCollector()
        _ = await c.collect()
        let r2 = await c.collect()
        XCTAssertEqual(r2.newEventCount, 0)
    }
    func testAppendedLineReParsesAndDedups() async throws {
        let (c, store) = makeCollector()
        _ = await c.collect()
        // 起初 store 里 1 个 event（setUp 里 1 个 token_count 行）
        let far = Date(timeIntervalSince1970: 0); let future = Date().addingTimeInterval(86400 * 3650)
        let beforeCount = await store.queryEvents(from: far, to: future).count
        XCTAssertEqual(beforeCount, 1)
        let extra = #"{"timestamp":"2026-05-12T07:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":600},"total_token_usage":{"input_tokens":1500,"cached_input_tokens":200,"output_tokens":400,"reasoning_output_tokens":0,"total_tokens":1900}}}}"# + "\n"
        let fh = try FileHandle(forWritingTo: rolloutFile); fh.seekToEndOfFile(); fh.write(extra.data(using: .utf8)!); fh.closeFile()
        let r = await c.collect()
        // 整文件 re-parse → 解析出 2 个 token_count event（与 Claude collector 一致：newEventCount = 本次解析数）
        XCTAssertEqual(r.newEventCount, 2)
        // 但 (msgId,reqId)=sessionId:lineIndex 去重 → store 里只净增 1 个 → 共 2 个
        let afterCount = await store.queryEvents(from: far, to: future).count
        XCTAssertEqual(afterCount, 2)
    }
    func testScanRootsParsesCodexHome() {
        let roots = CodexUsageCollector.scanRoots(env: ["CODEX_HOME": tmp.path], home: URL(fileURLWithPath: "/nonexistent"), fileExists: { _ in true })
        XCTAssertEqual(roots.first, tmp.appendingPathComponent("sessions"))
    }
}
```

> 注：`UsageEventStore.init` / `readDayAggregates` / `CollectResult.newEventCount` 的精确签名以现有文件为准；`CodexUsageCollector.scanRoots(env:home:fileExists:)` 的参数名仿 `ClaudeUsageCollector.scanRoots(env:home:fileExists:)`（Explore 报告有这个测试变体 —— 读 `ClaudeUsageCollector.swift` 照搬签名）。

- [ ] **Step 3: 跑确认失败** — `swift test --filter CodexUsageCollectorTests` → 编译失败。

- [ ] **Step 4: 新建 `CodexUsageCollector.swift`** —— 对照 `ClaudeUsageCollector.swift` 的结构（读它）；关键差异：
  - `scanRoots()` = `$CODEX_HOME/sessions` 优先、否则 `~/.codex/sessions`（存在才纳入）；`scanRoots(env:home:fileExists:)` 测试变体。
  - 枚举 `*.jsonl`；对每个文件读 `size`/`mtime` → `await cursor.nextReadOffset(for: file, currentSize: size, currentMTime: mtime)` —— **返回 nil（没变）→ skip；非 nil → 整文件读全部行**（不管返回的 offset 是几，都从 0 读）。
  - `let sid = CodexRolloutCostParser.sessionId(fromFileName: file.lastPathComponent)`；`let events = CodexRolloutCostParser.parseFile(lines: allLines, sessionId: sid)`；累加到 `collected`；`await cursor.updateCursor(for: file, size: size, mtime: mtime, lineOffset: allLines.count)`。
  - 全部文件后：`let dirty = await store.mergeEvents(collected)`；`if dirty.isEmpty { await store.rebuildAggregates(forDayKeys: touchedDayKeys, normalize: { OpenAIPricing.normalize($0) }) } else { await store.rebuildAllAggregates(normalize: { OpenAIPricing.normalize($0) }) }`（`touchedDayKeys` 由 `collected` 的 `ts` 算 local day key —— 用 `UsageAggregator.localDayKey($0.ts)` 收成 `Set`，仿 `ClaudeUsageCollector` 怎么算的，照它；为简单也可直接 `await store.rebuildAllAggregates(normalize:)`，但既然 Claude collector 有增量版就照搬）；`await cursor.flush()`；返回 `CollectResult(newEventCount: collected.count, scannedFileCount: <扫到的文件数>, parseErrorCount: 0, touchedDayKeys: touchedDayKeys)`。
  - **`newEventCount` 语义**：= `collected.count`（**本次解析出的 event 数**），与 `ClaudeUsageCollector` 一致（它就是 `newEventCount: collected.count`）—— **不**试图算「去重后净新增」（`UsageEventStore.mergeEvents` 只返回 dirty month keys、不返回净新增数）。整文件 re-parse 时 `collected.count` 会包含已存在的 event，靠 `(msgId,reqId)=sessionId:lineIndex` 在 `mergeEvents` 里去重保证 store 不重复 —— 这正是 `testAppendedLineReParsesAndDedups` 验证的（`newEventCount==2`、但 `store.queryEvents().count==2`）。`ClaudeUsageCollector` 字节不变（SC8 不破）。
  - `inFlight` 防重入（同 Claude collector）。
  - **绝不出现 `print` / `NSLog` / `os_log`**（SC9）—— ⚠️ 注意 `ClaudeUsageCollector` 里有一行 `NSLog` 打 parse error（`ClaudeUsageCollector.swift` 约 :63）、`ScanCursorStore`/`UsageEventStore` 也有 `NSLog`；**「对照 Claude collector 结构」时不要把那行 `NSLog` 抄过来** —— Codex 路径解析失败就静默跳过（rollout 文件含用户对话原文，连「第几行解析失败」都不打）。
  - `: UsageCollecting` conformance（协议在 Task 4 定义；本 Task 先只写 `func collect() async -> CollectResult`、Task 4 再补 `: UsageCollecting`，或把「定义 `UsageCollecting`」提到本 Task 开头 —— 实施时挑，编过即可）。

- [ ] **Step 5: 跑确认通过** — `swift test --filter CodexUsageCollectorTests` → all PASS。`testSecondCollectSkipsUnchangedFile` / `testAppendedLineReParsesAndDedups` 是 cursor + 去重逻辑的关键 —— 若不过，回到 Step 4 核对 `nextReadOffset` 的「没变返回 nil」语义 + `mergeEvents` 的 `(msgId,reqId)` 去重。

- [ ] **Step 6: build + 全量 test** — `swift build -c release && swift test` → 全绿（既有 `ScanCursorStoreTests` 不动全绿）。

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/{ScanCursorStore,CodexUsageCollector}.swift macos/Tests/ClaudeUsageBarTests/CodexUsageCollectorTests.swift
git commit -m "feat: v0.2.9 — ScanCursorStore 加 per-provider（Claude 保 scan-cursor.json 旧名）；CodexUsageCollector 扫 ~/.codex/sessions/** → CodexRolloutCostParser → UsageEventStore(provider:.codex)（cursor 只判变没变 + 整文件 re-parse + 去重幂等）[spec:2026-05-12-codex-cost-heatmap]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `UsageStatsService` 泛化（`UsageCollecting` + `pricing:` + `convenience init(provider:)`）

**Files:** Modify `UsageStatsService.swift`, `ClaudeUsageCollector.swift`（加 `: UsageCollecting`）, `CodexUsageCollector.swift`（加 `: UsageCollecting`）; Modify `Tests/.../UsageStatsServiceTests.swift`（追加 Codex 端到端）.

- [ ] **Step 1: 写失败测试（追加到 `UsageStatsServiceTests.swift`）**

```swift
    func testCodexStatsEndToEnd() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsDir = tmp.appendingPathComponent("sessions/2026/05/12", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let rollout = sessionsDir.appendingPathComponent("rollout-2026-05-12T07-00-00-019e1bee-0948-75c3-ae1a-bab380a1ffa9.jsonl")
        let lines = [
            #"{"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"output_tokens":20000,"reasoning_output_tokens":0,"total_tokens":120000},"total_token_usage":{"input_tokens":100000,"cached_input_tokens":0,"output_tokens":20000,"reasoning_output_tokens":0,"total_tokens":120000}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: rollout)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = UsageEventStore(dataDirOverride: tmp, provider: .codex)
        let collector = CodexUsageCollector(store: store, cursor: ScanCursorStore(dataDirOverride: tmp, provider: .codex), scanRootsOverride: [tmp.appendingPathComponent("sessions")])
        let svc = await UsageStatsService(store: store, collector: collector, pricing: OpenAIModelPriceTable.shared)
        await svc.refresh()
        await MainActor.run {
            XCTAssertFalse(svc.dailySpend.isEmpty)
            XCTAssertGreaterThan(svc.rolling30d?.totalUSD ?? 0, 0)   // 100k input × $1.25/Mtok + 20k output × $10/Mtok > 0
            XCTAssertFalse(svc.recentEvents.isEmpty)
        }
    }
```

> `UsageStatsService` 是 `@MainActor` —— DI init 的调用、`await refresh()`、读 `@Published` 都要在 MainActor 上（测试方法标 `@MainActor` 或用 `await MainActor.run`，按既有 `UsageStatsServiceTests` 的写法照搬）。`ISO8601DateFormatter().string(from:)` 不带 fractional seconds —— parser 的 `iso8601` 兜底那个 plain `ISO8601DateFormatter()` 会接住。

- [ ] **Step 2: 跑确认失败** — `swift test --filter UsageStatsServiceTests` → 编译失败（`UsageStatsService.init(store:collector:pricing:)` 不存在 / `collector` 类型不匹配）。

- [ ] **Step 3: 改 `UsageStatsService.swift`**
  - 加 `protocol UsageCollecting: Sendable { func collect() async -> CollectResult }`（放本文件顶部或 `UsageProvider.swift` 旁边 —— 实施时挑；倾向本文件）。
  - DI init：`init(store: UsageEventStore, collector: any UsageCollecting, pricing: ModelPriceTable = ClaudeModelPriceTable.shared)`；存 `private let pricing: ModelPriceTable`。
  - `refresh()` 里调 `UsageAggregator` 的**三处**（`UsageStatsService.swift` 现有 `refresh()` 体里只有这三个：`dailySpend(from:)`、`monthlySpend(from:)`、`rolling30dSummary(dayAggregates:now:scannedFileCount:parseErrorCount:)`）各加 `pricing: pricing`；`costForEvents` 不在 `refresh()` 里（它在 `UsageChartSectionView` —— Task 5 处理）。读现有 `refresh()` 体照改。
  - `convenience init()` 不变；改成 `self.init(store: UsageEventStore(), collector: ClaudeUsageCollector(store:..., cursor: ScanCursorStore()))` —— 注意现在 `collector` 参数类型是 `any UsageCollecting`，`ClaudeUsageCollector` 加 `: UsageCollecting` 后能传。
  - 加 `convenience init(provider: ProviderID)`：
    ```swift
    convenience init(provider: ProviderID) {
        switch provider {
        case .codex:
            let store = UsageEventStore(provider: .codex)
            self.init(store: store,
                      collector: CodexUsageCollector(store: store, cursor: ScanCursorStore(provider: .codex)),
                      pricing: OpenAIModelPriceTable.shared)
        default:
            let store = UsageEventStore()
            self.init(store: store, collector: ClaudeUsageCollector(store: store, cursor: ScanCursorStore()))
        }
    }
    ```
  - `static let shared` 不变。

- [ ] **Step 4: `ClaudeUsageCollector` / `CodexUsageCollector` 加 `: UsageCollecting`** —— 它们已有 `func collect() async -> CollectResult`，只需在 actor 声明加 conformance。

- [ ] **Step 5: 跑确认通过** — `swift test --filter UsageStatsServiceTests` → all PASS（含新 `testCodexStatsEndToEnd` + 既有 Claude 用例）。

- [ ] **Step 6: build + 全量 test** — `swift build -c release && swift test` → 全绿。

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/{UsageStatsService,ClaudeUsageCollector,CodexUsageCollector}.swift macos/Tests/ClaudeUsageBarTests/UsageStatsServiceTests.swift
git commit -m "feat: v0.2.9 — UsageStatsService 加 pricing 参数 + UsageCollecting 协议 + convenience init(provider:)（Claude 行为不变）；ClaudeUsageCollector/CodexUsageCollector conform UsageCollecting [spec:2026-05-12-codex-cost-heatmap]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Codex tab UI 接线（去 Plan 卡 + 估算费用卡 + 热力图 + `CodexProvider.onPollTick` + App）

**Files:** Modify `ProviderUsageSection.swift`, `UsageChartView.swift`, `PopoverView.swift`, `CodexProvider.swift`, `ClaudeUsageBarApp.swift`. 无新增单测（纯 SwiftUI 组合 + 接线）—— 由 `swift build` + Task 6 的 `manual_checks` 覆盖；`UsageAggregator.costForEvents`/`UsageHeatmapView` 本身已有测试。

- [ ] **Step 1: `ProviderUsageSection.swift`** —— 删掉渲染 `snap?.planLabel` 那张 `UsageCard`（连同它的 `if let plan = ...`）。

- [ ] **Step 2: `UsageChartView.swift`** —— `UsageChartSectionView` 加 `var costContext: ProviderCostContext? = nil`；`costSummary` 计算改 `UsageAggregator.costForEvents(recentEvents, since: cutoff, now: Date(), pricing: costContext?.pricing ?? ClaudeModelPriceTable.shared)`；`LocalCostCard(summary: cost, displayName: costContext?.displayName ?? { ClaudePricing.displayName($0) })`。

- [ ] **Step 3: `PopoverView.swift`**
  - `ProviderHistorySection` 加 `var costStats: UsageStatsService? = nil`（普通 `let`，**不**是 `@ObservedObject` —— Optional 不能）、`var costContext: ProviderCostContext? = nil`。`codexStats` 的 `@Published` 变化要能驱动重渲染 → 把「折线图(带 cost 卡) + 热力图」那段拆进一个内层、持非-Optional `@ObservedObject` 的子 view `ProviderCostArea`。具体（`PopoverView.swift` 内、`ProviderHistorySection` 旁，`private struct`）：

```swift
    /// 带本机成本数据的折线图区 + 消费热力图（mirror `claudeUsageArea` 的对应段）。`stats` 是非-Optional 的
    /// `@ObservedObject` —— 这样 codexStats 的 @Published 变化能驱动这子树重渲染（v0.2.5 G5 nit 同款套路）。
    private struct ProviderCostArea: View {
        @ObservedObject var historyService: UsageHistoryService
        @ObservedObject var stats: UsageStatsService
        let costContext: ProviderCostContext
        let primaryLabel: String
        let secondaryLabel: String
        var body: some View {
            UsageCard {
                UsageChartSectionView(historyService: historyService, recentEvents: stats.recentEvents,
                                      primaryLabel: primaryLabel, secondaryLabel: secondaryLabel, costContext: costContext)
            }
            if !stats.dailySpend.isEmpty && !stats.dailySpend.allSatisfy({ $0.usd == 0 }) {
                UsageCard { UsageHeatmapView(daySpends: stats.dailySpend, isInitializing: stats.isInitializing) }
            }
        }
    }
```

  `ProviderHistorySection.body` 改成：
```swift
        var body: some View {
            let pts = historyService.history.dataPoints
            let snap = runtime.snapshot
            let t5 = computeTrend(currentPct: snap?.primaryWindow?.utilizationPct, points: pts, metric: \.pct5h)
            let t7 = computeTrend(currentPct: snap?.secondaryWindow?.utilizationPct, points: pts, metric: \.pct7d)
            ProviderUsageSection(runtime: runtime, trendPrimary: t5, trendSecondary: t7)
            if let cs = costStats, let cc = costContext {
                ProviderCostArea(historyService: historyService, stats: cs, costContext: cc,
                                 primaryLabel: primaryLabel, secondaryLabel: secondaryLabel)
            } else {
                UsageCard { UsageChartSectionView(historyService: historyService, recentEvents: [],
                                                  primaryLabel: primaryLabel, secondaryLabel: secondaryLabel) }
            }
        }
```
  （`UsageChartSectionView` 的 `costContext` 参数顺序按 Task 5 Step 2 加在末尾、有默认 → Claude 调用点不写它。）
  - `ProviderUsageArea` 加 `var costStats: UsageStatsService? = nil`、`var costContext: ProviderCostContext? = nil`，透传给 `ProviderHistorySection`。
  - `PopoverView` 加构造参数 `@ObservedObject var codexStats: UsageStatsService`（放在 `historyService` 旁）。
  - `providerArea` 的 Codex 分支：`let costStats: UsageStatsService? = (selectedProvider == .codex ? codexStats : nil)`；`let costContext: ProviderCostContext? = (selectedProvider == .codex ? ProviderCostContext(pricing: OpenAIModelPriceTable.shared, displayName: { OpenAIPricing.displayName($0) }) : nil)`；连同 v0.2.8 的 `history`（trend/linechart）一起传进 `ProviderUsageArea(... history:, costStats:, costContext:, bottomBar:)`。
  - Claude 的 `claudeUsageArea` 不动。

- [ ] **Step 4: `CodexProvider.swift`** —— 加 `var onPollTick: (@MainActor () -> Void)? = nil`；`startPolling()` 的「立即一次」`Task { [weak self] in await self?.refreshNow() }` 后面 + timer sink 里，加 `onPollTick?()`（在 sink 闭包里直接调，sink 已在 main run loop；立即那次在 `Task` 里调 `await self?.refreshNow()` 之外也调一次 `self?.onPollTick?()` —— 或更简单：`startPolling()` 末尾 `onPollTick?()` 调一次 + 每次 sink 调一次）。

- [ ] **Step 5: `ClaudeUsageBarApp.swift`**
  - 加 `@StateObject private var codexStats = UsageStatsService(provider: .codex)`。
  - `PopoverView(coordinator:, claude:, historyService:, notificationService:, appUpdater:, codexStats: codexStats)`。
  - `.task` 里：`await usageStats.refresh()` 之后加 `await codexStats.refresh()`；`if let codex = coordinator.provider(.codex) as? CodexProvider { codex.onPollTick = { Task.detached { await codexStats.refresh() } } }`（放在现有 `codex.startPolling()` 之前）。

- [ ] **Step 6: build + 全量 test** — `cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release && swift test` → build OK；全部 tests PASS（无新测试，回归确认）。

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/{ProviderUsageSection,UsageChartView,PopoverView,CodexProvider,ClaudeUsageBarApp}.swift
git commit -m "feat: v0.2.9 — Codex tab：去掉 Plan 卡；折线图下接估算费用卡 + tab 底接消费热力图（ProviderCostContext）；CodexProvider.onPollTick 驱动 codexStats 刷新；App 加 @StateObject codexStats [spec:2026-05-12-codex-cost-heatmap]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 全量验收 + 回填文档（G6）

- [ ] **Step 1: build + test + artifacts + verify**

```bash
cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release && swift test
cd /Users/methol/data/code-methol/usage-bar && make release-artifacts && bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip
grep -rn 'print(\|NSLog\|os_log' macos/Sources/ClaudeUsageBar/CodexRolloutCostParser.swift macos/Sources/ClaudeUsageBar/CodexUsageCollector.swift   # 期望无命中（SC9 / SC_AUTO_NO_RAW_LOG）
```
Expected: build OK；全部 tests PASS；zip/dmg 产出 + verify "Release archive looks good"；grep 无命中。

- [ ] **Step 2: `make install` + 手动 smoke** — 重开 app，切 Codex tab：折线图下方有估算费用卡（模型名 `GPT-5.x`）、tab 底有消费热力图、无「Plan」卡；Claude tab 不变。把观察记到 spec evidence + Verification log。

- [ ] **Step 3: 回填 spec/version** — `2026-05-12-codex-cost-heatmap.md`：`spec_criteria[].done` 全 `true` + 填 `evidence`，Verification log 全勾，`status: accepted` → `implemented`。`docs/versions/v0.2.9-codex-cost-heatmap.md`：`status: planned` → `in-progress`，填 `release_notes_zh`（改进：Codex tab 加估算费用卡 + 消费热力图、去掉 Plan 卡；内部：抽 ModelPriceTable 协议 + OpenAIPricing 估价表 + CodexRolloutCostParser/CodexUsageCollector；隐私：rollout 文件只抽 token/model/时间、不落对话原文），G6 checklist 勾上。`docs/versions/README.md` + `docs/superpowers/specs/README.md` 同步状态。`docs/superpowers/plans/2026-05-12-codex-cost-heatmap.md`：勾掉本 plan 的步骤（除 Task 7 的 G5/PR）。Commit。

- [ ] **Step 4: G5 + PR + merge** — 独立 reviewer（codex `codex-rescue` / `general-purpose` subagent）code-review + security-review（敏感面：读 `~/.codex/sessions/**` 含完整对话/代码的文件 → 只抽 token；新增 `data/codex/`）。verdict approved 后 `gh pr create`（中文，含 spec id + version 链接），等 CI（"build" job）绿 → `git checkout main && git merge --ff-only feat/v0.2.9-codex-cost-heatmap && git push origin main` + 删分支。G5 verdict append 进 spec `reviews:`。`make install` 装最终 main。

---

## Self-Review

- **Spec coverage**：SC1→Task1；SC2→Task1（OpenAIPricing）+ `OpenAIPricingTests`；SC3→Task2；SC4→Task3；SC5→Task4；SC6→Task5（onPollTick + App）；SC7→Task5（去 Plan 卡 + cost 卡 + heatmap + ProviderCostContext）；SC8→贯穿（每个 Task 的 Step「全量 test」守既有全绿 + 新参数 Claude-默认）；SC9→Task2/Task3 的「不打印」+ Task6 Step1 的 grep + `CodexRolloutCostParserTests.testStoredEventHasOnlyAllowedFields`；SC10→Task6 Step1。
- **Placeholder scan**：关键/有风险的代码（`ModelPricing.swift`、`OpenAIPricing.swift`、`CodexRolloutCostParser.swift` 全文，及各 Test）已给出；机械的（`UsageAggregator`/`UsageEventStore`/`ProviderUsageSection`/`UsageChartView`/`PopoverView`/`ClaudeUsageBarApp` 的小改）以「读现有 X 照改 Y」+ spec §3.1 描述代替完整代码 —— 因为这些是「在现有文件里换个参数/删一段」、且实施者（我）有完整 spec；不是 placeholder（每条都说清了改哪行成什么）。
- **风险点已标注**：Task3 Step4 的「`CollectResult.newEventCount` 怎么算」（依赖读 `ClaudeUsageCollector`+`UsageEventStore.mergeEvents` 的实际返回 —— 本 plan 最大风险点，已显式 callout）；Task2 的 `StoredUsageEvent` 字段名/数字桥接（实施时核对）；Task5 Step3 的 `ProviderHistorySection` 怎么挂第二个 `@ObservedObject`（给了思路：拆内层 `ProviderCostArea`）；Task1 Step4 的 `ClaudeModelPricing` 字段名（实施时核对）。
- **Type consistency**：`ModelPriceTable`（`normalize`/`lookup`/`displayName`）、`ModelUnitPricing`（4 个 `…USDPerMTok` + `cost(input:output:cacheRead:cacheWrite:)`）、`ProviderCostContext`（`pricing: any ModelPriceTable`、`displayName: (String)->String`）、`OpenAIPricing`（`normalize`/`lookup(model:)`/`displayName`）/`OpenAIModelPriceTable.shared`、`ClaudeModelPriceTable.shared`、`CodexRolloutCostParser.parseFile(lines:sessionId:)`/`.sessionId(fromFileName:)`、`ScanCursorStore.init(dataDirOverride:provider:)`、`CodexUsageCollector.init(store:cursor:scanRootsOverride:)`/`.collect()`/`.scanRoots(env:home:fileExists:)`、`UsageStatsService.init(store:collector:pricing:)`/`.init(provider:)`、`UsageCollecting.collect()`、`UsageEventStore.rebuildAllAggregates(normalize:)`/`rebuildAggregates(forDayKeys:normalize:)`、`UsageAggregator.{foldByDay,foldByMonth,foldByYear}(normalize:)`/`{usdForBucket,dailySpend,monthlySpend,costForEvents,rolling30dSummary}(pricing:)`、`LocalCostCard.displayName`、`UsageChartSectionView.costContext`、`ProviderHistorySection.{costStats,costContext}`、`ProviderUsageArea.{costStats,costContext}`、`CodexProvider.onPollTick`、`PopoverView.codexStats` —— 各 Task 间一致。
