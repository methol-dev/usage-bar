import Foundation

/// Codex provider —— 复用本机 `codex` CLI 已登录的 ChatGPT 凭证（`~/.codex/auth.json`，**只读**）
/// 拉 `chatgpt.com/backend-api/wham/usage`。无后台轮询 / 通知 / 多账号（范围收敛，见 spec §2）。
/// 不主动刷新 / 不写回 auth.json：401/403 → 提示用户跑 `codex`。
@MainActor
final class CodexProvider: UsageProvider {
    let id: ProviderID = .codex
    let runtime = ProviderRuntime()
    let supportsBackgroundPolling = false
    var isConfigured: Bool { runtime.isConfigured }

    private let environment: [String: String]
    private let session: URLSession

    init(environment: [String: String] = ProcessInfo.processInfo.environment, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
        // 轻量同步探测：auth.json 在不在 —— 让 tab 一打开就显示对的「未配置 / 待拉取」态（不发网络）。
        // `load` 返回 CodexCredentials?，`try?` 再包一层 → CodexCredentials??；`?? nil` 拍平后判 != nil。
        let present = ((try? CodexCredentialStore.load(environment: environment)) ?? nil) != nil
        runtime.setConfigured(present)
    }

    func refreshNow() async {
        let creds: CodexCredentials?
        do {
            creds = try CodexCredentialStore.load(environment: environment)
        } catch {
            runtime.setConfigured(false)
            runtime.setError("未检测到有效的 Codex 凭证，请在终端运行 `codex` 登录", clearSnapshot: true)
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
            runtime.setSuccess(snapshot: response.asProviderSnapshot())
        } catch CodexUsageError.unauthorized {
            runtime.setError("Codex 凭证已过期，请在终端运行 `codex` 重新登录", clearSnapshot: true)
        } catch {
            runtime.setError("无法获取 Codex 用量（稍后重试）", clearSnapshot: false)
        }
    }
}
