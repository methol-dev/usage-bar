# Gemini Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 usage-bar 中接入第三条 provider — Gemini Code Assist for Individuals(个人 OAuth),提供 Pro / Flash 两段配额显示 + 历史折线 + 设置页集成,完整对标 Codex 现有形态(本机统计明确不做,推迟到后续 iteration)。

**Architecture:** 沿用 `CodexProvider` 模板结构:`GeminiCredentials`(本机 `~/.gemini/oauth_creds.json` 读取 + Google OAuth refresh)+ `GeminiOAuthClientLocator`(从本机 gemini-cli 安装目录 regex 抠 client_id/secret)+ `GeminiUsageClient`(调 `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` + `retrieveUserQuota`)+ `GeminiUsageModel`(per-model 数组 → Pro/Flash 槽位映射)+ `GeminiProvider`(主体 + 重入闸门 + 错误映射 + 历史样本)。后台 polling 走 `ProviderCoordinator` 统一 timer,不自持。`UsageBarApp` 在 `additionalProviders` 加 `GeminiProvider()`。SettingsView / MenuBar / Popover 自动按 `ProviderID.allCases` 渲染,无需额外 wire。

**Tech Stack:** Swift 5.9 + Swift Concurrency(`@MainActor` / async-await)+ SwiftUI + URLSession(URLProtocol mock 测试)+ XCTest + JSONSerialization / Codable。

**Spec:** `docs/superpowers/specs/2026-05-13-gemini-provider.md`(已 G2 approved)。

**改动面**:6 个新源文件 + 1 修改(UsageBarApp.swift)+ 6 测试文件 + 1 README 段 + 1 fixture 目录。

---

## Task 1: GeminiCredentials + GeminiCredentialStore(只读)

**Files:**
- Create: `macos/Sources/UsageBar/Providers/Gemini/GeminiCredentials.swift`
- Create: `macos/Tests/UsageBarTests/GeminiCredentialsTests.swift`

**目标**:实现 `~/.gemini/oauth_creds.json` 解析(只读,不含 refresh)。环境注入 `GEMINI_HOME` 以便测试,模仿 `CodexCredentialStore` 的 `CODEX_HOME` 模式。

- [ ] **Step 1: 写 6 个失败测试**

文件 `macos/Tests/UsageBarTests/GeminiCredentialsTests.swift`:

```swift
import XCTest
@testable import UsageBar

final class GeminiCredentialsTests: XCTestCase {

    private func makeGeminiHome(credsJSON: String?) throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let credsJSON {
            try Data(credsJSON.utf8).write(to: dir.appendingPathComponent("oauth_creds.json"))
        }
        return ["GEMINI_HOME": dir.path]
    }

    func testLoadAllFields() throws {
        let env = try makeGeminiHome(credsJSON: """
        { "access_token": "ACCESS_SENTINEL",
          "refresh_token": "REFRESH_SENTINEL",
          "token_type": "Bearer",
          "expiry_date": 1750000000000,
          "id_token": "ID_SENTINEL",
          "scope": "https://www.googleapis.com/auth/cloud-platform" }
        """)
        let creds = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        XCTAssertEqual(creds.accessToken, "ACCESS_SENTINEL")
        XCTAssertEqual(creds.refreshToken, "REFRESH_SENTINEL")
        XCTAssertEqual(creds.tokenType, "Bearer")
        XCTAssertEqual(creds.expiryDate, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(creds.idToken, "ID_SENTINEL")
        XCTAssertEqual(creds.scope, "https://www.googleapis.com/auth/cloud-platform")
    }

    func testLoadMinimalFields() throws {
        let env = try makeGeminiHome(credsJSON: """
        { "access_token": "ACCESS_SENTINEL", "token_type": "Bearer" }
        """)
        let creds = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        XCTAssertEqual(creds.accessToken, "ACCESS_SENTINEL")
        XCTAssertNil(creds.refreshToken)
        XCTAssertNil(creds.expiryDate)
    }

    func testLoadMissingAccessTokenThrows() throws {
        let env = try makeGeminiHome(credsJSON: #"{ "refresh_token": "R" }"#)
        XCTAssertThrowsError(try GeminiCredentialStore.load(environment: env)) { error in
            XCTAssertTrue(error is GeminiCredentialError)
        }
    }

    func testLoadInvalidJSONThrows() throws {
        let env = try makeGeminiHome(credsJSON: "not json {{{")
        XCTAssertThrowsError(try GeminiCredentialStore.load(environment: env))
    }

    func testLoadFileAbsentReturnsNil() throws {
        let env = try makeGeminiHome(credsJSON: nil)
        XCTAssertNil(try GeminiCredentialStore.load(environment: env))
    }

    func testLoadRespectsGeminiHome() throws {
        let env = try makeGeminiHome(credsJSON: #"{ "access_token": "A", "token_type": "Bearer" }"#)
        XCTAssertNotNil(try GeminiCredentialStore.load(environment: env))
        XCTAssertEqual(GeminiCredentialStore.credsFileURL(environment: env).lastPathComponent, "oauth_creds.json")
        XCTAssertTrue(GeminiCredentialStore.credsFileURL(environment: env).path.hasPrefix(env["GEMINI_HOME"]!))
    }

    func testCredentialErrorDescriptionHasNoRawValues() {
        for e in [GeminiCredentialError.malformed, GeminiCredentialError.missingAccessToken] {
            let s = "\(e)"
            XCTAssertFalse(s.contains("SENTINEL"))
            XCTAssertFalse(s.contains("{"))
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd macos && swift test --filter GeminiCredentialsTests 2>&1 | tail -20`
Expected: 编译错(`GeminiCredentialStore` / `GeminiCredentials` / `GeminiCredentialError` 未定义)

- [ ] **Step 3: 写 GeminiCredentials 实现**

新建目录 + 文件 `macos/Sources/UsageBar/Providers/Gemini/GeminiCredentials.swift`:

```swift
import Foundation

/// 从本机 gemini-cli 已登录的 `~/.gemini/oauth_creds.json` 读出来的凭证。
/// 字段对齐 google-auth-library 的 `Credentials` 接口(见 gemini-cli `packages/core/src/code_assist/oauth2.ts`)。
/// 本 spec 阶段:**只读**;refresh 在 Task 3 实现。
struct GeminiCredentials: Equatable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String?
    /// `expiry_date` 上游用毫秒 epoch;此处统一转 Swift `Date`(秒)。
    var expiryDate: Date?
    var idToken: String?
    var scope: String?

    /// `expiryDate` 已过期(留 60s 缓冲),返回 true。`expiryDate` 缺失也算需刷新(谨慎)。
    func isExpired(now: Date = Date()) -> Bool {
        guard let exp = expiryDate else { return true }
        return exp.timeIntervalSince(now) < 60
    }
}

enum GeminiCredentialError: Error, CustomStringConvertible {
    case malformed
    case missingAccessToken

    var description: String {
        switch self {
        case .malformed:           return "malformed"
        case .missingAccessToken:  return "missingAccessToken"
        }
    }
}

enum GeminiCredentialStore {
    /// `~/.gemini/oauth_creds.json`;`GEMINI_HOME` 设了就用 `$GEMINI_HOME/oauth_creds.json`。
    static func credsFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home: URL
        if let geminiHome = environment["GEMINI_HOME"], !geminiHome.isEmpty {
            home = URL(fileURLWithPath: geminiHome, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
        }
        return home.appendingPathComponent("oauth_creds.json")
    }

    /// 文件不存在 → nil(静默);存在但坏 → throw `GeminiCredentialError`。
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> GeminiCredentials? {
        let url = credsFileURL(environment: environment)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> GeminiCredentials {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GeminiCredentialError.malformed
        }
        guard let accessToken = obj["access_token"] as? String, !accessToken.isEmpty else {
            throw GeminiCredentialError.missingAccessToken
        }
        let expiry: Date?
        if let ms = obj["expiry_date"] as? Double {
            expiry = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let ms = obj["expiry_date"] as? Int {
            expiry = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        } else {
            expiry = nil
        }
        return GeminiCredentials(
            accessToken: accessToken,
            refreshToken: obj["refresh_token"] as? String,
            tokenType: obj["token_type"] as? String,
            expiryDate: expiry,
            idToken: obj["id_token"] as? String,
            scope: obj["scope"] as? String
        )
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd macos && swift test --filter GeminiCredentialsTests 2>&1 | tail -10`
Expected: `Test Suite 'GeminiCredentialsTests' passed` + 7 tests passed

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/UsageBar/Providers/Gemini/GeminiCredentials.swift \
        macos/Tests/UsageBarTests/GeminiCredentialsTests.swift
git commit -m "feat(gemini): GeminiCredentials + Store 只读层(SC2 / SC5 基础)"
```

---

## Task 2: GeminiOAuthClientLocator(三处枚举 + regex 抠 client_id/secret)

**Files:**
- Create: `macos/Sources/UsageBar/Providers/Gemini/GeminiOAuthClientLocator.swift`
- Create: `macos/Tests/UsageBarTests/GeminiOAuthClientLocatorTests.swift`
- Create: `macos/Tests/UsageBarTests/Fixtures/Gemini/oauth2-fixture.js`(mock gemini-cli 片段,只为测试 regex)

**目标**:三处候选路径枚举(homebrew / npm global / bun)+ regex 匹 `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET`。失败 → nil(provider 走 unconfigured 态)。fixture 不真分发 secret,用占位 `FIXTURE_CLIENT_*`。

- [ ] **Step 1: 写 fixture**

新建目录 + 文件 `macos/Tests/UsageBarTests/Fixtures/Gemini/oauth2-fixture.js`(放在 SwiftPM 已有的 `Fixtures/` 资源目录):

```javascript
// Mocked excerpt of gemini-cli's packages/core/dist/.../oauth2.js for regex testing only.
// Values are deliberately fake (FIXTURE_*) — not real Google OAuth credentials.
const OAUTH_CLIENT_ID = 'FIXTURE_CLIENT_ID.apps.googleusercontent.com';
const OAUTH_CLIENT_SECRET = 'FIXTURE_CLIENT_SECRET_VALUE';
const OAUTH_REFRESH_TOKEN_KEY = 'refresh_token';
```

- [ ] **Step 2: 写 5 个失败测试**

文件 `macos/Tests/UsageBarTests/GeminiOAuthClientLocatorTests.swift`:

```swift
import XCTest
@testable import UsageBar

final class GeminiOAuthClientLocatorTests: XCTestCase {

    /// 在临时目录里造一个 gemini-cli 安装结构,把 fixture 拷过去当 oauth2.js。
    private func makeFakeInstall(at relativePath: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oauth2Dir = tmp.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: oauth2Dir, withIntermediateDirectories: true)
        let fixtureURL = Bundle.module.url(forResource: "oauth2-fixture", withExtension: "js", subdirectory: "Gemini")
            ?? URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Gemini/oauth2-fixture.js")
        let dst = oauth2Dir.appendingPathComponent("oauth2.js")
        try FileManager.default.copyItem(at: fixtureURL, to: dst)
        return tmp
    }

    func testHomebrewPathFound() throws {
        let tmp = try makeFakeInstall(at: "lib/node_modules/@google/gemini-cli-core/dist/src/code_assist")
        let locator = GeminiOAuthClientLocator(candidatePaths: [tmp])
        let result = try XCTUnwrap(locator.findClientIdSecret())
        XCTAssertEqual(result.clientId, "FIXTURE_CLIENT_ID.apps.googleusercontent.com")
        XCTAssertEqual(result.clientSecret, "FIXTURE_CLIENT_SECRET_VALUE")
    }

    func testNpmGlobalPathFound() throws {
        let tmp = try makeFakeInstall(at: "node_modules/@google/gemini-cli-core/dist/src/code_assist")
        let locator = GeminiOAuthClientLocator(candidatePaths: [tmp])
        XCTAssertNotNil(locator.findClientIdSecret())
    }

    func testNoOauth2JsReturnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let locator = GeminiOAuthClientLocator(candidatePaths: [tmp])
        XCTAssertNil(locator.findClientIdSecret())
    }

    func testCorruptedOauth2JsRegexMissReturnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oauth2Dir = tmp.appendingPathComponent("lib/node_modules/@google/gemini-cli-core/dist/src/code_assist")
        try FileManager.default.createDirectory(at: oauth2Dir, withIntermediateDirectories: true)
        try Data("// no client id here".utf8).write(to: oauth2Dir.appendingPathComponent("oauth2.js"))
        let locator = GeminiOAuthClientLocator(candidatePaths: [tmp])
        XCTAssertNil(locator.findClientIdSecret())
    }

    func testFirstCandidateWins() throws {
        let first = try makeFakeInstall(at: "lib/node_modules/@google/gemini-cli-core/dist/src/code_assist")
        let second = try makeFakeInstall(at: "lib/node_modules/@google/gemini-cli-core/dist/src/code_assist")
        // 两个都命中,locator 应取第一个就停。
        let locator = GeminiOAuthClientLocator(candidatePaths: [first, second])
        XCTAssertNotNil(locator.findClientIdSecret())
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd macos && swift test --filter GeminiOAuthClientLocatorTests 2>&1 | tail -10`
Expected: 编译错(`GeminiOAuthClientLocator` 未定义)

- [ ] **Step 4: 写 GeminiOAuthClientLocator 实现 + 注册 fixture 到 Package.swift**

文件 `macos/Sources/UsageBar/Providers/Gemini/GeminiOAuthClientLocator.swift`:

```swift
import Foundation

/// 从本机已安装的 gemini-cli 的 `oauth2.js` 中用 regex 抠出 OAuth client_id/secret。
///
/// **合规理由**:不在 app 二进制中硬编码 Google secret(避免二次分发),仅在运行时从用户本机
/// 已合法持有的 gemini-cli 安装中读取(详见 spec §2.2 / §3.5)。
final class GeminiOAuthClientLocator {
    struct Result: Equatable {
        let clientId: String
        let clientSecret: String
    }

    private let candidatePaths: [URL]
    private let fileManager: FileManager
    /// gemini-cli `code_assist/oauth2.js` 在三种主流安装方式下的相对路径。
    /// 末段固定为 `code_assist/oauth2.js`(上游 source code 路径稳定);中段差异主要在
    /// `lib/node_modules` (homebrew / npm global) vs `node_modules` (bun / 项目本地) vs `.bun/install/global/node_modules` (bun 全局)。
    static let oauth2RelativePathInside = "@google/gemini-cli-core/dist/src/code_assist/oauth2.js"

    init(candidatePaths: [URL]? = nil, fileManager: FileManager = .default) {
        self.candidatePaths = candidatePaths ?? Self.defaultCandidatePaths(fileManager: fileManager)
        self.fileManager = fileManager
    }

    /// 返回首个命中的 client_id/secret;全部失败返回 nil。
    func findClientIdSecret() -> Result? {
        for root in candidatePaths {
            guard let oauth2URL = locateOauth2Js(under: root) else { continue }
            guard let text = try? String(contentsOf: oauth2URL, encoding: .utf8) else { continue }
            guard let id = Self.match(in: text, key: "OAUTH_CLIENT_ID"),
                  let secret = Self.match(in: text, key: "OAUTH_CLIENT_SECRET") else { continue }
            return Result(clientId: id, clientSecret: secret)
        }
        return nil
    }

    /// 在 root 下递归找 `lib/node_modules/<oauth2RelativePathInside>` 或 `node_modules/<...>`。
    /// 不深度遍历整树(那太慢);只走两条已知模式的相对路径。
    private func locateOauth2Js(under root: URL) -> URL? {
        let candidates = [
            root.appendingPathComponent("lib/node_modules").appendingPathComponent(Self.oauth2RelativePathInside),
            root.appendingPathComponent("node_modules").appendingPathComponent(Self.oauth2RelativePathInside),
            // 测试 fixture 形态:tmp 直接指向 `<...>/code_assist/` 父级
            root.appendingPathComponent("lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
            root.appendingPathComponent("node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    /// 真机三处枚举:Homebrew 默认、npm global 默认、bun 全局。
    static func defaultCandidatePaths(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/opt/homebrew"),                         // Apple Silicon Homebrew
            URL(fileURLWithPath: "/usr/local"),                            // Intel Homebrew + npm global
            home.appendingPathComponent(".bun/install/global"),            // bun 全局
        ]
    }

    /// 匹配形如 `OAUTH_CLIENT_ID = 'value'` 或 `OAUTH_CLIENT_ID="value"`,捕获引号内的 value。
    static func match(in text: String, key: String) -> String? {
        let pattern = #"\#(key)\s*=\s*['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > 1,
              let valueRange = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }
}
```

注册 fixture:打开 `macos/Package.swift`,在 testTarget 的 `resources:` 段加 `.copy("Fixtures/Gemini")`(若没有该目录配置则改成 `.copy("Fixtures")`),确保 SwiftPM 把 fixture 拷进 test bundle。如果 testTarget 已经有 `resources:` 项,只追加;无 → 加完整段。验证 Package.swift 现有 resources 配置:

Run: `grep -n "resources\|Fixtures" macos/Package.swift`

如果发现 testTarget 已 `.copy("Fixtures")`,fixture 自动进 bundle,无须修改。否则在 `testTarget(name: "UsageBarTests", ..., resources: [.copy("Fixtures")])` 处补全。

- [ ] **Step 5: 跑测试 + commit**

```bash
cd macos && swift test --filter GeminiOAuthClientLocatorTests 2>&1 | tail -10
```
Expected: 5 tests passed

```bash
git add macos/Sources/UsageBar/Providers/Gemini/GeminiOAuthClientLocator.swift \
        macos/Tests/UsageBarTests/GeminiOAuthClientLocatorTests.swift \
        macos/Tests/UsageBarTests/Fixtures/Gemini/oauth2-fixture.js \
        macos/Package.swift
git commit -m "feat(gemini): OAuth client_id/secret locator + fixture(SC5 基础;合规规避二次分发)"
```

---

## Task 3: GeminiCredentialStore.refresh() — token 刷新 + 原子写回

**Files:**
- Modify: `macos/Sources/UsageBar/Providers/Gemini/GeminiCredentials.swift`(在 `GeminiCredentialStore` enum 中加 refresh)
- Modify: `macos/Tests/UsageBarTests/GeminiCredentialsTests.swift`(加 refresh 测试)

**目标**:实现 OAuth refresh — `POST https://oauth2.googleapis.com/token`,form-encoded body(client_id/client_secret/refresh_token/grant_type),拿到新 access_token 后**原子**写回 oauth_creds.json(temp + rename + 0600)。

**spec 风险 #7 缓解策略**:本 task 只实现 refresh + 写回逻辑,不实现 flock(策略 b);并发写竞态由"仅在 401 时触发 refresh"(策略 a,在 Task 6 实现)+ "失败走 unconfigured"(策略 c,在 Task 6 实现)兜底。

- [ ] **Step 1: 写 4 个失败测试**

追加到 `macos/Tests/UsageBarTests/GeminiCredentialsTests.swift`:

```swift
extension GeminiCredentialsTests {

    private func stubSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        GeminiOAuthStubURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GeminiOAuthStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    func testRefreshSuccessUpdatesAccessTokenAndExpiry() async throws {
        let env = try makeGeminiHome(credsJSON: """
        { "access_token": "OLD", "refresh_token": "REFRESH_SENTINEL", "token_type": "Bearer" }
        """)
        let session = stubSession { req in
            XCTAssertEqual(req.url?.absoluteString, "https://oauth2.googleapis.com/token")
            XCTAssertEqual(req.httpMethod, "POST")
            let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("refresh_token=REFRESH_SENTINEL"))
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("client_id=CID"))
            XCTAssertTrue(body.contains("client_secret=CSEC"))
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}"#.utf8))
        }
        defer { GeminiOAuthStubURLProtocol.handler = nil }

        let old = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        let updated = try await GeminiCredentialStore.refresh(credentials: old, clientId: "CID", clientSecret: "CSEC", session: session, environment: env)
        XCTAssertEqual(updated.accessToken, "NEW")
        XCTAssertEqual(updated.refreshToken, "REFRESH_SENTINEL", "refresh_token 未变(响应里没回则保留)")
        XCTAssertNotNil(updated.expiryDate)

        // 写回后再 load,应是新值。
        let reloaded = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        XCTAssertEqual(reloaded.accessToken, "NEW")
    }

    func testRefreshUnauthorizedThrows() async throws {
        let env = try makeGeminiHome(credsJSON: #"{ "access_token": "OLD", "refresh_token": "R", "token_type": "Bearer" }"#)
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        defer { GeminiOAuthStubURLProtocol.handler = nil }
        let old = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        do {
            _ = try await GeminiCredentialStore.refresh(credentials: old, clientId: "CID", clientSecret: "CSEC", session: session, environment: env)
            XCTFail("expected unauthorized")
        } catch GeminiRefreshError.unauthorized {
            // ok
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRefreshMissingRefreshTokenThrows() async throws {
        let env = try makeGeminiHome(credsJSON: #"{ "access_token": "OLD", "token_type": "Bearer" }"#)
        let old = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        do {
            _ = try await GeminiCredentialStore.refresh(credentials: old, clientId: "CID", clientSecret: "CSEC", session: .shared, environment: env)
            XCTFail("expected missingRefreshToken")
        } catch GeminiRefreshError.missingRefreshToken {
            // ok
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testRefreshAtomicWriteDoesNotLeavePartialFile() async throws {
        let env = try makeGeminiHome(credsJSON: #"{ "access_token": "OLD", "refresh_token": "R", "token_type": "Bearer" }"#)
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}"#.utf8))
        }
        defer { GeminiOAuthStubURLProtocol.handler = nil }
        let old = try XCTUnwrap(GeminiCredentialStore.load(environment: env))
        _ = try await GeminiCredentialStore.refresh(credentials: old, clientId: "CID", clientSecret: "CSEC", session: session, environment: env)
        // 临时文件不应残留
        let dir = URL(fileURLWithPath: env["GEMINI_HOME"]!)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("oauth_creds.json.") }
        XCTAssertTrue(leftovers.isEmpty, "残留临时文件:\(leftovers)")
    }
}

// 复用一个 URLProtocol stub(避免与其它 test 类的 stub 冲突)
private final class GeminiOAuthStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = GeminiOAuthStubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd macos && swift test --filter GeminiCredentialsTests 2>&1 | tail -15`
Expected: 编译错(`GeminiCredentialStore.refresh` / `GeminiRefreshError` 未定义)

- [ ] **Step 3: 写 refresh 实现**

追加到 `macos/Sources/UsageBar/Providers/Gemini/GeminiCredentials.swift`:

```swift
enum GeminiRefreshError: Error, CustomStringConvertible {
    case missingRefreshToken
    case unauthorized          // 400 / 401
    case server(status: Int)
    case network
    case decode

    var description: String {
        switch self {
        case .missingRefreshToken: return "missingRefreshToken"
        case .unauthorized:        return "unauthorized"
        case .server(let s):       return "server(\(s))"
        case .network:             return "network"
        case .decode:              return "decode"
        }
    }
}

extension GeminiCredentialStore {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// 用 refresh_token 换新 access_token。成功后**原子**写回 `oauth_creds.json`(0600);
    /// 失败不动文件。
    static func refresh(credentials creds: GeminiCredentials,
                        clientId: String,
                        clientSecret: String,
                        session: URLSession = .shared,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        now: Date = Date()) async throws -> GeminiCredentials {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            throw GeminiRefreshError.missingRefreshToken
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyParams = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        req.httpBody = Data(formEncode(bodyParams).utf8)

        let data: Data; let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GeminiRefreshError.network
        }
        guard let http = response as? HTTPURLResponse else { throw GeminiRefreshError.network }
        switch http.statusCode {
        case 200..<300: break
        case 400, 401, 403: throw GeminiRefreshError.unauthorized
        default: throw GeminiRefreshError.server(status: http.statusCode)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int?
            let token_type: String?
            let id_token: String?
            let scope: String?
            let refresh_token: String?
        }
        let parsed: TokenResponse
        do {
            parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GeminiRefreshError.decode
        }

        var updated = creds
        updated.accessToken = parsed.access_token
        if let exp = parsed.expires_in { updated.expiryDate = now.addingTimeInterval(TimeInterval(exp)) }
        if let t = parsed.token_type { updated.tokenType = t }
        if let id = parsed.id_token { updated.idToken = id }
        if let s = parsed.scope { updated.scope = s }
        if let r = parsed.refresh_token, !r.isEmpty { updated.refreshToken = r }   // Google 偶尔会回新 refresh_token

        try writeAtomically(credentials: updated, environment: environment)
        return updated
    }

    /// 写回 oauth_creds.json:tmp + rename + 0600 权限。schema 与 gemini-cli 完全一致。
    static func writeAtomically(credentials: GeminiCredentials,
                                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let dst = credsFileURL(environment: environment)
        let dir = dst.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json: [String: Any] = ["access_token": credentials.accessToken]
        if let r = credentials.refreshToken { json["refresh_token"] = r }
        if let t = credentials.tokenType { json["token_type"] = t }
        if let exp = credentials.expiryDate {
            json["expiry_date"] = Int(exp.timeIntervalSince1970 * 1000)
        }
        if let id = credentials.idToken { json["id_token"] = id }
        if let s = credentials.scope { json["scope"] = s }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let tmp = dir.appendingPathComponent("oauth_creds.json.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        // 替换:_ = result 防 ranking 警告;若 dst 不存在,replaceItem 会直接创建。
        if FileManager.default.fileExists(atPath: dst.path) {
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: dst)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
    }

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd macos && swift test --filter GeminiCredentialsTests 2>&1 | tail -15`
Expected: 11 tests passed(原 7 + 新 4)

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/UsageBar/Providers/Gemini/GeminiCredentials.swift \
        macos/Tests/UsageBarTests/GeminiCredentialsTests.swift
git commit -m "feat(gemini): refresh + 原子写回 oauth_creds.json(SC3)"
```

---

## Task 4: GeminiUsageModel — Decodable + asProviderSnapshot()

**Files:**
- Create: `macos/Sources/UsageBar/Providers/Gemini/GeminiUsageModel.swift`
- Create: `macos/Tests/UsageBarTests/GeminiUsageModelTests.swift`

**目标**:`retrieveUserQuota` response 是 per-model 数组,每条含 `model` / `remainingFraction`(0~1)/ `resetTime`(ISO8601)/ `dailyLimit`。映射规则:Pro 模型(模型名含 `pro`)→ primary 槽,Flash(模型名含 `flash`)→ secondary 槽,其它模型 → `extraWindows`。`utilizationPct` = `(1 - remainingFraction) * 100`。

- [ ] **Step 1: 写 5 个失败测试**

文件 `macos/Tests/UsageBarTests/GeminiUsageModelTests.swift`:

```swift
import XCTest
@testable import UsageBar

final class GeminiUsageModelTests: XCTestCase {

    private func decode(_ json: String) throws -> GeminiQuotaResponse {
        try JSONDecoder().decode(GeminiQuotaResponse.self, from: Data(json.utf8))
    }

    func testProAndFlashBothPresent() throws {
        let json = """
        { "userQuota": [
            { "model": "gemini-2.5-pro",   "remainingFraction": 0.7, "resetTime": "2026-05-14T00:00:00Z", "dailyLimit": 1000 },
            { "model": "gemini-2.5-flash", "remainingFraction": 0.4, "resetTime": "2026-05-14T00:00:00Z", "dailyLimit": 1500 }
        ] }
        """
        let resp = try decode(json)
        let snap = resp.asProviderSnapshot()
        // utilizationPct = (1 - remainingFraction) * 100
        XCTAssertEqual(snap.primaryWindow?.utilizationPct ?? -1, 30, accuracy: 1e-6)
        XCTAssertEqual(snap.primaryWindow?.label, "Pro")
        XCTAssertEqual(snap.primaryWindow?.shortLabel, "Pro")
        XCTAssertNotNil(snap.primaryWindow?.resetsAt)
        XCTAssertEqual(snap.secondaryWindow?.utilizationPct ?? -1, 60, accuracy: 1e-6)
        XCTAssertEqual(snap.secondaryWindow?.label, "Flash")
        XCTAssertTrue(snap.extraWindows.isEmpty)
    }

    func testOnlyProPresent() throws {
        let json = #"{ "userQuota": [{ "model": "gemini-2.5-pro", "remainingFraction": 0.5, "resetTime": "2026-05-14T00:00:00Z" }] }"#
        let snap = try decode(json).asProviderSnapshot()
        XCTAssertEqual(snap.primaryWindow?.utilizationPct ?? -1, 50, accuracy: 1e-6)
        XCTAssertNil(snap.secondaryWindow)
    }

    func testProVariantNamesMatch() throws {
        // 各种 Pro 变体都应被识别为 Pro
        for name in ["gemini-2.5-pro-preview", "gemini-2.5-pro-latest", "gemini-pro"] {
            let json = "{ \"userQuota\": [{ \"model\": \"\(name)\", \"remainingFraction\": 0.5 }] }"
            let snap = try decode(json).asProviderSnapshot()
            XCTAssertNotNil(snap.primaryWindow, "\(name) 应识别为 Pro")
        }
    }

    func testUnknownModelsGoToExtraWindows() throws {
        let json = """
        { "userQuota": [
            { "model": "gemini-2.5-pro", "remainingFraction": 0.5 },
            { "model": "future-mystery-model", "remainingFraction": 0.2 }
        ] }
        """
        let snap = try decode(json).asProviderSnapshot()
        XCTAssertNotNil(snap.primaryWindow)
        XCTAssertEqual(snap.extraWindows.count, 1)
        XCTAssertEqual(snap.extraWindows.first?.title, "future-mystery-model")
    }

    func testEmptyQuotaArray() throws {
        let snap = try decode(#"{ "userQuota": [] }"#).asProviderSnapshot()
        XCTAssertNil(snap.primaryWindow)
        XCTAssertNil(snap.secondaryWindow)
        XCTAssertTrue(snap.extraWindows.isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd macos && swift test --filter GeminiUsageModelTests 2>&1 | tail -10`
Expected: 编译错(`GeminiQuotaResponse` 未定义)

- [ ] **Step 3: 写 GeminiUsageModel 实现**

文件 `macos/Sources/UsageBar/Providers/Gemini/GeminiUsageModel.swift`:

```swift
import Foundation

/// 单个模型的配额条目(`retrieveUserQuota` response 元素)。
struct GeminiPerModelQuota: Decodable, Equatable {
    let model: String
    let remainingFraction: Double
    let resetTime: Date?
    let dailyLimit: Int?

    enum CodingKeys: String, CodingKey {
        case model, remainingFraction, resetTime, dailyLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decode(String.self, forKey: .model)
        self.remainingFraction = (try? c.decode(Double.self, forKey: .remainingFraction)) ?? 0
        if let s = try? c.decode(String.self, forKey: .resetTime) {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.resetTime = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        } else {
            self.resetTime = nil
        }
        self.dailyLimit = try? c.decode(Int.self, forKey: .dailyLimit)
    }

    /// 0...1 fraction → 0...100 used percent。
    var utilizationPct: Double { max(0, min(100, (1.0 - remainingFraction) * 100.0)) }
}

/// `retrieveUserQuota` 响应顶层。
struct GeminiQuotaResponse: Decodable, Equatable {
    let userQuota: [GeminiPerModelQuota]

    enum CodingKeys: String, CodingKey { case userQuota }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.userQuota = (try? c.decode([GeminiPerModelQuota].self, forKey: .userQuota)) ?? []
    }
}

extension GeminiQuotaResponse {
    /// 模型名分桶:`pro` 关键词 → Pro 槽;`flash` → Flash 槽;其它 → extraWindows。
    /// 同类多个(如 pro-preview + pro-latest)取第一个,其余进 extraWindows。
    func asProviderSnapshot() -> ProviderUsageSnapshot {
        var pro: GeminiPerModelQuota?
        var flash: GeminiPerModelQuota?
        var extras: [GeminiPerModelQuota] = []
        for q in userQuota {
            let lower = q.model.lowercased()
            // Flash 优先匹配:避免 `gemini-pro-flash` 等假设性命名被 Pro 桶吞掉(G3 reviewer optional 提示)
            if lower.contains("flash") && flash == nil { flash = q }
            else if lower.contains("pro") && pro == nil { pro = q }
            else { extras.append(q) }
        }
        func window(from q: GeminiPerModelQuota?, label: String) -> UsageWindow? {
            guard let q else { return nil }
            return UsageWindow(label: label, utilizationPct: q.utilizationPct, resetsAt: q.resetTime,
                               windowDuration: nil, shortLabel: label)
        }
        let extraWins = extras.map { q in
            NamedUsageWindow(id: q.model, title: q.model, window: UsageWindow(
                label: q.model, utilizationPct: q.utilizationPct, resetsAt: q.resetTime,
                windowDuration: nil, shortLabel: String(q.model.prefix(2))))
        }
        return ProviderUsageSnapshot(
            primaryWindow: window(from: pro, label: "Pro"),
            secondaryWindow: window(from: flash, label: "Flash"),
            extraWindows: extraWins,
            creditLine: nil,
            planLabel: nil   // tier 由 GeminiUsageClient.loadCodeAssist 拿,装配时塞;本 model 层不知道
        )
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd macos && swift test --filter GeminiUsageModelTests 2>&1 | tail -10`
Expected: 5 tests passed

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/UsageBar/Providers/Gemini/GeminiUsageModel.swift \
        macos/Tests/UsageBarTests/GeminiUsageModelTests.swift
git commit -m "feat(gemini): per-model quota → ProviderUsageSnapshot 映射(SC1 基础)"
```

---

## Task 5: GeminiUsageClient — loadCodeAssist + retrieveUserQuota

**Files:**
- Create: `macos/Sources/UsageBar/Providers/Gemini/GeminiUsageClient.swift`
- Create: `macos/Tests/UsageBarTests/GeminiUsageClientTests.swift`

**目标**:两段网络调用 — `loadCodeAssist` 拿 projectId + tier,`retrieveUserQuota(project:)` 拿 per-model 配额。错误映射:401/403 → unauthorized;其它 → server/network/decode。projectId 找不到时回退 `cloudresourcemanager` 找 `gen-lang-client*`。

- [ ] **Step 1: 写 5 个失败测试**

文件 `macos/Tests/UsageBarTests/GeminiUsageClientTests.swift`:

```swift
import XCTest
@testable import UsageBar

final class GeminiUsageClientTests: XCTestCase {

    private func stubSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        GeminiAPIStubURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GeminiAPIStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeCreds() -> GeminiCredentials {
        GeminiCredentials(accessToken: "ACCESS_SENTINEL", refreshToken: "R", tokenType: "Bearer",
                          expiryDate: Date().addingTimeInterval(3600), idToken: nil, scope: nil)
    }

    func testLoadCodeAssistSuccess() async throws {
        let session = stubSession { req in
            XCTAssertEqual(req.url?.host, "cloudcode-pa.googleapis.com")
            XCTAssertEqual(req.url?.path, "/v1internal:loadCodeAssist")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ACCESS_SENTINEL")
            let body = #"{"cloudaicompanionProject":"my-proj-123","currentTier":{"id":"free"}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        let result = try await GeminiUsageClient.loadCodeAssist(credentials: makeCreds(), session: session)
        XCTAssertEqual(result.projectId, "my-proj-123")
        XCTAssertEqual(result.tier, "free")
    }

    func testRetrieveUserQuotaSuccess() async throws {
        let session = stubSession { req in
            XCTAssertEqual(req.url?.path, "/v1internal:retrieveUserQuota")
            let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"project\":\"my-proj-123\""))
            let resp = #"{"userQuota":[{"model":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2026-05-14T00:00:00Z"}]}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(resp.utf8))
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        let resp = try await GeminiUsageClient.retrieveUserQuota(credentials: makeCreds(), projectId: "my-proj-123", session: session)
        XCTAssertEqual(resp.userQuota.count, 1)
        XCTAssertEqual(resp.userQuota.first?.model, "gemini-2.5-pro")
    }

    func testUnauthorizedThrows() async {
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        do {
            _ = try await GeminiUsageClient.loadCodeAssist(credentials: makeCreds(), session: session)
            XCTFail("expected unauthorized")
        } catch GeminiUsageError.unauthorized {
            // ok
        } catch { XCTFail("wrong: \(error)") }
    }

    func testServerErrorOmitsBody() async {
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("SECRET_BODY".utf8))
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        do {
            _ = try await GeminiUsageClient.loadCodeAssist(credentials: makeCreds(), session: session)
            XCTFail("expected server")
        } catch let e as GeminiUsageError {
            if case .server(let s) = e { XCTAssertEqual(s, 503) } else { XCTFail("expected .server") }
            XCTAssertFalse("\(e)".contains("SECRET_BODY"))
            XCTAssertFalse("\(e)".contains("SENTINEL"))
        } catch { XCTFail("wrong: \(error)") }
    }

    func testLoadCodeAssistMissingProjectThrows() async {
        let session = stubSession { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"currentTier":{"id":"free"}}"#.utf8))
        }
        defer { GeminiAPIStubURLProtocol.handler = nil }
        do {
            _ = try await GeminiUsageClient.loadCodeAssist(credentials: makeCreds(), session: session)
            XCTFail("expected missing project")
        } catch GeminiUsageError.missingProject {
            // ok
        } catch { XCTFail("wrong: \(error)") }
    }
}

private final class GeminiAPIStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = GeminiAPIStubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd macos && swift test --filter GeminiUsageClientTests 2>&1 | tail -10`
Expected: 编译错(`GeminiUsageClient` 未定义)

- [ ] **Step 3: 写 GeminiUsageClient 实现**

文件 `macos/Sources/UsageBar/Providers/Gemini/GeminiUsageClient.swift`:

```swift
import Foundation

enum GeminiUsageError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case server(status: Int)
    case network
    case decode
    case missingProject

    var description: String {
        switch self {
        case .unauthorized:    return "unauthorized"
        case .server(let s):   return "server(\(s))"
        case .network:         return "network"
        case .decode:          return "decode"
        case .missingProject:  return "missingProject"
        }
    }
}

struct GeminiCodeAssistInfo: Equatable {
    let projectId: String
    let tier: String?
}

enum GeminiUsageClient {
    static let baseURL = URL(string: "https://cloudcode-pa.googleapis.com")!
    static var loadCodeAssistURL: URL { baseURL.appendingPathComponent("/v1internal:loadCodeAssist") }
    static var retrieveUserQuotaURL: URL { baseURL.appendingPathComponent("/v1internal:retrieveUserQuota") }

    /// 调 `v1internal:loadCodeAssist` 拿 projectId(`cloudaicompanionProject`)+ tier。
    static func loadCodeAssist(credentials: GeminiCredentials,
                               session: URLSession = .shared) async throws -> GeminiCodeAssistInfo {
        let body: [String: Any] = [
            "metadata": ["pluginType": "GEMINI", "platform": "DARWIN_AMD64"],
            "cloudaicompanionProject": "default"
        ]
        let data = try await postJSON(url: loadCodeAssistURL, body: body, credentials: credentials, session: session)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GeminiUsageError.decode
        }
        guard let project = obj["cloudaicompanionProject"] as? String, !project.isEmpty else {
            throw GeminiUsageError.missingProject
        }
        let tier = (obj["currentTier"] as? [String: Any])?["id"] as? String
        return GeminiCodeAssistInfo(projectId: project, tier: tier)
    }

    /// 调 `v1internal:retrieveUserQuota`,body `{"project": "..."}`,返回 per-model 数组。
    static func retrieveUserQuota(credentials: GeminiCredentials,
                                  projectId: String,
                                  session: URLSession = .shared) async throws -> GeminiQuotaResponse {
        let data = try await postJSON(url: retrieveUserQuotaURL,
                                      body: ["project": projectId],
                                      credentials: credentials, session: session)
        do {
            return try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        } catch {
            throw GeminiUsageError.decode
        }
    }

    private static func postJSON(url: URL, body: [String: Any], credentials: GeminiCredentials,
                                 session: URLSession) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("usage-bar", forHTTPHeaderField: "User-Agent")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw GeminiUsageError.decode
        }
        let data: Data; let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GeminiUsageError.network
        }
        guard let http = response as? HTTPURLResponse else { throw GeminiUsageError.network }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw GeminiUsageError.unauthorized
        default:        throw GeminiUsageError.server(status: http.statusCode)
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd macos && swift test --filter GeminiUsageClientTests 2>&1 | tail -10`
Expected: 5 tests passed

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/UsageBar/Providers/Gemini/GeminiUsageClient.swift \
        macos/Tests/UsageBarTests/GeminiUsageClientTests.swift
git commit -m "feat(gemini): v1internal loadCodeAssist + retrieveUserQuota client(SC1 基础)"
```

---

## Task 6: GeminiProvider 主体

**Files:**
- Create: `macos/Sources/UsageBar/Providers/Gemini/GeminiProvider.swift`
- Create: `macos/Tests/UsageBarTests/GeminiProviderTests.swift`

**目标**:`UsageProvider` conformer。`refreshNow()` 流程:
1. `GeminiCredentialStore.load()` — 文件不存在 → unconfigured 静默
2. 凭证存在但 `isExpired()` → **不在此处主动 refresh**(spec 风险 #7 缓解策略 a:仅在 401 时 refresh)
3. `GeminiOAuthClientLocator.findClientIdSecret()` — 失败 → unconfigured + 错误文案
4. `GeminiUsageClient.loadCodeAssist` → projectId
5. `GeminiUsageClient.retrieveUserQuota` → snapshot
6. **如果 401**:用 client_id/secret 跑一次 `GeminiCredentialStore.refresh`,成功后**重试一次**;refresh 失败 → unconfigured
7. 成功 → 写 runtime + 历史样本(pct5h ← Pro,pct7d ← Flash)
8. 重入闸门 `isRefreshing`

- [ ] **Step 1: 写 8 个失败测试**

文件 `macos/Tests/UsageBarTests/GeminiProviderTests.swift`:

```swift
import XCTest
@testable import UsageBar

final class GeminiProviderTests: XCTestCase {

    // MARK: - helpers

    private func makeGeminiHome(credsJSON: String?) throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let credsJSON {
            try Data(credsJSON.utf8).write(to: dir.appendingPathComponent("oauth_creds.json"))
        }
        return ["GEMINI_HOME": dir.path]
    }

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stubSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        GeminiProviderStubURLProtocol.handler = handler
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [GeminiProviderStubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    /// fake locator 总是返回固定值(避开真机三处枚举)
    private final class FakeLocator: GeminiClientLocating {
        let result: GeminiOAuthClientLocator.Result?
        init(_ r: GeminiOAuthClientLocator.Result? = .init(clientId: "CID", clientSecret: "CSEC")) { self.result = r }
        func findClientIdSecret() -> GeminiOAuthClientLocator.Result? { result }
    }

    private func successQuotaJSON() -> String {
        #"{"userQuota":[{"model":"gemini-2.5-pro","remainingFraction":0.7,"resetTime":"2026-05-14T00:00:00Z"},{"model":"gemini-2.5-flash","remainingFraction":0.4,"resetTime":"2026-05-14T00:00:00Z"}]}"#
    }

    @MainActor
    func testNoCredentials() async throws {
        let env = try makeGeminiHome(credsJSON: nil)
        let p = GeminiProvider(environment: env, session: .shared, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertFalse(p.runtime.isConfigured)
        XCTAssertNil(p.runtime.snapshot)
        XCTAssertEqual(p.id, .gemini)
    }

    @MainActor
    func testNoOAuthClientGoesUnconfigured() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let p = GeminiProvider(environment: env, session: .shared, locator: FakeLocator(nil))
        await p.refreshNow()
        XCTAssertFalse(p.runtime.isConfigured)
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertTrue(p.runtime.lastError?.contains("gemini-cli") == true)
    }

    @MainActor
    func testSuccessFullFlow() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/v1internal:loadCodeAssist" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P","currentTier":{"id":"free"}}"#.utf8))
            }
            if path == "/v1internal:retrieveUserQuota" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(self.successQuotaJSON().utf8))
            }
            XCTFail("unexpected path: \(path)")
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertTrue(p.runtime.isConfigured)
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.label, "Pro")
        XCTAssertEqual(p.runtime.snapshot?.primaryWindow?.utilizationPct ?? -1, 30, accuracy: 1e-6)
        XCTAssertEqual(p.runtime.snapshot?.secondaryWindow?.label, "Flash")
    }

    @MainActor
    func testUnauthorizedTriggersRefreshAndRetry() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"OLD","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        var loadCalls = 0
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/token" || req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"access_token":"NEW","expires_in":3600,"token_type":"Bearer"}"#.utf8))
            }
            if path == "/v1internal:loadCodeAssist" {
                loadCalls += 1
                if loadCalls == 1 {
                    return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
                }
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer NEW", "重试时应带新 token")
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P","currentTier":{"id":"free"}}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(self.successQuotaJSON().utf8))
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertTrue(p.runtime.isConfigured)
        XCTAssertNotNil(p.runtime.snapshot)
    }

    @MainActor
    func testUnauthorizedRefreshFailsClearsSnapshot() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"OLD","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let session = stubSession { req in
            if req.url?.host == "oauth2.googleapis.com" {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.lastError)
        XCTAssertNil(p.runtime.snapshot)
        XCTAssertTrue(p.runtime.lastError?.contains("过期") == true || p.runtime.lastError?.contains("登录") == true)
    }

    @MainActor
    func testServerErrorKeepsSnapshot() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        var status = 200
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/v1internal:loadCodeAssist" {
                return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    Data(self.successQuotaJSON().utf8))
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator())
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.snapshot)
        status = 500
        await p.refreshNow()
        XCTAssertNotNil(p.runtime.snapshot, "5xx 应保留旧 snapshot")
        XCTAssertNotNil(p.runtime.lastError)
    }

    @MainActor
    func testHistorySampleRecorded() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/v1internal:loadCodeAssist" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(self.successQuotaJSON().utf8))
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let h = UsageHistoryService(filename: "g.json", directory: try makeTmpDir())
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator(), history: h)
        await p.refreshNow()
        XCTAssertEqual(h.history.dataPoints.count, 1)
        // Pro remainingFraction 0.7 → utilization 30% → unit 0.30
        XCTAssertEqual(h.history.dataPoints.first?.pct5h ?? -1, 0.30, accuracy: 1e-6)
        // Flash 0.4 → 60% → 0.60
        XCTAssertEqual(h.history.dataPoints.first?.pct7d ?? -1, 0.60, accuracy: 1e-6)
    }

    @MainActor
    func testRefreshNowIsNotReentrant() async throws {
        let env = try makeGeminiHome(credsJSON: #"{"access_token":"A","refresh_token":"R","token_type":"Bearer","expiry_date":99999999999999}"#)
        let session = stubSession { req in
            let path = req.url?.path ?? ""
            if path == "/v1internal:loadCodeAssist" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"cloudaicompanionProject":"P"}"#.utf8))
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(self.successQuotaJSON().utf8))
        }
        defer { GeminiProviderStubURLProtocol.handler = nil }
        let h = UsageHistoryService(filename: "g.json", directory: try makeTmpDir())
        let p = GeminiProvider(environment: env, session: session, locator: FakeLocator(), history: h)
        async let a: Void = p.refreshNow()
        async let b: Void = p.refreshNow()
        _ = await (a, b)
        XCTAssertEqual(h.history.dataPoints.count, 1, "重入闸门:并发 refreshNow 只记一个点")
    }
}

private final class GeminiProviderStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = GeminiProviderStubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd macos && swift test --filter GeminiProviderTests 2>&1 | tail -15`
Expected: 编译错(`GeminiProvider` / `GeminiClientLocating` 未定义)

- [ ] **Step 3: 写 GeminiProvider 实现**

文件 `macos/Sources/UsageBar/Providers/Gemini/GeminiProvider.swift`:

```swift
import Foundation

/// 测试用注入 protocol(`GeminiOAuthClientLocator` 实现它)。
protocol GeminiClientLocating {
    func findClientIdSecret() -> GeminiOAuthClientLocator.Result?
}

extension GeminiOAuthClientLocator: GeminiClientLocating {}

/// Gemini Code Assist for Individuals provider —— 复用本机 `~/.gemini/oauth_creds.json` + private quota endpoint。
/// 详见 spec `2026-05-13-gemini-provider`。
@MainActor
final class GeminiProvider: UsageProvider {
    let id: ProviderID = .gemini
    let runtime = ProviderRuntime()
    let history: UsageHistoryService

    var isConfigured: Bool { runtime.isConfigured }

    private let environment: [String: String]
    private let session: URLSession
    private let locator: GeminiClientLocating
    private var isRefreshing = false

    var onPollTick: (@MainActor () -> Void)? = nil
    var nextEligibleRefresh: Date? { nil }   // 不做 backoff

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         session: URLSession = .shared,
         locator: GeminiClientLocating? = nil,
         history: UsageHistoryService? = nil) {
        self.environment = environment
        self.session = session
        self.locator = locator ?? GeminiOAuthClientLocator()
        let h = history ?? UsageHistoryService(filename: "history-gemini.json")
        self.history = h
        let present = ((try? GeminiCredentialStore.load(environment: environment)) ?? nil) != nil
        runtime.setConfigured(present)
        h.loadHistory()
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 1. load creds
        let creds: GeminiCredentials?
        do {
            creds = try GeminiCredentialStore.load(environment: environment)
        } catch {
            runtime.setConfigured(false)
            runtime.setError("未检测到有效的 Gemini 凭证,请运行 gemini 重新登录", clearSnapshot: true)
            return
        }
        guard var current = creds else {
            runtime.setConfigured(false)
            runtime.clear()
            return
        }
        runtime.setConfigured(true)

        // 2. locate OAuth client(只需要拿一次,但失败会让 401 路径无法 refresh,所以前置)
        guard let client = locator.findClientIdSecret() else {
            runtime.setError("未检测到 gemini-cli 安装,无法识别 OAuth 凭证", clearSnapshot: true)
            return
        }

        // 3. 一次完整调用尝试;401 → refresh + 重试一次
        do {
            try await fetchAndPublish(credentials: current)
        } catch GeminiUsageError.unauthorized {
            // refresh + retry
            do {
                current = try await GeminiCredentialStore.refresh(
                    credentials: current, clientId: client.clientId, clientSecret: client.clientSecret,
                    session: session, environment: environment)
            } catch {
                runtime.setError("Gemini 凭证已过期,请运行 gemini 重新登录", clearSnapshot: true)
                return
            }
            do {
                try await fetchAndPublish(credentials: current)
            } catch GeminiUsageError.unauthorized {
                runtime.setError("Gemini 凭证已过期,请运行 gemini 重新登录", clearSnapshot: true)
            } catch {
                runtime.setError("无法获取 Gemini 用量(稍后重试)", clearSnapshot: false)
            }
        } catch GeminiUsageError.missingProject {
            runtime.setError("未检测到 Gemini Code Assist 项目", clearSnapshot: true)
        } catch {
            runtime.setError("无法获取 Gemini 用量(稍后重试)", clearSnapshot: false)
        }
    }

    private func fetchAndPublish(credentials: GeminiCredentials) async throws {
        let info = try await GeminiUsageClient.loadCodeAssist(credentials: credentials, session: session)
        let response = try await GeminiUsageClient.retrieveUserQuota(credentials: credentials, projectId: info.projectId, session: session)
        var snapshot = response.asProviderSnapshot()
        if let tier = info.tier { snapshot.planLabel = tier.capitalized }
        runtime.setSuccess(snapshot: snapshot)
        recordHistorySample(from: snapshot)
    }

    private func recordHistorySample(from snap: ProviderUsageSnapshot) {
        let p = snap.primaryWindow?.utilizationPct
        let s = snap.secondaryWindow?.utilizationPct
        guard p != nil || s != nil else { return }
        func unit(_ pct: Double?) -> Double { min(max((pct ?? 0) / 100.0, 0), 1) }
        history.recordDataPoint(pct5h: unit(p), pct7d: unit(s))
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd macos && swift test --filter GeminiProviderTests 2>&1 | tail -15`
Expected: 8 tests passed

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/UsageBar/Providers/Gemini/GeminiProvider.swift \
        macos/Tests/UsageBarTests/GeminiProviderTests.swift
git commit -m "feat(gemini): GeminiProvider 主体 + 401-refresh-retry + 历史样本(SC1/SC3/SC4/SC5/SC6/SC8)"
```

---

## Task 7: UsageBarApp wire 注入 + 全量回归

**Files:**
- Modify: `macos/Sources/UsageBar/App/UsageBarApp.swift:8-9`(在 `additionalProviders` 加 `GeminiProvider()`)

**目标**:把 `GeminiProvider` 实例注入 ProviderCoordinator。本机统计未做 → 不需要 onPollTick 也不需要 GeminiStatsService。SettingsView / MenuBar / Popover 自动按 `ProviderID.allCases` 渲染,**先验证后再决定是否需要改 UI**。

- [ ] **Step 1: 验证 SettingsView 是否自动渲染所有 ProviderID(SC7 前置假设)**

Run: `grep -n "ProviderID\.allCases\|orderedProviderIDs\|allCases" macos/Sources/UsageBar/Features/Settings/SettingsView.swift`
Expected: SettingsView 应基于 `coordinator.orderedProviderIDs`(它来自 `ProviderID.allCases` 兜底)迭代渲染。如确认是,SC7 假设成立,Settings 不需要改。

如果发现 SettingsView 写死了某些 case(如 `.claude` / `.codex`),改成迭代 `coordinator.orderedProviderIDs` 渲染并把改动写入本 task。

- [ ] **Step 2: 修改 UsageBarApp.swift**

Edit `macos/Sources/UsageBar/App/UsageBarApp.swift`,把第 8-9 行:

```swift
@StateObject private var coordinator = ProviderCoordinator(claude: UsageService(),
                                                           additionalProviders: [CodexProvider()])
```

改成:

```swift
@StateObject private var coordinator = ProviderCoordinator(claude: UsageService(),
                                                           additionalProviders: [
                                                               CodexProvider(),
                                                               GeminiProvider()
                                                           ])
```

- [ ] **Step 3: 跑全量测试 + build 确认绿(回归)**

Run:
```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
```
Expected: build 成功;test 全绿(原 codex/claude 测试 + 新 gemini 测试 ≥ 22 个)

- [ ] **Step 4: 跑 ProviderCoordinator 测试确认 Gemini 已被注册**

Run: `cd macos && swift test --filter ProviderCoordinatorTests 2>&1 | tail -10`
Expected: 全绿。如果有 case 期望 `availableIDs == [.claude, .codex]`,改成包含 `.gemini`(测试该测的是注册逻辑,不是某个具体集合)。如发现需要改,在本 step 改完。

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/UsageBar/App/UsageBarApp.swift
# 若 step 4 改了测试,把改动也加上
git commit -m "feat(gemini): UsageBarApp 装配 GeminiProvider 进 coordinator(SC7 wire)"
```

---

## Task 8: README + docs 增 third-party credentials 披露段(SC10)

**Files:**
- Modify: `README.md`(加新段)
- Possibly Modify: `docs/user-guide/`(如有相关用户文档)

**目标**:满足 SC10,合规披露。

- [ ] **Step 1: 看 README 当前结构**

Run: `head -80 README.md`
Expected: 找到合适插入位置(通常在"Privacy" / "Authentication" / "Providers" 章节附近;若都没有,在 README 末尾新增)

- [ ] **Step 2: 加披露段**

在 README.md 找到合适位置,加入:

```markdown
## 第三方凭证说明

UsageBar 复用本机已安装命令行工具的 OAuth 凭证以拉取用量数据,**不引导用户重新登录,也不分发任何第三方 secret**:

- **Claude**:复用 `~/.config/usage-bar/credentials.json`(本 app 自管 OAuth 流程)+ 回退读 Claude CLI 的 Keychain(`Claude Code-credentials`)
- **Codex**:**只读** `~/.codex/auth.json`(由 `codex` CLI 维护)
- **Gemini**:**只读** `~/.gemini/oauth_creds.json`(由 `gemini` CLI 维护);Google OAuth `client_id` / `client_secret` 由 UsageBar 在运行时从用户本机已安装的 gemini-cli 包中读取,**不在 app 二进制中硬编码**、**不上传到任何远端服务器**

用户可通过卸载对应 CLI、删除上述凭证文件,完全切断 UsageBar 与对应服务的连接。

UsageBar 与上述 CLI 工具调用的服务端 API 是各服务方的私有 endpoint,无 SLA;UsageBar 仅在本地展示返回数据,不修改、不缓存超出 `~/.config/usage-bar/` 范围的任何数据。
```

如果 README 已有 "Privacy" 或类似章节,合并而非追加新段。

- [ ] **Step 3: 验证 markdown 链接 + frontmatter(若适用)**

Run: `head -100 README.md | grep -E "^##|^###"` 检查段落层级合理;无 frontmatter 文件不需要 lint。

- [ ] **Step 4: 检查是否存在 user-guide 中文文档需要同步**

Run: `ls docs/user-guide/ 2>/dev/null && find docs/user-guide -name "*.md" 2>/dev/null | head -5`
如果有面向用户的 provider / privacy 中文文档,在那里加同样的段(中文)。如果 docs/user-guide 只有占位,跳过。

- [ ] **Step 5: Commit**

```bash
git add README.md
# 若 step 4 改了 user-guide,一起加
git commit -m "docs(gemini): 增 third-party credentials 披露段(SC10 合规交付物)"
```

---

## Task 9: 全量验证 + 真机 SC 勾选

**Files:**
- Modify: `docs/superpowers/specs/2026-05-13-gemini-provider.md`(verification log 勾选 + status 升级 implemented)

**目标**:跑完所有自动化检查 + 真机验证 + 在 spec verification log 勾选 SC1~SC10。

- [ ] **Step 1: 自动化检查(SC9)**

Run:
```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
make release-artifacts 2>&1 | tail -5
bash macos/scripts/verify-release.sh macos/UsageBar.zip 2>&1 | tail -10
```
Expected: 四条全绿。任何一条红 → 修对应 task,不可继续。

- [ ] **Step 2: 真机准备**

确认本机已装 gemini-cli + 已跑过 `gemini` 登录:

Run:
```bash
ls ~/.gemini/oauth_creds.json 2>&1
which gemini 2>&1
```
Expected: oauth_creds.json 存在 + gemini 命令可用。

如果未装,先装:`brew install gemini-cli` 或按 https://github.com/google-gemini/gemini-cli 步骤;然后 `gemini` 跑一次完成 OAuth。

- [ ] **Step 3: 启动 app 跑真机 SC**

Run:
```bash
make app
open macos/UsageBar.app
```

逐项确认(对照 spec manual_checks):
- **SC1**:打开 popover 应看到 Gemini tab + Pro / Flash 两段配额(remainingFraction → utilizationPct + reset 倒计时)
- **SC2**:`mv ~/.gemini/oauth_creds.json ~/.gemini/oauth_creds.json.bak` → 重启 app → popover 应显示『请运行 gemini 登录』降级文案;恢复:`mv` 回去
- **SC4**:用 `python3 -c "import json; d=json.load(open('/Users/$USER/.gemini/oauth_creds.json')); d['access_token']='BAD'; json.dump(d, open('/Users/$USER/.gemini/oauth_creds.json','w'))"` 把 access_token 改坏 → 等下一次 polling 应看到 401-refresh 路径;真实 refresh 成功后恢复
- **SC5**:临时把 gemini-cli 路径覆盖测试已由 fixture 覆盖;真机不重复
- **SC7**:打开 Settings → Providers 列表 → Gemini 行可启用 / 禁用 / 切换菜单栏可见 / 拖拽排序

- [ ] **Step 4: spec verification log 勾选 + status 升级**

修改 `docs/superpowers/specs/2026-05-13-gemini-provider.md`:

frontmatter `status: approved` → `status: implemented`

frontmatter `spec_criteria` 每条:`done: false` → `done: true`,`evidence: null` → 填具体 evidence(测试名 / 文件:行 / 真机操作记录)。如:

```yaml
- id: SC1
  done: true
  evidence: "GeminiProviderTests.testSuccessFullFlow + 真机:启 app 见 Pro 30% / Flash 60% Tab"
```

底部 `## Verification log` 段把 `- [ ] SC1 — pending` 改成 `- [x] SC1 — <evidence 短描述>`,SC2~SC10 同。

- [ ] **Step 5: Commit + 本地一次完整 build 校验**

```bash
git add docs/superpowers/specs/2026-05-13-gemini-provider.md
git commit -m "spec(gemini-provider): G6 verification log 全勾 + status: implemented"
cd macos && swift test 2>&1 | tail -5
```

---

## Task 10: PR + ship review + merge

**目标**:G5 PR 创建、调 ship reviewer、CI 绿、squash-merge 进 main、关闭 issue #27。

- [ ] **Step 1: 自检分支 + push**

Run:
```bash
git status
git log --oneline main..HEAD | head -20
git push -u origin issue/27-gemini-cli
```
Expected: 多个 commit(每个 task 一个);分支被 push 到 origin。

- [ ] **Step 2: 建 PR(标题 + body 中文,引 spec / issue)**

Run:
```bash
gh pr create --base main --head issue/27-gemini-cli \
  --title "feat(gemini): 接入 Gemini Code Assist for Individuals(关闭 #27)" \
  --body "$(cat <<'EOF'
## Summary

- 新增第三条 provider:Gemini(对标 Claude / Codex)
- 数据源:`cloudcode-pa.googleapis.com/v1internal:loadCodeAssist + retrieveUserQuota`(私有 endpoint,CodexBar 路径)
- OAuth:复用本机 `~/.gemini/oauth_creds.json` + 从本机 gemini-cli 安装抠 client_id/secret(不分发 Google secret,合规理由见 spec §2.2 + README 第三方凭证段)
- UI:Pro 模型 → primary 槽,Flash 模型 → secondary 槽,沿用 Codex 同形 IconBar
- 本机统计**未做**(`~/.gemini/tmp` schema 不稳),推迟到 gemini-cli #15292 落地
- target_version: v0.6.0-gemini-provider

## Spec & ADR

- spec: docs/superpowers/specs/2026-05-13-gemini-provider.md(G2 approved 2026-05-13)
- 兑现 ADR 0005(reopen multi-provider direction)的 Gemini 占位
- 关联 issue: #27

## Test plan

- [x] swift build -c release 绿
- [x] swift test 绿(新增 27+ 测试覆盖凭证 / refresh / locator / quota / provider 主体 / 历史)
- [x] make release-artifacts + verify-release.sh 绿
- [x] 真机 SC1(popover 显示 Pro/Flash)、SC2(凭证缺失降级)、SC4(401 refresh)、SC7(Settings 启停 + 拖拽)

## 风险披露

- `v1internal` 是 Google 私有 API,无 SLA;字段漂移会让 Gemini provider 静默失败 → fallback 到错误文案,不崩溃
- OAuth client locator 三处枚举可能在 nvm/volta/asdf 等异常路径下失败 → 用户看到『未检测到 gemini-cli 安装』降级文案
- 已落地 spec §5 风险 #7 的 (a)+(c) 缓解策略(只在 401 时 refresh + 失败走 unconfigured),(b) flock 暂未做

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: 起 ship reviewer subagent(G5)**

Use Agent tool with `subagent_type: general-purpose`:

```
你是 usage-bar 项目主回路 G5 阶段的独立 ship reviewer。**禁止 self-approve**。读 PR diff(`gh pr diff <PR#>`)+ 项目 AGENTS.md + 关联 spec(docs/superpowers/specs/2026-05-13-gemini-provider.md),从以下维度审:

1. diff 是否完整覆盖 spec SC1~SC10(没漏功能 / 没多塞功能)
2. 是否触碰受保护文件(docs/adr/* / AGENTS.md / 母法 spec / release.yml / Package.swift 依赖 pin / verify-release.sh)
3. 安全 / 合规:OAuth 凭证 / token 在错误文案中无泄露;client_id/secret 不在 binary;无任何 Google secret commit 进 repo
4. 错误处理:401 / 5xx / 网络 / decode 各路径都有测试;不崩溃
5. 测试质量:fixture 是 fake 值;无真实 ~/.gemini 依赖;URLProtocol mock 隔离

最后输出:`=== G5 SHIP VERDICT === verdict: <approved|needs-revision|rejected> notes: <短理由> === END ===`
```

如果 verdict ≠ approved,根据 notes 修改并重新 push;通过后再继续。

- [ ] **Step 4: 等 CI 绿(G6 自动化部分)**

Run:
```bash
gh pr checks --watch --fail-fast
```
Expected: `build` check 绿。

- [ ] **Step 5: squash-merge + delete branch + 关闭 issue + 立项 v0.6.0**

Run:
```bash
gh pr merge --squash --delete-branch
gh issue close 27 --comment "已通过 PR 合入 main(spec: docs/superpowers/specs/2026-05-13-gemini-provider.md;实施 plan: docs/superpowers/plans/2026-05-13-gemini-provider-plan.md)。Gemini provider 上线,本机统计推迟到 gemini-cli #15292 落地。"
```

立项 v0.6.0:在 `docs/versions/` 新建 `v0.6.0-gemini-provider.md`(参考 `_TEMPLATE.md` + 路线表 README.md);frontmatter `status: in-progress`、`includes_specs: [2026-05-13-gemini-provider]`、`target_date: 2026-05-13`;并更新 `docs/versions/README.md` 路线表追加一行。Commit 推 main:

```bash
git checkout main && git pull
# 编辑 docs/versions/v0.6.0-gemini-provider.md 与 docs/versions/README.md
git add docs/versions/v0.6.0-gemini-provider.md docs/versions/README.md
git commit -m "docs(v0.6.0): 立项 gemini-provider — issue #27 + spec 已 implemented"
git push
```

---

## 验收对照(plan → spec SC)

| spec SC | 实施 task | 自动化测试 | 真机检查 |
|---|---|---|---|
| SC1 Pro/Flash 配额显示 | 4 + 6 | testProAndFlashBothPresent + testSuccessFullFlow | Task 9 step 3 |
| SC2 凭证缺失降级 | 1 + 6 | testNoCredentials + testLoadFileAbsentReturnsNil | Task 9 step 3 |
| SC3 自动 refresh | 3 + 6 | testRefreshSuccessUpdatesAccessTokenAndExpiry + testUnauthorizedTriggersRefreshAndRetry | Task 9 step 3 SC4 步骤覆盖 |
| SC4 401 → 文案 | 6 | testUnauthorizedRefreshFailsClearsSnapshot | Task 9 step 3 SC4 |
| SC5 无 gemini-cli → 降级 | 2 + 6 | testNoOauth2JsReturnsNil + testNoOAuthClientGoesUnconfigured | fixture 已覆盖,真机不重复 |
| SC6 后台 polling 走统一 timer | 7 | ProviderCoordinatorTests(回归) | n/a |
| SC7 Settings 集成 | 7 | ProviderCoordinatorTests(回归;SettingsView 实测在 Task 9 真机覆盖) | Task 9 step 3 SC7 |
| SC8 历史样本写入 history-gemini.json | 6 | testHistorySampleRecorded | n/a |
| SC9 build / test 全绿 + 五条数据通路覆盖 | 1-6 全部 | 5 个测试文件覆盖 | Task 9 step 1 |
| SC10 第三方凭证披露段 | 8 | n/a(纯 docs) | manual review README |

---

## 回滚 / 应急

如发版后 24h 内出现:
- Gemini API endpoint 字段漂移导致大面积失败 → revert PR 并 push hotfix tag
- OAuth client locator 在某种安装方式下失败 → 把候选路径列表放进 UserDefaults 让用户手动指定(快速 patch)
- 任何 Google 法律 contact / DMCA → 立刻禁用 Gemini provider(`additionalProviders` 移除该实例);触发 AGENTS.md hard gate #6 升级人工
