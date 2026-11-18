import 'composition/windows_composition_root.dart';

export 'presentation/app/konata_app.dart' show KonataApp, KonataScrollBehavior;

/// Windows 默认组装根入口（100% 兼容既有桌面与跨端集成门禁）。
Future<void> main() => WindowsCompositionRoot.run();
