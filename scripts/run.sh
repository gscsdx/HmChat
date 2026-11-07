#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

[[ $# -eq 0 ]] || fail '用法：./scripts/run.sh（可用 HDC_TARGET 指定设备）'
select_device
result="$(hdc_device shell aa start -a "$HARLGRAM_ABILITY" -b "$HARLGRAM_BUNDLE" 2>&1)" || { printf '%s\n' "$result"; exit 1; }
printf '%s\n' "$result"
[[ "$result" == *'successfully'* ]] || fail '设备未报告启动成功；请先安装应用并检查包名。'
