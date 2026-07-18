#!/usr/bin/env bash
set -euo pipefail

# 把 extension/ 打成一个可分发的 zip（供用户 chrome://extensions → Load unpacked）。
# 仓库里没有私钥 —— manifest.json 只含公钥 `key`（固定扩展 id），打包无需任何 secret。
# 用法：scripts/package-extension.sh [输出路径]（默认 ./usage-bar-extension.zip）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXT_DIR="$ROOT_DIR/extension"
OUT="${1:-$ROOT_DIR/usage-bar-extension.zip}"

[[ -f "$EXT_DIR/manifest.json" ]] || { echo "Error: $EXT_DIR/manifest.json not found"; exit 1; }

# manifest 合法性兜底（release 前的最后一道；PR/push CI 已做过完整校验）。
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$EXT_DIR/manifest.json" \
        || { echo "Error: extension/manifest.json is not valid JSON"; exit 1; }
fi

mkdir -p "$(dirname "$OUT")"
# 归一化成绝对路径 —— 下面 zip 在 `cd "$EXT_DIR"` 子 shell 里跑,相对 $OUT 会被解析到
# extension/ 下而非调用者 CWD(两个调用点都传相对路径),故必须先转绝对。
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT"

# 归档 extension/ 内容到 zip 根 —— 解压后即是可 Load unpacked 的目录。排除 .DS_Store。
( cd "$EXT_DIR" && zip -r -X "$OUT" . -x '.DS_Store' '*/.DS_Store' >/dev/null )

echo "Wrote $OUT"
unzip -l "$OUT" | sed -n '1,20p' || true   # 仅诊断输出,unzip 缺失/失败不应让打包失败
