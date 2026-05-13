---
slug: agents-operations
title: AI agent 实操命令与配置
type: guide
created: 2026-05-13
updated: 2026-05-13
---

# AI agent operations — 实操命令与配置

真正动手实施时的速查。**写文档时改看 [`conventions.md`](./conventions.md)；治理框架看 [`AGENTS.md`](../../AGENTS.md)**。

## 1. 构建 / 测试 / 打包命令

`make` targets 从仓库根目录跑；纯 `swift` 命令必须 `cd macos/`（`Package.swift` 在那里）。

```sh
# 构建与打包
make build              # swift build -c release（自动 cd macos）
make app                # build + 组装 .app（Info.plist / Sparkle / 资源 / 签名）
make zip                # app + zip + verify-release
make dmg                # app + DMG + verify-release
make release-artifacts  # 一次构建产出 zip + dmg + verify
make install            # build + 拷到 /Applications
make clean              # swift package clean + 删 bundle/zip/dmg

# 单测（必须 cd macos/）
cd macos && swift test
cd macos && swift test --filter UsageServiceTests
cd macos && swift test --filter UsageServiceTests/testBackoffIntervalCapsAtSixtyMinutes
```

**CI**（`.github/workflows/build.yml`）每个 push/PR 跑：`swift build -c release` → `swift test` → `make release-artifacts`。本地 commit 前要保证两者绿。

## 2. Issue 驱动开发配置

> 本节是 `methol-issue-driven-dev` skill 的项目配置单源。改动需配合 [`.github/labels.json`](../../.github/labels.json) 与 [`scripts/issues/`](../../scripts/issues/) 一起更新。
> 完整生命周期见 [`docs/workflow/issue-driven.md`](../workflow/issue-driven.md)。

### 适用范围

- **适用**：人工测试反馈的 bug、单个小功能点、脚本 / 文档微调
- **不适用**：跨模块架构级、需要 spec / ADR 支撑的大粒度任务 → 走 [`AGENTS.md`](../../AGENTS.md) §4 主回路（research → spec/ADR → plan → 实施）

### 模块清单 → scope 标签

| scope 标签 | 覆盖范围 |
|---|---|
| `scope:infra` | CI / `scripts/` / `Makefile` / `macos/scripts/` 构建链路 / 治理文档工具链 |

本仓库是单个 macOS app，业务代码改动默认不打 scope（只在涉及构建 / 工具链时打 `scope:infra`）。同步到 [`.github/labels.json`](../../.github/labels.json)。

### 评审者

- `reviewer`: `subagent` —— 用 Task 起评审 agent，prompt 见 skill `references/review-prompts.md`
- 与 [`AGENTS.md`](../../AGENTS.md) §5 fallback 一致：codex 可用时可临时改 `codex`（`codex:rescue` skill）

### 守护线 checklist（plan 阶段自检；任一触发 → `status:needs-human`）

- [ ] 不触碰凭证 / 密钥链路：OAuth token 刷新、`credentials.json` 格式、Sparkle 私钥、`SU_FEED_URL` 注入逻辑（见 [`AGENTS.md`](../../AGENTS.md) §6.1）
- [ ] 不引入新第三方依赖、不改 `LICENSE`、不改变开源 / 收费定位
- [ ] 不修改 `docs/adr/` 下已 `accepted` 的 ADR、不修改 `AGENTS.md` 或母法 spec（issue 明确要求除外）
- [ ] 不在 `UsageService` 之外重复 fetch / auth / 轮询逻辑（架构红线，见 [`CLAUDE.md`](../../CLAUDE.md) Architecture 节）
- [ ] 不手改 `Info.plist` 里的版本号（由 `APP_VERSION` / git tag 在 build 时注入）
- [ ] 单 issue 影响面不跨"app 代码 / 发版链路 / 治理文档"三大块，且改动文件数大致 ≤ 5

### 受保护文件（改了就 `status:needs-human`）

- `docs/adr/*`、`AGENTS.md`、`docs/superpowers/specs/2026-05-11-docs-governance.md`
- `.github/workflows/release.yml`、`macos/Package.swift` 的依赖 pin
- `macos/scripts/verify-release.sh` 的 invariant 检查

### 敏感写入链路（ship 阶段 diff 碰到就 `status:needs-human`）

- OAuth / token 刷新链路：`Providers/Claude/UsageService.swift`、`Models/StoredCredentials.swift`
- Sparkle 更新链路：`App/AppUpdater.swift`、`appcast.xml` 生成、release workflow
- codesign / `build.sh` 的 framework 嵌入步骤

### 本地验证命令矩阵（实施后、ship 前必跑相关项）

| 触发条件 | 命令 |
|---|---|
| 改 Swift 代码 | `cd macos && swift build -c release` + `cd macos && swift test` |
| 改 build / bundle / `scripts/` | `make release-artifacts` + `bash macos/scripts/verify-release.sh macos/UsageBar.zip` |
| 改 UI | `make app` 后手动起 app 回归金路径（尽量少跑 Xcode build） |
| 改纯文档 | 链接核对 + frontmatter lint（母法 spec `automated_checks`）；无脚本则人工核对 |

### CI / PR checks

- PR 必须等绿：`build`（`.github/workflows/build.yml`，跑 `swift build -c release` → `swift test` → `make release-artifacts`）
- `merge.sh` 用 `gh pr checks --watch` 等所有 check 绿

### artifacts 路径

- `docs/artifacts/issues/<num>/` — 本仓库把 skill 默认的 `artifacts/issues/<num>/` 挪到 `docs/` 下
- [`scripts/issues/{kickoff,ship,merge}.sh`](../../scripts/issues/) 已同步该路径
- 若日后从 skill 重新同步脚本，记得保留这个 override

## 3. 跨 runner 工具 preflight 详表

进入仓库后 AI 应先确认核心工具可用。任何一项不可用，**走 fallback 而不停下问用户**（除非所有路径都失败）。

| 角色 | Claude Code 工具 | 其他 runner 等价 | Fallback |
|---|---|---|---|
| brainstorming | `superpowers:brainstorming` | 手写本 spec _TEMPLATE.md + 对话 | 直接对话 + 模板 |
| 写 spec | `Write` / `Edit` | 等价文件操作 | 直接编辑 |
| writing-plans | `superpowers:writing-plans` | 手写 plan markdown + checklist | TODO.md 风格清单 |
| 实施 / verification | `superpowers:verification-before-completion` | 自检 checklist | 手动跑 `swift build && swift test` |
| 跨模型 design-review (G2) | `codex:codex-rescue` / `codex:rescue` | Codex CLI / API；换 Claude 子会话 | `general-purpose` subagent（prompt 显式要求独立判断） |
| 跨 session plan-review (G3) | `general-purpose` subagent | 新开会话 + 完整 prompt | 主会话 self-review + cool-down 后重读 |
| code-review (G5) | `superpowers:requesting-code-review` + `/review` | Codex / Cursor review | 跨模型 review + 自动化 lint |
| security-review | `/security-review` slash | 等价 prompt | 手写凭证 / 权限 checklist |
| fact-check | `Explore` subagent | 只读快速查找 | grep / find 手动 |
| integration-review (G7) | `/ultrareview` slash | 多 agent 并发抽样 | 多次独立 review + cross-check |

> **Claude Code runner 已记 memory**：codex 工具不可用时**不要停下问用户**，直接走 `general-purpose` subagent fallback。

## 4. Mock server 说明

`scripts/mock-server.py` 只 mock `GET /api/oauth/usage`。要把 app 指向它，必须临时改：
1. `Providers/Claude/UsageService.swift` 的 `defaultUsageEndpoint`
2. `macos/Resources/Info.plist` 加 `NSAppTransportSecurity > NSAllowsLocalNetworking`

**两处改动 commit 前必须还原** — 不在 debug flag 后面。Mock server 不实现 OAuth，所以本地需要已有有效 `~/.config/usage-bar/credentials.json`。

完整 scenario 列表见 [`CONTRIBUTING.md`](../../CONTRIBUTING.md) §Testing with the mock server。

## 5. CHANGELOG 维护

由 AI 在发版 runbook（[`docs/runbooks/release.md`](../runbooks/release.md) §5）自动生成。规则：

- **不要直接 copy PR 标题**（多为英文）
- 每条 PR / commit 翻译成中文 + 按"用户视角"重写
- 分类：新增 / 改进 / 修复 / 安全隐私 / 内部
- 引用对应 version 文件与 spec id

## 6. 自动化"硬证据"

下列命令产出绿色输出 = "我做完了"的硬证据（治理框架 G4）：

```sh
cd macos && swift build -c release
cd macos && swift test
make release-artifacts
bash macos/scripts/verify-release.sh macos/UsageBar.zip
```

纯文档版本：见母法 spec frontmatter `automated_checks` 中的 `SC_AUTO_LINKCHECK` / `SC_AUTO_FRONTMATTER`。
