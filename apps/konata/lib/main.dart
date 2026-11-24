import 'dart:async';

import 'bootstrap/windows_app.dart';

/// Konata v3 Windows 桌面与默认开发入口。
///
/// 所有宿主初始化与底座依赖组装均收口至 `bootstrap/windows_app.dart`。
void main() {
  unawaited(runWindowsKonataApp());
}
