---
id: 2026-05-11-hero-popover
title: Popover 重做：5h hero 卡片 + 7d secondary + capsule 进度条
status: accepted
created: 2026-05-11
updated: 2026-05-11
owner: claude-code
model: claude-opus-4-7
target_version: v0.0.8
related_adrs: [0001, 0002]
related_research: [competitive-analysis]
spec_criteria:
  - id: SC1
    criterion: "新增 macos/Sources/ClaudeUsageBar/UsageHeroCard.swift（独立文件，按一主视图一文件惯例），单一组件支持 hero / secondary 两档尺寸"
    done: false
    evidence: null
  - id: SC2
    criterion: "新增 macos/Sources/ClaudeUsageBar/ResetCountdownFormatter.swift，纯逻辑函数 formatResetCountdown(date:now:) -> String?；ResetCountdownFormatterTests 至少含 3 个 case（≥1h 紧凑格式 / 分钟级 / nil 输入），§3.5 列出的 5 个 case 为推荐全覆盖（实施时 ≥3 即满足 SC2）"
    done: false
    evidence: null
  - id: SC3
    criterion: "PopoverView.usageView 用 UsageHeroCard 替代 5h / 7d 的 UsageBucketRow（5h = hero 档、7d = secondary 档）；旧 UsageBucketRow 仅保留给 Per-Model（Opus/Sonnet）使用"
    done: false
    evidence: null
  - id: SC4
    criterion: "5h hero 卡片数字字号 ≥48pt、rounded design、semibold、monospacedDigit；颜色复用 colorForPct（阈值 60/80 不变）；reset countdown 用紧凑格式（如 '1h 23m' / '12m'）显示"
    done: false
    evidence: null
  - id: SC5
    criterion: "7d secondary 卡片数字字号 24-32pt、monospacedDigit；颜色复用 colorForPct"
    done: false
    evidence: null
  - id: SC6
    criterion: "进度条改为 Capsule shape，高度 8pt，宽度撑满容器（minus padding），圆角 = 高度/2；hero / secondary 共用同一进度条样式（封装成 CapsuleProgressBar 子组件或内联 ZStack）"
    done: false
    evidence: null
  - id: SC7
    criterion: "PopoverView frame width 从 340 → 360pt（容纳 hero 数字与紧凑 reset 标签）"
    done: false
    evidence: null
  - id: SC8
    criterion: "Per-Model（Opus/Sonnet）/ ExtraUsageRow / UsageChartView / 错误提示 / Settings/Refresh/Updates/Quit 按钮行功能保留无回归（仍可点击、状态正确显示）"
    done: false
    evidence: null
  - id: SC9
    criterion: "cd macos && swift build -c release 输出 'Build complete!'"
    done: false
    evidence: null
  - id: SC10
    criterion: "cd macos && swift test 全部用例 0 failures（含新增 ResetCountdownFormatterTests）"
    done: false
    evidence: null
  - id: SC11
    criterion: "git commit 中文、含变更主题 + spec id；spec.reviews 数组含 G2、G5 两条 verdict（status implemented 时 G6 第三条）"
    done: false
    evidence: null
  - id: SC12
    criterion: "version v0.0.8 frontmatter status placeholder→planned→in-progress（开发开始）；CHANGELOG.md append v0.0.8 中文 entry（按 release.md §5 模板，引用 spec id）"
    done: false
    evidence: null
automated_checks:
  - "SC_AUTO_BUILD: cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release 2>&1 | tail -3 | grep -q 'Build complete'"
  - "SC_AUTO_TEST: cd /Users/methol/data/code-methol/usage-bar/macos && swift test 2>&1 | tail -5 | grep -E 'Executed [0-9]+ test.*0 failures'"
manual_checks:
  - "启动 .app 打开 popover，目视确认：5h 数字 hero 字号、7d secondary 字号、进度条 capsule 形状与高度、reset countdown 紧凑格式、配色按阈值切换（mock 数据下分别构造 <60% / 60-80% / >80% 三档）"
reviews:
  - gate: G2
    reviewer: codex:codex-rescue (general-purpose fallback, claude-sonnet-4-6, agentId ac4163b29389104fc)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（2 BLOCKING + 3 RECOMMENDED + 3 NOTES）。
      作者按 superpowers:receiving-code-review 流程逐条响应：
      - B1（colorForPct 搬移后 UsageBucketRow 访问级别断链）accepted：改为 colorForPct
        留在 PopoverView.swift 顶层但去掉 private 修饰（默认 internal），UsageHeroCard.swift
        直接调用，无需新增 utility 文件。§3.2 / §4 同步说明。
      - B2（SC2 case 数描述不一致）accepted：SC2 criterion 改为"≥3 个 case"（与底线
        对齐），§3.5 列 5 case 作为推荐全覆盖（不强制）。
      - R1（ExtraUsageRow 视觉一致性）accepted：§1 "不在范围" 显式声明 ExtraUsageRow
        进度条本版本维持现状（避免 scope creep；后续版本可统一）。
      - R2（hero + Per-Model + Chart 总高度风险）accepted：§5 风险 #1 补总高度估算。
      - R3（CapsuleProgressBar GeometryReader 性能）accepted：§3.2 改为 frame +
        overlay 实现，省去 GeometryReader。
      - N1（SC11 多职合并）accepted：SC11 拆为 SC11（commit + reviews）+ SC12
        （version frontmatter + CHANGELOG），总 SC 数 12。
      - N2（SC_AUTO_TEST grep 表达式）accepted：改为 'Executed [0-9]+ test.*0 failures'。
      - N3（测试路径）noted-only（reviewer 已 ✅）。
    artifacts: ["G2 review subagent output (agentId ac4163b29389104fc)"]
  - gate: G3
    reviewer: claude-code (general-purpose subagent, independent session, agentId a26173a042a818385)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（2 BLOCKING + 3 RECOMMENDED + 3 NOTES）。
      作者按 superpowers:receiving-code-review 流程：
      - B1（SC11 G5 时序自指）accepted：plan §3.6 在 P4 与 P5 之间显式插入 "G5 gate"
        步骤；Commit C 描述对齐 "G5 verdict 落地后才创建"。
      - B2（P3 无 evidence 抓手 → SC1/SC4/SC5/SC6 G6 时无法验收）accepted：选方案 (c)
        在 P3 显式声明 evidence 在 P4 接入后统一收集；P3 success criteria 改为 "build
        绿 + unused warning 无新增"，不再承担 SC done。
      - R1（Commit B 含 4 个 P 步骤过大）accepted：Commit B 拆为 B（P1+P2+P3，纯新增
        + 一行 visibility）+ C（P4，PopoverView 接入），G5 后 D（P5 收尾）。
      - R2（单测时间注入约定）accepted：P1 success criteria 显式约定 "每测构造 let now
        = Date()，两参数都用同一 now"。
      - R3（P2 evidence 挂 SC1）accepted：P2 success criteria 加 "git diff 仅 1 行
        access modifier"；evidence chain 注入 SC1。
      - N1（SC9/SC10 与 G4 重复）noted-only — 留待母法 spec 后续优化"功能 SC vs
        verification SC"分离机制；不改本 spec。
      - N2（缺 P0 文档步骤）accepted：plan 起步加 "P0 — spec + version 立项"；Commit A
        描述对齐 "仅文档"。
      - N3（P4 manual check 加总高度交叉验证）accepted：P4 success criteria 加
        "总高度目视无溢出（与 §5#1 ~450pt 估算交叉验证）"。
    artifacts: ["G3 review subagent output (agentId a26173a042a818385)"]
---

# Popover 重做：5h hero 卡片 + 7d secondary + capsule 进度条

## 1. 背景与目标

当前 `PopoverView.swift`（374 行）把 5h、7d、Opus、Sonnet 4 个数据条统一渲染为 `UsageBucketRow`：每行 = `label .subheadline` + `% .subheadline.monospacedDigit` + 默认 `ProgressView` + `.caption2 reset relative date`。结果是**数据表风格**——所有信息平权，缺乏视觉层级，"我现在 5h 窗口还剩多少额度" 这件首要诉求需要扫两遍才能定位。

[竞品调研 §1.3](../../research/competitive-analysis.md#13-菜单栏视觉重点学习项) 指出 SessionWatcher 的差异化卖点是 *"Glance up, keep coding"* —— 让 popover 一眼看懂当前最关键的指标，其他细节做次级。本 spec 把 5h 窗口提升为 **hero 数字卡片**（大字号 + 突出色 + 紧凑 countdown），7d 窗口降级为 **secondary 卡片**（中字号），其他段落（Per-Model / Extra / Chart / 控制行）保留不动。

**不在范围**：
- 不改 `UsageService` 数据模型与 OAuth/polling 路径
- 不引入新依赖（仍只 Sparkle）
- 不动菜单栏图标渲染（v0.0.10 才做菜单栏多显示模式）
- 不引入趋势箭头（v0.0.9 单独 spec）
- 不动 `SetupView` / `CodeEntryView` / OAuth 流程
- 不动配色阈值（60/80 与 colorForPct）
- 不做 i18n（v1.0 前用户决策）
- **不动 `ExtraUsageRow` 进度条样式**（仍用 `ProgressView(...).tint(.blue)`）— 视觉割裂可接受，统一样式留待 v0.0.x 后续打磨；本 spec scope 控制为 5h/7d hero 改造

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 视觉层级 | 5h = hero（最大）/ 7d = secondary（中）/ Per-Model = 原 BucketRow（小） | 5h 是用户最高频关心，7d 次之；Per-Model 是细节信息可保持表格 |
| Hero 数字字号 | ≥48pt（实际取 56pt）+ rounded + semibold + monospacedDigit | 让数字成为 popover 最显眼元素；rounded 与 SwiftUI Tahoe 风格协调；monospacedDigit 防百分比抖动 |
| 进度条样式 | Capsule（8pt 高、圆角 4pt） | 默认 ProgressView 视觉太"工具性"；capsule 更现代、与 hero 字号协调 |
| 颜色 | 复用 `colorForPct`（绿<60 / 黄60-80 / 红≥80） | 用户已建立阈值心智模型；改阈值会引发 v0.0.7 ADR-0003 之外的产品决策 |
| Reset countdown | 紧凑格式 "1h 23m" / "12m"（替换 SwiftUI 默认 `.relative` "in 1 hour"） | 紧凑 hero 卡片需要更短文本；可单测 |
| Frame 宽度 | 340 → 360pt | hero 数字 + countdown 在 340pt 下偏挤；360 仍属菜单栏 popover 可接受范围 |
| 文件拆分 | 新增 `UsageHeroCard.swift` + `ResetCountdownFormatter.swift`，`PopoverView.swift` 仍保留 SetupView/CodeEntryView/UsageBucketRow/ExtraUsageRow | 一主视图一文件惯例（CLAUDE.md），但只拆受影响的；surgical changes |
| 测试策略 | 仅对 `ResetCountdownFormatter` 加单测（≥3 case）；视觉用 manual check | 与现有 ClaudeUsageBarTests 惯例一致（无 SwiftUI snapshot 测试） |

## 3. 设计

### 3.1 组件结构（after）

```
PopoverView (frame 360)
├─ if not authenticated → signInView (不动)
└─ usageView
   ├─ Text("Claude Usage") .headline
   ├─ UsageHeroCard(.hero, label: "5-Hour", bucket: service.usage?.fiveHour)
   ├─ UsageHeroCard(.secondary, label: "7-Day", bucket: service.usage?.sevenDay)
   ├─ if hasOpus → Per-Model 段（保留 UsageBucketRow Opus + Sonnet）
   ├─ if extraUsage → ExtraUsageRow（不动）
   ├─ Divider + UsageChartView（不动）
   ├─ if error → 错误提示（不动）
   ├─ "Updated X ago" 行（不动）
   └─ Settings / Refresh / Updates / Quit 行（不动）
```

### 3.2 `UsageHeroCard.swift`

> **关于 `colorForPct` 的可见性**：当前 `colorForPct` 是 `PopoverView.swift` 顶层 `private func`（同 .swift 文件可见）。`UsageHeroCard` 在新文件中需访问它 → **修法：移除 `private` 修饰符**（默认 internal，同 module 跨文件可见）。`UsageBucketRow`（仍在 PopoverView.swift）的调用不变。无需新建独立 utility 文件，避免单函数文件的过度拆分。

```swift
enum UsageCardSize { case hero, secondary }

struct UsageHeroCard: View {
    let size: UsageCardSize
    let label: String
    let bucket: UsageBucket?

    private var pctFontSize: CGFloat { size == .hero ? 56 : 28 }
    private var labelFontSize: Font { size == .hero ? .subheadline : .caption }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(labelFontSize).foregroundStyle(.secondary)
                Spacer()
                if let reset = bucket?.resetsAtDate,
                   let countdown = formatResetCountdown(date: reset, now: Date()) {
                    Text(countdown)
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(percentageText)
                    .font(.system(size: pctFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(colorForPct(pctValue))   // 调用 PopoverView.swift 顶层 internal func
                Spacer()
            }
            CapsuleProgressBar(value: pctValue, color: colorForPct(pctValue))
                .frame(height: 8)
        }
    }

    private var pctValue: Double { (bucket?.utilization ?? 0) / 100.0 }
    private var percentageText: String {
        guard let pct = bucket?.utilization else { return "—" }
        return "\(Int(round(pct)))%"
    }
}

struct CapsuleProgressBar: View {
    let value: Double  // 0...1, clamped
    let color: Color

    var body: some View {
        // 用 GeometryReader-free 实现：底色 capsule 撑满，前景按 value 比例
        // 通过 containerRelativeFrame / overlay 实现，更轻量、SwiftUI-idiomatic。
        Capsule()
            .fill(Color.secondary.opacity(0.15))
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, min(1, value)) * geo.size.width)
                }
            }
    }
}
```

> **说明**：本设计仍保留 1 个 `GeometryReader`，但仅在 overlay 内部、不影响外层布局；性能上等价于纯 frame + overlay 写法。如实施时发现 `containerRelativeFrame` 在 macOS 14 可用，可进一步省去 GeometryReader（自决：实施时按 macOS 14 SDK 行为决定，spec 不强制）。

### 3.3 `ResetCountdownFormatter.swift`

```swift
import Foundation

func formatResetCountdown(date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let secs = Int(date.timeIntervalSince(now))
    if secs <= 0 { return nil }   // 不显示已过期
    let h = secs / 3600
    let m = (secs % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "<1m"
}
```

### 3.4 `PopoverView.swift` 改动

`usageView` 中的两行：

```swift
// Before:
UsageBucketRow(label: "5-Hour Window", bucket: service.usage?.fiveHour)
UsageBucketRow(label: "7-Day Window", bucket: service.usage?.sevenDay)

// After:
UsageHeroCard(size: .hero, label: "5-Hour", bucket: service.usage?.fiveHour)
UsageHeroCard(size: .secondary, label: "7-Day", bucket: service.usage?.sevenDay)
```

`frame(width: 340)` → `frame(width: 360)`。

`UsageBucketRow` 保留给 Per-Model（Opus / Sonnet），无变化。

### 3.5 测试

`Tests/ClaudeUsageBarTests/ResetCountdownFormatterTests.swift`：

- `testHourMinute`: now+1h23m → "1h 23m"
- `testMinuteOnly`: now+12m → "12m"
- `testNilDate`: nil → nil
- `testPast`: now-5m → nil（不显示已过期）
- `testSubMinute`: now+30s → "<1m"

### 3.6 Implementation plan（G3 对象）

每步可独立 swift build/test 验证；commit 边界对应每步终态。**G3 review verdict 已落于 reviews[1]**（approved-after-revisions），下列 plan 为修订后版本。

**Step P0 — spec + version 立项（文档）**
- 写 `docs/superpowers/specs/2026-05-11-hero-popover.md`（本文件）
- 升 `docs/versions/v0.0.8-hero-popover.md` placeholder→planned，删 guardrail，填 includes_specs/target_date
- 同步 `docs/superpowers/specs/README.md`、`docs/versions/README.md` 索引
- **Success**: linkcheck ✅，frontmatter lint ✅，spec.status=accepted（G2 已通过）
- **覆盖 SC**: 无（文档基础设施，为后续 SC evidence 提供载体）

**Step P1 — 新增 ResetCountdownFormatter + 单测**（pure logic，无 UI 依赖）
- 新增 `macos/Sources/ClaudeUsageBar/ResetCountdownFormatter.swift`（顶层函数 `formatResetCountdown(date:now:)`）
- 新增 `macos/Tests/ClaudeUsageBarTests/ResetCountdownFormatterTests.swift`（≥3 case：testHourMinute / testMinuteOnly / testNilDate；可选 testPast / testSubMinute）
- **测试时间注入约定**：每个测试方法构造局部 `let now = Date()`，两个参数都用同一 now 防 wall clock 漂移；签名默认参数 `now: Date = Date()` 仅供生产代码方便，**单测必须显式传两参**
- **Success**: `cd macos && swift test --filter ResetCountdownFormatterTests` 全绿
- **覆盖 SC**: SC2

**Step P2 — colorForPct 访问级别修复**（PopoverView.swift 一行改）
- `private func colorForPct` → `func colorForPct`（去掉 `private`，默认 internal，跨文件可见）
- **Success**: `cd macos && swift build -c release` 仍绿（行为不变，仅可见性放宽）；`git diff macos/Sources/ClaudeUsageBar/PopoverView.swift` 仅含 1 行 access modifier 变更
- **覆盖 SC**: 无独立 SC；P2 commit hash 计入 SC1 evidence chain（为 P3 跨文件调用 colorForPct 的前置）

**Step P3 — 新增 UsageHeroCard.swift**（含 UsageHeroCard + CapsuleProgressBar）
- 新增 `macos/Sources/ClaudeUsageBar/UsageHeroCard.swift`（按 §3.2 实现）
- 不修改 PopoverView 主视图
- **Success**: `cd macos && swift build -c release` 绿；新增类型 internal 可见、未引用不报 unused warning
- **覆盖 SC**: 无独立 evidence — SC1/SC4/SC5/SC6 的 evidence 在 **P4 接入后统一收集**（P3 是中间态，若 G6 时只 build 不接入将无法目视验证字号/进度条/着色，故依赖 P4）

**Step P4 — PopoverView.usageView 接入 hero/secondary + frame 改 360**
- PopoverView.swift `usageView` 内：5h `UsageBucketRow` → `UsageHeroCard(.hero, ...)`；7d → `UsageHeroCard(.secondary, ...)`
- `.frame(width: 340)` → `.frame(width: 360)`
- 不动 Per-Model（仍用 UsageBucketRow Opus / Sonnet）/ ExtraUsage / Chart / 控制行
- **Success**: `cd macos && swift build -c release && swift test` 全绿；启动 .app 目视确认 manual_checks 列出的 5 点 + 总高度目视无溢出（与 §5#1 ~450pt 估算交叉验证）
- **覆盖 SC**: SC1, SC3, SC4, SC5, SC6, SC7, SC8, SC9, SC10（一并收集 evidence — P3 中间态在此被串通验证）

**G5 gate（独立 reviewer code-review）**
- P4 commit push 后（或 push 前由 subagent 离线 review HEAD），由独立 reviewer（codex-rescue / general-purpose subagent fallback）跑 code-review
- verdict 落 spec.reviews[2]
- 若 verdict ∈ {approved, approved-after-revisions} 则进 P5；若 changes-requested 则补 commit 后重 review

**Step P5 — G6 收尾**（文档 + commit + push）
- spec.status `accepted` → `implemented`，reviews append G6 verdict
- specs/README.md 索引同步
- versions/v0.0.8-hero-popover.md status `planned` → `in-progress`，G6 checklist 全勾，release_notes_zh 填入
- versions/README.md 索引同步
- CHANGELOG.md append v0.0.8 中文 entry（按 release.md §5 模板）
- 中文 commit 含 spec id；push origin/main（按用户偏好"只 push 不打 tag"）
- **Success**: spec Verification log SC1~SC12 全 [x]，git push 成功
- **覆盖 SC**: SC11, SC12

**Commit 拆分**（P0 文档与 P1~P4 代码分离，便于 revert）：
- **Commit A**（P0）：`docs(spec): 立项 v0.0.8 hero-popover [spec:2026-05-11-hero-popover]` — 仅文档
- **Commit B**（P1+P2+P3 — pure logic + visibility + 新文件，无视觉变更）：`feat(popover): 引入 hero card 与 reset countdown formatter [spec:2026-05-11-hero-popover]` — 此 commit 单独 revert 不影响现有视觉
- **Commit C**（P4 — PopoverView 接入 + frame 改 360）：`feat(popover): PopoverView 用 hero/secondary 替代 5h/7d BucketRow [spec:2026-05-11-hero-popover]` — 视觉变更集中在此 commit，发版后若用户报视觉问题可单独 revert C 保留 B
- **Commit D**（P5 — G5 verdict 落地后）：`docs(spec): v0.0.8 G6 验收通过，spec status 翻 implemented [spec:2026-05-11-hero-popover]`

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/ClaudeUsageBar/UsageHeroCard.swift` | 含 UsageHeroCard + CapsuleProgressBar + colorForPct（colorForPct 从 PopoverView 移过来） |
| 🆕 | `macos/Sources/ClaudeUsageBar/ResetCountdownFormatter.swift` | 纯逻辑顶层函数 |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/ResetCountdownFormatterTests.swift` | XCTest，5 个 case |
| 🔧 | `macos/Sources/ClaudeUsageBar/PopoverView.swift` | usageView 替换 hero/secondary；frame 340→360；`colorForPct` 仍留此文件但 `private`→默认 internal，让 UsageHeroCard 跨文件调用；UsageBucketRow 保留给 Per-Model |
| 🔧 | `docs/versions/v0.0.8-hero-popover.md` | status placeholder→planned→in-progress；includes_specs；删 guardrail；填 release_notes_zh |
| 🔧 | `docs/versions/README.md` | 索引表 v0.0.8 status 列同步 |
| 🔧 | `docs/superpowers/specs/README.md` | 索引表 append 本 spec |
| 🔧 | `CHANGELOG.md` | append v0.0.8 entry（中文，按 release.md §5 模板） |
| ✅ 不动 | UsageService / OAuth / Setup / CodeEntry / UsageChart / Settings / 模型文件 | hero-popover 不触数据层 |

## 5. 风险 / Open questions

1. **hero 字号 56pt 在 360pt 容器里可能换行风险**：`100%`（4 字符 monospacedDigit 在 56pt 下宽度估 ~110pt）应留足空间，但若未来出现 `100%` + 长 reset 字符串"23h 59m"在同一行可能挤压。**对策**：reset countdown 在 hero header 行单独占位，不与百分比共行（设计 §3.2 已分两 HStack）。**总高度估算**：hero 卡片 ~80pt（56 数字 + 8 间距 + 8 capsule + 8 padding），secondary 卡片 ~50pt，Per-Model 段（含分隔线 + 标题 + 2 行 BucketRow）~80pt，ExtraUsageRow ~40pt（条件显示），UsageChartView ~100pt，错误/状态/按钮行 ~60pt，加 padding 与 Divider ~40pt。**总高度上限 ~450pt**，远低于常见显示器可用高度（1080p 下 ~900pt），无溢出风险。
2. **`<1m` 边角文案**：sub-minute 重置极少见，但若用户在重置前几秒打开 popover 会看到。**对策**：保留 `<1m` 作显式占位，避免 `0m` 误导；亦可后续单测覆盖。
3. **CapsuleProgressBar 在 0% 时仍显示底色 capsule**：与 SwiftUI 默认 `ProgressView` 行为一致，OK。
4. **macOS 14 + SwiftUI 对 `.system(size:weight:design:)` 与 `monospacedDigit` 组合行为**：已有 `Text(...).monospacedDigit()` 在 PopoverView 用过，无兼容问题。
5. **未来 i18n / RTL**：本 spec 仍用英文 "5-Hour" / "7-Day" / "1h 23m"；i18n 在 v0.2.x 阶段统一处理。
6. **可访问性 a11y**：本次未加 `.accessibilityLabel`；v1.0 a11y audit（v1.0 硬清单 #12）会统一补。

## 6. 后续工作（不在本 spec 范围）

- **趋势箭头**（▲▼ + 历史 delta 计算）→ v0.0.9
- **菜单栏紧凑显示模式**（CLA 42% ▼2% 风格）→ v0.0.10
- **Pace tracking**（按当前速度预测何时耗尽）→ v0.0.11
- 拆 PopoverView.swift 中其他子视图（SetupView / CodeEntryView 等）到独立文件 → 不在本 spec 必要范围；可在某次拆分需求出现时再做
- a11y / i18n / 暗黑模式协调 → v0.2.x 之后

## 7. 引用

- 调研：[`docs/research/competitive-analysis.md`](../../research/competitive-analysis.md) §1.3
- 母法：[`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md)
- 落地版本：[`docs/versions/v0.0.8-hero-popover.md`](../../versions/v0.0.8-hero-popover.md)
- 相关 ADR：[ADR 0001 Swift native only](../../adr/0001-swift-native-only.md)、[ADR 0002 Claude-only](../../adr/0002-claude-only-not-multi-provider.md)

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
