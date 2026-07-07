---
id: 2026-05-11-local-cost-scan
title: 本地 JSONL 成本扫描（30 天 USD 累积 + per-model token）
status: superseded
created: 2026-05-11
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.1.2
related_adrs: [0001, 0002]
related_research: [competitive-analysis]
superseded_by: 2026-05-12-usage-store-redesign
spec_criteria:
  - id: SC1
    criterion: "新增 macos/Sources/UsageBar/ClaudePricing.swift：内嵌 LiteLLM-compatible 离线快照价格表（截至 2026-05 公开模型）；提供 struct ClaudeModelPricing { inputUSDPerMTok, outputUSDPerMTok, cacheReadUSDPerMTok, cacheWriteUSDPerMTok }；提供 lookup(model:) -> ClaudeModelPricing? 返回 nil 表示未知模型（unknown 落盘但 cost=0 且 unknownModelCount++）"
    done: true
    evidence: "see ## Verification log"
  - id: SC2
    criterion: "新增 macos/Sources/UsageBar/JSONLCostParser.swift：纯函数 parseLine(_ line: String) throws -> JSONLUsageEvent?（type≠assistant 返回 nil；JSON 失败抛错；只读 message.{id, model, usage.{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}} + top.{requestId, timestamp}；**不读 message.content**）"
    done: true
    evidence: "see ## Verification log"
  - id: SC3
    criterion: "新增 macos/Sources/UsageBar/LocalCostScanner.swift：actor LocalCostScanner（@MainActor 不需要，actor 隔离即可）；scan() async -> CostSummary：枚举扫描根 → 列 *.jsonl → 按行读 → parser → 按 (msg.id, requestId) 去重 → 按 timestamp 滚动 30 天窗口 → per-model 累积 token + 用 ClaudePricing 算 USD；CostSummary { generatedAt, windowDays:30, totalUSD, perModel:[ModelCost], unknownModelCount, parseErrorCount }"
    done: true
    evidence: "see ## Verification log"
  - id: SC4
    criterion: "扫描根优先级（按 ccusage / CodexBar 实测对齐）：环境变量 CLAUDE_CONFIG_DIR（冒号分隔多路径，每个路径附加 /projects 子目录）→ ~/.config/claude/projects → ~/.claude/projects；不存在的目录跳过不报错；不读 ~/.pi/agent/sessions（CodexBar 私有路径，本 spec 不引入）"
    done: true
    evidence: "see ## Verification log"
  - id: SC5
    criterion: "缓存：~/Library/Caches/usage-bar/cost-usage/claude-v1.json（mode 0644 即可，不含 secrets）；scan() 调用时若 cache.generatedAt < 60s 直接返回 cache；写盘失败仅 log 不抛；版本号 v1（schema 升级时 bump）"
    done: true
    evidence: "see ## Verification log"
  - id: SC6
    criterion: "30 天窗口语义：以 scan() 调用时刻 now 为基准，timestamp >= (now - 30 * 86400) 的事件计入；事件 timestamp 用 message 顶层 timestamp 字段（ISO8601）；解析失败行计入 parseErrorCount 但不中断扫描"
    done: true
    evidence: "see ## Verification log"
  - id: SC7
    criterion: "**安全/隐私约束（v0.1.1 SC7 永久警示延续 + 扩展隐私边界）**：禁止 print/log JSONL 行原文（含 message.content / user message body 可能含 API key / proprietary code / 个人信息）；parser 主动**不读 content 字段**（只 decode usage 子集 schema，testEnvelopeDoesNotDecodeContentField 必须存在）；错误日志**只 log error type，不 log 文件名（含 session UUID）/ 完整路径**（G2 #1 修订：basename = `<sessionUUID>.jsonl` 仍属半结构化隐私信息）；**测试 mock JSONL 不含真实 API key 前缀**（'sk-ant-' / 'sk-proj-' / 'AKIA' 等）；SC_AUTO_NO_PRINT_TOKENS / SC_AUTO_NO_REAL_TOKEN_PREFIX / SC_AUTO_NO_CONTENT_READ 守护范围扩到本 spec 新增 4 文件 + Tests"
    done: true
    evidence: "see ## Verification log"
  - id: SC8
    criterion: "UsageService 暴露 @Published localCost30d: CostSummary?；新增 func refreshLocalCostIfNeeded() async **不带 @MainActor**（G3 #2 修订：内部用 Task.detached 跑 scan，避免 await actor IO 期间持有 MainActor 任务）；启动 task 内调用一次；**polling timer 内禁止调用 scan 或 refreshLocalCostIfNeeded**（grep 守护：`! grep -nE '(refreshLocalCostIfNeeded|LocalCostScanner)' macos/Sources/UsageBar/UsageService.swift | grep -v '^.*: *func\\|^.*: *@Published\\|^.*: *let summary'` 只允许声明行命中）"
    done: true
    evidence: "see ## Verification log"
  - id: SC9
    criterion: "PopoverView 在 5h hero / 7d secondary 卡（及 ExtraUsageRow 之后）加 LocalCostCard（**新文件 LocalCostCard.swift**，G3 #5 决议：PopoverView 已 380+ 行，避免内嵌膨胀）（小字体）：'本地 30 天估算 ≈ $X.XX'；点击展开 per-model 明细；**localCost30d == nil 或 scannedFileCount == 0 时隐藏整张卡**（G2 B 修订：不打扰未装 CLI / 无 JSONL 的用户）；卡片底部 'ℹ️ 仅扫本地 JSONL 用量字段，不读对话内容' 一行隐私提示；'含 N 条未知模型调用记录'（G2 ADVISORY：明确是 calls 数而非 model 种数）"
    done: true
    evidence: "see ## Verification log"
  - id: SC10
    criterion: "新增 ClaudePricingTests / JSONLCostParserTests / LocalCostScannerTests：≥10 case 总计（pricing lookup / parser line skip+decode / scanner 去重 + 30d 窗口 + 缓存命中 + unknown model fallback）；测试用 inline mock JSONL 字符串不读真实文件；mock 不含真实 token 前缀"
    done: true
    evidence: "see ## Verification log"
  - id: SC11
    criterion: "不动 OAuth / refresh / polling timer / SetupView / CodeEntry / Settings / Notifications / hero/menubar/pace/trend 既有渲染（仅 PopoverView 加新卡 + UsageService 加新属性 + bootstrap 链路加 1 个 await）"
    done: true
    evidence: "see ## Verification log"
  - id: SC12
    criterion: "cd macos && swift build -c release 输出 'Build complete!'；cd macos && swift test 'Executed N tests, with 0 failures' 含本 spec 新增 ≥10 case"
    done: true
    evidence: "see ## Verification log"
  - id: SC13
    criterion: "git commit 中文、含变更主题 + spec id；spec.reviews 数组含 G2（含 security/privacy review）、G3、G5、G6 四条 verdict；version v0.1.2 frontmatter status placeholder→planned→in-progress；CHANGELOG.md append v0.1.2 中文 entry"
    done: true
    evidence: "see ## Verification log"
automated_checks:
  - "SC_AUTO_BUILD: cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release 2>&1 | tail -3 | grep -q 'Build complete'"
  - "SC_AUTO_TEST: cd /Users/methol/data/code-methol/usage-bar/macos && swift test 2>&1 | tail -5 | grep -E 'Executed [0-9]+ test.*0 failures'"
  - "SC_AUTO_NO_PRINT_TOKENS: ! grep -nrI -E '(print|NSLog|os_log|os\\.log|Logger)\\s*[\\(,].*([Aa]ccess[Tt]oken|[Rr]efresh[Tt]oken|rawJSON|claudeAiOauth|message\\.content|jsonlLine|rawLine|lastPathComponent)' macos/Sources/UsageBar/ 2>/dev/null"
  - "SC_AUTO_NO_REAL_TOKEN_PREFIX: ! grep -nrI -E 'sk-ant-(oat|ort|api)[0-9a-zA-Z]|sk-proj-[0-9a-zA-Z]|AKIA[0-9A-Z]{16}' macos/ docs/ CHANGELOG.md 2>/dev/null  # 后置硬匹配避免命中 spec 描述用的 grep 表达式自身"
  - "SC_AUTO_NO_CONTENT_READ: ! grep -nrIE 'message\\.content|JSONLUsageEvent[^/]*\\.content|Envelope\\.Message[^/]*\\bcontent\\b\\s*:' macos/Sources/UsageBar/JSONLCostParser.swift macos/Sources/UsageBar/LocalCostScanner.swift macos/Sources/UsageBar/LocalCostCard.swift 2>/dev/null  # G2 C 修订：仅捕获 message.content 或 schema 字段引用，不误报 let content 变量"
manual_checks:
  - "已用过 Claude CLI 的用户启动 .app：popover 出现\"本地 30 天估算 ≈ $X.XX\"卡片"
  - "未装 Claude CLI / 无 JSONL 文件用户：cost 卡片完全隐藏（不显示 $0.00 误导）"
  - "**隐私 manual check**：开发期不允许把任何用户对话日志贴到 commit / spec / PR / 测试 fixture；测试 fixture 全部由 spec 作者手写"
  - "缓存命中 manual check：popover 打开两次，第二次 < 100ms（命中 60s cache）"
reviews:
  - gate: G2
    reviewer: codex:codex-rescue (general-purpose fallback, agentId a212bbfd8f5465bf9, with security/privacy review focus)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（3 BLOCKING + 4 RECOMMENDED + 5 ADVISORY）。
      作者按 superpowers:receiving-code-review 流程处理：
      - BLOCKING #1 (NSLog file.lastPathComponent 含 sessionUUID) accepted — LocalCostScanner.performScan
        catch 块 NSLog 删除 `in \(file.lastPathComponent)`；SC7 文字更新
        "只 log error type，不 log 文件名（含 session UUID）"；SC_AUTO_NO_PRINT_TOKENS
        grep 加 `lastPathComponent` 关键字守护。
      - BLOCKING #2 (claude-opus-4-7 价格来源) accepted — ClaudePricing.swift 头部加
        LiteLLM URL + 注释说明 family 价 + 子版本沿用。
      - BLOCKING #3 (seen Set 内存上限) accepted — §5 风险 #3 补估算
        "10 万条 key × 70 bytes ≈ 7MB 峰值，actor 内 performScan 局部，scan 结束 release；
        500k 上限保险留后续 increment"。
      - RECOMMENDED A (DST 边界) accepted — §5 风险 #4 加文字"< 0.14% 误差可接受"。
      - RECOMMENDED B (SC9 nil 分支) accepted — SC9 文字"localCost30d == nil 或
        scannedFileCount == 0 时隐藏整张卡"。
      - RECOMMENDED C (SC_AUTO_NO_CONTENT_READ 注释误报 + 文件少) accepted —
        frontmatter 重写 grep 正则排除注释行 (^[^/]*…)；扩到 LocalCostCard.swift。
      - RECOMMENDED D (JSONEncoder.iso 命名污染) accepted —
        LocalCostScanner.swift 改用 private static encoder/decoder；删全局 extension。
      - ADVISORY (urls.first! force unwrap) accepted — init 加 NSTemporaryDirectory 兜底。
      - ADVISORY (ExtraUsage.formatUSD 引用) accepted — §4 表加"复用 ExtraUsage.formatUSD"。
      - ADVISORY (unknownModelCount 命名歧义) accepted — UI 文案 "N 条未知模型调用记录"。
      - ADVISORY (P0 linkcheck 命令) 与 G3 #3 合并处理。
      - ADVISORY (SC7 测试明确) accepted — SC7 criterion 加"testEnvelopeDoesNotDecodeContentField 必须存在"。
      - Confirmed correct 全部 ✅。
    artifacts: ["G2 review subagent output (agentId a212bbfd8f5465bf9)"]
  - gate: G3
    reviewer: claude-code (general-purpose subagent, agentId a9187a6660d37e2b2)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（5 BLOCKING + 6 RECOMMENDED + 5 NOTES）。
      作者按 superpowers:receiving-code-review 流程处理：
      - BLOCKING #1 (SC8 polling 不该调 scan 缺 grep 守护) accepted — SC8 criterion 加
        grep 守护表达式；P2 success 加同一 grep。
      - BLOCKING #2 (refreshLocalCostIfNeeded @MainActor + await actor IO 阻塞) accepted —
        §3.5 改写：删 @MainActor，内部 Task.detached + MainActor.run；SC8 文字同步；
        与 v0.1.1 SecItemCopyMatching Task.detached 工艺对齐。
      - BLOCKING #3 (P0 linkcheck/frontmatter 缺命令) accepted — P0 success 加 grep status
        + python3 YAML parse + grep verification log 行数三条具体命令。
      - BLOCKING #4 (P1 grep 'message.content' 注释误报) accepted — 直接引用 frontmatter
        SC_AUTO_NO_CONTENT_READ（已修订排除注释）；删除冗余 grep。
      - BLOCKING #5 (LocalCostCard inline vs 新文件) accepted — 决定**新文件 LocalCostCard.swift**；
        SC9 / §3.6 / §4 / P2 文字一致更新。
      - RECOMMENDED R1 (swift test count check) accepted — P1 success 加 count >=97 grep。
      - RECOMMENDED R2 (P3 grep schema 校验) accepted — 与 v0.1.1 spec.reviews schema
        一致（`^  - gate:`），无需调整。
      - RECOMMENDED R3 (B 独立 stash 验证) noted-only — 与 v0.1.1 经验对齐，
        B 是纯新增（leaf module 无 callers），编译独立性靠类型系统保证。
      - RECOMMENDED R4 (拆分 P1) noted-only — 与 v0.1.1 单 commit 经验一致：
        pricing + parser + scanner 三者强相关（同一数据流），分开 commit 反增反序复杂度。
      - RECOMMENDED R5 (parseErrorCount UI surface) accepted — §5 风险 #2 删除
        "UI 高比例时提示"承诺，明确"本 spec 不在 UI 显示该计数"。
      - RECOMMENDED R6 (scanRoots 测试) accepted — P1 test 加 testScanRootsRespectsEnvOverride；
        LocalCostScanner.scanRoots 加可测试 overload（env + home + fileExists 注入）。
      - NOTES N1 (cache miss after 60s) accepted — P1 test 加 testCacheMissAfter60sCutoff。
      - NOTES N2 (Dictionary[default:].add pin test) accepted — P1 test 加
        testAggregationAccumulatesAcrossLines。代码用显式 `if nil` 分支
        避免依赖 _modify subscript 行为。
      - NOTES N3 (PopoverView 插入点) accepted — P2 文字加"ExtraUsageRow 之后"。
      - NOTES N4 (.tertiary api macOS 14) confirmed ✅ — SwiftUI ShapeStyle.tertiary
        在 macOS 12+ 可用，无需调整。
      - NOTES N5 (windowDays SSOT) accepted — LocalCostScanner 仅在 actor init 一处声明；
        SC6 criterion 引用 actor 字段而非数字字面量。
    artifacts: ["G3 review subagent output (agentId a9187a6660d37e2b2)"]
  - gate: G5
    reviewer: codex:codex-rescue (general-purpose fallback, agentId acf6fba1727b29521, with security/privacy review focus)
    date: 2026-05-11
    verdict: approved
    summary: |
      原始 verdict: approved（0 BLOCKING + 3 RECOMMENDED + 5 NOTES）。
      作者按 superpowers:receiving-code-review 流程处理：
      - R1 (refreshLocalCostIfNeeded 写回 self.localCost30d 缺 @MainActor.run 显式标注) accepted —
        UsageService.swift refreshLocalCostIfNeeded 改为 `await MainActor.run { ... }` 显式包裹写回，
        与 v0.1.1 G5 修订 (@MainActor on bootstrapFromCLIIfNeeded) 同款防御工艺。
      - R2 (dedupe key msgId 全局唯一性需注释保护) accepted — LocalCostScanner.swift 加 1 行注释
        "msgId 是 Anthropic 生成的全局唯一 UUID（msg_01...），跨 session 不碰撞；requestId 进一步区分同一 msg 的 retry"。
      - R3 (ExtraUsage.formatUSD 重构为顶层 utility) noted-only — 低优先级，当前实现无功能缺陷；
        formatUSD 跨 cards 复用属于自然依赖；future increment 若 cards 数 ≥ 3 可考虑提取。
      - NOTES N1~N5 confirmed ✅：30d 边界包含语义、actor 隔离 cache、@MainActor class 默认推断、
        Mirror 反射 SC7 强守护、NSLog type(of:error) 仅 type 不 leak。
      - Confirmed correct 全部 ✅（SC7-A/B/C 隐私守护、LOGIC-1~4 正确性、MINIMALITY-1/2 改动隔离、
        UI-1/2 截断与 padding、TEST 103/103、PRIVACY-EXTRA 无其他泄漏路径）。
    artifacts: ["G5 review subagent output (agentId acf6fba1727b29521)"]
  - gate: G6
    reviewer: claude-code (main session, automated checks + manual UI verification deferred)
    date: 2026-05-11
    verdict: approved
    summary: |
      G6 merge 前验收：spec_criteria SC1~SC13 全部 done=true。
      - 自动化：SC_AUTO_BUILD `swift build -c release` ✅；SC_AUTO_TEST
        `swift test` 103/103（含 19 新增 case：4 ClaudePricing + 7 JSONLCostParser + 8 LocalCostScanner，
        基线 v0.1.1 84 + 19 = 103）✅
      - 安全/隐私：SC_AUTO_NO_PRINT_TOKENS（含 lastPathComponent 守护扩展）0 匹配 ✅；
        SC_AUTO_NO_REAL_TOKEN_PREFIX 后置 [0-9a-zA-Z] 硬匹配 0 匹配 ✅；
        SC_AUTO_NO_CONTENT_READ 修订后 0 匹配 ✅；
        Envelope.Message schema 实证不含 content 字段（testEnvelopeDoesNotDecodeContentField Mirror 守护）✅；
        NSLog 仅 type(of: error) 无 lastPathComponent 泄漏 ✅
      - 治理流程：G2（含 security/privacy review）/ G3 / G5（含 security/privacy review）
        三轮独立 reviewer 共 8 BLOCKING + 13 RECOMMENDED + 5 NOTES + 5 ADVISORY 全数受理或 reasoned reject；
        G2 独立命中 sessionUUID basename 泄漏 + 价格表来源 + seen Set 内存上限；
        G3 命中 refreshLocalCostIfNeeded concurrency + LocalCostCard 文件决议 + SC8 polling 守护缺失；
        G5 命中 MainActor.run 显式标注 + msgId 唯一性注释保护
      - SC8 polling 守护：grep 验证 LocalCostScanner / refreshLocalCostIfNeeded 仅在 refreshLocalCostIfNeeded
        函数体内出现，startPolling/scheduleTimer/fetchUsage 无引用 ✅
      - 隐私架构强守护：parser Envelope.Message struct 类型层禁止 content 字段（schema-level 而非
        runtime discipline）；Mirror 反射 testEnvelopeDoesNotDecodeContentField 在未来意外添加时立即红灯
      - v0.1.1 SC7 事故警示延续 + 扩展：从"禁止 print/log credentials"扩到"禁止 print/log JSONL 内容
        + 文件名（含 sessionUUID）"；自动化双守护（NO_PRINT_TOKENS + NO_CONTENT_READ）
      G6 通过 → spec status: draft → implemented。
    artifacts: ["swift test 103/103 ✅", "SC_AUTO_NO_REAL_TOKEN_PREFIX 0 matches ✅", "SC_AUTO_NO_CONTENT_READ 0 matches ✅"]
---

# 本地 JSONL 成本扫描

## 1. 背景与目标

调研 §1.5 / §2.4 Path 4 / §5.2 Step C 指出 Claude CLI 把每次 assistant 调用的 token usage 写入 `~/.claude/projects/<project>/<sessionUUID>.jsonl`。CodexBar 与 ccusage 都通过解析这些 JSONL 计算本地成本估算，是 OAuth API 之外的关键数据源。

本 spec 引入：
- **离线价格表**（LiteLLM-compatible 快照）+ **JSONL 行级 parser** + **滚动 30 天 scanner**，输出 per-model token + USD cost
- popover 加 LocalCostCard 显示"本地 30 天估算 ≈ $X.XX"
- 60s 节流 + 磁盘缓存避免每次打开 popover 重复扫盘

**v0.1.1 事故警示延续 + 隐私扩展**：v0.1.1 SC7 已立"禁止 print/log credentials"。本 spec 进一步扩展到**禁止 print/log JSONL 行原文**（user message body 可能含 API key / proprietary code / 个人信息）。parser 在 schema 层主动**不 decode `message.content` 字段**——架构层防御而非依赖代码自律。

**不在范围**：
- 不引入菜单栏 `$/天` 显示模式（v0.0.10 已留扩展点；本 spec 仅触发"popover 可见"）
- 不引入 Settings 配置项（用户无需开关；自动检测 JSONL 路径）
- 不读 `~/.pi/agent/sessions/`（CodexBar 私有路径，pi.codex 用户极少）
- 不读流式 mid-stream usage（`type: "assistant"` 的中间 chunk 与终态共享 msg.id+requestId，去重已 cover）
- 不读 `type: "user"` 行（本 spec 仅算 cost，不算 user prompt 字符）
- 不引入 ADR（仍是 Strategy 协议骨架延伸；v0.1.3 multi-account 落地时统一开 ADR）
- a11y / i18n 不涉及

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 扫描根 | `$CLAUDE_CONFIG_DIR/projects` (冒号分隔多路径) → `~/.config/claude/projects` → `~/.claude/projects` | 与 ccusage / CodexBar 行为对齐；Anthropic 官方 CLI `~/.claude/projects` 是默认；环境变量优先 |
| 解析事件类型 | 仅 `type: "assistant"` 的行 | usage 字段只在 assistant 行；user/system/summary 行无 |
| 去重 key | `(message.id, requestId)` 元组 | 实测同一调用流式块可达 4~8 行同 key；不去重则 token 重复累积 5~10× |
| Cost 公式 | `(input + output*output_factor + cache_read*cr_factor + cache_creation*cw_factor) / 1M * 价格` | 与 LiteLLM / ccusage 一致；cache_creation 取 1h 价（5m TTL 价偏低，保守估计） |
| 价格表来源 | 离线快照（spec hardcoded） | 避免运行时网络请求；快照日期写入 ClaudePricing.snapshotDate；过时由后续 spec 升级 |
| 未知模型 fallback | cost=0 + unknownModelCount++ | 不阻塞扫描；UI 提示"含 N 个未知模型条目（价格表过时？）" |
| 30 天窗口 | scan now - 30*86400 ≤ event.timestamp ≤ now | 与调研 §2.4 Path 4 对齐 |
| 节流 | 60s in-memory + on-disk cache | 用户连续打开 popover 只触发一次 IO |
| 缓存路径 | `~/Library/Caches/usage-bar/cost-usage/claude-v1.json` | macOS 标准 cache 位；不含 secrets，0644；schema 版本 v1 |
| 触发时机 | UsageService 启动 task 内调用一次；polling timer **不**触发；可选 popover open 时检查 60s cache | 避免 IO 抖动；polling 是网络任务不该混合 IO |
| Strategy 协议复用 | **不复用** v0.1.1 ClaudeUsageStrategy（语义不同：那个返 credentials；这个返 cost summary） | YAGNI；强行抽象会损害单职责；v0.1.3 multi-account 才会真正出现"多 strategy 链"需要统一抽象 |
| **安全约束 SC7** | parser schema 层不 decode `content` 字段；error log 只 log file basename 不 log 完整路径 | v0.1.1 事故警示延续；架构防御 |
| Logger 选择 | NSLog 简短：`[usage-bar] cost scan: <ErrorType> in <basename>` | 与 v0.1.1 对齐 |

## 3. 设计

### 3.1 数据流

```
.app 启动 → UsageBarApp.task
              ├─ historyService.loadHistory()
              ├─ service.bootstrapFromCLIIfNeeded()
              ├─ service.refreshLocalCostIfNeeded()  // 新增（async，不阻塞 polling 启动）
              │     ├─ cache.generatedAt < 60s → return cache
              │     └─ LocalCostScanner.scan() async
              │           ├─ enumerate roots
              │           ├─ for each *.jsonl: line read → JSONLCostParser.parseLine
              │           ├─ dedupe by (msg.id, requestId)
              │           ├─ filter timestamp ≥ now-30d
              │           ├─ per-model accumulate
              │           ├─ ClaudePricing.cost(for: model, tokens: ...) 算 USD
              │           └─ write cache + return CostSummary
              └─ service.startPolling()

popover 打开 → LocalCostCard 读 service.localCost30d
              nil → 隐藏卡
              非 nil → 显示总额 + 展开后 per-model 明细
```

### 3.2 `ClaudePricing.swift`

```swift
import Foundation

/// LiteLLM-compatible 价格表离线快照（截至 2026-05-11）。
/// 价格单位：USD per 1M tokens。
/// 来源：Anthropic 官方定价页 + LiteLLM model_prices_and_context_window.json。
/// 价格过时由后续 spec 升级（bump snapshotDate）。
struct ClaudeModelPricing: Equatable {
    let inputUSDPerMTok: Double
    let outputUSDPerMTok: Double
    let cacheReadUSDPerMTok: Double      // 缓存命中折扣价
    let cacheWriteUSDPerMTok: Double     // 缓存写入溢价（按 1h TTL 价；5m TTL 同价或略低，保守估计取 1h）
}

enum ClaudePricing {
    static let snapshotDate = "2026-05-11"

    /// 已知模型价格表。key 用 lowercase + family normalize（去 -YYYYMMDD 后缀）。
    /// 未列出 = unknown，cost=0 + unknownModelCount++。
    private static let table: [String: ClaudeModelPricing] = [
        // Opus 系列
        "claude-opus-4-7":     .init(inputUSDPerMTok: 15.0, outputUSDPerMTok: 75.0, cacheReadUSDPerMTok: 1.50, cacheWriteUSDPerMTok: 18.75),
        "claude-opus-4-6":     .init(inputUSDPerMTok: 15.0, outputUSDPerMTok: 75.0, cacheReadUSDPerMTok: 1.50, cacheWriteUSDPerMTok: 18.75),
        "claude-opus-4":       .init(inputUSDPerMTok: 15.0, outputUSDPerMTok: 75.0, cacheReadUSDPerMTok: 1.50, cacheWriteUSDPerMTok: 18.75),
        // Sonnet 系列
        "claude-sonnet-4-6":   .init(inputUSDPerMTok: 3.0,  outputUSDPerMTok: 15.0, cacheReadUSDPerMTok: 0.30, cacheWriteUSDPerMTok: 3.75),
        "claude-sonnet-4-5":   .init(inputUSDPerMTok: 3.0,  outputUSDPerMTok: 15.0, cacheReadUSDPerMTok: 0.30, cacheWriteUSDPerMTok: 3.75),
        "claude-sonnet-4":     .init(inputUSDPerMTok: 3.0,  outputUSDPerMTok: 15.0, cacheReadUSDPerMTok: 0.30, cacheWriteUSDPerMTok: 3.75),
        // Haiku 系列
        "claude-haiku-4-5":    .init(inputUSDPerMTok: 1.0,  outputUSDPerMTok: 5.0,  cacheReadUSDPerMTok: 0.10, cacheWriteUSDPerMTok: 1.25),
        "claude-haiku-4":      .init(inputUSDPerMTok: 1.0,  outputUSDPerMTok: 5.0,  cacheReadUSDPerMTok: 0.10, cacheWriteUSDPerMTok: 1.25),
        // 旧 3.x family（部分用户仍在用）
        "claude-3-5-sonnet":   .init(inputUSDPerMTok: 3.0,  outputUSDPerMTok: 15.0, cacheReadUSDPerMTok: 0.30, cacheWriteUSDPerMTok: 3.75),
        "claude-3-5-haiku":    .init(inputUSDPerMTok: 0.80, outputUSDPerMTok: 4.0,  cacheReadUSDPerMTok: 0.08, cacheWriteUSDPerMTok: 1.0),
        "claude-3-opus":       .init(inputUSDPerMTok: 15.0, outputUSDPerMTok: 75.0, cacheReadUSDPerMTok: 1.50, cacheWriteUSDPerMTok: 18.75)
    ]

    /// 模型 ID 归一化：去日期后缀 + lowercase。
    /// 例：claude-opus-4-7-20260420 → claude-opus-4-7
    static func normalize(_ model: String) -> String {
        let lower = model.lowercased()
        // 剥离 -YYYYMMDD 后缀（8 位数字）
        if let range = lower.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return String(lower[..<range.lowerBound])
        }
        return lower
    }

    static func lookup(model: String) -> ClaudeModelPricing? {
        return table[normalize(model)]
    }

    /// 给定 token 数算 USD。pricing nil 时返 0。
    static func cost(for pricing: ClaudeModelPricing?, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        guard let p = pricing else { return 0 }
        return (Double(input) * p.inputUSDPerMTok
              + Double(output) * p.outputUSDPerMTok
              + Double(cacheRead) * p.cacheReadUSDPerMTok
              + Double(cacheWrite) * p.cacheWriteUSDPerMTok) / 1_000_000.0
    }
}
```

### 3.3 `JSONLCostParser.swift`

```swift
import Foundation

/// 单条 JSONL 行解析结果（仅含 cost 计算所需字段；**不**包含 content / user 输入）。
struct JSONLUsageEvent: Equatable {
    let messageId: String       // message.id
    let requestId: String       // top.requestId
    let model: String           // message.model
    let timestamp: Date         // top.timestamp (ISO8601)
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
}

enum JSONLCostParser {
    /// SC7 安全约束：本 schema 主动**不含 content 字段**；解码失败也不打印 raw line。
    private struct Envelope: Decodable {
        let type: String?
        let requestId: String?
        let timestamp: String?
        let message: Message?
        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
            // 注意：故意不 decode content 字段（SC7）
            struct Usage: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?
                let cacheCreationInputTokens: Int?
                let cacheReadInputTokens: Int?
                enum CodingKeys: String, CodingKey {
                    case inputTokens = "input_tokens"
                    case outputTokens = "output_tokens"
                    case cacheCreationInputTokens = "cache_creation_input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                }
            }
        }
    }

    enum ParseError: Error, CustomStringConvertible {
        case invalidJSON
        case missingRequiredField

        var description: String {
            switch self {
            case .invalidJSON: return "invalidJSON"
            case .missingRequiredField: return "missingRequiredField"
            }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 解析单行。返回 nil = 该行非 assistant 类型（应跳过），抛 ParseError = 真错误。
    static func parseLine(_ line: String) throws -> JSONLUsageEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { throw ParseError.invalidJSON }
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ParseError.invalidJSON
        }
        guard env.type == "assistant" else { return nil }
        guard let msg = env.message,
              let msgId = msg.id,
              let requestId = env.requestId,
              let model = msg.model,
              let timestampStr = env.timestamp,
              let usage = msg.usage else {
            throw ParseError.missingRequiredField
        }
        let timestamp = isoFormatter.date(from: timestampStr)
            ?? isoFormatterNoFractional.date(from: timestampStr)
        guard let ts = timestamp else { throw ParseError.missingRequiredField }
        return JSONLUsageEvent(
            messageId: msgId,
            requestId: requestId,
            model: model,
            timestamp: ts,
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheCreationInputTokens: usage.cacheCreationInputTokens ?? 0,
            cacheReadInputTokens: usage.cacheReadInputTokens ?? 0
        )
    }
}
```

### 3.4 `LocalCostScanner.swift`

```swift
import Foundation

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

actor LocalCostScanner {
    static let shared = LocalCostScanner()

    private let fileManager = FileManager.default
    private let cacheDir: URL
    private let cacheFile: URL
    private let cacheTTL: TimeInterval = 60
    private let windowDays: Int = 30

    init(cacheDirOverride: URL? = nil) {
        let base = cacheDirOverride
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("usage-bar/cost-usage", isDirectory: true)
        self.cacheDir = base
        self.cacheFile = base.appendingPathComponent("claude-v1.json")
    }

    /// 主入口：60s cache hit → 返回 cache；否则全量重扫。
    func scan(now: Date = Date()) async -> CostSummary {
        if let cached = loadCache(), now.timeIntervalSince(cached.generatedAt) < cacheTTL {
            return cached
        }
        let summary = await performScan(now: now)
        saveCache(summary)
        return summary
    }

    /// 测试入口：跳过 cache 直接 scan。
    func scanForceRefresh(now: Date = Date()) async -> CostSummary {
        let summary = await performScan(now: now)
        saveCache(summary)
        return summary
    }

    private func performScan(now: Date) async -> CostSummary {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86400)
        let roots = Self.scanRoots()
        var seen: Set<String> = []  // "msgId|requestId"
        var perModelAgg: [String: ModelAgg] = [:]
        var parseErrors = 0
        var fileCount = 0

        for root in roots {
            guard let files = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for projectDir in files where (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let jsonls = try? fileManager.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else { continue }
                for file in jsonls where file.pathExtension == "jsonl" {
                    fileCount += 1
                    guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    for line in content.split(separator: "\n") {
                        do {
                            guard let event = try JSONLCostParser.parseLine(String(line)) else { continue }
                            guard event.timestamp >= cutoff else { continue }
                            let key = "\(event.messageId)|\(event.requestId)"
                            if seen.contains(key) { continue }
                            seen.insert(key)
                            let normalized = ClaudePricing.normalize(event.model)
                            perModelAgg[normalized, default: ModelAgg(model: event.model, normalized: normalized)].add(event)
                        } catch {
                            parseErrors += 1
                            // SC7：仅 log error type + basename，不 log line raw / 完整路径
                            NSLog("[usage-bar] cost scan: \(type(of: error)) in \(file.lastPathComponent)")
                        }
                    }
                }
            }
        }

        var unknownCount = 0
        var total = 0.0
        var perModel: [ModelCost] = []
        for (_, agg) in perModelAgg {
            let pricing = ClaudePricing.lookup(model: agg.normalized)
            if pricing == nil { unknownCount += agg.calls }
            let usd = ClaudePricing.cost(
                for: pricing,
                input: agg.inputTokens,
                output: agg.outputTokens,
                cacheRead: agg.cacheReadTokens,
                cacheWrite: agg.cacheCreationTokens
            )
            total += usd
            perModel.append(ModelCost(
                model: agg.firstSeenModel,
                normalizedModel: agg.normalized,
                calls: agg.calls,
                inputTokens: agg.inputTokens,
                outputTokens: agg.outputTokens,
                cacheReadTokens: agg.cacheReadTokens,
                cacheCreationTokens: agg.cacheCreationTokens,
                usd: usd,
                isUnknownPricing: pricing == nil
            ))
        }
        perModel.sort { $0.usd > $1.usd }

        return CostSummary(
            generatedAt: now,
            windowDays: windowDays,
            totalUSD: total,
            perModel: perModel,
            unknownModelCount: unknownCount,
            parseErrorCount: parseErrors,
            scannedFileCount: fileCount
        )
    }

    private struct ModelAgg {
        let firstSeenModel: String
        let normalized: String
        var calls: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreationTokens: Int = 0
        init(model: String, normalized: String) {
            self.firstSeenModel = model
            self.normalized = normalized
        }
        mutating func add(_ e: JSONLUsageEvent) {
            calls += 1
            inputTokens += e.inputTokens
            outputTokens += e.outputTokens
            cacheReadTokens += e.cacheReadInputTokens
            cacheCreationTokens += e.cacheCreationInputTokens
        }
    }

    private func loadCache() -> CostSummary? {
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONDecoder.iso.decode(CostSummary.self, from: data)
    }

    private func saveCache(_ summary: CostSummary) {
        do {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let data = try JSONEncoder.iso.encode(summary)
            try data.write(to: cacheFile, options: .atomic)
        } catch {
            NSLog("[usage-bar] cost cache write failed: \(type(of: error))")
        }
    }

    /// 扫描根优先级（SC4）。
    static func scanRoots() -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
        if !env.isEmpty {
            for path in env.split(separator: ":") {
                let url = URL(fileURLWithPath: String(path)).appendingPathComponent("projects", isDirectory: true)
                if fm.fileExists(atPath: url.path) { roots.append(url) }
            }
        }
        let home = fm.homeDirectoryForCurrentUser
        let xdg = home.appendingPathComponent(".config/claude/projects", isDirectory: true)
        if fm.fileExists(atPath: xdg.path) { roots.append(xdg) }
        let legacy = home.appendingPathComponent(".claude/projects", isDirectory: true)
        if fm.fileExists(atPath: legacy.path) { roots.append(legacy) }
        return roots
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
```

### 3.5 `UsageService` 改动

G3 #2 修订：`refreshLocalCostIfNeeded` **不带 @MainActor**，内部 `Task.detached` 把扫描挪到 cooperative pool（与 v0.1.1 SecItemCopyMatching Task.detached 工艺对齐），最后用 `await MainActor.run` 写回 published 属性。这避免 MainActor 在 actor 长 IO 链上挂起。

```swift
@Published var localCost30d: CostSummary? = nil

func refreshLocalCostIfNeeded() async {
    let summary = await Task.detached(priority: .utility) {
        await LocalCostScanner.shared.scan()
    }.value
    await MainActor.run {
        self.localCost30d = summary.scannedFileCount > 0 ? summary : nil
    }
}
```

`UsageBarApp.task` 在 `bootstrapFromCLIIfNeeded()` 之后、`startPolling()` 之前 `await service.refreshLocalCostIfNeeded()`。**polling timer 内不调用 scan**（SC8 grep 守护）。

### 3.6 `LocalCostCard.swift` (PopoverView 内嵌或独立)

简单 SwiftUI 卡片：`service.localCost30d` 为 nil 时整张隐藏；否则显示总额 + DisclosureGroup 展开 per-model 行 + 底部隐私提示。

```swift
struct LocalCostCard: View {
    let summary: CostSummary
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("本地 30 天估算")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("≈ \(formatUSD(summary.totalUSD))")
                    .font(.caption).fontWeight(.medium)
            }
            if expanded {
                ForEach(summary.perModel, id: \.normalizedModel) { row in
                    HStack {
                        Text(row.normalizedModel)
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.isUnknownPricing ? "—" : formatUSD(row.usd))
                            .font(.caption2)
                    }
                }
                if summary.unknownModelCount > 0 {
                    Text("含 \(summary.unknownModelCount) 个未知模型条目（价格表过时？）")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Text("ℹ️ 仅扫本地 JSONL 用量字段，不读对话内容")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onTapGesture { withAnimation { expanded.toggle() } }
    }
    private func formatUSD(_ amount: Double) -> String {
        ExtraUsage.formatUSD(amount)
    }
}
```

### 3.7 测试

`ClaudePricingTests`（≥3 case）：
- testNormalizeStripsDateSuffix（`claude-opus-4-7-20260420` → `claude-opus-4-7`）
- testLookupKnownModelReturnsPrice
- testLookupUnknownReturnsNil
- testCostFormulaMatchesExpected（mock pricing + 1M of each → 公式逐项验证）

`JSONLCostParserTests`（≥4 case）：
- testValidAssistantLineDecodes（mock JSONL 一行）
- testNonAssistantTypeReturnsNil
- testEmptyLineReturnsNil
- testMissingRequiredFieldThrows
- testEnvelopeDoesNotDecodeContentField（关键 SC7 守护：mock 含 `content: "...token=mock-secret..."` 字段，确认 JSONLUsageEvent 不包含此信息）
- testIso8601WithFractionalParses

`LocalCostScannerTests`（≥3 case，用临时 cacheDirOverride）：
- testDeduplicationByMsgIdAndRequestId（mock 同 key 重复 5 次，calls 计 1）
- testWindowFilters30Days（mock 31 天前事件被过滤）
- testCacheHitWithin60s（连续两次 scan 第二次走 cache）
- testUnknownModelFallback（mock 一个 fake-model-99 → unknownModelCount > 0 且 totalUSD 不含此条）

### 3.8 Implementation plan（G3 对象）

**Step P0** — spec + version + 索引（Commit A，仅文档）✅ 已完成 commit `d24e311`
- 升 v0.1.2 placeholder→planned；删 guardrail
- specs/README.md / versions/README.md 索引同步
- **Success**（G3 #3 修订：可执行命令）:
  - `grep -A1 '^status:' docs/versions/v0.1.2-*.md` 输出 `status: planned`
  - `python3 -c "import yaml,sys; yaml.safe_load(open('docs/superpowers/specs/2026-05-11-local-cost-scan.md').read().split('---')[1])"` 退出 0（frontmatter YAML 解析通过）
  - `grep -c '^- \[' docs/superpowers/specs/2026-05-11-local-cost-scan.md` ≥ 13（SC1~SC13 Verification log 行）
- **覆盖 SC**: 无

**Step P1** — pricing + parser + scanner + 单测（Commit B）
- 新增 ClaudePricing.swift / JSONLCostParser.swift / LocalCostScanner.swift
- 新增 ClaudePricingTests / JSONLCostParserTests / LocalCostScannerTests（≥13 case，含 G3 R6 testScanRootsRespectsEnvOverride + G3 N1 testCacheMissAfter60sCutoff + G3 N2 testAggregationAccumulatesAcrossLines + G2 SC7 testEnvelopeDoesNotDecodeContentField）
- **Success**:
  - `cd macos && swift build -c release` 绿；`cd macos && swift test` 绿
  - `cd macos && swift test 2>&1 | grep -E 'Executed (9[7-9]|[1-9][0-9]{2}) tests.*0 failures'` 命中（基线 v0.1.1 84 + ≥13 = ≥97）（G3 R1 修订：count check）
  - SC_AUTO_NO_REAL_TOKEN_PREFIX / SC_AUTO_NO_PRINT_TOKENS / SC_AUTO_NO_CONTENT_READ 三守护无匹配（G3 #4 修订：用 frontmatter 已修订的 grep，注释行排除）
- **覆盖 SC**: SC1, SC2, SC3, SC4, SC5, SC6, SC7（前置）, SC10, SC12（前半）

**Step P2** — UsageService 暴露 + UsageBarApp 接入 + LocalCostCard（Commit C）
- UsageService 加 @Published localCost30d + refreshLocalCostIfNeeded()（**不 @MainActor**，内部 Task.detached + MainActor.run；G3 #2 修订）
- UsageBarApp.task 在 bootstrapFromCLIIfNeeded 之后、startPolling 之前 await refreshLocalCostIfNeeded
- PopoverView 在 ExtraUsageRow 之后插入 LocalCostCard 引用（G3 N3）
- **新文件** macos/Sources/UsageBar/LocalCostCard.swift（G3 #5 决议：避免 PopoverView 380+ 行膨胀）
- **Success**:
  - `cd macos && swift build -c release && swift test` 全绿
  - `git diff --stat HEAD~1..HEAD` 仅触白名单：`macos/Sources/UsageBar/UsageService.swift` + `UsageBarApp.swift` + `PopoverView.swift` + `LocalCostCard.swift`（新文件）
  - SC8 polling 守护：`! grep -nE 'refreshLocalCostIfNeeded|LocalCostScanner' macos/Sources/UsageBar/UsageService.swift | grep -v -E '^\d+:\s*(func|@Published|let summary|await)'` 应为空（除声明 + 直接 await 行外不该出现）
  - SC_AUTO_NO_PRINT_TOKENS / SC_AUTO_NO_REAL_TOKEN_PREFIX / SC_AUTO_NO_CONTENT_READ 仍无匹配
- **覆盖 SC**: SC8, SC9, SC11, SC12（后半）

**G5 gate** — 独立 reviewer code-review 加 security/privacy review focus
- (a) SC7 隐私守护：grep 无 print/log line raw / message.content
- (b) parser schema 不包含 content 字段
- (c) 30 天窗口边界（恰好 30 天前事件 / 1 秒前事件）
- (d) 去重 key 正确（msg.id 单独不够，必须含 requestId）
- (e) 缓存 60s TTL 边界
- (f) 未知模型 fallback 不让 totalUSD 暴增（cost=0 而非用 default 价）
- (g) UsageService 改动最小（只加 published + 1 方法）
- (h) commit B/C 独立可 revert

**Step P3 — G6 收尾**（Commit D）
- spec.status accepted → implemented；reviews append G5 + G6
- Verification log 全 [x]；索引同步；CHANGELOG entry；version → in-progress
- **Success**：
  - `grep -c '^  - gate:' docs/superpowers/specs/2026-05-11-local-cost-scan.md` 输出 4
  - `grep -c '^## \[v0.1.2\]' CHANGELOG.md` 输出 1
- **覆盖 SC**: SC13

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/UsageBar/ClaudePricing.swift` | 离线价格表 |
| 🆕 | `macos/Sources/UsageBar/JSONLCostParser.swift` | 行级 parser，schema 不含 content |
| 🆕 | `macos/Sources/UsageBar/LocalCostScanner.swift` | actor 扫描器 + 缓存 |
| 🆕 | `macos/Sources/UsageBar/LocalCostCard.swift` | popover 内嵌卡（或合并入 PopoverView.swift） |
| 🆕 | `macos/Tests/UsageBarTests/ClaudePricingTests.swift` | ≥3 case |
| 🆕 | `macos/Tests/UsageBarTests/JSONLCostParserTests.swift` | ≥4 case 含 SC7 守护 |
| 🆕 | `macos/Tests/UsageBarTests/LocalCostScannerTests.swift` | ≥3 case |
| 🔧 | `macos/Sources/UsageBar/UsageService.swift` | 加 @Published + refreshLocalCostIfNeeded() |
| 🔧 | `macos/Sources/UsageBar/UsageBarApp.swift` | .task 加 await |
| 🔧 | `macos/Sources/UsageBar/PopoverView.swift` | 引用 LocalCostCard |
| 🔧 | `docs/versions/v0.1.2-local-cost-scan.md` / 索引 / CHANGELOG | 标准收尾 |
| ✅ 不动 | OAuth / refresh / SetupView / CodeEntry / Settings / Notifications / Strategy(v0.1.1) / 数据层 / hero/menubar/pace/trend | 仅 popover 加新卡 + bootstrap 链路加 1 await |

## 5. 风险 / Open questions

1. **价格表过时**：snapshotDate 写在 ClaudePricing；新模型出现 → unknownModelCount 提示 + 用户感知。**对策**：CHANGELOG 提示用户"成本估算可能低估，已知未列模型 N 个"。
2. **JSONL schema 漂移**：Claude CLI 改 usage 字段名 → parser missingRequiredField 累计 → UI 无显著变化（因为 totalUSD 仍 > 0）。**对策**：parseErrorCount 暴露在 CostSummary 字段供调试；本 spec **不**在 UI 显示该计数（G3 R5 修订：避免做出未实现的承诺）。后续若用户报 cost 不准可加 UI 提示，留 v0.1.x 后续 increment。
3. **大文件 + 内存性能**：单个 JSONL 可达数 MB（实测 1430 行 ≈ 1.4MB）；扫全 30d 项目可能 100+ 文件。**actor 隔离 + Task.detached + 60s cache** 防止重复 IO 与主线程阻塞；首次启动 actor + detached task 协同跑可能 200~500ms 但 100% off-main。**`seen` Set 内存上限**（G2 #3）：10 万条 key × 70 bytes ≈ 7MB 峰值，actor 内 performScan 局部变量，scan 结束 release。重度用户（30d > 50 万事件）罕见；接受不加 cap，未来若实测溢出再加 `if seen.count > 500_000 { break }` 保险。
4. **30 天窗口 DST 边界**（G2 A）：`30 * 86400` 是固定秒数，跨夏令时切换时窗口实际跨 30d ± 1h。对成本估算可接受（< 0.14% 误差）；不修。
5. **隐私边界**：本 spec **architecture-level 守护**（parser schema 不含 content）+ **测试 fixture 全部手写** + **错误日志只 log error type，不 log 文件名**（G2 #1 修订：basename 含 sessionUUID 仍属半结构化隐私）。Manual check：禁止把任何用户对话日志贴 commit/PR。
6. **缓存陈旧**：60s TTL 内即使用户跑了 10 次新 Claude 调用也看不到；接受（成本估算非实时刚需）。
7. **不读 user prompt 行**：本 spec 不算 user prompt 字符成本（仅算 assistant 输出 + cache）。Anthropic 计费基于 input + output；user prompt 在下次 assistant 调用 input_tokens 已包含；**不重复计算**。
8. **CLAUDE_CONFIG_DIR 多路径冲突**：若同一 sessionUUID.jsonl 出现在多个根（不应该但理论可能），dedupe key (msg.id, requestId) 自然处理；不会重复计数。
9. **macOS Sandbox**：当前 .app 未沙盒化（Info.plist 无 entitlements），可读 `~/.claude/`；**未来若打开 sandbox**，需 user-selected directory permission，本 spec 不处理。Caches dir force-unwrap 已加沙盒/异常环境兜底（NSTemporaryDirectory）。
10. **a11y / i18n**：本 spec 仅一张卡 + 几行中文文案；未来 i18n 时与 PopoverView 一起处理。
11. **JSONEncoder/Decoder 全局 extension 命名污染**（G2 D 修订）：原 spec 草稿在文件末尾给 `JSONEncoder` / `JSONDecoder` 加 `static let iso`，会污染全局命名域。修订：改为 `LocalCostScanner` 私有 static `encoder` / `decoder`。

## 6. 后续工作（不在本 spec 范围）

- 菜单栏 `$/天` 模式（v0.0.10 留位） → 后续小 increment
- 价格表自动从 LiteLLM 同步 → v0.2.x 评估（隐私 / 网络成本）
- MultiAccount cost 分账（v0.1.3 multi-account 配套） → v0.1.3 spec 内统一处理
- pi.codex `~/.pi/agent/sessions/` 扩展扫描根 → 用户报告再加
- 未来扩展数据源 spec（按需立项）

## 7. 引用

- 调研：[`docs/research/competitive-analysis.md`](../../research/competitive-analysis.md) §1.5 / §2.4 Path 4 / §5.2 Step C / §8.3
- 母法：[`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md)
- 前置 spec（事故警示来源）：[`2026-05-11-claude-cli-credentials.md`](./2026-05-11-claude-cli-credentials.md)
- 落地版本：[`docs/versions/v0.1.2-local-cost-scan.md`](../../versions/v0.1.2-local-cost-scan.md)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [x] SC1 — evidence: commit `5183583` 新增 ClaudePricing.swift（11 个已知模型 family 价；normalize 去日期后缀；lookup nil = unknown；testNormalizeStripsDateSuffix + testLookupKnownModel + testLookupUnknown + testCostFormulaMatchesExpected 4 case ✅）
- [x] SC2 — evidence: commit `5183583` 新增 JSONLCostParser.swift（Envelope.Message schema 仅 id/model/usage 不含 content；testValidAssistantLineDecodes / testNonAssistantTypeReturnsNil / testEmptyLineReturnsNil / testInvalidJSONThrows / testMissingRequiredFieldThrows / testEnvelopeDoesNotDecodeContentField / testIso8601WithoutFractionalParses / testRequestIdFallbackToMessageId 8 case ✅）
- [x] SC3 — evidence: commit `5183583` 新增 LocalCostScanner.swift（actor 隔离 + scan(now:) async + (msgId,requestId) 去重 + 30 天滚动窗 + per-model 累积 + ClaudePricing.cost 算 USD；CostSummary/ModelCost 完整字段）
- [x] SC4 — evidence: commit `5183583` LocalCostScanner.scanRoots 实现优先级（CLAUDE_CONFIG_DIR/projects 冒号分隔 → ~/.config/claude/projects → ~/.claude/projects；不存在跳过）；testScanRootsRespectsEnvOverride 多场景 ✅
- [x] SC5 — evidence: cacheDir 默认 `~/Library/Caches/usage-bar/cost-usage`，cacheFile `claude-v1.json`；写盘 .atomic；cacheTTL = 60；testCacheHitWithin60s + testCacheMissAfter60sCutoff 边界 ✅
- [x] SC6 — evidence: performScan cutoff = now - windowDays(30) * 86400；event.timestamp >= cutoff；windowDays 单一 actor 字段（SSOT）；testWindowFilters30Days 31d/1d 实证 ✅
- [x] SC7 — evidence: Envelope.Message struct 不含 content 字段（schema-level 守护）；testEnvelopeDoesNotDecodeContentField Mirror 反射验证 JSONLUsageEvent 无 content/contentBlocks/text 属性；NSLog 仅 type(of: error) 不 log lastPathComponent；测试 mock JSONL 用 'mock-' / 'msg_mock_' / 'req_mock_' 前缀；SC_AUTO_NO_REAL_TOKEN_PREFIX `sk-ant-(oat\|ort\|api)[0-9a-zA-Z]\|sk-proj-[0-9a-zA-Z]\|AKIA[0-9A-Z]{16}` 全仓 0 匹配；SC_AUTO_NO_PRINT_TOKENS（含 lastPathComponent 守护）+ SC_AUTO_NO_CONTENT_READ 双守护 0 匹配
- [x] SC8 — evidence: commit `87e374f` UsageService 加 @Published localCost30d + refreshLocalCostIfNeeded() async（内部 Task.detached + MainActor.run 显式标注 G5 R1）；polling 守护 grep `refreshLocalCostIfNeeded\|LocalCostScanner` macos/Sources/UsageBar/UsageService.swift 仅命中函数声明 + 函数体内 await 行，startPolling/scheduleTimer/fetchUsage 无引用 ✅
- [x] SC9 — evidence: commit `87e374f` 新增 LocalCostCard.swift（独立文件 G3 #5 决议）；PopoverView ExtraUsageRow 之后插入 `if let cost = service.localCost30d { Divider(); LocalCostCard(...) }`；nil 时整张隐藏；点击 toggle expanded + chevron 视觉提示；per-model 行 calls 数 + USD（unknown 显 "—"）；底部"ℹ️ 仅扫本地 JSONL 用量字段，不读对话内容"隐私一行；未知模型橙色"含 N 条未知模型调用记录"
- [x] SC10 — evidence: 19 case 总计（4 ClaudePricing + 8 JSONLCostParser + 7 LocalCostScanner，超 ≥10 要求）；inline mock 不读真实文件；mock 不含 'sk-ant-' 真实前缀（SC_AUTO_NO_REAL_TOKEN_PREFIX 0 匹配）
- [x] SC11 — evidence: `git diff d24e311..HEAD --stat` 仅触白名单文件：UsageService.swift（仅加 @Published + refreshLocalCostIfNeeded 方法块）+ UsageBarApp.swift（仅 .task 加 await refreshLocalCostIfNeeded）+ PopoverView.swift（仅插入 6 行 if let cost 块）+ LocalCostCard.swift（新文件）+ 3 新源 + 3 测试；OAuth/refresh/polling timer/SetupView/CodeEntry/Settings/Notifications/Strategy(v0.1.1)/数据层/hero/menubar/pace/trend 全无改动 ✅
- [x] SC12 — evidence: `cd macos && swift build -c release` 输出 `Build complete!`；`cd macos && swift test` `Executed 103 tests, with 0 failures` ✅（基线 84 + 19 新增 = 103）
- [x] SC13 — evidence: 4 个中文 commit 均含 spec id（d24e311 P0 / 5183583 P1 / 87e374f P2 / 本 commit P3）；spec.reviews 含 G2/G3/G5/G6 共 4 条 verdict；version v0.1.2 frontmatter status placeholder→planned（d24e311）→in-progress（本 commit）；CHANGELOG.md append v0.1.2 entry（本 commit）
