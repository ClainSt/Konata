#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // 此处控制器尺寸必须与当前窗口客户区尺寸一致，以避免启动阶段表面反复重建。
  // 减少启动期间 DXGI 表面创建与销毁开销。
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // 确认 Flutter 视图控制器及其子窗口句柄初始化成功。
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  FlutterDesktopPluginRegistrarRef raw_bridge_registrar =
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "KonataD3D11VideoBridge");
  if (raw_bridge_registrar != nullptr) {
    auto* bridge_registrar =
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(
                raw_bridge_registrar);
    d3d11_bridge_ = std::make_unique<D3D11TextureBridge>(
        GetHandle(), flutter_controller_->engine(), bridge_registrar);
  }
  FlutterDesktopPluginRegistrarRef raw_picker_registrar =
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "KonataWindowsFilePickerBridge");
  if (raw_picker_registrar != nullptr) {
    auto* picker_registrar =
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(
                raw_picker_registrar);
    file_picker_bridge_ =
        std::make_unique<WindowsFilePickerBridge>(GetHandle(), picker_registrar);
  }
  resize_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "konata/window_resize",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter 可能在首帧显示回调注册前即完成首帧绘制，以下强制刷新绘制以确保窗口可见；
  // 若首帧尚未就绪则此调用自然为空操作。
  // 防止窗口启动时长时间停留在不可见状态。
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  resize_channel_.reset();
  is_live_resizing_ = false;
  if (file_picker_bridge_) {
    file_picker_bridge_->Shutdown();
    file_picker_bridge_.reset();
  }
  if (d3d11_bridge_) {
    d3d11_bridge_->Shutdown();
    d3d11_bridge_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 窗口最小化时在无活跃视频会话的前提下即时回收闲置 D3D11 设备与系统工作集。
  if (message == WM_SIZE && wparam == SIZE_MINIMIZED) {
    if (d3d11_bridge_) {
      d3d11_bridge_->TrimMemoryOnMinimize();
    }
    if (resize_channel_) {
      resize_channel_->InvokeMethod(
          "windowMinimized", std::make_unique<flutter::EncodableValue>());
    }
  } else if (message == WM_ENTERSIZEMOVE) {
    if (!is_live_resizing_) {
      is_live_resizing_ = true;
      if (resize_channel_) {
        resize_channel_->InvokeMethod(
            "resizeStateChanged",
            std::make_unique<flutter::EncodableValue>(true));
      }
    }
  } else if (message == WM_EXITSIZEMOVE) {
    if (is_live_resizing_) {
      is_live_resizing_ = false;
      if (resize_channel_) {
        resize_channel_->InvokeMethod(
            "resizeStateChanged",
            std::make_unique<flutter::EncodableValue>(false));
      }
    }
  }

  // 优先交由 Flutter 引擎与已注册插件拦截处理窗口消息。
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case D3D11TextureBridge::kNotifyWindowMessage:
      if (d3d11_bridge_) {
        d3d11_bridge_->ProcessPendingNotifications();
      }
      return 0;
    case WindowsFilePickerBridge::kShowDialogWindowMessage:
      if (file_picker_bridge_) {
        file_picker_bridge_->ProcessPendingDialog();
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
