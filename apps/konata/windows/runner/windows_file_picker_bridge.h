#ifndef RUNNER_WINDOWS_FILE_PICKER_BRIDGE_H_
#define RUNNER_WINDOWS_FILE_PICKER_BRIDGE_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

// 在 Win32 主界面线程原位调起原生 `IFileOpenDialog` / `IFileSaveDialog` 系统文件对话框。
//
// 职责：
// 1. 彻底规避 `windows_file_picker` 在后台工作线程跨线程传入主窗口句柄导致的 Win32 模态死锁；
// 2. 通过 `PostMessageW` 跳出 Flutter 平台通道调用栈，在顶层消息循环以同线程模态归属安全弹窗，
//    确保全屏播放与侧栏展开时对话框始终稳居窗口前方且关闭后立即恢复焦点。
class WindowsFilePickerBridge {
 public:
  static constexpr UINT kShowDialogWindowMessage = WM_APP + 0x4C;

  WindowsFilePickerBridge(HWND window_handle,
                          flutter::PluginRegistrarWindows* registrar);
  ~WindowsFilePickerBridge();

  WindowsFilePickerBridge(const WindowsFilePickerBridge&) = delete;
  WindowsFilePickerBridge& operator=(const WindowsFilePickerBridge&) = delete;

  // 在 Win32 主线程顶层消息循环内执行待展示的系统文件/目录选择对话框。
  void ProcessPendingDialog();

  // 在窗口销毁前注销通道回调并清理尚未展示的排队请求。
  void Shutdown();

 private:
  enum class RequestKind {
    kPickFiles,
    kPickDirectory,
    kSaveFile,
  };

  struct PendingRequest {
    RequestKind kind = RequestKind::kPickFiles;
    std::string dialog_title;
    std::string initial_directory;
    std::string default_file_name;
    std::string accept_label;
    bool allow_multiple = true;
    std::vector<std::string> allowed_extensions;
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void ExecutePickFiles(const PendingRequest& req);
  void ExecutePickDirectory(const PendingRequest& req);
  void ExecuteSaveFile(const PendingRequest& req);

  HWND window_handle_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<PendingRequest> pending_request_;
  bool dialog_active_ = false;
  bool shutdown_called_ = false;
};

#endif  // RUNNER_WINDOWS_FILE_PICKER_BRIDGE_H_
