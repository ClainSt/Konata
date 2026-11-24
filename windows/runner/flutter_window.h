#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "d3d11_texture_bridge.h"
#include "win32_window.h"
#include "windows_file_picker_bridge.h"

// 专门用于承载并托管单一 Flutter 视图的 Win32 顶级窗口包装类。
class FlutterWindow : public Win32Window {
 public:
  // 构造基于指定 Dart 工程配置的新版宿主窗口实例。
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window 生命周期钩子实现：
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 待加载启动的 Flutter 工程运行时配置。
  flutter::DartProject project_;

  // 由当前窗口直接持有的 Flutter 视图控制器实例。
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 供原生 `libmpv` 视频渲染使用的 D3D11 共享纹理桥接器。
  std::unique_ptr<D3D11TextureBridge> d3d11_bridge_;

  // 在主界面线程同线程安全调起 Win32 系统文件/目录对话框的桥接器。
  std::unique_ptr<WindowsFilePickerBridge> file_picker_bridge_;

  // 向 Flutter 层实时广播 Win32 边框拖拽缩放起止状态（WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      resize_channel_;

  // 当前是否处于系统窗口拖拽缩放模态循环中。
  bool is_live_resizing_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
