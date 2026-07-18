---
id: 0010
title: Claude 多数据源（CLI + Web 合并为单 provider，优先级降级）
status: proposed
date: 2026-07-18
deciders: methol, claude-code
---

# ADR 0010 — Claude 多数据源（CLI + Web 合并为单 provider，优先级降级）

## Context

[ADR 0009](./0009-claude-web-usage-source.md) 新增了 Claude Web 用量源，并在其决策 #5 定为「CLI 源与 Web 源
是两个独立 provider / 两个额度视图，不合并」。落地后（PR #43）顶层出现了 `Claude` 与 `Claude Web` 两个并列
provider / 两个 tab。

owner 反馈这不是想要的形态：Claude 应是**一个** provider，其下有多个**数据源**（CLI = 打
`api.anthropic.com/api/oauth/usage`；Web = Chrome 扩展在用户 claude.ai 会话取数）。用户应能在 Settings 里
勾选启用哪些源、调它们的优先级；取数按优先级尝试、拿不到自动降级到下一个源。单数据源的 provider（Codex /
Gemini）该控件置灰。

本 ADR **amend [ADR 0009] 决策 #5**：由「两个独立 provider，不合并」改为「一个 Claude provider，多数据源」。
0009 的其余决策（cookie 全程留浏览器、文件交接而非长驻 IPC、复用主 binary+argv 检测、分发方式）不变。

## Decision

引入门面 `ClaudeProvider`（`id = .claude`，`conforms UsageProvider`），内部持两个数据源：
`.cli`（裸 `UsageService`）与 `.web`（`ClaudeWebProvider`）。

1. **注册门面而非裸 service**：`ProviderRegistry` 以 `.claude` 注册门面；`coordinator.claude` 仍指向裸
   `UsageService`，Claude 专属登录 UX / history / notifications / polling 继续直连它，改动面收敛。
2. **`.claudeWeb` 降为子源，不再是顶层**：从 `orderedProviderIDs` / `enabledProviderIDs` /
   `menuBarVisibleProviderIDs` 三个持久集合排除（registry 的 `orderedIDs` 传去 `.claudeWeb` 的顶层集）。
   `ProviderID.claudeWeb` 枚举 case 保留（Codable / 迁移 / 穷举 switch 需要），但永不注册 / 启用 / 展示为顶层。
3. **门面 runtime = 生效源镜像**：菜单栏 label 与 popover Claude 区都读门面 runtime；每次 refresh 后把「生效源」
   的 snapshot / error / isConfigured 忠实重放进门面 runtime。
4. **命中即停的优先级降级**：按用户优先级顺序遍历已启用源，第一个拿到可用快照的即生效、停止；其余源不再取数。
   默认优先级 `[web, cli]`（Web 优先以避开 oauth/usage 的 429 限流端点）。
5. **backoff 感知（防重新引入 429）**：`UsageService.fetchUsage` 自身不查 backoff，429 backoff 仅由「跳过 tick」
   实现。故门面在降级遍历中，若某源仍在其 `nextEligibleRefresh` 窗口内则**跳过、不取数**（用其既有快照兜底）；
   门面对外的 `nextEligibleRefresh` 仅在「只启用 CLI」时透传 CLI 的 backoff，只要启用了 Web（无 backoff）就恒可 tick。
6. **迁移**：PR#43 存量用户若 `.claudeWeb` 曾在 enabledProviders，或已存在扩展同步文件（`claude-web.json`），
   首次构造门面时默认勾选 Web 源；`.claudeWeb` 从三个持久集合读时被过滤掉（幂等）。
7. **Settings**：Claude 行加「数据来源」控件（多选启用 + 选优先谁）；单源 provider 置灰。

## Consequences

### Positive

- 形态符合 owner 预期：一个 Claude、可选多源、可降级；扩展面对下游 tab / 菜单栏 / 用量卡全部复用。
- Web 优先时**根本不打** oauth/usage → 从数据链上规避了最初的 429 失败（ADR 0009 Context 的动因）。
- 为「未来某 provider 有多源」留了范式（门面 + 源枚举 + 优先级）。

### Negative（命中即停的代价）

- Web 优先且可用时，CLI 的 `fetchUsage` 不跑，于是 **CLI 派生的 API 趋势线（history dataPoints）与阈值通知
  暂停更新**。本机 JSONL 统计（费用/热力图）仍随每次 tick 更新，不受影响。owner 已确认接受此取舍；需要趋势/
  通知常新的用户可把 CLI 调为优先或只启用 CLI。
- 门面 runtime 是「展示值」镜像，与两个源各自 runtime 并存（观察链上 UI 只读门面 runtime，避免闪烁）。

### Neutral

- 展示的用量仍是 best-effort（Web 源同 ADR 0009 威胁模型）；门面解码/镜像全函数化，畸形输入不崩。
- `ProviderID.claudeWeb` 作为「保留但不顶层」的枚举 case 存在，属可接受的历史包袱。

## Alternatives considered

- **每 tick 都刷所有已启用源（不命中即停）**：趋势/通知常新，但 Web 优先时仍会打 429 端点，违背规避初衷。拒绝。
- **保持两个独立 provider（ADR 0009 #5 现状）**：形态不符 owner 预期。被本 ADR amend。
- **计算型 `runtime` 直接返回生效源实例**（而非镜像重放）：源切换时 runtime 实例 identity 变化，SwiftUI
   `@Observable` 观察链不可靠传播。拒绝，采用「门面持稳定 runtime + 重放镜像」。

## References

- amends [ADR 0009](./0009-claude-web-usage-source.md) 决策 #5
- 实施：本 PR（ClaudeProvider 门面 + ClaudeDataSource + 迁移 + Settings 数据源控件）
- PR #42（诚实 UA / 诊断化）、PR #43（Claude Web 源落地）、PR #45（扩展自动同步）
