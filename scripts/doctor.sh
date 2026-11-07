#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

printf '工程：%s\nDevEco：%s\nSDK：%s\n' "$HARLGRAM_ROOT" "$DEVECO_HOME" "$DEVECO_SDK_HOME"
require_tool "$NODE_HOME/bin/node"
require_tool "$JAVA_HOME/bin/java"
require_tool "$HVIGOR_BIN"
require_tool "$HDC_BIN"
printf 'Node：'
"$NODE_HOME/bin/node" --version
"$JAVA_HOME/bin/java" -version 2>&1 | head -n 1
printf 'Hvigor：%s\nhdc：%s\n' "$HVIGOR_BIN" "$HDC_BIN"
[[ -d "$HARLGRAM_ROOT/oh_modules" ]] || fail '缺少依赖，请在项目根目录运行 ohpm install。'
printf '连接设备：\n'
"$HDC_BIN" list targets
printf '环境检查完成。签名有效性由 build.sh 的 SignHap 任务验证。\n'
