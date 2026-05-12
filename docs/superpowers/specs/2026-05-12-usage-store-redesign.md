---
id: 2026-05-12-usage-store-redesign
title: 用量统计与存储重设计（按 provider 持久化 raw events + 聚合 + 消费热力图）
status: implemented
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.3
related_adrs: [0001, 0002]
related_research: [competitive-analysis]
supersedes: [2026-05-11-local-cost-scan]
spec_criteria:
  - id: SC1
    criterion: "新增持久化存储布局 ~/.config/claude-usage-bar/data/：明细 data/<provider>/<YYYY>-<MM>.json（{schemaVersion:1, provider, month, lastUpdated, events:[{ts, msgId, reqId, sessionId, model, inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens}]}，USD 不落盘；`month` 字段仅供人读，load 时以文件名为准）；聚合 data/<provider>/agg-day.json / agg-month.json / agg-year.json（{schemaVersion:1, provider, lastUpdated, buckets:{<key>:{<model 归一化后字符串>:{calls, inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens}}}}，day 键 YYYY-MM-DD（本地时区）/ month 键 YYYY-MM（UTC，与明细文件名一致）/ year 键 YYYY（UTC））；游标 data/scan-cursor.json（{schemaVersion:1, files:{<absJsonlPath>:{size, mtime, lineOffset}}}）；所有文件 mode 0600、data/ 及子目录 mode 0700"
    done: true
    evidence: "see ## Verification log"
  - id: SC2
    criterion: "新增 macos/Sources/ClaudeUsageBar/UsageEventStore.swift：actor UsageEventStore（构造接受 dataDirOverride: URL? 便于测试）；mergeEvents(_ events:[StoredUsageEvent]) async：按 ts 的 UTC 年月分组 → 对每月 load 现有明细文件 → 以 (msgId, reqId) 元组去重 union → atomic write（mode 0600）；rebuildAggregates(forDayKeys:) / rebuildAllAggregates() async：从明细文件重算受影响的 day/month/year 桶并回写三个 agg 文件；queryEvents(from:to:) / readDayAggregates() / readMonthAggregates() / readYearAggregates() async；月明细 decode 失败 → 该月按空处理 + 返回 dirtyMonths 供 collector 清游标重建；agg 文件损坏 / schemaVersion 不符 → 从明细全量重建"
    done: true
    evidence: "see ## Verification log"
  - id: SC3
    criterion: "新增 macos/Sources/ClaudeUsageBar/ScanCursorStore.swift（独立 actor，不并入 UsageEventStore——职责不同：一个是 scan 进度，一个是事实存储）：load/save data/scan-cursor.json；nextReadOffset(for fileURL:, currentSize:, currentMTime:) -> Int? 返回 nil 表示文件无变化整跳过、0 表示需全读（size 变小 / 文件首次见 / mtime 跳变到更早）、N 表示从第 N 行续读；updateCursor(for:, size:, mtime:, lineOffset:)；clearCursor(for:)（dirtyMonths 重建时清相关文件）；游标文件损坏 / schemaVersion 不符 → 丢弃退化为全量扫一次；游标文件 mode 0600"
    done: true
    evidence: "see ## Verification log"
  - id: SC4
    criterion: "新增 macos/Sources/ClaudeUsageBar/ClaudeUsageCollector.swift：actor ClaudeUsageCollector；collect() async -> CollectResult{newEventCount, scannedFileCount, parseErrorCount, touchedDayKeys:Set<String>}：枚举 scanRoots（沿用 v0.1.2 优先级 CLAUDE_CONFIG_DIR/projects 冒号分隔 → ~/.config/claude/projects → ~/.claude/projects）→ 对每个 *.jsonl 问 ScanCursorStore 拿续读偏移 → 增量读行（split by \\n 取 lineOffset 之后的行；**最后一行若原文不以 \\n 结尾视为 CLI 部分写入，不计入本次 lineOffset、不解析，下次重读**）→ JSONLCostParser.parseLine（复用 v0.1.2，schema 仍不含 message.content）→ 收集 StoredUsageEvent（dayKey 用 event ts 的**本地时区**）→ **若 collectedEvents 为空则直接返回 CollectResult，不调 mergeEvents/rebuildAggregates（绝大多数 tick 走此分支，零写盘）** → 否则 UsageEventStore.mergeEvents → rebuildAggregates(forDayKeys: collectedEvents 的本地 dayKey ∪ dirtyMonths 的所有本地 dayKey) → 更新游标到新 size/mtime/lineOffset；parseError 计数不中断；inFlight 节流（上一轮未完成的 collect 调用直接返回上次结果，不并发）"
    done: true
    evidence: "see ## Verification log"
  - id: SC5
    criterion: "新增 macos/Sources/ClaudeUsageBar/UsageAggregator.swift：纯函数（无状态、无 IO）。foldByDay/foldByMonth/foldByYear(events:[StoredUsageEvent]) -> [String:[String:TokenSums]]；usdForBucket(_ bucket:[String:TokenSums]) -> Double（对每个 model 用 ClaudePricing.lookup + ClaudePricing.cost 求和；未知模型贡献 0 且计数到 unknownModelCalls）；rolling30dSummary(dayAggregates:now:) -> CostSummary（兼容旧 LocalCostCard 的 CostSummary 形态：generatedAt/windowDays:30/totalUSD/perModel/unknownModelCount/parseErrorCount=0/scannedFileCount 由调用方填）"
    done: true
    evidence: "see ## Verification log"
  - id: SC6
    criterion: "新增 macos/Sources/ClaudeUsageBar/UsageStatsService.swift：@MainActor ObservableObject；@Published rolling30d: CostSummary? = nil（取代 UsageService.localCost30d）；@Published dailySpend: [DaySpend] = []（DaySpend{dayKey:String, date:Date, usd:Double, calls:Int}，热力图数据源，覆盖最近 ≥ 366 天）；@Published monthlySpend: [MonthSpend] = []；@Published isInitializing: Bool = false；refresh() async（不带 @MainActor 形参约束，内部 Task.detached(.utility) 跑 collector + 读 agg + UsageAggregator 折算，await MainActor.run 写回 published；inFlight 标志防叠加；首次调用 isInitializing=true 直到第一次 collect 完成）；rolling30d == nil 或 scannedFileCount == 0 时保持 nil（不打扰无 JSONL 用户）"
    done: true
    evidence: "see ## Verification log"
  - id: SC7
    criterion: "新增 macos/Sources/ClaudeUsageBar/UsageHeatmapView.swift + 其纯数据 helper（UsageHeatmapModel）：GitHub 贡献图风格，53 周 × 7 天整年网格，每格一天；颜色按当天 USD 分 9 档（含 0 档；分档算法（分位数动态 / 固定阈值）由实现决定，但必须保证轻度用户不被压成单色——加测试 testColorBucketsHaveContrastForLightUser 验证小额消费也能拉开梯度）；悬停 tooltip 显示 'YYYY-MM-DD · ≈ $X.XX · N calls'；每格 accessibilityLabel = '日期 + 金额'；数据源 usageStats.dailySpend；usageStats.isInitializing 时显示骨架/'统计中…'；dailySpend 全 0 或空时整张热力图隐藏（与 LocalCostCard 一致策略）；新文件不塞进 PopoverView"
    done: true
    evidence: "see ## Verification log"
  - id: SC8
    criterion: "UsageService.swift 改动：删除 @Published localCost30d 与 refreshLocalCostIfNeeded()；改为持有 usageStatsService 的**强引用**（由 ClaudeUsageBarApp 在构造时注入；单向依赖无环——usageStatsService 不回指 UsageService），polling tick 内 `Task.detached { await usageStatsService.refresh() }`（不阻塞 fetchUsage）；启动链路（ClaudeUsageBarApp.task）在 bootstrapFromCLIIfNeeded 之后、startPolling 之前 await usageStatsService.refresh() 一次（首次全历史回填）；**switchAccount（v0.1.3）不再触碰本机统计**——本机 JSONL 统计是跨账号的，切账号后 rolling30d/dailySpend 重算结果不变，清掉再 refresh 是无意义闪烁；删除 switchAccount 里 `localCost30d = nil` 那行、不替换；polling timer 内除 refresh() 调用外不出现 LocalCostScanner / UsageEventStore / ClaudeUsageCollector 直接引用（grep 守护）"
    done: true
    evidence: "see ## Verification log"
  - id: SC9
    criterion: "ClaudeUsageBarApp.swift：新增 @StateObject usageStats: UsageStatsService；在构造 UsageService 时把 usageStats 注入（单向强引用；与 historyService / notificationService / appUpdater 同款 wiring）；.task 内串入 await usageStats.refresh()。PopoverView.swift + LocalCostCard.swift：数据源从 service.localCost30d 改为 usageStats.rolling30d（LocalCostCard 视觉不变）；在 LocalCostCard 之后（或合适位置）插入 `if !usageStats.dailySpend.isEmpty && !usageStats.dailySpend.allSatisfy({ $0.usd == 0 }) { UsageHeatmapView(...) }`；不动 hero / secondary / pace / trend / chart / history / settings / AccountSwitcher 既有渲染"
    done: true
    evidence: "see ## Verification log"
  - id: SC10
    criterion: "退役：删除 macos/Sources/ClaudeUsageBar/LocalCostScanner.swift 及 LocalCostScannerTests.swift；不再写 ~/Library/Caches/claude-usage-bar/cost-usage/（启动时 best-effort removeItem 一次旧 cache 目录，失败仅 log type）；JSONLCostParser.swift 与 ClaudePricing.swift 保留不动（复用）；history.json（API 用量 ring buffer）不动"
    done: true
    evidence: "see ## Verification log"
  - id: SC11
    criterion: "**安全/隐私约束（v0.1.1/v0.1.2 SC7 永久警示延续 + 扩展）**：JSONLCostParser 仍 schema 层不 decode message.content（testEnvelopeDoesNotDecodeContentField 仍存在）；新增 StoredUsageEvent / 月明细 / agg / 游标 schema 均不含 content/text/contentBlocks 字段；错误日志只 log error type（type(of: error)），禁止 log JSONL 行原文 / 文件名（含 sessionUUID）/ 完整路径（fileURL.path / absJsonlPath）/ sessionId；data/ 下所有文件 0600（明细 + 游标含 sessionId / 含绝对路径）、目录 0700；测试 mock JSONL 与 fixture 不含真实 token 前缀（'sk-ant-' / 'sk-proj-' / 'AKIA' 等），fixture 全部 spec 作者手写；SC_AUTO_NO_PRINT_TOKENS（含 lastPathComponent / sessionId / fileURL / absJsonlPath / .path 关键字守护）/ SC_AUTO_NO_REAL_TOKEN_PREFIX / SC_AUTO_NO_CONTENT_READ 守护范围扩到本 spec 新增全部文件 + Tests"
    done: true
    evidence: "see ## Verification log"
  - id: SC12
    criterion: "新增测试 ≥20 case 总计：UsageEventStoreTests（月文件 Codable round-trip / mergeEvents 按 (msgId,reqId) 去重重复 5 次→1 条 / 跨 UTC 月分组：一条 jsonl 含 4 月+5 月事件落两个文件 / atomic write / 0600 权限 / rebuildAggregates 改一天 events 只那天桶变 / rebuildAllAggregates 与增量结果一致 / 损坏月文件返回 dirtyMonths）；ScanCursorStoreTests（size+mtime 未变 nextReadOffset 返回 nil / size 变大返回上次 lineOffset / size 变小返回 0 / 文件首见返回 0 / partial last line 不前移游标 testPartialLastLineNotConsumed / 游标文件损坏退化全扫）；ClaudeUsageCollectorTests（全历史首扫多临时 jsonl 跨多月 / 增量第二次只读变动文件 newEventCount 正确 / 无新事件时不写盘 / parseError 不中断 / 复用 JSONLCostParser 去重）；UsageAggregatorTests（foldByDay/Month/Year 折叠正确 / usdForBucket 用 ClaudePricing.cost 逐项验证 / 未知模型 USD=0 计入 unknownModelCalls / rolling30dSummary 30 天窗口边界）；UsageStatsServiceTests（mock dataDir：refresh 发布 rolling30d+dailySpend+monthlySpend / inFlight 节流 / isInitializing 状态翻转）；UsageHeatmapModelTests（USD→9 档映射 / 轻度用户对比度 testColorBucketsHaveContrastForLightUser / 53 周整年网格生成 / 跨年边界 / 全 0 隐藏判定）"
    done: true
    evidence: "see ## Verification log"
  - id: SC13
    criterion: "cd macos && swift build -c release 输出 'Build complete!'；cd macos && swift test 'Executed N tests, with 0 failures' 含本 spec 新增 ≥20 case（main HEAD 实测基线 = 131，删 LocalCostScannerTests 7 个 = 124，净 ≥ 124 + 20 = ≥144；P0 commit 时以实测 main HEAD 为准复核此数字）"
    done: true
    evidence: "see ## Verification log"
  - id: SC14
    criterion: "git commit 中文、含变更主题 + spec id [spec:2026-05-12-usage-store-redesign]；spec.reviews 数组含 G2（含 security/privacy review）、G3、G5（含 security/privacy review）、G6 四条 verdict；spec 2026-05-11-local-cost-scan frontmatter status implemented→superseded + 加 superseded_by: 2026-05-12-usage-store-redesign；version v0.2.3 文件新建（status placeholder→planned→in-progress；includes_specs 填本 spec）；versions/README.md 与 specs/README.md 索引同步；CHANGELOG.md append v0.2.3 中文 entry"
    done: true
    evidence: "see ## Verification log"
automated_checks:
  - "SC_AUTO_BUILD: cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release 2>&1 | tail -3 | grep -q 'Build complete'"
  - "SC_AUTO_TEST: cd /Users/methol/data/code-methol/usage-bar/macos && swift test 2>&1 | tail -5 | grep -E 'Executed [0-9]+ test.*0 failures'"
  - "SC_AUTO_NO_PRINT_TOKENS: ! grep -nrI -E '(print|NSLog|os_log|os\\.log|Logger)\\s*[\\(,].*([Aa]ccess[Tt]oken|[Rr]efresh[Tt]oken|rawJSON|claudeAiOauth|message\\.content|jsonlLine|rawLine|lastPathComponent|sessionId|sessionUUID|fileURL|absJsonlPath|\\.path\\b|account\\.credentials)' macos/Sources/ClaudeUsageBar/ 2>/dev/null"
  - "SC_AUTO_NO_REAL_TOKEN_PREFIX: ! grep -nrI -E 'sk-ant-(oat|ort|api)[0-9a-zA-Z]|sk-proj-[0-9a-zA-Z]|AKIA[0-9A-Z]{16}' macos/ docs/ CHANGELOG.md 2>/dev/null"
  - "SC_AUTO_NO_CONTENT_READ: ! grep -nrIE 'message\\.content|StoredUsageEvent[^/]*\\.content|Envelope\\.Message[^/]*\\bcontent\\b\\s*:' macos/Sources/ClaudeUsageBar/JSONLCostParser.swift macos/Sources/ClaudeUsageBar/UsageEventStore.swift macos/Sources/ClaudeUsageBar/ClaudeUsageCollector.swift macos/Sources/ClaudeUsageBar/UsageHeatmapView.swift 2>/dev/null"
  - "SC_AUTO_LOCALCOSTSCANNER_GONE: ! test -e macos/Sources/ClaudeUsageBar/LocalCostScanner.swift && ! test -e macos/Tests/ClaudeUsageBarTests/LocalCostScannerTests.swift  # 判定约定同其它 SC_AUTO_*：退出码 0 = pass（两文件都不存在）；非 0 = fail。注意这条是 test-style 而非 grep-style，G6 执行者按退出码判定"
manual_checks:
  - "已用过 Claude CLI 的用户启动 .app：首次出现短暂'统计中…'后 popover 显示消费热力图（整年网格）+ '本地 30 天估算 ≈ $X.XX'卡片"
  - "未装 Claude CLI / 无 JSONL 文件用户：热力图与 cost 卡片均完全隐藏（不显示空网格 / $0.00）"
  - "增量验证：popover 打开 → 再跑一次 Claude CLI → 等一个 polling 周期 → 重开 popover 热力图当天格子颜色加深（新事件已增量并入）"
  - "幂等验证：删 ~/.config/claude-usage-bar/data/ 重启 app → 全历史回填，热力图与上次一致；不删 data/ 只删三个 agg-*.json 重启 → 从明细重建，结果一致"
  - "**隐私 manual check**：开发期禁止把任何用户对话日志 / 真实 sessionUUID / 真实 token 贴到 commit / spec / PR / 测试 fixture；测试 fixture 全部 spec 作者手写；任取一个 `stat -f '%OLp' ~/.config/claude-usage-bar/data/claude/*.json` 与 `stat -f '%OLp' ~/.config/claude-usage-bar/data/scan-cursor.json` 均显示 600；`stat -f '%OLp' ~/.config/claude-usage-bar/data` 与 `.../data/claude` 均显示 700"
reviews:
  - gate: G2
    reviewer: claude-code (general-purpose subagent fallback, agentId a1915deb108c2734a, with security/privacy review focus)
    date: 2026-05-12
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（4 BLOCKING + 5 RECOMMENDED + 5 ADVISORY）。
      作者按 superpowers:receiving-code-review 流程处理：
      - BLOCKING B1 (lineOffset 续读对 CLI 部分写入的最后一行不安全 → 永久丢事件) accepted —
        SC4 criterion 加 "最后一行若原文不以 \\n 结尾视为部分写入，不计入本次 lineOffset、不解析，下次重读"；
        SC12 加 testPartialLastLineNotConsumed；§3.2 伪码与 §5 风险同步。
      - BLOCKING B2 (SC13 测试基线写错：实测 main HEAD = 131 非 113) accepted —
        实测确认 131；SC13 改 "实测基线 131，删 LocalCostScannerTests 7 个 = 124，净 ≥144；
        P0 commit 时复核"；§3.5 末尾硬数字标 "实现时实测"。
      - BLOCKING B3 (SC_AUTO_LOCALCOSTSCANNER_GONE 是 test-style 混入 grep-style 数组易被自动化误判) accepted —
        该 grep 真值表本身正确；加注释明确判定约定 = 退出码 0=pass。
      - BLOCKING B4 (multi-account switchAccount 清 localCost30d 改清 rolling30d 是无意义闪烁；注入关系 hand-waving) accepted —
        SC8 改 "switchAccount 不再触碰本机统计（跨账号统计与账号无关），删除 localCost30d=nil 那行不替换"；
        SC8/SC9 明确单向强引用无环；§2 决策表 + §6 加 "取代 multi-account SC8 里 localCost30d 那条"。
      - RECOMMENDED R1 (touchedDays day key 时区未在 collector 层落实) accepted —
        SC4 明确 dayKey 用 event ts 本地时区；SC1 明确 agg-day 键本地、agg-month/year 键 UTC。
      - RECOMMENDED R2 (损坏月 + 源文件已删 → 该月永久空) accepted —
        §3.3 加 "损坏月 + 无可重读源 → 该月按空 + 记一次 NSLog type，accepted（罕见）"；不 rename .corrupt（避免 sessionId 残留文件）。
      - RECOMMENDED R3 (每 tick 重写整月文件的写放大) accepted —
        SC4 伪码加 "collectedEvents 为空则直接返回，不调 mergeEvents/rebuildAggregates"；§5 风险2 同步。
      - RECOMMENDED R4 (SC7 写死分位数 vs §5 说可退固定档 → 矛盾) accepted —
        SC7 改 "分档算法由实现决定，但必须保证轻度用户不被压成单色，加 testColorBucketsHaveContrastForLightUser"；
        分位数从 SC 硬约束降为 §5 倾向。
      - RECOMMENDED R5 (grep 守护没覆盖 fileURL.path) accepted —
        SC_AUTO_NO_PRINT_TOKENS 正则加 sessionUUID/fileURL/absJsonlPath/.path 关键字；SC11 文字同步。
      - ADVISORY A1 (month 字段冗余) accepted — SC1 注明 "month 字段仅供人读，load 时以文件名为准"。
      - ADVISORY A2 (ScanCursorStore "或并入" 模糊) accepted — SC3 改 "独立 actor，不并入"；§3.4 去 "或"。
      - ADVISORY A3 (为何 collector 是 actor 还要 detached) accepted — §3.2/§3.4 加一句引用 v0.1.2 G3 #2 理由。
      - ADVISORY A4 (不开 ADR 合理) confirmed ✅。
      - ADVISORY A5 (manual check 月文件名硬编码) accepted — manual_checks 改 "任取一个 data/claude/*.json"。
      - Confirmed correct 全部 ✅（隐私 schema 约束、rebuildAggregates 覆盖式幂等、UTC 月归档权衡、actor/MainActor 工艺、
        退役 LocalCostScanner 调用方迁移点全覆盖、provider 不做 protocol YAGNI、不动 history.json/OAuth 隔离边界）。
    artifacts: ["G2 review subagent output (agentId a1915deb108c2734a)"]
  - gate: G3
    reviewer: claude-code (general-purpose subagent, agentId af11b01410ef94e29, plan-review)
    date: 2026-05-12
    verdict: approved-after-revisions
    summary: |
      对实施 plan（docs/superpowers/plans/2026-05-12-usage-store-redesign.md）的 G3 review。
      原始 verdict: approved-after-revisions（2 BLOCKING + 4 RECOMMENDED + 8 NOTES）。全数受理：
      - BLOCKING B1 (testRolling30dSummaryWindowBoundary fixture 卡 30 天整边界 → 按本地 00:00 转 Date 后被排除，断言必失败) accepted —
        fixture 改用明确在窗内/外的日期（2026-04-20 / 2026-04-01）；plan 内 note 改正原因说明（不是时区微差，是按整天聚合的自然结果）。
      - BLOCKING B2 (rebuildAggregates(forDayKeys:) 全读所有月明细，与 spec §5 风险2"只读受影响月"承诺背离；重度用户每个有新事件的 tick 全量 JSON parse) accepted —
        改为由 dayKeys 推候选 UTC 月（一本地日 ≤2 UTC 月）+ 候选年的全部已存在月，只 eventsForMonth 这些；collector dirty 分支去掉重复 rebuild（dirty→rebuildAll，正常→rebuildAggregates，二选一）。
      - RECOMMENDED R1 (multi-account 测试还有 localCost30d 写入行，不止断言行) accepted — Task 7 Step 5 明确删两行。
      - RECOMMENDED R2 (testFoldByDayKeysUseLocalTimeZone 在 UTC±13/14 时区跨日 flaky) accepted — 两个 ts 改相邻 3 小时。
      - RECOMMENDED R3 (heatmap 周起始随 locale firstWeekday 变) accepted — UsageHeatmapModel.init 加 cal.firstWeekday = 1。
      - RECOMMENDED R4 (queryEvents 靠 name.count==7 排 agg 文件不稳，"agg-day" 也 7 字符) accepted — 改 !name.hasPrefix("agg")。
      - NOTES N1~N8 confirmed / 微调：UsageEventStore.defaultConfigDir 笔误行 plan 已标注删除；JSONEncoder.iso8601 丢亚秒对按天聚合无影响；注入决策 A（UsageStatsService.shared singleton + usageStats: 参数默认 .shared）确认正确（保 multi-account 2 参构造编译、与旧 LocalCostScanner.shared 一致）；测试数核对 = 131 - 7（LocalCostScannerTests）+ ≈35 新增 = ≈159 ≥ 144；mtime / partial-line / parseError 等 case 逻辑确认正确。
      - Confirmed correct 全部 ✅（JSONLUsageEvent 字段名匹配、CostSummary/ModelCost 移动后字段一致、ClaudePricing 三函数签名用对、ExtraUsage.formatUSD 存在、SC1~SC14 映射准确、TDD 顺序正确、mock fixture 无真实 token 前缀、UsageService/ClaudeUsageBarApp 改动落在真实代码位置）。
    artifacts: ["G3 review subagent output (agentId af11b01410ef94e29)"]
  - gate: G5
    reviewer: claude-code (general-purpose subagent, agentId a253d44d6256d7825, whole-implementation code review + security/privacy focus)
    date: 2026-05-12
    verdict: approved-after-revisions
    summary: |
      整个实现（commits 507f553 → edf3a16）的 G5 code review。verdict: APPROVED-WITH-NITS。
      build 0 warnings；159 tests 0 failures；三道隐私守护 grep 全绿（NO-PRINT / NO-TOKEN / NO-CONTENT）。
      - Important（1 BLOCKING-grade）accepted — ClaudeUsageCollector.collect() 在 mergeEvents 返回非空
        dirtyMonths（损坏月被当空覆盖）时只调 rebuildAllAggregates，未清游标 → 下次 collect 各 jsonl 从
        stored lineOffset 续读，被清空的损坏月里、游标之前的事件永久丢失。修复（commit 9ad1522）：
        collect 累积本轮扫过的所有 jsonl URL，dirty 非空时 `for f in scannedFiles { await cursor.clearCursor(for: f) }`
        强制下次全量重读；加 testCorruptedMonthFileTriggersCursorResetAndRecovery（160 tests）。
      - Minor noted-only：UsageHeatmapView.model 计算属性每次 body 重建（popover 低频，O(366) 可接受）；
        UsageStatsService.shared singleton 包进 @StateObject 略不惯用但单实例 app 安全；
        usableCount = max(allLines.count-1, offset) 空文件边界正确但可加注释。均不阻塞。
      - Confirmed correct 全部 ✅（数据层端到端：UTC 月归档 + 本地 dayKey + (msgId,reqId) 去重 + 增量
        rebuildAggregates 只读受影响月 + agg 损坏从明细重建；幂等性真实；并发设计 sound；集成无回归
        localCost30d/refreshLocalCostIfNeeded 完全移除、switchAccount 不再清本机统计、LocalCostCard 视觉不变、
        hero/pace/trend/chart/settings/AccountSwitcher 未动；隐私 schema airtight；scope/YAGNI 守住 provider 仅
        enum+目录、heatmap 仅一 view+model；测试 verify real behavior 非 mock）。
    artifacts: ["G5 review subagent output (agentId a253d44d6256d7825)", "fix commit 9ad1522 (cursor reset on dirty month)"]
  - gate: G6
    reviewer: claude-code (main session, automated checks + manual UI verification deferred to user)
    date: 2026-05-12
    verdict: approved
    summary: |
      G6 merge 前验收：spec_criteria SC1~SC14 全部 done=true。
      - 自动化：`cd macos && swift build -c release` → Build complete!；`swift test` → Executed 160 tests, with 0 failures
        （基线 131 − 7 LocalCostScannerTests + 36 新增 = 160：7 UsageEventStore + 5+1 UsageAggregator 加固后
        + 7 ScanCursorStore + 7 ClaudeUsageCollector（含 G5 修复 +1）+ 4 UsageStatsService + 6 UsageHeatmapModel
        − 1 multi-account 测试断言删除 ≈ 实测 160）
      - 隐私：SC_AUTO_NO_PRINT_TOKENS（含 sessionId/fileURL/.path/lastPathComponent 守护）/ SC_AUTO_NO_REAL_TOKEN_PREFIX /
        SC_AUTO_NO_CONTENT_READ 全 0 匹配；JSONLCostParser schema 仍不含 content（testEnvelopeDoesNotDecodeContentField 保留）；
        StoredUsageEvent/月明细/agg/游标 schema 均无 content/text/contentBlocks；data/ 文件 0600 目录 0700（有单测绑定）；
        测试 fixture 全手写，msg_mock_/req_mock_/00000000-mock-... 无真实 token 前缀
      - SC_AUTO_LOCALCOSTSCANNER_GONE：LocalCostScanner.swift + 其测试均已删除
      - 治理流程：G2（含 security/privacy）/ G3（plan review）/ G5（含 security/privacy，命中 1 BLOCKING-grade 已修）
        三轮独立 reviewer + 每个实施 Task 一轮 spec+quality combined review；G2 命中 lineOffset 部分末行 / 测试基线 /
        multi-account 协同 / dayKey 时区落实等 4 BLOCKING；G3 命中 rolling30d fixture / rebuildAggregates 全读 等 2 BLOCKING；
        G5 命中 dirtyMonths 不清游标 1 BLOCKING-grade。全数受理或 reasoned reject。
      - 数据安全架构：parser Envelope.Message struct 类型层禁 content（schema-level）；含 sessionId/绝对路径的
        明细 + 游标文件 0600；错误日志只 type(of: error)
      - **manual UI 验收 deferred**：消费热力图整年网格 / "本地 30 天估算 ≈ $X.XX" 卡片 / 未装 CLI 时两者隐藏 /
        增量当天格子加深 / 删 data/ 重启全历史回填 —— 需用户在 .app popover 目视（本会话无法启动菜单栏 app 验证渲染）
      G6 通过 → spec status: accepted → implemented。
    artifacts: ["swift test 160/160 ✅", "三道隐私 grep 0 matches ✅", "LocalCostScanner gone ✅"]
---

# 用量统计与存储重设计

## 1. 背景与目标

v0.1.2 [`local-cost-scan`](./2026-05-11-local-cost-scan.md) 落地了"扫本地 Claude CLI JSONL → 滚动 30 天 USD 估算"。它是 in-memory 聚合 + `~/Library/Caches/` 中间产物，每次启动全量扫一遍，**无长期持久化、无历史分档、无跨 provider 结构**。

本 spec **supersede v0.1.2**，把本地用量从"一次性估算"升级为**持久化事实存储层**：

- 本地 `~/.config/claude-usage-bar/data/` 下按 provider 分目录，明细以 raw event 粒度持久化（按 UTC 年月分文件），另维护按天/月/年三个聚合文件供 UI 快速渲染。
- 增量采集：per-file 游标（size/mtime/lineOffset），后台与 API 用量轮询挂同一 timer 但只做增量，绝大多数 tick 近零成本。
- USD **不落盘**：明细与聚合都只存 token 数；前端用当前价格表实时折算 → 价格表升级后历史自动重算。
- popover 新增 **GitHub 贡献图风格的消费热力图**（整年 53 周网格，颜色按当天 USD 多档分级）。
- provider 抽象**只做到目录结构预留**（`data/claude/`），Codex 采集器留后续 spec。

**v0.1.1/v0.1.2 SC7 隐私事故警示永久延续 + 扩展**：parser 仍 schema 层不 decode `message.content`；新增的明细/聚合/游标 schema 均不含对话内容；含 `sessionId` 的文件 0600；错误日志只 log error type。

**不在范围**：
- 不实现 Codex 采集器（仅预留 `data/<provider>/` 结构 + `provider` 字段；UsageProvider protocol 等接口抽象等 Codex 真实需求明确时再开 spec）。
- 不引入菜单栏 `$/天` 显示模式（v0.0.10 留位）。
- 不引入 Settings 配置项（自动检测 JSONL 路径，无开关）。
- 不读 `~/.pi/agent/sessions/`、不读 `type:"user"` 行、不读 mid-stream chunk（去重已 cover）。
- 不做 per-account 分账（明细不带 accountId；multi-account 场景 UI 明示"本机统计是跨账号的"；JSONL 本身不记账号信息，事后标注是猜）。
- 不引入 ADR（仍是数据源扩展骨架；ADR 待 Codex provider 真正落地时统一开）。
- a11y / i18n 与现有 popover 一起处理，本 spec 不单独做。
- 不动 `history.json`（API 用量 ring buffer，是另一套数据）。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 存储位置 | `~/.config/claude-usage-bar/data/`（与 credentials.json / accounts.json / history.json 同级新增 data/ 子目录） | 用户指定；与既有 config 目录一致 |
| 目录布局 | `data/<provider>/<YYYY>-<MM>.json`（明细）+ `data/<provider>/agg-{day,month,year}.json`（聚合）+ `data/scan-cursor.json`（游标） | 用户指定；按 provider 分目录，Codex 直接加 `data/codex/` |
| 明细粒度 | raw event（每次 assistant 调用一行：ts / msgId / reqId / sessionId / model / 4 个 token 字段） | 价格表升级可重算历史；(msgId,reqId) 天然幂等键；per-model 任意聚合 |
| 是否落盘 USD | **否**，明细与聚合都只存 token | 价格表升级后历史自动重算；不用回写文件 |
| 聚合文件 | day / month / year 三个，buckets[key][model] = TokenSums；明细是 SSOT，agg 随时可从明细重建 | UI（尤其热力图）快速渲染；agg 损坏直接 rebuild |
| 月归档时区 | 用 event ts 的 **UTC** 年月归档（非本地时区） | 避免月初/月末跨时区漂移导致同一事件落两个文件 |
| 增量游标 | per-file `(size, mtime, lineOffset)`；未变跳过、变大续读、变小/首见全读 | 与 polling 同频要求一致；O(变动量) |
| 刷新节奏 | 挂现有 polling timer（默认 60s 或用户设的间隔），但每次只增量；`refresh()` 内 inFlight 节流；启动时先全历史回填一次 | 用户指定"与订阅 API 用量共用逻辑、不同频率"；增量保证同频可行 |
| 首次回填 | 全部历史（不设上限），按 ts UTC 拆到各年月文件 | 用户指定；一号位、幂等、未来可看任意区间 |
| 并发模型 | UsageEventStore / ScanCursorStore / ClaudeUsageCollector 都是 actor；UsageStatsService 是 @MainActor ObservableObject，refresh 内 Task.detached(.utility) 跑 IO，MainActor.run 写回 published | 与 v0.1.1/v0.1.2 工艺对齐；IO 全 off-main |
| 账号维度 | 不加（机器级聚合） | JSONL 不记账号；事后标注是猜；单账号用户（绝大多数）下是多余嵌套；per-account 分账留后续 spec |
| 热力图 | GitHub 贡献图风格，53 周整年网格，颜色按当天 USD 分 9 档（含 0 档；分档算法实现决定，倾向分位数动态，硬性要求轻度用户有对比度），悬停 tooltip + accessibilityLabel | 用户指定；agg-day 正为它而生 |
| 复用 v0.1.2 | JSONLCostParser.swift（schema 不含 content）、ClaudePricing.swift（价格表）保留不动；LocalCostScanner.swift 退役 | parser/pricing 仍正确；scanner 被 store+collector 取代 |
| LocalCostCard | 保留视觉不变，数据源从 service.localCost30d 改为 usageStats.rolling30d | 不浪费已落地 UI；本 spec 不加新小卡 |
| 安全约束 SC11 | parser schema 不含 content；错误日志只 log error type 不 log 文件名/路径/sessionId；data/ 文件 0600 目录 0700 | v0.1.1/v0.1.2 事故警示延续 + sessionId 隐私扩展 |

## 3. 设计

### 3.1 存储布局

```
~/.config/claude-usage-bar/
├─ credentials.json        (v0.1.1, 不动)
├─ accounts.json           (v0.1.3, 不动)
├─ history.json            (API 用量 ring buffer, 不动)
└─ data/                   ← 本 spec 新增 (mode 0700)
   ├─ scan-cursor.json     (mode 0600)
   └─ claude/              (mode 0700; 未来 codex/ 同级)
      ├─ 2026-04.json      明细 (mode 0600)
      ├─ 2026-05.json
      ├─ agg-day.json      聚合 (mode 0600)
      ├─ agg-month.json
      └─ agg-year.json
```

**明细文件** `data/<provider>/<YYYY>-<MM>.json`：

```jsonc
{
  "schemaVersion": 1,
  "provider": "claude",
  "month": "2026-05",
  "lastUpdated": "2026-05-12T08:30:00Z",
  "events": [
    {
      "ts": "2026-05-11T14:23:01.123Z",
      "msgId": "msg_01ABC...",
      "reqId": "req_01XYZ...",
      "sessionId": "9f3c2a1b-...-uuid",
      "model": "claude-opus-4-7-20260420",
      "inputTokens": 1234,
      "outputTokens": 567,
      "cacheReadInputTokens": 8900,
      "cacheCreationInputTokens": 120
    }
  ]
}
```

`StoredUsageEvent` 即 `events[]` 的元素类型（Codable）。**故意不含** content/text/contentBlocks。`sessionId` 取 JSONL 行所在文件名的 UUID 部分（或行内 sessionId 字段，二者一致；仅用于未来分账可能 + 调试，不展示给用户）。

**聚合文件** `data/<provider>/agg-{day,month,year}.json`：

```jsonc
{
  "schemaVersion": 1,
  "provider": "claude",
  "lastUpdated": "2026-05-12T08:30:00Z",
  "buckets": {
    "2026-05-11": {                                    // day: YYYY-MM-DD; month: YYYY-MM; year: YYYY
      "claude-opus-4-7":  { "calls": 42, "inputTokens": 1200000, "outputTokens": 80000, "cacheReadInputTokens": 5000000, "cacheCreationInputTokens": 300000 },
      "claude-haiku-4-5": { "calls": 7,  "inputTokens": 50000,   "outputTokens": 3000,  "cacheReadInputTokens": 0,       "cacheCreationInputTokens": 0 }
    }
  }
}
```

注意 model 键用**归一化前的原始 model 字符串**还是归一化后？→ 用 `ClaudePricing.normalize(model)` 后的键（去日期后缀），与 v0.1.2 一致；这样 `claude-opus-4-7-20260420` 与 `claude-opus-4-7` 不会拆成两行。

**游标文件** `data/scan-cursor.json`：

```jsonc
{
  "schemaVersion": 1,
  "files": {
    "/Users/x/.claude/projects/foo/9f3c-...-uuid.jsonl": { "size": 148230, "mtime": "2026-05-11T14:25:00Z", "lineOffset": 1430 }
  }
}
```

`lineOffset` = 已处理的行数（下次从第 `lineOffset` 行起读，0-based 即跳过前 `lineOffset` 行）。游标文件含 path（含 sessionUUID）→ mode 0600。

### 3.2 数据流

```
.app 启动 (ClaudeUsageBarApp.task):
  ├─ historyService.loadHistory()                    (不动)
  ├─ service.bootstrapFromCLIIfNeeded()              (不动)
  ├─ await usageStats.refresh()                      ← 首次：游标空 → 全历史回填 (1~3s, off-main, isInitializing=true)
  └─ service.startPolling()

UsageStatsService.refresh():                          // @MainActor 上调用，但内部 detach
  guard !inFlight; inFlight = true; defer inFlight = false
  // 为何 collector 已是 actor（actor 方法本就 off-main）还要包一层 Task.detached？
  // 沿用 v0.1.2 G3 #2 工艺：避免 MainActor 任务在长 IO 链（actor await actor await IO）上挂起，
  // 把整条链放到 cooperative pool，MainActor 只在最后 run{} 写回 published 属性那一刻参与。
  let result = await Task.detached(.utility) {
    await collector.collect()                         // 增量扫 → (有新事件才) merge 明细 → rebuild 受影响 agg 桶 → 更新游标
    let dayAgg   = await store.readDayAggregates()
    let monthAgg = await store.readMonthAggregates()
    return (compute rolling30d / dailySpend / monthlySpend via UsageAggregator + ClaudePricing)
  }.value
  await MainActor.run { self.rolling30d = ...; self.dailySpend = ...; self.monthlySpend = ...; self.isInitializing = false }

polling tick (每 60s / 用户间隔):
  ├─ service.fetchUsage()                             (不动, API 用量)
  └─ Task.detached { await usageStats.refresh() }     ← 同频但增量; fetchUsage 不被阻塞

popover 打开:
  UsageHeatmapView 读 usageStats.dailySpend → 整年网格; 全 0 / 空 → 隐藏整张
  LocalCostCard 读 usageStats.rolling30d → nil → 隐藏
```

`collector.collect()` 内部：
```
inFlight 节流 (collector 自身也有一份)
roots = scanRoots()
for jsonl in roots/*/*.jsonl:
  scannedFileCount++
  size, mtime = stat(jsonl)
  offset = cursor.nextReadOffset(for: jsonl, currentSize: size, currentMTime: mtime)
  if offset == nil: continue                          // size & mtime 都没变, 整文件不打开
  raw = read(jsonl); endsWithNewline = raw.hasSuffix("\n")
  lines = raw.split("\n", omittingEmpty: true)
  // CLI 可能正在 append → 最后一行可能是半行。endsWithNewline 为 false 时把最后一行剔出本轮、不解析、不计入 offset。
  consumable = endsWithNewline ? lines[offset...] : lines[offset..<lines.count-1]
  newLineCount = endsWithNewline ? lines.count : lines.count - 1
  for line in consumable:
    do { event = JSONLCostParser.parseLine(line); guard event != nil }
    catch { parseErrorCount++; NSLog("[claude-usage-bar] usage collect: \(type(of: error))"); continue }  // 不 log 行/文件名/路径
    collectedEvents.append(StoredUsageEvent(from: event, sessionId: <fileUUID>))   // dayKey 在 fold 阶段用本地时区
  cursor.updateCursor(for: jsonl, size: size, mtime: mtime, lineOffset: newLineCount)
if collectedEvents.isEmpty:                            // 绝大多数 tick 走这里：不写任何盘
  return CollectResult(newEventCount: 0, scannedFileCount:, parseErrorCount:, touchedDayKeys: [])
let dirty = await store.mergeEvents(collectedEvents)  // 按 ts UTC 月分组 + (msgId,reqId) 去重 union + atomic write
for m in dirty: clear cursors of files contributing to month m  // 损坏月 → 下次全读重建；若该月已无可重读源 → 该月按空 + 记一次 NSLog type（accepted, 罕见）
let touchedDays = (collectedEvents 的本地 dayKey) ∪ (dirty 月的所有本地 dayKey)
await store.rebuildAggregates(forDayKeys: touchedDays)         // 重算这些 day + 其所属 month/year 桶, 回写 3 个 agg 文件
return CollectResult(newEventCount: collectedEvents.count, scannedFileCount:, parseErrorCount:, touchedDayKeys: touchedDays)
```

幂等性：`mergeEvents` 用 `(msgId,reqId)` 去重 union（重复 collect 不会双计）；`rebuildAggregates` 对每个桶**从明细重算后覆盖**（不是 += 累加），所以重复跑结果稳定。手动"重建" = 删 `data/` 重启（全历史回填）；只删 `agg-*.json` 重启 = 从明细重建聚合。无新事件的 tick 不触碰任何文件（解决重写整月文件的写放大）。

### 3.3 错误处理 / 隐私（SC11）

| 情况 | 处理 |
|---|---|
| `message.content` / 行原文 | parser schema 层不 decode；任何路径禁止 print/log |
| 错误日志 | 只 `NSLog("[claude-usage-bar] ...: \(type(of: error))")`；不含文件名/路径/sessionId/行内容 |
| 文件权限 | `data/` 及子目录 0700；所有 `.json`（明细 + agg + 游标）0600 — 明细与游标含 sessionId/path |
| 月明细 decode 失败 | 该月按空处理；返回 dirtyMonths；collector 清掉贡献该月的文件游标 → 下次全读重建 |
| 损坏月 + 无可重读源（贡献该月的 jsonl 已被 CLI 删除/轮转）| 该月按空；记一次 `NSLog(... type(of:error))`；accepted（罕见）。不把损坏文件 rename 成 `.json.corrupt`——避免留下含 sessionId 的残留文件 |
| agg 文件损坏 / schemaVersion 不符 / 缺失 | 从明细全量 rebuildAllAggregates |
| 游标文件损坏 / schemaVersion 不符 | 丢弃 → 退化为全量扫一次（功能正确，慢一次）|
| jsonl 最后一行部分写入（CLI 正在 append）| 该行剔出本轮、不解析、不计入 lineOffset；下次重读 |
| 写盘失败（明细 / agg / 游标）| best-effort，只 log type；幂等保证下次 tick 重试不写坏 |
| 未知模型 | token 照存；USD 算 0；UI 标"含 N 条未知模型调用记录"（沿用 v0.1.2）|
| Caches 旧目录 | 启动 best-effort `removeItem(at: ~/Library/Caches/claude-usage-bar/cost-usage/)`；失败仅 log type |
| 测试 fixture | 全部 spec 作者手写；不含真实 token 前缀 / 真实 sessionUUID / 真实对话 |

### 3.4 模块 / 文件

| 文件 | 类型 | 职责 |
|---|---|---|
| 🆕 `UsageEventStore.swift` | `actor` | 月明细 load/mergeEvents（UTC 月分组 + (msgId,reqId) 去重 + atomic write 0600）；rebuildAggregates(forDayKeys:)/rebuildAllAggregates；queryEvents/readXxxAggregates；损坏月返回 dirtyMonths；agg 损坏从明细重建。**唯一持有磁盘 schema 知识的地方** |
| 🆕 `ScanCursorStore.swift` | `actor`（独立文件，不并入 UsageEventStore——职责不同）| load/save scan-cursor.json；nextReadOffset(for:currentSize:currentMTime:)→Int?（nil 跳过 / 0 全读 / N 续读）；updateCursor / clearCursor；损坏丢弃；0600 |
| 🆕 `ClaudeUsageCollector.swift` | `actor` | collect()→CollectResult；枚举 scanRoots（沿用 v0.1.2 优先级）→ 问游标增量读 → JSONLCostParser.parseLine（复用）→ mergeEvents → rebuildAggregates → 更新游标；parseError 不中断；inFlight 节流 |
| 🆕 `UsageAggregator.swift` | 纯函数 | foldByDay/Month/Year(events)→[key:[model:TokenSums]]；usdForBucket(bucket)→Double（ClaudePricing.lookup+cost 求和；未知模型 0 + unknownModelCalls）；rolling30dSummary(dayAggregates:now:)→CostSummary（兼容旧形态）|
| 🆕 `UsageStatsService.swift` | `@MainActor ObservableObject` | @Published rolling30d/dailySpend/monthlySpend/isInitializing；refresh()（Task.detached IO + MainActor.run 写回；inFlight 防叠加）|
| 🆕 `UsageHeatmapView.swift` | SwiftUI View + `UsageHeatmapModel`（纯数据 helper）| GitHub 贡献图风格，53 周整年网格；颜色按当天 USD 9 档（含 0；分档算法实现决定，需保证轻度用户有对比度）；悬停 tooltip + 每格 accessibilityLabel；isInitializing 显骨架；全 0/空 隐藏 |
| 🔧 `UsageService.swift` | — | 删 localCost30d / refreshLocalCostIfNeeded；持有 usageStats 单向强引用；polling tick 内 `Task.detached { await usageStats.refresh() }`；**switchAccount 不再触碰本机统计**（删 `localCost30d=nil` 那行不替换）；polling timer 内不直接引用 store/collector（grep 守护）|
| 🔧 `ClaudeUsageBarApp.swift` | — | @StateObject usageStats；构造 UsageService 时注入 usageStats（单向）；.task 串入 await usageStats.refresh() |
| 🔧 `PopoverView.swift` | — | LocalCostCard 数据源改 usageStats.rolling30d；插入 UsageHeatmapView（全 0/空 隐藏）|
| 🔧 `LocalCostCard.swift` | — | 数据源参数从 CostSummary（来自 service.localCost30d）改为来自 usageStats.rolling30d；视觉不变 |
| 🗑 `LocalCostScanner.swift` | — | 删除（被 UsageEventStore + ClaudeUsageCollector + data/ 取代）|
| 🗑 `LocalCostScannerTests.swift` | — | 删除 |
| ✅ 不动 | `JSONLCostParser.swift` `ClaudePricing.swift` | 复用（parser schema 仍不含 content）|
| ✅ 不动 | OAuth / refresh / polling timer 主体 / SetupView / CodeEntry / Settings / Notifications / Strategy(v0.1.1) / StoredAccount(v0.1.3) / hero / menubar / pace / trend / chart / history.json | — |

### 3.5 测试（≥20 case）

`UsageEventStoreTests`：
- testMonthFileCodableRoundTrip
- testMergeEventsDeduplicatesByMsgIdAndReqId（同 (msgId,reqId) 重复 5 次 → events 计 1）
- testMergeEventsSplitsAcrossUTCMonths（一批 events 含 4 月+5 月 ts → 落 2026-04.json + 2026-05.json）
- testAtomicWriteAndFilePermissions0600
- testRebuildAggregatesOnlyAffectedBuckets（改某天 events → 只那天 day 桶 + 其 month/year 桶变）
- testCorruptedMonthFileReturnsDirtyMonth
- testRebuildAllAggregatesFromDetailMatchesIncremental

`ScanCursorStoreTests`：
- testUnchangedSizeAndMTimeReturnsNil
- testGrownSizeReturnsLastLineOffset
- testShrunkSizeReturnsZero
- testFirstSeenFileReturnsZero
- testCorruptedCursorFileDegradesToFullScan

`ClaudeUsageCollectorTests`（临时 jsonl + dataDirOverride）：
- testFirstScanBackfillsAllHistoryAcrossMonths
- testIncrementalSecondScanOnlyReadsChangedFile（newEventCount 正确）
- testPartialLastLineNotConsumed（最后一行无 trailing \n → 不解析、游标不前移；下次 CLI 补完 \n 后该事件被收）
- testNoNewEventsSkipsDiskWrite（第二次 collect 无新行 → 不重写月文件 / agg / 游标 mtime 不变）
- testParseErrorDoesNotAbortScan
- testDeduplicationReusesJSONLCostParserSemantics

`UsageAggregatorTests`：
- testFoldByDayMonthYearCorrect
- testUsdForBucketMatchesClaudePricingCost（逐项验证）
- testUnknownModelContributesZeroUSDAndCountsCalls
- testRolling30dSummaryWindowBoundary（恰好 30 天前 / 1 秒前）

`UsageStatsServiceTests`（mock dataDir）：
- testRefreshPublishesRolling30dAndDailyAndMonthly
- testRefreshInFlightThrottlingSkipsConcurrentCall
- testIsInitializingFlipsFalseAfterFirstCollect

`UsageHeatmapModelTests`：
- testUSDToNineBucketMapping
- testColorBucketsHaveContrastForLightUser（全部小额消费天也能拉开 ≥3 档，不被压成单色）
- testFullYear53WeekGridGeneration
- testCrossYearBoundary
- testAllZeroDaysHidesHeatmap

（≈30 case，超 ≥20 要求；具体可合并/拆分，但 SC12 列的关键守护行为必须覆盖。基线 main HEAD = 131，删 LocalCostScannerTests 7 个 → 净 ≥144。）

### 3.6 Implementation plan 概要（详细由 writing-plans 产出）

- **P0** — spec + version v0.2.3 + 索引 + 旧 spec status→superseded（Commit A，仅文档）
- **P1** — UsageEventStore + ScanCursorStore + UsageAggregator + 单测（Commit B，leaf modules）
- **P2** — ClaudeUsageCollector + UsageStatsService + 单测（Commit C，依赖 P1）
- **P3** — UsageHeatmapView + UsageHeatmapModel + 单测（Commit D）
- **P4** — UsageService/ClaudeUsageBarApp/PopoverView/LocalCostCard 接入 + 删 LocalCostScanner(+Tests) + Caches 清理（Commit E，集成）
- **P5** — G6 收尾：spec status→implemented、reviews append、Verification log、CHANGELOG、version→in-progress（Commit F）
- 每个 commit 前 `swift build -c release` + `swift test` 双绿 + 三隐私守护 + SC_AUTO_LOCALCOSTSCANNER_GONE（P4 后）

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/ClaudeUsageBar/UsageEventStore.swift` | actor，月明细 + agg + 磁盘 schema |
| 🆕 | `macos/Sources/ClaudeUsageBar/ScanCursorStore.swift` | actor，per-file 游标 |
| 🆕 | `macos/Sources/ClaudeUsageBar/ClaudeUsageCollector.swift` | actor，增量采集 |
| 🆕 | `macos/Sources/ClaudeUsageBar/UsageAggregator.swift` | 纯函数折算 + USD |
| 🆕 | `macos/Sources/ClaudeUsageBar/UsageStatsService.swift` | @MainActor ObservableObject |
| 🆕 | `macos/Sources/ClaudeUsageBar/UsageHeatmapView.swift` | 热力图 View + UsageHeatmapModel |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/UsageEventStoreTests.swift` 等 6 个测试文件 | ≥20 case 总计 |
| 🔧 | `macos/Sources/ClaudeUsageBar/UsageService.swift` | 删 localCost30d/refreshLocalCostIfNeeded；持 usageStats 单向强引用；polling tick 调 usageStats.refresh；switchAccount 删 `localCost30d=nil` 行不替换 |
| 🔧 | `macos/Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift` | @StateObject usageStats + 注入 + .task |
| 🔧 | `macos/Sources/ClaudeUsageBar/PopoverView.swift` | 数据源换 + 插 UsageHeatmapView |
| 🔧 | `macos/Sources/ClaudeUsageBar/LocalCostCard.swift` | 数据源参数换；视觉不变 |
| 🗑 | `macos/Sources/ClaudeUsageBar/LocalCostScanner.swift` + `macos/Tests/ClaudeUsageBarTests/LocalCostScannerTests.swift` | 删除 |
| 🔧 | `docs/superpowers/specs/2026-05-11-local-cost-scan.md` | status implemented→superseded + superseded_by |
| 🆕 | `docs/versions/v0.2.3-usage-store-redesign.md` | 新建 version 文件 |
| 🔧 | `docs/versions/README.md` / `docs/superpowers/specs/README.md` / `CHANGELOG.md` | 索引 + entry 同步 |
| ✅ 不动 | `JSONLCostParser.swift` `ClaudePricing.swift` `history.json` 及 OAuth/refresh/SetupView/CodeEntry/Settings/Notifications/Strategy/StoredAccount/hero/menubar/pace/trend/chart | 仅复用或无关 |

## 5. 风险 / Open questions

1. **首次全历史回填 IO**：重度用户 `~/.claude/projects` 可能上百文件、累计数十 MB。首次 `collect()` 在 Task.detached(.utility) 跑，估 1~3s，`isInitializing` 期间热力图显"统计中…"。后续 tick 增量近零成本。**对策**：游标命中后整文件不打开；inFlight 防叠加。
2. **重度用户单月明细文件膨胀**：raw event 粒度，每月可能上万~十万事件 → 单月 JSON 数 MB。**关键缓解（G2 R3）**：collect 在 `collectedEvents.isEmpty` 时直接返回，不 load/merge/rebuild/重写任何文件 —— 绝大多数 polling tick（用户没在跑新调用）走此分支，零写盘。只有真有新事件的 tick 才 load+解析+重序列化受影响月文件（估 <200ms，actor 内 off-main）。**对策**：可接受；若仍实测溢出（极重度连续使用），未来 increment 改当月 NDJSON append + 月底压缩成 JSON（本 spec 不做，YAGNI）。
3. **agg 与明细不一致风险**：agg 是从明细派生的缓存。`rebuildAggregates` 总是从明细重算覆盖 → 理论上不会漂移；保险：agg schemaVersion 不符或 decode 失败时 `rebuildAllAggregates`。
4. **价格表过时**：沿用 v0.1.2 —— `ClaudePricing.snapshotDate`；未知模型 `unknownModelCalls` 提示。新模型出现 → 热力图低估那几天。**对策**：CHANGELOG 提示；后续 spec 评估 LiteLLM 同步。
5. **UTC 月归档 vs 用户本地月感知**：热力图按天分格用的是哪天？→ 用 event ts 的**本地时区**算 dayKey（用户看"5 月 11 日花了多少"是按自己时区），但**月明细文件归档**用 UTC 月（避免边界事件落两文件）。即：dayKey 本地、月文件 UTC。跨时区用户极少；不修边界 ±1 天的离群。**这是个需要在实现时明确的细节，已在此固化。**
6. **JSONL schema 漂移**：Claude CLI 改 usage 字段名 → parseError 累计 → 热力图当天颜色偏浅。**对策**：CollectResult 暴露 parseErrorCount 供调试；本 spec 不在 UI 显示该计数（与 v0.1.2 G3-R5 一致）。
7. **去重 key 跨文件/跨月**：`(msgId,reqId)` 在 mergeEvents 内按月去重；同一 (msgId,reqId) 出现在两个月文件（不该但理论可能，如手动改系统时间）→ 各月各留一条，轻微重复计。罕见，接受。
8. **macOS Sandbox**：当前 .app 未沙盒化，可读 `~/.claude/`、可写 `~/.config/`。未来若开 sandbox 需 user-selected directory permission；本 spec 不处理。Caches 兜底沿用 v0.1.2（NSTemporaryDirectory）。
9. **热力图 9 档阈值算法（G2 R4：实现时可决断，不写进 SC 硬约束）**：倾向非零天 USD 的分位数动态分档（如 0/12.5/.../87.5 百分位 → 8 个非零档 + 0 档），因为不同用户消费量级差异大、固定档会把轻度用户压成一片浅色；若实现复杂可退回固定档（$0/<$0.5/<$2/<$5/<$15/<$40/<$80/<$150/≥$150）。无论选哪个，`testColorBucketsHaveContrastForLightUser` 是硬性验收门（轻度用户必须看得出梯度）。
10. **a11y / i18n**：热力图 + 几行中文文案；VoiceOver 给每格 accessibilityLabel "日期 + 金额"（已写进 SC7）。其余 i18n 与现有 popover 一起处理。
11. **provider 字符串硬编码**："claude" 目前在多处出现（目录名、文件 provider 字段）。本 spec 用一个 `enum UsageProvider: String { case claude }` 收口，Codex 时加 case。不做 protocol（YAGNI）。
12. **multi-account 协同（G2 B4）**：`switchAccount`（v0.1.3 SC4）当前清 `localCost30d = nil`。本 spec 删除该行**且不替换** —— 本机 JSONL 统计是机器级、跨账号的，切账号后 `usageStats` 重算结果不变，清掉再 refresh 只会闪烁。`UsageService` 持有 `usageStats` 的单向强引用（`usageStats` 不回指，无环）。本 spec §6 注明此条取代 multi-account spec SC4/SC8 里关于 `localCost30d` 的处理。

## 6. 后续工作（不在本 spec 范围）

- Codex provider 采集器（`data/codex/` + `~/.pi/agent/sessions/` 或 Codex 实际日志路径）→ 单独 spec，届时评估是否需 UsageProvider protocol。
- 菜单栏 `$/天` 显示模式（v0.0.10 留位）→ 小 increment，数据源已就绪（usageStats.dailySpend）。
- per-account 分账（需 sessionId→account 映射表）→ 单独 spec。
- 价格表自动从 LiteLLM 同步 → 评估隐私 / 网络成本。
- 热力图点击某格展开当天 per-model 明细 → 本 spec 先只 tooltip，展开留 increment。
- 当月明细文件改 NDJSON append + 月底压缩（若 raw event 量级实测溢出）→ increment。
- 用量数据导出（CSV / JSON）→ 用户报告需求再评估。
- **取代说明**：本 spec 删除 multi-account spec（v0.1.3）`switchAccount` 里 `localCost30d = nil` 的处理且不替换（理由见 §5 风险12）；multi-account spec 已 implemented 不改其文字，以本 spec 为准。

## 7. 引用

- 相关调研：[`docs/research/competitive-analysis.md`](../../research/competitive-analysis.md) §1.5 / §2.4 Path 4 / §5.2 Step C / §8.3（ccusage / CodexBar JSONL 解析）
- 被本 spec supersede：[`2026-05-11-local-cost-scan.md`](./2026-05-11-local-cost-scan.md)
- 隐私事故警示来源：[`2026-05-11-claude-cli-credentials.md`](./2026-05-11-claude-cli-credentials.md) SC7
- 多账号（switchAccount 清状态需协同）：[`2026-05-11-multi-account.md`](./2026-05-11-multi-account.md)
- 母法：[`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md)
- 落地版本：[`docs/versions/v0.2.3-usage-store-redesign.md`](../../versions/v0.2.3-usage-store-redesign.md)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [x] SC1 — evidence: commit `507f553` 新增 `UsageStoreTypes.swift`（`StoredUsageEvent` 无 content/text/contentBlocks；`MonthDetailFile` schemaVersion/provider/month/lastUpdated/events；`AggregateFile` buckets:[key:[model:TokenSums]]；`ScanCursorFile.FileCursor` size/mtime/lineOffset）；`UsageEventStore` 月明细 `data/<provider>/<YYYY>-<MM>.json` 0600、目录 0700（testMonthFilePermissionsAre0600）；commit `9c0a1f0`/`6fbc1a2`/`815e626` 落地 agg 文件（agg-day/month/year，day 键本地时区 / month·year 键 UTC，testRebuildAggregatesFromDetailMatchesReadback 验 agg 文件 0600）+ `scan-cursor.json` 0600（testCursorFilePermissionsAre0600）
- [x] SC2 — evidence: commit `507f553`+`de41e9c` `UsageEventStore` actor：`mergeEvents(_:) async -> Set<String>` 按 ts UTC 月分组 + `(msgId,reqId)` 元组去重 union + atomic write 0600（testMergeEventsDeduplicatesByMsgIdAndReqId / testMergeEventsSplitsAcrossUTCMonths）；`rebuildAggregates(forDayKeys:)`（只读受影响月明细，G3 B2）/ `rebuildAllAggregates()`；`queryEvents(from:to:)` / `readDay/Month/YearAggregates()`；月明细 decode 失败 → 当空 + 返回 dirtyMonths（mergeEvents 修订版 + `9c0a1f0` testCorruptedMonthFileTreatedAsEmpty 加 dirty 断言）；agg 损坏/schemaVersion 不符 → resolvedAgg 从明细全量重建
- [x] SC3 — evidence: commit `6fbc1a2` 新增 `ScanCursorStore.swift`（独立 actor）：load/save `data/scan-cursor.json`；`nextReadOffset(for:currentSize:currentMTime:) -> Int?` 返回 nil(无变化跳过)/0(首见·变小·mtime回退,全读)/N(续读)（testFirstSeen / testUnchangedSizeAndMTimeReturnsNil / testGrownSizeReturnsLastLineOffset / testShrunkSizeReturnsZero）；`updateCursor` / `clearCursor`（dirtyMonths 重建时清，见 SC4）；损坏/schemaVersion 不符 → 丢弃退化全扫（testCorruptedCursorFileDegradesToFullScan）；游标文件 0600
- [x] SC4 — evidence: commit `815e626`+`9ad1522` 新增 `ClaudeUsageCollector.swift` actor：`collect() async -> CollectResult{newEventCount, scannedFileCount, parseErrorCount, touchedDayKeys}`；枚举 scanRoots（v0.1.2 优先级 CLAUDE_CONFIG_DIR/projects 冒号分隔 → ~/.config/claude/projects → ~/.claude/projects，从 LocalCostScanner 复制）→ 问 ScanCursorStore 续读偏移 → 增量读行（无 trailing \n 的末行不消费不计入 lineOffset，testPartialLastLineNotConsumed）→ JSONLCostParser.parseLine（复用，schema 不含 content）→ 收 StoredUsageEvent（dayKey 本地时区，UsageAggregator.localDayKey）→ collected 为空直接返回不写盘（testNoNewEventsReturnsZeroAndNoWrite）→ 否则 mergeEvents → rebuildAggregates(forDayKeys: touchedDays)；dirty 非空 → 清本轮扫过的所有 jsonl 游标 + rebuildAllAggregates（G5 修复 `9ad1522`，testCorruptedMonthFileTriggersCursorResetAndRecovery）；parseError 不中断（testParseErrorDoesNotAbortScan）；inFlight 节流
- [x] SC5 — evidence: commit `de41e9c`+`9c0a1f0` 新增 `UsageAggregator.swift` 纯函数：`foldByDay`(本地时区)/`foldByMonth`/`foldByYear`(UTC) -> [key:[model 归一化:TokenSums]]（testFoldByDayKeysUseLocalTimeZone / testFoldByMonthAndYearUseUTC，model 用 ClaudePricing.normalize）；`usdForBucket(_:) -> BucketCost{usd, unknownModelCalls, perModel}`（套 ClaudePricing.lookup/cost；未知模型贡献 0 计入 unknownModelCalls，testUsdForBucketMatchesClaudePricingCost / testUnknownModelContributesZeroUSDAndCountsCalls）；`dailySpend`/`monthlySpend`；`rolling30dSummary(dayAggregates:now:scannedFileCount:parseErrorCount:) -> CostSummary`（兼容 v0.1.2 形态，testRolling30dSummaryWindowBoundary）
- [x] SC6 — evidence: commit `5f97f16`+`edf3a16` 新增 `UsageStatsService.swift`：`@MainActor ObservableObject`；`@Published private(set) rolling30d: CostSummary?` / `dailySpend: [DaySpend]` / `monthlySpend: [MonthSpend]` / `isInitializing: Bool = true`；`refresh() async` 内 `Task.detached(.utility)` 跑 collector.collect + 读 agg + UsageAggregator 折算，回 MainActor 写回 published（testRefreshPublishesRolling30dAndDailyAndMonthly）；`inFlight` 防叠加（testConcurrentRefreshDoesNotCrash）；首次 isInitializing=true 直到首次 collect 完（testIsInitializingTrueDuringFirstRefresh）；scannedFileCount==0 → rolling30d 保持 nil（testRefreshWithNoJSONLKeepsRolling30dNil）；`static let shared`（`edf3a16`，singleton 注入）
- [x] SC7 — evidence: commit `841fc4a` 新增 `UsageHeatmapView.swift`：`UsageHeatmapModel` GitHub 贡献图风格 53 周 × 7 天网格（testGridSpansAtLeast53Weeks）；颜色 9 档（0 档 + 8 非零档，分位数动态分档；testZeroSpendDayIsBucketZero / testNineBucketsMax / testColorBucketsHaveContrastForLightUser 验轻度用户对比度）；`firstWeekday=1` 固定周日起始（G3 R3）；`UsageHeatmapView` `.help` tooltip "YYYY-MM-DD · ≈ $X.XX · N calls" + `.accessibilityLabel` 日期+金额 + isInitializing 显 ProgressView+"统计中…"；数据源 `usageStats.dailySpend`；全 0/空隐藏（testIsEmptyWhenAllZeroOrNoDays + PopoverView 插入条件）；新文件不塞进 PopoverView；跨年（testCrossYearBoundaryIncludesBothYears）
- [x] SC8 — evidence: commit `edf3a16` `UsageService.swift`：删 `@Published localCost30d` + `refreshLocalCostIfNeeded()`；加 `private let usageStats: UsageStatsService` + init 末参 `usageStats: UsageStatsService = .shared`（单向强引用无环）；polling timer 回调 `Task.detached { [usageStats] in await usageStats.refresh() }`（不阻塞 fetchUsage）；switchAccount/signOut/completeSignIn 删 `localCost30d = nil` 不替换（跨账号统计无关，加注释）；grep 验证 usageStats 仅出现在属性声明/init/timer 回调，无 UsageEventStore/ClaudeUsageCollector 引用
- [x] SC9 — evidence: commit `edf3a16` `ClaudeUsageBarApp.swift`：`@StateObject usageStats = UsageStatsService.shared` + `.environmentObject(usageStats)` + `.task` 内 bootstrapFromCLIIfNeeded 之后 startPolling 之前 `await usageStats.refresh()`；`PopoverView.swift`：`@EnvironmentObject usageStats` + 数据源 `service.localCost30d` → `usageStats.rolling30d` + LocalCostCard 之后插 `if !usageStats.dailySpend.isEmpty && !usageStats.dailySpend.allSatisfy({ $0.usd == 0 }) { Divider(); UsageHeatmapView(...) }`；`LocalCostCard.swift` 签名视觉不变；hero/secondary/pace/trend/chart/history/settings/AccountSwitcher 渲染未动（diff 仅触白名单行）
- [x] SC10 — evidence: commit `de41e9c` 把 `CostSummary`/`ModelCost` 从 LocalCostScanner 移到 UsageStoreTypes；commit `edf3a16` `git rm` `LocalCostScanner.swift` + `LocalCostScannerTests.swift`（SC_AUTO_LOCALCOSTSCANNER_GONE 通过）；`ClaudeUsageBarApp.task` 起始 best-effort `removeItem` 旧 `~/Library/Caches/claude-usage-bar/cost-usage`；JSONLCostParser.swift / ClaudePricing.swift 保留不动（复用）；history.json 不动
- [x] SC11 — evidence: JSONLCostParser schema 仍不含 content（testEnvelopeDoesNotDecodeContentField 保留，pre-existing）；StoredUsageEvent / MonthDetailFile / AggregateFile / ScanCursorFile schema 均无 content/text/contentBlocks；所有新增文件错误日志只 `NSLog("...: \(type(of: error))")`，无 JSONL 行/文件名/路径/sessionId 泄漏；data/ 文件 0600 目录 0700（多个单测绑定）；测试 fixture 全手写，`msg_mock_`/`req_mock_`/`00000000-mock-...` 无真实 token 前缀；SC_AUTO_NO_PRINT_TOKENS（含 sessionId/fileURL/.path/lastPathComponent/sessionUUID/absJsonlPath 关键字守护）/ SC_AUTO_NO_REAL_TOKEN_PREFIX / SC_AUTO_NO_CONTENT_READ 全 0 匹配
- [x] SC12 — evidence: 新增 36 case（7 UsageEventStoreTests + 6 UsageAggregatorTests + 7 ScanCursorStoreTests + 7 ClaudeUsageCollectorTests + 4 UsageStatsServiceTests + 6 UsageHeatmapModelTests − 1 UsageServiceMultiAccountTests 删除断言），含 testColorBucketsHaveContrastForLightUser / testPartialLastLineNotConsumed / testNoNewEventsReturnsZeroAndNoWrite / testCorruptedMonthFileTriggersCursorResetAndRecovery 等关键守护；inline mock 不读真实文件，不含真实 token 前缀
- [x] SC13 — evidence: `cd macos && swift build -c release` 输出 `Build complete!`（0 warnings）；`cd macos && swift test` 输出 `Executed 160 tests, with 0 failures`（实测基线 main HEAD 131，删 7 LocalCostScannerTests，净 +29 新增 = 160，> ≥144 floor）
- [x] SC14 — evidence: 全部 commit 中文 + 含 `[spec:2026-05-12-usage-store-redesign]`（507f553/de41e9c/9c0a1f0/6fbc1a2/815e626/5f97f16/841fc4a/edf3a16/9ad1522 + P0 索引 commit f451089 + 立项 44995e6 + G2 修订 8aa9f16 + plan 31c762b/0121134 + 本 commit）；spec.reviews 含 G2/G3/G5/G6 四条 verdict；`2026-05-11-local-cost-scan.md` status implemented→superseded + superseded_by（commit f451089）；version `v0.2.3-usage-store-redesign.md` 新建 placeholder→planned（44995e6）→in-progress（本 commit）+ includes_specs 填本 spec；versions/README.md（44995e6/f451089）与 specs/README.md（f451089 + 本 commit accepted→implemented）索引同步；CHANGELOG.md append v0.2.3 entry（本 commit）
