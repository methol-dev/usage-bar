import SwiftUI

struct LocalCostCard: View {
    let summary: CostSummary
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("本地 30 天估算")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("≈ \(ExtraUsage.formatUSD(summary.totalUSD))")
                    .font(.caption)
                    .fontWeight(.medium)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if expanded {
                Divider().padding(.vertical, 2)
                ForEach(summary.perModel, id: \.normalizedModel) { row in
                    HStack {
                        Text(row.normalizedModel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(row.calls) 次")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 50, alignment: .trailing)
                        Text(row.isUnknownPricing ? "—" : ExtraUsage.formatUSD(row.usd))
                            .font(.caption2)
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                }
                if summary.unknownModelCount > 0 {
                    Text("含 \(summary.unknownModelCount) 条未知模型调用记录（价格表过时？）")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text("ℹ️ 仅扫本地 JSONL 用量字段，不读对话内容")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        }
    }
}
