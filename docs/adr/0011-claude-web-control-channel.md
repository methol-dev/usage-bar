---
id: 0011
title: Claude Web 反向控制通道（扩展轮询主程序拉配置）
status: proposed
date: 2026-07-18
deciders: methol, claude-code
---

# ADR 0011 — Claude Web 反向控制通道（扩展轮询主程序拉配置）

## Context

[ADR 0009](./0009-claude-web-usage-source.md) 的数据流是**单向**的：Chrome 扩展在用户 claude.ai 会话取用量 →
Native Messaging → 主程序。主程序无法主动指挥扩展（Native Messaging 只能 Chrome→host 拉起，主进程没有
反向通道）。这带来两个缺口：app 里的「Refresh」按钮无法让扩展真去取一次新数据；关掉 Claude / Web 源后
扩展仍在后台同步。

owner 提出把主导权反转：让扩展**主动**定期（每 ~1min）轮询主程序拉「配置」，据此行动；拉不到就休眠。

关键事实：
- `chrome.runtime.sendNativeMessage` 是「发一条 → host 回一条 → host 退出」的一次性交换。Chrome 会读取
  host 退出前写入管道的那条 response 交给回调（管道语义：writer 退出后已写字节仍可读，EOF 在字节读完后才到）。
  因此「host 回完就退出」不丢 response —— 前提是 host 用无缓冲 `write(2)`（本仓库 host 用 `FileHandle`，满足）。
- MV3 service worker 会被杀（~30s 空闲），`connectNative` 的长驻端口随之断，对本场景**不比** `sendNativeMessage`
  更可靠，反而要长驻 host 进程（ADR 0009 已刻意避免）。故仍用一次性 `sendNativeMessage` + 轮询。
- 扩展进程（host）由 Chrome 按 manifest 拉起，与菜单栏 GUI 是否在运行**无关**。故「app 关了」host 仍能应答，
  只是返回**陈旧**的控制文件 —— 需要 liveness 判据。

## Decision

新增一条**反向控制通道**：主程序写控制文件 `~/.config/usage-bar/claude-web-control.json`，扩展经 host
轮询拉取。

1. **控制文件** `ClaudeWebControl { paused, intervalSeconds, syncNonce, ts }`（app 原子写 0600）。
2. **host 分派 + 回传**：入站 `{"type":"poll"}` = 只拉配置（不写 usage）；其余 = usage payload（写
   `claude-web.json`，不变）。两种 ack 都带回控制文件原文：`{"ok":<bool>,"control":<json>|null}`。host 只做
   「是合法 JSON」形状校验后原样内嵌（缺失/空/半截/畸形 → `control:null`，保证 response 恒为合法 JSON）；
   不解析其字段，仍不发网络、不起 AppKit。
3. **扩展心跳**：默认每 1min 轮询（`{type:"poll"}`）。据 control 行动：
   - `paused` → 停止 claude.ai 取数；
   - `syncNonce` 变化 → 立即取数一次（app 端 Refresh 的闭环）；
   - `intervalSeconds` → 自主取数节奏（跟随 app 轮询间隔）；
   - 拉不到 / `ts` 陈旧（app 关或崩，文件不再刷新）→ **退避休眠**（心跳周期沿 1→2→5→10min 阶梯拉长，持久化，
     `tabs`/`focus` 事件可唤醒）。
4. **app 侧发布点**（集中在 `ProviderCoordinator`，它同时知道 Claude 顶层启用与 Web 子源启用）：启动、每
   ~2min liveness timer（刷新 `ts`，与 pollingMinutes 解耦）、后台 tick、源勾选/优先级变化、pollingMinutes 变化；
   **仅** popover Refresh（`coordinator.refreshNow(.claude)` 唯一调用点）bump `syncNonce`（持久化、单调）。
   `paused = !(Claude 顶层启用 && Web 源启用)`。
5. **可观测**：扩展 popup 显示「上次收到 control」的时间 —— 通道死（response 系统性丢失）与「通道健康但空闲」
   可区分，不被「拉不到就睡」掩盖。

## Consequences

### Positive
- app 能反向指挥扩展：Refresh → 扩展 ≤1min 内真取一次；关 Claude/Web 源 → 扩展停同步、更省。
- 仍是一次性 `sendNativeMessage` + 短命 host，不引入长驻进程 / 新端口 / 新依赖。version-skew 安全：旧扩展忽略
  新 response；新扩展遇旧 host（无 control）按「拉不到」优雅休眠。

### Negative
- 1min 心跳 = 约 1440 次/天 host spawn（当前空闲基线 5min alarm 的 ~5×）。每次 fork/exec 主 binary（dyld 映射
  Sparkle 等），轻微 CPU + 唤醒开销。owner 明确要 1min 响应；paused/陈旧/不可达时退避休眠缓解非常态。
- liveness 靠 `ts` 陈旧判定；app **崩溃**（非正常退出）后,扩展最多再同步到 `ts` 超过 `CONTROL_STALE`（~5min）
  才休眠。可接受。
- host 文件契约从「只碰 claude-web.json」扩为「读 control 文件」；同用户、同信任边界，无凭证（SC7 不变）。

### Neutral
- `sendNativeMessage` 能否可靠回传 response 是本方案命门；理论成立（管道语义 + 无缓冲写），但需真机 Chrome
  验证（go/no-go）。扩展的「拉不到就睡」是韧性兜底,非对失效的粉饰（配 popup 正向信号可诊断）。

## Alternatives considered
- **`connectNative` 长驻端口**：MV3 SW 被杀即断端口，不更可靠，且要长驻 host（ADR 0009 已避免）。拒绝。
- **本地回环 HTTP**：新监听端口 = 新攻击面（ADR 0009 Alternative C 已拒绝）。拒绝。
- **5min 心跳 + 只搭 usage-ack 便车**：开销回到基线，但控制延迟 ~5min；owner 选 1min。备选保留在心跳常量里。

## References
- 扩展 ADR 0009（Claude Web 用量源）数据流为双向（拉模型）；与 ADR 0010（Claude 多数据源）的 Web 源同一条链。
- 实施：本 PR（ClaudeWebControl + host 分派/回传 + coordinator 发布 + 扩展心跳/退避）。
