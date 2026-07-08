---
alwaysApply: false
description: "本地测试 Claude 用量 API / 错误处理时读"
---

# Mock server 规则

`scripts/mock-server.py` mock 四条路由：

- `GET /api/oauth/usage` — 按当前 scenario 返回用量
- `GET /api/oauth/userinfo` — 静态假用户信息
- `GET /scenario/<name>` — 运行时切换 scenario
- `POST /v1/oauth/token` — 假 token 端点，仅供手动实验

真实浏览器 OAuth flow **不** mock。

## 把 app 指向 mock server

必须临时改两处：

1. `Providers/Claude/UsageService.swift` 的 `defaultUsageEndpoint`
2. `macos/Resources/Info.plist` 加 `NSAppTransportSecurity > NSAllowsLocalNetworking`

**两处改动 commit 前必须还原** — 不在 debug flag 后面，否则会 leak 到 main。

## 凭证前提

Mock server 不实现 OAuth flow，所以本地测试需要 Claude CLI Keychain 里已有有效凭证（v0.5.1 起凭证 in-memory only，启动时从 Claude CLI Keychain 借读，不再落盘 `credentials.json`）。

完整 scenario 列表与操作步骤见 [`CONTRIBUTING.md`](../../CONTRIBUTING.md) §Testing with the mock server。
