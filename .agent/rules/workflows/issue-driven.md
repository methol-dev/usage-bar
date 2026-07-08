---
description: "接 GitHub issue / 修 bug / 小功能 / 脚本文档微调的工作流（含本项目配置）"
---

# Issue 驱动工作流

> 适用：人工测试反馈的 bug、单个小功能点、脚本 / 文档微调。
> 不适用：跨模块架构级、需要 spec / ADR 支撑的大粒度任务 → 走 `AGENTS.md` 工作流主回路。
> 标签单源在 [`.github/labels.json`](../../../.github/labels.json)，改标签需配合 `scripts/issues/sync-labels.sh --prune` 同步。

## 原则

- **AI 主导、人只做决策**：人建 issue、异步看结果；代码、测试、commit、PR、merge 由 AI 完成，默认不阻塞。
- **过程记录在 GitHub，不落盘**：诊断发 issue comment，验证写 PR body。仓库里不留 artifacts 文件。
- **分支隔离 + PR 通道**：每个 issue 一条 `issue/<num>-<slug>` 分支，squash-merge 回 `main`，单条可回滚 commit。
- **需人介入用标签说话**：AI 打 `status:needs-human` 后转做其他事，人看到再处理。

## 生命周期

```
人创建 issue（template 自动打 type:*）
   ▼
AI 分诊：纠正 type、补 priority:*（必要时 scope:infra）
   ▼
scripts/issues/kickoff.sh <num>     # 切分支 + status:in-progress
   ▼
AI 把诊断发成 issue comment：根因 / 方案 / 需人介入自检
   │  触发需人介入清单        → status:needs-human，停
   │  影响面大（>5 文件或跨"app 代码/发版链路/治理文档"）→ 先起 subagent 做一次 plan 评审
   ▼
实施 + 本地验证（矩阵见 .agent/rules/build-test.md）
   ▼
scripts/issues/ship.sh <num> <body-file>   # push + 开 PR（body 含摘要 + 验证记录）
   ▼
评审 subagent 审 PR diff（唯一必做评审，结论贴 PR review comment）
   │  PASS         → scripts/issues/merge.sh <num>   # 等 CI 绿 + squash-merge
   │  NEEDS_HUMAN  → status:needs-human，停
   ▼
issue 由 "Closes #<num>" 自动关闭（结束；记录都在 issue + PR 里）
```

## 标签

- **type**（template 自动打）：`type:bug` / `type:feat` / `type:chore` / `type:docs`
- **priority**（分诊时打）：`priority:p0` / `p1` / `p2`
- **scope**（仅构建 / 工具链改动打）：`scope:infra`
- **status**（只表达"需要注意"的状态，其余看 issue / PR 自身状态）：
  - `status:in-progress` — AI 已认领实施中
  - `status:needs-human` — **阻塞信号**，需人决策
  - `status:blocked` — 外部依赖阻塞

## 需人介入清单（诊断自检 + PR 前复核，任一触发 → `status:needs-human`）

1. 凭证 / 密钥链路：OAuth token 刷新、`credentials.json` 格式、Sparkle 私钥、`SU_FEED_URL` 注入（hard gate，见 `AGENTS.md`）
2. 新第三方依赖 / 改 `LICENSE` / 改开源收费定位
3. 受保护文件：`docs/adr/*` 已 accepted 的 ADR、`AGENTS.md`、`.agent/rules/**`、`.github/workflows/release.yml`、`macos/Package.swift` 依赖 pin、`verify-release.sh` invariant（issue / 用户明确要求除外）
4. 敏感写入链路：`Providers/Claude/UsageService.swift`、`Models/StoredCredentials.swift`、`App/AppUpdater.swift`、`appcast.xml` 生成、codesign / `build.sh` framework 嵌入
5. 在 `UsageService` 之外重复 fetch / auth / 轮询逻辑（架构红线，见 [`swift.md`](../swift.md)）
6. 评审两轮仍不收敛，或 CI 红且原因超出 AI 能力边界（语义歧义、需人取舍）

## Commit / PR 规范

- 分支：`issue/<num>-<slug>`（`kickoff.sh` 自动生成，slug ≤40 字符）
- commit：`<type>(issue-#<num>): <summary>`，例 `fix(issue-#42): masking layout NPE on empty code`
- PR 标题：`<type>: <issue title>`（`ship.sh` 自动转换）；PR body 必含 `Closes #<num>`（模板 `.github/pull_request_template.md`）
- 合入：`merge.sh` 用 `gh pr checks --watch` 等 CI 绿后 `gh pr merge --squash --delete-branch`

## 脚本速查

| 脚本 | 作用 | 何时跑 |
|------|------|--------|
| `scripts/issues/sync-labels.sh [--prune]` | 从 `.github/labels.json` 同步标签（`--prune` 删除 json 里已去掉的） | 第一次 / 标签变更 |
| `scripts/issues/kickoff.sh <n>` | 切分支 + status:in-progress | 分诊后开工 |
| `scripts/issues/ship.sh <n> [body-file]` | push + 开 PR | 实施 + 本地验证通过后 |
| `scripts/issues/merge.sh <n>` | 等 CI + squash-merge + 清 status 标签 | PR 评审 PASS 后 |
