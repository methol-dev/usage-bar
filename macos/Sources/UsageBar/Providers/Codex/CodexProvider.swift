import Foundation

/// Codex provider —— 复用本机 `codex` CLI 已登录的 ChatGPT 凭证（`~/.codex/auth.json`，**只读**）
/// 拉 `chatgpt.com/backend-api/wham/usage`。无通知 / 多账号（范围收敛，见 spec）。
/// 不主动刷新 / 不写回 auth.json：401/403 → 提示用户跑 `codex`。
/// v0.2.8：自持一个 `UsageHistoryService`（`history-codex.json`），每次成功拉取记一个 `(session%, weekly%)` 历史点。
/// v0.2.10：后台轮询不再自持 timer —— 由 `ProviderCoordinator` 统管（用同一个 `pollingMinutes` 间隔，见 `pollIntervalSeconds`）。
@MainActor
final class CodexProvider: UsageProvider {
    let id: ProviderID = .codex
    let runtime = ProviderRuntime()

    /// 本 provider 的历史样本（与 Claude 的 `history.json` 同结构，不同文件 `history-codex.json`）。
    let history: UsageHistoryService

    var isConfigured: Bool { runtime.isConfigured }

    private let environment: [String: String]
    private let session: URLSession
    private let defaults: UserDefaults

    /// 后台轮询间隔 —— 跟随 `UsageService` 那个 `pollingMinutes` key（非法值 → `defaultPollingMinutes`，即 30min）。
    /// 注：实际的后台 timer 由 `ProviderCoordinator` 持（它用同一 key、同一算法 → 两者天然一致）；这里暴露这个属性供单测断言。
    var pollIntervalSeconds: TimeInterval {
        let stored = defaults.integer(forKey: "pollingMinutes")
        let mins = UsageService.pollingOptions.contains(stored) ? stored : UsageService.defaultPollingMinutes
        return TimeInterval(mins * 60)
    }

    /// 重入闸门：`refreshNow()` 同一时刻只跑一份（后台 timer / Refresh 按钮 / popover 打开可能撞上）。
    /// `@MainActor` 序列化读写 —— 第二个调用在第一个的网络 `await` 期间进来会命中此 guard 直接 return。
    private var isRefreshing = false

    /// 后台 tick 时额外回调（`ProviderCoordinator` 用它驱动 `codexStats.refresh()` —— 即 Codex 本机 session 扫描走同一节奏）。
    var onPollTick: (@MainActor () -> Void)? = nil

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         session: URLSession = .shared,
         history: UsageHistoryService? = nil,
         defaults: UserDefaults = .standard) {
        self.environment = environment
        self.session = session
        self.defaults = defaults
        // 默认值不能写在参数上（`UsageHistoryService` 是 @MainActor，默认参数会在 nonisolated 上下文求值）——
        // 在 @MainActor 的 init 里现造。
        let history = history ?? UsageHistoryService(filename: "history-codex.json")
        self.history = history
        // 轻量同步探测：auth.json 在不在 —— 让 tab 一打开就显示对的「未配置 / 待拉取」态（不发网络）。
        // `load` 返回 CodexCredentials?，`try?` 再包一层 → CodexCredentials??；`?? nil` 拍平后判 != nil。
        let present = ((try? CodexCredentialStore.load(environment: environment)) ?? nil) != nil
        runtime.setConfigured(present)
        history.loadHistory()
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let creds: CodexCredentials?
        do {
            creds = try CodexCredentialStore.load(environment: environment)
        } catch {
            runtime.setConfigured(false)
            runtime.setError("Codex not signed in. Run `codex` to sign in.", clearSnapshot: true)
            return
        }
        guard let creds else {
            runtime.setConfigured(false)
            runtime.clear()
            return
        }
        runtime.setConfigured(true)
        do {
            let response = try await CodexUsageClient.fetchUsage(credentials: creds, session: session)
            let snapshot = response.asProviderSnapshot()
            runtime.setSuccess(snapshot: snapshot)
            // (session%, weekly%) 落进历史:pct5h↔session、pct7d↔weekly(换算见 HistoryRecording.record)。
            history.record(snapshot)
        } catch CodexUsageError.unauthorized {
            runtime.setError("Codex credentials expired. Run `codex` to sign in again.", clearSnapshot: true)
        } catch {
            runtime.setError("Could not fetch Codex usage. Will retry.", clearSnapshot: false)
        }
    }
}
