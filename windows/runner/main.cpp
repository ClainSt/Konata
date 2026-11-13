#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <filesystem>
#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Process-local temporary files (Dart, SQLite, libmpv) stay with the portable
  // executable. Never change the user's system environment or use the cwd.
  wchar_t executable[32768];
  const DWORD length = ::GetModuleFileNameW(nullptr, executable, 32768);
  if (length == 0 || length >= 32768) return EXIT_FAILURE;
  const auto root = std::filesystem::path(executable).parent_path();
  const auto temporary = root / L"cache" / L"tmp";
  std::error_code error;
  std::filesystem::create_directories(temporary, error);
  if (error || !::SetEnvironmentVariableW(L"TEMP", temporary.c_str()) ||
      !::SetEnvironmentVariableW(L"TMP", temporary.c_str())) {
    ::MessageBoxW(nullptr,
        L"Konata 无法写入程序目录。请将整个文件夹移到可写位置后重试。\n"
        L"Move the entire Konata folder to a writable location and try again.",
        L"Konata", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
#ifndef NDEBUG
  // media_kit keeps debug references across Dart hot restarts using a PID file.
  // A new OS process may reuse that PID, but cannot reuse its native pointers.
  // Clear only this process's marker before Dart starts; hot restarts remain intact.
  const auto references = temporary /
      (L"com.alexmercerind.media_kit.NativeReferenceHolder." +
       std::to_wstring(::GetCurrentProcessId()));
  std::filesystem::remove(references, error);
  if (error) {
    ::OutputDebugStringW(L"Konata: cannot clear stale media_kit debug references.\n");
    return EXIT_FAILURE;
  }
#endif
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Konata", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
