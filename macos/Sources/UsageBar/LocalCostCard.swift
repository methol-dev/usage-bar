import SwiftUI

/// Three icon+value badges: $ amount · # calls · cube tokens.
/// Used both in the cost card total header AND the heatmap hover line.
struct UsageMetricBadges: View {
    let usd: Double
    let calls: Int
    let tokens: Int

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Image(systemName: "dollarsign.circle.fill")
                Text(ExtraUsage.formatUSDCompact(usd))
            }
            HStack(spacing: 2) {
                Image(systemName: "number")
                Text(ExtraUsage.formatTokens(calls))
            }
            HStack(spacing: 2) {
                Image(systemName: "cube.fill")
                Text(ExtraUsage.formatTokens(tokens))
            }
        }
        .imageScale(.small)
        .foregroundStyle(.secondary)
    }
}

struct LocalCostCard: View {
    let summary: CostSummary
    /// 把规范化模型名映成显示名 —— 默认 Claude（`ClaudePricing.displayName`）；Codex 传 `OpenAIPricing.displayName`。
    var displayName: (String) -> String = { ClaudePricing.displayName($0) }
    @State private var expanded = false

    private var totalCalls: Int { summary.perModel.reduce(0) { $0 + $1.calls } }
    private var totalTokens: Int {
        summary.perModel.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens
        }
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
            // ── Header + rows in one Grid (5 columns) ─────────────────────
            // col1: name/title (expands), col2: calls, col3: tokens, col4: amount, col5: chevron
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                // Header row (always shown)
                GridRow {
                    Text("Usage")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridColumnAlignment(.leading)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: "number").imageScale(.small)
                        Text(ExtraUsage.formatTokens(totalCalls))
                    }
                    .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: "cube.fill").imageScale(.small)
                        Text(ExtraUsage.formatTokens(totalTokens))
                    }
                    .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Image(systemName: "dollarsign.circle.fill").imageScale(.small)
                        Text(ExtraUsage.formatUSDCompact(summary.totalUSD))
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(.secondary)
                    // col5: chevron — always on header row, direction flips only
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)

                // Divider spanning all 5 columns (only when expanded)
                if expanded {
                    GridRow {
                        Divider()
                            .gridCellColumns(5)
                            .gridCellUnsizedAxes(.horizontal)
                            .padding(.vertical, 1)
                    }

                    // Per-model rows
                    ForEach(summary.perModel.sorted(by: { $0.usd > $1.usd }), id: \.normalizedModel) { row in
                        let rowTokens = row.inputTokens + row.outputTokens + row.cacheReadTokens + row.cacheCreationTokens
                        GridRow {
                            Text(displayName(row.normalizedModel))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridColumnAlignment(.leading)
                                .foregroundStyle(row.isUnknownPricing ? Color.orange.opacity(0.8) : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(ExtraUsage.formatTokens(row.calls))
                                .foregroundStyle(.secondary)
                            Text(ExtraUsage.formatTokens(rowTokens))
                                .foregroundStyle(.tertiary)
                            Text(row.isUnknownPricing ? "—" : ExtraUsage.formatUSDCompact(row.usd))
                            // col5 placeholder to keep chevron column consistent
                            Color.clear.frame(width: 1, height: 1)
                        }
                        .font(.caption2)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // ── Footnotes (only when expanded) ───────────────────────────
            if expanded {
                if !ModelPricingCatalog.shared.isLoaded {
                    Text("定价数据未加载，费用估算暂不可用")
                        .font(.caption2)
                        .foregroundStyle(Color.orange.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if summary.unknownModelCount > 0 {
                    Text("含 \(summary.unknownModelCount) 条无定价数据的调用")
                        .font(.caption2)
                        .foregroundStyle(Color.orange.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("ⓘ 仅读用量字段，不读对话内容")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("本机消费明细")
        .accessibilityHint(expanded ? "收起" : "展开")
    }
}
