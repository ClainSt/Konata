# apps/konata

## 职责边界
- Konata v3 双端极薄应用壳（Composition Root），负责 Windows 桌面与 Android（手机/平板）原生宿主承载、显式 `FeatureManifest` 注册、跨端存储/安全存储桥接及应用启动引导。
- 不承载业务规则、数据访问细节或独立通用组件。

## 关键入口与组装模块
- `lib/main.dart`：Windows 桌面端与默认开发入口，仅委托 `bootstrap/windows_app.dart`。
- `lib/main_android.dart`：Android 专用裁剪入口，仅委托 `bootstrap/android_app.dart`，物理隔绝一切桌面插件依赖。
- `lib/bootstrap/app_bootstrap.dart`：双端共享底座上下文初始化（三库分治 + 惰性 `cache.db`、`ScopedPrefsStore`、`DiagnosticLogStore`、`DomainEventBus`）与顶层 Riverpod Provider 覆写。
- `lib/bootstrap/feature_registry.dart`：按字母序显式维护全仓 `FeatureManifest` 清单与 7 大扩展点平台过滤聚合器。
- `lib/bootstrap/host_storage_adapters.dart`：Windows 绿色便携根目录 / Android `ApplicationSupportDirectory` 桥接，以及 `flutter_secure_storage` 对 `SecureStoragePort` 的实现。
- `lib/bootstrap/windows_app.dart` / `lib/bootstrap/android_app.dart`：双端差异化宿主装配入口。
