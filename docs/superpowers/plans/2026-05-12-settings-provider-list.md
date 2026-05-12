# Settings provider 列表 + 刷新纪律 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 superpowers:executing-plans。步骤用 checkbox。

**Goal:** Settings 把 Primary Provider 下拉换成可拖动/可开关的 provider 列表（外加菜单栏单选子开关）、去 Account 区（Sign Out 迁 popover 底栏）、Codex 用统一 polling interval、刷新纪律（切 tab 不刷新、刷新只 2 入口）、菜单栏 provider-aware —— Claude / 既有行为零回归。

**Architecture:** `ProviderCoordinator` 长出 `orderedProviderIDs`（持久化 `providerOrder`）/ `enabledProviderIDs`（持久化 `enabledProviders`，Claude 恒在）/ `menuBarProviderID`（= 原 `primaryProviderID` 改名，key 沿用，约束 ∈ enabled∩registered）/ `setEnabled` / `moveProvider` / `refreshAllEnabledOnOpen` / `startBackgroundPolling`（持统一 `backgroundTimer`，`internal func onBackgroundTick()`，监听 `UserDefaults.didChangeNotification` 重起）；`availableIDs` = ordered∩registered∩enabled。`SettingsView` 加「Providers」section、删 Primary picker + Account section。`PopoverView` 删 `.task(id:)`、加无 id `.task` 调 `refreshAllEnabledOnOpen`、`bottomBar` 加 Sign Out、`ProviderTabBar(availableIDs:)` 改吃 `coordinator.availableIDs` 并 iterate 它（不再 iterate 全 5 个占位）、selectedProvider 失效时回退 .claude。`MenuBarIconRenderer` 的 `drawClaudeLogo` → `drawProviderGlyph(for:)`、`renderIcon` 加 `providerID`/`primaryLabel`/`secondaryLabel`。`UsageWindow` 加 `shortLabel`，Claude/Codex 的 model 层填。`CodexProvider` 删 `static pollIntervalSeconds` + 自持 timer，加实例 `pollIntervalSeconds`（读 `defaults["pollingMinutes"]`）+ `init(defaults:)`。`ClaudeUsageBarApp` 改用 `coordinator.startBackgroundPolling()` / `menuBarRuntime` / `menuBarProviderID` / `providerID:`。

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit（菜单栏 NSImage 渲染）/ Combine（Timer.publish）/ XCTest。命令用绝对路径（`cd /Users/methol/data/code-methol/usage-bar/macos` 或 repo 根）。

> 对应 spec：[`../specs/2026-05-12-settings-provider-list.md`](../specs/2026-05-12-settings-provider-list.md)（G2 approved-after-revisions，8 SC）。机械细节以 spec §3.1 为准；本 plan 给关键代码 + 任务拆分 + 验证。注：spec SC1 说 `orderedProviderIDs` 默认 = `registry.orderedIDs`（= `ProviderID.allCases`，**含 cursor/copilot/gemini 占位** —— Settings 列表要列出它们显示「coming soon」），读盘后只丢「不在 `ProviderID.allCases` 里」的（实际不会有）+ 末尾补漏掉的；`enabledProviderIDs` 默认 = 全 `ProviderID.allCases`，未注册的靠 `availableIDs` 的 `registered` 过滤排除掉，Settings 里它们的 toggle `.disabled(!registered)`。

---

## File Structure

改：`ProviderCoordinator.swift`、`SettingsView.swift`、`PopoverView.swift`、`ProviderTabBar.swift`、`MenuBarLabel.swift`、`MenuBarIconRenderer.swift`、`ProviderUsageSnapshot.swift`、`UsageModel.swift`、`CodexUsageModel.swift`、`CodexProvider.swift`、`ClaudeUsageBarApp.swift`；测试 `ProviderCoordinatorTests.swift`（新建）、`CodexProviderTests.swift`（追加）。

---

## Task 1: `ProviderCoordinator` —— 顺序 / 启用集 / menuBarProviderID / 容错 / setEnabled / moveProvider

**Files:** Create `Tests/.../ProviderCoordinatorTests.swift`；Modify `ProviderCoordinator.swift`、`CodexProvider.swift`（先加 `init(defaults:)` + 实例 `pollIntervalSeconds`，删 static 那个 —— Task 1 一并做以便 coordinator 用得上）。

- [x] **Step 1: 写 `ProviderCoordinatorTests.swift`（失败测试）**

```swift
import XCTest
@testable import ClaudeUsageBar

@MainActor
final class ProviderCoordinatorTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "coord-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)   // 干净起步
        return d
    }
    // 用真的 UsageService（不发网络）做 claude；codex 用真 CodexProvider（注入空 CODEX_HOME → unconfigured）。
    private func makeCoordinator(_ d: UserDefaults, withCodex: Bool = true) -> ProviderCoordinator {
        let claude = UsageService(defaults: d)   // 若 UsageService 无 defaults 参数，用 .standard 也行——测试只读 coordinator 行为
        let extras: [UsageProvider] = withCodex ? [CodexProvider(environment: [:], defaults: d)] : []
        return ProviderCoordinator(claude: claude, additionalProviders: extras, defaults: d)
    }

    func testDefaultOrderAndEnabled() {
        let c = makeCoordinator(defaults())
        XCTAssertEqual(c.orderedProviderIDs, ProviderID.allCases)            // 默认全 5 个（含占位）
        XCTAssertTrue(c.enabledProviderIDs.isSuperset(of: [.claude, .codex]))
        XCTAssertEqual(c.availableIDs, [.claude, .codex])                    // ordered ∩ registered ∩ enabled
    }
    func testReadStoredOrderFiltersAndAppends() {
        let d = defaults()
        d.set(["codex", "claude", "bogus", "gemini"], forKey: "providerOrder")
        let c = makeCoordinator(d)
        // bogus 被丢；缺的 cursor/copilot 接末尾（顺序：codex, claude, gemini, 然后补 cursor, copilot —— 任意补法都行，只断言：是 allCases 的一个排列、前 3 个是 codex,claude,gemini）
        XCTAssertEqual(Set(c.orderedProviderIDs), Set(ProviderID.allCases))
        XCTAssertEqual(Array(c.orderedProviderIDs.prefix(3)), [.codex, .claude, .gemini])
    }
    func testSetEnabledClaudeIsNoOp() {
        let c = makeCoordinator(defaults())
        c.setEnabled(.claude, false)
        XCTAssertTrue(c.enabledProviderIDs.contains(.claude))
    }
    func testDisablingCodexRemovesFromAvailable() {
        let c = makeCoordinator(defaults())
        c.setEnabled(.codex, false)
        XCTAssertFalse(c.availableIDs.contains(.codex))
        XCTAssertFalse(c.enabledProviderIDs.contains(.codex))
    }
    func testDisablingMenuBarProviderMovesIt() {
        let d = defaults(); d.set("codex", forKey: "primaryProviderID")
        let c = makeCoordinator(d)
        XCTAssertEqual(c.menuBarProviderID, .codex)        // 注册+enabled → 接受
        c.setEnabled(.codex, false)
        XCTAssertEqual(c.menuBarProviderID, .claude)       // 跳到首个 enabled+registered
    }
    func testMoveProviderPersists() {
        let d = defaults()
        let c = makeCoordinator(d)
        let first = c.orderedProviderIDs[0], second = c.orderedProviderIDs[1]
        c.moveProvider(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(c.orderedProviderIDs[0], second)
        XCTAssertEqual(c.orderedProviderIDs[1], first)
        XCTAssertEqual(d.stringArray(forKey: "providerOrder"), c.orderedProviderIDs.map(\.rawValue))
    }
    func testMenuBarProviderIDRejectsUnregistered() {
        let c = makeCoordinator(defaults())
        c.menuBarProviderID = .cursor                      // 未注册 → 拒绝
        XCTAssertEqual(c.menuBarProviderID, .claude)
    }
    func testMenuBarProviderIDRejectsDisabled() {
        let c = makeCoordinator(defaults())
        c.setEnabled(.codex, false)
        c.menuBarProviderID = .codex                       // 注册但 disabled → 拒绝
        XCTAssertEqual(c.menuBarProviderID, .claude)
    }
    func testInitFallbackOnIllegalStoredMenuBar() {
        let d = defaults(); d.set("gemini", forKey: "primaryProviderID")   // 未注册
        let c = makeCoordinator(d)
        XCTAssertEqual(c.menuBarProviderID, .claude)
    }
}
```

> 注：本 Task 还要**删掉 `CodexProviderTests` 里引用旧 API 的用例** —— `testCoordinatorPrimaryEligibleExcludesNonPollingProvider`（引用被删的 `coord.primaryEligibleIDs`/`coord.primaryProviderID`/`ProviderCoordinator.primaryProviderKey`）整个删掉（等价覆盖已搬到 `ProviderCoordinatorTests.testMenuBarProviderIDRejectsUnregistered/Disabled`）。`UsageService(defaults:)` 若不存在就用现成 `UsageService()`（这些测试不依赖它的内部状态，只断言 coordinator）。`CodexProvider(environment:[:], defaults:d)` 需要 Task 1 同步给 `CodexProvider` 加 `defaults:` 参数（见 Step 4）。`ProviderCoordinator(... defaults:)` 是 Task 1 新增的注入点。

- [x] **Step 2: 跑确认失败** — `cd /Users/methol/data/code-methol/usage-bar/macos && swift test --filter ProviderCoordinatorTests` → 编译失败（`ProviderCoordinator.init(claude:additionalProviders:defaults:)` / `orderedProviderIDs` / `enabledProviderIDs` / `menuBarProviderID` / `setEnabled` / `moveProvider` 不存在）。

- [x] **Step 3: 改 `ProviderCoordinator.swift`**

```swift
import Foundation

@MainActor
final class ProviderCoordinator: ObservableObject {
    let claude: UsageService
    let registry: ProviderRegistry
    private let defaults: UserDefaults

    // MARK: persistence keys
    static let menuBarProviderKey = "primaryProviderID"        // 沿用旧 key（老用户偏好）
    static let providerOrderKey   = "providerOrder"
    static let enabledProvidersKey = "enabledProviders"

    // MARK: provider 顺序（含占位）
    @Published var orderedProviderIDs: [ProviderID] {
        didSet { defaults.set(orderedProviderIDs.map(\.rawValue), forKey: Self.providerOrderKey) }
    }
    // MARK: 启用集（Claude 恒在）
    @Published private(set) var enabledProviderIDs: Set<ProviderID> {
        didSet {
            var s = enabledProviderIDs; s.insert(.claude)
            if s != enabledProviderIDs { enabledProviderIDs = s; return }   // re-enter 一次把 .claude 补上
            defaults.set(enabledProviderIDs.map(\.rawValue), forKey: Self.enabledProvidersKey)
            // 启用集变了 → menuBarProviderID 可能失效
            if !(enabledProviderIDs.contains(menuBarProviderID) && registry.isAvailable(menuBarProviderID)) {
                menuBarProviderID = firstMenuBarEligible()
            }
        }
    }
    // MARK: 菜单栏 provider（= 原 primaryProviderID）
    @Published var menuBarProviderID: ProviderID {
        didSet {
            guard !isRevertingMenuBar else { return }
            guard menuBarProviderID != oldValue else { return }
            guard enabledProviderIDs.contains(menuBarProviderID), registry.isAvailable(menuBarProviderID) else {
                isRevertingMenuBar = true; menuBarProviderID = oldValue; isRevertingMenuBar = false; return
            }
            defaults.set(menuBarProviderID.rawValue, forKey: Self.menuBarProviderKey)
        }
    }
    private var isRevertingMenuBar = false

    init(claude: UsageService, additionalProviders: [UsageProvider] = [], defaults: UserDefaults = .standard) {
        self.claude = claude
        self.defaults = defaults
        let registry = ProviderRegistry(providers: [claude] + additionalProviders)
        self.registry = registry

        // orderedProviderIDs：读盘 → 丢不在 allCases 里的（实际无）→ 末尾补漏掉的
        let storedOrder = (defaults.stringArray(forKey: Self.providerOrderKey) ?? [])
            .compactMap(ProviderID.init(rawValue:))
        var order = storedOrder.filter { ProviderID.allCases.contains($0) }
        var seen = Set(order)
        for id in registry.orderedIDs where !seen.contains(id) { order.append(id); seen.insert(id) }
        self.orderedProviderIDs = order.isEmpty ? registry.orderedIDs : order

        // enabledProviderIDs：读盘 → ∩ allCases → 强制含 .claude；没存过则默认全 allCases
        if let storedEnabled = defaults.stringArray(forKey: Self.enabledProvidersKey) {
            var s = Set(storedEnabled.compactMap(ProviderID.init(rawValue:))); s.insert(.claude)
            self.enabledProviderIDs = s
        } else {
            self.enabledProviderIDs = Set(ProviderID.allCases)
        }

        // menuBarProviderID：读盘 → 校验 ∈ enabled∩registered，否则首个合格的（最坏 .claude）
        let storedMenuBar = defaults.string(forKey: Self.menuBarProviderKey).flatMap(ProviderID.init(rawValue:))
        let registeredAvail = registry.availableIDs
        if let m = storedMenuBar, self.enabledProviderIDs.contains(m), registeredAvail.contains(m) {
            self.menuBarProviderID = m
        } else {
            // firstMenuBarEligible 用的是 self 上的属性，已全初始化 → 可调；但为安全直接内联：
            self.menuBarProviderID = orderedProviderIDs.first(where: { self.enabledProviderIDs.contains($0) && registeredAvail.contains($0) }) ?? .claude
        }
    }

    private func firstMenuBarEligible() -> ProviderID {
        orderedProviderIDs.first(where: { enabledProviderIDs.contains($0) && registry.isAvailable($0) }) ?? .claude
    }

    // MARK: mutators
    func setEnabled(_ id: ProviderID, _ on: Bool) {
        if id == .claude { return }                          // Claude 恒在
        if on { enabledProviderIDs.insert(id) } else { enabledProviderIDs.remove(id) }
    }
    func moveProvider(from source: IndexSet, to dest: Int) {
        orderedProviderIDs.move(fromOffsets: source, toOffset: dest)
    }

    // MARK: lookup
    func provider(_ id: ProviderID) -> UsageProvider? { registry.provider(id) }
    func runtime(for id: ProviderID) -> ProviderRuntime? { registry.provider(id)?.runtime }
    func isAvailable(_ id: ProviderID) -> Bool { registry.isAvailable(id) }            // = registered（保留语义）
    /// popover tab 用：已注册 + 已启用，按用户排序。
    var availableIDs: [ProviderID] { orderedProviderIDs.filter { registry.isAvailable($0) && enabledProviderIDs.contains($0) } }
    var menuBarRuntime: ProviderRuntime { registry.provider(menuBarProviderID)?.runtime ?? claude.runtime }

    func refreshNow(_ id: ProviderID) async { await registry.provider(id)?.refreshNow() }
}
```

（注意：`firstMenuBarEligible()` 在 `enabledProviderIDs.didSet` 里被调，那时 `orderedProviderIDs` / `registry` 都已初始化 —— OK。`enabledProviderIDs` 的 `didSet` 里既改 `menuBarProviderID` 又可能 re-enter 自己 —— re-enter 的那次 `s == enabledProviderIDs` 为 true 跳过、不无限递归。读现有文件确认没漏 import / 旧引用。）

- [x] **Step 4: 改 `CodexProvider.swift`（加 `defaults:` + 实例 `pollIntervalSeconds`，删 static + 自持 timer 留到 Task 5；本 Task 先把构造参数和计算属性加上）**

在 `CodexProvider` 里：
```swift
private let defaults: UserDefaults
// 删 `static let pollIntervalSeconds: TimeInterval = 300`，改成实例计算属性：
var pollIntervalSeconds: TimeInterval {
    let stored = defaults.integer(forKey: "pollingMinutes")
    let mins = UsageService.pollingOptions.contains(stored) ? stored : UsageService.defaultPollingMinutes
    return TimeInterval(mins * 60)
}
init(environment: [String: String] = ProcessInfo.processInfo.environment,
     session: URLSession = .shared,
     history: UsageHistoryService? = nil,
     defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // ... 其余不变
}
// startPolling() 里把 `Timer.publish(every: Self.pollIntervalSeconds, ...)` 暂改成 `Timer.publish(every: pollIntervalSeconds, ...)` —— Task 5 会整段撤掉自持 timer，本 Task 先保编译过。
```

- [x] **Step 5: 改各调用点编译过** — `ClaudeUsageBarApp.swift` 里 `coordinator.primaryRuntime` → `coordinator.menuBarRuntime`、`coordinator.primaryProviderID` → `coordinator.menuBarProviderID`；`ProviderCoordinator(claude:additionalProviders:)` 调用点（App + 测试）若没传 `defaults:` 用默认即可，不用改。`SettingsView.swift` 里 `$coordinator.primaryProviderID` / `coordinator.primaryEligibleIDs` 暂时会编译失败 —— Task 4 处理 Settings；本 Task 为了 build 过，先把 SettingsView 那个 Picker 临时改成读 `coordinator.menuBarProviderID` + `coordinator.availableIDs`（Task 4 再换成 Providers section）。`grep -rn "primaryProviderID\|primaryEligibleIDs\|primaryRuntime" macos/Sources/` → 只剩 `menuBarProviderKey = "primaryProviderID"` 这条字面量（持久化 key 沿用），无 `primaryEligibleIDs`/`primaryRuntime`/`@Published var primaryProviderID`；`grep ... macos/Tests/` 清掉旧引用（删 `testCoordinatorPrimaryEligibleExcludesNonPollingProvider`）。**注**：协议属性 `supportsBackgroundPolling` 留着不删（Codex `= false`、Claude `= true`）—— 本版它失去「primary 候选资格」用途、暂无消费者，加 `// TODO(后续): 这个 flag 现在没消费者了——要么彻底退役、要么改用途`；`CodexProviderTests.testSupportsBackgroundPollingIsFalse` 保留。

- [x] **Step 6: 跑确认通过** — `swift test --filter ProviderCoordinatorTests` → all PASS。

- [x] **Step 7: build + 全量 test** — `swift build -c release && swift test` → 全绿（既有测试不动）。

- [x] **Step 8: Commit**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/ClaudeUsageBar/{ProviderCoordinator,CodexProvider,ClaudeUsageBarApp,SettingsView}.swift macos/Tests/ClaudeUsageBarTests/{ProviderCoordinatorTests,CodexProviderTests}.swift
git commit -m "feat: v0.2.10 — ProviderCoordinator 长出 orderedProviderIDs/enabledProviderIDs/menuBarProviderID（原 primaryProviderID 改名，key 沿用）+ setEnabled/moveProvider + availableIDs=ordered∩registered∩enabled + 容错回退；CodexProvider 加 defaults: 注入 + 实例 pollIntervalSeconds（读 pollingMinutes） [spec:2026-05-12-settings-provider-list]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `UsageWindow.shortLabel` + Claude/Codex model 层填

**Files:** Modify `ProviderUsageSnapshot.swift`、`UsageModel.swift`、`CodexUsageModel.swift`；（`UsageModelTests` / `CodexUsageModelTests` 若有则确保不挂）。

- [x] **Step 1: 改 `ProviderUsageSnapshot.swift`** —— `UsageWindow` 加 `var shortLabel: String`，init 加 `shortLabel: String? = nil` 参数，body 里 `self.shortLabel = shortLabel ?? (label.map { String($0.prefix(2)) } ?? "")`。

- [x] **Step 2: 改 `UsageModel.swift`** —— `UsageBucket.asUsageWindow(label:windowDuration:)` 加 `shortLabel: String? = nil` 透传；`asProviderSnapshot()` 里 `fiveHour?.asUsageWindow(label: "Session", windowDuration: 5*60*60, shortLabel: "5h")`、`sevenDay?.asUsageWindow(label: "Weekly", ..., shortLabel: "7d")`（per-model extras 不用菜单栏 → 不填，默认取前 2 字符）。

- [x] **Step 3: 改 `CodexUsageModel.swift`** —— `win(_:_:)` 里 `UsageWindow(label: label, ..., )` 后加 shortLabel：session 窗 `"5h"`（Codex 的 session 也是 ~5h 类）、weekly 窗 `"7d"`。具体：把 `func win(_ w:, _ label:)` 改成 `func win(_ w:, _ label:, _ short: String)`，两个调用点传 `"5h"` / `"7d"`。

- [x] **Step 4: build + test** — `swift build -c release && swift test` → 全绿（`UsageWindow` 多个字段，`Equatable` 自动；若有断言精确比较 `UsageWindow(...)` 的旧测试需补 `shortLabel:` —— 跑一遍看哪挂了再补）。

- [x] **Step 5: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/{ProviderUsageSnapshot,UsageModel,CodexUsageModel}.swift macos/Tests/ClaudeUsageBarTests/*
git commit -m "feat: v0.2.10 — UsageWindow 加 shortLabel（≤3 字符菜单栏用，默认取 label 前 2 字符）；Claude 5h/7d、Codex Session/Weekly 各填短名 [spec:2026-05-12-settings-provider-list]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 菜单栏 provider-aware（`MenuBarIconRenderer` + `MenuBarLabel`）

**Files:** Modify `MenuBarIconRenderer.swift`、`MenuBarLabel.swift`、`ClaudeUsageBarApp.swift`；（`MenuBarLabelTests` / renderer 测试若有则确保不挂）。

- [x] **Step 1: 改 `MenuBarIconRenderer.swift`**
  - `cachedLabels` 改成动态：把 `for label in ["5h", "7d"]` 预生成的 dict 改成一个 `func cachedLabel(_ s: String) -> CachedLabel`（按需生成 + 进 cache dict，加锁或就接受偶发重算 —— 菜单栏 label 集合很小、调用在 main，直接用一个 `var` dict 即可）。
  - `drawClaudeLogo(x:y:size:)` → `drawProviderGlyph(for providerID: ProviderID, x:y:size:)`：`case .claude:` 走现有 `claudeLogoImage.draw(...)`（字节不变）；`default:` 用 SF Symbol 渲染成 template image —— `let name = providerID == .codex ? "terminal" : "circle"; if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium)) { img.isTemplate = true; img.draw(in: NSRect(x:x,y:y,width:size,height:size)) }`（SF Symbol 在 macOS 11+ 有；`NSImage(systemSymbolName:)` macOS 11+ —— app target 14+ OK）。
  - `renderIcon(pct5h:pct7d:)` → `renderIcon(providerID: ProviderID, primaryLabel: String, secondaryLabel: String, pct5h: Double, pct7d: Double)`：里面 `drawClaudeLogo(...)` → `drawProviderGlyph(for: providerID, ...)`；`drawRow(label: "5h", ...)` → `drawRow(label: primaryLabel, ...)`、`drawRow(label: "7d", ...)` → `drawRow(label: secondaryLabel, ...)`。`renderUnauthenticatedIcon()` → `renderUnauthenticatedIcon(providerID: ProviderID, primaryLabel: String, secondaryLabel: String)` 同样改。

- [x] **Step 2: 改 `MenuBarLabel.swift`** —— 加 `var providerID: ProviderID`；`iconView` 调 renderer 时传 `providerID: providerID, primaryLabel: shortPrimary, secondaryLabel: shortSecondary`，其中 `shortPrimary = runtime.snapshot?.primaryWindow?.shortLabel ?? "5h"`、`shortSecondary = runtime.snapshot?.secondaryWindow?.shortLabel ?? "7d"`；`percentText` 里 `formatMenuBarPercent(..., prefix: "5h")` 的 `"5h"` 改成 `shortPrimary`（保持一致）。其余不动（`trend` / `showTrend` 不变）。

- [x] **Step 3: 改 `ClaudeUsageBarApp.swift`** —— `MenuBarLabel(runtime: coordinator.menuBarRuntime, historyService: historyService, showTrend: coordinator.menuBarProviderID == .claude, providerID: coordinator.menuBarProviderID)`（注意：`MenuBarLabel` 现在依赖 `coordinator.menuBarProviderID` 这个 `@Published` —— `coordinator` 在 `MenuBarExtra { } label: { }` 里需作为 `@ObservedObject` 可观察，已是 `@StateObject coordinator` → OK）。

- [x] **Step 4: build + test** — `swift build -c release && swift test` → 全绿。

- [x] **Step 5: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/{MenuBarIconRenderer,MenuBarLabel,ClaudeUsageBarApp}.swift macos/Tests/ClaudeUsageBarTests/*
git commit -m "feat: v0.2.10 — 菜单栏 provider-aware：drawClaudeLogo→drawProviderGlyph(for:)（Claude PNG / 其它 SF Symbol）；renderIcon 加 providerID + 窗口短标签（从 snapshot.shortLabel）；MenuBarLabel 加 providerID 入参 [spec:2026-05-12-settings-provider-list]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Settings「Providers」section + 删 Account 区

**Files:** Modify `SettingsView.swift`。无新单测（纯 SwiftUI 组合，靠 build + manual_checks）。

- [x] **Step 1: 改 `SettingsView.swift`**
  - 删「Primary Provider」`Picker`（连同 `if coordinator.primaryEligibleIDs.count <= 1 { Text(...) }`，以及 Task 1 Step 5 临时塞的那版）。
  - 删最底下 `if service.isAuthenticated { Section("Account") { ... } }` 整块。
  - 在 `Section("General") { ... }` 之后、`Section("Notifications") { ... }` 之前，加：
```swift
Section("Providers") {
    List {
        ForEach(coordinator.orderedProviderIDs) { id in
            let registered = coordinator.isAvailable(id)
            HStack {
                Text(id.displayName).foregroundStyle(registered ? .primary : .secondary)
                if !registered { Text("coming soon").font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { coordinator.enabledProviderIDs.contains(id) },
                    set: { coordinator.setEnabled(id, $0) }
                ))
                .labelsHidden()
                .disabled(id == .claude || !registered)
                Button {
                    coordinator.menuBarProviderID = id
                } label: {
                    Image(systemName: coordinator.menuBarProviderID == id ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.borderless)
                .help("在菜单栏显示这个供应商")
                .disabled(!coordinator.enabledProviderIDs.contains(id) || !registered)
            }
        }
        .onMove { coordinator.moveProvider(from: $0, to: $1) }
    }
    .frame(minHeight: CGFloat(coordinator.orderedProviderIDs.count) * 28)   // List 在 Form 里要给高度
    Text("✓ = 在菜单栏显示；开关 = 是否启用该供应商的 tab 与后台刷新。拖动重排。")
        .font(.caption).foregroundStyle(.secondary)
}
```
  - **Fallback（若拖不动）**：`swift build` + 跑起来看 Settings 里 Providers section 能否拖（`make install` 后开 Settings）。若 `.onMove` 在 grouped `Form` 里不出拖动手柄：在每行 `Spacer()` 前加 `VStack { Button { coordinator.moveProvider(from: IndexSet(integer: idx), to: max(idx-1,0)) } label: { Image(systemName: "chevron.up") }.disabled(idx==0); Button { coordinator.moveProvider(from: IndexSet(integer: idx), to: idx+2) } label: { Image(systemName: "chevron.down") }.disabled(idx==coordinator.orderedProviderIDs.count-1) }.buttonStyle(.borderless).imageScale(.small)`（`idx = coordinator.orderedProviderIDs.firstIndex(of: id)!`），并去掉 `.onMove`。done 判据相同（能改顺序 + `coordinator.orderedProviderIDs` + `UserDefaults["providerOrder"]` 更新）。本 plan 先按 `.onMove` 写，manual check 失败再降级。

- [x] **Step 2: build** — `swift build -c release` → OK。

- [x] **Step 3: Commit**（先不 install，Task 6 统一 install + 验拖动）

```bash
git add macos/Sources/ClaudeUsageBar/SettingsView.swift
git commit -m "feat: v0.2.10 — Settings 删 Primary Provider 下拉 + 删 Account section；加 Providers section（List + .onMove 拖动排序 + 每行 Enabled toggle（Claude 恒开）+ 菜单栏单选 ✓）[spec:2026-05-12-settings-provider-list]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 刷新纪律 + coordinator 统管非-Claude 后台 timer + Sign Out 迁 popover

**Files:** Modify `ProviderCoordinator.swift`、`PopoverView.swift`、`ProviderTabBar.swift`、`CodexProvider.swift`、`ClaudeUsageBarApp.swift`；`ProviderCoordinatorTests.swift`（追加）；`CodexProviderTests.swift`（追加）。

- [x] **Step 1: 写失败测试（追加到 `ProviderCoordinatorTests.swift`）**

```swift
    func testRefreshAllEnabledOnOpen_codexRefreshedClaudeOnlyIfEmpty() async {
        // claude 已有 snapshot（模拟成功过一次）vs 没有；codex 总是被 refreshNow
        // 用真 UsageService / CodexProvider 不好控 snapshot —— 改用一组 fake provider 注入 coordinator。
        // 见下方 FakeProvider；用 init(claude:additionalProviders:defaults:) 传 fake claude 不行（claude 类型固定 UsageService）
        // —— 所以这条测试改成断言 onBackgroundTick / refreshAllEnabledOnOpen 对 codex(fake) 的行为，claude 的兜底逻辑用「snapshot==nil 时 claude.runtime.snapshot 仍 nil」间接验证。
        // 简化：只断言 codex(真 CodexProvider，environment 空 → refreshNow 走 unconfigured 分支不发网络) 被「调用过」——
        // 给 CodexProvider 加一个测试可见的 `refreshNowCallCount`？侵入太大。
        // 折中：本测试仅断言 `availableIDs` 里非-Claude 的会被 refreshAllEnabledOnOpen 遍历到（不实际验证副作用）——
        // 真正的「Claude 仅 snapshot==nil 时拉」靠 onBackgroundTick 的 fake spy 测（下一条）。
        let c = makeCoordinator(defaults())
        await c.refreshAllEnabledOnOpen()        // 不崩、不发网络（codex unconfigured）即可
    }
```

> ⚠️ 实施备注：`refreshAllEnabledOnOpen` / `onBackgroundTick` 的「Claude 仅 snapshot==nil 时拉」「非-Claude 都拉」最干净的测法是用 spy provider。但 `ProviderCoordinator.claude` 类型固定是 `UsageService`，没法塞 fake claude。两个可行路径：(a) 在 `ProviderCoordinator` 里把「要不要拉 Claude」抽成 `var shouldRefreshClaudeOnOpen: Bool { claude.runtime.snapshot == nil }`，单测可断言这个布尔（不实际触发 refresh）；(b) 给 `UsageProvider` spy 化 codex，断言其 `refreshNow` 被调次数。**实施时选 (a)**（最小侵入）：`refreshAllEnabledOnOpen` 内部 `if shouldRefreshClaudeOnOpen { await claude.refreshNow() }`；测 `shouldRefreshClaudeOnOpen`（真 `UsageService` 全新实例 → `runtime.snapshot == nil` → true）。`onBackgroundTick()` 的「不碰 Claude」靠「它的代码里根本没引用 claude.refreshNow」+ code review 保证（这部分不强求单测）。`CodexProvider` 被纳入 backgroundTimer 的验证：断言 `coordinator.availableIDs.contains(.codex)`（= 会被 tick 遍历到）+ `coordinator` 起 timer 后 `c.backgroundIntervalSeconds == TimeInterval(30*60)`（默认）、改 `defaults.set(5, forKey:"pollingMinutes")` 后 `c.backgroundIntervalSeconds == 300`。把这些写成具体断言：

```swift
    func testBackgroundIntervalFollowsPollingMinutes() {
        let d = defaults()
        let c = makeCoordinator(d)
        XCTAssertEqual(c.backgroundIntervalSeconds, TimeInterval(30 * 60))
        d.set(5, forKey: "pollingMinutes")
        XCTAssertEqual(c.backgroundIntervalSeconds, TimeInterval(5 * 60))
        d.set(7, forKey: "pollingMinutes")            // 非法 → 30
        XCTAssertEqual(c.backgroundIntervalSeconds, TimeInterval(30 * 60))
    }
    func testShouldRefreshClaudeOnOpenWhenSnapshotNil() {
        let c = makeCoordinator(defaults())
        XCTAssertTrue(c.shouldRefreshClaudeOnOpen)     // 全新 UsageService → runtime.snapshot == nil
    }
    func testOnBackgroundTickRefreshesCodexNotClaude() async {
        // 用真 CodexProvider（environment 空 → refreshNow 不发网络、走 unconfigured/clear）
        // 断言 onBackgroundTick() 调用不崩 + claude.runtime.snapshot 仍 nil（没被 tick 拉过）
        let c = makeCoordinator(defaults())
        c.onBackgroundTick()
        // 让 Task { await provider.refreshNow() } 跑完
        await Task.yield(); try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(c.claude.runtime.snapshot)        // 后台 tick 不碰 Claude
    }
```

- [x] **Step 2: 跑确认失败** — `swift test --filter ProviderCoordinatorTests` → 编译失败（`backgroundIntervalSeconds` / `shouldRefreshClaudeOnOpen` / `onBackgroundTick` / `refreshAllEnabledOnOpen` 不存在）。

- [x] **Step 3: 改 `ProviderCoordinator.swift`（加刷新纪律 + 后台 timer）**

```swift
import Foundation
import Combine
// ... 在 class 里加：

    private var backgroundTimer: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var lastBackgroundInterval: TimeInterval = 0

    var backgroundIntervalSeconds: TimeInterval {
        let stored = defaults.integer(forKey: "pollingMinutes")
        let mins = UsageService.pollingOptions.contains(stored) ? stored : UsageService.defaultPollingMinutes
        return TimeInterval(mins * 60)
    }
    var shouldRefreshClaudeOnOpen: Bool { claude.runtime.snapshot == nil }

    /// popover 打开（视图首次 appear）触发一次：非-Claude 各拉一次；Claude 仅在首屏空时兜一次。
    func refreshAllEnabledOnOpen() async {
        for id in availableIDs where id != .claude { await registry.provider(id)?.refreshNow() }
        if shouldRefreshClaudeOnOpen { await claude.refreshNow() }
    }

    /// 装配处调用：起统一后台 timer（非-Claude 的），并为 Codex 设好 onPollTick→codexStats.refresh（回调由 App 传入）。
    func startBackgroundPolling(codexOnPollTick: @escaping @MainActor () -> Void) {
        if let codex = registry.provider(.codex) as? CodexProvider { codex.onPollTick = codexOnPollTick }
        rescheduleBackgroundTimer()
        onBackgroundTick()                                    // 立即一次
        // pollingMinutes 变了重起
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.backgroundIntervalSeconds != self.lastBackgroundInterval { self.rescheduleBackgroundTimer() }
        }
    }
    private func rescheduleBackgroundTimer() {
        backgroundTimer?.cancel()
        lastBackgroundInterval = backgroundIntervalSeconds
        backgroundTimer = Timer.publish(every: lastBackgroundInterval, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.onBackgroundTick() }
    }
    /// 一次后台 tick（internal 以便单测调）：非-Claude enabled provider 各 refreshNow + onPollTick。
    func onBackgroundTick() {
        for id in availableIDs where id != .claude {
            guard let p = registry.provider(id) else { continue }
            Task { await p.refreshNow() }
            // onPollTick 是 CodexProvider 上的属性 —— 走具体类型；其它 provider 暂无此 hook
            (p as? CodexProvider)?.onPollTick?()
        }
    }
```

（`NotificationCenter` observer 在 coordinator 生命周期 = app 生命周期，不显式 remove —— 与既有 timer 同理。`UserDefaults.didChangeNotification` 比对 `lastBackgroundInterval` 避免每次任意 key 改都重起。）

- [x] **Step 4: 改 `CodexProvider.swift`** —— 撤掉自持 timer：删 `private var pollCancellable: AnyCancellable?` / `var isPolling: Bool { ... }`；`startPolling()` 改成只「立即拉一次 + onPollTick 一次」（不再 `Timer.publish`）—— 实际上 `startPolling()` 现在已无人调（App 改调 `coordinator.startBackgroundPolling`）；保留它作 no-arg「立即拉一次」也行，或干脆删掉并让 coordinator 的 `onBackgroundTick()` 立即那次代劳。**实施挑：删 `startPolling()` 整个方法**（coordinator 接管），把 `import Combine` 若不再用也删。同步删 `CodexProviderTests.testStartPollingIsIdempotent`（引用没了的 `startPolling`/`isPolling`）及任何断言 `isPolling` 的用例；`testSupportsBackgroundPollingIsFalse` 保留。

- [x] **Step 5: 改 `PopoverView.swift`**
  - 删 `.task(id: selectedProvider) { guard selectedProvider != .claude, coordinator.isAvailable(selectedProvider) else { return }; await coordinator.refreshNow(selectedProvider) }`。
  - 加 `.task { await coordinator.refreshAllEnabledOnOpen() }`（无 id）。
  - `ProviderTabBar(selection: $selectedProvider, availableIDs: coordinator.availableIDs)` —— `availableIDs` 现在是 enabled∩registered∩ordered。
  - `providerArea`：把 `else if coordinator.isAvailable(selectedProvider), let runtime = ...` 改成 `else if coordinator.availableIDs.contains(selectedProvider), let runtime = coordinator.runtime(for: selectedProvider)`（即「注册 + 启用」才渲染用量区）；最后那个 `else { ProviderComingSoonView(...) }` 保留（现在几乎走不到 —— 只有 selectedProvider 被禁用后短暂出现）。加一个 `.onChange(of: coordinator.availableIDs) { ids in if !ids.contains(selectedProvider) { selectedProvider = .claude } }`（用户禁用当前 tab → 回退）。
  - `bottomBar`：在 `Refresh` 按钮之后、`Check for Updates…` 之前（或 `Quit` 之前）加 `if claude.isAuthenticated { Button("Sign Out") { claude.signOut() }.buttonStyle(.borderless).font(.caption) }`。
  - `.task(id:)` 删了之后，`import` 不变。

- [x] **Step 6: 改 `ProviderTabBar.swift`** —— `ForEach(ProviderID.allCases)` → `ForEach(availableIDs, id: \.self)`；`pillForeground(for:)` 里 `availableIDs.contains(provider)` 那个分支恒 true 了 —— 简化成「选中=primary、否则=secondary」（不再有「占位 provider」的 0.5 透明态，因为占位的不在 `availableIDs` 里了）。

- [x] **Step 7: 改 `ClaudeUsageBarApp.swift`** —— `.task` 里把
```swift
if let codex = coordinator.provider(.codex) as? CodexProvider {
    codex.onPollTick = { Task.detached { await codexStats.refresh() } }
    codex.startPolling()
}
```
改成
```swift
coordinator.startBackgroundPolling(codexOnPollTick: { Task.detached { await codexStats.refresh() } })
```
（`coordinator.claude.startPolling()` 那行 —— Claude 的 —— 不动。）**注**：spec §3.1 写的是无参 `coordinator.startBackgroundPolling()`，但 coordinator 够不到 `codexStats` 这个 `@StateObject` —— 本 plan 有意改成 `startBackgroundPolling(codexOnPollTick:)` 由 App 注入回调。

- [x] **Step 8: 跑确认通过** — `swift test --filter ProviderCoordinatorTests` + `--filter CodexProviderTests` → all PASS（`CodexProviderTests` 里若有断言 `isPolling` / `startPolling` 的，删掉或改 —— spec SC6 说退役 `isPolling`）。

- [x] **Step 9: build + 全量 test** — `swift build -c release && swift test` → 全绿。

- [x] **Step 10: Commit**

```bash
git add macos/Sources/ClaudeUsageBar/{ProviderCoordinator,CodexProvider,PopoverView,ProviderTabBar,ClaudeUsageBarApp}.swift macos/Tests/ClaudeUsageBarTests/{ProviderCoordinatorTests,CodexProviderTests}.swift
git commit -m "feat: v0.2.10 — 刷新纪律：删切-tab-自动刷新、popover 打开调 refreshAllEnabledOnOpen（非-Claude 各拉一次、Claude 仅首屏空时兜）；ProviderCoordinator 统管非-Claude 后台 timer（onBackgroundTick + 监听 pollingMinutes 重起），撤 CodexProvider 自持 timer；Sign Out 迁 popover 底栏；ProviderTabBar 改吃 availableIDs [spec:2026-05-12-settings-provider-list]

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 全量验收 + 回填文档（G6）

- [x] **Step 1: build + test + artifacts + verify**

```bash
cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release && swift test
cd /Users/methol/data/code-methol/usage-bar && make release-artifacts && bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip
grep -rn "primaryProviderID\|primaryEligibleIDs\|primaryRuntime" macos/Sources/   # 期望：只剩 menuBarProviderKey = "primaryProviderID"（持久化 key 沿用），无 primaryEligibleIDs/primaryRuntime
```
Expected: build OK；全部 tests PASS；zip/dmg 产出 + verify「Release archive looks good」。

- [x] **Step 2: `make install` + 手动 smoke** —
  - Settings → Providers section：拖动 Claude/Codex 重排（**拖不动 → 走 Task 4 Step 1 的 ↑/↓ fallback**，改完重 build/test/commit）；Codex 关掉 Enabled → popover 顶 tab 不再有 Codex、Codex 后台刷新停；Claude 的 Enabled 禁用；点 Codex 行 ✓ → 菜单栏变 Codex 图标（SF Symbol terminal）+ Codex 窗口 %；点回 Claude ✓ → 恢复 Claude logo + 5h/7d。
  - Settings 最底下无「Account」；popover 底栏有「Sign Out」（已登录时）。
  - Polling Interval 改 5min → Codex 后台刷新跟随（看 Codex tab 的 Updated 时间）。
  - 打开 popover → 各 enabled provider 拉一次（先显缓存）；tab 间来回切 → 不重拉；点底栏 Refresh → 当前 tab provider 重拉。
  把观察记进 spec evidence + Verification log。

- [x] **Step 3: 回填 spec/version** — `2026-05-12-settings-provider-list.md`：`spec_criteria[].done` 全 true + 填 evidence、Verification log 全勾、`status: accepted → implemented`、`updated` 同步、append G5 verdict（Task 7 后）。`docs/versions/v0.2.10-settings-provider-list.md`：`status: planned → in-progress`、填 `release_notes_zh`（改进：Settings 改 provider 列表（拖动+开关+菜单栏单选）、去 Account 区、Codex 用统一 polling interval、切 tab 不再触发刷新；内部：ProviderCoordinator 统管顺序/启用集/菜单栏 provider/非-Claude timer、菜单栏 provider-aware）、G6 checklist 勾。`docs/versions/README.md` + `docs/superpowers/specs/README.md` 同步状态。本 plan 勾掉步骤（除 Task 7 的 G5/PR）。Commit。

- [ ] **Step 4: G5 + PR + merge** — 独立 reviewer（codex `codex-rescue` / `general-purpose` subagent）code-review + light security-review（敏感面小：纯 Settings/coordinator/UI，不读新文件、不动凭证；唯一注意点：`enabledProviderIDs` 持久化的是 provider 名字符串，无敏感信息）。verdict approved/approved-with-nits 后 `gh pr create`（中文，含 spec id + version 链接），等 CI（"build" job）绿 → `git checkout main && git merge --ff-only feat/v0.2.10-settings-provider-list && git push origin main` + 删分支。G5 verdict append 进 spec `reviews:`。`make install` 装最终 main。

---

## Self-Review

- **Spec coverage**：SC1→Task1；SC2→Task4（Providers section + 删 Account）+ Task5 Step5（Sign Out 迁 popover）；SC3→Task2（shortLabel）+ Task3（renderer/MenuBarLabel）；SC4→Task1 Step4（CodexProvider 实例 pollIntervalSeconds + defaults:）+ Task5 Step4（撤自持 timer）；SC5→Task5 Step5（删 .task(id:) + 加无 id .task + ProviderTabBar + onChange 回退 + Sign Out）；SC6→Task5 Step3/7（coordinator backgroundTimer + onBackgroundTick + 监听 pollingMinutes + App 改调 startBackgroundPolling）；SC7→贯穿（每个 Task 末「全量 test」守既有全绿 + UsageService 字节不变 + key 沿用）；SC8→各 Task 的 build/test（含 `ProviderCoordinatorTests`/`CodexProviderTests` 改动）+ Task6 Step1；「切 tab 不刷新」子项无单测、靠 G5 code-review（删 `.task(id:)` 后结构性成立）。
- **Placeholder scan**：关键代码（`ProviderCoordinator` 的新成员全文、`ProviderCoordinatorTests` 主要 case、Settings Providers section、renderer 改法）已给出；机械的小改（`UsageWindow.shortLabel` 透传、各调用点改名、`ProviderTabBar` 的 ForEach 换源）以「读现有 X 照改 Y」+ spec §3.1 描述代替 —— 每条说清了改哪行成什么，不是 placeholder。
- **风险点已标注**：Task1 的 `enabledProviderIDs.didSet` re-enter 自己 + 改 `menuBarProviderID`（已 callout 不无限递归）；Task4 的 `Form` 里 `List + .onMove` 能不能拖（已给 ↑/↓ fallback + manual check）；Task5 的「Claude 仅 snapshot==nil 时拉」测法（已 callout 选 `shouldRefreshClaudeOnOpen` 布尔最小侵入）；`MenuBarLabel` 依赖 `coordinator.menuBarProviderID` 这个 @Published（已 callout coordinator 是 @StateObject 可观察）。
- **Type consistency**：`orderedProviderIDs: [ProviderID]` / `enabledProviderIDs: Set<ProviderID>` / `menuBarProviderID: ProviderID` / `setEnabled(_:_:)` / `moveProvider(from:to:)` / `availableIDs`(重定义) / `menuBarRuntime` / `refreshAllEnabledOnOpen()` / `shouldRefreshClaudeOnOpen` / `backgroundIntervalSeconds` / `onBackgroundTick()` / `startBackgroundPolling(codexOnPollTick:)`（coordinator）；`CodexProvider.init(environment:session:history:defaults:)` / 实例 `pollIntervalSeconds`（删 static）/ 删 `pollCancellable`/`isPolling`/`startPolling`；`UsageWindow.shortLabel`（init `shortLabel: String? = nil`）；`UsageBucket.asUsageWindow(label:windowDuration:shortLabel:)`；`MenuBarIconRenderer.renderIcon(providerID:primaryLabel:secondaryLabel:pct5h:pct7d:)` / `renderUnauthenticatedIcon(providerID:primaryLabel:secondaryLabel:)` / `drawProviderGlyph(for:x:y:size:)`；`MenuBarLabel.providerID`；`ProviderTabBar` 不改签名（`availableIDs` 来源换）—— 各 Task 间一致。
