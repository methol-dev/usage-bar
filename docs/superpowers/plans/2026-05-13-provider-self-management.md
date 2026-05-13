# Provider Self Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让所有供应商（含 Claude）都可以被启用/禁用，每个供应商独立控制菜单栏可见性，修复 Settings 拖拽排序无效问题，并让只用 Codex 的用户不再看到 Claude 登录强制提示。

**Architecture:** 核心改动在 `ProviderCoordinator`：移除 Claude 始终开启约束、删除已被取代的 `menuBarProviderID`（单选）、新增 `menuBarVisibleProviderIDs`（集合）。`PopoverView` 调整登录门控逻辑。`SettingsView` 改用 `List` 实现拖拽排序并在 `ProviderRow` 加菜单栏 checkbox。`MultiMenuBarLabel` 换用新的 `menuBarVisibleIDs` 数据源。

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, UserDefaults

---

## File Map

| 文件 | 改动类型 | 说明 |
|---|---|---|
| `macos/Sources/UsageBar/ProviderCoordinator.swift` | 修改 | 移除 Claude 恒在约束、删 menuBarProviderID、加 menuBarVisibleProviderIDs |
| `macos/Sources/UsageBar/PopoverView.swift` | 修改 | 调整登录门控、加空态视图、修 selectedProvider fallback |
| `macos/Sources/UsageBar/SettingsView.swift` | 修改 | Providers 改用 List + editMode；ProviderRow 加 Menu Bar checkbox |
| `macos/Sources/UsageBar/MultiMenuBarLabel.swift` | 修改 | 数据源从 availableIDs 换成 menuBarVisibleIDs |
| `macos/Tests/UsageBarTests/ProviderCoordinatorTests.swift` | 修改 | 删旧 menuBarProviderID 测试、更新断言、加新 menuBarVisible 测试 |

---

## Task 1: 改造 ProviderCoordinator + 更新测试（原子操作，同一 commit）

> Swift 是编译语言：API 变更和测试更新必须在同一次编译通过。本 task 同时改源码与测试。

**Files:**
- Modify: `macos/Sources/UsageBar/ProviderCoordinator.swift`
- Modify: `macos/Tests/UsageBarTests/ProviderCoordinatorTests.swift`

- [ ] **Step 1.1: 在 ProviderCoordinator 中删除 menuBarProviderID 相关属性、key、方法**

在 `ProviderCoordinator.swift` 中删除以下内容（不要只注释，直接删）：

```swift
// 删除：static let menuBarProviderKey = "primaryProviderID"
// 删除：@Published var menuBarProviderID: ProviderID { ... }（含整个 didSet block）
// 删除：private var isRevertingMenuBar = false
// 删除：var menuBarRuntime: ProviderRuntime { ... }
// 删除：private func firstMenuBarEligible() -> ProviderID { ... }
```

同时删除 `enabledProviderIDs.didSet` 中与 menuBarProviderID 相关的两行：
```swift
// 删除这两行（在 didSet 末尾）：
if !(enabledProviderIDs.contains(menuBarProviderID) && registry.isAvailable(menuBarProviderID)) {
    menuBarProviderID = firstMenuBarEligible()
}
```

删除后，`enabledProviderIDs` 的 `didSet` 结构如下：

```swift
@Published private(set) var enabledProviderIDs: Set<ProviderID> {
    didSet {
        var s = enabledProviderIDs
        s.insert(.claude)
        if s != enabledProviderIDs {
            enabledProviderIDs = s
            return
        }
        defaults.set(enabledProviderIDs.map(\.rawValue), forKey: Self.enabledProvidersKey)
    }
}
```

注意：`s.insert(.claude)` 那段还没删（下一步删），先让文件可以编译。

- [ ] **Step 1.2: 删除 enabledProviderIDs.didSet 的 Claude 强制约束**

把 Step 1.1 后的 `enabledProviderIDs` 简化为：

```swift
@Published private(set) var enabledProviderIDs: Set<ProviderID> {
    didSet { defaults.set(enabledProviderIDs.map(\.rawValue), forKey: Self.enabledProvidersKey) }
}
```

- [ ] **Step 1.3: 更新 setEnabled —— 删除 Claude guard**

把：
```swift
func setEnabled(_ id: ProviderID, _ on: Bool) {
    if id == .claude { return }
    if on { enabledProviderIDs.insert(id) } else { enabledProviderIDs.remove(id) }
}
```
改为：
```swift
func setEnabled(_ id: ProviderID, _ on: Bool) {
    if on { enabledProviderIDs.insert(id) } else { enabledProviderIDs.remove(id) }
}
```

- [ ] **Step 1.4: 在 ProviderCoordinator 中添加 menuBarVisibleProviderIDs**

在 `static let enabledProvidersKey` 后面加：
```swift
static let menuBarVisibleProvidersKey = "menuBarVisibleProviders"
```

在 `orderedProviderIDs` 和 `enabledProviderIDs` 的 `@Published` 区域后，添加：
```swift
@Published private(set) var menuBarVisibleProviderIDs: Set<ProviderID> {
    didSet { defaults.set(menuBarVisibleProviderIDs.map(\.rawValue), forKey: Self.menuBarVisibleProvidersKey) }
}
```

在 `setEnabled` 后面，添加 mutator 和计算属性：
```swift
func setMenuBarVisible(_ id: ProviderID, _ on: Bool) {
    if on { menuBarVisibleProviderIDs.insert(id) } else { menuBarVisibleProviderIDs.remove(id) }
}

/// 实际在菜单栏显示的 IDs：menuBarVisible ∩ availableIDs（enabled + registered），按用户排序。
var menuBarVisibleIDs: [ProviderID] {
    orderedProviderIDs.filter {
        menuBarVisibleProviderIDs.contains($0) &&
        registry.isAvailable($0) &&
        enabledProviderIDs.contains($0)
    }
}
```

- [ ] **Step 1.5: 更新 init —— 删除 menuBarProviderID 初始化逻辑，加 menuBarVisibleProviderIDs 初始化**

找到 `init` 方法中关于 `menuBar` 的部分（大约 5 行），删除：
```swift
// 删除这整个块：
let registeredIDs = registry.availableIDs
let storedMenuBar = defaults.string(forKey: Self.menuBarProviderKey).flatMap(ProviderID.init(rawValue:))
let menuBar: ProviderID
if let m = storedMenuBar, enabled.contains(m), registeredIDs.contains(m) {
    menuBar = m
} else {
    menuBar = order.first(where: { enabled.contains($0) && registeredIDs.contains($0) }) ?? .claude
}
```

同时删除 init 最后几行中的 `self.menuBarProviderID = menuBar`。

删除 `enabled.insert(.claude)` 这一行（在"启用集"读盘块里）：
```swift
// 改前：
if let storedEnabled = defaults.stringArray(forKey: Self.enabledProvidersKey) {
    enabled = Set(storedEnabled.compactMap(ProviderID.init(rawValue:)).filter { ProviderID.allCases.contains($0) })
    enabled.insert(.claude)   // ← 删除这行
} else {

// 改后：
if let storedEnabled = defaults.stringArray(forKey: Self.enabledProvidersKey) {
    enabled = Set(storedEnabled.compactMap(ProviderID.init(rawValue:)).filter { ProviderID.allCases.contains($0) })
} else {
```

在 init 的 `let enabled` 块之后，添加菜单栏可见集的读取：
```swift
// 菜单栏可见集：读盘 → ∩ allCases；从没存过 → 默认全 allCases（首次升级保留全显行为）
let menuBarVisible: Set<ProviderID>
if let stored = defaults.stringArray(forKey: Self.menuBarVisibleProvidersKey) {
    menuBarVisible = Set(stored.compactMap(ProviderID.init(rawValue:)).filter { ProviderID.allCases.contains($0) })
} else {
    menuBarVisible = Set(ProviderID.allCases)
}
```

在 init 末尾赋值时添加：
```swift
self.orderedProviderIDs = order
self.enabledProviderIDs = enabled
self.menuBarVisibleProviderIDs = menuBarVisible
// 注意：self.menuBarProviderID = menuBar 这行已在上面删除
```

- [ ] **Step 1.6: 更新 ProviderCoordinatorTests —— 删除涉及 menuBarProviderID 的测试**

打开 `ProviderCoordinatorTests.swift`，删除以下整个测试方法（完整删除）：
- `testSetEnabledClaudeIsNoOp` — 将被 `testClaudeCanBeDisabled` 替代
- `testDisablingMenuBarProviderMovesIt` — menuBarProviderID 已删除
- `testMenuBarProviderIDRejectsUnregistered` — menuBarProviderID 已删除
- `testMenuBarProviderIDRejectsDisabled` — menuBarProviderID 已删除
- `testInitFallbackOnIllegalStoredMenuBar` — menuBarProviderID 已删除

- [ ] **Step 1.7: 更新 testDefaultOrderAndEnabled —— 替换 menuBarProviderID 断言**

找到并修改 `testDefaultOrderAndEnabled`：
```swift
func testDefaultOrderAndEnabled() {
    let c = makeCoordinator(freshDefaults())
    XCTAssertEqual(c.orderedProviderIDs, ProviderID.allCases)
    XCTAssertTrue(c.enabledProviderIDs.isSuperset(of: [.claude, .codex]))
    XCTAssertEqual(c.availableIDs, [.claude, .codex])
    // 改：删除 menuBarProviderID 断言，改为 menuBarVisibleIDs 断言
    XCTAssertTrue(Set(c.menuBarVisibleIDs).isSuperset(of: [.claude, .codex]))
}
```

- [ ] **Step 1.8: 添加新测试 —— Claude 可禁用 + menuBarVisible 行为**

在 `ProviderCoordinatorTests` 末尾（`StubProviderForCoordTest` 之前）添加：

```swift
// MARK: - Task 1（本 spec）：Claude 可禁用

func testClaudeCanBeDisabled() {
    let c = makeCoordinator(freshDefaults())
    c.setEnabled(.claude, false)
    XCTAssertFalse(c.enabledProviderIDs.contains(.claude))
    XCTAssertFalse(c.availableIDs.contains(.claude))
}

func testAllProvidersDisabledYieldsEmptyAvailableIDs() {
    let c = makeCoordinator(freshDefaults(), withCodex: false)
    c.setEnabled(.claude, false)
    XCTAssertTrue(c.availableIDs.isEmpty)
}

// MARK: - Task 1：menuBarVisible

func testMenuBarVisibleDefaultsToAllCases() {
    let c = makeCoordinator(freshDefaults())
    XCTAssertEqual(c.menuBarVisibleProviderIDs, Set(ProviderID.allCases))
}

func testSetMenuBarVisibleFalseRemovesFromSet() {
    let d = freshDefaults()
    let c = makeCoordinator(d)
    c.setMenuBarVisible(.codex, false)
    XCTAssertFalse(c.menuBarVisibleProviderIDs.contains(.codex))
    let stored = Set((d.stringArray(forKey: "menuBarVisibleProviders") ?? [])
        .compactMap(ProviderID.init(rawValue:)))
    XCTAssertFalse(stored.contains(.codex), "应持久化到 UserDefaults")
}

func testMenuBarVisibleIDsExcludesDisabledProvider() {
    let c = makeCoordinator(freshDefaults())
    c.setEnabled(.codex, false)
    XCTAssertFalse(c.menuBarVisibleIDs.contains(.codex), "disabled → 不在 menuBarVisibleIDs")
}

func testMenuBarVisibleIDsExcludesUnregisteredProvider() {
    let c = makeCoordinator(freshDefaults(), withCodex: false)
    // codex 未注册但 menuBarVisibleProviderIDs 默认包含 .codex
    XCTAssertFalse(c.menuBarVisibleIDs.contains(.codex), "未注册 → 不在 menuBarVisibleIDs")
}

func testMenuBarVisibleIDsExcludesExplicitlyHiddenProvider() {
    let c = makeCoordinator(freshDefaults())
    c.setMenuBarVisible(.codex, false)
    XCTAssertFalse(c.menuBarVisibleIDs.contains(.codex), "menuBarVisible=false → 不在 menuBarVisibleIDs")
}

func testDisablingClaudeRemovesFromMenuBarVisibleIDs() {
    let c = makeCoordinator(freshDefaults())
    XCTAssertTrue(c.menuBarVisibleIDs.contains(.claude))
    c.setEnabled(.claude, false)
    XCTAssertFalse(c.menuBarVisibleIDs.contains(.claude))
}

func testMenuBarVisibleIDsRespectOrderedProviderIDs() {
    let d = freshDefaults()
    d.set(["codex", "claude"], forKey: "providerOrder")
    let c = makeCoordinator(d)
    // 顺序：codex 在前
    let ids = c.menuBarVisibleIDs
    if ids.count >= 2 {
        XCTAssertEqual(ids[0], .codex)
        XCTAssertEqual(ids[1], .claude)
    }
}
```

- [ ] **Step 1.9: 构建并运行测试**

```bash
cd macos && swift build -c release 2>&1 | tail -10
cd macos && swift test --filter ProviderCoordinatorTests 2>&1 | tail -30
```

预期：构建成功，所有 ProviderCoordinatorTests 通过（包括新增的 8 个）。
若有编译错误，逐一修复（通常是 `self.menuBarVisibleProviderIDs` 未在 init 中初始化，或遗漏了某处 menuBarProviderID 引用）。

- [ ] **Step 1.10: 运行全量测试**

```bash
cd macos && swift test 2>&1 | tail -20
```

预期：所有测试通过（0 failures）。

- [ ] **Step 1.11: Commit**

```bash
git add macos/Sources/UsageBar/ProviderCoordinator.swift \
        macos/Tests/UsageBarTests/ProviderCoordinatorTests.swift
git commit -m "$(cat <<'EOF'
feat: ProviderCoordinator — Claude 可禁用 + 新增 menuBarVisibleProviderIDs

- 移除 Claude 始终开启约束（setEnabled/enabledProviderIDs.didSet）
- 删除已被取代的 menuBarProviderID（单选）及 menuBarRuntime/isRevertingMenuBar
- 新增 menuBarVisibleProviderIDs: Set<ProviderID>（独立菜单栏可见集）
- 新增 setMenuBarVisible(_:_:) mutator 与 menuBarVisibleIDs 计算属性
- 更新 ProviderCoordinatorTests：删旧 menuBarProviderID 测试，加 8 个新测试

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 更新 PopoverView —— 修复登录门控逻辑 + 空态视图

**Files:**
- Modify: `macos/Sources/UsageBar/PopoverView.swift`

- [ ] **Step 2.1: 更新 body —— 调整 Claude 登录门控逻辑**

找到 `var body: some View` 中的：
```swift
VStack(alignment: .leading, spacing: 10) {
    if !claude.isAuthenticated {
        notAuthenticatedView
    } else {
        AccountSwitcherView(service: claude)  // accounts.count <= 1 时自隐藏
        ProviderTabBar(selection: $selectedProvider, availableIDs: coordinator.availableIDs)
        providerArea
    }
}
```

替换为：
```swift
VStack(alignment: .leading, spacing: 10) {
    let claudeEnabled = coordinator.enabledProviderIDs.contains(.claude)
    if claudeEnabled && !claude.isAuthenticated {
        notAuthenticatedView
    } else if coordinator.availableIDs.isEmpty {
        noProvidersView
    } else {
        if claudeEnabled { AccountSwitcherView(service: claude) }
        ProviderTabBar(selection: $selectedProvider, availableIDs: coordinator.availableIDs)
        providerArea
    }
}
```

- [ ] **Step 2.2: 更新 providerArea —— 当 Claude 未在 availableIDs 中时不渲染 claudeUsageArea**

找到 `providerArea` 的第一个 `if` 分支：
```swift
if selectedProvider == .claude {
    claudeUsageArea
```

替换为：
```swift
if selectedProvider == .claude && coordinator.availableIDs.contains(.claude) {
    claudeUsageArea
```

- [ ] **Step 2.3: 更新 onChange —— selectedProvider 回退到第一个可用 provider**

找到：
```swift
.onChange(of: coordinator.availableIDs) { _, ids in
    if !ids.contains(selectedProvider) { selectedProvider = .claude }
}
```

替换为：
```swift
.onChange(of: coordinator.availableIDs) { _, ids in
    if !ids.contains(selectedProvider) {
        selectedProvider = ids.first ?? .claude
    }
}
```

- [ ] **Step 2.4: 在 body 的 `.task` 后添加 `.onAppear` 以处理初始 selectedProvider**

在 body 末尾的修饰符区域，找到 `.task { await coordinator.refreshAllEnabledOnOpen() }`，在其**之后**添加：
```swift
.onAppear {
    if !coordinator.availableIDs.contains(selectedProvider) {
        selectedProvider = coordinator.availableIDs.first ?? .claude
    }
}
```

- [ ] **Step 2.5: 在 PopoverView 中添加 noProvidersView**

在 `notAuthenticatedView` 属性之前，添加：
```swift
@ViewBuilder
private var noProvidersView: some View {
    VStack(spacing: 12) {
        Text("没有启用的供应商")
            .font(.headline)
        Text("请在设置中至少启用一个供应商。")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        SettingsLink { Text("打开设置") }
            .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(maxWidth: .infinity)
    Divider()
    HStack {
        settingsButton
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .buttonStyle(.borderless)
    }
}
```

- [ ] **Step 2.6: 构建**

```bash
cd macos && swift build -c release 2>&1 | tail -10
```

预期：构建成功，无错误。若有 `menuBarProviderID` 相关引用残留（来自注释），删除那行注释。

- [ ] **Step 2.7: Commit**

```bash
git add macos/Sources/UsageBar/PopoverView.swift
git commit -m "$(cat <<'EOF'
feat: PopoverView — 按 Claude 启用状态分路，加空态视图

- Claude 禁用时跳过登录门控，直接展示其他 provider 的 tab
- 全部 provider 都禁用时显示「没有启用的供应商」空态 + 打开设置入口
- providerArea 添加 Claude 可用性检查，避免 disabled Claude 渲染 claudeUsageArea
- selectedProvider 回退逻辑改为 first available（不再硬编码 .claude）

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 更新 SettingsView —— 拖拽排序 + Menu Bar toggle

**Files:**
- Modify: `macos/Sources/UsageBar/SettingsView.swift`

- [ ] **Step 3.1: 替换 Section("Providers") 内容为 List + onMove**

找到 `Section("Providers")` 整个块：
```swift
Section("Providers") {
    ForEach(coordinator.orderedProviderIDs, id: \.self) { id in
        ProviderRow(coordinator: coordinator, id: id)
    }
    .onMove { from, to in coordinator.moveProvider(from: from, to: to) }
    Text("开关 = 同时控制菜单栏显示与后台刷新；Claude 始终开启。拖动调整顺序（也影响 popover tab 顺序）。")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

替换为：
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
    .frame(height: CGFloat(coordinator.orderedProviderIDs.count) * 40 + 8)
    Text("Enable = 控制数据采集与 tab；菜单栏 = 是否在状态栏展示。拖动可调整顺序。")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

- [ ] **Step 3.2: 更新 ProviderRow —— 解锁 Claude toggle + 添加 Menu Bar checkbox**

找到整个 `private struct ProviderRow: View { ... }` 并替换为：

```swift
private struct ProviderRow: View {
    @ObservedObject var coordinator: ProviderCoordinator
    let id: ProviderID

    var body: some View {
        let registered = coordinator.isAvailable(id)
        let enabled = coordinator.enabledProviderIDs.contains(id)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(id.displayName)
                    .foregroundStyle(registered ? .primary : .secondary)
                if !registered {
                    Text("coming soon")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("菜单栏", isOn: Binding(
                get: { coordinator.menuBarVisibleProviderIDs.contains(id) },
                set: { coordinator.setMenuBarVisible(id, $0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(!enabled || !registered)
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { coordinator.setEnabled(id, $0) }
            ))
            .labelsHidden()
            .disabled(!registered)
        }
    }
}
```

注意：Claude 的 Enable toggle 不再 `.disabled(id == .claude || ...)`，仅剩 `.disabled(!registered)`。

- [ ] **Step 3.3: 构建**

```bash
cd macos && swift build -c release 2>&1 | tail -10
```

预期：构建成功。若出现 `frame(height:)` 类型错误，把 `40` 改为 `CGFloat(40)`。

- [ ] **Step 3.4: Commit**

```bash
git add macos/Sources/UsageBar/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat: Settings Providers — 拖拽排序修复 + Menu Bar checkbox + Claude 可关闭

- Providers section 改用 List + editMode.active + onMove，拖拽手柄正确显示
- ProviderRow 加「菜单栏」checkbox（disabled 状态：未注册或已禁用）
- Claude Enable toggle 解锁（不再强制始终开启）
- 提示文案更新

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 更新 MultiMenuBarLabel —— 改用 menuBarVisibleIDs

**Files:**
- Modify: `macos/Sources/UsageBar/MultiMenuBarLabel.swift`

- [ ] **Step 4.1: 替换数据源**

找到：
```swift
ForEach(coordinator.availableIDs, id: \.self) { id in
```

替换为：
```swift
ForEach(coordinator.menuBarVisibleIDs, id: \.self) { id in
```

- [ ] **Step 4.2: 添加 menuBarVisibleIDs 为空时的 fallback icon**

当所有 provider 的菜单栏都关闭时，`HStack` 内无子视图，macOS `MenuBarExtra` 可能隐藏。添加 fallback：

```swift
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
```

- [ ] **Step 4.3: 构建 + 全量测试**

```bash
cd macos && swift build -c release 2>&1 | tail -10
cd macos && swift test 2>&1 | tail -20
```

预期：构建成功，所有测试通过（0 failures）。

- [ ] **Step 4.4: Commit**

```bash
git add macos/Sources/UsageBar/MultiMenuBarLabel.swift
git commit -m "$(cat <<'EOF'
feat: MultiMenuBarLabel — 使用 menuBarVisibleIDs，加全隐时 fallback icon

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: 最终集成验证

- [ ] **Step 5.1: 全量测试**

```bash
cd macos && swift test 2>&1 | grep -E "Test Suite|PASS|FAIL|error:"
```

预期输出示例：
```
Test Suite 'All tests' passed at ...
Executed XX tests, with 0 failures (0 unexpected) in ...
```

- [ ] **Step 5.2: Release 构建验证**

```bash
make release-artifacts 2>&1 | tail -20
bash macos/scripts/verify-release.sh macos/UsageBar.zip
```

预期：`verify-release.sh` 输出全 ✅。

- [ ] **Step 5.3: 手动回归验收（make app 后操作）**

```bash
make app
```

打开 `macos/UsageBar.app` 执行以下检查（在 Settings > Providers）：

| 验收项 | 操作 | 预期结果 |
|---|---|---|
| SC1 | 禁用 Claude → 打开 popover | 不显示登录提示，直接显示其他 provider tab |
| SC2 | 只启用 Codex → 打开 popover | 正常显示 Codex 数据，无 Claude 登录强制 |
| SC3 | 拖动 provider 行 | 顺序实时更新，popover tab 顺序随之变化 |
| SC4 | 关闭某 provider 的「菜单栏」checkbox | 该 provider 消失于状态栏文字区 |
| SC5 | 禁用全部 provider → 打开 popover | 显示「没有启用的供应商」+ 打开设置按钮 |
| 回归 | 恢复默认状态（全部启用）| 与改前行为一致 |

- [ ] **Step 5.4: 更新 spec spec_criteria**

在 `docs/superpowers/specs/2026-05-13-provider-self-management.md` 中，将已验证的 SC1~SC6 的 `done` 改为 `true`，`evidence` 填入相应描述（如 `"swift test green; manual verified"`）。

- [ ] **Step 5.5: 提交 spec 状态更新**

```bash
git add docs/superpowers/specs/2026-05-13-provider-self-management.md
git commit -m "docs: 更新 v0.3.0 spec SC1-SC6 验收状态 [spec:2026-05-13-provider-self-management]

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```
