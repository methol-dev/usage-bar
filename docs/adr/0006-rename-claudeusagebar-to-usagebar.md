---
id: 0006
title: Rename ClaudeUsageBar → UsageBar + 切换 bundle identifier
status: accepted
date: 2026-05-13
deciders: claude-code, methol
---

# ADR 0006 — Rename ClaudeUsageBar → UsageBar

## Context

fork 自 `Blimp-Labs/claude-usage-bar` 时，app / SwiftPM module / `.app` bundle 沿用了上游的 `ClaudeUsageBar`（CamelCase）、`Claude Usage Bar`（显示名）、`com.local.ClaudeUsageBar`（占位 bundle id）以及 `~/.config/claude-usage-bar/`（本地数据目录）。

到 2026-05-13 为止三件事使这套命名不再合适：

- **[ADR 0005](./0005-reopen-multi-provider-direction.md) 已放宽「Claude-only」**：项目定位是「最精致的少数几个 provider 条」，首个 Codex 已 merge（v0.2.6）。`Claude Usage Bar` 这个名字会误导用户以为只支持 Claude。
- **GitHub repo 本就叫 `methol/usage-bar`**（[ADR 0004](./0004-fork-divergence-from-blimp-labs.md) 决定不迁 namespace），app 名与 repo 名不一致徒增混淆。
- **本仓库从未正式发布过任何版本**（无 Sparkle 更新连续性、无真实用户的本地数据需要迁移）—— 现在是改命名的零成本窗口；越往后改代价越大（公证证书、appcast、用户数据）。

owner 已明确决定改名为 `UsageBar`、bundle id 用 `com.tuzhihao.app.UsageBar`（2026-05-13）。

## Decision

把项目标识符里的 `Claude` 前缀去掉，统一为 **`UsageBar` / `usage-bar`**：

1. **Swift 层**：Package name / executableTarget / testTarget / 源码目录 → `UsageBar`、`Tests/UsageBarTests`；`@main struct` → `UsageBarApp`；SwiftPM 资源 bundle → `UsageBar_UsageBar.bundle`；资源 finder 函数 `claudeUsageBarResourceBundle` → `usageBarResourceBundle`。
2. **`Info.plist`**：`CFBundleName` / `CFBundleExecutable` / `CFBundleDisplayName` → `UsageBar`；`CFBundleIdentifier` → **`com.tuzhihao.app.UsageBar`**（替换占位的 `com.local.ClaudeUsageBar`）。
3. **构建链 / CI**：`Makefile`、`macos/scripts/build.sh`（`APP_NAME`）、`verify-release.sh`、`.github/workflows/{build,release}.yml` 的产物名 → `UsageBar.app` / `UsageBar.zip` / `UsageBar.dmg` / `UsageBar.html`。
4. **本地存储**：`~/.config/claude-usage-bar/` → `~/.config/usage-bar/`、`~/Library/Caches/claude-usage-bar/` → `~/Library/Caches/usage-bar/`、NSLog 前缀 `[claude-usage-bar]` → `[usage-bar]`、mktemp 前缀同步。**代码不做自动迁移**——旧数据由 owner 在本地手动搬。
5. **文档**：README / CHANGELOG / CONTRIBUTING / docs（specs / plans / versions / runbooks）里指代本项目的 `ClaudeUsageBar` / `Claude Usage Bar` / `claude-usage-bar` 一并改为 `UsageBar` / `usage-bar`。

**刻意不动**：

- `Blimp-Labs/claude-usage-bar`、`blimp-labs.github.io/claude-usage-bar` —— 真实的上游 repo / GitHub Pages 地址，与本项目命名无关（见 ADR 0004）。
- `docs/adr/0004` 正文 —— append-only；其中的 `claude-usage-bar` 均为上游引用或被否决的备选 namespace（`methol/claude-usage-bar`），rewrite 等于篡改历史决策。
- `data/<provider>/` 子目录里的 provider id（`claude`、`codex` 等）—— 那是 provider 标识，不是项目名。
- `claude-logo.png` 等资源文件名、"Claude API usage" 等描述功能而非产品名的表述。

## Consequences

### Positive

- 命名与「多 provider」定位（ADR 0005）一致，不再暗示只支持 Claude
- `CFBundleIdentifier` 进入真实 reverse-DNS 命名空间，为后续 Apple 公证（v0.2.1 placeholder）扫清障碍
- app 名 = repo 名 = `usage-bar`，去掉与 `Blimp-Labs/claude-usage-bar` 的字面同名混淆

### Negative

- 现有本地安装（开发机）的 `~/.config/claude-usage-bar/` 数据需手动迁移到 `~/.config/usage-bar/`，否则首次启动会重新走 OAuth + 丢失历史
- bundle id 变更 = macOS 视为一个全新 app（UserDefaults 偏好域、TCC 授权、登录项都会重置）—— 因尚未正式发布，实际影响仅限开发者本人
- 一次性大范围改动（80+ 文件改名 + 内容替换），review 主要靠机械核对 + 构建/测试硬证据

### Neutral

- GitHub repo 名仍是 `methol/usage-bar`（ADR 0004 决定不迁 namespace），本 ADR 不改变这一点

## Alternatives considered

### Alternative A — 保持 `ClaudeUsageBar` 不改

- 描述：沿用上游命名
- 拒绝原因：与 ADR 0005「多 provider」方向矛盾；`Claude Usage Bar` 误导用户

### Alternative B — 改成全新产品名（`Tokenbar` / `Quotabar` 之类）

- 描述：借机做更彻底的 rebrand
- 拒绝原因：repo 已叫 `usage-bar`，`UsageBar` 与之天然一致；owner 未提出更激进的 rebrand 需求

### Alternative C — 只改显示名，保留旧 bundle id `com.local.ClaudeUsageBar`

- 描述：最小改动
- 拒绝原因：`com.local.*` 本就是占位、非有效 reverse-DNS；既然要改不如一次到位，何况无发布历史、无迁移成本

## References

- [ADR 0004 — Fork divergence from Blimp-Labs](./0004-fork-divergence-from-blimp-labs.md)（上游引用保留依据）
- [ADR 0005 — 重新开放多 provider 方向](./0005-reopen-multi-provider-direction.md)
- 版本：`v0.2.13-rename-usagebar`（历史 version 文档，已随 2026-07-08 文档清理移除，见 git history）
- 实施 commits：`7a420d6`（ClaudeUsageBar→UsageBar）、`533469f`（本地存储 / bundle id / ADR 0001 引用）
