---
id: 0005
title: 重新开放多 provider 方向 — 先搭 UI 外壳，逐步对接（首个 Codex）
status: accepted
date: 2026-05-12
deciders: claude-code, methol
---

# ADR 0005 — 重新开放多 provider 方向

## Context

ADR 0002（已随 2026-07-08 治理清理移除正文，见 git history）在 2026-05-11 决定"专注 Claude，不做多 provider"，理由是工程范围收敛、与 CodexBar 拼广度无差异化、AI 单兵维护多回退路径不现实。

到 v0.2.3 为止，那个判断对早期是对的：先把 Claude 一条线（OAuth + CLI 凭证 + JSONL 扫描 + 多账号 + 用量持久化 + 热力图）做扎实。但现在情况变了：

- **用户明确要做** Codex 对接（owner 决策，2026-05-12）：日常同时用 Claude 和 Codex，菜单栏里只能看一个很别扭。
- **v0.2.3 的存储层已经按 provider 维度建模**（`StoredUsageEvent` 带 provider 字段、`UsageEventStore` 按 provider 分文件），数据层不再是"为 Claude 写死"的状态——加 provider 的边际成本比 0002 写作时低。
- **本 ADR 不是"照搬 CodexBar 30+ provider"**：定位仍是"最精致的少数几个 provider 条"，不是"卷广度"。先 Claude（已完成）+ Codex（下一步），其余 provider（Cursor / Copilot / Gemini）作为 UI 占位、视需求再排。

## Decision

**重新开放多 provider 方向，supersede ADR 0002。** 分两步走：

1. **本版本（v0.2.4）只搭 UI 外壳**：popover 顶部加 provider tab（Claude / Codex / Cursor / Copilot / Gemini），仅 Claude 可用，其余显示"敬请期待"占位面板。不动数据层、不引入新 OAuth/CLI 路径。
2. **后续独立版本对接 Codex 数据层**：复用 v0.2.3 的 per-provider 存储抽象，新建 Codex 的凭证/用量 strategy。其余 provider 视用户需求再评估，不预先承诺。

差异化定位**不变**：仍是"精致 / 可靠 / 原生"，只是从"只做 Claude"放宽到"做少数几个做透的 provider，Claude 仍是一等公民"。

## Consequences

### Positive

- 满足 owner 的实际工作流（Claude + Codex 同屏）
- v0.2.3 的 per-provider 存储抽象终于有第二个消费者，验证了那次重设计的价值
- UI 外壳先行，让"多 provider"在视觉上落地、收集反馈，再决定数据层投入

### Negative

- 重新引入 ADR 0002 极力规避的复杂度：多 provider 的凭证回退、API 漂移维护负担（但限定在 Claude + Codex 两家，不是 30+）
- "敬请期待"占位 tab 若长期不兑现，会变成 UI 噪声 —— 缓解：本 ADR 明确只承诺 Codex，其余可随时从 tab 列表移除
- 营销叙事从"最精致的 Claude 专用条"要调整为"最精致的 AI 编码用量条（Claude + Codex）"

### Neutral

- 与 CodexBar 仍不构成直接替代（它卷广度，我们卷精度 + 少数几家）
- ADR 0002 转为 `superseded-by 0005`（正文已于 2026-07-08 随治理清理移除，编号保留空缺，见 git history）

## Alternatives considered

### Alternative A — 维持 ADR 0002，永不做多 provider

- 描述：继续只做 Claude，把精力全投在 Claude 数据源健壮性 + UI 上
- 拒绝原因：owner 已明确要 Codex；继续坚持 0002 等于无视真实需求

### Alternative B — 直接做 Codex 数据层对接，跳过 UI 外壳

- 描述：本版本就把 Codex 的凭证 + 用量拉通
- 拒绝原因：Codex 数据源（OAuth + CLI RPC + OpenAI Web）工作量大，塞进本以"popover 重做"为主的版本会让范围失控；先 UI 外壳、数据层独立版本更可控

### Alternative C — 照搬 CodexBar：descriptor + macro + 30+ provider

- 描述：完整 provider 抽象框架
- 拒绝原因：见 ADR 0002 Context，依然成立 —— 卷不过、无差异化、维护不起；本 ADR 只放宽到"少数几家"

## References

- 被本 ADR supersede：ADR 0002（正文已移除，见 git history）
- 相关 spec：`2026-05-12-popover-redesign`、`2026-05-12-usage-store-redesign`（历史 spec，见 git history）
- 相关 ADR：[`0001-swift-native-only.md`](./0001-swift-native-only.md)（Swift 原生约束对所有 provider 同样适用）
