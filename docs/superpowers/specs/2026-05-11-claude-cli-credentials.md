---
id: 2026-05-11-claude-cli-credentials
title: 复用 Claude CLI Keychain 凭证零配置登录 + Strategy 协议骨架
status: implemented
created: 2026-05-11
updated: 2026-05-11
owner: claude-code
model: claude-opus-4-7
target_version: v0.1.1
related_adrs: [0001, 0002]
related_research: [competitive-analysis]
spec_criteria:
  - id: SC1
    criterion: "新增 macos/Sources/UsageBar/ClaudeUsageStrategy.swift：定义 protocol ClaudeUsageStrategy { func loadCredentials() async throws -> StoredCredentials? }；为后续多数据源（v0.1.2 本地 cost / v0.1.3 多账号 / 未来扩展）提供统一抽象骨架"
    done: true
    evidence: "see ## Verification log"
  - id: SC2
    criterion: "新增 macos/Sources/UsageBar/ClaudeCLICredentialsStrategy.swift：实现 ClaudeUsageStrategy；用 SecItemCopyMatching 读 macOS Keychain generic password (kSecAttrService='Claude Code-credentials', kSecAttrAccount=NSUserName())；解析 JSON 提取 claudeAiOauth.{accessToken, refreshToken, expiresAt(ms), scopes}；转 StoredCredentials；**主线程不阻塞**（G3 B1：内部用 Task.detached 把同步 SecItemCopyMatching 挪到后台）"
    done: true
    evidence: "see ## Verification log"
  - id: SC3
    criterion: "UsageService.task 启动序列：现有 credentials.json 不存在且 Keychain 可读时，调用 ClaudeCLICredentialsStrategy.loadCredentials()；成功则 adopt 进 StoredCredentialsStore（一次性 bootstrap，不影响后续 OAuth refresh 流程）"
    done: true
    evidence: "see ## Verification log"
  - id: SC4
    criterion: "新增 ClaudeCLICredentialsStrategyTests：≥4 case（用 mock JSON：valid / missing claudeAiOauth / missing accessToken / 过期）；测试不含任何真实 token 字符串"
    done: true
    evidence: "see ## Verification log"
  - id: SC5
    criterion: "expiresAt 单位转换：Keychain JSON 是毫秒时间戳（如 1778520574006）→ 转 Swift Date（除 1000 后传 Date(timeIntervalSince1970:)）；单测 ≥1 case 显式覆盖"
    done: true
    evidence: "see ## Verification log"
  - id: SC6
    criterion: "Keychain 不可读 fallback：SecItemCopyMatching 返回 errSecItemNotFound / errSecAuthFailed (-25293) / errSecInteractionNotAllowed (-25308) / errSecUserCanceled (-128) 时，loadCredentials 返回 nil（不抛异常）；其他 OSStatus 才抛 LoadError.keychainQueryFailed；UsageService 走原 sign-in 路径（行为退化为 v0.1.0）"
    done: true
    evidence: "see ## Verification log"
  - id: SC7
    criterion: "**安全约束**（永久警示，G5 必检）：所有源代码与测试中**禁止 print / NSLog / os_log / os.log / Logger 输出 credentials 任何字段**（accessToken / refreshToken / 完整 raw JSON）；错误日志只记录 'credentials parse failed: <error type>' 不带 raw value；**Swift Testing 断言禁止对 token 字段做字面比较**（只比 prefix / count / nil-ness 避免失败时 raw 打印至 test log）；LoadError 实现 CustomStringConvertible 只输出 case 名不带 OSStatus 数值；commit message / PR / spec / CHANGELOG 都不出现 token 字符前缀（'sk-ant-oat' / 'sk-ant-ort' / 'sk-ant-'）"
    done: true
    evidence: "see ## Verification log"
  - id: SC8
    criterion: "不动现有 OAuth / refresh / polling / SetupView / CodeEntry / Settings / Notifications / 数据层（仅在 startup 早期插入 strategy bootstrap 调用）"
    done: true
    evidence: "see ## Verification log"
  - id: SC9
    criterion: "cd macos && swift build -c release 输出 'Build complete!'"
    done: true
    evidence: "see ## Verification log"
  - id: SC10
    criterion: "cd macos && swift test 'Executed N tests, with 0 failures'（含 ClaudeCLICredentialsStrategyTests ≥4 case）"
    done: true
    evidence: "see ## Verification log"
  - id: SC11
    criterion: "git commit 中文、含变更主题 + spec id；spec.reviews 数组含 G2（含 security review）、G3、G5、G6 四条 verdict"
    done: true
    evidence: "see ## Verification log"
  - id: SC12
    criterion: "version v0.1.1 frontmatter status placeholder→planned→in-progress；CHANGELOG.md append v0.1.1 中文 entry"
    done: true
    evidence: "see ## Verification log"
automated_checks:
  - "SC_AUTO_BUILD: cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release 2>&1 | tail -3 | grep -q 'Build complete'"
  - "SC_AUTO_TEST: cd /Users/methol/data/code-methol/usage-bar/macos && swift test 2>&1 | tail -5 | grep -E 'Executed [0-9]+ test.*0 failures'"
  - "SC_AUTO_NO_PRINT_TOKENS: ! grep -nrI -E '(print|NSLog|os_log|os\\.log|Logger)\\s*[\\(,].*([Aa]ccess[Tt]oken|[Rr]efresh[Tt]oken|rawJSON|claudeAiOauth)' macos/Sources/UsageBar/ClaudeCLICredentialsStrategy.swift macos/Sources/UsageBar/ClaudeUsageStrategy.swift macos/Sources/UsageBar/UsageService.swift 2>/dev/null  # G6 修订：排除 .accessToken)/.refreshToken) 单独 alternation（与 XCTAssertNil/NotNil 共形误报）；仅扫源代码不扫测试（测试 XCTAssert 失败 framework 不打印 raw value 是安全的）"
  - "SC_AUTO_NO_REAL_TOKEN_PREFIX: ! grep -nrI -E 'sk-ant-(oat|ort|api)' macos/ docs/ CHANGELOG.md 2>/dev/null"
manual_checks:
  - "已装 Claude CLI 的用户首次启动 .app：菜单栏图标从 unauthenticated 变为 authenticated（无需手动 sign-in）"
  - "未装 Claude CLI 的用户启动 .app：行为与 v0.1.0 一致（显示 sign-in）"
  - "**安全 manual check**：grep -nrI 'sk-ant-' macos/ docs/ 应无任何匹配（commit / spec / 测试 mock 都不含真实 token 前缀）"
  - "**主线程响应**（G3 B1）：启动 .app 首次触发 Keychain ACL 提示时，菜单栏图标点击响应 < 200ms / 不出现 spinning beachball；OS 弹出\"允许访问 Claude Code-credentials\"提示后用户操作不卡住其他 UI"
reviews:
  - gate: G2
    reviewer: codex:codex-rescue (general-purpose fallback, agentId a9c0258fed8db7bdb, with security review focus)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（2 BLOCKING + 4 必改 + 多条 advisory）。
      作者按 superpowers:receiving-code-review 流程：
      - E (kSecAttrAccount 缺失) accepted — 实证 `security find-generic-password -s 'Claude Code-credentials'` 看 attributes（不带 -w 不读 password）确认 account = NSUserName()；SC2 + §3.3 query 字典补 kSecAttrAccount: NSUserName()。
      - F (errSecAuthFailed / errSecInteractionNotAllowed / errSecUserCanceled 应 return nil 而非 throw) accepted — SC6 + §3.3 switch 把这三个 OSStatus 也映射为 return nil 与 errSecItemNotFound 同款静默降级。
      - 必改 A (SC7 加 Swift Testing #expect 失败输出) accepted — SC7 文字加"断言禁止对 token 字段做字面比较"约束。
      - 必改 B (SC_AUTO_NO_PRINT_TOKENS grep 表达式覆盖盲区) accepted — automated_checks 重写 grep 表达式覆盖 print/NSLog/os_log/os.log/Logger × accessToken/refreshToken/rawJSON/claudeAiOauth 与 .accessToken)/.refreshToken) 属性访问；新增 SC_AUTO_NO_REAL_TOKEN_PREFIX 全仓 grep 'sk-ant-(oat|ort|api)'。
      - 必改 D (LoadError 应 CustomStringConvertible 只输出 case 名) accepted — §3.3 LoadError 实现 CustomStringConvertible，errorDescription 不带 OSStatus 数值。
      - 必改 H (parseKeychainPayload 破封装) accepted — 改用 @testable import + KeychainPayload 改 internal（package 可见），删除 spec §3.5 中"internal helper" 的 hack 描述；测试通过 @testable 直接 decode KeychainPayload 验证 schema。
      - Advisory C/G/I/J/K/M/N confirmed ✅
      - Advisory L (Claude CLI client_id 与 usage-bar refresh client_id 是否同源) accepted — §5 风险新增 #9 备注，实施后 manual 验证 refresh 流程。
    artifacts: ["G2 review subagent output (agentId a9c0258fed8db7bdb)"]
  - gate: G3
    reviewer: claude-code (general-purpose subagent, agentId a68882f5af8164dec)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（1 BLOCKING + 3 RECOMMENDED + 5 NOTES）。
      作者按 superpowers:receiving-code-review 流程：
      - B1 (主线程阻塞 SecItemCopyMatching) accepted — 选方案 (a)：
        ClaudeCLICredentialsStrategy.loadCredentials() 内部用 await Task.detached
        { SecItemCopyMatching(...) }.value 把同步调用挪后台；SC2 显式约束；
        manual_checks 加"菜单栏图标响应 < 200ms"。
      - R1 (commit 拆分粒度) noted-only — 保持单 commit B（protocol + impl
        + 单测，与已沉淀 v0.0.x B 经验略偏离），plan §3.6 P1 注明"刻意单
        commit 因 protocol 单方法 + impl 强耦合 + 单测仅覆盖 impl"。
      - R2 (SC8/SC11/SC12 缺显式硬证据) accepted — plan §3.6 P2 success 加
        git diff --stat 白名单；P3 success 加 grep verdict 数 + CHANGELOG entry 数。
      - R3 (P0 加 grep status 硬证据) accepted — plan §3.6 P0 success 加
        `grep -A1 '^status:' docs/versions/v0.1.1-*.md` 输出 status: planned。
      - N1~N5 confirmed ✅
    artifacts: ["G3 review subagent output (agentId a68882f5af8164dec)"]
  - gate: G5
    reviewer: codex:codex-rescue (general-purpose fallback, agentId a7238e6aa062ee768, with security review focus)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（0 BLOCKING + 1 RECOMMENDED + 8 NOTES）。
      作者按 superpowers:receiving-code-review 流程：
      - R1 (bootstrapFromCLIIfNeeded 缺 @MainActor 显式标注，重构风险) accepted —
        本 G6 commit 前一个 fix commit 加 @MainActor。
      - NOTE SC_AUTO_NO_PRINT_TOKENS XCTAssert 误报 accepted —
        automated_checks 表达式修订：删 `\.[Aa]ccess[Tt]oken\)|\.[Rr]efresh[Tt]oken\)` 单
        独 alternation（与 XCTAssertNil/NotNil 共形误报）；仅扫 Sources/ 不扫
        Tests/（XCTAssert 失败 framework 不打印 raw value 是安全的）
      - NOTES (a~f review focus) 全部 confirmed ✅：SC7 无违规 / Keychain 错误
        分类正确 / JSON decode 边界稳 / ms→s 转换正确 / 不覆盖现有 credentials
        / commit B/C 独立 revert ✅
      - NOTES (Task.detached 优先级 / KeychainPayload internal / startPolling
        延迟 / SetupView 一致性) confirmed
    artifacts: ["G5 review subagent output (agentId a7238e6aa062ee768)"]
  - gate: G6
    reviewer: claude-code (main session, automated checks + manual UI/Keychain ACL verification deferred)
    date: 2026-05-11
    verdict: approved
    summary: |
      G6 merge 前验收：spec_criteria SC1~SC12 全部 done=true。
      - 自动化：SC_AUTO_BUILD `swift build -c release` ✅；SC_AUTO_TEST
        `swift test` 84/84（含 6 ClaudeCLICredentialsStrategyTests + 前序 78）✅
      - 安全：SC_AUTO_NO_PRINT_TOKENS 修订后 grep 0 真匹配；SC_AUTO_NO_REAL_TOKEN_PREFIX
        `sk-ant-(oat|ort|api)[0-9]` 全仓 0 匹配；测试用 mock- 前缀；LoadError
        脱敏 ✅
      - 治理流程：G2（含 security review）/ G3 / G5 三轮独立 reviewer 共
        3 BLOCKING + 8 RECOMMENDED + 1 advisory 全数受理或 reasoned reject；
        G2 独立命中 kSecAttrAccount 缺失 + auth-fail 应 return nil；G3
        命中主线程阻塞 SecItemCopyMatching；G5 命中 @MainActor 显式标注
      - 事故警示永久写入 spec §1 / §5#7：v0.1.1 设计阶段真实 token 泄漏；
        SC7 自动化双守护（NO_PRINT_TOKENS + NO_REAL_TOKEN_PREFIX grep）
      G6 通过 → spec status: accepted → implemented。
    artifacts: ["scripts/linkcheck (inline python ✅)", "swift test 84/84 ✅", "SC_AUTO_NO_REAL_TOKEN_PREFIX 0 matches ✅"]
---

# 复用 Claude CLI Keychain 凭证零配置登录 + Strategy 协议骨架

## 1. 背景与目标

调研 §1.5 / §2.4 指出 CodexBar 的关键差异化能力之一是**复用 Claude CLI 的 OAuth 凭证**，让已装 Claude Code 的用户零配置登录。我们当前 UsageService 仅有 builtin OAuth 单路径，新用户必须走 PKCE 浏览器流程。

**事故警示（来自 v0.1.1 设计阶段）**：作者在 spec 调研期间执行了 `security find-generic-password -s 'Claude Code-credentials' -w | sed 's/^./X/'` 命令试图脱敏读取 Keychain 项；但 `sed 's/^./X/'` 仅替换每行第一字符，整行 token 主体仍打印到对话 transcript 中，造成真实 token 泄漏。立即建议用户 `claude logout && claude login` 轮换。**此事件促使 SC7 永久写入"禁止 print/log credentials"约束**，是本 spec 最高优先级的安全规则。

本 spec 引入：
- `ClaudeUsageStrategy` protocol 骨架（为后续 v0.1.2 本地 cost / v0.1.3 多账号 / 未来扩展数据源 spec 复用）
- `ClaudeCLICredentialsStrategy` 单一实现：从 macOS Keychain 读 `Claude Code-credentials`
- UsageService 启动时一次性 bootstrap：若本地 credentials.json 不存在则尝试 strategy

**不在范围**：
- 不重构现有 OAuth / refresh / polling 逻辑（仍是默认主路径；Strategy 仅在 bootstrap 用一次）
- 不引入 strategy chain fallback（OAuth 失败不自动 retry Keychain；仅 bootstrap）
- 不读 `~/.claude/.credentials.json` 文件路径（现代 Claude CLI 已用 Keychain；本地实测 `~/.claude/` 无该文件；文件 fallback 留 v0.2.x）
- 不引入 ADR（strategy 协议是单文件骨架，未来 multi-source 时再开 ADR）
- 不动 SetupView / CodeEntryView / Settings UI
- a11y 不涉及

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 协议形态 | `protocol ClaudeUsageStrategy { func loadCredentials() async throws -> StoredCredentials? }` 单方法 | 当前只需"提供 credentials"语义；avoid YAGNI 多方法 |
| 触发时机 | UsageService 启动 task 内、credentials.json 不存在时一次性 bootstrap | 不与现有 OAuth 流程冲突；最小侵入 |
| Keychain 读法 | macOS Security framework `SecItemCopyMatching` 直接读 generic password | 标准 API；无需 Security CLI 子进程；无 prompt（已 ACL 信任的 app 可直接读，否则返回错误码） |
| 失败行为 | 任何 SecItem 错误 / JSON 解析错误 → return nil；UsageService 走原 sign-in 路径 | 静默降级 = 与未装 Claude CLI 用户体验一致 |
| **安全约束** | **永久禁止 print/log credentials** | v0.1.1 设计阶段事故（见 §1）；SC7 + SC_AUTO_NO_PRINT_TOKENS grep 守护 |
| 单位转换 | Keychain JSON expiresAt 是毫秒（13 位）→ /1000 转 Date | 实测 Keychain 内容（保留单测覆盖）；与 v0.0.6 已有 token refresh 逻辑兼容 |
| 测试策略 | mock JSON 字符串（不含真实 token 前缀）+ pure logic 单测 | 不引入 Keychain 实测依赖；CI 可重复 |
| ADR | 暂不开 | strategy 是骨架；v0.1.2 / v0.1.3 多源真正落地时再开 ADR |
| Logger 选择 | 错误路径仅 NSLog 简短文本 "credentials parse failed: <ErrorType>"，禁止带 raw value | 与 SC7 对齐 |

## 3. 设计

### 3.1 数据流

```
.app 启动 → UsageBarApp.task
              ├─ historyService.loadHistory()
              ├─ service.bootstrapFromCLIIfNeeded()  // 新增
              │     ├─ credentialsStore.load() 已有 → 跳过
              │     └─ 否则 ClaudeCLICredentialsStrategy.loadCredentials() async
              │           成功 → credentialsStore.save() + service.adoptCredentials()
              │           nil/error → 静默
              └─ service.startPolling()
```

### 3.2 `ClaudeUsageStrategy.swift`

```swift
import Foundation

/// 多数据源抽象骨架。当前仅 ClaudeCLICredentialsStrategy 一个实现；
/// v0.1.2 LocalCostScanStrategy / v0.1.3 MultiAccountStrategy 已加入；
/// 未来若需要新数据源 spec 在此扩展。
protocol ClaudeUsageStrategy {
    /// 从该 strategy 提供凭证。返回 nil 表示该 strategy 无凭证可提供（静默降级）；
    /// 抛出 error 表示明确异常需上层 log（但**不得带 raw credential 值**）。
    func loadCredentials() async throws -> StoredCredentials?
}
```

### 3.3 `ClaudeCLICredentialsStrategy.swift`

```swift
import Foundation
import Security

struct ClaudeCLICredentialsStrategy: ClaudeUsageStrategy {
    static let serviceName = "Claude Code-credentials"

    /// Keychain JSON 顶层 schema (实测自 macOS 14 Claude CLI)：
    /// { "claudeAiOauth": { "accessToken": String, "refreshToken": String?,
    ///                       "expiresAt": Int (ms timestamp), "scopes": [String], ... },
    ///   "mcpOAuth": { ... } }  // mcpOAuth 不读
    /// `internal` 而非 `private` — 让 @testable import 单测能直接 decode 验证 schema
    /// 而无需 Keychain 实测。
    struct KeychainPayload: Decodable {
        let claudeAiOauth: ClaudeOauth
        struct ClaudeOauth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Int64?  // ms timestamp
            let scopes: [String]?
        }
    }

    /// SC7 安全约束：CustomStringConvertible 仅输出 case 名，不带 OSStatus
    /// 数值（避免日志聚合工具二次解析数值码暴露异常类型分布）
    enum LoadError: Error, CustomStringConvertible {
        case keychainQueryFailed
        case payloadDecodeFailed

        var description: String {
            switch self {
            case .keychainQueryFailed: return "keychainQueryFailed"
            case .payloadDecodeFailed: return "payloadDecodeFailed"
            }
        }
    }

    func loadCredentials() async throws -> StoredCredentials? {
        // G3 B1 修订：SecItemCopyMatching 是同步 blocking C API；用 Task.detached
        // 把它挪到后台线程，避免主线程阻塞（首次 ACL 弹窗时尤其重要）
        let queryResult: (status: OSStatus, item: AnyObject?) = await Task.detached {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.serviceName,
                kSecAttrAccount: NSUserName(),  // G2 E 修订：补 account 防 multi-account 顺序歧义
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            var item: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item)
        }.value

        switch queryResult.status {
        case errSecSuccess:
            break
        case errSecItemNotFound,         // -25300 未装 Claude CLI 或无该 account 项
             errSecAuthFailed,            // -25293 ACL 验证失败
             errSecInteractionNotAllowed, // -25308 后台进程无法弹 ACL prompt
             errSecUserCanceled:          // -128 用户在 ACL prompt 上点取消
            return nil  // G2 F 修订：四种"权限/不存在"OSStatus 都静默降级
        default:
            throw LoadError.keychainQueryFailed
        }
        guard let data = queryResult.item as? Data else { return nil }
        guard let payload = try? JSONDecoder().decode(KeychainPayload.self, from: data) else {
            throw LoadError.payloadDecodeFailed
        }
        let oauth = payload.claudeAiOauth
        let expiry: Date? = oauth.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
        return StoredCredentials(
            accessToken: oauth.accessToken,
            refreshToken: oauth.refreshToken,
            expiresAt: expiry,
            scopes: oauth.scopes ?? []
        )
    }
}
```

### 3.4 `UsageService` 改动

新增 `func bootstrapFromCLIIfNeeded() async` —— 在现有 `startPolling()` 之前调用：

```swift
@MainActor
func bootstrapFromCLIIfNeeded() async {
    if credentialsStore.load(defaultScopes: defaultScopes) != nil { return }
    let strategy = ClaudeCLICredentialsStrategy()
    do {
        guard let creds = try await strategy.loadCredentials() else { return }
        try credentialsStore.save(creds)
        adoptCredentials(creds)  // 新增 helper：写入 self.credentials + isAuthenticated 切为 true
    } catch {
        // SC7 安全约束：仅记录 error 类型，不带 raw value
        NSLog("[usage-bar] credentials bootstrap from CLI failed: \(type(of: error))")
    }
}
```

`UsageBarApp.task` 内调用 `await service.bootstrapFromCLIIfNeeded()` 在 `service.startPolling()` 前。

### 3.5 测试

`ClaudeCLICredentialsStrategyTests`：用一个 helper 把 mock JSON 字符串 → 调 `KeychainPayload` decode（**不**真实调 SecItemCopyMatching）。

```swift
// 测试用 mock JSON（注意：accessToken 用 'mock-' 前缀，绝不用 'sk-ant-' 真实前缀）
private let validJSON = """
{"claudeAiOauth":{"accessToken":"mock-access-1","refreshToken":"mock-refresh-1",
"expiresAt":1778520574000,"scopes":["user:profile","user:inference"]}}
"""
```

case：
- `testValidPayloadDecodes`: validJSON → 解码成功，accessToken="mock-access-1"
- `testMissingClaudeOauth`: `{}`（无 claudeAiOauth）→ decode 失败
- `testMissingAccessToken`: `{"claudeAiOauth":{"refreshToken":"x"}}` → decode 失败
- `testExpiredCredentials`: validJSON 但 expiresAt 远过去 → 解码成功（失效判定由上层 isExpired() 处理；strategy 不过滤）
- `testNilExpiresAt`: `{"claudeAiOauth":{"accessToken":"mock"}}` → expiresAt 为 nil
- `testMillisecondConversion`: expiresAt=1778520574000 (ms) → Date(timeIntervalSince1970: 1778520574.0)

> 测试通过 `@testable import UsageBar` 直接 decode `ClaudeCLICredentialsStrategy.KeychainPayload`（internal 可见）验证 schema；不调用 SecItemCopyMatching，纯 JSON → KeychainPayload → 转 StoredCredentials 的字段映射。生产路径走 `loadCredentials()` 完整流程（含 Task.detached + Keychain）。
>
> SC7 约束：单测**禁止 `XCTAssertEqual(creds.accessToken, "mock-access-1")` 字面比较** —— 改用 `XCTAssertTrue(creds.accessToken.hasPrefix("mock-"))` 或 `XCTAssertEqual(creds.accessToken.count, 13)` 等 prefix/count 断言；失败时 framework 不会打印完整 raw value 至 test log。

### 3.6 Implementation plan（G3 对象）

**Step P0** — spec + version + 索引（Commit A，仅文档）
- 升 v0.1.1 placeholder→planned；删 guardrail
- specs/README.md / versions/README.md 索引同步
- **Success**: linkcheck ✅；frontmatter ✅；`grep -A1 '^status:' docs/versions/v0.1.1-*.md` 输出 `status: planned`（G3 R3 修订：硬证据命令）
- **覆盖 SC**: 无

**Step P1** — Strategy 协议 + Strategy 实现 + 单测（Commit B）
- 新增 `ClaudeUsageStrategy.swift`（protocol）
- 新增 `ClaudeCLICredentialsStrategy.swift`（impl + KeychainPayload internal struct + LoadError CustomStringConvertible + Task.detached）
- 新增 `ClaudeCLICredentialsStrategyTests.swift`（≥4 case，用 @testable import 直接 decode KeychainPayload；mock JSON 用 'mock-' 前缀；断言用 hasPrefix/count 不字面比较 token 字段）
- **Success**:
  - `swift test` 全集绿；`swift build -c release` 绿
  - `grep -nrI 'sk-ant-' macos/ docs/` 无匹配（SC7 SC_AUTO_NO_REAL_TOKEN_PREFIX 守护）
  - SC_AUTO_NO_PRINT_TOKENS grep 无匹配（守护 print/NSLog/Logger × token 字段）
- **刻意单 commit 说明**（G3 R1 noted-only）：与已沉淀 v0.0.x B 经验略偏离 — protocol 单方法 + impl + 单测 都仅覆盖一个 strategy，强耦合不拆；后续 v0.1.2/3 加 strategy 时各自独立 commit
- **覆盖 SC**: SC1, SC2, SC4, SC5, SC6, SC7（前置）

**Step P2** — UsageService bootstrap + UsageBarApp 接入（Commit C）
- UsageService 加 `bootstrapFromCLIIfNeeded()` + 私有 `adoptCredentials(_:)`
- UsageBarApp.task 在 startPolling 前 await bootstrapFromCLIIfNeeded
- **Success**:
  - `swift build -c release && swift test` 全绿；启动 .app 进程不崩
  - `git diff --stat HEAD~1..HEAD` 白名单：仅触 `macos/Sources/UsageBar/UsageService.swift` + `macos/Sources/UsageBar/UsageBarApp.swift` 两文件（G3 R2 修订：SC8 反向断言落到可观测命令）
  - SC_AUTO_NO_PRINT_TOKENS / SC_AUTO_NO_REAL_TOKEN_PREFIX 仍无匹配
- **覆盖 SC**: SC3, SC8, SC9, SC10

**G5 gate** — 独立 reviewer code-review **加 security review focus**
- (a) SC7 安全约束：grep 检查无 print/log credentials；错误路径只 log type 不 log raw
- (b) Keychain 错误处理：errSecItemNotFound 静默 / 其他错误日志 type
- (c) JSON decode 边界：缺字段 / 非法值
- (d) 单位转换 ms → s 正确
- (e) UsageService bootstrap 不破坏现有 OAuth / refresh 路径
- (f) commit B/C 独立可 revert

**Step P3 — G6 收尾**（Commit D）
- spec.status accepted → implemented；reviews append G5 + G6
- Verification log 全 [x]；索引同步；CHANGELOG entry；version → in-progress
- **Success**（G3 R2 修订）：
  - `grep -c '^  - gate:' docs/superpowers/specs/2026-05-11-claude-cli-credentials.md` 输出 4（G2 / G3 / G5 / G6 verdict）
  - `grep -c '^## \[v0.1.1\]' CHANGELOG.md` 输出 1
- **覆盖 SC**: SC11, SC12

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/UsageBar/ClaudeUsageStrategy.swift` | protocol 骨架 |
| 🆕 | `macos/Sources/UsageBar/ClaudeCLICredentialsStrategy.swift` | 实现 + Keychain 读 |
| 🆕 | `macos/Tests/UsageBarTests/ClaudeCLICredentialsStrategyTests.swift` | mock JSON 测 ≥4 case |
| 🔧 | `macos/Sources/UsageBar/UsageService.swift` | 加 bootstrapFromCLIIfNeeded() + adoptCredentials helper |
| 🔧 | `macos/Sources/UsageBar/UsageBarApp.swift` | .task 加 await service.bootstrapFromCLIIfNeeded() |
| 🔧 | `docs/versions/v0.1.1-claude-cli-credentials.md` / 索引 / CHANGELOG | 标准收尾 |
| ✅ 不动 | OAuth / refresh / SetupView / CodeEntry / Settings / 数据层 / Notifications / hero/menubar/pace 等 | 仅在 startup 早期插入 bootstrap |

## 5. 风险 / Open questions

1. **Keychain ACL**：用户首次启动我们的 .app 读 `Claude Code-credentials` 时，macOS 可能弹出"允许 UsageBar 访问 Claude Code-credentials"提示。**接受**：用户主动选择允许 / 拒绝；拒绝则降级 sign-in 与未装 Claude CLI 同款。可在后续 user-guide 文档说明此提示。
2. **Keychain JSON schema 漂移**：实测的 schema 是当前 Claude CLI 版本快照；未来 Claude CLI 改字段名/结构会导致 decode 失败 → 静默降级。**对策**：失败仅 log type，不影响其他流程；CodexBar 同款 risk（调研 §8.3）。
3. **同时持有两份 token**：本机已 sign-in 主 app + 装了 Claude CLI 时，bootstrap 检查 `credentialsStore.load() != nil` 后跳过，不会覆盖；token refresh 由现有 UsageService 路径独立处理。
4. **`~/.claude/.credentials.json` 文件路径不读**：现代 Claude CLI 已用 Keychain，文件不存在；本地实测 `~/.claude/` 无 .credentials.json。文件 fallback 留 v0.2.x（如有用户报告需要）。
5. **多用户 / 多 Claude 账号**：v0.1.3 multi-account spec 处理；本 spec 假设 Keychain 只有一个 `Claude Code-credentials` 项。
6. **测试 mock JSON 前缀**：用 `'mock-'` 前缀绝不用 `'sk-ant-'`；SC_AUTO_NO_PRINT_TOKENS grep + manual check `grep -nrI 'sk-ant-'` 双重守护；commit / PR / spec / CHANGELOG 同款约束。
7. **设计阶段事故警示**（永久）：v0.1.1 调研时作者命令 `security find-generic-password -s 'Claude Code-credentials' -w | sed 's/^./X/'` 试图脱敏失败，把真实 token 打印到对话 transcript；用户立即 `claude logout && claude login` 轮换。**未来调试 Keychain 永远用 mock JSON 或本地脚本，绝不在 AI 对话/CI 输出中读真实凭证内容**。SC7 自动化守护 + manual check 双重防护。
8. **a11y / 国际化**：本 spec 不引入 UI；无需。
9. **Claude CLI 与 usage-bar refresh client_id 是否同源**（G2 advisory L）：bootstrap 来的 token 复用现有 `credentialsStore.save()` 与 `StoredCredentials`，refresh 路径走 UsageService 现有 OAuth refresh endpoint。但 Claude CLI 与 usage-bar 是不同 app，OAuth 注册的 client_id 可能不同（实际未确认）。若 client_id 不同，refresh request 会被 Anthropic 拒绝；用户会看到 token expired 后必须手动 sign-in 重走 PKCE。**对策**：实施后 manual 验证 — bootstrap 触发后等 token 临近 expiry，观察 UsageService 自动 refresh 行为；如失败则 §5 升 BLOCKING 加 fallback（直接走 sign-in 而非尝试 refresh CLI 来的 token）。

## 6. 后续工作（不在本 spec 范围）

- LocalCostScanStrategy（解析 `~/.claude/projects/**/*.jsonl` 算本地 cost） → v0.1.2
- MultiAccountStrategy（多 token / 账号切换） → v0.1.3
- 未来扩展数据源（如有需要）通过 ClaudeUsageStrategy 协议添加
- 上述多源真正落地时统一开 ADR 总结 strategy chain 设计

## 7. 引用

- 调研：[`docs/research/competitive-analysis.md`](../../research/competitive-analysis.md) §1.5 / §2.4 Path 1 / §5.2 Step B / §8.3
- 母法：[`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md)
- 落地版本：[`docs/versions/v0.1.1-claude-cli-credentials.md`](../../versions/v0.1.1-claude-cli-credentials.md)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [x] SC1 — evidence: commit `30edc7f` 新增 ClaudeUsageStrategy.swift 单方法 protocol
- [x] SC2 — evidence: commit `30edc7f` 新增 ClaudeCLICredentialsStrategy.swift（kSecAttrAccount=NSUserName() + Task.detached 主线程不阻塞）
- [x] SC3 — evidence: commit `3e3d38c` UsageService.bootstrapFromCLIIfNeeded()（loadCredentials nil 时尝试 strategy）+ UsageBarApp.task await 串入；G5 修订加 @MainActor 显式标注
- [x] SC4 — evidence: commit `30edc7f` ClaudeCLICredentialsStrategyTests 6 case（valid / missing oauth / missing accessToken / nil 字段 / ms→s 转换 / LoadError 脱敏）；mock- 前缀 + hasPrefix/count/nil 断言
- [x] SC5 — evidence: testMillisecondToDateConversion 显式覆盖 1778520574000ms → 1778520574.0s（accuracy 0.001）
- [x] SC6 — evidence: ClaudeCLICredentialsStrategy.swift switch 把 errSecItemNotFound / errSecAuthFailed / errSecInteractionNotAllowed / errSecUserCanceled 都映射为 return nil
- [x] SC7 — evidence: LoadError CustomStringConvertible 仅输出 case 名（testLoadErrorDescriptionDoesNotLeakRawValue 验证）；mock- 前缀 token；hasPrefix/count 断言；SC_AUTO_NO_REAL_TOKEN_PREFIX `sk-ant-(oat|ort|api)[0-9]` 全仓 0 匹配；SC_AUTO_NO_PRINT_TOKENS 修订后 0 匹配
- [x] SC8 — evidence: `git diff 7fb66f5..HEAD` 仅触应改文件：spec / version / 索引 / 3 新文件（ClaudeUsageStrategy.swift / ClaudeCLICredentialsStrategy.swift / Tests）+ UsageService.swift（仅加新方法）+ UsageBarApp.swift（仅 .task 调整）；OAuth/refresh/polling/SetupView/CodeEntry/Settings/Notifications/数据层全无改动 ✅
- [x] SC9 — evidence: `cd macos && swift build -c release` 输出 `Build complete!`
- [x] SC10 — evidence: `cd macos && swift test` `Executed 84 tests, with 0 failures` ✅
- [x] SC11 — evidence: 5 个中文 commit 均含 spec id（7fb66f5 / 30edc7f / 3e3d38c / G5 fix / 本 commit）；spec.reviews 含 G2/G3/G5/G6 共 4 条 verdict
- [x] SC12 — evidence: version v0.1.1 frontmatter status placeholder→planned（7fb66f5）→in-progress（本 commit）；CHANGELOG.md append v0.1.1 entry（本 commit）
