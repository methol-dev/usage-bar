import Foundation

/// 「活体用量数据源」契约 —— 一个 provider（Claude / Codex / …）一个实现。
///
/// 协议**只管「拉一次用量并把结果写进自己的 `runtime`」**；凭证管理 / 登录流程是各 provider 的
/// 内部细节（Claude 有 OAuth+refresh+多账号那一大套，Codex 只读 `~/.codex/auth.json`），不进协议。
/// v0.2.11：**所有** provider 的后台轮询由 `ProviderCoordinator` 的统一 timer 管（`startBackgroundPolling()` / `onBackgroundTick()`，
/// 间隔 = `pollingMinutes`）；做 429 backoff 的 provider（= Claude）用只读 hint `nextEligibleRefresh` 表达「这个时刻之前别 tick 我」，
/// coordinator 每 tick 跳过还在 backoff 窗口里的 provider；`onPollTick` 让后台 tick 顺带驱动该 provider 的本机统计刷新。
@MainActor
protocol UsageProvider: AnyObject {
    var id: ProviderID { get }
    /// 该 provider 当前能否取数（Claude = 已登录；Codex = `~/.codex/auth.json` 存在且可解析）。
    var isConfigured: Bool { get }
    /// 该 provider 的 UI 状态容器；实现负责在 `refreshNow()` 等处写它。
    var runtime: ProviderRuntime { get }
    /// 后台 tick 时额外回调（驱动该 provider 的本机统计刷新；nil = 不做）。`ProviderCoordinator.onBackgroundTick()` 在调 `refreshNow()` 后调它。
    var onPollTick: (@MainActor () -> Void)? { get set }
    /// 「这个时刻之前别 tick 我」—— 给做指数 backoff 的 provider 用（默认 nil = 随时可 tick）。
    /// **必须是协议要求**（不能只放 extension）—— 否则经 `any UsageProvider` 调用会被静态派发到默认实现、绕过 conformer 的 override。
    var nextEligibleRefresh: Date? { get }
    /// 拉一次用量，把结果（或错误）写进 `runtime`。**永不抛**——异常进 `runtime.lastError`。
    func refreshNow() async
}

extension UsageProvider {
    var displayName: String { id.displayName }
    var nextEligibleRefresh: Date? { nil }   // 默认实现：不做 backoff 的 provider 用
}

// MARK: - 可测性用的窄协议（spy 注入）
//
// `UsageService.fetchUsage()` 在成功后会调 `recordDataPoint` 与 `checkAndNotify`（push 模型）。
// 把这两个调用对象窄化成协议，单测就能注入 spy 断言「重构后这两条调用路径没被吞掉」（spec SC5-c）。

@MainActor
protocol HistoryRecording: AnyObject {
    func recordDataPoint(pct5h: Double, pct7d: Double)
}

@MainActor
protocol UsageNotifying: AnyObject {
    func checkAndNotify(pct5h: Double, pct7d: Double, pctExtra: Double)
}
