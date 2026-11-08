#!/usr/bin/env bash
# Source from the other scripts; all paths remain quoted for installations with spaces.
set -euo pipefail

HARLGRAM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 缓存根：Windows 上默认放在工程外，避免 .local、artifacts、构建产物和依赖
# 在源码目录堆积；其他平台保持原路径，不改变已在 macOS 验证的流程。
# 工程内同名入口由 scripts/cache-layout.ps1 建立目录联接到该位置。
if [[ -z "${HARLGRAM_CACHE_HOME:-}" ]]; then
  case "$(uname -s 2>/dev/null || printf '%s' unknown)" in
    MINGW*|MSYS*|CYGWIN*) HARLGRAM_CACHE_HOME="F:/HmChat-cache" ;;
  esac
fi
export HARLGRAM_CACHE_HOME
# 用户级 hvigor 缓存只在显式设置缓存根时改道，且只影响本仓库脚本；
# 不写入系统环境变量，也不影响其他鸿蒙工程。
if [[ -n "${HARLGRAM_CACHE_HOME:-}" && -z "${HVIGOR_USER_HOME:-}" ]]; then
  export HVIGOR_USER_HOME="$HARLGRAM_CACHE_HOME/user-home"
fi
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
if [[ -d "$DEVECO_HOME/Contents" ]]; then
  DEVECO_HOME="$DEVECO_HOME/Contents"
fi
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"
export NODE_HOME="${HARLGRAM_NODE_HOME:-$DEVECO_HOME/tools/node}"
export JAVA_HOME="${HARLGRAM_JAVA_HOME:-$DEVECO_HOME/jbr/Contents/Home}"
export PATH="$NODE_HOME/bin:$DEVECO_HOME/tools/ohpm/bin:$JAVA_HOME/bin:$PATH"
HVIGOR_BIN="${HVIGOR_BIN:-$DEVECO_HOME/tools/hvigor/bin/hvigorw}"
HDC_BIN="${HDC_BIN:-$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc}"
EMULATOR_BIN="${EMULATOR_BIN:-$DEVECO_HOME/tools/emulator/Emulator}"
HARLGRAM_BUNDLE="${HARLGRAM_BUNDLE:-com.hmchat.app}"
HARLGRAM_ABILITY="${HARLGRAM_ABILITY:-EntryAbility}"

fail() { printf '%s\n' "$*" >&2; exit 1; }
require_tool() { [[ -x "$1" ]] || fail "找不到可执行文件：$1；请设置 DEVECO_HOME 或对应工具路径。"; }

# 构建前修复工程内缓存目录联接；DevEco 的 clean 或重新安装依赖可能删除联接，
# 导致缓存重新写回工程内。非 Windows 或未设置缓存根时不做任何事。
repair_cache_layout() {
  [[ -n "${HARLGRAM_CACHE_HOME:-}" ]] || return 0
  case "$(uname -s 2>/dev/null || printf '%s' unknown)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 0 ;;
  esac
  command -v powershell.exe >/dev/null 2>&1 || fail '已设置缓存根，但找不到 powershell.exe，无法检查目录联接。'
  local project_root="$HARLGRAM_ROOT"
  local script_path="$HARLGRAM_ROOT/scripts/cache-layout.ps1"
  local cache_home="$HARLGRAM_CACHE_HOME"
  if command -v cygpath >/dev/null 2>&1; then
    project_root="$(cygpath -w "$HARLGRAM_ROOT")"
    script_path="$(cygpath -w "$script_path")"
    cache_home="$(cygpath -w "$cache_home")"
  fi
  powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File "$script_path" \
    -ProjectRoot "$project_root" -CacheHome "$cache_home" -Repair -Quiet >/dev/null \
    || fail '缓存目录重定向修复失败；请手动运行 scripts/cache-layout.ps1 查看原因。'
}

select_device() {
  require_tool "$HDC_BIN"
  local target listing
  local targets=()
  listing="$("$HDC_BIN" list targets)" || fail '无法读取设备列表。'
  while IFS= read -r target; do
    target="${target//$'\r'/}"
    [[ -z "$target" || "$target" == '[Empty]' ]] && continue
    targets+=("$target")
  done <<< "$listing"
  [[ ${#targets[@]} -gt 0 ]] || fail '没有可用设备；请启动已有模拟器或连接已开启调试的真机。'
  if [[ -n "${HDC_TARGET:-}" ]]; then
    for target in "${targets[@]}"; do
      [[ "$target" == "$HDC_TARGET" ]] && return 0
    done
    fail "HDC_TARGET 不在设备列表中：$HDC_TARGET"
  fi
  [[ ${#targets[@]} -eq 1 ]] || fail "检测到多个设备，请用 HDC_TARGET 指定目标：${targets[*]}"
  HDC_TARGET="${targets[0]}"
}

hdc_device() { "$HDC_BIN" -t "$HDC_TARGET" "$@"; }
