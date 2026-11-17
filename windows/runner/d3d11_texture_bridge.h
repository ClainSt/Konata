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

// 将 Windows 平台 `libmpv` 解码视频帧桥接至 Flutter Desktop 外部纹理系统。
//
// 主路径：采用三缓冲离屏 D3D11 共享纹理句柄直通 GPU 合成层零拷贝输出。
// 通过 `MPV_RENDER_API_TYPE_D3D11` 直接绘制至共享表面，
// 并经 DXGI 共享句柄描述符暴露给 Flutter 光栅化器。
// 回退路径：当 D3D11 设备初始化或 DXGI 恢复失败时，自动降级为软件像素缓冲渲染。
// 保障软件回退通道稳定可用。
class D3D11TextureBridge {
 public:
  static constexpr UINT kNotifyWindowMessage = WM_APP + 0x4B;

  D3D11TextureBridge(HWND window_handle,
                     flutter::FlutterEngine* engine,
                     flutter::PluginRegistrarWindows* registrar);
  ~D3D11TextureBridge();

  D3D11TextureBridge(const D3D11TextureBridge&) = delete;
  D3D11TextureBridge& operator=(const D3D11TextureBridge&) = delete;

  // 在 Win32 平台主线程排空待处理的纹理变更通知队列。
  void ProcessPendingNotifications();

  // 在引擎销毁前中止全部活跃渲染会话并安全注销已注册纹理。
  // 防止 Flutter 引擎卸载后残留异步帧通知。
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
