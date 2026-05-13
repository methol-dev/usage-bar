#!/usr/bin/env bash
# 启动一个 issue 的开发流程:
#   1. 从 main 切新分支 issue/<num>-<slug>
#   2. 搭建 docs/artifacts/issues/<num>/ 骨架文件(diagnosis / plan-review / verification)
#   3. 把 issue 标签切到 status:in-progress(清掉 status:triaged / status:plan-review)
#
# 用法: scripts/issues/kickoff.sh <issue-number>
# 前置:工作区干净,gh 已登录
set -euo pipefail

ISSUE_NUM="${1:-}"
[[ -z "$ISSUE_NUM" ]] && { echo "用法: $0 <issue-number>" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

command -v gh >/dev/null || { echo "未找到 gh" >&2; exit 2; }
command -v jq >/dev/null || { echo "未找到 jq" >&2; exit 2; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "工作区不干净,先处理" >&2
  git status --short >&2
  exit 2
fi

DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)"

INFO="$(gh issue view "$ISSUE_NUM" --json title,url,labels)"
TITLE="$(echo "$INFO" | jq -r .title)"
URL="$(echo "$INFO" | jq -r .url)"

SLUG="$(printf '%s' "$TITLE" \
  | sed -E 's/^\[(bug|feat|chore|docs)\][[:space:]]*//I' \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-40)"
[[ -z "$SLUG" ]] && SLUG="issue"

BRANCH="issue/${ISSUE_NUM}-${SLUG}"

echo "[kickoff] issue #$ISSUE_NUM"
echo "[kickoff] title : $TITLE"
echo "[kickoff] branch: $BRANCH (base: $DEFAULT_BRANCH)"

git checkout "$DEFAULT_BRANCH"
git pull --ff-only
git checkout -b "$BRANCH"

ART_DIR="docs/artifacts/issues/$ISSUE_NUM"
mkdir -p "$ART_DIR"

cat > "$ART_DIR/diagnosis.md" <<EOF
# Issue #$ISSUE_NUM 诊断

- 链接:$URL
- 标题:$TITLE

## 复现与定位
(由 AI 填写)

## 根因
(由 AI 填写)

## 修复方案
(由 AI 填写)

## 影响范围
- 修改文件:
- 风险点:
- 测试计划:

## 守护线自检
> 逐项对照项目 CLAUDE.md "Issue 驱动开发配置" 段的 "守护线 checklist"。任一项触发 → 是否需要人工介入填 YES。
- (照搬项目配置段的 checklist 并勾选)

## 是否需要人工介入
- 结论:YES / NO
- 理由:
EOF

cat > "$ART_DIR/plan-review.md" <<'EOF'
# AI 方案评审(Plan Review)

由评审者(项目 CLAUDE.md 配置段的 reviewer:subagent / codex / manual)对 diagnosis.md
的修复方案做评审,结果填入本文件。prompt 模板见 issue-driven-dev skill 的 references/review-prompts.md。

## 评审结论
- VERDICT: PASS / NEEDS_REVISION / NEEDS_HUMAN
- 评审者:
- 评审日期:

## 关键反馈
(粘贴评审回复要点)

## 应对
- 接受的反馈与对应修改:
- 拒绝的反馈与理由:

## 是否需要人工介入
- 结论(综合 diagnosis 自检与本次评审):YES / NO
- 若 YES,阻塞原因:
EOF

cat > "$ART_DIR/verification.md" <<'EOF'
# 验证记录

## 命令 / 步骤
- (照搬项目 CLAUDE.md 配置段 "本地验证命令" 里与本次改动相关的项)

## 结果 / 截图
-

## 本地验证清单
- 单测 / 集成测试:
- 构建:
- 接口契约(如适用):
- 手动回归(如适用):

## CI
- (PR 的 checks 状态由 ship/merge 阶段记录)
EOF

git add "$ART_DIR"
git commit -m "chore(issue-#${ISSUE_NUM}): kickoff scaffolding"

gh issue edit "$ISSUE_NUM" --remove-label "status:triaged"      2>/dev/null || true
gh issue edit "$ISSUE_NUM" --remove-label "status:plan-review"  2>/dev/null || true
gh issue edit "$ISSUE_NUM" --add-label    "status:in-progress"  2>/dev/null || true

echo "[kickoff] 完成。下一步:"
echo "  1. AI 填充 docs/artifacts/issues/$ISSUE_NUM/diagnosis.md(含守护线自检)"
echo "  2. AI 调评审者做 plan 评审,写入 plan-review.md,打 status:plan-review"
echo "  3. 评审 PASS 后继续实施;如 NEEDS_HUMAN 则打 status:needs-human 等人工"
