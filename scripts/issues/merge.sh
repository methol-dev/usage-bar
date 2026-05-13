#!/usr/bin/env bash
# 合并 issue PR 并收尾:
#   1. 等 PR checks 全绿
#   2. gh pr merge --squash --delete-branch
#   3. 切回默认分支,pull,删除本地分支
#   4. 写 docs/artifacts/issues/<num>/{done.json,handoff.md} 并再 push 一次
#   5. issue 标签切到 status:done
#
# 前置:ship 评审 VERDICT=PASS,无 status:needs-human
#
# 用法: scripts/issues/merge.sh <issue-number>
set -euo pipefail

ISSUE_NUM="${1:-}"
[[ -z "$ISSUE_NUM" ]] && { echo "用法: $0 <issue-number>" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

command -v gh >/dev/null || { echo "未找到 gh" >&2; exit 2; }
command -v jq >/dev/null || { echo "未找到 jq" >&2; exit 2; }

DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)"

PR_NUM="$(gh pr list --state open --json number,headRefName \
  | jq -r ".[] | select(.headRefName | startswith(\"issue/${ISSUE_NUM}-\")) | .number" \
  | head -1)"

[[ -z "$PR_NUM" ]] && { echo "找不到 issue #$ISSUE_NUM 对应的 open PR" >&2; exit 2; }

BRANCH="$(gh pr view "$PR_NUM" --json headRefName -q .headRefName)"

echo "[merge] PR #$PR_NUM on $BRANCH"
echo "[merge] 等 PR checks(--watch)"
gh pr checks "$PR_NUM" --watch --fail-fast

echo "[merge] squash-merge"
gh pr merge "$PR_NUM" --squash --delete-branch

git checkout "$DEFAULT_BRANCH"
git pull --ff-only
git branch -D "$BRANCH" 2>/dev/null || true

TODAY="$(date +%F)"
HEAD_SHA="$(git rev-parse --short HEAD)"
ART_DIR="docs/artifacts/issues/$ISSUE_NUM"
mkdir -p "$ART_DIR"

cat > "$ART_DIR/done.json" <<EOF
{
  "issue": $ISSUE_NUM,
  "pr": $PR_NUM,
  "merge_commit": "$HEAD_SHA",
  "completed_at": "$TODAY",
  "status": "passed",
  "artifacts": [
    "$ART_DIR/diagnosis.md",
    "$ART_DIR/plan-review.md",
    "$ART_DIR/verification.md",
    "$ART_DIR/handoff.md"
  ]
}
EOF

cat > "$ART_DIR/handoff.md" <<EOF
# Issue #$ISSUE_NUM 交接

- PR:#$PR_NUM(已合并)
- 合并 commit:\`$HEAD_SHA\`
- 完成日期:$TODAY

## 修复要点
见 [\`diagnosis.md\`](diagnosis.md)

## 评审结论
- Plan:[\`plan-review.md\`](plan-review.md)
- Ship:PR #$PR_NUM 的 review comment

## 验证
见 [\`verification.md\`](verification.md)

## 回滚
\`\`\`
git revert $HEAD_SHA
\`\`\`
EOF

git add "$ART_DIR"
git commit -m "chore(issue-#${ISSUE_NUM}): close-out artifacts"
git push

gh issue edit "$ISSUE_NUM" --remove-label "status:ship-review"  2>/dev/null || true
gh issue edit "$ISSUE_NUM" --remove-label "status:needs-human"  2>/dev/null || true
gh issue edit "$ISSUE_NUM" --add-label    "status:done"         2>/dev/null || true

echo "[merge] issue #$ISSUE_NUM 收尾完成"
