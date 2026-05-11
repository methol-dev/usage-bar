import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    // @AppStorage 直接绑定 enum（SwiftUI 原生支持 RawRepresentable + RawValue == String）
    // G5 review B1 修订：消除 String<->enum 的中间 Binding(get:set:) 映射
    @AppStorage(MenuBarDisplayMode.storageKey) private var mode: MenuBarDisplayMode = .icon

    var body: some View {
        switch mode {
        case .icon:
            iconView
        case .percent:
            Text(percentText).monospacedDigit()
        case .percentWithTrend:
            HStack(spacing: 4) {
                Text(percentText).monospacedDigit()
                if let t = trend {
                    Text(trendText(t))
                        .monospacedDigit()
                        .foregroundStyle(t.direction == .up ? .red : .green)
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        Image(nsImage: service.isAuthenticated
            ? renderIcon(pct5h: service.pct5h, pct7d: service.pct7d)
            : renderUnauthenticatedIcon())
    }

    private var percentText: String {
        guard service.isAuthenticated else {
            return formatMenuBarPercent(utilization: nil, prefix: "5h")
        }
        return formatMenuBarPercent(utilization: service.usage?.fiveHour?.utilization, prefix: "5h")
    }

    private var trend: TrendIndicator? {
        guard service.isAuthenticated else { return nil }
        return computeTrend(
            currentPct: service.usage?.fiveHour?.utilization,
            points: historyService.history.dataPoints,
            metric: \.pct5h
        )
    }

    private func trendText(_ t: TrendIndicator) -> String {
        let arrow = t.direction == .up ? "▲" : "▼"
        return "\(arrow)\(t.deltaPct)"
    }
}
