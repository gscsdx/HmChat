# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(harlgram)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

add_library(entry SHARED napi_init.cpp)
set_target_properties(entry PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
# HarmonyOS uses musl: this SDK provides libdl.a; -ldl resolves its dlopen/dlsym ABI.
target_link_libraries(entry PRIVATE libace_napi.z.so dl)

# Clash NAPI bridge for the VPN extension process. It lives in its own
# subdirectory so the TDLib `entry` target and its link set stay unchanged.
add_subdirectory(clash)
