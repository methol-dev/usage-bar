import Foundation

/// 一个多源 provider 的数据来源（ADR 0010 / 0012）—— Claude / Codex 等 provider 下可有多个源,
/// 用户多选启用 + 排优先级。
/// - `.web`：Chrome 扩展在用户已登录的浏览器会话里取用量（claude.ai / chatgpt.com）。
/// - `.cli`：直连官方接口（Claude `oauth/usage`、Codex `wham/usage`），token 来自本机 CLI 凭证。
///
/// rawValue 用于 UserDefaults 持久化（`<provider>.enabledSources` / `<provider>.sourcePriority`）。
enum UsageSource: String, Codable, CaseIterable, Identifiable {
    case web
    case cli

    var id: String { rawValue }

    /// Settings 数据源控件里显示的名字。
    var displayName: String {
        switch self {
        case .web: return "Web (extension)"
        case .cli: return "CLI (API)"
        }
    }
}
