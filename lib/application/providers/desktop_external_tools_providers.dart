import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../composition/platform_composition.dart';
import '../../domain/models/external_audio_relay_models.dart';
import '../../domain/models/external_player_config.dart';
import '../../infrastructure/players/desktop_external_player_store.dart';
import '../playback/playback_preferences_provider.dart';
import 'library_providers.dart';

/// 桌面专属外部程序 SQLite 存取器 Provider（仅 Windows 组装根与桌面外部调用面板使用）。
final desktopExternalPlayerStoreProvider = Provider<DesktopExternalPlayerStore>(
  (ref) {
    final db = ref.watch(konataDatabaseProvider);
    return DesktopExternalPlayerStore(db);
  },
);

/// 桌面已配置外部播放器完整列表 Provider（仅桌面设置面板使用）。
final desktopExternalPlayersProvider = FutureProvider<List<ExternalPlayerConfig>>(
  (ref) async {
    return ref.watch(desktopExternalPlayerStoreProvider).getExternalPlayers();
  },
);

/// 桌面外部音频播放器与 `foo_beefweb` 组件状态实时探测 Provider。
final foobarBeefwebStatusProvider =
    FutureProvider<FoobarComponentStatusSnapshot>((ref) async {
      await ref.watch(desktopExternalPlayersProvider.future);
      final port = ref.watch(
        playbackPreferencesProvider.select((s) => s.foobarBeefwebPort),
      );
      final gateway = ref.watch(desktopRelayGatewayProvider);
      if (gateway == null) {
        return FoobarComponentStatusSnapshot(
          state: FoobarComponentState.unconfigured,
          port: port,
        );
      }
      return gateway.probeAudioPlayerStatus(beefwebPort: port);
    });

/// 桌面外部程序配置保存动作协调器（同时刷新共享接力目标与组件状态缓存）。
class DesktopExternalToolsActions {
  /// 创建桌面外部程序保存协调器。
  const DesktopExternalToolsActions(this._ref);

  final Ref _ref;

  /// 保存单条外部程序配置。
  Future<void> saveExternalPlayer(ExternalPlayerConfig config) =>
      saveExternalPlayers([config]);

  /// 批量保存全部外部程序配置并刷新依赖缓存。
  Future<void> saveExternalPlayers(
    Iterable<ExternalPlayerConfig> configs,
  ) async {
    final store = _ref.read(desktopExternalPlayerStoreProvider);
    for (final config in configs) {
      await store.upsertExternalPlayer(config);
    }
    _ref.invalidate(desktopExternalPlayersProvider);
    _ref.invalidate(desktopVideoRelayTargetsProvider);
    _ref.invalidate(foobarBeefwebStatusProvider);
  }
}

/// 桌面外部程序保存动作 Provider。
final desktopExternalToolsActionsProvider =
    Provider<DesktopExternalToolsActions>(
      (ref) => DesktopExternalToolsActions(ref),
    );
