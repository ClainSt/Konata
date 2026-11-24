import 'package:flutter/widgets.dart';

import 'main.dart';

/// Konata v3 Android 专用裁剪入口占位壳。
///
/// 保持与桌面端入口物理分离，确保 Android Release AOT 产物不引入任何桌面专属依赖；
/// 底座落地后由 `bootstrap/android_app.dart` 接管完整组装逻辑。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KonataBootstrapShell(platformLabel: 'Android'));
}
