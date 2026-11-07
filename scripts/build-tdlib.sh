#!/usr/bin/env bash
# Reproducible TDLib + OpenSSL build for the OHOS ABI. No global installations.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="${1:-all}"
TD_REVISION="4c6377aa7386c39217878a9a56d581922ad37ca4"
OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
DEVECO_PATH="${DEVECO_PATH:-/Applications/DevEco-Studio.app/Contents}"
OHOS_NATIVE="${OHOS_NATIVE:-$DEVECO_PATH/sdk/default/openharmony/native}"
OHOS_ARCH="${OHOS_ARCH:-arm64-v8a}"
BUILD_JOBS="${BUILD_JOBS:-3}"
CACHE="$ROOT/.local/third_party"
TD_SOURCE="$CACHE/td-src"
TD_HOST_BUILD="$CACHE/td-host"
TD_OHOS_BUILD="$CACHE/td-$OHOS_ARCH"
OPENSSL_SOURCE="$CACHE/openssl-$OPENSSL_VERSION"
OPENSSL_BUILD="$CACHE/openssl-build-$OHOS_ARCH"
OPENSSL_INSTALL="$CACHE/openssl-install-$OHOS_ARCH"
CMAKE="$OHOS_NATIVE/build-tools/cmake/bin/cmake"
NINJA="$OHOS_NATIVE/build-tools/cmake/bin/ninja"
LLVM="$OHOS_NATIVE/llvm/bin"

case "$OHOS_ARCH" in
  arm64-v8a) TARGET="aarch64-linux-ohos"; OPENSSL_TARGET="linux-aarch64" ;;
  x86_64) TARGET="x86_64-linux-ohos"; OPENSSL_TARGET="linux-x86_64" ;;
  *) echo "Unsupported OHOS_ARCH: $OHOS_ARCH" >&2; exit 2 ;;
esac
case "$PHASE" in all|fetch|openssl|generate|tdlib|package|smoke) ;; *) echo "Usage: $0 [all|fetch|openssl|generate|tdlib|package|smoke]" >&2; exit 2 ;; esac
if ! [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then echo 'BUILD_JOBS must be a positive integer' >&2; exit 2; fi
for tool in "$CMAKE" "$NINJA" "$LLVM/clang" "$LLVM/llvm-readelf" "$LLVM/llvm-strip"; do
  test -x "$tool" || { echo "Missing tool: $tool" >&2; exit 1; }
done
mkdir -p "$CACHE"

fetch_sources() {
  if ! test -d "$TD_SOURCE/.git"; then
    git clone --filter=blob:none --no-checkout https://github.com/tdlib/td.git "$TD_SOURCE"
    git -C "$TD_SOURCE" checkout --detach "$TD_REVISION"
  fi
  test "$(git -C "$TD_SOURCE" rev-parse HEAD)" = "$TD_REVISION" || {
    echo 'TDLib cache revision differs; preserve the cache and choose a fresh directory.' >&2; exit 1;
  }
  local archive="$CACHE/openssl-$OPENSSL_VERSION.tar.gz"
  if ! test -f "$archive"; then
    curl --fail --location --retry 3 \
      "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
      --output "$archive.part"
    mv "$archive.part" "$archive"
  fi
  test "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$OPENSSL_SHA256" || {
    echo 'OpenSSL archive SHA-256 mismatch' >&2; exit 1;
  }
  if ! test -f "$OPENSSL_SOURCE/Configure"; then tar -xzf "$archive" -C "$CACHE"; fi
}

build_openssl() {
  test -f "$OPENSSL_SOURCE/Configure" || { echo 'Run the fetch phase first' >&2; exit 1; }
  mkdir -p "$OPENSSL_BUILD"
  # Configure uses host Perl, while compiler/binutils exclusively target OHOS.
  (
    cd "$OPENSSL_BUILD"
    CC="$LLVM/clang --target=$TARGET --sysroot=$OHOS_NATIVE/sysroot" \
    AR="$LLVM/llvm-ar" RANLIB="$LLVM/llvm-ranlib" \
      perl "$OPENSSL_SOURCE/Configure" "$OPENSSL_TARGET" \
        no-shared no-tests no-apps no-docs no-module no-async no-asm \
        -fPIC -DOPENSSL_NO_SECURE_MEMORY \
        --prefix="$OPENSSL_INSTALL" --libdir=lib
    make -j"$BUILD_JOBS" build_libs
    make install_dev
  )
}

generate_tdlib() {
  command -v gperf >/dev/null || { echo 'Host gperf is required' >&2; exit 1; }
  "$CMAKE" -S "$TD_SOURCE" -B "$TD_HOST_BUILD" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_BUILD_TYPE=Release \
    -DTD_GENERATE_SOURCE_FILES=ON -DBUILD_TESTING=OFF -DCCACHE_FOUND:FILEPATH=OFF
  "$CMAKE" --build "$TD_HOST_BUILD" --target prepare_cross_compiling -j "$BUILD_JOBS"
}

build_tdlib() {
  test -f "$OPENSSL_INSTALL/lib/libcrypto.a" || { echo 'Run the openssl phase first' >&2; exit 1; }
  # Keep an unversioned SONAME for HarmonyOS HAP Native library packaging.
  # These exact, idempotent patches are limited to OHOS platform integration.
  python3 - "$TD_SOURCE/CMakeLists.txt" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'set_property(TARGET tdjson PROPERTY SOVERSION "${TDLib_VERSION}")'
new = '# Harlgram OHOS: HAP packages the unversioned libtdjson.so SONAME.'
if old in s:
    p.write_text(s.replace(old, new))
elif new not in s:
    raise SystemExit('Unexpected TDLib CMake source; review the SONAME patch')
p = p.parent / 'tdutils/td/utils/port/detail/ThreadPthread.h'
s = p.read_text()
old = '#if TD_LINUX || TD_FREEBSD || TD_NETBSD\n#define TD_HAVE_THREAD_AFFINITY 1'
new = '#if (TD_LINUX || TD_FREEBSD || TD_NETBSD) && !defined(__OHOS__)\n#define TD_HAVE_THREAD_AFFINITY 1'
if old in s:
    p.write_text(s.replace(old, new))
elif new not in s:
    raise SystemExit('Unexpected TDLib thread header; review the OHOS affinity patch')
PY
  "$CMAKE" -S "$TD_SOURCE" -B "$TD_OHOS_BUILD" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_NATIVE/build/cmake/ohos.toolchain.cmake" \
    -DOHOS_ARCH="$OHOS_ARCH" -DOHOS_STL=c++_shared \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS_RELEASE='-O2 -DNDEBUG' \
    -DCMAKE_C_FLAGS_RELEASE='-O2 -DNDEBUG' -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DOPENSSL_ROOT_DIR="$OPENSSL_INSTALL" \
    -DOPENSSL_INCLUDE_DIR="$OPENSSL_INSTALL/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_INSTALL/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$OPENSSL_INSTALL/lib/libssl.a" \
    -DZLIB_INCLUDE_DIR="$OHOS_NATIVE/sysroot/usr/include" \
    -DZLIB_LIBRARY="$OHOS_NATIVE/sysroot/usr/lib/$TARGET/libz.so" \
    -DTD_ENABLE_JNI=OFF -DTD_ENABLE_PCH=ON -DBUILD_TESTING=OFF -DCCACHE_FOUND:FILEPATH=OFF
  "$CMAKE" --build "$TD_OHOS_BUILD" --target tdjson -j "$BUILD_JOBS"
}

package_tdlib() {
  local output="$ROOT/entry/libs/$OHOS_ARCH"
  local evidence="$CACHE/td-$OHOS_ARCH-evidence.txt"
  test -f "$TD_OHOS_BUILD/libtdjson.so" || { echo 'TDLib shared library was not built' >&2; exit 1; }
  mkdir -p "$output"
  cp "$TD_OHOS_BUILD/libtdjson.so" "$output/libtdjson.so"
  "$LLVM/llvm-strip" --strip-unneeded "$output/libtdjson.so"
  for symbol in td_create_client_id td_send td_receive td_execute; do
    "$LLVM/llvm-nm" -D --defined-only "$output/libtdjson.so" | awk '{print $3}' | \
      grep -x "$symbol" >/dev/null || { echo "Missing exported symbol: $symbol" >&2; exit 1; }
  done
  {
    echo "TDLib: $TD_REVISION"
    echo "OpenSSL: $OPENSSL_VERSION"
    echo "OpenSSL archive SHA-256: $OPENSSL_SHA256"
    echo "OHOS_ARCH: $OHOS_ARCH"
    cat "$OHOS_NATIVE/oh-uni-package.json"
    shasum -a 256 "$output/libtdjson.so"
    "$LLVM/llvm-readelf" -h -d "$output/libtdjson.so"
    "$LLVM/llvm-nm" -D --defined-only "$output/libtdjson.so" | \
      awk '/ td_create_client_id$| td_send$| td_receive$| td_execute$/'
  } | tee "$evidence"
  mkdir -p "$ROOT/entry/src/main/resources/rawfile/licenses"
  cp "$TD_SOURCE/LICENSE_1_0.txt" "$ROOT/entry/src/main/resources/rawfile/licenses/TDLib.txt"
  cp "$TD_SOURCE/sqlite/sqlite/LICENSE" "$ROOT/entry/src/main/resources/rawfile/licenses/SQLCipher.txt"
  cp "$OPENSSL_SOURCE/LICENSE.txt" "$ROOT/entry/src/main/resources/rawfile/licenses/OpenSSL.txt"
  # libc++_shared.so is redistributed by the HAP toolchain. Keep the SDK's
  # complete LLVM notices, including the libc++/libc++abi legacy notices.
  cp "$OHOS_NATIVE/llvm/NOTICE" "$ROOT/entry/src/main/resources/rawfile/licenses/LLVM.txt"
  cp "$ROOT/LICENSE" "$ROOT/entry/src/main/resources/rawfile/licenses/Harlgram-GPL-3.0.txt"
  cp "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/entry/src/main/resources/rawfile/licenses/Harlgram-Notices.txt"
  echo "Packaged: $output/libtdjson.so"
  echo "Build evidence: $evidence"
}

smoke_tdlib() {
  # No API credentials, account, database, network messages or UI interaction.
  test -f "$ROOT/entry/libs/$OHOS_ARCH/libtdjson.so" || { echo 'Run the package phase first' >&2; exit 1; }
  source "$ROOT/scripts/env.sh"
  select_device
  local remote='/data/local/tmp/harlgram-tdlib-smoke'
  local actual_arch expected_arch
  actual_arch="$(hdc_device shell uname -m | tr -d '\r\n')"
  if [[ "$OHOS_ARCH" = arm64-v8a ]]; then expected_arch=aarch64; else expected_arch=x86_64; fi
  [[ "$actual_arch" = "$expected_arch" ]] || { echo "Device ABI is $actual_arch; requested $OHOS_ARCH" >&2; exit 1; }
  cat > "$CACHE/tdlib-smoke.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
int main(void) {
  void *library = dlopen("libtdjson.so", RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "FAIL dlopen: %s\n", dlerror()); return 1; }
  int (*create_client)(void) = (int (*)(void))dlsym(library, "td_create_client_id");
  void (*send_request)(int, const char *) = (void (*)(int, const char *))dlsym(library, "td_send");
  const char *(*receive_response)(double) = (const char *(*)(double))dlsym(library, "td_receive");
  const char *(*execute_request)(const char *) = (const char *(*)(const char *))dlsym(library, "td_execute");
  if (!create_client || !send_request || !receive_response || !execute_request) return 2;
  execute_request("{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":0}");
  puts("PASS dlopen and four TDLib C functions");
  int client = create_client();
  if (client <= 0) return 3;
  send_request(client, "{\"@type\":\"getAuthorizationState\",\"@extra\":\"native-smoke\"}");
  int observed = 0;
  for (int i = 0; i < 100; ++i) {
    const char *response = receive_response(0.1);
    if (response && strstr(response, "authorizationStateWaitTdlibParameters")) { observed = 1; break; }
  }
  send_request(client, "{\"@type\":\"close\"}");
  int closed = 0;
  for (int i = 0; i < 100; ++i) {
    const char *response = receive_response(0.1);
    if (response && strstr(response, "authorizationStateClosed")) { closed = 1; break; }
  }
  puts(observed ? "PASS authorizationStateWaitTdlibParameters" : "FAIL authorization initialization");
  puts(closed ? "PASS authorizationStateClosed" : "FAIL orderly close");
  return observed && closed ? 0 : 4;
}
C
  "$LLVM/clang" --target="$TARGET" --sysroot="$OHOS_NATIVE/sysroot" \
    -fPIE -pie "$CACHE/tdlib-smoke.c" -ldl -o "$CACHE/tdlib-smoke-$OHOS_ARCH"
  hdc_device shell mkdir -p "$remote"
  hdc_device file send "$CACHE/tdlib-smoke-$OHOS_ARCH" "$remote/tdlib-smoke"
  hdc_device file send "$ROOT/entry/libs/$OHOS_ARCH/libtdjson.so" "$remote/libtdjson.so"
  hdc_device file send "$OHOS_NATIVE/llvm/lib/$TARGET/libc++_shared.so" "$remote/libc++_shared.so"
  hdc_device shell "chmod 700 $remote/tdlib-smoke && LD_LIBRARY_PATH=$remote $remote/tdlib-smoke" | \
    tee "$CACHE/td-$OHOS_ARCH-smoke.log"
  # hdc versions differ in how they propagate a remote exit code; assert output too.
  grep -q '^PASS dlopen and four TDLib C functions' "$CACHE/td-$OHOS_ARCH-smoke.log"
  grep -q '^PASS authorizationStateWaitTdlibParameters' "$CACHE/td-$OHOS_ARCH-smoke.log"
  grep -q '^PASS authorizationStateClosed' "$CACHE/td-$OHOS_ARCH-smoke.log"
}

case "$PHASE" in
  all) fetch_sources; build_openssl; generate_tdlib; build_tdlib; package_tdlib ;;
  fetch) fetch_sources ;;
  openssl) build_openssl ;;
  generate) generate_tdlib ;;
  tdlib) build_tdlib ;;
  package) package_tdlib ;;
  smoke) smoke_tdlib ;;
esac
