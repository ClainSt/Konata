#include "flutter_window.h"

#include <optional>
#include <algorithm>
#include <dwmapi.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
// 统一使用 Win32 物理像素，保留任务栏工作区及负坐标副屏。
std::string FitMiniWindow(HWND hwnd, const std::string& intent) {
  RECT bounds{};
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  const HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  if (!GetWindowRect(hwnd, &bounds) || !GetMonitorInfoW(monitor, &info)) {
    return "unavailable";
  }
  const RECT work = info.rcWork;
  const LONG width = bounds.right - bounds.left;
  const LONG height = bounds.bottom - bounds.top;
  const LONG max_x = (std::max)(work.left, work.right - width);
  const LONG max_y = (std::max)(work.top, work.bottom - height);
  const LONG threshold = MulDiv(24, GetDpiForWindow(hwnd), 96);
  const LONG left_distance = bounds.left - work.left;
  const LONG right_distance = work.right - bounds.right;
  std::string side = "none";
  if (intent == "left" ||
      (intent == "snap" && left_distance <= threshold &&
       left_distance <= right_distance)) {
    side = "left";
  } else if (intent == "right" ||
             (intent == "snap" && right_distance <= threshold)) {
    side = "right";
  }
  const LONG x = side == "left" ? work.left :
      side == "right" ? max_x : std::clamp(bounds.left, work.left, max_x);
  const LONG y = std::clamp(bounds.top, work.top, max_y);
  if (x != bounds.left || y != bounds.top) {
    if (!SetWindowPos(hwnd, nullptr, x, y, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) {
      return "unavailable";
    }
  }
  return side;
}
}  // namespace
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
  mini_dock_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "konata/desktop_mini",
          &flutter::StandardMethodCodec::GetInstance());
  mini_dock_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "beginAudioDrag") {
          audio_drag_moved_ = false;
          audio_dragging_ = audio_surface_ &&
              GetCursorPos(&audio_drag_cursor_) &&
              GetWindowRect(GetHandle(), &audio_drag_bounds_);
          result->Success();
          return;
        }
        if (call.method_name() == "updateAudioDrag" ||
            call.method_name() == "endAudioDrag") {
          if (audio_dragging_) {
            POINT cursor{};
            if (GetCursorPos(&cursor)) {
              const LONG dx = cursor.x - audio_drag_cursor_.x;
              const LONG dy = cursor.y - audio_drag_cursor_.y;
              audio_drag_moved_ = audio_drag_moved_ || dx != 0 || dy != 0;
              SetWindowPos(GetHandle(), nullptr,
                           audio_drag_bounds_.left + dx,
                           audio_drag_bounds_.top + dy, 0, 0,
                           SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            }
            if (call.method_name() == "endAudioDrag") {
              audio_dragging_ = false;
              if (audio_drag_moved_ && mini_dock_channel_) {
                mini_dock_channel_->InvokeMethod(
                    "moveEnded", std::make_unique<flutter::EncodableValue>());
              }
            }
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setAudioSurface") {
          audio_surface_ = true;
          // 异形区域由窗口管理库登记；这里仅负责关闭系统材质与边框。
          const int no_backdrop = 1;
          const int no_rounding = 1;
          const COLORREF no_border = 0xFFFFFFFE;
          DwmSetWindowAttribute(GetHandle(), 38, &no_backdrop, sizeof(no_backdrop));
          DwmSetWindowAttribute(GetHandle(), 33, &no_rounding, sizeof(no_rounding));
          DwmSetWindowAttribute(GetHandle(), 34, &no_border, sizeof(no_border));
          const MARGINS margins{0, 0, 0, 0};
          DwmExtendFrameIntoClientArea(GetHandle(), &margins);
          result->Success();
          return;
        }
        if (call.method_name() == "clearAudioSurface") {
          audio_surface_ = false;
          audio_dragging_ = false;
          const int default_rounding = 0;
          const COLORREF default_border = 0xFFFFFFFF;
          DwmSetWindowAttribute(GetHandle(), 33, &default_rounding, sizeof(default_rounding));
          DwmSetWindowAttribute(GetHandle(), 34, &default_border, sizeof(default_border));
          result->Success();
          return;
        }
        if (call.method_name() != "fit") {
          result->NotImplemented();
          return;
        }
        const auto* intent = std::get_if<std::string>(call.arguments());
        if (!intent || is_live_resizing_) {
          result->Success(flutter::EncodableValue(std::string("none")));
          return;
        }
        const auto side = FitMiniWindow(GetHandle(), *intent);
        if (side == "unavailable") {
          result->Error("dock_failed", "无法读取或调整屏幕工作区");
        } else {
          result->Success(flutter::EncodableValue(side));
        }
      });
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
  mini_dock_channel_.reset();
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

  // 音频异形窗口禁止系统最大化；外部点击失焦只通知胶囊收起。
  if (audio_surface_) {
    if (message == WM_SYSCOMMAND &&
        ((wparam & 0xFFF0) == SC_MAXIMIZE ||
         (wparam & 0xFFF0) == SC_SIZE)) {
      return 0;
    }
    if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE &&
        !audio_dragging_ && mini_dock_channel_) {
      mini_dock_channel_->InvokeMethod(
          "audioBlur", std::make_unique<flutter::EncodableValue>());
    }
  }
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
      moved_in_drag_ = false;
      if (resize_channel_) {
        resize_channel_->InvokeMethod(
            "resizeStateChanged",
            std::make_unique<flutter::EncodableValue>(true));
      }
    }
  } else if (message == WM_MOVING && is_live_resizing_) {
    moved_in_drag_ = true;
  } else if (message == WM_EXITSIZEMOVE) {
    if (is_live_resizing_) {
      is_live_resizing_ = false;
      if (moved_in_drag_ && mini_dock_channel_) {
        mini_dock_channel_->InvokeMethod(
            "moveEnded", std::make_unique<flutter::EncodableValue>());
      }
      moved_in_drag_ = false;
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
