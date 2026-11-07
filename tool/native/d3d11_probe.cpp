// Test-only D3D11 render API probe. No changes to shipped libmpv.
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <mpv/client.h>
#include <mpv/render_d3d11.h>
#include <atomic>
#include <fstream>
#include <iostream>
#include <set>
#include <stdexcept>
#include <vector>

template<class T> struct Com {
    T* p = nullptr;
    ~Com() { if (p) p->Release(); }
    T** put() { return &p; }
    T* operator->() { return p; }
};
void check(HRESULT result, const char* what) {
    if (FAILED(result)) throw std::runtime_error(what);
}
struct Api {
    HMODULE dll;
#define FN(name) decltype(&name) name = nullptr;
    FN(mpv_create) FN(mpv_initialize) FN(mpv_set_option_string)
    FN(mpv_get_property_string) FN(mpv_free) FN(mpv_command)
    FN(mpv_terminate_destroy) FN(mpv_render_context_create)
    FN(mpv_render_context_set_update_callback) FN(mpv_render_context_update)
    FN(mpv_render_context_render) FN(mpv_render_context_report_swap)
    FN(mpv_render_context_free)
#undef FN
    Api(const char* path) {
        dll = LoadLibraryA(path);
        if (!dll) throw std::runtime_error("libmpv load failed");
#define LOAD(name) name = reinterpret_cast<decltype(name)>(GetProcAddress(dll, #name)); if (!name) throw std::runtime_error(#name);
        LOAD(mpv_create) LOAD(mpv_initialize) LOAD(mpv_set_option_string)
        LOAD(mpv_get_property_string) LOAD(mpv_free) LOAD(mpv_command)
        LOAD(mpv_terminate_destroy) LOAD(mpv_render_context_create)
        LOAD(mpv_render_context_set_update_callback) LOAD(mpv_render_context_update)
        LOAD(mpv_render_context_render) LOAD(mpv_render_context_report_swap)
        LOAD(mpv_render_context_free)
#undef LOAD
    }
    std::string property(mpv_handle* player, const char* name) {
        char* value = mpv_get_property_string(player, name);
        std::string result = value ? value : "";
        mpv_free(value);
        return result;
    }
};
int main(int argc, char** argv) {
    if (argc != 4) { std::cerr << "dll media output.raw\n"; return 2; }
    HWND window = nullptr;
    mpv_handle* player = nullptr;
    mpv_render_context* render = nullptr;
    try {
        Api api(argv[1]);
        window = CreateWindowExW(0, L"STATIC", L"Konata 10-bit verification",
            WS_OVERLAPPEDWINDOW | WS_VISIBLE, 20, 20, 1080, 720,
            nullptr, nullptr, nullptr, nullptr);
        if (!window) throw std::runtime_error("Window creation failed");
        Com<ID3D11Device> device;
        Com<ID3D11DeviceContext> context;
        D3D_FEATURE_LEVEL level;
        check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
            nullptr, 0, D3D11_SDK_VERSION, device.put(), &level, context.put()), "D3D11CreateDevice");
        Com<IDXGIDevice> dxgi;
        check(device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void**>(dxgi.put())), "DXGI device");
        Com<IDXGIAdapter> adapter;
        check(dxgi->GetAdapter(adapter.put()), "GetAdapter");
        Com<IDXGIFactory2> factory;
        check(adapter->GetParent(__uuidof(IDXGIFactory2), reinterpret_cast<void**>(factory.put())), "Factory2");
        DXGI_SWAP_CHAIN_DESC1 description{};
        description.Width = 1024;
        description.Height = 256;
        description.Format = DXGI_FORMAT_R10G10B10A2_UNORM;
        description.SampleDesc.Count = 1;
        description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        description.BufferCount = 2;
        description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        Com<IDXGISwapChain1> swapchain;
        check(factory->CreateSwapChainForHwnd(device.p, window, &description,
            nullptr, nullptr, swapchain.put()), "10-bit swapchain creation");
        player = api.mpv_create();
        if (!player) throw std::runtime_error("mpv_create");
        for (auto option : std::vector<std::pair<const char*, const char*>>{
            {"config", "no"}, {"vo", "libmpv"}, {"hwdec", "no"}, {"ao", "null"},
            {"pause", "yes"}, {"keep-open", "yes"}, {"sub-visibility", "no"},
            {"osd-level", "0"}, {"dither-depth", "10"}, {"dither", "no"},
            {"scale", "bilinear"}, {"cscale", "bilinear"}, {"deband", "no"}}) {
            if (api.mpv_set_option_string(player, option.first, option.second) < 0)
                throw std::runtime_error(option.first);
        }
        if (api.mpv_initialize(player) < 0) throw std::runtime_error("mpv initialize");
        mpv_d3d11_init_params init{device.p};
        int advanced = 1;
        mpv_render_param parameters[] = {
            {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_D3D11)},
            {MPV_RENDER_PARAM_D3D11_INIT_PARAMS, &init},
            {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        int created = api.mpv_render_context_create(&render, player, parameters);
        if (created < 0) throw std::runtime_error("D3D11 render API init " + std::to_string(created));
        std::atomic<bool> update{true};
        api.mpv_render_context_set_update_callback(render, [](void* state) {
            static_cast<std::atomic<bool>*>(state)->store(true);
        }, &update);
        const char* command[] = {"loadfile", argv[2], nullptr};
        if (api.mpv_command(player, command) < 0) throw std::runtime_error("loadfile");
        auto start = GetTickCount64();
        bool captured = false;
        while (GetTickCount64() - start < 15000 && !captured) {
            MSG message;
            while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
                TranslateMessage(&message); DispatchMessageW(&message);
            }
            bool ready = update.exchange(false);
            if (ready) api.mpv_render_context_update(render);
            // Redraw the paused frame to the actual swapchain buffer, then read
            // that exact buffer before Present. No separate screenshot target.
            if (ready || GetTickCount64() - start > 3000) {
                Com<ID3D11Texture2D> buffer;
                check(swapchain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void**>(buffer.put())), "GetBuffer");
                mpv_d3d11_fbo fbo{buffer.p};
                mpv_render_param draw[] = {{MPV_RENDER_PARAM_D3D11_FBO, &fbo}, {MPV_RENDER_PARAM_INVALID, nullptr}};
                if (api.mpv_render_context_render(render, draw) < 0) throw std::runtime_error("render");
                if (GetTickCount64() - start > 3000 && !api.property(player, "video-params/pixelformat").empty()) {
                    D3D11_TEXTURE2D_DESC desc;
                    buffer->GetDesc(&desc);
                    if (desc.Format != DXGI_FORMAT_R10G10B10A2_UNORM) throw std::runtime_error("Unexpected actual buffer format");
                    desc.Usage = D3D11_USAGE_STAGING;
                    desc.BindFlags = 0;
                    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                    desc.MiscFlags = 0;
                    Com<ID3D11Texture2D> staging;
                    check(device->CreateTexture2D(&desc, nullptr, staging.put()), "staging texture");
                    context->CopyResource(staging.p, buffer.p);
                    D3D11_MAPPED_SUBRESOURCE mapped;
                    check(context->Map(staging.p, 0, D3D11_MAP_READ, 0, &mapped), "readback");
                    std::ofstream output(argv[3], std::ios::binary);
                    std::set<unsigned> levels[3];
                    for (UINT row = 0; row < desc.Height; row++) {
                        auto pixels = reinterpret_cast<const uint32_t*>(static_cast<const char*>(mapped.pData) + row * mapped.RowPitch);
                        output.write(reinterpret_cast<const char*>(pixels), desc.Width * 4);
                        for (UINT x = 0; x < desc.Width; x++)
                            for (int c = 0; c < 3; c++) levels[c].insert((pixels[x] >> (10*c)) & 1023);
                    }
                    context->Unmap(staging.p, 0);
                    if (!output) throw std::runtime_error("write readback");
                    check(swapchain->Present(1, 0), "Present");
                    api.mpv_render_context_report_swap(render);
                    std::cout << "{\"format\":\"R10G10B10A2_UNORM\",\"width\":" << desc.Width
                        << ",\"height\":" << desc.Height << ",\"uniqueRGB\":[" << levels[0].size()
                        << "," << levels[1].size() << "," << levels[2].size() << "],\"mpv\":\""
                        << api.property(player, "mpv-version") << "\",\"ffmpeg\":\"" << api.property(player, "ffmpeg-version")
                        << "\",\"decoded\":\"" << api.property(player, "video-params/pixelformat") << "\"}\n";
                    captured = true;
                } else {
                    check(swapchain->Present(1, 0), "Present");
                    api.mpv_render_context_report_swap(render);
                }
            }
            Sleep(5);
        }
        api.mpv_render_context_set_update_callback(render, nullptr, nullptr);
        api.mpv_render_context_free(render);
        api.mpv_terminate_destroy(player);
        DestroyWindow(window);
        return captured ? 0 : 3;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        if (window) DestroyWindow(window);
        // Probe process exits on failure; no application state or cache is used.
        return 1;
    }
}
