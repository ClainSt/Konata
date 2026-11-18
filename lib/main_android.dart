import 'composition/android_composition_root.dart';

export 'presentation/app/konata_app.dart' show KonataApp, KonataScrollBehavior;

/// Android 专用组装根入口（严格物理裁剪全部 Windows 桌面模块与插件引用）。
Future<void> main() => AndroidCompositionRoot.run();
