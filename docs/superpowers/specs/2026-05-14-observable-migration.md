---
id: 2026-05-14-observable-migration
title: ObservableObject → @Observable 全仓迁移
status: draft
created: 2026-05-14
updated: 2026-05-14
owner: claude-code
model: claude-sonnet-4-6
target_version: v0.5.0-observable-migration
related_adrs:
  - 0001-swift-native-only
related_research: []
spec_criteria:
  - id: SC1
    criterion: 9 个目标类全部加 @Observable，移除 ObservableObject + @Published；swift build -c release 绿
    done: false
    evidence: ""
  - id: SC2
    criterion: 视图层全部更新：@StateObject → @State，@ObservedObject → let，@EnvironmentObject 改 init 注入
    done: false
    evidence: ""
  - id: SC3
    criterion: RuntimeAggregator 整个类删除；MultiMenuBarLabel icon 模式下仍随任一 provider runtime 变化刷新（@Observable 原生追踪）
    done: false
    evidence: ""
  - id: SC4
    criterion: LaunchAtLoginModel 提取到 Models/LaunchAtLoginModel.swift 独立文件
    done: false
    evidence: ""
  - id: SC5
    criterion: import Combine 从 UsageService / MultiMenuBarLabel 移除；UsageHistoryService 保留（内部 flushTimer AnyCancellable）；ProviderCoordinator 保留（backgroundTimer AnyCancellable）
    done: false
    evidence: ""
  - id: SC6
    criterion: "UsageService.runtimeAuthSync: AnyCancellable? 删除，改用 isAuthenticated.didSet 同步 runtime.setConfigured"
    done: false
    evidence: ""
  - id: SC7
    criterion: swift test 全绿（308+ tests，0 failures）
    done: false
    evidence: ""
  - id: SC8
    criterion: make release-artifacts + verify-release.sh 全绿
    done: false
    evidence: ""
automated_checks:
  - "SC_AUTO_BUILD: swift build -c release"
  - "SC_AUTO_TEST: swift test"
  - "SC_AUTO_GREP_NO_OBSERVABLE_OBJECT: ! grep -rn 'ObservableObject\\|@Published' macos/Sources/UsageBar/ --include='*.swift'"
  - "SC_AUTO_GREP_NO_RUNTIME_AGGREGATOR: ! grep -rn 'RuntimeAggregator' macos/Sources/UsageBar/ --include='*.swift'"
  - "SC_AUTO_GREP_NO_STATE_OBJECT: ! grep -rn '@StateObject\\|@ObservedObject\\|@EnvironmentObject' macos/Sources/UsageBar/ --include='*.swift'"
  - "SC_AUTO_RELEASE: make release-artifacts && bash macos/scripts/verify-release.sh macos/UsageBar.zip"
manual_checks:
  - "真机：菜单栏图标随 provider 数据刷新（icon 模式 + text 模式）"
  - "真机：Popover 用量数据正常显示；Settings 面板正常"
  - "真机：Launch at Login 开关正常"
reviews: []
---

# ObservableObject → @Observable 全仓迁移

## 1. 背景与目标

仓库目前有 9 个 `ObservableObject` 类，全部使用 `@Published` + `@StateObject`/`@ObservedObject`/`@EnvironmentObject` 的老栈。macOS 14 起 SwiftUI 支持 `@Observable` macro，优势：

- 视图只追踪实际读取的属性，减少不必要重渲染
- 消除 `Combine` 框架依赖（除 `ProviderCoordinator` 的 timer `AnyCancellable`）
- 语法更简洁：`@Published var x` → `var x`，`@StateObject` → `@State`

另外顺带做两项整洁：
- `RuntimeAggregator` 整个删除（@Observable 原生追踪，不再需要手动转发 `objectWillChange`）
- `LaunchAtLoginModel` 从 `SettingsView.swift` 提取到独立文件

## 2. 迁移目标清单

| 类 | 文件 | 决策 |
|---|---|---|
| `ProviderRuntime` | `Models/ProviderRuntime.swift` | `@Observable` |
| `UsageService` | `Providers/Claude/UsageService.swift` | `@Observable`；删 `runtimeAuthSync`，改 `didSet` |
| `ProviderCoordinator` | `Services/ProviderCoordinator.swift` | `@Observable`；`AnyCancellable` timer 保留 |
| `UsageHistoryService` | `Services/UsageHistoryService.swift` | `@Observable` |
| `UsageStatsService` | `Services/UsageStatsService.swift` | `@Observable` |
| `NotificationService` | `Services/NotificationService.swift` | `@Observable` |
| `AppUpdater` | `App/AppUpdater.swift` | `@Observable`；KVO callback 保留 |
| `LaunchAtLoginModel` | 提取到 `Models/LaunchAtLoginModel.swift` | `@Observable` |
| `RuntimeAggregator` | `MenuBar/MultiMenuBarLabel.swift` | **整体删除** |

## 3. 架构决策

### 3.1 `@Observable` 规则

- 移除 `: ObservableObject`，加 `@Observable` macro
- 移除所有 `@Published`，保留 `private(set) var`（`@Observable` 支持 property observer `didSet`）
- `import Observation` 替换 `import Combine`（除 `ProviderCoordinator` 同时保留两者）

### 3.2 视图层规则

| 旧 | 新 |
|---|---|
| `@StateObject private var x = Foo()` | `@State private var x = Foo()` |
| `@StateObject` + `_x = StateObject(wrappedValue:)` | `@State` + `_x = State(wrappedValue:)` |
| `@ObservedObject var x: Foo` | `let x: Foo`（@Observable 类无需包装器）|
| `@EnvironmentObject var usageStats: UsageStatsService` | `let usageStats: UsageStatsService`（init 注入，与 `codexStats` 一致）|
| `.environmentObject(usageStats)` | 删除；`usageStats` 改为 `PopoverView` 构造参数 |

### 3.3 `RuntimeAggregator` 删除

`RuntimeAggregator` 的唯一目的是把各 `ProviderRuntime.objectWillChange` 聚合转发给 `MultiMenuBarLabel`，让 icon 模式在任一 runtime 数据变化时重渲染。

`@Observable` 下，SwiftUI 在执行 `body` 时自动追踪所有 `@Observable` 实例的属性读取。`makeCompositeIcon(ids:)` 在 `body` 内被调用，其中读取了 `rt.snapshot`、`rt.isConfigured`——这些读取被 SwiftUI 追踪，因此任何 runtime 属性变化都自动触发重渲染，`RuntimeAggregator` 的 Combine 手动聚合完全可以删除。

同时删除：
- `@StateObject private var aggregator = RuntimeAggregator()`
- `.onAppear { aggregator.update(...) }`
- `.onChange(of: ids) { aggregator.update(...) }`
- `import Combine`

### 3.4 `UsageService.runtimeAuthSync` 替换

现有：
```swift
private var runtimeAuthSync: AnyCancellable?
// init 里：
self.runtimeAuthSync = self.$isAuthenticated.sink { [runtime] authed in
    runtime.setConfigured(authed)
}
```

迁移后（`@Observable` 支持 `didSet`）：
```swift
var isAuthenticated = false {
    didSet { runtime.setConfigured(isAuthenticated) }
}
```

删除 `runtimeAuthSync` 属性，`import Combine` 从 `UsageService.swift` 移除。

### 3.5 `ProviderCoordinator` 的 `@Published` + `didSet` 保留语义

`orderedProviderIDs`、`enabledProviderIDs`、`menuBarVisibleProviderIDs` 带 `didSet` 写 `UserDefaults`——`@Observable` 下 `didSet` 语义不变，仅移除 `@Published` 包装器。

### 3.6 `AppUpdater` KVO 不变

`canCheckObservation` 的 KVO + MainActor dispatch 模式不需要修改；只移除 `ObservableObject + @Published`。

## 4. 涉及文件（15 个）

**Services / Models（核心迁移）：**
1. `Models/ProviderRuntime.swift`
2. `Providers/Claude/UsageService.swift`
3. `Services/ProviderCoordinator.swift`
4. `Services/UsageHistoryService.swift`
5. `Services/UsageStatsService.swift`
6. `Services/NotificationService.swift`
7. `App/AppUpdater.swift`
8. `Models/LaunchAtLoginModel.swift`（新建）

**视图层（wrapper 更新）：**
9. `Features/Settings/SettingsView.swift`（提取 LaunchAtLoginModel，`@StateObject` → `@State`）
10. `MenuBar/MultiMenuBarLabel.swift`（删 RuntimeAggregator + Combine）
11. `App/UsageBarApp.swift`（`@StateObject` → `@State`，移除 `.environmentObject`，补 `usageStats` 参数）
12. `Features/Popover/PopoverView.swift`（`@ObservedObject`/`@EnvironmentObject` → `let`，补 `usageStats` 参数）
13. `MenuBar/MenuBarLabel.swift`（`@ObservedObject` → `let`）
14. `Features/Popover/ProviderUsageSection.swift`（`@ObservedObject` → `let`）
15. `Features/Popover/UsageChartView.swift`（`@ObservedObject` → `let`）

## 5. 测试影响

现有测试均通过直接方法调用 + 属性读取验证——不依赖 Combine publisher / `AnyCancellable`。`@Observable` 下测试逻辑不变；`@MainActor` 隔离的测试类需要确保 class 级 `@MainActor` 已标注（已有 `ProviderCoordinatorTests` 等都已标注）。

预期：`swift test` 0 changes 直接绿，或只需补 `@MainActor` 注解。

## 6. 成功验收

见 frontmatter `spec_criteria` SC1~SC8。自动化检查：
- `SC_AUTO_GREP_NO_OBSERVABLE_OBJECT`：全仓 Sources 无 `ObservableObject`/`@Published` 残留
- `SC_AUTO_GREP_NO_RUNTIME_AGGREGATOR`：MenuBar/ 无 `RuntimeAggregator`/`AnyCancellable` 残留
- `SC_AUTO_GREP_NO_STATE_OBJECT`：全仓 Sources 无 `@StateObject`/`@ObservedObject`/`@EnvironmentObject` 残留
