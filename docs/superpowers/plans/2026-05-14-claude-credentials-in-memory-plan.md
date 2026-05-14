---
id: 2026-05-14-claude-credentials-in-memory-plan
title: Claude 凭证改 in-memory only — 实施计划
status: draft
created: 2026-05-14
updated: 2026-05-14
owner: claude-code
model: claude-opus-4-7
spec: 2026-05-14-claude-credentials-in-memory
target_version: v0.5.1-claude-credentials-in-memory
reviews: []
---

# Claude 凭证改 in-memory only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Claude provider 从"自管凭证 + CLI 后备"改成"纯 CLI 借读 + in-memory cache"，删除多账号 UI / 持久化文件读写 / OAuth refresh 整套代码。

**Architecture:** UsageService 新增 `inMemoryCredentials: StoredCredentials?` cache + `ensureFreshCredentials(allowInteraction:)` 入口，所有 fetchUsage 路径走它；401 时清 cache + 重读 Keychain + retry 一次；启动 / Retry 按钮调 `retrySignIn()` 强制重读（allowInteraction=true）。OAuth client / refresh / 多账号 / AccountSwitcherView / StoredCredentialsStore 一刀切删除。

**Tech Stack:** Swift 5.9+, SwiftUI, swift-package-manager, XCTest, macOS Security framework (Keychain SecItemCopyMatching), 现有 ClaudeCLICredentialsStrategy。

**前置条件：**
- 当前 git HEAD: `09813ac` (spec G2 approved)
- 当前 main 测试: `swift test` 308/308 全绿
- 现有 OAuth/多账号 / accounts.json / credentials.json / StoredCredentialsStore 仍在代码中（本 plan 逐步删）
- 工作目录: `/Users/methol/data/code-methol/usage-bar/macos`（swift 命令在此目录运行）

---

## Task 1: 加 `inMemoryCredentials` + `ensureFreshCredentials`（不影响既有路径）

**目的：** 引入 in-memory cache 字段和 `ensureFreshCredentials` 方法；旧 OAuth/refresh 路径保持不动，确保 swift test 不破。建立 TDD 安全网。

**Files:**
- Modify: `macos/Sources/UsageBar/Providers/Claude/UsageService.swift`
- Create: `macos/Tests/UsageBarTests/UsageServiceCredentialsTests.swift`

- [ ] **Step 1.1: 写失败测试** — 新建 `UsageServiceCredentialsTests.swift`：

```swift
import Testing
import XCTest
@testable import UsageBar

@MainActor
final class UsageServiceCredentialsTests: XCTestCase {
    /// cache 非空且未过期 → 不调 Keychain loader
    func testEnsureFreshCredentialsCacheHit() async throws {
        let service = UsageService(usageEndpoint: URL(string: "https://example.invalid/usage")!)
        var loadCount = 0
        service.cliKeychainLoader = {
            loadCount += 1
            return StoredCredentials(accessToken: "t-keychain", refreshToken: nil,
                                     expiresAt: Date().addingTimeInterval(3600),
                                     scopes: ["user:profile"])
        }
        // 预置 cache：未过期
        service._test_setInMemoryCredentials(StoredCredentials(
            accessToken: "t-cache", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: ["user:profile"]))

        let creds = await service.ensureFreshCredentials(allowInteraction: false)
        XCTAssertEqual(creds?.accessToken, "t-cache")
        XCTAssertEqual(loadCount, 0, "keychain loader 不应被调用")
    }

    /// cache 过期 → 调 Keychain loader 拿新 token + 写回 cache
    func testEnsureFreshCredentialsCacheExpiredReloadsKeychain() async throws {
        let service = UsageService(usageEndpoint: URL(string: "https://example.invalid/usage")!)
        var loadCount = 0
        service.cliKeychainLoader = {
            loadCount += 1
            return StoredCredentials(accessToken: "t-new", refreshToken: nil,
                                     expiresAt: Date().addingTimeInterval(3600),
                                     scopes: ["user:profile"])
        }
        service._test_setInMemoryCredentials(StoredCredentials(
            accessToken: "t-stale", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(-60),
            scopes: ["user:profile"]))

        let creds = await service.ensureFreshCredentials(allowInteraction: false)
        XCTAssertEqual(creds?.accessToken, "t-new")
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(service.runtime.isConfigured)
    }

    /// Keychain loader 返回 nil → cache 清空 + isConfigured=false
    func testEnsureFreshCredentialsKeychainEmptyClearsState() async throws {
        let service = UsageService(usageEndpoint: URL(string: "https://example.invalid/usage")!)
        service.cliKeychainLoader = { nil }
        service._test_setInMemoryCredentials(nil)

        let creds = await service.ensureFreshCredentials(allowInteraction: false)
        XCTAssertNil(creds)
        XCTAssertFalse(service.runtime.isConfigured)
    }
}
```

- [ ] **Step 1.2: 跑测试确认 fail**

Run: `cd macos && swift test --filter UsageServiceCredentialsTests 2>&1 | tail -20`
Expected: compile fail，因为 `_test_setInMemoryCredentials`、`ensureFreshCredentials` 都不存在。

- [ ] **Step 1.3: 在 UsageService 加 cache 字段 + ensureFreshCredentials**

在 `UsageService.swift` 类体顶部其它 `@Published` 字段附近加：

```swift
/// v0.5.1: in-memory only —— Claude 凭证不存盘，启动/过期时从 Claude CLI Keychain 重读。
/// nil = 尚未拉取或上次拉取失败；非 nil 但 isExpired() → 需重读。
private var inMemoryCredentials: StoredCredentials?

#if DEBUG
/// 测试种子（仅 @testable import 可见，因 access 是 internal）。
func _test_setInMemoryCredentials(_ c: StoredCredentials?) { inMemoryCredentials = c }
#endif
```

注：`_test_setInMemoryCredentials` 必须 `internal`（默认）—— XCTest `@testable import UsageBar` 才能用。`#if DEBUG` 包住避免 release build 暴露。

在 "MARK: - UsageProvider conformance" extension 之前的某处（同文件靠近 fetchUsage 那段）加：

```swift
extension UsageService {
    /// v0.5.1: 凭证拉取统一入口 —— in-memory cache 命中直接返回；否则从 Claude CLI Keychain 重读并写回 cache。
    /// - Parameter allowInteraction: false=后台 polling 安全（ACL prompt 静默降级返回 nil）；true=前台用户操作（允许首次弹 ACL）。
    /// - Returns: 最新有效 credentials；Keychain 无 / 不可读 / 解析失败 → nil。
    func ensureFreshCredentials(allowInteraction: Bool) async -> StoredCredentials? {
        if let c = inMemoryCredentials, !c.isExpired() {
            return c
        }
        let creds = try? await ClaudeCLICredentialsStrategy().loadCredentials(allowInteraction: allowInteraction)
        inMemoryCredentials = creds
        runtime.setConfigured(creds != nil)
        return creds
    }
}
```

注：`ClaudeCLICredentialsStrategy.loadCredentials(allowInteraction:)` 已存在；这里直接 throws-as-optional（解析失败按 nil 处理 — 与旧 bootstrap 静默降级语义一致）。

测试用例里的 `service.cliKeychainLoader = { ... }` 注入路径将在 Step 1.5 加上 — 先用最简内部实现走通。

- [ ] **Step 1.4: 改 ensureFreshCredentials 用注入点 + 跑测试通过**

把 Step 1.3 那段 ensureFreshCredentials 改成可注入的实现：

```swift
extension UsageService {
    func ensureFreshCredentials(allowInteraction: Bool) async -> StoredCredentials? {
        if let c = inMemoryCredentials, !c.isExpired() {
            return c
        }
        let creds = await cliKeychainLoader()
        inMemoryCredentials = creds
        runtime.setConfigured(creds != nil)
        return creds
    }
}
```

注：`cliKeychainLoader: () async -> StoredCredentials?` 在 UsageService 类体里**已经存在**（用于 attemptCLIKeychainRecovery）—— line 35 附近：
```swift
var cliKeychainLoader: () async -> StoredCredentials? = {
    try? await ClaudeCLICredentialsStrategy().loadCredentials(allowInteraction: false)
}
```

但旧默认值用 `allowInteraction: false` 硬码。我们需要让它接收 `allowInteraction` 参数。改成：

把现有 cliKeychainLoader 字段类型从 `() async -> StoredCredentials?` 改为 `(_ allowInteraction: Bool) async -> StoredCredentials?`，默认值改为：

```swift
var cliKeychainLoader: (_ allowInteraction: Bool) async -> StoredCredentials? = { allowInteraction in
    try? await ClaudeCLICredentialsStrategy().loadCredentials(allowInteraction: allowInteraction)
}
```

ensureFreshCredentials 内调用改成 `await cliKeychainLoader(allowInteraction)`。

⚠️ 同步：所有现有调用面（`attemptCLIKeychainRecovery`、`migrateStripCLIRefreshToken` 等）目前调 `cliKeychainLoader()`（无参），需改成 `cliKeychainLoader(false)`。`grep -n 'cliKeychainLoader(' macos/Sources/UsageBar/Providers/Claude/UsageService.swift` 找到所有调用点逐个改。

测试文件里 spy 也改成接收 `allowInteraction: Bool` 参数（哪怕测试中不验证它）：

```swift
service.cliKeychainLoader = { _ in
    loadCount += 1
    return StoredCredentials(...)
}
```

Run: `cd macos && swift test --filter UsageServiceCredentialsTests 2>&1 | tail -20`
Expected: 3 个测试全 PASS。

- [ ] **Step 1.5: 全量 swift test 不破**

Run: `cd macos && swift test 2>&1 | tail -10`
Expected: 311/311（旧 308 + 新 3）全绿。

- [ ] **Step 1.6: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/Providers/Claude/UsageService.swift \
        macos/Tests/UsageBarTests/UsageServiceCredentialsTests.swift
git commit -m "feat(claude-creds): 加 inMemoryCredentials cache + ensureFreshCredentials 入口

v0.5.1 task 1: 新增 in-memory cache 字段 + 统一的 ensureFreshCredentials(allowInteraction:)
方法。cliKeychainLoader 签名补 allowInteraction 参数(原硬码 false)。

旧 OAuth/refresh/多账号路径暂未删；既有 fetchUsage 仍走 loadCredentials() 老路。
本 task 仅引入新 API + 3 个 cache 行为测试(命中/过期/keychain 空)。后续 task 切
fetchUsage 走 ensureFreshCredentials。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `fetchUsage` 切到 `ensureFreshCredentials` 路径（含 401 retry）

**目的：** 把 fetchUsage 主线从 `loadCredentials()` + OAuth refresh 链路切到 `ensureFreshCredentials` + 清 cache + retry 一次。旧 refresh 代码暂留（下个 task 删）。

**Files:**
- Modify: `macos/Sources/UsageBar/Providers/Claude/UsageService.swift`（替换 `fetchUsage` + `sendAuthorizedRequest` 的凭证读取分支）
- Modify: `macos/Tests/UsageBarTests/UsageServiceCredentialsTests.swift`（加 401 retry 2 用例）

- [ ] **Step 2.1: 加 401 retry 测试**

在 `UsageServiceCredentialsTests` 里加：

```swift
/// 401 → 清 cache → 重读 Keychain 拿新 token → 重试一次 → 200
func testFetchUsage401ClearsCacheAndRetriesOnce() async throws {
    let (session, protocolClass) = makeStubSession()
    let service = UsageService(session: session,
                               usageEndpoint: URL(string: "https://example.invalid/usage")!)
    let oldToken = "t-old"; let newToken = "t-new"
    var keychainSeq = [oldToken, newToken]
    service.cliKeychainLoader = { _ in
        guard !keychainSeq.isEmpty else { return nil }
        return StoredCredentials(accessToken: keychainSeq.removeFirst(),
                                 refreshToken: nil,
                                 expiresAt: Date().addingTimeInterval(3600),
                                 scopes: ["user:profile"])
    }

    // stub: 第一次 401, 第二次 200 with empty usage payload
    var callCount = 0
    protocolClass.responseProvider = { _ in
        callCount += 1
        if callCount == 1 {
            return (Data("{}".utf8), HTTPURLResponse(url: URL(string: "x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let body = #"{"fiveHour":null,"sevenDay":null,"extraUsage":null}"#
        return (Data(body.utf8), HTTPURLResponse(url: URL(string: "x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    await service.fetchUsage()
    XCTAssertEqual(callCount, 2)
    XCTAssertNil(service.lastError)
    XCTAssertTrue(service.isAuthenticated)
}

/// 401 → 清 cache → 重读 keychain 拿到同一个 token (CLI 没 refresh) → 不再重试 → setError 过期
func testFetchUsage401SameTokenReportsExpired() async throws {
    let (session, protocolClass) = makeStubSession()
    let service = UsageService(session: session,
                               usageEndpoint: URL(string: "https://example.invalid/usage")!)
    service.cliKeychainLoader = { _ in
        StoredCredentials(accessToken: "t-same", refreshToken: nil,
                          expiresAt: Date().addingTimeInterval(3600),
                          scopes: ["user:profile"])
    }
    var callCount = 0
    protocolClass.responseProvider = { _ in
        callCount += 1
        return (Data("{}".utf8), HTTPURLResponse(url: URL(string: "x")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    }

    await service.fetchUsage()
    XCTAssertEqual(callCount, 1, "同 token 不应重发")
    XCTAssertEqual(service.lastError, "Token expired; run `claude` to refresh.")
    XCTAssertFalse(service.runtime.isConfigured)
}
```

`makeStubSession()` 是仓库现有 helper（在 `UsageServiceTests.swift` 已使用 URLProtocol stub 同样模式；如未公开，从该文件 copy 进 `UsageServiceCredentialsTests.swift` 内的 helper extension —— 同模式 `class StubProtocol: URLProtocol { static var responseProvider: ((URLRequest) -> (Data, HTTPURLResponse))? }`）。具体复用方式：

```swift
private func makeStubSession() -> (URLSession, StubProtocol.Type) {
    StubProtocol.responseProvider = nil
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return (URLSession(configuration: config), StubProtocol.self)
}

final class StubProtocol: URLProtocol {
    static var responseProvider: ((URLRequest) -> (Data, HTTPURLResponse))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let provider = Self.responseProvider else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (data, http) = provider(request)
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2.2: 跑测试确认 fail**

Run: `cd macos && swift test --filter UsageServiceCredentialsTests 2>&1 | tail -20`
Expected: 2 个新增测试 FAIL（旧 fetchUsage 没走 ensureFreshCredentials；401 路径仍走旧 OAuth refresh 逻辑）。

- [ ] **Step 2.3: 改 fetchUsage 走新路径**

在 `UsageService.swift` 替换 `fetchUsage()`（line 693 起）方法体的凭证读取段：

```swift
func fetchUsage() async {
    let epochAtStart = accountSwitchEpoch
    guard let creds = await ensureFreshCredentials(allowInteraction: false) else {
        lastError = "Sign in with Claude CLI, then tap Retry"
        isAuthenticated = false
        runtime.setError("Sign in with Claude CLI, then tap Retry", clearSnapshot: true)
        return
    }

    do {
        let (data, http) = try await performAuthorizedRequest(token: creds.accessToken, url: usageEndpoint)
        guard accountSwitchEpoch == epochAtStart else { return }

        if http.statusCode == 401 {
            // 清 cache → 重读 keychain → 若拿到新 token 重试一次；若同 token 即 token expired
            let oldToken = creds.accessToken
            inMemoryCredentials = nil
            guard let retried = await ensureFreshCredentials(allowInteraction: false),
                  retried.accessToken != oldToken else {
                lastError = "Token expired; run `claude` to refresh."
                runtime.setError("Token expired; run `claude` to refresh.", clearSnapshot: false)
                return
            }
            let (data2, http2) = try await performAuthorizedRequest(token: retried.accessToken, url: usageEndpoint)
            guard accountSwitchEpoch == epochAtStart else { return }
            try processUsageResponse(data: data2, http: http2)
            return
        }
        try processUsageResponse(data: data, http: http)
    } catch {
        guard accountSwitchEpoch == epochAtStart else { return }
        lastError = error.localizedDescription
        runtime.setError(error.localizedDescription, clearSnapshot: false)
    }
}

/// 抽出原 fetchUsage 内 200/429/non-200 写入 runtime 的部分，供 fetchUsage 主路径 + 401 retry 共用
private func processUsageResponse(data: Data, http: HTTPURLResponse) throws {
    if http.statusCode == 429 {
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        let prev = currentBackoffSeconds == 0 ? baseInterval : currentBackoffSeconds
        currentBackoffSeconds = Self.backoffInterval(retryAfter: retryAfter, currentInterval: prev)
        backoffUntil = Date().addingTimeInterval(currentBackoffSeconds)
        lastError = "Rate limited — backing off to \(Int(currentBackoffSeconds))s"
        runtime.setError(lastError ?? "Rate limited", clearSnapshot: false)
        return
    }
    guard http.statusCode == 200 else {
        lastError = "HTTP \(http.statusCode)"
        runtime.setError("HTTP \(http.statusCode)", clearSnapshot: false)
        return
    }
    let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
    let reconciled = decoded.reconciled(with: usage)
    usage = reconciled
    lastError = nil
    let now = Date()
    lastUpdated = now
    runtime.setSuccess(snapshot: reconciled.asProviderSnapshot(), at: now)
    historyService?.recordDataPoint(pct5h: pct5h, pct7d: pct7d)
    notificationService?.checkAndNotify(pct5h: pct5h, pct7d: pct7d, pctExtra: pctExtra)
    currentBackoffSeconds = 0
    backoffUntil = nil
}
```

⚠️ 旧 `sendAuthorizedRequest`（OAuth refresh 链路）暂留不删（task 3 会清理）；新 fetchUsage 不再调它，但保留以免依赖测试报 unresolved symbol。

- [ ] **Step 2.4: 跑测试确认通过**

Run: `cd macos && swift test --filter UsageServiceCredentialsTests 2>&1 | tail -20`
Expected: 5 个测试全 PASS（Task 1 的 3 个 + Task 2 的 2 个）。

- [ ] **Step 2.5: 跑全量测试确认不破**

Run: `cd macos && swift test 2>&1 | tail -10`
Expected: ⚠️ 部分既有 UsageServiceTests case 会 fail，因为 fetchUsage 行为变了（不再走 OAuth refresh）。**预期 fail 的 case** 在 Task 5/6 删除——本 step 记录失败用例数后 commit。

Run（统计失败数）: `cd macos && swift test 2>&1 | grep -c 'failed)' | head -3`

- [ ] **Step 2.6: Commit**

```bash
git add macos/Sources/UsageBar/Providers/Claude/UsageService.swift \
        macos/Tests/UsageBarTests/UsageServiceCredentialsTests.swift
git commit -m "feat(claude-creds): fetchUsage 改走 ensureFreshCredentials + 清 cache 重试

v0.5.1 task 2: fetchUsage 凭证读取从 loadCredentials() + OAuth refresh 链路切到
ensureFreshCredentials + 401 retry 路径。

行为变化:
- creds == nil → setError 'Sign in with Claude CLI, then tap Retry'
- 401 → 清 cache → 重读 keychain; 拿到新 token 重试一次; 同 token 即 setError
  'Token expired; run \`claude\` to refresh.'
- 抽出 processUsageResponse helper, 供主路径 + 401 retry 共用

旧 sendAuthorizedRequest 暂留(下个 task 删); 既有 OAuth refresh 测试预期 fail
(task 5 删除)。

新增 2 测试: 401 retry 拿新 token / 同 token 报过期。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 加 `retrySignIn()` 公开方法 + UI 接入

**目的：** Retry 按钮 / 启动 task 改调新方法（force allowInteraction=true + 清 cache 强制重读）。

**Files:**
- Modify: `macos/Sources/UsageBar/Providers/Claude/UsageService.swift`
- Modify: `macos/Sources/UsageBar/Features/Popover/PopoverView.swift:334`
- Modify: `macos/Sources/UsageBar/App/UsageBarApp.swift:49`
- Modify: `macos/Tests/UsageBarTests/UsageServiceCredentialsTests.swift`

- [ ] **Step 3.1: 加 retrySignIn 测试**

```swift
/// Retry 按钮 → 强制重读 Keychain (allowInteraction=true 传递确认)
func testRetrySignInForcesKeychainReload() async throws {
    let service = UsageService(usageEndpoint: URL(string: "https://example.invalid/usage")!)
    service._test_setInMemoryCredentials(StoredCredentials(
        accessToken: "t-stale-but-not-expired",
        refreshToken: nil,
        expiresAt: Date().addingTimeInterval(3600),
        scopes: []))
    var receivedAllowInteraction: Bool? = nil
    service.cliKeychainLoader = { allow in
        receivedAllowInteraction = allow
        return StoredCredentials(accessToken: "t-fresh", refreshToken: nil,
                                 expiresAt: Date().addingTimeInterval(3600),
                                 scopes: [])
    }

    await service.retrySignIn()
    XCTAssertEqual(receivedAllowInteraction, true, "Retry 必须传 allowInteraction=true")
    // cache 应被强制刷新即使原 cache 没过期
    let after = await service.ensureFreshCredentials(allowInteraction: false)
    XCTAssertEqual(after?.accessToken, "t-fresh")
}
```

- [ ] **Step 3.2: 跑测试确认 fail**

Run: `cd macos && swift test --filter UsageServiceCredentialsTests/testRetrySignInForcesKeychainReload 2>&1 | tail -10`
Expected: compile fail（retrySignIn 不存在）。

- [ ] **Step 3.3: 加 retrySignIn 实现**

在 UsageService 同 ensureFreshCredentials extension 内加：

```swift
/// v0.5.1 Retry 按钮 / 启动 task 用：清 cache + force allowInteraction=true 重读 Keychain。
/// 与 ensureFreshCredentials(allowInteraction: false) 的区别：① 必清 cache（绕过未过期判定）；② 允许首次 ACL prompt。
func retrySignIn() async {
    inMemoryCredentials = nil
    _ = await ensureFreshCredentials(allowInteraction: true)
}
```

- [ ] **Step 3.4: 改 PopoverView Retry 按钮 action**

`PopoverView.swift:334` 把：
```swift
Button("Retry") {
    Task { await coordinator.claude.bootstrapFromCLIIfNeeded() }
}
```
改成：
```swift
Button("Retry") {
    Task { await coordinator.claude.retrySignIn() }
}
```

- [ ] **Step 3.5: 改 UsageBarApp 启动 task**

`UsageBarApp.swift:49` 把：
```swift
await coordinator.claude.bootstrapFromCLIIfNeeded()
```
改成：
```swift
await coordinator.claude.retrySignIn()
```

- [ ] **Step 3.6: 跑测试确认**

Run: `cd macos && swift test --filter UsageServiceCredentialsTests 2>&1 | tail -10`
Expected: 6 个测试全 PASS。

Run: `cd macos && swift build 2>&1 | tail -5`
Expected: Build succeeded（bootstrapFromCLIIfNeeded 暂时还在 UsageService 里，只是不再被 caller 调用 — 不影响 build）。

- [ ] **Step 3.7: Commit**

```bash
git add macos/Sources/UsageBar/Providers/Claude/UsageService.swift \
        macos/Sources/UsageBar/Features/Popover/PopoverView.swift \
        macos/Sources/UsageBar/App/UsageBarApp.swift \
        macos/Tests/UsageBarTests/UsageServiceCredentialsTests.swift
git commit -m "feat(claude-creds): 加 retrySignIn() + UI/启动 task 接入

v0.5.1 task 3: 新增 retrySignIn() 公开方法 - 清 cache + ensureFreshCredentials
(allowInteraction=true). Retry 按钮 + UsageBarApp .task 启动入口切到它,
取代既有 bootstrapFromCLIIfNeeded.

bootstrapFromCLIIfNeeded 函数暂留(task 5 整体删 OAuth+多账号代码)。

新增 1 测试: testRetrySignInForcesKeychainReload (强制重读 + allowInteraction=true).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 删 AccountSwitcherView + PopoverView 多账号引用

**目的：** 多账号 UI 整体下线，PopoverView 不再依赖 `claude.accounts` / `isAwaitingCode`。

**Files:**
- Delete: `macos/Sources/UsageBar/Features/Popover/AccountSwitcherView.swift`
- Modify: `macos/Sources/UsageBar/Features/Popover/PopoverView.swift`

- [ ] **Step 4.1: grep 找到 AccountSwitcherView 所有引用**

Run: `grep -rn 'AccountSwitcherView' macos/Sources/UsageBar/ --include='*.swift'`
Expected: 2-3 处（文件本身 + PopoverView body 内 + 可能的 import 注释）。

- [ ] **Step 4.2: 删除 PopoverView 中的引用**

`PopoverView.swift:25` 附近，删除：
```swift
if claudeEnabled { AccountSwitcherView(service: claude) }
```

`PopoverView.swift:5-8` 头部文档注释如提到 `accounts`/`isAwaitingCode`，更新成 only 提及 `isAuthenticated`/`lastError`/`runtime`。

- [ ] **Step 4.3: 删除文件**

Run: `git rm macos/Sources/UsageBar/Features/Popover/AccountSwitcherView.swift`

- [ ] **Step 4.4: 跑 build 确认**

Run: `cd macos && swift build 2>&1 | tail -10`
Expected: Build succeeded.

Run: `cd macos && swift test 2>&1 | tail -10`
Expected: 仍有 Task 2 引入的 fail case（OAuth refresh tests），但**不增加新失败**。

- [ ] **Step 4.5: Commit**

```bash
git add macos/Sources/UsageBar/Features/Popover/PopoverView.swift
git commit -m "refactor(claude-creds): 删 AccountSwitcherView + PopoverView 多账号引用

v0.5.1 task 4: 多账号 UI 整体下线 - AccountSwitcherView.swift 整文件删除,
PopoverView 中 if claudeEnabled { AccountSwitcherView(...) } 一行移除,
头部文档注释清理 (不再引用 accounts/isAwaitingCode).

claude.accounts / activeAccountId / accountEmail 等 UsageService 字段
暂留 (task 5 整体删).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 大删 OAuth + 多账号 + Store 代码

**目的：** 一次性删 UsageService 的 OAuth/refresh/多账号字段与方法、StoredCredentialsStore 类、StoredAccount 文件。UsageService 预计从 906 行瘦身到 ~300 行。

**Files:**
- Modify: `macos/Sources/UsageBar/Providers/Claude/UsageService.swift`
- Modify: `macos/Sources/UsageBar/Models/StoredCredentials.swift`
- Delete: `macos/Sources/UsageBar/Models/StoredAccount.swift`

- [ ] **Step 5.1: 删 UsageService 字段**

在 `UsageService.swift` 类体里删除以下 `@Published` 和 private 字段：
- `@Published var isAwaitingCode = false`（line 11）
- `@Published private(set) var accountEmail: String?`（line 12）
- `@Published private(set) var accounts: [StoredAccount] = []`
- `@Published private(set) var activeAccountId: UUID?`
- `private var accountSwitchEpoch: Int = 0`
- `private var currentFetchTask: Task<Void, Never>?`
- `private var refreshTask: Task<RefreshResult, Never>?`
- `private let credentialsStore: StoredCredentialsStore`（构造器参数也删，default 调用点改）
- `private let localProfileLoader: @MainActor () -> String?`（构造器参数删）
- `private let tokenEndpoint: URL`、`private let userinfoEndpoint: URL`、`private let redirectUri: String`、`private let clientId: String`
- `private var codeVerifier: String?`、`private var oauthState: String?`
- `nonisolated static let defaultOAuthScopes`、`nonisolated private static let authorizeEndpoint` / `defaultUserinfoEndpoint` / `defaultTokenEndpoint` / `defaultRedirectURI`
- `private enum RefreshResult`

构造器 `init(...)` 参数清理：保留 `session`, `usageEndpoint`, `usageStats`；删 `userinfoEndpoint`, `tokenEndpoint`, `redirectUri`, `credentialsStore`, `localProfileLoader`。

init body 简化为：
```swift
init(
    session: URLSession = .shared,
    usageEndpoint: URL = UsageService.defaultUsageEndpoint,
    usageStats: UsageStatsService = .shared
) {
    self.usageStats = usageStats
    self.session = session
    self.usageEndpoint = usageEndpoint
    let stored = UserDefaults.standard.integer(forKey: "pollingMinutes")
    let minutes = Self.pollingOptions.contains(stored) ? stored : Self.defaultPollingMinutes
    self.pollingMinutes = minutes
    self.runtime = ProviderRuntime()
    self.runtimeAuthSync = self.$isAuthenticated.sink { [runtime] authed in
        runtime.setConfigured(authed)
    }
}
```

`accountSwitchEpoch` 已删 → fetchUsage 中所有 `guard accountSwitchEpoch == epochAtStart` race-guard 行也删（已无意义）。

- [ ] **Step 5.2: 删 UsageService 方法**

删除以下 method 及其整段 extension：
- `switchAccount(to:)`、`addAccount(...)`、`removeAccount(...)`、`saveAccounts(...)` 等多账号 API
- `bootstrapFromCLIIfNeeded()`
- `migrateStripCLIRefreshToken()`
- `expireSession()`
- `attemptCLIKeychainRecovery()`
- `refreshCredentials(force:)`、`performRefresh(force:)`、`credentials(from:fallback:)`
- `expirationDate(from:)`
- `fetchProfile()`、`loadLocalProfile()`
- `sendAuthorizedRequest(...)` （整个方法）
- `loadCredentials()`、`saveCredentials(_:)`、`deleteCredentials()`
- 整段 "MARK: - OAuth & Credentials" extension
- 整段 "MARK: - Refresh + Token rotation" extension（其中的 `performRefresh`/`credentials(from:)`/`expirationDate(from:)`）
- "MARK: Profile" 段

保留：
- `@Published var usage`, `lastError`, `lastUpdated`, `isAuthenticated`
- `@Published var pollingMinutes` + `updatePollingInterval`
- `runtime` + `runtimeAuthSync`
- `historyService`/`notificationService`/`usageStats` 字段
- `currentBackoffSeconds`/`backoffUntil`/`baseInterval`/`pct5h`/`pct7d`/`pctExtra`
- `onPollTick`
- `cliKeychainLoader`（Task 1 改成 (Bool) async -> StoredCredentials?）
- `ensureFreshCredentials`/`retrySignIn`（Task 1/3 新增）
- `fetchUsage`/`processUsageResponse`（Task 2 重写）
- `performAuthorizedRequest`
- UsageProvider conformance 整段
- pollingOptions / defaultPollingMinutes / maxBackoffInterval 静态常量
- `backoffInterval(retryAfter:currentInterval:)` 静态方法
- `defaultUsageEndpoint` 静态常量
- "MARK: - Base64URL" extension（Data extension，给 PKCE 用，但 fetchUsage 中通过 oauth-2025-04-20 header 可能不需要 - **需 grep 确认**：`grep -n base64URLEncoded macos/Sources/UsageBar/Providers/Claude/UsageService.swift`，若只在 OAuth 段使用则删；如有其它 caller 保留。

- [ ] **Step 5.3: 删 StoredAccount.swift 文件**

Run: `git rm macos/Sources/UsageBar/Models/StoredAccount.swift`

- [ ] **Step 5.4: 删 StoredCredentialsStore 类（保留 StoredCredentials struct）**

把 `macos/Sources/UsageBar/Models/StoredCredentials.swift` 改成只剩：

```swift
import Foundation

struct StoredCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]

    var hasRefreshToken: Bool {
        guard let refreshToken else { return false }
        return refreshToken.isEmpty == false
    }

    func needsRefresh(at now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard hasRefreshToken, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

extension StoredCredentials {
    /// CLI 只读路径专用：返回不含 refreshToken 的副本，避免持有 CLI 的 refresh token
    /// 导致 OAuth Token Rotation 使 Claude Code 被迫退出登录（issue #22）。
    func strippingRefreshToken() -> StoredCredentials {
        StoredCredentials(accessToken: accessToken, refreshToken: nil, expiresAt: expiresAt, scopes: scopes)
    }
}
```

整段 `StoredCredentialsStore` class 删除。

- [ ] **Step 5.5: 跑 build 确认**

Run: `cd macos && swift build 2>&1 | tail -20`
Expected: ⚠️ 可能有遗留 reference 编译错。逐个修：
- 若有 UsageServiceMultiAccountTests / StoredCredentialsStoreMigrationTests 引用已删 symbol → **下个 task 5 step 删这些测试**；本 step 先把生产代码 build 跑通，测试 build 失败可暂忽略。
- 用 `cd macos && swift build --target UsageBar 2>&1 | tail -20` 只 build app target，跳过测试。

Run: `cd macos && swift build --target UsageBar 2>&1 | tail -5`
Expected: Build succeeded.

- [ ] **Step 5.6: Commit**

```bash
git add macos/Sources/UsageBar/Providers/Claude/UsageService.swift \
        macos/Sources/UsageBar/Models/StoredCredentials.swift
git rm macos/Sources/UsageBar/Models/StoredAccount.swift 2>/dev/null || true
git commit -m "refactor(claude-creds): 删 OAuth/refresh/多账号/StoredCredentialsStore 整套

v0.5.1 task 5: UsageService 大瘦身 906 → ~300 行. 一次性删除:

UsageService 字段:
- isAwaitingCode, accountEmail, accounts, activeAccountId, accountSwitchEpoch
- currentFetchTask, refreshTask, credentialsStore, localProfileLoader
- tokenEndpoint, userinfoEndpoint, redirectUri, clientId, codeVerifier, oauthState
- defaultOAuthScopes 等 OAuth 常量

UsageService 方法:
- switchAccount/addAccount/removeAccount/saveAccounts
- bootstrapFromCLIIfNeeded/migrateStripCLIRefreshToken
- expireSession/attemptCLIKeychainRecovery
- refreshCredentials/performRefresh/credentials(from:)/expirationDate(from:)
- fetchProfile/loadLocalProfile
- sendAuthorizedRequest (整方法; 被新 fetchUsage 替代)
- loadCredentials/saveCredentials/deleteCredentials

整文件删:
- Models/StoredAccount.swift

整段删:
- StoredCredentialsStore class (保留 StoredCredentials struct + helpers)

测试编译预期失败 (UsageServiceMultiAccountTests/StoredCredentialsStoreMigrationTests
依赖被删 symbol) - 下个 task 处理.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 删退役测试 + 改造保留测试

**目的：** 删多账号 / OAuth refresh / bootstrap / migration 相关测试整文件 + UsageServiceTests 内单 case；改造 3 个仍有意义的 case 走 in-memory 路径。

**Files:**
- Delete: `macos/Tests/UsageBarTests/UsageServiceMultiAccountTests.swift`
- Delete: `macos/Tests/UsageBarTests/StoredCredentialsStoreMigrationTests.swift`
- Modify: `macos/Tests/UsageBarTests/UsageServiceTests.swift`（删 17 个 case + 改造 3 个）

- [ ] **Step 6.1: 删整文件**

```bash
cd /Users/methol/data/code-methol/usage-bar
git rm macos/Tests/UsageBarTests/UsageServiceMultiAccountTests.swift \
       macos/Tests/UsageBarTests/StoredCredentialsStoreMigrationTests.swift
```

- [ ] **Step 6.2: UsageServiceTests 内删 17 个 case**

打开 `UsageServiceTests.swift`，删除以下测试方法（按 line 顺序，整段函数 body 一起删）：
1. `testFetchUsageRefreshesOn401AndRetriesOnce`（line 25）
2. `testFetchUsageDoesNotSignOutWhenRetriedRequestIsRateLimited`（line 105）
3. `testFetchUsageSignsOutWhenRefreshFails`（line 198）
4. `testFetchProfileDoesNotSignOutWhenUserinfoStillReturns401AfterRefresh`（line 246）
5. `testServer500DuringRefreshStaysAuthenticated`（line 309）
6. `testNetworkErrorDuringRefreshStaysAuthenticated`（line 352）
7. `testExpiredTokenWithTransientRefreshFailureDoesNotMakeAPICall`（line 395）
8. `testExpiredTokenWithPermanentRefreshFailureSignsOut`（line 438）
9. `testRecoversFromKeychainOnPermanentRefreshFailure`（line 522）
10. `testHardExpiresWhenKeychainEmpty`（line 534）
11. `testNoRecoveryLoopWhenKeychainHasSameStaleToken`（line 547）
12. `testHardExpiresWhenKeychainTokenAlreadyExpired`（line 557）
13. `testNoRecoveryWhenMultipleAccounts`（line 570）
14. `testNormalRefreshSuccessDoesNotTouchKeychain`（line 613）
15. `testEndToEndRefreshRecoveryAcrossMultiplePolls`（line 658）
16. `testEndToEnd401WithTransientFailureThenRecovery`（line 763）
17. `testBootstrapDoesNotSaveRefreshToken`（line 898）
18. `testMigrationStripsRefreshTokenMatchingKeychain`（line 925）
19. `testMigrationDoesNotAffectDifferentRefreshToken`（line 963）
20. `testKeychainRecoveryDoesNotSaveRefreshToken`（line 999）

保留（3 case）：
- `testBackoffIntervalCapsAtSixtyMinutes`（line 11）
- `testBackoffIntervalNeverReducesSixtyMinutePolling`（line 18）
- `testFetchUsageSuccessClearsBackoff`（line 171）— 若该 case 用了 sendAuthorizedRequest 等被删 API，改造它走 fetchUsage + cliKeychainLoader spy + StubProtocol

预计 UsageServiceTests.swift 行数从 ~1100 → ~150 行。

- [ ] **Step 6.3: 跑 build 确认**

Run: `cd macos && swift build 2>&1 | tail -10`
Expected: Build succeeded.

Run: `cd macos && swift test 2>&1 | tail -10`
Expected: 全绿（删 ~20 case + 改 ~3 case 之后无失败用例）。

- [ ] **Step 6.4: 跑 grep 兜底 SC_AUTO_GREP_* 检查**

```bash
grep -rEn 'accounts\.json|credentials\.json|\.write\(to: *credentialsFileURL' macos/Sources/UsageBar/ --include='*.swift'
```
Expected: 空输出。

```bash
grep -rn 'AccountSwitcherView' macos/Sources/UsageBar/ --include='*.swift'
```
Expected: 空输出。

```bash
grep -rEn 'StoredCredentialsStore|StoredAccount\b' macos/Sources/UsageBar/ --include='*.swift'
```
Expected: 空输出。

⚠️ 若某条命中：回去检查残留并补删。

- [ ] **Step 6.5: Commit**

```bash
git add macos/Tests/UsageBarTests/UsageServiceTests.swift
git rm macos/Tests/UsageBarTests/UsageServiceMultiAccountTests.swift 2>/dev/null || true
git rm macos/Tests/UsageBarTests/StoredCredentialsStoreMigrationTests.swift 2>/dev/null || true
git commit -m "test(claude-creds): 删多账号/OAuth refresh 测试 ~20 case + 2 整文件

v0.5.1 task 6: 退役测试清理.

整文件删:
- UsageServiceMultiAccountTests.swift
- StoredCredentialsStoreMigrationTests.swift

UsageServiceTests.swift 删 17 case (testFetchUsageRefreshesOn401AndRetriesOnce
等), 保留 3 case (backoff cap/reduce + FetchUsageSuccessClearsBackoff 改造走
in-memory).

swift test 全绿; grep 兜底 SC_AUTO_GREP_NO_CREDS_WRITE/NO_ACCOUNT_VIEW/
NO_STORE_TYPE 均空命中.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: 文档同步（版本文档 + README + CHANGELOG + 删 reviews:dispatched 标记）

**目的：** 立 v0.5.1 版本文档；更新 docs/versions/README.md 表格；写 CHANGELOG entry；spec status → implemented 暂缓（G6 closeout 才做，此 task 仅写 verification log 占位）。

**Files:**
- Create: `macos/../docs/versions/v0.5.1-claude-credentials-in-memory.md`
- Modify: `docs/versions/README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 7.1: 写 v0.5.1 版本文档**

参考 `docs/versions/_TEMPLATE.md` 与 `docs/versions/v0.6.0-gemini-provider.md` 风格，创建 `docs/versions/v0.5.1-claude-credentials-in-memory.md`：

```markdown
---
slug: v0.5.1-claude-credentials-in-memory
title: Claude 凭证改 in-memory only
type: version
status: in-progress
target_date: 2026-05-14
shipped_date: null
target_version: v0.5.1
codename: claude-credentials-in-memory
specs:
  - 2026-05-14-claude-credentials-in-memory
adrs: []
created: 2026-05-14
updated: 2026-05-14
---

# v0.5.1 — Claude 凭证改 in-memory only

## 主题

usage-bar 不再持久化 Claude 凭证。in-memory cache + 从 Claude CLI Keychain 重读；OAuth refresh / 多账号 UI 全部下线。

## 验收

见 spec [2026-05-14-claude-credentials-in-memory](../superpowers/specs/2026-05-14-claude-credentials-in-memory.md) §SC1-SC10。

## Release notes 草稿

**Removed**

- Local credentials persistence (`~/.config/usage-bar/credentials.json` and `accounts.json` are no longer written). Existing files are ignored; users can delete them manually.
- Multi-account UI inside Claude provider (`AccountSwitcherView` removed). Use Claude CLI to manage your active session; "multi-account" now means "multiple providers" (Claude / Codex / Gemini).
- Built-in OAuth refresh flow inside usage-bar. Token refresh is now fully delegated to Claude CLI.

**Fixed**

- "Not signed in" state being stuck after token expiry — Retry button now actually re-reads the Keychain (was previously short-circuited).
- Issue #22 class of failures (CLI logged out after rotation): structurally impossible now, usage-bar holds no refresh_token.

## 升级路径

无需用户操作。首次启动新版本时：
- 若 Claude CLI Keychain 中有有效 token：30s 内 popover 自动恢复显示用量。
- 若 ACL 未授权：弹一次 Keychain 授权框，点 Always Allow 即可。
- 旧 `~/.config/usage-bar/accounts.json` + `credentials.json` 不会被读取也不会被覆盖；用户可自行 `rm` 清理。
```

- [ ] **Step 7.2: 更新 docs/versions/README.md 表格**

在 v0.5.0 行之后插入 v0.5.1 行（找 v0.5.0 行的 grep：`grep -n 'v0.5.0' docs/versions/README.md`），保持表格格式一致：

```markdown
| [v0.5.1](./v0.5.1-claude-credentials-in-memory.md) | claude-credentials-in-memory | in-progress | ⏸ | | 2026-05-14 | 🔧 Claude 凭证改 in-memory only（删持久化 / 多账号 UI / OAuth refresh；纯 CLI Keychain 借读）|
```

- [ ] **Step 7.3: 写 CHANGELOG entry**

打开 `CHANGELOG.md`，参考最近 entry 格式（如 v0.6.0 / v0.4.1），在最顶部插入：

```markdown
## v0.5.1 — 2026-05-14

### Removed

- usage-bar no longer persists Claude credentials to disk. The in-memory cache is repopulated from Claude CLI's Keychain item on launch and on token expiry. Existing `~/.config/usage-bar/credentials.json` / `accounts.json` files are ignored; users can delete them manually.
- Multi-account UI inside the Claude provider (`AccountSwitcherView` removed). `Account switcher` / `Add account` menus retired. Use Claude CLI to switch active sessions; multi-account now means multiple providers (Claude / Codex / Gemini).
- Built-in OAuth refresh inside usage-bar. Token refresh is fully delegated to Claude CLI.

### Fixed

- Stuck "Not signed in" state after token expiry. Retry button now actually re-reads the Keychain (previously short-circuited when an `accounts.json` was present).
- Removes the entire class of OAuth Token Rotation failures (issue #22) by no longer holding refresh tokens.
```

- [ ] **Step 7.4: build + test 兜底**

Run: `cd macos && swift test 2>&1 | tail -5`
Expected: 全绿。

- [ ] **Step 7.5: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add docs/versions/v0.5.1-claude-credentials-in-memory.md \
        docs/versions/README.md CHANGELOG.md
git commit -m "docs(v0.5.1): 立项 + CHANGELOG + README 表格更新

v0.5.1 task 7: 文档同步.

- 新 docs/versions/v0.5.1-claude-credentials-in-memory.md (frontmatter +
  主题 + 验收引 spec + release notes 草稿 + 升级路径)
- docs/versions/README.md 表格加 v0.5.1 行 (in-progress / 2026-05-14)
- CHANGELOG.md 顶部加 v0.5.1 entry: Removed/Fixed

spec status: draft → approved 已在 G2 阶段做; implemented 留待 G6 closeout.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: 真机验证 + verification log 勾选

**目的：** make app + install + 跑 5 个真机 SC（SC1/SC2/SC3/SC5/SC7）+ 自动化 SC（SC6/SC8/SC9）；spec verification log 全勾。

**Files:**
- Modify: `docs/superpowers/specs/2026-05-14-claude-credentials-in-memory.md`（verification log + spec_criteria done=true）

- [ ] **Step 8.1: 跑自动化 check**

```bash
cd macos && swift build -c release 2>&1 | tail -3
# Expected: Build succeeded.

cd macos && swift test 2>&1 | tail -3
# Expected: All tests passed.

! grep -rEn 'accounts\.json|credentials\.json|\.write\(to: *credentialsFileURL' macos/Sources/UsageBar/ --include='*.swift'
# Expected: exit 0 (无命中)

! grep -rn 'AccountSwitcherView' macos/Sources/UsageBar/ --include='*.swift'
# Expected: exit 0 (无命中)

! grep -rEn 'StoredCredentialsStore|StoredAccount\b' macos/Sources/UsageBar/ --include='*.swift'
# Expected: exit 0 (无命中)

cd /Users/methol/data/code-methol/usage-bar
make release-artifacts 2>&1 | tail -10
# Expected: 末尾 == Codesign verified OK + verify-release 全 OK
```

记录每条 evidence（commit sha / log 路径）。

- [ ] **Step 8.2: SC1 真机 — Keychain 有有效 token → 自动恢复**

前置确认 Keychain 有有效 token：
```bash
security find-generic-password -s 'Claude Code-credentials' -a "$USER" -g 2>&1 | grep expiresAt
# 若 expiresAt 时间戳已过期：在 Claude CLI 跑一次 `claude --version` 或一条 prompt 触发 refresh
```

安装 + 启动：
```bash
osascript -e 'tell application "UsageBar" to quit' 2>&1
sleep 1
rm -rf /Applications/UsageBar.app
cp -R /Users/methol/data/code-methol/usage-bar/macos/UsageBar.app /Applications/
open /Applications/UsageBar.app
sleep 5
```

打开 popover（点菜单栏 UsageBar 图标）确认 Claude 区显示数据（有 5h / 7d window）。

Evidence: 截图或 verify with `osascript -e 'tell application "System Events" to count windows of process "UsageBar"'`。

- [ ] **Step 8.3: SC2 真机 — Keychain 无 → Sign in prompt**

```bash
osascript -e 'tell application "UsageBar" to quit' 2>&1
sleep 1
# 备份并清 Keychain item (后面会还原):
security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w > /tmp/keychain-backup.txt
security delete-generic-password -s 'Claude Code-credentials' -a "$USER" 2>&1
open /Applications/UsageBar.app
sleep 5
```

打开 popover 确认显示 "Not signed in" + "Sign in with Claude CLI, then tap Retry"。

恢复 Keychain：
```bash
security add-generic-password -s 'Claude Code-credentials' -a "$USER" -w "$(cat /tmp/keychain-backup.txt)" 2>&1
rm /tmp/keychain-backup.txt
```

- [ ] **Step 8.4: SC3 真机 — token 过期 → Token expired 提示**

通过 Claude CLI 的 keychain 写一个过期 token 测试。最简：让 keychain 自然过期太慢，改用单测断言（已有 testFetchUsage401SameTokenReportsExpired 覆盖此路径）。

Evidence: 引用 testFetchUsage401SameTokenReportsExpired 通过结果。

- [ ] **Step 8.5: SC5 真机 — 清旧文件后恢复**

```bash
osascript -e 'tell application "UsageBar" to quit' 2>&1
sleep 1
ls -la ~/.config/usage-bar/
rm ~/.config/usage-bar/credentials.json ~/.config/usage-bar/accounts.json 2>/dev/null
ls -la ~/.config/usage-bar/
open /Applications/UsageBar.app
sleep 35   # 等首轮 polling tick
ls -la ~/.config/usage-bar/   # 确认 credentials.json / accounts.json 不被重建
```

- [ ] **Step 8.6: SC7 — UI 不再有 AccountSwitcherView**

```bash
grep -rn 'AccountSwitcherView' macos/Sources/ --include='*.swift' || echo 'PASS: AccountSwitcherView not referenced'
```
Expected: PASS。

- [ ] **Step 8.7: 在 spec 文件 verification log 勾选 SC + 填 evidence**

打开 `docs/superpowers/specs/2026-05-14-claude-credentials-in-memory.md`，把 `## Verification log` 段的 `- [ ] SC1 — pending` 改成 `- [x] SC1 — 真机验证：xxx`（含 git sha / log 路径）。同样改 SC2~SC10。

同时 spec frontmatter `spec_criteria` 各条 `done: false` → `done: true`，`evidence: null` → 简短一句说明。

- [ ] **Step 8.8: Commit**

```bash
git add docs/superpowers/specs/2026-05-14-claude-credentials-in-memory.md
git commit -m "docs(v0.5.1): G4 verification log 全勾 + spec_criteria 全 done=true

v0.5.1 task 8: 真机 + 自动化 SC 验证.

- SC1/SC2/SC5/SC7 真机操作通过 (Keychain 有效→恢复 / 无→Sign in / 清旧文件→自恢
  复 / UI 无 AccountSwitcherView)
- SC3 单测覆盖 (testFetchUsage401SameTokenReportsExpired)
- SC6 grep 兜底空命中
- SC8 swift test 全绿
- SC9 make release-artifacts + verify-release.sh 全 OK
- SC10 CHANGELOG v0.5.1 entry 已落 (task 7)

spec_criteria 全 done=true, verification log 全勾.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: G5 PR + ultrareview + merge

**目的：** 开 PR，跑 ultrareview，merge 到 main。

**Files:**
- New branch: `feat/v0.5.1-claude-credentials-in-memory`
- Open: PR to origin/main

- [ ] **Step 9.1: 推 branch**

```bash
cd /Users/methol/data/code-methol/usage-bar
git switch -c feat/v0.5.1-claude-credentials-in-memory
git push -u origin feat/v0.5.1-claude-credentials-in-memory
```

- [ ] **Step 9.2: 开 PR**

```bash
gh pr create --base main --head feat/v0.5.1-claude-credentials-in-memory \
  --title "feat(v0.5.1): Claude 凭证改 in-memory only" \
  --body "$(cat <<'EOF'
## Summary

- usage-bar 不再持久化 Claude 凭证（accounts.json / credentials.json 写入路径全删）；in-memory cache + 从 CLI Keychain 重读。
- 多账号 UI（AccountSwitcherView / StoredAccount / accountSwitchEpoch / 双写 v1+v2）整体下线。
- OAuth refresh 路径删除；refresh 完全交给 Claude CLI。
- 修 #N: Retry 按钮失效 (bootstrapFromCLIIfNeeded 短路问题)。

UsageService 从 906 行瘦身到 ~300 行；删 ~20 个测试 case + 2 整测试文件；新增 6 个 in-memory 行为测试。

## Spec

[2026-05-14-claude-credentials-in-memory](docs/superpowers/specs/2026-05-14-claude-credentials-in-memory.md) — G2 approved。

## Test plan

- [x] swift test 全绿
- [x] make release-artifacts + verify-release.sh 全 OK
- [x] 真机 SC1/SC2/SC5/SC7 通过
- [x] SC3 单测覆盖
- [x] grep 兜底 SC_AUTO_GREP_NO_CREDS_WRITE/NO_ACCOUNT_VIEW/NO_STORE_TYPE 空命中

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 9.3: 跑 ultrareview**

用户操作：在 Claude Code 里执行 `/ultrareview <PR#>`（AI 无法自启）。等 review 结果。

- [ ] **Step 9.4: 解决 review 反馈**（如有）

按 review verdict 修；reviewer 全 approved 后进 Step 9.5。

- [ ] **Step 9.5: merge**

```bash
gh pr merge <PR#> --squash --delete-branch
```

- [ ] **Step 9.6: spec status → implemented + 关 G7**

```bash
git switch main && git pull
sed -i '' 's/^status: approved/status: implemented/' docs/superpowers/specs/2026-05-14-claude-credentials-in-memory.md
git add docs/superpowers/specs/2026-05-14-claude-credentials-in-memory.md
git commit -m "docs(v0.5.1): G6 closeout — spec status: approved → implemented"
git push origin main
```

---

## 验证总览

最后跑一遍：

```bash
cd macos
swift build -c release && swift test
cd ..
make release-artifacts
```

Expected：
- Build succeeded
- All tests passed
- DMG + ZIP 产出 + verify-release.sh 4 项检查全绿
