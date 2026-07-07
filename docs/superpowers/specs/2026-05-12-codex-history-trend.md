---
id: 2026-05-12-codex-history-trend
title: Codex 历史采样持久化 + 趋势箭头 + 额度折线图（泛化 UsageHistoryService / UsageChartSectionView）
status: implemented
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.8
related_adrs: [0005]
related_research: [codex-data-sources]
related_specs: [2026-05-12-multi-provider-refactor, 2026-05-12-codex-provider, 2026-05-11-trend-arrows, 2026-05-11-pace-tracking, 2026-05-12-popover-redesign]
spec_criteria:
  - id: SC1
    criterion: "`UsageHistoryService` 改成可指定「写到哪个文件」与「写到哪个目录」—— `init(filename:directory:)`，默认 `filename: \"history.json\"` + `directory: ~/.config/usage-bar`，即 Claude 的现有路径与行为零变化（`history.json` 文件名、`.bak.json` 备份名、30 天保留、5 分钟 flush、willTerminate flush 全不变）；`.bak` 路径由 filename 派生（`history.bak.json`）。新签名让单测能用临时目录隔离验证。"
    done: true
    evidence: "UsageHistoryService 加 `init(filename: String = \"history.json\", directory: URL? = nil)`，把原 `static historyFileURL` 换成实例 `let fileURL`/`backupURL`（`internal` 供测试）；`loadHistory`/`flushToDisk` 用 `fileURL`、坏文件挪到 `backupURL`；`flushToDisk` 写后 `setAttributes([.posixPermissions: 0o600])`（G5 should-fix；Claude 的 `history.json` 一并受益）；逻辑其余不变。UsageHistoryServiceTests 新建 5 用例：testInitDefaultPathUnchanged / testRecordFlushReloadCustomFile / testTwoFilenamesNoCollision / testFlushedFileIsOwnerOnly（断言 0o600）/ testLoadCorruptFileMovesToBak。"
  - id: SC2
    criterion: "`CodexProvider` 拥有自己的 `UsageHistoryService`（默认 `filename: \"history-codex.json\"`），并在每次**成功** `refreshNow()`（拿到 snapshot）后追加一个数据点：`pct5h = primaryWindow.utilizationPct/100`、`pct7d = secondaryWindow.utilizationPct/100`（缺失的窗口按 0 记，如 Free 计划只有 weekly 时 session 记 0；两个窗口都缺则不记）。失败路径（凭证缺失 / 401 / 网络错误）不追加数据点。`CodexProvider` 在 init 时 `loadHistory()`。`UsageHistoryService` 注入到 `CodexProvider.init(history:)` 以便单测。"
    done: true
    evidence: "CodexProvider 加 `let history: UsageHistoryService`，`init(...history: UsageHistoryService? = nil)` —— 默认值在 @MainActor init 体内现造（`history ?? UsageHistoryService(filename: \"history-codex.json\")`，避免 @MainActor 默认参数在 nonisolated 上下文求值的编译错），init 末 `history.loadHistory()`；`refreshNow()` 顶部加 `guard !isRefreshing` 重入闸门（G5 must-fix），成功分支 `runtime.setSuccess` 后调 `recordHistorySample(from:)`：`guard p != nil || s != nil`，每个 % 经 `min(max(pct/100, 0), 1)` clamp（G5 should-fix）后 `history.recordDataPoint(pct5h:pct7d:)`。CodexProviderTests 新增：testRefreshSuccessRecordsHistorySample（两窗口 40%/60% → 1 点 0.40/0.60）/ testRefreshFreePlanRecordsZeroSession（单 604800 窗口 55% → primary 为 nil、1 点 pct5h=0/pct7d=0.55）/ testRefreshFailureRecordsNothing（401 → 0 点）/ testRefreshNoCredentialsRecordsNothing（无 auth.json → 0 点、snapshot nil）/ testRefreshNowIsNotReentrant（两个 async let 并发 → 只记 1 点）。"
  - id: SC3
    criterion: "`CodexProvider` 新增 `func startPolling()` —— 幂等（已有 timer 直接 return）；调用即立刻 `Task { [weak self] in await self?.refreshNow() }` 拉一次，并起一个固定 5 分钟（`pollIntervalSeconds = 300`，无 UI 设置）的重复 timer，每次 `[weak self]` 捕获后 `Task { await self?.refreshNow() }`（仿 `UsageHistoryService` 用 `Timer.publish().autoconnect().sink`，存 `AnyCancellable`；`CodexProvider` 生命周期 = app 生命周期，无需 deinit 显式取消，与 `UsageHistoryService` 一致）。`UsageBarApp` 在启动 `.task` 里对 `CodexProvider` 调一次 `startPolling()`。`supportsBackgroundPolling` **保持 `false`** —— 见 SC7 / §2：该 flag 仅作 `primaryEligibleIDs`（菜单栏 primary 候选）的门，本版本菜单栏渲染尚未 provider-aware（`5h` 前缀 / Claude 字标硬编码），Codex 暂不进 Primary Provider 下拉；它有自己的 refresh timer 但不被当成「可上菜单栏的稳定数据源」。`UsageProvider.supportsBackgroundPolling` 与 `ProviderCoordinator.primaryEligibleIDs` 的文档注释更新以反映「flag = 菜单栏 primary 候选资格（需后台数据源 **且** 菜单栏能渲染该 provider）；provider 可以为 popover 内历史采样自持轻量 refresh timer 而不必置此 flag」。"
    done: true
    evidence: "CodexProvider 加 `private var pollCancellable: AnyCancellable?`、`static let pollIntervalSeconds: TimeInterval = 300`、`var isPolling: Bool { pollCancellable != nil }`、`func startPolling()`：`guard pollCancellable == nil else { return }` → `Task { [weak self] in await self?.refreshNow() }` → `pollCancellable = Timer.publish(every:...,on:.main,in:.common).autoconnect().sink { [weak self] _ in Task { await self?.refreshNow() } }`（`import Combine`）；`supportsBackgroundPolling = false`（不变）。UsageBarApp `.task` 末 `if let codex = coordinator.provider(.codex) as? CodexProvider { codex.startPolling() }`。UsageProvider/ProviderCoordinator 注释重写为「菜单栏 primary 候选资格」。测试 testStartPollingIsIdempotent（两次 startPolling，isPolling 仍 true、不崩）+ testSupportsBackgroundPollingIsFalse；既有 testCoordinatorPrimaryEligibleExcludesNonPollingProvider 仍绿（Codex 不进 primaryEligibleIDs）。"
  - id: SC4
    criterion: "Codex tab（popover）的 Session / Weekly 卡显示趋势箭头：从 Codex 自己的历史样本用既有 `computeTrend(currentPct:points:metric:)`（默认 6h lookback）算出，传给 `ProviderUsageSection(trendPrimary:trendSecondary:)` —— 与 Claude tab 一致。无历史时（样本 < 1 个 ≤ 6h 前的点）箭头为 nil（不显示），不报错。"
    done: true
    evidence: "PopoverView 新增 `private struct ProviderHistorySection`：`@ObservedObject historyService/runtime` + `let primaryLabel/secondaryLabel`，body 里 `computeTrend(currentPct: snap?.primaryWindow?.utilizationPct, points: pts, metric: \\.pct5h)` / `\\.pct7d` → `ProviderUsageSection(runtime:, trendPrimary:, trendSecondary:)`（与 `claudeUsageArea` 同一套 API、同一个 `computeTrend`）。无历史 → `computeTrend` 对空 points 返回 nil（既有 TrendCalculatorTests 守该行为）→ 箭头不显示。纯 SwiftUI 无 ViewInspector，由 `swift build` + manual_checks（开 Codex tab 等 6h+ 看箭头）覆盖。"
  - id: SC5
    criterion: "Codex tab 加上额度折线图区块（`UsageChartSectionView`，复用，不重写）：`UsageChartSectionView` / `UsageChartContentView` 新增 `primaryLabel`/`secondaryLabel` 参数（默认 `\"5h\"`/`\"7d\"`，Claude 调用点不变），Codex 传 `\"Session\"`/`\"Weekly\"`；图例 / tooltip / `chartForegroundStyleScale` 用这两个 label。Codex 传 `recentEvents: []` → 估算费用卡不渲染（`scannedFileCount == 0` 已有的隐藏逻辑）。折线图放在 `PopoverView` 的泛化 provider 区里、Session/Weekly 卡之下、`Updated …` 之上。"
    done: true
    evidence: "UsageChartSectionView 加 `var primaryLabel: String = \"5h\"` / `var secondaryLabel: String = \"7d\"`，透传给 `UsageChartContentView`（加 `let primaryLabel/secondaryLabel`）；两条 `LineMark.foregroundStyle(by: .value(\"Window\", primaryLabel/secondaryLabel))` + `chartForegroundStyleScale([primaryLabel: .blue, secondaryLabel: .orange])`（tooltip 文字本就只是百分比，未动）；颜色映射不变。`ProviderHistorySection` 里 `UsageCard { UsageChartSectionView(historyService:, recentEvents: [], primaryLabel:, secondaryLabel:) }` 放在 `ProviderUsageSection` 之后；`ProviderUsageArea` 加可选 `history: (service:primaryLabel:secondaryLabel:)?`，`runtime.isConfigured` 分支 `if let h = history { ProviderHistorySection(...) } else { ProviderUsageSection(runtime:) }`，其后 error 卡 / `Updated …` / `bottomBar()` 不变；`providerArea` Codex 分支传 `(CodexProvider.history, \"Session\", \"Weekly\")`。`recentEvents: []` → `costSummary` 的 `scannedFileCount == 0` → 费用卡不渲染。Claude 调用点（`claudeUsageArea`）走默认 `5h`/`7d` —— 不变。`swift build -c release` 通过。"
  - id: SC6
    criterion: "`swift build -c release` 通过；`swift test` 全绿（含新增的 `UsageHistoryService(filename:directory:)` 隔离测试、`CodexProvider` 成功/失败/Free 计划记点测试、`startPolling()` 幂等性测试、`supportsBackgroundPolling == false` 断言）；`make release-artifacts` + `verify-release.sh` 对 zip/dmg 均 OK。"
    done: true
    evidence: "`cd macos && swift build -c release` Build complete；`swift test` = 219 tests 0 failures（207 既有 + UsageHistoryServiceTests 5 + CodexProviderTests 7 新）；`make release-artifacts` 产出 zip/dmg；`bash macos/scripts/verify-release.sh macos/UsageBar.zip` 与 `.dmg` 均 \"Release archive looks good\"。"
  - id: SC7
    criterion: "Claude tab / 菜单栏 / Settings 行为零回归：Claude 的 `history.json` 路径与内容格式不变；Claude tab 折线图仍标 `5h`/`7d`；菜单栏 trend 仍只对 Claude 显示；**Codex 仍不在 Settings「Primary Provider」下拉里**（`supportsBackgroundPolling` 保持 `false`，菜单栏渲染尚未 provider-aware —— 见 §6 后续）；既有 `UsageServiceTests` / `ProviderAbstractionTests` / `UsageChartInterpolationTests` / `SettingsViewTests` 等全绿不动。"
    done: true
    evidence: "`UsageDataPoint` 字段（pct5h/pct7d JSON key）/ `history.json` 默认路径未动（testInitDefaultPathUnchanged）；Claude `claudeUsageArea` 的 `UsageChartSectionView(historyService:recentEvents:)` 调用走默认参数 → 仍 `5h`/`7d`；`MenuBarLabel`/`MenuBarIconRenderer`/`SettingsView` 文件未动；`supportsBackgroundPolling` 仍 false（testSupportsBackgroundPollingIsFalse + testCoordinatorPrimaryEligibleExcludesNonPollingProvider）；既有 219 tests 全绿（含 UsageServiceTests/ProviderAbstractionTests/UsageChartInterpolationTests/SettingsViewTests）；`ProviderCoordinator` 逻辑只改注释。"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_ARTIFACTS: make release-artifacts"
manual_checks:
  - "本机有 `~/.codex/auth.json` 时：开 popover 切到 Codex tab → 看到 Session/Weekly 卡 + 折线图（首开「No history data yet.」）；等 ≥2 个 polling 周期（或多次按 Refresh）后折线图出现数据点；隔 6h+ 再看 → Session/Weekly 卡出现 ▲/▼ 趋势箭头"
  - "本版本起：只要 `~/.codex/auth.json` 存在，app 每 5 分钟会向 `https://chatgpt.com/backend-api/wham/usage` 发一次 GET（用本机 Codex 凭证）；`~/.config/usage-bar/history-codex.json` 里只存 session%/weekly% 两个百分比，不含 token。release notes 中需对用户明示该后台行为"
  - "Settings → Primary Provider 下拉**不**含 Codex（仍只有 Claude）—— 本版本意图如此"
reviews:
  - gate: G2
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: design-review + security-review (敏感面：后台周期性访问 chatgpt.com + 新增本机 history-codex.json)
    verdict: approved-after-revisions
    notes: >
      2 must-fix：① 翻 `supportsBackgroundPolling = true` 会让 Codex 进 `primaryEligibleIDs` → Settings 可选 Codex 为 primary，但 `MenuBarLabel`/`MenuBarIconRenderer` 的 `5h` 前缀与 Claude 字标硬编码、尚未 provider-aware —— spec 须选定一条路并锁住入口；② `CodexProvider` timer 的生命周期/引用循环（`[weak self]`、MainActor 跳转、`startPolling()` 幂等、cancel 行为）spec 没写全。
      should-fix：补 startPolling 幂等性测试 hook；frontmatter 小不一致（`related_adrs` 用 `[0005]`、`evidence` 用 `null`）；release notes 须明示新增的 5 分钟后台网络行为。
      第二轮复审（同一 reviewer）：两轮 must-fix 均闭合，无剩余阻塞项 → verdict 升 approved，可进入 G3。
      已全部应用：must-fix ① → `supportsBackgroundPolling` 保持 `false`（flag 重定义为「菜单栏 primary 候选资格」，更新协议/coordinator 文档注释），Codex 仍有自己的 refresh timer 但不进 Primary 下拉，菜单栏 provider-aware 化挪到 §6 后续；must-fix ② → SC3 写全 `[weak self]` + 幂等 + `Timer.publish/AnyCancellable`（仿 `UsageHistoryService`，app 生命周期不需 deinit 取消）；should-fix → 加 `testStartPollingIsIdempotent`、`related_adrs: [0005]`、`evidence: null`、新增后台行为写进 `manual_checks`（后续发版 release notes 同步）。
  - gate: G3
    date: 2026-05-12
    reviewer: general-purpose subagent (independent, cross-session)
    scope: plan-review of docs/superpowers/plans/2026-05-12-codex-history-trend.md
    verdict: ready-with-revisions
    notes: >
      1 must-fix（Task 2/3/4 在 commit 前只跑了 `--filter` 测试或只 `swift build`，违反 G4「每个代码 commit 要 `swift build` 与 `swift test` 全绿」—— 已在三个 Task 的 commit 前各加一步 `cd macos && swift build -c release && swift test`）
      + should-fix（Task 3/4 无新增单测要在 plan 里显式声明「由 manual_checks 覆盖」—— 已加；`testInitDefaultPathUnchanged` 会顺带 `try?` 建真 `~/.config/...` 目录，无害，已知；`testRefreshFreePlanRecordsZeroSession` 的 fixture 经 reviewer 核对正确，那段 hedge 多余）。plan 的代码片段对照现有代码逐行核对、`@ObservedObject` 不能 Optional 的拆分解法、labeled-tuple 传参、`computeTrend`/`ProviderRuntime` API、`@MainActor init` 调 `loadHistory()` 均经确认（praise）。
  - gate: G5
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: code-review + security-review (敏感面：新增 5 分钟后台访问 chatgpt.com + 新建 history-codex.json)
    verdict: request-changes → 修订后 approved
    notes: >
      1 must-fix（`refreshNow()` 无重入闸门 —— timer / Refresh 按钮 / 切 tab 撞上会并发拉 chatgpt.com、重复记历史、旧响应覆盖新状态。已加 `private var isRefreshing` guard：`guard !isRefreshing else { return }; isRefreshing = true; defer { isRefreshing = false }`，`@MainActor` 序列化保证第二个调用在第一个的网络 `await` 期间进来直接 return）
      + 3 should-fix（① `history-codex.json` 没设 0600 —— 已在 `UsageHistoryService.flushToDisk` 写后 `setAttributes([.posixPermissions: 0o600])`（Claude 的 `history.json` 一并受益）+ 测试 `testFlushedFileIsOwnerOnly`；② `utilizationPct/100` 未 clamp —— `recordHistorySample` 改用 `min(max(pct/100, 0), 1)`；③ 重入测试不足 —— 加 `testRefreshNowIsNotReentrant`：两个 `async let` 并发调 `refreshNow`，断言只记 1 个历史点）
      + 2 nit（version 文档正文「`supportsBackgroundPolling` 可能翻成 true」与实现矛盾 —— 已改；labeled-tuple 传 history 建议后续改 struct —— 记 §6）。
      创建并加载历史于 @MainActor init、`ProviderHistorySection` 复用 `computeTrend`/`UsageChartSectionView` 无逻辑复制、错误路径不透传 token —— 均获认可（praise）。修订后 `swift build -c release` 通过、`swift test` = 219 tests 0 failures、`make release-artifacts` + verify zip/dmg OK。
---

# Codex 历史采样持久化 + 趋势箭头 + 额度折线图

## 1. 背景与目标

v0.2.6 给 Codex tab 做了「额度窗口卡（Session/Weekly）+ pace + 套餐徽章 + credits 余额」，但跟 Claude tab 比还缺：**趋势箭头**（▲▼ + 增量百分点）、**额度折线图**、消费热力图。用户的目标是「Codex tab 和 Claude 现在的界面/功能一致」。本 spec 是这条路的第二步（第一步 v0.2.6 已完成；热力图 + 本机成本扫描 → v0.2.9）。

趋势箭头与折线图都依赖**历史样本**。Claude 的历史由 `UsageHistoryService`（`~/.config/usage-bar/history.json` ring buffer，30 天保留）承载，目前是 Claude 专属、`UsageService` 在 polling 成功后 `recordDataPoint`。Codex 第一版（v0.2.6）`supportsBackgroundPolling = false`、只在切 tab / 按 Refresh 时惰性拉一次 —— 那样历史只在用户开 popover 时零星积累，6h lookback 的趋势基本算不出来。所以本 spec 顺带给 Codex 一个轻量后台采样节奏。

**目标**：（a）把 `UsageHistoryService` 泛化成 per-provider（一个文件名/目录参数，Claude 路径行为零变化）；（b）`CodexProvider` 每次成功拉取落一个采样点到自己的历史文件，并有一个固定间隔的轻量 refresh timer 保证样本积累；（c）Codex tab 显示趋势箭头 + 额度折线图，文案 `Session`/`Weekly`。改动小、不引入新依赖、不动 Claude 既有行为、不动凭证/存储格式、不动菜单栏。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 历史复用方式 | **复用 `UsageHistoryService`，按 provider 不同文件**（`init(filename:directory:)`，默认 = Claude 现路径）。**不**新建 Codex 专用历史类 | `UsageDataPoint` 的 `pct5h`/`pct7d` 本质就是「主/次窗口已用比例」，Codex 的 session/weekly 直接对得上；ring buffer / 降采样 / 插值 / 保留 / flush 全可原样复用。新建一个并行类是 DRY 反模式 |
| `recordDataPoint` 函数名 | **保持 `recordDataPoint(pct5h:pct7d:)` 不改名**（虽对 Codex 语义上是 session/weekly） | 改名会波及 `HistoryRecording` 协议、`UsageService`、spy 测试；`UsageDataPoint.pct5h/pct7d` 是已持久化的 JSON key（改了破坏现有 `history.json`）必须保留。函数名跟字段名一致即可，在 `CodexProvider` 调用处注释清楚映射。YAGNI，不改名 |
| `UsageHistoryService` 注入目录 | `init` 同时收 `directory:`（默认 `~/.config/usage-bar`）—— 不止 `filename:` | 现有 `historyFileURL` 用 `homeDirectoryForCurrentUser`，单测没法重定向（这也是它至今没单测的原因）。加 `directory:` 让新测试用临时目录跑完整 load/record/flush/prune 循环。顺带补回测试覆盖 |
| Codex 后台采样 | **有**：`CodexProvider` 自持一个固定 5 分钟（无 UI 设置）的 refresh timer（`Timer.publish().autoconnect().sink`，仿 `UsageHistoryService`），`UsageBarApp` 启动时显式 `startPolling()` | 没有后台采样，6h-lookback 趋势 + 折线图基本是空的，跟「和 Claude 一致」相悖。`wham/usage` 是个轻 GET，5 分钟不构成滥用。可配置化 → 后续 |
| `supportsBackgroundPolling` 翻不翻 true | **保持 `false`**；把这个 flag 的语义明确为「**菜单栏 primary 候选资格**」= 需要「稳定后台数据源」**且**「菜单栏能渲染该 provider」。Codex 满足前者、不满足后者（`MenuBarLabel` 的 `5h` 前缀 / `MenuBarIconRenderer` 的 Claude 字标硬编码），所以本版本 Codex **不**进 Settings「Primary Provider」下拉 | G2 must-fix #1：翻 true 会把一个「菜单栏还渲染不了」的 provider 放进 primary 选择器。最小、不冒险的做法是不动 flag、只给 Codex 一个独立的 refresh timer 入口；菜单栏 provider-aware 化是另一块工作 → §6。更新 `UsageProvider` / `ProviderCoordinator` 文档注释说明「provider 可为 popover 内历史采样自持轻量 timer 而不必置此 flag」 |
| 菜单栏 trend 是否对 Codex 显示 | **本版本不**（Codex 也还不能上菜单栏，无从谈起）；`MenuBarLabel.showTrend` 仍 `primaryProviderID == .claude` | Codex tab **内**的趋势箭头本版本已做（popover 里直接拿 `CodexProvider.history`）。菜单栏侧整体留作后续 |
| 折线图复用方式 | **复用 `UsageChartSectionView`，加 `primaryLabel`/`secondaryLabel` 参数**（默认 `5h`/`7d`，Claude 调用点不变）；Codex 传 `recentEvents: []`（费用卡自动隐藏） | 整张图（PillPicker + Chart + hover tooltip + 降采样）原样可用，只有两条线/图例的文字是硬编码的 `5h`/`7d`，参数化即可。Codex 的「跟随时间窗口的估算费用」是 v0.2.9 的事（要先有本机 session JSONL 扫描），现在传空数组 |

## 3. 设计

### 3.1 改动文件

| 文件 | 改动 |
|---|---|
| `macos/Sources/UsageBar/UsageHistoryService.swift` | `init(filename: String = "history.json", directory: URL? = nil)`：存 `private let fileURL: URL`（= `(directory ?? Self.defaultDirectory).appendingPathComponent(filename)`，`defaultDirectory` 即原 `~/.config/usage-bar` 并 `createDirectory`）；存 `private let backupURL: URL` = `fileURL.deletingPathExtension().appendingPathExtension("bak.json")`。把原 `static var historyFileURL` 的所有用法换成实例 `fileURL`/`backupURL`。`willTerminate` observer / `loadHistory` / `recordDataPoint` / `flushToDisk` / `downsampledPoints` / `pruned` 逻辑不变（只是路径来源变实例属性）。`HistoryRecording` conformance 不变。为 `testInitDefaultPathUnchanged` 把 `fileURL`/`backupURL` 留 `internal`（非 `private`）或加一个 `internal var debugFileURL`/`debugBackupURL` 转发——实施期挑更克制的；倾向直接 `internal let`。 |
| `macos/Sources/UsageBar/UsageProvider.swift` | `supportsBackgroundPolling` 的文档注释改写：「该 flag = 该 provider 是否作为**菜单栏 primary 候选**（`ProviderCoordinator.primaryEligibleIDs`）—— 要求既有稳定后台数据源、又有 provider-aware 的菜单栏渲染。注意：provider 可以为「popover 内历史采样」自持一个轻量 refresh timer（装配处显式 `startPolling()`）而**不**必置此 flag —— Codex v0.2.8 即如此。」（仅注释；协议成员不变。） |
| `macos/Sources/UsageBar/ProviderCoordinator.swift` | `primaryEligibleIDs` 的文档注释同步上面的措辞（仅注释，逻辑不变）。 |
| `macos/Sources/UsageBar/CodexProvider.swift` | (a) `supportsBackgroundPolling` 保持 `false`（不改）；(b) 新增 `let history: UsageHistoryService`，`init(environment:session:history:)` 默认 `history: UsageHistoryService(filename: "history-codex.json")`；`init` 末尾 `history.loadHistory()`；(c) `refreshNow()` 成功分支（`runtime.setSuccess(snapshot:)` 之后）调 `private func recordHistorySample(from snap: ProviderUsageSnapshot)`：`let p = snap.primaryWindow?.utilizationPct; let s = snap.secondaryWindow?.utilizationPct; guard p != nil || s != nil else { return }; history.recordDataPoint(pct5h: (p ?? 0)/100, pct7d: (s ?? 0)/100)`（注释：pct5h↔session、pct7d↔weekly，沿用既有字段名）；(d) 新增 `private var pollCancellable: AnyCancellable?` + `static let pollIntervalSeconds: TimeInterval = 300` + `func startPolling()`：`guard pollCancellable == nil else { return }`（幂等）；`Task { [weak self] in await self?.refreshNow() }`（立即拉一次）；`pollCancellable = Timer.publish(every: Self.pollIntervalSeconds, on: .main, in: .common).autoconnect().sink { [weak self] _ in Task { await self?.refreshNow() } }`（仿 `UsageHistoryService.startFlushTimerIfNeeded`；`CodexProvider` = app 生命周期，与 `UsageHistoryService` 一样不在 deinit 显式 cancel）。`import Combine`。 |
| `macos/Sources/UsageBar/UsageChartView.swift` | `UsageChartSectionView`：加 `var primaryLabel: String = "5h"`、`var secondaryLabel: String = "7d"`；传给 `UsageChartContentView`。`UsageChartContentView`：同样加这两个参数；把 body 里硬编码的 `"5h"`/`"7d"`（两处 `LineMark.foregroundStyle(by: .value("Window", …))`、`chartForegroundStyleScale([…])`）换成 `primaryLabel`/`secondaryLabel`；`tooltipView` 的两个 Label（蓝=primary、橙=secondary）保持颜色不变（文字本就只是百分比，不显示 label 名 —— 若现状有显示则一并换，实施时按文件实际为准）。`chartForegroundStyleScale` 的 key 顺序仍 primary→蓝、secondary→橙。 |
| `macos/Sources/UsageBar/PopoverView.swift` | 新增 `private struct ProviderHistorySection: View { @ObservedObject var historyService: UsageHistoryService; @ObservedObject var runtime: ProviderRuntime; let primaryLabel: String; let secondaryLabel: String; var body { let pts = historyService.history.dataPoints; let t5 = computeTrend(currentPct: runtime.snapshot?.primaryWindow?.utilizationPct, points: pts, metric: \.pct5h); let t7 = computeTrend(currentPct: runtime.snapshot?.secondaryWindow?.utilizationPct, points: pts, metric: \.pct7d); ProviderUsageSection(runtime: runtime, trendPrimary: t5, trendSecondary: t7); UsageCard { UsageChartSectionView(historyService: historyService, recentEvents: [], primaryLabel: primaryLabel, secondaryLabel: secondaryLabel) } } }`。`ProviderUsageArea` 加 `var history: (service: UsageHistoryService, primaryLabel: String, secondaryLabel: String)? = nil`；`runtime.isConfigured` 分支里：`if let h = history { ProviderHistorySection(historyService: h.service, runtime: runtime, primaryLabel: h.primaryLabel, secondaryLabel: h.secondaryLabel) } else { ProviderUsageSection(runtime: runtime) }`，其余（error 卡 / `Updated …` / `bottomBar()`）不变。`providerArea` 非 Claude 分支：`let history = selectedProvider == .codex ? (coordinator.provider(.codex) as? CodexProvider).map { ($0.history, "Session", "Weekly") } : nil`；`ProviderUsageArea(runtime: runtime, providerID: selectedProvider, onBackToClaude: …, history: history, bottomBar: { bottomBar })`。 |
| `macos/Sources/UsageBar/UsageBarApp.swift` | 启动 `.task` 末尾（`coordinator.claude.startPolling()` 之后）加：`if let codex = coordinator.provider(.codex) as? CodexProvider { codex.startPolling() }`。（Codex 历史在 `CodexProvider.init` 里已 `loadHistory()`。） |
| `macos/Tests/UsageBarTests/UsageHistoryServiceTests.swift`（新建） | 见 §3.3。 |
| `macos/Tests/UsageBarTests/CodexProviderTests.swift` | 追加 §3.3 的 Codex 记点 / `startPolling` 幂等 / `supportsBackgroundPolling` 用例。 |

### 3.2 数据流

```
UsageBarApp.task ──► CodexProvider.startPolling()  ── 立即一次 + every 300s ──►  refreshNow()
                                                                                        │  成功
                                                                                        ▼
                                            runtime.setSuccess(snapshot)  +  history.recordDataPoint(session%, weekly%)
                                                              │                              │
   PopoverView (Codex tab) ◄── @ObservedObject ───────────────┘                              ▼ (5min flush / willTerminate)
        │  ProviderHistorySection(historyService = CodexProvider.history, runtime, "Session", "Weekly")    history-codex.json
        ├─ computeTrend(pts, \.pct5h / \.pct7d) ─► ▲/▼ → ProviderUsageSection 的 Session/Weekly 卡
        └─ UsageChartSectionView(historyService, recentEvents: [], primaryLabel: "Session", secondaryLabel: "Weekly")
```

（`supportsBackgroundPolling` 仍 `false` → `primaryEligibleIDs` 不含 `.codex` → 菜单栏 / Settings 不变。）

### 3.3 测试方案

**新建 `UsageHistoryServiceTests.swift`**（用临时目录隔离）：

- **testInitDefaultPathUnchanged**：`UsageHistoryService()` 的 `fileURL` 末段 == `"history.json"`、`backupURL` 末段 == `"history.bak.json"`、`fileURL.deletingLastPathComponent()` 末两段 == `.config/usage-bar`。（守 SC1「Claude 路径零变化」。）
- **testRecordAndFlushToCustomFile**：`let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`（测试 tearDown 删之）；`let h = UsageHistoryService(filename: "history-codex.json", directory: dir)`；`h.recordDataPoint(pct5h: 0.5, pct7d: 0.2)`；`h.flushToDisk()`；断言 `dir/history-codex.json` 存在；`UsageHistoryService(filename:"history-codex.json", directory: dir)` 新实例 `loadHistory()` 后有 1 个点、`pct5h == 0.5`、`pct7d == 0.2`。
- **testTwoFilenamesNoCollision**：同一 `dir`、两个实例（`history.json` / `history-codex.json`）各 `recordDataPoint`（不同值）+ `flushToDisk`；各自新实例 `loadHistory()` 回来只有自己的那条。
- **testLoadCorruptFileMovesToBak**：往 `dir/history-codex.json` 写 `"{ not json"`，`h.loadHistory()` → `h.history.dataPoints.isEmpty`、`dir/history-codex.bak.json` 存在。

**追加到 `CodexProviderTests.swift`**（沿用既有 `CodexStubURLProtocol`、临时 `CODEX_HOME` 写 `auth.json` 的既有 helper）：

- **testSupportsBackgroundPollingIsFalse**：`CodexProvider().supportsBackgroundPolling == false`。（守 SC7「Codex 不进 primary 下拉」。）
- **testRefreshSuccessRecordsHistorySample**：stub 返回含 primary(5h, used_percent X)+secondary(7d, used_percent Y) 两窗口的 usage JSON；`let h = UsageHistoryService(filename:"t.json", directory: tmpDir)`；`let p = CodexProvider(environment: 指向有 auth.json 的 CODEX_HOME, session: stubSession, history: h)`；`await p.refreshNow()`；断言 `h.history.dataPoints.count == 1`、`pct5h ≈ X/100`、`pct7d ≈ Y/100`（`accuracy: 1e-9`）。
- **testRefreshFreePlanRecordsZeroSession**：stub 返回**只有 weekly 窗口**（Free 计划，`normalizedWindows()` 的 session 为 nil）；`refreshNow()` 后 `dataPoints.count == 1`、`pct5h == 0`、`pct7d ≈ weekly%/100`。
- **testRefreshFailureRecordsNothing**：stub 返回 401；`refreshNow()` 后 `h.history.dataPoints.isEmpty`、`p.runtime.lastError != nil`。
- **testRefreshNoCredentialsRecordsNothing**：`environment` 指向无 `auth.json` 的临时 `CODEX_HOME`；`refreshNow()` 后 `h.history.dataPoints.isEmpty`、`p.runtime.snapshot == nil`。
- **testStartPollingIsIdempotent**：`p.startPolling(); p.startPolling()` 不崩；（若实施时给了 `internal var isPolling: Bool { pollCancellable != nil }`）断言 `p.isPolling == true`，再 `p.startPolling()` 仍 `true`、无副作用。（timer 真实周期不在测试里跑。）

> `startPolling()` 起的 5 分钟 timer 真实触发、`PopoverView` 的 trend/chart 渲染（无 ViewInspector）→ 由 code-reading + 上面单测的边界部分 + `manual_checks` 覆盖。

CI 仍跑 `swift build -c release` + `swift test` + `make release-artifacts`，全绿。

## 4. 文件迁移动作汇总

| 动作 | 文件 |
|---|---|
| 🔧 | `UsageHistoryService.swift` —— `init(filename:directory:)`，文件路径变实例属性（Claude 默认零变化），`fileURL`/`backupURL` 留 `internal` 供测试 |
| 🔧 | `UsageProvider.swift` —— `supportsBackgroundPolling` 文档注释重定义（仅注释） |
| 🔧 | `ProviderCoordinator.swift` —— `primaryEligibleIDs` 文档注释同步（仅注释） |
| 🔧 | `CodexProvider.swift` —— `let history` + `init(history:)` + `loadHistory()`；成功路径 `recordHistorySample`；`startPolling()`（幂等、立即一次 + 5 分钟 `Timer.publish/AnyCancellable`、`[weak self]`）；`supportsBackgroundPolling` **不动**（仍 `false`） |
| 🔧 | `UsageChartView.swift` —— `UsageChartSectionView`/`UsageChartContentView` 加 `primaryLabel`/`secondaryLabel`（默认 `5h`/`7d`） |
| 🔧 | `PopoverView.swift` —— 新增 `ProviderHistorySection`（trend + 折线图）；`ProviderUsageArea` 可选挂它；Codex 分支传 `(CodexProvider.history, "Session", "Weekly")` |
| 🔧 | `UsageBarApp.swift` —— 启动 `.task` 里 `(coordinator.provider(.codex) as? CodexProvider)?.startPolling()` |
| 🆕 | `UsageHistoryServiceTests.swift`；`CodexProviderTests.swift` 追加用例 |
| ✅ 不动 | `history.json` 格式 / `UsageDataPoint` 字段 / `HistoryRecording` 协议签名 / `UsageService` polling / `MenuBarLabel` / `MenuBarIconRenderer` / `SettingsView`（Codex 仍不进 primary 下拉）/ Claude tab 折线图文案 / `ProviderCoordinator` 逻辑（仅改注释）/ 凭证 & 存储 / Codex 凭证读取逻辑 / `UsageStatsService` / `UsageHeatmapView`（→ v0.2.9） |

## 5. 风险 / Open questions

1. **Codex 有了后台 timer 但不在 primary 下拉里** —— 故意的（菜单栏渲染尚未 provider-aware，G2 must-fix #1）。`supportsBackgroundPolling` 这个名字现在和「Codex 其实也在后台 poll」字面上有点出入 —— 用文档注释把语义钉成「菜单栏 primary 候选资格」来缓解；彻底理顺（拆成 `canDriveMenuBar` 之类）等菜单栏 provider-aware 化那版一起做。可接受。
2. **固定 5 分钟 Codex polling，无 UI 设置** —— `wham/usage` 是轻 GET；和 Claude polling 默认同量级。要不要可配置 → 后续。
3. **`CodexProvider.history` 在 init 里同步 `loadHistory()`** —— 本机小文件读，`CodexProvider` 本来就在 app 启动时 eager 创建；与 Claude「在 `.task` 里 load」时机略不同但无害（Codex 历史不喂菜单栏首帧）。可接受。
4. **Free 计划记 `pct5h = 0`** —— 折线图上 session 线平 0。比「跳过不记导致折线图有洞 / 趋势算不出」更简单，对 Free 用户（无 5 小时窗口 ≈ 0 占用）语义也说得过去。可接受。
5. **新增后台网络行为** —— 本版本起只要本机有 Codex 凭证，app 就每 5 分钟访问一次 `chatgpt.com/backend-api/wham/usage`。凭证读取/不写回逻辑与 v0.2.6 完全一致；`history-codex.json` 只存两个百分比、不含 token。发版 release notes 需对用户明示（已进 `manual_checks`）。

## 6. 后续工作（不在本 spec 范围）

- **菜单栏 provider-aware 化** + Codex 进 Primary Provider 下拉：`MenuBarLabel` 的 `5h` 前缀、`MenuBarIconRenderer` 的 Claude 字标参数化；把「primary 对应的 history」传进 `MenuBarLabel` 让非 Claude primary 也有 trend；届时把 `supportsBackgroundPolling` 拆/正名（如 `canDriveMenuBar`）
- Codex polling 间隔可配置（仿 Claude `pollingMinutes`）
- Codex 本机 `~/.codex/sessions/**` JSONL 扫描 → 成本/token → 估算费用卡 + 消费热力图（→ v0.2.9 spec `2026-05-12-codex-cost-heatmap`）
- 把 `UsageHistoryService` 进一步抽成「provider→history 的注册表」（目前 Claude 在 `UsageBarApp` 注入、Codex 在 `CodexProvider` 自持，两套小路径；provider 多了再统一）
- `PopoverView.ProviderUsageArea.history` 的 labeled-tuple 传参（`(service:primaryLabel:secondaryLabel:)?`）—— provider 增多后改成具名小 struct，避免 label/顺序出错（G5 nit）

## 7. 引用

- 前置 spec：[`2026-05-12-multi-provider-refactor.md`](./2026-05-12-multi-provider-refactor.md)、[`2026-05-12-codex-provider.md`](./2026-05-12-codex-provider.md)、[`2026-05-11-trend-arrows.md`](./2026-05-11-trend-arrows.md)、[`2026-05-11-pace-tracking.md`](./2026-05-11-pace-tracking.md)、[`2026-05-12-popover-redesign.md`](./2026-05-12-popover-redesign.md)
- 调研：[`../research/codex-data-sources.md`](../../research/codex-data-sources.md)
- ADR：[`../adr/0005-reopen-multi-provider-direction.md`](../../adr/0005-reopen-multi-provider-direction.md)
- 落地版本：[`../versions/v0.2.8-codex-history-trend.md`](../../versions/v0.2.8-codex-history-trend.md)

## Verification log

> G6 验收依据（详见 frontmatter `spec_criteria` 的 evidence）。

- [x] SC1 — UsageHistoryService(filename:directory:)，Claude 默认路径零变化（UsageHistoryServiceTests 4 用例）
- [x] SC2 — CodexProvider 成功路径 recordHistorySample（含 Free 计划记 0、失败不记；CodexProviderTests 4 新用例）
- [x] SC3 — startPolling() 幂等 + 立即一次 + 5 分钟 timer + app 启动调用；supportsBackgroundPolling 保持 false（含注释重定义；testStartPollingIsIdempotent / testSupportsBackgroundPollingIsFalse）
- [x] SC4 — Codex tab Session/Weekly 卡趋势箭头（ProviderHistorySection 用既有 computeTrend）
- [x] SC5 — Codex tab 折线图（UsageChartSectionView 加 primaryLabel/secondaryLabel，Session/Weekly 文案，recentEvents:[] → 无费用卡）
- [x] SC6 — swift build OK；swift test 219 tests 0 failures；make release-artifacts + verify zip/dmg OK
- [x] SC7 — Claude tab / 菜单栏 / Settings 零回归（Codex 不进 primary 下拉；既有 219 tests 绿）
