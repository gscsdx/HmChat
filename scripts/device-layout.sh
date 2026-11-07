#!/usr/bin/env bash
# Official command: https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-test/uitest-guidelines.md
# Raw accessibility trees can contain messages and credentials. Never echo them.
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [[ "${1:-}" == '--help' && $# -eq 1 ]]; then
  printf '%s\n' \
    '用法：HDC_TARGET=<用户指定真机> ./scripts/device-layout.sh' \
    '仅采集 HARLGRAM_BUNDLE 对应窗口；不会安装、启动应用或注入交互。' \
    '原始布局可能含私密内容，仅保存到被 Git 忽略的 artifacts/device-layout/。' \
    '终端只输出去敏结构摘要；layout.summary.json 不保留文本、描述、ID 或资源路径。'
  exit 0
fi
[[ $# -eq 0 ]] || fail '用法：HDC_TARGET=<用户指定真机> ./scripts/device-layout.sh'
[[ -n "${HDC_TARGET:-}" ]] || fail '必须显式设置 HDC_TARGET；本脚本不会自动选择设备。'
[[ "$HARLGRAM_BUNDLE" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$ ]] || fail '应用包名格式不正确。'
command -v python3 >/dev/null 2>&1 || fail '找不到 python3，无法安全生成布局摘要。'
command -v git >/dev/null 2>&1 || fail '找不到 Git，无法确认原始布局已被忽略。'
umask 077

base="$HARLGRAM_ROOT/artifacts/device-layout"
mkdir -p "$base"
base="$(cd "$base" && pwd -P)"
root="$(cd "$HARLGRAM_ROOT" && pwd -P)"
# 缓存根启用时，工程内 artifacts 是指向缓存根的目录联接，实路径会落在缓存根。
# 两种受信位置都接受，其他任何外部路径继续拒绝。
trusted_inside="$root/artifacts/device-layout"
if [[ -n "${HARLGRAM_CACHE_HOME:-}" ]]; then
  cache="$(cd "$HARLGRAM_CACHE_HOME" 2>/dev/null && pwd -P)" || fail "缓存根不可用：$HARLGRAM_CACHE_HOME"
  trusted_external="$cache/artifacts/device-layout"
  [[ "$base" == "$trusted_inside" || "$base" == "$trusted_external" ]] || fail "artifacts/device-layout 只能位于工程内或缓存根内：$trusted_external"
else
  [[ "$base" == "$trusted_inside" ]] || fail 'artifacts/device-layout 不得通过符号链接指向工程外部。'
fi
git -C "$HARLGRAM_ROOT" check-ignore -q -- artifacts/device-layout/layout.raw.json || fail 'artifacts/device-layout 尚未被 Git 忽略，已停止采集。'
capture="$(mktemp -d "$base/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
remote="/data/local/tmp/harlgram-layout-$(basename "$capture").json"
remote_created=false
cleanup() {
  if [[ "$remote_created" == true ]]; then
    hdc_device shell rm -f "$remote" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Both command output and file contents stay private, including when hdc exits nonzero.
if ! (select_device) >"$capture/device.log" 2>&1; then
  fail '指定设备不可用；请检查 HDC_TARGET 和真机连接。设备诊断仅保存在 artifacts/device-layout/。'
fi
remote_created=true
if ! hdc_device shell uitest dumpLayout -b "$HARLGRAM_BUNDLE" -p "$remote" >"$capture/dump.log" 2>&1; then
  fail '设备布局采集失败；原始诊断仅保存在 artifacts/device-layout/。'
fi
if [[ "${HARLGRAM_HDC_TRANSFER:-file}" == shell ]]; then
  if ! hdc_device shell cat "$remote" >"$capture/layout.raw.json" 2>"$capture/transfer.log"; then
    fail '布局文件接收失败；原始诊断仅保存在 artifacts/device-layout/。'
  fi
else
  if ! hdc_device file recv "$remote" "$capture/layout.raw.json" >"$capture/transfer.log" 2>&1; then
    fail '布局文件接收失败；原始诊断仅保存在 artifacts/device-layout/。'
  fi
fi
[[ -s "$capture/layout.raw.json" ]] || fail '未收到有效布局文件；请将目标应用保持在前台。'

python3 - "$capture/layout.raw.json" "$capture/layout.summary.json" <<'PY'
import collections
import json
import math
import pathlib
import re
import sys

source, target = map(pathlib.Path, sys.argv[1:])
# A type is accepted only from this constant allowlist. Custom/dynamic names become Other.
known_types = set('''AbilityComponent AlphabetIndexer Badge Blank Button Calendar CalendarPicker
Canvas Checkbox CheckboxGroup Circle Column ColumnSplit Common ContentSlot Counter DataPanel
DatePicker Divider EffectComponent Ellipse EmbeddedComponent Flex FlowItem FolderStack FormComponent
Gauge Grid GridCol GridContainer GridItem GridRow Hyperlink Image ImageAnimator ImageSpan LazyForEach
Line List ListItem ListItemGroup LoadingProgress Marquee Menu MenuItem MenuItemGroup NavDestination
Navigation Navigator NodeContainer Panel Path PatternLock PluginComponent Polygon Polyline Progress
QRCode Radio Rating Rect Refresh RelativeContainer RichEditor RichText Root Row RowSplit Scroll
ScrollBar Search Section Select Shape SideBarContainer Slider Span Stack Stepper StepperItem Swiper
SymbolGlyph SymbolSpan TabBar TabContent Tabs Text TextArea TextClock TextInput TextPicker TextTimer
TimePicker Toggle UIExtensionComponent Video WaterFlow Web XComponent Window'''.split())
boolean_keys = ('visible', 'enabled', 'clickable', 'longClickable', 'scrollable', 'selected',
                'checked', 'checkable', 'focused', 'focusable')
number = r'-?\d+(?:\.\d+)?'
text_bounds = re.compile(r'^\[\s*(' + number + r')\s*,\s*(' + number +
                         r')\s*\]\s*\[\s*(' + number + r')\s*,\s*(' + number + r')\s*\]$')

def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and abs(value) <= 1000000

def bounds(value):
    values = None
    if isinstance(value, str):
        match = text_bounds.fullmatch(value.strip())
        if match:
            values = [float(item) for item in match.groups()]
    elif isinstance(value, dict):
        values = [value.get(name) for name in ('left', 'top', 'right', 'bottom')]
    elif isinstance(value, list) and len(value) == 4:
        values = value
    if values is not None and all(finite(item) for item in values):
        return values
    return None

try:
    if source.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('oversize')
    tree = json.loads(source.read_text(encoding='utf-8'))
    if not isinstance(tree, (dict, list)):
        raise ValueError('invalid root')
    roots = tree if isinstance(tree, list) else [tree]
    stack = [(item, None, 0) for item in reversed(roots)]
    nodes = []
    counts = collections.Counter()
    while stack:
        item, parent, depth = stack.pop()
        if not isinstance(item, dict) or depth > 256 or len(nodes) >= 100000:
            raise ValueError('invalid node')
        attrs = item.get('attributes', item)
        if not isinstance(attrs, dict):
            raise ValueError('invalid attributes')
        children = item.get('children', [])
        if not isinstance(children, list):
            raise ValueError('invalid children')
        kind = attrs.get('type')
        kind = kind if isinstance(kind, str) and kind in known_types else 'Other'
        index = len(nodes)
        node = {'index': index, 'parent': parent, 'depth': depth, 'type': kind, 'children': len(children)}
        rectangle = bounds(attrs.get('bounds'))
        if rectangle is not None:
            node['bounds'] = rectangle
        for key in boolean_keys:
            value = attrs.get(key)
            if isinstance(value, bool):
                node[key] = value
            elif value == 'true' or value == 'false':
                node[key] = value == 'true'
        nodes.append(node)
        counts[kind] += 1
        stack.extend((child, index, depth + 1) for child in reversed(children))
    if not nodes or all(node['type'] == 'Other' for node in nodes):
        raise ValueError('unrecognized layout')
    # Summary geometry is the dump's coordinate system; it is not claimed to be window vp.
    stats = {'nodes': len(nodes), 'maxDepth': max(node['depth'] for node in nodes),
             'types': dict(sorted(counts.items())),
             'rootBounds': [node['bounds'] for node in nodes if node['parent'] is None and 'bounds' in node]}
    target.write_text(json.dumps({'schemaVersion': 1, 'coordinateUnit': 'dump-native',
                                 'summary': stats, 'nodes': nodes}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('布局去敏结构摘要：' + json.dumps(stats, ensure_ascii=False, separators=(',', ':')))
except (OSError, ValueError, TypeError, RecursionError, OverflowError):
    # Decoder/IO exception text can contain raw content or user-controlled paths.
    print('无法解析布局或布局结构不受支持；未输出原始内容。', file=sys.stderr)
    sys.exit(1)
PY
printf '去敏结构文件：%s/layout.summary.json\n' "$capture"
printf '原始布局与诊断保存在同一被 Git 忽略的目录，请勿公开。\n'
