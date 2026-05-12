import Foundation

/// 「活体用量数据源」契约 —— 一个 provider（Claude / Codex / …）一个实现。
///
/// 协议**只管「拉一次用量并把结果写进自己的 `runtime`」**；凭证管理 / 登录流程是各 provider 的
/// 内部细节（Claude 有 OAuth+refresh+多账号那一大套，Codex 只读 `~/.codex/auth.json`），不进协议。
/// v0.2.10：非-Claude provider 的后台轮询 timer 由 `ProviderCoordinator` 统管（`startBackgroundPolling()` / `onBackgroundTick()`，
/// 用同一个 `pollingMinutes` 间隔）；Claude 的后台 timer + 429 backoff 仍归 `UsageService` 自己（`claude.startPolling()`）。
@MainActor
protocol UsageProvider: AnyObject {
    var id: ProviderID { get }
    /// 该 provider 当前能否取数（Claude = 已登录；Codex = `~/.codex/auth.json` 存在且可解析）。
    var isConfigured: Bool { get }
    /// TODO(后续): 这个 flag 自 v0.2.10 起没有消费者了 —— 原先用作「菜单栏 primary 候选资格」，但 v0.2.10 退役了 `primaryEligibleIDs`
    /// （菜单栏已 provider-aware，任何 enabled+registered 的 provider 都能上菜单栏）。要么彻底从协议退役、要么改用途。
    /// 暂留（Claude = true、Codex = false）以免协议改动波及面太大。
    var supportsBackgroundPolling: Bool { get }
    /// 该 provider 的 UI 状态容器；实现负责在 `refreshNow()` 等处写它。
    var runtime: ProviderRuntime { get }
    /// 拉一次用量，把结果（或错误）写进 `runtime`。**永不抛**——异常进 `runtime.lastError`。
    func refreshNow() async
}

extension UsageProvider {
    var displayName: String { id.displayName }
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
