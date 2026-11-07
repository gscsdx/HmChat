#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_tool "$EMULATOR_BIN"

case "${1:-list}" in
  list)
    [[ $# -le 1 ]] || fail '用法：./scripts/emulator.sh list'
    exec "$EMULATOR_BIN" -list -details
    ;;
  start)
    [[ $# -eq 2 && -n "$2" ]] || fail '用法：./scripts/emulator.sh start "已有模拟器名称"'
    exec "$EMULATOR_BIN" -start "$2"
    ;;
  *) fail '用法：./scripts/emulator.sh list | start "已有模拟器名称"' ;;
esac
