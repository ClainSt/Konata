#pragma once
#include <windows.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <string>
#include <functional>

// Opt-in render API comparison. Uses the already loaded player and existing
// child window; no second player, decoding pipeline or Flutter video texture.
class D3D11Video {
 public:
  D3D11Video(HWND window, int64_t player, const std::string& library);
  ~D3D11Video();
  void Resize();
  std::string Failure();
#ifndef NDEBUG
  void SimulateFailure();
#endif
  flutter::EncodableMap Capture();
  flutter::EncodableMap BeginColor();
  void CommitColor(bool hdr, int epoch);
  void DisplayChanged(bool force = false);
  std::function<void()> on_display_changed;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
