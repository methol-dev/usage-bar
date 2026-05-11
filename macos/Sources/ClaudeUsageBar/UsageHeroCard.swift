import SwiftUI

enum UsageCardSize {
    case hero       // 5h 主卡片，56pt 大字号
    case secondary  // 7d 次卡片，28pt 中字号
}

struct UsageHeroCard: View {
    let size: UsageCardSize
    let label: String
    let bucket: UsageBucket?
    var trend: TrendIndicator? = nil
    var pace: PaceState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(labelFont)
                    .foregroundStyle(.secondary)
                if let trend {
                    Text(trendText(for: trend))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(trend.direction == .up ? .red : .green)
                }
                Spacer()
                if let countdown {
                    Text(countdown)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(percentageText)
                    .font(.system(size: pctFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(pctColor)
                Spacer()
            }
            CapsuleProgressBar(value: pctValue, color: pctColor)
                .frame(height: 8)
            if let paceText {
                Text(paceText.text)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(paceText.color)
            }
        }
    }

    private var pctFontSize: CGFloat {
        switch size {
        case .hero: return 56
        case .secondary: return 28
        }
    }

    private var labelFont: Font {
        switch size {
        case .hero: return .subheadline
        case .secondary: return .caption
        }
    }

    private var pctValue: Double {
        (bucket?.utilization ?? 0) / 100.0
    }

    private var pctColor: Color {
        colorForPct(pctValue)
    }

    private var percentageText: String {
        guard let pct = bucket?.utilization else { return "—" }
        return "\(Int(round(pct)))%"
    }

    private var countdown: String? {
        guard let resetDate = bucket?.resetsAtDate else { return nil }
        return formatResetCountdown(date: resetDate, now: Date())
    }

    private func trendText(for t: TrendIndicator) -> String {
        let arrow = t.direction == .up ? "▲" : "▼"
        return "\(arrow) \(t.deltaPct)%"
    }

    private var paceText: (text: String, color: Color)? {
        guard let pace else { return nil }
        switch pace {
        case .onPace:
            return nil  // 默认状态不显示，避免打扰
        case .inDeficit(let percentOver, let runsOutIn):
            // 复用 v0.0.8 formatResetCountdown：把 runsOutIn 当作"距离 N 秒后耗尽"
            // edge case: runsOutIn=0（currentPct=100）→ formatResetCountdown(0) 返回 nil → "—"
            let countdown = formatResetCountdown(date: Date().addingTimeInterval(runsOutIn), now: Date()) ?? "—"
            return ("\(percentOver)% over pace · runs out in \(countdown)", .red)
        case .inReserve(let percentUnder):
            return ("\(percentUnder)% under pace", .green)
        }
    }
}

struct CapsuleProgressBar: View {
    let value: Double  // 期望 0...1，越界自动 clamp
    let color: Color

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.15))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, min(1, value)) * geo.size.width)
                }
            }
    }
}

#Preview("Hero card – trend + pace 三档") {
    VStack(alignment: .leading, spacing: 12) {
        UsageHeroCard(
            size: .hero,
            label: "5-Hour (in deficit)",
            bucket: UsageBucket(utilization: 70, resetsAt: "2099-01-01T00:00:00Z"),
            trend: TrendIndicator(direction: .up, deltaPct: 8),
            pace: .inDeficit(percentOver: 20, runsOutIn: 64 * 60)  // ~1h 4m
        )
        UsageHeroCard(
            size: .hero,
            label: "5-Hour (in reserve)",
            bucket: UsageBucket(utilization: 30, resetsAt: "2099-01-01T00:00:00Z"),
            trend: TrendIndicator(direction: .down, deltaPct: 5),
            pace: .inReserve(percentUnder: 20)
        )
        UsageHeroCard(
            size: .secondary,
            label: "7-Day (no pace)",
            bucket: UsageBucket(utilization: 73, resetsAt: "2099-01-08T00:00:00Z"),
            trend: TrendIndicator(direction: .up, deltaPct: 12),
            pace: nil  // 7d 不显示 pace
        )
        UsageHeroCard(
            size: .hero,
            label: "5-Hour (on pace, hidden)",
            bucket: UsageBucket(utilization: 50, resetsAt: "2099-01-01T00:00:00Z"),
            trend: nil,
            pace: .onPace  // .onPace 不显示 pace 行
        )
    }
    .padding()
    .frame(width: 360)
}
