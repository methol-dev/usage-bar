---
id: 2026-05-12-popover-redesign
title: Popover 重做 — provider tab 外壳 + 卡片化视觉 + 折线图 pace 面积
status: implemented
created: 2026-05-12
updated: 2026-05-12
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.4
related_adrs: [2, 5]
related_research: []
spec_criteria:
  - id: SC1
    criterion: "popover 顶部出现 provider tab bar（Claude / Codex / Cursor / Copilot / Gemini）；Claude 为选中态，其余 4 个 dimmed；选中非 Claude 时整个用量区替换为「敬请期待」占位面板，且能切回 Claude"
    done: true
    evidence: "ProviderTab/ProviderTabBar/ProviderComingSoonView @ 9106c4b；PopoverView 接线 @ 75852df；ProviderTabTests 3 cases 绿；make app + open 启动无崩溃。视觉细节（选中态/dimmed/占位面板）待 user 目测确认。"
  - id: SC2
    criterion: "5h / 7d 用量为圆角卡片：左上 SF Symbol 图标（5h=clock，7d=calendar）+ 标题，右上 百分比 + 趋势箭头；下方 capsule 进度条；底行「Resets in: …」+「Pace: safe/fast」标签 —— 5h（<24h）显示「Xh Ym at H:MM AM/PM」，7d（一般 ≥24h）显示「X days Yh Zm」（此时整行没有「at 时钟」）；popover 背景为柔和渐变（dark mode 自适应、近乎不可见）"
    done: true
    evidence: "formatResetWithClock @ 662e78d（5 cases 绿）；UsageCard @ 2316efc；UsageHeroCard 三行布局 @ 3e912b0；PopoverView 卡片化 + 渐变背景 @ 75852df。视觉/dark mode 待 user 目测确认。"
  - id: SC3
    criterion: "折线图在原 5h（蓝）/ 7d（橙）两条折线下方叠加 pace 面积：浅蓝 = 5h pace、浅黄 = 7d pace；pace = 当前窗口内 elapsed 比例 ×100（5h 跨多窗口时呈锯齿）；原两条折线、悬停 RuleMark/PointMark/tooltip 行为完全不变；图例仍只显示 5h / 7d 两项"
    done: true
    evidence: "UsagePaceArea.series @ a28bbe0（5 cases 绿）；chartView 叠 AreaMark（pace 在最前=底层、用 foregroundStyle(Color) 不进图例）@ fac597f；PopoverView 透传 reset 日期 @ 75852df；悬停/tooltip 代码未改动。pace 面积浅度/锯齿/图例待 user 目测确认。"
  - id: SC4
    criterion: "新增 ADR 0005（status accepted，supersedes 0002）；ADR 0002 frontmatter status 改为 superseded-by 0005；docs/adr/README.md 索引更新；docs/versions/v0.2.4-popover-redesign.md 与 docs/versions/README.md 路线表更新"
    done: true
    evidence: "立项 commit 7d50888：新增 docs/adr/0005-reopen-multi-provider-direction.md（accepted）、0002 status → superseded-by 0005、adr/README.md + versions/README.md + specs/README.md 索引更新、新增 v0.2.4-popover-redesign.md。"
  - id: SC5
    criterion: "死代码 struct UsageChartView 删除（grep 确认无引用后）；新增 formatResetWithClock / UsagePaceArea.series / ProviderTab 各有单测覆盖（含 nil reset、窗口边界、跨窗口锯齿、clamp 边界、provider 可用性）；cd macos && swift build -c release 与 cd macos && swift test 全绿"
    done: true
    evidence: "struct UsageChartView 删除 @ fac597f（grep 仅剩定义已无）；新增测试文件 ResetCountdownFormatterTests(+5)/UsagePaceAreaTests(5)/ProviderTabTests(3)；swift build -c release 绿、swift test 175 tests 0 failures、make release-artifacts（zip+dmg verify）绿。注：plan 里 UsageProvider 因与存储层同名枚举冲突，UI 维度改名 ProviderTab。"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
manual_checks:
  - "打开 popover 目测：渐变背景 / 圆角卡片 / 图标 / Resets-at-clock 文案 / Pace 标签 / tab bar 选中态与 dimmed 态；切到 Codex 看占位面板再切回"
  - "折线图目测：pace 面积足够浅、明显在两条折线之下、5h 呈锯齿、7d 单条斜坡；悬停 tooltip 与 RuleMark 不变；图例只有 5h / 7d"
  - "dark mode 下目测渐变背景不刺眼、卡片对比度可读"
reviews:
  - gate: G2+G3
    date: 2026-05-12
    reviewer: independent general-purpose subagent (codex fallback per AGENTS §5)
    verdict: approved-after-revisions
    notes: "G2 spec approved-after-revisions（敏感面无；ADR supersede 路径正确）；G3 plan approved-after-revisions。必改已落地：plan Task1 去掉 formatResetWithClock 的悬空 calendar 参数、Task3 把不稳断言改稳；spec 建议（SC2 点明 7d 文案、SC5 补 UsageProvider 测试）已采纳。7d pace 复用 PaceCalculator 的 elapsedFraction>=0.03 噪声阈值 → 开窗前 ~5h 无 Pace 标签（已知行为）。"
---

# Popover 重做 — provider tab 外壳 + 卡片化视觉 + 折线图 pace 面积

## 1. 背景与目标

owner 给了一张参考截图（圆角卡片浮在柔和渐变上、时钟/日历图标、"Resets in: 2h 46m at 11:44 PM"、"Pace: safe"，顶部一排 Claude/Codex/Cursor/Copilot/Gemini tab），要求 popover 朝那个方向重做；同时希望折线图上能看出"配速"——在两条用量折线下方叠一层极浅的 pace 面积，一眼看出此刻比"匀速用完额度"快了还是慢了。

截图里的多 provider tab 与 [ADR 0002](../adr/0002-claude-only-not-multi-provider.md)（"只做 Claude"）冲突；owner 明确要做（"后面准备对接 codex"），故本 spec 同时新增 [ADR 0005](../adr/0005-reopen-multi-provider-direction.md) supersede 0002。本版本只搭 UI 外壳，Codex 数据层对接留给后续独立版本。

落地版本：[v0.2.4 popover-redesign](../versions/v0.2.4-popover-redesign.md)。

## 2. 决策摘要

| 决策点 | 选择 | 原因 / 对应 ADR |
|---|---|---|
| ADR 0002 处置 | 新增 ADR 0005「重新开放多 provider 方向」，0002 status 改 `superseded-by 0005`（正文不动） | ADR append-only；status 变更是 README 规定的 supersede 机制；owner 已授权 |
| provider tab 范围 | 仅 UI 外壳：Claude 可用，其余 4 个「敬请期待」占位；不动数据层、不加 OAuth/CLI 路径 | ADR 0005 step 1；本版本主题是 popover 重做不是多 provider 工程 |
| v0.0.8 的 56pt hero | 去掉，5h / 7d 两卡等权紧凑 | 对齐参考截图（截图两卡同尺寸、无大字号） |
| pace 面积窗口 | 5h + 7d 都画；极浅蓝 / 极浅黄；置于折线之下；不可交互 | owner 选定「5h 和 7d 都画」 |
| pace 窗口边界推导 | 从当前 `resetsAtDate` 按 5h / 7d 步长回推得到窗口序列；5h 跨多窗口时呈锯齿 | Claude 5h 窗口非固定网格、无历史 reset 记录，回推是可接受近似；pace 面积只是参考线，不要求精确 |
| 折线 & 悬停 tooltip | 完全不动 | owner 明确「现有的两条折线 / 鼠标滚动上去显示的用量估计不需要改动」 |
| 7d pace 标签 | 7d 卡片也显示「Pace: safe/fast」（5h 一直有） | 既然 7d 也算 pace 面积，标签一并给；复用 `computePaceState(windowDuration: 7d)` |
| `Pace:` 标签措辞 | `inReserve` / `onPace` / nil-但有数据 → 「safe」绿；`inDeficit` → 「fast」红 | 截图里就一个词；详细 runs-out 倒计时太长，去掉 |
| 死代码 `UsageChartView` | 删除（PopoverView 已改用 `UsageChartSectionView`，实施前 grep 复核无引用） | 顺手清理，避免双份图表代码维护漂移 |
| `UsageHeroCard` 文件名 | 保留文件名与类型名不变，仅重做内部布局、去掉 `size` 参数、加 `icon` 参数 | 减少 churn；"hero card" 名字仍说得通 |
| 卡片化范围 | 用 `UsageCard` 容器包：两个主用量卡 + per-model 区 + extra usage 区 + 趋势图区 + 热力图区；去掉这些区块间的 `Divider()`（卡片间距代替）；底部 footer（settings/refresh/quit/updated）保持裸样式 | 贴合截图"浮动卡片"观感；footer 是工具栏不是内容卡 |

## 3. 设计

### 3.1 Provider tab 外壳（+ ADR 0005）

**新文件 `macos/Sources/ClaudeUsageBar/ProviderTabBar.swift`**：

```swift
enum UsageProvider: String, CaseIterable, Identifiable {
    case claude, codex, cursor, copilot, gemini
    var id: String { rawValue }
    var displayName: String { /* "Claude" / "Codex" / ... */ }
    var isAvailable: Bool { self == .claude }   // 本版本只有 Claude 可用
}
```

- `ProviderTabBar`：水平药丸式分段控件。选中项填充背景（浅色下白底/elevated material，深色下提亮 material）、其余项 `.foregroundStyle(.tertiary)`。`@Binding var selection: UsageProvider`。整体外观贴近截图（圆角胶囊容器 + 内部小药丸）。
- `ProviderComingSoonView(provider:)`（同文件私有）：图标 + 「\(provider.displayName) 支持开发中，敬请期待」+「← 回到 Claude」按钮。
- 不持久化选择（用 `@State`，默认 `.claude`）——切到不可用 provider 只是看占位面板，重开 popover 回到 Claude 没问题。

**`PopoverView` 改动**：

- 已登录分支（现在的 `else` 里 `AccountSwitcherView` + `Text("Claude Usage").font(.headline)` + `usageView`）改为：
  `AccountSwitcherView`（自隐藏不变）→ `ProviderTabBar(selection: $selectedProvider)` → 若 `selectedProvider == .claude` 显示 `usageView`，否则显示 `ProviderComingSoonView(provider: selectedProvider)`。
  原 `Text("Claude Usage")` headline 删掉（tab 里那颗 "Claude" 药丸已经起标识作用）。
- `body` 顶层加柔和渐变背景：`LinearGradient`（顶→底，浅色：极淡蓝→近白；深色：近黑→稍深的近黑，几乎不可见），通过 `.background()` 铺满整个 popover 内容区，放在 `.padding()` 外层。

**ADR**：新增 `docs/adr/0005-reopen-multi-provider-direction.md`（accepted，supersedes 0002，正文已写）；`docs/adr/0002-*.md` frontmatter `status: superseded-by 0005`；`docs/adr/README.md` 索引加 0005 行、0002 状态更新。— 这些文档改动已随本 spec 一并完成。

### 3.2 用量卡片视觉重做

**新 `UsageCard` 容器**（放 `UsageHeroCard.swift` 里，或单独 `UsageCard.swift`——实施时定，倾向同文件）：把任意内容包成圆角卡片——`RoundedRectangle(cornerRadius: 14)` 填充 `.background(.thickMaterial)`（或一个比渐变背景稍亮/稍暗的 subtle fill）+ 内 padding 12 + 细描边或浅阴影（`.shadow(radius: 1, y: 0.5)`）。`PopoverView` 用它包住 3.x 决策表里列的各区块；区块间 spacing ~10，去掉原来的 `Divider()`。

**`UsageHeroCard` 重做**（保留文件名/类型名，去 `size`，加 `icon: String`）：

```
┌─────────────────────────────────────────┐
│ 🕐 5-Hour                     42%  ▼2%   │   row1: Label(icon)+title  …  pct(色)+trend
│ ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │   row2: CapsuleProgressBar (复用, h=8)
│ Resets in: 2h 46m at 11:44 PM   Pace:safe│   row3: caption secondary … caption(色)
└─────────────────────────────────────────┘
```

- row1：左 `Label(title, systemImage: icon)`（5h→`clock`，7d→`calendar`）`.font(.subheadline).foregroundStyle(.secondary)`；右 `Text("\(pct)%")` `.font(.title3).weight(.semibold)` rounded monospacedDigit，颜色 `colorForPct`；紧跟趋势箭头 `Text("▼2%")` `.caption2` monospacedDigit（绿/红，逻辑不变）。无数据时 pct 显示 "—"。
- row2：`CapsuleProgressBar(value: pct/100, color: colorForPct(...))`，height 8（复用现有组件）。
- row3：左 `Text("Resets in: \(formatResetWithClock(date: resetDate, now: Date()))")` `.caption` secondary；右 `Text("Pace: \(paceWord.text)")` `.caption` `.foregroundStyle(paceWord.color)`。若 `resetDate == nil` → 整行省略左半（或整行不显示）；若 pace 为 nil → 不显示右半。
- 删掉 `enum UsageCardSize`；`PopoverView` 两处调用改为 `UsageHeroCard(label:bucket:trend:pace:icon:)`，7d 那处也传 `pace:`（见下）和 `icon: "calendar"`。
- `#Preview` 相应更新。

**新 formatter `formatResetWithClock(date: Date?, now: Date) -> String?`**（加在 `ResetCountdownFormatter.swift`）：

- `date == nil` → `nil`。
- `date - now <= 0` → `nil`（或复用 `formatResetCountdown` 的行为）。
- `date - now < 24h` → `"\(formatResetCountdown(date:now:)) at \(date 格式化为 .hour().minute())"`，例：`"2h 46m at 11:44 PM"`。
- 否则 → `formatResetCountdown(date:now:)`，例：`"4 days 5h 59m"`（依赖现有实现的多 days 格式）。
- 注：现有 `formatResetCountdown` 只输出 "Xh Ym" / "Ym" / "<1m"，**不含 days** —— 所以 `formatResetWithClock` 的 "≥24h" 分支必须自己用整除算 days，不能直接复用 `formatResetCountdown`。

**7d pace 计算**（`PopoverView.usageView`）：现有只算 `pace5h`，新增
`let pace7d = computePaceState(currentPct: service.usage?.sevenDay?.utilization, resetDate: service.usage?.sevenDay?.resetsAtDate, windowDuration: 7*24*3600)`，传给 7d 的 `UsageHeroCard`。`PaceCalculator.swift` 不改（`windowDuration` 已是参数）。注意 `computePaceState` 内有 `elapsedFraction >= 0.03` 早退（开窗初期噪声大，隐藏），对 7d 窗口意味着**新窗口开始后约 5 小时内 7d 卡不显示 Pace 标签**——已知行为，可接受。

**`paceWord(_:) -> (text: String, color: Color)?`**（放 `UsageHeroCard.swift`）：`nil` → `nil`；`.onPace` / `.inReserve` → `("safe", .green)`；`.inDeficit` → `("fast", .red)`。

### 3.3 折线图 pace 面积

**透传 reset 日期**：`UsageChartSectionView` 增加 `fiveHourResetDate: Date?` / `sevenDayResetDate: Date?` 两个参数，往下传给 `UsageChartContentView`；`PopoverView` 调用处传 `service.usage?.fiveHour?.resetsAtDate` / `service.usage?.sevenDay?.resetsAtDate`。

**pace 序列 helper**（加在 `UsageChartView.swift` 文件里，紧挨 `UsageChartInterpolation`）：

```swift
struct PacePoint: Identifiable { let id = UUID(); let date: Date; let pct: Double }

enum UsagePaceArea {
    /// reset==nil → []。否则在 [domainStart, domainEnd] 上等距采样 sampleCount+1 个点，
    /// 每点求其所在窗口内 elapsed 比例 ×100：
    ///   k = max(0, floor((reset - t) / windowDuration))
    ///   windowStart = reset - windowDuration*(k+1)
    ///   pct = clamp((t - windowStart)/windowDuration, 0, 1) * 100
    static func series(reset: Date?, windowDuration: TimeInterval,
                       domainStart: Date, domainEnd: Date,
                       sampleCount: Int = 240) -> [PacePoint]
}
```

- 5h：`windowDuration = 5*3600` → 跨多个 5h 窗口时 `pct` 在每个窗口边界从 100 跌回 0，呈锯齿（密集采样下边界是陡坡而非完美竖线，可接受）。
- 7d：`windowDuration = 7*24*3600` → 通常 domain（≤30 天）内最多跨一两个窗口，主要是一条 0→100 的斜坡；domain 起点早于窗口起点的部分 `pct` 仍按公式落在 [0,100]，符合直觉。
- `domainStart = Date.now - selectedRange.interval`，`domainEnd = Date.now`（与 `chartXScale` 一致）。

**`UsageChartContentView.chartView` 改动**：在 `Chart { }` **最前面**（先画 = 在底层）加：

```swift
let pace5h = UsagePaceArea.series(reset: fiveHourResetDate, windowDuration: 5*3600, domainStart: ..., domainEnd: ...)
let pace7d = UsagePaceArea.series(reset: sevenDayResetDate, windowDuration: 7*24*3600, domainStart: ..., domainEnd: ...)

ForEach(pace7d) { p in
    AreaMark(x: .value("Time", p.date), y: .value("Pace 7d", p.pct))
}
.foregroundStyle(Color.orange.opacity(0.08))
.interpolationMethod(.linear)

ForEach(pace5h) { p in
    AreaMark(x: .value("Time", p.date), y: .value("Pace 5h", p.pct))
}
.foregroundStyle(Color.blue.opacity(0.10))
.interpolationMethod(.linear)
```

然后才是现有的两组 `LineMark`（用 `.foregroundStyle(by:)` + `chartForegroundStyleScale` —— 不动），最后是 hover 的 `RuleMark` / `PointMark`（不动）。因为 AreaMark 用直接 `.foregroundStyle(Color…)` 而非 `by:`，不会进图例；图例仍只有 "5h" / "7d"。`chartYScale(domain: 0...100)`、`chartOverlay` hover、`tooltipView` 全不动。

**删死代码**：`UsageChartView` struct（文件顶部那个独立的、PopoverView 已不用的版本）删除；`UsageChartInterpolation` / `UsageChartInterpolatedValues` 保留（`UsageChartContentView` 在用）。实施第一步：`grep -rn "UsageChartView" macos/` 确认除定义外无引用（含测试），再删。

### 3.4 测试

- `formatResetWithClock`：nil → nil；<24h → "Xh Ym at H:MM"（用固定 now/date，注意时区/locale，断言用 `Calendar`/`DateComponents` 构造或断言子串）；≥24h → 与 `formatResetCountdown` 一致；reset 已过 → nil。
- `UsagePaceArea.series`：reset==nil → []；单窗口内单调递增 0→…；正好跨一个 5h 边界时序列里存在"前点≈100、后点≈0"的相邻对；t 接近 reset 时 pct→100；domainStart 远早于窗口序列时仍全部落 [0,100]；sampleCount 个数正确。
- 加到现有 test target（`UsageServiceTests` 同目录），新建 `ResetCountdownFormatterTests` / `UsagePaceAreaTests`（若已有同名则追加 case）。

### 3.5 错误处理 / 降级

- `service.usage == nil`（未拿到数据）：卡片 pct 显示 "—"、进度条 0、无 "Resets in"/"Pace" 行——沿用现有 `UsageHeroCard` 的空态逻辑。
- pace 面积：任一 reset 为 nil → 该面积不画（空序列）。两个都 nil → 图退化成现状（只有两条线），无报错。
- provider 切到不可用项：纯展示占位面板，不触发任何网络/数据动作。

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `docs/adr/0005-reopen-multi-provider-direction.md` | accepted，supersedes 0002（已写） |
| 🔧 | `docs/adr/0002-claude-only-not-multi-provider.md` | 仅 frontmatter `status: superseded-by 0005`（正文不动，已改） |
| 🔧 | `docs/adr/README.md` | 索引加 0005、0002 状态更新、`updated` 改 2026-05-12（已改） |
| 🆕 | `docs/versions/v0.2.4-popover-redesign.md` | 已写（status planned） |
| 🔧 | `docs/versions/README.md` | 路线表加 v0.2.4、`updated` 与"截止于"注更新（已改） |
| 🆕 | `docs/superpowers/specs/2026-05-12-popover-redesign.md` | 本文件 |
| 🔧 | `docs/superpowers/specs/README.md` | 索引 append 本 spec（实施 G4 文档 commit 时一并） |
| 🆕 | `macos/Sources/ClaudeUsageBar/ProviderTabBar.swift` | `UsageProvider` enum + `ProviderTabBar` view + `ProviderComingSoonView` |
| 🔧 | `macos/Sources/ClaudeUsageBar/PopoverView.swift` | tab bar 接线 + 渐变背景 + 各区块换 `UsageCard` + 去 Divider + 算 `pace7d` + 给图传 reset 日期 + 去 `Text("Claude Usage")` |
| 🔧 | `macos/Sources/ClaudeUsageBar/UsageHeroCard.swift` | 重做布局、去 `UsageCardSize` 与 `size` 参数、加 `icon`、加 `paceWord`；可能在此加 `UsageCard` 容器 |
| 🔧 | `macos/Sources/ClaudeUsageBar/UsageChartView.swift` | 删死代码 `UsageChartView` struct；`UsageChartSectionView`/`UsageChartContentView` 加 reset 日期参数；加 `PacePoint` + `UsagePaceArea`；`chartView` 加两组 `AreaMark` |
| 🔧 | `macos/Sources/ClaudeUsageBar/ResetCountdownFormatter.swift` | 加 `formatResetWithClock(date:now:)` |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/ResetCountdownFormatterTests.swift`（或追加） | `formatResetWithClock` 测试 |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/UsagePaceAreaTests.swift`（或追加） | `UsagePaceArea.series` 测试 |
| ✅ 不动 | `UsageService.swift` / `UsageHistoryService.swift` / `UsageStatsService.swift` / 数据层 / `PaceCalculator.swift`（仅以不同 `windowDuration` 复用） | 本 spec 不碰数据/服务层 |
| ✅ 不动 | 折线图的悬停 `chartOverlay` / `tooltipView` / `UsageChartInterpolation` / `chartForegroundStyleScale` / 图例 | owner 明确不动 |

> 实施时确认测试 target 的实际目录名（`macos/Tests/...`），新建文件按现有命名惯例放。

## 5. 风险 / Open questions

1. **5h 窗口边界靠回推近似**：用户在窗口中途打开 app、且过去某些 5h 窗口的真实起点与"按 5h 步长回推"不一致时，锯齿位置会偏。pace 面积只是参考，可接受；spec 不要求精确历史窗口对齐。
2. **渐变背景在 dark mode 的观感**需实测调参——目标是"几乎看不出渐变、只是不死板"，可能要做到 opacity 极低甚至接近纯色。
3. **去掉 56pt hero 是对 v0.0.8（`2026-05-11-hero-popover`）的局部回退**——已被本 spec §2 决策覆盖（owner 要求对齐截图）。v0.0.8 spec 状态不变（implemented 不可变），仅本 spec 在此声明取代其卡片尺寸设计。
4. **`Pace:` 措辞 / 颜色 / 渐变强度**都是审美参数，实施时按截图微调，不再回 owner 确认（owner 已授权 UI 细节自决）。
5. **provider 占位面板交互极简**——真正的多 provider 架构（descriptor / 多 strategy）不在本版本，后续 Codex 数据层 spec 再设计。
6. **`UsageChartView` 是否真无引用**：实施第一步 grep 复核；若发现还有引用（含 `#Preview` 之外的代码或测试），改为合并而非删除。

## 6. 后续工作（不在本 spec 范围）

- Codex 数据层对接（独立版本）：复用 v0.2.3 per-provider 存储，新建 Codex 凭证/用量 strategy；届时 `UsageProvider.codex.isAvailable` 转 true。
- 其余 provider（Cursor / Copilot / Gemini）视用户需求再排，或从 tab 列表移除。
- 折线图 pace 边界精确化（若 Claude 暴露历史窗口起点）。
- 可能恢复某种"主窗口强调"（非 56pt，但比 7d 略突出）。

## 7. 引用

- 相关 ADR：[`0005-reopen-multi-provider-direction.md`](../adr/0005-reopen-multi-provider-direction.md)（supersedes [`0002`](../adr/0002-claude-only-not-multi-provider.md)）；[`0001-swift-native-only.md`](../adr/0001-swift-native-only.md)
- 相关 spec：[`2026-05-11-hero-popover.md`](./2026-05-11-hero-popover.md)（本 spec 局部取代其卡片尺寸设计）、[`2026-05-11-pace-tracking.md`](./2026-05-11-pace-tracking.md)（复用 `PaceState`/`computePaceState`）、[`2026-05-12-usage-store-redesign.md`](./2026-05-12-usage-store-redesign.md)（per-provider 存储为后续 Codex 对接铺路）
- 落地版本：[`../versions/v0.2.4-popover-redesign.md`](../versions/v0.2.4-popover-redesign.md)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [x] SC1 — provider tab + 占位面板已实现（9106c4b + 75852df）；app 启动无崩溃；视觉待 user 目测
- [x] SC2 — 卡片化 / 图标 / Resets-at-clock 文案 / Pace 标签 / 渐变背景已实现（662e78d + 2316efc + 3e912b0 + 75852df）；视觉 + dark mode 待 user 目测
- [x] SC3 — 折线图叠 5h/7d pace 面积（在底层、不进图例）已实现（a28bbe0 + fac597f + 75852df）；悬停/tooltip 未改；浅度/锯齿待 user 目测
- [x] SC4 — ADR 0005 新增 + 0002 superseded + 各 README/version 索引更新（7d50888）
- [x] SC5 — 死代码 UsageChartView 删除 + 13 条新单测；swift build -c release / swift test(175) / make release-artifacts 全绿

> 备注：manual_checks 三项（popover 目测、折线图目测、dark mode 目测）尚待 user 在本机确认 —— 实施环境无法做可视化验证，已用 `make app` 烟测确认进程不崩溃。若目测发现样式问题，作为 v0.2.4 范围内的 follow-up 修。
