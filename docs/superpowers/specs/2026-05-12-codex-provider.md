---
id: 2026-05-12-codex-provider
title: Codex provider 对接（第一条数据源：~/.codex/auth.json OAuth → wham/usage）
status: implemented
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
revision_note: "2026-05-12 §3 重写：v0.2.5 多供应商抽象已落地，Codex 改为新增一个 CodexProvider: UsageProvider + 复用泛化视图层；不再有独立 CodexUsageService/CodexUsageView。SC1-7 验收目标不变。"
model: claude-opus-4-7
target_version: v0.2.6
related_adrs: [0005]
related_research: [codex-data-sources, competitive-analysis]
related_specs: [2026-05-12-multi-provider-refactor]
spec_criteria:
  - id: SC1
    criterion: 装了 codex CLI 并 ChatGPT 登录后，popover Codex tab 展示 5h（session）与 weekly 两张用量卡（百分比 + 进度条 + pace 标记 + Resets in 倒计时），plan 徽章正确（Plus/Pro/…），有 credits 时显示余额行（剩余余额，或 Unlimited）
    done: true
    evidence: "数据路径：CodexProvider.refreshNow → CodexUsageResponse.asProviderSnapshot → ProviderUsageSection（复用 UsageHeroCard 含 pace/Resets in）+ planLabel 徽章 + CreditLineRow（remaining/Unlimited）。测试 testDecodeFullFixtureAndMap / testProviderSuccess。UI 已 `make install` 待用户目测确认（version G6 checklist）。commit feat: v0.2.6 Codex provider 核心 + 接线"
  - id: SC2
    criterion: 没有 ~/.codex/auth.json（或 OPENAI_API_KEY 也没有）时，Codex tab 显示"未检测到 Codex 凭证，请运行 codex 登录"占位，不崩溃、不报噪声 error
    done: true
    evidence: "CodexProvider.refreshNow：load 返回 nil → runtime.setConfigured(false) + clear()（不设 lastError）→ ProviderUsageArea 渲染 ProviderUnconfiguredView（.codex 文案『请在终端运行 codex 登录后回到这里』）。测试 testProviderNoCredentials。"
  - id: SC3
    criterion: wham/usage 返回 401/403 时，Codex tab 清掉旧 snapshot 并显示"Codex 凭证已过期，请运行 codex 重新登录"（不留旧卡片 + 过期错误并存的歧义状态），不崩溃；网络错误保留旧 snapshot 但显示通用错误文案
    done: true
    evidence: "CodexProvider.refreshNow catch CodexUsageError.unauthorized → runtime.setError(…, clearSnapshot: true)；其它 → setError(…, clearSnapshot: false)（留旧 snapshot）。测试 testProviderUnauthorizedClearsSnapshot / testProviderServerErrorKeepsSnapshot / testClientUnauthorized / testClientServerErrorOmitsBody。"
  - id: SC4
    criterion: Codex 的凭证读取与请求是只读副作用——不创建/不修改 ~/.codex/auth.json，不发起浏览器 OAuth 登录流程；CODEX_HOME 环境变量被尊重
    done: true
    evidence: "CodexCredentialStore 仅 `Data(contentsOf:)`，无任何写/创建调用；CodexProvider 无 OAuth/refresh 路径（401 仅提示用户跑 codex）；authFileURL 读 CODEX_HOME。测试 testLoadRespectsCodexHome / testLoadFileAbsentReturnsNil。grep 确认无凭证写回。"
  - id: SC5
    criterion: 单测覆盖 auth.json 解析（OAuth 形态 / API key 形态 / 缺字段）、wham/usage 响应解码（含 primary/secondary 窗口角色归一化、缺窗口、credits 字符串/数字）、reset_at→Date 与窗口长度→pace 输入的换算
    done: true
    evidence: "CodexProviderTests：testLoadOAuthSnakeCase/CamelCase/APIKeyForm/MissingTokensThrows/InvalidJSONThrows、testDecodeFullFixtureAndMap（reset_at→Date、windowSeconds→windowDuration）、testNormalizeSwappedWindows、testDecodeSingleWindow、testDecodeCreditsBalanceAsString/Unlimited、testDecodeUnknownPlan、testDecodeEmpty。23 个用例全过。"
  - id: SC6
    criterion: 切到 Codex tab 时拉取一次用量；popover 里有 "Refresh" 能重拉；Claude tab 行为零回归（菜单栏 label、polling、通知都不受影响）
    done: true
    evidence: "PopoverView .task(id: selectedProvider) 对非 Claude 可用 provider 调 coordinator.refreshNow（既有逻辑，Codex 自动生效）；bottomBar 的 Refresh 调 coordinator.refreshNow(selectedProvider)。Claude 链路（UsageService/UsageHistoryService/NotificationService/MenuBarLabel）未改动 + 200 测试全绿（含 12 UsageServiceTests）。Settings Primary Provider Picker 仍只 Claude（primaryEligibleIDs）。待用户目测确认。"
  - id: SC7
    criterion: 错误日志 / error 对象 / debug description / 测试 fixture 失败输出都不打印 raw access_token / refresh_token / id_token / account_id 值（与既有 ClaudeCLICredentialsStrategy SC7 安全约束一致）；error 枚举 case 名也不带可二次解析的数值码。可验证方式：(a) 单测断言 error 的 `description` / `localizedDescription` 不含注入的假 token 串；(b) `grep -rn` 确认 Codex 相关源文件里没有把凭证字段插值进 log/print/error 文案
    done: true
    evidence: "(a) testCodexCredentialErrorDescriptionHasNoRawValues / testClientUnauthorized / testClientServerErrorOmitsBody（断言 `\"\\(error)\"` 不含 SENTINEL / SECRET_BODY）；测试 fixture 用哨兵值 ACCESS_SENTINEL 等而非像真 token 的串，断言失败 message 用 mask()。(b) grep -rnE 'accessToken|refreshToken|idToken|accountId' macos/Sources/ClaudeUsageBar/Codex*.swift —— 命中仅：struct 字段声明、`Bearer \\(accessToken)` header value、`ChatGPT-Account-Id` header value、JSON key 字符串；无 print/os_log/description/error 文案插值。CodexUsageError/CodexCredentialError 的 description 只回 case 名（server 带 HTTP 状态码，非凭证）。"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_ARTIFACTS: make release-artifacts"
manual_checks:
  - "目测 popover Codex tab：有 codex 登录态时两张卡 + plan 徽章；无登录态占位文案；切 tab 触发拉取"
reviews:
  - gate: G2
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: design-review + security-review (敏感面：读 ~/.codex/auth.json OAuth tokens)
    verdict: approved-after-revisions
    notes: >
      1 must-fix（SC7：凭证解析单测失败 diff 不得打印 raw token，改哨兵值 + 掩码 message）
      + 3 should-fix（① PopoverView configured/unconfigured 判定改读 runtime.isConfigured 而非 provider.isConfigured；
      ② ProviderCoordinator setter 层拒绝非 primaryEligibleIDs 值，不止构造时校验；③ CreditLineRow 同步加 isUnlimited/remaining 渲染分支 + 标题不再硬编码 "Extra Usage"）。
      全部已在本 spec §3 应用。安全只读边界、不做 token refresh-with-writeback、范围大小均获认可（praise）。
  - gate: G3
    date: 2026-05-12
    reviewer: general-purpose subagent (independent, cross-session)
    scope: plan-review of docs/superpowers/plans/2026-05-12-codex-provider.md
    verdict: ready-with-revisions
    notes: >
      3 must-fix（① CodexPlan(rawValue: try? decodeIfPresent…) → String?? 不编译，补 ?? nil；
      ② credits balance string 分支 .flatMap{ Double($0) } 类型错，先拍平 String?? ；
      ③ CodexPlan 有 .other 又有 .unknown 且 .other 吞掉所有未知串 → 与 testDecodeUnknownPlan 矛盾，砍 .other）
      + 3 should-fix（CodexProvider.init 删掉坏的 setConfigured 行只留正确形式；ProviderCoordinator didSet 用 isReverting 旗标而非靠 == oldValue；coordinator 测试 bracket UserDefaults 清理）+ 几个 nit（CreditLineRow 用 credit. 不是 line.；credit isEnabled corner case；ProviderUnconfiguredView Codex 文案）。
      全部已在 plan v2 应用。line-number / 既有代码声明经核对准确；SC1-7 覆盖完整。
  - gate: G5
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: code-review + security-review (敏感面：读 ~/.codex/auth.json OAuth tokens)
    verdict: request-changes → resolved
    notes: >
      1 must-fix（codex runner /tmp 写权限拦了 `swift test`，无法在该沙箱出绿——实为 runner 配置问题非真实失败；
      已在本机重跑：swift build -c release 通过、swift test = 201 tests 全绿、make release-artifacts + verify-release zip/dmg 均 OK）
      + 3 should-fix（① ProviderUsageArea unconfigured 分支也渲染 runtime.lastError，否则 auth.json 损坏被「未检测到凭证」遮掉；
      ② normalizedWindows() 兜底改按 windowSeconds 升序而非出现顺序；③ ProviderAbstractionTests UserDefaults 清理改 defer）。
      3 个 should-fix 已在 commit「fix: v0.2.6 G5 review」应用 + 补 testNormalizeNonStandardSwappedWindowsFallback。
      SC7/SC4 只读边界、HTTP client 不泄漏凭证、ProviderUsageArea/@ObservedObject runtime 反应性修复、ProviderCoordinator isRevertingPrimary 防递归 均获认可（praise）。
---

# Codex provider 对接（第一条数据源）

> 前置依赖：[v0.2.5 多供应商架构重构](./2026-05-12-multi-provider-refactor.md)（已 `implemented`）。本 spec §3 已按 v0.2.5 落成的抽象重写——Codex = 新增一个 `CodexProvider: UsageProvider` + 复用泛化视图层，无独立 `CodexUsageService`/`CodexUsageView`。

## 1. 背景与目标

[ADR 0005](../adr/0005-reopen-multi-provider-direction.md) 重新开放多 provider 方向，分两步：v0.2.4 已搭好 popover 顶部的 provider tab UI 外壳（Claude 可用，Codex/Cursor/Copilot/Gemini 是"敬请期待"占位）；本 spec 是第二步的第一刀 —— **把 Codex tab 从占位变成真的能看用量**，但只接 Codex 最稳的一条数据源（`~/.codex/auth.json` 里的 OAuth token → `https://chatgpt.com/backend-api/wham/usage`），CLI RPC / chatgpt.com Web / 本地 session JSONL 等其余路留作后续 patch 版本。

API 事实见调研 [`codex-data-sources.md`](../research/codex-data-sources.md)（直接读 CodexBar 源码整理）。

用户决策（2026-05-12）：① 本版本只打通一条数据源；② Codex tab 展示逻辑尽量和 Claude tab 一致；③ 凭证只读 `~/.codex/auth.json`，不做 app 内独立 OAuth 登录。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 数据源 | 仅 OAuth → `wham/usage` | 用户决策①；最轻最稳，CodexBar 也把它当首选路 |
| 凭证来源 | 只读 `~/.codex/auth.json`（尊重 `CODEX_HOME`），支持 `OPENAI_API_KEY` 与 `tokens.*` 两种形态 | 用户决策③；复用 codex CLI 已登录态，零配置 |
| Token 刷新 | **v0.2.5 不做主动刷新、不写回 auth.json**；401/403 → 提示用户跑 `codex` | "只读"硬约束；写回 auth.json 是另一回事（见 §5 风险 1），等用户反馈再决定 |
| Codex tab 展示 | 复用 v0.2.5 的 `ProviderUsageSection`：Session(5h) + Weekly(7d) 两张 `UsageHeroCard` + pace 标记 + Resets in；plan 徽章用 `ProviderUsageSnapshot.planLabel`；credits 余额走 `CreditLine`（需给它加一个"剩余余额"字段，见 §3.2） | 用户决策②；映射到统一 snapshot 后视图层零改动复用；pace 由 `reset_at` + `limit_window_seconds` 直接算，**无需历史样本** |
| Codex 趋势箭头 / 成本 / 热力图 | 不做 | 趋势需持久化历史样本（`UsageHistoryService`/`history.json` 目前仍是 Claude 专属）；成本/热力图是"本地 JSONL 扫描"那条数据源 —— 都不在本版本 |
| Codex 用量是否走 polling / 通知 / 多账号 | 不做后台 polling / 通知 / 多账号（`supportsBackgroundPolling = false`）；切到 Codex tab 时拉一次 + Refresh 按钮重拉；Settings「Primary Provider」选择器只列 `supportsBackgroundPolling` 的 provider（即本版本仍只有 Claude 能驱动菜单栏 label） | Codex 这条路没有后台轮询，让它驱动菜单栏会得到一个只在 popover 打开时才更新的陈旧 label；范围收敛 |
| Codex provider 实现 | 新增 `CodexProvider: UsageProvider`（`@MainActor`，持有 v0.2.5 的 `ProviderRuntime`），**不复用也不污染 `UsageService`**；注册进 `ProviderCoordinator(claude:additionalProviders:)` | `UsageService` 是 Claude 的 OAuth/refresh/polling/backoff/多账号 单一真相源；Codex 这条路完全不同。v0.2.5 抽象的整个目的就是让新 provider = 实现一个协议 + 注册 |

## 3. 设计（基于 v0.2.5 抽象）

v0.2.5 已落成的可复用件：`UsageProvider` 协议（`id` / `isConfigured` / `supportsBackgroundPolling` / `runtime` / `refreshNow()`）、`ProviderRuntime`（per-provider 的 `@Published snapshot/lastUpdated/lastError/isConfigured` + `setSuccess`/`setError(clearSnapshot:)`/`clear`/`setConfigured`）、`ProviderUsageSnapshot`/`UsageWindow`/`NamedUsageWindow`/`CreditLine` 统一形状、`ProviderRegistry` + `ProviderCoordinator(claude:additionalProviders:)`、popover 用量区 `ProviderUsageSection(runtime:)`、占位视图 `ProviderUnconfiguredView`/`ProviderComingSoonView`、`PopoverView.providerArea` 已对"已注册但非 Claude 的 provider"分 configured / unconfigured 两路渲染、`MenuBarLabel` 读主 provider 的 `ProviderRuntime`、Settings「Primary Provider」Picker。

⇒ Codex 落地 = **新增一个 `CodexProvider: UsageProvider` + 它的凭证/解码/HTTP 三个支撑文件 + 在装配处把它塞进 `additionalProviders` + 一处 Settings Picker 过滤 + 一处 popover 子视图抽取（顺带清掉 v0.2.5 G5 nit ②）**。视图层 / tab 切换 / coordinator / registry **主体复用、少量装配与观察链修补**（见 §3.2 —— 不是"零改动"：`PopoverView` 路由要从读 `provider.isConfigured` 改成读 `runtime.isConfigured`、`CreditLineRow` 要加分支、coordinator 要加 `primaryEligibleIDs`）。

### 3.1 新增文件（全部 `macos/Sources/ClaudeUsageBar/`）

| 文件 | 职责 |
|---|---|
| `CodexCredentials.swift` | `struct CodexCredentials { accessToken; refreshToken?; idToken?; accountId? }` + `enum CodexCredentialStore { static func load(environment:) throws -> CodexCredentials? }`：定位 `~/.codex/auth.json`（环境变量 `CODEX_HOME` 设了就用 `$CODEX_HOME/auth.json`），解析该 JSON —— 若**文件顶层**有 `OPENAI_API_KEY` 字段（注意：是 auth.json 里的 JSON key，不是进程环境变量）→ `accessToken` = 该值、其余 nil；否则取 `tokens.{access_token\|accessToken, refresh_token\|refreshToken, id_token\|idToken, account_id\|accountId}`。文件不存在 → 返回 `nil`（静默，不是错误）；存在但解析失败 / 既无 `tokens` 又无 `OPENAI_API_KEY` → throw `CodexCredentialError`（case 名只描述形态、不带 raw 值，SC7）。`internal`（非 private）让 `@testable import` 单测能直接 decode。只读：绝不创建/写回该文件。 |
| `CodexUsageModel.swift` | (a) `struct CodexUsageResponse: Decodable` —— `wham/usage` 的线缆形状：`plan_type → CodexPlan`（已知值的枚举 + `.unknown(String)`，都有 `displayName`）；`rate_limit.{primary_window, secondary_window} → CodexRateWindow { usedPercent: Double; resetAt: Date /* from Unix 秒 */; windowSeconds: Int }`；`credits → CodexCredits { hasCredits: Bool; unlimited: Bool; balance: Double? /* 接受数字或字符串数字 */ }`。每个子结构 try?-tolerant（坏字段不整体失败）。(b) `func normalizedWindows() -> (session: CodexRateWindow?, weekly: CodexRateWindow?)` —— 按 `windowSeconds/60 == 300`(5h) / `== 10080`(7d) 把 (primary, secondary) 摆正（抄 CodexBar `CodexRateWindowNormalizer` 思路；都不匹配时按出现顺序兜底）。(c) `func asProviderSnapshot() -> ProviderUsageSnapshot` —— session → `primaryWindow`（label `"Session"`，`windowDuration = TimeInterval(windowSeconds)`），weekly → `secondaryWindow`（label `"Weekly"`），`extraWindows = []`，`planLabel = plan.displayName`，`creditLine` = credits 映射（见 §3.2 对 `CreditLine` 的小扩展）。 |
| `CodexUsageClient.swift` | `enum CodexUsageClient { static func fetchUsage(credentials:, session: URLSession = .shared) async throws -> CodexUsageResponse }`：`GET https://chatgpt.com/backend-api/wham/usage`，headers `Authorization: Bearer <accessToken>`、`ChatGPT-Account-Id: <accountId>`（有才带）、`Accept: application/json`、`User-Agent: usage-bar`。`200..<300` → decode；`401/403` → `CodexUsageError.unauthorized`；其它非 2xx → `.server(status: Int)`（**不把 response body 拼进 error 文案**，避免泄漏）；URLError/解码失败 → `.network` / `.decode`（均不含凭证）。Endpoint 常量集中在此文件方便 mock；`session` 注入参数让单测用 `URLProtocol` stub。 |
| `CodexProvider.swift` | `@MainActor final class CodexProvider: UsageProvider` —— `let id = ProviderID.codex`；`let runtime = ProviderRuntime()`；`var isConfigured: Bool { runtime.isConfigured }`；`let supportsBackgroundPolling = false`。`func refreshNow() async`：(1) `try? CodexCredentialStore.load(environment:)` → `nil`（无凭证）：`runtime.setConfigured(false)` + `runtime.clear()`，return；load 自身 throw（auth.json 损坏）：`runtime.setConfigured(false)` + `runtime.setError("未检测到有效的 Codex 凭证，请在终端运行 `codex` 登录", clearSnapshot: true)`，return。(2) 有凭证：`runtime.setConfigured(true)` → `CodexUsageClient.fetchUsage` → 成功：`runtime.setSuccess(snapshot: response.asProviderSnapshot())`；`.unauthorized`：`runtime.setError("Codex 凭证已过期，请运行 `codex` 重新登录", clearSnapshot: true)`（**不主动刷新、不写回 auth.json**——只读硬约束，见 §5 风险 1）；`.server/.network/.decode`：`runtime.setError("无法获取 Codex 用量（稍后重试）", clearSnapshot: false)`（保留旧 snapshot）。可选：`init` 里同步做一次"auth.json 文件是否存在"的轻量探测，先把 `runtime.isConfigured` 设对（不发网络）；不做也行——切到 tab 时 `.task` 立刻 `refreshNow`。无 Timer、无 backoff、无节流（范围收敛；切 tab + Refresh 触发足够）。 |
| 单测 `macos/Tests/ClaudeUsageBarTests/CodexProviderTests.swift` | 见 §3.4。 |

### 3.2 改动现有文件

| 文件 | 改动 |
|---|---|
| `ProviderUsageSnapshot.swift` | 给 `CreditLine` 加两个 optional 字段：`var remainingAmount: Double?`（Codex `credits.balance` —— 剩余余额，与 Claude 的"已用/上限"语义不同，所以单列）和 `var isUnlimited: Bool = false`（Codex `credits.unlimited`）。memberwise init 补默认值，Claude 路径调用点不受影响。 |
| `ProviderUsageSection.swift` | `CreditLineRow`：(a) 标题不再硬编码 `"Extra Usage"`——Claude 路径仍叫 "Extra Usage"，但当 `remainingAmount`/`isUnlimited` 在用时（Codex）标题用 "Credits"（可传一个 `title: String` 进去，或按字段语义分支）；(b) 渲染分支补：`isUnlimited` → "Unlimited"；否则 `remainingAmount != nil` → "$X.XX 剩余"（用 `ExtraUsage.formatUSD`）；否则维持现有 `usedAmount`/`limitAmount`+ `utilizationPct` 渲染（Claude 路径，行为不变）。 |
| `PopoverView.swift` | 把 `providerArea` 里"已注册非 Claude provider"那一大段（**含 configured / unconfigured 的判定**）抽成一个 `private struct ProviderUsageArea: View { @ObservedObject var runtime: ProviderRuntime; let providerID: ProviderID; … }`——**关键：configured-vs-unconfigured 的判定从 `coordinator.provider(id)?.isConfigured` 改为读 `runtime.isConfigured`**（`@Published`，子视图观察得到），否则子视图观察了 runtime、父视图却还按旧属性决定是否挂载它，等于没修。`PopoverView` 里只负责"已注册非 Claude → 渲染 `ProviderUsageArea(runtime: coordinator.runtime(for: id)!, …)`"。这样 `runtime.isConfigured`/`snapshot`/`lastError` 变化能正确驱动该子树重渲染（当前写法靠 `PopoverView.body` 重渲染才会重算 `providerArea`，而切 tab 后 `runtime` 变化不必然触发 `PopoverView` 重渲染——v0.2.5 G5 nit ② 记的就是这个）。`bottomBar`/`settingsButton` 复用方式按实现期最简处理（传闭包或抽 shared 子视图皆可）。Claude 分支与 `.task(id:)` 拉取逻辑不变。 |
| `ProviderCoordinator.swift` | (a) 加 `var primaryEligibleIDs: [ProviderID] { availableIDs.filter { registry.provider($0)?.supportsBackgroundPolling == true } }`；(b) 构造时若 `stored` 不在 `primaryEligibleIDs` 里则回退 `.claude`（当前是判 `isAvailable`，收紧成 eligible）；(c) **`primaryProviderID` 的 `didSet`（或换成带校验的 setter）拒绝非 eligible 值**——不能光在构造时校验、运行时还能被赋成 `.codex` 写进 UserDefaults。（视图层目前没有写 `primaryProviderID` 为 Codex 的路径——Settings Picker 过滤后给不出这个值——但 invariant 要在 model 层封死。） |
| `SettingsView.swift` | 「Primary Provider」Picker 的 `ForEach` 数据源从 `coordinator.availableIDs` 改成 `coordinator.primaryEligibleIDs`；`.disabled(...)` 与那条 caption 的条件相应改成 `primaryEligibleIDs.count <= 1`。本版本结果：Codex 出现在 popover tab 里，但不出现在「驱动菜单栏的 provider」选项里。 |
| `ClaudeUsageBarApp.swift` | `ProviderCoordinator(claude: UsageService())` → `ProviderCoordinator(claude: UsageService(), additionalProviders: [CodexProvider()])`。其余装配不变（`MenuBarLabel(runtime: coordinator.primaryRuntime, …)` 仍只可能是 Claude 的 runtime）。 |

不动：`UsageService` / `UsageHistoryService` / `NotificationService` / `UsageEventStore` / `UsageStatsService` / `MenuBarLabel` / `ProviderTabBar` / `ProviderRegistry` / `UsageHeroCard` / `UsageModel.swift` 的 Claude 映射 —— Codex 这条路完全旁路它们。

### 3.3 数据流

```
切到 Codex tab
  → PopoverView .task(id: selectedProvider)  (已有逻辑：非 Claude 可用 provider → coordinator.refreshNow(id))
     → CodexProvider.refreshNow()
        → CodexCredentialStore.load(environment:)   (读 ~/.codex/auth.json，CODEX_HOME 优先；只读)
           ├ nil      → runtime.setConfigured(false) + clear()  → ProviderUsageArea 渲染 ProviderUnconfiguredView（"运行 codex 登录"）
           ├ throws   → runtime.setConfigured(false) + setError(…, clearSnapshot: true)
           └ creds    → runtime.setConfigured(true) → CodexUsageClient.fetchUsage(creds)
                          GET chatgpt.com/backend-api/wham/usage   (Bearer + ChatGPT-Account-Id)
              ├ 200          → CodexUsageResponse → asProviderSnapshot() → runtime.setSuccess(snapshot)
              │                  → ProviderUsageArea → ProviderUsageSection: Session/Weekly 两卡（usedPercent + pace from reset_at & windowSeconds）+ plan 徽章 + credits 行
              ├ 401/403      → runtime.setError("Codex 凭证已过期，请运行 codex 重新登录", clearSnapshot: true)
              └ 其它/网络/解码 → runtime.setError("无法获取 Codex 用量（稍后重试）", clearSnapshot: false)  (留旧 snapshot)
点 popover "Refresh"  → coordinator.refreshNow(.codex)  → 同上（强制重拉）
菜单栏 label：不受影响——primaryProviderID 仍只能是 Claude（Codex 不在 primaryEligibleIDs）
```

### 3.4 测试方案

`CodexProviderTests`（纯单元，无真实网络 / Keychain / `~/.codex`；HTTP 用 `URLProtocol` stub，仿 `ProviderAbstractionTests.StubURLProtocol`）：

- **凭证解析**（喂 fixture `Data`）：
  - ⚠️ SC7：**不要** `XCTAssertEqual(creds.accessToken, "<fake-token>")`——失败 diff 会把假 token 打进测试输出（违反 SC7 的"测试失败输出不含 raw token"）。改用一个测试内 helper：把 fixture 里塞的是**可逆但不像真 token 的哨兵串**（如 `"ACCESS_SENTINEL"`），断言时用 `XCTAssertEqual(redact(creds.accessToken), redact("ACCESS_SENTINEL"))` 这种——或更简单：fixture token 用明显的哨兵值 + 断言 `creds.accessToken?.hasSuffix("…")` / `== sentinel` 时**只在该 case 自定义 `XCTAssertEqual` 的 message** 用掩码后的值。核心：测试源码与失败输出里都不出现像真凭证的串。
  - OAuth 形态 snake_case（用哨兵值）→ `accessToken/refreshToken/idToken/accountId` 四个字段都映射到对应哨兵
  - camelCase 形态 → 同上
  - 仅 `OPENAI_API_KEY` → `accessToken` == 该哨兵，其余 nil
  - 缺 `tokens` 且无 `OPENAI_API_KEY` → throw（断言具体 case）
  - 非法 JSON → throw
  - 文件不存在 → `load` 返回 `nil`（用临时空目录 + `CODEX_HOME` 注入验证）
  - `CODEX_HOME` 注入 → 路径指向 `$CODEX_HOME/auth.json`（`load(environment:)` 直接吃一个注入的 `[String:String]`，无需 DEBUG-only 钩子）
- **响应解码 + 映射**：
  - 全量 fixture（`plan_type=plus`、primary `limit_window_seconds=18000`、secondary `604800`、`reset_at` 给定 Unix 秒、`credits.balance` 数字）→ 两窗口 `usedPercent`/`resetAt`(`== Date(timeIntervalSince1970:)`)/`windowSeconds` 正确、`plan == .plus`；`asProviderSnapshot()` → `primaryWindow.label == "Session"`、`windowDuration == 18000`、`secondaryWindow.label == "Weekly"`、`planLabel == "Plus"`、`creditLine?.remainingAmount` 正确
  - primary/secondary 顺序颠倒（primary 是 604800）→ `normalizedWindows()` 把 session/weekly 摆正 → snapshot 仍 Session=5h、Weekly=7d
  - 只有一个窗口 → 另一个 `nil`（snapshot 对应 window 为 `nil`）
  - `credits.balance` 是字符串 `"12.34"` → `12.34`；`credits.unlimited == true` → snapshot `creditLine?.isUnlimited == true`
  - 未知 `plan_type`（如 `"galaxy_brain"`）→ `.unknown("galaxy_brain")`，`displayName` 不崩、`planLabel` 非空
  - 缺 `rate_limit` 整段 / 缺 `credits` → 仍解码成功、对应字段 `nil`
- **`CodexProvider.refreshNow()` 行为**（注入 stub `CodexCredentialStore` 结果 + stub `URLSession`）：
  - 无凭证 → `runtime.isConfigured == false`、`snapshot == nil`、`lastError == nil`
  - 有凭证 + 200 → `runtime.isConfigured == true`、`snapshot != nil`、`lastUpdated != nil`、`lastError == nil`
  - 有凭证 + 401 → `lastError` 非空且**不含**注入的假 token 串、`snapshot == nil`（clearSnapshot）
  - 有凭证 + 500（先成功一次再 500）→ `lastError` 非空、`snapshot` 仍是上一次的（保留）
- **SC7 红线**：构造一个 `CodexUsageError`/`CodexCredentialError` 含（间接经手的）假 token，断言 `"\($0)"` / `.localizedDescription`（若 `LocalizedError`）不含该串；测试里也 `grep` 不到把凭证插值进文案（grep 那条放 §SC7 evidence，不在单测里）。

CI 仍跑 `swift build -c release` + `swift test` + `make release-artifacts`，全绿。

## 4. 文件迁移动作汇总

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/ClaudeUsageBar/CodexCredentials.swift` | 只读 `~/.codex/auth.json`（尊重 `CODEX_HOME`） |
| 🆕 | `macos/Sources/ClaudeUsageBar/CodexUsageModel.swift` | 线缆形状 + `normalizedWindows()` + `asProviderSnapshot()` |
| 🆕 | `macos/Sources/ClaudeUsageBar/CodexUsageClient.swift` | `GET wham/usage`，错误不含凭证/ body |
| 🆕 | `macos/Sources/ClaudeUsageBar/CodexProvider.swift` | `CodexProvider: UsageProvider`（`supportsBackgroundPolling = false`） |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/CodexProviderTests.swift` | §3.4 |
| 🔧 | `macos/Sources/ClaudeUsageBar/ProviderUsageSnapshot.swift` | `CreditLine` 加 `remainingAmount?` / `isUnlimited` |
| 🔧 | `macos/Sources/ClaudeUsageBar/ProviderUsageSection.swift` | `CreditLineRow` 补 unlimited / remaining 分支 |
| 🔧 | `macos/Sources/ClaudeUsageBar/PopoverView.swift` | 抽 `ProviderUsageArea`（`@ObservedObject runtime`）—— 顺带清 v0.2.5 G5 nit ② |
| 🔧 | `macos/Sources/ClaudeUsageBar/ProviderCoordinator.swift` | 加 `primaryEligibleIDs`；stored 校验收紧成 eligible |
| 🔧 | `macos/Sources/ClaudeUsageBar/SettingsView.swift` | Primary Provider Picker 数据源 → `primaryEligibleIDs` |
| 🔧 | `macos/Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift` | `additionalProviders: [CodexProvider()]` |
| ✅ 不动 | `UsageService.swift` 等 Claude 链路、`ProviderRegistry`、`ProviderTabBar`、`MenuBarLabel`、`UsageHeroCard` | Codex 旁路；tab 可用性由 registry 注册自动生效 |

## 5. 风险 / Open questions

1. **不刷新 token → Codex tab 可能频繁"过期"**。access_token JWT 的 `exp` 未知；若只有几小时，不常跑 `codex` 的用户会经常看到过期提示。缓解：v0.2.6 先这样，文案明确给出修复动作（"运行 `codex` 重新登录"）；若反馈差，后续版本加"401 时用 refresh_token 刷新 **并写回 auth.json**"（写回是必须的——否则轮换后的 refresh_token 会让 codex CLI 自己失效，见调研 §3）。**这一点请 G2 reviewer 判断：是否值得在本版本就做带写回的刷新；本 spec 默认不做（"只读"硬约束 + 用户决策③）。**
2. **`wham/usage` 接口未来漂移**：字段名/路径变了会静默坏。缓解：解码 try?-tolerant；坏了显示通用 error 而非崩溃。和 Claude `/api/oauth/usage` 同等脆弱性，可接受。
3. **`~/.codex/config.toml` 的 `chatgpt_base_url` 覆盖**：本版本不解析 config.toml，固定打 `chatgpt.com/backend-api`。极少数自托管/代理用户会拿不到——可接受，后续按需补。
4. **`CreditLine` 语义拼接**：给它加 `remainingAmount`/`isUnlimited` 是为了不丢 Codex 的余额信息，但 `CreditLine` 现在同时承载"Claude：已用/上限"与"Codex：剩余/无限"两套语义，`CreditLineRow` 靠"哪个字段非 nil"分支。可接受（字段都 optional、互不干扰），但若将来第三个 provider 又来一套不同语义，应考虑把它拆成 enum。留 G2 判断当前折中是否 OK。
5. **`primaryEligibleIDs` 把 Codex 挡在菜单栏之外**：用户能在 popover 看 Codex，但不能让它驱动菜单栏 label（因为没后台 polling）。这是有意的——一个只在 popover 打开时更新的菜单栏数字会误导人。等 Codex 加了后台 polling（§6）再放开。

## 6. 后续工作（不在本 spec 范围）

- Codex token 刷新 + 写回 `~/.codex/auth.json`（或独立缓存）
- Codex CLI RPC（`codex app-server`）/ chatgpt.com Web 兜底路
- Codex 本地 session JSONL 扫描 → 成本/token（喂 v0.2.3 的 per-provider `UsageEventStore` + 热力图）
- Codex 历史样本持久化 → 趋势箭头 + 后台 polling + 阈值通知
- Codex 多账号
- Cursor / Copilot / Gemini provider（仍是占位，按需求再排）

## 7. 引用

- 相关调研：[`../research/codex-data-sources.md`](../research/codex-data-sources.md)、[`../research/competitive-analysis.md`](../research/competitive-analysis.md)
- 相关 ADR：[`../adr/0005-reopen-multi-provider-direction.md`](../adr/0005-reopen-multi-provider-direction.md)
- 落地版本：[`../versions/v0.2.6-codex-provider.md`](../versions/v0.2.6-codex-provider.md)
- 前置 spec：[`2026-05-12-multi-provider-refactor.md`](./2026-05-12-multi-provider-refactor.md)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence（详见 frontmatter `spec_criteria`）。

- [x] SC1 — 数据路径 + ProviderUsageSection 复用；UI 待用户目测确认
- [x] SC2 — testProviderNoCredentials + ProviderUnconfiguredView .codex 文案
- [x] SC3 — testProviderUnauthorizedClearsSnapshot / testProviderServerErrorKeepsSnapshot
- [x] SC4 — CodexCredentialStore 只读 + CODEX_HOME；testLoadRespectsCodexHome
- [x] SC5 — CodexProviderTests 23 用例（解析 / 解码+映射 / 归一）
- [x] SC6 — PopoverView .task + bottomBar Refresh；Claude 链路未改 + 200 测试绿
- [x] SC7 — error description 无 raw 值（测试断言）+ grep 无凭证插值；fixture 用哨兵值
