# docs/

文档总索引。任意 AI 进入本仓库后，建议读完根目录 `AGENTS.md` 之后立刻读本文件，理解文档分布。

> 治理母法：[`superpowers/specs/2026-05-11-docs-governance.md`](./superpowers/specs/2026-05-11-docs-governance.md)（spec id `2026-05-11-docs-governance`）。
> 其 §3.1 目录树为历史快照；AI 开发规则现按 [ADR 0007](./adr/0007-agent-rules-restructure.md) 组织在根目录 [`.agent/rules/`](../.agent/rules/)。

## 子目录

| 目录 | 用途 | 何时写 |
|---|---|---|
| [`research/`](./research/) | 长期事实性调研（业界 / 竞品 / 外部 API 变化） | 主动调研、或调研跨多 spec 复用 |
| [`superpowers/specs/`](./superpowers/specs/) | 单次设计 spec（brainstorming 产出） | 启动新功能 / 模块 / 流程 |
| [`superpowers/plans/`](./superpowers/plans/) | 实施 plan（writing-plans 产出） | spec 通过 G2 后，进入实施前 |
| [`adr/`](./adr/) | 架构决策记录（append-only） | 决策需让 6 个月后的 AI 也能看懂 |
| [`versions/`](./versions/) | 版本路线 + 每版本验收 + release notes 草稿 | 计划下一个 vX.Y.Z 时；发版前后更新 |
| [`runbooks/`](./runbooks/) | AI 可执行的标准操作流程 | 任何 AI 要按部就班跑的操作 |
| [`artifacts/issues/<num>/`](./artifacts/issues/) | issue 驱动流程的逐 issue 产物（`diagnosis` / `plan-review` / `verification` / `done.json` / `handoff`），由 `scripts/issues/*.sh` 维护 | 每个走 issue 驱动的 issue |

## 根目录配套

| 文件 | 角色 |
|---|---|
| [`AGENTS.md`](../AGENTS.md) | **AI 治理入口**（中立 runner），所有 AI 进仓库的第一份要读 |
| [`.agent/rules/`](../.agent/rules/) | 按领域拆分的详细 AI 开发规则（Rules Index 见 `AGENTS.md`） |
| [`CLAUDE.md`](../CLAUDE.md) | Claude Code 专用提示（import AGENTS.md + Claude 专属 hint） |
| [`CHANGELOG.md`](../CHANGELOG.md) | 用户视角变更记录，AI 在发版 runbook 自动维护 |
| [`README.md`](../README.md) | 面向用户与开源 contributor 的产品介绍 |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | 人类 contributor 指南；项目实际为 AI-led |

## 当前状态

- 当前 tag：fork 自 Blimp-Labs 截止 `v0.0.6`；本仓库自 `v0.0.7` 起独立编号（[ADR 0004](./adr/0004-fork-divergence-from-blimp-labs.md)）
- 当前版本计划：见 [`versions/README.md`](./versions/README.md)
- 当前进行中 spec：见 [`superpowers/specs/README.md`](./superpowers/specs/README.md)

## 写作约定

见 [`.agent/rules/docs.md`](../.agent/rules/docs.md)（写作风格 / frontmatter 速查 / 命名规范单源）。
