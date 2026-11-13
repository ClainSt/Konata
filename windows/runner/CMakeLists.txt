cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "d3d11_video.cpp"
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

# The runner handles native failures with C++ exceptions/futures. Flutter's
# no-STL-exceptions default aliases std::exception to stdext::exception, which
# cannot catch exceptions thrown by the MSVC runtime (e.g. map::at). Keep this
# correction local to the runner; plugin build settings remain unchanged.
get_target_property(runner_definitions ${BINARY_NAME} COMPILE_DEFINITIONS)
list(REMOVE_ITEM runner_definitions "_HAS_EXCEPTIONS=0")
set_property(TARGET ${BINARY_NAME} PROPERTY COMPILE_DEFINITIONS "${runner_definitions}")

# Normal Release entry with separate path_provider/preferences storage for QA.
if("$ENV{KONATA_SCRAPER_PACKAGE}" STREQUAL "1")
  target_compile_definitions(${BINARY_NAME} PRIVATE "KONATA_SCRAPER_PACKAGE")
elseif("$ENV{KONATA_RELEASE_VALIDATION}" STREQUAL "1")
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
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "d3d11.lib" "dxgi.lib")
if(DEFINED ENV{KONATA_NATIVE_ROOT})
  set(KONATA_NATIVE_HEADERS "$ENV{KONATA_NATIVE_ROOT}/windows/include")
else()
  set(KONATA_NATIVE_HEADERS "${CMAKE_SOURCE_DIR}/../.dart_tool/konata-native/windows/include")
endif()
target_include_directories(${BINARY_NAME} PRIVATE "${KONATA_NATIVE_HEADERS}")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
