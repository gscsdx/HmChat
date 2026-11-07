#!/usr/bin/env bash
#
# S6-01：从固定提交的 FlClashX core 工作树重建 OHOS arm64 内核库 libclash_core.so。
#
# 边界：只做构建与取证。不修改 core 源码或 go.mod、不改签名、不安装到设备。
# 工具链：OHOS_GO 与 OHOS_NDK 必须由调用方显式提供；脚本不探测、不猜测本机路径。
#
# 必需环境变量：
#   OHOS_GO            OHOS Go 工具链的 go 可执行文件（需支持 GOOS=openharmony）
#   OHOS_NDK           OHOS NDK 的 native/ 目录（含 llvm/bin 与 sysroot）
# 可选环境变量：
#   CLASH_CORE_SRC     core 模块目录（默认 <repo>/source-refs/FlClashX/core）
#   OUT                .so 输出目录（默认 <repo>/entry/libs/arm64-v8a）
#   CLASH_CORE_VERSION 覆盖注入的 mihomo 版本（默认从 go.mod 提取）
#   GOPROXY            默认 https://goproxy.cn,direct
#   DRY_RUN=1          只校验环境并打印固定项，不执行构建
#
# 用法：
#   OHOS_GO=/opt/ohos-go/bin/go OHOS_NDK=/opt/ohos-sdk/native ./scripts/build-clash-core.sh
#   DRY_RUN=1 OHOS_GO=... OHOS_NDK=... ./scripts/build-clash-core.sh
#
# 退出码：0 成功；1 校验或构建失败；2 用法错误。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_SRC="${CLASH_CORE_SRC:-$ROOT/source-refs/FlClashX/core}"
OUT="${OUT:-$ROOT/entry/libs/arm64-v8a}"
EVIDENCE="$ROOT/artifacts/clash-evidence/core-build"
LIB_NAME="libclash_core.so"
# 基线版本（docs/integration/flclash-core-lib-baseline.md §6.6）；与 go.mod 不一致只告警，
# 便于上游版本升级时先观察行为再同步文档与本常量。
MIHOMO_BASELINE="v1.19.28"
TAGS="with_gvisor"
DRY_RUN="${DRY_RUN:-0}"

fail() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
用法：OHOS_GO=<ohos-go> OHOS_NDK=<ndk-native> [选项] bash scripts/build-clash-core.sh

必需环境变量：
  OHOS_GO            支持 GOOS=openharmony 的 Go 可执行文件（不自动探测）
  OHOS_NDK           OHOS SDK 的 native/ 目录（含 llvm/bin 与 sysroot）

可选环境变量：
  CLASH_CORE_SRC     core 模块目录（默认 source-refs/FlClashX/core）
  OUT                .so 输出目录（默认 entry/libs/arm64-v8a）
  CLASH_CORE_VERSION 覆盖从 go.mod 提取的 mihomo 版本
  GOPROXY            默认 https://goproxy.cn,direct
  DRY_RUN=1          只校验环境并打印固定项，不执行构建

选项：
  --dry-run, --check 同 DRY_RUN=1
  -h, --help         显示本帮助

退出码：0 成功；1 校验或构建失败；2 用法错误。
取证产物：artifacts/clash-evidence/core-build/{go-version-m.txt,sha256.txt,readelf.txt}
USAGE
}
rel() {
  case "$1" in
    "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

TMP_DIR=""
cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

for arg in "$@"; do
  case "$arg" in
    --dry-run|--check) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数：%s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 环境（显式传入）
: "${OHOS_GO:?未设置 OHOS_GO：请填入支持 GOOS=openharmony 的 Go 可执行文件路径}"
: "${OHOS_NDK:?未设置 OHOS_NDK：请填入 OHOS SDK 的 native/ 目录（含 llvm/bin 与 sysroot）}"
GO="$OHOS_GO"
[[ -x "$GO" ]] || fail "OHOS_GO 不可执行：$GO"
[[ -d "$OHOS_NDK" ]] || fail "OHOS_NDK 不是目录：$OHOS_NDK"

# ---------------------------------------------------------------- 源码工作树固定项
[[ -d "$CORE_SRC" ]] || fail "找不到 core 工作树：$(rel "$CORE_SRC")"
[[ -f "$CORE_SRC/go.mod" ]] || fail "core 工作树缺少 go.mod：$(rel "$CORE_SRC")"
[[ -f "$CORE_SRC/go.sum" ]] || fail "core 工作树缺少 go.sum：$(rel "$CORE_SRC")"

# OHOS 功能正确性依赖 sing-tun 的本地补丁与 replace，缺一即拒绝构建。
SING_TUN="$CORE_SRC/third_party/sing-tun"
[[ -d "$SING_TUN" ]] || fail "缺少 third_party/sing-tun，拒绝构建（OHOS TUN 补丁不在源码树内）"
for patch_file in debug_hilog.go debug_hilog_ohos.go debug_hilog_stub.go tun_linux.go tun_linux_gvisor.go; do
  [[ -f "$SING_TUN/$patch_file" ]] || fail "third_party/sing-tun 缺少 OHOS 补丁文件：$patch_file"
done
grep -Eq '^[[:space:]]*replace[[:space:]]+github\.com/metacubex/sing-tun[[:space:]]+=>[[:space:]]+\./third_party/sing-tun' \
  "$CORE_SRC/go.mod" \
  || fail 'go.mod 缺少 replace github.com/metacubex/sing-tun => ./third_party/sing-tun，拒绝构建'

# ---------------------------------------------------------------- mihomo 版本注入
# go.mod 里既有单行 require 也有 require 块，取模块路径后的字段即可覆盖两种写法。
GO_MOD_MIHOMO="$(awk '{
  for (i = 1; i < NF; i++) if ($i == "github.com/metacubex/mihomo") { print $(i + 1); exit }
}' "$CORE_SRC/go.mod")"
[[ "$GO_MOD_MIHOMO" =~ ^v[0-9] ]] || fail "无法从 go.mod 提取 mihomo 版本：'${GO_MOD_MIHOMO}'"
MIHOMO_VERSION="${CLASH_CORE_VERSION:-$GO_MOD_MIHOMO}"
[[ "$MIHOMO_VERSION" =~ ^[vV]?[0-9] ]] || fail "CLASH_CORE_VERSION 非法：$MIHOMO_VERSION"

# ---------------------------------------------------------------- 工具链与编译器
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # cgo 直接 exec clang.exe，不做 MSYS 路径转换：sysroot 必须是 Windows 绝对路径，
    # 否则 stdlib.h 等头文件解析失败；Go 也拒绝相对路径的 CC。
    OHOS_NDK_W="$(cygpath -w "$OHOS_NDK" 2>/dev/null || printf '%s' "$OHOS_NDK")"
    OHOS_NDK_W="${OHOS_NDK_W//\\//}"
    SYSROOT="$OHOS_NDK_W/sysroot"
    CLANG="$OHOS_NDK_W/llvm/bin/clang.exe"
    CLANG_FLAGS=(-target aarch64-linux-ohos --sysroot="$SYSROOT" -D__MUSL__)
    ;;
  *)
    SYSROOT="$OHOS_NDK/sysroot"
    CLANG="$OHOS_NDK/llvm/bin/aarch64-unknown-linux-ohos-clang"
    CLANG_FLAGS=(--sysroot="$SYSROOT")
    ;;
esac
[[ -d "$SYSROOT" ]] || fail "找不到 NDK sysroot：$SYSROOT"
[[ -x "$CLANG" ]] || fail "找不到 OHOS clang（需 OHOS_NDK 指向 native/ 目录）：$CLANG"

# GOTOOLCHAIN=local：go.mod 声明的 Go 版本不得触发下载原生工具链（会丢失 openharmony 目标）。
GO_REPORT="$("$GO" version 2>&1 | sed -n '1p')"
GO_ENV_VERSION="$("$GO" env GOVERSION 2>/dev/null || printf 'unknown')"
"$GO" tool dist list 2>/dev/null | grep -qx 'openharmony/arm64' \
  || fail "Go 工具链不包含 openharmony/arm64 目标：$GO"

find_llvm_tool() {
  local name="$1" candidate
  for candidate in "$OHOS_NDK/llvm/bin/$name" "$OHOS_NDK/llvm/bin/$name.exe"; do
    if [[ -x "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  command -v "$name" 2>/dev/null || return 1
}
READELF="$(find_llvm_tool llvm-readelf || true)"
NM="$(find_llvm_tool llvm-nm || true)"
SHA256_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then SHA256_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA256_TOOL="shasum"
fi
[[ -n "$SHA256_TOOL" ]] || fail '找不到 sha256sum 或 shasum，无法生成哈希证据'

# ---------------------------------------------------------------- 固定参数
# shellcheck disable=SC2054  # 逗号是 ldflags 内的字面量
LD_FLAGS="-s -w -X github.com/metacubex/mihomo/constant.Version=${MIHOMO_VERSION} -extldflags=-Wl,-soname,${LIB_NAME}"
GOPROXY_EFFECTIVE="${GOPROXY:-https://goproxy.cn,direct}"
CC_CMD="$(printf '%q ' "$CLANG" "${CLANG_FLAGS[@]}")"
TARGET_LIB="$OUT/$LIB_NAME"

printf '==> Harlgram clash core 构建（S6-01）\n'
printf '    core 源码     : %s\n' "$(rel "$CORE_SRC")"
printf '    mihomo        : %s（go.mod=%s，基线=%s）\n' "$MIHOMO_VERSION" "$GO_MOD_MIHOMO" "$MIHOMO_BASELINE"
printf '    Go 工具链     : %s（GOVERSION=%s）\n' "$GO_REPORT" "$GO_ENV_VERSION"
printf '    GOOS/GOARCH   : openharmony / arm64\n'
printf '    CGO_ENABLED   : 1\n'
printf '    buildmode     : c-shared\n'
printf '    tags          : %s\n' "$TAGS"
printf '    trimpath      : on（-trimpath）\n'
printf '    buildvcs      : off（-buildvcs=false）\n'
printf '    ldflags       : %s\n' "$LD_FLAGS"
printf '    GOPROXY       : %s\n' "$GOPROXY_EFFECTIVE"
printf '    CC            : %s\n' "$CC_CMD"
printf '    输出          : %s\n' "$(rel "$TARGET_LIB")"
printf '    取证目录      : %s\n' "$(rel "$EVIDENCE")"
if [[ "$MIHOMO_VERSION" != "$MIHOMO_BASELINE" ]]; then
  printf '    警告          : 版本与基线 %s 不一致；如属预期升级，请同步基线文档与本脚本常量。\n' "$MIHOMO_BASELINE"
fi
printf '\n'

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN=1：环境与固定项校验通过，未执行构建。\n'
  exit 0
fi

# ---------------------------------------------------------------- 构建（先落临时目录）
mkdir -p "$OUT" "$EVIDENCE"
TMP_DIR="$EVIDENCE/.tmp-$$"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
TMP_LIB="$TMP_DIR/$LIB_NAME"

printf '==> 开始构建（c-shared，仅超时由调用方控制）\n'
(
  cd "$CORE_SRC"
  env \
    GOROOT="$("$GO" env GOROOT)" \
    GOTOOLCHAIN=local \
    GOOS=openharmony \
    GOARCH=arm64 \
    CGO_ENABLED=1 \
    GOFLAGS= \
    CC="$CC_CMD" \
    GOPROXY="$GOPROXY_EFFECTIVE" \
    "$GO" build \
      -trimpath \
      -buildvcs=false \
      -tags "$TAGS" \
      -ldflags="$LD_FLAGS" \
      -buildmode=c-shared \
      -o "$TMP_LIB" \
      .
)

# 失败即非零退出；只有新产物通过校验才替换已有 .so，绝不把旧库当成功。
[[ -f "$TMP_LIB" ]] || fail "构建未产出 $LIB_NAME（go build 未报错但文件缺失）"
size="$(wc -c < "$TMP_LIB" | tr -d ' \n')"
[[ "$size" =~ ^[0-9]+$ ]] && (( size > 1048576 )) \
  || fail "产物大小异常（${size} bytes），拒绝安装"

SONAME=""
NEEDED=""
if [[ -n "$READELF" ]]; then
  SONAME="$("$READELF" -d "$TMP_LIB" | sed -n 's/.*(SONAME).*\[\([^]]*\)\].*/\1/p' | sed -n '1p')"
  [[ "$SONAME" == "$LIB_NAME" ]] || fail "SONAME 校验失败：期望 $LIB_NAME，实际 '${SONAME:-缺失}'"
  NEEDED="$("$READELF" -d "$TMP_LIB" | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' | paste -sd, - 2>/dev/null || true)"
else
  printf '    警告：未找到 llvm-readelf，跳过 SONAME/NEEDED 校验（建议设置 OHOS_NDK 指向完整 NDK）。\n' >&2
fi

# 通过校验后才落位，保证失败路径不会留下半成品或覆盖旧库。
mv -f "$TMP_LIB" "$TARGET_LIB"

# ---------------------------------------------------------------- 取证（不含绝对路径）
SHA256="$("$SHA256_TOOL" "$TARGET_LIB" | awk '{print $1}')"

{
  printf '%s  %s\n' "$SHA256" "$(rel "$TARGET_LIB")"
} > "$EVIDENCE/sha256.txt"

if ! { "$GO" version -m "$TARGET_LIB" > "$EVIDENCE/go-version-m.txt" 2>&1; }; then
  printf '    警告：go version -m 读取失败，详情见 %s\n' "$(rel "$EVIDENCE/go-version-m.txt")" >&2
fi
# 用 [U]sers 等价匹配 macOS 用户主目录前缀，避免公开树出现真实主目录字面量。
if grep -Eq '/[U]sers/|/home/|[A-Za-z]:[/\\]' "$EVIDENCE/go-version-m.txt" 2>/dev/null; then
  printf '    警告：go-version-m.txt 出现本机绝对路径，交付前需人工核对。\n' >&2
fi

{
  printf '== 文件 ==\n%s\n\n' "$(rel "$TARGET_LIB")"
  printf '== SONAME / NEEDED（llvm-readelf -d）==\n'
  if [[ -n "$READELF" ]]; then
    "$READELF" -d "$TARGET_LIB" | sed -n 's/.*(SONAME).*\[\([^]]*\)\].*/SONAME: \1/p'
    "$READELF" -d "$TARGET_LIB" | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/NEEDED: \1/p'
    printf '\n== ELF 头（llvm-readelf -h）==\n'
    "$READELF" -h "$TARGET_LIB"
  else
    printf '未找到 llvm-readelf，本节为空。\n'
  fi
  printf '\n== 导出符号（llvm-nm -D --defined-only）==\n'
  if [[ -n "$NM" ]]; then
    "$NM" -D --defined-only "$TARGET_LIB"
  else
    printf '未找到 llvm-nm，本节为空。\n'
  fi
} > "$EVIDENCE/readelf.txt"

printf '==> 构建完成\n'
printf '    %s（%s bytes）\n' "$(rel "$TARGET_LIB")" "$size"
printf '    sha256 : %s\n' "$SHA256"
[[ -n "$SONAME" ]] && printf '    SONAME : %s\n' "$SONAME"
[[ -n "$NEEDED" ]] && printf '    NEEDED : %s\n' "$NEEDED"
printf '    取证   : %s/{go-version-m.txt,sha256.txt,readelf.txt}\n' "$(rel "$EVIDENCE")"