import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/amll_lyric_provider.dart';
import 'data/lrclib_lyric_provider.dart';
import 'data/lyric_http_transport.dart';
import 'data/lyric_overrides_sync_slice.dart';
import 'data/lyrics_preferences.dart';
import 'data/netease_lyric_provider.dart';
import 'data/qqmusic_lyric_provider.dart';
import 'domain/lyric_candidate.dart';
import 'providers.dart';
import 'state/lyric_display_controller.dart';
import 'ui/immersive_lyric_control_sheet.dart';
import 'ui/settings_lyrics_card.dart';

/// 静态声明阶段使用的轻量级歌词源描述对象（避免静默提前初始化网络客户端）。
@immutable
final class LyricSourceDescriptor {
  /// 构造歌词源描述信息。
  const LyricSourceDescriptor({
    required this.source,
    required this.defaultEnabled,
    required this.requiresDisclaimer,
  });

  /// 对应领域歌词来源枚举。
  final LyricSource source;

  /// 是否默认开启。
  final bool defaultEnabled;

  /// 启用前是否需要展示免责声明提示。
  final bool requiresDisclaimer;
}

/// `feature_lyrics` 向宿主外壳注册的静态声明清单。
///
/// 挂载音频播放器「歌词设置」侧栏、设置页「在线歌词来源与注音」分区及多源歌词贡献声明。
final FeatureManifest featureLyricsManifest = _buildManifest(
  syncSlices: const <SyncSliceContributor<Object?>>[],
  dataProviders: _staticDataProviders,
);

/// 基于运行期数据库Bundle与可选网络客户端构建完整 `feature_lyrics` 扩展清单（含 `lyric_overrides_slice`）。
FeatureManifest createFeatureLyricsManifest({
  required KonataDatabaseBundle databases,
  KonataHttpClientPort? httpClient,
}) {
  final transport = httpClient == null
      ? null
      : KonataHttpClientLyricTransport(httpClient);
  return _buildManifest(
    syncSlices: <SyncSliceContributor<Object?>>[
      LyricOverridesSyncSlice(userStateDb: databases.userState),
    ],
    dataProviders: transport == null
        ? _staticDataProviders
        : <DataProviderContribution>[
            LyricSourceProviderContribution(
              id: 'amll',
              displayName: 'AMLL 逐字歌词',
              priority: 10,
              provider: AmllLyricProvider(transport),
            ),
            LyricSourceProviderContribution(
              id: 'netease',
              displayName: '网易云音乐',
              priority: 20,
              provider: NeteaseLyricProvider(transport),
            ),
            LyricSourceProviderContribution(
              id: 'lrclib',
              displayName: 'LRCLIB',
              priority: 30,
              provider: LrclibLyricProvider(transport),
            ),
            LyricSourceProviderContribution(
              id: 'qq',
              displayName: 'QQ 音乐（非官方）',
              priority: 40,
              provider: QqMusicLyricProvider(transport),
            ),
          ],
  );
}

const List<DataProviderContribution> _staticDataProviders =
    <DataProviderContribution>[
      LyricSourceProviderContribution(
        id: 'amll',
        displayName: 'AMLL 逐字歌词',
        priority: 10,
        provider: LyricSourceDescriptor(
          source: LyricSource.amll,
          defaultEnabled: true,
          requiresDisclaimer: false,
        ),
      ),
      LyricSourceProviderContribution(
        id: 'netease',
        displayName: '网易云音乐',
        priority: 20,
        provider: LyricSourceDescriptor(
          source: LyricSource.netease,
          defaultEnabled: true,
          requiresDisclaimer: false,
        ),
      ),
      LyricSourceProviderContribution(
        id: 'lrclib',
        displayName: 'LRCLIB',
        priority: 30,
        provider: LyricSourceDescriptor(
          source: LyricSource.lrclib,
          defaultEnabled: true,
          requiresDisclaimer: false,
        ),
      ),
      LyricSourceProviderContribution(
        id: 'qq',
        displayName: 'QQ 音乐（非官方）',
        priority: 40,
        provider: LyricSourceDescriptor(
          source: LyricSource.qq,
          defaultEnabled: false,
          requiresDisclaimer: true,
        ),
      ),
    ];

FeatureManifest _buildManifest({
  required List<SyncSliceContributor<Object?>> syncSlices,
  required List<DataProviderContribution> dataProviders,
}) {
  return FeatureManifest(
    id: 'feature_lyrics',
    displayName: '歌词与逐字扫白',
    settingsSections: <SettingsSectionContribution>[
      SettingsSectionContribution(
        id: 'lyrics_sources',
        title: '歌词与注音',
        subtitle: '管理多源歌词竞速库与罗马音注音显示',
        iconKey: 'lyrics',
        order: 30,
        viewBuilder: (slotContext) => _SettingsLyricsSectionSlot(
          preferencesStore:
              slotContext.arguments['preferencesStore']
                  as LyricsPreferencesStore?,
        ),
      ),
    ],
    playerSidePanels: <PlayerSidePanelContribution>[
      PlayerSidePanelContribution(
        id: 'lyrics_control',
        label: '歌词设置',
        iconKey: 'lyrics',
        order: 20,
        supportedModes: const <PlayerMediaMode>{PlayerMediaMode.audio},
        viewBuilder: (slotContext) {
          final rawLyricCtrl = slotContext.arguments['lyricController'];
          final rawCtrl = slotContext.arguments['controller'];
          final resolvedArgCtrl = rawLyricCtrl is LyricDisplayController
              ? rawLyricCtrl
              : (rawCtrl is LyricDisplayController ? rawCtrl : null);
          return _PlayerLyricControlPanelSlot(
            controller: resolvedArgCtrl,
            onClose: slotContext.arguments['onClose'] as VoidCallback?,
            embedded: slotContext.arguments['embedded'] == true,
          );
        },
      ),
    ],
    dataProviders: dataProviders,
    syncSlices: syncSlices,
  );
}

class _SettingsLyricsSectionSlot extends ConsumerWidget {
  const _SettingsLyricsSectionSlot({this.preferencesStore});

  final LyricsPreferencesStore? preferencesStore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store =
        preferencesStore ??
        ref.watch<LyricsPreferencesStore>(lyricsPreferencesStoreProvider);
    return SettingsLyricsCard(preferencesStore: store);
  }
}

class _PlayerLyricControlPanelSlot extends ConsumerWidget {
  const _PlayerLyricControlPanelSlot({
    this.controller,
    this.onClose,
    this.embedded = false,
  });

  final LyricDisplayController? controller;
  final VoidCallback? onClose;
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolvedController =
        controller ??
        ref.watch<LyricDisplayController>(lyricDisplayControllerProvider);
    return ImmersiveLyricControlSheet(
      controller: resolvedController,
      onClose: onClose ?? () {},
      embedded: embedded,
    );
  }
}
