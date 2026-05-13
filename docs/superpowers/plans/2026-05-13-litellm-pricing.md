# LiteLLM Pricing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把手写的 `OpenAIPricing.table` / `ClaudePricing.table` 价格表删掉，改为打包 LiteLLM 的 `model_prices_and_context_window.json` 全量快照、运行期 3h 后台刷新、查表用逐级回退候选链 —— 修掉 Codex tab「含 N 条未知模型调用（价格表过时？）」。

**Architecture:** 新增 `ModelPricingCatalog`（`Sendable` 单例，锁保护内存表）：启动时按「`~/.config/usage-bar/litellm_model_prices.json` 缓存 → bundle 内打包副本」加载并解析；`unitPricing(rawModel:)` 内部跑逐级回退候选链；`refreshIfStale(now:)` 同步返回、按持久化的 `fetched_at`（meta 文件）做 3h 节流、超时则 detach 一个 `URLSession` download task 原子替换缓存。`ProviderCoordinator` 的统一 tick 每次调一次 `refreshIfStale`。`ClaudeModelPriceTable` / `OpenAIModelPriceTable` 的 `lookup` 改成委托 catalog；两张静态字典删除。`build.sh` 构建前 `curl` 刷新 bundle 副本、构建后 `git checkout --` 还原工作区。

**Tech Stack:** Swift 5.9 / SwiftPM / XCTest / `Foundation`（`JSONSerialization`、`URLSession` download task、`Data.write(.atomic)`）/ bash（`build.sh`、`verify-release.sh`）。

**Spec:** `docs/superpowers/specs/2026-05-13-litellm-pricing.md`（status: accepted；SC1~SC8）。

---

## File Structure

| 文件 | 责任 |
|---|---|
| 🆕 `macos/Sources/UsageBar/ModelPricingCatalog.swift` | LiteLLM JSON 的加载 / 解析 / 内存表 / 候选链查表 / 3h 后台刷新；上游 URL 编译期常量 |
| 🆕 `macos/Sources/UsageBar/Resources/litellm_model_prices.json` | 打包快照（committed；build.sh 每次刷新、build 后还原工作区）|
| 🆕 `macos/Sources/UsageBar/Resources/THIRD_PARTY_LICENSES.txt` | LiteLLM MIT 全文 + 出处说明 |
| 🆕 `macos/Tests/UsageBarTests/ModelPricingCatalogTests.swift` | 解析 / 缓存优先 / 越界回退 / `refreshIfStale` 节流与原子性 |
| 🆕 `macos/Tests/UsageBarTests/Fixtures/litellm_snapshot_frozen.json` | 冻结的真实 LiteLLM 快照子集（给回退链测试用）|
| 🆕 `macos/Tests/UsageBarTests/ModelPriceTableFallbackTests.swift` | 候选链每步覆盖 + 真实别名样本命中 |
| 🔧 `macos/Sources/UsageBar/OpenAIPricing.swift` | 删 `table` / `snapshotDate` / `// UNVERIFIED`；`lookup` 委托 catalog；`normalize` / `displayName` 留 |
| 🔧 `macos/Sources/UsageBar/ClaudePricing.swift` | 删 `table` / `snapshotDate` / `cost(for:)`；`lookup` 委托 catalog；`normalize` / `displayName` 留；`ClaudeModelPricing` struct 若没人用一并删 |
| 🔧 `macos/Tests/UsageBarTests/ClaudePricingTests.swift` | 迁移到不依赖被删 API |
| 🔧 `macos/Tests/UsageBarTests/OpenAIPricingTests.swift` | 同上（`testLookupKnownAndUnknown` 等依赖静态表的改掉）|
| 🔧 `macos/Sources/UsageBar/ProviderCoordinator.swift` | `onBackgroundTick()` 末尾 + `startBackgroundPolling()` 调 `ModelPricingCatalog.shared.refreshIfStale(now: Date())` |
| 🔧 `macos/Sources/UsageBar/LocalCostCard.swift` | 提示文案区分「无定价数据」/「定价数据未加载」|
| 🔧 `macos/scripts/build.sh` | `fetch_litellm_prices()`（build 前）+ 装配后 `git checkout --` 还原 |
| 🔧 `macos/scripts/verify-release.sh` | 增检 bundle 内 `litellm_model_prices.json` 存在 + 合法 JSON + size > 100KB |
| 🔧 `CLAUDE.md` / `README.md` | 文档同步 |

**关键类型契约**（贯穿全部 Task，名字必须一致）：

```swift
// ModelPricingCatalog.swift
struct CatalogLoadLimits { static let minBytes = 50_000; static let maxBytes = 10_000_000 }

final class ModelPricingCatalog: @unchecked Sendable {
    static let shared = ModelPricingCatalog()

    // 测试用的注入点（生产走默认）
    typealias Now = () -> Date
    typealias Downloader = (@escaping (Data?) -> Void) -> Void   // 异步下载，回调给 raw bytes（nil = 失败）

    init(cacheURL: URL? = ..., bundledURL: URL? = ..., metaURL: URL? = ...,
         now: @escaping Now = Date.init, downloader: Downloader? = nil,
         minBytesOverride: Int? = nil)            // 测试传 0 绕过 50KB 下限；生产 nil = 用 Limits.minBytes

    var isLoaded: Bool { get }                       // false = 空表（两级都加载失败）
    func unitPricing(rawModel: String) -> ModelUnitPricing?   // 内部跑候选链
    func refreshIfStale(now: Date)                   // 同步、立即返回；内部按 3h 节流 + detach 下载

    // 仅测试可见（@testable）：
    func reloadTableForTesting()
    static func pricingCandidates(for rawModel: String) -> [String]   // 候选链（纯函数，去重）
}
```

`ModelUnitPricing` 已存在于 `ModelPricing.swift`，不动。`ClaudeModelPriceTable` / `OpenAIModelPriceTable` 已存在，只改 `lookup` 体。

---

## Task 1: `ModelPricingCatalog` —— 加载 + 解析 + exact-match 查表

**Files:**
- Create: `macos/Sources/UsageBar/ModelPricingCatalog.swift`
- Test: `macos/Tests/UsageBarTests/ModelPricingCatalogTests.swift`

- [x] **Step 1: 写失败测试 —— 解析 fixture JSON**

在 `ModelPricingCatalogTests.swift`：

```swift
import XCTest
@testable import UsageBar

final class ModelPricingCatalogTests: XCTestCase {
    /// 写一份 JSON 到临时文件，返回 URL（测试结束自动清理）。
    private func tempJSON(_ contents: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("prices.json")
        try! contents.data(using: .utf8)!.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private static let sampleJSON = """
    {
      "sample_spec": {"input_cost_per_token": 9.9, "output_cost_per_token": 9.9},
      "gpt-5": {"input_cost_per_token": 0.00000125, "output_cost_per_token": 0.00001, "cache_read_input_token_cost": 0.000000125},
      "gpt-5-codex": {"input_cost_per_token": 0.00000125, "output_cost_per_token": 0.00001},
      "gpt-5-mini": {"input_cost_per_token": 0.00000025, "output_cost_per_token": 0.000002},
      "claude-opus-4-20250514": {"input_cost_per_token": 0.000015, "output_cost_per_token": 0.000075, "cache_read_input_token_cost": 0.0000015, "cache_creation_input_token_cost": 0.00001875},
      "openai/gpt-4o": {"input_cost_per_token": 0.0000025, "output_cost_per_token": 0.00001},
      "azure/gpt-4o": {"input_cost_per_token": 0.0000099, "output_cost_per_token": 0.0000099},
      "broken-model": {"input_cost_per_token": "not-a-number"}
    }
    """

    func testParsesPerTokenIntoPerMTokAndSkipsSampleSpec() {
        // 所有 tempJSON fixture 都远小于 50KB → 必须用 minBytesOverride: 0 绕过下限
        let cat = ModelPricingCatalog(cacheURL: tempJSON(Self.sampleJSON), bundledURL: nil, minBytesOverride: 0)
        XCTAssertTrue(cat.isLoaded)
        let p = cat.unitPricing(rawModel: "gpt-5")
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.inputUSDPerMTok ?? 0, 1.25, accuracy: 1e-9)      // 0.00000125 × 1e6
        XCTAssertEqual(p?.outputUSDPerMTok ?? 0, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p?.cacheReadUSDPerMTok ?? 0, 0.125, accuracy: 1e-9)
        XCTAssertEqual(p?.cacheWriteUSDPerMTok ?? -1, 0.0, accuracy: 1e-12) // 缺 cache_creation → 0
        // sample_spec 不进表
        XCTAssertNil(cat.unitPricing(rawModel: "sample_spec"))
        // 单 key 字段非数 → 该 key 跳过，不影响其它 key、不 crash
        XCTAssertNil(cat.unitPricing(rawModel: "broken-model"))
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `cd macos && swift test --filter ModelPricingCatalogTests/testParsesPerTokenIntoPerMTokAndSkipsSampleSpec`
Expected: 编译失败 —— `cannot find 'ModelPricingCatalog' in scope`。

- [x] **Step 3: 写 `ModelPricingCatalog` 的最小实现（加载 + 解析 + exact lookup）**

`macos/Sources/UsageBar/ModelPricingCatalog.swift`：

```swift
import Foundation

/// 模型 → per-Mtok 单价的运行时目录，数据来自 [LiteLLM](https://github.com/BerriAI/litellm) 的
/// `model_prices_and_context_window.json`（社区维护的全厂商价格库）。
///
/// 加载优先级：① `~/.config/usage-bar/litellm_model_prices.json`（运行期缓存，3h 后台刷新写入）
/// → ② app bundle 内打包的同名快照（offline 兜底）→ ③ 都失败：空表（`isLoaded == false`，所有查表 nil）。
/// 价格随上游自动更新，不再随发版手维护。**估算口径**：与既有 `OpenAIPricing` 一致，是 list-price 估算、不是真实账单。
///
/// 安全/健壮性：上游 URL 是编译期常量、无运行时覆盖路径；下载与读取都加 size 上下限防 OOM；
/// 所有 JSON 访问用 optional cast，单个 key 解析失败仅跳过该 key（不抛、不 crash）。
final class ModelPricingCatalog: @unchecked Sendable {
    static let shared = ModelPricingCatalog()

    /// 上游全量快照地址（编译期常量）。固定 `main` 分支，与 ccusage 一致。
    static let upstreamURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    enum Limits { static let minBytes = 50_000; static let maxBytes = 10_000_000 }
    static let refreshInterval: TimeInterval = 3 * 60 * 60   // 写死 3h

    /// 顶层非模型键，排除。
    private static let nonModelKeys: Set<String> = ["sample_spec"]
    /// key 里出现这些 provider 路由前缀的，前缀匹配阶段不予采纳（命中 bedrock 的 claude 价格是错的）。
    static let foreignRoutePrefixes = ["azure/", "vertex_ai/", "bedrock/", "openrouter/", "azure_ai/"]

    typealias Now = () -> Date
    /// 异步下载器：成功回调 raw bytes，失败回调 nil。生产用 `URLSession` download task。
    typealias Downloader = (@escaping (Data?) -> Void) -> Void

    private let cacheURL: URL?
    private let bundledURL: URL?
    private let metaURL: URL?
    private let now: Now
    private let downloader: Downloader
    private let minBytesOverride: Int?           // 测试注入 0 绕过 50KB 下限；生产 nil

    private let lock = NSLock()
    private var table: [String: ModelUnitPricing] = [:]   // key = 上游原名小写
    private var loaded = false
    private var refreshInFlight = false

    init(cacheURL: URL? = ModelPricingCatalog.defaultCacheURL,
         bundledURL: URL? = ModelPricingCatalog.defaultBundledURL,
         metaURL: URL? = ModelPricingCatalog.defaultMetaURL,
         now: @escaping Now = Date.init,
         downloader: Downloader? = nil,
         minBytesOverride: Int? = nil) {
        self.cacheURL = cacheURL
        self.bundledURL = bundledURL
        self.metaURL = metaURL
        self.now = now
        self.minBytesOverride = minBytesOverride
        self.downloader = downloader ?? ModelPricingCatalog.urlSessionDownloader(from: ModelPricingCatalog.upstreamURL, maxBytes: Limits.maxBytes)
        reload()
    }

    private var effMinBytes: Int { minBytesOverride ?? Limits.minBytes }

    // MARK: - 默认路径

    static var defaultCacheURL: URL? {
        configDir()?.appendingPathComponent("litellm_model_prices.json")
    }
    static var defaultMetaURL: URL? {
        configDir()?.appendingPathComponent("litellm_model_prices.meta.json")
    }
    static var defaultBundledURL: URL? {
        Bundle.module.url(forResource: "litellm_model_prices", withExtension: "json")
    }
    private static func configDir() -> URL? {
        // 与 StoredCredentials 等一致：~/.config/usage-bar/
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("usage-bar", isDirectory: true)
    }

    // MARK: - 加载

    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }

    /// 测试用：强制按当前 cache/bundled 重读一次。
    func reloadTableForTesting() { reload() }

    private func reload() {
        let parsed = Self.loadParsed(from: cacheURL, minBytes: effMinBytes) ?? Self.loadParsed(from: bundledURL, minBytes: effMinBytes)
        lock.lock()
        table = parsed ?? [:]
        loaded = parsed != nil
        lock.unlock()
    }

    /// 读一个文件 → size 在 [minBytes, maxBytes] → JSON 顶层 dict → 解析。任何一步失败返回 nil（不抛）。
    private static func loadParsed(from url: URL?, minBytes: Int) -> [String: ModelUnitPricing]? {
        guard let url else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size >= minBytes, size <= Limits.maxBytes,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any], !dict.isEmpty
        else { return nil }
        return parse(dict)
    }

    /// 顶层 dict → `[小写模型名: ModelUnitPricing]`。跳过非模型键；单 key 任何字段 cast 失败 → 跳过该 key。
    static func parse(_ dict: [String: Any]) -> [String: ModelUnitPricing] {
        var out: [String: ModelUnitPricing] = [:]
        for (rawKey, value) in dict {
            if nonModelKeys.contains(rawKey) { continue }
            guard let attrs = value as? [String: Any] else { continue }
            func num(_ k: String) -> Double {
                if let d = attrs[k] as? Double { return d }
                if let n = attrs[k] as? NSNumber { return n.doubleValue }
                return 0
            }
            let inPT = num("input_cost_per_token")
            let outPT = num("output_cost_per_token")
            let crPT = num("cache_read_input_token_cost")
            let cwPT = num("cache_creation_input_token_cost")
            // 没有任何价格字段（全 0）的 key 收进去也无害（查到 = $0），但跳过更干净；保留 input==0&&output==0 跳过。
            if inPT == 0 && outPT == 0 && crPT == 0 && cwPT == 0 { continue }
            out[rawKey.lowercased()] = ModelUnitPricing(
                inputUSDPerMTok: inPT * 1_000_000,
                outputUSDPerMTok: outPT * 1_000_000,
                cacheReadUSDPerMTok: crPT * 1_000_000,
                cacheWriteUSDPerMTok: cwPT * 1_000_000)
        }
        return out
    }

    // MARK: - 查表（候选链）

    func unitPricing(rawModel: String) -> ModelUnitPricing? {
        lock.lock(); let snapshot = table; lock.unlock()
        guard !snapshot.isEmpty else { return nil }
        for cand in Self.pricingCandidates(for: rawModel) {
            if let hit = snapshot[cand] { return hit }
        }
        // 前缀匹配（步骤 6）：候选链最后再来一遍——以任一候选为前缀的 key，排除 foreign route 前缀，字典序第一。
        let keys = snapshot.keys.sorted()
        for cand in Self.pricingCandidates(for: rawModel) {
            if let k = keys.first(where: { $0.hasPrefix(cand) && !Self.foreignRoutePrefixes.contains(where: { fp in $0.contains(fp) }) }) {
                return snapshot[k]
            }
        }
        return nil
    }

    // 候选链留到 Task 2 完整实现；先放最小版本（只有原名）让本 Task 测试过。
    static func pricingCandidates(for rawModel: String) -> [String] {
        [rawModel.lowercased()]
    }

    // MARK: - 刷新（留到 Task 3）

    func refreshIfStale(now: Date) { /* Task 3 */ }
    private static func urlSessionDownloader(from url: URL, maxBytes: Int) -> Downloader {
        { completion in completion(nil) }   // Task 3 替换成真 download task
    }
}
```

> 注：`@unchecked Sendable` + `NSLock` 是因为 `UsageStatsService.refresh()` 在 `Task.detached` 里用 `ModelPriceTable`（其 `lookup` 会摸到 catalog）；不用 actor 是为了让 MainActor 的 `ProviderCoordinator.onBackgroundTick()` 能同步调 `refreshIfStale`。

- [x] **Step 4: 跑测试确认通过**

Run: `cd macos && swift test --filter ModelPricingCatalogTests/testParsesPerTokenIntoPerMTokAndSkipsSampleSpec`
Expected: PASS。

- [x] **Step 5: 加「缓存优先于 bundle」+「越界/损坏回退」+「空表」测试**

追加到 `ModelPricingCatalogTests`：

```swift
    func testCachePreferredOverBundled() {
        let cache = tempJSON(#"{"gpt-5":{"input_cost_per_token":0.000002,"output_cost_per_token":0.000002}}"#)
        let bundled = tempJSON(Self.sampleJSON)
        let cat = ModelPricingCatalog(cacheURL: cache, bundledURL: bundled, minBytesOverride: 0)
        XCTAssertEqual(cat.unitPricing(rawModel: "gpt-5")?.inputUSDPerMTok ?? 0, 2.0, accuracy: 1e-9) // 缓存值，不是 1.25
    }

    func testCorruptCacheFallsBackToBundled() {
        let cat = ModelPricingCatalog(cacheURL: tempJSON("{ this is not json"), bundledURL: tempJSON(Self.sampleJSON), minBytesOverride: 0)
        XCTAssertTrue(cat.isLoaded)
        XCTAssertNotNil(cat.unitPricing(rawModel: "gpt-5"))
    }

    func testTooSmallFileRejectedByMinBytes() {
        // 不绕过下限：sampleJSON < 50KB → loadParsed 返回 nil → 没有可用源 → 空表
        let cat = ModelPricingCatalog(cacheURL: tempJSON(Self.sampleJSON), bundledURL: nil /* 用生产 minBytes */)
        XCTAssertFalse(cat.isLoaded)
        XCTAssertNil(cat.unitPricing(rawModel: "gpt-5"))
    }

    func testBothSourcesMissingGivesEmptyTable() {
        let cat = ModelPricingCatalog(cacheURL: nil, bundledURL: nil)
        XCTAssertFalse(cat.isLoaded)
        XCTAssertNil(cat.unitPricing(rawModel: "gpt-5"))
    }
```

- [x] **Step 6: 跑全部 catalog 测试**

Run: `cd macos && swift test --filter ModelPricingCatalogTests`
Expected: 全 PASS（5 个 case）。

- [x] **Step 7: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/ModelPricingCatalog.swift macos/Tests/UsageBarTests/ModelPricingCatalogTests.swift
git commit -m "feat: v0.2.14 — ModelPricingCatalog 加载/解析 LiteLLM JSON（缓存优先 bundle 兜底；per-token→per-Mtok；跳 sample_spec；size 校验；单 key 失败即跳）[spec:2026-05-13-litellm-pricing]"
```

---

## Task 2: 逐级回退候选链 `pricingCandidates(for:)`

**Files:**
- Modify: `macos/Sources/UsageBar/ModelPricingCatalog.swift`（替换 `pricingCandidates` 最小版本）
- Test: `macos/Tests/UsageBarTests/ModelPriceTableFallbackTests.swift`（新建）+ fixture

- [x] **Step 1: 写失败测试 —— 候选链每步**

`macos/Tests/UsageBarTests/ModelPriceTableFallbackTests.swift`：

```swift
import XCTest
@testable import UsageBar

final class ModelPriceTableFallbackTests: XCTestCase {
    func testCandidateChainSteps() {
        let c = ModelPricingCatalog.pricingCandidates(for: "GPT-5.4-xhigh")
        // 步骤 1 原名 → 步骤 2 去 effort 后缀
        XCTAssertEqual(c.first, "gpt-5.4-xhigh")
        XCTAssertTrue(c.contains("gpt-5.4"))
        // 步骤 3：去 codex 家族后缀退基座
        XCTAssertTrue(ModelPricingCatalog.pricingCandidates(for: "gpt-5.3-codex").contains("gpt-5.3"))
        XCTAssertTrue(ModelPricingCatalog.pricingCandidates(for: "gpt-5.1-codex-max").contains("gpt-5.1"))
        XCTAssertTrue(ModelPricingCatalog.pricingCandidates(for: "gpt-5.3-codex-spark").contains("gpt-5.3"))
        // 步骤 4：去 minor 版本号
        XCTAssertTrue(ModelPricingCatalog.pricingCandidates(for: "gpt-5.3").contains("gpt-5"))
        XCTAssertTrue(ModelPricingCatalog.pricingCandidates(for: "gpt-5.4-mini").contains("gpt-5-mini"))
        // 步骤 5：provider 前缀
        XCTAssertTrue(ModelPricingCatalog.pricingCandidates(for: "gpt-4o").contains("openai/gpt-4o"))
        XCTAssertTrue(ModelPricingCatalog.pricingCandidates(for: "claude-opus-4").contains("anthropic/claude-opus-4"))
        // 去重：不重复
        let all = ModelPricingCatalog.pricingCandidates(for: "gpt-5")
        XCTAssertEqual(all.count, Set(all).count)
        // 组合：gpt-5.3-codex-xhigh 应能一路退到 gpt-5
        let combo = ModelPricingCatalog.pricingCandidates(for: "gpt-5.3-codex-xhigh")
        XCTAssertTrue(combo.contains("gpt-5.3-codex"))
        XCTAssertTrue(combo.contains("gpt-5.3"))
        XCTAssertTrue(combo.contains("gpt-5"))
    }
}
```

- [x] **Step 2: 跑确认失败**

Run: `cd macos && swift test --filter ModelPriceTableFallbackTests/testCandidateChainSteps`
Expected: FAIL（候选链还是最小版本，只返回原名）。

- [x] **Step 3: 实现完整候选链**

替换 `ModelPricingCatalog.swift` 里的 `pricingCandidates`：

```swift
    /// 逐级回退候选链（小写后，按优先级，去重）。纯函数，方便单测。
    /// 步骤 2–4 是 OpenAI/codex CLI 内部别名专用的（需随其演进维护，见 spec §2 注）；步骤 5 两边都用；
    /// 前缀匹配（步骤 6）由 `unitPricing` 在跑完本列表后单独做。
    static func pricingCandidates(for rawModel: String) -> [String] {
        let base = rawModel.lowercased()
        var out: [String] = []
        func push(_ s: String) { if !s.isEmpty, !out.contains(s) { out.append(s) } }

        // ① 原名
        push(base)

        // ② 去 reasoning-effort 后缀
        let effort = #"-(minimal|low|medium|high|xhigh)$"#
        let noEffort = base.replacingOccurrences(of: effort, with: "", options: .regularExpression)
        push(noEffort)

        // ③ 去 codex 家族后缀退基座（在「去 effort 后」的名上做）
        var noCodex = noEffort
        for suffix in ["-codex-max", "-codex-spark", "-codex-mini", "-codex"] {
            if noCodex.hasSuffix(suffix) { noCodex = String(noCodex.dropLast(suffix.count)); break }
        }
        push(noCodex)

        // ④ 去 minor 版本号：gpt-5.3 → gpt-5；gpt-5.3-mini → gpt-5-mini（对 gpt- 前缀的名）
        func dropMinor(_ s: String) -> String? {
            // 匹配 "gpt-<major>.<minor>" 可选带 "-<size>" 后缀
            guard let m = s.range(of: #"^gpt-(\d+)\.\d+(-[a-z]+)?$"#, options: .regularExpression) else { return nil }
            _ = m
            // 重构：gpt-<major>[-<size>]
            let parts = s.dropFirst(4)  // 去 "gpt-"
            let majorMinor = parts.prefix { $0 != "-" }   // "<major>.<minor>"
            let rest = parts.dropFirst(majorMinor.count)  // "" 或 "-<size>"
            guard let dot = majorMinor.firstIndex(of: ".") else { return nil }
            let major = majorMinor[..<dot]
            return "gpt-\(major)\(rest)"
        }
        if let d = dropMinor(noCodex) { push(d) }
        if let d = dropMinor(noEffort) { push(d) }
        if let d = dropMinor(base) { push(d) }

        // ⑤ provider 前缀（对目前已 push 的每个候选都加一遍 openai/ 和 anthropic/）
        for c in out where !c.contains("/") {
            push("openai/\(c)")
            push("anthropic/\(c)")
        }
        return out
    }
```

> ⚠️ 实现注意：`for c in out where ...` 在循环里 `push` 会改 `out` —— Swift 的 `for c in out` 迭代的是循环开始时的拷贝吗？不是，`Array` 是值类型，`for c in out` 迭代的是**进入循环那一刻** `out` 的快照（because `out` 被 copy 进 iterator）。但保险起见用 `let snapshot = out; for c in snapshot ...`。请在实现里这么写。

- [x] **Step 4: 跑确认通过**

Run: `cd macos && swift test --filter ModelPriceTableFallbackTests/testCandidateChainSteps`
Expected: PASS。

- [x] **Step 5: 抓一份冻结快照 fixture（给真实别名命中测试用）**

```bash
cd /Users/methol/data/code-methol/usage-bar
mkdir -p macos/Tests/UsageBarTests/Fixtures
curl -fsSL https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json \
  -o macos/Tests/UsageBarTests/Fixtures/litellm_snapshot_frozen.json
# 确认是合法 JSON 且体量正常
python3 -c "import json,sys; d=json.load(open('macos/Tests/UsageBarTests/Fixtures/litellm_snapshot_frozen.json')); print('keys:', len(d))"
```
Expected: 打印 `keys: <几百>`（几百个模型）。**这份 fixture 是冻结的**——不随 build.sh 变，CI 稳定。

把它注册为 SwiftPM test resource：`macos/Package.swift` 的 test target（`path: "Tests/UsageBarTests"`）当前**没有** `resources:` 块，新增一个 —— resource 路径相对 target `path`，所以是 `resources: [.process("Fixtures")]`（**不是** `.process("Tests/UsageBarTests/Fixtures")`，那会被解析成 `Tests/UsageBarTests/Tests/UsageBarTests/Fixtures` → 构建失败）。参照 main target 的 `path: "Sources/UsageBar"` + `resources: [.process("Resources")]` 写法。

- [x] **Step 6: 写真实别名命中测试**

追加到 `ModelPriceTableFallbackTests`：

```swift
    private func frozenCatalog() -> ModelPricingCatalog {
        let url = Bundle.module.url(forResource: "litellm_snapshot_frozen", withExtension: "json")!
        return ModelPricingCatalog(cacheURL: url, bundledURL: nil, minBytesOverride: 0)
    }

    func testRealAliasesResolveToNonNilPricing() {
        let cat = frozenCatalog()
        XCTAssertTrue(cat.isLoaded)
        for model in ["gpt-5.3-codex", "gpt-5.2", "gpt-5.4", "gpt-5.1-codex-max",
                      "gpt-5.4-mini", "gpt-5.2-codex", "gpt-5.4-xhigh", "gpt-5.3-codex-spark",
                      "claude-opus-4-7", "claude-sonnet-4-6"] {
            XCTAssertNotNil(cat.unitPricing(rawModel: model), "expected non-nil pricing for \(model)")
        }
        XCTAssertNil(cat.unitPricing(rawModel: "foo-bar-9"))
    }

    func testForeignRoutePrefixesNotMatchedByPrefixSearch() {
        // 构造一个只含 azure/ 变体的小表，确认前缀匹配不会命中它
        let cat = ModelPricingCatalog(cacheURL: nil, bundledURL: nil, minBytesOverride: 0)
        _ = cat  // 占位：真正断言放到 ModelPricingCatalogTests 里用注入 JSON（azure/gpt-4o 那条），见 Step 7
    }
```

> 注：如果某个别名在当前 LiteLLM 快照里**确实**通过候选链所有步骤都查不到（比如 `gpt-5.3-codex-spark` 这种很新的内部名上游完全没有任何 `gpt-5.3*` / `gpt-5*` 条目——不太可能，但若发生），那说明 spec SC4 的样本选得太激进：**回退方案**——把该样本从「必须非空」降级为「记录其行为」（用 `XCTAssertNil` 或加注释说明上游暂无），并在 spec verification log 里注明。先按「都应非空」实现，跑 Step 8 看结果再决定。

- [x] **Step 7: 把「前缀匹配排除 foreign route」断言加到 catalog 测试**

追加到 `ModelPricingCatalogTests`（用 Step 1 的 `sampleJSON`，它含 `openai/gpt-4o` 和 `azure/gpt-4o`）：

```swift
    func testPrefixMatchPrefersNonForeignRoute() {
        // sampleJSON 里 "openai/gpt-4o" 和 "azure/gpt-4o" 都在；查 "gpt-4o"：
        // 候选链步骤 5 会生成 "openai/gpt-4o" → 精确命中（input 2.5），不会落到前缀匹配里的 azure 那条（9.9）
        let cat = ModelPricingCatalog(cacheURL: tempJSON(Self.sampleJSON), bundledURL: nil, minBytesOverride: 0)
        XCTAssertEqual(cat.unitPricing(rawModel: "gpt-4o")?.inputUSDPerMTok ?? 0, 2.5, accuracy: 1e-9)
    }
```

- [x] **Step 8: 跑全部 fallback + catalog 测试**

Run: `cd macos && swift test --filter ModelPriceTableFallbackTests && swift test --filter ModelPricingCatalogTests`
Expected: 全 PASS。若 `testRealAliasesResolveToNonNilPricing` 有个别样本红 → 按 Step 6 注的回退方案处理那条，并在 commit message 里说明。

- [x] **Step 9: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/ModelPricingCatalog.swift macos/Tests/UsageBarTests/ModelPriceTableFallbackTests.swift macos/Tests/UsageBarTests/Fixtures/litellm_snapshot_frozen.json macos/Package.swift
git commit -m "feat: v0.2.14 — 逐级回退候选链 pricingCandidates（去 effort/codex 后缀、去 minor 版本号、加 provider 前缀）+ 前缀匹配排除 azure/vertex/bedrock；冻结 LiteLLM 快照 fixture 验真实别名命中 [spec:2026-05-13-litellm-pricing]"
```

---

## Task 3: `refreshIfStale` —— 3h 节流 + 原子替换 + meta 文件

**Files:**
- Modify: `macos/Sources/UsageBar/ModelPricingCatalog.swift`
- Test: `macos/Tests/UsageBarTests/ModelPricingCatalogTests.swift`

- [x] **Step 1: 写失败测试 —— 节流 + 触发下载写缓存+meta**

追加到 `ModelPricingCatalogTests`：

```swift
    private static let validDownloadJSON = #"{"gpt-5":{"input_cost_per_token":0.000003,"output_cost_per_token":0.000003}}"#

    func testRefreshSkippedWhenFresh() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("p.json")
        let metaURL = dir.appendingPathComponent("p.meta.json")
        try! Self.sampleJSON.data(using: .utf8)!.write(to: cacheURL)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try! #"{"fetched_at":"\#(ISO8601DateFormatter().string(from: t0))"}"#.data(using: .utf8)!.write(to: metaURL)
        var downloadCalled = false
        let cat = ModelPricingCatalog(cacheURL: cacheURL, bundledURL: nil, metaURL: metaURL,
                                      now: { t0 }, downloader: { cb in downloadCalled = true; cb(nil) },
                                      minBytesOverride: 0)
        cat.refreshIfStale(now: t0.addingTimeInterval(2 * 3600))   // 2h 后，未到 3h
        XCTAssertFalse(downloadCalled)
    }

    func testRefreshTriggersWhenStaleAndWritesCacheAndMeta() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("p.json")
        let metaURL = dir.appendingPathComponent("p.meta.json")
        try! Self.sampleJSON.data(using: .utf8)!.write(to: cacheURL)   // 旧内容：gpt-5 input 1.25
        // 无 meta 文件 → 视为「从未抓取」→ 应触发
        let exp = expectation(description: "download invoked")
        let cat = ModelPricingCatalog(
            cacheURL: cacheURL, bundledURL: nil, metaURL: metaURL,
            now: Date.init,
            downloader: { cb in cb(Self.validDownloadJSON.data(using: .utf8)); exp.fulfill() },
            minBytesOverride: 0)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        cat.refreshIfStale(now: t)
        wait(for: [exp], timeout: 2.0)
        // 下载在 Task.detached 里，给它一点时间落盘 + 重建表
        let done = expectation(description: "table updated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(cat.unitPricing(rawModel: "gpt-5")?.inputUSDPerMTok ?? 0, 3.0, accuracy: 1e-9) // 新值
            XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))
            // meta 里的 fetched_at == t
            let meta = try! JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as! [String: Any]
            XCTAssertEqual(meta["fetched_at"] as? String, ISO8601DateFormatter().string(from: t))
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)
    }

    func testRefreshWithBadDownloadKeepsOldCacheAndNoMeta() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("p.json")
        let metaURL = dir.appendingPathComponent("p.meta.json")
        try! Self.sampleJSON.data(using: .utf8)!.write(to: cacheURL)
        let exp = expectation(description: "download invoked")
        let cat = ModelPricingCatalog(cacheURL: cacheURL, bundledURL: nil, metaURL: metaURL,
                                      downloader: { cb in cb("not json at all".data(using: .utf8)); exp.fulfill() },
                                      minBytesOverride: 0)
        cat.refreshIfStale(now: Date(timeIntervalSince1970: 1_800_000_000))
        wait(for: [exp], timeout: 2.0)
        let done = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // 缓存没被改坏：gpt-5 还是旧值 1.25
            XCTAssertEqual(cat.unitPricing(rawModel: "gpt-5")?.inputUSDPerMTok ?? 0, 1.25, accuracy: 1e-9)
            XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path))   // 没写 meta
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)
    }
```

> 注：`refreshIfStale` 触发的下载用 `Task.detached`，所以上面用 `expectation` + `asyncAfter` 等它落盘。下载器本身是同步回调（测试注入的），但落盘+重建表那段为了不阻塞调用方放在 detached task 里——所以 `downloader` 的回调里 `exp.fulfill()` 只证明「下载被调」，真正的副作用要再等一拍。这是可接受的测试模式（项目里 `UsageHistoryServiceTests` 等也有类似）。

- [x] **Step 2: 跑确认失败**

Run: `cd macos && swift test --filter ModelPricingCatalogTests/testRefreshTriggersWhenStaleAndWritesCacheAndMeta`
Expected: FAIL（`refreshIfStale` 还是空实现）。

- [x] **Step 3: 实现 `refreshIfStale` + meta 读写 + 真 `URLSession` downloader**

替换 `ModelPricingCatalog.swift` 里的 `refreshIfStale` / `urlSessionDownloader`，并补 meta 读写：

```swift
    func refreshIfStale(now: Date) {
        lock.lock()
        if refreshInFlight { lock.unlock(); return }
        let last = Self.readFetchedAt(metaURL)
        if let last, now.timeIntervalSince(last) < Self.refreshInterval { lock.unlock(); return }
        refreshInFlight = true
        lock.unlock()

        let minBytes = effMinBytes      // 在持锁外取一次即可（init 后不变）
        downloader { [weak self] data in
            guard let self else { return }
            Task.detached(priority: .utility) {
                defer { self.lock.lock(); self.refreshInFlight = false; self.lock.unlock() }
                guard let data,
                      data.count >= minBytes,
                      data.count <= Self.Limits.maxBytes,
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let dict = obj as? [String: Any], !dict.isEmpty,
                      let cacheURL = self.cacheURL
                else { return }
                // 原子写缓存（.atomic = 同目录建临时文件再 rename，满足同卷原子）
                guard (try? data.write(to: cacheURL, options: [.atomic])) != nil else { return }
                // 写 meta（fetched_at = 发起刷新时传入的 now，已被闭包捕获）
                if let metaURL = self.metaURL {
                    let iso = ISO8601DateFormatter().string(from: now)
                    if let metaData = try? JSONSerialization.data(withJSONObject: ["fetched_at": iso]) {
                        try? metaData.write(to: metaURL, options: [.atomic])
                    }
                }
                // 重建内存表
                let parsed = Self.parse(dict)
                self.lock.lock(); self.table = parsed; self.loaded = true; self.lock.unlock()
            }
        }
    }

    private static func readFetchedAt(_ url: URL?) -> Date? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = obj["fetched_at"] as? String
        else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func urlSessionDownloader(from url: URL, maxBytes: Int) -> Downloader {
        { completion in
            // download task：写盘到临时位置而非全读内存，避免被超大响应 OOM。
            let task = URLSession.shared.downloadTask(with: url) { tmpURL, _, _ in
                guard let tmpURL,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: tmpURL.path),
                      let size = attrs[.size] as? Int, size <= maxBytes,
                      let data = try? Data(contentsOf: tmpURL)
                else { completion(nil); return }
                completion(data)
            }
            task.resume()
        }
    }
```

> ⚠️ 实现注意：
> 1. `now` 必须被 `downloader` 的逃逸闭包捕获、再带进 `Task.detached`（上面代码已这么写）——meta 里写的是「发起这次刷新时的逻辑时刻」，不是落盘时刻。
> 2. `effMinBytes`（= `minBytesOverride ?? Limits.minBytes`，Task 1 已加）在 `refreshIfStale` 开头取一次存进 `minBytes` 局部变量再带进闭包，避免在 detached task 里再摸 self 的属性。
> 3. **downloader 契约**：注入的 `Downloader` 必须保证最终调一次 `completion`（失败也要 `completion(nil)`）——否则 `refreshInFlight` 永久 true、再不刷新。生产的 `URLSession` download task 自带超时；测试 stub 自己负责调。
> 4. 真 `URLSession.shared.downloadTask` 已把响应写盘到 tmpURL，`stat` 它的 size 即可判上限，不必再看 `Content-Length` header。`completion(data)` 之后 `URLSession` 会自动清理 tmpURL。

- [x] **Step 4: 跑确认通过**

Run: `cd macos && swift test --filter ModelPricingCatalogTests`
Expected: 全 PASS（含 3 个新 refresh case）。

- [x] **Step 5: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/ModelPricingCatalog.swift macos/Tests/UsageBarTests/ModelPricingCatalogTests.swift
git commit -m "feat: v0.2.14 — ModelPricingCatalog.refreshIfStale（持久化 fetched_at meta 做 3h 节流；同步返回；detach URLSession download task → size 校验 → 原子写缓存+meta → 重建表；坏下载不动旧缓存）[spec:2026-05-13-litellm-pricing]"
```

---

## Task 4: 打包快照 + Package.swift 资源 + THIRD_PARTY_LICENSES.txt

**Files:**
- Create: `macos/Sources/UsageBar/Resources/litellm_model_prices.json`、`macos/Sources/UsageBar/Resources/THIRD_PARTY_LICENSES.txt`
- Modify: `macos/Package.swift`（确认 `Resources/` 已 `.process` —— CLAUDE.md 说已经是 `resources: [.process("Resources")]`，新文件自动进；无需改）

- [x] **Step 1: 抓上游全量快照提交进 Resources**

```bash
cd /Users/methol/data/code-methol/usage-bar
curl -fsSL https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json \
  -o macos/Sources/UsageBar/Resources/litellm_model_prices.json
python3 -c "import json; d=json.load(open('macos/Sources/UsageBar/Resources/litellm_model_prices.json')); assert len(d) > 100; print('ok, keys=', len(d))"
ls -la macos/Sources/UsageBar/Resources/litellm_model_prices.json   # 期望 ~1.5–3MB
```

- [x] **Step 2: 写 THIRD_PARTY_LICENSES.txt**

`macos/Sources/UsageBar/Resources/THIRD_PARTY_LICENSES.txt`（粘 LiteLLM 仓库的 MIT 全文 —— 从 https://github.com/BerriAI/litellm/blob/main/LICENSE 取；下面是模板，把 `<YEAR>` `<COPYRIGHT HOLDER>` 换成 LiteLLM LICENSE 文件里的实际值）：

```
This product bundles model price data from BerriAI/litellm
(file: litellm_model_prices.json, sourced from
https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json).

LiteLLM is distributed under the MIT License:

MIT License

Copyright (c) <YEAR> <COPYRIGHT HOLDER>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

> 用 `curl -fsSL https://raw.githubusercontent.com/BerriAI/litellm/main/LICENSE` 取实际 LICENSE 内容贴进去（年份/holder 以实际为准）。

- [x] **Step 3: 验证 bundle 资源能被 catalog 找到（写个 smoke test）**

追加到 `ModelPricingCatalogTests`：

```swift
    func testBundledSnapshotIsLoadable() {
        // 不注入路径 —— 用生产默认（cache 可能不存在，bundled 一定存在）
        // 注意：CI 上 ~/.config/usage-bar/ 通常没有 cache，所以这里实际测的是 bundled 路径
        let url = ModelPricingCatalog.defaultBundledURL
        XCTAssertNotNil(url, "bundled litellm_model_prices.json must be in the resource bundle")
        let cat = ModelPricingCatalog(cacheURL: nil, bundledURL: url)
        XCTAssertTrue(cat.isLoaded)
        XCTAssertNotNil(cat.unitPricing(rawModel: "gpt-4o"))         // 上游肯定有 gpt-4o
        XCTAssertNotNil(cat.unitPricing(rawModel: "claude-3-5-sonnet-20241022"))
    }
```

- [x] **Step 4: 跑测试 + 完整 build**

Run: `cd macos && swift build && swift test --filter ModelPricingCatalogTests`
Expected: PASS（`testBundledSnapshotIsLoadable` 绿 = 资源进了 bundle）。

- [x] **Step 5: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/Resources/litellm_model_prices.json macos/Sources/UsageBar/Resources/THIRD_PARTY_LICENSES.txt macos/Tests/UsageBarTests/ModelPricingCatalogTests.swift
git commit -m "feat: v0.2.14 — 打包 LiteLLM 全量价格快照 litellm_model_prices.json + THIRD_PARTY_LICENSES.txt（MIT 归属）进资源 bundle [spec:2026-05-13-litellm-pricing]"
```

---

## Task 5: `ClaudePricing` / `OpenAIPricing` 改委托 catalog；删静态表；迁移测试

**Files:**
- Modify: `macos/Sources/UsageBar/OpenAIPricing.swift`、`macos/Sources/UsageBar/ClaudePricing.swift`
- Modify: `macos/Tests/UsageBarTests/ClaudePricingTests.swift`、`macos/Tests/UsageBarTests/OpenAIPricingTests.swift`

- [x] **Step 1: 改 `OpenAIPricing.swift`**

删 `table`、`snapshotDate`、所有 `// UNVERIFIED` 注释、`lookup(model:)` 里查 `table` 的实现；`normalize` / `displayName` 保留原样。`OpenAIModelPriceTable.lookup` 改成：

```swift
struct OpenAIModelPriceTable: ModelPriceTable {
    static let shared = OpenAIModelPriceTable()
    func normalize(_ model: String) -> String { OpenAIPricing.normalize(model) }
    func lookup(_ model: String) -> ModelUnitPricing? { ModelPricingCatalog.shared.unitPricing(rawModel: model) }
    func displayName(_ model: String) -> String { OpenAIPricing.displayName(model) }
}
```

`OpenAIPricing` enum 里删掉 `lookup(model:)`（没人直接用了——确认 `grep -rn 'OpenAIPricing.lookup' macos/Sources`，只剩 table adapter 的话就删；若还有调用点改成走 `ModelPricingCatalog.shared.unitPricing`）。保留 `normalize` / `displayName` / 顶部那段「best-effort 估算、非账单」的免责注释（更新措辞：数据现在来自 LiteLLM 快照）。

- [x] **Step 2: 改 `ClaudePricing.swift`**

同理：删 `table`、`snapshotDate`、`cost(for:)`、`lookup(model:)`；`ClaudeModelPricing` struct 若 `grep -rn 'ClaudeModelPricing' macos/Sources` 显示没人用了也删（注意 `ClaudeModelPriceTable.lookup` 原来返回它转的 `ModelUnitPricing`——现在直接走 catalog 就不需要 `ClaudeModelPricing` 了）。`ClaudeModelPriceTable.lookup` 改成：

```swift
struct ClaudeModelPriceTable: ModelPriceTable {
    static let shared = ClaudeModelPriceTable()
    func normalize(_ model: String) -> String { ClaudePricing.normalize(model) }
    func lookup(_ model: String) -> ModelUnitPricing? { ModelPricingCatalog.shared.unitPricing(rawModel: model) }
    func displayName(_ model: String) -> String { ClaudePricing.displayName(model) }
}
```

`ClaudePricing` enum 保留 `normalize` / `displayName`。

- [x] **Step 3: 跑全套 build —— 看哪些测试编译炸了**

Run: `cd macos && swift build -c debug 2>&1 | head -30; swift test 2>&1 | tail -30`
Expected: `ClaudePricingTests.testLookupKnownModelReturnsPrice` / `testCostFormulaMatchesExpected`、`OpenAIPricingTests.testLookupKnownAndUnknown` / `testTablesConformToProtocol` 等会失败或编译错（依赖被删的 `cost(for:)` / `ClaudeModelPricing` / 静态表里的具体型号）。

- [x] **Step 4: 迁移 `ClaudePricingTests.swift`**

改成：保留 `testNormalizeStripsDateSuffix` / `testDisplayName`（这俩不依赖被删的东西）；删 `testLookupKnownModelReturnsPrice`（具体单价的断言迁去 `ModelPriceTableFallbackTests` 用 frozen fixture）、删 `testCostFormulaMatchesExpected`（`cost(for:)` 没了；`ModelUnitPricing.cost` 的公式已在 `OpenAIPricingTests.testModelUnitPricingCostFormula` 覆盖）；`testLookupUnknownReturnsNil` 改成 `XCTAssertNil(ClaudeModelPriceTable.shared.lookup("definitely-not-a-real-model-xyz"))`（走 catalog；用一个绝不会前缀匹配上的名）。

- [x] **Step 5: 迁移 `OpenAIPricingTests.swift`**

保留 `testNormalizeStripsDateSuffixAndLowercases` / `testDisplayName`；`testLookupKnownAndUnknown` 改成依赖 catalog（注意此时 catalog 走的是 bundle 里的真实快照——`OpenAIModelPriceTable.shared.lookup("gpt-5")` 应非空、`lookup("gpt-9000")` 应 nil）；`testModelUnitPricingCostFormula` 保留；`testTablesConformToProtocol` 改成不依赖具体单价（`XCTAssertNotNil(openai.lookup("gpt-5"))` 而非检查 `== 某数值`；`claude.lookup("claude-opus-4-7")` 非空——靠候选链退到 family）。

- [x] **Step 6: 跑全套测试**

Run: `cd macos && swift build -c release && swift test`
Expected: 全 PASS。`grep -nE 'static let table' macos/Sources/UsageBar/OpenAIPricing.swift macos/Sources/UsageBar/ClaudePricing.swift` → 无输出（SC_AUTO_NO_STATIC_TABLE 绿）。

- [x] **Step 7: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/OpenAIPricing.swift macos/Sources/UsageBar/ClaudePricing.swift macos/Tests/UsageBarTests/ClaudePricingTests.swift macos/Tests/UsageBarTests/OpenAIPricingTests.swift macos/Tests/UsageBarTests/ModelPriceTableFallbackTests.swift
git commit -m "refactor: v0.2.14 — 删 OpenAIPricing/ClaudePricing 手写静态表（含 snapshotDate / cost(for:) / ClaudeModelPricing），lookup 改委托 ModelPricingCatalog；迁移对应测试到 frozen fixture / catalog [spec:2026-05-13-litellm-pricing]"
```

---

## Task 6: 接进 `ProviderCoordinator` 统一 tick

**Files:**
- Modify: `macos/Sources/UsageBar/ProviderCoordinator.swift`
- Test: `macos/Tests/UsageBarTests/ProviderCoordinatorTests.swift`

- [x] **Step 1: 写失败测试 —— tick 会调 `refreshIfStale`**

现有 `ProviderCoordinatorTests.swift` 有 helper `freshDefaults() -> UserDefaults` 和 `makeCoordinator(_ d: UserDefaults, withCodex: Bool = true) -> ProviderCoordinator`（多数 case 用 `makeCoordinator(freshDefaults())`）。难点：`ModelPricingCatalog.shared` 是单例，不好注入 spy。**做法**：给 `ProviderCoordinator` 加一个可注入的 hook `var onTickSideEffects: () -> Void = { ModelPricingCatalog.shared.refreshIfStale(now: Date()) }`，`onBackgroundTick()` 末尾调它；测试里替换成 spy。

```swift
    func testBackgroundTickInvokesPricingRefreshHook() {
        let coord = makeCoordinator(freshDefaults())
        var called = 0
        coord.onTickSideEffects = { called += 1 }
        coord.onBackgroundTick()
        XCTAssertGreaterThanOrEqual(called, 1)
    }
```

- [x] **Step 2: 跑确认失败**

Run: `cd macos && swift test --filter ProviderCoordinatorTests/testBackgroundTickInvokesPricingRefreshHook`
Expected: FAIL（没有 `onTickSideEffects`）。

- [x] **Step 3: 实现 hook**

`ProviderCoordinator.swift`：加属性

```swift
    /// 每次后台 tick 的「附带副作用」——默认让价格目录按 3h 节流自刷新。可注入便于测试。
    var onTickSideEffects: () -> Void = { ModelPricingCatalog.shared.refreshIfStale(now: Date()) }
```

`onBackgroundTick()` 函数体最后加一行 `onTickSideEffects()`。`startBackgroundPolling()` 里（在 `onBackgroundTick()` 那次立即调用之外，无需额外加——`onBackgroundTick()` 已经会调 `onTickSideEffects`，启动那次立即 tick 就覆盖了「app 启动调一次」）。

> 注：首次访问 `ModelPricingCatalog.shared` 会触发 `init` → `reload()`（同步读 ~2MB 文件 + `JSONSerialization`），发生在 MainActor 的这次 tick 里——一次性、~几十 ms，可接受；不值得为此把首次 reload 丢后台（会让「启动后 cost 卡数据可用」延迟）。

- [x] **Step 4: 跑确认通过 + 全套**

Run: `cd macos && swift test --filter ProviderCoordinatorTests && swift build -c release && swift test`
Expected: 全 PASS。`grep -nE 'Timer\.scheduledTimer|DispatchSourceTimer|Timer\.publish' macos/Sources/UsageBar/ModelPricingCatalog.swift` → 无输出。

- [x] **Step 5: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/ProviderCoordinator.swift macos/Tests/UsageBarTests/ProviderCoordinatorTests.swift
git commit -m "feat: v0.2.14 — ProviderCoordinator 后台 tick 末尾调 ModelPricingCatalog.refreshIfStale（onTickSideEffects hook，可注入）；不新增 Timer [spec:2026-05-13-litellm-pricing]"
```

---

## Task 7: `LocalCostCard` 文案

**Files:**
- Modify: `macos/Sources/UsageBar/LocalCostCard.swift`

- [x] **Step 1: 看现状**

`grep -n '价格表过时\|unknownModelCount\|isLoaded' macos/Sources/UsageBar/LocalCostCard.swift`。当前（`LocalCostCard.swift:112-113`）：
```swift
if summary.unknownModelCount > 0 {
    Text("含 \(summary.unknownModelCount) 条未知模型调用（价格表过时？）")
}
```

- [x] **Step 2: 改文案 + 加空表分支**

```swift
if !ModelPricingCatalog.shared.isLoaded {
    Text("定价数据未加载，费用估算暂不可用")
        .font(.caption2).foregroundStyle(.secondary)
} else if summary.unknownModelCount > 0 {
    Text("含 \(summary.unknownModelCount) 条无定价数据的调用")
        .font(.caption2).foregroundStyle(.secondary)
}
```
（字体/颜色 modifier 照搬原来那行的；只改文案 + 加 `if` 分支。）

- [x] **Step 3: build**

Run: `cd macos && swift build -c release`
Expected: 成功。`grep -F '价格表过时' macos/Sources/UsageBar/LocalCostCard.swift` → 无输出。

- [x] **Step 4: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/LocalCostCard.swift
git commit -m "feat: v0.2.14 — LocalCostCard 文案区分「无定价数据的调用」与「定价数据未加载」，去掉「价格表过时」暗示 [spec:2026-05-13-litellm-pricing]"
```

---

## Task 8: `build.sh` 刷新 + 还原工作区；`verify-release.sh` 增检

**Files:**
- Modify: `macos/scripts/build.sh`、`macos/scripts/verify-release.sh`

- [x] **Step 1: build.sh 加 `fetch_litellm_prices()`**

在 `build.sh`（`build_app_bundle()` 调 `swift build` 之前）加：

```bash
fetch_litellm_prices() {
    local dest="$PROJECT_DIR/Sources/UsageBar/Resources/litellm_model_prices.json"
    local tmp="$BUILD_DIR/litellm_model_prices.json.dl"
    mkdir -p "$BUILD_DIR"
    if ! curl -fsSL --max-time 30 "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json" -o "$tmp" 2>/dev/null; then
        echo "warning: litellm price fetch failed (curl); keeping committed snapshot"
        return 0
    fi
    local size; size=$(stat -f%z "$tmp" 2>/dev/null || stat -c%s "$tmp" 2>/dev/null || echo 0)
    if [[ "$size" -lt 50000 || "$size" -gt 10000000 ]]; then
        echo "warning: litellm price fetch size out of range ($size bytes); keeping committed snapshot"; return 0
    fi
    if ! "$PLUTIL" -lint "$tmp" >/dev/null 2>&1; then
        echo "warning: litellm price fetch not valid JSON; keeping committed snapshot"; return 0
    fi
    cp "$tmp" "$dest"
    echo "==> Refreshed litellm price snapshot ($size bytes)"
}
```
并在 `build_app_bundle()` 里 `swift build` **之前**调 `fetch_litellm_prices`。

- [x] **Step 2: build.sh 装配完成后还原工作区**

加函数：

```bash
restore_litellm_snapshot() {
    # build 时 fetch_litellm_prices 覆盖了 committed 副本 —— 装配完成后还原，让 dev/CI 工作区保持干净。
    if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$PROJECT_DIR" checkout -- "Sources/UsageBar/Resources/litellm_model_prices.json" 2>/dev/null || true
    fi
}
```

**调用点**：放在 `build_app_bundle()` **函数体的最后一行**（与 `fetch_litellm_prices` 在函数开头对称——`swift build` 之前 fetch、bundle 装配完之后 restore，一进一出都在同一个函数里，`--skip-build` 时整个函数不跑、也就不会有多余的 `git checkout`）。

> 路径说明：`build.sh` 里 `cd "$PROJECT_DIR"`（= `macos/`）；git 仓库根在 `macos/` 的上一层。`git -C "$PROJECT_DIR"` 把 git 的 cwd 设成 `macos/`，git 自动向上找到 `.git`；pathspec `Resources/litellm_model_prices.json` 相对该 cwd 解析 → `macos/Sources/UsageBar/Resources/litellm_model_prices.json` —— 命中目标。tarball 构建（无 `.git`）时 `rev-parse` 失败 → 跳过、不报错。

- [x] **Step 3: verify-release.sh 增检**

在 `verify_app_bundle()` 的 `echo "==> Verifying packaged resources..."` 那段，加（紧挨现有的 `claude-logo.png` 检查后面）：

```bash
    local litellm_json="$resource_bundle/litellm_model_prices.json"
    [[ -f "$litellm_json" ]] || { echo "Error: missing bundled litellm_model_prices.json"; exit 1; }
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$litellm_json" || { echo "Error: bundled litellm_model_prices.json is not valid JSON"; exit 1; }
    fi
    local litellm_size; litellm_size=$(stat -f%z "$litellm_json" 2>/dev/null || stat -c%s "$litellm_json" 2>/dev/null || echo 0)
    [[ "$litellm_size" -gt 100000 ]] || { echo "Error: bundled litellm_model_prices.json too small ($litellm_size bytes)"; exit 1; }
    [[ -f "$resource_bundle/THIRD_PARTY_LICENSES.txt" ]] || { echo "Error: missing bundled THIRD_PARTY_LICENSES.txt"; exit 1; }
```
（`$resource_bundle` 变量在 `verify_app_bundle` 里已定义为 `.../UsageBar_UsageBar.bundle`。）

- [x] **Step 4: 跑全流程验证**

```bash
cd /Users/methol/data/code-methol/usage-bar
make app                                  # 应看到 "==> Refreshed litellm price snapshot ..." 或 warning
git diff --quiet -- macos/Sources/UsageBar/Resources/litellm_model_prices.json && echo "WORKTREE CLEAN ✓"   # 必须打印
make zip
bash macos/scripts/verify-release.sh macos/UsageBar.zip   # 应过，含新的 litellm 检查
```
Expected: `make app` 成功；worktree clean ✓；verify-release 全绿。

- [x] **Step 5: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/scripts/build.sh macos/scripts/verify-release.sh
git commit -m "build: v0.2.14 — build.sh 构建前 curl 刷新 litellm 快照（失败仅 warning）+ 构建后 git checkout 还原工作区；verify-release.sh 增检 bundle 内 litellm_model_prices.json 存在/合法 JSON/size>100KB + THIRD_PARTY_LICENSES.txt [spec:2026-05-13-litellm-pricing]"
```

---

## Task 9: 文档同步 + 最终验证 + spec verification log

**Files:**
- Modify: `CLAUDE.md`、`README.md`、`docs/superpowers/specs/2026-05-13-litellm-pricing.md`（verification log + SC done）、`docs/versions/v0.2.14-litellm-pricing.md`、`docs/superpowers/plans/2026-05-13-litellm-pricing.md`（勾完）

- [x] **Step 1: CLAUDE.md**

「Architecture — what spans files」里 token/history 那段后面加一条 bullet，或在「Style & dependencies」里加：

> - **模型估价数据来自打包的 LiteLLM 快照**（`macos/Sources/UsageBar/Resources/litellm_model_prices.json`，上游 `BerriAI/litellm` 的 `model_prices_and_context_window.json`）。`macos/scripts/build.sh` 在 `swift build` 前用 `curl` 刷新它、构建后 `git checkout --` 还原工作区（所以平时 `git status` 干净；下载失败就用 committed 副本）。运行期 `ModelPricingCatalog` 优先读 `~/.config/usage-bar/litellm_model_prices.json`（由 `ProviderCoordinator` 的统一 tick 每 3h 后台刷新），否则读 bundle 副本。新增 bundled 资源须同步更新 `macos/scripts/verify-release.sh`。`OpenAIPricing` / `ClaudePricing` 现在只剩 `normalize`/`displayName`（手维护），价格查表全走 `ModelPricingCatalog`（含逐级回退候选链）。

- [x] **Step 2: README.md**

致谢/acknowledgments 段（没有就在 `## License` 附近加一小段）加一行：
> 模型估价数据来自 [BerriAI/litellm](https://github.com/BerriAI/litellm)（`model_prices_and_context_window.json`），MIT License。

- [x] **Step 3: 跑全部硬证据**

```bash
cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release && swift test
cd /Users/methol/data/code-methol/usage-bar && make release-artifacts
bash macos/scripts/verify-release.sh macos/UsageBar.zip
bash macos/scripts/verify-release.sh macos/UsageBar.dmg
git status --porcelain   # 应只有本 plan/spec/version/CLAUDE/README 这几个 doc 文件待提交，无 litellm_model_prices.json
# automated_checks 逐条：
! grep -nE 'static let table' macos/Sources/UsageBar/OpenAIPricing.swift macos/Sources/UsageBar/ClaudePricing.swift && echo "SC_AUTO_NO_STATIC_TABLE ✓"
! grep -nE 'Timer\.scheduledTimer|DispatchSourceTimer|Timer\.publish' macos/Sources/UsageBar/ModelPricingCatalog.swift && echo "SC_AUTO_NO_NEW_TIMER ✓"
! grep -F '价格表过时' macos/Sources/UsageBar/LocalCostCard.swift && echo "SC_AUTO_NO_STALE_COPY ✓"
```
Expected: 全绿。

- [x] **Step 4: 回填 spec verification log + SC done**

`docs/superpowers/specs/2026-05-13-litellm-pricing.md`：每条 SC1~SC8 的 `done: true` + `evidence:` 填实际证据（测试名 / 命令输出 / commit hash）；底部 `## Verification log` 的 `- [x] SCx — pending` 改成 `- [x] SCx — <evidence>`；`status: accepted` → `implemented`（G6 全勾后）。`docs/superpowers/specs/README.md` 那行 status 同步改 `implemented`。

`docs/versions/v0.2.14-litellm-pricing.md`：G6 checklist 勾「所有 spec 的 spec_criteria 全 done」「CI 全绿」；`status: planned` → `in-progress`；填 `release_notes_zh`（分类「修复 / 改进 / 内部」，参考其它 version 文件的写法）。`docs/versions/README.md` 那行 status 同步。

- [x] **Step 5: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add CLAUDE.md README.md docs/
git commit -m "docs: v0.2.14 — CLAUDE.md/README 同步 LiteLLM 价格数据说明；spec verification log 回填 SC1~SC8 全勾、status→implemented；version status→in-progress + release_notes_zh；plan 勾完 [spec:2026-05-13-litellm-pricing]"
```

---

## Self-Review notes

- **Spec coverage**：SC1→Task1；SC2→Task5；SC3→Task2；SC4→Task2 Step6；SC5→Task8 Step1+2；SC6→Task3+Task6；SC7→Task8 Step3；SC8→Task7。`automated_checks` 全在 Task9 Step3 验。`manual_checks`（断网 build / 联网 build worktree clean / 删缓存实机）—— 前两条在 Task8 Step4 部分覆盖（联网那次），断网那次需手动断网跑一次（执行者注意）；实机那条在 Task9 之后手动验。
- **类型一致性**：`ModelPricingCatalog` 的 `unitPricing(rawModel:)` / `refreshIfStale(now:)` / `pricingCandidates(for:)` / `isLoaded` / `minBytesOverride` / `onTickSideEffects` 全程同名。`ModelUnitPricing` 复用既有。
- **已知坑**：Task1 的 size 下限会卡掉小 fixture —— 用 `minBytesOverride: 0`（Step5 的修正注已写明，实现时务必带这个 init 参数）。Task2 Step6 若某真实别名在当前快照彻底查不到 → 按 Step6 注的回退方案降级该断言 + spec 注明。
