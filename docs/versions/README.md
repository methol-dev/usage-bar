---
slug: versions-index
title: 版本路线索引
type: index
created: 2026-05-11
updated: 2026-05-11
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

placeholder ─作者评估后 scope-cut─► wontfix（不实施，不打 tag；版本号保留作历史记录）
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
| [v0.2.3](./v0.2.3-cookie-fallback.md) | cookie-fallback | **wontfix** | — | 🚫 scope-cut（2026-05-11 user 决策不实施） |
| [v0.2.4](./v0.2.4-cli-pty-fallback.md) | cli-pty-fallback | **wontfix** | — | 🚫 scope-cut（v0.1.1 Keychain 已覆盖；PTY 复杂度高边际收益低） |
| [v0.2.5](./v0.2.5-widgetkit.md) | widgetkit | placeholder | — | 🔧 WidgetKit |
| [v0.2.6](./v0.2.6-cli-tool.md) | cli-tool | **wontfix** | — | 🚫 scope-cut（新依赖违反 ADR 0001；价值边际） |
| [v0.3.0](./v0.3.0-phase3-milestone.md) | phase3-milestone | placeholder | — | 🏁 Phase 3 里程碑 |
| [v1.0.0](./v1.0.0-stable.md) | stable | placeholder | — | 🚀 稳定可用 |

## v1.0.0 "稳定可用"硬清单

见母法 §7.3（14 条）。

## 命名规范

- 文件名：`vX.Y.Z-<kebab-case-codename>.md`
- 版本号严格递增；不跳号；patch 含 feature 在 0.x 阶段是合法的
- placeholder 升级到 planned 时：清空 `includes_specs` 示例、填 `target_date`
