import Foundation

/// 「活体用量数据源」契约 —— 一个 provider（Claude / Codex / …）一个实现。
///
/// 协议**只管「拉一次用量并把结果写进自己的 `runtime`」**；凭证管理 / 登录流程是各 provider 的
/// 内部细节（Claude 有 OAuth+refresh+多账号那一大套，Codex 只读 `~/.codex/auth.json`），不进协议。
/// 后台轮询的 timer 也由实现自己持有（`supportsBackgroundPolling == true` 的 provider 在装配处自行
/// `startPolling()`）—— `ProviderCoordinator` 本身不跑 timer。
@MainActor
protocol UsageProvider: AnyObject {
    var id: ProviderID { get }
    /// 该 provider 当前能否取数（Claude = 已登录；Codex = `~/.codex/auth.json` 存在且可解析）。
    var isConfigured: Bool { get }
    /// 是否有自己的后台轮询（Claude = true；Codex 第一版 = false，靠切 tab / Refresh 按需拉）。
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
