import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';

import 'providers.dart';
import 'ui/ui.dart';

Object _buildAudioSettingsSectionView(ViewSlotContext slotContext) {
  final rawIsDesktop = slotContext.arguments['isDesktopPlatform'];
  final rawIsAndroid = slotContext.arguments['isAndroidPlatform'];

  return Consumer(
    builder: (context, ref, _) {
      final deps = ref.watch(featurePlayerAudioDependenciesProvider);
      final prefs = ref.watch(audioPlaybackPrefsRepoProvider);
      final controller = ref.watch(audioPlaybackControllerProvider);
      final resolvedDesktop = rawIsDesktop is bool
          ? rawIsDesktop
          : deps.platform == KonataPlatform.windows;
      final resolvedAndroid = rawIsAndroid is bool
          ? rawIsAndroid
          : (deps.platform == KonataPlatform.androidPhone ||
                deps.platform == KonataPlatform.androidTablet);
      return SettingsAudioPanel(
        preferences: prefs,
        controller: controller,
        isDesktopPlatform: resolvedDesktop,
        isAndroidPlatform: resolvedAndroid,
      );
    },
  );
}

/// `feature_player_audio` 声明式扩展清单常量。
///
/// 对外壳层注册「音频与发烧直通」设置分区贡献；沉浸舞台与迷你小窗通过根出口组件显式装配。
const FeatureManifest featurePlayerAudioManifest = FeatureManifest(
  id: 'feature_player_audio',
  displayName: '沉浸式 CD 音乐舞台与小窗',
  settingsSections: <SettingsSectionContribution>[
    SettingsSectionContribution(
      id: 'audio_playback',
      title: '音频与发烧直通',
      subtitle: '-12 dBFS 防爆耳安全链、回放增益、迷你唱片与外部播放器转发',
      iconKey: 'audio_stage',
      order: 35,
      viewBuilder: _buildAudioSettingsSectionView,
    ),
  ],
);
