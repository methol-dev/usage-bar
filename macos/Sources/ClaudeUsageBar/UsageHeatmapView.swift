import SwiftUI

/// 纯数据：把 [DaySpend] 折成 53 周 × 7 天的网格 + 每格 USD→0...8 档映射。
struct UsageHeatmapModel {
    struct Cell: Equatable {
        let dayKey: String?      // nil = 网格里超出范围的占位格
        let date: Date?
        let usd: Double
        let calls: Int
        let bucket: Int          // 0...8
    }
    /// weeks[w][d]：w = 第 w 列（最旧→最新），d = 0(周日)...6(周六)。共 53 列。
    let weeks: [[Cell]]
    let isEmpty: Bool
    private let byDayKey: [String: Cell]

    func cell(forDayKey key: String) -> Cell? { byDayKey[key] }

    init(daySpends: [DaySpend], referenceDate: Date = Date()) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        cal.firstWeekday = 1   // 固定周日为每周第一天（GitHub 贡献图惯例），不随 locale 变
        let dayFmt = DateFormatter(); dayFmt.calendar = cal; dayFmt.timeZone = TimeZone.current
        dayFmt.locale = Locale(identifier: "en_US_POSIX"); dayFmt.dateFormat = "yyyy-MM-dd"

        let spendByKey = Dictionary(uniqueKeysWithValues: daySpends.map { ($0.dayKey, $0) })
        let nonZero = daySpends.filter { $0.usd > 0 }.map { $0.usd }.sorted()
        self.isEmpty = nonZero.isEmpty

        // 分位数动态分档：8 个非零档（0 档专留 usd==0）。阈值 = nonZero 的 1/8...7/8 分位。
        func bucket(for usd: Double) -> Int {
            if usd <= 0 || nonZero.isEmpty { return 0 }
            if nonZero.count == 1 { return 4 }
            func quantile(_ q: Double) -> Double {
                let pos = q * Double(nonZero.count - 1)
                let lo = Int(pos.rounded(.down)), hi = min(lo + 1, nonZero.count - 1)
                let frac = pos - Double(lo)
                return nonZero[lo] * (1 - frac) + nonZero[hi] * frac
            }
            let thresholds = (1...7).map { quantile(Double($0) / 8.0) }
            var b = 1
            for t in thresholds where usd > t { b += 1 }
            return min(b, 8)
        }

        // 网格末列 = 包含 referenceDate 的那一周；往前推 52 周 = 53 列。每列从周日开始。
        let startOfRefWeek = cal.dateInterval(of: .weekOfYear, for: referenceDate)?.start ?? referenceDate
        var cols: [[Cell]] = []
        var byKey: [String: Cell] = [:]
        for colBack in stride(from: 52, through: 0, by: -1) {
            guard let weekStart = cal.date(byAdding: .weekOfYear, value: -colBack, to: startOfRefWeek) else { continue }
            var col: [Cell] = []
            for d in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: d, to: weekStart) else { col.append(Cell(dayKey: nil, date: nil, usd: 0, calls: 0, bucket: 0)); continue }
                if date > referenceDate { col.append(Cell(dayKey: nil, date: nil, usd: 0, calls: 0, bucket: 0)); continue }
                let key = dayFmt.string(from: date)
                let sp = spendByKey[key]
                let cell = Cell(dayKey: key, date: date, usd: sp?.usd ?? 0, calls: sp?.calls ?? 0, bucket: bucket(for: sp?.usd ?? 0))
                col.append(cell); byKey[key] = cell
            }
            cols.append(col)
        }
        self.weeks = cols
        self.byDayKey = byKey
    }
}

struct UsageHeatmapView: View {
    let daySpends: [DaySpend]
    let isInitializing: Bool

    private var model: UsageHeatmapModel { UsageHeatmapModel(daySpends: daySpends) }

    private func color(for bucket: Int) -> Color {
        if bucket == 0 { return Color.secondary.opacity(0.12) }
        return Color.green.opacity(0.18 + Double(bucket) * 0.10)   // 0.28 ... 0.98
    }
    private func tooltip(_ c: UsageHeatmapModel.Cell) -> String {
        guard let key = c.dayKey else { return "" }
        return "\(key) · ≈ \(ExtraUsage.formatUSD(c.usd)) · \(c.calls) calls"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("消费热力图（近一年）").font(.caption).foregroundStyle(.secondary)
            if isInitializing {
                HStack { ProgressView().controlSize(.small); Text("统计中…").font(.caption2).foregroundStyle(.secondary) }
            } else {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(Array(model.weeks.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: 2) {
                            ForEach(Array(col.enumerated()), id: \.offset) { _, cell in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color(for: cell.bucket))
                                    .frame(width: 9, height: 9)
                                    .help(tooltip(cell))
                                    .accessibilityLabel(cell.dayKey.map { "\($0)，约 \(ExtraUsage.formatUSD(cell.usd))" } ?? "")
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
