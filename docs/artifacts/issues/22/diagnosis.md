# Issue #22 诊断

- 链接：https://github.com/methol/usage-bar/issues/22
- 标题：[bug] UsageService 调用 refreshCredentials 消费 Claude Code 的 refresh token，导致 Claude Code 被迫退出登录

## 复现与定位

1. `bootstrapFromCLIIfNeeded()` 在首次启动时从 Claude Code Keychain 读取完整凭证（`ClaudeCLICredentialsStrategy.loadCredentials()`），包含 `accessToken + refreshToken`，并通过 `saveCredentials(creds)` 写入 `credentials.json`。
2. 轮询期间，`sendAuthorizedRequest()` 在 token 接近过期时调用 `refreshCredentials(force:)` → `performRefresh()`。
3. `performRefresh()` 使用存储的 `refreshToken`（实为 Claude Code 的 refresh token）向 OAuth 端点发起 `grant_type=refresh_token` 请求。
4. 服务端执行 OAuth Token Rotation：作废旧 refresh token，签发新的 `accessToken_B + refreshToken_B`。
5. usage-bar 将新 token 写入 `credentials.json`；Claude Code Keychain 仍持有已失效的旧 refresh token。
6. 约 8 小时后 Claude Code 的 access token 到期，尝试用已失效的 refresh token 续期 → `400 invalid_grant` → 强制退出登录。

## 根因

- `bootstrapFromCLIIfNeeded()` 保存了 Claude Code 的 `refreshToken`（不该有此 token）。
- `performRefresh()` 消费了该 token，触发了 OAuth Token Rotation，使 Claude Code 丧失续期能力。
- `attemptCLIKeychainRecovery()` 在恢复时也会通过 `cliKeychainLoader` 读取 Keychain 并用 `saveCredentials(recovered)` 保存，若不处理同样会再次引入 `refreshToken`。

## 修复方案

**核心原则**：从 CLI Keychain 读取的凭证只应取 `accessToken`，永不持有 `refreshToken`。

**三处修改**（仅 `StoredCredentials.swift` + `UsageService.swift`）：

1. **`StoredCredentials.swift`**：添加 `strippingRefreshToken()` helper，返回不含 `refreshToken` 的副本。

2. **`UsageService.bootstrapFromCLIIfNeeded()`**：
   - 在现有 `!accounts.isEmpty` 早返回**之前**，调用新增的 `migrateStripCLIRefreshToken()` 迁移方法（处理已有存储 refresh_token 的老用户）。
   - 在保存新 bootstrap 凭证时改为 `saveCredentials(creds.strippingRefreshToken())`。

3. **`UsageService.attemptCLIKeychainRecovery()`**：保存前改为 `saveCredentials(recovered.strippingRefreshToken())`，防止恢复路径重新引入 `refreshToken`。

4. **新增 `migrateStripCLIRefreshToken()`**：读取 Keychain 当前 `refreshToken`，比对存储账号；若匹配（"bug 发生前"的用户）则剥离并保存。"bug 已发生"（tokens 不一致）的用户在自然过期后通过 `attemptCLIKeychainRecovery()` 安全恢复（恢复路径已修复不会再引入 `refreshToken`）。

**新增测试**（4 个）：
- bootstrap 不保存 refresh_token
- 迁移剥离与 Keychain RT 相同的存储 refresh_token
- 迁移不影响 RT 不同（PKCE OAuth 账号）的账号
- Keychain 恢复路径不保存 refresh_token

## 影响范围

- 修改文件：
  - `macos/Sources/UsageBar/StoredCredentials.swift`（+4 行）
  - `macos/Sources/UsageBar/UsageService.swift`（bootstrap + recovery + 新增 migrate，约 +25 行）
  - `macos/Tests/UsageBarTests/UsageServiceTests.swift`（+4 新测试）
- 风险点：
  - 迁移仅影响"stored RT == Keychain RT"的用户（bug 发生前），"bug 已发生"用户走自然恢复。
  - PKCE OAuth 用户（usage-bar 自有 RT）不受影响：其 RT 不在 CLI Keychain 中，迁移不匹配，`performRefresh()` 依然正常工作。
  - `cliKeychainLoader` 在测试中可被 mock，恢复路径的新行为可单测覆盖。
- 测试计划：`cd macos && swift test`；手动验证 bootstrap 场景

## 守护线自检

- [x] 不触碰凭证 / 密钥链路中的 OAuth token 刷新（修复方向：**停止**消费 CLI refresh_token，不改刷新端点逻辑）
- [x] 不引入新第三方依赖、不改 LICENSE、不改变商业模式
- [x] 不修改已 accepted 的 ADR、不修改 AGENTS.md / 母法 spec
- [x] 不在 `UsageService` 之外重复 fetch / auth / 轮询逻辑（改动均在 `UsageService` 内部）
- [x] 不手改 Info.plist 里的版本号
- [x] 单 issue 影响面：仅 app 代码，改动文件 ≤ 3 个 Swift 文件

**守护线敏感路径核查**：修改涉及 `UsageService.swift` 和 `StoredCredentials.swift`（均属 OAuth / token 刷新链路），需在 plan review 时特别关注安全性。符合"修复而非扩展"原则，不引入新的 token 存储路径。

## 是否需要人工介入

- 结论：NO
- 理由：改动范围明确（3 个文件，约 30 行），修复方向是"不做事"（停止持有/消费 CLI refresh_token），无新增凭证存储路径，与现有 `attemptCLIKeychainRecovery()` 已有恢复机制配合良好。PKCE OAuth 用户不受影响。
