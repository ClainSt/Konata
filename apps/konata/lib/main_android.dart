import 'dart:async';

import 'bootstrap/android_app.dart';

/// Konata v3 Android 专用裁剪入口（物理隔离桌面端依赖，确保 Release AOT 零桌面残留）。
///
/// 所有 Android 端宿主初始化与底座组装均收口至 `bootstrap/android_app.dart`。
void main() {
  unawaited(runAndroidKonataApp());
}
