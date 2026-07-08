# docs/

文档总索引。任意 AI 进入本仓库后，建议读完根目录 `AGENTS.md` 之后立刻读本文件，理解文档分布。

> 治理演进：AI 开发规则在根目录 [`.agent/rules/`](../.agent/rules/)（[ADR 0007](./adr/0007-agent-rules-restructure.md)）；
> spec / superpowers 治理层已废弃（[ADR 0008](./adr/0008-retire-spec-governance.md)），设计讨论走 plan review + PR，决策沉淀走 ADR。

## 子目录

| 目录 | 用途 | 何时写 |
|---|---|---|
| [`adr/`](./adr/) | 架构决策记录（append-only） | 决策需让 6 个月后的 AI 也能看懂 |
| [`versions/`](./versions/) | 版本路线 + 每版本验收 + release notes 草稿 | 计划下一个 vX.Y.Z 时；发版前后更新 |
| [`runbooks/`](./runbooks/) | AI 可执行的标准操作流程 | 任何 AI 要按部就班跑的操作 |
| [`research/`](./research/) | 长期事实性调研（业界 / 竞品 / 外部 API 变化） | 主动调研、或调研跨多任务复用 |

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

## 写作约定

见 [`.agent/rules/docs.md`](../.agent/rules/docs.md)（写作风格 / frontmatter 速查 / 命名规范单源）。
