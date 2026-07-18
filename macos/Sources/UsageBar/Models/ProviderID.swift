import Foundation

/// 规范化的 provider 标识 —— 统一了原先分裂的两个枚举：popover UI tab 的 `ProviderTab`，
/// 与存储层用作 `data/<provider>/` 目录名的旧 `UsageProvider`（`UsageStoreTypes.swift`）。
///
/// `rawValue` 同时用作磁盘目录名 —— `ProviderID.claude.rawValue == "claude"`，与既有
/// `~/.config/usage-bar/data/claude/` 目录兼容，重命名零迁移成本。
///
/// 「某个 provider 当前是否可用」不在本枚举里 —— v0.2.5 重构后由 `ProviderRegistry`
/// 是否注册了对应 `UsageProvider` 决定（见 spec `2026-05-12-multi-provider-refactor`）。
enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case cursor
    case copilot
    case gemini
    /// Claude 订阅网页用量源（Chrome 扩展 + Native Messaging）。rawValue 带连字符 →
    /// 磁盘目录 `claude-web`（本 provider 无本地 JSONL，不实际建目录，仅取名一致）。
    case claudeWeb = "claude-web"

    var id: String { rawValue }

    /// "claude" → "Claude"；`.capitalized` 对连字符/驼峰不友好，个别 case 显式给名。
    var displayName: String {
        switch self {
        case .claudeWeb: return "Claude Web"
        default:         return rawValue.capitalized
        }
    }
}
