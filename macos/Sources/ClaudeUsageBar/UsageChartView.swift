import SwiftUI
import Charts

struct UsageChartInterpolatedValues {
    let date: Date
    let pct5h: Double
    let pct7d: Double
}

enum UsageChartInterpolation {
    static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    static func interpolateValues(at date: Date, in points: [UsageDataPoint]) -> UsageChartInterpolatedValues? {
        guard points.count >= 2 else { return nil }

        let sorted = points.sorted { $0.timestamp < $1.timestamp }

        if date < sorted.first!.timestamp || date > sorted.last!.timestamp {
            return UsageChartInterpolatedValues(date: date, pct5h: 0, pct7d: 0)
        }

        for i in 0..<(sorted.count - 1) {
            if date >= sorted[i].timestamp && date <= sorted[i + 1].timestamp {
                let span = sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp)
                let t = span > 0 ? date.timeIntervalSince(sorted[i].timestamp) / span : 0

                let i0 = max(0, i - 1)
                let i3 = min(sorted.count - 1, i + 2)

                let pct5h = catmullRom(
                    sorted[i0].pct5h, sorted[i].pct5h,
                    sorted[i + 1].pct5h, sorted[i3].pct5h, t: t
                )
                let pct7d = catmullRom(
                    sorted[i0].pct7d, sorted[i].pct7d,
                    sorted[i + 1].pct7d, sorted[i3].pct7d, t: t
                )

                return UsageChartInterpolatedValues(
                    date: date,
                    pct5h: clampToUnitInterval(pct5h),
                    pct7d: clampToUnitInterval(pct7d)
                )
            }
        }

        return nil
    }

    private static func clampToUnitInterval(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - Pace area

struct PacePoint: Identifiable {
    let id = UUID()
    let date: Date
    let pct: Double   // 0...100
}

/// pace 面积序列：在 [domainStart, domainEnd] 上等距采样 sampleCount+1 个点，
/// 每点求其所在 windowDuration 窗口内 elapsed 比例 ×100。窗口序列由当前 `reset`
/// 按 windowDuration 步长向过去回推（Claude 5h 窗口非固定网格、无历史 reset 记录，
/// 回推是可接受近似 —— pace 面积只作参考线，不要求精确历史窗口对齐）。
enum UsagePaceArea {
    static func series(reset: Date?,
                       windowDuration: TimeInterval,
                       domainStart: Date,
                       domainEnd: Date,
                       sampleCount: Int = 240) -> [PacePoint] {
        guard let reset, windowDuration > 0, sampleCount > 0, domainEnd > domainStart else { return [] }
        let span = domainEnd.timeIntervalSince(domainStart)
        var out: [PacePoint] = []
        out.reserveCapacity(sampleCount + 1)
        for i in 0...sampleCount {
            let t = domainStart.addingTimeInterval(span * Double(i) / Double(sampleCount))
            let kRaw = floor(reset.timeIntervalSince(t) / windowDuration)
            let k = max(0.0, kRaw)
            let windowStart = reset.addingTimeInterval(-windowDuration * (k + 1))
            let frac = t.timeIntervalSince(windowStart) / windowDuration
            let clamped = min(max(frac, 0), 1)
            out.append(PacePoint(date: t, pct: clamped * 100))
        }
        return out
    }
}

// MARK: - UsageChartSectionView
// 趋势图 + 跟随 picker 时间窗口的估算费用卡（Change A/B）

struct UsageChartSectionView: View {
    @ObservedObject var historyService: UsageHistoryService
    let recentEvents: [StoredUsageEvent]
    var fiveHourResetDate: Date? = nil
    var sevenDayResetDate: Date? = nil

    @State private var selectedRange: TimeRange = .day1

    /// 根据当前选定时间范围，从 recentEvents 中计算 CostSummary。
    private var costSummary: CostSummary? {
        let cutoff = Date().addingTimeInterval(-selectedRange.interval)
        let summary = UsageAggregator.costForEvents(recentEvents, since: cutoff, now: Date())
        return summary.scannedFileCount > 0 ? summary : nil
    }

    private var periodLabel: String {
        switch selectedRange {
        case .hour1: return "1 小时"
        case .hour6: return "6 小时"
        case .day1:  return "1 天"
        case .day7:  return "7 天"
        case .day30: return "30 天"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            UsageChartContentView(historyService: historyService,
                                  selectedRange: selectedRange,
                                  fiveHourResetDate: fiveHourResetDate,
                                  sevenDayResetDate: sevenDayResetDate)

            if let cost = costSummary {
                LocalCostCard(summary: cost, periodLabel: periodLabel)
            }
        }
    }
}

/// 拆出原 UsageChartView 的内容部分，接受外部 selectedRange 而非自持状态。
private struct UsageChartContentView: View {
    @ObservedObject var historyService: UsageHistoryService
    let selectedRange: TimeRange
    var fiveHourResetDate: Date? = nil
    var sevenDayResetDate: Date? = nil
    @State private var hoverDate: Date?

    var body: some View {
        let points = historyService.downsampledPoints(for: selectedRange)
        if points.isEmpty {
            Text("No history data yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        } else {
            chartView(points: points)
        }
    }

    @ViewBuilder
    private func chartView(points: [UsageDataPoint]) -> some View {
        let now = Date()
        let domainStart = now.addingTimeInterval(-selectedRange.interval)
        let pace5h = UsagePaceArea.series(reset: fiveHourResetDate, windowDuration: 5 * 3600,
                                          domainStart: domainStart, domainEnd: now)
        let pace7d = UsagePaceArea.series(reset: sevenDayResetDate, windowDuration: 7 * 24 * 3600,
                                          domainStart: domainStart, domainEnd: now)
        let interpolated = hoverDate.flatMap {
            UsageChartInterpolation.interpolateValues(at: $0, in: points)
        }

        Chart {
            // pace 面积（先画 = 在底层；不进图例 —— 用直接 foregroundStyle(Color) 而非 by:）
            ForEach(pace7d) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Pace 7d", p.pct))
            }
            .foregroundStyle(Color.orange.opacity(0.08))
            .interpolationMethod(.linear)

            ForEach(pace5h) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Pace 5h", p.pct))
            }
            .foregroundStyle(Color.blue.opacity(0.10))
            .interpolationMethod(.linear)

            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.pct5h * 100)
                )
                .foregroundStyle(by: .value("Window", "5h"))
                .interpolationMethod(.catmullRom)
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", point.pct7d * 100)
                )
                .foregroundStyle(by: .value("Window", "7d"))
                .interpolationMethod(.catmullRom)
            }

            if let iv = interpolated {
                RuleMark(x: .value("Selected", iv.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                PointMark(
                    x: .value("Time", iv.date),
                    y: .value("Usage", iv.pct5h * 100)
                )
                .foregroundStyle(.blue)
                .symbolSize(24)

                PointMark(
                    x: .value("Time", iv.date),
                    y: .value("Usage", iv.pct7d * 100)
                )
                .foregroundStyle(.orange)
                .symbolSize(24)
            }
        }
        .chartXScale(domain: domainStart...now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%")
                            .font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel(format: xAxisFormat)
                    .font(.caption2)
                AxisGridLine()
            }
        }
        .chartForegroundStyleScale([
            "5h": Color.blue,
            "7d": Color.orange
        ])
        .chartLegend(.visible)
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plotOrigin = geo[proxy.plotFrame!].origin
                            let x = location.x - plotOrigin.x
                            if let date: Date = proxy.value(atX: x) {
                                hoverDate = date
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .overlay(alignment: .top) {
            if let iv = interpolated {
                tooltipView(date: iv.date, pct5h: iv.pct5h, pct7d: iv.pct7d)
            }
        }
        .frame(height: 120)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func tooltipView(date: Date, pct5h: Double, pct7d: Double) -> some View {
        VStack(spacing: 2) {
            Text(date, format: tooltipDateFormat)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Label("\(Int(round(pct5h * 100)))%", systemImage: "circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)
                Label("\(Int(round(pct7d * 100)))%", systemImage: "circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Formatting

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1:
            return .dateTime.hour().minute()
        case .hour6, .day1:
            return .dateTime.hour()
        case .day7:
            return .dateTime.weekday(.abbreviated)
        case .day30:
            return .dateTime.day().month(.abbreviated)
        }
    }

    private var tooltipDateFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1, .hour6, .day1:
            return .dateTime.hour().minute()
        case .day7:
            return .dateTime.weekday(.abbreviated).hour().minute()
        case .day30:
            return .dateTime.month(.abbreviated).day().hour()
        }
    }
}
