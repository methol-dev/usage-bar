---
id: 0009
title: 新增 Claude Web 用量源（Chrome 扩展 + Native Messaging）
status: proposed
date: 2026-07-18
deciders: methol, claude-code
---

# ADR 0009 — 新增 Claude Web 用量源（Chrome 扩展 + Native Messaging）

## Context

Claude 订阅的 5h / 周窗口用量目前只能从非公开的 `api.anthropic.com/api/oauth/usage` 拿。该端点自
2026-03 起按 User-Agent 分桶限流：不冒充 `claude-code/<version>` 就持续 429（见
[anthropics/claude-code#31637](https://github.com/anthropics/claude-code/issues/31637)）。本仓库拒绝冒充
（PR #42 发诚实 UA `usage-bar`），代价是窗口用量常拿不到。

owner 明确要求：不冒充客户端、不偷读浏览器 cookie，而是用**用户自己已登录的浏览器会话**去调
claude.ai 网页显示用量时用的接口——请求由用户浏览器在真实会话里发出，与用户自己打开用量页面同源。

约束与事实：
- claude.ai 的 `/api/organizations/{id}/usage` 是官方网页在用、但**未文档化**的接口（无稳定性承诺，
  schema 未知）。
- app 现无任何子进程 / IPC 先例（Codex/Gemini 均为只读凭证文件）。
- macOS 上 Chrome Native Messaging 是官方的「扩展 ↔ 本地程序」通道，走 stdio、不开网络端口。

## Decision

新增一个**独立 provider** `ProviderID.claudeWeb`，数据链：

```
Chrome 扩展（MV3）在已登录 claude.ai 标签页上下文取用量（content-script 注入，真同源，浏览器自动带 cookie）
  → chrome.runtime.sendNativeMessage → Native Messaging host（UsageBar.app 内 wrapper 拉起主 binary --native-host）
  → host 原子写 ~/.config/usage-bar/claude-web.json → ClaudeWebProvider 轮询 tick 读文件 → 复用现成 UI
```

关键决策点：
1. **cookie 全程留浏览器**：扩展不请求 `cookies` 权限、不读 `document.cookie`，只转发 `{status, ts, usage}`。
2. **文件交接而非长驻 IPC**：Chrome 短暂拉起 host 写文件即退出，主 app 只读文件——避开仓库无先例的
   子进程生命周期管理，完全复用现有「read-only 源 + 统一 timer + runtime」范式。
3. **复用主 binary，argv 检测触发**：manifest `path` 直接指向主 binary；Chrome 拉起 host 时 argv[1] =
   扩展 origin（`chrome-extension://<id>/`），`main.swift` 据此进入 stdio host 模式。不新增 SwiftPM target、
   不放单独 wrapper —— bundle 内 `Contents/MacOS/` 第二个可执行文件会破坏 ad-hoc codesign（要求每个可执行
   都被签名）。
4. **分发**：先 load-unpacked + manifest 固定 `key`（扩展 id 跨机器稳定），Web Store 作为后续。
5. **CLI 源与 Web 源并存**：与打 oauth/usage 的 Claude CLI 源是两个 provider / 两个额度视图，不合并。

## Consequences

### Positive

- 拿窗口用量的方式对用户最透明：请求在用户真实登录会话里、由浏览器发出，不冒充任何客户端、不碰未
  文档化的鉴权端点。
- 架构改动面小：下游 tab / 用量卡 / 菜单栏 / 局部降级 UI 全部现成复用；新增集中在扩展 + 一条本地桥。
- 无新第三方依赖、无沙盒 / 签名障碍（ad-hoc 单 binary + shell wrapper）。

### Negative

- claude.ai 网页接口**未文档化**：schema 可能变、可能失效，需 Phase 0 spike 抓真实响应后才能定稿映射
  （`ClaudeWebUsageMapper` 当前为 best-effort 猜测）。
- 依赖用户装扩展 + 保持 claude.ai 登录 + 有一个 claude.ai 标签页；比「app 自己拉」多了外部依赖。
- 抓官方网页接口属 **ToS 灰区**（见下）。

### Neutral

- 展示的用量数字是 best-effort / 不可信：交接文件同用户可写、非权限边界（与现有 Codex/Gemini 读同用户
  凭证文件同威胁模型）。解码全函数化，畸形输入不崩。
- Native host 每次同步被 Chrome 短暂拉起完整主 binary（含加载 Sparkle dylib），开销轻微、可接受。

## Alternatives considered

### Alternative A — 冒充 claude-code UA 打 oauth/usage

- 描述：给现有 Claude 源发 `claude-code/<version>` UA 进宽松限流桶（ccusage / CodexBar 的做法）。
- 拒绝原因：owner 明确不接受冒充；且属 ToS 灰区（Anthropic 2026-02 明文限定 OAuth 仅供 Claude Code /
  claude.ai）。

### Alternative B — app 直接读浏览器 cookie 数据库打 claude.ai

- 描述：app 解析 Safari/Chrome 的 cookie store 取 sessionKey，自己请求 claude.ai（CodexBar 的 Web 源）。
- 拒绝原因：owner 明确不接受偷读 cookie；且请求由 app 冒充浏览器发出，透明度低于扩展方案。

### Alternative C — 本地回环 HTTP（扩展 POST 到 127.0.0.1）

- 描述：app 起本地端口收扩展推送。
- 拒绝原因：新增监听端口 = 新攻击面（需配对 token / CORS）；Native Messaging 无端口、更安全，owner 已选它。

### Alternative D — POST /v1/messages 读 anthropic-ratelimit-unified-* 响应头

- 描述：用 setup-token 发最小推理请求读限流头（CodexBar issue #1894 提案）。
- 拒绝原因：仍用订阅 token 打鉴权端点、属同一 ToS 灰区；且未确认可行，不比网页方案更合规。

## Open / Hard Gate

- **网页接口 ToS**（AGENTS.md Hard Gate 6）：抓 claude.ai 未文档化接口的合规性由 owner 确认可接受。
- **Phase 0 go/no-go**：content-script 同源 fetch 能否稳定带上会话 cookie、真实 usage schema —— 需在真实
  Chrome + 登录态验证后才继续 app 侧映射定稿。

## References

- 实施计划：本 PR
- PR #42（Claude CLI 源诊断化 + 诚实 UA）
- anthropics/claude-code#31637、#31021（oauth/usage 限流分桶）
- steipete/CodexBar `docs/claude.md`（数据源对比）、issue #1844（Keychain 2.1.x 变更）、#1894（ratelimit 头方案）
