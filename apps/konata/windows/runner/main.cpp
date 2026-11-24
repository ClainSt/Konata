#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <filesystem>
#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 进程内临时文件（Dart、SQLite、libmpv）统一落盘于绿色便携根目录同级空间，
  // 绝不修改用户全局环境变量或读写系统工作目录。
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
  // 若由控制台进程启动则直接复用其终端；在调试器托管模式下则新建输出控制台。
  // 便于本地调试阶段实时查看标准输出与错误日志。
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // 按单线程套间模式初始化 Windows COM 运行库，供内置插件与系统对话框使用。
  // 确保插件调用 COM 接口时具备合法套间环境。
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
