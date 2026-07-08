---
description: "接 GitHub issue / 修 bug / 小功能 / 脚本文档微调的完整工作流（含本项目配置）"
---

# Issue 驱动工作流 — 完整生命周期 + 项目配置

> 本文件是 `methol-issue-driven-dev` skill 的项目配置单源。改动需配合
> [`.github/labels.json`](../../../.github/labels.json) 与 [`scripts/issues/`](../../../scripts/issues/) 一起更新。

## 0. 适用范围

- **适用**：人工测试反馈的 bug、单个小功能点、脚本 / 文档微调
- **不适用**：跨模块架构级、需要 spec / ADR 支撑的大粒度任务 → 走 `AGENTS.md` 工作流主回路（research → spec/ADR → plan → 实施）

## 1. 设计原则

- **AI 主导、人只做决策**：人负责创建 issue、异步查看结果与产物；代码、测试、commit、push 由 AI 出。
- **决策点交给另一个 AI 角色**：plan 评审与 ship 评审都请评审者把关，AI 自己判定是否需要人工介入，**默认不阻塞**。
- **分支隔离**：每个 issue 一条 `issue/<num>-<slug>` 分支，合入时 squash-merge 回 `main`，保留单条可回滚的 commit。
- **PR 是 ship 通道**：issue 驱动流程一律走 PR（让评审 review 有承载），即使项目其他任务直推 main。
- **人异步介入**：AI 打 `status:needs-human` 表示需要决策；人看到再处理，不让 AI 空等。

## 2. 生命周期

```
人创建 issue
   │  (template 自动打 type:* + status:triaged)
   ▼
AI 分诊 ─── 纠正 type / 补 scope:* / 补 priority:*
   │
   ▼
scripts/issues/kickoff.sh <num>
   │  从 main 切分支 issue/<num>-<slug>
   │  搭建 docs/artifacts/issues/<num>/ 骨架（diagnosis / plan-review / verification）
   │  标签 → status:in-progress
   ▼
AI 填 diagnosis.md（含 §5 守护线自检）
   │  标签 → status:plan-review
   ▼
AI 调评审者做 plan 评审 → plan-review.md
   │  VERDICT=PASS         → 标签回 status:in-progress，进入实施
   │  VERDICT=NEEDS_HUMAN  → 标签 status:needs-human，异步等人
   ▼
AI 实施 + 本地验证（验证矩阵见 .agent/rules/build-test.md）
   │
   ▼
scripts/issues/ship.sh <num>
   │  push 分支 + 开 PR（Closes #<num>）
   │  标签 → status:ship-review
   ▼
AI 调评审者做 ship 评审 → PR review comment
   │  VERDICT=PASS         → scripts/issues/merge.sh <num>
   │  VERDICT=NEEDS_HUMAN  → 标签 status:needs-human，异步等人
   ▼
merge.sh：等 CI 绿 → squash-merge --delete-branch → 写 done.json + handoff.md → push
   │  标签 → status:done（issue 由 "Closes #<num>" 自动关闭）
   ▼
（结束）
```

## 3. 标签体系

- **type**（issue 生命周期内固定，由 template 打）：`type:bug` / `type:feat` / `type:chore` / `type:docs`
- **priority**（AI 分诊时打）：`priority:p0` / `priority:p1` / `priority:p2`
- **scope**（AI 分诊时打）：本仓库是单个 macOS app，业务代码改动默认不打 scope；只在涉及构建 / 工具链时打 `scope:infra`（覆盖 CI / `scripts/` / `Makefile` / `macos/scripts/` 构建链路 / 治理文档工具链）
- **status**（随阶段迁移）：
  - `status:triaged` — template 初始状态，AI 分诊中
  - `status:plan-review` — 诊断已出，评审者审中
  - `status:in-progress` — 实施中
  - `status:ship-review` — PR 已开，评审者审 PR diff 中
  - `status:needs-human` — **阻塞信号**，AI 判定需要人介入
  - `status:blocked` — 外部依赖阻塞（环境 / 前置 issue）
  - `status:done` — 已合并

单源在 `.github/labels.json`，同步用 `scripts/issues/sync-labels.sh`（仅第一次 / 标签变更时跑）。

## 4. 评审者

- `reviewer`: `subagent` —— 用 Task 起评审 agent，prompt 见 skill `references/review-prompts.md`
- 与 [`tooling.md`](../tooling.md) fallback 一致：codex 可用时可临时改 `codex`（`codex:rescue` skill）

## 5. 守护线 checklist（plan 阶段自检；任一触发 → `status:needs-human`）

- [ ] 不触碰凭证 / 密钥链路：OAuth token 刷新、`credentials.json` 格式、Sparkle 私钥、`SU_FEED_URL` 注入逻辑（hard gate，见 `AGENTS.md`）
- [ ] 不引入新第三方依赖、不改 `LICENSE`、不改变开源 / 收费定位
- [ ] 不修改 `docs/adr/` 下已 `accepted` 的 ADR、不修改 `AGENTS.md` 或母法 spec（issue / 用户明确要求除外）
- [ ] 不在 `UsageService` 之外重复 fetch / auth / 轮询逻辑（架构红线，见 [`swift.md`](../swift.md)）
- [ ] 不手改 `Info.plist` 里的版本号（由 `APP_VERSION` / git tag 在 build 时注入）
- [ ] 单 issue 影响面不跨"app 代码 / 发版链路 / 治理文档"三大块，且改动文件数大致 ≤ 5

**ship 阶段**（任一触发 → NEEDS_HUMAN）：

- CI 红且 AI 判断不在能力边界内（语义歧义、需人定夺的取舍）
- 评审者 ship 评审列出高风险项（数据丢失 / 审计断裂 / 鉴权降级）
- diff 触碰 §6 敏感写入链路

## 6. 受保护文件与敏感写入链路

**受保护文件（改了就 `status:needs-human`）**：

- `docs/adr/*`、`AGENTS.md`、`docs/superpowers/specs/2026-05-11-docs-governance.md`
- `.github/workflows/release.yml`、`macos/Package.swift` 的依赖 pin
- `macos/scripts/verify-release.sh` 的 invariant 检查

**敏感写入链路（ship 阶段 diff 碰到就 `status:needs-human`）**：

- OAuth / token 刷新链路：`Providers/Claude/UsageService.swift`、`Models/StoredCredentials.swift`
- Sparkle 更新链路：`App/AppUpdater.swift`、`appcast.xml` 生成、release workflow
- codesign / `build.sh` 的 framework 嵌入步骤

## 7. Commit / PR 规范

- 分支：`issue/<num>-<slug>`，slug 取 issue title 去 `[bug]/[feat]/[chore]/[docs]` 前缀、小写、连字符化、<=40 字符（`kickoff.sh` 自动生成）
- commit message：`<type>(issue-#<num>): <summary>`，例：`fix(issue-#42): masking layout NPE on empty code`
- PR 标题：`<type>: <issue title>`（`ship.sh` 从 issue title 自动转换，保持与 commit 一致）
- PR body：`Closes #<num>` + 诊断 / 评审 / 验证 / checklist（模板 `.github/pull_request_template.md`，`ship.sh` 自动填）
- 合入：`gh pr merge --squash --delete-branch`（`merge.sh` 做），避免遗留 noisy commit
- PR 必须等绿：`build`（`.github/workflows/build.yml`）；`merge.sh` 用 `gh pr checks --watch` 等所有 check 绿

## 8. 脚本速查

| 脚本 | 作用 | 何时跑 |
|------|------|--------|
| `scripts/issues/sync-labels.sh` | 从 `.github/labels.json` 同步仓库标签 | 第一次 / 标签变更 |
| `scripts/issues/kickoff.sh <n>` | 建分支 + 搭 artifacts 骨架 + 切 status:in-progress | 分诊后开工 |
| `scripts/issues/ship.sh <n>` | push + 开 PR + 切 status:ship-review | 实施 + 本地验证通过后 |
| `scripts/issues/merge.sh <n>` | 等 CI + squash-merge + 写 done.json/handoff.md + 切 status:done | ship 评审 PASS 后 |

## 9. 产物结构

`docs/artifacts/issues/<num>/`（本仓库把 skill 默认的 `artifacts/issues/<num>/` 挪到 `docs/` 下，
`scripts/issues/{kickoff,ship,merge}.sh` 已同步该路径；若日后从 skill 重新同步脚本，记得保留这个 override）：

- `diagnosis.md` — 复现 / 根因 / 修复方案 / 影响范围 / 守护线自检 / 是否需人介入
- `plan-review.md` — 评审者对方案的评审结论 + 关键反馈 + 应对
- `verification.md` — 验证命令 / 结果 / 截图 / 本地验证清单
- `done.json` — 机器可读完成记录（`merge.sh` 自动写）
- `handoff.md` — 人读交接（`merge.sh` 自动写）

`done.json` 最小 schema：

```json
{
  "issue": 42,
  "pr": 57,
  "merge_commit": "<short-sha>",
  "completed_at": "YYYY-MM-DD",
  "status": "passed",
  "artifacts": ["docs/artifacts/issues/42/diagnosis.md", "docs/artifacts/issues/42/plan-review.md", "docs/artifacts/issues/42/verification.md", "docs/artifacts/issues/42/handoff.md"]
}
```

`status` 取值：`passed` / `blocked` / `partial`。不记录工时 / 耗时，`completed_at` 只到日期。

## 10. 首次启用

```bash
scripts/issues/sync-labels.sh        # 只第一次 / 标签变更时
scripts/issues/kickoff.sh 42         # AI 填 diagnosis、调评审者、实施、本地验证
scripts/issues/ship.sh 42            # AI 调评审者 review PR、等 CI
scripts/issues/merge.sh 42
```
