#!/usr/bin/env bash
# 合并 issue PR 并收尾:
#   1. 等 PR checks 全绿
#   2. gh pr merge --squash --delete-branch
#   3. 切回默认分支,pull,删除本地分支
#   4. 清掉 issue 上的 status 标签(issue 由 PR body 的 "Closes #<num>" 自动关闭)
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

PR_NUM="$(gh pr list --state open --limit 200 --json number,headRefName \
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

gh issue edit "$ISSUE_NUM" --remove-label "status:in-progress" 2>/dev/null || true
gh issue edit "$ISSUE_NUM" --remove-label "status:needs-human" 2>/dev/null || true

echo "[merge] issue #$ISSUE_NUM 收尾完成(issue 由 Closes 自动关闭;记录都在 issue + PR 里)"
