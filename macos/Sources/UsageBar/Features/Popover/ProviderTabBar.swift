import SwiftUI

// popover 顶部的 provider tab 直接用 `ProviderID`（见 ProviderID.swift）。
// 「某 provider 可用 vs 占位」由 `ProviderCoordinator.availableIDs`（= 注册表里有没有它）决定，
// 由调用方传进 `ProviderTabBar(availableIDs:)`。

/// popover 顶部的多 provider 药丸 tab。不可用的 provider 仍可点选，
/// （`PopoverView` 的 `.onChange` 会把失效的 selection 弹回 Claude；`ProviderComingSoonView` 仅作防御性 fallback。）
struct ProviderTabBar: View {
    @Binding var selection: ProviderID
    let availableIDs: [ProviderID]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(availableIDs, id: \.self) { provider in
                Button {
                    selection = provider
                } label: {
                    Text(provider.displayName)
                        .font(.caption.weight(provider == selection ? .semibold : .regular))
                        .foregroundStyle(provider == selection ? .primary : .secondary)
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
                // 选中态只靠字重/底色表达，VoiceOver 听不出来，需显式标注
                .accessibilityAddTraits(provider == selection ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

/// 选中一个尚未对接数据层的 provider（占位 tab）时显示。
struct ProviderComingSoonView: View {
    let provider: ProviderID
    var onBackToClaude: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("\(provider.displayName) coming soon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("← Back to Claude", action: onBackToClaude)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// 选中一个已对接但当前未配置（无凭证）的 provider 时显示。
/// （v0.2.5 暂时用不到 —— 唯一可用 provider 是 Claude，未登录走 PopoverView 的 signInView；
/// v0.2.6 Codex tab 在 `~/.codex/auth.json` 缺失时会展示它。）
struct ProviderUnconfiguredView: View {
    let provider: ProviderID
    var onBackToClaude: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("\(provider.displayName) not signed in")
                .font(.subheadline)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("← Back to Claude", action: onBackToClaude)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var hint: String {
        switch provider {
        case .codex:
            return "Run `codex` in your terminal, then come back."
        default:
            return "Sign in via the \(provider.displayName) CLI / app."
        }
    }
}

#Preview("ProviderTabBar") {
    struct Wrap: View {
        @State var sel: ProviderID = .claude
        var body: some View {
            VStack(spacing: 12) {
                ProviderTabBar(selection: $sel, availableIDs: [.claude])
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
