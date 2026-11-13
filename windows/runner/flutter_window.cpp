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
  if (message == WM_APP + 42) {
    auto renderer = reinterpret_cast<D3D11Video*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (renderer) renderer->DisplayChanged(wparam != 0);
    return 0;
  }
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
  video_channel_ = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ccplayer/native_video",
      &flutter::StandardMethodCodec::GetInstance());
  video_channel_->SetMethodCallHandler(
      [view, weak_channel = std::weak_ptr(video_channel_), hosts = std::set<HWND>{},
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
            auto renderer = renderers->at(host).get();
            SetWindowLongPtrW(host, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(renderer));
            renderer->on_display_changed = [weak_channel, host] {
              if (auto channel = weak_channel.lock()) channel->InvokeMethod("displayChanged",
                  std::make_unique<flutter::EncodableValue>(reinterpret_cast<int64_t>(host)));
            };
            result->Success();
          } catch (const std::exception& error) {
            result->Error("d3d11", error.what());
          }
          return;
        }
        if (call.method_name() == "captureD3D11") {
          const auto renderer = renderers->find(host);
          // The host survives output recovery. Requests in the detached
          // interval are expected and must not enter STL exception handling.
          if (renderer == renderers->end()) {
            result->Error("output_unavailable", "Video output is being recreated");
            return;
          }
          try {
            result->Success(flutter::EncodableValue(renderer->second->Capture()));
          } catch (const std::exception& error) {
            result->Error("capture", error.what());
          }
          return;
        }
        if (call.method_name() == "detachD3D11") {
          SetWindowLongPtrW(host, GWLP_USERDATA, 0);
          renderers->erase(host);
          result->Success();
          return;
        }
        if (call.method_name() == "beginColor" || call.method_name() == "commitColor") {
          const auto renderer = renderers->find(host);
          if (renderer == renderers->end()) {
            result->Error("output_unavailable", "Video output is being recreated");
            return;
          }
          try {
            if (call.method_name() == "beginColor") {
              result->Success(flutter::EncodableValue(renderer->second->BeginColor()));
            } else {
              renderer->second->CommitColor(std::get<bool>((*args)[1]), std::get<int>((*args)[2]));
              result->Success();
            }
          } catch (const std::exception& error) {
            result->Error("output_color", error.what());
          }
          return;
        }
#ifndef NDEBUG
        if (call.method_name() == "simulateD3D11Failure") {
          if (renderers->count(host)) renderers->at(host)->SimulateFailure();
          result->Success();
          return;
        }
#endif
        if (call.method_name() == "pointerAtControls") {
          if (renderers->count(host)) {
            const auto failure = renderers->at(host)->Failure();
            if (!failure.empty()) {
              result->Error("render_failed", failure);
              return;
            }
          }
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
          SetWindowLongPtrW(host, GWLP_USERDATA, 0);
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
  EnumChildWindows(GetHandle(), [](HWND child, LPARAM) -> BOOL {
    wchar_t name[64]{};
    GetClassNameW(child, name, 64);
    if (std::wstring(name) == L"KonataRenderSurface") SetWindowLongPtrW(child, GWLP_USERDATA, 0);
    return TRUE;
  }, 0);
  video_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_DISPLAYCHANGE || message == WM_SETTINGCHANGE ||
      message == WM_WINDOWPOSCHANGED) {
    EnumChildWindows(hwnd, [](HWND child, LPARAM force) -> BOOL {
      wchar_t name[64]{};
      GetClassNameW(child, name, 64);
      if (std::wstring(name) == L"KonataRenderSurface")
        PostMessageW(child, WM_APP + 42, force, 0);
      return TRUE;
    }, message != WM_WINDOWPOSCHANGED);
  }
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
