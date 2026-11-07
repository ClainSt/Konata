#include "d3d11_video.h"
#include <d3d11.h>
#include <dxgi1_2.h>
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

using Microsoft::WRL::ComPtr;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
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
  mpv_handle* player;
  Api api;
  HANDLE wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  std::atomic<bool> stop{false};
  std::atomic<bool> resize{true};
  std::thread thread;
  std::mutex mutex;
  std::shared_ptr<std::promise<EncodableMap>> capture;
  std::string failure;
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
    for (UINT y = 0; y < desc.Height; ++y) {
      const auto pixels = reinterpret_cast<const uint32_t*>(
          static_cast<const char*>(mapped.pData) + y * mapped.RowPitch);
      for (UINT x = 0; x < desc.Width; ++x)
        for (int c = 0; c < 3; ++c) values[c].set((pixels[x] >> (c * 10)) & 1023);
    }
    context->Unmap(staging.Get(), 0);
    return {{EncodableValue("format"), EncodableValue("R10G10B10A2_UNORM")},
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
        const bool changed = resize.exchange(false);
        const uint64_t flags = api.mpv_render_context_update(render);
        std::shared_ptr<std::promise<EncodableMap>> request;
        { std::lock_guard<std::mutex> lock(mutex); request = std::move(capture); }
        if (!changed && !request && !(flags & MPV_RENDER_UPDATE_FRAME)) continue;
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
        Check(swapchain->Present(1, 0), "D3D11 presentation failed");
        api.mpv_render_context_report_swap(render);
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
void D3D11Video::Resize() { impl_->resize = true; SetEvent(impl_->wake); }
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
