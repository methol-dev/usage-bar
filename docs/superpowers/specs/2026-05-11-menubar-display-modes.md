---
id: 2026-05-11-menubar-display-modes
title: 菜单栏多显示模式（icon / percent / percent+trend）
status: accepted
created: 2026-05-11
updated: 2026-05-11
owner: claude-code
model: claude-opus-4-7
target_version: v0.0.10
related_adrs: [0001, 0002]
related_research: [competitive-analysis]
spec_criteria:
  - id: SC1
    criterion: "新增 macos/Sources/ClaudeUsageBar/MenuBarDisplayMode.swift：enum MenuBarDisplayMode: String, CaseIterable, Identifiable { case icon, percent, percentWithTrend }；含 displayName 人类可读 label 与 storageKey 'menubarDisplayMode'；默认值 .icon"
    done: false
    evidence: null
  - id: SC2
    criterion: "新增 macos/Sources/ClaudeUsageBar/MenuBarLabel.swift：SwiftUI View，根据 @AppStorage(MenuBarDisplayMode.storageKey) 切换三种显示分支：.icon → 现有 renderIcon / renderUnauthenticatedIcon；.percent → Text('5h N%' 或 '5h —')；.percentWithTrend → HStack(percent + trend)"
    done: false
    evidence: null
  - id: SC3
    criterion: "新增顶层纯函数 formatMenuBarPercent(utilization: Double?, prefix: String) -> String，覆盖：utilization 0..100 → 'prefix N%'；nil → 'prefix —'；含 ≥3 case 单测（含小数 round / nil / 100 边界）"
    done: false
    evidence: null
  - id: SC4
    criterion: ".percentWithTrend 在 .percent 文本基础上，trend 非 nil 时附加 '▲N' / '▼N'（无 % 节省宽度），foregroundStyle 整段 monospacedDigit + color = up→.red / down→.green；trend nil 时与 .percent 一致"
    done: false
    evidence: null
  - id: SC5
    criterion: "macos/Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift MenuBarExtra label 替换为 MenuBarLabel(service: service, historyService: historyService).task { ... }；.task 闭包保留不变；验证 .task 内 startPolling()/loadHistory() 重复执行幂等（startPolling→scheduleTimer 自带 timer?.invalidate；loadHistory 是覆盖式赋值），即使 SwiftUI 多次重渲染 label 也不引入累积副作用"
    done: false
    evidence: null
  - id: SC6
    criterion: "SettingsWindowContent General section 加 Picker 'Menubar Display'，**用 @AppStorage(MenuBarDisplayMode.storageKey) 直接绑定**（与 MenuBarLabel 同款，避免 Binding(get:set:) 与 @AppStorage 双轨读写不对称），3 个 case 显示 displayName"
    done: false
    evidence: null
  - id: SC7
    criterion: "默认 displayMode = .icon，新装 / 升级用户视觉无变化（不破坏现有体验）"
    done: false
    evidence: null
  - id: SC8
    criterion: "不动 MenuBarIconRenderer.swift / UsageService / UsageHistoryService 数据层 / ExtraUsage / OAuth / Notifications；ExtraUsage 不参与 menubar 显示（菜单栏空间限制 + 数据语义不同，留后续）"
    done: false
    evidence: null
  - id: SC9
    criterion: "cd macos && swift build -c release 输出 'Build complete!'"
    done: false
    evidence: null
  - id: SC10
    criterion: "cd macos && swift test 'Executed N tests, with 0 failures'（含新增 MenuBarDisplayModeTests 或 formatMenuBarPercent 单测 ≥3 case）"
    done: false
    evidence: null
  - id: SC11
    criterion: "git commit 中文、含变更主题 + spec id；spec.reviews 数组含 G2、G3、G5、G6 四条 verdict"
    done: false
    evidence: null
  - id: SC12
    criterion: "version v0.0.10 frontmatter status placeholder→planned→in-progress；CHANGELOG.md append v0.0.10 中文 entry"
    done: false
    evidence: null
automated_checks:
  - "SC_AUTO_BUILD: cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release 2>&1 | tail -3 | grep -q 'Build complete'"
  - "SC_AUTO_TEST: cd /Users/methol/data/code-methol/usage-bar/macos && swift test 2>&1 | tail -5 | grep -E 'Executed [0-9]+ test.*0 failures'"
manual_checks:
  - "Settings 切换三种 displayMode，目视确认菜单栏 label 切换：.icon = 双进度条图标；.percent = 文本 '5h 42%'；.percentWithTrend = '5h 42% ▼5'（需 ≥6h history 才会有 trend）；.icon 仍是默认值"
  - "Settings 切换 displayMode 后菜单栏 label ≤1s 内立即响应（@AppStorage → SwiftUI 重渲染）"
  - "未登录状态下切到 .percent / .percentWithTrend，目视确认 label 显示 '5h —'（em-dash）无误导性内容；可接受不强制改为 'Sign in' 提示"
  - "P2 commit 后 git diff --stat 确认仅触三文件（MenuBarLabel.swift / ClaudeUsageBarApp.swift / SettingsView.swift）；其余文件无改动（SC8 反向断言）"
reviews:
  - gate: G2
    reviewer: codex:codex-rescue (general-purpose fallback, agentId a78db21ea62686f9e)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（2 BLOCKING + 5 RECOMMENDED）。
      作者按 superpowers:receiving-code-review 流程：
      - B1（.task 挂 MenuBarLabel 可能多次执行 startPolling 等）accepted —
        实证 grep `UsageService.swift:103-122` 确认 startPolling→scheduleTimer
        自带 `timer?.invalidate()` 已幂等；historyService.loadHistory 是覆盖式
        赋值；其他 service 引用赋值幂等。.task 留在 MenuBarLabel 上不挪位置
        （MenuBarExtra label vs content 各自挂的差别在视觉/交互无别）；SC5
        criterion 显式补"验证 .task 重复执行幂等"。
      - B2（Binding vs @AppStorage 双轨写）accepted — SC6 显式约束 SettingsWindowContent
        Picker 用 @AppStorage 直接绑定，与 MenuBarLabel 对称。
      - S1（manual check 加切换 ≤1s 立即响应）accepted — manual_checks 新增项。
      - S2（"Icon (default)" 硬编 default 字样）accepted — displayName 改为不带
        "(default)"（直接 "Icon" / "Percent text" / "Percent + trend"）。
      - S3（未登录无引导文字）accepted — manual_checks 加未登录目视确认项。
      - S4（trend nil 时 percentWithTrend 退化为 percent）accepted — §5 风险新增 #8。
      - S5（rawValue 迁移）noted-only — 已有 ?? .icon fallback。
      修订后 spec.status 升 accepted。
    artifacts: ["G2 review subagent output (agentId a78db21ea62686f9e)"]
  - gate: G3
    reviewer: claude-code (general-purpose subagent, agentId a17b5275f66fdd49d)
    date: 2026-05-11
    verdict: approved
    summary: |
      原始 verdict: approved（0 BLOCKING + 4 RECOMMENDED + 5 NOTES，全数受理）。
      - R1（P2 success 加 git diff --stat 反向断言落到可观测命令）accepted —
        manual_checks 增加 "git diff --stat 仅触三文件" 项。
      - R2（Commit C 边界）confirmed ✅ 无环 atomic。
      - R3（P1 也跑全集 swift test 防命名冲突）accepted —
        plan §3.7 Step P1 success 改为 "swift test 全集（含 MenuBarDisplayModeTests）" 而非仅 --filter。
      - R4（G5 reviewer focus 加重渲染开销）accepted —
        plan §3.7 G5 gate 第 5 点：MenuBarLabel body 重渲染开销与性能退化检查。
      - N1~N5（依赖单向 / build/test 边界 / commit 拆分 / SC 全覆盖 / Settings @AppStorage 简化）
        confirmed ✅；N5 与 G2 B2 重复处理。
    artifacts: ["G3 review subagent output (agentId a17b5275f66fdd49d)"]
---

# 菜单栏多显示模式（icon / percent / percent+trend）

## 1. 背景与目标

竞品 SessionWatcher 在菜单栏支持多种紧凑显示（百分比 / token / $ / 趋势），让用户根据偏好选最关心的指标。我们当前 `MenuBarIconRenderer` 只支持双进度条图标模式，文字密度 0。

本 spec 引入 3 种显示模式：

- **icon**（默认，现状）：双窗口进度条图标
- **percent**：文本 `5h 42%`，更紧凑、可与 macOS 系统字体协调
- **percentWithTrend**：在 percent 基础上加 `▲N` / `▼N` 趋势（复用 v0.0.9 TrendCalculator）

**不在范围**：
- `$/天` 模式 —— 数据源依赖 v0.1.2 本地 JSONL cost 扫描；本版本**不引入**该 mode（不做 dead UI 选项），等 v0.1.2 spec 时同时新增 `.dollarsPerDay` case
- 5h vs 7d 窗口切换 —— 本版本固定显示 5h（用户最高频关心）；7d 选项留后续 spec
- token 数模式 —— Anthropic OAuth API 不暴露 token 计数（只有 utilization%），需依赖 v0.1.2 数据源；同 $ 模式留后续
- 厂商缩写（如 SessionWatcher 的 `CLA`）—— Claude-only（ADR 0002），无意义
- 双窗口同时显示文本 —— `5h 42% 7d 73%` 在菜单栏过长，先单窗口；可在后续做"双窗口紧凑"模式
- a11y `.accessibilityLabel` —— 留 v1.0 a11y audit 统一处理

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| Mode 集 | 仅 icon / percent / percentWithTrend 三个 | scope 控制；$ / token 等待数据源 spec |
| 默认 mode | .icon | 不破坏现有用户视觉与心智 |
| 持久化 | @AppStorage("menubarDisplayMode")，String rawValue | macOS UserDefaults，与 setupComplete / pollingMinutes 同款 |
| Settings 入口 | General section Picker，与 LaunchAtLogin / PollingInterval 同列 | 减少认知负担 |
| 单窗口选择 | 固定 5h | 调研 §5.2 "5h 是用户最高频关心的"；7d 切换留后续 |
| Trend 来源 | 复用 v0.0.9 computeTrend(currentPct: utilization, points: history.dataPoints, metric: \.pct5h) | 与 hero card 同源、单位约定一致 |
| Trend 文本格式 | `▲N` / `▼N`（无 %） | 菜单栏宽度紧张；箭头 + 数字已表达"百分点变化"语义 |
| Trend color | up→.red / down→.green | 与 v0.0.9 hero card 同色、心智一致 |
| 未登录文本 | `5h —`（em-dash） | 不显示百分号占位，避免误导为 0% |
| 文件拆分 | 新增 MenuBarDisplayMode.swift（enum + helper）+ MenuBarLabel.swift（View） | 一文件一主视图惯例；helper 与 enum 同文件减少 boilerplate |

## 3. 设计

### 3.1 数据流

```
@AppStorage("menubarDisplayMode") (String)
        │
        ▼
MenuBarLabel.body
  ├─ mode == .icon → Image(nsImage: renderIcon(pct5h, pct7d))
  ├─ mode == .percent → Text(formatMenuBarPercent(utilization: 5h.utilization, prefix: "5h"))
  └─ mode == .percentWithTrend → HStack {
       Text(percentText)
       if let trend { Text("▲N") or Text("▼N") }
     }
```

### 3.2 `MenuBarDisplayMode.swift`

```swift
import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case icon
    case percent
    case percentWithTrend

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .icon: return "Icon"             // 默认值由 storageKey 默认值表达，不写在 displayName
        case .percent: return "Percent text"
        case .percentWithTrend: return "Percent + trend"
        }
    }

    static let storageKey = "menubarDisplayMode"
}

/// 把 utilization (0...100) 格式化为菜单栏百分比文本。
/// nil 显示 prefix + " —"（em-dash 占位）。
func formatMenuBarPercent(utilization: Double?, prefix: String) -> String {
    guard let pct = utilization else { return "\(prefix) —" }
    return "\(prefix) \(Int(round(pct)))%"
}
```

### 3.3 `MenuBarLabel.swift`

```swift
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @AppStorage(MenuBarDisplayMode.storageKey) private var modeRaw: String = MenuBarDisplayMode.icon.rawValue

    var body: some View {
        let mode = MenuBarDisplayMode(rawValue: modeRaw) ?? .icon
        switch mode {
        case .icon:
            iconView
        case .percent:
            Text(percentText)
                .monospacedDigit()
        case .percentWithTrend:
            HStack(spacing: 4) {
                Text(percentText).monospacedDigit()
                if let t = trend {
                    Text(trendText(t))
                        .monospacedDigit()
                        .foregroundStyle(t.direction == .up ? .red : .green)
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        Image(nsImage: service.isAuthenticated
            ? renderIcon(pct5h: service.pct5h, pct7d: service.pct7d)
            : renderUnauthenticatedIcon())
    }

    private var percentText: String {
        guard service.isAuthenticated else {
            return formatMenuBarPercent(utilization: nil, prefix: "5h")
        }
        return formatMenuBarPercent(utilization: service.usage?.fiveHour?.utilization, prefix: "5h")
    }

    private var trend: TrendIndicator? {
        guard service.isAuthenticated else { return nil }
        return computeTrend(
            currentPct: service.usage?.fiveHour?.utilization,
            points: historyService.history.dataPoints,
            metric: \.pct5h
        )
    }

    private func trendText(_ t: TrendIndicator) -> String {
        let arrow = t.direction == .up ? "▲" : "▼"
        return "\(arrow)\(t.deltaPct)"
    }
}
```

### 3.4 `ClaudeUsageBarApp.swift` 改动

```swift
// Before:
} label: {
    Image(nsImage: service.isAuthenticated ? renderIcon(...) : renderUnauthenticatedIcon())
        .task { ... }
}

// After:
} label: {
    MenuBarLabel(service: service, historyService: historyService)
        .task { ... }   // .task 保留在 label View 上
}
```

### 3.5 `SettingsWindowContent` 改动

在 General section LaunchAtLogin 与 PollingInterval 之间插入。**用 @AppStorage 直接绑定**（G2 review B2 修订 — 与 MenuBarLabel 对称，避免 Binding(get:set:) 与 @AppStorage 双轨写）：

```swift
struct SettingsWindowContent: View {
    @ObservedObject var service: UsageService
    @ObservedObject var notificationService: NotificationService
    @AppStorage(MenuBarDisplayMode.storageKey) private var menubarModeRaw: String = MenuBarDisplayMode.icon.rawValue
    // ...
    Picker("Menubar Display", selection: Binding(
        get: { MenuBarDisplayMode(rawValue: menubarModeRaw) ?? .icon },
        set: { menubarModeRaw = $0.rawValue }
    )) {
        ForEach(MenuBarDisplayMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
        }
    }
}
```

> 注：Picker selection 仍用 `Binding(get:set:)` 适配 enum，但 get/set 内只读写 `@AppStorage` 绑定的 `menubarModeRaw` 字符串，不直接 `UserDefaults.standard.set` — 这样 SwiftUI 的 @AppStorage 观察机制保证多视图（label + Settings）同步，无双轨。

### 3.6 测试

`MenuBarDisplayModeTests`（≥3 case）：
- `testFormatPercentNormal`: utilization=42.0, prefix="5h" → "5h 42%"
- `testFormatPercentNil`: utilization=nil, prefix="5h" → "5h —"
- `testFormatPercent100`: utilization=100.0, prefix="5h" → "5h 100%"
- `testFormatPercentRounding`: utilization=42.7 → "5h 43%"（round-half-to-even / 标准 round）
- `testDisplayModeRawValueRoundtrip`: enum.rawValue init 互通

不对 MenuBarLabel View 做 SwiftUI snapshot 测试（与现有惯例一致）。

### 3.7 Implementation plan（G3 对象）

**Step P0 — spec + version + 索引**（Commit A，仅文档）
- 升 v0.0.10 placeholder→planned；删 guardrail；填 includes_specs
- specs/README.md / versions/README.md 索引同步
- **Success**: linkcheck ✅ frontmatter ✅；spec.status=accepted（G2 通过）
- **覆盖 SC**: 无

**Step P1 — 新增 MenuBarDisplayMode.swift + 单测**（Commit B，pure logic）
- 新增 `MenuBarDisplayMode.swift`（enum + formatMenuBarPercent 函数）
- 新增 `MenuBarDisplayModeTests.swift`（≥3 case + roundtrip）
- **Success**: `swift test`（**全集**，G3 R3 修订 — 防新 enum/helper 引入命名冲突误伤其他测试，成本 < 10s）全绿；`swift build -c release` 绿
- **覆盖 SC**: SC1, SC3（pure logic 部分）

**Step P2 — 新增 MenuBarLabel.swift + ClaudeUsageBarApp 接入 + Settings Picker**（Commit C，刻意合并）
- 新增 `MenuBarLabel.swift`
- ClaudeUsageBarApp.swift MenuBarExtra label 替换为 MenuBarLabel（保留 .task）
- SettingsWindowContent 加 displayMode Picker
- **Success**: `swift build -c release && swift test` 全绿；启动 .app 进程不崩；Settings 能看到 Picker
- **覆盖 SC**: SC2, SC4, SC5, SC6, SC7, SC8, SC9, SC10
- **Manual checklist**（不计入 success criteria）：grep 确认 MenuBarIconRenderer.swift / UsageService.swift / UsageHistoryService.swift 等无修改（SC8 反向断言）

**G5 gate** — 独立 reviewer code-review（codex-rescue / general-purpose subagent fallback）
- **Reviewer focus**：(a) MenuBarLabel 三个分支视觉与 macOS HIG 协调；(b) @AppStorage 读写时序（多视图共享、launch race）；(c) 未登录 fallback 路径；(d) commit B/C 独立 revert；(e) MenuBarLabel body 重渲染开销 — service / historyService publish 时 body 重算含 computeTrend 调用，确认无性能退化（G3 R4 修订）

**Step P3 — G6 收尾**（Commit D）
- spec.status accepted → implemented；reviews append G5 + G6
- spec_criteria SC 全 done；Verification log 全 [x]
- specs/README + versions/README 索引同步
- versions/v0.0.10 status planned → in-progress + G6 checklist + release_notes_zh
- CHANGELOG append v0.0.10 entry
- **覆盖 SC**: SC11, SC12

**Commit 拆分**：A（P0 文档）/ B（P1 enum + 测试，纯逻辑）/ C（P2 View + 接入 + Settings，**刻意合并** — 三处改动语义紧耦合，单独 revert 利于"显示模式有问题"时整体回退）/ D（P3 G6 收尾）

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/ClaudeUsageBar/MenuBarDisplayMode.swift` | enum + formatMenuBarPercent helper |
| 🆕 | `macos/Sources/ClaudeUsageBar/MenuBarLabel.swift` | SwiftUI View，3 分支切换 |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/MenuBarDisplayModeTests.swift` | ≥3 case |
| 🔧 | `macos/Sources/ClaudeUsageBar/ClaudeUsageBarApp.swift` | MenuBarExtra label 替换为 MenuBarLabel；.task 保留 |
| 🔧 | `macos/Sources/ClaudeUsageBar/SettingsView.swift` | General section 加 displayMode Picker |
| 🔧 | `docs/versions/v0.0.10-menubar-display-modes.md` | placeholder→planned→in-progress |
| 🔧 | `docs/versions/README.md` / `docs/superpowers/specs/README.md` | 索引同步 |
| 🔧 | `CHANGELOG.md` | append v0.0.10 entry |
| ✅ 不动 | `MenuBarIconRenderer.swift` / `UsageService.swift` / `UsageHistoryService.swift` / `NotificationService.swift` / `PopoverView.swift` / `UsageHeroCard.swift` | menu bar mode 切换不触图标渲染 / 数据层 / 通知 / popover |

## 5. 风险 / Open questions

1. **menu bar 文本宽度**：`5h 42% ▼5` 约 8 字符；macOS 菜单栏在多 menubar item 拥挤时可能被压缩。可接受，用户可切回 .icon。
2. **@AppStorage 多视图同步**：`menubarDisplayMode` 同时被 MenuBarLabel 与 SettingsWindowContent 读，SwiftUI @AppStorage 自动同步无 race。
3. **未登录 percentWithTrend**：currentPct nil → trend nil，HStack 仅显示 `5h —`。
4. **trend 在菜单栏的高频更新**：computeTrend 复用 v0.0.9 实现，30 天历史 < 1ms / 次；MenuBarExtra label 渲染频率 ≤ polling 间隔（默认 60s），无性能压力。
5. **用户切回 .icon 后期望立即看到图标**：@AppStorage 变更触发 SwiftUI 重渲染，应当立即生效；如有延迟可在后续观察。
6. **暗黑模式下文本对比度**：menu bar Text 使用系统 foregroundStyle（自动适配），trend 用 .red / .green 系统色（macOS 自动调）；与 v0.0.9 hero 同款。
7. **a11y 已知降级**：menu bar 文本 mode 缺 .accessibilityLabel；与 v0.0.9 trend 同款 noted；v1.0 a11y audit 统一处理。
8. **`.percentWithTrend` 在 trend nil 时退化为 `.percent` 视觉**：history 不足 6h（新装 / 清缓存）时 trend 始终 nil，`.percentWithTrend` 与 `.percent` 视觉一致，用户可能困惑"我选了带 trend 的为啥没箭头"。属预期行为（数据不足静默优于错误信息），可在 v1.0 user-guide 文档中说明。

## 6. 后续工作（不在本 spec 范围）

- `.dollarsPerDay` mode + `.tokens` mode → v0.1.2（数据源 ready 后）
- 5h / 7d 窗口切换（双 mode 拆 5h-percent / 7d-percent）→ 后续 spec
- 双窗口紧凑模式 `5h 42% 7d 73%` → 后续 spec
- a11y label → v1.0 a11y audit
- pace tracking 集成（菜单栏显示"还能用 X 分钟"）→ v0.0.11

## 7. 引用

- 调研：[`docs/research/competitive-analysis.md`](../../research/competitive-analysis.md) §1.3
- 母法：[`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md)
- 落地版本：[`docs/versions/v0.0.10-menubar-display-modes.md`](../../versions/v0.0.10-menubar-display-modes.md)
- 前置 spec：[`2026-05-11-trend-arrows.md`](./2026-05-11-trend-arrows.md)（v0.0.9 提供 computeTrend / TrendIndicator）

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [ ] SC1 — pending
- [ ] SC2 — pending
- [ ] SC3 — pending
- [ ] SC4 — pending
- [ ] SC5 — pending
- [ ] SC6 — pending
- [ ] SC7 — pending
- [ ] SC8 — pending
- [ ] SC9 — pending
- [ ] SC10 — pending
- [ ] SC11 — pending
- [ ] SC12 — pending
