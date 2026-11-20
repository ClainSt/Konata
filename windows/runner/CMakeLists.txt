cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "d3d11_texture_bridge.cpp"
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
# 启用 UTF-8 源码/执行字符集，避免简体中文 Windows (CP936) 编译中文注释触发 C4819
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

# The runner handles native failures with C++ exceptions/futures. Flutter's
# no-STL-exceptions default aliases std::exception to stdext::exception, which
# cannot catch exceptions thrown by the MSVC runtime (e.g. map::at). Keep this
# correction local to the runner; plugin build settings remain unchanged.
get_target_property(runner_definitions ${BINARY_NAME} COMPILE_DEFINITIONS)
list(REMOVE_ITEM runner_definitions "_HAS_EXCEPTIONS=0")
set_property(TARGET ${BINARY_NAME} PROPERTY COMPILE_DEFINITIONS "${runner_definitions}")

# Normal Release entry with separate path_provider/preferences storage for QA.
if("$ENV{KONATA_RELEASE_VALIDATION}" STREQUAL "1")
  target_compile_definitions(${BINARY_NAME} PRIVATE "KONATA_RELEASE_VALIDATION")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "d3d11.lib" "dxgi.lib")
# 对齐 konata-native.cmake 的原生目录定位，并在首次检出尚未展开头文件时自动解包。
if(DEFINED ENV{KONATA_NATIVE_ROOT})
  set(KONATA_RUNNER_NATIVE_ROOT "$ENV{KONATA_NATIVE_ROOT}")
else()
  get_filename_component(KONATA_RUNNER_NATIVE_ROOT
    "${CMAKE_SOURCE_DIR}/../native/konata-native" ABSOLUTE)
endif()
if(EXISTS "${KONATA_RUNNER_NATIVE_ROOT}/windows-headers.zip")
  set(KONATA_RUNNER_HEADERS_READY TRUE)
  foreach(KONATA_HDR client.h render.h render_d3d11.h render_gl.h stream_cb.h)
    if(NOT EXISTS "${KONATA_RUNNER_NATIVE_ROOT}/windows/include/mpv/${KONATA_HDR}")
      set(KONATA_RUNNER_HEADERS_READY FALSE)
    endif()
  endforeach()
  if(NOT KONATA_RUNNER_HEADERS_READY)
    file(MAKE_DIRECTORY "${KONATA_RUNNER_NATIVE_ROOT}/windows/include")
    file(ARCHIVE_EXTRACT
      INPUT "${KONATA_RUNNER_NATIVE_ROOT}/windows-headers.zip"
      DESTINATION "${KONATA_RUNNER_NATIVE_ROOT}/windows/include"
    )
  endif()
endif()

target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}"
  "${KONATA_RUNNER_NATIVE_ROOT}/windows/include"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
