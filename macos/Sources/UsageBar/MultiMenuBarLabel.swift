import SwiftUI

/// 菜单栏 label —— 将所有 menuBarVisible 的 provider 并排展示（按 orderedProviderIDs 顺序）。
/// 各 provider 的显示由各自的 `MenuBarLabel` 负责；menuBarVisible/enabled/注册变化实时反映。
struct MultiMenuBarLabel: View {
    @ObservedObject var coordinator: ProviderCoordinator

    var body: some View {
        HStack(spacing: 6) {
            if coordinator.menuBarVisibleIDs.isEmpty {
                Image(systemName: "chart.bar")
                    .font(.system(size: 14, weight: .medium))
            } else {
                ForEach(coordinator.menuBarVisibleIDs, id: \.self) { id in
                    if let runtime = coordinator.runtime(for: id) {
                        MenuBarLabel(runtime: runtime, providerID: id)
                    }
                }
            }
        }
    }
}
