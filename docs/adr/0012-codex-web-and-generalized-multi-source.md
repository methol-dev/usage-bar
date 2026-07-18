---
id: 0012
title: Codex Web 用量源 + 泛化多源门面与每 provider 控制通道
status: proposed
date: 2026-07-18
deciders: methol, claude-code
---

# ADR 0012 — Codex Web 用量源 + 泛化多源门面与每 provider 控制通道

## Context

[ADR 0010](./0010-claude-multi-source.md) 把 Claude 做成「多数据源门面」（CLI + Web，命中即停），
[ADR 0011](./0011-claude-web-control-channel.md) 加了「扩展轮询主程序拉配置」的反向控制通道。这两者当时都
**只服务 Claude**：门面类叫 `ClaudeProvider`、控制文件是单个 `ClaudeWebControl`、Chrome 扩展只认 claude.ai。

owner 提出：Codex（ChatGPT）也有官方网页可查用量（与 Codex CLI 同端点 `chatgpt.com/backend-api/wham/usage`，
CLI 用磁盘 `~/.codex/auth.json` 的 bearer，网页用登录会话的 bearer）。诉求：**用与 Claude Web 相同的机制**让
Codex 也支持 web 用量源 —— 请求由用户已登录的 chatgpt.com 浏览器会话发出，token 不出浏览器。

owner 拍板（AskUserQuestion）：
- **泛化门面，Codex 也多源**（而非给 Codex 单独造一套）。
- **Web 优先，CLI 兜底**（默认优先级 `[web, cli]`，与 Claude 一致）。

前置重构 [G1 / PR #51](https://github.com/methol-dev/usage-bar/pull/51) 已把 `ClaudeProvider` 泛化成
`MultiSourceProvider(id:)`、`ClaudeDataSource` → `UsageSource`、持久化 key 按 id 分隔（Claude 的 key 与旧值逐字节
一致 → 零迁移）。本 ADR 记录 G2：真正引入 Codex Web 源 + 把控制通道推广到「每 provider」。

## Decision

### 1. Codex Web 作为 Codex 的一个数据源

- 新增 `ProviderID.codexWeb`（rawValue `codex-web`），与 `.claudeWeb` 同样是**子源、非顶层 provider**
  （不进 coordinator 的排序 / 启用 / 菜单栏可见三个持久集合）。
- 新增 `CodexWebProvider` / `CodexWebPayload` / `CodexWebUsageMapper`，镜像 ClaudeWeb 的三态状态机
  （文件缺失 / logged_out|no_session / ok + staleness）。映射**复用** `CodexUsageResponse`：把扩展落盘的
  `usage` 子对象重新序列化交给现成 Decodable，再 `asProviderSnapshot()` —— wham/usage 与 CLI 同 schema。
- coordinator 注入裸 `CodexProvider` 作 `codex:`，内部构造 `codexGroup = MultiSourceProvider(id: .codex,
  cliSource: codex, webSource: CodexWebProvider())`，`.codex` 顶层注册的是**门面**；裸 CLI 单独挂在
  `codexCLI` 上（history / 登录 UX 直连它，同 Claude 的 `claude` / `claudeGroup`）。

### 2. 交接文件与控制信封泛化到每 provider

- 交接文件按 id 分：`claude-web.json` / `codex-web.json`（`WebSourceStore.fileURL(for:)`，Claude 文件名不变）。
  host 按 usage payload 的 `provider` 字段分派写入；缺失 / 未知 → `.claude`（向后兼容旧扩展）。
- 控制文件仍是**单个** `claude-web-control.json`（名字不变），内容升级为 `WebControlEnvelope`：顶层扁平
  `paused/intervalSeconds/syncNonce/ts` = **Claude 的**控制（旧扩展只读顶层即得 Claude 配置，行为不变），
  新增 `byProvider: { claude, codex }` 携带每个 web-capable provider 的独立控制。host 仍只做「合法 JSON」
  形状校验后原样内嵌，零字段解析。
- 每 provider 独立 `syncNonce`（持久化 key `<id>.web.syncNonce`，Claude 的 key == 旧 `claude.web.syncNonce`）。
  app 对某 provider 点 Refresh 只 bump 该 provider 的 nonce。
- 文件监听快 timer（~15s）遍历所有 web-capable provider，各自紧跟落盘。

### 3. 扩展一扩管两站

- `host_permissions` 加 `https://chatgpt.com/*`；一次 poll 拿整个信封，对 claude / codex 各按其
  `byProvider[id]`（Claude 缺失时回退顶层扁平）独立取数。
- Codex 取数：在 chatgpt.com 页面上下文先 `GET /api/auth/session` 拿 `accessToken`，**token 只在页面上下文里**
  用于同源 `GET /backend-api/wham/usage` 的 `Authorization` 头，**绝不回传 app**；payload 只含用量数字 + status。
- 合规不变：无 `cookies` 权限、不读 `document.cookie`、请求由用户浏览器在真实会话里发出、cookie/token 不出浏览器。

## Consequences

- **命中即停对 Codex 的取舍**（同 ADR 0010 对 Claude）：当 Codex 的 web 源优先且可用时，门面**不**调 Codex CLI
  的 `refreshNow` → CLI 派生的 **API 趋势线（`history-codex.json`）暂停记新点**（本机 JSONL 费用统计仍随 tick 刷）。
  想要趋势常新的用户可把 CLI 调优先或只启用 CLI。可接受：与 Claude 行为一致、可预期。
- 控制文件从「Claude 专属」变为「多 provider 信封」，但顶层扁平字段保持 = Claude → 旧扩展 / 旧 app 双向兼容
  （version skew 安全）。
- `codex:` 是 coordinator 的可选注入参数（默认 nil）：注入才建 codexGroup；既有单测走不注入路径、行为不变。

## Alternatives considered

- **给 Codex 单造一套 provider/控制通道**：重复 ADR 0010/0011 的全部机制，维护面翻倍。否决（owner 选泛化）。
- **每 provider 一个控制文件**：扩展要 poll 两次、host 要多一层分派。信封方案一次 poll 拿全，更省。
- **CLI 优先**：Codex CLI 端点同样可能限流；与 Claude 保持一致的「Web 优先」更稳（owner 选 Web 优先）。
