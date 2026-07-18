import Foundation

/// Claude 订阅**网页**用量源。请求由用户已登录的 claude.ai 浏览器会话经 Chrome 扩展发出;
/// app 本身不 fetch claude.ai、不碰 cookie —— 只读扩展经 Native Messaging host 落盘的
/// `~/.config/usage-bar/claude-web.json`(见 `ClaudeWebStore`)。
///
/// 与 Claude CLI 源(`UsageService`,打 api.anthropic.com/api/oauth/usage)是**两个独立 provider /
/// 两个额度视图**,不是「Claude tab 内切来源」。read-only + 统一 timer + runtime,范式同 Codex。
@MainActor
final class ClaudeWebProvider: UsageProvider {
    let id: ProviderID = .claudeWeb
    let runtime = ProviderRuntime()
    var isConfigured: Bool { runtime.isConfigured }
    var onPollTick: (@MainActor () -> Void)?

    /// 数据新鲜度阈值:扩展默认每 15min 同步一次,超过此时长未更新视为陈旧(扩展停了 / 浏览器关了)。
    static let stalenessThreshold: TimeInterval = 60 * 60

    private let loader: ClaudeWebLoading
    private let now: () -> Date
    private var isRefreshing = false

    init(loader: ClaudeWebLoading = ClaudeWebFileLoader(), now: @escaping () -> Date = { Date() }) {
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

    /// 三态状态机(评审 S3):文件缺失 / logged_out|no_session / ok。
    /// 不能用「文件存在 → configured」——logged_out 也会写文件。
    private func apply(_ payload: ClaudeWebPayload?) {
        guard let payload else {
            // 扩展没装 / 没成功同步过 → 未配置(走整屏 ProviderUnconfiguredView + signInHint 引导)。
            runtime.setConfigured(false)
            runtime.clear()
            return
        }
        switch payload.status {
        case .loggedOut, .noSession:
            runtime.setConfigured(false)
            runtime.setError("Open claude.ai and sign in — the extension will sync automatically.",
                             clearSnapshot: true)
        case .error, .unknown:
            // 保留旧卡(若有),显示错误文案。
            runtime.setError("Claude Web sync failed. Will retry.", clearSnapshot: false)
        case .ok:
            if let ts = payload.timestamp, now().timeIntervalSince(ts) > Self.stalenessThreshold {
                runtime.setError("Claude Web data is stale — is the extension still running?",
                                 clearSnapshot: false)
                return
            }
            runtime.setConfigured(true)
            // 映射未定(Phase 0 pending)/ 无窗口 → 空快照(骨架态),不报错;已配置。
            let snapshot = ClaudeWebUsageMapper.snapshot(from: payload.usage) ?? ProviderUsageSnapshot()
            runtime.setSuccess(snapshot: snapshot, at: payload.timestamp ?? now())
        }
    }
}
