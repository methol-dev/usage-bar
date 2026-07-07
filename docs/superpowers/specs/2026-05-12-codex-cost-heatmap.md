---
id: 2026-05-12-codex-cost-heatmap
title: Codex 本机 session JSONL 扫描 → 估算成本 + 消费热力图（泛化定价层 + Codex collector）
status: implemented
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.9
related_adrs: [0005]
related_research: [codex-data-sources]
related_specs: [2026-05-11-local-cost-scan, 2026-05-12-usage-store-redesign, 2026-05-12-codex-provider, 2026-05-12-codex-history-trend, 2026-05-12-popover-redesign]
spec_criteria:
  - id: SC1
    criterion: "**定价层泛化（纯结构，Claude 零回归）**：新增 `protocol ModelPriceTable: Sendable { func normalize(_ model: String) -> String; func lookup(_ model: String) -> ModelUnitPricing?; func displayName(_ model: String) -> String }` + `struct ModelUnitPricing: Equatable, Sendable { let inputUSDPerMTok, outputUSDPerMTok, cacheReadUSDPerMTok, cacheWriteUSDPerMTok: Double; func cost(input:output:cacheRead:cacheWrite: Int) -> Double }`（公式同 `ClaudePricing.cost`）。`ClaudePricing` 加 `struct ClaudeModelPriceTable: ModelPriceTable`（三方法转发既有静态方法、`lookup` 把 `ClaudeModelPricing` 映成 `ModelUnitPricing`）+ `static let shared`；既有 `ClaudeModelPricing` / `enum ClaudePricing` 与定价表**完全不动**。`UsageAggregator` 的定价/折叠函数加默认参数：`usdForBucket` / `dailySpend` / `monthlySpend` / `costForEvents` / `rolling30dSummary` 加 `pricing: ModelPriceTable = ClaudeModelPriceTable.shared`；`foldByDay/foldByMonth/foldByYear` 加 `normalize: @Sendable (String) -> String = { ClaudePricing.normalize($0) }`（用于 agg key 规范化）。`UsageEventStore.rebuildAllAggregates()` / `rebuildAggregates(forDayKeys:)` 加 `normalize:` 同默认（转发给 fold）。`LocalCostCard` 加 `displayName: (String) -> String = { ClaudePricing.displayName($0) }`。**所有新参数均有 Claude-默认 → 既有 Claude 调用点一行不改**。"
    done: true
    evidence: "`ModelPricing.swift`（`ModelPriceTable: Sendable` + `ModelUnitPricing` + `ProviderCostContext`）；`ClaudePricing.swift` 加 `ClaudeModelPriceTable`（表/静态方法字节不变）；`UsageAggregator` 的 `usdForBucket/dailySpend/monthlySpend/costForEvents/rolling30dSummary` 加 `pricing:` Claude-默认、`foldBy*` 加 `normalize:` Claude-默认；`UsageEventStore.rebuild*` 加 `normalize:`；`LocalCostCard` 加 `displayName:`。commit 7ba564e。224→ 全绿（Claude 调用点未改）。"
  - id: SC2
    criterion: "**OpenAI 估价表**：新增 `enum OpenAIPricing`（结构对照 `ClaudePricing`）+ `struct OpenAIModelPriceTable: ModelPriceTable` + `static let shared`。`table: [String: ModelUnitPricing]` 收录 `gpt-5.5` / `gpt-5.1` / `gpt-5` / `gpt-5-codex` / `gpt-5-mini` / `gpt-5-nano` / `o3` / `o4-mini`；表头注释写明 `snapshotDate` + 「**这些是 best-effort 估算（按 OpenAI 模型 list price 推算），非真实账单 —— Codex 套餐是包额度计费**；过期了改这张表」+ 每项标注来源/置信度（无确切来源的标 `// UNVERIFIED — list-price estimate`）。`normalize`：strip 尾部 `-YYYY-MM-DD` 或 `-YYYYMMDD` 日期后缀 + 小写。`displayName`：`gpt-5.5`→`GPT-5.5`、`gpt-5-codex`→`GPT-5 Codex`、`gpt-5-mini`→`GPT-5 mini`、`o4-mini`→`o4-mini`、未知 → 原样。`lookup` 未知模型 → nil（→ `usdForBucket` 既有 `isUnknownPricing` 分支）。"
    done: true
    evidence: "`OpenAIPricing.swift`：8 个模型估价（gpt-5.5/5.1/5/codex/mini/nano/o3/o4-mini），每项 `// UNVERIFIED — list-price estimate` + `snapshotDate = 2026-05-12` + 表头「估算非账单」声明；`normalize` strip `-YYYY-MM-DD`/`-YYYYMMDD` + 小写；`displayName` GPT-5.x 等；`lookup` 未知 → nil。`OpenAIModelPriceTable: ModelPriceTable`。`OpenAIPricingTests`(5) 全绿。commit 7ba564e。"
  - id: SC3
    criterion: "**Codex rollout 解析器**：新增 `enum CodexRolloutCostParser { static func parseFile(lines: [String], sessionId: String) -> [StoredUsageEvent]; static func sessionId(fromFileName name: String) -> String }`。`parseFile` 是**有状态状态机**：按行（`lineIndex` 从 0）顺序解析 —— ① 行能解出 `payload.model`（来自 `turn_context`，**若 `session_meta` / `collaboration_mode.settings.model` 也带 model 则一并接受**；主路径是 `turn_context.payload.model`）→ 更新「当前模型」；② 行 `type==\"event_msg\"` 且 `payload.type==\"token_count\"` 且 `payload.info.last_token_usage` 非 null（`info` 为 null 的 token_count —— 只带 `rate_limits` —— 跳过）→ 产出 `StoredUsageEvent`：`ts` = 该行顶层 `timestamp`（解析失败用 `Date()`）；`model` = 当前模型（**若此前还没见过任何 model 行 → `\"unknown\"`**）；令 `lt = info.last_token_usage`：`cacheReadInputTokens = max(lt.cached_input_tokens, 0)`、`inputTokens = max(lt.input_tokens - lt.cached_input_tokens, 0)`、`outputTokens = max(lt.output_tokens, 0)`（已含 reasoning，OpenAI 按 output 计）、`cacheCreationInputTokens = 0`（OpenAI 自动 prompt caching，无 cache-write 计费）；`sessionId` = 传入；`msgId = \"\\(sessionId):\\(lineIndex)\"`、`reqId = String(lineIndex)`（rollout 文件 append-only → 行号稳定 → `UsageEventStore` 的 `(msgId,reqId)` 去重对「同文件重复扫」幂等）；③ 非法 JSON 行 / 缺字段 → 跳过、**不抛**。`sessionId(fromFileName:)`：从 `rollout-<ISO8601>-<uuid>.jsonl` 取末尾 uuid（5 段 `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`），取不出 → 用整文件名（去扩展名）。"
    done: true
    evidence: "`CodexRolloutCostParser.swift`：状态机（`turn_context.payload.model` / `collaboration_mode.settings.model` → 当前模型；`event_msg`/`token_count`/`info.last_token_usage` → `StoredUsageEvent`，`info==null` 跳过；`inputTokens = max(input-cached,0)`、`cacheReadInputTokens = cached`、`outputTokens = output`、`cacheCreationInputTokens = 0`；`msgId = sessionId:lineIndex`、`reqId = lineIndex`；坏 JSON 跳过不抛；`model = \"unknown\"` 若未见 model 行）；`sessionId(fromFileName:)` 取末尾 uuid。`CodexRolloutCostParserTests`(7，含字段集合断言) 全绿。commit （CodexRolloutCostParser 提交）。"
  - id: SC4
    criterion: "**Codex collector + cursor per-provider**：(a) `ScanCursorStore.init` 加 `provider: ProviderID = .claude`；cursor 文件名按 provider 区分 —— `.claude` 仍是 `<dataDir>/scan-cursor.json`（**保旧名 → 零迁移**），其它 → `<dataDir>/scan-cursor-<provider>.rawValue.json`（仍在**同一个 shared `dataDir`**，不是 `data/<provider>/` 子目录 —— `dataDirOverride` 语义不变）。(b) 新增 `actor CodexUsageCollector`（对照 `ClaudeUsageCollector`）：`init(store: UsageEventStore, cursor: ScanCursorStore, scanRootsOverride: [URL]? = nil)`；`collect() -> CollectResult`（`inFlight` 防重入 → 枚举各 root 下 `*.jsonl` → 对每个文件读 size/mtime，`cursor.nextReadOffset(...)` 返回 nil（没变）则跳过、否则**整文件从头读全部行**（不用 line-resume —— rollout 的「当前模型」依赖前文，re-parse 全文 + `UsageEventStore` 去重最简单且正确）→ `CodexRolloutCostParser.parseFile(lines:, sessionId: CodexRolloutCostParser.sessionId(fromFileName:))` → 收集 events → `cursor.updateCursor(for:, size:, mtime:, lineOffset: lines.count)`（占满，下次没变就跳过）→ 全部文件后 `store.mergeEvents(all)` → dirty 时 `store.rebuildAllAggregates(normalize: { OpenAIPricing.normalize($0) })` 否则 `store.rebuildAggregates(forDayKeys: touched, normalize: { OpenAIPricing.normalize($0) })` → `cursor.flush()` → 返回 `CollectResult`）。(c) `static func scanRoots() -> [URL]` = `$CODEX_HOME/sessions` 优先、否则 `~/.codex/sessions`（存在才纳入）+ `static func scanRoots(env:home:fileExists:)` 测试变体。"
    done: true
    evidence: "`ScanCursorStore.init(provider:.claude)` —— Claude 保 `scan-cursor.json`、其它 `scan-cursor-<provider>.json`（同 dataDir）；`CodexUsageCollector.swift`（actor，对照 `ClaudeUsageCollector`：`inFlight`、枚举 `*.jsonl`、`cursor.nextReadOffset` 判变没变、变了整文件 re-parse、`mergeEvents`、dirty→`rebuildAllAggregates(normalize:{OpenAIPricing.normalize})` 否则增量、`flush()`）；`scanRoots()` = `$CODEX_HOME/sessions` 优先否则 `~/.codex/sessions`；**无任何日志输出**。`CodexUsageCollectorTests`(5) 全绿。"
  - id: SC5
    criterion: "**`UsageStatsService` 泛化（Claude 零回归）**：新增 `protocol UsageCollecting: Sendable { func collect() async -> CollectResult }`（`ClaudeUsageCollector` / `CodexUsageCollector` 都 conform —— 它们是 actor，已 Sendable）。`UsageStatsService` 的 DI init 改成 `init(store: UsageEventStore, collector: any UsageCollecting, pricing: ModelPriceTable = ClaudeModelPriceTable.shared)`；`refresh()` 里 `UsageAggregator.dailySpend/monthlySpend/rolling30dSummary/costForEvents` 调用都带 `pricing: self.pricing`。既有 `convenience init()`（Claude）+ `static let shared`（Claude）**不变**。新增 `convenience init(provider: ProviderID)`：`.codex` → `UsageEventStore(provider:.codex)` + `CodexUsageCollector(store:, cursor: ScanCursorStore(provider:.codex))` + `pricing: OpenAIModelPriceTable.shared`；`.claude` → 等价于现 `init()`。"
    done: true
    evidence: "`UsageStatsService`：`protocol UsageCollecting: Sendable`（`ClaudeUsageCollector`/`CodexUsageCollector` conform）；`init(store:collector: any UsageCollecting, pricing: ModelPriceTable = ClaudeModelPriceTable.shared)`；`refresh()` 三处聚合（`dailySpend/monthlySpend/rolling30dSummary`）带 `pricing:`；`convenience init()`/`static let shared` 不变；新增 `convenience init(provider:)`。`UsageStatsServiceTests` 追加 `testCodexStatsEndToEnd` 全绿。"
  - id: SC6
    criterion: "**App / 后台接线**：`CodexProvider` 加 `var onPollTick: (@MainActor () -> Void)? = nil`（默认 nil）；`startPolling()` 的「立即拉一次」与「每次 5 分钟 timer sink」里，在 `refreshNow()` 之外（不阻塞）调 `onPollTick?()`。`UsageBarApp` 加 `@StateObject private var codexStats = UsageStatsService(provider: .codex)`；`PopoverView(...)` 多传 `codexStats: codexStats`；`.task` 里在 `await usageStats.refresh()` 之后 `await codexStats.refresh()`；并 `if let codex = coordinator.provider(.codex) as? CodexProvider { codex.onPollTick = { Task.detached { await codexStats.refresh() } } }`（在 `codex.startPolling()` 之前设）。"
    done: true
    evidence: "`CodexProvider.onPollTick: (@MainActor () -> Void)?`，`startPolling()` 立即一次 + 每 timer sink 调；`UsageBarApp` 加 `@StateObject codexStats = UsageStatsService(provider:.codex)`，`PopoverView(... codexStats:)`，`.task` 里 `await codexStats.refresh()` + `codex.onPollTick = { Task.detached { await codexStats.refresh() } }`（在 `startPolling()` 前）。build 通过。"
  - id: SC7
    criterion: "**Codex tab UI（对齐 Claude）**：(a) 去掉 Codex tab 的「Plan: Free」卡 —— `ProviderUsageSection` 删掉渲染 `snap?.planLabel` 的那张 `UsageCard`（`planLabel` 字段保留在 `ProviderUsageSnapshot`，只是不渲染）。(b) 新增 `struct ProviderCostContext { let pricing: any ModelPriceTable; let displayName: (String) -> String }`（取代会到处穿的 `(pricing:displayName:)` tuple —— 兑现 v0.2.8 G5 nit）。`UsageChartSectionView` 加 `var costContext: ProviderCostContext? = nil`：`costSummary` 用 `UsageAggregator.costForEvents(recentEvents, since:, now:, pricing: costContext?.pricing ?? ClaudeModelPriceTable.shared)`；`LocalCostCard(summary: cost, displayName: costContext?.displayName ?? { ClaudePricing.displayName($0) })`。Claude 调用点（`UsageChartSectionView(historyService:recentEvents:primaryLabel:secondaryLabel:)`）走默认 → 不变。(c) `PopoverView.ProviderHistorySection` 加 `var costStats: UsageStatsService? = nil`、`var costContext: ProviderCostContext? = nil`：折线图传 `recentEvents: costStats?.recentEvents ?? []`、`costContext`；若 `costStats != nil` 且 `costStats.dailySpend` 非空且不全 0 → 其后 `UsageCard { UsageHeatmapView(daySpends: costStats.dailySpend, isInitializing: costStats.isInitializing) }`。`ProviderUsageArea` 加 `var costStats`/`var costContext` 透传给 `ProviderHistorySection`。`providerArea` 的 Codex 分支：`costStats = codexStats`、`costContext = ProviderCostContext(pricing: OpenAIModelPriceTable.shared, displayName: { OpenAIPricing.displayName($0) })`。Claude tab 的 `claudeUsageArea` **不动**。"
    done: true
    evidence: "`ProviderUsageSection` 删 planLabel 卡（仅注释保留语义）；`ProviderCostContext` 在 `ModelPricing.swift`；`UsageChartSectionView.costContext: ProviderCostContext?`（costSummary / LocalCostCard 用它，Claude 默认）；`PopoverView`：`ProviderHistorySection` 加 `costStats`/`costContext` + 内层 `ProviderCostArea`（持 `@ObservedObject stats`，渲染折线图含估算费用卡 + 消费热力图），`ProviderUsageArea` 透传，`providerArea` Codex 分支构造 `ProviderCostContext(pricing: OpenAIModelPriceTable.shared, displayName: { OpenAIPricing.displayName($0) })` + `codexStats`；`claudeUsageArea` 不动。build 通过。"
  - id: SC8
    criterion: "**Claude / 既有行为零回归**：`ClaudeModelPricing` / `enum ClaudePricing` 的定价表与静态方法字节不变（`ClaudePricingTests` 全绿）；`UsageAggregator` / `UsageEventStore` / `UsageStatsService` / `LocalCostCard` / `UsageChartSectionView` 的新参数全有 Claude-默认 → Claude 调用点不改（`UsageAggregatorTests` / `UsageStatsServiceTests`(Claude) / `UsageEventStoreTests` 全绿）；`ScanCursorStore` 默认 `provider:.claude` → cursor 文件名 `scan-cursor.json` 不变（`ScanCursorStoreTests` 全绿）；`JSONLCostParser` / `ClaudeUsageCollector` 字节不变；Claude tab `claudeUsageArea`（trend → ProviderUsageSection → chart+costcard → heatmap）渲染不变；`MenuBarLabel` / `SettingsView` 不动（Codex 仍 `supportsBackgroundPolling=false`，不进 primary 下拉 —— Settings 重做是 v0.2.10）；Codex tab 的 v0.2.8 折线图 + Session/Weekly 趋势照旧。"
    done: true
    evidence: "237 tests 全绿（含既有 `ClaudePricingTests`/`UsageAggregatorTests`/`UsageEventStoreTests`/`ScanCursorStoreTests`/`UsageStatsServiceTests`(Claude)）；`ClaudePricing` 表/静态方法、`JSONLCostParser`、`ClaudeUsageCollector`、`UsageEventStore` 的 init/路径/权限、`MenuBarLabel`/`SettingsView`、Codex `supportsBackgroundPolling`（仍 false）均未改；Claude tab `claudeUsageArea` 渲染不变。"
  - id: SC9
    criterion: "**安全 / 隐私（Codex 路径硬约束）**：`CodexRolloutCostParser` / `CodexUsageCollector` 落盘的**只有** `StoredUsageEvent`（= token 计数 + model 名 + ts + 合成 ids）+ `ScanCursorFile`（path/size/mtime/lineOffset）—— **绝不持久化或日志输出** rollout 文件里的 prompt / 代码 / 对话内容、文件**绝对路径**、或 sessionId 之外的任何原文（rollout 文件含用户完整对话）。新增的 `data/codex/*.json` 与 `scan-cursor-codex.json` 沿用 `UsageEventStore` 既有的目录 0700 / 文件 0600（写入路径不变 → 自动继承）。代码里不出现 `print`/`NSLog`/`os_log` 打印解析中的行内容或路径；单测的 token fixture 用明显假值（如 `1000`/`600` 这种整数，不放像真 token 的串）；`CodexRolloutCostParserTests` 断言「产出的 `StoredUsageEvent` 字段集合 = {ts, msgId, reqId, sessionId, model, inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens}」（即只有这些）。"
    done: true
    evidence: "`CodexRolloutCostParser.swift` / `CodexUsageCollector.swift` 落盘只有 `StoredUsageEvent` + `ScanCursorFile`，无 print/NSLog/os_log（SC_AUTO_NO_RAW_LOG grep 无命中，连注释里的函数名字面量也去掉了）；`data/codex/*.json` + `scan-cursor-codex.json` 沿用 `UsageEventStore`/`ScanCursorStore` 既有 0700/0600；测试 fixture 用明显假整数（1000/600/…）；`CodexRolloutCostParserTests.testStoredEventHasOnlyAllowedFields` 断言字段集合 ⊆ {ts,msgId,reqId,sessionId,model,inputTokens,outputTokens,cacheReadInputTokens,cacheCreationInputTokens}。"
  - id: SC10
    criterion: "`swift build -c release` 通过；`swift test` 全绿 —— 新增测试：`OpenAIPricingTests`（normalize 去日期后缀 / lookup 已知与未知 / displayName / `ModelUnitPricing.cost` 公式含 cacheRead 折扣）、`CodexRolloutCostParserTests`（正常多模型切换 + token 映射 / `info==null` 跳过 / `token_count` 早于任何 model 行 → `\"unknown\"` / 坏 JSON 行跳过 / 空行数组 → 空 / `sessionId(fromFileName:)` / 字段集合断言）、`CodexUsageCollectorTests`（临时 sessions 目录 → `collect()` 有新 event + `readDayAggregates` 非空 / 再 `collect()` 文件没变 → `newEventCount==0` / append 新行 → 又有净新增 / `scanRoots(env:home:fileExists:)` 解析 `CODEX_HOME`）、`UsageStatsServiceTests` 追加（用 `CodexUsageCollector` + `OpenAIModelPriceTable` → `refresh()` → `dailySpend` 非空、`rolling30d?.totalUSD > 0`、`recentEvents` 非空）；`make release-artifacts` 产出 zip/dmg + `bash macos/scripts/verify-release.sh macos/UsageBar.zip` 与 `.dmg` 均 OK。"
    done: true
    evidence: "`swift build -c release` 通过；`swift test` = 237 tests 0 失败（新增 `OpenAIPricingTests`×5 + `CodexRolloutCostParserTests`×7 + `CodexUsageCollectorTests`×5 + `UsageStatsServiceTests.testCodexStatsEndToEnd`×1 = +18）；`make release-artifacts` 产出 zip+dmg；`verify-release.sh` 对 zip 与 dmg 均「Release archive looks good」；`grep` SC_AUTO_NO_RAW_LOG 无命中。"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_ARTIFACTS: make release-artifacts"
  - "SC_AUTO_VERIFY_ZIP: bash macos/scripts/verify-release.sh macos/UsageBar.zip"
  - "SC_AUTO_NO_RAW_LOG: grep -rn 'print(\\|NSLog\\|os_log' macos/Sources/UsageBar/CodexRolloutCostParser.swift macos/Sources/UsageBar/CodexUsageCollector.swift  →  无命中（不打印解析中内容/路径）"
manual_checks:
  - "本机有 `~/.codex/sessions/**/rollout-*.jsonl` 时：开 popover 切到 Codex tab → 折线图下方出现估算费用卡（`Usage # … $…`，模型名是 `GPT-5.x` 之类）；tab 底部出现消费热力图（按天着色 + 当天 $/calls/tokens）；**不再有「Plan: Free」卡**。"
  - "本版本起：Codex 本机扫描随后台 5 分钟 timer + popover 打开各跑一次；写到 `~/.config/usage-bar/data/codex/`（独立于 Claude 的 `data/claude/`），cursor 在 `~/.config/usage-bar/data/scan-cursor-codex.json`；ls -l 看权限是 `-rw-------`（0600）/ 目录 0700。"
  - "Claude tab：估算费用卡 / 热力图 / 模型名显示与本版本前完全一致（定价表/显示名/agg 文件未变）。"
reviews:
  - gate: G2
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: design-review + security-review (敏感面：读 ~/.codex/sessions/** rollout 文件——含用户完整对话/代码；新增 data/codex/ 落盘)
    verdict: approved-after-revisions
    notes: >
      2 must-fix：① SC7 当时只写「Claude 零回归」，没把 Codex parser/collector 纳入「不持久化/日志 content、不打印 raw line/path、tests 不用像真 token 的 fixture、data/codex 权限」的硬验收 —— 已新增独立的 SC9（安全/隐私），并补 `SC_AUTO_NO_RAW_LOG` grep 检查 + 字段集合断言要求；② Codex cursor 文件位置在 SC4/§3.1/manual_checks 三处不一致 —— 已统一为「同一 shared `dataDir` 下 `scan-cursor-codex.json`（Claude 保 `scan-cursor.json` 旧名 → 零迁移），`dataDirOverride` 语义不变」。
      5 should-fix：① `(pricing:displayName:)` tuple 该结构化 —— 已改成 `struct ProviderCostContext`（兑现 v0.2.8 G5 nit）；② `ModelPriceTable`/`ModelUnitPricing`/`UsageCollecting` 加 `: Sendable`（refresh 在 Task.detached 里用 pricing）—— 已加；③ fold/rebuild 仍固定用 Claude normalizer —— 已给 `foldBy*` / `rebuildAggregates` 加 `normalize:` 默认参数（Codex collector 传 `OpenAIPricing.normalize`）；④ 补「token_count 早于任何 model 行 → unknown」parser 测试 —— 已进 SC10 测试清单；⑤ SC 粒度偏大 —— 已把原 SC5/SC6/SC8 拆成 SC5/SC6/SC7/SC8/SC9/SC10（共 10 条）。
      3 nit：SC3 措辞「session_meta 的 model」—— 改成「若存在则读，主路径 turn_context」；OpenAIPricing 值标 `// UNVERIFIED — list-price estimate` + snapshotDate；`automated_checks` 补 `verify-release.sh`。均已应用。
      `ModelPriceTable` seam 选点（只覆盖 normalize/lookup/displayName 三个真实用点 + 保 ClaudePricing 不动）、`CodexRolloutCostParser` 不复用 `JSONLCostParser`（不同数据源）—— 均获认可（praise）。
  - gate: G5
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: code-review + security-review（敏感面：读 ~/.codex/sessions/** rollout 文件——含用户完整对话/代码；新增 data/codex/ 落盘）
    verdict: approved-with-nits
    notes: >
      无 must-fix / should-fix。逐项确认：SC9（落盘只有 StoredUsageEvent + ScanCursorFile、无 print/NSLog/os_log、data/codex 继承 0700/0600、fixture 假整数、字段集合断言守住）；SC8（ClaudePricing 表/静态方法字节不变、ClaudeUsageCollector 仅加协议 conformance、新参数全 Claude-默认、ScanCursorStore 默认仍 scan-cursor.json）；parser token 映射 / info==null 跳过 / 绝对行号幂等 / 坏 JSON 不抛；collector cursor 只判变没变 + 整文件 re-parse + (msgId,reqId) 去重 + inFlight 防重入 + scanRoots CODEX_HOME 优先；Sendable/并发无隐患；SwiftUI 第二个同型 stats 走构造参数 + ProviderCostArea 套路正确 + 去 planLabel 卡只影响 Codex。swift build -c release 零警告、swift test 237 全绿。
      2 nit：① `CodexUsageCollector.swift` 的 `guard nextReadOffset(...) != nil` 处加注释说明「返回值数值本身不用、只判 nil」（已应用，commit）；② `ProviderHistorySection` else 分支 `recentEvents: []` 是 v0.2.8 历史遗留、非本 PR 范围（不改）。
---

# Codex 本机 session JSONL 扫描 → 估算成本 + 消费热力图

## 1. 背景与目标

「让 Codex tab 和 Claude tab 界面/功能一致」的最后一块：Claude tab 有「跟随时间窗口的估算费用卡」（扫 `~/.claude/projects/**/*.jsonl` → token → `ClaudePricing` → USD）和「消费热力图」（按天着色）。Codex 还没有 —— 用户实测反馈「还少了热力图」。

v0.1.2 / v0.2.3 已把这条流水线做得相当通用：`UsageEventStore` 已是 per-provider（`init(provider:)`，写 `data/<provider>/`）、`UsageAggregator`/`UsageStatsService` 的纯逻辑也基本不依赖 Claude；剩下三处是 Claude-硬编码的：(1) **定价**（`ClaudePricing` 表 + `UsageAggregator` 直接调它）、(2) **JSONL 解析**（`JSONLCostParser` 认 Claude `type==\"assistant\"` 的 schema）、(3) **扫描根 + collector**（`ClaudeUsageCollector` 走 `~/.claude/projects`）。本 spec 把定价层抽成协议、补一张 OpenAI 估价表、写一个 Codex rollout 解析器 + collector，再把 Codex tab 接上估算费用卡 + 热力图，**顺带去掉 Codex tab 的「Plan」卡片**（对齐 Claude）。

**不含**（→ v0.2.10）：Settings 改成 provider 列表（拖动排序 + 启用开关 + 菜单栏子开关）、去掉 Primary Provider 下拉、去掉 Settings 的 Account 区、刷新纪律重构（统一 polling interval、切 tab / 打开 popover 不再触发刷新只渲染缓存、刷新只走「后台 timer + Refresh 按钮」两入口、`ProviderCoordinator` 统管 timer/顺序/启用集/菜单栏 provider）。本版本 Codex 仍沿用 v0.2.8 的固定 5 分钟 `startPolling()`、`supportsBackgroundPolling=false`。

> **估价说明**：ChatGPT/Codex 套餐（Free/Plus/Pro）是「套餐包额度」、不是「按 token 计费」—— Codex tab 的 USD 跟 Claude tab 一样是**用模型 list price 算的合成估算**，不是真实账单。`OpenAIPricing` 里写明 `snapshotDate`、「best-effort 估算」声明、每项 `// UNVERIFIED — list-price estimate`。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 定价怎么泛化 | 抽 `protocol ModelPriceTable: Sendable`（`normalize`/`lookup`/`displayName`）；`ClaudePricing` 加转发用的 `struct ClaudeModelPriceTable` + `static let shared`（既有静态 API 与表零改动）；`UsageAggregator` 的定价/折叠函数加默认参数（`pricing:` / `normalize:`）；`UsageEventStore.rebuild*` 转发 `normalize:` | 不动 `ClaudePricing`（Claude 零回归），不改现有调用点（默认参数），新增面最小；协议三方法刚好覆盖所有用法；`Sendable` 因 `refresh()` 在 `Task.detached` 里用 pricing |
| OpenAI 价怎么来 | 硬编码 `OpenAIPricing` 估价表（gpt-5.x / gpt-5-codex / o-series），逐项 `// UNVERIFIED — list-price estimate` + `snapshotDate`；未知模型 → nil → UI 标 `isUnknownPricing` | 没有官方「Codex 套餐折算成 token 价」口径；和 Claude tab 一样给个有用的估算即可。过期改常量 |
| Codex JSONL 怎么解析 | 新写 `CodexRolloutCostParser.parseFile(lines:sessionId:)` —— **整文件、有状态**（跟踪「当前模型」，模型在 `turn_context` 行、token 在后续 `token_count` 行；`info==null` 的 token_count 跳过）；不复用 `JSONLCostParser`（schema 完全不同） | rollout 格式（`event_msg`→`token_count`→`info.last_token_usage`）跟 Claude 的 assistant-message 格式没关系；状态机最贴合；G2 也确认不强行复用 |
| token 怎么映射 | `cacheReadInputTokens = cached_input_tokens`；`inputTokens = max(input_tokens - cached_input_tokens, 0)`（未缓存部分）；`outputTokens = output_tokens`（已含 reasoning，OpenAI 按 output 计）；`cacheCreationInputTokens = 0`（OpenAI 自动 prompt caching，无 cache-write 计费 —— `ModelUnitPricing.cacheWriteUSDPerMTok` 对 OpenAI 设 0 即可） | 实测 `total = input_tokens + output_tokens`、`input_tokens ⊇ cached`、`output_tokens ⊇ reasoning`；按 OpenAI 计费模型映成 `StoredUsageEvent` 的四个 token 字段 |
| collector 要不要复用 cursor 的 line-resume | 不用 —— 文件变了就整文件 re-parse（cursor 只当「变没变」判据），靠 `UsageEventStore` 的 `(msgId,reqId)=sessionId:lineIndex` 去重保证幂等 | rollout 的「当前模型」依赖前文，从中间 offset 续读会丢模型；rollout 文件不大、且只有当前活跃 session 的文件 mtime 会动（其余被 cursor 跳过），re-parse 成本可接受 |
| `ScanCursorStore` 要不要 per-provider | 要 —— `init(provider:.claude)` 默认（Claude 文件名 `scan-cursor.json` 不变 → 零迁移）；Codex 用同一 `dataDir` 下的 `scan-cursor-codex.json`（`dataDirOverride` 语义不变） | 一行参数；隔离两 provider 的 file→offset 命名空间；G2 must-fix #2 要求三处一致 |
| `UsageStatsService` 怎么 per-provider | DI init 加 `pricing: ModelPriceTable`（默认 Claude）+ collector 抽成窄协议 `UsageCollecting: Sendable`（`ClaudeUsageCollector`/`CodexUsageCollector` conform）；加 `convenience init(provider:)`；`static let shared` / 既有 `init()` 不变。App 里 `@StateObject` 一个 `codexStats` | 已经 DI 友好；加 `pricing` + collector 协议化就够；不强塞单例 |
| Codex tab 怎么接 cost/heatmap | 扩 v0.2.8 的 `PopoverView.ProviderHistorySection`：加可选 `costStats: UsageStatsService?` + `costContext: ProviderCostContext?`；非 nil → 折线图传 `recentEvents/costContext`（出估算费用卡）、其后追加 `UsageHeatmapView`。Claude 的 `claudeUsageArea` 不动 | `ProviderHistorySection` 本就是「Codex 的数据区」；Claude 那块自成一体、不冒险合并 |
| 那个会到处穿的 `(pricing:displayName:)` tuple | 现在就做成 `struct ProviderCostContext { let pricing: any ModelPriceTable; let displayName: (String)->String }` | G2 should-fix #1（也兑现 v0.2.8 G5 记下的「tuple 改 struct」）；穿三层 view，结构化划算 |
| `usageStats` 是 `@EnvironmentObject` —— 第二个怎么传 | Codex 的 `codexStats` 不走 environment（同类型不能注两个），作普通参数传进 `PopoverView`（仿 `historyService`） | environment 单例性限制 |
| Codex stats 何时 refresh | popover 打开一次（App `.task`）+ Codex 的 5 分钟 timer 每 tick（`CodexProvider.onPollTick` 闭包，App 设成 `{ Task.detached { await codexStats.refresh() } }`） | 与 Claude（`UsageService.scheduleTimer` 里 `Task.detached { await usageStats.refresh() }`）对称；不让 `CodexProvider` import `UsageStatsService` |
| 去掉 Codex「Plan」卡 | `ProviderUsageSection` 删掉渲染 `planLabel` 的那张 `UsageCard`；`planLabel` 字段保留 | 用户要求对齐 Claude（Claude 没这卡）；字段保留以防后续要用 |

## 3. 设计

### 3.1 改动文件

| 文件 | 改动 |
|---|---|
| `ModelPricing.swift`（新建） | `protocol ModelPriceTable: Sendable { func normalize(_:) -> String; func lookup(_:) -> ModelUnitPricing?; func displayName(_:) -> String }`；`struct ModelUnitPricing: Equatable, Sendable { let inputUSDPerMTok, outputUSDPerMTok, cacheReadUSDPerMTok, cacheWriteUSDPerMTok: Double; func cost(input:output:cacheRead:cacheWrite: Int) -> Double }`（`(input*in + output*out + cacheRead*cr + cacheWrite*cw)/1_000_000`，同 `ClaudePricing.cost`）。 |
| `ClaudePricing.swift` | 加 `struct ClaudeModelPriceTable: ModelPriceTable { func normalize(_ m:String){ClaudePricing.normalize(m)}; func lookup(_ m:String) -> ModelUnitPricing? { ClaudePricing.lookup(model:m).map { ModelUnitPricing(inputUSDPerMTok:$0.inputUSDPerMTok, outputUSDPerMTok:$0.outputUSDPerMTok, cacheReadUSDPerMTok:$0.cacheReadUSDPerMTok, cacheWriteUSDPerMTok:$0.cacheWriteUSDPerMTok) }; func displayName(_ m:String){ClaudePricing.displayName(m)} }` + `static let shared = ClaudeModelPriceTable()`。既有 `ClaudeModelPricing` / `enum ClaudePricing` / 表 **字节不变**。 |
| `OpenAIPricing.swift`（新建） | `enum OpenAIPricing { static let snapshotDate = \"2026-05-12\"; private static let table: [String: ModelUnitPricing] = [ /* 表头注释：估算非账单 */ \"gpt-5.5\": .init(...), \"gpt-5.1\": ..., \"gpt-5\": ..., \"gpt-5-codex\": ..., \"gpt-5-mini\": ..., \"gpt-5-nano\": ..., \"o3\": ..., \"o4-mini\": ... /* 每项 // UNVERIFIED — list-price estimate */ ]; static func normalize(_ m:String) -> String { /* strip 尾部 -YYYY-MM-DD / -YYYYMMDD + lowercased */ }; static func lookup(model:String) -> ModelUnitPricing? { table[normalize(model)] }; static func displayName(_ m:String) -> String { /* gpt-5.5→GPT-5.5 等 */ } }`；`struct OpenAIModelPriceTable: ModelPriceTable`（转发）+ `static let shared`。 |
| `CodexRolloutCostParser.swift`（新建） | `enum CodexRolloutCostParser { static func parseFile(lines:[String], sessionId:String) -> [StoredUsageEvent]; static func sessionId(fromFileName name:String) -> String }`。逻辑见 SC3。每行用 `JSONSerialization.jsonObject` 容错解析（失败 → 跳过）；从 `obj["payload"]` 里挖 `model`（顶层 `model` 或 `collaboration_mode.settings.model`）与 `info.last_token_usage`。无任何 `print`/`NSLog`/`os_log`（SC9）。 |
| `ScanCursorStore.swift` | `init(dataDirOverride: URL? = nil, provider: ProviderID = .claude)`；cursor 文件名：`provider == .claude ? \"scan-cursor.json\" : \"scan-cursor-\\(provider.rawValue).json\"`，仍在 `dataDir`（`dataDirOverride` 语义不变）。其余不动。 |
| `UsageEventStore.swift` | `rebuildAllAggregates(normalize: @Sendable (String)->String = { ClaudePricing.normalize($0) })` 与 `rebuildAggregates(forDayKeys:, normalize: ...)` —— 转发给 `UsageAggregator.foldBy*`。其余（`init(provider:)`、`data/<provider>/`、0700/0600）不动。 |
| `UsageAggregator.swift` | `foldByDay/foldByMonth/foldByYear` 加 `normalize: @Sendable (String)->String = { ClaudePricing.normalize($0) }`（替换内部写死的 `ClaudePricing.normalize`）；`usdForBucket` / `dailySpend` / `monthlySpend` / `costForEvents` / `rolling30dSummary` 加 `pricing: ModelPriceTable = ClaudeModelPriceTable.shared`，内部 `ClaudePricing.lookup/cost` → `pricing.lookup(...)` + `ModelUnitPricing.cost(...)`、`ClaudePricing.normalize` → 透传的 `normalize` 或 `pricing.normalize`。其余不动。 |
| `LocalCostCard.swift` | 加 `var displayName: (String) -> String = { ClaudePricing.displayName($0) }`；`Text(ClaudePricing.displayName(row.normalizedModel))` → `Text(displayName(row.normalizedModel))`。 |
| `CodexUsageCollector.swift`（新建） | 见 SC4。`actor CodexUsageCollector`，对照 `ClaudeUsageCollector` 的结构（`inFlight`、枚举、cursor、`mergeEvents`、`rebuildAggregates(... normalize:{OpenAIPricing.normalize($0)})`、`flush()`、`CollectResult`）。无 `print`/`NSLog`/`os_log`（SC9）。 |
| `UsageStatsService.swift` | `protocol UsageCollecting: Sendable { func collect() async -> CollectResult }`；`ClaudeUsageCollector`/`CodexUsageCollector` 加 `: UsageCollecting`（已是 actor → Sendable）。`init(store:collector:pricing:)`（`collector: any UsageCollecting`、`pricing: ModelPriceTable = ClaudeModelPriceTable.shared`）；`refresh()` 里聚合调用带 `pricing: self.pricing`。`convenience init()` / `static let shared` 不变。加 `convenience init(provider: ProviderID)`。 |
| `ProviderUsageSection.swift` | 删掉 `if let plan = snap?.planLabel, !plan.isEmpty { UsageCard { ... } }` 整块。其余不动。 |
| `UsageChartView.swift` | `UsageChartSectionView` 加 `var costContext: ProviderCostContext? = nil`；`costSummary` 用 `costForEvents(..., pricing: costContext?.pricing ?? ClaudeModelPriceTable.shared)`；`LocalCostCard(summary:, displayName: costContext?.displayName ?? { ClaudePricing.displayName($0) })`。 |
| `ProviderCostContext`（放 `ModelPricing.swift` 或 `UsageChartView.swift`） | `struct ProviderCostContext { let pricing: any ModelPriceTable; let displayName: (String) -> String }`。 |
| `PopoverView.swift` | `ProviderHistorySection` 加 `var costStats: UsageStatsService? = nil` + `var costContext: ProviderCostContext? = nil`；`ProviderUsageArea` 加同名透传；`PopoverView` 加 `@ObservedObject var codexStats: UsageStatsService`（构造参数）；`providerArea` Codex 分支构造 `ProviderCostContext(pricing: OpenAIModelPriceTable.shared, displayName: { OpenAIPricing.displayName($0) })` 并连同 `codexStats` 传进去。 |
| `CodexProvider.swift` | 加 `var onPollTick: (@MainActor () -> Void)? = nil`；`startPolling()` 立即一次 + 每次 timer sink 里 `onPollTick?()`（在 `refreshNow()` 之外）。 |
| `UsageBarApp.swift` | `@StateObject private var codexStats = UsageStatsService(provider: .codex)`；`PopoverView(..., codexStats: codexStats)`；`.task` 里 `await codexStats.refresh()`（在 `await usageStats.refresh()` 后）；`if let codex = coordinator.provider(.codex) as? CodexProvider { codex.onPollTick = { Task.detached { await codexStats.refresh() } } }`（在 `codex.startPolling()` 前）。 |
| 测试 | `OpenAIPricingTests` / `CodexRolloutCostParserTests` / `CodexUsageCollectorTests`（新建）+ `UsageStatsServiceTests`（追加 Codex 端到端）。见 SC10 / §3.3。 |

### 3.2 数据流

```
~/.codex/sessions/**/rollout-<ISO8601>-<uuid>.jsonl   （append-only；含用户完整对话/代码 —— 只抽 token/model/ts，不落原文）
        │  (CodexProvider.onPollTick 每 5min  +  App .task 打开一次)
        ▼
codexStats.refresh()  ──►  CodexUsageCollector.collect()
                                 │  ScanCursorStore(provider:.codex): size/mtime 变了?
                                 │  变了 → 整文件读全部行 → CodexRolloutCostParser.parseFile(lines, sessionId=uuid)
                                 │       （状态机：turn_context.payload.model → 当前模型；event_msg/token_count.info.last_token_usage → StoredUsageEvent，msgId=sessionId:lineIndex）
                                 ▼
                          UsageEventStore(provider:.codex).mergeEvents → data/codex/YYYY-MM.json + rebuildAggregates(normalize:{OpenAIPricing.normalize}) → data/codex/agg-*.json   （0700/0600）
                                 │
        codexStats.refresh() 读 readDayAggregates / queryEvents(31d)
                  │  UsageAggregator.{dailySpend,rolling30dSummary,costForEvents}(pricing: OpenAIModelPriceTable.shared)
                  ▼
        codexStats.{dailySpend, recentEvents, rolling30d}  →  @Published
                  │
PopoverView(Codex tab).ProviderHistorySection(costStats: codexStats, costContext: ProviderCostContext(OpenAI…)):
        ├─ UsageChartSectionView(recentEvents: codexStats.recentEvents, costContext) → 折线图(Session/Weekly) + 估算费用卡(LocalCostCard, displayName: OpenAIPricing.displayName)
        └─ UsageHeatmapView(daySpends: codexStats.dailySpend)        ← 新
   （ProviderUsageSection 不再渲染 planLabel 卡）
```

### 3.3 测试方案（要点）

- **`OpenAIPricingTests`**：`OpenAIPricing.normalize(\"gpt-5.5-2026-01-01\") == \"gpt-5.5\"`、`normalize(\"GPT-5.5\") == \"gpt-5.5\"`；`lookup(\"gpt-5.5\") != nil`、`lookup(\"gpt-9000\") == nil`；`displayName(\"gpt-5-codex\")` 合理；`ModelUnitPricing(input:1, output:2, cr:0.1, cw:0).cost(input:1_000_000, output:1_000_000, cacheRead:1_000_000, cacheWrite:0) == 1+2+0.1`。
- **`CodexRolloutCostParserTests`**：
  - 正常顺序：`[session_meta] → [turn_context model=gpt-5] → [event_msg token_count info=null] (跳过) → [event_msg token_count info.last_token_usage{input:1000,cached:600,output:200,reasoning:50}] → [turn_context model=gpt-5-codex] → [event_msg token_count info.last_token_usage{input:500,cached:0,output:80}]` → 2 个 `StoredUsageEvent`：#1 model==`gpt-5`、inputTokens==400、cacheReadInputTokens==600、outputTokens==200、cacheCreationInputTokens==0、reqId/msgId 含其 lineIndex；#2 model==`gpt-5-codex`、inputTokens==500、cacheReadInputTokens==0。
  - `token_count` 早于任何 model 行 → 该 event model==`\"unknown\"`。
  - 混入 `\"not json {{\"` 行 → 跳过、不抛、不影响其它行的 lineIndex（用绝对行号）。
  - `parseFile(lines: [], sessionId: \"s\") == []`。
  - `sessionId(fromFileName: \"rollout-2026-05-12T19-24-05-019e1bee-0948-75c3-ae1a-bab380a1ffa9.jsonl\") == \"019e1bee-0948-75c3-ae1a-bab380a1ffa9\"`；`sessionId(fromFileName: \"weird.jsonl\") == \"weird\"`。
  - **字段集合断言**（SC9）：产出的某个 `StoredUsageEvent` 序列化成字典后 key 集合 ⊆ {ts, msgId, reqId, sessionId, model, inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens}（即不含任何原文字段）。
- **`CodexUsageCollectorTests`**：临时目录 `tmp/sessions/2026/05/12/rollout-…-<uuid>.jsonl`（写 2~3 个含 token_count 的行 + 一个 turn_context model 行）；`let store = UsageEventStore(dataDirOverride: tmp, provider: .codex)`；`let cursor = ScanCursorStore(dataDirOverride: tmp, provider: .codex)`；`let c = CodexUsageCollector(store: store, cursor: cursor, scanRootsOverride: [tmp.appendingPathComponent(\"sessions\")])`；`await c.collect()` → `newEventCount > 0`、`await store.readDayAggregates()` 非空；再 `await c.collect()`（文件没变）→ `newEventCount == 0`；append 一行新 token_count → `await c.collect()` → 净新增 1（整文件 re-parse + 去重）。`CodexUsageCollector.scanRoots(env: [\"CODEX_HOME\": tmp.path], home: ..., fileExists: { _ in true }) == [tmp/sessions]`。
- **`UsageStatsServiceTests` 追加**：用上面的 store/collector + `OpenAIModelPriceTable.shared` → `let svc = UsageStatsService(store: store, collector: c, pricing: OpenAIModelPriceTable.shared)`；`await svc.refresh()` → `svc.dailySpend` 非空、`svc.rolling30d?.totalUSD ?? 0 > 0`（喂的 token × OpenAI 表 > 0）、`svc.recentEvents` 非空。
- **既有不动、全绿**：`UsageAggregatorTests` / `UsageStatsServiceTests`(Claude) / `ClaudePricingTests` / `JSONLCostParserTests` / `ScanCursorStoreTests` / `UsageEventStoreTests`（默认参数 → Claude 路径不变）。
- **`SC_AUTO_NO_RAW_LOG`**：`grep -rn 'print(\\|NSLog\\|os_log' CodexRolloutCostParser.swift CodexUsageCollector.swift` 无命中。
- 纯 SwiftUI（`LocalCostCard` 的 `displayName` 闭包、Codex tab 的 `UsageHeatmapView`、去 Plan 卡、`ProviderHistorySection` 接 cost/heatmap）—— `swift build` + `manual_checks` 覆盖。

CI 跑 `swift build -c release` + `swift test` + `make release-artifacts` + `verify-release.sh`，全绿。

## 4. 文件迁移动作汇总

| 动作 | 文件 |
|---|---|
| 🆕 | `ModelPricing.swift`（`ModelPriceTable` 协议 + `ModelUnitPricing` + `ProviderCostContext`） |
| 🆕 | `OpenAIPricing.swift`（估价表 + `OpenAIModelPriceTable`） |
| 🆕 | `CodexRolloutCostParser.swift` |
| 🆕 | `CodexUsageCollector.swift` |
| 🔧 | `ClaudePricing.swift`（加 `ClaudeModelPriceTable` 转发 + `shared`；表/静态方法字节不动） |
| 🔧 | `ScanCursorStore.swift`（`init` 加 `provider`，cursor 文件名 per-provider，`.claude` 保旧名 `scan-cursor.json`） |
| 🔧 | `UsageAggregator.swift`（定价函数加 `pricing:` 默认参数；fold 加 `normalize:` 默认参数） |
| 🔧 | `UsageEventStore.swift`（`rebuild*` 转发 `normalize:`；其余不动） |
| 🔧 | `UsageStatsService.swift`（`UsageCollecting: Sendable` 协议；`init` 加 `pricing:`；`convenience init(provider:)`） |
| 🔧 | `LocalCostCard.swift`（加 `displayName:` 闭包参数） |
| 🔧 | `ProviderUsageSection.swift`（删 planLabel 卡） |
| 🔧 | `UsageChartView.swift`（`UsageChartSectionView` 加 `costContext: ProviderCostContext?`） |
| 🔧 | `PopoverView.swift`（`ProviderHistorySection` / `ProviderUsageArea` 加 `costStats`/`costContext`；`PopoverView` 收 `codexStats`；Codex 分支接上） |
| 🔧 | `CodexProvider.swift`（加 `onPollTick`） |
| 🔧 | `UsageBarApp.swift`（`codexStats` `@StateObject` + `.task` refresh + `onPollTick` 接线） |
| 🆕/🔧 | `OpenAIPricingTests` / `CodexRolloutCostParserTests` / `CodexUsageCollectorTests`（新建）+ `UsageStatsServiceTests`（追加 Codex 端到端） |
| ✅ 不动 | `ClaudeModelPricing`/`enum ClaudePricing`/定价表 / `JSONLCostParser` / `ClaudeUsageCollector` / `UsageEventStore` 的 `init/data 路径/权限` / `UsageHeatmapView` / `UsageHeroCard` / Claude `claudeUsageArea` / `MenuBarLabel` / `SettingsView` / 凭证 & rate 拉取逻辑 / Codex `supportsBackgroundPolling`（仍 false） |

## 5. 风险 / Open questions

1. **OpenAI 估价是「合成估算」不是账单** —— 与 Claude tab 同性质。`OpenAIPricing` 注释 + `snapshotDate` + 每项 `// UNVERIFIED`。可接受。
2. **整文件 re-parse 而非 line-resume** —— rollout 文件不大、且只有活跃 session 的文件 mtime 会动（其余被 cursor 跳过）。`(msgId,reqId)=sessionId:lineIndex` 去重保证幂等。超大 rollout 文件的增量优化（记上次 turn_id + model）→ 后续 YAGNI。
3. **隐私敏感面**（读含完整对话/代码的 rollout 文件）—— SC9 硬约束 + `SC_AUTO_NO_RAW_LOG` + 字段集合断言；落盘只有 `StoredUsageEvent`/`ScanCursorFile`，沿用 0700/0600。可接受。
4. **未知模型** —— `lookup` 返回 nil → `usdForBucket` 走 `isUnknownPricing`（USD 计 0、计 unknown count）→ UI 标出。用户改 `OpenAIPricing.table` 即可。
5. **`any ModelPriceTable` 作存储属性 + `Sendable`** —— 协议标 `Sendable`、conformer 全 value type → OK；`ProviderCostContext` 持 `any ModelPriceTable` + 一个 `(String)->String` 闭包（闭包非 Sendable，但 `ProviderCostContext` 只在 MainActor 视图层用，不跨 actor）—— 可接受。

## 6. 后续工作（不在本 spec 范围）

- v0.2.10：Settings 改 provider 列表（拖动排序 + 启用开关 + 菜单栏子开关）、去 Primary Provider 下拉、去 Settings 的 Account 区、刷新纪律（统一 polling interval、切 tab / 打开 popover 不再触发刷新只渲染缓存、刷新只走「后台 timer + Refresh 按钮」两入口、`ProviderCoordinator` 统管 timer/顺序/启用集/菜单栏 provider）
- 把 v0.2.8 引入的 `(service:primaryLabel:secondaryLabel:)` history tuple 也收敛进具名 struct（本版本已把 cost 那个 tuple 做成 `ProviderCostContext`）
- rollout 解析的增量优化（记上次 turn_id + model）—— 仅当出现超大 rollout 文件
- Codex 用 ChatGPT Web/RPC 兜底数据源（research §4 列）
- 校准 `OpenAIPricing` 表（拿到确切来源后去掉 `// UNVERIFIED`）

## 7. 引用

- 前置 spec：[`2026-05-11-local-cost-scan.md`](./2026-05-11-local-cost-scan.md)（Claude 本机扫描流水线）、[`2026-05-12-usage-store-redesign.md`](./2026-05-12-usage-store-redesign.md)（per-provider `UsageEventStore`）、[`2026-05-12-codex-provider.md`](./2026-05-12-codex-provider.md)、[`2026-05-12-codex-history-trend.md`](./2026-05-12-codex-history-trend.md)（`ProviderHistorySection`）、[`2026-05-12-popover-redesign.md`](./2026-05-12-popover-redesign.md)
- 调研：[`../research/codex-data-sources.md`](../../research/codex-data-sources.md)（§4「本地 session JSONL」）
- ADR：[`../adr/0005-reopen-multi-provider-direction.md`](../../adr/0005-reopen-multi-provider-direction.md)
- 落地版本：[`../versions/v0.2.9-codex-cost-heatmap.md`](../../versions/v0.2.9-codex-cost-heatmap.md)

## Verification log

> G6 验收依据（详见 frontmatter `spec_criteria` 的 evidence）。

- [x] SC1 — 定价层泛化（`ModelPriceTable` + `ClaudeModelPriceTable` + 聚合器/LocalCostCard 默认参数）
- [x] SC2 — `OpenAIPricing` 估价表 + `OpenAIModelPriceTable`
- [x] SC3 — `CodexRolloutCostParser`（状态机 + token 映射 + sessionId 解析）
- [x] SC4 — `CodexUsageCollector` + `ScanCursorStore` per-provider
- [x] SC5 — `UsageStatsService` 加 `pricing`/`UsageCollecting` + `convenience init(provider:)`
- [x] SC6 — App 接线（`codexStats` StateObject + `.task` refresh + `CodexProvider.onPollTick`）
- [x] SC7 — Codex tab UI：去 Plan 卡 + 估算费用卡 + 消费热力图（`ProviderCostContext`）
- [x] SC8 — Claude / 既有零回归
- [x] SC9 — 安全/隐私（Codex 路径只落 token/model/ts/ids，不落原文/路径，不打印；字段集合断言）
- [x] SC10 — swift build / swift test（含新测试）/ make release-artifacts + verify 全绿
