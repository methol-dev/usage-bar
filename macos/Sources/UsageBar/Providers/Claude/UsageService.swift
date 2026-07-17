import Foundation
import Observation

@MainActor
@Observable
final class UsageService {
    var usage: UsageResponse?
    var lastError: String?
    var lastUpdated: Date?
    var isAuthenticated = false {
        didSet { runtime.setConfigured(isAuthenticated) }
    }

    // v0.2.5: 窄化成协议，便于单测注入 spy（实参仍是 UsageHistoryService / NotificationService）
    var historyService: HistoryRecording?
    var notificationService: UsageNotifying?

    /// v0.2.5 多供应商抽象：Claude provider 的 UI 状态容器（每次 fetch 后镜像写入）。
    let runtime: ProviderRuntime

    private let usageStats: UsageStatsService
    private let session: URLSession
    private let usageEndpoint: URL
    /// v0.5.1: in-memory only —— Claude 凭证不存盘，启动/过期时从 Claude CLI Keychain 重读。
    /// nil = 尚未拉取或上次拉取失败；非 nil 但 isExpired() → 需重读。
    private var inMemoryCredentials: StoredCredentials?

    #if DEBUG
    /// 测试种子（@testable import 可见，因 access 是 internal）。
    func _test_setInMemoryCredentials(_ c: StoredCredentials?) { inMemoryCredentials = c }
    #endif

    /// v0.2.7：refresh 永久失败时回退去读 Claude CLI Keychain（fail-silent，不弹 ACL）。`internal` 是为单测可替换。
    /// v0.5.1：签名升级 —— 增加 `allowInteraction` 参数（false=后台 polling 安全、true=前台用户操作）。
    var cliKeychainLoader: (_ allowInteraction: Bool) async -> StoredCredentials? = { allowInteraction in
        try? await ClaudeCLICredentialsStrategy().loadCredentials(allowInteraction: allowInteraction)
    }
    /// 429 backoff 状态：`currentBackoffSeconds` = 当前 backoff 时长（0 = 不在 backoff，用于指数递增）；`backoffUntil` = 「这之前别再拉」的截止时刻。
    /// v0.2.11：取代原 `currentInterval`（自持 timer 退役后，「下次拉的间隔」由 `ProviderCoordinator` 的统一 timer 负责）。
    private var currentBackoffSeconds: TimeInterval = 0
    private var backoffUntil: Date?
    /// 重入保护（与 Codex/Gemini provider 同款）：后台 tick、popover Refresh、updatePollingInterval
    /// 三个入口可能在 `session.data(for:)` 挂起点交错，没有 guard 会产生重复请求 + 重复 history 数据点。
    private var isRefreshing = false
    /// 账号切换代际：`retrySignIn()` 时 +1；在飞的 fetch 在写值前比对，不一致即丢弃陈旧响应
    /// （`ProviderCoordinator.onBackgroundTick` 的注释依赖这一兜底）。
    private var accountSwitchEpoch = 0
    /// 后台 tick 时额外回调（驱动 Claude 的本机用量统计刷新；装配处设成 `{ Task { await usageStats.refresh() } }`，`UsageStatsService.refresh` 内部已自管 detached 后台优先级）。
    var onPollTick: (@MainActor () -> Void)?

    static let defaultPollingMinutes = 30
    static let pollingOptions = [5, 15, 30, 60]
    nonisolated static let maxBackoffInterval: TimeInterval = 60 * 60
    nonisolated static let defaultUsageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private(set) var pollingMinutes: Int

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
        runtime.setConfigured(isAuthenticated)
    }
}

// MARK: - UsageProvider conformance (v0.2.5 multi-provider refactor)
//
// `UsageService` 就是 Claude 的 `UsageProvider` 实现。`runtime` 是类体里的存储属性；
// `fetchUsage()` 在成功/失败时已镜像写它。
// v0.2.11：后台轮询的 recurring 由 `ProviderCoordinator` 的统一 timer 管（`UsageService` 不再自持 `Timer`）；
// `nextEligibleRefresh`（= `backoffUntil`）让 coordinator 在 429 backoff 窗口内跳过本 provider。

extension UsageService: UsageProvider {
    var id: ProviderID { .claude }
    var isConfigured: Bool { isAuthenticated }
    /// `UsageProvider.nextEligibleRefresh` —— coordinator 的统一 timer 在 backoff 窗口内会跳过本 provider。
    var nextEligibleRefresh: Date? { backoffUntil }

    /// 「拉一次」（popover Refresh 按钮 / coordinator 的后台 tick）。不做内部节流——Refresh 按钮就是要强制重拉。
    func refreshNow() async {
        await fetchUsage()
    }
}

// MARK: - In-memory credentials entry (v0.5.1)
//
// 凭证拉取统一入口 —— in-memory cache 命中直接返回；否则从 Claude CLI Keychain 重读并写回 cache。

extension UsageService {
    /// v0.5.1: 凭证拉取统一入口 —— in-memory cache 命中直接返回；否则从 Claude CLI Keychain 重读并写回 cache。
    /// - Parameter allowInteraction: false=后台 polling 安全（ACL prompt 静默降级返回 nil）；true=前台用户操作（允许首次弹 ACL）。
    /// - Returns: 最新有效 credentials；Keychain 无 / 不可读 / 解析失败 → nil。
    func ensureFreshCredentials(allowInteraction: Bool) async -> StoredCredentials? {
        // 注：cache hit / loader 重读 两条路径都显式写 isAuthenticated。
        // isAuthenticated didSet 已同步 runtime.setConfigured；
        // UI 依赖 `claude.isAuthenticated` 决定 Claude tab 错误卡里是否给 Retry 入口（未认证降级态）。
        // cache hit 时如 _test_setInMemoryCredentials 注入或某些 race 后 isAuthenticated 未同步，需补一次写。
        if let c = inMemoryCredentials, !c.isExpired() {
            isAuthenticated = true
            return c
        }
        let creds = await cliKeychainLoader(allowInteraction)
        inMemoryCredentials = creds
        isAuthenticated = (creds != nil)
        return creds
    }

    /// v0.5.1 Retry 按钮 / 启动 task 用：清 cache + force allowInteraction=true 重读 Keychain。
    /// 与 ensureFreshCredentials(allowInteraction: false) 的区别：① 必清 cache（绕过未过期判定）；② 允许首次 ACL prompt。
    func retrySignIn() async {
        accountSwitchEpoch += 1
        inMemoryCredentials = nil
        _ = await ensureFreshCredentials(allowInteraction: true)
    }
}

// MARK: - Polling & Fetch
//
// v0.2.11：自持 `Timer` 退役 —— 后台轮询的 recurring 由 `ProviderCoordinator` 的统一 timer 管（间隔 = `pollingMinutes`，
// 监听 UserDefaults 变化重起）；每个 tick coordinator 会调 `refreshNow()`（跳过 `nextEligibleRefresh` 还在未来的）+ `onPollTick?()`。
// 「立即拉一次」散到各调用点（`updatePollingInterval` / 装配处的 `coordinator.startBackgroundPolling()` 立即 tick）。

extension UsageService {
    func updatePollingInterval(_ minutes: Int) {
        pollingMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "pollingMinutes")
        // 后台轮询的 recurring 由 ProviderCoordinator 的统一 timer 负责 —— 它监听 `pollingMinutes` 的 UserDefaults 变化自动重起；
        // 这里只额外立即拉一次。
        if isAuthenticated { Task { [weak self] in await self?.fetchUsage() } }
    }

    private var baseInterval: TimeInterval { TimeInterval(pollingMinutes * 60) }

    // `usage` 现在只供 UsageService 内部用（reconcile + 下面三个便捷比例 + mapToSnapshot 经由 asProviderSnapshot()）；
    // UI 层读 `runtime.snapshot`（v0.2.5 多供应商重构）。
    var pct5h: Double { (usage?.fiveHour?.utilization ?? 0) / 100.0 }
    var pct7d: Double { (usage?.sevenDay?.utilization ?? 0) / 100.0 }
    var pctExtra: Double { (usage?.extraUsage?.utilization ?? 0) / 100.0 }

    // MARK: API Fetch

    func fetchUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let epoch = accountSwitchEpoch

        // v0.5.1: 凭证读取走 ensureFreshCredentials（in-memory cache → Claude CLI Keychain）；
        // 401 → 清 cache → 重读 Keychain；拿到新 token 重试一次；同 token 即报 token 过期。
        guard let creds = await ensureFreshCredentials(allowInteraction: false) else {
            // notice 而非 error：未装/未登录 Claude CLI 是正常的未配置态，每个轮询 tick 都会走到这里。
            DiagnosticLog.claudeUsage.notice("fetch aborted: no credentials (root cause in claude.credentials category)")
            lastError = "Sign in with Claude CLI, then tap Retry"
            isAuthenticated = false
            runtime.setError("Sign in with Claude CLI, then tap Retry", clearSnapshot: true)
            return
        }

        do {
            let (data, http) = try await performAuthorizedRequest(token: creds.accessToken, url: usageEndpoint)
            // 网络挂起期间若发生 retrySignIn（账号切换），丢弃这次陈旧响应，不写任何状态。
            guard epoch == accountSwitchEpoch else { return }

            if http.statusCode == 401 {
                DiagnosticLog.claudeUsage.warning("fetch: HTTP 401, re-reading credentials for one retry")
                let oldToken = creds.accessToken
                inMemoryCredentials = nil
                guard let retried = await ensureFreshCredentials(allowInteraction: false),
                      retried.accessToken != oldToken else {
                    DiagnosticLog.claudeUsage.error("fetch: 401 retry impossible (no fresher token) — token expired")
                    lastError = "Token expired; run `claude` to refresh."
                    isAuthenticated = false
                    runtime.setError("Token expired; run `claude` to refresh.", clearSnapshot: false)
                    return
                }
                let (data2, http2) = try await performAuthorizedRequest(token: retried.accessToken, url: usageEndpoint)
                guard epoch == accountSwitchEpoch else { return }
                try processUsageResponse(data: data2, http: http2)
                return
            }
            try processUsageResponse(data: data, http: http)
        } catch {
            guard epoch == accountSwitchEpoch else { return }
            // SC7：只记错误类别 + URLError code 数值（如 -1009 offline / -1200 TLS），
            // 不透传 userInfo / DecodingError context（可能含 URL 或 body 片段）。
            // 系统代理（PAC / HTTP proxy）问题通常表现为 -1003/-1004/-1200 类传输层错误。
            if error is DecodingError {
                DiagnosticLog.claudeUsage.error("fetch: HTTP 200 but response decode failed (schema drift?)")
            } else {
                let urlErrorCode = (error as? URLError)?.code.rawValue ?? 0
                DiagnosticLog.claudeUsage.error("fetch: transport error (URLError code \(urlErrorCode, privacy: .public))")
            }
            lastError = error.localizedDescription
            runtime.setError(error.localizedDescription, clearSnapshot: false)
        }
    }

    /// 抽出原 fetchUsage 内 200/429/non-200 写入 runtime 的部分，供 fetchUsage 主路径 + 401 retry 共用。
    private func processUsageResponse(data: Data, http: HTTPURLResponse) throws {
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let prev = currentBackoffSeconds == 0 ? baseInterval : currentBackoffSeconds
            currentBackoffSeconds = Self.backoffInterval(retryAfter: retryAfter, currentInterval: prev)
            backoffUntil = Date().addingTimeInterval(currentBackoffSeconds)
            // Retry-After 以 Double 插值（未消毒的服务端值转 Int 会 trap）；backoff 值经 backoffInterval 保证有限。
            DiagnosticLog.claudeUsage.warning("fetch: HTTP 429, Retry-After \(retryAfter ?? -1, privacy: .public)s, backing off \(Int(self.currentBackoffSeconds), privacy: .public)s")
            lastError = "Rate limited — backing off to \(Int(currentBackoffSeconds))s"
            runtime.setError(lastError ?? "Rate limited", clearSnapshot: false)
            return
        }
        guard http.statusCode == 200 else {
            DiagnosticLog.claudeUsage.error("fetch: HTTP \(http.statusCode, privacy: .public)")
            lastError = "HTTP \(http.statusCode)"
            runtime.setError("HTTP \(http.statusCode)", clearSnapshot: false)
            return
        }
        DiagnosticLog.claudeUsage.info("fetch: HTTP 200 ok")
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

    // MARK: Authorized requests

    private func performAuthorizedRequest(
        token: String,
        url: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // 上游自 2026-03 起按 User-Agent 对该端点分桶限流：无 UA / 未知 UA 落入激进桶，
        // 极易持续 429（见 anthropics/claude-code#31637）。先与 Codex provider 同款诚实 UA；
        // 若诊断日志证实仍持续 429，再评估是否对齐社区工具发 `claude-code/<version>`（ToS 灰区，
        // 属 AGENTS.md Hard Gate 6，需用户拍板）。
        request.setValue(AppHTTP.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

// MARK: - Backoff
//
// 单一计算：429 Retry-After + 指数翻倍 + 60min 上限。状态变量（`currentBackoffSeconds` / `backoffUntil`）
// 在类 body 内；fetchUsage 直接读写，UsageProvider conformance 通过 `nextEligibleRefresh` 暴露给 coordinator。

extension UsageService {
    nonisolated static func backoffInterval(
        retryAfter: TimeInterval?,
        currentInterval: TimeInterval
    ) -> TimeInterval {
        // Retry-After 是服务端/代理可控输入：`Double("inf")`/`Double("nan")` 都能解析成功，
        // NaN 会穿透 min/max 污染 backoff 状态（下游 `Int(...)` 插值直接 trap）。非有限或负值按缺失处理。
        let sanitized = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return min(max(sanitized ?? currentInterval, currentInterval * 2), maxBackoffInterval)
    }
}
