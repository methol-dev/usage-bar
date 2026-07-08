---
id: 0003
title: AI-led development — AI 主导调研 / 设计 / 实施，人类辅助
status: accepted
date: 2026-05-11
deciders: claude-code, methol
---

# ADR 0003 — AI-led development

## Context

本仓库由人类用户（methol）和 AI（默认 Claude Code）协作开发。在 v0.0.7 之前未明确分工边界。如果不固化分工：

- AI 不知道何时该自主决策、何时该停下问人类——容易过度保守（事事询问）或过度激进（替人类拍板）
- 人类不知道 AI 已经做了什么、依据何在——审计成本极高
- 后续 AI 会话不知道前任 AI 的决策权范围

调研竞品时观察到的一个事实：**SessionWatcher / CodexBar / ccusage / Claude-Code-Usage-Monitor 等同类项目都是人类主导**。我们走 AI-led 路线本身就是差异化（之一）。

## Decision

**AI 主导，人类辅助**：

- **AI（默认 Claude Code）** 主导：调研、设计、ADR 拟定、plan 制定、实施、review、发版 runbook 执行、CHANGELOG 撰写
- **人类（methol）** 辅助：
  - 仅在 [`AGENTS.md`](../../AGENTS.md)「Hard Gates」列举的情形必须介入
  - 提供凭证 / 密钥 / Apple Developer 账号等 AI 不可持有的资源
  - 在 AI 自身明确表态"拿不准"时（AskUserQuestion）做选择
  - 对 AI 产出有否决权（但非主动审批权——人类不必逐条审 spec）

**review 机制兜底**：AI 自审自批是禁止的。plan review 与 code review 必须由独立 reviewer（subagent / 跨模型 / 人类）通过。（初版为母法 spec 的 7 个 review gate，2026-07-08 起按 [ADR 0008](./0008-retire-spec-governance.md) 简化为工作流内嵌检查点。）

**文档为第一公民**：因为是 AI-led，文档必须写到"任意陌生 AI 会话只读文档就能 5 分钟接续"的程度。

## Consequences

### Positive

- AI 工作连续性：会话间断时下一个 AI 不需要"逆向工程"前任的思路
- 决策 trace 清晰：所有架构选择有 ADR、所有功能有 spec、所有版本有 release notes
- 人类时间成本最低：只在 hard gates 介入，不必每条 PR 审
- 项目可作为 *"AI 主导开源开发"* 的案例

### Negative

- 文档治理重型：初版的母法 spec / 17 条 SC / 7 个 gate 对一个 ~3.5k 行 Swift 项目显然是过度治理。**后记（2026-07-08）**：该担忧成真，治理已按 [ADR 0007](./0007-agent-rules-restructure.md) / [ADR 0008](./0008-retire-spec-governance.md) 轻量化
- AI 失误兜底压力大：人类不审批 = 必须靠独立 review 与自动化 verification（构建 / 测试 / CI）兜住失误
- 法律 / 商业责任仍在人类：commits 上的 Author 是人类（或 `Co-Authored-By: Claude` 标记）；产品发布前的最终审视仍是人类（hard gate）

### Neutral

- 与 *人类主导 + AI 助手* 模式相比，开发速度不一定快，但**一致性**更高（同一套规则约束所有 AI 会话）

## Alternatives considered

### Alternative A — 人类主导 + AI 助手

- 描述：用户写 spec / 拍板架构 / 提交 PR，AI 仅辅助打字
- 拒绝原因：用户明确希望减少自身投入；浪费 AI 主导能力

### Alternative B — 完全 AI 自治（无人类介入）

- 描述：AI 持有所有凭证、自动发版、人类完全不介入
- 拒绝原因：
  - Apple Developer 账号、Sparkle 私钥、付款信息等技术上 AI 无法持有
  - 法律 / 合规责任必须有人类 accountable
  - 完全自治会导致 AI 偏离用户真实意图（无校准信号）

### Alternative C — AI 写代码 + 人类审 PR

- 描述：AI 实施，人类逐 PR review 并 approve
- 拒绝原因：用户表态"核心是 AI"，不希望 PR 审批挂在人类身上；review 工作通过独立 AI subagent + 自动化校验承担

## References

- 用户全局指令：`/Users/methol/.claude/CLAUDE.md`（中文 / Plan Mode / Subagent / 中文 git log / karpathy-guidelines）
- 相关 ADR：[`0001-swift-native-only.md`](./0001-swift-native-only.md)、[`0008-retire-spec-governance.md`](./0008-retire-spec-governance.md)（工作流现行形态）
