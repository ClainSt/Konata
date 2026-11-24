# apps/konata

## 职责边界
- Konata v3 双端极薄应用壳（Composition Root），负责 Windows 桌面与 Android（手机/平板）原生宿主承载、显式 `FeatureManifest` 注册及应用启动引导。
- 不承载业务规则、数据访问细节或独立通用组件。

## 关键入口
- `lib/main.dart`：Windows 桌面端与默认开发入口。
- `lib/main_android.dart`：Android 专用裁剪入口（确保 Release AOT 产物零桌面依赖残留）。
- `lib/bootstrap/`：后续 Phase 0 落地 `windows_app.dart`、`android_app.dart` 与按字母序排列的 `feature_registry.dart`。
