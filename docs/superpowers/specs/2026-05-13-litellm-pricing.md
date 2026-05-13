---
id: 2026-05-13-litellm-pricing
title: 模型价格表改走 LiteLLM 数据源（打包快照 + 3h 后台刷新 + 逐级回退 normalize）
status: implemented
created: 2026-05-13
updated: 2026-05-13
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.14
related_adrs: [0002]
related_research: []
spec_criteria:
  - id: SC1
    criterion: 新增 `ModelPricingCatalog`，按「运行期缓存 → 打包副本」优先级加载 LiteLLM 原始全量 JSON，遍历顶层 dict（排除 `sample_spec` 等非模型键）解析出 per-Mtok 单价（per-token × 1_000_000）；任一文件损坏/缺失/超出 size 上下限时回退下一级，两级都失败则空表（所有查表返回 nil，不崩）
    done: true
    evidence: "ModelPricingCatalog.swift（reload: cacheURL→bundledURL→空表；parse: 跳 sample_spec、optional cast、per-token×1e6）；ModelPricingCatalogTests.testParsesPerTokenIntoPerMTokAndSkipsSampleSpec / testCorruptCacheFallsBackToBundled / testTooSmallFileRejectedByMinBytes / testBothSourcesMissingGivesEmptyTable / testBundledSnapshotIsLoadable 全绿"
  - id: SC2
    criterion: `ClaudeModelPriceTable.lookup` / `OpenAIModelPriceTable.lookup` 改为委托 `ModelPricingCatalog`；`OpenAIPricing.table` / `ClaudePricing.table` 两个静态字典及 `snapshotDate` / `// UNVERIFIED` / `ClaudePricing.cost(for:)` 删除（`normalize`/`displayName` 保留）；`ClaudePricingTests` 同步迁移到不依赖被删 API
    done: true
    evidence: "OpenAIPricing.swift / ClaudePricing.swift 删 table/snapshotDate/cost(for:)/ClaudeModelPricing；适配器 lookup 委托 ModelPricingCatalog.shared.unitPricing；ClaudePricingTests/OpenAIPricingTests/UsageAggregatorTests 已迁移；SC_AUTO_NO_STATIC_TABLE（grep -nE 'static let table' 无输出）✓"
  - id: SC3
    criterion: 查表采用有序逐级回退候选链（原始名 → 去 reasoning-effort 后缀 → 去 codex 家族后缀退基座 → 去 minor 版本号 → 加/去 `openai/`·`anthropic/` 前缀 → LiteLLM key 前缀匹配，且前缀匹配跳过含其它 provider 路由前缀如 `azure/`·`vertex_ai/`·`bedrock/` 的 key），去重后依次喂 catalog，任一命中即返回；全 miss 才计 unknown
    done: true
    evidence: "ModelPricingCatalog.pricingCandidates（① 原名 ② 去 -(minimal|low|medium|high|xhigh)$ ③ 去 -codex(-max|-spark|-mini) ④ dropMinor gpt-5.3→gpt-5 ⑤ openai/anthropic 前缀）+ unitPricing 末尾前缀匹配（跳 azure_ai/vertex_ai/bedrock/openrouter/databricks/watsonx）；ModelPriceTableFallbackTests.testCandidateChainSteps 全绿"
  - id: SC4
    criterion: 用一份冻结的真实 LiteLLM 快照 fixture，断言别名样本 `gpt-5.3-codex` / `gpt-5.2` / `gpt-5.4` / `gpt-5.1-codex-max` / `gpt-5.4-mini` / `gpt-5.2-codex` / `gpt-5.4-xhigh` / `gpt-5.3-codex-spark` 及 `claude-opus-4-7` / `claude-sonnet-4-6` 都拿到非空单价（断言「非空」而非具体数值）；造一个不存在的 `foo-bar-9` 仍为 unknown；候选链每一步至少一个用例覆盖
    done: true
    evidence: "Tests/UsageBarTests/Fixtures/litellm_snapshot_frozen.json（冻结快照）+ ModelPriceTableFallbackTests.testRealAliasesResolveToNonNilPricing：gpt-5.3-codex/gpt-5.2/gpt-5.4/gpt-5.1-codex-max/gpt-5.4-mini/gpt-5.2-codex/gpt-5.4-xhigh/gpt-5.3-codex-spark/claude-opus-4-7/claude-sonnet-4-6 全非空、foo-bar-9 nil ✓"
  - id: SC5
    criterion: `build.sh` 在 `swift build` 前 `curl` 拉取上游 JSON（校验合法 JSON + size 在 [50KB, 10MB]）覆盖 `macos/Sources/UsageBar/Resources/litellm_model_prices.json`，bundle 装配完成后若处于 git 仓库则 `git checkout --` 还原该文件使工作区保持干净；下载/校验失败仅打印 warning 并沿用仓库内旧副本，不中断构建
    done: true
    evidence: "build.sh fetch_litellm_prices()（curl→size[50KB,10MB]→python3 json.load 校验→cp 覆盖 Sources/UsageBar/Resources/litellm_model_prices.json；任一失败 echo warning + return 0 不中断）+ restore_litellm_snapshot()（build_app_bundle 末尾 git -C 还原）；实测 `make app` 后 `git diff --quiet -- macos/Sources/UsageBar/Resources/litellm_model_prices.json` ✓（断网时走 warning 分支、构建仍成功、工作区干净）"
  - id: SC6
    criterion: 运行期由 `ProviderCoordinator` 已有的统一 tick 同步调用 `ModelPricingCatalog.shared.refreshIfStale(now:)`（该方法立即返回、内部按「持久化的上次抓取时刻 ≥ 3h」自节流、超时则 detach 一个后台下载任务 → 校验合法 JSON 且 size 在 [50KB,10MB] → `Data.write(options:.atomic)` 替换 `~/.config/usage-bar/litellm_model_prices.json` + 写同目录 meta 文件记 `fetched_at` + 重建内存表）；app 启动装配时也调一次；不新增任何 `Timer`/`DispatchSourceTimer`/`Timer.publish`
    done: true
    evidence: "ProviderCoordinator.onTickSideEffects 默认 { ModelPricingCatalog.shared.refreshIfStale(now: Date()) }，onBackgroundTick() 末尾调；refreshIfStale 同步立即返回、按 meta 的 fetched_at 做 3h 节流、detach URLSession downloadTask→size 校验→Data.write(.atomic) 写缓存+写 meta+重建表；ProviderCoordinatorTests.testBackgroundTickInvokesPricingRefreshHook + ModelPricingCatalogTests.testRefreshSkippedWhenFresh/testRefreshTriggersWhenStaleAndWritesCacheAndMeta/testRefreshWithBadDownloadKeepsOldCacheAndNoMeta 全绿；SC_AUTO_NO_NEW_TIMER（grep -nE 'Timer.scheduledTimer|DispatchSourceTimer|Timer.publish' ModelPricingCatalog.swift 无输出）✓"
  - id: SC7
    criterion: `verify-release.sh` 增检 bundle 内 `litellm_model_prices.json` 存在、是合法 JSON、size > 100KB（该阈值绑定「打全量快照」这一决策）
    done: true
    evidence: "verify-release.sh verify_app_bundle() 增检 $resource_bundle/litellm_model_prices.json 存在 + python3 json.load + size>100000 + THIRD_PARTY_LICENSES.txt 存在；`make release-artifacts` + `verify-release.sh` zip/dmg 均「Release archive looks good」✓"
  - id: SC8
    criterion: `LocalCostCard` 文案区分「含 N 条无定价数据的调用」（catalog 有表但 miss）与「定价数据未加载」（catalog 空表），均不再暗示「价格表过时」；`swift build -c release` 与 `swift test` 全绿
    done: true
    evidence: "LocalCostCard.swift：!ModelPricingCatalog.shared.isLoaded →「定价数据未加载，费用估算暂不可用」；else unknownModelCount>0 →「含 N 条无定价数据的调用」；SC_AUTO_NO_STALE_COPY（grep -F '价格表过时' 无输出）✓；swift build -c release ✓、swift test = 262 passed ✓"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_ARTIFACTS: make release-artifacts"
  - "SC_AUTO_VERIFY: bash macos/scripts/verify-release.sh macos/UsageBar.zip"
  - "SC_AUTO_NO_STATIC_TABLE: ! grep -nE 'static let table' macos/Sources/UsageBar/OpenAIPricing.swift macos/Sources/UsageBar/ClaudePricing.swift"
  - "SC_AUTO_NO_NEW_TIMER: ! grep -nE 'Timer\\.scheduledTimer|DispatchSourceTimer|Timer\\.publish' macos/Sources/UsageBar/ModelPricingCatalog.swift"
  - "SC_AUTO_NO_STALE_COPY: ! grep -F '价格表过时' macos/Sources/UsageBar/LocalCostCard.swift"
  - "SC_AUTO_GIT_CLEAN_AFTER_BUILD: make app >/dev/null 2>&1 && git diff --quiet -- macos/Sources/UsageBar/Resources/litellm_model_prices.json"
manual_checks:
  - "断网跑 `make app`，确认仅 warning、构建仍成功、bundle 里带的是仓库旧副本，且 `git status` 干净"
  - "联网跑 `make app`，确认 bundle 内 litellm_model_prices.json 是最新（与上游 curl 结果一致），且 `git status` 干净"
  - "实机：删除 ~/.config/usage-bar/litellm_model_prices.json + meta 文件后启动 app，几秒内出现新缓存文件 + meta（fetched_at 是当前时刻）；Codex tab 的「无定价数据的调用」条目接近 0"
reviews:
  - gate: G2
    reviewer: general-purpose subagent (independent, agentId a3b59d55b9198507d)
    verdict: approved-after-revisions
    date: 2026-05-13
    notes: |
      design + security review。5 条 must-fix 已在本 spec 应用：
      (M1) build.sh 改为 build 后 `git checkout --` 还原 in-repo 副本、工作区保持干净（用户已确认存全量快照、bundle +~2MB 是有意权衡，§2 记明）；
      (M2) 修两条坏 grep（`static let table` / `grep -E`、去 `-r`）+ 新增 `SC_AUTO_NO_STALE_COPY` / `SC_AUTO_GIT_CLEAN_AFTER_BUILD`；
      (M3) 不用文件 mtime 节流，改持久化 `fetched_at` meta 文件，`refreshIfStale` 可注入时钟；
      (M4) 排除 `sample_spec` 等非模型键、前缀匹配跳过 azure/vertex/bedrock、JSON 全 optional-cast 单 key 失败即 skip、下载与读取都加 size 上下限防 OOM、原子写用 `Data.write(.atomic)`；
      (轻 must-fix) URL 为编译期常量无运行时覆盖、无完整性校验是有意权衡（影响面仅 UI 估算 + 免责声明）、LiteLLM MIT 归属义务通过打包 THIRD_PARTY_LICENSES.txt + README 致谢履行。
      should-fix（S1~S5）已并入 §3.4/§3.2/§5。verdict 升为 accepted 由本次修订满足。
  - gate: G3
    reviewer: general-purpose subagent (independent, agentId a569ca0b7493d1c8d)
    verdict: ready-with-revisions
    date: 2026-05-13
    notes: |
      plan-review（针对 docs/superpowers/plans/2026-05-13-litellm-pricing.md）。SC1~SC8 + G2 五条 must-fix 全覆盖；
      2 条 must-fix 已改进 plan：(1) Package.swift test target 无 resources 块、新增须 `.process("Fixtures")` 而非
      `.process("Tests/UsageBarTests/Fixtures")`；(2) Task6 测试 helper 调用改 `makeCoordinator(freshDefaults())`。
      4 条 should-fix 已改进：catalog 构造器全 plan 补 `minBytesOverride` 自洽（删「⚠️ 修正」补丁段）；Task3 骨架
      去占位 `minBytes_orOverride` 用真表达式 + 补 downloader「必须最终调一次 completion」契约注；Task8 `restore_litellm_snapshot`
      明确放 `build_app_bundle()` 函数体末尾；Task6 补「首次 ModelPricingCatalog.shared 在 MainActor 同步 reload ~2MB」注。
      verdict 升为 ready 由本次修订满足。
  - gate: G5
    reviewer: general-purpose subagent (independent, agentId a49b7d33afbb5be60)
    verdict: approved-with-nits
    date: 2026-05-13
    notes: |
      code-review + light security review（分支 litellm-pricing vs main）。8 条 SC 的可观察行为均已实现、
      并发模型（NSLock 守 table/loaded/refreshInFlight + 同步 refreshIfStale + detach 下载）正确无死锁、
      候选链推演全对、build.sh/verify-release 的 set -e/git checkout 边界正确、安全面（编译期常量 URL、
      无凭证/PII、OOM 防护、原子写、MIT 归属）齐全且未触 AGENTS.md §6 任何 hard gate。
      should-fix S1（refresh 测试 asyncAfter(0.4) flaky）已修：改 waitUntil 轮询 isRefreshInFlightForTesting；
      nit N4（Downloader completion 契约）已补 typedoc。N1/N2/N3 记录不改（影响为零 / owner 已拍板的体积权衡）。
---

# 模型价格表改走 LiteLLM 数据源

## 1. 背景与目标

Codex tab 的「估算费用卡」频繁出现「含 N 条未知模型调用（价格表过时？）」——根因不是解析 bug，而是 `OpenAIPricing.table`（手写、`snapshotDate = 2026-05-12`）严重滞后：本地 `~/.codex/sessions/` 里实跑的模型是 `gpt-5.3-codex` / `gpt-5.2` / `gpt-5.4` / `gpt-5.1-codex-max` / `gpt-5.4-mini` / `gpt-5.2-codex` / `gpt-5.3-codex-spark` / `gpt-5.4-xhigh` 等，几乎全不在表里。`ClaudePricing.table` 同样是手写静态表、同样会滞后。

[ccusage](https://github.com/ryoppippi/ccusage) 的做法：不自维护价格表，运行时拉取 [LiteLLM](https://github.com/BerriAI/litellm) 的社区价格库 `model_prices_and_context_window.json`，进程内缓存；`--offline` 用包内预打包快照。本 spec 把同样的思路引入本 app：**静态价格表 → LiteLLM 数据源（打包快照 + 后台刷新）**，并补一层「别名 → 有价模型」的逐级回退查表（codex CLI 的内部别名上游未必收录）。

不引入新第三方**代码**依赖（不进 `Package.swift`、不链接任何东西、不执行任何上游代码）——只多一个数据文件 + 一个出站 GET。与 [ADR 0002](../adr/0002-claude-only-not-multi-provider.md)（Claude-only）不冲突——LiteLLM 是数据源不是 provider。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 覆盖面 | Claude + OpenAI 两边都改成走 LiteLLM | 一致性；两张手写表都会滞后 |
| 别名→有价模型 | 逐级回退 normalize（无手维护 alias 映射表） | 新别名出来不用改代码；映射表会重蹈手维护的覆辙。**注**：回退链里的 codex 后缀正则（`-codex-max`/`-codex-spark`/`-xhigh`…）本质仍是需随 codex CLI 演进维护的部分，只是比逐型号映射表更耐变——不包装成「零维护」 |
| 打包/落盘粒度 | 存上游**原始全量** JSON（不瘦身） | 用户拍板：代码最简、与上游完全一致；bundle +~2MB 与 CLAUDE.md「保持精简」有张力，是**经 owner 确认的有意权衡**；committed 副本每次发版前由 build.sh 刷新但 build 后还原工作区，git 历史里只在「真去更新 fallback」时才有 diff |
| build.sh 与 in-repo 副本 | build 前 curl 覆盖 → 装配后 `git checkout --` 还原 → 工作区保持干净 | 既满足「打进去的是最新的」，又不让 `make app` / CI 弄脏工作区；下载失败则沿用旧副本、不中断 |
| 后台刷新 timer | 复用 `ProviderCoordinator` 现有统一 tick，不开新 Timer | app 保持简洁（沿用 v0.2.11 的「单 timer」方向）|
| 刷新间隔 / 节流依据 | 写死 3 小时；以持久化的 `fetched_at`（meta 文件）为准，不用文件 mtime | 用户指定 3h；mtime 会被备份/rsync/touch 污染、且 bundle 副本 mtime 是 build 时刻不可靠 |
| 上游完整性校验 | 无 checksum / 签名（区别于 Sparkle）| 篡改影响面仅限 UI 上「估算费用」数字（不碰凭证/支付/API 调用），且 UI 上常驻「best-effort 估算、非真实账单」免责声明——搞签名链 overkill；这是**有意权衡** |
| LiteLLM 数据归属 | 打包 `THIRD_PARTY_LICENSES.txt`（含 LiteLLM MIT 声明）+ README 致谢段 | MIT 再分发义务 |

## 3. 设计

### 3.1 数据源与文件

- **上游**：`https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`（原始全量，~2MB；key = 模型名，value 含 `input_cost_per_token` / `output_cost_per_token` / `cache_read_input_token_cost` / `cache_creation_input_token_cost` 等；单价是 **per-token**；顶层含一个非模型的示例键 `sample_spec`，须排除）。URL 是 `ModelPricingCatalog` 里的**编译期常量**，无任何运行时（UserDefaults / 环境变量 / 用户输入）覆盖路径。
- **打包副本**：`macos/Sources/UsageBar/Resources/litellm_model_prices.json` —— 提交进仓库（offline 构建兜底）。`Package.swift` 的 `resources: [.process("Resources")]` 已覆盖，自动进 SwiftPM resource bundle（`UsageBar_UsageBar.bundle`）。
- **第三方许可**：`macos/Sources/UsageBar/Resources/THIRD_PARTY_LICENSES.txt` —— 提交进仓库，含 LiteLLM 的 MIT 许可全文 + 一句「model price data sourced from BerriAI/litellm」；一并进资源 bundle。README 加一行致谢。
- **运行期缓存**：`~/.config/usage-bar/litellm_model_prices.json` + `~/.config/usage-bar/litellm_model_prices.meta.json`（`{"fetched_at":"<ISO8601>"}`），与 `credentials.json` / `history.json` 同目录、同默认权限（不需 0600——价格数据非 secret；也不强制 0666）。

### 3.2 `ModelPricingCatalog`（新组件）

`Sendable` 单例。**并发模型**：内部用一把锁保护内存表（不是 actor）——这样 `ProviderCoordinator`（MainActor）的 tick 能**同步**调 `refreshIfStale` 而不引入 `await`；`refreshIfStale` 自己决定要不要 `Task.detached` 一个后台下载，下载回调里再加锁更新表。

- **加载顺序（启动 / 重建表时）**：① 运行期缓存文件——先 `stat`，size 在 [50KB, 10MB] 且 `JSONSerialization` 解析成非空 `[String: Any]` 才用 → ② bundle 内打包副本（同样校验）→ ③ 都失败：空表（`unitPricing` 全返回 nil；UI 区分这个「空表」与「有表但 miss」两种状态，见 §3.5）。
- **解析**：遍历顶层 dict；跳过 `sample_spec` 等已知非模型键；每个 `model -> attrs`，用 **optional cast** 取 `attrs as? [String: Any]`，再取四个价格字段（`as? Double`/`as? NSNumber`，缺失或非数按 0），任一步 `as?` 失败 → skip 该 key（不抛、不 crash）；per-token × 1_000_000 得 per-Mtok，存内存 `[lowercasedKey: ModelUnitPricing]`（key 用上游原名小写，**不预先 normalize**——回退链在查询时做）。
- **查询接口**：`unitPricing(rawModel:) -> ModelUnitPricing?`（provider 无关——LiteLLM 一张表通吃；provider 前缀差异在回退链处理），`isLoaded: Bool`（区分空表 vs 有表）。
- **后台刷新**：`refreshIfStale(now: Date)` —— **同步、立即返回**；读 meta 文件的 `fetched_at`（无 meta 或无缓存文件 → 视为「从未抓取」）；若 `now - fetched_at < 3h` 直接返回；否则 `Task.detached` 发起 `URLSession` **download task**（写盘而非全读内存；下载完成后先 `stat` size 在 [50KB,10MB]、再 `JSONSerialization` 校验为非空 dict）→ 通过则 `Data.write(to: cacheURL, options: [.atomic])`（`.atomic` 自动在同目录建临时文件再 rename，跨卷问题不存在）+ 写 meta（`fetched_at = now`，也 `.atomic`）+ 加锁重建内存表；任一步失败 → 保持原状（不更新 meta，下次 tick 再试）。为可测：`refreshIfStale` 实际签名带可注入的「当前时刻」「下载器」「读 meta 的来源」依赖（生产用默认实现）。

### 3.3 接入 `ProviderCoordinator`

`ProviderCoordinator`（v0.2.11 起持有统一后台 tick）在每次 tick 回调里多调一句 `ModelPricingCatalog.shared.refreshIfStale(now: Date())`（内部自带 3h 节流，tick 频率无所谓）。app 启动装配时也调一次。**不新增 Timer**。

> 取舍：①若用户把 polling interval 设得极大、或禁用了**所有** provider 导致 tick 不再触发，3h 刷新就不触发——Claude 恒在 enabled 集，实践中 tick 总会触发，故影响可忽略；打包副本每次发版也是新的。②全新安装的用户首次启动时无缓存/meta → 视为「从未抓取」→ 第一次 tick 就触发一次 ~2MB 下载——这是**有意的**（让新用户尽快拿到最新价格），不是 bug。

### 3.4 逐级回退查表（候选链）

`ClaudeModelPriceTable` / `OpenAIModelPriceTable` 保留各自的 `normalize`（仅用于把同一模型的不同写法折叠成统计 bucket key，**行为不变**——`OpenAIPricing.normalize` 仍只去日期后缀，所以 `gpt-5.4-xhigh` 经它后仍带 `-xhigh` 后缀，回退链拿得到）和 `displayName`（UI 短名，手维护，不变）。改的只是 `lookup`：收到的入参可能是 `normalize` 之后的 bucket key（`UsageAggregator.usdForBucket` 调用路径）也可能是裸名（其它调用方）——`lookup` 内部一律先小写，再构造一个**有序候选名列表**，去重后依次喂 `ModelPricingCatalog.unitPricing`，第一个命中即返回；全 miss → nil（计 unknown）。

候选链（小写后，按顺序）：
1. 原始名
2. 去 reasoning-effort 后缀：`-(minimal|low|medium|high|xhigh)$`（如 `gpt-5.4-xhigh` → `gpt-5.4`）
3. 去 codex 家族后缀退基座：依次试去掉 `-codex-max` / `-codex-spark` / `-codex-mini` / `-codex`（如 `gpt-5.3-codex` → `gpt-5.3`、`gpt-5.1-codex-max` → `gpt-5.1`）
4. 去 minor 版本号：`gpt-5.3` → `gpt-5`；带尺寸的 `gpt-5.4-mini` → `gpt-5-mini`、`gpt-5.4-nano` → `gpt-5-nano`（假设「同 major 下尺寸变体同价」——best-effort 估算，非账单；OpenAIPricing 顶部那段免责声明继续适用）
5. 加/去 provider 前缀：`openai/<候选>`、`anthropic/<候选>`（LiteLLM 部分 key 带 provider 前缀）
6. LiteLLM key 前缀匹配：在 catalog 的 key 集合里取「以候选名为前缀」的 key——**先过滤掉含其它 provider 路由前缀的 key**（key 里出现 `azure/`、`vertex_ai/`、`bedrock/`、`openrouter/` 等的不要，命中 bedrock 的 claude 价格是错的），剩下的按字典序取第一个（保证确定性；精度损失边界：候选 `claude-opus-4` 可能匹配到 `claude-opus-4-20250514` 而非更接近的子版本——与现状「手写表沿用 family 价」等价、不更差）

> 步骤 2–4 对 Claude 名无副作用（不含 `-codex` / `gpt-` 前缀、minor 号规则不命中）；步骤 5–6 两边都用。步骤 2–4 是 codex CLI 别名专用的、需随其演进维护（见 §2 注）。

### 3.5 受影响的计费路径（不动）

`ModelPriceTable` 协议、`ProviderCostContext`、`UsageAggregator.usdForBucket`（含 `isUnknownPricing` / `unknownModelCalls` 统计）、各 view 的 `ProviderCostContext` 注入——**全部不变**，只是 `lookup` 背后换了数据源。`LocalCostCard` 改提示文案：catalog 已加载但有 miss → 「含 N 条无定价数据的调用」；catalog 空表（加载失败）→ 「定价数据未加载，费用估算暂不可用」——都不再暗示「价格表过时」。

### 3.6 构建脚本

`build.sh` 在 `build_app_bundle()` 调 `swift build` **之前**插一步 `fetch_litellm_prices()`：
1. `curl -fsSL --max-time 30 <上游 URL> -o "$BUILD_DIR/litellm_model_prices.json.dl"`
2. 校验：文件非空、`size` 在 [50KB, 10MB]、`plutil -lint`（或 `python3 -c 'import json;json.load(open(...))'`）通过
3. 通过 → `cp` 覆盖 `Sources/UsageBar/Resources/litellm_model_prices.json`；任一步失败 → `echo "warning: litellm price fetch skipped (...)"` 并保留现有文件、`return 0`（不让 `set -e` 退出）

`make app` / `make zip` / `make dmg` 等流程在 bundle 装配 **完成后**，若 `git rev-parse --git-dir` 成功（即在 git 仓库里）：`git checkout -- macos/Sources/UsageBar/Resources/litellm_model_prices.json`（还原工作区——这样 dev 本地和 CI 都不会因构建而脏）；不在 git 仓库（tarball 构建）则跳过、不报错。`verify-release.sh` 走的是已装配好的 `.app`/zip，不受影响。

> 注：committed 的 `litellm_model_prices.json` 因此只在「有人主动想刷新 fallback 快照」时才产生 git diff（可日后加个 `make refresh-pricing-snapshot` 或 CI 定时任务，**不在本 spec 范围**）；平时它就是个静态 fallback，体积 ~2MB 接受。

### 3.7 测试方案（TDD）

- `ModelPricingCatalogTests`：
  - 解析：小份 fixture JSON（含 `gpt-5`, `gpt-5-codex`, `gpt-5-mini`, `claude-opus-4-20250514`, `claude-sonnet-4-5`, `openai/gpt-4o`, 以及一个 `sample_spec` 和一个 `azure/...` 干扰键）→ 断言 per-token→per-Mtok 换算正确、`sample_spec` 不进表、解析不抛；
  - 缓存优先：写一份与 bundle 差异化的缓存 fixture + 对应 meta，确认读到缓存值；
  - 损坏/越界回退：缓存文件是 `"{"` / 是 0 字节 / 是 11MB → 回退 bundle；bundle 也坏 → 空表、`unitPricing` 全 nil、`isLoaded == false`、不抛；
  - `refreshIfStale`：注入「now」「假下载器」「假 meta 源」——`fetched_at` 为 nil / 4h 前 → 触发下载并写新缓存+meta；2h 前 → 不触发；下载器返回坏数据（太小/非 JSON）→ 缓存与 meta 保持不变；
  - 同步契约：`refreshIfStale` 立即返回（不阻塞）。
- `ModelPriceTableFallbackTests`：喂一份**冻结的**真实 LiteLLM 快照 fixture（仓库内单独放一份，不复用会随 build.sh 变的 bundle 那份），断言 SC4 列出的别名样本都拿到**非空**单价（不绑定具体数值）、`foo-bar-9` 为 nil；候选链步骤 1–6 各至少一个用例。
- 现有 `swift test` 全套保持绿；`ClaudePricingTests` 改成不依赖被删的 `cost(for:)`/`table`（改用 `ModelUnitPricing.cost` + catalog fixture，或直接并入 `ModelPriceTableFallbackTests`）。

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/UsageBar/ModelPricingCatalog.swift` | LiteLLM JSON 加载/解析/缓存/3h 刷新；URL 编译期常量 |
| 🆕 | `macos/Sources/UsageBar/Resources/litellm_model_prices.json` | 打包快照（提交进仓库；build.sh 每次刷新、build 后还原工作区）|
| 🆕 | `macos/Sources/UsageBar/Resources/THIRD_PARTY_LICENSES.txt` | LiteLLM MIT 全文 + 出处说明 |
| 🆕 | `macos/Tests/UsageBarTests/ModelPricingCatalogTests.swift` | |
| 🆕 | `macos/Tests/UsageBarTests/ModelPriceTableFallbackTests.swift` | 含冻结快照 fixture（或放 `Tests/.../Fixtures/`）|
| 🔧 | `macos/Sources/UsageBar/OpenAIPricing.swift` | 删 `table`/`snapshotDate`/`// UNVERIFIED`；`lookup` 走 catalog + 候选链；`normalize`/`displayName` 留 |
| 🔧 | `macos/Sources/UsageBar/ClaudePricing.swift` | 删 `table`/`snapshotDate`/`cost(for:)`；`lookup` 同上；`normalize`/`displayName` 留 |
| 🔧 | `macos/Tests/UsageBarTests/ClaudePricingTests.swift` | 迁移到不依赖被删 API |
| 🔧 | `macos/Sources/UsageBar/ProviderCoordinator.swift` | tick 回调里加 `ModelPricingCatalog.shared.refreshIfStale(now:)`；装配处启动调一次 |
| 🔧 | `macos/Sources/UsageBar/LocalCostCard.swift` | 提示文案区分「无定价数据」/「定价数据未加载」|
| 🔧 | `macos/scripts/build.sh` | 加 `fetch_litellm_prices()`（build 前）+ 装配后 `git checkout --` 还原 |
| 🔧 | `macos/scripts/verify-release.sh` | 增检 bundle 内 `litellm_model_prices.json` 存在 + 合法 JSON + size > 100KB |
| 🔧 | `CLAUDE.md` | 「Architecture」/「Style & dependencies」补：价格数据来自打包的 LiteLLM 全量快照（build.sh 自动刷新、build 后还原工作区），运行期 3h 后台再刷新到 `~/.config/usage-bar/`；新增 bundled 资源须同步 `verify-release.sh` |
| 🔧 | `README.md` | 致谢段加「price data: BerriAI/litellm (MIT)」|
| ✅ 不动 | `macos/Sources/UsageBar/ModelPricing.swift`（`ModelPriceTable` / `ModelUnitPricing` / `ProviderCostContext`）| |
| ✅ 不动 | `macos/Sources/UsageBar/UsageAggregator.swift` 计费路径 | |
| ✅ 不动 | `macos/Sources/UsageBar/CodexRolloutCostParser.swift` | |

## 5. 风险 / Open questions（含 G2 安全复审结论）

1. **新增出站 GET**（`raw.githubusercontent.com`，HTTPS，满足默认 ATS，无需改 Info.plist）：**不泄露任何用户数据**（无 query/body/凭证 header）；URL 编译期常量、无运行时覆盖；固定指向 `main` 分支（与 ccusage 一致）——供应链面比 pin tag 大，但见第 2 点缓解。
2. **上游被篡改但格式仍合法**（价格被改成天文/0）：影响面**仅限 UI 上「估算费用」数字与热力图深浅**——不碰任何凭证、不触发支付、不影响 OAuth/CLI 凭证、不影响实际 API 调用（本 app 不发 API 调用，只读本地 JSONL）；UI 常驻「best-effort 估算、非真实账单」免责声明。故不做 checksum/签名（有意权衡）。**风险等级低、可接受**——不构成 AGENTS.md §6 hard gate。
3. **OOM / 解析炸弹**：下载用 download task（写盘不全读内存）+ size 上下限 [50KB,10MB]；读缓存/bundle 文件前先 `stat`；所有 JSON 访问 optional cast、单 key 失败即 skip——不会 crash。
4. **第三方许可（MIT）**：通过打包 `THIRD_PARTY_LICENSES.txt` + README 致谢履行再分发义务。不改本仓库 LICENSE、不改商业模式——不构成 hard gate；GitHub raw 程序化拉取（3h 一次）不违反其 ToS。
5. **上游 JSON 长期不可用 / 路径或结构变动**：三层兜底（运行期缓存 → 打包副本 → 空表不崩，UI 退化为「定价数据未加载」）；`build.sh` 失败不阻断。可接受。
6. **bundle 体积 +~2MB / committed 文件 ~2MB**：与 CLAUDE.md「keep ... small」有张力——用户拍板存全量、build 后还原工作区使 git 历史不因每次构建而膨胀（详见 §2、§3.6）。后续若介意可再开 spec 做 build-time filter（见 §6）。
7. **回退链步骤 6 字典序选 key 的精度损失**：某超新子版本（如 `claude-opus-4-7`）可能暂退到 `claude-opus-4` family 价——与现状等价、不更差。

## 6. 后续工作（不在本 spec 范围）

- 把价格快照瘦身成 anthropic+openai 子集（若 bundle/repo 体积成问题）——会需要重设 SC7 的 size 阈值
- `make refresh-pricing-snapshot` 或 CI 定时任务，定期更新 committed fallback 快照
- 运行期刷新做成可在 Settings 开关 / 显示「价格数据更新于 X」
- 把 LiteLLM 的 `max_input_tokens` 等字段也用起来（如 context 用量百分比）

## 7. 引用

- 相关调研：ccusage 价格机制（本 spec §1 内联）
- 相关 ADR：[0002 Claude-only](../adr/0002-claude-only-not-multi-provider.md)（不冲突说明）
- 落地版本：[v0.2.14](../versions/v0.2.14-litellm-pricing.md)
- 前序：[v0.2.11 unified-poll-timer](../versions/v0.2.11-unified-poll-timer.md)（统一 tick 来源）

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [x] SC1 — done
- [x] SC2 — done
- [x] SC3 — done
- [x] SC4 — done
- [x] SC5 — done
- [x] SC6 — done
- [x] SC7 — done
- [x] SC8 — done
