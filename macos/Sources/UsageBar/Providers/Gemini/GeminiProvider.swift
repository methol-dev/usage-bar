import Foundation

/// 测试用注入 protocol（`GeminiOAuthClientLocator` 实现它）。
protocol GeminiClientLocating {
    func findClientIdSecret() -> GeminiOAuthClientLocator.Result?
}

extension GeminiOAuthClientLocator: GeminiClientLocating {}

/// Gemini Code Assist for Individuals provider —— 复用本机 `~/.gemini/oauth_creds.json` + private quota endpoint。
/// 详见 spec `2026-05-13-gemini-provider`。
///
/// 401 处理策略（spec 风险 #7 缓解 a）：**不**在前置主动 refresh，只有当真实请求回 401 时
/// 才用 client_id/secret 跑一次 `GeminiCredentialStore.refresh` 并**重试一次**；refresh 失败 → 提示用户重新登录。
@MainActor
final class GeminiProvider: UsageProvider {
    let id: ProviderID = .gemini
    let runtime = ProviderRuntime()
    /// 本 provider 的历史样本（`history-gemini.json`，与 Claude/Codex 同结构、不同文件）。
    let history: UsageHistoryService

    var isConfigured: Bool { runtime.isConfigured }

    private let environment: [String: String]
    private let session: URLSession
    private let locator: GeminiClientLocating

    /// 重入闸门：并发 `refreshNow()` 只跑一份（后台 timer / Refresh 按钮 / popover 打开可能撞上）。
    /// `@MainActor` 序列化读写 —— 第二个调用在第一个的网络 `await` 期间进来会命中此 guard 直接 return。
    private var isRefreshing = false

    /// 后台 tick 时额外回调（Gemini 暂无本机统计，保留以满足协议；当前永不被设值/调用）。
    var onPollTick: (@MainActor () -> Void)? = nil
    /// 不做 backoff，coordinator 每 tick 都可调度本 provider。
    var nextEligibleRefresh: Date? { nil }

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         session: URLSession = .shared,
         locator: GeminiClientLocating? = nil,
         history: UsageHistoryService? = nil) {
        self.environment = environment
        self.session = session
        self.locator = locator ?? GeminiOAuthClientLocator()
        // 默认值不能写在参数上（`UsageHistoryService` 是 @MainActor，默认参数会在 nonisolated 上下文求值）——
        // 在 @MainActor 的 init 里现造。
        let h = history ?? UsageHistoryService(filename: "history-gemini.json")
        self.history = h
        // 轻量同步探测：oauth_creds.json 在不在 —— tab 一打开就显示对的「未配置 / 待拉取」态（不发网络）。
        let present = ((try? GeminiCredentialStore.load(environment: environment)) ?? nil) != nil
        runtime.setConfigured(present)
        h.loadHistory()
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 1. load creds —— 不存在 → 静默 unconfigured；存在但坏 → 错误文案
        let credsOpt: GeminiCredentials?
        do {
            credsOpt = try GeminiCredentialStore.load(environment: environment)
        } catch {
            runtime.setConfigured(false)
            runtime.setError("Gemini not signed in. Run `gemini` to sign in.", clearSnapshot: true)
            return
        }
        guard var current = credsOpt else {
            runtime.setConfigured(false)
            runtime.clear()
            return
        }
        runtime.setConfigured(true)

        // 2. locate OAuth client —— 失败 → unconfigured + 错误文案（401 路径也依赖它，故前置）
        guard let client = locator.findClientIdSecret() else {
            runtime.setConfigured(false)
            runtime.setError("gemini-cli not installed; cannot resolve OAuth credentials.", clearSnapshot: true)
            return
        }

        // 3. 一次完整调用尝试；401 → refresh + 重试一次
        do {
            try await fetchAndPublish(credentials: current)
        } catch GeminiUsageError.unauthorized {
            // refresh + retry
            do {
                current = try await GeminiCredentialStore.refresh(
                    credentials: current,
                    clientId: client.clientId,
                    clientSecret: client.clientSecret,
                    session: session,
                    environment: environment)
            } catch {
                runtime.setError("Gemini credentials expired. Run `gemini` to sign in again.", clearSnapshot: true)
                return
            }
            do {
                try await fetchAndPublish(credentials: current)
            } catch GeminiUsageError.unauthorized {
                runtime.setError("Gemini credentials expired. Run `gemini` to sign in again.", clearSnapshot: true)
            } catch GeminiUsageError.missingProject {
                runtime.setError("No Gemini Code Assist project found.", clearSnapshot: true)
            } catch {
                runtime.setError("Could not fetch Gemini usage. Will retry.", clearSnapshot: false)
            }
        } catch GeminiUsageError.missingProject {
            runtime.setError("No Gemini Code Assist project found.", clearSnapshot: true)
        } catch {
            runtime.setError("Could not fetch Gemini usage. Will retry.", clearSnapshot: false)
        }
    }

    /// 拉一次完整流程：loadCodeAssist → retrieveUserQuota → 写 runtime + 记历史样本。
    /// 任一步抛 `GeminiUsageError` 由调用方决定语义（401 触发 refresh 重试，其它走通用错误文案）。
    private func fetchAndPublish(credentials: GeminiCredentials) async throws {
        let info = try await GeminiUsageClient.loadCodeAssist(credentials: credentials, session: session)
        let response = try await GeminiUsageClient.retrieveUserQuota(
            credentials: credentials, projectId: info.projectId, session: session)
        var snapshot = response.asProviderSnapshot()
        if let tier = info.tier { snapshot.planLabel = tier.capitalized }
        runtime.setSuccess(snapshot: snapshot)
        recordHistorySample(from: snapshot)
    }

    /// 把一次成功拉取的 (Pro%, Flash%) 落进历史（pct5h ← Pro 主窗口、pct7d ← Flash 次窗口）。
    /// 换算 / 缺窗口语义统一在 `ProviderUsageSnapshot.historySample`。
    private func recordHistorySample(from snap: ProviderUsageSnapshot) {
        guard let s = snap.historySample else { return }
        history.recordDataPoint(pct5h: s.pct5h, pct7d: s.pct7d)
    }
}
