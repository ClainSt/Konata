#ifndef RUNNER_D3D11_TEXTURE_BRIDGE_H_
#define RUNNER_D3D11_TEXTURE_BRIDGE_H_

#include <d3d11.h>
#include <dxgi1_4.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <wrl/client.h>

#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

// 将 Windows 平台 `libmpv` 解码视频帧桥接至高色深 D3D11 / DirectComposition 渲染管线。
//
// 方案 A（`d3d11_fp16`）：`libmpv` 经 `MPV_RENDER_API_TYPE_D3D11` 直绘至 16-bit 半精度浮点
// (`DXGI_FORMAT_R16G16B16A16_FLOAT`) 或 10-bit (`DXGI_FORMAT_R10G10B10A2_UNORM`) 离屏渲染目标，
// 再在同设备 GPU 上以交错梯度噪声（IGN）抖动着色器零 CPU 拷贝解析至 Flutter 三缓冲 DXGI 共享纹理，
// 100% 兼容窗口亚克力/云母透光材质与全圆角叠加层。
//
// 方案 B（`dcomp_10bit` / `dcomp_fp16`）：基于 Windows DirectComposition 独立子视觉层与
// `DXGI_FORMAT_R10G10B10A2_UNORM` / `DXGI_FORMAT_R16G16B16A16_FLOAT` 翻转模型交换链直出，
// `libmpv` 直接绘制至 10-bit/HDR 后台缓冲并由 DWM 零中间拷贝合成。
//
// 兜底方案（`sw`）：当硬件设备不可用或 DXGI 丢失恢复失败时透明回退软件像素缓冲纹理。
class D3D11TextureBridge {
 public:
  static constexpr UINT kNotifyWindowMessage = WM_APP + 0x4B;

  D3D11TextureBridge(HWND window_handle,
                     flutter::FlutterEngine* engine,
                     flutter::PluginRegistrarWindows* registrar);
  ~D3D11TextureBridge();

  D3D11TextureBridge(const D3D11TextureBridge&) = delete;
  D3D11TextureBridge& operator=(const D3D11TextureBridge&) = delete;

  // 在 Win32 平台主线程排空待处理的纹理与后端变更通知队列。
  void ProcessPendingNotifications();

  // 窗口最小化且无活跃视频会话时即时释放闲置 D3D11 设备并回吐进程空闲工作集。
  void TrimMemoryOnMinimize();

  // 在引擎销毁前中止全部活跃渲染会话、销毁子合成窗口并安全注销已注册纹理。
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
  void HandleSetViewportRect(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleGetSessionMetrics(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleSetHdrFboEnabled(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleDisposeSession(
      const flutter::EncodableMap& args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleGetAdapterInfo(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleTrimMemory(
      const flutter::EncodableMap* args,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  struct PendingNotification {
    int64_t session_id = 0;
    int64_t texture_id = -1;
    std::string backend;
    std::string surface_format;
    int64_t color_bit_depth = 8;
    std::string adapter_name;
    std::string reason;
  };

  void QueueTextureChanged(int64_t session_id,
                           int64_t texture_id,
                           const std::string& backend,
                           const std::string& surface_format,
                           int64_t color_bit_depth,
                           const std::string& adapter_name,
                           const std::string& reason);

  // 获取短期复用池中的温热 D3D11 设备（无可用或已失效时新建），消除切换作品重复创建驱动上下文的 50~120ms 延迟。
  bool AcquireReusableD3D11Device(
      Microsoft::WRL::ComPtr<ID3D11Device>* out_device,
      Microsoft::WRL::ComPtr<ID3D11DeviceContext>* out_context,
      std::string* out_adapter_name);

  // 会话释放后将健康 D3D11 设备归还短期复用池，闲置满 8 秒后由系统线程池定时器彻底回收零驻留。
  void RecycleD3D11Device(Microsoft::WRL::ComPtr<ID3D11Device> device,
                          Microsoft::WRL::ComPtr<ID3D11DeviceContext> context,
                          std::string adapter_name);

  void ClearCachedD3D11Device(bool wait_for_timer);
  static VOID CALLBACK OnIdleDeviceTimerCallback(PVOID param,
                                                 BOOLEAN timer_or_wait_fired);

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

  std::mutex device_cache_mutex_;
  Microsoft::WRL::ComPtr<ID3D11Device> cached_device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> cached_context_;
  std::string cached_adapter_name_;
  std::chrono::steady_clock::time_point cached_device_at_{};
  HANDLE idle_device_timer_ = nullptr;
};

#endif  // RUNNER_D3D11_TEXTURE_BRIDGE_H_
