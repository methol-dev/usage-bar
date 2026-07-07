# CLAUDE.md

Guidance for Claude Code in this repo. **不是通用 AI 入口** — 通用治理 / 命令 / 约定见
[`AGENTS.md`](./AGENTS.md) + [`docs/agents/`](./docs/agents/)。本文件只留 Claude Code
高频踩到的**专用坑**。

@AGENTS.md

> 上面一行用 Claude Code 的 `@import` 语法把 [`AGENTS.md`](./AGENTS.md) 完整加载为上下文。

## 跳板

- 日常 swift / make 命令 → [`docs/agents/operations.md`](./docs/agents/operations.md) §1
- 项目架构红线（改代码前必读）→ [`docs/agents/operations.md`](./docs/agents/operations.md) §7
- Issue 驱动开发配置 → [`docs/agents/operations.md`](./docs/agents/operations.md) §2
- 写作约定 / frontmatter → [`docs/agents/conventions.md`](./docs/agents/conventions.md)

## Mock server gotcha

`scripts/mock-server.py` mock 四条路由：`GET /api/oauth/usage`（按当前 scenario 返回用量）、
`GET /api/oauth/userinfo`（静态假用户信息）、`GET /scenario/<name>`（运行时切换 scenario）、
`POST /v1/oauth/token`（假 token 端点，仅供手动实验）。真实浏览器 OAuth flow **不** mock。
要把 app 指向它必须临时改：
1. `Providers/Claude/UsageService.swift` 的 `defaultUsageEndpoint`
2. `macos/Resources/Info.plist` 加 `NSAppTransportSecurity > NSAllowsLocalNetworking`

**两处改动 commit 前必须还原** — 不在 debug flag 后面，否则会 leak 到 main。Mock server
不实现 OAuth flow，所以本地测试需要 Claude CLI Keychain 里已有有效凭证（v0.5.1 起凭证
in-memory only，启动时从 Claude CLI Keychain 借读，不再落盘 `credentials.json`）。

完整 scenario 列表见 [`CONTRIBUTING.md`](./CONTRIBUTING.md) §Testing with the mock server。

## Claude Code 专用 hint

- 用 `AskUserQuestion` 触发 hard gate 升级（不要开放式问）
- 用 `TaskCreate` 追踪 brainstorming → spec → plan 进度，每步 `TaskUpdate`
- `superpowers:brainstorming` skill 是设计任务的入口；`writing-plans` 是后续 plan 阶段
- codex 工具不可用时**直接走 `general-purpose` subagent fallback，不要停下问用户**（已记 memory）
