#!/usr/bin/env bash
# 把 .github/labels.json 同步到当前仓库的 GitHub Labels。
# 幂等:已存在的 label 会被更新颜色 / 描述。
# --prune:额外删除 GitHub 上 type:/priority:/scope:/status: 命名空间内、
#         但已不在 labels.json 里的标签(其他标签一律不动)。
#
# 用法: scripts/issues/sync-labels.sh [--prune]
# 依赖: gh(已登录)、jq
set -euo pipefail

PRUNE=0
[[ "${1:-}" == "--prune" ]] && PRUNE=1

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

if [[ "$PRUNE" == "1" ]]; then
  WANTED="$(jq -r '.[].name' "$LABELS_FILE")"
  printf '%s\n' "$EXISTING" | grep -E '^(type|priority|scope|status):' | while read -r name; do
    if ! printf '%s\n' "$WANTED" | grep -qxF "$name"; then
      gh label delete "$name" -R "$REPO" --yes >/dev/null
      echo "  - $name"
    fi
  done
fi

echo "[sync-labels] done"
