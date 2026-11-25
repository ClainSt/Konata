#include "d3d11_texture_bridge.h"

#include <d3dcompiler.h>
#include <dcomp.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_d3d11.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr char kChannelName[] = "konata/d3d11_video";
constexpr wchar_t kDcompHostClassName[] = L"KONATA_DCOMP_VIDEO_HOST";
constexpr size_t kMinSurfaceExtent = 2;
constexpr size_t kMaxSurfaceExtent = 8192;
constexpr size_t kTripleBufferSlots = 3;
constexpr size_t kPrimaryBufferSlots = 2;
constexpr size_t kMetricsWindowCapacity = 512;
constexpr DWORD kIdleD3D11DeviceTtlMs = 5000;

using FnRenderContextCreate = int (*)(mpv_render_context** res,
                                      mpv_handle* mpv,
                                      mpv_render_param* params);
using FnRenderContextSetUpdateCb = void (*)(mpv_render_context* ctx,
                                            mpv_render_update_fn callback,
                                            void* callback_ctx);
using FnRenderContextUpdate = uint64_t (*)(mpv_render_context* ctx);
using FnRenderContextRender = int (*)(mpv_render_context* ctx,
                                      mpv_render_param* params);
using FnRenderContextReportSwap = void (*)(mpv_render_context* ctx);
using FnRenderContextFree = void (*)(mpv_render_context* ctx);

using FnDCompositionCreateDevice = HRESULT(WINAPI*)(IDXGIDevice* dxgi_device,
                                                    REFIID iid,
                                                    void** dcomp_device);

using FnD3DCompile = HRESULT(WINAPI*)(LPCVOID src_data,
                                      SIZE_T src_data_size,
                                      LPCSTR source_name,
                                      const D3D_SHADER_MACRO* defines,
                                      ID3DInclude* include,
                                      LPCSTR entrypoint,
                                      LPCSTR target,
                                      UINT flags1,
                                      UINT flags2,
                                      ID3DBlob** code,
                                      ID3DBlob** error_msgs);

// 将 16-bit 半精度浮点 / 10-bit 高精渲染目标以交错梯度噪声（IGN）抖动零拷贝解析至
// Flutter 共享纹理的极简全屏三角形顶点着色器源码。
constexpr char kResolveVertexShaderHlsl[] = R"(
struct VSOut {
  float4 pos : SV_Position;
  float2 uv : TEXCOORD0;
};
VSOut main(uint id : SV_VertexID) {
  VSOut o;
  o.uv = float2((id << 1) & 2, id & 2);
  o.pos = float4(o.uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
  return o;
}
)";

// 读取高色深 FP16 / 10-bit 渲染目标并施加三角分布交错梯度噪声（IGN）消除色带截断的像素着色器源码。
// 纯黑像素（如遮幅黑边）直通零噪点，保护 OLED 纯黑对比度与驱动快速清除压缩。
constexpr char kResolvePixelShaderHlsl[] = R"(
Texture2D<float4> srcTex : register(t0);
SamplerState srcSampler : register(s0);
struct PSIn {
  float4 pos : SV_Position;
  float2 uv : TEXCOORD0;
};
float4 main(PSIn input) : SV_Target {
  float4 c = srcTex.Sample(srcSampler, input.uv);
  if (all(c.rgb <= 1e-6)) {
    return float4(0.0, 0.0, 0.0, 1.0);
  }
  float ign = frac(52.9829189 * frac(dot(input.pos.xy, float2(0.06711056, 0.00583715))));
  float dither = (ign - 0.5) / 255.0;
  return float4(saturate(c.rgb + dither), 1.0);
}
)";

struct MpvRenderSymbols {
  FnRenderContextCreate create = nullptr;
  FnRenderContextSetUpdateCb set_update_callback = nullptr;
  FnRenderContextUpdate update = nullptr;
  FnRenderContextRender render = nullptr;
  FnRenderContextReportSwap report_swap = nullptr;
  FnRenderContextFree free = nullptr;

  bool IsValid() const {
    return create != nullptr && set_update_callback != nullptr &&
           update != nullptr && render != nullptr && report_swap != nullptr &&
           free != nullptr;
  }
};

std::string WideToUtf8(const wchar_t* wide) {
  if (wide == nullptr || wide[0] == L'\0') {
    return "";
  }
  const int needed = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                         nullptr, nullptr);
  if (needed <= 1) {
    return "";
  }
  std::string out(static_cast<size_t>(needed - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), needed, nullptr,
                      nullptr);
  return out;
}

HMODULE ResolveLibMpvModule() {
  HMODULE existing = GetModuleHandleW(L"libmpv-2.dll");
  if (existing != nullptr) {
    return existing;
  }
  wchar_t exe_path[MAX_PATH] = {};
  const DWORD len = GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (len > 0 && len < MAX_PATH) {
    std::wstring dir(exe_path, len);
    const size_t slash = dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
      const std::wstring local_dll = dir.substr(0, slash + 1) + L"libmpv-2.dll";
      HMODULE loaded = LoadLibraryW(local_dll.c_str());
      if (loaded != nullptr) {
        return loaded;
      }
    }
  }
  return LoadLibraryW(L"libmpv-2.dll");
}

bool LoadMpvRenderSymbols(MpvRenderSymbols* out) {
  HMODULE mod = ResolveLibMpvModule();
  if (mod == nullptr) {
    return false;
  }
  out->create = reinterpret_cast<FnRenderContextCreate>(
      GetProcAddress(mod, "mpv_render_context_create"));
  out->set_update_callback = reinterpret_cast<FnRenderContextSetUpdateCb>(
      GetProcAddress(mod, "mpv_render_context_set_update_callback"));
  out->update = reinterpret_cast<FnRenderContextUpdate>(
      GetProcAddress(mod, "mpv_render_context_update"));
  out->render = reinterpret_cast<FnRenderContextRender>(
      GetProcAddress(mod, "mpv_render_context_render"));
  out->report_swap = reinterpret_cast<FnRenderContextReportSwap>(
      GetProcAddress(mod, "mpv_render_context_report_swap"));
  out->free = reinterpret_cast<FnRenderContextFree>(
      GetProcAddress(mod, "mpv_render_context_free"));
  return out->IsValid();
}

FnDCompositionCreateDevice ResolveDCompositionCreateDevice() {
  static FnDCompositionCreateDevice cached = []() -> FnDCompositionCreateDevice {
    HMODULE mod = LoadLibraryW(L"dcomp.dll");
    if (mod == nullptr) {
      return nullptr;
    }
    return reinterpret_cast<FnDCompositionCreateDevice>(
        GetProcAddress(mod, "DCompositionCreateDevice"));
  }();
  return cached;
}

FnD3DCompile ResolveD3DCompile() {
  static FnD3DCompile cached = []() -> FnD3DCompile {
    HMODULE mod = LoadLibraryW(L"d3dcompiler_47.dll");
    if (mod == nullptr) {
      return nullptr;
    }
    return reinterpret_cast<FnD3DCompile>(GetProcAddress(mod, "D3DCompile"));
  }();
  return cached;
}

void EnsureDcompHostWindowClassRegistered() {
  static std::once_flag once;
  std::call_once(once, []() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    wc.lpszClassName = kDcompHostClassName;
    RegisterClassExW(&wc);
  });
}

size_t ClampExtent(int64_t raw) {
  if (raw < static_cast<int64_t>(kMinSurfaceExtent)) {
    return kMinSurfaceExtent;
  }
  if (raw > static_cast<int64_t>(kMaxSurfaceExtent)) {
    return kMaxSurfaceExtent;
  }
  return static_cast<size_t>(raw);
}

int64_t ReadInt64Arg(const flutter::EncodableMap& args,
                     const char* key,
                     int64_t fallback) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return fallback;
  }
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) {
    return *v64;
  }
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) {
    return static_cast<int64_t>(*v32);
  }
  return fallback;
}

double ReadDoubleArg(const flutter::EncodableMap& args,
                     const char* key,
                     double fallback) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return fallback;
  }
  if (const auto* vd = std::get_if<double>(&it->second)) {
    return *vd;
  }
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*v64);
  }
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*v32);
  }
  return fallback;
}

bool ReadBoolArg(const flutter::EncodableMap& args,
                 const char* key,
                 bool fallback) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return fallback;
  }
  if (const auto* v = std::get_if<bool>(&it->second)) {
    return *v;
  }
  return fallback;
}

std::string ReadStringArg(const flutter::EncodableMap& args,
                          const char* key,
                          const std::string& fallback) {
  auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return fallback;
  }
  if (const auto* vs = std::get_if<std::string>(&it->second)) {
    return *vs;
  }
  return fallback;
}

const char* FormatNameForDxgi(DXGI_FORMAT fmt) {
  switch (fmt) {
    case DXGI_FORMAT_R16G16B16A16_FLOAT:
      return "DXGI_FORMAT_R16G16B16A16_FLOAT";
    case DXGI_FORMAT_R10G10B10A2_UNORM:
      return "DXGI_FORMAT_R10G10B10A2_UNORM";
    case DXGI_FORMAT_B8G8R8A8_UNORM:
      return "DXGI_FORMAT_B8G8R8A8_UNORM";
    default:
      return "DXGI_FORMAT_UNKNOWN";
  }
}

int64_t BitDepthForDxgi(DXGI_FORMAT fmt) {
  switch (fmt) {
    case DXGI_FORMAT_R16G16B16A16_FLOAT:
      return 16;
    case DXGI_FORMAT_R10G10B10A2_UNORM:
      return 10;
    default:
      return 8;
  }
}

bool SupportsRenderTargetAndShaderResource(ID3D11Device* device,
                                           DXGI_FORMAT fmt) {
  if (device == nullptr) {
    return false;
  }
  UINT support = 0;
  if (FAILED(device->CheckFormatSupport(fmt, &support))) {
    return false;
  }
  const UINT required = D3D11_FORMAT_SUPPORT_TEXTURE2D |
                        D3D11_FORMAT_SUPPORT_RENDER_TARGET |
                        D3D11_FORMAT_SUPPORT_SHADER_SAMPLE;
  return (support & required) == required;
}

bool SupportsDisplaySwapChainFormat(ID3D11Device* device, DXGI_FORMAT fmt) {
  if (device == nullptr) {
    return false;
  }
  UINT support = 0;
  if (FAILED(device->CheckFormatSupport(fmt, &support))) {
    return false;
  }
  const UINT required = D3D11_FORMAT_SUPPORT_TEXTURE2D |
                        D3D11_FORMAT_SUPPORT_RENDER_TARGET |
                        D3D11_FORMAT_SUPPORT_DISPLAY;
  return (support & required) == required;
}

bool CreateD3D11Device(flutter::FlutterEngine* engine,
                       Microsoft::WRL::ComPtr<ID3D11Device>* out_device,
                       Microsoft::WRL::ComPtr<ID3D11DeviceContext>* out_context,
                       std::string* out_adapter_name) {
  Microsoft::WRL::ComPtr<IDXGIAdapter> engine_adapter;
  bool have_engine_adapter = false;
  if (engine != nullptr) {
    IDXGIAdapter* raw_adapter = nullptr;
    if (engine->GetGraphicsAdapter(&raw_adapter) && raw_adapter != nullptr) {
      engine_adapter.Attach(raw_adapter);
      have_engine_adapter = true;
    }
  }

  const std::array<D3D_FEATURE_LEVEL, 4> levels = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
  };

  // 绝不能传入单线程标志 `D3D11_CREATE_DEVICE_SINGLETHREADED`，确保 mpv 硬件解码线程
  // 在开启多线程保护下安全并发；优先申请视频支持标志以启用零拷贝解码，
  // 若驱动拒绝视频上下文则回退常规 BGRA 硬件设备。
  const UINT video_flags =
      D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
  const UINT basic_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = E_FAIL;

  if (have_engine_adapter) {
    hr = D3D11CreateDevice(
        engine_adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, video_flags,
        levels.data(), static_cast<UINT>(levels.size()), D3D11_SDK_VERSION,
        out_device->ReleaseAndGetAddressOf(), nullptr,
        out_context->ReleaseAndGetAddressOf());
    if (FAILED(hr)) {
      hr = D3D11CreateDevice(
          engine_adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, basic_flags,
          levels.data(), static_cast<UINT>(levels.size()), D3D11_SDK_VERSION,
          out_device->ReleaseAndGetAddressOf(), nullptr,
          out_context->ReleaseAndGetAddressOf());
    }
  }
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, video_flags, levels.data(),
        static_cast<UINT>(levels.size()), D3D11_SDK_VERSION,
        out_device->ReleaseAndGetAddressOf(), nullptr,
        out_context->ReleaseAndGetAddressOf());
  }
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, basic_flags, levels.data(),
        static_cast<UINT>(levels.size()), D3D11_SDK_VERSION,
        out_device->ReleaseAndGetAddressOf(), nullptr,
        out_context->ReleaseAndGetAddressOf());
  }
  if (FAILED(hr) || !(*out_device) || !(*out_context)) {
    return false;
  }

  Microsoft::WRL::ComPtr<ID3D10Multithread> multithread;
  if (SUCCEEDED((*out_device).As(&multithread)) && multithread) {
    multithread->SetMultithreadProtected(TRUE);
  }

  if (out_adapter_name != nullptr) {
    out_adapter_name->assign("Direct3D 11 Hardware");
    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
    if (SUCCEEDED((*out_device).As(&dxgi_device)) && dxgi_device) {
      Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
      if (SUCCEEDED(dxgi_device->GetAdapter(&adapter)) && adapter) {
        DXGI_ADAPTER_DESC desc{};
        if (SUCCEEDED(adapter->GetDesc(&desc))) {
          const std::string utf8 = WideToUtf8(desc.Description);
          if (!utf8.empty()) {
            out_adapter_name->assign(utf8);
          }
        }
      }
    }
  }
  return true;
}

// 通知 DXGI 驱动主动收缩空闲显存与命令缓冲区驻留，降低视频关闭或窗口最小化后的内存占用。
void TrimDxgiDevice(ID3D11Device* device) {
  if (device == nullptr) {
    return;
  }
  Microsoft::WRL::ComPtr<IDXGIDevice3> dxgi_device3;
  if (SUCCEEDED(device->QueryInterface(IID_PPV_ARGS(&dxgi_device3))) &&
      dxgi_device3) {
    dxgi_device3->Trim();
  }
}

// 轻量读取首选 DXGI 显卡名称，不创建额外的 D3D11 探测设备上下文。
std::string ProbePrimaryAdapterNameLightweight(flutter::FlutterEngine* engine) {
  if (engine != nullptr) {
    IDXGIAdapter* raw_adapter = nullptr;
    if (engine->GetGraphicsAdapter(&raw_adapter) && raw_adapter != nullptr) {
      Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
      adapter.Attach(raw_adapter);
      DXGI_ADAPTER_DESC desc{};
      if (SUCCEEDED(adapter->GetDesc(&desc))) {
        const std::string utf8 = WideToUtf8(desc.Description);
        if (!utf8.empty()) {
          return utf8;
        }
      }
    }
  }
  Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
  if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) && factory) {
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter1;
    if (SUCCEEDED(factory->EnumAdapters1(0, &adapter1)) && adapter1) {
      DXGI_ADAPTER_DESC1 desc1{};
      if (SUCCEEDED(adapter1->GetDesc1(&desc1))) {
        const std::string utf8 = WideToUtf8(desc1.Description);
        if (!utf8.empty()) {
          return utf8;
        }
      }
    }
  }
  return "";
}

struct ResolveShaderBytecodeCache {
  std::vector<uint8_t> vs;
  std::vector<uint8_t> ps;
  bool valid = false;
};

// 进程级缓存全屏三角形抖动解析着色器的 DXBC 字节码，避免每次打开视频重复触发 D3DCompile。
const ResolveShaderBytecodeCache& GetCompiledResolveShaderBytecode() {
  static ResolveShaderBytecodeCache cache;
  static std::once_flag once;
  std::call_once(once, []() {
    FnD3DCompile compile_fn = ResolveD3DCompile();
    if (compile_fn == nullptr) {
      return;
    }
    Microsoft::WRL::ComPtr<ID3DBlob> vs_blob;
    Microsoft::WRL::ComPtr<ID3DBlob> ps_blob;
    Microsoft::WRL::ComPtr<ID3DBlob> err_blob;

    HRESULT hr = compile_fn(
        kResolveVertexShaderHlsl, std::strlen(kResolveVertexShaderHlsl),
        "vs_resolve", nullptr, nullptr, "main", "vs_4_0",
        D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &vs_blob, &err_blob);
    if (FAILED(hr) || !vs_blob) {
      return;
    }

    hr = compile_fn(kResolvePixelShaderHlsl,
                    std::strlen(kResolvePixelShaderHlsl), "ps_resolve", nullptr,
                    nullptr, "main", "ps_4_0", D3DCOMPILE_OPTIMIZATION_LEVEL3,
                    0, &ps_blob, &err_blob);
    if (FAILED(hr) || !ps_blob) {
      return;
    }

    const auto* vs_ptr =
        static_cast<const uint8_t*>(vs_blob->GetBufferPointer());
    const auto* ps_ptr =
        static_cast<const uint8_t*>(ps_blob->GetBufferPointer());
    cache.vs.assign(vs_ptr, vs_ptr + vs_blob->GetBufferSize());
    cache.ps.assign(ps_ptr, ps_ptr + ps_blob->GetBufferSize());
    cache.valid = !cache.vs.empty() && !cache.ps.empty();
  });
  return cache;
}

bool CompileResolveShaders(ID3D11Device* device,
                           Microsoft::WRL::ComPtr<ID3D11VertexShader>* out_vs,
                           Microsoft::WRL::ComPtr<ID3D11PixelShader>* out_ps,
                           Microsoft::WRL::ComPtr<ID3D11SamplerState>* out_sm) {
  if (device == nullptr) {
    return false;
  }
  const ResolveShaderBytecodeCache& bytecode =
      GetCompiledResolveShaderBytecode();
  if (!bytecode.valid) {
    return false;
  }

  HRESULT hr = device->CreateVertexShader(bytecode.vs.data(),
                                          bytecode.vs.size(), nullptr,
                                          out_vs->ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return false;
  }

  hr = device->CreatePixelShader(bytecode.ps.data(), bytecode.ps.size(),
                                 nullptr, out_ps->ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    return false;
  }

  D3D11_SAMPLER_DESC samp{};
  samp.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
  samp.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
  samp.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
  samp.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  samp.ComparisonFunc = D3D11_COMPARISON_NEVER;
  samp.MaxLOD = D3D11_FLOAT32_MAX;
  hr = device->CreateSamplerState(&samp, out_sm->ReleaseAndGetAddressOf());
  return SUCCEEDED(hr);
}

}  // namespace

class D3D11TextureBridge::RenderSession
    : public std::enable_shared_from_this<RenderSession> {
 public:
  enum class BackendMode {
    kGpuNextUnderlay,
    kDirectComposition10Bit,
    kDirectCompositionFp16,
    kD3D11HighBitDepth,
    kSoftware,
  };

  struct SessionMetrics {
    int64_t rendered_frames = 0;
    int64_t render_p50_us = 0;
    int64_t render_p99_us = 0;
    int64_t render_avg_us = 0;
    std::string backend;
    std::string surface_format;
    int64_t color_bit_depth = 8;
    bool dcomp_active = false;
  };

  using TextureChangedCallback =
      std::function<void(int64_t session_id,
                         int64_t texture_id,
                         const std::string& backend,
                         const std::string& surface_format,
                         int64_t color_bit_depth,
                         const std::string& adapter_name,
                         const std::string& reason)>;

  using DeviceAcquirer =
      std::function<bool(Microsoft::WRL::ComPtr<ID3D11Device>*,
                         Microsoft::WRL::ComPtr<ID3D11DeviceContext>*,
                         std::string*)>;
  using DeviceRecycler =
      std::function<void(Microsoft::WRL::ComPtr<ID3D11Device>,
                         Microsoft::WRL::ComPtr<ID3D11DeviceContext>,
                         std::string)>;

  RenderSession(int64_t session_id,
                HWND parent_window,
                mpv_handle* mpv,
                MpvRenderSymbols symbols,
                flutter::FlutterEngine* engine,
                flutter::TextureRegistrar* registrar,
                size_t width,
                size_t height,
                TextureChangedCallback on_texture_changed,
                DeviceAcquirer acquire_device,
                DeviceRecycler recycle_device)
      : session_id_(session_id),
        parent_window_(parent_window),
        mpv_(mpv),
        symbols_(symbols),
        engine_(engine),
        registrar_(registrar),
        on_texture_changed_(std::move(on_texture_changed)),
        acquire_device_(std::move(acquire_device)),
        recycle_device_(std::move(recycle_device)),
        target_width_(width),
        target_height_(height) {}

  bool Initialize(bool prefer_software,
                  const std::string& requested_backend,
                  std::string* error_message) {
    if (!prefer_software && requested_backend == "gpu_next") {
      if (InitializeGpuNextUnderlayBackend()) {
        return true;
      }
      if (mpv_ == nullptr) {
        if (error_message != nullptr) {
          error_message->assign("无法创建 Windows gpu-next 10-bit 底层子窗口");
        }
        return false;
      }
    }
    if (mpv_ == nullptr || !symbols_.IsValid()) {
      if (error_message != nullptr) {
        error_message->assign("非 gpu_next 后端需要有效的 mpv 句柄与渲染符号");
      }
      return false;
    }

    bool initialized = false;
    if (!prefer_software) {
      if (requested_backend == "dcomp_10bit") {
        initialized = InitializeDirectCompositionBackend(false);
      } else if (requested_backend == "dcomp_fp16") {
        initialized = InitializeDirectCompositionBackend(true);
      }
      if (!initialized) {
        const bool prefer_10bit_fbo = (requested_backend == "d3d11_10bit");
        initialized = InitializeD3D11HighBitDepthBackend(prefer_10bit_fbo);
      }
    }
    if (!initialized) {
      if (!InitializeSoftwareBackend()) {
        if (error_message != nullptr) {
          error_message->assign(
              "无法初始化 D3D11/DirectComposition 及软件兜底视频渲染上下文");
        }
        return false;
      }
    }

    render_thread_ = std::thread([this]() { RenderThreadMain(); });
    return true;
  }

  void Resize(size_t width, size_t height) {
    if (backend_mode_ == BackendMode::kGpuNextUnderlay) {
      target_width_ = width;
      target_height_ = height;
      return;
    }
    {
      std::lock_guard<std::mutex> lock(render_mutex_);
      if (stop_requested_) {
        return;
      }
      if (target_width_ == width && target_height_ == height) {
        return;
      }
      target_width_ = width;
      target_height_ = height;
      resize_requested_ = true;
      force_render_ = true;
    }
    render_cv_.notify_one();
  }

  // 在共享纹理模式下动态切换离屏高色深渲染目标：SDR 常态保持 10-bit（4 字节/像素），HDR 升档至 FP16（8 字节/像素）。
  bool SetHdrFboEnabled(bool enabled) {
    if (is_software_ || backend_mode_ != BackendMode::kD3D11HighBitDepth ||
        !device_ || !resolve_vs_ || !resolve_ps_ || !resolve_sampler_) {
      return false;
    }
    const DXGI_FORMAT desired_fmt = NegotiateHighBitDepthFormat(!enabled);
    {
      std::lock_guard<std::mutex> lock(render_mutex_);
      if (stop_requested_ || disposed_) {
        return false;
      }
      pending_hdr_fbo_format_ = desired_fmt;
      pending_hdr_fbo_change_ = true;
      force_render_ = true;
    }
    render_cv_.notify_one();
    return true;
  }

  // 在 Win32 主线程同步底层 10-bit 渲染宿主（gpu-next 子窗口或 DirectComposition 底层视觉层）的视口几何、圆角裁剪与显隐。
  void SetViewportRectOnUiThread(int left_px,
                                 int top_px,
                                 int right_px,
                                 int bottom_px,
                                 float corner_radius_px,
                                 bool visible) {
    const int w = std::max<int>(static_cast<int>(kMinSurfaceExtent),
                                right_px - left_px);
    const int h = std::max<int>(static_cast<int>(kMinSurfaceExtent),
                                bottom_px - top_px);
    if (backend_mode_ == BackendMode::kGpuNextUnderlay) {
      if (dcomp_hwnd_ == nullptr || !IsWindow(dcomp_hwnd_)) {
        return;
      }
      if (!visible || right_px - left_px <= 2 || bottom_px - top_px <= 2) {
        ShowWindow(dcomp_hwnd_, SW_HIDE);
        return;
      }
      // 严守底层 Z 序（HWND_BOTTOM），确保 Flutter 透明画布、弹窗与亚克力浮层始终位于视频上方。
      SetWindowPos(dcomp_hwnd_, HWND_BOTTOM, left_px, top_px, w, h,
                   SWP_NOACTIVATE | SWP_SHOWWINDOW);
      const int radius_int = static_cast<int>(std::max(0.0f, corner_radius_px));
      if (radius_int > 0) {
        HRGN region = CreateRoundRectRgn(0, 0, w + 1, h + 1, radius_int * 2,
                                         radius_int * 2);
        if (region != nullptr) {
          if (!SetWindowRgn(dcomp_hwnd_, region, TRUE)) {
            DeleteObject(region);
          }
        }
      } else {
        SetWindowRgn(dcomp_hwnd_, nullptr, TRUE);
      }
      target_width_ = static_cast<size_t>(w);
      target_height_ = static_cast<size_t>(h);
      return;
    }

    if (!IsDirectCompositionMode()) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(dcomp_mutex_);
      if (!dcomp_device_ || !dcomp_target_ || !dcomp_visual_ || !dcomp_clip_) {
        return;
      }
      if (!visible || right_px - left_px <= 2 || bottom_px - top_px <= 2) {
        dcomp_target_->SetRoot(nullptr);
        dcomp_device_->Commit();
        return;
      }
      dcomp_visual_->SetOffsetX(static_cast<float>(left_px));
      dcomp_visual_->SetOffsetY(static_cast<float>(top_px));
      dcomp_clip_->SetLeft(0.0f);
      dcomp_clip_->SetTop(0.0f);
      dcomp_clip_->SetRight(static_cast<float>(w));
      dcomp_clip_->SetBottom(static_cast<float>(h));
      const float r = std::max(0.0f, corner_radius_px);
      dcomp_clip_->SetTopLeftRadiusX(r);
      dcomp_clip_->SetTopLeftRadiusY(r);
      dcomp_clip_->SetTopRightRadiusX(r);
      dcomp_clip_->SetTopRightRadiusY(r);
      dcomp_clip_->SetBottomLeftRadiusX(r);
      dcomp_clip_->SetBottomLeftRadiusY(r);
      dcomp_clip_->SetBottomRightRadiusX(r);
      dcomp_clip_->SetBottomRightRadiusY(r);
      dcomp_visual_->SetClip(dcomp_clip_.Get());
      dcomp_target_->SetRoot(dcomp_visual_.Get());
      dcomp_device_->Commit();
    }
    Resize(static_cast<size_t>(w), static_cast<size_t>(h));
  }

  SessionMetrics CollectMetrics() {
    SessionMetrics out{};
    out.backend = backend();
    out.surface_format = surface_format();
    out.color_bit_depth = color_bit_depth();
    out.dcomp_active = IsDirectCompositionMode();

    std::vector<int64_t> copy;
    {
      std::lock_guard<std::mutex> lock(metrics_mutex_);
      out.rendered_frames = total_rendered_frames_;
      copy = render_durations_us_;
    }
    if (!copy.empty()) {
      int64_t sum = 0;
      for (int64_t v : copy) {
        sum += v;
      }
      out.render_avg_us = sum / static_cast<int64_t>(copy.size());
      std::sort(copy.begin(), copy.end());
      out.render_p50_us = copy[copy.size() / 2];
      const size_t p99_idx = std::min(
          copy.size() - 1,
          static_cast<size_t>((copy.size() * 99) / 100));
      out.render_p99_us = copy[p99_idx];
    }
    return out;
  }

  void Dispose() {
    {
      std::lock_guard<std::mutex> lock(render_mutex_);
      if (disposed_) {
        return;
      }
      disposed_ = true;
      stop_requested_ = true;
    }

    // 在 join 渲染线程之前先解绑 mpv 更新回调，防止对象销毁期间发生悬空回调访问。
    if (render_ctx_ != nullptr && symbols_.set_update_callback != nullptr) {
      symbols_.set_update_callback(render_ctx_, nullptr, nullptr);
    }
    render_cv_.notify_all();
    if (render_thread_.joinable()) {
      render_thread_.join();
    }

    if (render_ctx_ != nullptr && symbols_.free != nullptr) {
      symbols_.free(render_ctx_);
      render_ctx_ = nullptr;
    }

    UnregisterCurrentTexture();
    ReleaseDirectCompositionResources();

    // 渲染上下文已销毁且渲染线程已汇合，将健康 D3D11 设备归还 8 秒短期复用池，释放会话私有着色器与 FBO。
    Microsoft::WRL::ComPtr<ID3D11Device> recyclable_device;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> recyclable_context;
    std::string recyclable_adapter;
    {
      std::lock_guard<std::mutex> lock(surface_mutex_);
      hdr_fbo_srv_.Reset();
      hdr_fbo_texture_.Reset();
      hdr_fbo_width_ = 0;
      hdr_fbo_height_ = 0;
      resolve_sampler_.Reset();
      resolve_ps_.Reset();
      resolve_vs_.Reset();
      if (!is_software_ && device_ && context_) {
        recyclable_device = std::move(device_);
        recyclable_context = std::move(context_);
        recyclable_adapter = adapter_name_;
      }
    }
    if (recyclable_device && recyclable_context && recycle_device_) {
      recycle_device_(std::move(recyclable_device),
                      std::move(recyclable_context),
                      std::move(recyclable_adapter));
    }
  }

  int64_t session_id() const { return session_id_; }
  int64_t texture_id() const { return texture_id_; }
  int64_t native_window_handle() const {
    return reinterpret_cast<int64_t>(dcomp_hwnd_);
  }
  std::string adapter_name() const { return adapter_name_; }
  int64_t color_bit_depth() const {
    return BitDepthForDxgi(active_fbo_format_.load(std::memory_order_acquire));
  }
  std::string surface_format() const {
    return is_software_
               ? "SW_RGBA8888"
               : FormatNameForDxgi(
                     active_fbo_format_.load(std::memory_order_acquire));
  }

  std::string backend() const {
    if (is_software_) {
      return "sw";
    }
    switch (backend_mode_) {
      case BackendMode::kGpuNextUnderlay:
        return "gpu_next";
      case BackendMode::kDirectComposition10Bit:
        return "dcomp_10bit";
      case BackendMode::kDirectCompositionFp16:
        return "dcomp_fp16";
      case BackendMode::kD3D11HighBitDepth: {
        const DXGI_FORMAT fmt =
            active_fbo_format_.load(std::memory_order_acquire);
        if (fmt == DXGI_FORMAT_R16G16B16A16_FLOAT) {
          return "d3d11_fp16";
        }
        if (fmt == DXGI_FORMAT_R10G10B10A2_UNORM) {
          return "d3d11_10bit";
        }
        return "d3d11";
      }
      case BackendMode::kSoftware:
        return "sw";
    }
    return "sw";
  }

  bool IsDirectCompositionMode() const {
    return !is_software_ &&
           (backend_mode_ == BackendMode::kGpuNextUnderlay ||
            backend_mode_ == BackendMode::kDirectComposition10Bit ||
            backend_mode_ == BackendMode::kDirectCompositionFp16);
  }

 private:
  struct TextureAllocation {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> rtv;
    HANDLE shared_handle = nullptr;
    size_t width = 0;
    size_t height = 0;
    std::atomic<int> pinned_count{0};
  };

  static void OnMpvUpdate(void* ctx) {
    auto* self = static_cast<RenderSession*>(ctx);
    if (self == nullptr) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(self->render_mutex_);
      if (self->stop_requested_) {
        return;
      }
      self->render_requested_ = true;
    }
    self->render_cv_.notify_one();
  }

  static void OnSurfaceReleased(void* release_context) {
    auto* alloc = static_cast<TextureAllocation*>(release_context);
    if (alloc != nullptr) {
      alloc->pinned_count.fetch_sub(1, std::memory_order_acq_rel);
    }
  }

  void RecordFrameRenderMicros(int64_t duration_us) {
    std::lock_guard<std::mutex> lock(metrics_mutex_);
    total_rendered_frames_ += 1;
    if (render_durations_us_.size() < kMetricsWindowCapacity) {
      render_durations_us_.push_back(duration_us);
    } else {
      render_durations_us_[metrics_cursor_] = duration_us;
      metrics_cursor_ = (metrics_cursor_ + 1) % kMetricsWindowCapacity;
    }
  }

  // 根据显卡硬件支持优先协商 16-bit 半精度浮点（`R16G16B16A16_FLOAT`）或 10-bit（`R10G10B10A2_UNORM`）渲染目标。
  DXGI_FORMAT NegotiateHighBitDepthFormat(bool prefer_10bit) {
    if (!device_) {
      return DXGI_FORMAT_B8G8R8A8_UNORM;
    }
    if (prefer_10bit) {
      if (SupportsRenderTargetAndShaderResource(
              device_.Get(), DXGI_FORMAT_R10G10B10A2_UNORM)) {
        return DXGI_FORMAT_R10G10B10A2_UNORM;
      }
      if (SupportsRenderTargetAndShaderResource(
              device_.Get(), DXGI_FORMAT_R16G16B16A16_FLOAT)) {
        return DXGI_FORMAT_R16G16B16A16_FLOAT;
      }
    } else {
      if (SupportsRenderTargetAndShaderResource(
              device_.Get(), DXGI_FORMAT_R16G16B16A16_FLOAT)) {
        return DXGI_FORMAT_R16G16B16A16_FLOAT;
      }
      if (SupportsRenderTargetAndShaderResource(
              device_.Get(), DXGI_FORMAT_R10G10B10A2_UNORM)) {
        return DXGI_FORMAT_R10G10B10A2_UNORM;
      }
    }
    return DXGI_FORMAT_B8G8R8A8_UNORM;
  }

  bool EnsureHighBitDepthFboLocked(size_t width, size_t height) {
    const DXGI_FORMAT fmt = active_fbo_format_.load(std::memory_order_acquire);
    if (fmt == DXGI_FORMAT_B8G8R8A8_UNORM || !resolve_vs_ || !resolve_ps_ ||
        !resolve_sampler_) {
      hdr_fbo_texture_.Reset();
      hdr_fbo_srv_.Reset();
      hdr_fbo_width_ = 0;
      hdr_fbo_height_ = 0;
      return true;
    }
    if (hdr_fbo_texture_ && hdr_fbo_srv_ && hdr_fbo_width_ == width &&
        hdr_fbo_height_ == height && hdr_fbo_format_ == fmt) {
      return true;
    }
    hdr_fbo_texture_.Reset();
    hdr_fbo_srv_.Reset();

    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = static_cast<UINT>(width);
    desc.Height = static_cast<UINT>(height);
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = fmt;
    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = 0;
    desc.MiscFlags = 0;

    Microsoft::WRL::ComPtr<ID3D11Texture2D> fbo_tex;
    if (FAILED(device_->CreateTexture2D(&desc, nullptr, &fbo_tex)) ||
        !fbo_tex) {
      return false;
    }

    D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc{};
    srv_desc.Format = fmt;
    srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    srv_desc.Texture2D.MostDetailedMip = 0;
    srv_desc.Texture2D.MipLevels = 1;

    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> srv;
    if (FAILED(device_->CreateShaderResourceView(fbo_tex.Get(), &srv_desc,
                                                 &srv)) ||
        !srv) {
      return false;
    }

    hdr_fbo_texture_ = std::move(fbo_tex);
    hdr_fbo_srv_ = std::move(srv);
    hdr_fbo_width_ = width;
    hdr_fbo_height_ = height;
    hdr_fbo_format_ = fmt;
    return true;
  }

  bool InitializeD3D11HighBitDepthBackend(bool prefer_10bit) {
    const bool acquired =
        acquire_device_
            ? acquire_device_(&device_, &context_, &adapter_name_)
            : CreateD3D11Device(engine_, &device_, &context_, &adapter_name_);
    if (!acquired) {
      return false;
    }
    DXGI_FORMAT chosen_fmt = NegotiateHighBitDepthFormat(prefer_10bit);
    if (chosen_fmt != DXGI_FORMAT_B8G8R8A8_UNORM) {
      if (!CompileResolveShaders(device_.Get(), &resolve_vs_, &resolve_ps_,
                                 &resolve_sampler_)) {
        // 若系统缺失 d3dcompiler_47.dll，则降级至直绘 8-bit 共享表面。
        chosen_fmt = DXGI_FORMAT_B8G8R8A8_UNORM;
      }
    }
    active_fbo_format_.store(chosen_fmt, std::memory_order_release);
    // 初始化期仅按需预创建 1 个共享纹理槽校验硬件链路，其余槽位待真实视口尺寸就绪后再按需分配，避免占位尺寸浪费显存。
    if (!CreateSlotTextureLocked(0, target_width_, target_height_) ||
        !EnsureHighBitDepthFboLocked(target_width_, target_height_)) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }

    mpv_d3d11_init_params d3d11_init{};
    d3d11_init.device = device_.Get();
    int advanced_control = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE,
         const_cast<char*>(MPV_RENDER_API_TYPE_D3D11)},
        {MPV_RENDER_PARAM_D3D11_INIT_PARAMS, &d3d11_init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced_control},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };

    mpv_render_context* ctx = nullptr;
    if (symbols_.create(&ctx, mpv_, params) < 0 || ctx == nullptr) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }

    render_ctx_ = ctx;
    is_software_ = false;
    backend_mode_ = BackendMode::kD3D11HighBitDepth;
    RegisterGpuTexture();
    symbols_.set_update_callback(render_ctx_, &RenderSession::OnMpvUpdate, this);
    return texture_id_ >= 0;
  }

  // 创建挂接于主窗口最底层（HWND_BOTTOM）的原生子窗口供 vo=gpu-next (libplacebo) 直接创建 10-bit/HDR 翻转交换链。
  bool InitializeGpuNextUnderlayBackend() {
    if (parent_window_ == nullptr || !IsWindow(parent_window_)) {
      return false;
    }
    const std::string probed_adapter =
        ProbePrimaryAdapterNameLightweight(engine_);
    adapter_name_ =
        probed_adapter.empty() ? "D3D11 libplacebo" : probed_adapter;

    EnsureDcompHostWindowClassRegistered();
    HWND host_hwnd = CreateWindowExW(
        WS_EX_TRANSPARENT | WS_EX_NOPARENTNOTIFY, kDcompHostClassName, L"",
        WS_CHILD | WS_DISABLED, 0, 0, static_cast<int>(target_width_),
        static_cast<int>(target_height_), parent_window_, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (host_hwnd == nullptr) {
      return false;
    }
    // 初始置于最底层并保持隐藏，待上层 Flutter BlendMode.clear 挖空同步真实像素矩形后立即显现。
    SetWindowPos(host_hwnd, HWND_BOTTOM, 0, 0, static_cast<int>(target_width_),
                 static_cast<int>(target_height_),
                 SWP_NOACTIVATE | SWP_HIDEWINDOW);

    dcomp_hwnd_ = host_hwnd;
    active_fbo_format_.store(DXGI_FORMAT_R10G10B10A2_UNORM,
                             std::memory_order_release);
    backend_mode_ = BackendMode::kGpuNextUnderlay;
    texture_id_ = -1;
    is_software_ = false;
    return true;
  }

  // 直接将 10-bit/HDR DirectComposition 翻转模型交换链挂载至顶层宿主窗口非顶置目标（topmost=FALSE），
  // 由 DWM 物理保证视频永远位于 Flutter 透明子窗口之下，彻底杜绝穿模与遮挡浮层。
  bool InitializeDirectCompositionBackend(bool prefer_fp16) {
    FnDCompositionCreateDevice create_dcomp = ResolveDCompositionCreateDevice();
    if (create_dcomp == nullptr || parent_window_ == nullptr ||
        !IsWindow(parent_window_)) {
      return false;
    }
    const bool acquired =
        acquire_device_
            ? acquire_device_(&device_, &context_, &adapter_name_)
            : CreateD3D11Device(engine_, &device_, &context_, &adapter_name_);
    if (!acquired) {
      return false;
    }

    DXGI_FORMAT swap_fmt = prefer_fp16 ? DXGI_FORMAT_R16G16B16A16_FLOAT
                                       : DXGI_FORMAT_R10G10B10A2_UNORM;
    if (!SupportsDisplaySwapChainFormat(device_.Get(), swap_fmt)) {
      swap_fmt = prefer_fp16 ? DXGI_FORMAT_R10G10B10A2_UNORM
                             : DXGI_FORMAT_R16G16B16A16_FLOAT;
      if (!SupportsDisplaySwapChainFormat(device_.Get(), swap_fmt)) {
        ReleaseD3D11ResourcesLocked();
        return false;
      }
    }

    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
    if (FAILED(device_.As(&dxgi_device)) || !dxgi_device) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }
    Microsoft::WRL::ComPtr<IDXGIAdapter> dxgi_adapter;
    Microsoft::WRL::ComPtr<IDXGIFactory2> dxgi_factory;
    if (FAILED(dxgi_device->GetAdapter(&dxgi_adapter)) || !dxgi_adapter ||
        FAILED(dxgi_adapter->GetParent(IID_PPV_ARGS(&dxgi_factory))) ||
        !dxgi_factory) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }

    Microsoft::WRL::ComPtr<IDCompositionDevice> dcomp_dev;
    if (FAILED(create_dcomp(dxgi_device.Get(), IID_PPV_ARGS(&dcomp_dev))) ||
        !dcomp_dev) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }

    Microsoft::WRL::ComPtr<IDCompositionTarget> dcomp_target;
    Microsoft::WRL::ComPtr<IDCompositionVisual> dcomp_visual;
    Microsoft::WRL::ComPtr<IDCompositionRectangleClip> dcomp_clip;
    // topmost = FALSE：DWM 将此视觉树合成于顶层窗口背景材质之上、所有子窗口（含 FLUTTERVIEW）之下。
    if (FAILED(dcomp_dev->CreateTargetForHwnd(parent_window_, FALSE,
                                              &dcomp_target)) ||
        FAILED(dcomp_dev->CreateVisual(&dcomp_visual)) ||
        FAILED(dcomp_dev->CreateRectangleClip(&dcomp_clip))) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }

    DXGI_SWAP_CHAIN_DESC1 sc_desc{};
    sc_desc.Width = static_cast<UINT>(target_width_);
    sc_desc.Height = static_cast<UINT>(target_height_);
    sc_desc.Format = swap_fmt;
    sc_desc.Stereo = FALSE;
    sc_desc.SampleDesc.Count = 1;
    sc_desc.SampleDesc.Quality = 0;
    sc_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sc_desc.BufferCount = static_cast<UINT>(kTripleBufferSlots);
    sc_desc.Scaling = DXGI_SCALING_STRETCH;
    sc_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sc_desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    sc_desc.Flags = 0;

    Microsoft::WRL::ComPtr<IDXGISwapChain1> swap_chain;
    if (FAILED(dxgi_factory->CreateSwapChainForComposition(
            device_.Get(), &sc_desc, nullptr, &swap_chain)) ||
        !swap_chain) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }

    // 为 10-bit / 16-bit 浮点翻转模型交换链声明精确色彩空间，防止 DWM 误判伽马。
    Microsoft::WRL::ComPtr<IDXGISwapChain3> swap_chain3;
    if (SUCCEEDED(swap_chain.As(&swap_chain3)) && swap_chain3) {
      const DXGI_COLOR_SPACE_TYPE cs =
          (swap_fmt == DXGI_FORMAT_R16G16B16A16_FLOAT)
              ? DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709
              : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
      UINT cs_support = 0;
      if (SUCCEEDED(swap_chain3->CheckColorSpaceSupport(cs, &cs_support)) &&
          (cs_support & DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT) !=
              0) {
        swap_chain3->SetColorSpace1(cs);
      }
    }

    if (FAILED(dcomp_visual->SetContent(swap_chain.Get())) ||
        FAILED(dcomp_target->SetRoot(nullptr)) ||
        FAILED(dcomp_dev->Commit())) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }

    mpv_d3d11_init_params d3d11_init{};
    d3d11_init.device = device_.Get();
    int advanced_control = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE,
         const_cast<char*>(MPV_RENDER_API_TYPE_D3D11)},
        {MPV_RENDER_PARAM_D3D11_INIT_PARAMS, &d3d11_init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced_control},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };

    mpv_render_context* ctx = nullptr;
    if (symbols_.create(&ctx, mpv_, params) < 0 || ctx == nullptr) {
      ReleaseD3D11ResourcesLocked();
      return false;
    }

    dcomp_hwnd_ = nullptr;
    dcomp_device_ = std::move(dcomp_dev);
    dcomp_target_ = std::move(dcomp_target);
    dcomp_visual_ = std::move(dcomp_visual);
    dcomp_clip_ = std::move(dcomp_clip);
    dcomp_swap_chain_ = std::move(swap_chain);
    dcomp_width_ = target_width_;
    dcomp_height_ = target_height_;
    active_fbo_format_.store(swap_fmt, std::memory_order_release);
    render_ctx_ = ctx;
    is_software_ = false;
    backend_mode_ = (swap_fmt == DXGI_FORMAT_R16G16B16A16_FLOAT)
                        ? BackendMode::kDirectCompositionFp16
                        : BackendMode::kDirectComposition10Bit;
    texture_id_ = -1;
    symbols_.set_update_callback(render_ctx_, &RenderSession::OnMpvUpdate, this);
    return true;
  }

  void ReleaseDirectCompositionResources() {
    {
      std::lock_guard<std::mutex> lock(dcomp_mutex_);
      if (dcomp_visual_) {
        dcomp_visual_->SetContent(nullptr);
      }
      if (dcomp_target_) {
        dcomp_target_->SetRoot(nullptr);
      }
      if (dcomp_device_) {
        dcomp_device_->Commit();
      }
      dcomp_swap_chain_.Reset();
      dcomp_clip_.Reset();
      dcomp_visual_.Reset();
      dcomp_target_.Reset();
      dcomp_device_.Reset();
    }
    if (dcomp_hwnd_ != nullptr) {
      if (IsWindow(dcomp_hwnd_)) {
        DestroyWindow(dcomp_hwnd_);
      }
      dcomp_hwnd_ = nullptr;
    }
  }

  bool InitializeSoftwareBackend() {
    int advanced_control = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_SW)},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced_control},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };

    mpv_render_context* ctx = nullptr;
    if (symbols_.create(&ctx, mpv_, params) < 0 || ctx == nullptr) {
      return false;
    }

    render_ctx_ = ctx;
    is_software_ = true;
    backend_mode_ = BackendMode::kSoftware;
    active_fbo_format_.store(DXGI_FORMAT_B8G8R8A8_UNORM,
                             std::memory_order_release);
    adapter_name_ = "Software Rasterizer (mpv sw)";
    RegisterSoftwareTexture();
    symbols_.set_update_callback(render_ctx_, &RenderSession::OnMpvUpdate, this);
    return texture_id_ >= 0;
  }

  void RegisterGpuTexture() {
    auto tex = std::make_unique<flutter::TextureVariant>(
        flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [this](size_t width,
                   size_t height) -> const FlutterDesktopGpuSurfaceDescriptor* {
              return ObtainGpuDescriptor(width, height);
            }));
    const int64_t new_id = registrar_->RegisterTexture(tex.get());
    texture_variant_ = std::move(tex);
    texture_id_ = new_id;
  }

  void RegisterSoftwareTexture() {
    auto tex = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture(
            [this](size_t width,
                   size_t height) -> const FlutterDesktopPixelBuffer* {
              return CopySoftwareBuffer(width, height);
            }));
    const int64_t new_id = registrar_->RegisterTexture(tex.get());
    texture_variant_ = std::move(tex);
    texture_id_ = new_id;
  }

  void UnregisterCurrentTexture() {
    if (texture_id_ < 0 || registrar_ == nullptr) {
      texture_variant_.reset();
      return;
    }
    const int64_t id_to_remove = texture_id_;
    texture_id_ = -1;
    // 通过 `std::shared_ptr` 延长渲染会话生命周期，直至 Flutter 光栅线程彻底释放纹理。
    std::shared_ptr<RenderSession> self_guard = shared_from_this();
    std::shared_ptr<flutter::TextureVariant> retired_variant(
        std::move(texture_variant_));
    registrar_->UnregisterTexture(
        id_to_remove,
        [self_guard, keep = std::move(retired_variant)]() mutable {
          keep.reset();
        });
  }

  const FlutterDesktopGpuSurfaceDescriptor* ObtainGpuDescriptor(size_t /*w*/,
                                                                size_t /*h*/) {
    std::lock_guard<std::mutex> lock(surface_mutex_);
    if (latest_slot_ < 0 ||
        static_cast<size_t>(latest_slot_) >= kTripleBufferSlots) {
      return nullptr;
    }
    const std::shared_ptr<TextureAllocation>& alloc = slots_[latest_slot_];
    if (!alloc || alloc->shared_handle == nullptr || alloc->width == 0 ||
        alloc->height == 0) {
      return nullptr;
    }
    alloc->pinned_count.fetch_add(1, std::memory_order_acq_rel);
    gpu_descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    gpu_descriptor_.handle = alloc->shared_handle;
    gpu_descriptor_.width = alloc->width;
    gpu_descriptor_.height = alloc->height;
    gpu_descriptor_.visible_width = alloc->width;
    gpu_descriptor_.visible_height = alloc->height;
    gpu_descriptor_.format = kFlutterDesktopPixelFormatBGRA8888;
    gpu_descriptor_.release_callback = &RenderSession::OnSurfaceReleased;
    gpu_descriptor_.release_context = alloc.get();
    return &gpu_descriptor_;
  }

  const FlutterDesktopPixelBuffer* CopySoftwareBuffer(size_t /*w*/,
                                                      size_t /*h*/) {
    std::lock_guard<std::mutex> lock(surface_mutex_);
    if (sw_front_width_ == 0 || sw_front_height_ == 0) {
      return nullptr;
    }
    const auto& buf = sw_buffers_[sw_front_index_];
    if (buf.size() < sw_front_width_ * sw_front_height_ * 4) {
      return nullptr;
    }
    sw_descriptor_.buffer = buf.data();
    sw_descriptor_.width = sw_front_width_;
    sw_descriptor_.height = sw_front_height_;
    sw_descriptor_.release_callback = nullptr;
    sw_descriptor_.release_context = nullptr;
    return &sw_descriptor_;
  }

  bool CreateSlotTextureLocked(size_t index, size_t width, size_t height) {
    std::shared_ptr<TextureAllocation>& slot = slots_[index];
    if (slot && slot->texture && slot->width == width &&
        slot->height == height) {
      return true;
    }
    if (slot) {
      if (slot->pinned_count.load(std::memory_order_acquire) > 0) {
        retired_textures_.push_back(slot);
      }
      slot.reset();
    }

    // Flutter ANGLE 外部共享纹理通道仅接受 32-bit BGRA 句柄；上游高色深运算已在
    // `DXGI_FORMAT_R16G16B16A16_FLOAT` / `R10G10B10A2_UNORM` FBO 完成，此处仅作为
    // 经 GPU 交错梯度噪声抖动解析后的零拷贝呈现槽。
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = static_cast<UINT>(width);
    desc.Height = static_cast<UINT>(height);
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = 0;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

    Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
    const HRESULT hr = device_->CreateTexture2D(&desc, nullptr, &tex);
    if (FAILED(hr) || !tex) {
      return false;
    }

    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> rtv;
    if (FAILED(device_->CreateRenderTargetView(tex.Get(), nullptr, &rtv)) ||
        !rtv) {
      return false;
    }

    Microsoft::WRL::ComPtr<IDXGIResource> dxgi_res;
    if (FAILED(tex.As(&dxgi_res)) || !dxgi_res) {
      return false;
    }
    HANDLE shared = nullptr;
    if (FAILED(dxgi_res->GetSharedHandle(&shared)) || shared == nullptr) {
      return false;
    }

    auto next_alloc = std::make_shared<TextureAllocation>();
    next_alloc->texture = std::move(tex);
    next_alloc->rtv = std::move(rtv);
    next_alloc->shared_handle = shared;
    next_alloc->width = width;
    next_alloc->height = height;
    slot = std::move(next_alloc);
    return true;
  }

  void PruneRetiredTexturesLocked() {
    auto it = retired_textures_.begin();
    while (it != retired_textures_.end()) {
      if (!(*it) || (*it)->pinned_count.load(std::memory_order_acquire) <= 0) {
        it = retired_textures_.erase(it);
      } else {
        ++it;
      }
    }
  }

  void ReleaseD3D11ResourcesLocked() {
    latest_slot_ = -1;
    for (auto& slot : slots_) {
      if (slot && slot->pinned_count.load(std::memory_order_acquire) > 0) {
        retired_textures_.push_back(slot);
      }
      slot.reset();
    }
    hdr_fbo_srv_.Reset();
    hdr_fbo_texture_.Reset();
    hdr_fbo_width_ = 0;
    hdr_fbo_height_ = 0;
    resolve_sampler_.Reset();
    resolve_ps_.Reset();
    resolve_vs_.Reset();
    context_.Reset();
    device_.Reset();
  }

  int AcquireWritableD3D11Slot(size_t width, size_t height) {
    std::lock_guard<std::mutex> lock(surface_mutex_);
    PruneRetiredTexturesLocked();
    // 视口缩小时（如全屏切入悬浮小窗）立刻释放其余未被占用的旧大尺寸纹理槽，避免旧全屏显存滞留。
    for (size_t i = 0; i < kTripleBufferSlots; ++i) {
      if (static_cast<int>(i) == latest_slot_) {
        continue;
      }
      auto& slot = slots_[i];
      if (slot && (slot->width != width || slot->height != height) &&
          slot->pinned_count.load(std::memory_order_acquire) <= 0) {
        slot.reset();
      }
    }
    // 自适应双缓冲：第 3 弹性槽一旦不再为最新呈现帧且已解钉，立刻释放回归双槽驻留，常态节省 33% 共享纹理显存。
    if (latest_slot_ != 2 && slots_[2] &&
        slots_[2]->pinned_count.load(std::memory_order_acquire) <= 0) {
      slots_[2].reset();
    }

    auto try_acquire = [&](int candidate) -> bool {
      if (!CreateSlotTextureLocked(static_cast<size_t>(candidate), width,
                                   height)) {
        return false;
      }
      write_cursor_ = static_cast<size_t>(candidate);
      return true;
    };

    // 优先在主双槽 [0, 1] 中选择非最新且未钉住的槽位，兼顾零撕裂与低显存。
    const int first_primary = (latest_slot_ == 0) ? 1 : 0;
    const std::array<int, kPrimaryBufferSlots> primaries = {
        first_primary,
        1 - first_primary,
    };
    for (int candidate : primaries) {
      const auto& alloc = slots_[candidate];
      const int pinned =
          alloc ? alloc->pinned_count.load(std::memory_order_acquire) : 0;
      if (candidate != latest_slot_ && pinned == 0) {
        return try_acquire(candidate) ? candidate : -1;
      }
    }

    // 主双槽同时被光栅线程钉住时按需临时启用第 3 弹性槽，保证高帧率零阻塞。
    {
      const auto& burst = slots_[2];
      const int burst_pinned =
          burst ? burst->pinned_count.load(std::memory_order_acquire) : 0;
      if (latest_slot_ != 2 && burst_pinned == 0) {
        return try_acquire(2) ? 2 : -1;
      }
    }

    // 兜底：若存在任何未钉住槽位则复用，否则轮转下一个非最新槽。
    for (int candidate = 0; candidate < static_cast<int>(kTripleBufferSlots);
         ++candidate) {
      const auto& alloc = slots_[candidate];
      const int pinned =
          alloc ? alloc->pinned_count.load(std::memory_order_acquire) : 0;
      if (pinned == 0) {
        return try_acquire(candidate) ? candidate : -1;
      }
    }
    const int fallback =
        static_cast<int>((write_cursor_ + 1) % kTripleBufferSlots);
    return try_acquire(fallback) ? fallback : -1;
  }

  void RenderThreadMain() {
    while (true) {
      size_t render_w = kMinSurfaceExtent;
      size_t render_h = kMinSurfaceExtent;
      bool force_draw = false;
      bool stop_now = false;
      bool apply_hdr_fbo_change = false;
      DXGI_FORMAT desired_hdr_fbo_fmt = DXGI_FORMAT_R10G10B10A2_UNORM;

      {
        std::unique_lock<std::mutex> lock(render_mutex_);
        render_cv_.wait(lock, [this]() {
          return stop_requested_ || render_requested_ || resize_requested_ ||
                 pending_hdr_fbo_change_;
        });
        if (stop_requested_) {
          stop_now = true;
        } else {
          render_requested_ = false;
          resize_requested_ = false;
          force_draw = force_render_;
          force_render_ = false;
          if (pending_hdr_fbo_change_) {
            apply_hdr_fbo_change = true;
            desired_hdr_fbo_fmt = pending_hdr_fbo_format_;
            pending_hdr_fbo_change_ = false;
          }
          render_w = target_width_;
          render_h = target_height_;
        }
      }

      if (stop_now) {
        break;
      }

      if (render_ctx_ == nullptr) {
        continue;
      }

      if (apply_hdr_fbo_change && !is_software_ && !IsDirectCompositionMode()) {
        if (desired_hdr_fbo_fmt !=
            active_fbo_format_.load(std::memory_order_acquire)) {
          std::lock_guard<std::mutex> lock(surface_mutex_);
          active_fbo_format_.store(desired_hdr_fbo_fmt,
                                   std::memory_order_release);
          hdr_fbo_srv_.Reset();
          hdr_fbo_texture_.Reset();
          hdr_fbo_width_ = 0;
          hdr_fbo_height_ = 0;
        }
      }

      const uint64_t update_flags = symbols_.update(render_ctx_);
      const bool should_render =
          ((update_flags & MPV_RENDER_UPDATE_FRAME) != 0) || force_draw;
      if (!should_render) {
        continue;
      }

      const auto t0 = std::chrono::steady_clock::now();
      bool rendered_ok = false;
      if (is_software_) {
        RenderSoftwareFrame(render_w, render_h);
        rendered_ok = true;
      } else if (IsDirectCompositionMode()) {
        rendered_ok = RenderDirectCompositionFrame(render_w, render_h);
        if (!rendered_ok) {
          RecoverOrFallbackFromD3D11Failure(render_w, render_h);
        }
      } else {
        rendered_ok = RenderD3D11Frame(render_w, render_h);
        if (!rendered_ok) {
          RecoverOrFallbackFromD3D11Failure(render_w, render_h);
        }
      }
      if (rendered_ok) {
        const auto dt = std::chrono::duration_cast<std::chrono::microseconds>(
                            std::chrono::steady_clock::now() - t0)
                            .count();
        RecordFrameRenderMicros(static_cast<int64_t>(dt));
      }
    }
  }

  bool RenderDirectCompositionFrame(size_t width, size_t height) {
    if (!device_ || !context_) {
      return false;
    }
    Microsoft::WRL::ComPtr<IDXGISwapChain1> sc;
    {
      std::lock_guard<std::mutex> lock(dcomp_mutex_);
      sc = dcomp_swap_chain_;
    }
    if (!sc) {
      return false;
    }
    if (dcomp_width_ != width || dcomp_height_ != height) {
      context_->ClearState();
      context_->Flush();
      const HRESULT rhr = sc->ResizeBuffers(
          static_cast<UINT>(kTripleBufferSlots), static_cast<UINT>(width),
          static_cast<UINT>(height),
          active_fbo_format_.load(std::memory_order_acquire), 0);
      if (FAILED(rhr)) {
        return false;
      }
      dcomp_width_ = width;
      dcomp_height_ = height;
    }

    Microsoft::WRL::ComPtr<ID3D11Texture2D> back_buffer;
    if (FAILED(sc->GetBuffer(0, IID_PPV_ARGS(&back_buffer))) || !back_buffer) {
      return false;
    }

    // 严格遵守 mpv D3D11 渲染契约：每次进入 mpv 渲染前重置管线默认状态。
    context_->ClearState();
    mpv_d3d11_fbo fbo{};
    fbo.tex = back_buffer.Get();
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_D3D11_FBO, &fbo},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    const int rc = symbols_.render(render_ctx_, params);
    if (rc < 0) {
      return false;
    }
    const HRESULT phr = sc->Present(0, 0);
    if (FAILED(phr)) {
      return false;
    }
    symbols_.report_swap(render_ctx_);
    return true;
  }

  void ResolveHighBitDepthToSharedSlot(ID3D11RenderTargetView* dst_rtv,
                                       size_t width,
                                       size_t height) {
    D3D11_VIEWPORT vp{};
    vp.TopLeftX = 0.0f;
    vp.TopLeftY = 0.0f;
    vp.Width = static_cast<FLOAT>(width);
    vp.Height = static_cast<FLOAT>(height);
    vp.MinDepth = 0.0f;
    vp.MaxDepth = 1.0f;

    // 仅重置解析全屏三角形所需的最小管线槽位，省去每帧额外的 2 次全上下文 ClearState 缓存失效。
    context_->RSSetViewports(1, &vp);
    context_->RSSetState(nullptr);
    context_->OMSetDepthStencilState(nullptr, 0);
    context_->OMSetBlendState(nullptr, nullptr, 0xFFFFFFFFu);
    context_->OMSetRenderTargets(1, &dst_rtv, nullptr);
    context_->IASetInputLayout(nullptr);
    context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context_->VSSetShader(resolve_vs_.Get(), nullptr, 0);
    context_->PSSetShader(resolve_ps_.Get(), nullptr, 0);
    context_->GSSetShader(nullptr, nullptr, 0);
    ID3D11ShaderResourceView* srv = hdr_fbo_srv_.Get();
    ID3D11SamplerState* samp = resolve_sampler_.Get();
    context_->PSSetShaderResources(0, 1, &srv);
    context_->PSSetSamplers(0, 1, &samp);
    context_->Draw(3, 0);
    // 立刻解绑着色器资源与渲染目标，避免下一帧 mpv 写入同一 FP16 纹理触发读写冲突。
    ID3D11ShaderResourceView* null_srv = nullptr;
    ID3D11RenderTargetView* null_rtv = nullptr;
    context_->PSSetShaderResources(0, 1, &null_srv);
    context_->OMSetRenderTargets(1, &null_rtv, nullptr);
  }

  bool RenderD3D11Frame(size_t width, size_t height) {
    if (!device_ || !context_) {
      return false;
    }

    const int slot_index = AcquireWritableD3D11Slot(width, height);
    if (slot_index < 0) {
      return false;
    }

    Microsoft::WRL::ComPtr<ID3D11Texture2D> shared_target;
    Microsoft::WRL::ComPtr<ID3D11RenderTargetView> shared_rtv;
    {
      std::lock_guard<std::mutex> lock(surface_mutex_);
      if (slots_[slot_index]) {
        shared_target = slots_[slot_index]->texture;
        shared_rtv = slots_[slot_index]->rtv;
      }
    }
    if (!shared_target || !shared_rtv) {
      return false;
    }

    const bool use_high_bit_fbo =
        active_fbo_format_.load(std::memory_order_acquire) !=
            DXGI_FORMAT_B8G8R8A8_UNORM &&
        resolve_vs_ && resolve_ps_ && resolve_sampler_;
    ID3D11Texture2D* mpv_target = shared_target.Get();
    if (use_high_bit_fbo) {
      if (!EnsureHighBitDepthFboLocked(width, height)) {
        return false;
      }
      mpv_target = hdr_fbo_texture_.Get();
    }

    context_->ClearState();
    mpv_d3d11_fbo fbo{};
    fbo.tex = mpv_target;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_D3D11_FBO, &fbo},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };

    const int rc = symbols_.render(render_ctx_, params);
    if (rc < 0) {
      return false;
    }

    if (use_high_bit_fbo) {
      ResolveHighBitDepthToSharedSlot(shared_rtv.Get(), width, height);
    }
    context_->Flush();

    {
      std::lock_guard<std::mutex> lock(surface_mutex_);
      latest_slot_ = slot_index;
    }
    if (texture_id_ >= 0) {
      registrar_->MarkTextureFrameAvailable(texture_id_);
    }
    symbols_.report_swap(render_ctx_);
    return true;
  }

  void RenderSoftwareFrame(size_t width, size_t height) {
    const size_t back_idx = (sw_front_index_ + 1) % 2;
    const size_t stride = width * 4;
    auto& back_buf = sw_buffers_[back_idx];
    back_buf.resize(stride * height);

    int size_arr[2] = {static_cast<int>(width), static_cast<int>(height)};
    size_t stride_val = stride;
    char format_rgba[] = "rgba";
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_SW_SIZE, size_arr},
        {MPV_RENDER_PARAM_SW_FORMAT, format_rgba},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride_val},
        {MPV_RENDER_PARAM_SW_POINTER, back_buf.data()},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };

    int rc = symbols_.render(render_ctx_, params);
    if (rc < 0) {
      char format_rgb0[] = "rgb0";
      params[1].data = format_rgb0;
      rc = symbols_.render(render_ctx_, params);
      if (rc >= 0) {
        const size_t total = back_buf.size();
        for (size_t i = 3; i < total; i += 4) {
          back_buf[i] = 0xFF;
        }
      }
    }
    if (rc < 0) {
      return;
    }

    {
      std::lock_guard<std::mutex> lock(surface_mutex_);
      sw_front_index_ = back_idx;
      sw_front_width_ = width;
      sw_front_height_ = height;
    }
    if (texture_id_ >= 0) {
      registrar_->MarkTextureFrameAvailable(texture_id_);
    }
    symbols_.report_swap(render_ctx_);
  }

  void RecoverOrFallbackFromD3D11Failure(size_t width, size_t height) {
    if (render_ctx_ != nullptr) {
      symbols_.set_update_callback(render_ctx_, nullptr, nullptr);
      symbols_.free(render_ctx_);
      render_ctx_ = nullptr;
    }

    const bool was_dcomp = IsDirectCompositionMode();
    if (was_dcomp) {
      std::lock_guard<std::mutex> lock(dcomp_mutex_);
      if (dcomp_visual_) {
        dcomp_visual_->SetContent(nullptr);
      }
      dcomp_swap_chain_.Reset();
    }

    {
      std::lock_guard<std::mutex> lock(surface_mutex_);
      ReleaseD3D11ResourcesLocked();
    }

    // 恢复方案 1：原地重建高色深 D3D11 共享纹理管线。
    if (!d3d11_recovery_attempted_) {
      d3d11_recovery_attempted_ = true;
      if (InitializeD3D11HighBitDepthBackend(true)) {
        if (RenderD3D11Frame(width, height)) {
          if (was_dcomp && on_texture_changed_) {
            on_texture_changed_(session_id_, texture_id_, backend(),
                                surface_format(), color_bit_depth(),
                                adapter_name_, "DCOMP_FALLBACK_TO_D3D11_10BIT");
          }
          return;
        }
        if (render_ctx_ != nullptr) {
          symbols_.set_update_callback(render_ctx_, nullptr, nullptr);
          symbols_.free(render_ctx_);
          render_ctx_ = nullptr;
        }
        std::lock_guard<std::mutex> lock(surface_mutex_);
        ReleaseD3D11ResourcesLocked();
      }
    }

    // 恢复方案 2：透明回退至软件像素缓冲纹理，并通知 Dart 侧绑定全新 `textureId`。
    UnregisterCurrentTexture();
    if (InitializeSoftwareBackend()) {
      RenderSoftwareFrame(width, height);
      if (on_texture_changed_) {
        on_texture_changed_(session_id_, texture_id_, "sw", "SW_RGBA8888", 8,
                            adapter_name_, "DXGI_DEVICE_LOST_FALLBACK");
      }
    }
  }

  const int64_t session_id_;
  HWND const parent_window_;
  mpv_handle* const mpv_;
  const MpvRenderSymbols symbols_;
  flutter::FlutterEngine* const engine_;
  flutter::TextureRegistrar* const registrar_;
  TextureChangedCallback on_texture_changed_;
  DeviceAcquirer acquire_device_;
  DeviceRecycler recycle_device_;

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> hdr_fbo_texture_;
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> hdr_fbo_srv_;
  Microsoft::WRL::ComPtr<ID3D11VertexShader> resolve_vs_;
  Microsoft::WRL::ComPtr<ID3D11PixelShader> resolve_ps_;
  Microsoft::WRL::ComPtr<ID3D11SamplerState> resolve_sampler_;
  size_t hdr_fbo_width_ = 0;
  size_t hdr_fbo_height_ = 0;
  DXGI_FORMAT hdr_fbo_format_ = DXGI_FORMAT_B8G8R8A8_UNORM;
  std::atomic<DXGI_FORMAT> active_fbo_format_{DXGI_FORMAT_B8G8R8A8_UNORM};
  BackendMode backend_mode_ = BackendMode::kD3D11HighBitDepth;

  std::mutex dcomp_mutex_;
  HWND dcomp_hwnd_ = nullptr;
  Microsoft::WRL::ComPtr<IDCompositionDevice> dcomp_device_;
  Microsoft::WRL::ComPtr<IDCompositionTarget> dcomp_target_;
  Microsoft::WRL::ComPtr<IDCompositionVisual> dcomp_visual_;
  Microsoft::WRL::ComPtr<IDCompositionRectangleClip> dcomp_clip_;
  Microsoft::WRL::ComPtr<IDXGISwapChain1> dcomp_swap_chain_;
  size_t dcomp_width_ = 0;
  size_t dcomp_height_ = 0;

  mpv_render_context* render_ctx_ = nullptr;
  std::unique_ptr<flutter::TextureVariant> texture_variant_;

  std::mutex surface_mutex_;
  std::array<std::shared_ptr<TextureAllocation>, kTripleBufferSlots> slots_{};
  std::vector<std::shared_ptr<TextureAllocation>> retired_textures_;
  FlutterDesktopGpuSurfaceDescriptor gpu_descriptor_{};
  int latest_slot_ = -1;
  size_t write_cursor_ = 0;

  std::array<std::vector<uint8_t>, 2> sw_buffers_{};
  FlutterDesktopPixelBuffer sw_descriptor_{};
  size_t sw_front_index_ = 0;
  size_t sw_front_width_ = 0;
  size_t sw_front_height_ = 0;

  std::mutex metrics_mutex_;
  int64_t total_rendered_frames_ = 0;
  std::vector<int64_t> render_durations_us_;
  size_t metrics_cursor_ = 0;

  std::mutex render_mutex_;
  std::condition_variable render_cv_;
  std::thread render_thread_;
  size_t target_width_ = kMinSurfaceExtent;
  size_t target_height_ = kMinSurfaceExtent;
  bool render_requested_ = true;
  bool resize_requested_ = false;
  bool force_render_ = true;
  bool pending_hdr_fbo_change_ = false;
  DXGI_FORMAT pending_hdr_fbo_format_ = DXGI_FORMAT_R10G10B10A2_UNORM;
  bool stop_requested_ = false;
  bool disposed_ = false;
  bool is_software_ = false;
  bool d3d11_recovery_attempted_ = false;

  int64_t texture_id_ = -1;
  std::string adapter_name_;
};

D3D11TextureBridge::D3D11TextureBridge(
    HWND window_handle,
    flutter::FlutterEngine* engine,
    flutter::PluginRegistrarWindows* registrar)
    : window_handle_(window_handle), engine_(engine), registrar_(registrar) {
  if (registrar_ == nullptr) {
    return;
  }
  texture_registrar_ = registrar_->texture_registrar();
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar_->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) { HandleMethodCall(call, std::move(result)); });
}

D3D11TextureBridge::~D3D11TextureBridge() { Shutdown(); }

void D3D11TextureBridge::Shutdown() {
  std::unordered_map<int64_t, std::shared_ptr<RenderSession>> to_dispose;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      return;
    }
    shutdown_called_ = true;
    to_dispose.swap(sessions_);
    pending_notifications_.clear();
  }

  for (auto& kv : to_dispose) {
    if (kv.second) {
      kv.second->Dispose();
    }
  }
  ClearCachedD3D11Device(true);
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_.reset();
  }
}

bool D3D11TextureBridge::AcquireReusableD3D11Device(
    Microsoft::WRL::ComPtr<ID3D11Device>* out_device,
    Microsoft::WRL::ComPtr<ID3D11DeviceContext>* out_context,
    std::string* out_adapter_name) {
  Microsoft::WRL::ComPtr<ID3D11Device> dev;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
  std::string adapter;
  HANDLE old_timer = nullptr;
  {
    std::lock_guard<std::mutex> lock(device_cache_mutex_);
    old_timer = idle_device_timer_;
    idle_device_timer_ = nullptr;
    dev = std::move(cached_device_);
    ctx = std::move(cached_context_);
    adapter = std::move(cached_adapter_name_);
    cached_adapter_name_.clear();
  }
  if (old_timer != nullptr) {
    DeleteTimerQueueTimer(nullptr, old_timer, nullptr);
  }
  if (dev && ctx && SUCCEEDED(dev->GetDeviceRemovedReason())) {
    *out_device = std::move(dev);
    *out_context = std::move(ctx);
    if (out_adapter_name != nullptr) {
      *out_adapter_name = std::move(adapter);
    }
    return true;
  }
  return CreateD3D11Device(engine_, out_device, out_context, out_adapter_name);
}

void D3D11TextureBridge::RecycleD3D11Device(
    Microsoft::WRL::ComPtr<ID3D11Device> device,
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context,
    std::string adapter_name) {
  if (!device || !context || FAILED(device->GetDeviceRemovedReason())) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      return;
    }
  }
  context->ClearState();
  context->Flush();
  TrimDxgiDevice(device.Get());

  HANDLE old_timer = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Device> displaced_device;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> displaced_context;
  {
    std::lock_guard<std::mutex> lock(device_cache_mutex_);
    old_timer = idle_device_timer_;
    idle_device_timer_ = nullptr;
    displaced_device = std::move(cached_device_);
    displaced_context = std::move(cached_context_);
    cached_device_ = std::move(device);
    cached_context_ = std::move(context);
    cached_adapter_name_ = std::move(adapter_name);
    cached_device_at_ = std::chrono::steady_clock::now();
    CreateTimerQueueTimer(&idle_device_timer_, nullptr,
                          &D3D11TextureBridge::OnIdleDeviceTimerCallback, this,
                          kIdleD3D11DeviceTtlMs, 0, WT_EXECUTEONLYONCE);
  }
  if (old_timer != nullptr) {
    DeleteTimerQueueTimer(nullptr, old_timer, nullptr);
  }
  if (displaced_device) {
    TrimDxgiDevice(displaced_device.Get());
  }
}

void D3D11TextureBridge::ClearCachedD3D11Device(bool wait_for_timer) {
  HANDLE old_timer = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Device> dev;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
  {
    std::lock_guard<std::mutex> lock(device_cache_mutex_);
    old_timer = idle_device_timer_;
    idle_device_timer_ = nullptr;
    dev = std::move(cached_device_);
    ctx = std::move(cached_context_);
    cached_adapter_name_.clear();
  }
  if (old_timer != nullptr) {
    DeleteTimerQueueTimer(nullptr, old_timer,
                          wait_for_timer ? INVALID_HANDLE_VALUE : nullptr);
  }
  if (dev) {
    TrimDxgiDevice(dev.Get());
  }
}

VOID CALLBACK D3D11TextureBridge::OnIdleDeviceTimerCallback(
    PVOID param,
    BOOLEAN /*timer_or_wait_fired*/) {
  auto* self = static_cast<D3D11TextureBridge*>(param);
  if (self == nullptr) {
    return;
  }
  Microsoft::WRL::ComPtr<ID3D11Device> expired_dev;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> expired_ctx;
  {
    std::lock_guard<std::mutex> lock(self->device_cache_mutex_);
    if (!self->cached_device_) {
      return;
    }
    const auto elapsed_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - self->cached_device_at_)
            .count();
    if (elapsed_ms + 1000 < static_cast<int64_t>(kIdleD3D11DeviceTtlMs)) {
      return;
    }
    expired_dev = std::move(self->cached_device_);
    expired_ctx = std::move(self->cached_context_);
    self->cached_adapter_name_.clear();
  }
  if (expired_dev) {
    TrimDxgiDevice(expired_dev.Get());
  }
}

void D3D11TextureBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "getAdapterInfo") {
    HandleGetAdapterInfo(std::move(result));
    return;
  }
  if (call.method_name() == "trimMemory") {
    const auto* opt_args =
        call.arguments()
            ? std::get_if<flutter::EncodableMap>(call.arguments())
            : nullptr;
    HandleTrimMemory(opt_args, std::move(result));
    return;
  }

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error("INVALID_ARGS", "参数必须为 Map 映射结构");
    return;
  }

  if (call.method_name() == "createSession") {
    HandleCreateSession(*args, std::move(result));
  } else if (call.method_name() == "resize") {
    HandleResize(*args, std::move(result));
  } else if (call.method_name() == "setViewportRect") {
    HandleSetViewportRect(*args, std::move(result));
  } else if (call.method_name() == "getSessionMetrics") {
    HandleGetSessionMetrics(*args, std::move(result));
  } else if (call.method_name() == "setHdrFboEnabled") {
    HandleSetHdrFboEnabled(*args, std::move(result));
  } else if (call.method_name() == "disposeSession") {
    HandleDisposeSession(*args, std::move(result));
  } else {
    result->NotImplemented();
  }
}

void D3D11TextureBridge::HandleCreateSession(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (texture_registrar_ == nullptr) {
    result->Error("NO_TEXTURE_REGISTRAR", "纹理注册器不可用");
    return;
  }

  const size_t width = ClampExtent(ReadInt64Arg(args, "width", 1280));
  const size_t height = ClampExtent(ReadInt64Arg(args, "height", 720));
  const bool prefer_software = ReadBoolArg(args, "preferSoftware", false);
  const std::string requested_backend =
      ReadStringArg(args, "renderBackend", "gpu_next");

  const int64_t mpv_ptr_val = ReadInt64Arg(args, "mpvHandle", 0);
  const bool is_gpu_next_underlay =
      !prefer_software && requested_backend == "gpu_next";

  MpvRenderSymbols symbols{};
  if (!is_gpu_next_underlay) {
    if (mpv_ptr_val == 0) {
      result->Error("INVALID_MPV_HANDLE", "mpvHandle 必须为非零有效句柄");
      return;
    }
    if (!LoadMpvRenderSymbols(&symbols)) {
      result->Error("LIBMPV_LOAD_FAILED",
                    "无法从 libmpv-2.dll 解析 mpv_render_context 符号");
      return;
    }
  }

  int64_t session_id = 0;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      result->Error("BRIDGE_SHUTDOWN", "D3D11 视频桥接器正在关闭");
      return;
    }
    session_id = next_session_id_++;
  }

  auto* mpv = reinterpret_cast<mpv_handle*>(static_cast<uintptr_t>(mpv_ptr_val));
  auto session = std::make_shared<RenderSession>(
      session_id, window_handle_, mpv, symbols, engine_, texture_registrar_,
      width, height,
      [this](int64_t sid, int64_t tid, const std::string& backend,
             const std::string& surface_format, int64_t color_bit_depth,
             const std::string& adapter, const std::string& reason) {
        QueueTextureChanged(sid, tid, backend, surface_format, color_bit_depth,
                            adapter, reason);
      },
      [this](Microsoft::WRL::ComPtr<ID3D11Device>* out_dev,
             Microsoft::WRL::ComPtr<ID3D11DeviceContext>* out_ctx,
             std::string* out_adapter) {
        return AcquireReusableD3D11Device(out_dev, out_ctx, out_adapter);
      },
      [this](Microsoft::WRL::ComPtr<ID3D11Device> dev,
             Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx,
             std::string adapter) {
        RecycleD3D11Device(std::move(dev), std::move(ctx), std::move(adapter));
      });

  std::string err;
  if (!session->Initialize(prefer_software, requested_backend, &err)) {
    session->Dispose();
    result->Error("RENDER_INIT_FAILED", err);
    return;
  }

  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      session->Dispose();
      result->Error("BRIDGE_SHUTDOWN", "D3D11 视频桥接器正在关闭");
      return;
    }
    sessions_.emplace(session_id, session);
  }

  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("sessionId")] =
      flutter::EncodableValue(session->session_id());
  payload[flutter::EncodableValue("textureId")] =
      flutter::EncodableValue(session->texture_id());
  payload[flutter::EncodableValue("backend")] =
      flutter::EncodableValue(session->backend());
  payload[flutter::EncodableValue("surfaceFormat")] =
      flutter::EncodableValue(session->surface_format());
  payload[flutter::EncodableValue("colorBitDepth")] =
      flutter::EncodableValue(session->color_bit_depth());
  payload[flutter::EncodableValue("dcompActive")] =
      flutter::EncodableValue(session->IsDirectCompositionMode());
  payload[flutter::EncodableValue("nativeWindowHandle")] =
      flutter::EncodableValue(session->native_window_handle());
  payload[flutter::EncodableValue("adapterName")] =
      flutter::EncodableValue(session->adapter_name());
  result->Success(flutter::EncodableValue(payload));
}

void D3D11TextureBridge::HandleResize(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const int64_t session_id = ReadInt64Arg(args, "sessionId", 0);
  const size_t width = ClampExtent(ReadInt64Arg(args, "width", 1280));
  const size_t height = ClampExtent(ReadInt64Arg(args, "height", 720));

  std::shared_ptr<RenderSession> session;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    auto it = sessions_.find(session_id);
    if (it != sessions_.end()) {
      session = it->second;
    }
  }
  if (!session) {
    result->Error("SESSION_NOT_FOUND", "未找到对应视频渲染会话");
    return;
  }
  session->Resize(width, height);
  result->Success();
}

void D3D11TextureBridge::HandleSetViewportRect(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const int64_t session_id = ReadInt64Arg(args, "sessionId", 0);
  const int left_px = static_cast<int>(ReadInt64Arg(args, "leftPx", 0));
  const int top_px = static_cast<int>(ReadInt64Arg(args, "topPx", 0));
  const int right_px = static_cast<int>(ReadInt64Arg(args, "rightPx", 0));
  const int bottom_px = static_cast<int>(ReadInt64Arg(args, "bottomPx", 0));
  const float radius_px =
      static_cast<float>(ReadDoubleArg(args, "cornerRadiusPx", 0.0));
  const bool visible = ReadBoolArg(args, "visible", true);

  std::shared_ptr<RenderSession> session;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    auto it = sessions_.find(session_id);
    if (it != sessions_.end()) {
      session = it->second;
    }
  }
  if (!session) {
    result->Error("SESSION_NOT_FOUND", "未找到对应视频渲染会话");
    return;
  }
  session->SetViewportRectOnUiThread(left_px, top_px, right_px, bottom_px,
                                     radius_px, visible);
  result->Success();
}

void D3D11TextureBridge::HandleGetSessionMetrics(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const int64_t session_id = ReadInt64Arg(args, "sessionId", 0);
  std::shared_ptr<RenderSession> session;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    auto it = sessions_.find(session_id);
    if (it != sessions_.end()) {
      session = it->second;
    }
  }
  if (!session) {
    result->Error("SESSION_NOT_FOUND", "未找到对应视频渲染会话");
    return;
  }
  const auto m = session->CollectMetrics();
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("renderedFrames")] =
      flutter::EncodableValue(m.rendered_frames);
  payload[flutter::EncodableValue("renderP50Us")] =
      flutter::EncodableValue(m.render_p50_us);
  payload[flutter::EncodableValue("renderP99Us")] =
      flutter::EncodableValue(m.render_p99_us);
  payload[flutter::EncodableValue("renderAvgUs")] =
      flutter::EncodableValue(m.render_avg_us);
  payload[flutter::EncodableValue("backend")] =
      flutter::EncodableValue(m.backend);
  payload[flutter::EncodableValue("surfaceFormat")] =
      flutter::EncodableValue(m.surface_format);
  payload[flutter::EncodableValue("colorBitDepth")] =
      flutter::EncodableValue(m.color_bit_depth);
  payload[flutter::EncodableValue("dcompActive")] =
      flutter::EncodableValue(m.dcomp_active);
  result->Success(flutter::EncodableValue(payload));
}

void D3D11TextureBridge::HandleSetHdrFboEnabled(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const int64_t session_id = ReadInt64Arg(args, "sessionId", 0);
  const bool enabled = ReadBoolArg(args, "enabled", false);

  std::shared_ptr<RenderSession> session;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    auto it = sessions_.find(session_id);
    if (it != sessions_.end()) {
      session = it->second;
    }
  }
  if (!session) {
    result->Success(flutter::EncodableValue(false));
    return;
  }
  const bool scheduled = session->SetHdrFboEnabled(enabled);
  result->Success(flutter::EncodableValue(scheduled));
}

void D3D11TextureBridge::HandleDisposeSession(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const int64_t session_id = ReadInt64Arg(args, "sessionId", 0);
  std::shared_ptr<RenderSession> session;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    auto it = sessions_.find(session_id);
    if (it != sessions_.end()) {
      session = std::move(it->second);
      sessions_.erase(it);
    }
  }
  if (session) {
    session->Dispose();
  }
  result->Success();
}

void D3D11TextureBridge::HandleGetAdapterInfo(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Microsoft::WRL::ComPtr<ID3D11Device> dev;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
  std::string adapter_name;
  const bool ok = AcquireReusableD3D11Device(&dev, &ctx, &adapter_name);
  const bool supports_fp16 =
      ok && SupportsRenderTargetAndShaderResource(
                dev.Get(), DXGI_FORMAT_R16G16B16A16_FLOAT);
  const bool supports_10bit =
      ok && SupportsRenderTargetAndShaderResource(
                dev.Get(), DXGI_FORMAT_R10G10B10A2_UNORM);
  const bool supports_dcomp_10bit =
      ok && ResolveDCompositionCreateDevice() != nullptr &&
      SupportsDisplaySwapChainFormat(dev.Get(), DXGI_FORMAT_R10G10B10A2_UNORM);
  if (ok) {
    RecycleD3D11Device(std::move(dev), std::move(ctx), adapter_name);
  }

  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("available")] = flutter::EncodableValue(ok);
  payload[flutter::EncodableValue("adapterName")] =
      flutter::EncodableValue(adapter_name);
  payload[flutter::EncodableValue("supportsFp16")] =
      flutter::EncodableValue(supports_fp16);
  payload[flutter::EncodableValue("supports10Bit")] =
      flutter::EncodableValue(supports_10bit);
  payload[flutter::EncodableValue("supportsDcomp10Bit")] =
      flutter::EncodableValue(supports_dcomp_10bit);
  result->Success(flutter::EncodableValue(payload));
}

void D3D11TextureBridge::HandleTrimMemory(
    const flutter::EncodableMap* args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const bool release_idle_device =
      args != nullptr ? ReadBoolArg(*args, "releaseIdleDevice", false) : false;
  const bool trim_working_set =
      args != nullptr ? ReadBoolArg(*args, "trimWorkingSet", true) : true;

  if (release_idle_device) {
    ClearCachedD3D11Device(false);
  } else {
    Microsoft::WRL::ComPtr<ID3D11Device> cached_ref;
    {
      std::lock_guard<std::mutex> lock(device_cache_mutex_);
      cached_ref = cached_device_;
    }
    if (cached_ref) {
      TrimDxgiDevice(cached_ref.Get());
    }
  }

  if (trim_working_set) {
    SetProcessWorkingSetSizeEx(GetCurrentProcess(), static_cast<SIZE_T>(-1),
                               static_cast<SIZE_T>(-1), 0);
  }
  result->Success();
}

void D3D11TextureBridge::TrimMemoryOnMinimize() {
  bool has_active_sessions = false;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      return;
    }
    has_active_sessions = !sessions_.empty();
  }
  if (has_active_sessions) {
    return;
  }
  ClearCachedD3D11Device(false);
  SetProcessWorkingSetSizeEx(GetCurrentProcess(), static_cast<SIZE_T>(-1),
                             static_cast<SIZE_T>(-1), 0);
}

void D3D11TextureBridge::QueueTextureChanged(int64_t session_id,
                                             int64_t texture_id,
                                             const std::string& backend,
                                             const std::string& surface_format,
                                             int64_t color_bit_depth,
                                             const std::string& adapter_name,
                                             const std::string& reason) {
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      return;
    }
    pending_notifications_.push_back({session_id, texture_id, backend,
                                      surface_format, color_bit_depth,
                                      adapter_name, reason});
  }
  if (window_handle_ != nullptr && IsWindow(window_handle_)) {
    PostMessageW(window_handle_, kNotifyWindowMessage, 0, 0);
  }
}

void D3D11TextureBridge::ProcessPendingNotifications() {
  std::vector<PendingNotification> queued;
  flutter::MethodChannel<flutter::EncodableValue>* channel_ptr = nullptr;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_ || !channel_ || pending_notifications_.empty()) {
      return;
    }
    queued.swap(pending_notifications_);
    channel_ptr = channel_.get();
  }

  for (const auto& item : queued) {
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("sessionId")] =
        flutter::EncodableValue(item.session_id);
    payload[flutter::EncodableValue("textureId")] =
        flutter::EncodableValue(item.texture_id);
    payload[flutter::EncodableValue("backend")] =
        flutter::EncodableValue(item.backend);
    payload[flutter::EncodableValue("surfaceFormat")] =
        flutter::EncodableValue(item.surface_format);
    payload[flutter::EncodableValue("colorBitDepth")] =
        flutter::EncodableValue(item.color_bit_depth);
    payload[flutter::EncodableValue("adapterName")] =
        flutter::EncodableValue(item.adapter_name);
    payload[flutter::EncodableValue("reason")] =
        flutter::EncodableValue(item.reason);
    channel_ptr->InvokeMethod(
        "onTextureChanged",
        std::make_unique<flutter::EncodableValue>(std::move(payload)));
  }
}
