#!/usr/bin/env bash
# 启动一个 issue 的开发流程:
#   1. 从 main 切新分支 issue/<num>-<slug>
#   2. issue 标签打上 status:in-progress
#
# 诊断(根因 / 方案 / 需人介入自检)不落盘,由 AI 直接发成 issue comment。
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

TITLE="$(gh issue view "$ISSUE_NUM" --json title -q .title)"

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

gh issue edit "$ISSUE_NUM" --add-label "status:in-progress" 2>/dev/null || true

echo "[kickoff] 完成。下一步:"
echo "  1. AI 把诊断(根因 / 方案 / 需人介入自检)发成 issue comment"
echo "  2. 触发需人介入清单 → 打 status:needs-human 停;影响面大 → 先做一次 plan 评审"
echo "  3. 否则直接实施 + 本地验证,然后 scripts/issues/ship.sh $ISSUE_NUM <pr-body-file>"
