---
id: 2026-05-14-claude-credentials-in-memory
title: Claude 凭证改 in-memory only —— 永不存盘、永不主动 refresh
status: draft
created: 2026-05-14
updated: 2026-05-14T10:00:00+08:00
owner: claude-code
model: claude-opus-4-7
target_version: v0.5.1-claude-credentials-in-memory
related_adrs:
  - 0005-reopen-multi-provider-direction
related_research: []
spec_criteria:
  - id: SC1
    criterion: 启动时 Keychain 有有效 token → 5 min 内首次 fetchUsage 成功，popover 显示数据
    done: false
    evidence: null
  - id: SC2
    criterion: 启动时 Keychain 无 / 无 ACL 授权 → popover 显示 "Sign in with Claude CLI, tap Retry"；Retry 触发 `allowInteraction=true`
    done: false
    evidence: null
  - id: SC3
    criterion: Keychain access_token 已过期且 CLI 未刷新 → fetchUsage 收 401 → 清 cache → 重读 Keychain 仍同 token → setError "Token expired; run `claude` to refresh."；不无限 retry
    done: false
    evidence: null
  - id: SC4
    criterion: issue #22 回归不再现 —— CLI 触发 OAuth rotation 写新 token → usage-bar 下一 polling tick 自动用新 token，无掉线
    done: false
    evidence: null
  - id: SC5
    criterion: 真机：清 `~/.config/usage-bar/accounts.json` + `credentials.json` 后启动 app → 30s 内 popover 自动从 Keychain 恢复；旧文件不被重新创建
    done: false
    evidence: null
  - id: SC6
    criterion: 代码层 — usage-bar 进程不再向 `~/.config/usage-bar/credentials.json` / `accounts.json` 写入任何内容（grep + 真机文件创建时间戳验证）
    done: false
    evidence: null
  - id: SC7
    criterion: UI — popover 顶部不再有 AccountSwitcherView（无 email、无下拉菜单）
    done: false
    evidence: null
  - id: SC8
    criterion: swift test 全绿（多账号 / refresh 用例退役、新增 in-memory cache 用例）
    done: false
    evidence: null
  - id: SC9
    criterion: `make release-artifacts` + `verify-release.sh` 全绿
    done: false
    evidence: null
  - id: SC10
    criterion: CHANGELOG v0.5.1 entry 说明 "removed local credentials persistence; multi-account UI retired"
    done: false
    evidence: null
automated_checks:
  - "SC_AUTO_BUILD: swift build -c release"
  - "SC_AUTO_TEST: swift test"
  # 正向 grep —— 命中即失败（说明仍有持久化写入路径）
  - "SC_AUTO_GREP_NO_CREDS_WRITE: ! grep -rEn 'accounts\\.json|credentials\\.json|\\.write\\(to: *credentialsFileURL' macos/Sources/UsageBar/ --include='*.swift'"
  - "SC_AUTO_GREP_NO_ACCOUNT_VIEW: ! grep -rn 'AccountSwitcherView' macos/Sources/UsageBar/ --include='*.swift'"
  - "SC_AUTO_GREP_NO_STORE_TYPE: ! grep -rn 'StoredCredentialsStore\\|StoredAccount\\b' macos/Sources/UsageBar/ --include='*.swift'"
  - "SC_AUTO_RELEASE: make release-artifacts && bash macos/scripts/verify-release.sh macos/UsageBar.zip"
manual_checks:
  - "真机 SC1: Keychain 有有效 token 时启动 app，5 min 内 popover 出数"
  - "真机 SC2: 清掉 Keychain item（security delete-generic-password -s 'Claude Code-credentials'）后启动，popover 显示 Not signed in"
  - "真机 SC3: 模拟 Keychain token 过期（手改 expiresAt 至过去）→ popover 显示 Token expired 提示"
  - "真机 SC5: 清 ~/.config/usage-bar/accounts.json + credentials.json 后启动 app，30s 内恢复数据"
reviews:
  - round: 1
    reviewer: general-purpose-subagent
    verdict: approved-after-revisions
    notes: 4 条 required 已闭环 — §3.4 补 `isAwaitingCode` + `expireSessionOnAuthFailure` 参数 + PopoverView 文档注释；§3.6 列出具体测试方法名；automated_checks 改正向 grep；§5 #2 directoryURL 决策明确 + §6 加 AppPaths follow-up；§6 加 CONTRIBUTING.md mock-server 联动 follow-up。
  - round: 2
    reviewer: pending
    verdict: pending
---

# Claude 凭证改 in-memory only —— 永不存盘、永不主动 refresh

## 1. 背景与目标

### 1.1 触发事件

2026-05-14 用户反馈：app 长时间持续显示 "Not signed in"，Retry 按钮无效。systematic-debugging 定位根因：

- `expireSession()` 通过 `deleteCredentials()` 删 `credentials.json`，但 `accounts.json` 保留。
- 重启 app：`UsageService.init` 读 `accounts.json` 看非空 → `isAuthenticated = true` 短暂态；首轮 `fetchUsage()` 发现 `loadCredentials() == nil` 立即切回 `"Not signed in"`。
- 用户点 Retry 调 `bootstrapFromCLIIfNeeded()`，被 `if !accounts.isEmpty { return }` short-circuit，即使 Claude CLI Keychain 此刻有有效 token 也用不上。

### 1.2 既有架构的累积复杂度

- **v0.1.1** 引入 Claude CLI Keychain 复用（bootstrap path）
- **v0.1.3** 引入多账号（StoredAccount[]、activeAccountId、accountSwitchEpoch、currentFetchTask、双写 v1+v2）
- **v0.2.7** 引入 attemptCLIKeychainRecovery（refresh 永久失败时回退 Keychain）
- **issue #22 (v0.3+)** 引入 strippingRefreshToken + migrateStripCLIRefreshToken（避免持有 CLI refresh_token 触发 rotation）

每次都是补丁式叠加，UsageService 累积到 ~900 行，"信用谁的 credentials" 在 3 个层（accounts.json / credentials.json / Keychain）之间打架。本次 Retry 失效正是这个累积复杂度的边缘 bug。

### 1.3 目标

把 Claude 凭证从 "usage-bar 自管理 + CLI 后备" 改为 "纯 CLI 借读 + in-memory cache"。一刀切：
- usage-bar 永不向磁盘写入凭证
- usage-bar 永不主动 refresh token（refresh 完全交给 Claude CLI；CLI rotation 后写新 token 到 Keychain，usage-bar 下一 polling tick 拿到）
- 多账号下线（多账号 = 多 provider，单 provider 内不维护多账号 fiction）

非目标：
- 不改 Codex / Gemini provider（它们本就是 in-memory only，本 spec 借鉴它们的架构）
- 不动 Sparkle / 公证 / 价格表逻辑
- 不自动迁移旧用户磁盘文件（用户自行删；代码不读、不写）

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 凭证存储 | in-memory `StoredCredentials?` cache，不存盘 | 用户原话；彻底免 issue #22 同类问题 |
| Refresh 职责 | usage-bar 不主动 refresh，完全交给 Claude CLI | 避免双方各自 rotate 互相 invalidate（issue #22 病根）；usage-bar 只读 Keychain |
| 多账号 | 整体下线（StoredAccount / activeAccountId / AccountSwitcherView 全删）| 用户表态 "多账号 = 多 provider，不考虑同 provider 内多账号"；Claude CLI Keychain 只 1 个 item，多账号本就是 usage-bar 内部 fiction |
| Token 缓存策略 | Approach A：内存 cache + 过期重读 | brainstorming Q5 用户选；省 Keychain IO 但状态机简单 |
| 旧磁盘文件 | 代码不读不写；用户自行删 | 用户原话；代码不带迁移逻辑、不留 deprecation 路径 |
| target version | v0.5.1（抢 v0.5.x 号名，v0.5.0 仍为 observable-migration 占位） | 用户表态；行为变化显著但与 v0.5.0 正交 |

## 3. 设计

### 3.1 行为契约

| 维度 | v0.5.1 前 | v0.5.1 后 |
|---|---|---|
| 凭证来源 | `~/.config/usage-bar/credentials.json` + `accounts.json` 持久化 | 完全不存盘；in-memory cache + 从 CLI Keychain 重读 |
| Refresh | usage-bar 自己用 refresh_token 调 OAuth token endpoint | 删除；交给 CLI |
| 多账号 UI | AccountSwitcherView 显示 email + 切换/加账号 | 整体下线 |
| 401 处理 | 内置 OAuth refresh → 失败 → expireSession → 删 credentials.json | 清内存 cache → 重读 Keychain → 仍同 token 即报 "Token expired" |
| Retry 按钮 | bootstrapFromCLIIfNeeded（`accounts.isEmpty` 短路）| retrySignIn — 无短路条件，强制重读 Keychain（`allowInteraction=true`）|

### 3.2 状态机 + 数据流

```
                ┌────────────────────────────────────┐
                │ UsageService                       │
                │   private var inMemoryCredentials: │
                │                StoredCredentials? │
                └──────────────┬─────────────────────┘
                               │
   ┌───────────────────────────┴───────────────────────────────┐
   │ ensureFreshCredentials(allowInteraction: Bool) async      │
   │     -> StoredCredentials?                                 │
   │                                                            │
   │ if let c = inMemoryCredentials, !c.isExpired():           │
   │     return c                                              │
   │ creds = await ClaudeCLICredentialsStrategy()              │
   │            .loadCredentials(allowInteraction: ...)        │
   │ inMemoryCredentials = creds                               │
   │ runtime.setConfigured(creds != nil)                       │
   │ isAuthenticated = (creds != nil)                          │
   │ return creds                                              │
   └────────────────────────────────────────────────────────────┘
                               │
                               ▼
            ┌────────────────────────────────┐
            │  fetchUsage()                  │
            └──────────────┬─────────────────┘
                           │
   creds = await ensureFreshCredentials(allowInteraction: false)
   ├── nil → runtime.setError("Sign in with Claude CLI, tap Retry") → return
   └── send GET usageEndpoint w/ Bearer creds.accessToken
        ├── 200 → runtime.setSuccess + history + notify
        ├── 401 → inMemoryCredentials = nil
        │        retried = await ensureFreshCredentials(allowInteraction: false)
        │        ├── retried == nil 或 retried.accessToken == creds.accessToken
        │        │   → runtime.setError("Token expired; run `claude` to refresh.") → return
        │        └── retried != nil → 再发一次；仍 401 → 同上 error
        ├── 429 → 既有 backoff 路径不变（backoffUntil / currentBackoffSeconds）
        └── 其它 → runtime.setError + 既有路径
```

### 3.3 触发 ensureFreshCredentials 的 3 个时机

| 时机 | allowInteraction | 入口 |
|---|---|---|
| 每次 fetchUsage 之前 | `false`（后台 polling 安全；ACL prompt 不允许）| `fetchUsage` 内部 |
| Retry 按钮 / 启动时 | `true`（前台用户操作；允许首次 ACL prompt）| `UsageService.retrySignIn()` 新公开方法 |

启动时 `UsageBarApp .task` 把现有 `bootstrapFromCLIIfNeeded()` 调用换成 `retrySignIn()`（语义更准）。

### 3.4 删 / 留代码清单

**删除**

| 文件 / 字段 / 方法 | 备注 |
|---|---|
| `Features/Popover/AccountSwitcherView.swift` | 整文件 |
| `Models/StoredAccount.swift` | 整文件（StoredAccount / StoredAccountsFile）|
| `Models/StoredCredentials.swift` 中 `StoredCredentialsStore` 类 | 整 class（无写入者），仅留 `StoredCredentials` struct 与 helpers |
| `UsageService.accounts`, `activeAccountId`, `accountSwitchEpoch`, `currentFetchTask`, `accountEmail`, `refreshTask` | 多账号 + refresh 状态 |
| `UsageService.switchAccount`, `addAccount`, `migrateStripCLIRefreshToken`, `attemptCLIKeychainRecovery`, `expireSession`, `refreshCredentials`, `performRefresh`, `credentials(from:fallback:)`, `expirationDate(from:)`, `fetchProfile`, `bootstrapFromCLIIfNeeded` | OAuth + 账号管理函数 |
| `UsageService.tokenEndpoint`, `userinfoEndpoint`, `redirectUri`, `clientId`, `defaultOAuthScopes`, `codeVerifier`, `oauthState` | OAuth client 常量 + PKCE 状态 |
| `UsageService.@Published var isAwaitingCode` | PKCE flow 已退役（addAccount 删）；此字段无消费者 |
| `UsageService` 整段 "OAuth & Credentials" / "Refresh + Token rotation" extension | |
| `sendAuthorizedRequest(...).expireSessionOnAuthFailure` 参数 | expireSession 删除后该参数失去意义，连同 4 处调用点 signature 简化 |
| `PopoverView` 内 `AccountSwitcherView` 引用 + `claude.accounts` 分支 + 头部 `@ObservedObject` 文档注释中对 `accounts` / `isAwaitingCode` 的引用 | 文档注释 + 实际引用一并清 |

**新增**

| 位置 | 内容 |
|---|---|
| `UsageService` | `private var inMemoryCredentials: StoredCredentials?` |
| `UsageService` | `private func ensureFreshCredentials(allowInteraction: Bool) async -> StoredCredentials?` |
| `UsageService` | `func retrySignIn() async`（公开；Retry 按钮 + 启动 task 用）|

**保留 / 调整**

- `StoredCredentials` struct（in-memory 表示用）+ `isExpired` / `needsRefresh` / `hasRefreshToken` / `strippingRefreshToken` helpers
- `ClaudeCLICredentialsStrategy`（唯一通向凭证的接口）
- `UsageService` 的 fetchUsage / usageEndpoint / runtime / 429 backoff / pollingMinutes / onPollTick / nextEligibleRefresh
- `isAuthenticated` `@Published` 字段保留 — 作为 `runtime.isConfigured` 的同义投影；PopoverView 已经依赖它，破坏成本不必要
- `ProviderCoordinator` 不动；统一 polling timer 行为不变

### 3.5 UI 改动

- `PopoverView.swift`：
  - `body` 内 `if claudeEnabled && !claude.isAuthenticated { NotAuthenticatedView(...) }` 分支保留
  - 删除 `if claudeEnabled { AccountSwitcherView(service: claude) }` 行
  - `NotAuthenticatedView` 的 Retry 按钮 action 由 `coordinator.claude.bootstrapFromCLIIfNeeded()` 换成 `coordinator.claude.retrySignIn()`
- `AccountSwitcherView.swift`：整文件删除（含相关 import）

### 3.6 测试方案

**删除（具体）**
- `UsageServiceMultiAccountTests.swift` — 整文件
- `StoredCredentialsStoreMigrationTests.swift` — 整文件（测的是被删的 v1→v2 迁移）
- `UsageServiceTests.swift` 内（按方法名）：
  - `testFetchProfile*`（fetchProfile 路径）
  - `testRefreshToken*`、`testPerformRefresh*`（performRefresh 路径）
  - `testExpireSession*`、`testAttemptCLIKeychainRecovery*`、`testBootstrapFromCLI*`、`testMigrateStripCLIRefreshToken*`
  - `testSendAuthorizedRequest*Refresh*` 凡涉及 OAuth refresh 重试链路的用例
  - 上述 case 涉及 mock 的 `tokenEndpoint`/`userinfoEndpoint` 注入也一并退役

**新增 / 改造**
- `UsageServiceCredentialsTests`（新文件）：
  - `testEnsureFreshCredentialsCacheHit` — cache 非空且未过期 → 不走 keychain loader
  - `testEnsureFreshCredentialsCacheExpiredReloadsKeychain` — cache 过期 → 调 loader
  - `testEnsureFreshCredentialsKeychainEmptyClearsState` — loader 返回 nil → cache=nil + isConfigured=false
  - `testFetchUsage401ClearsCacheAndRetriesOnce` — 第一次 401 → 清 cache → 重新 fetch → 200
  - `testFetchUsage401SameTokenReportsExpired` — 重读 keychain 拿到同 token → setError "Token expired"
  - `testRetrySignInForcesKeychainReload` — Retry 按钮 force allowInteraction=true（mock loader 断言）

mock：注入 `cliKeychainLoader: () async -> StoredCredentials?` 现已存在，复用即可。

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `docs/versions/v0.5.1-claude-credentials-in-memory.md` | 新版本文档 |
| 🆕 | `macos/Tests/UsageBarTests/UsageServiceCredentialsTests.swift` | in-memory cache + 401 retry 用例 |
| 🔧 | `macos/Sources/UsageBar/Providers/Claude/UsageService.swift` | 大幅瘦身 ~900 → ~300 行；删 OAuth/多账号；加 ensureFreshCredentials + retrySignIn |
| 🔧 | `macos/Sources/UsageBar/Models/StoredCredentials.swift` | 删 StoredCredentialsStore 类；留 StoredCredentials struct + helpers |
| 🔧 | `macos/Sources/UsageBar/Features/Popover/PopoverView.swift` | 删 AccountSwitcherView 引用；NotAuthenticatedView.Retry 换 action |
| 🔧 | `macos/Sources/UsageBar/App/UsageBarApp.swift` | 启动 task：`bootstrapFromCLIIfNeeded` → `retrySignIn` |
| 🔧 | `docs/versions/README.md` | 表格加 v0.5.1 行 |
| 🔧 | `CHANGELOG.md` | v0.5.1 entry：removed local credentials persistence; multi-account retired |
| ❌ | `macos/Sources/UsageBar/Features/Popover/AccountSwitcherView.swift` | 整文件删 |
| ❌ | `macos/Sources/UsageBar/Models/StoredAccount.swift` | 整文件删 |
| ❌ | `macos/Tests/UsageBarTests/UsageServiceMultiAccountTests.swift` | 整文件删 |
| ❌ | `macos/Tests/UsageBarTests/StoredCredentialsStoreMigrationTests.swift` | 整文件删 |
| ✅ 不动 | `macos/Sources/UsageBar/Providers/Claude/ClaudeCLICredentialsStrategy.swift` | 唯一通向凭证的接口；保留 |
| ✅ 不动 | `macos/Sources/UsageBar/Services/ProviderCoordinator.swift` | 统一 polling timer 不变 |
| ✅ 不动 | Codex / Gemini provider | 本来就是 in-memory，不动 |

## 5. 风险 / Open questions

1. **v0.1.3 多账号用户升级体验**：升级后只能用 Claude CLI 当前 active 账号；其他账号需在 Claude CLI 切换。CHANGELOG 明示。
   - **风险**：低（Claude CLI 本身只支持 1 个 active session；多账号 v0.1.3 本就 fiction）
2. **删 `StoredCredentialsStore` 后 `directoryURL` 是否要提取为共享常量**：
   - **现状**：`UsageHistoryService`、`UsageEventStore`、`ScanCursorStore`、`ModelPricingCatalog` 等多处**各自**实现 `homeDirectoryForCurrentUser/.config/usage-bar`，未共享 `StoredCredentialsStore.directoryURL`。
   - **决策**：本 spec 不做提取（避免 scope 蔓延）；`StoredCredentialsStore` 整类删除后，其它服务原样维持各自常量。"提取 `AppPaths.configDirectory` 共享常量" 列为 follow-up（§6）。
3. **新增 ACL prompt 触发频率**：Retry 按钮走 `allowInteraction=true`，可能在某些用户场景频繁触发授权框。
   - **缓解**：ACL prompt 一旦 Always Allow 不再重弹；Retry 是用户主动操作，prompt 可接受。
4. **测试覆盖 OAuth refresh 路径退役后的回归保护**：旧 OAuth refresh tests 删除后失去对该路径的回归保护，但路径本身被删除，无需保护。
   - **缓解**：SC4 显式覆盖 "issue #22 不再现" 行为路径。
5. **Hard gates 评估**（AGENTS.md §5）：
   - 凭证 / 密钥操作：❌ 不涉及（不动 Apple Dev / Sparkle / GitHub PAT / 公证证书）
   - 引入新依赖 / 改 LICENSE：❌
   - 同 gate ≥2 轮分歧：待 G2/G3
   - 24h 发版后 health 报警：待 G7
   - 违反既有 ADR：❌（v0.1.3 是 version spec 非 ADR；ADR 0005 多 provider 方向无冲突）
   - 法律 / 合规：❌

**结论**：无 hard gate 触发，走标准 G1→G7 主回路。

## 6. 后续工作（不在本 spec 范围）

- v0.5.0 observable-migration（独立 spec / 占位中）
- 旧用户 `~/.config/usage-bar/accounts.json` 自动清理 utility（用户表态自行处理）
- **提取 `AppPaths.configDirectory` 共享常量**：HistoryService / EventStore / ScanCursorStore / ModelPricingCatalog 等当前各自维护 `~/.config/usage-bar` 路径，统一到单一常量；本 spec 实施后立即做（小 patch）。
- **ADR 0007 候选**：「usage-bar 不再是 OAuth client，只是 CLI Keychain 借读方」—— 本 spec merge 后立即触发 follow-up（review 建议），避免下个 provider 重复辩论。
- `CONTRIBUTING.md` + `CLAUDE.md` mock server 部分联动更新：原指引提到"本地需要已有有效 credentials.json"，in-memory 后 dev workflow 改为"本地需要 Claude CLI 已登录"。

## 7. 引用

- 相关调研：无
- 相关 ADR：[0005-reopen-multi-provider-direction](../../adr/0005-reopen-multi-provider-direction.md)（多 provider 方向；本 spec 与其方向一致）
- 落地版本：[v0.5.1](../../versions/v0.5.1-claude-credentials-in-memory.md)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [ ] SC1 — pending
- [ ] SC2 — pending
- [ ] SC3 — pending
- [ ] SC4 — pending
- [ ] SC5 — pending
- [ ] SC6 — pending
- [ ] SC7 — pending
- [ ] SC8 — pending
- [ ] SC9 — pending
- [ ] SC10 — pending
