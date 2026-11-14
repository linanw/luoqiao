execute_process(
    COMMAND "${READELF}" --relocations --wide "${LIBRARY}"
    RESULT_VARIABLE readelf_status
    OUTPUT_VARIABLE relocations
)
if(NOT readelf_status STREQUAL "0")
    message(FATAL_ERROR "Could not inspect the WireGuard library ELF relocations.")
endif()
if(relocations MATCHES "R_AARCH64_TLS_TPREL")
    message(FATAL_ERROR "The WireGuard library uses initial-exec TLS and cannot be loaded by HarmonyOS.")
endif()
