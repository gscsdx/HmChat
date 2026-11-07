#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
export HARLGRAM_ROOT
"$NODE_HOME/bin/node" "$HARLGRAM_ROOT/scripts/configure-telegram.mjs" "${1:-debug}"
