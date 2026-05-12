---
id: 0002
title: Claude-only, not multi-provider — 差异化做"最精致的 Claude 专用条"
status: superseded-by 0005
date: 2026-05-11
deciders: claude-code, methol
---

# ADR 0002 — Claude-only, not multi-provider

## Context

竞品全景（详见 [`../research/competitive-analysis.md`](../research/competitive-analysis.md)）：

- **CodexBar** 已支持 30+ provider（Codex / Claude / Cursor / Gemini / Copilot / z.ai / Kiro / Vertex / Augment / ...），用 SwiftSyntax 宏 + ProviderDescriptor 抽象做到"加一个 provider = 一个文件夹"
- **SessionWatcher** 支持 5 个工具（Claude / Codex / Cursor / Copilot / Gemini），定价 $7.99 一次性
- **本仓库现状**：只支持 Claude，单一 OAuth 路径

如果跟随 CodexBar 做 multi-provider：

- 实施成本：SwiftSyntax 宏 + descriptor 抽象 + 每 provider 独立 strategy chain + cookie/keychain/CLI/OAuth 多源回退 = 重型工程
- 用户价值：CodexBar 已经把 30+ provider 卷到极致，我们做 5 个 / 10 个都没有差异化
- 维护负担：上游 provider API 变化频繁，AI 单兵维护多 provider 的回退路径不现实

## Decision

**专注 Claude，不做多 provider**。差异化定位：*"最精致、最可靠、最 Claude-native 的菜单栏使用条"*。

具体含义：

- 不在 v1.0 路线上加入 Codex / Cursor / Gemini / Copilot 等其他 provider
- 与 CodexBar 比拼 UI 精致度、信息密度、Claude 数据源健壮性（OAuth + CLI 凭证 + JSONL 扫描 + cookie + CLI PTY 等多路径），而非广度
- Strategy chain 抽象在 v0.1.1 引入，但仅服务于 Claude 内部多路径，不预留 provider 维度
- 视觉与文案围绕 Anthropic / Claude 品牌语言（颜色、字体、文案风格）

## Consequences

### Positive

- 工程范围收敛：一个 provider 的 OAuth + CLI + JSONL + cookie + PTY 已经够 v0.1 ~ v0.3 做满
- UI 可以深度定制 Claude 特性（Opus / Sonnet 分桶、Extra usage USD 显示、weekly + 5h 双窗口可视化、subscription tier 显示等），不被多 provider 通用 UI 拖累
- 用户群体清晰：Claude Code / Claude Pro / Max 用户，营销与文档可以聚焦
- 维护负担线性、可由 AI 单兵承担

### Negative

- 失去多 provider 用户群体（多家订阅的开发者会用 CodexBar）
- 如果 Claude 业务模式大变（如 Anthropic 关停 OAuth usage endpoint），单点风险大
- 如果未来想做付费版，"只支持 Claude" 的市场天花板低于"30+ provider"

### Neutral

- 与 CodexBar 在 GitHub 上不构成直接替代关系；与 SessionWatcher 的 *"Claude monitor"* 单工具版（$2.99）是直接竞品

## Alternatives considered

### Alternative A — 跟随 CodexBar 做 30+ provider

- 描述：完全照搬 CodexBar 的 descriptor + macro + 多 strategy 架构
- 拒绝原因：见 Context 第三段；卷不过 CodexBar 且无差异化

### Alternative B — Claude + Codex 双 provider

- 描述：保留 Claude 主线，加 Codex 作为第二 provider（覆盖大多数 AI 编码用户）
- 拒绝原因：
  - Codex 数据源（OAuth + CLI RPC + OpenAI Web）实施成本不亚于 Claude
  - Codex 用户与 Claude 用户重合度不明，难证明 ROI
  - 维持"差异化定位"的 narrative 难以同时容纳两个 provider
  - 如果未来真要加，作为独立 ADR 重新评估即可

### Alternative C — Claude + 第二个 provider 由 community 贡献

- 描述：架构上预留 provider 维度，但官方只维护 Claude，其他靠 PR
- 拒绝原因：项目是 AI-led，无 community 维护资源；预留维度 = 引入复杂度但拿不到收益

## References

- 母法：[`../superpowers/specs/2026-05-11-docs-governance.md`](../superpowers/specs/2026-05-11-docs-governance.md) §4.3
- 调研：[`../research/competitive-analysis.md`](../research/competitive-analysis.md) §4.3 / §4.4 / §5.3
- 相关 ADR：[`0001-swift-native-only.md`](./0001-swift-native-only.md)
