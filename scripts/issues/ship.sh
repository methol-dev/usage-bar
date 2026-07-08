#!/usr/bin/env bash
# 推送当前 issue 分支并开 PR。
#
# 用法: scripts/issues/ship.sh <issue-number> [pr-body-file]
#   pr-body-file:AI 事先写好的 PR body(含诊断摘要 + 验证记录);
#                不传则用最小骨架,AI 需事后 gh pr edit 补全。
# 前置:
#   - 当前在 issue/<num>-<slug> 分支
#   - 本地验证通过(.agent/rules/build-test.md 验证矩阵)
set -euo pipefail

ISSUE_NUM="${1:-}"
BODY_FILE="${2:-}"
[[ -z "$ISSUE_NUM" ]] && { echo "用法: $0 <issue-number> [pr-body-file]" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

command -v gh >/dev/null || { echo "未找到 gh" >&2; exit 2; }

DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ ! "$BRANCH" =~ ^issue/${ISSUE_NUM}- ]]; then
  echo "当前分支 $BRANCH 与 issue #$ISSUE_NUM 不匹配" >&2
  exit 2
fi

ISSUE_TITLE="$(gh issue view "$ISSUE_NUM" --json title -q .title)"

PR_TITLE="$(printf '%s' "$ISSUE_TITLE" \
  | sed -E 's/^\[bug\][[:space:]]*/fix: /I; s/^\[feat\][[:space:]]*/feat: /I; s/^\[chore\][[:space:]]*/chore: /I; s/^\[docs\][[:space:]]*/docs: /I')"

git push -u origin "$BRANCH"

TMP_BODY=""
if [[ -z "$BODY_FILE" ]]; then
  TMP_BODY="$(mktemp)"
  trap 'rm -f "$TMP_BODY"' EXIT
  cat > "$TMP_BODY" <<EOF
Closes #${ISSUE_NUM}

## 修改摘要
(AI 补全:做了什么 + 为什么)

## 验证
(AI 补全:验证命令与结果,按 .agent/rules/build-test.md 矩阵)
EOF
  BODY_FILE="$TMP_BODY"
elif ! grep -q "Closes #${ISSUE_NUM}" "$BODY_FILE"; then
  echo "警告: PR body 未包含 'Closes #${ISSUE_NUM}',issue 不会自动关闭" >&2
fi

PR_URL="$(gh pr create \
  --base "$DEFAULT_BRANCH" \
  --head "$BRANCH" \
  --title "$PR_TITLE" \
  --body-file "$BODY_FILE")"

echo "[ship] PR: $PR_URL"
echo "[ship] 下一步:AI 调评审 subagent 审 PR diff(结果贴 PR review comment)"
echo "[ship]   PASS → scripts/issues/merge.sh $ISSUE_NUM;NEEDS_HUMAN → 打 status:needs-human 停"
