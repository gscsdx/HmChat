#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

[[ $# -le 1 ]] || fail '用法：./scripts/install.sh [signed.hap]'
hap="${1:-$HARLGRAM_ROOT/entry/build/default/outputs/default/entry-default-signed.hap}"
[[ -f "$hap" ]] || fail "未找到 HAP：$hap；先运行 ./scripts/build.sh。"
select_device
printf '安装到 %s\n' "$HDC_TARGET"
if [[ "${HARLGRAM_HDC_TRANSFER:-file}" == shell ]]; then
  exec python3 "$HARLGRAM_ROOT/scripts/install-via-shell.py" "$HDC_BIN" "$HDC_TARGET" "$hap"
fi
result="$(hdc_device install -r "$hap" 2>&1)" || { printf '%s\n' "$result"; exit 1; }
printf '%s\n' "$result"
[[ "$result" == *'successfully'* ]] || fail 'hdc 未报告安装成功，请检查设备 API 版本、签名和安装输出。'
