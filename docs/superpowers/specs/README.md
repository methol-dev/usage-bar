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
