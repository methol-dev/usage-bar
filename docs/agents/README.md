---
slug: agents-index
title: docs/agents/ 索引
type: index
created: 2026-05-13
updated: 2026-05-13
---

# docs/agents/

AI agent 进入本仓库的"操作工作台"。**根目录 [`AGENTS.md`](../../AGENTS.md) 给治理骨架（必须先读）；本目录给具体操作**。

## 三份必看

| 文件 | 用途 | 何时读 |
|---|---|---|
| [`quickstart.md`](./quickstart.md) | 任务类型 → 路径反向索引（"我要做什么 → 看哪里"） | 刚进项目、拿到一个新任务时 |
| [`operations.md`](./operations.md) | 实操命令 + Issue 驱动配置 + 守护线 checklist + 本地验证矩阵 | 真正动手实施时 |
| [`conventions.md`](./conventions.md) | 写作约定 + frontmatter 速查 + 命名规范 | 写 spec / ADR / version 文档时 |

## 与 AGENTS.md / CLAUDE.md 的分工

```
AGENTS.md              ←  治理骨架（必读，所有 runner）— 项目快照、工作流、review gate、hard gates
├─ docs/agents/quickstart.md    "我要做什么 → 看哪里" — 拿到任务后第一份
├─ docs/agents/operations.md    日常命令 + Issue 驱动 + 守护线 — 实施时
└─ docs/agents/conventions.md   写作规范 + frontmatter — 写文档时

CLAUDE.md              ←  Claude Code 专用坑（Mock server / Sparkle / build 注入），非 Claude Code 可跳过
```

## 编辑约定

- 三份文件都用 frontmatter（`slug` + `type=guide` + `created/updated`）
- 内容跨文件迁移时，原位置留 1 行链接跳转，不留 stub block
- 大量内容更新时，更新 `updated` 字段
