import Foundation

struct UsageDataPoint: Codable, Identifiable {
    let timestamp: Date
    let pct5h: Double
    let pct7d: Double

    /// 用 timestamp 做稳定身份：原先每次 init 造新 UUID，downsample 结果在每次
    /// 悬停/重渲染时全量换身份，Swift Charts 被迫销毁重建所有 mark。
    /// （解码旧 history 文件时多出的 "id" 字段会被忽略，兼容无损。）
    var id: Date { timestamp }

    init(timestamp: Date = Date(), pct5h: Double, pct7d: Double) {
        self.timestamp = timestamp
        self.pct5h = pct5h
        self.pct7d = pct7d
    }
}

struct UsageHistory: Codable {
    var dataPoints: [UsageDataPoint] = []
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour1 = "1h"
    case hour6 = "6h"
    case day1 = "1d"
    case day7 = "7d"
    case day30 = "30d"

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .hour1: return 3600
        case .hour6: return 6 * 3600
        case .day1: return 86400
        case .day7: return 7 * 86400
        case .day30: return 30 * 86400
        }
    }

    var targetPointCount: Int {
        switch self {
        case .hour1: return 120
        case .hour6: return 180
        case .day1: return 200
        case .day7: return 200
        case .day30: return 200
        }
    }
}
