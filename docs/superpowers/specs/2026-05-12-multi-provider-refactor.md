---
id: 2026-05-12-multi-provider-refactor
title: 多供应商架构重构 — UsageProvider 协议 + ProviderUsageSnapshot 统一形状 + per-provider 运行时（Claude 行为不变）
status: accepted
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.5
related_adrs: [0005, 0002]
related_research: [competitive-analysis, codex-data-sources]
related_specs: [2026-05-12-popover-redesign, 2026-05-12-codex-provider]
spec_criteria:
  - id: SC0
    criterion: 命名冲突先行解决 —— 现有 `UsageStoreTypes.UsageProvider`（存储用 enum，仅 `.claude`）与 `ProviderTab`（UI 枚举）合并为单一 `ProviderID`（`claude/codex/cursor/copilot/gemini`），同 module 内不再有名为 `UsageProvider` 的 enum；磁盘 `data/claude/` 目录名不受影响（`ProviderID.claude.rawValue == "claude"`）
    done: false
    evidence: null
  - id: SC1
    criterion: 存在 `protocol UsageProvider`（`id: ProviderID` / `displayName` / `isConfigured` / `supportsBackgroundPolling` / `defaultPollMinutes` / `fetchSnapshot() async throws -> ProviderUsageSnapshot` / `refreshNow() async`）与统一模型 `ProviderUsageSnapshot`（`primaryWindow`/`secondaryWindow`/`extraWindows`/`creditLine`/`planLabel`）+ `UsageWindow`（`label`/`utilizationPct`/`resetsAt`/`windowDuration`）+ `CreditLine`；Claude 以 `ClaudeUsageProvider` 形式实现该协议（沿用现有 OAuth/refresh/多账号/backoff/polling 全部逻辑，`fetchSnapshot` = 现有 endpoint → 解码 `UsageResponse` → 映射成 snapshot）
    done: false
    evidence: null
  - id: SC2
    criterion: 存在 `ProviderRegistry`（当前只注册 Claude 一个）+ 每 provider 一个 `ProviderRuntime`（`@MainActor ObservableObject`：`snapshot`/`lastUpdated`/`lastError`/`isConfigured`/`trendPrimary`/`trendSecondary`，**由所属 provider 写入**）+ `ProviderCoordinator`（持有 registry 与 `[ProviderID: ProviderRuntime]` + `primaryProviderID`，提供 `runtime(for:)`/`primaryRuntime`/`refreshNow(id:)`；**本版本 coordinator 不自己跑 timer**——Claude 的后台 polling 仍归 `ClaudeUsageProvider` 自己，它每次 fetch 成功后把映射出的 snapshot 写进自己的 `ProviderRuntime`）；`ClaudeUsageBarApp` 通过 `ProviderCoordinator` 装配，不再直接 `@StateObject UsageService()`（`UsageService` 演化成 `ClaudeUsageProvider`）
    done: false
    evidence: null
  - id: SC3
    criterion: 菜单栏 label（`MenuBarLabel`）改为读"主 provider"的 `ProviderRuntime`（icon 两段 = primary/secondary 窗口 %，percent 文案 = primary 窗口 %，趋势 = `trendPrimary`）；`primaryProviderID` 由 UserDefaults 持久化、默认 `.claude`；Settings 里有一个选主 provider 的 Picker（当前只有 Claude 可选 → 可隐藏或置灰，但 setting key 与读取链路已就位）
    done: false
    evidence: null
  - id: SC4
    criterion: popover 用量区（`PopoverView` 的 `usageView` + `UsageHeroCard` + 趋势/pace 计算）改为渲染"当前选中 tab 那个 provider"的 `ProviderRuntime`/`ProviderUsageSnapshot`/`UsageWindow`，不再直接引用 `UsageService.usage` 与 `UsageBucket`；`ProviderTab`（UI 枚举）与 `ProviderID` 建立明确映射（或合并）
    done: false
    evidence: null
  - id: SC5
    criterion: Claude 用户行为零回归 —— 启动→（CLI 凭证 bootstrap / OAuth 登录 / 添加账号 / code 粘贴）→ polling → 菜单栏 icon/percent/percent+trend → popover 两卡 + 趋势 + pace + per-model + extra usage + 折线图 + 热力图 + 错误提示 + 通知阈值，全部与重构前一致。**可审计证据**（不止"目测"）：(a) `swift test` 现有用例全过（必要处只改类型引用，不改断言语义）；(b) 新增 `ProviderAbstractionTests` 含 `UsageResponse → ProviderUsageSnapshot` 的 fixture 映射用例（断言每个目标字段值，相当于重构前后字段快照对比）；(c) 一个 spy 测试断言"`ClaudeUsageProvider` 一次成功 fetch 后仍调用 `historyService.recordDataPoint` 和 `notificationService` 的阈值检查"（注入 spy 替身），证明 history/notification 调用路径未被抽象层吞掉；(d) manual_checks 逐项目测
    done: false
    evidence: null
  - id: SC6
    criterion: 不引入 descriptor / SwiftSyntax 宏 / 插件注册框架；新增第三方依赖数 = 0；`UsageEventStore`/`UsageStatsService`/`JSONLCostParser`/`UsageAggregator`/`ScanCursorStore`（v0.2.3 成本热力图，已是 per-provider）逻辑不动，仅把其 `UsageProvider` 枚举并入统一的 `ProviderID`（或显式留注释说明二者关系，不强制合并）
    done: false
    evidence: null
  - id: SC7
    criterion: 活体用量渲染只走抽象层 —— `git grep -n 'UsageResponse\|UsageBucket' macos/Sources/ClaudeUsageBar` 的命中只出现在 `ClaudeUsageProvider.swift` / `UsageModel.swift`（Claude 内部解码模型与映射）及其测试里，菜单栏（`MenuBarLabel`）与 popover 用量区（`ProviderUsageSection`/`UsageHeroCard`）不引用它们，只读 `ProviderRuntime`/`ProviderUsageSnapshot`/`UsageWindow`
    done: false
    evidence: null
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_ARTIFACTS: make release-artifacts"
  - "SC_AUTO_GREP_SC7: git grep -n 'UsageResponse\\|UsageBucket' macos/Sources/ClaudeUsageBar -- ':!*ClaudeUsageProvider.swift' ':!*UsageModel.swift'  # 期望无输出（除注释）"
manual_checks:
  - "目测：Claude 已登录态下 popover/菜单栏/Settings 与重构前肉眼无差异；Settings 出现主 provider Picker（Claude-only）；切到 Codex/Cursor 等 tab 仍是占位"
reviews:
  - gate: G2
    by: codex (gpt-5.x, codex-rescue subagent)
    date: 2026-05-12
    verdict: approved-after-revisions
    notes: "3 必改：①命名冲突（旧 enum UsageProvider vs 新协议）— 已加 SC0/阶段 A0 先合并成 ProviderID；②ownership 不唯一（polling timer / recordDataPoint / checkNotify）— 已在 SC2/§3.3 明确归 ClaudeUsageProvider，coordinator 本版本不跑 timer；③SC5 证据太软 — 已加 fixture 映射测试 + history/notification spy 测试。可选建议（UsageWindow 加 label / 拆 A 阶段 / SC7 grep 命令）已采纳。"
  - gate: G3
    by: general-purpose subagent (独立 plan-review)
    date: 2026-05-12
    verdict: ready-with-revisions
    notes: "plan 基本 ready。3 必改：①A0 漏了 UsageEventStore.swift 的 provider 字段 + ProviderTabTests 处理要写明 — 已补；②primaryProviderID 不能在 ObservableObject 里用 @AppStorage — 改 @Published+手动 UserDefaults（§3.1 + 实施分期 D 已改）；③B 步要点名 setupComplete 迁移 + SettingsWindowContent 注入换 coordinator + 为 spy 给 UsageHistoryService/NotificationService 抽协议或去 final — 已补进 A2/B。建议（拆 A2/C/E、SC7 grep 作 C 硬证据、钉 utilizationPct=0..100、#Preview 跟符号、NotificationService 是 push 模型）已采纳。实施期决定：不把 UsageService 改名为 ClaudeUsageProvider，保留类名只 conform 协议，减少机械改名回归面。"
---

# 多供应商架构重构（Claude 行为不变）

## 1. 背景与目标

[ADR 0005](../adr/0005-reopen-multi-provider-direction.md) 重新开放多 provider 方向、分两步走：第 1 步 v0.2.4 搭好了 popover 顶部的 provider tab UI 外壳（Claude 可用，其余占位）；第 2 步要对接 Codex 数据层。但当前"活体用量"链路（`UsageService` + `UsageResponse`/`UsageBucket` + `MenuBarLabel` + `PopoverView.usageView` + `TrendCalculator`/`PaceCalculator` + `UsageHistoryService`）是**对 Claude 写死**的 —— 直接把 Codex 接进来要么塞进 `UsageService`（污染那个 Claude OAuth/polling 单一真相源），要么写一份平行的 `CodexUsageService`/`CodexUsageView`（重复代码、两套要各自维护）。两条都不优雅。

本 spec 先打地基：把活体用量链路抽象成"一个 provider 一个 `UsageProvider` 实现 + 统一的 `ProviderUsageSnapshot` 形状 + 每 provider 一个 `ProviderRuntime` 状态容器 + 一个 `ProviderCoordinator` 协调器"，Claude 改写成"恰好是当前唯一注册的 provider"。**纯重构，Claude 用户行为零回归**（唯一可见变化：Settings 多一个目前只有 Claude 可选的"主 provider" Picker）。地基好了之后，[v0.2.6 Codex provider](./2026-05-12-codex-provider.md) 只需新增一个 `CodexUsageProvider`，视图/状态容器/tab 切换全复用本 spec 的泛化层。

**明确不做**（ADR 0002/0005 已排除）：descriptor + 宏 + 30+ provider 插件框架。本 spec 的抽象是"够用的少数几家"级别，不是 CodexBar 那种规模。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 抽象野心 | 中等：`UsageProvider` 协议 + `ProviderUsageSnapshot` 统一形状 + per-provider `ProviderRuntime` + `ProviderCoordinator`；视图层泛化到吃 `ProviderRuntime` | 用户决策（2026-05-12）；既要"优雅 + Codex 能干净插入"，又不上插件框架 |
| Claude 怎么落到抽象上 | `UsageService` 演化成 `ClaudeUsageProvider`（保留全部 OAuth/refresh/多账号/backoff/polling 内部逻辑），新增 `fetchSnapshot()` = 现有 endpoint 调用 → 解码 `UsageResponse` → `mapToSnapshot()`；`UsageResponse`/`UsageBucket`/`ExtraUsage` 降级为该 provider 的内部解码模型 + 映射函数 | 复用既有、降低回归面；OAuth 那套外壳本就 Claude 特有，留在 provider 内部正合适 |
| 历史/趋势 | `UsageHistoryService` + `history.json` **本 spec 不动、不迁移**，仍 Claude 专用；`ClaudeUsageProvider` 的 `ProviderRuntime` 把 `trendPrimary/Secondary` 接到现有 history service，其它 provider 的 runtime 暂时 `trend*=nil` | 历史文件迁移有数据风险且非本 spec 核心；趋势 per-provider 等真有第二个需要趋势的 provider 时再泛化（后续工作） |
| 成本热力图那套（v0.2.3） | 不动；只把 `UsageStoreTypes.UsageProvider` 枚举与新的 `ProviderID` 对齐（合并或注释说明） | 已经是 per-provider，重构它没收益、纯增风险 |
| 菜单栏 label | 改读"主 provider" runtime；`primaryProviderID` 入 UserDefaults（默认 `.claude`）；Settings 加 Picker（Claude-only 时可隐藏，但 setting + 读取链路就位） | 用户决策（2026-05-12）；为 v0.2.6 Codex 上菜单栏铺路 |
| `NotificationService` | 继续观察 Claude（= 默认 primary）那个 runtime，阈值语义不变；由 `ProviderCoordinator`/`ClaudeUsageProvider` 在 fetch 后推样本进去 | 行为零回归优先；通知阈值 per-provider 化是后续工作 |
| `ProviderTab`（UI 枚举）vs `ProviderID` | 二者合并成一个 `ProviderID`（`claude/codex/cursor/copilot/gemini`），`isAvailable` 由 registry 是否注册了对应 provider 决定 | 消除当前两个并行枚举的认知负担（v0.2.4 注释里也吐槽过这点）|

## 3. 设计

### 3.1 新增类型（`macos/Sources/ClaudeUsageBar/Provider/` 新目录，或平铺在现有目录——实现期定，推荐建子目录）

| 类型 | 形态 | 说明 |
|---|---|---|
| `ProviderID` | `enum ProviderID: String, Codable, CaseIterable { case claude, codex, cursor, copilot, gemini }` | 规范 provider 标识。取代现有 `ProviderTab`（UI）和 `UsageStoreTypes.UsageProvider`（存储）两个枚举。`displayName` 计算属性（`"claude" → "Claude"`）。 |
| `UsageWindow` | `struct UsageWindow: Equatable { var label: String?; var utilizationPct: Double?; var resetsAt: Date?; var windowDuration: TimeInterval? }` | 一个滚动额度窗口的统一形状。`windowDuration` 让 pace（"此刻应该用到多少 %"）对所有 provider 通用；`label`（如 `"Session"`/`"Weekly"`）让渲染层不用再硬编码文案（G2 可选建议）—— Claude 映射时 primary 给 `"Session"`、secondary 给 `"Weekly"`，与现状一致。 |
| `CreditLine` | `struct CreditLine: Equatable { var isEnabled: Bool; var usedAmount: Double?; var limitAmount: Double?; var utilizationPct: Double?; var currencyCode: String? }` | 统一"按量计费/额外用量"行 —— 覆盖 Claude 的 `extra_usage` 与 Codex 的 `credits`。 |
| `ProviderUsageSnapshot` | `struct ProviderUsageSnapshot: Equatable { var primaryWindow: UsageWindow?; var secondaryWindow: UsageWindow?; var extraWindows: [NamedUsageWindow]; var creditLine: CreditLine?; var planLabel: String? }`；`NamedUsageWindow { id; title; window: UsageWindow }`（承载 Claude 的 Opus/Sonnet per-model 行） | 一次拉取的统一结果。各 provider 的 `fetchSnapshot()` 负责把自家 API 形状映射到这里。 |
| `UsageProvider` | `protocol UsageProvider: AnyObject { var id: ProviderID { get }; var displayName: String { get }; var isConfigured: Bool { get }; var supportsBackgroundPolling: Bool { get }; var defaultPollMinutes: Int { get }; func fetchSnapshot() async throws -> ProviderUsageSnapshot }` | 活体用量数据源契约。**只管"取数"**——凭证管理/登录流程是各 provider 的内部细节（Claude 有 OAuth 那一大套；Codex 只读文件），不进协议。 |
| `ProviderRuntime` | `@MainActor final class ProviderRuntime: ObservableObject`：`@Published var snapshot: ProviderUsageSnapshot?` / `lastUpdated: Date?` / `lastError: String?` / `isConfigured: Bool`；`trendPrimary: TrendIndicator?` / `trendSecondary: TrendIndicator?`（计算属性或 published，Claude 实例接 `UsageHistoryService`，其它返回 nil）；`func refresh(force: Bool) async`（调 provider.fetchSnapshot，更新 published；401-ish 失败时清 snapshot，网络失败保留 snapshot——把这条作为通用策略） | 每 provider 一个；视图直接 `@ObservedObject` 它。 |
| `ProviderRegistry` | `struct ProviderRegistry { let providers: [ProviderID: UsageProvider] }`（当前只放 `.claude`），`var availableIDs: [ProviderID]`，`var orderedTabIDs: [ProviderID] = ProviderID.allCases`（tab 排序固定，可用性 = `providers[id] != nil`） | provider 注册表。新增 provider = 往这里加一项 + 在 registry 构造处 new 它。 |
| `ProviderCoordinator` | `@MainActor final class ProviderCoordinator: ObservableObject`：持有 `ProviderRegistry` 与 `[ProviderID: ProviderRuntime]`；`@Published var primaryProviderID: ProviderID`（default `.claude`，**手动 `UserDefaults` 读/写——不用 `@AppStorage`，它在 `ObservableObject` 里不触发 `objectWillChange`，G3 必改 ②**）；`func provider(_:) -> UsageProvider?` / `func runtime(for:) -> ProviderRuntime?` / `var primaryRuntime: ProviderRuntime` / `var claude: ClaudeUsageProvider`（便捷）；`func refreshNow(_ id:) async`（给 popover Refresh 与"切 tab 拉一次"用，委托给 `provider.refreshNow()`）。**本版本 coordinator 不自己跑 timer**——Claude 的后台 polling timer / backoff / `recordDataPoint` / `checkAndNotify` 仍归 `ClaudeUsageProvider` 自己（G2 必改 ②），coordinator 只是注册表 + 主 provider 选择 + 按需 refresh 的"门面"。 | 把现在散在 `ClaudeUsageBarApp.task` 里的"装配/查找 provider"职责收口；Claude 自己的 OAuth/refresh/polling 细节不动。 |

### 3.2 Claude 改写

- `UsageService.swift` → 演化为 `ClaudeUsageProvider`（文件可改名或保留名字，实现期定；倾向改名 `ClaudeUsageProvider.swift` 并保留一个 `typealias` 过渡期不需要——直接全量替换引用更干净）。
  - 保留：OAuth PKCE 流程、`submitOAuthCode`、token refresh、`bootstrapFromCLIIfNeeded`、多账号（`accounts`/`StoredAccount`）、`isAuthenticated`/`isAwaitingCode`、polling 间隔设置（`pollingMinutes`/`pollingOptions`/`updatePollingInterval`）、指数 backoff、推样本给 `historyService`/`notificationService`。
  - 改：`fetchUsage()` 的"拉到 `UsageResponse` 之后"那段——拆成 `func fetchSnapshot() async throws -> ProviderUsageSnapshot`，内部仍调原 endpoint、解码 `UsageResponse`（保留 reconcile 逻辑）、再 `mapToSnapshot()`。`UsageResponse`→`ProviderUsageSnapshot` 映射：`fiveHour`→`primaryWindow`（`windowDuration: 5*3600`）、`sevenDay`→`secondaryWindow`（`windowDuration: 7*86400`）、`sevenDayOpus`/`sevenDaySonnet`→`extraWindows`、`extraUsage`→`creditLine`、plan 暂无 → `planLabel = nil`。
  - `isConfigured` = `isAuthenticated`。`supportsBackgroundPolling = true`。`defaultPollMinutes` = 现默认值。
  - `@Published var usage: UsageResponse?` 等可保留为内部，但 UI 不再读它——UI 读 `ProviderRuntime.snapshot`。**所有权（G2 必改 ②）**：polling timer / backoff / `recordDataPoint` / `checkAndNotify` 全部继续归 `ClaudeUsageProvider` 自己——位置和时机不变（仍在它现有的 fetch 成功分支里）；唯一新增的一行是"fetch 成功后把 `mapToSnapshot(usage)` 写进自己的 `ProviderRuntime`（连同 `lastUpdated`/清 `lastError`；fetch 失败按通用策略：401-ish 清 snapshot、网络错误保留 snapshot 但设 lastError）"。`coordinator.refreshNow(.claude)` = 调 `ClaudeUsageProvider` 现有的 `fetchUsage()`（带"距上次 <Ns 不重拉"的节流，给 popover Refresh 按钮和切 tab 用）。注意：Claude 的"未登录/等 code/添加账号"这些 UI 状态仍由 `PopoverView` 直接观察 `ClaudeUsageProvider`（这部分不泛化——是 Claude 特有的登录 UX），泛化的只是"已登录之后的用量展示区"。

### 3.3 polling / 装配迁移

现状：`ClaudeUsageBarApp.task` 里做 history load、wire services、`bootstrapFromCLIIfNeeded`、首次 `usageStats.refresh()`、`service.startPolling()`。重构后：

- `ClaudeUsageBarApp` `@StateObject` 改成持有 `ProviderCoordinator`（内部 new `ProviderRegistry` → new `ClaudeUsageProvider` + 它的 `ProviderRuntime`）、`UsageHistoryService`、`NotificationService`、`AppUpdater`、`UsageStatsService`。
- `.task` 里：`historyService.loadHistory()` → wire `ClaudeUsageProvider.historyService/notificationService` → `await claudeProvider.bootstrapFromCLIIfNeeded()` → setupComplete 标记 → `await usageStats.refresh()` → `claudeProvider.startPolling()`（**注意：polling timer 仍由 `ClaudeUsageProvider` 自己起，不是 coordinator**——G2 必改 ②；coordinator 本版本只做注册/查找/`refreshNow`，将来要给 Codex 那种 `supportsBackgroundPolling == false` 的 provider 做按需拉取或要统一调度时再扩 coordinator）。
- `PopoverView`/`MenuBarLabel` 注入：传 `coordinator`（+ 仍需 `claudeProvider` 引用给登录 UX 区，可由 `coordinator.provider(.claude) as? ClaudeUsageProvider` 取，或 coordinator 暴露一个 `claude` 便捷属性）、`historyService`（折线图区还要它）、`notificationService`、`appUpdater`、`usageStats`。

### 3.4 视图泛化

- `MenuBarLabel`：`@ObservedObject coordinator: ProviderCoordinator`（或直接传 `primaryRuntime: ProviderRuntime` + `claudeProvider` 判 `isAuthenticated`——但 primary 可能不是 Claude，所以判 `primaryRuntime.isConfigured` 更对）。icon: `renderIcon(pct5h: primary?.utilizationPct, pct7d: secondary?.utilizationPct)`（变量名将来可改，但 `MenuBarIconRenderer` 接口本就是两个可选 Double，不用动）。percent: `primaryWindow?.utilizationPct`。trend: `primaryRuntime.trendPrimary`。未配置: 现有 `renderUnauthenticatedIcon()` / `"5h --%"`.
- `PopoverView`：
  - 顶部 tab：`ProviderTabBar` 改吃 `ProviderID`（`registry.orderedTabIDs` + `isAvailable = registry.providers[id] != nil`）。
  - 选中 tab == 某可用 provider：渲染新的 `ProviderUsageSection(runtime:historyService:usageStats:)`（把现在 `PopoverView.usageView` 里"两卡 + per-model + extra + 折线图 + 热力图 + 错误"那段搬过去，改吃 `runtime.snapshot` 的 `UsageWindow`/`NamedUsageWindow`/`CreditLine`）。Claude 还要额外渲染登录 UX（未登录/等 code/添加账号）——这部分留在 `PopoverView` 顶层，仅当 `selectedID == .claude && !claudeProvider.isAuthenticated` 等条件触发。
  - 选中 tab == 未注册 provider：现有 `ProviderComingSoonView`。
  - 切 tab：`.task(id: selectedID)` → `await coordinator.refreshNow(selectedID)`（已配置才拉；Claude 因为有后台 polling，refreshNow 可做成"距上次 >Ns 才真拉"）。
- `UsageHeroCard`：`bucket: UsageBucket?` → `window: UsageWindow?`（`utilizationPct`/`resetsAt` 直接来自 `UsageWindow`；其余渲染不变）。`PaceCalculator.expectedPacePct` 已是 `(resetDate:windowDuration:)`，直接喂 `window.resetsAt` + `window.windowDuration`。
- per-model 行（`UsageBucketRow`）：改吃 `UsageWindow` / `NamedUsageWindow`。
- extra-usage 行（`ExtraUsageRow`）：改吃 `CreditLine`。Claude 的"credits 是分→换算成元"放进映射函数，`CreditLine.usedAmount/limitAmount` 已是元。
- 趋势计算（`computeTrend`）：现签名 `(currentPct:, points:, metric: KeyPath)`——`ProviderRuntime` 的 `trendPrimary` 内部对 Claude 走 `computeTrend(currentPct: snapshot.primaryWindow?.utilizationPct, points: historyService.history.dataPoints, metric: \.pct5h)`，对外只暴露 `TrendIndicator?`。

### 3.5 测试方案

- **不删现有测试**；`UsageServiceTests` 等若引用了改名/改型的符号，最小改动跟上（不改断言语义）。
- 新增 `ProviderAbstractionTests`：
  - `UsageResponse → ProviderUsageSnapshot` 映射：5h→primary（windowDuration 5h）、7d→secondary（7d）、opus/sonnet→extraWindows、extra_usage（分）→ creditLine（元 + utilizationPct）、缺字段→对应为 nil。
  - `ProviderRegistry`：默认只注册 `.claude`；`availableIDs == [.claude]`；`orderedTabIDs == ProviderID.allCases`。
  - `ProviderCoordinator`：`primaryProviderID` 默认 `.claude`；`primaryRuntime === runtime(for: .claude)`；改 `primaryProviderID` 后 `primaryRuntime` 跟着变（用一个 stub registry 注册两个假 provider 测）。
  - `ProviderRuntime.refresh`：注入一个 stub `UsageProvider`（`fetchSnapshot` 可控返回/抛错）——成功→`snapshot` 更新、`lastError=nil`、`lastUpdated` 刷新；抛"unauthorized"类错误→`snapshot` 清空、`lastError` 有值；抛网络错误→`snapshot` 保留、`lastError` 有值。
  - `ProviderID.displayName`：`.claude→"Claude"` 等。
- 一个"行为不变"的烟测思路（不强制写成自动化）：手动核对 popover/菜单栏与重构前截图一致（manual_checks）。

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `Provider/ProviderID.swift` | 取代 `ProviderTab` + `UsageStoreTypes.UsageProvider` |
| 🆕 | `Provider/ProviderUsageSnapshot.swift` | `UsageWindow` / `NamedUsageWindow` / `CreditLine` / `ProviderUsageSnapshot` |
| 🆕 | `Provider/UsageProvider.swift` | 协议 |
| 🆕 | `Provider/ProviderRuntime.swift` | per-provider 状态容器 |
| 🆕 | `Provider/ProviderRegistry.swift` | 注册表 |
| 🆕 | `Provider/ProviderCoordinator.swift` | 协调器 + primaryProviderID |
| 🆕 | `Provider/ClaudeUsageProvider.swift` | 由 `UsageService.swift` 演化（或保留 `UsageService.swift` 文件名、内部改造——实现期定） |
| 🆕 | `ProviderUsageSection.swift` | 从 `PopoverView.usageView` 抽出的泛化用量展示区 |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/ProviderAbstractionTests.swift` | |
| 🔧 | `ProviderTabBar.swift` | `ProviderTab` → `ProviderID`；`isAvailable` 由 registry 决定（构造时传入 availableIDs） |
| 🔧 | `PopoverView.swift` | 注入 coordinator；用量区委托给 `ProviderUsageSection`；登录 UX 区留 Claude 专用 |
| 🔧 | `MenuBarLabel.swift` | 改读 primary `ProviderRuntime` |
| 🔧 | `ClaudeUsageBarApp.swift` | `@StateObject` 改成 `ProviderCoordinator`；`.task` 装配迁移 |
| 🔧 | `UsageService.swift` | 拆出 `fetchSnapshot()` + `mapToSnapshot()`；其余逻辑保留（若选"演化成新文件"则整体迁移） |
| 🔧 | `UsageHeroCard.swift` | `UsageBucket?` → `UsageWindow?` |
| 🔧 | `UsageStoreTypes.swift` | `UsageProvider` 枚举并入 `ProviderID`（或留 `typealias` + 注释，二选一，实现期定） |
| 🔧 | `SettingsView.swift` | 加主 provider Picker |
| 🔧 | 既有 `*Tests.swift` | 跟随符号改名/改型最小改动 |
| 🔧（仅抽协议/去 final） | `UsageHistoryService`（抽 `HistoryRecording` 协议或去 `final`，供 spy）、`NotificationService`（抽 `UsageNotifying` 协议或去 `final`，供 spy）、`UsageEventStore.swift`（`provider: UsageProvider` → `ProviderID`，A0 阶段） | 仅为可测性 / enum 改名；行为不变。**注意**：`NotificationService` 是 push 模型（`UsageService.fetchUsage` 主动调 `checkAndNotify`），不是"观察某对象"——`UsageService` 继续持引用继续主动调，几乎不动 |
| ✅ 不动 | `UsageStatsService`/`JSONLCostParser`/`UsageAggregator`/`ScanCursorStore`/`UsageHeatmapView`/`UsageChartView`/`UsageHistoryModel`/`AppUpdater`/`MenuBarIconRenderer`/`MenuBarDisplayMode`/`PaceCalculator`/`TrendCalculator`/`AccountSwitcherView`/`StoredAccount`/`StoredCredentials`/`ClaudeCLICredentialsStrategy`/`ClaudeUsageStrategy`/`ClaudePricing`/`PillPicker`/`UsageCard`/各 formatter | 见决策摘要 |

> "演化成新文件" vs "原地改造 `UsageService.swift`"：实现期权衡，不强制。原则是改完后 `git grep UsageService` 不应再有"被当 Claude 真相源直接读"的 UI 调用点（SC7）。

## 5. 风险 / Open questions

1. **回归面大**。这是个横跨 ~15 个文件的重构，最容易在"行为不变"上翻车（菜单栏 icon、pace 标记、reconcile、通知阈值时机、添加账号流程）。缓解：(a) 分阶段实现（§见下"实施分期"），每阶段 `swift build && swift test` 必须绿；(b) 不改任何 formatter / 计算函数的内部逻辑，只换它们的输入类型；(c) manual_checks 逐项目测。
2. **`UsageBucket.resetsAt` 是 ISO8601 字符串、`UsageWindow.resetsAt` 是 `Date`**。Claude 映射时要把字符串 parse 成 Date（复用 `UsageBucket.resetsAtDate`）。reconcile（缺 resetsAt 时按上次推算）逻辑保留在 `UsageResponse` 层（映射前做），映射后 `UsageWindow.resetsAt` 已是确定值。
3. **`primaryProviderID` 当前只有 Claude 可选**——Picker 在单 provider 时基本是装饰。决定：Picker 在 `availableIDs.count <= 1` 时隐藏（或 disabled 并提示"更多 provider 即将到来"），但 setting key + `MenuBarLabel` 读取链路就位。这点小，实现期定具体呈现。
4. **`UsageStoreTypes.UsageProvider` 合并 vs 共存**。它现在只有 `.claude` 一个 case、用作磁盘目录名。并入 `ProviderID` 最干净，但要确认磁盘上已有的 `data/claude/` 目录名不受影响（`ProviderID.claude.rawValue == "claude"`，一致，安全）。倾向合并；若合并牵扯太多就留 `typealias ProviderProvider = ProviderID` 类的桥。
5. **是否该是个 ADR**？引入 `UsageProvider` 协议算架构决策。但 ADR 0005 已经定了"分两步、复用 per-provider 抽象、新建 strategy"的方向，本 spec 是它的"how"落地。倾向不另开 ADR，spec §2 决策摘要足够；若 G2 reviewer 认为该有 ADR，再补一个轻量 ADR 0006 引用本 spec。

### 实施分期（= G3 plan；已并入 G2 必改 ①③ + G3 plan-review 的必改与建议）

> **G3 后的两个实施期决定**：(1) **不把 `UsageService` 改名为 `ClaudeUsageProvider`** —— 保留 `UsageService` 类名 + 文件名（避免 `UsageServiceTests.swift` 742 行等大面积机械改名带来的回归面），只让它 conform `UsageProvider`、新增映射 + runtime 写入。spec 全文凡写 `ClaudeUsageProvider` 处 ≡ 演化后的 `UsageService`；SC7 的 grep 例外文件相应是 `UsageService.swift`。(2) **`UsageWindow.utilizationPct` 语义钉死为 `0...100`**（与 `UsageBucket.utilization` 一致，映射时直接搬；`MenuBarLabel`/icon 那边现在喂的是 `pct5h = utilization/100`（0..1），改写时做 `/100` 换算）。

- **A0. 命名清理（纯 rename，无行为变化）**：新增 `ProviderID`（5 case，`displayName` 计算属性）；把 `UsageStoreTypes.UsageProvider` enum + **`UsageEventStore.swift` 的 `private let provider: UsageProvider` 与默认参数** 全部改指 `ProviderID`、删掉旧 enum（`ProviderID.claude.rawValue == "claude"`，磁盘 `data/claude/` 兼容）；`ProviderTabBar.swift` 的 `ProviderTab` 并到 `ProviderID`（`isAvailable` 本阶段仍硬编码 `== .claude`，registry 还没来），其 `#Preview` 跟着改；测试：`ProviderTabTests.swift` 照搬到 `ProviderID` 版（`allCases` 顺序 / `displayName` / `isAvailable` 暂仍硬编码，C 阶段再改）、`UsageEventStoreTests`/`UsageAggregatorTests`/`ScanCursorStoreTests` 凡引用 `UsageProvider.claude` 的改 `ProviderID.claude`。→ build+test 绿。**目的**：消除"协议名 vs 旧 enum 名"同 module 冲突，让 A1/A2 能编译。
- **A1. 统一模型 + Claude 映射 + 映射测试（纯增）**：新增 `UsageWindow`(`label`/`utilizationPct` 0..100/`resetsAt: Date?`/`windowDuration`)、`NamedUsageWindow`、`CreditLine`、`ProviderUsageSnapshot`；`UsageService` 加 `func mapToSnapshot(_ usage: UsageResponse) -> ProviderUsageSnapshot`（`fiveHour`→primary(label "Session", windowDuration 5*3600)、`sevenDay`→secondary("Weekly", 7*86400)、`sevenDayOpus`/`sevenDaySonnet`→extraWindows、`extraUsage`→`CreditLine`（**含分→元 /100 换算**、`utilizationPct` 原样）、`planLabel = nil`；`resetsAt` 用 `UsageBucket.resetsAtDate` parse）；`ProviderAbstractionTests` 加 `mapToSnapshot` 的 fixture 用例（逐字段断言，含 /100）= SC5-b。视图、`fetchUsage` 都不动。→ 绿。
- **A2. 协议 + runtime + registry + coordinator + conform + spy 测试**：新增 `protocol UsageProvider`（`id`/`displayName`/`isConfigured`/`supportsBackgroundPolling`/`defaultPollMinutes`/`runtime: ProviderRuntime`/`refreshNow() async`——`fetchSnapshot` 不进协议，作 Codex 内部 helper；Claude 的"取数"逻辑就是现有 `fetchUsage`）、`ProviderRuntime`（`@MainActor ObservableObject`：`snapshot`/`lastUpdated`/`lastError`/`isConfigured`/`trendPrimary`/`trendSecondary`；提供 `apply(snapshot:)` / `apply(error:clearSnapshot:)` 给 provider 写）、`ProviderRegistry`（只注册 `.claude`）、`ProviderCoordinator`（持有 registry + `[ProviderID: ProviderRuntime]`；`primaryProviderID` 用 **`@Published` + 手动 `UserDefaults` 读写**（不用 `@AppStorage`，它在 `ObservableObject` 里不触发 `objectWillChange`）；`provider(_:)`/`runtime(for:)`/`primaryRuntime`/`claude`/`refreshNow(_:) async`；本版本不跑 timer）；`UsageService` conform `UsageProvider`（`runtime` 在 init 里 new；`refreshNow()` = 现有 `fetchUsage()` + "距上次成功 <Ns 不重拉"节流；在 `fetchUsage()` 现有 success 分支末尾加一行 `runtime.apply(snapshot: mapToSnapshot(reconciled))`，catch/permanentFailure 分支按通用策略 `runtime.apply(error:clearSnapshot:)`——位置时机不动 recordDataPoint/checkNotify/timer）；**为 SC5-c 的 spy**：给 `UsageHistoryService` 抽一个 `protocol HistoryRecording { func recordDataPoint(pct5h:pct7d:) }` + `NotificationService` 抽 `protocol UsageNotifying { func checkAndNotify(pct5h:pct7d:pctExtra:) }`（或去 `final` + 子类化），`UsageService.historyService`/`notificationService` 改持协议；`ProviderAbstractionTests` 加：registry/coordinator/runtime（stub `UsageProvider`）用例、`primaryProviderID` 切换后 `primaryRuntime` 跟变、`refreshNow` 成功/401/网络三态 → runtime 状态、**spy 断言"一次成功 `fetchUsage` 后 `recordDataPoint` 与 `checkAndNotify` 各被调一次"**（SC5-c）。`ClaudeUsageBarApp` 本阶段不变（下阶段换 coordinator）。→ 绿。
- **B. 装配迁移**：`ClaudeUsageBarApp` `@StateObject` 改成 `ProviderCoordinator`（内部 new registry → new `UsageService`(=Claude provider) → 它的 runtime）+ 仍持 `UsageHistoryService`/`NotificationService`/`AppUpdater`/`UsageStatsService`；`.task` 装配迁移（顺序不变：history load → wire `coordinator.claude.historyService/notificationService` → `await coordinator.claude.bootstrapFromCLIIfNeeded()` → **`setupComplete` 判断原样接到 `coordinator.claude.isAuthenticated`** → `await usageStats.refresh()` → `coordinator.claude.startPolling()`——polling 仍由 provider 起）；`PopoverView`/`MenuBarLabel`/`SettingsWindowContent` 的注入：从 `UsageService` 换成 `coordinator`（视图内部暂时还 `coordinator.claude` 直读老 API）；`ClaudeUsageBarApp` 的 `Settings { SettingsWindowContent(...) }` 调用点 + `SettingsViewTests` 跟着改。→ 绿。
- **C. 视图泛化**（回归面最大，内部按 C1→C3 推进，每子步 build 绿）：
  - **C1**：`UsageHeroCard` `bucket: UsageBucket?` → `window: UsageWindow?`（`percentageText`/`pctValue`/`resetLine`/`paceDeviation`/`markerFraction` 内部逻辑不动，只换取值来源）；`UsageBucketRow` → 吃 `NamedUsageWindow`/`UsageWindow`；`ExtraUsageRow` → 吃 `CreditLine`（`usedAmount`/`limitAmount` 已是元）；**`UsageHeroCard.swift` 的 `#Preview` 改用 `UsageWindow(...)` 字面量**（`swift build` 编 preview）。加一个 smoke 测试：给 fixture `ProviderUsageSnapshot` → 断言 `UsageHeroCard` 计算属性输出与"同数据走旧 `UsageBucket`"一致。
  - **C2**：抽 `ProviderUsageSection(runtime: ProviderRuntime, historyService: UsageHistoryService, recentEvents:..., dailySpend:...)`——把 `PopoverView.usageView` 里"两 `UsageHeroCard` + per-model + extra + 折线图 + 热力图 + 错误卡 + Updated...ago + Refresh 行"那段搬进去，改吃 `runtime.snapshot` 的 window/creditLine + `runtime.trendPrimary/Secondary`（趋势计算挪进 `ProviderRuntime`：Claude runtime 内部 `computeTrend(currentPct: snapshot.primaryWindow?.utilizationPct, points: historyService.history.dataPoints, metric: \.pct5h)`）；`PopoverView` 已登录分支改 `ProviderUsageSection(runtime: coordinator.runtime(for: selectedID)!, ...)`；Claude 的未登录/等 code/添加账号 UX 区留在 `PopoverView` 顶层（仅 `selectedID == .claude` 时按 `coordinator.claude` 的状态渲染）。
  - **C3**：`MenuBarLabel` 改 `@ObservedObject coordinator` → 读 `coordinator.primaryRuntime`（icon: `(primaryWindow?.utilizationPct ?? 0)/100`、`(secondaryWindow?...)/100`；percent 文案: `primaryWindow?.utilizationPct`；trend: `primaryRuntime.trendPrimary`；未配置: `!primaryRuntime.isConfigured`）+ 加 percent 文案测试；`ProviderTabBar` 的 `isAvailable` 改由传入的 `availableIDs` 决定，`#Preview` 跟着改；`PopoverView` 的 tab 列表来自 `ProviderID.allCases`，可用性查 registry。
  - → 全绿 + `SC_AUTO_GREP_SC7` 通过（C 阶段的硬证据）+ 目测。
- **D. 主 provider 设置**：`SettingsView` 加主 provider Picker（`coordinator.primaryProviderID` 绑定；`availableIDs.count <= 1` 时隐藏或 disabled+提示）；确认 `MenuBarLabel` 走 `primaryRuntime`、切换 `primaryProviderID` 后 label 跟着重渲染（加测试：改 `primaryProviderID` → `primaryRuntime === runtime(for: 新id)`）。→ 绿 + 目测。
- **E1. 清理**：删死代码（`UsageService` 里 UI 不再用的便捷属性若确无引用——`pct5h` 等映射里还要用就留；`@Published var usage` 改 `private(set)` 或保留）；跑 `SC_AUTO_GREP_SC7` 自查；`#Preview` 全扫一遍跟符号。→ 绿。
- **E2. 收尾（gate 动作，非代码步）**：回填 spec `spec_criteria.done/evidence` + Verification log；跨模型 code-review（G5）；版本 `release_notes_zh` 草稿（纯重构，用户向 entry 写"内部：多供应商架构重构，为后续接入 Codex 等做准备"）+ CHANGELOG append；G6 checklist 勾。

> **manual_checks 展开**（E2 前逐项过）：icon 三种 display mode（icon / percent / percent+trend）各看一遍数值对；pace 标记竖线位置对；per-model（Opus/Sonnet）行在；extra usage 行金额/百分比对；折线图正常；热力图正常；未登录态 / 等 code 态 / 添加账号流程 / 切账号 / Sign Out 都正常；popover Refresh 按钮工作；Settings 的 polling Picker 仍工作 + 新的主 provider Picker 出现（Claude-only）；切到 Codex/Cursor 等 tab 仍是占位面板。

## 6. 后续工作（不在本 spec 范围）

- v0.2.6 Codex provider（新增 `CodexUsageProvider`，复用本 spec 全部泛化层）—— spec 已存在：[`2026-05-12-codex-provider.md`](./2026-05-12-codex-provider.md)
- 历史样本 per-provider 化（泛化 `UsageHistoryService`/`history.json`），让非 Claude provider 也有趋势箭头
- 通知阈值 per-provider 化
- per-provider 的 OAuth/凭证 UX 各自演化（Codex 是只读文件，Cursor/Copilot/Gemini 未定）
- Cursor / Copilot / Gemini provider（仍占位，按需求再排）

## 7. 引用

- 相关 ADR：[`../adr/0005-reopen-multi-provider-direction.md`](../adr/0005-reopen-multi-provider-direction.md)（supersede 了 [`0002`](../adr/0002-claude-only-not-multi-provider.md)）
- 相关调研：[`../research/competitive-analysis.md`](../research/competitive-analysis.md)（§3.2 实现机制差距）、[`../research/codex-data-sources.md`](../research/codex-data-sources.md)
- 相关 spec：[`2026-05-12-popover-redesign.md`](./2026-05-12-popover-redesign.md)（v0.2.4，搭了 provider tab UI 外壳）、[`2026-05-12-codex-provider.md`](./2026-05-12-codex-provider.md)（v0.2.6，本 spec 的下游消费者）
- 落地版本：[`../versions/v0.2.5-multi-provider-refactor.md`](../versions/v0.2.5-multi-provider-refactor.md)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [ ] SC1 — pending
- [ ] SC2 — pending
- [ ] SC3 — pending
- [ ] SC4 — pending
- [ ] SC5 — pending
- [ ] SC6 — pending
- [ ] SC7 — pending
