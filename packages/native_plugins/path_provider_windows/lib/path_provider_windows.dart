// 遵循 Flutter 官方组件 BSD 开源许可协议（详见随包 LICENSE 文件）。

// `path_provider_windows` 基于 Dart FFI 实现；为不支持 FFI 的平台（如 Web）导出占位实现，
// 以避免传递依赖破坏多端编译流程。
export 'src/folders_stub.dart' if (dart.library.ffi) 'src/folders.dart';
export 'src/path_provider_windows_stub.dart'
    if (dart.library.ffi) 'src/path_provider_windows_real.dart';
