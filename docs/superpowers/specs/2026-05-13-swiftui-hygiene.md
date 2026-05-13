---
id: 2026-05-13-swiftui-hygiene
title: SwiftUI hygiene：3 处 high bug + low 清理 + 死代码下线
status: implemented
created: 2026-05-13
updated: 2026-05-13
owner: claude-code
model: claude-opus-4-7
target_version: v0.3.1
related_adrs: []
related_research: []
spec_criteria:
  - id: SC1
    criterion: "UsageChartView 的 chartOverlay 不再使用 plotFrame! 强解包；plotFrame 为 nil 时 hoverDate 被设回 nil，不引入崩溃路径"
    done: true
    evidence: "UsageChartView.swift:202-210 改 guard let plot = proxy.plotFrame else { hoverDate = nil; return }；commit ad6fb27"
  - id: SC2
    criterion: "UsageHeatmapModel 改为 @State 缓存 + onChange(of: daySpends) 重建；body 重渲染不再每次重算 53×7 网格"
    done: true
    evidence: "UsageHeatmapView.swift: @State private var model + init 初始化 + body 末 .onChange(of: daySpends) { _, newValue in model = UsageHeatmapModel(daySpends: newValue) }；commit ad6fb27"
  - id: SC3
    criterion: "LocalCostCard 的展开/收起从 onTapGesture 改为 Button + .buttonStyle(.plain)，VoiceOver 可识别为按钮"
    done: true
    evidence: "LocalCostCard.swift: var body 顶层包 Button { withAnimation(...) { expanded.toggle() } } label: { VStack {...} } + .buttonStyle(.plain) + .accessibilityLabel + .accessibilityHint；commit ad6fb27"
  - id: SC4
    criterion: "UsageService.swift:766 的 Task.sleep(nanoseconds:) 替换为 Task.sleep(for:)；UsageService 类加 final"
    done: true
    evidence: "UsageService.swift:6 class → final class；UsageService.swift:766 Task.sleep(nanoseconds: 100_000_000) → Task.sleep(for: .milliseconds(100))；commit 165b1fb"
  - id: SC5
    criterion: "[撤回] 原计划去掉 ForEach(Array(seq.enumerated())) 的外层 Array(...) — 实测发现 SwiftUI ForEach 要求 RandomAccessCollection，而 Swift 标准库 Sequence.enumerated() 返回的 EnumeratedSequence 不符合该协议，外层 Array(...) 必须保留"
    done: true
    evidence: "撤回：编译错误 'Generic struct ForEach requires that EnumeratedSequence<[ProviderID]> conform to RandomAccessCollection'（MultiMenuBarLabel.swift:36）"
  - id: SC6
    criterion: "UsageBarApp.swift 的 Task.detached { await usageStats.refresh() } 改为 Task { ... }（usageStats.refresh 内部已自管 Task.detached）"
    done: true
    evidence: "UsageBarApp.swift:51,52 两处 Task.detached 改 Task；UsageService.swift:42 同步注释；commit 165b1fb"
  - id: SC7
    criterion: "CreditLine.currencyCode 字段及全部赋值点删除；grep 验证 currencyCode 0 命中"
    done: true
    evidence: "ProviderUsageSnapshot.swift 删字段 + init 参数 + self.currencyCode 赋值；CodexUsageModel.swift:131 + UsageModel.swift:252 删两处实参；grep -rn 'currencyCode' macos/Sources macos/Tests = 0 hits；commit bfd063f"
  - id: SC8
    criterion: "UsageProvider.supportsBackgroundPolling 协议成员 + 2 个 conformer impl + 4 处测试断言全部清理；grep 验证 supportsBackgroundPolling 0 命中"
    done: true
    evidence: "UsageProvider.swift 删协议成员 + TODO 注释；CodexProvider.swift:14 + UsageService.swift:868 删 impl；3 处测试 stub（CodexProviderTests:253、ProviderCoordinatorTests:199、ProviderAbstractionTests:237）+ 独立 test method testSupportsBackgroundPollingIsFalse 全删；CodexProviderTests:309 历史注释保留并 append v0.3.1 退役说明；grep -rn 'supportsBackgroundPolling' macos/Sources = 0 hits；commit bfd063f"
  - id: SC9
    criterion: "swift build -c release 与 swift test 均绿"
    done: true
    evidence: "swift build -c release: Build complete!（10.18s）；swift test: 272 passed, 0 failures（少 1 = 删掉的 testSupportsBackgroundPollingIsFalse，预期）"
  - id: SC10
    criterion: "make release-artifacts 与 verify-release.sh 全绿（含 litellm_model_prices.json / THIRD_PARTY_LICENSES.txt invariant）"
    done: true
    evidence: "make release-artifacts: UsageBar.zip + UsageBar.dmg 都成功；verify-release.sh 对 zip 与 dmg 各跑一次都 Release archive looks good"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release 2>&1 | tail -5"
  - "SC_AUTO_TEST: cd macos && swift test 2>&1 | tail -20"
  - "SC_AUTO_NO_CURRENCYCODE: grep -rn 'currencyCode' macos/Sources macos/Tests | wc -l   # 期望 0"
  - "SC_AUTO_NO_SUPPORTSBGPOLL: grep -rn 'supportsBackgroundPolling' macos/Sources macos/Tests | wc -l   # 期望 0"
  - "SC_AUTO_NO_NANOSLEEP: grep -rn 'Task.sleep(nanoseconds:' macos/Sources | wc -l   # 期望 0"
  - "SC_AUTO_RELEASE: make release-artifacts && bash macos/scripts/verify-release.sh macos/UsageBar.zip"
manual_checks:
  - "SC1 手动：popover 打开后切 provider tab、hover chart 区域反复触发 → 无 plotFrame 崩溃"
  - "SC2 手动：popover 打开 → 鼠标在 heatmap 上反复 hover → 视觉不卡顿（macOS Activity Monitor app CPU 应保持低位）"
  - "SC3 手动：开 VoiceOver → 焦点切到 LocalCostCard → 应朗读为按钮，可 VO+Space 切展开/收起"
  - "金路径手动回归：菜单栏图标显示正常 → popover 切 Claude/Codex tab → SettingsView 各开关与拖拽生效"
reviews: []
---

# SwiftUI hygiene：3 处 high bug + low 清理 + 死代码下线

## 1. 背景与目标

v0.3.0 Provider 自主管理 merge 后，对全仓 50 个 Swift 文件做了一次 SwiftUI 现代化 audit（macOS 14+ / Swift 5.9 约束），整体观感很干净：没有任何已弃 API（`foregroundColor` / `cornerRadius` / 单参 `onChange` 等都已经规范）。但 audit 抓到 3 个真正影响**正确性 / 性能 / 可访问性**的 high 问题，外加一批 low hygiene 问题以及 1 个死字段 + 1 个死协议成员。

本 spec 把"非架构改动、风险最低、立刻能合并"的部分一次性收掉；**不**触动 `ObservableObject → @Observable` 迁移（留 v0.5.0）、**不**触动 SettingsView Binding 重构与 PopoverView ViewBuilder 抽 struct（留 v0.4.0）。

详细 audit 报告见对话上下文，本 spec 只列结论与处置。

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 范围切分 | 仅 hygiene + 死代码，不动 Binding / @Observable | 风险隔离；高频回归只跑一次 |
| `plotFrame!` 修复 | 改 `guard let plot = proxy.plotFrame else { hoverDate = nil; return }` | 最小侵入；保留现有 GeometryReader 拓扑（彻底替换为 chartOverlay-only API 留 v0.4.0） |
| `UsageHeatmapModel` 缓存 | `@State` + `onChange(of: daySpends)` 重建 | 与现有 SwiftUI 数据流对齐；不引入 task / actor 复杂度 |
| `LocalCostCard` 可访问 | `Button + .buttonStyle(.plain)` 包整张卡 | accessibility.md 推荐；视觉零变化 |
| `supportsBackgroundPolling` 退役 | 协议本体 + impl + 测试断言一并清理 | 已 6 个版本无人读；保留只增加未来误用风险 |
| `currencyCode` 字段 | 直接删除 | 仅 Codex 写 "USD" / Claude 写 nil，UI 写死 `$`；未来要做多币种再重加 |
| 不引入新依赖 | ✅ | 严守 CLAUDE.md 守护线 |

## 3. 设计

### 3.1 UsageChartView.swift — plotFrame guard（high）

定位：`macos/Sources/UsageBar/UsageChartView.swift:196-212` 的 `chartOverlay { proxy in GeometryReader { geo in ... } }` 内有 `geo[proxy.plotFrame!]` 强解包。`plotFrame` 在 chart 还未完成首次布局、或在 Swift Charts 内部重渲染瞬间会是 `nil`，hover 时踩到即崩。

最小 fix：

```swift
// Before
case .active(let location):
    let plotOrigin = geo[proxy.plotFrame!].origin
    let x = location.x - plotOrigin.x
    if let date: Date = proxy.value(atX: x) { hoverDate = date }
case .ended:
    hoverDate = nil

// After
case .active(let location):
    guard let plot = proxy.plotFrame else {
        hoverDate = nil
        return
    }
    let plotOrigin = geo[plot].origin
    let x = location.x - plotOrigin.x
    if let date: Date = proxy.value(atX: x) { hoverDate = date }
case .ended:
    hoverDate = nil
```

不动 `chartOverlay { GeometryReader { ... } }` 的整体结构（彻底切现代 chartOverlay-only API 留 v0.4.0）。

### 3.2 UsageHeatmapView.swift — model 缓存（high，性能）

定位：`macos/Sources/UsageBar/UsageHeatmapView.swift:86`：

```swift
private var model: UsageHeatmapModel { UsageHeatmapModel(daySpends: daySpends) }
```

每次 body 重渲染（包括 `@State hovered` 改变触发的 hover 帧）都重新构造 model，model init 内含排序 + 分位数 + 53×7=371 个 Cell 的网格生成。

最小 fix：把 model 提升为 `@State`，初值在 `init` 里一次性算好；`daySpends` 变化时用 `.onChange(of: daySpends)` 重算。

```swift
// Before
@State private var hovered: UsageHeatmapModel.Cell?
private var model: UsageHeatmapModel { UsageHeatmapModel(daySpends: daySpends) }

let daySpends: [DaySpend]
let isInitializing: Bool

// After
@State private var hovered: UsageHeatmapModel.Cell?
@State private var model: UsageHeatmapModel

let daySpends: [DaySpend]
let isInitializing: Bool

init(daySpends: [DaySpend], isInitializing: Bool) {
    self.daySpends = daySpends
    self.isInitializing = isInitializing
    _model = State(initialValue: UsageHeatmapModel(daySpends: daySpends))
}

// 在 body 的 root 容器加：
.onChange(of: daySpends) { _, newValue in
    model = UsageHeatmapModel(daySpends: newValue)
}
```

`DaySpend` 需为 `Equatable`（待验证；若不是顺手加 `Equatable` 一致性，由编译器合成）。

### 3.3 LocalCostCard.swift — Button 化（high，accessibility）

定位：`macos/Sources/UsageBar/LocalCostCard.swift:133-135`。整张卡的展开/收起目前用 `onTapGesture`，VoiceOver 把整张卡识别为 group 而非 button。

最小 fix：把外层 VStack 包进 `Button { withAnimation(...) { expanded.toggle() } } label: { ... }` + `.buttonStyle(.plain)`。

```swift
// Before
VStack(alignment: .leading, spacing: 12) {
    /* 卡片内容 */
}
.padding(...)
.background(...)
.contentShape(Rectangle())
.onTapGesture {
    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
}

// After
Button {
    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
} label: {
    VStack(alignment: .leading, spacing: 12) {
        /* 卡片内容 */
    }
    .padding(...)
    .background(...)
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
.accessibilityLabel("本机消费明细")
.accessibilityHint(expanded ? "收起" : "展开")
```

视觉零变化（`.plain` 取消 macOS button 默认 chrome）。

### 3.4 hygiene 5 条

| 文件:行 | 改动 |
|---|---|
| `UsageService.swift:6` | `class UsageService: ObservableObject` → `final class UsageService: ObservableObject` |
| `UsageService.swift:766` | `try? await Task.sleep(nanoseconds: 100_000_000)` → `try? await Task.sleep(for: .milliseconds(100))` |
| ~~`UsageHeatmapView.swift:102,104`~~ | ~~`ForEach(Array(m.weeks.enumerated()), …)` → 去外层~~ — **撤回**：`ForEach` 要 `RandomAccessCollection`，`EnumeratedSequence` 不符合 |
| ~~`MultiMenuBarLabel.swift:36`~~ | ~~`ForEach(Array(ids.enumerated()), …)` → 去外层~~ — **撤回**：同上 |
| `UsageBarApp.swift:51,52` | `Task.detached { await usageStats.refresh() }` → `Task { await usageStats.refresh() }`（`refresh` 内部已自管 `Task.detached(priority: .utility)`） |

> 注：`UsageModel.swift` 的 `String(format: "%.2f", …)` 替换为 `.formatted(...)` 这条 **不收**——审计建议 low，且这里都是货币/单位 suffix 拼接，`.formatted` 风格相反更啰嗦，留作以后批量统一。

### 3.5 死代码 2 处

#### 3.5.1 `CreditLine.currencyCode`（字段）

定位：`macos/Sources/UsageBar/ProviderUsageSnapshot.swift:55`（含 init 参数）。

写入点：`CodexUsageModel.swift:131`（写 `"USD"`）、`UsageModel.swift:252`（写 `nil`）。
读取点：0（`ProviderUsageSection.swift` 的 `CreditLineRow` 渲染时写死 `$` 前缀）。

处置：
- 从 `CreditLine` struct 删字段 + init 参数
- 删 2 处赋值
- 不补迁移代码（字段从未影响 UI / 持久化文件）

#### 3.5.2 `UsageProvider.supportsBackgroundPolling`（协议成员）

定位：`macos/Sources/UsageBar/UsageProvider.swift:18`（协议 + TODO 注释自 v0.2.10 已声明退役）。

生产 0 处读；测试 4 处断言：
- `CodexProviderTests.swift:253,333`
- `ProviderCoordinatorTests.swift:199`
- `ProviderAbstractionTests.swift:237`

处置：
- 删协议成员
- 删 `CodexProvider.swift:14` 与 `UsageService.swift:868` 两个 conformer impl
- 删 4 处测试断言（不替换为新断言；`ProviderCoordinator` 行为不依赖此字段）
- 删协议定义周边 TODO 注释

### 3.6 跨文件不变量

- 不动 `Package.swift`、不引依赖
- 不动 `Info.plist`、`build.sh`、`verify-release.sh`、`release.yml`
- 不动 `litellm_model_prices.json`、`THIRD_PARTY_LICENSES.txt` 资源
- 不动 OAuth / token refresh / Sparkle / codesign 任何链路
- 不改 ADR、不改 AGENTS.md / CLAUDE.md / 母法 spec

## 4. 文件变更清单

| 动作 | 文件 | 说明 |
|---|---|---|
| 🔧 | `UsageChartView.swift` | plotFrame guard |
| 🔧 | `UsageHeatmapView.swift` | model 改 @State + onChange；去 Array(seq.enumerated()) |
| 🔧 | `LocalCostCard.swift` | onTapGesture → Button + .plain |
| 🔧 | `UsageService.swift` | `final` + `Task.sleep(for:)`；删 supportsBackgroundPolling impl |
| 🔧 | `UsageBarApp.swift` | 去 Task.detached 包裹 |
| 🔧 | `MultiMenuBarLabel.swift` | 去 Array(seq.enumerated()) |
| 🔧 | `ProviderUsageSnapshot.swift` | 删 currencyCode 字段 + init 参数 |
| 🔧 | `UsageModel.swift` | 删 currencyCode 赋值 |
| 🔧 | `CodexUsageModel.swift` | 删 currencyCode 赋值 |
| 🔧 | `UsageProvider.swift` | 删 supportsBackgroundPolling 协议成员 + TODO 注释 |
| 🔧 | `CodexProvider.swift` | 删 supportsBackgroundPolling impl |
| 🔧 | `CodexProviderTests.swift` | 删 supportsBackgroundPolling 断言（2 处） |
| 🔧 | `ProviderCoordinatorTests.swift` | 删 supportsBackgroundPolling 断言（1 处） |
| 🔧 | `ProviderAbstractionTests.swift` | 删 supportsBackgroundPolling 断言（1 处） |
| 🆕 | `docs/versions/v0.3.1-swiftui-hygiene.md` | 本 spec 落地版本 |
| 🆕 | `docs/versions/v0.4.0-view-layer-modernization.md` | placeholder：SettingsView Binding + PopoverView ViewBuilder 抽 struct |
| 🆕 | `docs/versions/v0.5.0-observable-migration.md` | placeholder：ObservableObject → @Observable + UsageService 887 行拆分 |
| 🔧 | `docs/versions/README.md` | 路线表 append 三行 |
| ✅ 不动 | `Package.swift` / `Info.plist` / `build.sh` / CI / ADR | 严守守护线 |

合计改动：14 个代码文件（含 4 个测试）+ 4 个文档文件。**接近 CLAUDE.md 守护线"≤ 5 文件"上限**，但每处都是单点局部修改、无跨模块改造，整体仍属 issue-driven 范围。

## 5. 风险 / Open questions

1. ~~`DaySpend` 是否 `Equatable`~~ — **已确认**：`UsageAggregator.swift:128` 已经是 `struct DaySpend: Equatable`，可直接用新 `onChange(of:)`。
2. **`Button + .buttonStyle(.plain)` 与现有 hover 视觉**：LocalCostCard 当前 hover 是否依赖 `onTapGesture` 之外的 `.onHover` 等？若仅 tap 切展开/收起、无 hover 高亮，则视觉零变化。落实施前读 `LocalCostCard.swift` 全文确认。
3. **`UsageHeatmapView` 测试覆盖**：若 `UsageHeatmapModel` 已有独立单测，本次改动仅需让现有测试继续绿；若无，**不**主动新增（属 YAGNI）。
4. **`supportsBackgroundPolling` 删除后协议形状变化**：所有 conformer（生产 + 测试 spy）都要跟改一遍。`CodexProviderTests.swift:310` 附近有一段 v0.2.10 退役历史注释，连同断言一起清理；`swift test` 一跑即知是否漏改。

## 6. 后续工作（不在本 spec 范围）

- **v0.4.0 view-layer 现代化**（独立 spec）：
  - `SettingsView.swift` 5 处 `Binding(get:set:)` 改 `$bindable + onChange`
  - `PopoverView.swift` 6 个 `@ViewBuilder private var ...: some View` helper 抽独立 `View` struct
  - `UsageHeatmapView.swift:122-126` `.onAppear { DispatchQueue.main.async { withAnimation(.none) { ... } } }` 三层嵌套改 `.task { ... }`
  - `SettingsView.swift:139-145` `DispatchQueue.main.async` 改 `Task { @MainActor in ... }`
  - `UsageChartView.swift` `chartOverlay { GeometryReader }` 双层套娃彻底切现代 API
- **v0.5.0 @Observable 迁移**（独立 spec）：
  - 8 个 service 类 `ObservableObject + @Published + @StateObject` 老栈迁 `@Observable + @Bindable`
  - `UsageService.swift` 887 行借迁移之机拆分（OAuth、token refresh、polling timer、backoff 各成一文件）
  - `MultiMenuBarLabel.swift:73-84` `RuntimeAggregator` 手搓 Combine `sink` 由 observation tracking 自然消除

## 7. 引用

- 相关 ADR：无（不涉及架构决策）
- 相关 audit：本 spec 对应的 SwiftUI/Swift audit 报告（对话上下文，未单独落盘）
- 落地版本：v0.3.1
- 后继版本：v0.4.0、v0.5.0

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [x] SC1 — UsageChartView plotFrame guard（commit ad6fb27）
- [x] SC2 — UsageHeatmapModel @State 缓存 + onChange 重建（commit ad6fb27）
- [x] SC3 — LocalCostCard Button + .plain（commit ad6fb27）
- [x] SC4 — UsageService final + Task.sleep(for:)（commit 165b1fb）
- [x] SC5 — **撤回**（audit 误判 `ForEach.enumerated()` 直接可用；实证 SwiftUI ForEach 要 RandomAccessCollection）
- [x] SC6 — UsageBarApp 去多余 Task.detached + 同步注释（commit 165b1fb）
- [x] SC7 — currencyCode 字段下线（commit bfd063f）
- [x] SC8 — supportsBackgroundPolling 协议成员退役（commit bfd063f）
- [x] SC9 — `swift build -c release` + `swift test` 272 passed 0 failed
- [x] SC10 — `make release-artifacts` + `verify-release.sh` zip/dmg 全绿
