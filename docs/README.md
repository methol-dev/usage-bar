# docs/

文档总索引。任意 AI 进入本仓库后，建议读完根目录 `AGENTS.md` 之后立刻读本文件，理解文档分布。

> 治理母法：[`superpowers/specs/2026-05-11-docs-governance.md`](./superpowers/specs/2026-05-11-docs-governance.md)（spec id `2026-05-11-docs-governance`）

## 子目录

| 目录 | 用途 | 何时写 |
|---|---|---|
| [`research/`](./research/) | 长期事实性调研（业界 / 竞品 / 外部 API 变化） | 主动调研、或调研跨多 spec 复用 |
| [`superpowers/specs/`](./superpowers/specs/) | 单次设计 spec（brainstorming 产出） | 启动新功能 / 模块 / 流程 |
| [`adr/`](./adr/) | 架构决策记录（append-only） | 决策需让 6 个月后的 AI 也能看懂 |
| [`versions/`](./versions/) | 版本路线 + 每版本验收 + release notes 草稿 | 计划下一个 vX.Y.Z 时；发版前后更新 |
| [`runbooks/`](./runbooks/) | AI 可执行的标准操作流程 | 任何 AI 要按部就班跑的操作 |
| [`workflow/`](./workflow/) | 轻量协作流程（如 [`issue-driven.md`](./workflow/issue-driven.md) — bug / 小功能 / 微调走的 issue 驱动回路） | 处理 issue 号 / 人工测试反馈时 |
| [`artifacts/issues/<num>/`](./artifacts/issues/) | issue 驱动流程的逐 issue 产物（`diagnosis` / `plan-review` / `verification` / `done.json` / `handoff`），由 `scripts/issues/*.sh` 维护 | 每个走 issue 驱动的 issue |
| [`user-guide/`](./user-guide/) | 面向终端用户（中文） | 用户可见功能落地后 |

## 根目录配套

| 文件 | 角色 |
|---|---|
| [`AGENTS.md`](../AGENTS.md) | **AI 治理入口**（中立 runner），所有 AI 进仓库的第一份要读 |
| [`CLAUDE.md`](../CLAUDE.md) | Claude Code 专用提示（常用命令、构建坑） |
| [`CHANGELOG.md`](../CHANGELOG.md) | 用户视角变更记录，AI 在发版 runbook 自动维护 |
| [`README.md`](../README.md) | 面向用户与开源 contributor 的产品介绍 |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | 历史的人类 contributor 指南；项目实际为 AI-led |

## 当前状态

- 当前 tag：fork 自 Blimp-Labs 截止 `v0.0.6`；本仓库自 `v0.0.7` 起独立编号（[ADR 0004](./adr/0004-fork-divergence-from-blimp-labs.md)）
- 当前版本计划：见 [`versions/README.md`](./versions/README.md)
- 当前进行中 spec：见 [`superpowers/specs/README.md`](./superpowers/specs/README.md)

## 写作约定

- 所有日期 `YYYY-MM-DD`，以提交者本地日期为准
- 所有 spec / ADR / version 文档第一行必须是 `---`（YAML frontmatter）
- 中文优先；技术术语、命令、API 名称、模型 ID 保留英文
- 不写 emoji 除非用户明确要求
