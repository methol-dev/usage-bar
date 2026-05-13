---
slug: versions-index
title: 版本路线索引
type: index
created: 2026-05-11
updated: 2026-05-13
---

# Versions

版本路线图 + 每个版本的 spec 清单 / 验收 / release notes 草稿。每个 `vX.Y.Z` 一个文件。

> 模板：[`_TEMPLATE.md`](./_TEMPLATE.md)  
> Frontmatter schema：见母法 [`2026-05-11-docs-governance.md`](../superpowers/specs/2026-05-11-docs-governance.md) §3.3  
> 版本号约定：见母法 §7.1

## 状态机

```
placeholder ─首个 spec 落地─► planned ─开发开始─► in-progress ─tag 推送─► shipped
                                                                            │
                                                                            └─严重缺陷─► yanked
```

## 当前路线

| 版本 | Codename | Status | Target | 主题 |
|---|---|---|---|---|
| [v0.0.7](./v0.0.7-docs-governance.md) | docs-governance | planned | 2026-05-11 | 📚 文档治理 + 路线骨架 |
| [v0.0.8](./v0.0.8-hero-popover.md) | hero-popover | in-progress | 2026-05-12 | 🎨 hero popover 重做 |
| [v0.0.9](./v0.0.9-trend-arrows.md) | trend-arrows | in-progress | 2026-05-12 | 🎨 趋势箭头 |
| [v0.0.10](./v0.0.10-menubar-display-modes.md) | menubar-display-modes | in-progress | 2026-05-12 | 🎨 菜单栏多显示模式 |
| [v0.0.11](./v0.0.11-pace-tracking.md) | pace-tracking | in-progress | 2026-05-12 | 🎨 Pace tracking |
| [v0.1.0](./v0.1.0-phase1-milestone.md) | phase1-milestone | shipped | 2026-05-11 | 🏁 Phase 1 里程碑（逻辑标记） |
| [v0.1.1](./v0.1.1-claude-cli-credentials.md) | claude-cli-credentials | in-progress | 2026-05-12 | 🔌 Claude CLI 凭证复用 |
| [v0.1.2](./v0.1.2-local-cost-scan.md) | local-cost-scan | in-progress | 2026-05-12 | 🔌 本地 JSONL cost 扫描 |
| [v0.1.3](./v0.1.3-multi-account.md) | multi-account | in-progress | 2026-05-12 | 🔌 多账号 |
| [v0.2.0](./v0.2.0-phase2-milestone.md) | phase2-milestone | shipped | 2026-05-11 | 🏁 Phase 2 里程碑（逻辑标记） |
| [v0.2.1](./v0.2.1-apple-notarization.md) | apple-notarization | placeholder | — | 🔧 Apple 公证 |
| [v0.2.2](./v0.2.2-sparkle-beta-channel.md) | sparkle-beta-channel | in-progress | 2026-05-12 | 🔧 Sparkle beta 通道 |
| [v0.2.3](./v0.2.3-usage-store-redesign.md) | usage-store-redesign | in-progress | 2026-05-12 | 🔌 用量统计与存储重设计（持久化 + 消费热力图） |
| [v0.2.4](./v0.2.4-popover-redesign.md) | popover-redesign | in-progress | 2026-05-12 | 🎨 Popover 重做（provider tab 外壳 + 卡片化 + 折线图 pace 面积） |
| [v0.2.5](./v0.2.5-multi-provider-refactor.md) | multi-provider-refactor | in-progress | 2026-05-12 | 🏗️ 多供应商架构重构（`UsageProvider` 协议 + per-provider 运行时；Claude 行为不变） |
| [v0.2.6](./v0.2.6-codex-provider.md) | codex-provider | in-progress | 2026-05-12 | 🔌 Codex provider（第一条数据源：`~/.codex/auth.json` → `wham/usage`；代码已 merge 到 main） |
| [v0.2.7](./v0.2.7-claude-keychain-reimport.md) | claude-keychain-reimport | in-progress | 2026-05-12 | 🔧 Claude refresh 失败 → 回退读 Claude CLI Keychain（修「Session expired」误报） |
| [v0.2.8](./v0.2.8-codex-history-trend.md) | codex-history-trend | in-progress | 2026-05-13 | 🔌 Codex 历史采样 + 趋势箭头 + 折线图（泛化 UsageHistoryService / UsageChartSectionView） |
| [v0.2.9](./v0.2.9-codex-cost-heatmap.md) | codex-cost-heatmap | in-progress | 2026-05-14 | 🔌 Codex 本地 session JSONL 扫描 → 估算成本/token → 消费热力图 + 去 Plan 卡（Codex tab 全面对齐 Claude） |
| [v0.2.10](./v0.2.10-settings-provider-list.md) | settings-provider-list | in-progress | 2026-05-16 | ⚙️ Settings 改 provider 列表（拖动排序 + 启用开关 + 菜单栏单选子开关）+ 去 Account 区 + Codex 统一 polling interval + 刷新纪律（切 tab 不刷新；刷新只 2 入口）|
| [v0.2.11](./v0.2.11-unified-poll-timer.md) | unified-poll-timer | in-progress | 2026-05-18 | 🏗️ ProviderCoordinator 统一后台 timer（收编 Claude backoff）+ Codex 菜单栏专属 glyph |
| [v0.2.12](./v0.2.12-app-icon-refresh.md) | app-icon-refresh | in-progress | 2026-05-12 | 🎨 更换 App 图标（深紫圆角 + 蓝紫渐变进度条意象；菜单栏 glyph 不变；无代码改动） |
| [v0.2.13](./v0.2.13-rename-usagebar.md) | rename-usagebar | in-progress | 2026-05-13 | 🔧 重命名 ClaudeUsageBar → UsageBar（app / 模块 / bundle id + 本地数据目录；无功能改动；ADR 0006） |
| [v0.2.14](./v0.2.14-litellm-pricing.md) | litellm-pricing | in-progress | 2026-05-14 | 🔌 价格表改走 LiteLLM 快照（打包 + 3h 后台刷新）+ 逐级回退 normalize（修 Codex「未知模型」误报） |

> **目标（用户 2026-05-12 定）**：把 Codex tab 做到和 Claude tab 界面/功能一致 —— v0.2.6 已上额度窗口卡 + pace；v0.2.8 补趋势 + 折线图；v0.2.9 补成本 + 消费热力图。v0.2.7 是穿插的独立小修（Claude 凭证回退）。新版本立项时按 §7.1 命名规范 append 即可。
>
> 注：母法 spec [`2026-05-11-docs-governance.md`](../superpowers/specs/2026-05-11-docs-governance.md) §7.2 / §7.3 中的 v0.2.3~v1.0.0 路线是 v0.0.7 立项历史快照（implemented spec 不可变），不代表当前路线。

## 命名规范

- 文件名：`vX.Y.Z-<kebab-case-codename>.md`
- 版本号严格递增；不跳号；patch 含 feature 在 0.x 阶段是合法的
- placeholder 升级到 planned 时：清空 `includes_specs` 示例、填 `target_date`
