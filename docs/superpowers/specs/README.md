---
slug: specs-index
title: Spec 索引
type: index
created: 2026-05-11
updated: 2026-05-11
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
