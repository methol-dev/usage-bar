---
slug: specs-index
title: Spec 索引
type: index
created: 2026-05-11
updated: 2026-05-13
---

# Specs

`superpowers:brainstorming` 产出的单次设计文档。每个 spec 对应一个**功能模块或治理决策**，最终落地到某个 `vX.Y.Z` 版本。

> 模板：[`_TEMPLATE.md`](./_TEMPLATE.md)  
> Frontmatter schema 与生命周期约定：见母法 [`2026-05-11-docs-governance.md`](./2026-05-11-docs-governance.md) §3.3

## 索引

| Spec ID | Title | Status | Target | 引用 |
|---|---|---|---|---|
| `2026-05-11-docs-governance` | 文档治理框架与版本路线骨架 | implemented | v0.0.7 | [文件](./2026-05-11-docs-governance.md) |
| `2026-05-11-hero-popover` | Popover 重做：5h hero + 7d secondary + capsule 进度条 | implemented | v0.0.8 | [文件](./2026-05-11-hero-popover.md) |
| `2026-05-11-trend-arrows` | 趋势箭头 ▲▼ + 6h 增量百分点 | implemented | v0.0.9 | [文件](./2026-05-11-trend-arrows.md) |
| `2026-05-11-menubar-display-modes` | 菜单栏多显示模式 icon / percent / percent+trend | implemented | v0.0.10 | [文件](./2026-05-11-menubar-display-modes.md) |
| `2026-05-11-pace-tracking` | 5h 配速指示器 On pace / In deficit / In reserve | implemented | v0.0.11 | [文件](./2026-05-11-pace-tracking.md) |
| `2026-05-11-claude-cli-credentials` | 复用 Claude CLI Keychain 凭证 + Strategy 协议骨架 | implemented | v0.1.1 | [文件](./2026-05-11-claude-cli-credentials.md) |
| `2026-05-11-local-cost-scan` | 本地 JSONL 成本扫描（30 天 USD + per-model token） | superseded | v0.1.2 | [文件](./2026-05-11-local-cost-scan.md) |
| `2026-05-11-multi-account` | 多账号支持（accounts store + 迁移 + popover 切换器） | implemented | v0.1.3 | [文件](./2026-05-11-multi-account.md) |
| `2026-05-11-sparkle-beta-channel` | Sparkle 双通道（stable / beta）+ Settings Picker | implemented | v0.2.2 | [文件](./2026-05-11-sparkle-beta-channel.md) |
| `2026-05-12-usage-store-redesign` | 用量统计与存储重设计（按 provider 持久化 raw events + 聚合 + 消费热力图） | implemented | v0.2.3 | [文件](./2026-05-12-usage-store-redesign.md) |
| `2026-05-12-popover-redesign` | Popover 重做：provider tab 外壳 + 卡片化视觉 + 折线图 pace 面积（+ ADR 0005 supersede 0002） | implemented | v0.2.4 | [文件](./2026-05-12-popover-redesign.md) |
| `2026-05-12-multi-provider-refactor` | 多供应商架构重构：`UsageProvider` 协议 + `ProviderUsageSnapshot` 统一形状 + per-provider `ProviderRuntime` + Claude 改写成 provider（纯重构） | implemented | v0.2.5 | [文件](./2026-05-12-multi-provider-refactor.md) |
| `2026-05-12-codex-provider` | Codex provider 第一条数据源：`CodexProvider: UsageProvider` 读 `~/.codex/auth.json` OAuth → `wham/usage`，复用 v0.2.5 泛化视图层 | implemented | v0.2.6 | [文件](./2026-05-12-codex-provider.md) |
| `2026-05-12-claude-keychain-reimport` | Claude refresh 永久失败（单账号）时回退读 Claude CLI Keychain 续上凭证（修「Session expired」误报）；复用 v0.1.1 的 `ClaudeCLICredentialsStrategy` | implemented | v0.2.7 | [文件](./2026-05-12-claude-keychain-reimport.md) |
| `2026-05-12-codex-history-trend` | Codex 历史采样持久化 + Session/Weekly 卡趋势箭头 + 额度折线图：泛化 `UsageHistoryService(filename:directory:)`、`UsageChartSectionView` 加 `primaryLabel/secondaryLabel`、`CodexProvider` 自持 `history-codex.json` + 5 分钟轻量采样 timer | implemented | v0.2.8 | [文件](./2026-05-12-codex-history-trend.md) |
| `2026-05-12-codex-cost-heatmap` | Codex 本机 session JSONL 扫描 → 估算成本 + 消费热力图 + 去 Plan 卡：抽 `ModelPriceTable` 协议 + `OpenAIPricing` 估价表、`CodexRolloutCostParser`/`CodexUsageCollector`、`UsageStatsService`/`ScanCursorStore` per-provider、`ProviderCostContext` 接进 Codex tab（Claude 零回归） | implemented | v0.2.9 | [文件](./2026-05-12-codex-cost-heatmap.md) |
| `2026-05-12-settings-provider-list` | Settings 改 provider 列表（拖动排序 + 启用/禁用开关 + 菜单栏单选子开关，取代 Primary 下拉）+ 去 Account 区；`ProviderCoordinator` 统管顺序/启用集/菜单栏 provider/非-Claude 后台 timer；菜单栏 provider-aware（图标 + 窗口短标签）；Codex 用统一 polling interval；刷新纪律（切 tab 不刷新，刷新只 2 入口） | implemented | v0.2.10 | [文件](./2026-05-12-settings-provider-list.md) |

| `2026-05-12-unified-poll-timer` | ProviderCoordinator 统一后台 timer（收编 Claude 的 429 backoff —— UsageService 退役自持 Timer，backoff 改「截止时刻」hint）+ Codex 菜单栏专属 glyph（代码绘制，取代 SF Symbol） | implemented | v0.2.11 | [文件](./2026-05-12-unified-poll-timer.md) |
| `2026-05-13-litellm-pricing` | 模型价格表改走 LiteLLM 数据源：打包 `model_prices_and_context_window.json` 快照 + 运行期 3h 后台刷新（复用 ProviderCoordinator tick）+ 逐级回退 normalize（codex CLI 别名 → 有价模型）；删 `OpenAIPricing`/`ClaudePricing` 手写表 | implemented | v0.2.14 | [文件](./2026-05-13-litellm-pricing.md) |
| `2026-05-13-provider-self-management` | Provider 自主管理：全供应商可禁用（含 Claude）+ 独立菜单栏开关 + 拖拽排序修复；只用 Codex 的用户不再被强制引导 Claude 登录 | implemented | v0.3.0 | [文件](./2026-05-13-provider-self-management.md) |
| `2026-05-13-swiftui-hygiene` | SwiftUI hygiene：3 处 high bug（PlotFrame API / Heatmap 模型转 @State / LocalCostCard 可点击转 Button）+ low 清理 + 死代码下线（supportsBackgroundPolling / currencyCode）| implemented | v0.3.1 | [文件](./2026-05-13-swiftui-hygiene.md) |
| `2026-05-13-code-structure-hygiene` | 代码结构治理：目录分 9 子目录（Providers/Core+per-provider）+ UsageService 移进 Providers/Claude/ 同文件 // MARK: 章节化 + demo.png 清理 + AppResources 改名 BundleLocator | implemented | v0.3.2 | [文件](./2026-05-13-code-structure-hygiene.md) |

> 新增 spec 时在表格 append 一行；状态由 spec frontmatter 同步。

## 状态机

```
draft ─G2 approved─► accepted ─G6 spec_criteria 全 done─► implemented
                          │
                          └─ 被新 spec supersede ─► superseded
```

## 命名规范

- 文件名：`YYYY-MM-DD-<kebab-case-slug>.md`（与 frontmatter `id` 一致）
- slug 简短、表达主题，不带版本号（版本号在 `target_version` 字段）
- 同一主题如需新版（supersede），新建文件并把旧文件 status 改为 `superseded`，不删除旧文件

## 历史路径映射（v0.3.2 后）

v0.3.2 把 `macos/Sources/UsageBar/` 平铺 55 个 swift 文件改为 9 个职责子目录。已 implemented 的 spec / plan / artifacts 中
形如 `Sources/UsageBar/<Name>.swift` 的旧引用，用下表查新位置。权威清单见
[`2026-05-13-code-structure-hygiene.md`](./2026-05-13-code-structure-hygiene.md) §3.3。

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
