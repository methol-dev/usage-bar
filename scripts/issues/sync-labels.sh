#!/usr/bin/env bash
# 把 .github/labels.json 同步到当前仓库的 GitHub Labels。
# 幂等:已存在的 label 会被更新颜色 / 描述,不会删除仓库里其他已有 label。
#
# 用法: scripts/issues/sync-labels.sh
# 依赖: gh(已登录)、jq
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABELS_FILE="$ROOT_DIR/.github/labels.json"

command -v gh >/dev/null || { echo "未找到 gh" >&2; exit 2; }
command -v jq >/dev/null || { echo "未找到 jq" >&2; exit 2; }
[[ -f "$LABELS_FILE" ]] || { echo "找不到 $LABELS_FILE" >&2; exit 2; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "[sync-labels] target: $REPO"

# 不加 || true:列表拉取失败必须 fail fast，否则会对已有 label 全量 create 然后中途报错
EXISTING="$(gh label list -R "$REPO" --limit 200 --json name -q '.[].name')"

jq -c '.[]' "$LABELS_FILE" | while read -r row; do
  name="$(echo "$row" | jq -r .name)"
  color="$(echo "$row" | jq -r .color)"
  desc="$(echo "$row" | jq -r .description)"
  if printf '%s\n' "$EXISTING" | grep -qxF "$name"; then
    gh label edit "$name" -R "$REPO" --color "$color" --description "$desc" >/dev/null
    echo "  ~ $name"
  else
    gh label create "$name" -R "$REPO" --color "$color" --description "$desc" >/dev/null
    echo "  + $name"
  fi
done

echo "[sync-labels] done"
