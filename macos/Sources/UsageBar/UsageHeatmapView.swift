import SwiftUI

/// 纯数据：把 [DaySpend] 折成 53 周 × 7 天的网格 + 每格 USD→0...8 档映射。
struct UsageHeatmapModel {
    struct Cell: Equatable {
        let dayKey: String?      // nil = 网格里超出范围的占位格
        let date: Date?
        let usd: Double
        let calls: Int
        let tokens: Int
        let bucket: Int          // 0...8
    }
    /// weeks[w][d]：w = 第 w 列（最旧→最新），d = 0(周日)...6(周六)。共 53 列。
    let weeks: [[Cell]]
    let isEmpty: Bool
    private let byDayKey: [String: Cell]

    func cell(forDayKey key: String) -> Cell? { byDayKey[key] }

    /// 最新一天（= 当前列里最后一个非占位格 = 今天）。用作 hover 信息行的默认显示。
    var todayCell: Cell? { weeks.last?.last(where: { $0.dayKey != nil }) }

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

        // 网格范围：从最早 daySpend 所在周起，到 referenceDate 所在周止。
        // 若无数据则退化为单列（当周）。
        let startOfRefWeek = cal.dateInterval(of: .weekOfYear, for: referenceDate)?.start ?? referenceDate
        let earliestDate = daySpends.min(by: { $0.date < $1.date })?.date ?? referenceDate
        let startOfEarliestWeek = cal.dateInterval(of: .weekOfYear, for: earliestDate)?.start ?? startOfRefWeek

        // 计算列数（从最早那周到当前周，含两端）
        let weeksBetween = cal.dateComponents([.weekOfYear], from: startOfEarliestWeek, to: startOfRefWeek).weekOfYear ?? 0
        let totalCols = max(1, weeksBetween + 1)

        var cols: [[Cell]] = []
        var byKey: [String: Cell] = [:]
        for colBack in stride(from: totalCols - 1, through: 0, by: -1) {
            guard let weekStart = cal.date(byAdding: .weekOfYear, value: -colBack, to: startOfRefWeek) else { continue }
            var col: [Cell] = []
            for d in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: d, to: weekStart) else { col.append(Cell(dayKey: nil, date: nil, usd: 0, calls: 0, tokens: 0, bucket: 0)); continue }
                if date > referenceDate { col.append(Cell(dayKey: nil, date: nil, usd: 0, calls: 0, tokens: 0, bucket: 0)); continue }
                let key = dayFmt.string(from: date)
                let sp = spendByKey[key]
                let cell = Cell(dayKey: key, date: date, usd: sp?.usd ?? 0, calls: sp?.calls ?? 0, tokens: sp?.tokens ?? 0, bucket: bucket(for: sp?.usd ?? 0))
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

    @State private var hovered: UsageHeatmapModel.Cell?
    @State private var model: UsageHeatmapModel

    init(daySpends: [DaySpend], isInitializing: Bool) {
        self.daySpends = daySpends
        self.isInitializing = isInitializing
        _model = State(initialValue: UsageHeatmapModel(daySpends: daySpends))
    }

    private func color(for bucket: Int) -> Color {
        if bucket == 0 { return Color.secondary.opacity(0.15) }
        return Color.green.opacity(0.30 + Double(bucket) * 0.085)  // 0.385 ... 0.98
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isInitializing {
                HStack { ProgressView().controlSize(.small); Text("统计中…").font(.caption2).foregroundStyle(.secondary) }
            } else {
                let m = model
                let lastIndex = m.weeks.count - 1
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 2) {
                            ForEach(Array(m.weeks.enumerated()), id: \.offset) { idx, col in
                                VStack(spacing: 2) {
                                    ForEach(Array(col.enumerated()), id: \.offset) { _, cell in
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(color(for: cell.bucket))
                                            .frame(width: 9, height: 9)
                                            .accessibilityLabel(cell.dayKey.map { "\($0)，约 \(ExtraUsage.formatUSDCompact(cell.usd))" } ?? "")
                                            .onHover { isHovering in
                                                if isHovering {
                                                    hovered = cell
                                                } else if hovered == cell {
                                                    hovered = nil
                                                }
                                            }
                                    }
                                }
                                .id(idx)
                            }
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async {
                            withAnimation(.none) { proxy.scrollTo(lastIndex, anchor: .trailing) }
                        }
                    }
                }
                // 信息行：默认显示今天，hover 时显示悬停那天（固定高度避免布局跳动）
                Group {
                    if let cell = hovered ?? m.todayCell, let key = cell.dayKey {
                        HStack(spacing: 6) {
                            Text(key)
                            UsageMetricBadges(usd: cell.usd, calls: cell.calls, tokens: cell.tokens)
                        }
                    } else {
                        Color.clear
                    }
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: daySpends) { _, newValue in
            model = UsageHeatmapModel(daySpends: newValue)
            hovered = nil   // 避免悬空：旧 model 的 cell 不在新 model 里
        }
    }
}
