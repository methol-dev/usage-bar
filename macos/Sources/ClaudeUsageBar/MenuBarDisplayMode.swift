import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case icon
    case percent
    case percentWithTrend

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .icon: return "Icon"
        case .percent: return "Percent text"
        case .percentWithTrend: return "Percent + trend"
        }
    }

    static let storageKey = "menubarDisplayMode"
}

/// 把 utilization (0...100 百分制) 格式化为菜单栏百分比文本。
/// nil 显示 prefix + " —"（em-dash 占位，避免误读为 0%）。
func formatMenuBarPercent(utilization: Double?, prefix: String) -> String {
    guard let pct = utilization else { return "\(prefix) —" }
    return "\(prefix) \(Int(round(pct)))%"
}
