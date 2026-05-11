# Runbook — Release

> AI 标准发版流程。任何 `vX.Y.Z` tag 推送都遵循本流程。  
> ⚠️ 涉及 hard gate 的步骤标注 ⚠️ HARD GATE — 必须人类介入。

## 适用范围

- patch 版（v0.0.x）：跑全部步骤
- minor 版（v0.x.0）：额外跑 §7 G7 integration verification（`/ultrareview` 或 subagent 并发抽样）
- 纯文档版（如 v0.0.7）：跳过 §3 build/test、跳过 §4 artifacts，从 §5 开始；Sparkle 不推送

## 0. 前置检查（Preflight）

```bash
# 工作目录
cd /Users/methol/data/code-methol/usage-bar

# 当前分支必须是 main
git rev-parse --abbrev-ref HEAD
# 期望输出：main

# 工作区必须 clean
git status --short
# 期望输出：空

# remote 必须是 methol/usage-bar
git remote -v | grep -q 'methol/usage-bar' || { echo "❌ Wrong remote, see ADR 0004"; exit 1; }

# 当前最新 tag
LATEST_TAG=$(git tag --sort=-v:refname | head -1)
echo "Latest tag: $LATEST_TAG"
```

判定条件：
- [ ] 分支 = main、工作区 clean
- [ ] remote = methol/usage-bar
- [ ] 待发版本号严格 > LATEST_TAG（semver 比较）
- [ ] 待发版本号在 `docs/versions/` 有对应文件且 `status: in-progress`

## 1. 待发版本 spec 验收（G6）

```bash
VER=v0.0.X       # 替换为待发版本
VERSION_FILE=docs/versions/${VER}-*.md

# 收集本版本包含的 spec
yq '.includes_specs[]' $VERSION_FILE 2>/dev/null
```

对每个 spec：

- [ ] spec 的 `## Verification log` 区块所有 SC 行 `- [x]`
- [ ] spec frontmatter `status: implemented` 或 `accepted`
- [ ] spec frontmatter `reviews:` 数组含 G5 verdict=approved

## 2. CI 与 review 通过（G5 已完成）

- [ ] 对应 PR 已 merge 到 main
- [ ] CI 全绿：build + test + release-artifacts
- [ ] G5 reviewer verdict 记录在 PR comment 或 spec reviews 数组

## 3. Build & test 本地复现（纯文档版可跳过）

```bash
cd macos
swift build -c release
swift test
cd ..
make release-artifacts
bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip
bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.dmg
```

判定：
- [ ] 全部命令 exit code 0
- [ ] `verify-release.sh` 两次都通过

## 4. Release artifacts 准备

- [ ] `macos/ClaudeUsageBar.zip` 存在且 verify 通过
- [ ] `macos/ClaudeUsageBar.dmg` 存在且 verify 通过
- [ ] 自 v0.2.1 公证后：检查 stapled ticket
  ```bash
  spctl --assess --type execute --verbose=4 macos/ClaudeUsageBar.app
  ```
  期望输出含 `accepted`

## 5. CHANGELOG.md 自动维护

AI 在本步骤生成并 append v${VER} 的中文 entry。

### 5.1 收集变更

```bash
PREV_TAG=$(git tag --sort=-v:refname | head -2 | tail -1)
git log --oneline ${PREV_TAG}..HEAD
```

### 5.2 生成中文 entry 模板

> **重要**：不要直接 copy PR 标题（可能是英文）。AI 必须把每条 PR / commit 翻译成中文，并按"用户视角"重写。

模板：

```markdown
## [v${VER}] — ${DATE}

### 新增（Added）
- <用户视角的新功能描述>（#PR 号 / commit 哈希）

### 改进（Changed）
- <行为变化、UI 调整>

### 修复（Fixed）
- <bug 修复，给出用户能理解的现象>

### 安全 / 隐私（Security）
- <如涉及>

### 内部（Internal）
- 内部重构、文档、CI 变更（用户不感知的可省略）

### 参考
- 版本计划：[`docs/versions/${VER}-...md`](docs/versions/${VER}-...md)
- 含 spec：${SPEC_IDS}
```

### 5.3 落地

```bash
# AI 用 Edit 工具在 CHANGELOG.md 顶部（保留 # Changelog 标题后）插入新 entry
# 不要覆盖历史 entry
```

判定：
- [ ] CHANGELOG.md 顶部已含 v${VER} entry
- [ ] 中文表达；技术术语保留英文
- [ ] 引用本版本的 version 文件与 spec id

## 6. 推送 tag

```bash
git tag ${VER} -m "${VER}"
git push origin ${VER}
```

判定：
- [ ] tag 已推送，GitHub 上可见
- [ ] CI tag-driven release workflow 启动

## 7. GitHub Release & Sparkle 推送

CI 完成后：
- [ ] GitHub Release 已自动创建
- [ ] 上传资源：`ClaudeUsageBar.zip` + `ClaudeUsageBar.dmg`
- [ ] release notes 含本版本 CHANGELOG entry（自动从 `release_notes_zh` 同步）
- [ ] Sparkle appcast (`https://methol.github.io/usage-bar/appcast.xml`) 已更新
- [ ] minor / major 版本：额外跑 `/ultrareview` 整体 review（G7）

## 8. version 文件状态翻转

```bash
# 在 docs/versions/${VER}-*.md 中：
# status: in-progress → shipped
# shipped_date: YYYY-MM-DD（提交者本地日期）
```

判定：
- [ ] version 文件 frontmatter status / shipped_date 已更新
- [ ] commit message：`chore(release): mark ${VER} as shipped`

## 8.5 Sparkle 双通道（v0.2.2+）

自 v0.2.2 起 app 支持 Sparkle stable / beta 双通道。tag 命名约定：

| Tag pattern | Channel | CI 行为 |
|---|---|---|
| `v0.X.Y` / `v1.0.0` 等不带 `-beta.N` 后缀 | **stable** | appcast item 不带 `<sparkle:channel>` 标签（默认通道） |
| `v0.X.Y-beta.N` / `v0.X.Y-beta.1` 等带 `-beta.N` 后缀 | **beta** | appcast item 加 `<sparkle:channel>beta</sparkle:channel>` |

约束：
- 两类 item 都进**同一个** `appcast.xml`，部署到 GitHub Pages
- 用户在 Settings → "更新通道" 选 Beta 后能看到 beta items；选 Stable 则不可见
- beta 用户的 `allowedChannels` = `["stable", "beta"]`，**也能**收 stable 更新（不会"卡在 beta"）
- 跨 channel 版本比较由 `SUStandardVersionComparator` 决定（更高版本号胜出，无论 channel）

CI workflow 若使用 generate-appcast 工具需根据 tag 后缀注入 `--channel beta` 参数。

打 beta tag 前置约束：
- ⚠️ HARD GATE：Apple 公证（v0.2.1）若未落地，beta build 仍未经公证 — 用户首次启动可能看到 Gatekeeper 警告
- 必须更新版本号到 `vX.Y.Z-beta.N` 后再 tag 推送
- 仅推 origin（`git push origin vX.Y.Z-beta.N`）；不更新 main 分支

## 9. 24h health check（发版后异步）

24 小时后：

- [ ] Sparkle appcast 没有 5xx
- [ ] GitHub Release downloads 数 > 0
- [ ] 无 critical issue 在 GitHub Issues 内开出
- [ ] 用户社群（如有）无重大反馈

任一项失败 → 走 `incident-response.md` 流程。

## 10. Runs log

> AI 每次发版跑完后在表末 append 一行。`evidence` 字段填 CI run URL 或本地 commit sha。

| Date | Version | Result | Operator | Evidence |
|---|---|---|---|---|
| — | — | — | — | (尚未跑过) |

## 引用

- 母法：[`../superpowers/specs/2026-05-11-docs-governance.md`](../superpowers/specs/2026-05-11-docs-governance.md) §4.2 G6/G7
- ADR 0004：[`../adr/0004-fork-divergence-from-blimp-labs.md`](../adr/0004-fork-divergence-from-blimp-labs.md)
- 关联：[`notarization.md`](./notarization.md)、[`sparkle-keys.md`](./sparkle-keys.md)、[`incident-response.md`](./incident-response.md)
