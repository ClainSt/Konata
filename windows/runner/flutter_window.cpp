#include "flutter_window.h"

#include <algorithm>
#include <optional>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <set>
#include <map>
#include <stdexcept>
#include "d3d11_video.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
LRESULT CALLBACK RenderSurfaceProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  // Rendering lives here; pointer input belongs to the Flutter view underneath.
  if (message == WM_NCHITTEST) return HTTRANSPARENT;
  return DefWindowProcW(window, message, wparam, lparam);
}
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  const HWND view = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(view);
  WNDCLASSW render_class{};
  render_class.lpfnWndProc = RenderSurfaceProc;
  render_class.hInstance = GetModuleHandleW(nullptr);
  render_class.lpszClassName = L"KonataRenderSurface";
  if (!RegisterClassW(&render_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }
  flutter::MethodChannel<flutter::EncodableValue> video_channel(
      flutter_controller_->engine()->messenger(), "ccplayer/native_video",
      &flutter::StandardMethodCodec::GetInstance());
  video_channel.SetMethodCallHandler(
      [view, hosts = std::set<HWND>{},
       renderers = std::make_shared<std::map<HWND, std::unique_ptr<D3D11Video>>>()]
      (const auto& call, auto result) mutable {
        if (call.method_name() == "create") {
          // A child of the Flutter client shares its top-level window and DPI.
          const auto* render_api = std::get_if<bool>(call.arguments());
          HWND host = CreateWindowExW(0,
              render_api && *render_api ? L"KonataRenderSurface" : L"STATIC",
              L"", WS_CHILD | WS_CLIPCHILDREN, 0, 0, 1, 1, view, nullptr,
              GetModuleHandleW(nullptr), nullptr);
          if (!host) {
            result->Error("create", "Could not create embedded video surface");
            return;
          }
          hosts.insert(host);
          result->Success(flutter::EncodableValue(reinterpret_cast<int64_t>(host)));
          return;
        }
        const auto* args = std::get_if<flutter::EncodableList>(call.arguments());
        if (!args || args->empty()) {
          result->Error("arguments", "Missing surface handle");
          return;
        }
        HWND host = reinterpret_cast<HWND>((*args)[0].LongValue());
        if (!hosts.count(host)) {
          result->Success();
          return;
        }
        if (call.method_name() == "attachD3D11" && args->size() == 3) {
          try {
            if (renderers->count(host)) throw std::runtime_error("Renderer already attached");
            renderers->emplace(host, std::make_unique<D3D11Video>(host,
                (*args)[1].LongValue(), std::get<std::string>((*args)[2])));
            result->Success();
          } catch (const std::exception& error) {
            result->Error("d3d11", error.what());
          }
          return;
        }
        if (call.method_name() == "captureD3D11") {
          try {
            result->Success(flutter::EncodableValue(renderers->at(host)->Capture()));
          } catch (const std::exception& error) {
            result->Error("capture", error.what());
          }
          return;
        }
        if (call.method_name() == "pointerAtControls") {
          POINT point{};
          RECT bounds{};
          GetCursorPos(&point);
          HWND under_pointer = WindowFromPoint(point);
          GetClientRect(host, &bounds);
          ScreenToClient(host, &point);
          bounds.top = (std::max)(0L, bounds.bottom - static_cast<LONG>((*args)[1].LongValue()));
          result->Success(flutter::EncodableValue(IsWindowVisible(host) &&
              GetAncestor(under_pointer, GA_ROOT) == GetAncestor(view, GA_ROOT) &&
              PtInRect(&bounds, point)));
          return;
        }
        if (call.method_name() == "destroy") {
          renderers->erase(host);
          hosts.erase(host);
          DestroyWindow(host);
        } else if (call.method_name() == "hide") {
          ShowWindow(host, SW_HIDE);
        } else if (call.method_name() == "layout" && args->size() == 6) {
          const int width = std::get<int>((*args)[3]);
          const int height = std::get<int>((*args)[4]);
          const int inset = std::get<int>((*args)[5]);
          // Expose the Flutter controls without changing the swapchain size.
          HRGN region = inset ? CreateRectRgn(0, 0, width, (std::max)(0, height - inset)) : nullptr;
          if (!SetWindowRgn(host, region, TRUE) && region) DeleteObject(region);
          SetWindowPos(host, HWND_TOP, std::get<int>((*args)[1]),
                       std::get<int>((*args)[2]), std::get<int>((*args)[3]),
                       std::get<int>((*args)[4]), SWP_NOACTIVATE | SWP_SHOWWINDOW);
          if (renderers->count(host)) renderers->at(host)->Resize();
        } else {
          result->NotImplemented();
          return;
        }
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
