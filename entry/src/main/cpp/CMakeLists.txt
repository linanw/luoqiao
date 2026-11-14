cmake_minimum_required(VERSION 3.16)
project(HarmonyWireGuard LANGUAGES C CXX)

if(NOT OHOS_ARCH STREQUAL "arm64-v8a")
    message(FATAL_ERROR "Harmony WireGuard currently builds for arm64-v8a.")
endif()

if(NOT WIREGUARD_OHOS_GO AND DEFINED ENV{WIREGUARD_OHOS_GO})
    set(WIREGUARD_OHOS_GO "$ENV{WIREGUARD_OHOS_GO}")
endif()
if(NOT WIREGUARD_OHOS_GO)
    find_program(WIREGUARD_OHOS_GO go
        HINTS "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.toolchain/ohos-go/bin")
endif()
if(NOT WIREGUARD_OHOS_GO)
    message(FATAL_ERROR "Run tools/prepare-ohos-go.sh to build the OpenHarmony Go toolchain.")
endif()
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "GOTOOLCHAIN=local" "${WIREGUARD_OHOS_GO}" tool dist list
    RESULT_VARIABLE GO_DIST_STATUS
    OUTPUT_VARIABLE GO_TARGETS
)
if(NOT GO_DIST_STATUS STREQUAL "0" OR NOT GO_TARGETS MATCHES "openharmony/arm64")
    message(FATAL_ERROR "Set WIREGUARD_OHOS_GO to the Go executable built by tools/prepare-ohos-go.sh.")
endif()

# Go recompiles standard packages after a source change, but CMake must also
# rerun both archive commands when the pinned interface resource fix changes.
execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env "GOTOOLCHAIN=local" "${WIREGUARD_OHOS_GO}" env GOROOT
    RESULT_VARIABLE GO_ROOT_STATUS
    OUTPUT_VARIABLE OHOS_GO_ROOT
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
if(NOT GO_ROOT_STATUS STREQUAL "0")
    message(FATAL_ERROR "Could not locate the OpenHarmony Go standard library.")
endif()
set(OHOS_GO_RESOURCE_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../tools/patches/openharmony-go-interface-resources.patch"
    "${OHOS_GO_ROOT}/src/net/interface_table_openharmony.go"
    "${OHOS_GO_ROOT}/src/net/cgo_unix_cgo.go"
)

set(TAILNET_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../tailnet")
file(GLOB_RECURSE TAILNET_SOURCES CONFIGURE_DEPENDS "${TAILNET_DIR}/*.go")

set(GO_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/wireguard")
file(GLOB_RECURSE WIREGUARD_SOURCES CONFIGURE_DEPENDS "${GO_SOURCE_DIR}/*.go")
set(GO_ARCHIVE "${CMAKE_CURRENT_BINARY_DIR}/wireguard_go.a")
set(GO_HEADER "${CMAKE_CURRENT_BINARY_DIR}/wireguard_go.h")
set(OHOS_GO_TARGET "--target=aarch64-linux-ohos \"--sysroot=${CMAKE_SYSROOT}\"")

add_custom_command(
    OUTPUT "${GO_ARCHIVE}" "${GO_HEADER}"
    COMMAND "${CMAKE_COMMAND}" -E env
        "GOOS=openharmony" "GOARCH=arm64" "CGO_ENABLED=1" "GOTOOLCHAIN=local"
        "CC=\"${CMAKE_C_COMPILER}\"" "CGO_CFLAGS=${OHOS_GO_TARGET} -D__MUSL__"
        "CGO_LDFLAGS=${OHOS_GO_TARGET}"
        "${WIREGUARD_OHOS_GO}" build -mod=readonly -trimpath -tags=netcgo,osusergo
        -buildmode=c-archive -o "${GO_ARCHIVE}" .
    DEPENDS
        "${WIREGUARD_OHOS_GO}"
        ${OHOS_GO_RESOURCE_SOURCES}
        "${GO_SOURCE_DIR}/go.mod" "${GO_SOURCE_DIR}/go.sum"
        ${WIREGUARD_SOURCES}
        ${TAILNET_SOURCES} "${TAILNET_DIR}/go.mod" "${TAILNET_DIR}/go.sum"
    WORKING_DIRECTORY "${GO_SOURCE_DIR}"
    VERBATIM
)
add_custom_target(wireguard_go DEPENDS "${GO_ARCHIVE}" "${GO_HEADER}")

add_library(wireguard SHARED napi_bridge.cpp)
add_dependencies(wireguard wireguard_go)
target_compile_features(wireguard PRIVATE cxx_std_17)
target_include_directories(wireguard PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(wireguard PRIVATE "${GO_ARCHIVE}" libace_napi.z.so)
# Each archive owns a Go runtime; cgo trampolines and runtime state must bind locally.
target_link_options(wireguard PRIVATE "-Wl,--exclude-libs,ALL")
add_custom_command(TARGET wireguard POST_BUILD
    COMMAND "${CMAKE_COMMAND}" "-DREADELF=${CMAKE_READELF}" "-DLIBRARY=$<TARGET_FILE:wireguard>"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/verify_elf.cmake"
    VERBATIM
)

set(TAILNET_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../tailnet")
set(TAILNET_ARCHIVE "${CMAKE_CURRENT_BINARY_DIR}/tailnet_go.a")
file(GLOB_RECURSE TAILNET_SOURCES CONFIGURE_DEPENDS "${TAILNET_DIR}/*.go")
add_custom_command(OUTPUT "${TAILNET_ARCHIVE}" "${CMAKE_CURRENT_BINARY_DIR}/tailnet_go.h"
 COMMAND "${CMAKE_COMMAND}" -E env "GOOS=openharmony" "GOARCH=arm64" "CGO_ENABLED=1" "GOTOOLCHAIN=local"
 "CC=\"${CMAKE_C_COMPILER}\"" "CGO_CFLAGS=${OHOS_GO_TARGET} -D__MUSL__" "CGO_LDFLAGS=${OHOS_GO_TARGET}"
 "${WIREGUARD_OHOS_GO}" build -mod=readonly -trimpath -tags=netcgo,osusergo -buildmode=c-archive -o "${TAILNET_ARCHIVE}" ./cmd/native
 DEPENDS ${TAILNET_SOURCES} "${TAILNET_DIR}/go.mod" "${TAILNET_DIR}/go.sum" ${OHOS_GO_RESOURCE_SOURCES}
 WORKING_DIRECTORY "${TAILNET_DIR}" VERBATIM)
add_custom_target(tailnet_go DEPENDS "${TAILNET_ARCHIVE}")
add_library(tailnet SHARED tailnet_bridge.cpp)
add_dependencies(tailnet tailnet_go)
target_compile_features(tailnet PRIVATE cxx_std_17)
target_include_directories(tailnet PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(tailnet PRIVATE "${TAILNET_ARCHIVE}" libace_napi.z.so)
target_link_options(tailnet PRIVATE "-Wl,--exclude-libs,ALL")
