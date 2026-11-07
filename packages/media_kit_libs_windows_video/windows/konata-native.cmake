# Native artifacts are prepared by the pinned build recipe, never downloaded
# from a floating release during the application build.
if(DEFINED ENV{KONATA_NATIVE_ROOT})
  set(KONATA_NATIVE_ROOT "$ENV{KONATA_NATIVE_ROOT}")
else()
  get_filename_component(KONATA_NATIVE_ROOT
    "${CMAKE_SOURCE_DIR}/../.dart_tool/konata-native" ABSOLUTE)
endif()
set(KONATA_MANIFEST "${KONATA_NATIVE_ROOT}/windows-manifest.json")
if(NOT EXISTS "${KONATA_MANIFEST}")
  message(FATAL_ERROR "Missing pinned Konata Windows native build: ${KONATA_MANIFEST}")
endif()
file(READ "${KONATA_MANIFEST}" KONATA_NATIVE_JSON)
string(JSON KONATA_MPV GET "${KONATA_NATIVE_JSON}" mpv)
string(JSON KONATA_FFMPEG GET "${KONATA_NATIVE_JSON}" ffmpeg)
string(JSON KONATA_PLATFORM GET "${KONATA_NATIVE_JSON}" platform)
if(NOT KONATA_MPV STREQUAL "0.42.0" OR NOT KONATA_FFMPEG STREQUAL "9.0.2"
    OR NOT KONATA_PLATFORM STREQUAL "windows-x64")
  message(FATAL_ERROR "Unexpected Konata native version or platform")
endif()
string(JSON KONATA_FILE_COUNT LENGTH "${KONATA_NATIVE_JSON}" files)
if(KONATA_FILE_COUNT LESS 3)
  message(FATAL_ERROR "Incomplete Konata native manifest")
endif()
math(EXPR KONATA_LAST_FILE "${KONATA_FILE_COUNT} - 1")
foreach(KONATA_INDEX RANGE ${KONATA_LAST_FILE})
  string(JSON KONATA_PATH MEMBER "${KONATA_NATIVE_JSON}" files ${KONATA_INDEX})
  string(JSON KONATA_EXPECTED GET "${KONATA_NATIVE_JSON}" files "${KONATA_PATH}" sha256)
  file(SHA256 "${KONATA_NATIVE_ROOT}/${KONATA_PATH}" KONATA_ACTUAL)
  if(NOT KONATA_ACTUAL STREQUAL KONATA_EXPECTED)
    message(FATAL_ERROR "Native library verification failed: ${KONATA_PATH}")
  endif()
endforeach()
file(MAKE_DIRECTORY "${LIBMPV_SRC}/include")
file(COPY "${KONATA_NATIVE_ROOT}/windows/libmpv-2.dll"
          "${KONATA_NATIVE_ROOT}/windows/libmpv.dll.a"
     DESTINATION "${LIBMPV_SRC}")
file(COPY "${KONATA_NATIVE_ROOT}/windows/include/mpv/"
     DESTINATION "${LIBMPV_SRC}/include")
