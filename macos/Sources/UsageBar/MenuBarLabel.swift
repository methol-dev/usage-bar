import SwiftUI

/// 菜单栏 label —— 显示指定 provider runtime 的用量。
struct MenuBarLabel: View {
    @ObservedObject var runtime: ProviderRuntime
    var providerID: ProviderID
    @AppStorage(MenuBarDisplayMode.storageKey) private var mode: MenuBarDisplayMode = .icon

    var body: some View {
        switch mode {
        case .icon:
            iconView
        case .percent:
            Text(percentText).monospacedDigit()
        case .percentWithPace:
            HStack(spacing: 4) {
                Text(percentText).monospacedDigit()
                if let pace = paceText {
                    Text(pace)
                        .monospacedDigit()
                        .foregroundStyle(paceColor)
                }
            }
        }
    }

    private var primaryShort: String {
        let s = runtime.snapshot?.primaryWindow?.shortLabel ?? ""
        return s.isEmpty ? "5h" : s
    }
    private var secondaryShort: String {
        let s = runtime.snapshot?.secondaryWindow?.shortLabel ?? ""
        return s.isEmpty ? "7d" : s
    }

    @ViewBuilder
    private var iconView: some View {
        Image(nsImage: runtime.isConfigured
            ? renderIcon(providerID: providerID, primaryLabel: primaryShort, secondaryLabel: secondaryShort,
                         pct5h: primaryFraction, pct7d: secondaryFraction)
            : renderUnauthenticatedIcon(providerID: providerID, primaryLabel: primaryShort, secondaryLabel: secondaryShort))
    }

    private var primaryFraction: Double { (runtime.snapshot?.primaryWindow?.utilizationPct ?? 0) / 100.0 }
    private var secondaryFraction: Double { (runtime.snapshot?.secondaryWindow?.utilizationPct ?? 0) / 100.0 }

    private var percentText: String {
        guard runtime.isConfigured else {
            return formatMenuBarPercent(utilization: nil, prefix: primaryShort)
        }
        return formatMenuBarPercent(utilization: runtime.snapshot?.primaryWindow?.utilizationPct, prefix: primaryShort)
    }

    /// 当前用量相对 pace 的偏差（百分点整数）；nil = 无数据或偏差 < 1pp。
    private var paceDelta: Int? {
        guard runtime.isConfigured,
              let window = runtime.snapshot?.primaryWindow,
              let utilPct = window.utilizationPct,
              let duration = window.windowDuration,
              let expected = expectedPacePct(resetDate: window.resetsAt, windowDuration: duration)
        else { return nil }
        let delta = Int((utilPct - expected).rounded())
        return abs(delta) >= 1 ? delta : nil
    }

    private var paceText: String? {
        guard let delta = paceDelta else { return nil }
        return delta > 0 ? "+\(delta)%" : "\(delta)%"
    }

    private var paceColor: Color {
        guard let delta = paceDelta else { return .primary }
        return delta > 0 ? .red : .green
    }
}
