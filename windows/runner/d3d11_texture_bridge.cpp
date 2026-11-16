#include "d3d11_texture_bridge.h"

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_d3d11.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr char kChannelName[] = "konata/d3d11_video";
constexpr size_t kMinSurfaceExtent = 2;
constexpr size_t kMaxSurfaceExtent = 8192;
constexpr size_t kTripleBufferSlots = 3;

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

  // Never pass D3D11_CREATE_DEVICE_SINGLETHREADED so mpv d3d11va decoder threads
  // can operate safely with multithread protection enabled. Prefer
  // D3D11_CREATE_DEVICE_VIDEO_SUPPORT for zero-copy d3d11va, falling back if a
  // driver refuses video-device creation.
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
    *out_adapter_name = "Direct3D 11 Hardware";
    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
    if (SUCCEEDED((*out_device).As(&dxgi_device)) && dxgi_device) {
      Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
      if (SUCCEEDED(dxgi_device->GetAdapter(&adapter)) && adapter) {
        DXGI_ADAPTER_DESC desc{};
        if (SUCCEEDED(adapter->GetDesc(&desc))) {
          const std::string utf8 = WideToUtf8(desc.Description);
          if (!utf8.empty()) {
            *out_adapter_name = utf8;
          }
        }
      }
    }
  }
  return true;
}

}  // namespace

class D3D11TextureBridge::RenderSession
    : public std::enable_shared_from_this<RenderSession> {
 public:
  using TextureChangedCallback =
      std::function<void(int64_t session_id,
                         int64_t texture_id,
                         const std::string& backend,
                         const std::string& adapter_name,
                         const std::string& reason)>;

  RenderSession(int64_t session_id,
                mpv_handle* mpv,
                MpvRenderSymbols symbols,
                flutter::FlutterEngine* engine,
                flutter::TextureRegistrar* registrar,
                size_t width,
                size_t height,
                TextureChangedCallback on_texture_changed)
      : session_id_(session_id),
        mpv_(mpv),
        symbols_(symbols),
        engine_(engine),
        registrar_(registrar),
        on_texture_changed_(std::move(on_texture_changed)),
        target_width_(width),
        target_height_(height) {}

  bool Initialize(bool prefer_software, std::string* error_message) {
    bool initialized = false;
    if (!prefer_software) {
      initialized = InitializeD3D11Backend();
    }
    if (!initialized) {
      if (!InitializeSoftwareBackend()) {
        if (error_message != nullptr) {
          *error_message =
              "Failed to initialize both D3D11 and software mpv render context";
        }
        return false;
      }
    }

    render_thread_ = std::thread([this]() { RenderThreadMain(); });
    return true;
  }

  void Resize(size_t width, size_t height) {
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

  void Dispose() {
    {
      std::lock_guard<std::mutex> lock(render_mutex_);
      if (disposed_) {
        return;
      }
      disposed_ = true;
      stop_requested_ = true;
    }

    // Detach mpv callback before joining render thread so mpv never posts
    // new notifications during teardown or after render_ctx destruction.
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
  }

  int64_t session_id() const { return session_id_; }
  int64_t texture_id() const { return texture_id_; }
  std::string backend() const { return is_software_ ? "sw" : "d3d11"; }
  std::string adapter_name() const { return adapter_name_; }

 private:
  struct TextureAllocation {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
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

  bool InitializeD3D11Backend() {
    if (!CreateD3D11Device(engine_, &device_, &context_, &adapter_name_)) {
      return false;
    }
    if (!AllocateD3D11SlotsLocked(target_width_, target_height_)) {
      device_.Reset();
      context_.Reset();
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
    RegisterGpuTexture();
    symbols_.set_update_callback(render_ctx_, &RenderSession::OnMpvUpdate, this);
    return texture_id_ >= 0;
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
    // Keep session alive through std::shared_ptr until Flutter finishes using
    // TextureVariant callbacks on its raster thread.
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

  bool AllocateD3D11SlotsLocked(size_t width, size_t height) {
    if (!device_) {
      return false;
    }
    PruneRetiredTexturesLocked();
    for (size_t i = 0; i < kTripleBufferSlots; ++i) {
      if (!CreateSlotTextureLocked(i, width, height)) {
        return false;
      }
    }
    return true;
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
    context_.Reset();
    device_.Reset();
  }

  int AcquireWritableD3D11Slot(size_t width, size_t height) {
    std::lock_guard<std::mutex> lock(surface_mutex_);
    PruneRetiredTexturesLocked();
    for (size_t offset = 1; offset <= kTripleBufferSlots; ++offset) {
      const int candidate =
          static_cast<int>((write_cursor_ + offset) % kTripleBufferSlots);
      const auto& alloc = slots_[candidate];
      const int pinned =
          alloc ? alloc->pinned_count.load(std::memory_order_acquire) : 0;
      if (candidate == latest_slot_ && pinned > 0) {
        continue;
      }
      if (pinned == 0 || offset == kTripleBufferSlots) {
        if (!CreateSlotTextureLocked(static_cast<size_t>(candidate), width,
                                     height)) {
          return -1;
        }
        write_cursor_ = static_cast<size_t>(candidate);
        return candidate;
      }
    }
    return -1;
  }

  void RenderThreadMain() {
    while (true) {
      size_t render_w = kMinSurfaceExtent;
      size_t render_h = kMinSurfaceExtent;
      bool force_draw = false;
      bool stop_now = false;

      {
        std::unique_lock<std::mutex> lock(render_mutex_);
        render_cv_.wait(lock, [this]() {
          return stop_requested_ || render_requested_ || resize_requested_;
        });
        if (stop_requested_) {
          stop_now = true;
        } else {
          render_requested_ = false;
          resize_requested_ = false;
          force_draw = force_render_;
          force_render_ = false;
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

      const uint64_t update_flags = symbols_.update(render_ctx_);
      const bool should_render =
          ((update_flags & MPV_RENDER_UPDATE_FRAME) != 0) || force_draw;
      if (!should_render) {
        continue;
      }

      if (is_software_) {
        RenderSoftwareFrame(render_w, render_h);
      } else {
        if (!RenderD3D11Frame(render_w, render_h)) {
          RecoverOrFallbackFromD3D11Failure(render_w, render_h);
        }
      }
    }
  }

  bool RenderD3D11Frame(size_t width, size_t height) {
    if (!device_ || !context_) {
      return false;
    }
    const HRESULT removed = device_->GetDeviceRemovedReason();
    if (FAILED(removed)) {
      return false;
    }

    const int slot_index = AcquireWritableD3D11Slot(width, height);
    if (slot_index < 0) {
      return false;
    }

    Microsoft::WRL::ComPtr<ID3D11Texture2D> target;
    {
      std::lock_guard<std::mutex> lock(surface_mutex_);
      if (slots_[slot_index]) {
        target = slots_[slot_index]->texture;
      }
    }
    if (!target) {
      return false;
    }

    mpv_d3d11_fbo fbo{};
    fbo.tex = target.Get();
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_D3D11_FBO, &fbo},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };

    const int rc = symbols_.render(render_ctx_, params);
    if (rc < 0 || FAILED(device_->GetDeviceRemovedReason())) {
      return false;
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
    // Tear down old render context first so mpv releases GPU references cleanly.
    if (render_ctx_ != nullptr) {
      symbols_.set_update_callback(render_ctx_, nullptr, nullptr);
      symbols_.free(render_ctx_);
      render_ctx_ = nullptr;
    }

    {
      std::lock_guard<std::mutex> lock(surface_mutex_);
      ReleaseD3D11ResourcesLocked();
    }

    // Attempt 1: recreate hardware D3D11 device + mpv D3D11 context keeping same
    // textureId.
    if (!d3d11_recovery_attempted_) {
      d3d11_recovery_attempted_ = true;
      if (CreateD3D11Device(engine_, &device_, &context_, &adapter_name_)) {
        bool slots_ok = false;
        {
          std::lock_guard<std::mutex> lock(surface_mutex_);
          slots_ok = AllocateD3D11SlotsLocked(width, height);
        }
        if (slots_ok) {
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
          if (symbols_.create(&ctx, mpv_, params) >= 0 && ctx != nullptr) {
            render_ctx_ = ctx;
            symbols_.set_update_callback(render_ctx_,
                                         &RenderSession::OnMpvUpdate, this);
            if (RenderD3D11Frame(width, height)) {
              return;
            }
          }
          if (render_ctx_ != nullptr) {
            symbols_.set_update_callback(render_ctx_, nullptr, nullptr);
            symbols_.free(render_ctx_);
            render_ctx_ = nullptr;
          }
        }
        std::lock_guard<std::mutex> lock(surface_mutex_);
        ReleaseD3D11ResourcesLocked();
      }
    }

    // Attempt 2: switch transparently to software PixelBufferTexture and notify
    // Dart to rebind Texture widget to the new textureId.
    UnregisterCurrentTexture();
    if (InitializeSoftwareBackend()) {
      RenderSoftwareFrame(width, height);
      if (on_texture_changed_) {
        on_texture_changed_(session_id_, texture_id_, "sw", adapter_name_,
                            "DXGI_DEVICE_LOST_FALLBACK");
      }
    }
  }

  const int64_t session_id_;
  mpv_handle* const mpv_;
  const MpvRenderSymbols symbols_;
  flutter::FlutterEngine* const engine_;
  flutter::TextureRegistrar* const registrar_;
  TextureChangedCallback on_texture_changed_;

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
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

  std::mutex render_mutex_;
  std::condition_variable render_cv_;
  std::thread render_thread_;
  size_t target_width_ = kMinSurfaceExtent;
  size_t target_height_ = kMinSurfaceExtent;
  bool render_requested_ = true;
  bool resize_requested_ = false;
  bool force_render_ = true;
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
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_.reset();
  }
}

void D3D11TextureBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "getAdapterInfo") {
    HandleGetAdapterInfo(std::move(result));
    return;
  }

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    result->Error("INVALID_ARGS", "Expected map arguments");
    return;
  }

  if (call.method_name() == "createSession") {
    HandleCreateSession(*args, std::move(result));
  } else if (call.method_name() == "resize") {
    HandleResize(*args, std::move(result));
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
    result->Error("NO_TEXTURE_REGISTRAR", "TextureRegistrar unavailable");
    return;
  }

  const int64_t mpv_ptr_val = ReadInt64Arg(args, "mpvHandle", 0);
  if (mpv_ptr_val == 0) {
    result->Error("INVALID_MPV_HANDLE", "mpvHandle is required and non-zero");
    return;
  }

  MpvRenderSymbols symbols{};
  if (!LoadMpvRenderSymbols(&symbols)) {
    result->Error("LIBMPV_LOAD_FAILED",
                  "Failed to load mpv_render_context symbols from libmpv-2.dll");
    return;
  }

  const size_t width = ClampExtent(ReadInt64Arg(args, "width", 1280));
  const size_t height = ClampExtent(ReadInt64Arg(args, "height", 720));
  const bool prefer_software = ReadBoolArg(args, "preferSoftware", false);

  int64_t session_id = 0;
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      result->Error("BRIDGE_SHUTDOWN", "D3D11 bridge is shutting down");
      return;
    }
    session_id = next_session_id_++;
  }

  auto* mpv = reinterpret_cast<mpv_handle*>(static_cast<uintptr_t>(mpv_ptr_val));
  auto session = std::make_shared<RenderSession>(
      session_id, mpv, symbols, engine_, texture_registrar_, width, height,
      [this](int64_t sid, int64_t tid, const std::string& backend,
             const std::string& adapter, const std::string& reason) {
        QueueTextureChanged(sid, tid, backend, adapter, reason);
      });

  std::string err;
  if (!session->Initialize(prefer_software, &err)) {
    session->Dispose();
    result->Error("RENDER_INIT_FAILED", err);
    return;
  }

  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      session->Dispose();
      result->Error("BRIDGE_SHUTDOWN", "D3D11 bridge is shutting down");
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
    result->Error("SESSION_NOT_FOUND", "Unknown video render session");
    return;
  }
  session->Resize(width, height);
  result->Success();
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
  const bool ok = CreateD3D11Device(engine_, &dev, &ctx, &adapter_name);
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("available")] = flutter::EncodableValue(ok);
  payload[flutter::EncodableValue("adapterName")] =
      flutter::EncodableValue(adapter_name);
  result->Success(flutter::EncodableValue(payload));
}

void D3D11TextureBridge::QueueTextureChanged(int64_t session_id,
                                             int64_t texture_id,
                                             const std::string& backend,
                                             const std::string& adapter_name,
                                             const std::string& reason) {
  {
    std::lock_guard<std::mutex> lock(sessions_mutex_);
    if (shutdown_called_) {
      return;
    }
    pending_notifications_.push_back(
        {session_id, texture_id, backend, adapter_name, reason});
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
    payload[flutter::EncodableValue("adapterName")] =
        flutter::EncodableValue(item.adapter_name);
    payload[flutter::EncodableValue("reason")] =
        flutter::EncodableValue(item.reason);
    channel_ptr->InvokeMethod(
        "onTextureChanged",
        std::make_unique<flutter::EncodableValue>(std::move(payload)));
  }
}
