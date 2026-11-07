#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/env.sh"

[[ $# -le 1 ]] || fail '用法：./scripts/screenshot.sh [output.png]'
output="${1:-$HARLGRAM_ROOT/artifacts/screenshots/$(date +%Y%m%d-%H%M%S).png}"
[[ "$output" == *.png ]] || fail '截图文件须使用 .png 扩展名。'
select_device
mkdir -p "$(dirname "$output")"
remote="/data/local/tmp/harlgram-screenshot-$$.png"
staging="$(mktemp -d "${TMPDIR:-/tmp}/harlgram-screenshot.XXXXXX")"
trap 'hdc_device shell rm -f "$remote" >/dev/null 2>&1 || true; rm -f "$staging/capture.png"; rmdir "$staging"' EXIT
result="$(hdc_device shell snapshot_display -t png -f "$remote" 2>&1)" || { printf '%s\n' "$result"; exit 1; }
printf '%s\n' "$result"
[[ "$result" == *'success: snapshot'* ]] || fail '设备未报告截图成功。'
if [[ "${HARLGRAM_HDC_TRANSFER:-file}" == shell ]]; then
  python3 - "$HDC_BIN" "$HDC_TARGET" "$remote" "$staging/capture.png" <<'PY'
import base64, pathlib, subprocess, sys
try:
    hdc, target, remote, output = sys.argv[1:]
    result = subprocess.run([hdc, '-t', target, 'shell', 'base64', remote], capture_output=True, check=True, timeout=30)
    data = base64.b64decode(result.stdout)
    if not data.startswith(b'\x89PNG\r\n\x1a\n') or len(data) > 64 * 1024 * 1024:
        raise ValueError('invalid screenshot')
    pathlib.Path(output).write_bytes(data)
except (ValueError, OSError, subprocess.SubprocessError):
    sys.exit('截图传输未通过校验，原始响应未输出。')
PY
else
  hdc_device file recv "$remote" "$staging/capture.png"
fi
[[ -s "$staging/capture.png" ]] || fail '未收到截图文件。'
mv "$staging/capture.png" "$output"
printf '截图：%s\n' "$output"
