# SwiftUI hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec `2026-05-13-swiftui-hygiene`：3 处 high bug 修复 + 5 条 low hygiene 替换 + 2 处死代码下线，v0.3.0 → v0.3.1。

**Architecture:** 全部为局部内部修改 + 1 个字段删除 + 1 个协议成员退役。不动 Package.swift / Info.plist / OAuth / Sparkle 任何链路。改动按主题分 4 个 commit：① docs / ② 3 个 high bug / ③ low hygiene / ④ 死代码下线。每个 commit 后跑 `swift build -c release && swift test`。

**Tech Stack:** Swift 5.9, SwiftUI（macOS 14+）, Swift Charts, XCTest。

---

## Verification 规范

每个 Task 末尾的 verify 步骤都跑：

```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
```

期望：build success、`Test Suite 'All tests' passed`、0 failed。

最后一个 Task（集成 verify）额外跑 `make release-artifacts` 与 `verify-release.sh`。

---

## Task 1: docs commit（spec + 3 个 version + README 路线表）

文档已写完，先单独 commit 便于回滚定位。

**Files:**
- Created: `docs/superpowers/specs/2026-05-13-swiftui-hygiene.md`
- Created: `docs/versions/v0.3.1-swiftui-hygiene.md`
- Created: `docs/versions/v0.4.0-view-layer-modernization.md`
- Created: `docs/versions/v0.5.0-observable-migration.md`
- Created: `docs/superpowers/plans/2026-05-13-swiftui-hygiene.md`（本文件）
- Modified: `docs/versions/README.md`

- [ ] **Step 1: 确认文档改动状态**

```bash
cd /Users/methol/data/code-methol/usage-bar
git status
```

期望：5 个新文件 + 1 个修改文件，工作树无其它改动。

- [ ] **Step 2: stage + commit docs**

```bash
git add docs/
git commit -m "docs: 立项 v0.3.1 SwiftUI hygiene spec + v0.4.0/v0.5.0 占位 [spec:2026-05-13-swiftui-hygiene]

- 新增 spec 2026-05-13-swiftui-hygiene：3 处 high bug + 5 条 low hygiene + 2 处死代码下线
- 新增 v0.3.1 落地版本（planned）
- 新增 v0.4.0 view-layer-modernization、v0.5.0 observable-migration 两个 placeholder
- versions/README.md 路线表 append 三行
- 同时落 implementation plan 文件"
```

---

## Task 2: SC1 — UsageChartView plotFrame guard

消除 `geo[proxy.plotFrame!]` 强解包崩溃路径。

**Files:**
- Modify: `macos/Sources/UsageBar/UsageChartView.swift:196-212`

- [ ] **Step 1: 读现场代码**

```bash
sed -n '190,215p' macos/Sources/UsageBar/UsageChartView.swift
```

确认 `chartOverlay { proxy in GeometryReader { geo in ... .onContinuousHover { phase in switch phase { case .active(let location): let plotOrigin = geo[proxy.plotFrame!].origin ... } } } }` 结构与 spec §3.1 一致。

- [ ] **Step 2: 用 Edit 工具替换 hover 处理**

`old_string` = `.onContinuousHover { phase in switch phase` 块内 `case .active` 那段（包含 `proxy.plotFrame!`）。

`new_string`：

```swift
case .active(let location):
    guard let plot = proxy.plotFrame else {
        hoverDate = nil
        return
    }
    let plotOrigin = geo[plot].origin
    let x = location.x - plotOrigin.x
    if let date: Date = proxy.value(atX: x) { hoverDate = date }
```

- [ ] **Step 3: 本地验证**

```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
```

期望：build green，all tests pass。

---

## Task 3: SC2 — UsageHeatmapView model 缓存

把 `UsageHeatmapModel` 从 computed property 提升为 `@State`，daySpends 变化时通过 `onChange` 重建。

**Files:**
- Modify: `macos/Sources/UsageBar/UsageHeatmapView.swift`（多处）

- [ ] **Step 1: 读 UsageHeatmapView 完整结构**

```bash
sed -n '1,160p' macos/Sources/UsageBar/UsageHeatmapView.swift
```

定位：
- 现状 `private var model: UsageHeatmapModel { UsageHeatmapModel(daySpends: daySpends) }`
- 现状 `@State private var hovered: UsageHeatmapModel.Cell?`
- 现状 view init / 顶层属性结构

- [ ] **Step 2: 把 model 改 @State + 加 init**

替换属性区与 init：

```swift
// 老代码（property + computed model）
@State private var hovered: UsageHeatmapModel.Cell?
private var model: UsageHeatmapModel { UsageHeatmapModel(daySpends: daySpends) }

let daySpends: [DaySpend]
let isInitializing: Bool

// 新代码
@State private var hovered: UsageHeatmapModel.Cell?
@State private var model: UsageHeatmapModel

let daySpends: [DaySpend]
let isInitializing: Bool

init(daySpends: [DaySpend], isInitializing: Bool) {
    self.daySpends = daySpends
    self.isInitializing = isInitializing
    _model = State(initialValue: UsageHeatmapModel(daySpends: daySpends))
}
```

注：属性顺序保留 SwiftUI 习惯（`@State` 在前）。

- [ ] **Step 3: 在 body 的 root 容器加 onChange**

在 `var body: some View { ... }` 的最外层 view（通常是 VStack / HStack / ScrollView）上加：

```swift
.onChange(of: daySpends) { _, newValue in
    model = UsageHeatmapModel(daySpends: newValue)
}
```

`DaySpend` 已是 `Equatable`（`UsageAggregator.swift:128` 确认），新 onChange 签名直接可用。

- [ ] **Step 4: 本地验证**

```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
```

期望 build green、tests green。若 `UsageHeatmapModelTests` 存在则一并跑过；若无，不补新测试（YAGNI）。

---

## Task 4: SC3 — LocalCostCard Button 化

把整张卡的 `.onTapGesture` 改为 `Button + .buttonStyle(.plain)`，让 VoiceOver 识别为按钮。

**Files:**
- Modify: `macos/Sources/UsageBar/LocalCostCard.swift:43-136`

- [ ] **Step 1: 读 LocalCostCard.body 全文**

```bash
sed -n '43,140p' macos/Sources/UsageBar/LocalCostCard.swift
```

确认 body 结构是 `VStack { Grid { ... } if expanded { ... } } .frame .padding .background .contentShape .onTapGesture { ... }`。

- [ ] **Step 2: 用 Button 包裹整个 VStack，删除 onTapGesture**

`old_string`：

```swift
.frame(maxWidth: .infinity)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        }
    }
```

`new_string`（保留 padding/background/contentShape 在 Button label 内；Button 包整 body；最后挂 buttonStyle + accessibility）：

```swift
.frame(maxWidth: .infinity)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
```

然后把 `var body: some View {` 后的 `VStack(alignment: .leading, spacing: 6) {` 改成：

```swift
Button {
    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
} label: {
    VStack(alignment: .leading, spacing: 6) {
```

并把 body 结束的 `}` 改为：

```swift
        }   // end VStack
    }       // end Button label
    .buttonStyle(.plain)
    .accessibilityLabel("本机消费明细")
    .accessibilityHint(expanded ? "收起" : "展开")
}           // end body
```

> 注：上面要做 3 处 Edit。先把 `.onTapGesture` 块整段删掉、保留 `.background`；再把开头 `VStack` 包进 `Button { } label: { VStack { ... } }`；最后把 body 结束补 `.buttonStyle(.plain) + 2 个 accessibility`。

- [ ] **Step 3: 本地验证**

```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
```

期望 build green、tests green。

- [ ] **Step 4: 合并 commit 3 个 high bug**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/UsageChartView.swift \
        macos/Sources/UsageBar/UsageHeatmapView.swift \
        macos/Sources/UsageBar/LocalCostCard.swift
git status
git commit -m "fix: 修 SwiftUI 3 处 high 风险 [spec:2026-05-13-swiftui-hygiene]

- UsageChartView: plotFrame 改 guard let，消除 hover 时强解包崩溃路径 (SC1)
- UsageHeatmapView: UsageHeatmapModel 由 computed 改 @State 缓存，daySpends 变化 onChange 重建；
  消除 hover 帧每次重算 53×7 网格的性能问题 (SC2)
- LocalCostCard: onTapGesture 改 Button + .buttonStyle(.plain)，VoiceOver 可识别为按钮 (SC3)"
```

---

## Task 5: SC4 — UsageService final + Task.sleep(for:)

**Files:**
- Modify: `macos/Sources/UsageBar/UsageService.swift:6`
- Modify: `macos/Sources/UsageBar/UsageService.swift:766`

- [ ] **Step 1: UsageService 加 final**

`old_string` = `class UsageService: ObservableObject`
`new_string` = `final class UsageService: ObservableObject`

（替换 UsageService.swift:6 那一处定义；要保留 `@MainActor` 等其它修饰。先 Read 该行附近确认完整签名。）

- [ ] **Step 2: Task.sleep 改新签名**

`old_string` = `try? await Task.sleep(nanoseconds: 100_000_000)`
`new_string` = `try? await Task.sleep(for: .milliseconds(100))`

- [ ] **Step 3: 本地 build 验证**

```bash
cd macos && swift build -c release 2>&1 | tail -5
```

期望 green。`final` 不破坏现有继承（仓库无 UsageService 子类，已确认）。

---

## Task 6: SC5 — 去掉 ForEach 中 Array(seq.enumerated()) 的外层 Array

3 处替换，全是 SwiftUI ForEach。

**Files:**
- Modify: `macos/Sources/UsageBar/UsageHeatmapView.swift:102`
- Modify: `macos/Sources/UsageBar/UsageHeatmapView.swift:104`
- Modify: `macos/Sources/UsageBar/MultiMenuBarLabel.swift:36`

- [ ] **Step 1: 改 UsageHeatmapView 第一处**

`old_string` = `ForEach(Array(m.weeks.enumerated()), id: \.offset) { idx, col in`
`new_string` = `ForEach(m.weeks.enumerated(), id: \.offset) { idx, col in`

- [ ] **Step 2: 改 UsageHeatmapView 第二处**

`old_string` = `ForEach(Array(col.enumerated()), id: \.offset) { _, cell in`
`new_string` = `ForEach(col.enumerated(), id: \.offset) { _, cell in`

- [ ] **Step 3: 改 MultiMenuBarLabel**

`old_string` = `ForEach(Array(ids.enumerated()), id: \.element) { index, id in`
`new_string` = `ForEach(ids.enumerated(), id: \.element) { index, id in`

- [ ] **Step 4: 本地 build 验证**

```bash
cd macos && swift build -c release 2>&1 | tail -5
```

期望 green。

---

## Task 7: SC6 — UsageBarApp 去掉多余 Task.detached

**Files:**
- Modify: `macos/Sources/UsageBar/UsageBarApp.swift:51,52`

- [ ] **Step 1: 改两个 onPollTick 赋值**

`old_string` = 

```swift
                    coordinator.claude.onPollTick = { Task.detached { await usageStats.refresh() } }
                    coordinator.provider(.codex)?.onPollTick = { Task.detached { await codexStats.refresh() } }
```

`new_string` =

```swift
                    coordinator.claude.onPollTick = { Task { await usageStats.refresh() } }
                    coordinator.provider(.codex)?.onPollTick = { Task { await codexStats.refresh() } }
```

> 注：`UsageStatsService.refresh()` 内部自管 `Task.detached(priority: .utility)`，外层不需要再 detach。

- [ ] **Step 2: 同步 UsageService.swift:42 的注释**

该注释提到 "装配处设成 `{ Task.detached { await usageStats.refresh() } }`"——与新装配方式不符，把 `Task.detached` 改 `Task`。

`old_string` = `（驱动 Claude 的本机用量统计刷新；装配处设成 `{ Task.detached { await usageStats.refresh() } }`）。`
`new_string` = `（驱动 Claude 的本机用量统计刷新；装配处设成 `{ Task { await usageStats.refresh() } }`）。`

- [ ] **Step 3: 本地验证**

```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
```

期望 build green、tests green。

- [ ] **Step 4: 合并 commit 4 条 low hygiene**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/UsageService.swift \
        macos/Sources/UsageBar/UsageHeatmapView.swift \
        macos/Sources/UsageBar/MultiMenuBarLabel.swift \
        macos/Sources/UsageBar/UsageBarApp.swift
git status
git commit -m "chore: SwiftUI 低风险 hygiene 替换 [spec:2026-05-13-swiftui-hygiene]

- UsageService: 加 final、Task.sleep(nanoseconds:) 改 Task.sleep(for: .milliseconds(100)) (SC4)
- UsageHeatmapView/MultiMenuBarLabel: 去掉 ForEach 中 Array(seq.enumerated()) 的外层 Array(...)（3 处）(SC5)
- UsageBarApp: onPollTick 闭包去掉多余 Task.detached 包裹；同步 UsageService.swift:42 注释 (SC6)"
```

---

## Task 8: SC7 — CreditLine.currencyCode 字段下线

**Files:**
- Modify: `macos/Sources/UsageBar/ProviderUsageSnapshot.swift:55,63,70`
- Modify: `macos/Sources/UsageBar/CodexUsageModel.swift:131`
- Modify: `macos/Sources/UsageBar/UsageModel.swift:252`

- [ ] **Step 1: 删 ProviderUsageSnapshot 字段定义 + init 参数 + 赋值**

先 Read 周围上下文（line 50-75），看 init 完整签名。

- 删 `var currencyCode: String?` 那一行（line 55）
- 删 init 签名里的 `currencyCode: String? = nil` 参数（line 63）
- 删 init body 里的 `self.currencyCode = currencyCode`（line 70）

注意：删除字段后，所有 init 调用都必须移除 `currencyCode:` 实参，否则编译失败。

- [ ] **Step 2: 删 CodexUsageModel 赋值点**

`macos/Sources/UsageBar/CodexUsageModel.swift:131` 附近是 `CreditLine(... currencyCode: "USD")` 的多行调用。删 `currencyCode: "USD"` 这一行（可能含末尾逗号）。

读 line 125-135 确认完整调用结构后，用 Edit 把 `currencyCode: "USD")` 改成 `)`（去最后一个参数 + 行）。

- [ ] **Step 3: 删 UsageModel 赋值点**

`macos/Sources/UsageBar/UsageModel.swift:252` 是 `currencyCode: nil`。同上，读上下文删行。

- [ ] **Step 4: grep 验证 0 命中**

```bash
grep -rn 'currencyCode' macos/Sources macos/Tests
```

期望：0 命中。

- [ ] **Step 5: 本地 build + test**

```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
```

期望 build green、tests green。

---

## Task 9: SC8 — UsageProvider.supportsBackgroundPolling 协议成员退役

**Files:**
- Modify: `macos/Sources/UsageBar/UsageProvider.swift:15-18`（删协议成员 + TODO 注释）
- Modify: `macos/Sources/UsageBar/CodexProvider.swift:14`
- Modify: `macos/Sources/UsageBar/UsageService.swift:868`
- Modify: `macos/Tests/UsageBarTests/CodexProviderTests.swift:253,310-333`
- Modify: `macos/Tests/UsageBarTests/ProviderCoordinatorTests.swift:199`
- Modify: `macos/Tests/UsageBarTests/ProviderAbstractionTests.swift:237`

- [ ] **Step 1: 读 UsageProvider 协议定义周边**

```bash
sed -n '10,25p' macos/Sources/UsageBar/UsageProvider.swift
```

定位 TODO 注释（"v0.2.10 起没有消费者..."）+ `var supportsBackgroundPolling: Bool { get }` 行。

- [ ] **Step 2: 删协议成员 + 周边注释**

把 `var supportsBackgroundPolling: Bool { get }` 这行 + 它上面/下面紧贴的 TODO 注释（关于 v0.2.10 退役那段）一起删掉。

- [ ] **Step 3: 删 CodexProvider 的 impl**

`old_string` = `    let supportsBackgroundPolling = false`
`new_string` = ``（删整行）

如果该行前后有空行需要修正缩进，用 Read 看上下文。

- [ ] **Step 4: 删 UsageService 的 impl**

`macos/Sources/UsageBar/UsageService.swift:868` 是 `var supportsBackgroundPolling: Bool { true }`。删整行。

- [ ] **Step 5: 删 CodexProviderTests 两处断言**

`macos/Tests/UsageBarTests/CodexProviderTests.swift:253` = `XCTAssertFalse(p.supportsBackgroundPolling)`
`macos/Tests/UsageBarTests/CodexProviderTests.swift:333` = `XCTAssertFalse(CodexProvider().supportsBackgroundPolling)`

两处都删整行。第 310 行附近的 "v0.2.10 退役了 primaryEligibleIDs..." 注释保留（讲的是 primaryEligibleIDs 已退役、不是 supportsBackgroundPolling）。

> 注意：要先 Read 310-335 看清楚那段注释是讲哪个 retire，避免误删。

- [ ] **Step 6: 删 ProviderCoordinatorTests 断言**

`macos/Tests/UsageBarTests/ProviderCoordinatorTests.swift:199` = `var supportsBackgroundPolling = false`

读该行上下文 — 这通常是 test spy 类的属性定义。删整行。

- [ ] **Step 7: 删 ProviderAbstractionTests 断言**

`macos/Tests/UsageBarTests/ProviderAbstractionTests.swift:237` = `var supportsBackgroundPolling: Bool = false`

同上，是 spy 类属性。删整行。

- [ ] **Step 8: grep 验证 0 命中**

```bash
grep -rn 'supportsBackgroundPolling' macos/Sources macos/Tests
```

期望：0 命中。

- [ ] **Step 9: 本地 build + test**

```bash
cd macos && swift build -c release 2>&1 | tail -5
cd macos && swift test 2>&1 | tail -20
```

期望 build green、tests green（若 spy class 缺成员导致 protocol conformance 失败，要回 Step 1 检查删漏的协议默认实现 / extension）。

- [ ] **Step 10: 合并 commit 死代码下线**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add macos/Sources/UsageBar/ProviderUsageSnapshot.swift \
        macos/Sources/UsageBar/CodexUsageModel.swift \
        macos/Sources/UsageBar/UsageModel.swift \
        macos/Sources/UsageBar/UsageProvider.swift \
        macos/Sources/UsageBar/CodexProvider.swift \
        macos/Sources/UsageBar/UsageService.swift \
        macos/Tests/UsageBarTests/CodexProviderTests.swift \
        macos/Tests/UsageBarTests/ProviderCoordinatorTests.swift \
        macos/Tests/UsageBarTests/ProviderAbstractionTests.swift
git status
git commit -m "chore: 死代码下线 currencyCode + supportsBackgroundPolling [spec:2026-05-13-swiftui-hygiene]

- CreditLine.currencyCode 字段：仅 Codex 写 \"USD\" / Claude 写 nil，UI 写死 \$ 前缀从不读，
  删字段 + init 参数 + 2 处赋值（SC7）
- UsageProvider.supportsBackgroundPolling 协议成员：v0.2.10 起生产 0 读，
  删协议成员 + 2 个 conformer impl + 4 处测试断言（SC8）"
```

---

## Task 10: SC9 + SC10 — 集成验证

完整跑 build + test + release-artifacts + verify-release。

- [ ] **Step 1: 最终 grep 校验**

```bash
cd /Users/methol/data/code-methol/usage-bar
grep -rn 'currencyCode' macos/Sources macos/Tests | wc -l
grep -rn 'supportsBackgroundPolling' macos/Sources macos/Tests | wc -l
grep -rn 'Task.sleep(nanoseconds:' macos/Sources | wc -l
grep -rn 'ForEach(Array(' macos/Sources | wc -l
```

期望全部输出 `0`。

- [ ] **Step 2: 完整 swift test**

```bash
cd macos && swift test 2>&1 | tail -30
```

期望 0 failed。记录测试通过数（如 "273 tests passed"）。

- [ ] **Step 3: make release-artifacts**

```bash
cd /Users/methol/data/code-methol/usage-bar
make release-artifacts 2>&1 | tail -20
```

期望：build green、zip 创建、dmg 创建。

- [ ] **Step 4: verify-release.sh**

```bash
bash macos/scripts/verify-release.sh macos/UsageBar.zip 2>&1 | tail -20
```

期望全 check green（含 litellm_model_prices.json、THIRD_PARTY_LICENSES.txt invariant）。

---

## Task 11: 关闸 — spec frontmatter close-out

把 spec 的 `spec_criteria` 全 done + 填 evidence，`status: draft` 升 `accepted`（G2 通过；本仓库自动化 review 见末尾说明），最终改 `implemented`。

**Files:**
- Modify: `docs/superpowers/specs/2026-05-13-swiftui-hygiene.md`

- [ ] **Step 1: 收集 evidence 字符串**

对每条 SC 整理 evidence。例如：
- SC1：`"UsageChartView.swift: guard let plot = proxy.plotFrame; UsageChartView.swift:200-208"`
- SC2：`"UsageHeatmapView.swift: @State model + onChange(of: daySpends); UsageHeatmapView.swift:84-95"`
- ...
- SC9：`"swift test: <N> passed 0 failed"`（用 Step 2 实际数字替换 N）
- SC10：`"make release-artifacts + verify-release.sh: all green"`

- [ ] **Step 2: 批量 Edit frontmatter**

把每条 `done: false` 改 `done: true`，`evidence: null` 改成对应字符串。

- [ ] **Step 3: 改 status + Verification log**

```yaml
status: implemented
updated: 2026-05-13
```

Verification log section 把 `- [ ] SC1 — pending` 改成 `- [x] SC1 — <evidence 简述>`，10 行都改。

- [ ] **Step 4: 同步 v0.3.1 version 文件**

`docs/versions/v0.3.1-swiftui-hygiene.md`：
- frontmatter `status: planned` → `status: in-progress`（等 PR merge 后再 → shipped）
- 不动 `shipped_date`（发 tag 时填）

- [ ] **Step 5: commit spec close-out**

```bash
cd /Users/methol/data/code-methol/usage-bar
git add docs/superpowers/specs/2026-05-13-swiftui-hygiene.md \
        docs/versions/v0.3.1-swiftui-hygiene.md
git commit -m "docs: v0.3.1 SwiftUI hygiene SC1-SC10 验收完成 [spec:2026-05-13-swiftui-hygiene]

- spec status: draft → implemented
- 10 条 spec_criteria 全部 done + 填 evidence
- v0.3.1 version status: planned → in-progress（等 tag 推送转 shipped）"
```

---

## Task 12: push + 开 PR

- [ ] **Step 1: push branch**

```bash
git push -u origin feat/v0.3.1-swiftui-hygiene
```

- [ ] **Step 2: 用 gh 开 PR**

```bash
gh pr create --base main --head feat/v0.3.1-swiftui-hygiene \
  --title "v0.3.1 SwiftUI hygiene：3 处 high bug + low 清理 + 死代码下线 [spec:2026-05-13-swiftui-hygiene]" \
  --body "$(cat <<'EOF'
## 概要

落地 spec [`2026-05-13-swiftui-hygiene`](../blob/feat/v0.3.1-swiftui-hygiene/docs/superpowers/specs/2026-05-13-swiftui-hygiene.md)：v0.3.0 Provider 自主管理 merge 后做了一次 SwiftUI 现代化 audit（macOS 14+/Swift 5.9 约束），本 PR 收 audit 中**风险最低**的一组改动；view 层重构（Binding/ViewBuilder）留 v0.4.0，@Observable 迁移留 v0.5.0。

## High 修复（影响正确性 / 性能 / 可访问性）

- **SC1** `UsageChartView`：`proxy.plotFrame!` 改 `guard let plot = proxy.plotFrame`，消除 hover 时 chart 未布局完的强解包崩溃路径
- **SC2** `UsageHeatmapView`：`UsageHeatmapModel` 由 computed property 提升为 `@State`，`onChange(of: daySpends)` 重建；消除 hover 帧每次重算 53×7 网格的性能问题
- **SC3** `LocalCostCard`：整张卡 `onTapGesture` 改 `Button + .buttonStyle(.plain)`，VoiceOver 可识别为按钮

## Low hygiene

- **SC4** `UsageService` 加 `final`；`Task.sleep(nanoseconds:)` 改 `Task.sleep(for:)`
- **SC5** `UsageHeatmapView`（2 处）/ `MultiMenuBarLabel`（1 处）的 `ForEach(Array(seq.enumerated()), …)` 去外层 `Array(...)`
- **SC6** `UsageBarApp` `onPollTick` 闭包去掉多余 `Task.detached` 包裹（`UsageStatsService.refresh` 内部已自管 `Task.detached`）

## 死代码下线

- **SC7** `CreditLine.currencyCode`：仅 Codex 写 `"USD"` / Claude 写 `nil`，`CreditLineRow` 写死 `\$` 前缀从不读 → 删字段 + 2 处赋值
- **SC8** `UsageProvider.supportsBackgroundPolling`：v0.2.10 起生产 0 读 → 删协议成员 + 2 个 conformer impl + 4 处测试断言

## 验收（SC9/SC10）

- ✅ `swift build -c release` green
- ✅ `swift test` <N> passed / 0 failed（关闸时填实际数字）
- ✅ `make release-artifacts` + `verify-release.sh` 全绿（含 litellm / THIRD_PARTY_LICENSES invariant）
- 手动金路径：菜单栏图标 / popover 切 provider / SettingsView 各开关与拖拽 / VoiceOver 焦点切到 LocalCostCard 朗读为按钮

## 守护线

- ❌ 不触凭证 / 密钥（OAuth、token refresh、Sparkle 私钥、Keychain）
- ❌ 不引第三方依赖、不改 LICENSE
- ❌ 不改 ADR / AGENTS.md / 母法 spec / Info.plist 版本号
- ❌ 不在 UsageService 之外重复 fetch/auth 实现
- ✅ 改动按 4 个主题独立 commit，每个 commit 后 swift build + swift test 全绿

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: 等 CI 跑完**

```bash
gh pr checks --watch
```

期望：`build` workflow（`swift build -c release` → `swift test` → `make release-artifacts`）全绿。

---

## 后续（不属本 plan）

- merge 后给 `docs/versions/v0.3.1-swiftui-hygiene.md` 加 `shipped_date`、status → shipped
- 接 v0.4.0 view-layer-modernization 立项

---

## Self-review checklist

- ✅ 每个 SC 都有对应 Task（SC1→T2、SC2→T3、SC3→T4、SC4→T5、SC5→T6、SC6→T7、SC7→T8、SC8→T9、SC9+SC10→T10）
- ✅ Task 1 单独 commit docs；Task 11 关闸 commit；Task 12 push+PR
- ✅ 无 TBD / TODO / "implement later" 占位
- ✅ 所有 file path 是绝对 macOS 仓内路径
- ✅ 所有 grep / build / test 命令完整可粘贴执行
- ✅ commit 信息中文 + 引用 spec id（守 CLAUDE.md commit 规范）
