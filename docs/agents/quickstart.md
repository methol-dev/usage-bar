---
slug: agents-quickstart
title: AI agent 任务路径反向索引
type: guide
created: 2026-05-13
updated: 2026-05-13
---

# AI agent quickstart — 任务路径反向索引

刚进项目、拿到一个具体任务时，先在本表查"该读哪里"。

## 总表

| 我要做什么 | 第一步看 | 第二步 |
|---|---|---|
| **接 GitHub issue / 修 bug / 做小功能** | [`docs/workflow/issue-driven.md`](../workflow/issue-driven.md) | `bash scripts/issues/kickoff.sh <num>` 起步 |
| **做新功能 / 模块（跨多文件，需 spec）** | [`AGENTS.md`](../../AGENTS.md) §4 主回路 | `superpowers:brainstorming` skill → spec → plan → 实施 |
| **发版（推 tag）** | [`docs/runbooks/release.md`](../runbooks/release.md) | 跑前置检查 + 自动 CHANGELOG 翻译 |
| **改架构 / 写新 ADR** | [`docs/adr/_TEMPLATE.md`](../adr/_TEMPLATE.md) | [`AGENTS.md`](../../AGENTS.md) §6 hard gate（必须人工确认） |
| **写新 spec** | [`docs/superpowers/specs/_TEMPLATE.md`](../superpowers/specs/_TEMPLATE.md) | [`conventions.md`](./conventions.md) §frontmatter |
| **写新 version 文件** | [`docs/versions/_TEMPLATE.md`](../versions/_TEMPLATE.md) | placeholder→planned 升格规则见 [`AGENTS.md`](../../AGENTS.md) §7.1 |
| **整理文档 / 索引对齐** | 走和当前 spec 一样的流程：brainstorming → spec → plan | 参考 spec [`2026-05-13-docs-cleanup`](../superpowers/specs/2026-05-13-docs-cleanup.md) |
| **日常 swift build / test / app 打包** | [`operations.md`](./operations.md) §构建命令 | 别忘了在 macos/ 目录下跑 swift |
| **接新 provider（usage 数据源）** | [`docs/runbooks/add-new-provider.md`](../runbooks/add-new-provider.md) | spec 风格参考 `2026-05-12-codex-provider` |
| **调研 / 写 research 文档** | [`docs/research/README.md`](../research/README.md) | 主要锚点 `competitive-analysis.md` |

## 关键路径速查

### 我是新进 runner，第一次进这个仓库

1. 读 [`AGENTS.md`](../../AGENTS.md)（治理骨架，≤150 行）
2. 浏览本文件（任务反向索引）
3. 看 [`docs/versions/README.md`](../versions/README.md) 知道项目当前在做什么 version
4. 看 [`docs/superpowers/specs/README.md`](../superpowers/specs/README.md) 找当前 spec
5. 真正动手前再开 [`operations.md`](./operations.md)（命令速查）+ [`conventions.md`](./conventions.md)（写作规范）

### 我是 Claude Code（vs 其他 runner）

额外读 [`CLAUDE.md`](../../CLAUDE.md)（Claude 专用坑：Mock server / Sparkle gating / 版本注入）。

### 我要做的事不在上表

兜底：先 brainstorming → spec → plan。任何**跨多文件 / 跨模块 / 有架构影响**的任务都不能跳过 spec。

## Hard gates — 必须停下问人类的 6 种情形

完整列表在 [`AGENTS.md`](../../AGENTS.md) §6；速记 6 类：

1. 凭证 / 密钥操作（Apple Developer 账号、Sparkle 私钥）
2. 引入新第三方依赖 / 改 LICENSE / 改商业模式
3. 同一 review gate ≥ 2 轮分歧无明显推荐项
4. 发版后 24h 内 health check 报警
5. spec / ADR 违反既有 ADR 且要 supersede
6. 触发法律 / 合规风险信号

升级方式：用 `AskUserQuestion`（Claude Code）或等价交互工具，**给 2~3 个具体选项 + 推荐项**，不开放式提问。

## 工具不可用时怎么办

完整 fallback 表在 [`operations.md`](./operations.md) §跨 runner 工具 preflight。一句话：**走 fallback，别停下问用户**（仅 Claude Code runner 已记 memory；其他 runner 按表执行）。
