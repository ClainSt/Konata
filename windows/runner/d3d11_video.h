#pragma once
#include <windows.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <string>

// Opt-in render API comparison. Uses the already loaded player and existing
// child window; no second player, decoding pipeline or Flutter video texture.
class D3D11Video {
 public:
  D3D11Video(HWND window, int64_t player, const std::string& library);
  ~D3D11Video();
  void Resize();
  flutter::EncodableMap Capture();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
