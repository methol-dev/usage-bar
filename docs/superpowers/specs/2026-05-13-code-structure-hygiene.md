---
id: 2026-05-13-code-structure-hygiene
title: 代码结构治理 —— 目录分层 + 死资源清理 + UsageService 文件内章节化
status: implemented
created: 2026-05-13
updated: 2026-05-13
owner: claude-code
model: claude-opus-4-7
target_version: v0.3.2
related_adrs: []
related_research: []
spec_criteria:
  - id: SC1
    criterion: macos/Sources/UsageBar/ 按 9 个职责子目录（App / Models / Services / Providers/{Core,Claude,Codex} / Pricing / LocalCost / MenuBar / Features/{Popover,Settings} / Utilities）分组；55 个 swift 文件迁移到位（含 UsageService.swift 进 Providers/Claude/）；evidence 命令 `find macos/Sources/UsageBar -name '*.swift' -not -path '*/Resources/*' | wc -l` 应输出 55，且 `find macos/Sources/UsageBar -maxdepth 1 -name '*.swift' | wc -l` 应输出 0；`cd macos && swift build -c release` + `cd macos && swift test` 全绿
    done: true
    evidence: "commit 9b2cfab: 55 swift git-mv 到 9 子目录；find 验证 55 + 顶层 0；swift build/test 272 全绿；make release-artifacts + verify-release (zip+dmg) 全绿"
  - id: SC2
    criterion: 死资源 `macos/Resources/demo.png` 删除；`grep -rn "demo\.png" --include="*.md"` 输出只剩 docs/artifacts/issues/ 历史 + 本 spec 自身；`bash macos/scripts/verify-release.sh macos/UsageBar.zip` 绿
    done: true
    evidence: "commit f4ad6dc: git rm demo.png；grep 残留仅 docs/artifacts/issues/11 + spec/version/plan 自身；272 swift test + verify-release 全绿"
  - id: SC3
    criterion: `AppResources.swift` 重命名 `BundleLocator.swift`；类型 `AppResourceBundleFinder` 重命名 `BundleLocator`；外部函数 `usageBarResourceBundle()` **保留原名**（2 处调用方 `PollingOptionFormatter` / `MenuBarIconRenderer` 不需改）；`swift build` + `swift test` 绿
    done: true
    evidence: "commit 7536e31: git mv 改名 (rename 84% similarity)；类名 AppResourceBundleFinder → BundleLocator；函数名保留；272 swift test 全绿"
  - id: SC4
    criterion: `Providers/Claude/UsageService.swift` 同一文件内用 `// MARK: -` 分章节 + 多个 `extension UsageService { ... }` 块把 OAuth / Polling / Backoff 三段独立成区；**每个 method 保留原 access modifier**（private 仍 private，internal 仍 internal）、**不动方法签名**、**不动 method body**；evidence 命令 `git diff origin/main..HEAD --stat -- 'macos/Sources/UsageBar/Providers/Claude/UsageService.swift'` 应见 1 file changed；OAuth / backoff / polling 相关测试全绿（`UsageServiceTests` / `UsageServiceMultiAccountTests` 全过）
    done: true
    evidence: "commit 35b74c4: 单文件改动 (1 file changed, 259 ins, 239 del —— 行数差是 // MARK: 注释)；BEFORE/AFTER signature sort+diff 各 125 行完全一致空输出；272 swift test 全绿；make release-artifacts + verify-release 全绿"
  - id: SC5
    criterion: 因结构变动失效的 file path 引用按白名单全量更新——白名单 = `CLAUDE.md` / `AGENTS.md` / `docs/superpowers/specs/README.md` / `docs/versions/README.md` / `docs/runbooks/**` / draft 或 planned 状态的 specs / 主 `README.md`；**implemented specs / plans / docs/artifacts/** 一律不改（母法 immutability）；在 `docs/superpowers/specs/README.md` 增加一节"v0.3.2 路径映射表"，复制 spec §3.3 的全 55 项映射；evidence 命令 `grep -rn 'Sources/UsageBar/[A-Z][^/]*\.swift' CLAUDE.md AGENTS.md README.md docs/versions/README.md` 输出**无命中**（顶层 .swift 引用已全部改为子目录路径）
    done: true
    evidence: "commit 3fa221b: CLAUDE.md 5 处 path 更新 + specs/README 增 9 组 55 项映射表；evidence grep 无命中 ✓；AGENTS.md / README.md / docs/versions/README.md 扫后无失效引用，未改"
automated_checks:
  - "SC_AUTO_BUILD: cd macos && swift build -c release"
  - "SC_AUTO_TEST: cd macos && swift test"
  - "SC_AUTO_RELEASE: make release-artifacts"
  - "SC_AUTO_VERIFY: bash macos/scripts/verify-release.sh macos/UsageBar.zip"
  - "SC_AUTO_LAYOUT: find macos/Sources/UsageBar -name '*.swift' -not -path '*/Resources/*' | wc -l  # 应 = 55"
  - "SC_AUTO_NO_TOPLEVEL: find macos/Sources/UsageBar -maxdepth 1 -name '*.swift' | wc -l  # 应 = 0"
  - "SC_AUTO_PATH_GREP_WHITELIST_CLEAN: grep -rn 'Sources/UsageBar/[A-Z][^/]*\\.swift' CLAUDE.md AGENTS.md README.md docs/versions/README.md  # 应无命中"
manual_checks:
  - "G5 code review 通过（subagent 独立判断；重点：纯结构变动；UsageService.swift access modifier 0 改动；verify-release.sh 未被改动；CLAUDE.md/AGENTS.md path 引用更新无遗漏）"
reviews:
  - gate: G2
    round: 1
    reviewer: general-purpose-subagent
    verdict: needs-major-revision
    date: 2026-05-13
    summary: "4 个事实/语义错误：.DS_Store 未被 git 跟踪（SC2 前提错）；verify-release.sh:37 强制 en.lproj 存在（删 en.lproj 会 fail 且触动受保护文件）；跨文件 extension private 不可达（升 internal 会破坏 OAuth 红线）；i18n 内联中文会 fail 3 处英文测试断言。spec 已据此重写。"
  - gate: G2
    round: 2
    reviewer: general-purpose-subagent
    verdict: approved-after-revisions
    date: 2026-05-13
    summary: "v1 must-fix 已修；新 must-fix 3 项已并入此版：(a) §3.2 示例 private extension 会破坏协议 conformance 与 internal 方法 → 改成 `extension UsageService` 不带前缀，每方法保留原 modifier；(b) 全文「8 子目录」改「9 子目录」；(c) §3.3 映射表写全 55 项。"
  - gate: G5
    round: 1
    reviewer: general-purpose-subagent
    verdict: approved
    date: 2026-05-13
    summary: "三维度（sort/signature/access-modifier）独立验证 SC4 UsageService.swift 纯重排序成立——method body 0 行差异、signature diff 空、access modifier diff 空。受保护文件 git diff 全空。SC1-SC5 五条 evidence 经独立命令复现全部成立。1 个 should-consider（specs/README 表格 status 同步 accepted）已顺手并入本 PR。"
---

# 代码结构治理 —— 目录分层 + 死资源清理 + UsageService 文件内章节化

> **本 spec 假定**：本项目会接入更多 provider（用户偏好，user memory `project_provider_extensibility`，2026-05-13 记录）—— 这是目录分层决策的核心驱动。

## 1. 背景与目标

v0.3.1 SwiftUI hygiene 完成 3 处 high bug + 死代码下线后，仍存在 3 类结构性问题：

1. **`macos/Sources/UsageBar/` 55 个 swift 文件全部平铺在单层目录** —— 无任何分层；新 runner 难一眼看清职责拓扑；后续接入新 provider 会让目录失控。
2. **死资源残留**：`macos/Resources/demo.png`（v0.3.0 期间 README 已替换为 file1.tuzhihao.com 外链截图，issue #11 verification 已确认无其他引用）。
3. **`AppResources.swift` 命名误导**：实际职责是"找 SwiftPM resource bundle 的路径"，名字读起来像"App 全局资源"，新人易混淆。

附带一个内部代码可读性问题：**`UsageService.swift` 实测 886 行 / 38KB 单文件**。CLAUDE.md 钦定它是"单一事实源"不能拆类；跨文件 extension 在 Swift 访问控制语义下要么走 `fileprivate`（仅同 source file，跨文件不可达）要么升 `internal`（打开 module 内任意类型对 OAuth 私有 API 的调用口子，违反"敏感写入链路"红线）—— 两条都过不去。**因此本 spec 选择同一文件内用 `// MARK:` + `private extension UsageService` 章节化的轻量方案**，diff 是 method 顺序重排 + 注释加章节标题，**0 个 access modifier 变更**。这放弃了"减小单文件 LOC"目标，留给后续 spec（如果有更彻底的方案再启动）。

附带一个 i18n hygiene 观察（**本 spec 不处理**）：`Resources/en.lproj/Localizable.strings` 全 app 只有 1 个 key（`polling.option.not_recommended`），且 app 主语料是中文。但 `macos/scripts/verify-release.sh:37` 强制检查 `$resource_bundle/en.lproj/Localizable.strings` 存在；`verify-release.sh` 是 CLAUDE.md "受保护文件"，本 spec 不触动。i18n 退场留给后续独立 spec（届时一并改 verify-release，走 hard gate 升级）。

**本 spec 不引入新功能、不改任何用户可见行为、不动凭证 / Sparkle / verify-release 等受保护链路语义；只动结构。**

## 2. 决策摘要

| 决策点 | 选择 | 原因 |
|---|---|---|
| 分层方案 | A：9 子目录 feature 主导；`Providers/` 下分 `Core/` + per-provider | 为接入新 provider 留低成本扩展位 |
| Claude provider 实现位置 | `UsageService.swift` 移进 `Providers/Claude/` | 与 `Providers/Codex/CodexProvider.swift` 范式一致；Claude provider impl 散落 `Services/` + `Providers/Claude/` 两处会让"新 provider 仿照谁"模糊（G2 v1 reviewer S3） |
| `Pricing/` 放顶层 | 与 `Models/` / `MenuBar/` / `Features/` 同级 | 跨 provider 共用；不放 `Providers/Core/Pricing/` 是因为 pricing 不属 provider 抽象语义，而是定价数据资源 |
| UsageService 拆法 | **同一文件内 `// MARK:` + `private extension`**，不拆 .swift | Swift 跨文件 extension 不能访问 host type 的 `private`；唯一拆法是升 `internal`，会打开 OAuth/token 链路给 module 内任意类型调用，违反 CLAUDE.md "敏感写入链路" 红线（G2 v1 reviewer M3） |
| `claude-logo.svg` 处理 | **保留** | 不是构建链消费（`generate-logo-png.swift` 把 SVG path 硬编为 Swift 字符串字面量），但是出处凭证 provenance（与 `macos/scripts/codex-logo.svg` 同范式，issue #8 明确） |
| `demo.png` 处理 | **删** | README 已用外链截图；issue #11 verification 已确认无其他引用 |
| `icon.png` / Assets.xcassets / dmg/background.png / AppIcon.icns | **保留** | 全部活的（README / `build.sh` / DMG 制作链各自引用） |
| `.DS_Store` 处理 | **不动** | 实测 `git ls-files \| grep DS_Store` 输出 0 行——`.gitignore` 已生效。工作区里 untracked 的 `.DS_Store` 不进 git，无害（G2 v1 reviewer M1） |
| `en.lproj` 处理 | **不动** | `verify-release.sh:37` 强制检查它存在；删需同步改受保护文件，触发 hard gate（G2 v1 reviewer M2） |
| 文档 path 引用 | grep 白名单文件全量修；implemented spec / plan / artifacts 不动 + 在 specs/README.md 增路径映射表作为 reader hint | 母法 immutability（G2 v1 reviewer S1 / S2） |

## 3. 设计

### 3.1 目录结构

```
macos/Sources/UsageBar/
├─ App/                     # 入口 + 全局 wiring
│  ├─ UsageBarApp.swift
│  ├─ AppUpdater.swift
│  └─ BundleLocator.swift           # ← AppResources.swift 改名
├─ Models/                  # 纯数据 struct（无业务行为）
│  ├─ UsageModel.swift
│  ├─ UsageHistoryModel.swift
│  ├─ UsageStoreTypes.swift
│  ├─ StoredAccount.swift
│  ├─ StoredCredentials.swift
│  ├─ ProviderID.swift
│  ├─ ProviderRuntime.swift
│  ├─ ProviderUsageSnapshot.swift
│  ├─ MenuBarDisplayMode.swift
│  └─ UpdateChannel.swift
├─ Services/                # 跨 provider 业务编排（不含 provider 实现）
│  ├─ UsageHistoryService.swift
│  ├─ UsageStatsService.swift
│  ├─ NotificationService.swift
│  ├─ ProviderCoordinator.swift
│  └─ ProviderRegistry.swift
├─ Providers/               # provider 抽象 + 各实现
│  ├─ Core/
│  │  └─ UsageProvider.swift              # 协议 + HistoryRecording/UsageNotifying
│  ├─ Claude/
│  │  ├─ UsageService.swift               # ← 从顶层移入；// MARK: 章节化
│  │  ├─ ClaudeUsageStrategy.swift
│  │  ├─ ClaudeUsageCollector.swift
│  │  └─ ClaudeCLICredentialsStrategy.swift
│  └─ Codex/
│     ├─ CodexProvider.swift
│     ├─ CodexCredentials.swift
│     ├─ CodexUsageClient.swift
│     ├─ CodexUsageCollector.swift
│     ├─ CodexUsageModel.swift
│     └─ CodexRolloutCostParser.swift
├─ Pricing/                 # 跨 provider 共用定价
│  ├─ ModelPricing.swift
│  ├─ ModelPricingCatalog.swift
│  ├─ ClaudePricing.swift
│  └─ OpenAIPricing.swift
├─ LocalCost/               # 本地 JSONL 扫描 / 聚合
│  ├─ UsageEventStore.swift
│  ├─ UsageAggregator.swift
│  ├─ ScanCursorStore.swift
│  └─ JSONLCostParser.swift
├─ MenuBar/                 # 菜单栏渲染
│  ├─ MenuBarLabel.swift
│  ├─ MultiMenuBarLabel.swift
│  └─ MenuBarIconRenderer.swift
├─ Features/                # 主功能 UI 簇
│  ├─ Popover/
│  │  ├─ PopoverView.swift
│  │  ├─ UsageHeroCard.swift
│  │  ├─ UsageCard.swift
│  │  ├─ UsageChartView.swift
│  │  ├─ UsageHeatmapView.swift
│  │  ├─ LocalCostCard.swift
│  │  ├─ ProviderTabBar.swift
│  │  ├─ ProviderUsageSection.swift
│  │  ├─ AccountSwitcherView.swift
│  │  └─ PillPicker.swift
│  └─ Settings/
│     └─ SettingsView.swift
├─ Utilities/               # 纯函数 / 格式化 / 计算 / 跨 UI 的轻量 helper
│  ├─ PaceCalculator.swift
│  ├─ TrendCalculator.swift
│  ├─ ResetCountdownFormatter.swift
│  └─ PollingOptionFormatter.swift
└─ Resources/               # ← 不动（SwiftPM `.process` 入口）
   ├─ claude-logo.png
   ├─ codex-logo.png
   ├─ litellm_model_prices.json
   ├─ THIRD_PARTY_LICENSES.txt
   └─ en.lproj/Localizable.strings       # ← 不动；i18n 退场留后续 spec
```

**SwiftPM 不受影响**：target `path: "Sources/UsageBar"` 递归扫描所有 `.swift`，子目录是合法 SwiftPM 用法。`resources: [.process("Resources")]` 也只看 `Resources/` 这一个固定路径。实施后用 `swift build -c release` 验证。

### 3.2 UsageService 同文件章节化

主文件 `UsageService.swift`（886 行）保持单文件，但内部按职责分章节。**关键约束**：每个 method 保留原 access modifier（internal 仍是 internal、private 仍是 private）—— 因此 extension 块**不带** `private`/`fileprivate` 前缀，access 控制由每个 method 自身的修饰符决定。

```swift
// MARK: - Type Declaration & Stored Properties
final class UsageService: ObservableObject {
    @Published var ...
    // 存储属性、init、deinit
}

// MARK: - UsageProvider conformance
extension UsageService: UsageProvider {
    var id: ProviderID { .claude }
    var nextEligibleRefresh: Date? { ... }   // 内部 internal，由协议要求
    func refreshNow() async { ... }
}

// MARK: - OAuth & Credentials
extension UsageService {
    // internal API（被 UsageBarApp / SettingsView 调用）
    func bootstrapFromCLIIfNeeded() { ... }
    func startOAuthFlow() { ... }
    func submitOAuthCode(_ code: String) { ... }
    func signOut() { ... }
    func switchAccount(to: StoredAccount) { ... }

    // private helpers（仅本文件内）
    private func loadCredentials() throws -> StoredCredentials { ... }
    private func saveCredentials(_ creds: StoredCredentials) throws { ... }
    private func deleteCredentials() throws { ... }
    private func refreshCredentials(...) async throws -> StoredCredentials { ... }
    private func performRefresh(...) async throws -> StoredCredentials { ... }
    private func attemptCLIKeychainRecovery() async { ... }
    private func expireSession() { ... }
}

// MARK: - Polling & Fetch
extension UsageService {
    // internal API
    func updatePollingInterval(_ minutes: Int) { ... }
    func fetchUsage() async { ... }
    func fetchProfile() async { ... }

    // private helpers
    private func startBackgroundPolling() { ... }
    private func onBackgroundTick() async { ... }
    private func sendAuthorizedRequest(...) async throws -> Data { ... }
}

// MARK: - Backoff
extension UsageService {
    // 注：nextEligibleRefresh 在 conformance extension 内（协议要求 internal）
    private func recordRateLimitError() { ... }
    private func resetBackoff() { ... }
    private func backoffInterval(forAttempt n: Int) -> TimeInterval { ... }
}
```

**核心规则**：
- extension 块**不加** `private` / `fileprivate` 前缀 —— 否则会把内部 `internal` method 降级，破坏 `UsageBarApp` / `SettingsView` / `ProviderCoordinator` 等外部调用方，并破坏 `UsageProvider` 协议 conformance。
- 每个 method 移动时**原样保留**它当前的 access modifier；任何隐式/显式修饰符改动都视为本 spec 范围外的行为变更，G5 会 reject。
- 不改 method body、不改签名、不重命名。

**实施时的客观比对方法**（plan 阶段会展开为步骤）：
1. 章节化前先 commit 原文件作为 `BEFORE` baseline
2. `git diff BEFORE -- UsageService.swift --stat` 应见单文件、净 0 行（重排 + MARK 注释抵消，可能 ±10 行注释）
3. 把 `BEFORE` 与 `AFTER` 各自抽取所有 method signature 行（grep `func ` / `var `），`sort` 后 `diff` 应为空 —— 证明无新增/删除/改名 method
4. 把每个 method 的 access modifier 列成两列对比表，应全等

### 3.3 文档 path 引用更新（白名单）

`grep -rn 'Sources/UsageBar/[A-Z][^/]*\.swift\|AppResources'` 在以下白名单内全量修：

- `CLAUDE.md`
- `AGENTS.md`
- `docs/superpowers/specs/README.md`（含本 spec 入索引）
- `docs/versions/README.md`
- `docs/runbooks/**`
- `README.md`（主 README）
- **status 为 `draft` 或 `planned` 的 specs**（v0.3.0 / v0.3.2 / v0.4.0 / v0.5.0；前提是引用到改动的 path）

**不改**（母法 immutability）：
- `docs/superpowers/specs/*.md` 中 status 为 `implemented` / `superseded` 的
- `docs/superpowers/plans/*.md`（已落地的 plan 视为历史快照）
- `docs/artifacts/**`（issue 落地 artifacts）

在 `docs/superpowers/specs/README.md` 末尾加一节"v0.3.2 路径映射表"，**完整复制下表**（55 行）。spec §3.3 是权威清单；specs/README.md 是 reader 的反查入口。

#### 完整旧→新路径映射（55 项）

> 全部源路径相对 repo 根。所有 swift 文件在 v0.3.2 前均位于 `macos/Sources/UsageBar/<Name>.swift`；下表只列新路径（重名"UsageService"已去重）。

**App/** (3)
- `UsageBarApp.swift` → `App/UsageBarApp.swift`
- `AppUpdater.swift` → `App/AppUpdater.swift`
- `AppResources.swift` → `App/BundleLocator.swift` (**改名**)

**Models/** (10)
- `UsageModel.swift` → `Models/UsageModel.swift`
- `UsageHistoryModel.swift` → `Models/UsageHistoryModel.swift`
- `UsageStoreTypes.swift` → `Models/UsageStoreTypes.swift`
- `StoredAccount.swift` → `Models/StoredAccount.swift`
- `StoredCredentials.swift` → `Models/StoredCredentials.swift`
- `ProviderID.swift` → `Models/ProviderID.swift`
- `ProviderRuntime.swift` → `Models/ProviderRuntime.swift`
- `ProviderUsageSnapshot.swift` → `Models/ProviderUsageSnapshot.swift`
- `MenuBarDisplayMode.swift` → `Models/MenuBarDisplayMode.swift`
- `UpdateChannel.swift` → `Models/UpdateChannel.swift`

**Services/** (5)
- `UsageHistoryService.swift` → `Services/UsageHistoryService.swift`
- `UsageStatsService.swift` → `Services/UsageStatsService.swift`
- `NotificationService.swift` → `Services/NotificationService.swift`
- `ProviderCoordinator.swift` → `Services/ProviderCoordinator.swift`
- `ProviderRegistry.swift` → `Services/ProviderRegistry.swift`

**Providers/Core/** (1)
- `UsageProvider.swift` → `Providers/Core/UsageProvider.swift`

**Providers/Claude/** (4)
- `UsageService.swift` → `Providers/Claude/UsageService.swift` (Claude provider 实现)
- `ClaudeUsageStrategy.swift` → `Providers/Claude/ClaudeUsageStrategy.swift`
- `ClaudeUsageCollector.swift` → `Providers/Claude/ClaudeUsageCollector.swift`
- `ClaudeCLICredentialsStrategy.swift` → `Providers/Claude/ClaudeCLICredentialsStrategy.swift`

**Providers/Codex/** (6)
- `CodexProvider.swift` → `Providers/Codex/CodexProvider.swift`
- `CodexCredentials.swift` → `Providers/Codex/CodexCredentials.swift`
- `CodexUsageClient.swift` → `Providers/Codex/CodexUsageClient.swift`
- `CodexUsageCollector.swift` → `Providers/Codex/CodexUsageCollector.swift`
- `CodexUsageModel.swift` → `Providers/Codex/CodexUsageModel.swift`
- `CodexRolloutCostParser.swift` → `Providers/Codex/CodexRolloutCostParser.swift`

**Pricing/** (4)
- `ModelPricing.swift` → `Pricing/ModelPricing.swift`
- `ModelPricingCatalog.swift` → `Pricing/ModelPricingCatalog.swift`
- `ClaudePricing.swift` → `Pricing/ClaudePricing.swift`
- `OpenAIPricing.swift` → `Pricing/OpenAIPricing.swift`

**LocalCost/** (4)
- `UsageEventStore.swift` → `LocalCost/UsageEventStore.swift`
- `UsageAggregator.swift` → `LocalCost/UsageAggregator.swift`
- `ScanCursorStore.swift` → `LocalCost/ScanCursorStore.swift`
- `JSONLCostParser.swift` → `LocalCost/JSONLCostParser.swift`

**MenuBar/** (3)
- `MenuBarLabel.swift` → `MenuBar/MenuBarLabel.swift`
- `MultiMenuBarLabel.swift` → `MenuBar/MultiMenuBarLabel.swift`
- `MenuBarIconRenderer.swift` → `MenuBar/MenuBarIconRenderer.swift`

**Features/Popover/** (10)
- `PopoverView.swift` → `Features/Popover/PopoverView.swift`
- `UsageHeroCard.swift` → `Features/Popover/UsageHeroCard.swift`
- `UsageCard.swift` → `Features/Popover/UsageCard.swift`
- `UsageChartView.swift` → `Features/Popover/UsageChartView.swift`
- `UsageHeatmapView.swift` → `Features/Popover/UsageHeatmapView.swift`
- `LocalCostCard.swift` → `Features/Popover/LocalCostCard.swift`
- `ProviderTabBar.swift` → `Features/Popover/ProviderTabBar.swift`
- `ProviderUsageSection.swift` → `Features/Popover/ProviderUsageSection.swift`
- `AccountSwitcherView.swift` → `Features/Popover/AccountSwitcherView.swift`
- `PillPicker.swift` → `Features/Popover/PillPicker.swift`

**Features/Settings/** (1)
- `SettingsView.swift` → `Features/Settings/SettingsView.swift`

**Utilities/** (4)
- `PaceCalculator.swift` → `Utilities/PaceCalculator.swift`
- `TrendCalculator.swift` → `Utilities/TrendCalculator.swift`
- `ResetCountdownFormatter.swift` → `Utilities/ResetCountdownFormatter.swift`
- `PollingOptionFormatter.swift` → `Utilities/PollingOptionFormatter.swift`

**合计 55 文件**（3 + 10 + 5 + 1 + 4 + 6 + 4 + 4 + 3 + 10 + 1 + 4 = 55 ✅）

### 3.4 风险

1. **`swift package clean` + 全量重 build**：每次大重构后必须做（不然 SwiftPM `.swiftmodule` 旧索引会引一些不存在的 path）。Plan 第一步就 `swift package clean`，CI 已经做 `swift build -c release` 全量构建，影响可控。
2. **Xcode / SourceKit 索引重建**：第一次打开会卡顿几十秒；不影响 build。
3. **git rename detection**：默认 50% 相似度；纯 `git mv` 应当全部识别。UsageService.swift 章节化是单文件改动，`git diff --stat` 视角是 1 file。
4. **`git log --follow <new_path>`** 应能追到旧 path 的历史；本 spec 完成后跑一次验证 `git log --follow macos/Sources/UsageBar/Providers/Claude/UsageService.swift | head` 应能看到 v0.3.1 及更早 commit。
5. **`@testable import UsageBar`**：SwiftPM target name = "UsageBar"，与目录布局无关，测试代码无需改 import。
6. **OAuth / token 链路语义**：本 spec **完全不动**（同一文件内章节化不改任何 access modifier、不改任何 method body）。
7. **`verify-release.sh` invariant**：检查 bundle 内 `claude-logo.png` / `codex-logo.png` / `litellm_model_prices.json` / `THIRD_PARTY_LICENSES.txt` / `en.lproj/Localizable.strings` —— 本 spec 改动均不影响 bundle 内容（demo.png 不在 bundle 里）。

## 4. 现有文件迁移动作（关键摘要）

| 动作 | 路径 | 备注 |
|---|---|---|
| 🆕 (mkdir) | `App/` `Models/` `Services/` `Providers/Core/` `Providers/Claude/` `Providers/Codex/` `Pricing/` `LocalCost/` `MenuBar/` `Features/Popover/` `Features/Settings/` `Utilities/` | 12 个新目录 |
| 🔧 (git mv) | 全部 55 个 swift 文件迁入对应子目录 | UsageService.swift → `Providers/Claude/` |
| 🔧 (rename) | `AppResources.swift` → `App/BundleLocator.swift` + 类 `AppResourceBundleFinder` → `BundleLocator` | 函数名不变 |
| 🔧 (in-file refactor) | `Providers/Claude/UsageService.swift` 加 `// MARK:` 章节 + 拆 `private extension` | 不动 access modifier / method 签名 / method body |
| ❌ (delete) | `macos/Resources/demo.png` | README 已用外链；issue #11 verification 已确认无其他引用 |
| 🔧 (doc update) | `CLAUDE.md` / `AGENTS.md` / 白名单 docs path 引用 | 见 §3.3 |
| 🆕 (doc) | `docs/superpowers/specs/README.md` 加"v0.3.2 路径映射表" | 给历史 path 引用提供反查 |
| ✅ 不动 | `Tests/` 目录布局、`Resources/`（含 en.lproj）、`macos/Resources/` 除 demo.png 外、`verify-release.sh` / `build.sh` / `Package.swift` | 受保护或无需动 |

## 5. 风险 / Open questions

1. **G5 reviewer 验证 "纯重排序" 的可操作性**：UsageService.swift 章节化后，G5 reviewer 怎么快速核实"无语义改动"？建议 plan 阶段把"重排序前后跑 `sort + diff` 比对"作为 SC4 的实施步骤之一（commit 前自查）。
2. **新 provider 加入流程**：plan 阶段或本 spec §6 应该给出 "如何加 Providers/Gemini/" 的简短 checklist，让 user memory `project_provider_extensibility` 的承诺变成 actionable。

## 6. 后续工作（不在本 spec 范围）

- **v0.4.0 view-layer modernization**：PopoverView 抽 struct、SettingsView Binding 优化、GCD 嵌套去除
- **v0.5.0 @Observable migration**：ObservableObject → @Observable 迁移；可能届时 UsageService 拆分有更彻底方案（@Observable 改写后是否有跨文件 helper 拆分的更优解，留待 v0.5.0 评估）
- **i18n 退场专项**：删 `en.lproj/Localizable.strings` 单 key + 内联中文 + 改 `verify-release.sh:37` invariant + 改 3 处 `PollingOptionFormatterTests` 断言。需独立 spec（触动 `verify-release.sh` 受保护文件，走 hard gate 升级）。
- **`.DS_Store` 工作区清理**：纯个人工作流问题（macOS Finder 会持续生成），不进 spec。`.gitignore` 已生效，无后顾之忧。
- **新 provider 接入 checklist**：在 `docs/runbooks/` 加一份 `add-new-provider.md`，列加 `Providers/<Name>/` 后还要触动 `ProviderRegistry` / `ProviderCoordinator` 哪些点。
- **Tests/ 目录分层**：37 个测试文件平铺，但 SwiftPM 测试目录习惯平铺，治理 ROI 低，暂不动。

**已 implemented spec 的 path 引用**：母法规定 implemented spec 不可变。本次重构后那些 spec 中指向旧路径的引用会失效。mitigation：在 `docs/superpowers/specs/README.md` 末尾的"v0.3.2 路径映射表"提供反查（§3.3）。

## 7. 引用

- 前置 spec：[`2026-05-13-swiftui-hygiene.md`](./2026-05-13-swiftui-hygiene.md) (v0.3.1，已 implemented)
- 用户偏好 memory：`project_provider_extensibility`（2026-05-13）、`project_provider_abstraction`
- G2 v1 review：见 spec frontmatter `reviews` 字段（待 G2 v2 通过后 append 两轮 verdict）
- 落地版本：[`../../versions/v0.3.2-code-structure-hygiene.md`](../../versions/v0.3.2-code-structure-hygiene.md)

## Verification log

> G6 验收依据。每条 SC 完成时勾选并填 evidence。

- [x] SC1 — done (commit 9b2cfab): 55 swift git-mv 到 9 子目录；find 验证 55 项 + 顶层 0 项；swift build/test/release-artifacts/verify-release 全绿
- [x] SC2 — done (commit f4ad6dc): demo.png 已删；grep 残留仅历史；272 swift test + verify-release 全绿
- [x] SC3 — done (commit 7536e31): AppResources.swift → BundleLocator.swift；类名重命名；函数名保留；272 swift test 全绿
- [x] SC4 — done (commit 35b74c4): 单文件改动；BEFORE/AFTER signature sort+diff 各 125 行完全一致空输出；272 swift test 全绿
- [x] SC5 — done (commit 3fa221b): CLAUDE.md 5 处 + specs/README 加 9 组 55 项映射表；evidence grep 无命中
