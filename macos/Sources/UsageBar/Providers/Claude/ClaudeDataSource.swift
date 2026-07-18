import Foundation

/// Claude 的数据来源 —— 一个 Claude provider 下可有多个源,用户多选启用 + 排优先级(ADR 0010)。
/// - `.web`:Chrome 扩展在用户已登录 claude.ai 会话里取用量(`ClaudeWebProvider`)。
/// - `.cli`:打 api.anthropic.com/api/oauth/usage(`UsageService`)。
///
/// rawValue 用于 UserDefaults 持久化(`claude.enabledSources` / `claude.sourcePriority`)。
enum ClaudeDataSource: String, Codable, CaseIterable, Identifiable {
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
