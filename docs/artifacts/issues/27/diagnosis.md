# Issue #27 诊断

- 链接:https://github.com/methol/usage-bar/issues/27
- 标题:[feat] 增加对接gemini cli

## 复现与定位

非 bug,是新功能。目标:接入 Google 的 [gemini-cli](https://github.com/google-gemini/gemini-cli),"完整对标 Claude 和 Codex 的功能" — 即在 usage-bar 里把 Gemini 当作第三个 provider,提供与 Claude / Codex 同等的:

- 远端 quota / rate(对应 Claude `api/oauth/usage` 的 5h/7d 滚动配额、Codex `chatgpt.com/.../wham/usage`)
- 本机会话级 token / cost 统计(对应 `ClaudeUsageCollector` / `CodexUsageCollector` 扫 jsonl)
- 菜单栏图标 / Popover tab / 设置页 / 后台 polling / 历史折线

issue 提了两条参考:`codexbar.app` 怎么获取 rate,以及仓库里 Claude / Codex 的实现。

## 根因(此处 = 现状 fact-finding)

### 1. Gemini 端的数据可得性 — 不同于 Claude / Codex 的结构

| 项 | Claude | Codex | Gemini 个人 OAuth |
|---|---|---|---|
| 凭证文件 | `~/.config/usage-bar/credentials.json`(本 app 自管 OAuth) | `~/.codex/auth.json`(读 CLI 的) | `~/.gemini/oauth_creds.json`(读 CLI 的) |
| 公开 quota API | `api.anthropic.com/api/oauth/usage`(官方公开) | `chatgpt.com/backend-api/wham/usage`(私有 / 已被业界复用) | **无公开 endpoint**;CLI 自身用私有 `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` |
| 滚动窗口 | 5h / 7d(服务端给 percent + reset) | 5h primary + weekly secondary(同) | 每 model 的 `remainingFraction` + `resetTime`(需自行映射 Pro→primary / Flash→secondary) |
| 本机会话日志 | `~/.claude/projects/**/session-*.jsonl`,JSONL append-only,含 token 字段 | `~/.codex/sessions/**/rollout-*.jsonl`,同上 | `~/.gemini/tmp/<project_hash>/chats/*.json`,**单体 JSON 整体重写、无 token 字段**;JSONL 提案 [#15292](https://github.com/google-gemini/gemini-cli/issues/15292) 未实装 |

调研引用:
- CodexBar 的 Gemini 接入实测可用,做法记录在 [`steipete/CodexBar/docs/gemini.md`](https://github.com/steipete/CodexBar/blob/main/docs/gemini.md)
- gemini-cli 凭证字段定义见官方 [`packages/core/src/code_assist/oauth2.ts`](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts)
- 个人 quota 公开规格:60 req/min + 1000 req/day(Gemini 2.5 Pro),只在 CLI `/stats` 与 429 时被动告知,见 [discussion #4122](https://github.com/google-gemini/gemini-cli/discussions/4122)

### 2. OAuth client_id / secret 来源决策 — 法律 / 合规信号

Gemini 个人 OAuth 走 Google 端 client_id / secret。CodexBar 选择从本机已装的 gemini-cli 安装目录(Homebrew / npm / bun 三处之一)中**用正则从 `oauth2.js` 抠出** client_id/secret —— 其理由是规避法律风险("凭证形式上属于用户机器")。硬编码进自己的 app 是另一条路,但等同于把 Google 发给 gemini-cli 的 secret 重新分发,**触及 Google API ToS 与可能的商标 / 凭证盗用风险**。

→ 这条决定属于 [`AGENTS.md`](../../../AGENTS.md) §5 hard gate **#6 触发法律 / 合规风险信号**,**必须人工决策**,不在 AI 自决范围。

### 3. 改动面体量估算

以 Codex provider 为对标(目前 6 文件 + 注入点),Gemini provider 最少新增 / 修改:

- `Providers/Gemini/GeminiProvider.swift`(主体,对标 `CodexProvider.swift`)
- `Providers/Gemini/GeminiCredentials.swift`(读 `oauth_creds.json` + Google OAuth refresh)
- `Providers/Gemini/GeminiUsageClient.swift`(调 `v1internal:loadCodeAssist` + `retrieveUserQuota`)
- `Providers/Gemini/GeminiUsageModel.swift`(`remainingFraction` → ProviderUsageSnapshot 映射)
- `Providers/Gemini/GeminiUsageCollector.swift`(可选:扫 `~/.gemini/tmp/.../chats/*.json` 做 token 估算 — 但 schema 不稳)
- `Models/ProviderID.swift` 加 `.gemini` case
- `Services/ProviderCoordinator`(加 wire / polling 接入)
- `App/UsageBarApp.swift`(注入 GeminiProvider + Stats + History 同 Codex 做法)
- `MenuBar/MenuBarIconRenderer.swift`(图标 / 颜色 — Gemini 蓝渐变)
- `Features/Popover/PopoverView.swift` + `ProviderTabBar.swift`(加 tab)
- 设置页(可能新加 enable 开关)
- 历史落地 `history-gemini.json`(对标 Codex)

合计 **8~12 个文件**,跨"凭证 / 网络 / 本机解析 / 注入 wire / UI"五层。

## 修复方案(此处 = 实施路径选项)

三个候选,按推荐顺序:

### 选项 A(推荐)— 升级到主回路 spec → plan → 实施

走 [`AGENTS.md`](../../../AGENTS.md) §3 主回路:`superpowers:brainstorming` → 写 spec(在 `docs/superpowers/specs/2026-05-13-gemini-provider.md`)→ G2 reviewer → plan → 实施。spec 至少要决:

1. quota 数据源是 CodexBar 那条私有 endpoint 路径,还是先做"只读凭证识别身份,不显示 rate,只做本机估算";
2. OAuth client_id/secret 来源(动态抠 / 硬编码 / 让用户自己注册);
3. 本机统计的 schema 跟踪策略(跟 gemini-cli 版本走的契约,还是放弃本机统计);
4. UI 映射(Pro→primary / Flash→secondary 是否合理;免费版没有滚动窗口该怎么显示)。

理由:**改动面跨 5 层 + 私有 API + 法律决策**,任何一条都不该靠 issue-driven 短路径塞过去。

### 选项 B — 切到最小 MVP 子任务并仍走 spec(不推荐直接做)

把 issue 拆成 2~3 个子 issue:
1. 只读 `~/.gemini/oauth_creds.json` 显示登录状态 + identity(不显示 rate)— 仍 >5 文件,**仍踩守护线**
2. 接 quota endpoint
3. 本机统计

但即便是 1,也已经涉及 OAuth client_id 决策。所以**第一步仍需要 spec**,不能跳过。该选项本质等同 A,只是把 implementation 切片。

### 选项 C — 关闭 / 延后 issue

理由可包括:
- v0.4.x 路线优先级在别处(参见 [`project_provider_abstraction` memory](../../../.claude/projects/-Users-methol-data-code-methol-usage-bar/memory/project_provider_abstraction.md) 末尾候选列表)
- 等 gemini-cli 官方加 quota 公开 API / JSONL session log(#15292)再做,避免长期跟私有 schema 跑

## 影响范围
- 修改文件:8~12(估算见根因 §3)
- 风险点:
  1. 法律 / 合规 — Google OAuth client secret 分发,**hard gate #6**
  2. 私有 API 长期可用性 — `v1internal` 无 SLA,Google 可改
  3. 本机统计 schema 不稳 — `~/.gemini/tmp` 是单体 JSON,精度 / 兼容性都差
- 测试计划:N/A(此 issue 不在 issue-driven 实施阶段)

## 守护线自检

> 逐项对照 [`docs/agents/operations.md`](../../agents/operations.md) §2 "守护线 checklist"。任一项触发 → 是否需要人工介入填 YES。

- [x] 不触碰凭证 / 密钥链路 → **触发**(新增 Google OAuth client + token refresh 链路)
- [x] 不引入新第三方依赖 / 不改 LICENSE → **可能触发**(取决于是否引入 GoogleAuth Swift 库;若手写 OAuth 不引入)
- [ ] 不修改受保护文件 → 未触发(本阶段未修改 ADR / AGENTS.md)
- [x] 不在 `UsageService` 之外重复 fetch / auth / 轮询 → **设计上不违反**(Gemini 会做自己的 OAuth,但 polling 走 `ProviderCoordinator` 统一 timer,符合架构)
- [ ] 不手改 `Info.plist` 版本号 → 未触发
- [x] **单 issue 影响面不跨"app 代码 / 发版链路 / 治理文档"三大块,且改动文件数大致 ≤ 5** → **触发**(8~12 文件)

额外触发的 hard gate(见 [`AGENTS.md`](../../../AGENTS.md) §5):
- [x] **#6 触发法律 / 合规风险信号**(Google OAuth client_id/secret 来源决策)

## 是否需要人工介入

- 结论:**YES — status:needs-human**
- 理由:同时触发(a)守护线"≤5 文件"红线、(b)凭证链路、(c)hard gate #6 法律合规。三条任一都足以升级;同时触发更不能 AI 自决。
- 请用户在 issue 评论中选择 A / B / C 之一(详见上面"修复方案"段)。
