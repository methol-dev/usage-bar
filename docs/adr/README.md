---
slug: adr-index
title: ADR 索引
type: index
created: 2026-05-11
updated: 2026-07-08
---

# Architecture Decision Records

不可变的架构决策记录（[MADR 0.x](https://adr.github.io/madr/) 精简风格）。一旦 `status: accepted`，正文不可变；后续变更通过新 ADR 引用并 `supersede`。

> 模板：[`_TEMPLATE.md`](./_TEMPLATE.md)  
> Frontmatter schema：见母法 [`2026-05-11-docs-governance.md`](../superpowers/specs/2026-05-11-docs-governance.md) §3.3

## 索引

| ID | Title | Status | 一句话 |
|---|---|---|---|
| [0001](./0001-swift-native-only.md) | Swift native only | accepted | 全栈 Swift / SwiftUI / SwiftPM；拒非原生 |
| [0002](./0002-claude-only-not-multi-provider.md) | Claude-only, not multi-provider | superseded-by 0005 | 差异化做"最精致的 Claude 专用条"（已被 0005 放宽） |
| [0003](./0003-ai-led-development.md) | AI-led development | accepted | AI 主导调研 / 设计 / 实施，人类辅助 |
| [0004](./0004-fork-divergence-from-blimp-labs.md) | Fork divergence from Blimp-Labs | accepted | 自 v0.0.7 起独立编号 + URL 校准 |
| [0005](./0005-reopen-multi-provider-direction.md) | 重新开放多 provider 方向 | accepted | supersede 0002；先搭 UI 外壳，逐步对接（首个 Codex） |
| [0006](./0006-rename-claudeusagebar-to-usagebar.md) | Rename ClaudeUsageBar → UsageBar | accepted | app / 模块 / bundle 去掉 `Claude` 前缀；bundle id → `com.tuzhihao.app.UsageBar`；本地数据目录 → `~/.config/usage-bar/` |
| [0007](./0007-agent-rules-restructure.md) | AI 开发规则改用 `.agent/rules/` 组织 | accepted | AGENTS.md 收敛为入口 + Rules Index；规则按领域拆分带 `globs`；删 `docs/agents|workflow|user-guide` 等冗余 |

## 状态机

```
proposed ─human ack─► accepted ─被新 ADR supersede─► superseded-by NNNN
                              ─不再适用但无新 ADR─► deprecated
```

## 命名规范

- 文件名：`NNNN-<kebab-case-slug>.md`（4 位数字 + slug）
- 编号严格递增；不复用，不重排
- supersede 时：新 ADR 引用旧 ADR id 并在 `Context` 节说明替换原因；同时把旧 ADR 的 `status` 改为 `superseded-by NNNN`
