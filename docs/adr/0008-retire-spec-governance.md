---
id: 0008
title: 废弃 spec/superpowers 治理层，采用轻量 plan-mode 工作流
status: accepted
date: 2026-07-08
deciders: methol, claude-code
---

# ADR 0008 — 废弃 spec/superpowers 治理层，采用轻量 plan-mode 工作流

## Context

[ADR 0007](./0007-agent-rules-restructure.md) 把 AI 规则收敛到 `.agent/rules/` 后，owner 于同日进一步删除了：

- 治理母法 spec `2026-05-11-docs-governance`（613 行，定义 frontmatter schema、7 Review Gates、hard gates 等）
- spec 模板与索引（`docs/superpowers/specs/{_TEMPLATE,README}.md`，历史 spec 已在前一轮清理）
- 跨 runner 工具 preflight 表（`.agent/rules/tooling.md`，内容全部围绕 superpowers / codex 工具链）

背景判断：

- superpowers skill 体系（brainstorming / writing-plans / requesting-code-review）不再使用
- research → spec → plan 双文档层 + 7 Review Gates 对单人 AI-led 小项目开销超过收益
  （ADR 0003 Negative 当时已预警"过度治理"，该担忧成真）
- Claude Code 原生能力已覆盖原 gate 的核心目的：plan mode（计划）、`/review`（代码质量）、
  `/security-review`（安全）、`/simplify`（精简）

## Decision

功能开发（跨多文件 / 有架构影响的任务）的工作流替换为：

1. **Plan** — 进入 plan mode，探索代码库后产出实施计划（步骤 + 验收标准）
2. **Plan review** — 独立 reviewer（subagent / 人类）审计划；通过后才动代码
3. **实施 + 测试** — 编码；每个 commit 保持 `swift build` + `swift test` 绿
4. **代码检查** — `/review`（正确性 / 质量）+ `/security-review`（凭证 / 权限）
5. **精简** — `/simplify` 清理冗余代码
6. **PR** — 创建 PR；CI 绿后 squash merge
7. **发版** — 按 `docs/runbooks/release.md`（version 文档 + CHANGELOG + tag + 24h health check）

配套调整：

- **spec / plan 文档不再入库**：设计讨论保留在 plan review 与 PR 描述中；决策沉淀走 ADR
- **version 文档保留**（发版验收与 release notes 的载体），frontmatter 去掉 `includes_specs`，
  验收从"spec criteria 全 done"改为"计划变更全部 merge + CI 绿"
- **7 Gates 术语退役**：其实质要求内嵌到工作流步骤（独立 review、每 commit 构建测试绿、发版 pre-flight）
- **Hard Gates（6 种必须问人类的情形）不变**，权威副本在 `AGENTS.md`
- **ADR 体系保留**（append-only、编号不复用）；本次移除已 superseded 的 ADR 0002，编号 0002 保留空缺
- ADR 0007 中"母法 spec §4 / §3.3 继续有效"的表述自本 ADR 起失效；frontmatter 速查的权威版本改为
  [`.agent/rules/docs.md`](../../.agent/rules/docs.md)

## Consequences

### Positive

- 流程贴合 Claude Code 原生工具（plan mode / slash skills），无需维护平行的 skill 依赖与 fallback 表
- 文档负担大幅下降：新功能从"research + spec + plan + 7 gates"变为"一次 plan review + 一次 code review"
- 单一 AI 会话可以端到端跑完整流程，不再依赖跨 session 的 spec 交接

### Negative

- 失去 spec 级设计存档：功能的设计意图今后由 plan review 记录、PR 描述与 ADR 承担
- 历史文档（versions / CHANGELOG / 旧 ADR）中的 spec 引用成为纯历史名词，链接不再可解析（不回改）

### Neutral

- AI-led 原则（[ADR 0003](./0003-ai-led-development.md)）、Hard Gates、"禁止自审自批"的独立 review 原则均不变
- issue 驱动工作流（小任务通道）不受影响，此前已独立简化

## Alternatives considered

### Alternative A — 保留精简版 spec 层

- 描述：spec 减为一页纸模板，仍入库归档
- 拒绝原因：owner 判定仍过重；plan mode 的计划 + PR 描述已覆盖同等信息，入库归档在上一轮清理中已被证明是"定期删除"的对象

### Alternative B — 完全去掉 review 环节

- 描述：AI 直接实施 + 合并，靠 CI 兜底
- 拒绝原因：失去独立审查兜底，违背 ADR 0003 "禁止自审自批" 的根基

## References

- [ADR 0003 — AI-led development](./0003-ai-led-development.md)
- [ADR 0007 — AI 开发规则改用 `.agent/rules/` 组织](./0007-agent-rules-restructure.md)
- 新工作流权威描述：[`AGENTS.md`](../../AGENTS.md)「开发工作流」
- 被移除的母法 spec：`2026-05-11-docs-governance`（见 git history）
