import SwiftUI

// popover 顶部的 provider tab 现在直接用 `ProviderID`（见 ProviderID.swift）——
// 不再有独立的 `ProviderTab` 枚举。
//
// 临时（A0 阶段）：`isAvailable` 仍硬编码 `== .claude`；v0.2.5 阶段 C 视图泛化时
// 改由 `ProviderRegistry` 是否注册了对应 `UsageProvider` 决定，届时移除本扩展。
extension ProviderID {
    var isAvailable: Bool { self == .claude }
}

/// popover 顶部的多 provider 药丸 tab。不可用的 provider 仍可点选，
/// 由调用方在 selection 非 Claude 时展示 `ProviderComingSoonView`。
struct ProviderTabBar: View {
    @Binding var selection: ProviderID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProviderID.allCases) { provider in
                Button {
                    selection = provider
                } label: {
                    Text(provider.displayName)
                        .font(.caption.weight(provider == selection ? .semibold : .regular))
                        .foregroundStyle(pillForeground(for: provider))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(provider == selection ? Color(nsColor: .controlBackgroundColor) : .clear)
                                .shadow(color: provider == selection ? .black.opacity(0.12) : .clear, radius: 1, y: 0.5)
                        )
                        .contentShape(Rectangle())   // 整个药丸（含两侧空白）都可点
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func pillForeground(for provider: ProviderID) -> Color {
        if provider == selection { return .primary }
        return provider.isAvailable ? .secondary : .secondary.opacity(0.5)
    }
}

/// 选中一个尚未拉通数据层的 provider 时显示。
struct ProviderComingSoonView: View {
    let provider: ProviderID
    var onBackToClaude: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("\(provider.displayName) 支持开发中，敬请期待")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("← 回到 Claude", action: onBackToClaude)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

#Preview("ProviderTabBar") {
    struct Wrap: View {
        @State var sel: ProviderID = .claude
        var body: some View {
            VStack(spacing: 12) {
                ProviderTabBar(selection: $sel)
                if sel != .claude {
                    ProviderComingSoonView(provider: sel, onBackToClaude: { sel = .claude })
                }
            }
            .padding()
            .frame(width: 360)
        }
    }
    return Wrap()
}
