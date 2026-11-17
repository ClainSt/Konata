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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
