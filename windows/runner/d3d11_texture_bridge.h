#ifndef RUNNER_D3D11_TEXTURE_BRIDGE_H_
#define RUNNER_D3D11_TEXTURE_BRIDGE_H_

#include <d3d11.h>
#include <dxgi.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

// Bridges libmpv video frames into Flutter Desktop external textures on Windows.
//
// Primary path: triple-buffered offscreen ID3D11Texture2D (BGRA8888 +
// D3D11_RESOURCE_MISC_SHARED) rendered via MPV_RENDER_API_TYPE_D3D11 and
// exposed through kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle.
// Fallback path: MPV_RENDER_API_TYPE_SW -> FlutterDesktopPixelBuffer texture
// when D3D11 device creation or DXGI recovery is unavailable.
class D3D11TextureBridge {
 public:
  static constexpr UINT kNotifyWindowMessage = WM_APP + 0x4B;

  D3D11TextureBridge(HWND window_handle,
                     flutter::FlutterEngine* engine,
                     flutter::PluginRegistrarWindows* registrar);
  ~D3D11TextureBridge();

  D3D11TextureBridge(const D3D11TextureBridge&) = delete;
  D3D11TextureBridge& operator=(const D3D11TextureBridge&) = delete;

  // Drains queued texture change notifications on the Win32 platform thread.
  void ProcessPendingNotifications();

  // Stops all active render sessions and unregisters textures safely before
  // FlutterEngine teardown.
  void Shutdown();

 private:
  class RenderSession;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void HandleCreateSession(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleResize(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleDisposeSession(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleGetAdapterInfo(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  struct PendingNotification {
    int64_t session_id = 0;
    int64_t texture_id = -1;
    std::string backend;
    std::string adapter_name;
    std::string reason;
  };

  void QueueTextureChanged(int64_t session_id,
                           int64_t texture_id,
                           const std::string& backend,
                           const std::string& adapter_name,
                           const std::string& reason);

  HWND window_handle_ = nullptr;
  flutter::FlutterEngine* engine_;
  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* texture_registrar_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  std::mutex sessions_mutex_;
  std::unordered_map<int64_t, std::shared_ptr<RenderSession>> sessions_;
  std::vector<PendingNotification> pending_notifications_;
  int64_t next_session_id_ = 1;
  bool shutdown_called_ = false;
};

#endif  // RUNNER_D3D11_TEXTURE_BRIDGE_H_
