---
id: 2026-05-11-sparkle-beta-channel
title: Sparkle 双通道（stable / beta）+ 用户级 channel 选择
status: draft
created: 2026-05-11
updated: 2026-05-11
owner: claude-code
model: claude-opus-4-7
target_version: v0.2.2
related_adrs: [0001]
related_research: [competitive-analysis]
spec_criteria:
  - id: SC1
    criterion: "新增 macos/Sources/ClaudeUsageBar/UpdateChannel.swift：enum UpdateChannel: String, CaseIterable { case stable = \"stable\", beta = \"beta\" }；storageKey = \"updateChannel\"；display label：stable → \"稳定版\"，beta → \"Beta（实验性）\""
    done: false
    evidence: "see ## Verification log"
  - id: SC2
    criterion: "AppUpdater.swift 扩展：从 final class : ObservableObject 改为 final class : NSObject, ObservableObject, SPUUpdaterDelegate（**init 顺序**（G2-B1）：所有 stored property 赋值 → super.init() → KVO 注册 → updaterController.startUpdater）；allowedChannels(for:) nonisolated 实现返回根据用户选择的 set；SPUStandardUpdaterController init 传入 updaterDelegate: self"
    done: false
    evidence: "see ## Verification log"
  - id: SC3
    criterion: "UpdateChannel 持久化：@AppStorage(UpdateChannel.storageKey) 在 SettingsView；AppUpdater 内部通过**注入的 UserDefaults**（G2-B2/G3-B1：init 加 defaults: UserDefaults = .standard，存为 stored property，delegate 回调从 self.defaults 读）读 storageKey；切换 channel 后 next check 生效；不需要立即重启 SPUUpdater"
    done: false
    evidence: "see ## Verification log"
  - id: SC4
    criterion: "SettingsView Form 内新增 `Section(\"更新通道\")`（G3-N1 修订：现有 SettingsView 无\"自动更新\" section，新建 Section 位置在 General/Notifications 之后、Account/About 之前）：Picker 显示 channel options + 一行说明 \"Beta 通道包含未稳定版本，仅建议测试用户启用\""
    done: false
    evidence: "see ## Verification log"
  - id: SC5
    criterion: "更新 docs/runbooks/release.md（若存在）或新增 章节：appcast.xml 生成约定 — beta tag `v*-beta.*` 触发 CI 只生成 beta items（item 加 `<sparkle:channel>beta</sparkle:channel>`）；stable tag `v*` 不带 -beta 后缀生成 stable items（无 sparkle:channel 标签 = 默认通道）；签名 + 部署到同一 GitHub Pages 路径"
    done: false
    evidence: "see ## Verification log"
  - id: SC6
    criterion: "**安全约束（v0.1.1~v0.1.3 SC7 永久延续）**：禁止 print/log credentials；channel 选择不涉及 token 处理；AppUpdater 错误日志只 NSLog type；测试 mock 无真实 token"
    done: false
    evidence: "see ## Verification log"
  - id: SC7
    criterion: "新增 UpdateChannelTests / AppUpdaterChannelTests：≥5 case：testRawValueRoundTrip / testCurrentFallsBackForNil / testCurrentFallsBackForUnknownRawValue（G2-RC：\"canary\" 等非法字符串 fallback）/ testAllowedChannelsForStable / testAllowedChannelsForBeta / testDisplayName / **testAppUpdaterReflectsInjectedDefaults**（用 `UserDefaults(suiteName: \"test.\\(UUID)\")` 创建隔离 suite，传给 AppUpdater.init，写入 storageKey 后 allowedChannels(for: nil) 返回预期 set）"
    done: false
    evidence: "see ## Verification log"
  - id: SC8
    criterion: "不动 OAuth / refresh / polling / SetupView / CodeEntry / Notifications / Strategy / LocalCost / multi-account / hero/menubar/pace/trend；仅 AppUpdater + SettingsView + 新文件 UpdateChannel.swift + Tests + 1 个 runbook doc"
    done: false
    evidence: "see ## Verification log"
  - id: SC9
    criterion: "cd macos && swift build -c release 输出 'Build complete!'；cd macos && swift test 'Executed N tests, with 0 failures' 含本 spec ≥4 case（基线 120 + ≥4 = ≥124）"
    done: false
    evidence: "see ## Verification log"
  - id: SC10
    criterion: "git commit 中文、含变更主题 + spec id；spec.reviews 数组含 G2、G3、G5、G6 四条 verdict；version v0.2.2 frontmatter status placeholder→planned→in-progress；CHANGELOG.md append v0.2.2 中文 entry"
    done: false
    evidence: "see ## Verification log"
automated_checks:
  - "SC_AUTO_BUILD: cd /Users/methol/data/code-methol/usage-bar/macos && swift build -c release 2>&1 | tail -3 | grep -q 'Build complete'"
  - "SC_AUTO_TEST: cd /Users/methol/data/code-methol/usage-bar/macos && swift test 2>&1 | tail -5 | grep -E 'Executed [0-9]+ test.*0 failures'"
  - "SC_AUTO_NO_PRINT_TOKENS: ! grep -nrI -E '(print|NSLog|os_log|os\\.log|Logger)\\s*[\\(,].*([Aa]ccess[Tt]oken|[Rr]efresh[Tt]oken|rawJSON|claudeAiOauth|message\\.content|jsonlLine|rawLine|lastPathComponent|account\\.credentials)' macos/Sources/ClaudeUsageBar/ 2>/dev/null"
  - "SC_AUTO_NO_REAL_TOKEN_PREFIX: ! grep -nrI -E 'sk-ant-(oat|ort|api)[0-9a-zA-Z]|sk-proj-[0-9a-zA-Z]|AKIA[0-9A-Z]{16}' macos/ docs/ CHANGELOG.md 2>/dev/null"
manual_checks:
  - "在 .app 启动后打开 Settings，看到 \"更新通道\" 区块和 Picker；切换到 Beta 后下次 checkForUpdates 应能拉取 sparkle:channel=\"beta\" 的 item"
  - "切回 stable 后 beta items 不再可见"
reviews:
  - gate: G2
    reviewer: claude-code (general-purpose subagent, agentId a5e72a9e3325055e6, with security focus)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（2 BLOCKING + 4 RECOMMENDED + 4 ADVISORY）。
      作者按 superpowers:receiving-code-review 流程处理：
      - BLOCKING B1 (NSObject super.init 顺序) accepted — SC2 加 sub-criterion
        "init order: stored property init → super.init() → KVO registration → startUpdater"。
      - BLOCKING B2 (SC7 AppUpdaterChannelTests UserDefaults 注入与 init 签名矛盾) accepted —
        SC3 改 AppUpdater.init 加 defaults: UserDefaults = .standard 注入 seam；
        SC7 改用 `UserDefaults(suiteName: "test.\(UUID)")` 隔离 suite。
      - RECOMMENDED A (UserDefaults.standard thread-safe) accepted — §5 #1 加 Apple docs 引用。
      - RECOMMENDED B (跨 channel 版本比较保证) accepted — §5 新增 #7 SUStandardVersionComparator 说明。
      - RECOMMENDED C (testCurrentFallsBackForUnknownRawValue) accepted — SC7 加 "canary" 字符串 case。
      - RECOMMENDED D (SUEnableAutomaticChecks 自动 check 同样走 delegate) accepted — §5 #1 加一行说明。
      - ADVISORY 全 confirmed / 接受（appcast XML namespace 在 P3 verify；SC9 baseline 数；scope cut；frontmatter）。
      - Confirmed correct 全部 ✅。
    artifacts: ["G2 review subagent output (agentId a5e72a9e3325055e6)"]
  - gate: G3
    reviewer: claude-code (general-purpose subagent, agentId ac9834821224675bd)
    date: 2026-05-11
    verdict: approved-after-revisions
    summary: |
      原始 verdict: approved-after-revisions（2 BLOCKING + 3 RECOMMENDED + 2 NOTES）。
      作者按 superpowers:receiving-code-review 流程处理：
      - BLOCKING B1 (AppUpdaterChannelTests 注入 contract 缺) 与 G2-B2 重合 — 同款修订（init defaults: 注入 + suiteName UUID）。
      - BLOCKING B2 (P1 缺 AppUpdater regression check) accepted — P1 Success 加
        `swift test --filter UsageServiceTests` + `swift test --filter SettingsViewTests` 单独跑全绿。
      - RECOMMENDED R1 (P3 拆分) accepted — P3 拆为 P3a (runbook doc, G4) + P3b (G6 wrap-up)。
      - RECOMMENDED R2 (baseline 验证) accepted — P0 加 baseline 测试数记录步骤；P1 grep 规则保留 ≥125 上下限。
      - RECOMMENDED R3 (P2 git diff 严格 SettingsView only) accepted — P2 Success 改为 git diff --name-only base..HEAD 严格白名单。
      - NOTES N1 (SettingsView 无"自动更新" section) accepted — SC4 + §3.3 措辞改"Form 内新增 Section"；位置 Notifications 之后 / Account 之前。
      - NOTES N2 (test-in-same-commit) confirmed ✅。
      - Confirmed correct 全部 ✅。
    artifacts: ["G3 review subagent output (agentId ac9834821224675bd)"]
---

# Sparkle 双通道（stable / beta）

## 1. 背景与目标

调研 §2.11 指出 CodexBar 用 Sparkle `sparkle:channel="beta"` 让 nightly / 实验版本对吃螃蟹用户可见，主线 stable 用户不打扰。

本 spec 引入：
- `UpdateChannel` 枚举 + `@AppStorage` 持久化
- `AppUpdater` 实现 `SPUUpdaterDelegate.allowedChannels(for:)` 根据用户选择返回
- `SettingsView` "更新通道" Picker
- 发版 runbook 说明 beta tag 流程

**不在范围**：
- 实际打 beta tag（需用户授权 §6 #1 hard gate）→ 留用户手动
- appcast.xml CI 生成器改造（CI workflow 由用户后续维护）
- 自动从 beta 回滚到 stable（用户切回后自然下次更新走 stable）

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| channel 名 | "stable" / "beta" | Sparkle 约定，与 CodexBar 一致 |
| 默认 channel | stable | 不打扰现有用户；显式 opt-in 才进 beta |
| 持久化 | UserDefaults via @AppStorage("updateChannel") | 与现有 pollingMinutes 模式一致 |
| AppUpdater 读取 | UserDefaults.standard.string(forKey:) 在 allowedChannels(for:) 内 | delegate 回调每次调用都读 UserDefaults，省 ObservableObject 生命周期复杂度 |
| Allowed channels 语义 | stable 用户：["stable"]；beta 用户：["stable", "beta"] | beta 用户**也能**拿 stable 更新（不丢更新），仅扩展可见集合 |
| UI 位置 | SettingsView 现有"自动更新"附近 | 上下文集中 |
| 切换生效时机 | 下次 checkForUpdates 自动生效（不强制重启 SPUUpdater） | SPUUpdaterDelegate 是每次调用回调，零侵入 |

## 3. 设计

### 3.1 `UpdateChannel.swift`

```swift
import Foundation

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    static let storageKey = "updateChannel"
    static let defaultChannel: UpdateChannel = .stable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: return "稳定版"
        case .beta: return "Beta（实验性）"
        }
    }

    /// 读 UserDefaults 当前 channel；非法值 fallback 到 default
    static func current(defaults: UserDefaults = .standard) -> UpdateChannel {
        guard let raw = defaults.string(forKey: storageKey),
              let channel = UpdateChannel(rawValue: raw) else {
            return defaultChannel
        }
        return channel
    }

    /// allowedChannels 语义：beta 用户也能收 stable
    static func allowedChannelStrings(for channel: UpdateChannel) -> Set<String> {
        switch channel {
        case .stable: return ["stable"]
        case .beta: return ["stable", "beta"]
        }
    }
}
```

### 3.2 `AppUpdater.swift` 改动

```swift
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    // existing fields...

    init(bundle: Bundle = .main) {
        // ... 现有
        super.init()
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,   // ← 新增 self
            userDriverDelegate: nil
        )
        // ... 现有
    }

    // SPUUpdaterDelegate
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let channel = UpdateChannel.current()
        return UpdateChannel.allowedChannelStrings(for: channel)
    }
}
```

注意 AppUpdater 从 `final class` 改为 `final class ... NSObject, ObservableObject, SPUUpdaterDelegate`（添加 NSObject 父类以满足 Sparkle delegate Obj-C 兼容性）。delegate 方法 `nonisolated` 因为 Sparkle 可能从非 main 线程调用。

### 3.3 SettingsView 改动

在现有"自动更新"section（如有）或合适位置插入：
```swift
@AppStorage(UpdateChannel.storageKey) private var rawChannel: String = UpdateChannel.defaultChannel.rawValue

Section("更新通道") {
    Picker("通道", selection: $rawChannel) {
        ForEach(UpdateChannel.allCases) { ch in
            Text(ch.displayName).tag(ch.rawValue)
        }
    }
    Text("Beta 通道包含未稳定版本，仅建议测试用户启用")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

### 3.4 Release runbook 文档化

`docs/runbooks/release.md`（若不存在则新建）追加章节：

```markdown
## Sparkle 双通道

- **stable tag**：`v0.2.x` / `v1.0.0` 等不带 `-beta.N` 后缀；appcast item 不带 `sparkle:channel`（默认通道）
- **beta tag**：`v0.2.3-beta.1` / `v0.3.0-beta.2` 等；appcast item 加 `<sparkle:channel>beta</sparkle:channel>`
- CI 在 release workflow 内：
  - tag matches `*-beta.*` → 生成 beta item
  - 否则 → 生成 stable item
- 两类 item 都进同一个 appcast.xml 部署到 GitHub Pages
- 用户在 Settings → 更新通道选 Beta 后能看到 beta items
```

### 3.5 测试

`UpdateChannelTests`（≥3 case）：
- testRawValueRoundTrip
- testCurrentFallsBackToDefaultForInvalidValue
- testAllowedChannelsForStable / testAllowedChannelsForBeta
- testDisplayName

`AppUpdaterChannelTests`（≥1 case，用 InMemoryUserDefaults）：
- testAllowedChannelsReflectsUserDefaultsValue（mock UserDefaults 注入；改 storageKey → allowedChannels(for:) 返回正确）

### 3.6 Implementation plan（G3 对象）

**Step P0** — spec + version + 索引（Commit A，仅文档）
- 升 v0.2.2 placeholder→planned；删 guardrail
- specs/README.md / versions/README.md 索引同步
- **Success**: linkcheck OK；frontmatter parse；grep status: planned
- **覆盖 SC**: 无

**Step P0 baseline 验证**（G3-R2 修订）：在 P1 启动前先跑 `cd macos && swift test 2>&1 | grep -E 'Executed [0-9]+ tests.*0 failures' | tail -2` 记录实际基线测试数（应为 120，若漂移则调 P1 grep）。

**Step P1** — UpdateChannel + AppUpdater + 测试（Commit B）
- 新增 UpdateChannel.swift（含 displayName + storageKey + current(defaults:) + allowedChannelStrings(for:)）
- AppUpdater 改造：加 NSObject + SPUUpdaterDelegate；**init 顺序**：stored property → super.init() → KVO → startUpdater（G2-B1）；新增 `init(bundle:, defaults:)` 加 UserDefaults 注入 seam（G2-B2/G3-B1）
- 新增 UpdateChannelTests（≥4 case）+ AppUpdaterChannelTests（≥1 case，用 `UserDefaults(suiteName: "test.\(UUID())")` 注入）
- **Success**:
  - `cd macos && swift build -c release && swift test` 全绿
  - `swift test 2>&1 | grep -E 'Executed (12[4-9]|1[3-9][0-9]) tests.*0 failures'` 命中（基线 120 + ≥5 = ≥125）
  - **回归 check**（G3-B2）：`swift test --filter UsageServiceTests` + `swift test --filter SettingsViewTests` 单独跑全绿
  - SC_AUTO_NO_PRINT_TOKENS / SC_AUTO_NO_REAL_TOKEN_PREFIX 守护无匹配
- **覆盖 SC**: SC1, SC2, SC3, SC6（前置）, SC7, SC9（前半）

**Step P2** — SettingsView UI（Commit C）
- SettingsView Form 内新增 `Section("更新通道")`，位置在 Notifications 之后 / Account/About 之前（G3-N1）
- Picker 绑定 @AppStorage(UpdateChannel.storageKey)
- **Success**:
  - `cd macos && swift build && swift test` 全绿
  - `git diff --name-only <P1 sha>..HEAD -- macos/Sources/ClaudeUsageBar/` 仅含 `SettingsView.swift`（G3-R3）
- **覆盖 SC**: SC4, SC8（部分）

**Step P3a** — Release runbook 文档（Commit D-1，G3-R1 拆分）
- 新增/更新 docs/runbooks/release.md beta tag 章节
- **Success**: linkcheck pass + frontmatter lint pass（若 runbook 有 frontmatter）
- **覆盖 SC**: SC5

**Step P3b** — G6 收尾（Commit D-2，G3-R1 拆分）
- spec status accepted → implemented；reviews append G5 + G6
- Verification log 全 [x]；索引同步；CHANGELOG entry；version → in-progress
- **Success**：
  - `grep -c '^  - gate:' docs/superpowers/specs/2026-05-11-sparkle-beta-channel.md` 输出 ≥4
  - `grep -c '^## \[v0.2.2\]' CHANGELOG.md` 输出 1
- **覆盖 SC**: SC10

## 4. 现有文件迁移动作

| 动作 | 文件 | 备注 |
|---|---|---|
| 🆕 | `macos/Sources/ClaudeUsageBar/UpdateChannel.swift` | 枚举 + helpers |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/UpdateChannelTests.swift` | ≥3 case |
| 🆕 | `macos/Tests/ClaudeUsageBarTests/AppUpdaterChannelTests.swift` | ≥1 case |
| 🔧 | `macos/Sources/ClaudeUsageBar/AppUpdater.swift` | 加 NSObject + SPUUpdaterDelegate + allowedChannels |
| 🔧 | `macos/Sources/ClaudeUsageBar/SettingsView.swift` | 加 "更新通道" Picker section |
| 🆕/🔧 | `docs/runbooks/release.md` | beta tag 章节 |
| 🔧 | `docs/versions/v0.2.2-sparkle-beta-channel.md` / 索引 / CHANGELOG | 标准收尾 |
| ✅ 不动 | OAuth/refresh/polling/SetupView/CodeEntry/Notifications/Strategy/LocalCost/multi-account/hero/menubar/pace/trend | 仅 AppUpdater + SettingsView |

## 5. 风险 / Open questions

1. **Sparkle delegate 线程**：SPUUpdaterDelegate 可能从非 main 线程调用 allowedChannels。用 `nonisolated` 标注 + UserDefaults 读取。**UserDefaults.standard 是 Apple 文档承诺的 thread-safe API**（G2-A 修订），并发 @AppStorage 写 + delegate 读安全。SUEnableAutomaticChecks 触发的自动 check 也通过同一 delegate（G2-D）。
2. **首次启动 channel 字段不存在**：UserDefaults 返 nil → fallback stable。
3. **用户选 beta 但仓库无 beta tag**：appcast 无 beta items → Sparkle 退到 stable。可接受。
4. **切回 stable 后已装的 beta build 不会被自动降级**：用户需要手动等 stable 版本超过当前 beta 版本号。已知行为，文档化即可。
5. **SC_AUTO 守护**：channel 不涉及 token；现有 SC_AUTO_NO_PRINT_TOKENS / NO_REAL_TOKEN_PREFIX 守护范围自然覆盖新文件。
6. **AppUpdater NSObject 转换**：原 `final class AppUpdater: ObservableObject` 改 `final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate`。NSKeyValueObservation 在 NSObject 上 work；consumers (`ClaudeUsageBarApp.swift:8` @StateObject + `PopoverView.swift:7` @ObservedObject) 仅用 ObservableObject 协议层 API，NSObject 转换无 ABI break。
7. **跨 channel 版本比较**（G2-B 修订）：Sparkle 用 `SUStandardVersionComparator` 比较版本号，不分 channel。beta 用户 allowedChannels=["stable","beta"] 时若 stable v2.0 + beta v1.9 同 appcast，比较结果 v2.0 胜出 → beta 用户拿到 v2.0（不会"卡在 beta"）。

## 6. 后续工作（不在本 spec 范围）

- appcast.xml CI 自动生成器改造 → v0.2.2 后续 increment
- 实际打 beta tag 发版 → 需用户授权（§6 #1 hard gate）
- About 面板显示当前 channel → v0.2.x

## 7. 引用

- 调研：[`docs/research/competitive-analysis.md`](../../research/competitive-analysis.md) §2.11
- 母法：[`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md)
- 落地版本：[`docs/versions/v0.2.2-sparkle-beta-channel.md`](../../versions/v0.2.2-sparkle-beta-channel.md)
- [Sparkle Channels 官方文档](https://sparkle-project.org/documentation/publishing/#publishing-channels)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [ ] SC1 — evidence: TBD
- [ ] SC2 — evidence: TBD
- [ ] SC3 — evidence: TBD
- [ ] SC4 — evidence: TBD
- [ ] SC5 — evidence: TBD
- [ ] SC6 — evidence: TBD
- [ ] SC7 — evidence: TBD
- [ ] SC8 — evidence: TBD
- [ ] SC9 — evidence: TBD
- [ ] SC10 — evidence: TBD
