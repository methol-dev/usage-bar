import Foundation

/// Codex（ChatGPT）订阅**网页**用量源（ADR 0012）。请求由用户已登录的 chatgpt.com 浏览器会话经
/// Chrome 扩展发出；app 本身不 fetch chatgpt.com、不碰 cookie / token —— 只读扩展经 Native Messaging
/// host 落盘的 `~/.config/usage-bar/codex-web.json`（见 `WebSourceStore`）。
///
/// 与 Codex CLI 源（`CodexProvider`，用本机 `~/.codex/auth.json` 打 chatgpt.com/backend-api/wham/usage）
/// 走同一端点，区别只在**谁发请求 / 凭证从哪来**：CLI 用磁盘上的 auth.json，Web 用浏览器登录会话。
/// read-only + 统一 timer + runtime，范式同 `ClaudeWebProvider`。
@MainActor
final class CodexWebProvider: UsageProvider {
    let id: ProviderID = .codexWeb
    let runtime = ProviderRuntime()
    var isConfigured: Bool { runtime.isConfigured }
    var onPollTick: (@MainActor () -> Void)?

    /// 数据新鲜度阈值：超过此时长未更新视为陈旧（扩展停了 / 浏览器关了）。
    static let stalenessThreshold: TimeInterval = 60 * 60

    private let loader: CodexWebLoading
    private let now: () -> Date
    private var isRefreshing = false

    init(loader: CodexWebLoading = CodexWebFileLoader(), now: @escaping () -> Date = { Date() }) {
        self.loader = loader
        self.now = now
        // 轻量同步探测:首屏就显示对的态(文件在不在 + 内容 status)。不发网络。
        apply(loader.load())
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        apply(loader.load())
    }

    /// 三态状态机（同 `ClaudeWebProvider`）：文件缺失 / logged_out|no_session / ok。
    /// 不能用「文件存在 → configured」——logged_out 也会写文件。
    private func apply(_ payload: CodexWebPayload?) {
        guard let payload else {
            runtime.setConfigured(false)
            runtime.clear()
            return
        }
        switch payload.status {
        case .loggedOut, .noSession:
            runtime.setConfigured(false)
            runtime.setError("Open chatgpt.com and sign in — the extension will sync automatically.",
                             clearSnapshot: true)
        case .error, .unknown:
            runtime.setError("Codex Web sync failed. Will retry.", clearSnapshot: false)
        case .ok:
            if let ts = payload.timestamp, now().timeIntervalSince(ts) > Self.stalenessThreshold {
                runtime.setError("Codex Web data is stale — is the extension still running?",
                                 clearSnapshot: false)
                return
            }
            runtime.setConfigured(true)
            let snapshot = CodexWebUsageMapper.snapshot(from: payload.usage) ?? ProviderUsageSnapshot()
            runtime.setSuccess(snapshot: snapshot, at: payload.timestamp ?? now())
        }
    }
}

/// provider 侧读取抽象 —— 单测注入内存 stub,避免依赖真实 `~/.config/`。
protocol CodexWebLoading {
    func load() -> CodexWebPayload?
}

struct CodexWebFileLoader: CodexWebLoading {
    func load() -> CodexWebPayload? {
        guard let data = WebSourceStore.readData(for: .codex) else { return nil }
        return CodexWebPayload.parse(data)
    }
}
