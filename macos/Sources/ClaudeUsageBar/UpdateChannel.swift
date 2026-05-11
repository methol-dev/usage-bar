import Foundation

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    static let storageKey = "updateChannel"
    static let defaultChannel: UpdateChannel = .stable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: return "稳定版"
        case .beta: return "Beta（实验性）"
        }
    }

    /// 读 UserDefaults 当前 channel；nil / 非法 rawValue fallback 到 default
    static func current(defaults: UserDefaults = .standard) -> UpdateChannel {
        guard let raw = defaults.string(forKey: storageKey),
              let channel = UpdateChannel(rawValue: raw) else {
            return defaultChannel
        }
        return channel
    }

    /// allowedChannels 语义：beta 用户也能收 stable 更新（不会"卡在 beta"）
    static func allowedChannelStrings(for channel: UpdateChannel) -> Set<String> {
        switch channel {
        case .stable: return ["stable"]
        case .beta: return ["stable", "beta"]
        }
    }
}
