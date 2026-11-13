#include "d3d11_video.h"
#include <d3d11.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <mpv/client.h>
#include <mpv/render_d3d11.h>
#include <atomic>
#include <algorithm>
#include <bitset>
#include <chrono>
#include <future>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <cstring>
#include <cmath>

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
std::atomic<int> renderer_generation{0};
void Check(HRESULT result, const char* message) {
  if (FAILED(result)) throw std::runtime_error(message);
}
struct Api {
  HMODULE library = nullptr;
#define ENTRY(name) decltype(&name) name = nullptr;
  ENTRY(mpv_render_context_create)
  ENTRY(mpv_render_context_set_update_callback)
  ENTRY(mpv_render_context_update)
  ENTRY(mpv_render_context_render)
  ENTRY(mpv_render_context_report_swap)
  ENTRY(mpv_render_context_free)
#undef ENTRY
  explicit Api(const std::string& path) {
    const int length = MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, nullptr, 0);
    std::wstring wide(length, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, path.c_str(), -1, wide.data(), length);
    library = LoadLibraryW(wide.c_str());
    if (!library) throw std::runtime_error("Cannot load player render API");
#pragma warning(push)
#pragma warning(disable: 4191)
#define LOAD(name) name = reinterpret_cast<decltype(name)>(GetProcAddress(library, #name)); if (!name) { FreeLibrary(library); library = nullptr; throw std::runtime_error(#name); }
    LOAD(mpv_render_context_create)
    LOAD(mpv_render_context_set_update_callback)
    LOAD(mpv_render_context_update)
    LOAD(mpv_render_context_render)
    LOAD(mpv_render_context_report_swap)
    LOAD(mpv_render_context_free)
#undef LOAD
#pragma warning(pop)
  }
  ~Api() { if (library) FreeLibrary(library); }
};
}

struct D3D11Video::Impl {
  HWND window;
  const int generation = ++renderer_generation;
  mpv_handle* player;
  Api api;
  HANDLE wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  std::atomic<bool> stop{false};
  std::atomic<bool> resize{true};
#ifndef NDEBUG
  std::atomic<bool> simulate_failure{false};
#endif
  std::thread thread;
  std::mutex mutex;
  std::shared_ptr<std::promise<EncodableMap>> capture;
  std::string failure;
  // Only presentation is suspended during a color transaction. Rendering and
  // mpv update callbacks keep running so the core never waits on Dart.
  bool presentation_blocked = true;
  bool hdr_output = false;
  int color_epoch = 0;
  int commit_epoch = 0;
  bool commit_hdr = false;
  std::shared_ptr<std::promise<void>> color_commit;
  HMONITOR display_monitor = nullptr;
  bool display_hdr = false;
  int display_peak = 0;
  mpv_render_context* render = nullptr;

  Impl(HWND host, int64_t handle, const std::string& path)
      : window(host), player(reinterpret_cast<mpv_handle*>(handle)), api(path) {
    if (!wake) throw std::runtime_error("Cannot create rendering event");
    std::promise<void> initialized;
    auto ready = initialized.get_future();
    thread = std::thread([this, &initialized] { Run(initialized); });
    try {
      ready.get();
    } catch (...) {
      stop = true;
      SetEvent(wake);
      thread.join();
      CloseHandle(wake);
      throw;
    }
  }
  ~Impl() {
    stop = true;
    SetEvent(wake);
    if (thread.joinable()) thread.join();
    CloseHandle(wake);
  }

  EncodableMap DisplayInfo() {
    const HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
    bool hdr = false;
    int peak = 0;
    ComPtr<IDXGIFactory1> factory;
    if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
      for (UINT a = 0; ; ++a) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(a, &adapter) != S_OK) break;
        for (UINT n = 0; ; ++n) {
          ComPtr<IDXGIOutput> output;
          if (adapter->EnumOutputs(n, &output) != S_OK) break;
          ComPtr<IDXGIOutput6> output6;
          DXGI_OUTPUT_DESC1 info{};
          if (SUCCEEDED(output.As(&output6)) && SUCCEEDED(output6->GetDesc1(&info)) &&
              info.Monitor == monitor) {
            hdr = info.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
            if (std::isfinite(info.MaxLuminance) && info.MaxLuminance >= 100 && info.MaxLuminance <= 10000)
              peak = static_cast<int>(info.MaxLuminance);
          }
        }
      }
    }
    return {{EncodableValue("monitor"), EncodableValue(reinterpret_cast<int64_t>(monitor))},
            {EncodableValue("hdrActive"), EncodableValue(hdr)},
            {EncodableValue("peak"), EncodableValue(peak)}};
  }

  EncodableMap Readback(ID3D11Device* device, ID3D11DeviceContext* context,
                        ID3D11Texture2D* buffer) {
    D3D11_TEXTURE2D_DESC desc{};
    buffer->GetDesc(&desc);
    if (desc.Format != DXGI_FORMAT_R10G10B10A2_UNORM)
      throw std::runtime_error("Unexpected swapchain format");
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    ComPtr<ID3D11Texture2D> staging;
    Check(device->CreateTexture2D(&desc, nullptr, &staging), "Cannot create readback texture");
    context->CopyResource(staging.Get(), buffer);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    Check(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped), "Cannot read presented buffer");
    std::bitset<1024> values[3];
    std::vector<uint8_t> bytes(static_cast<size_t>(desc.Width) * desc.Height * 4);
    for (UINT y = 0; y < desc.Height; ++y) {
      const auto pixels = reinterpret_cast<const uint32_t*>(
          static_cast<const char*>(mapped.pData) + y * mapped.RowPitch);
      std::memcpy(bytes.data() + static_cast<size_t>(y) * desc.Width * 4,
                  pixels, static_cast<size_t>(desc.Width) * 4);
      for (UINT x = 0; x < desc.Width; ++x)
        for (int c = 0; c < 3; ++c) values[c].set((pixels[x] >> (c * 10)) & 1023);
    }
    context->Unmap(staging.Get(), 0);
    return {{EncodableValue("generation"), EncodableValue(generation)},
            {EncodableValue("outputColorSpace"), EncodableValue(hdr_output ? "bt.2020/pq" : "sdr")},
            {EncodableValue("pixels"), EncodableValue(std::move(bytes))},
            {EncodableValue("format"), EncodableValue("R10G10B10A2_UNORM")},
            {EncodableValue("width"), EncodableValue(static_cast<int>(desc.Width))},
            {EncodableValue("height"), EncodableValue(static_cast<int>(desc.Height))},
            {EncodableValue("redLevels"), EncodableValue(static_cast<int>(values[0].count()))},
            {EncodableValue("greenLevels"), EncodableValue(static_cast<int>(values[1].count()))},
            {EncodableValue("blueLevels"), EncodableValue(static_cast<int>(values[2].count()))}};
  }

  void Run(std::promise<void>& initialized) {
    bool ready = false;
    try {
      ComPtr<ID3D11Device> device;
      ComPtr<ID3D11DeviceContext> context;
      Check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
          nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context), "Cannot create D3D11 device");
      ComPtr<IDXGIDevice> dxgi;
      Check(device.As(&dxgi), "Cannot get DXGI device");
      ComPtr<IDXGIAdapter> adapter;
      Check(dxgi->GetAdapter(&adapter), "Cannot get DXGI adapter");
      ComPtr<IDXGIFactory2> factory;
      Check(adapter->GetParent(IID_PPV_ARGS(&factory)), "Cannot get DXGI factory");
      DXGI_SWAP_CHAIN_DESC1 desc{};
      desc.Width = desc.Height = 8;
      desc.Format = DXGI_FORMAT_R10G10B10A2_UNORM;
      desc.SampleDesc.Count = 1;
      desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
      desc.BufferCount = 2;
      desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
      ComPtr<IDXGISwapChain1> swapchain;
      Check(factory->CreateSwapChainForHwnd(device.Get(), window, &desc,
          nullptr, nullptr, &swapchain), "Cannot create 10-bit swapchain");
      mpv_d3d11_init_params init{device.Get()};
      int advanced = 1;
      mpv_render_param parameters[] = {
          {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_D3D11)},
          {MPV_RENDER_PARAM_D3D11_INIT_PARAMS, &init},
          {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
          {MPV_RENDER_PARAM_INVALID, nullptr}};
      if (api.mpv_render_context_create(&render, player, parameters) < 0)
        throw std::runtime_error("Cannot initialize D3D11 render API");
      api.mpv_render_context_set_update_callback(render, [](void* value) {
        SetEvent(static_cast<Impl*>(value)->wake);
      }, this);
      initialized.set_value();
      ready = true;
      SetEvent(wake);
      while (!stop) {
        WaitForSingleObject(wake, INFINITE);
        if (stop) break;
#ifndef NDEBUG
        if (simulate_failure.exchange(false))
          throw std::runtime_error("Injected presentation failure");
#endif
        const bool changed = resize.exchange(false);
        const uint64_t flags = api.mpv_render_context_update(render);
        std::shared_ptr<std::promise<EncodableMap>> request;
        std::shared_ptr<std::promise<void>> commit;
        int frame_epoch;
        {
          std::lock_guard<std::mutex> lock(mutex);
          request = std::move(capture);
          commit = std::move(color_commit);
          frame_epoch = color_epoch;
          if (commit) {
            ComPtr<IDXGISwapChain3> colors;
            UINT support = 0;
            const auto space = commit_hdr ? DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020
                                          : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
            if (commit_epoch != color_epoch || FAILED(swapchain.As(&colors)) ||
                FAILED(colors->CheckColorSpaceSupport(space, &support)) ||
                !(support & DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT) ||
                FAILED(colors->SetColorSpace1(space))) {
              commit->set_exception(std::make_exception_ptr(std::runtime_error("Output color space unavailable or display changed")));
              commit.reset();
            } else {
              hdr_output = commit_hdr;
            }
          }
        }
        if (!changed && !request && !commit && !(flags & MPV_RENDER_UPDATE_FRAME)) continue;
        if (changed) {
          RECT rect{};
          GetClientRect(window, &rect);
          const UINT width = static_cast<UINT>((std::max)(8L, rect.right));
          const UINT height = static_cast<UINT>((std::max)(8L, rect.bottom));
          context->ClearState();
          Check(swapchain->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0), "Cannot resize swapchain");
        }
        ComPtr<ID3D11Texture2D> buffer;
        Check(swapchain->GetBuffer(0, IID_PPV_ARGS(&buffer)), "Cannot get render target");
        mpv_d3d11_fbo fbo{buffer.Get()};
        mpv_render_param draw[] = {{MPV_RENDER_PARAM_D3D11_FBO, &fbo},
                                  {MPV_RENDER_PARAM_INVALID, nullptr}};
        if (api.mpv_render_context_render(render, draw) < 0)
          throw std::runtime_error("D3D11 rendering failed");
        EncodableMap observation;
        if (request) observation = Readback(device.Get(), context.Get(), buffer.Get());
        {
          std::lock_guard<std::mutex> lock(mutex);
          if (frame_epoch == color_epoch && commit) presentation_blocked = false;
          if (!presentation_blocked && frame_epoch == color_epoch) {
            Check(swapchain->Present(1, 0), "D3D11 presentation failed");
            api.mpv_render_context_report_swap(render);
          }
          if (commit) {
            if (frame_epoch == color_epoch) commit->set_value();
            else commit->set_exception(std::make_exception_ptr(std::runtime_error("Display changed during color transaction")));
          }
        }
        if (request) request->set_value(std::move(observation));
      }
    } catch (...) {
      if (!ready) initialized.set_exception(std::current_exception());
      try { throw; } catch (const std::exception& error) {
        std::lock_guard<std::mutex> lock(mutex);
        failure = error.what();
      }
    }
    if (render) {
      api.mpv_render_context_set_update_callback(render, nullptr, nullptr);
      api.mpv_render_context_free(render);
      render = nullptr;
    }
  }
};

D3D11Video::D3D11Video(HWND window, int64_t player, const std::string& library)
    : impl_(std::make_unique<Impl>(window, player, library)) {}
D3D11Video::~D3D11Video() = default;
EncodableMap D3D11Video::BeginColor() {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->presentation_blocked = true;
  auto info = impl_->DisplayInfo();
  impl_->display_monitor = reinterpret_cast<HMONITOR>(info.at(EncodableValue("monitor")).LongValue());
  impl_->display_hdr = std::get<bool>(info.at(EncodableValue("hdrActive")));
  impl_->display_peak = std::get<int>(info.at(EncodableValue("peak")));
  info[EncodableValue("epoch")] = EncodableValue(++impl_->color_epoch);
  return info;
}
void D3D11Video::CommitColor(bool hdr, int epoch) {
  auto request = std::make_shared<std::promise<void>>();
  auto result = request->get_future();
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->failure.empty()) throw std::runtime_error(impl_->failure);
    if (impl_->color_commit) throw std::runtime_error("Output transition already pending");
    impl_->commit_hdr = hdr;
    impl_->commit_epoch = epoch;
    impl_->color_commit = request;
  }
  SetEvent(impl_->wake);
  if (result.wait_for(std::chrono::seconds(5)) != std::future_status::ready)
    throw std::runtime_error("Output transition timed out");
  result.get();
}
void D3D11Video::DisplayChanged(bool force) {
  if (!force && MonitorFromWindow(impl_->window, MONITOR_DEFAULTTONEAREST) == impl_->display_monitor) return;
  const auto info = impl_->DisplayInfo();
  const auto monitor = reinterpret_cast<HMONITOR>(info.at(EncodableValue("monitor")).LongValue());
  const bool hdr = std::get<bool>(info.at(EncodableValue("hdrActive")));
  const int peak = std::get<int>(info.at(EncodableValue("peak")));
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (monitor == impl_->display_monitor && hdr == impl_->display_hdr && peak == impl_->display_peak) return;
    impl_->display_monitor = monitor;
    impl_->display_hdr = hdr;
    impl_->display_peak = peak;
    impl_->presentation_blocked = true;
    ++impl_->color_epoch;
  }
  if (on_display_changed) on_display_changed();
}
void D3D11Video::Resize() { impl_->resize = true; SetEvent(impl_->wake); }
std::string D3D11Video::Failure() {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  return impl_->failure;
}
#ifndef NDEBUG
void D3D11Video::SimulateFailure() {
  impl_->simulate_failure = true;
  SetEvent(impl_->wake);
}
#endif
EncodableMap D3D11Video::Capture() {
  auto request = std::make_shared<std::promise<EncodableMap>>();
  auto result = request->get_future();
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->failure.empty()) throw std::runtime_error(impl_->failure);
    if (impl_->capture) throw std::runtime_error("Capture already pending");
    impl_->capture = request;
  }
  SetEvent(impl_->wake);
  if (result.wait_for(std::chrono::seconds(5)) != std::future_status::ready)
    throw std::runtime_error("Render capture timed out");
  return result.get();
}
