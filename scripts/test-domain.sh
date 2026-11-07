#!/usr/bin/env bash
# Transpile the platform-independent TypeScript, then test behavior with Node's built-in runner.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
require_tool "$NODE_HOME/bin/node"
HARLGRAM_TYPESCRIPT="${HARLGRAM_TYPESCRIPT:-$DEVECO_HOME/tools/ohpm/node_modules/typescript/lib/typescript.js}"
if [[ ! -f "$HARLGRAM_TYPESCRIPT" ]]; then
  HARLGRAM_TYPESCRIPT="$DEVECO_HOME/tools/hvigor/node_modules/typescript/lib/typescript.js"
fi
[[ -f "$HARLGRAM_TYPESCRIPT" ]] || fail '找不到 DevEco TypeScript 编译器，请设置 HARLGRAM_TYPESCRIPT。'
export HARLGRAM_ROOT HARLGRAM_TYPESCRIPT
"$NODE_HOME/bin/node" "$HARLGRAM_ROOT/tests/transpile.mjs"
"$NODE_HOME/bin/node" --test "$HARLGRAM_ROOT/tests/"*.test.mjs "$HARLGRAM_ROOT/tests/clash/"*.test.mjs
