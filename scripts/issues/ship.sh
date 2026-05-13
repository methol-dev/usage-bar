#!/usr/bin/env bash
# 推送当前 issue 分支并开 PR,进入 ship 评审阶段。
#
# 用法: scripts/issues/ship.sh <issue-number>
# 前置:
#   - 当前在 issue/<num>-<slug> 分支
#   - docs/artifacts/issues/<num>/{diagnosis,plan-review,verification}.md 已填充
#   - 本地验证通过(按项目 CLAUDE.md 配置段的"本地验证命令")
set -euo pipefail

ISSUE_NUM="${1:-}"
[[ -z "$ISSUE_NUM" ]] && { echo "用法: $0 <issue-number>" >&2; exit 2; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

command -v gh >/dev/null || { echo "未找到 gh" >&2; exit 2; }

DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ ! "$BRANCH" =~ ^issue/${ISSUE_NUM}- ]]; then
  echo "当前分支 $BRANCH 与 issue #$ISSUE_NUM 不匹配" >&2
  exit 2
fi

ART_DIR="docs/artifacts/issues/$ISSUE_NUM"
for f in diagnosis.md plan-review.md verification.md; do
  [[ -f "$ART_DIR/$f" ]] || { echo "缺少 $ART_DIR/$f" >&2; exit 2; }
done

ISSUE_TITLE="$(gh issue view "$ISSUE_NUM" --json title -q .title)"

PR_TITLE="$(printf '%s' "$ISSUE_TITLE" \
  | sed -E 's/^\[bug\][[:space:]]*/fix: /I; s/^\[feat\][[:space:]]*/feat: /I; s/^\[chore\][[:space:]]*/chore: /I; s/^\[docs\][[:space:]]*/docs: /I')"

git push -u origin "$BRANCH"

PR_BODY_FILE="$(mktemp)"
trap 'rm -f "$PR_BODY_FILE"' EXIT

cat > "$PR_BODY_FILE" <<EOF
Closes #${ISSUE_NUM}

## 诊断 / 修复方案
见 \`docs/artifacts/issues/${ISSUE_NUM}/diagnosis.md\`

## 方案评审(Plan Review)
$(sed -n '/^## 评审结论/,/^## 关键反馈/p' "$ART_DIR/plan-review.md" | sed '1d;$d')

## 验证
$(cat "$ART_DIR/verification.md")

## Ship 评审
- 由 AI 调评审者(项目配置段 reviewer)对本 PR diff 评审,结果以 PR review comment 投放
- VERDICT=PASS 且未触发 status:needs-human → AI 直接 \`scripts/issues/merge.sh ${ISSUE_NUM}\`
- VERDICT=NEEDS_HUMAN → AI 打 status:needs-human 等人工,可继续处理其他 issue

## 自动化 checklist
- [ ] 本地验证记录已补齐
- [ ] CI 绿
- [ ] 相关 CLAUDE.md / 文档如需更新已同步
EOF

PR_URL="$(gh pr create \
  --base "$DEFAULT_BRANCH" \
  --head "$BRANCH" \
  --title "$PR_TITLE" \
  --body-file "$PR_BODY_FILE")"

gh issue edit "$ISSUE_NUM" --remove-label "status:in-progress"  2>/dev/null || true
gh issue edit "$ISSUE_NUM" --add-label    "status:ship-review"  2>/dev/null || true
gh pr edit    "$PR_URL"   --add-label    "status:ship-review"  2>/dev/null || true

echo "[ship] PR: $PR_URL"
echo "[ship] 下一步:AI 触发 ship 评审(贴在 PR review comment),通过后跑 scripts/issues/merge.sh $ISSUE_NUM"
