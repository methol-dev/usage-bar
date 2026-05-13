# Issue 驱动工作流 — 完整生命周期

> 适用:人工测试反馈的 bug、单个小功能点、文档 / 脚本微调。
> 不适用:跨模块架构级、需要 spec / ADR 支撑的大粒度任务——走项目自己的任务卡 / plan 流程。

## 1. 设计原则

- **AI 主导、人只做决策**:人负责创建 issue、异步查看结果与产物;代码、测试、commit、push 由 AI 出。
- **决策点交给另一个 AI 角色**:plan 评审与 ship 评审都请评审者(默认 Task subagent;项目 CLAUDE.md 配置段可改 `codex` / `manual`)把关,AI 自己判定是否需要人工介入,**默认不阻塞**。
- **分支隔离**:每个 issue 一条 `issue/<num>-<slug>` 分支,合入时 squash-merge 回 `main`,保留单条可回滚的 commit。
- **PR 是 ship 通道**:issue 驱动流程一律走 PR(让评审 review 有承载),即使项目其他任务直推 main。
- **人异步介入**:AI 打 `status:needs-human` 表示需要决策;人看到再处理,不让 AI 空等。

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
   │  搭建 docs/artifacts/issues/<num>/ 骨架(diagnosis / plan-review / verification)
   │  标签 → status:in-progress
   ▼
AI 填 diagnosis.md(含项目 CLAUDE.md 配置段里的守护线自检)
   │  标签 → status:plan-review
   ▼
AI 调评审者做 plan 评审 → plan-review.md
   │  VERDICT=PASS         → 标签回 status:in-progress,进入实施
   │  VERDICT=NEEDS_HUMAN  → 标签 status:needs-human,异步等人
   ▼
AI 实施 + 本地验证(项目 CLAUDE.md 配置段里列的验证命令:单测 / 构建 / 合同 / 手动回归)
   │
   ▼
scripts/issues/ship.sh <num>
   │  push 分支 + 开 PR(Closes #<num>)
   │  标签 → status:ship-review
   ▼
AI 调评审者做 ship 评审 → PR review comment
   │  VERDICT=PASS         → scripts/issues/merge.sh <num>
   │  VERDICT=NEEDS_HUMAN  → 标签 status:needs-human,异步等人
   ▼
merge.sh:等 CI 绿 → squash-merge --delete-branch → 写 done.json + handoff.md → push
   │  标签 → status:done(issue 由 "Closes #<num>" 自动关闭)
   ▼
(结束)
```

## 3. 标签体系

- **type**(issue 生命周期内固定,由 template 打):`type:bug` / `type:feat` / `type:chore` / `type:docs`
- **priority**(AI 分诊时打):`priority:p0` / `priority:p1` / `priority:p2`
- **scope**(AI 分诊时打,具体取值见项目 CLAUDE.md 配置段):`scope:<模块名>`,如 `scope:backend` / `scope:frontend` / `scope:infra`
- **status**(随阶段迁移):
  - `status:triaged` — template 初始状态,AI 分诊中
  - `status:plan-review` — 诊断已出,评审者审中
  - `status:in-progress` — 实施中
  - `status:ship-review` — PR 已开,评审者审 PR diff 中
  - `status:needs-human` — **阻塞信号**,AI 判定需要人介入
  - `status:blocked` — 外部依赖阻塞(环境 / 前置 issue)
  - `status:done` — 已合并

单源在 `.github/labels.json`,同步用 `scripts/issues/sync-labels.sh`(仅第一次 / 标签变更时跑)。

## 4. AI 判定"是否需要人工介入"的依据

**plan 阶段**(任一触发 → NEEDS_HUMAN):
- 触碰项目 CLAUDE.md 配置段里"守护线 checklist"的任一项
- 涉及修改受保护文件(配置段里列的:已发布 DB migration / spec / ADR / 根 CLAUDE.md / 生产部署文件等)
- 评审者给出 NEEDS_REVISION 两轮仍未收敛
- 预估影响面跨配置段约定的"单 issue 上限"(如跨 2 个以上子工程)

**ship 阶段**(任一触发 → NEEDS_HUMAN):
- CI 红且 AI 判断不在能力边界内(语义歧义、需人定夺的取舍)
- 评审者 ship 评审列出高风险项(数据丢失 / 审计断裂 / 鉴权降级)
- diff 触碰配置段里列的"敏感写入链路"
- 生产镜像版本 / digest 变更

不触发以上条件 → AI 直接推进,不阻塞人。

## 5. Commit / PR 规范

- 分支:`issue/<num>-<slug>`,slug 取 issue title 去 `[bug]/[feat]/[chore]/[docs]` 前缀、小写、连字符化、<=40 字符(`kickoff.sh` 自动生成)
- commit message:`<type>(issue-#<num>): <summary>`,例:`fix(issue-#42): masking layout NPE on empty code`
- PR 标题:`<type>: <issue title>`(`ship.sh` 从 issue title 自动转换,保持与 commit 一致)
- PR body:`Closes #<num>` + 诊断 / 评审 / 验证 / checklist(模板 `.github/pull_request_template.md`,`ship.sh` 自动填)
- 合入:`gh pr merge --squash --delete-branch`(`merge.sh` 做),避免遗留 noisy commit

## 6. 脚本速查

| 脚本 | 作用 | 何时跑 |
|------|------|--------|
| `scripts/issues/sync-labels.sh` | 从 `.github/labels.json` 同步仓库标签 | 第一次 / 标签变更 |
| `scripts/issues/kickoff.sh <n>` | 建分支 + 搭 artifacts 骨架 + 切 status:in-progress | 分诊后开工 |
| `scripts/issues/ship.sh <n>` | push + 开 PR + 切 status:ship-review | 实施 + 本地验证通过后 |
| `scripts/issues/merge.sh <n>` | 等 CI + squash-merge + 写 done.json/handoff.md + 切 status:done | ship 评审 PASS 后 |

## 7. 产物结构

`docs/artifacts/issues/<num>/`:
- `diagnosis.md` — 复现 / 根因 / 修复方案 / 影响范围 / 守护线自检 / 是否需人介入
- `plan-review.md` — 评审者对方案的评审结论 + 关键反馈 + 应对
- `verification.md` — 验证命令 / 结果 / 截图 / 本地验证清单
- `done.json` — 机器可读完成记录(`merge.sh` 自动写)
- `handoff.md` — 人读交接(`merge.sh` 自动写)

`done.json` 最小 schema:
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
`status` 取值:`passed` / `blocked` / `partial`(项目可在配置段里扩字段)。不记录工时 / 耗时,`completed_at` 只到日期。

## 8. 首次启用

```bash
scripts/issues/sync-labels.sh        # 只第一次 / 标签变更时
scripts/issues/kickoff.sh 42         # AI 填 diagnosis、调评审者、实施、本地验证
scripts/issues/ship.sh 42            # AI 调评审者 review PR、等 CI
scripts/issues/merge.sh 42
```
