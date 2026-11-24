import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'state/history_controller.dart';
import 'ui/playback_history_sub_cards.dart';

/// 播放记录时间轴模块的宿主依赖集合。
final class FeatureHistoryDependencies {
  /// 创建播放记录模块依赖容器。
  const FeatureHistoryDependencies({
    required this.databases,
    required this.navigator,
    required this.diagnosticLog,
    required this.platform,
    this.sourceDeviceId = '',
    this.imageLoader,
    this.pathArtworkLoader,
  });

  /// 本地三库持久化集合。
  final KonataDatabaseBundle databases;

  /// 全局跨模块路由导航端口。
  final AppNavigator navigator;

  /// 脱敏诊断日志端口。
  final DiagnosticLogPort diagnosticLog;

  /// 当前运行平台分类。
  final KonataPlatform platform;

  /// 本机设备标识（用于同步墓碑来源记录）。
  final String sourceDeviceId;

  /// 可选封面图像字节加载回调（解耦具体图片缓存包依赖）。
  final HistoryArtworkLoader? imageLoader;

  /// 可选按相对路径加载分集剧照或原画字节的回调（未注入时回退作品封面）。
  final HistoryPathArtworkLoader? pathArtworkLoader;
}

/// 播放记录模块宿主依赖注入入口；必须在根 `ProviderScope` 覆盖。
final featureHistoryDependenciesProvider = Provider<FeatureHistoryDependencies>(
  (ref) {
    throw UnimplementedError(
      '必须在宿主根 ProviderScope 覆盖 featureHistoryDependenciesProvider',
    );
  },
);

/// 播放记录时间轴控制器提供者。
final historyControllerProvider = Provider<HistoryController>((ref) {
  final deps = ref.watch(featureHistoryDependenciesProvider);
  final controller = HistoryController(
    databases: deps.databases,
    navigator: deps.navigator,
    diagnosticLog: deps.diagnosticLog,
    sourceDeviceId: deps.sourceDeviceId,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
