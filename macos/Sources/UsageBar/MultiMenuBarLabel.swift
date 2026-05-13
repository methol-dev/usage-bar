import SwiftUI
import Combine

/// 菜单栏 label —— 将所有 menuBarVisible 的 provider 并排展示（按 orderedProviderIDs 顺序）。
///
/// icon 模式：所有 provider 图标合并为一张 NSImage（compositeIcons），规避 SwiftUI MenuBarExtra
/// label 中 ForEach 多张 template NSImage 只渲第一张的已知问题。
/// text 模式：沿用每个 provider 独立 MenuBarLabel 子视图（各自观察自己的 runtime）。
struct MultiMenuBarLabel: View {
    @ObservedObject var coordinator: ProviderCoordinator
    @StateObject private var aggregator = RuntimeAggregator()
    @AppStorage(MenuBarDisplayMode.storageKey) private var mode: MenuBarDisplayMode = .icon

    var body: some View {
        let ids = coordinator.menuBarVisibleIDs
        content(for: ids)
            .onAppear {
                aggregator.update(runtimes: ids.compactMap { coordinator.runtime(for: $0) })
            }
            .onChange(of: ids) { _, newIds in
                aggregator.update(runtimes: newIds.compactMap { coordinator.runtime(for: $0) })
            }
    }

    @ViewBuilder
    private func content(for ids: [ProviderID]) -> some View {
        if ids.isEmpty {
            Image(systemName: "chart.bar")
                .font(.system(size: 14, weight: .medium))
        } else if mode == .icon {
            Image(nsImage: makeCompositeIcon(ids: ids))
                .renderingMode(.template)
                .fixedSize()
        } else {
            HStack(spacing: 6) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 {
                        Divider().frame(height: 12)
                    }
                    if let runtime = coordinator.runtime(for: id) {
                        MenuBarLabel(runtime: runtime, providerID: id)
                    }
                }
            }
        }
    }

    private func makeCompositeIcon(ids: [ProviderID]) -> NSImage {
        let icons: [NSImage] = ids.compactMap { id in
            guard let rt = coordinator.runtime(for: id) else { return nil }
            let primaryShort: String = {
                let s = rt.snapshot?.primaryWindow?.shortLabel ?? ""
                return s.isEmpty ? "5h" : s
            }()
            let secondaryShort: String = {
                let s = rt.snapshot?.secondaryWindow?.shortLabel ?? ""
                return s.isEmpty ? "7d" : s
            }()
            let pct5h = (rt.snapshot?.primaryWindow?.utilizationPct ?? 0) / 100.0
            let pct7d = (rt.snapshot?.secondaryWindow?.utilizationPct ?? 0) / 100.0
            return rt.isConfigured
                ? renderIcon(providerID: id, primaryLabel: primaryShort, secondaryLabel: secondaryShort,
                             pct5h: pct5h, pct7d: pct7d)
                : renderUnauthenticatedIcon(providerID: id, primaryLabel: primaryShort,
                                           secondaryLabel: secondaryShort)
        }
        return icons.count > 1 ? compositeIcons(icons) : (icons.first ?? NSImage())
    }
}

/// 聚合多个 ProviderRuntime 的变化通知，驱动 MultiMenuBarLabel 在 icon 模式下感知任一 provider 数据刷新。
@MainActor
private final class RuntimeAggregator: ObservableObject {
    private var subscriptions = Set<AnyCancellable>()

    func update(runtimes: [ProviderRuntime]) {
        subscriptions.removeAll()
        for rt in runtimes {
            rt.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &subscriptions)
        }
    }
}
