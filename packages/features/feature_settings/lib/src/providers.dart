import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import 'state/settings_controller.dart';

/// 通用设置容器模块的宿主依赖集合。
final class FeatureSettingsDependencies {
  /// 创建通用设置模块依赖容器。
  const FeatureSettingsDependencies({
    required this.databases,
    required this.scopedPrefs,
    required this.secureStorage,
    required this.httpClient,
    required this.photosStorage,
    required this.backupFilePort,
    required this.urlOpener,
    required this.diagnosticLog,
    required this.navigator,
    required this.currentPlatform,
    this.sections = const <SettingsSectionContribution>[],
    this.appVersion = '3.0.0',
    this.storageRoot,
    this.onThemeModeChanged,
    this.onAmbientBackdropChanged,
    this.onWindowMaterialChanged,
    this.onNetworkConfigChanged,
    this.connectivityProbeOverride,
    this.onDetailVisibilityChanged,
  });

  /// 本地三库持久化集合。
  final KonataDatabaseBundle databases;

  /// 作用域偏好配置仓库。
  final ScopedPrefsStore scopedPrefs;

  /// 系统安全凭据存储端口（TMDB / Fanart 密钥仅存此处）。
  final SecureStoragePort secureStorage;

  /// 统一 HTTP 客户端端口。
  final KonataHttpClientPort httpClient;

  /// 本地图片存储管理器。
  final PhotosStorage photosStorage;

  /// 跨平台文件导出端口（供脱敏诊断报告导出落盘）。
  final BackupFilePort backupFilePort;

  /// 外部浏览器链接打开端口。
  final UrlOpenerPort urlOpener;

  /// 脱敏诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 全局路由导航端口。
  final AppNavigator navigator;

  /// 当前运行平台分类，用于按平台过滤外部与内置设置分区。
  final KonataPlatform currentPlatform;

  /// 由宿主聚合注入的全部设置分区贡献列表（支持来自各已挂载业务包）。
  final List<SettingsSectionContribution> sections;

  /// 应用当前语义化版本号展示字符串。
  final String appVersion;

  /// 可选存储根目录端口（供离线映射表更新读取便携目录）。
  final StorageRootPort? storageRoot;

  /// 主题模式变更后通知宿主壳层刷新主题的回调。
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  /// 柔和流光背景开关变更后通知宿主壳层刷新的回调。
  final ValueChanged<bool>? onAmbientBackdropChanged;

  /// Windows 桌面窗口材质变更后通知宿主 DWM 控制器刷新的回调。
  final ValueChanged<KonataWindowMaterial>? onWindowMaterialChanged;

  /// 网络配置保存后通知宿主额外监听器的回调。
  final ValueChanged<KonataNetworkConfig>? onNetworkConfigChanged;

  /// 可选连通性探针覆盖函数。
  final NetworkConnectivityProbe? connectivityProbeOverride;

  /// 手机二级详情页显隐变更回调。
  final ValueChanged<bool>? onDetailVisibilityChanged;
}

/// 通用设置模块宿主依赖注入入口；必须在根 `ProviderScope` 覆盖。
final featureSettingsDependenciesProvider =
    Provider<FeatureSettingsDependencies>((ref) {
      throw UnimplementedError(
        '必须在宿主根 ProviderScope 覆盖 featureSettingsDependenciesProvider',
      );
    });

/// 通用设置控制器提供者。
final settingsControllerProvider = Provider<SettingsController>((ref) {
  final deps = ref.watch(featureSettingsDependenciesProvider);
  final controller = SettingsController(
    databases: deps.databases,
    scopedPrefs: deps.scopedPrefs,
    secureStorage: deps.secureStorage,
    httpClient: deps.httpClient,
    photosStorage: deps.photosStorage,
    backupFilePort: deps.backupFilePort,
    urlOpener: deps.urlOpener,
    diagnosticLog: deps.diagnosticLog,
    appVersion: deps.appVersion,
    storageRoot: deps.storageRoot,
    bundledMappingAssetLoader: (assetPath) async {
      try {
        final data = await rootBundle.load(assetPath);
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } catch (_) {
        return null;
      }
    },
    onThemeModeChanged: deps.onThemeModeChanged,
    onAmbientBackdropChanged: deps.onAmbientBackdropChanged,
    onWindowMaterialChanged: deps.onWindowMaterialChanged,
    onNetworkConfigChanged: deps.onNetworkConfigChanged,
    connectivityProbeOverride: deps.connectivityProbeOverride,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
