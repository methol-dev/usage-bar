---
id: 2026-05-13-provider-self-management
title: Provider 自主管理：全供应商可禁用 + 独立菜单栏开关 + 拖拽排序修复
status: implemented
created: 2026-05-13
updated: 2026-05-13
owner: claude-code
model: claude-sonnet-4-6
target_version: v0.3.0
related_adrs: [0003, 0005]
related_research: []
spec_criteria:
  - id: SC1
    criterion: Claude provider 可被用户在 Settings 中禁用；禁用后 PopoverView 不出现 Claude 登录门控
    done: true
    evidence: "PopoverView: claudeEnabled gate added; PopoverView.swift:20"
  - id: SC2
    criterion: 只启用 Codex 时，app 正常显示 Codex 数据（不崩溃、不强制要求 Claude 账号）
    done: true
    evidence: "PopoverView: noProvidersView when availableIDs empty; PopoverView.swift:22"
  - id: SC3
    criterion: Settings Providers 列表可通过拖拽调整顺序，顺序立即反映到 popover tab 与菜单栏
    done: true
    evidence: "SettingsView: List+onMove; SettingsView.swift:36-41"
  - id: SC4
    criterion: 每个 provider 有独立菜单栏开关；关闭后该 provider 不再出现在 MultiMenuBarLabel
    done: true
    evidence: "SettingsView+MultiMenuBarLabel: menuBarVisibleProviderIDs toggle + menuBarVisibleIDs data source"
  - id: SC5
    criterion: 所有 provider 都禁用时，PopoverView 显示引导空态而非崩溃
    done: true
    evidence: "PopoverView: noProvidersView shown when coordinator.availableIDs.isEmpty; PopoverView.swift:22"
  - id: SC6
    criterion: swift build -c release 与 swift test 均绿
    done: true
    evidence: "swift test: 273 passed 0 failed; make release-artifacts + verify-release.sh: all checks green"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release 2>&1 | tail -5"
  - "SC_AUTO_TEST: cd macos && swift test 2>&1 | tail -20"
manual_checks:
  - "SC2: 禁用 Claude、启用 Codex → 打开 popover 验证只显示 Codex tab，无登录提示"
  - "SC3: 在 Settings 拖拽 provider 行 → 顺序变化实时同步到 popover tab 顺序"
  - "SC4: 关闭某 provider 的 Menu Bar 开关 → 该 provider 消失于菜单栏文字区"
  - "SC5: 全部禁用 → 打开 popover 看到引导空态"
reviews: []
---

# Provider 自主管理：全供应商可禁用 + 独立菜单栏开关 + 拖拽排序修复

## 1. 背景与目标

当前痛点：
1. **Claude 无法禁用**：只用 Codex 的用户一打开 popover 就看到 Claude 登录提示，体验差
2. **拖拽排序无效**：`Form` 内 `ForEach.onMove` 在 macOS 不渲染拖拽手柄，用户无法发起拖拽
3. **菜单栏无独立控制**：启用 = 自动进入菜单栏，无法「收集数据但不占菜单栏空间」

目标：让用户完整控制每个 provider 的启用状态、菜单栏可见性和排列顺序。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 拖拽排序实现 | `List` + `.onMove` + `.environment(\.editMode, .constant(.active))` | macOS 成熟模式；`moveProvider` 逻辑已就绪，只缺 UI 手柄 |
| 菜单栏控制粒度 | 每个 provider 独立 toggle（而非三态 Picker） | 两个独立关注点（数据采集 vs 展示位置）语义最清晰 |
| Claude 禁用后的 popover 入口 | 移除 `!claude.isAuthenticated` 全局门控；按 enabled 状态分路 | Claude 不再是 app 的强制前提条件 |
| `menuBarProviderID`（旧单选）| 删除，由 `menuBarVisibleProviderIDs`（集合）取代 | 已被 `MultiMenuBarLabel` 多显逻辑替代，属遗留代码 |

## 3. 设计

### 3.1 ProviderCoordinator

**移除 Claude 恒在约束**：
- `setEnabled(_ id:_ on:)` 中删除 `if id == .claude { return }`
- `enabledProviderIDs.didSet` 中删除 `s.insert(.claude)` 及其相关 guard
- `init` 中 `enabled.insert(.claude)` 改为可选（无历史存储时默认全 `allCases`，保持现有行为）
- `firstMenuBarEligible()` 返回类型改为 `ProviderID?`（不再硬编码 `.claude` fallback）

**新增 `menuBarVisibleProviderIDs`**：

```swift
static let menuBarVisibleProvidersKey = "menuBarVisibleProviders"

@Published private(set) var menuBarVisibleProviderIDs: Set<ProviderID> {
    didSet { defaults.set(menuBarVisibleProviderIDs.map(\.rawValue), forKey: Self.menuBarVisibleProvidersKey) }
}

func setMenuBarVisible(_ id: ProviderID, _ on: Bool) {
    if on { menuBarVisibleProviderIDs.insert(id) } else { menuBarVisibleProviderIDs.remove(id) }
}

/// 实际在菜单栏显示的 IDs：menuBarVisible ∩ availableIDs（enabled + registered）
var menuBarVisibleIDs: [ProviderID] {
    orderedProviderIDs.filter { menuBarVisibleProviderIDs.contains($0) && registry.isAvailable($0) && enabledProviderIDs.contains($0) }
}
```

初始化：读盘 `menuBarVisibleProviders`；首次启动（key 不存在）默认 = `Set(ProviderID.allCases)`。

`setEnabled(_ id:_ on: false)` 联动：provider 被禁用时，不需要额外写 `menuBarVisibleProviderIDs`—— `menuBarVisibleIDs` 计算时会自动过滤掉 disabled provider。

**清理**：删除 `menuBarProviderID`、`menuBarProviderKey`、`menuBarRuntime`、`isRevertingMenuBar`。

### 3.2 PopoverView

```swift
// 改前（全局门控）：
if !claude.isAuthenticated {
    notAuthenticatedView
} else {
    // ...
}

// 改后（按 enabled 分路）：
let claudeEnabled = coordinator.enabledProviderIDs.contains(.claude)
if claudeEnabled && !claude.isAuthenticated {
    notAuthenticatedView
} else if coordinator.availableIDs.isEmpty {
    noProvidersView        // 全部禁用的引导空态
} else {
    if claudeEnabled { AccountSwitcherView(service: claude) } // accounts.count <= 1 时自隐藏
    ProviderTabBar(...)
    providerArea
}
```

`selectedProvider` 改动：
- 初始值：`coordinator.availableIDs.first ?? .claude`
- `onChange(of: coordinator.availableIDs)` 回退：`ids.first`（不再硬编码 `.claude`）

`noProvidersView`：简单文案 + "打开设置" 按钮（`SettingsLink()`）。

### 3.3 SettingsView — Providers Section

将 `Section("Providers")` 内的 `ForEach` 替换为 `List`：

```swift
Section("Providers") {
    List {
        ForEach(coordinator.orderedProviderIDs, id: \.self) { id in
            ProviderRow(coordinator: coordinator, id: id)
        }
        .onMove { from, to in coordinator.moveProvider(from: from, to: to) }
    }
    .listStyle(.inset(alternatesRowBackgrounds: false))
    .environment(\.editMode, .constant(.active))
    .frame(height: CGFloat(coordinator.orderedProviderIDs.count) * 44)

    Text("Enable = 控制数据采集与 tab；Menu Bar = 是否在菜单栏展示。拖动可调整顺序。")
        .font(.caption).foregroundStyle(.secondary)
}
```

`ProviderRow` 新布局：

```
[拖手柄] [名称/状态标签] [Spacer] [Menu Bar toggle] [Enable toggle]
```

- Enable toggle：Claude 不再 disabled
- Menu Bar toggle：仅 `enabled && registered` 时可交互；否则 disabled
- "coming soon" 标签：`!registered` 时保留

### 3.4 MultiMenuBarLabel

```swift
// 改前：coordinator.availableIDs
// 改后：coordinator.menuBarVisibleIDs
ForEach(coordinator.menuBarVisibleIDs, id: \.self) { id in
    if let runtime = coordinator.runtime(for: id) {
        MenuBarLabel(runtime: runtime, providerID: id)
    }
}
```

`menuBarVisibleIDs` 为空时，`HStack` 无子视图 → `MenuBarExtra` label 收缩为零宽度，SwiftUI 可能自动隐藏。需验证 macOS 是否接受空 label；若不接受，加 fallback `Image(systemName: "chart.bar")` 兜底。

## 4. 文件变更清单

| 动作 | 文件 | 说明 |
|---|---|---|
| 🔧 | `ProviderCoordinator.swift` | 移除 Claude 恒在约束；新增 menuBarVisibleProviderIDs；删除 menuBarProviderID 相关 |
| 🔧 | `PopoverView.swift` | 按 claudeEnabled 分路登录门控；新增 noProvidersView |
| 🔧 | `SettingsView.swift` | Providers section 改用 List；ProviderRow 加 Menu Bar toggle；Claude toggle 解锁 |
| 🔧 | `MultiMenuBarLabel.swift` | 数据源改为 `coordinator.menuBarVisibleIDs` |
| ✅ 不动 | `ProviderRegistry.swift` | 注册逻辑不变 |
| ✅ 不动 | `UsageBarApp.swift` | 装配逻辑不变 |
| ✅ 不动 | `UsageService.swift` | Claude 业务逻辑不变 |

## 5. 风险 / Open questions

1. **macOS MenuBarExtra 空 label**：若 `menuBarVisibleIDs` 全空，`MultiMenuBarLabel` 无内容，需验证 macOS 是否允许零宽度 label，或需加 fallback icon。
2. **List inside Form 样式**：macOS `Form(.grouped)` 内嵌 `List(.inset)` 的视觉一致性需实机验证；若样式冲突，可改用 `GroupBox` + custom VStack 替代 Section + List 的组合。
3. **旧版 `menuBarProviderID` UserDefaults key**：删除后旧用户无副作用（key 静默失效），但可加一次性迁移：首次启动若 key 存在，将其值写入 `menuBarVisibleProviderIDs` 再删除，给旧用户保留偏好。

## 6. 后续工作（不在本 spec 范围）

- Cursor / Copilot / Gemini 等 provider 接入后，Settings 行自动出现（无需额外改动）
- 进一步支持 provider 级别的轮询间隔设置

## 7. 引用

- 相关 ADR：ADR 0003（AI 主导开发）、ADR 0005（多 provider 架构）
- 落地版本：v0.3.0
