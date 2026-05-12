---
id: 2026-05-12-claude-keychain-reimport
title: Claude refresh 失败时回退读 Claude CLI Keychain（修「Session expired」误报）
status: implemented
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.7
related_adrs: []
related_research: []
related_specs: [2026-05-11-claude-cli-credentials, 2026-05-11-multi-account, 2026-05-12-multi-provider-refactor]
spec_criteria:
  - id: SC1
    criterion: 当 Claude 的 token refresh 永久失败（refresh token 失效）或 refresh 后请求仍 401 时，**且 `accounts.count <= 1`**，先尝试从 Claude CLI Keychain（`ClaudeCLICredentialsStrategy`，fail-silent 读取）读一次凭证；读到、且与当前失败的 access token 不同、且 `!recovered.isExpired()` → 把它存进 active account（`saveCredentials`）、`isAuthenticated` 保持 true、清 `lastError`、不弹「Session expired」；下一轮 polling 用新 token 正常拉取（若 `recovered.needsRefresh()` 但未过期，下一轮 `sendAuthorizedRequest` 会用其 refresh token 续期——这是既有逻辑）
    done: true
    evidence: "UsageService.expireSession() async 入口调 attemptCLIKeychainRecovery()（accounts.count<=1 + accessToken≠current + !isExpired() 三道 guard），过则 saveCredentials/isAuthenticated=true/lastError=nil/runtime.clear()/setConfigured(true)/return。测试 testRecoversFromKeychainOnPermanentRefreshFailure（断言 isAuthenticated、store 里 token 已换、lastError/runtime.lastError 均 nil）。"
  - id: SC2
    criterion: 以下任一情况 → 走原来的硬过期路径（删凭证、`isAuthenticated=false`、`lastError = "Session expired — please sign in again"`、`runtime.setError(clearSnapshot:true)`）：`accounts.count > 1`；Keychain 读不到 / 解析失败；读到的 access token 与失效的相同；读到的 `recovered.isExpired()`；`saveCredentials` 失败。即新逻辑只「在能安全恢复时恢复」，不引入新的卡死/恢复循环状态
    done: true
    evidence: "三道 guard + do/catch 任一不过 → return false → expireSession 原路径执行。测试 testHardExpiresWhenKeychainEmpty / testNoRecoveryLoopWhenKeychainHasSameStaleToken / testHardExpiresWhenKeychainTokenAlreadyExpired / testNoRecoveryWhenMultipleAccounts（均断言 isAuthenticated=false + lastError=过期文案；空 Keychain 那条还断言 credentials 已删、runtime.snapshot==nil）。`saveCredentials` 失败分支由代码里 `do { … } catch { return false }` 保证、未单独造测试（一致由 code-reading 覆盖）。"
  - id: SC3
    criterion: Keychain 读取是只读副作用（复用 v0.1.1 的 `ClaudeCLICredentialsStrategy.loadCredentials()`，不创建/不修改 Keychain）；恢复路径的那次读取用 `interactionNotAllowed` 的 `LAContext`（`kSecUseAuthenticationContext`）（后台 polling 触发时不弹 ACL，直接降级返回 nil）；不打印 raw token（沿用既有 SC7 约束）；恢复只在单账号时发生，不会用别人的 token 覆盖某个非 active 账号
    done: true
    evidence: "ClaudeCLICredentialsStrategy 仍只 `SecItemCopyMatching`（无 add/update/delete）；`loadCredentials(allowInteraction:)`，`!allowInteraction` 时挂 `LAContext{interactionNotAllowed=true}` 到 `kSecUseAuthenticationContext`（非已弃用的 `kSecUseAuthenticationUIFail`）；`cliKeychainLoader` 默认 `allowInteraction: false`；`bootstrapFromCLIIfNeeded` 仍走无参 `loadCredentials()`=true。grep `accessToken|refreshToken` 在 UsageService/ClaudeCLICredentialsStrategy 无 NSLog/print/os_log/description/error 文案插值。recovery 第一道 guard `accounts.count <= 1`。"
  - id: SC4
    criterion: 单测覆盖：(a) refresh 永久失败 + 单账号 + Keychain 有新鲜（未过期、不同）凭证 → service 仍 authenticated、credentials 已被新值替换、lastError 清空、未删除凭证；(b) Keychain 返回 nil → 硬过期（authenticated=false、credentials 已删、lastError 为过期文案、runtime.snapshot==nil）；(c) Keychain 返回的 access token 与失效的相同 → 硬过期（不恢复循环）；(d) Keychain 返回的是不同但已 `isExpired()` 的 token → 硬过期；(e) `accounts.count > 1` 时即使 Keychain 有新鲜凭证也走硬过期；(f) 正常 refresh 成功路径下 `cliKeychainLoader` 根本不被调用
    done: true
    evidence: "UsageServiceTests 新增 6 个用例：testRecoversFromKeychainOnPermanentRefreshFailure(a) / testHardExpiresWhenKeychainEmpty(b) / testNoRecoveryLoopWhenKeychainHasSameStaleToken(c) / testHardExpiresWhenKeychainTokenAlreadyExpired(d) / testNoRecoveryWhenMultipleAccounts(e，init 前 store.saveAccounts 种 2 账号) / testNormalRefreshSuccessDoesNotTouchKeychain(f，cliKeychainLoader 设成 XCTFail 闭包)。"
  - id: SC5
    criterion: Claude 既有行为零回归 —— 正常 refresh 成功路径、多账号切换、首启 `bootstrapFromCLIIfNeeded`、backoff、polling、transient 失败（不到 expireSession）都不受影响；既有 `UsageServiceTests` 中走硬过期路径的用例已显式注入 no-op `cliKeychainLoader` 后断言不变；`swift test` 全绿
    done: true
    evidence: "testFetchUsageSignsOutWhenRefreshFails / testExpiredTokenWithPermanentRefreshFailureSignsOut 各加 `service.cliKeychainLoader = { nil }`，原断言全保留；transient 用例（testServer500…/testNetworkError…/testExpiredTokenWithTransientRefreshFailure…）与 `bootstrapFromCLIIfNeeded`（走无参 loadCredentials()=true）均未碰；`swift build -c release` 通过、`swift test` = 207 tests 0 failures；`make release-artifacts` + verify-release zip/dmg OK。"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_ARTIFACTS: make release-artifacts"
manual_checks:
  - "在 app token 已过期（弹 Session expired）但 Claude Code 仍能用的机器上：重启 app（或等下一轮 polling）→ 不再弹 Session expired，正常显示用量"
reviews:
  - gate: G2
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: design-review + security-review (敏感面：读 Claude CLI Keychain + 写 active account 凭证)
    verdict: approved-after-revisions
    notes: >
      2 must-fix（① attemptCLIKeychainRecovery 接受门槛除「token≠失败的」外还要 `!recovered.isExpired()`，否则不同但已过期的 token 会推迟硬过期变相循环；② 补对应测试用例「不同但已过期 token → 硬过期」）
      + 3 should-fix（③ 恢复路径 gate 在 `accounts.count<=1`，不冒险用别人 token 覆盖非 active 账号；④ 恢复路径那次 Keychain 读取用 `kSecUseAuthenticationUIFail`，后台 polling 触发时不弹 ACL；⑤ 既有走硬过期路径的 UsageServiceTests 预先注入 no-op `cliKeychainLoader` 再断言不变）。
      全部已在本 spec §2~§5 应用。expireSession 单点改造方向、不加 `Task{fetchUsage}` 重入、internal 闭包注入、范围大小均获认可（praise）。
  - gate: G3
    date: 2026-05-12
    reviewer: general-purpose subagent (independent, cross-session)
    scope: plan-review of docs/superpowers/plans/2026-05-12-claude-keychain-reimport.md
    verdict: ready-with-revisions
    notes: >
      2 must-fix（① plan 的测试片段用了不存在的 makeService/tokenStub API —— UsageServiceTests 是 per-test inline MockURLProtocol.handler 模式、MockURLProtocol 是 file-private，新测试要并入 UsageServiceTests.swift 用现成 helper；
      ② testNoRecoveryWhenMultipleAccounts：没有 addAccount API，多账号要在 init 前用 store.saveAccounts(StoredAccountsFile v2) 种）
      + 3 should-fix（③ attemptCLIKeychainRecovery 成功时还要 runtime.clear() 抹掉上一轮 expireSession 留的 lastError；④ stored creds 要带 refreshToken 才走得到 .permanentFailure→expireSession；⑤ SC2「saveCredentials 失败」无测试覆盖，evidence 要诚实写「靠 do/catch 行 + code-reading」）+ 几个 nit（drop `?? nil`、setConfigured 幂等注释）。
      全部已在 plan 顶部「G3 corrections」块 + §3.1(b) 代码更新。production 代码片段编译性、4 处 expireSession 调用点、既有硬过期/transient 测试归类、post-recovery fetchUsage 无重入 均经核对确认（praise）。
  - gate: G5
    date: 2026-05-12
    reviewer: codex (codex-rescue subagent, independent)
    scope: code-review + security-review (敏感面：读 Claude CLI Keychain + 写 active account 凭证)
    verdict: approved-with-nits
    notes: >
      仅 1 个 nit（spec §2/§3 当时仍写 `kSecUseAuthenticationUIFail`，而实现已正确改用非弃用的 `LAContext{interactionNotAllowed}` + `kSecUseAuthenticationContext` —— 已修正 spec 措辞）。无 must-fix / should-fix。
      恢复逻辑 3 道 gate 顺序、成功路径状态清理顺序、post-recovery fetchUsage 不误触 setError、timer 仍存活、无参 loadCredentials() 满足协议、Keychain 纯只读、新测试覆盖完整且 MockURLProtocol 不跨测试泄漏、SC2 evidence 诚实标注 saveCredentials-失败靠 code-reading —— 均获认可（praise）。
      G5「CI 拦截 swift test」实为 codex runner /tmp 写权限问题，非真实失败：本机 swift build -c release 通过、swift test = 207 tests 全绿、make release-artifacts + verify-release zip/dmg OK。
---

# Claude refresh 失败时回退读 Claude CLI Keychain

## 1. 背景与目标

菜单栏 app 用的是它**自己**的 OAuth 凭证（`~/.config/claude-usage-bar/credentials.json`），跟 Claude Code 用的 Keychain 凭证（`Claude Code-credentials`）是两套。v0.1.1（[spec](./2026-05-11-claude-cli-credentials.md)）加了一个**首启**时从 Keychain 自动导入的 `bootstrapFromCLIIfNeeded`，但它只在「还没有任何账号」时跑一次。用户一旦手动登录过、有了账号，app 的 token 过期、且其 refresh token 也失效后，就直接 `expireSession()` 弹「Session expired — please sign in again」逼用户重登 —— 而此时 Claude Code 自己往往还在正常用（Keychain 里有新鲜 token）。用户实测就遇到了这个（2026-05-12）。

**目标**：在 `expireSession()` 真正生效前，先复用 v0.1.1 那套 Keychain 读取逻辑试着续上凭证；能续上就静默续、不打扰；续不上才走原硬过期路径。改动小、不引入新依赖、不改凭证存储格式。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 在哪儿插入恢复 | `expireSession()` 函数入口（所有 4 处调用点自动受益），而非每个 call site 各加一遍 | 单点改动，DRY；`expireSession` 全部调用点都在 `sendAuthorizedRequest`（已 `async`），把它改 `async` 无副作用 |
| 用什么读 Keychain | 复用 `ClaudeCLICredentialsStrategy.loadCredentials(allowInteraction:)`（v0.1.1，已脱敏、已 `Task.detached` 后台读、四种「不存在/权限」OSStatus 都静默降级返回 nil）；新增 `allowInteraction` 参数控制是否挂 `interactionNotAllowed` 的 `LAContext` | 不重写核心逻辑，行为一致；SC3 只读约束直接继承；只多一个参数 |
| 恢复后存哪 | `saveCredentials(recovered)` —— 更新 active account 的 credentials 镜像（和正常登录/refresh 一贯行为一致）；**仅在 `accounts.count <= 1` 时才走这条恢复路径** | 单账号时 active account 就是 Claude CLI 那个人，纯续期、无歧义；多账号下「active 是不是 Keychain 那个人」不确定，不冒覆盖别人 token 的险（G2 should-fix #3） |
| 防恢复循环 / 接受门槛 | Keychain 读到的凭证要同时满足：(a) access token != 当前失败的那个；(b) `!recovered.isExpired()` —— 才当作可恢复 | (a) 否则 Keychain 自己也是失效 token 会陷入「永远 authenticated 但永远拉不到」的静默卡死；(b) 不同但已过期的 token 同样会推迟硬过期、变相循环（G2 must-fix #2）。`recovered.needsRefresh()`（临界但未过期）可接受 —— 下一轮 `sendAuthorizedRequest` 会用它的 refresh token 续期，是既有逻辑 |
| Keychain 读取的 ACL 行为 | 恢复路径那次读取给 query 挂一个 `interactionNotAllowed = true` 的 `LAContext`（`kSecUseAuthenticationContext`）—— 非交互式（不弹 ACL → 直接返回 `errSecInteractionNotAllowed` → 既有逻辑降级返回 nil）。不用已弃用（macOS 11）的 `kSecUseAuthenticationUIFail` | `expireSession` 可能在后台 polling 里被触发，绝不能从后台弹凭证授权框（G2 should-fix #4）。给 `loadCredentials` 加一个 `allowInteraction:` 参数，bootstrap（前台首启）走无参 `loadCredentials()`=true、recovery 传 false |
| 恢复后是否立刻重拉 | 不在 `expireSession` 里主动 `fetchUsage`（避免重入）；timer 在恢复分支不 invalidate，下一轮 polling 自然用新 token 拉 | 简单、无重入风险；用户至多等一个 polling 周期（G2 也确认不要加 `Task { fetchUsage }`） |

## 3. 设计

### 3.1 改动文件

| 文件 | 改动 |
|---|---|
| `macos/Sources/ClaudeUsageBar/ClaudeCLICredentialsStrategy.swift` | 拆成无参 `loadCredentials()`（满足协议 = `allowInteraction: true`）+ `loadCredentials(allowInteraction: Bool)`：当 `!allowInteraction` 时给 query 挂一个 `interactionNotAllowed = true` 的 `LAContext`（`kSecUseAuthenticationContext`）—— `SecItemCopyMatching` 不弹 ACL、直接返回 `errSecInteractionNotAllowed`（既有 switch 已降级为返回 nil）。`import LocalAuthentication`。`bootstrapFromCLIIfNeeded` 仍走无参 `loadCredentials()`（前台首启可弹）。其余不动；SC7 脱敏不变。 |
| `macos/Sources/ClaudeUsageBar/UsageService.swift` | (a) `expireSession()` → `private func expireSession() async`：入口先调新私有方法 `attemptCLIKeychainRecovery()`，返回 true（已恢复）则直接 return，不执行原来的「删凭证 + 清状态 + setError」那段；返回 false 才执行原段。(b) 新增 `private func attemptCLIKeychainRecovery() async -> Bool`：`guard accounts.count <= 1 else { return false }`（多账号不冒险，G2 #3）；`let current = loadCredentials()`；`guard let recovered = await cliKeychainLoader() else { return false }`；`guard recovered.accessToken != current?.accessToken else { return false }`（防循环，G2 #2a）；`guard !recovered.isExpired() else { return false }`（不收已过期的，G2 #2b）；`do { try saveCredentials(recovered); isAuthenticated = true; runtime.setConfigured(true); lastError = nil; return true } catch { return false }`。(c) 加注入点 `var cliKeychainLoader: () async -> StoredCredentials?`（`internal`，非 `public`），默认 `{ (try? await ClaudeCLICredentialsStrategy().loadCredentials(allowInteraction: false)) ?? nil }`；放进 `init` 参数列表（仿现有 `localProfileLoader:` 风格）或直接作存储属性（实现期挑最贴近现有风格的）。(d) `sendAuthorizedRequest` 里 4 处 `expireSession()` 调用改 `await expireSession()`。其余逻辑（refresh 流程、return nil 的位置、timer/refreshTask）全不动 —— 注意硬过期分支才 invalidate timer，恢复分支不动 timer，下一轮 polling 自然用新 token。 |
| `macos/Tests/ClaudeUsageBarTests/ClaudeKeychainReimportTests.swift`（新建，或并入 `UsageServiceTests.swift`） | 见 §3.3。 |

### 3.2 测试接缝

`expireSession` 直接 `new ClaudeCLICredentialsStrategy()` 单测不好替换 → 用 §3.1(c) 的 `cliKeychainLoader` 闭包注入（仿 `UsageService` 已有的 `localProfileLoader:` 风格，`internal` 不进对外 API 面）。考虑过「把 `ClaudeUsageStrategy` 协议做成可注入参数」—— 比闭包重，且该协议目前只有一个实现，YAGNI，不采。

### 3.3 测试方案

新增（用 `cliKeychainLoader` 注入；构造 `UsageService` 用临时 `StoredCredentialsStore` + stub 的 token/usage endpoint，仿既有 `UsageServiceTests` 风格）：

- **testRecoversFromKeychainOnPermanentRefreshFailure**：已存一个 token（`expiresAt` 在过去）、单账号；refresh stub 返回 `invalid_grant`（→ `.permanentFailure`）；`cliKeychainLoader` 返回一个**不同且未过期**的 `StoredCredentials`。`await service.fetchUsage()`。断言：`isAuthenticated == true`；`loadCredentials()?.accessToken == 注入的新 token`；`lastError == nil`；凭证未被删；`runtime.lastError == nil`。
- **testHardExpiresWhenKeychainEmpty**：同上但 `cliKeychainLoader` 返回 `nil`。断言硬过期：`isAuthenticated == false`；`loadCredentials() == nil`；`lastError == "Session expired — please sign in again"`；`runtime.lastError == "Session expired — please sign in again"`、`runtime.snapshot == nil`。
- **testNoRecoveryLoopWhenKeychainHasSameStaleToken**：`cliKeychainLoader` 返回 `accessToken` 与当前失败的相同（其它字段任意）。断言走硬过期（同上）。
- **testHardExpiresWhenKeychainTokenAlreadyExpired**（G2 must-fix #5）：`cliKeychainLoader` 返回一个**不同但 `isExpired()`** 的 token。断言走硬过期（同上）。
- **testNoRecoveryWhenMultipleAccounts**（G2 #3）：`accounts.count == 2`（用既有多账号建账号路径），refresh stub `.permanentFailure`，`cliKeychainLoader` 返回新鲜不同的 token。断言走硬过期（不恢复）。
- **testNormalRefreshSuccessUnaffected**：refresh stub 返回成功的新 token；`cliKeychainLoader` 设成 `{ XCTFail("不该被调用"); return nil }`。断言正常拉到 usage、`isAuthenticated == true`。
- **既有 `UsageServiceTests` 中走硬过期路径的用例**（G2 should-fix #7）：`testFetchUsageSignsOutWhenRefreshFails` / `testExpiredTokenWithPermanentRefreshFailureSignsOut`（或当前实际名）—— 显式注入 `cliKeychainLoader = { nil }`，保留原硬过期断言不变；transient 失败用例（`testNetworkErrorDuringRefreshStaysAuthenticated` / `testServer500DuringRefreshStaysAuthenticated`）根本不到 `expireSession`，不动。

CI 仍跑 `swift build -c release` + `swift test` + `make release-artifacts`，全绿。

## 4. 文件迁移动作汇总

| 动作 | 文件 |
|---|---|
| 🔧 | `macos/Sources/ClaudeUsageBar/ClaudeCLICredentialsStrategy.swift` —— 拆 `loadCredentials()` / `loadCredentials(allowInteraction:)`，`!allowInteraction` 时挂 `interactionNotAllowed` 的 `LAContext`；`import LocalAuthentication` |
| 🔧 | `macos/Sources/ClaudeUsageBar/UsageService.swift` —— `expireSession` 改 async + 入口加 `attemptCLIKeychainRecovery()`（`accounts.count<=1` + token≠失败的 + `!isExpired()` 三道门）；加 `cliKeychainLoader` 注入点；4 处 `expireSession()` → `await expireSession()` |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/ClaudeKeychainReimportTests.swift`（或并入 `UsageServiceTests.swift`），并给既有硬过期用例补 `cliKeychainLoader = { nil }` |
| ✅ 不动 | 凭证存储格式、多账号文件结构、`bootstrapFromCLIIfNeeded` 语义（仍只首启跑、仍 `allowInteraction: true`）、`refreshCredentials`、polling/backoff、所有 Codex/provider 文件 |

## 5. 风险 / Open questions

1. **`expireSession` 改 async 的传播面**：已确认所有调用点都在 `sendAuthorizedRequest`（`async throws`）内；`runtime` mirroring 也在那里。无同步调用点。低风险。
2. **「不同但临界（`needsRefresh()` 但未 `isExpired()`）」的 Keychain token 会被接受**：恢复后下一轮 `sendAuthorizedRequest` 看到 `needsRefresh()` → 用它的 refresh token 续期（既有逻辑）。若那次 refresh 也失败 → 再次 `expireSession` → 这次 Keychain 多半还是同一个 token → 命中「token == 失败的那个」门 → 硬过期。不会循环。可接受。
3. **多账号用户享受不到这个修复**：本版本只在 `accounts.count <= 1` 时恢复（保守）。多账号用户 token 过期仍弹 Session expired —— 但他们本来就管理着多个登录态，重登一个账号成本低。后续若需要可加「按 `accountEmail` 匹配 Keychain 身份再恢复」（§6）。可接受。

## 6. 后续工作（不在本 spec 范围）

- 多账号下的恢复：按 `accountEmail` / JWT `sub` 匹配 Keychain 登录身份，匹配上才恢复对应账号 —— 让多账号用户也享受这个修复
- 把 Keychain 当**第一优先**凭证源（每次启动都优先读 Keychain，credentials.json 退为缓存）—— 更激进，改 `bootstrapFromCLIIfNeeded` 的「已有账号就跳过」语义，单独评估
- `ClaudeUsageStrategy` 真正多实现（如 `~/.claude.json` 明文回退）—— 当前只有一个实现，YAGNI

## 7. 引用

- 前置 spec：[`2026-05-11-claude-cli-credentials.md`](./2026-05-11-claude-cli-credentials.md)（v0.1.1 Keychain bootstrap + `ClaudeCLICredentialsStrategy`）、[`2026-05-11-multi-account.md`](./2026-05-11-multi-account.md)、[`2026-05-12-multi-provider-refactor.md`](./2026-05-12-multi-provider-refactor.md)（`runtime` mirroring）
- 落地版本：[`../versions/v0.2.7-claude-keychain-reimport.md`](../versions/v0.2.7-claude-keychain-reimport.md)

## Verification log

> G6 验收依据（详见 frontmatter `spec_criteria` 的 evidence）。

- [x] SC1 — attemptCLIKeychainRecovery 三道门 + testRecoversFromKeychainOnPermanentRefreshFailure
- [x] SC2 — 任一门不过 → 硬过期；testHardExpires* / testNoRecovery* 四条；saveCredentials 失败靠 do/catch + code-reading
- [x] SC3 — 只读 SecItemCopyMatching + LAContext interactionNotAllowed + grep 无凭证插值 + 单账号 gate
- [x] SC4 — 6 个新用例覆盖 (a)~(f)
- [x] SC5 — 既有硬过期用例注入 no-op loader 后断言不变；207 tests 全绿；artifacts OK
