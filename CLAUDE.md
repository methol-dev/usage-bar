# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

> 上面一行用 Claude Code 的 `@import` 语法把 [`AGENTS.md`](./AGENTS.md) 完整加载为上下文。
> 本文件只保留 Claude Code 高频用到的**技术坑与实操命令**；项目治理 / 版本路线 / review gate 等
> 全部在 `AGENTS.md`，避免两边维护漂移。

## Repo at a glance

A macOS menu bar app (SwiftUI + Swift Charts) that displays Claude API usage. The Swift package and all build scripts live under `macos/`; root-level `Makefile` is the canonical entry point and wraps `macos/scripts/build.sh` (bundle .app, embed Sparkle, ad-hoc codesign).

Targets macOS 14+, Swift 5.9. The only runtime third-party dependency is [Sparkle](https://sparkle-project.org) 2.8.1, pinned exact in `macos/Package.swift`.

## Common commands

All `make` targets are run from the repo root. Plain `swift` commands must be run from `macos/` because that is where `Package.swift` lives.

```sh
make build              # swift build -c release (cd macos)
make app                # build + bundle .app (Info.plist, assets, Sparkle, codesign)
make zip                # app + zip + verify-release
make dmg                # app + DMG (downloads create-dmg v1.2.3) + verify-release
make release-artifacts  # build once, produce both zip and dmg, verify both
make install            # build + copy bundle into /Applications
make clean              # swift package clean + delete bundle/zip/dmg

# Tests (must cd into macos/)
cd macos && swift test
cd macos && swift test --filter UsageServiceTests
cd macos && swift test --filter UsageServiceTests/testBackoffIntervalCapsAtSixtyMinutes
```

CI (`.github/workflows/build.yml`) runs `swift build -c release`, `swift test`, then `make release-artifacts` on every push/PR to `main`. Keep both `swift test` and `make release-artifacts` green.

## Architecture — what spans files

The big picture cannot be inferred from any single file. Key invariants:

- **`UsageService` is the single source of truth for API state.** It owns OAuth (PKCE + browser callback paste), token refresh, polling timer, and exponential backoff. Other types receive it via `@StateObject` injection from `UsageBarApp` and read published properties — do not duplicate fetch/auth logic elsewhere. See `UsageService.swift:1-100`.
- **Three injected services compose the app**, wired in `UsageBarApp.swift`: `UsageService` (API), `UsageHistoryService` (in-memory ring buffer flushed to disk every 5 min and on `willTerminate`; 30-day retention), `NotificationService` (threshold notifications), `AppUpdater` (Sparkle wrapper). `UsageService` holds weak-ish references to history/notification services so its polling loop can push samples and fire alerts.
- **Token & history live on disk under `~/.config/usage-bar/`**: `credentials.json` (0600, contains access+refresh+expiry+scopes; falls back to legacy plaintext `token` file if present — see `StoredCredentials.swift`) and `history.json`. The legacy `token` file is deleted on first save of the new format.
- **Model price data comes from a bundled LiteLLM snapshot, not hand-maintained tables.** `ModelPricingCatalog` loads `litellm_model_prices.json` (upstream: `BerriAI/litellm`'s `model_prices_and_context_window.json`) with priority: `~/.config/usage-bar/litellm_model_prices.json` (runtime cache, refreshed every 3h on the background tick — see `ProviderCoordinator.onTickSideEffects`) → bundled copy → empty table (UI degrades to "定价数据未加载"). `build.sh` `curl`s a fresh snapshot into `macos/Sources/UsageBar/Resources/litellm_model_prices.json` *before* `swift build` and `git checkout`s it back *after* assembling the bundle (so `git status` stays clean; if the fetch fails it just keeps the committed copy). `OpenAIPricing` / `ClaudePricing` now only hold `normalize`/`displayName`; all price lookups go through `ModelPricingCatalog` (which runs a step-down fallback candidate chain so codex CLI aliases like `gpt-5.3-codex` resolve). `THIRD_PARTY_LICENSES.txt` (LiteLLM MIT) is bundled alongside; both new resources are checked by `verify-release.sh`.
- **Bundle creation is custom, not stock SwiftPM.** `macos/scripts/build.sh` runs `swift build -c release`, then hand-assembles `.app/Contents/{MacOS,Resources,Frameworks}`, copies the SwiftPM resource bundle (`UsageBar_UsageBar.bundle`), compiles `Resources/Assets.xcassets` with `actool`, and embeds `Sparkle.framework`. Adding new bundled resources requires they land in the SwiftPM resource bundle (declared in `Package.swift` `resources: [.process("Resources")]`), and any new `.app/Contents/Resources/...` invariants must also be enforced in `macos/scripts/verify-release.sh`.
- **Sparkle is gated by `SU_FEED_URL` at build time.** If the env var is unset (the default for local builds), `build.sh` strips `SUFeedURL` from `Info.plist`, leaving the updater inert. Release CI injects the feed URL. Do not hardcode the feed URL in `Info.plist`.
- **Releases are tag-driven.** Pushing a `v*` tag triggers the release workflow which builds once, produces ZIP (Sparkle) + DMG (manual install), verifies both artifacts, generates a signed Sparkle `appcast.xml` from the ZIP, and deploys to GitHub Pages. Requires `SPARKLE_PRIVATE_KEY` repo secret. `Info.plist` 中的 `CFBundleShortVersionString` / `CFBundleVersion` 在 build 时由 `APP_VERSION` 环境变量或 git tag 注入；plist 里写死的 `1.0.0` 是历史占位，不要手改。

## Mock server gotcha

`scripts/mock-server.py` only mocks `GET /api/oauth/usage`. To point the app at it you must temporarily edit `UsageService.swift`'s `defaultUsageEndpoint` AND add `NSAppTransportSecurity > NSAllowsLocalNetworking` to `macos/Resources/Info.plist`. **Both edits must be reverted before committing** — they are not behind a debug flag. The mock server does not implement the OAuth flow, so an existing valid token in `~/.config/usage-bar/credentials.json` is required.

## Style & dependencies

- Keep third-party dependencies minimal — Sparkle is the only runtime dep, and adding another requires updating `Package.swift`, `verify-release.sh` (if it ships in the bundle), and the `build.sh` framework-bundling step.
- One primary SwiftUI view per file (existing convention: `PopoverView.swift`, `SettingsView.swift`, `UsageChartView.swift`).
- All UI-touching service classes are `@MainActor`; keep that annotation when extending them.

## Issue 驱动开发配置

> 本节为 `methol-issue-driven-dev` skill 的项目配置单源。改动需配合 `.github/labels.json` 与 `scripts/issues/` 一起更新。完整生命周期见 [`docs/workflow/issue-driven.md`](./docs/workflow/issue-driven.md)。

### 适用范围
- 适用:人工测试反馈的 bug、单个小功能点、脚本 / 文档微调。
- 不适用:跨模块架构级、需要 spec / ADR 支撑的大粒度任务 —— 走 [`AGENTS.md`](./AGENTS.md) §4 的 research → spec/ADR → plan → 实施 主回路。

### 模块清单 → scope 标签
| scope 标签 | 覆盖范围 |
|-----------|---------|
| `scope:infra` | CI / `scripts/` / `Makefile` / `macos/scripts/` 构建链路 / 治理文档工具链 |

本仓库是单个 macOS app,业务代码改动默认不打 scope(只在涉及构建 / 工具链时打 `scope:infra`)。(同步到 `.github/labels.json`)

### 评审者
- `reviewer`: `subagent` —— 用 Task 起评审 agent,prompt 见 skill 的 `references/review-prompts.md`。与 AGENTS.md §5 的 fallback 一致,无需 codex;codex 可用时也可临时改用 `codex`(`codex:rescue` skill)。

### 守护线 checklist(plan 阶段自检,任一项触发 → `status:needs-human`)
- [ ] 不触碰凭证 / 密钥链路:OAuth token 刷新、`credentials.json` 格式、Sparkle 私钥、`SU_FEED_URL` 注入逻辑(见 AGENTS.md §6.1)
- [ ] 不引入新第三方依赖、不改 `LICENSE`、不改变开源 / 收费定位
- [ ] 不修改 `docs/adr/` 下已 `accepted` 的 ADR、不修改 `AGENTS.md` 或母法 spec(issue 明确要求除外)
- [ ] 不在 `UsageService` 之外重复 fetch / auth / 轮询逻辑(架构红线,见本文件 Architecture 节)
- [ ] 不手改 `Info.plist` 里的版本号(由 `APP_VERSION` / git tag 在 build 时注入)
- [ ] 单 issue 影响面不跨"app 代码 / 发版链路 / 治理文档"三大块,且改动文件数大致 ≤ 5

### 受保护文件 / 敏感写入链路
- 受保护文件(改了就 `status:needs-human`):`docs/adr/*`、`AGENTS.md`、`docs/superpowers/specs/2026-05-11-docs-governance.md`、`.github/workflows/release.yml`、`macos/Package.swift` 的依赖 pin、`macos/scripts/verify-release.sh` 的 invariant 检查
- 敏感写入链路(ship 阶段 diff 碰到就 `status:needs-human`):OAuth / token 刷新链路(`UsageService.swift`、`StoredCredentials.swift`)、Sparkle 更新链路(`AppUpdater.swift`、`appcast.xml` 生成、release workflow)、codesign / `build.sh` 的 framework 嵌入步骤

### 本地验证命令(实施后、ship 前必跑相关项)
| 触发条件 | 命令 |
|---------|------|
| 改 Swift 代码 | `cd macos && swift build -c release` + `cd macos && swift test` |
| 改 build / bundle / `scripts/` | `make release-artifacts` + `bash macos/scripts/verify-release.sh macos/UsageBar.zip` |
| 改 UI | `make app` 后手动起 app 回归金路径(尽量少跑 Xcode build) |
| 改纯文档 | 链接核对 + frontmatter lint(母法 spec 的 `automated_checks`);无脚本则人工核对 |

### CI / PR checks
- PR 必须等绿的 check:`build`(`.github/workflows/build.yml`,跑 `swift build -c release` → `swift test` → `make release-artifacts`)。`merge.sh` 用 `gh pr checks --watch` 等全部 check 绿。

### artifacts 路径
- `docs/artifacts/issues/<num>/` —— 本仓库把 skill 默认的 `artifacts/issues/<num>/` 挪到 `docs/` 下(统一收纳进文档树)。`scripts/issues/{kickoff,ship,merge}.sh` 已同步该路径;若日后从 skill 重新同步脚本,记得保留这个 override。
