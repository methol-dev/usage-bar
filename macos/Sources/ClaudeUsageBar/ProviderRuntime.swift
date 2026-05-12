import Foundation

/// 一个 provider 的 UI 状态容器 —— 视图（popover 用量区 / 菜单栏 label）`@ObservedObject` 它。
/// 由所属 `UsageProvider` 写入（`setSuccess` / `setError` / `clear` / `setConfigured`）。
///
/// 错误时的 snapshot 取舍统一为：凭证类失败（401-ish / session 过期）`clearSnapshot: true`——
/// 不留「旧卡片 + 过期错误」并存的歧义 UI；网络 / 5xx 类失败保留旧 snapshot 但显示错误文案。
@MainActor
final class ProviderRuntime: ObservableObject {
    @Published private(set) var snapshot: ProviderUsageSnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isConfigured: Bool

    init(isConfigured: Bool = false) {
        self.isConfigured = isConfigured
    }

    func setConfigured(_ value: Bool) {
        if isConfigured != value { isConfigured = value }
    }

    /// 一次成功拉取：写 snapshot + 刷新 lastUpdated + 清 lastError。
    func setSuccess(snapshot: ProviderUsageSnapshot, at date: Date = Date()) {
        self.snapshot = snapshot
        self.lastUpdated = date
        self.lastError = nil
    }

    /// 一次失败：设 lastError；`clearSnapshot` 为 true 时清空旧 snapshot（凭证类失败），否则保留。
    func setError(_ message: String, clearSnapshot: Bool) {
        self.lastError = message
        if clearSnapshot { self.snapshot = nil }
    }

    /// 清空全部（登出 / 切账号 / session 失效等）。
    func clear() {
        self.snapshot = nil
        self.lastUpdated = nil
        self.lastError = nil
    }
}
