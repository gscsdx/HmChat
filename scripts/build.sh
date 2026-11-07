#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

mode="${1:-debug}"
[[ "$mode" == debug || "$mode" == release ]] || fail '用法：./scripts/build.sh [debug|release]'
[[ $# -le 1 ]] || fail '用法：./scripts/build.sh [debug|release]'
require_tool "$NODE_HOME/bin/node"
require_tool "$JAVA_HOME/bin/java"
require_tool "$HVIGOR_BIN"
cd "$HARLGRAM_ROOT"
repair_cache_layout
"$HARLGRAM_ROOT/scripts/configure-telegram.sh" "$mode"
mkdir -p .hvigor
lock_dir="$HARLGRAM_ROOT/.hvigor/harlgram-build.lock"
mkdir "$lock_dir" 2>/dev/null || fail '另一个 build.sh 正在运行；若此前进程异常退出，请先核实没有构建进程，再移除 .hvigor/harlgram-build.lock。'
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
"$HVIGOR_BIN" --mode module -p product=default -p module=entry@default -p "buildMode=$mode" assembleHap --no-daemon
printf '\n产物目录：%s/entry/build/default/outputs/default\n' "$HARLGRAM_ROOT"
if [[ -n "${HARLGRAM_CACHE_HOME:-}" ]]; then
  printf '缓存根实路径：%s/build/default/outputs/default\n' "$HARLGRAM_CACHE_HOME"
fi
