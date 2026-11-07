# NAPI bridge to the prebuilt clash core (VPN extension process only).
#
# This fragment is included with add_subdirectory() from ../CMakeLists.txt, so
# it intentionally declares neither project() nor cmake_minimum_required().

if(DEFINED OHOS_ARCH AND NOT "${OHOS_ARCH}" STREQUAL "")
  set(HARLGRAM_CLASH_ARCH "${OHOS_ARCH}")
elseif(DEFINED CMAKE_ANDROID_ARCH_ABI AND NOT "${CMAKE_ANDROID_ARCH_ABI}" STREQUAL "")
  set(HARLGRAM_CLASH_ARCH "${CMAKE_ANDROID_ARCH_ABI}")
endif()

if(NOT HARLGRAM_CLASH_ARCH)
  message(FATAL_ERROR
    "clash_bridge: target ABI is undefined (OHOS_ARCH and CMAKE_ANDROID_ARCH_ABI are both empty).")
endif()

if(NOT DEFINED NATIVERENDER_ROOT_PATH)
  message(FATAL_ERROR "clash_bridge: NATIVERENDER_ROOT_PATH is not defined by the parent scope.")
endif()

# entry/libs/<abi>/libclash_core.so, produced by the Go core build. The core is
# linked here on purpose: its runtime needs to be loaded at process start, so
# the bridge records a SONAME-based DT_NEEDED entry instead of loading it at
# runtime.
set(HARLGRAM_CLASH_CORE
  "${NATIVERENDER_ROOT_PATH}/../../../libs/${HARLGRAM_CLASH_ARCH}/libclash_core.so")

if(NOT EXISTS "${HARLGRAM_CLASH_CORE}")
  message(FATAL_ERROR
    "clash_bridge: prebuilt core is missing: entry/libs/${HARLGRAM_CLASH_ARCH}/libclash_core.so. "
    "Build the core and copy it there before packaging; this bridge must link it as DT_NEEDED.")
endif()

# The core is linked by absolute path, which makes CMake add a build-host
# RUNPATH by default. Suppress it: the SONAME must be resolved from the
# packaged library directory only.
add_library(clash_bridge SHARED clash_bridge.cpp)
set_target_properties(clash_bridge PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
  OUTPUT_NAME clash_bridge
  PREFIX "lib"
  SUFFIX ".so"
  SKIP_BUILD_RPATH TRUE
  BUILD_WITH_INSTALL_RPATH FALSE
)

target_include_directories(clash_bridge PRIVATE
  ${NATIVERENDER_ROOT_PATH}
  ${NATIVERENDER_ROOT_PATH}/include
)

target_link_libraries(clash_bridge PRIVATE
  libace_napi.z.so
  libhilog_ndk.z.so
  dl
  "${HARLGRAM_CLASH_CORE}"
)

# No BUILD_RPATH / INSTALL_RPATH: the packaged library directory resolves the
# SONAME, and build-host absolute paths must never leak into the artifact.