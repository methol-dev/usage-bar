import Foundation

/// 模型 → per-Mtok 单价的运行时目录，数据来自 [LiteLLM](https://github.com/BerriAI/litellm) 的
/// `model_prices_and_context_window.json`（社区维护的全厂商价格库）。
///
/// 加载优先级：① `~/.config/usage-bar/litellm_model_prices.json`（运行期缓存，3h 后台刷新写入）
/// → ② app bundle 内打包的同名快照（offline 兜底）→ ③ 都失败：空表（`isLoaded == false`，所有查表 nil）。
/// 价格随上游自动更新，不再随发版手维护。**估算口径**：与既有 `OpenAIPricing` / `ClaudePricing` 一致，
/// 是 list-price 估算、不是真实账单——ChatGPT/Codex/Claude 套餐是「包额度」计费，没有按 token 收费的口径。
///
/// 安全/健壮性：上游 URL 是编译期常量、无运行时覆盖路径；下载与读取都加 size 上下限防 OOM；
/// 所有 JSON 访问用 optional cast，单个 key 解析失败仅跳过该 key（不抛、不 crash）。
final class ModelPricingCatalog: @unchecked Sendable {
    static let shared = ModelPricingCatalog()

    /// 上游全量快照地址（编译期常量）。固定 `main` 分支，与 ccusage 一致；无 UserDefaults/环境变量覆盖路径。
    static let upstreamURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    enum Limits { static let minBytes = 50_000; static let maxBytes = 10_000_000 }
    static let refreshInterval: TimeInterval = 3 * 60 * 60   // 写死 3h

    /// 顶层非模型键，解析时排除。
    private static let nonModelKeys: Set<String> = ["sample_spec"]
    /// key 里出现这些 provider 路由前缀的，前缀匹配阶段不予采纳（命中 bedrock 的 claude 价格是错的）。
    static let foreignRoutePrefixes = ["azure/", "azure_ai/", "vertex_ai/", "bedrock/", "openrouter/", "databricks/", "watsonx/"]

    typealias Now = () -> Date
    /// 异步下载器：成功回调 raw bytes，失败回调 nil。**契约**：必须最终调一次 completion（含失败路径），
    /// 否则 `refreshInFlight` 会永久卡 true、再不刷新。生产用 `URLSession` download task（自带超时）。
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
        self.downloader = downloader ?? ModelPricingCatalog.urlSessionDownloader(from: ModelPricingCatalog.upstreamURL,
                                                                                 maxBytes: Limits.maxBytes)
        reload()
    }

    private var effMinBytes: Int { minBytesOverride ?? Limits.minBytes }

    // MARK: - 默认路径

    static var defaultCacheURL: URL? { configDir()?.appendingPathComponent("litellm_model_prices.json") }
    static var defaultMetaURL: URL? { configDir()?.appendingPathComponent("litellm_model_prices.meta.json") }
    static var defaultBundledURL: URL? { Bundle.module.url(forResource: "litellm_model_prices", withExtension: "json") }

    /// `~/.config/usage-bar/`，与 `StoredCredentials` 等一致。
    private static func configDir() -> URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("usage-bar", isDirectory: true)
    }

    // MARK: - 加载

    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded }

    /// 测试用：强制按当前 cache/bundled 重读一次。
    func reloadTableForTesting() { reload() }
    /// 测试用：后台刷新是否还在进行（用来轮询等 detach task 落盘完成，不用裸 sleep）。
    var isRefreshInFlightForTesting: Bool { lock.lock(); defer { lock.unlock() }; return refreshInFlight }

    private func reload() {
        let parsed = Self.loadParsed(from: cacheURL, minBytes: effMinBytes)
            ?? Self.loadParsed(from: bundledURL, minBytes: effMinBytes)
        lock.lock()
        table = parsed ?? [:]
        loaded = parsed != nil
        lock.unlock()
    }

    /// 读一个文件 → size 在 [minBytes, maxBytes] → JSON 顶层 dict → 解析。任何一步失败返回 nil（不抛）。
    private static func loadParsed(from url: URL?, minBytes: Int) -> [String: ModelUnitPricing]? {
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int),
              size >= minBytes, size <= Limits.maxBytes,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any], !dict.isEmpty
        else { return nil }
        let parsed = parse(dict)
        return parsed.isEmpty ? nil : parsed
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
            if inPT == 0 && outPT == 0 && crPT == 0 && cwPT == 0 { continue }   // 无价格字段 → 跳过
            out[rawKey.lowercased()] = ModelUnitPricing(
                inputUSDPerMTok: inPT * 1_000_000,
                outputUSDPerMTok: outPT * 1_000_000,
                cacheReadUSDPerMTok: crPT * 1_000_000,
                cacheWriteUSDPerMTok: cwPT * 1_000_000)
        }
        return out
    }

    // MARK: - 查表（逐级回退候选链）

    func unitPricing(rawModel: String) -> ModelUnitPricing? {
        lock.lock(); let snapshot = table; lock.unlock()
        guard !snapshot.isEmpty else { return nil }
        let candidates = Self.pricingCandidates(for: rawModel)
        for cand in candidates {
            if let hit = snapshot[cand] { return hit }
        }
        // 步骤 6：前缀匹配 —— 以任一候选为前缀的 key，排除带 foreign route 前缀的，字典序第一（确定性）。
        let keys = snapshot.keys.sorted()
        for cand in candidates {
            if let k = keys.first(where: { key in
                key.hasPrefix(cand) && !Self.foreignRoutePrefixes.contains(where: { key.contains($0) })
            }) {
                return snapshot[k]
            }
        }
        return nil
    }

    /// 逐级回退候选链（小写后，按优先级，去重）。纯函数，方便单测。
    /// 步骤 2–4 是 OpenAI / codex CLI 内部别名专用的（需随其演进维护，见 spec §2 注）；步骤 5 两边都用；
    /// 前缀匹配（步骤 6）由 `unitPricing` 在跑完本列表后单独做。
    static func pricingCandidates(for rawModel: String) -> [String] {
        let base = rawModel.lowercased()
        var out: [String] = []
        func push(_ s: String) { if !s.isEmpty, !out.contains(s) { out.append(s) } }

        // ① 原名
        push(base)

        // ② 去 reasoning-effort 后缀
        let noEffort = base.replacingOccurrences(of: #"-(minimal|low|medium|high|xhigh)$"#,
                                                 with: "", options: .regularExpression)
        push(noEffort)

        // ③ 去 codex 家族后缀退基座（在「去 effort 后」的名上做）
        var noCodex = noEffort
        for suffix in ["-codex-max", "-codex-spark", "-codex-mini", "-codex"] {
            if noCodex.hasSuffix(suffix) { noCodex = String(noCodex.dropLast(suffix.count)); break }
        }
        push(noCodex)

        // ④ 去 minor 版本号：gpt-5.3 → gpt-5；gpt-5.3-mini → gpt-5-mini（仅对 "gpt-<major>.<minor>[-<size>]" 形态）
        func dropMinor(_ s: String) -> String? {
            guard s.range(of: #"^gpt-\d+\.\d+(-[a-z]+)?$"#, options: .regularExpression) != nil else { return nil }
            let body = s.dropFirst(4)                       // 去 "gpt-"
            let majorMinor = body.prefix { $0 != "-" }      // "<major>.<minor>"
            let rest = body.dropFirst(majorMinor.count)     // "" 或 "-<size>"
            guard let dot = majorMinor.firstIndex(of: ".") else { return nil }
            return "gpt-\(majorMinor[..<dot])\(rest)"
        }
        for cand in [noCodex, noEffort, base] {
            if let d = dropMinor(cand) { push(d) }
        }

        // ⑤ provider 前缀（对当前已 push 的每个非带 "/" 候选都加 openai/ 和 anthropic/）
        let snapshot = out
        for c in snapshot where !c.contains("/") {
            push("openai/\(c)")
            push("anthropic/\(c)")
        }
        return out
    }

    // MARK: - 后台刷新（3h 节流）

    /// 同步、立即返回。若距上次抓取（持久化在 meta 文件的 `fetched_at`）≥ 3h，则后台 detach 一次下载并原子替换缓存。
    /// `now` 传当前逻辑时刻（也是写进 meta 的 `fetched_at`）。
    func refreshIfStale(now: Date) {
        lock.lock()
        if refreshInFlight { lock.unlock(); return }
        if let last = Self.readFetchedAt(metaURL), now.timeIntervalSince(last) < Self.refreshInterval {
            lock.unlock(); return
        }
        refreshInFlight = true
        lock.unlock()

        let minBytes = effMinBytes
        downloader { [weak self] data in
            guard let self else { return }
            Task.detached(priority: .utility) {
                defer { self.lock.lock(); self.refreshInFlight = false; self.lock.unlock() }
                guard let data,
                      data.count >= minBytes, data.count <= Self.Limits.maxBytes,
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let dict = obj as? [String: Any], !dict.isEmpty,
                      let cacheURL = self.cacheURL
                else { return }
                let parsed = Self.parse(dict)
                guard !parsed.isEmpty else { return }
                // 原子写缓存（.atomic = 同目录建临时文件再 rename）
                guard (try? data.write(to: cacheURL, options: [.atomic])) != nil else { return }
                // 写 meta（fetched_at = now，已被闭包捕获）
                if let metaURL = self.metaURL,
                   let metaData = try? JSONSerialization.data(withJSONObject: ["fetched_at": ISO8601DateFormatter().string(from: now)]) {
                    try? metaData.write(to: metaURL, options: [.atomic])
                }
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
                      let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int), size <= maxBytes,
                      let data = try? Data(contentsOf: tmpURL)
                else { completion(nil); return }
                completion(data)
            }
            task.resume()
        }
    }
}
