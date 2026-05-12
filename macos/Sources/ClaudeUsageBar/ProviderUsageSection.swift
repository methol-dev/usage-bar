import SwiftUI

/// popover 里「某 provider 用量数据卡片」的统一区块（provider 无关）：套餐徽章 + 主/次窗口卡（含 pace）
/// + per-model 行 + 按量计费行。
///
/// 不含：历史折线图 / 消费热力图 / 该 provider 的错误卡 / "Updated X ago" / 底部按钮栏 ——
/// 那些由调用方（`PopoverView`）按需组合（折线图/热力图目前还是 Claude 专属，依赖未泛化的
/// `UsageHistoryService` / `UsageStatsService`）。
struct ProviderUsageSection: View {
    @ObservedObject var runtime: ProviderRuntime
    /// 主/次窗口的趋势箭头（Claude tab 由 `PopoverView` 从历史算好传入；无历史的 provider 传 nil）。
    var trendPrimary: TrendIndicator? = nil
    var trendSecondary: TrendIndicator? = nil

    var body: some View {
        let snap = runtime.snapshot

        if let plan = snap?.planLabel, !plan.isEmpty {
            UsageCard {
                HStack {
                    Text("Plan").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(plan).font(.subheadline.weight(.medium))
                }
            }
        }

        // 卡片在「还没拉到数据」（snap == nil → 骨架）或「这个窗口确实存在」时才渲染；
        // 已有 snapshot 但某个窗口为 nil（如 Codex Free 计划只返回 weekly、没有 session 窗口）→ 不渲染那张空卡。
        if snap == nil || snap?.primaryWindow != nil {
            UsageCard {
                UsageHeroCard(
                    label: snap?.primaryWindow?.label ?? "Session",
                    window: snap?.primaryWindow,
                    trend: trendPrimary,
                    pacePct: expectedPacePct(resetDate: snap?.primaryWindow?.resetsAt,
                                             windowDuration: snap?.primaryWindow?.windowDuration ?? 5 * 60 * 60),
                    icon: "clock"
                )
            }
        }

        if snap == nil || snap?.secondaryWindow != nil {
            UsageCard {
                UsageHeroCard(
                    label: snap?.secondaryWindow?.label ?? "Weekly",
                    window: snap?.secondaryWindow,
                    trend: trendSecondary,
                    pacePct: expectedPacePct(resetDate: snap?.secondaryWindow?.resetsAt,
                                             windowDuration: snap?.secondaryWindow?.windowDuration ?? 7 * 24 * 60 * 60),
                    icon: "calendar"
                )
            }
        }

        if let extras = snap?.extraWindows, !extras.isEmpty {
            UsageCard {
                Text("Per-Model (7 day)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(extras) { named in
                    UsageWindowRow(label: named.title, window: named.window)
                }
            }
        }

        if let credit = snap?.creditLine, credit.isEnabled {
            UsageCard { CreditLineRow(credit: credit) }
        }
    }
}

/// per-model（Opus / Sonnet 等）用量行 —— 取代旧 `PopoverView` 私有的 `UsageBucketRow`。
struct UsageWindowRow: View {
    let label: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(percentageText).font(.subheadline).monospacedDigit()
            }
            ProgressView(value: (window.utilizationPct ?? 0) / 100.0, total: 1.0)
                .tint(colorForPct((window.utilizationPct ?? 0) / 100.0))
            if let resetDate = window.resetsAt {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var percentageText: String {
        guard let pct = window.utilizationPct else { return "—" }
        return "\(Int(round(pct)))%"
    }
}

/// 按量计费 / 额外用量行 —— 取代旧 `PopoverView` 私有的 `ExtraUsageRow`。
/// 同时承载 Claude `extra_usage`（已用/上限 + 进度条）与 Codex `credits`（剩余余额 / Unlimited）。
struct CreditLineRow: View {
    let credit: CreditLine

    /// 用到了 Codex 语义字段（余额/无限）→ 标题叫 "Credits"；否则 Claude 的 "Extra Usage"。
    private var title: String {
        (credit.remainingAmount != nil || credit.isUnlimited) ? "Credits" : "Extra Usage"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            if credit.isUnlimited {
                Text("Unlimited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let remaining = credit.remainingAmount {
                Text("\(ExtraUsage.formatUSD(remaining)) remaining")
                    .font(.caption)
                    .monospacedDigit()
            } else if let used = credit.usedAmount, let limit = credit.limitAmount {
                HStack {
                    Text("\(ExtraUsage.formatUSD(used)) / \(ExtraUsage.formatUSD(limit))")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    if let pct = credit.utilizationPct {
                        Text("\(Int(round(pct)))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: (credit.utilizationPct ?? 0) / 100.0, total: 1.0)
                    .tint(.blue)
            }
        }
    }
}
