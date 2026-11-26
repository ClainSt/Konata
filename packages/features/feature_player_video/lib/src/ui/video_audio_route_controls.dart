import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/video_playback_preferences.dart';

/// 全局设置与播放侧栏共用互斥路由选项，实际输出能力以底层反馈为准。
class VideoAudioRouteControls extends StatelessWidget {
  const VideoAudioRouteControls({
    super.key,
    required this.platform,
    required this.preferences,
    required this.store,
    this.coordinator,
  });

  final KonataPlatform platform;
  final VideoPlaybackPreferences preferences;
  final VideoPlaybackPreferencesStore store;
  final AudiophileSafetyCoordinator? coordinator;

  @override
  Widget build(BuildContext context) {
    final windows = platform == KonataPlatform.windows;
    final mode = windows
        ? preferences.bitstreamPassthrough
              ? AudioOutputRouteMode.bitstreamPassthrough
              : preferences.qualityConfig.exclusiveAudioOutput
              ? AudioOutputRouteMode.exclusiveAudioOutput
              : AudioOutputRouteMode.sharedResampled
        : preferences.androidBitPerfectUsb
        ? AudioOutputRouteMode.androidBitPerfectUsb
        : AudioOutputRouteMode.sharedResampled;
    final direct =
        mode == AudioOutputRouteMode.exclusiveAudioOutput ||
        mode == AudioOutputRouteMode.androidBitPerfectUsb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('输出模式', style: KonataTheme.bodyLabelStyle(context.palette)),
        const SizedBox(height: 8),
        KonataDropdown<AudioOutputRouteMode>(
          key: const ValueKey('video_audio_route_mode'),
          value: mode,
          options: [
            const KonataDropdownOption(
              value: AudioOutputRouteMode.sharedResampled,
              label: '系统共享输出',
            ),
            if (windows) ...[
              const KonataDropdownOption(
                value: AudioOutputRouteMode.exclusiveAudioOutput,
                label: 'WASAPI 独占',
              ),
              const KonataDropdownOption(
                value: AudioOutputRouteMode.bitstreamPassthrough,
                label: 'HDMI / S/PDIF 透传',
              ),
            ] else
              const KonataDropdownOption(
                value: AudioOutputRouteMode.androidBitPerfectUsb,
                label: 'USB DAC 逐位直通',
              ),
          ],
          onChanged: (mode) =>
              store.setAudioOutputRoute(mode, platform: platform),
        ),
        const SizedBox(height: 8),
        if (mode == AudioOutputRouteMode.bitstreamPassthrough)
          Text(
            '请求压缩码流透传，与软件 DSP 互斥；需兼容功放及音轨。',
            style: KonataTheme.captionStyle(context.palette),
          ),
        if (direct) ...[
          Text(
            '请求独占或逐位输出；未核验并解锁前保留安全限幅。',
            style: KonataTheme.captionStyle(context.palette),
          ),
          if (coordinator case final safety?)
            Align(
              alignment: Alignment.centerLeft,
              child: KonataPillButton.secondary(
                key: const ValueKey('video_sheet_audiophile_unlock_button'),
                compact: true,
                label: '核验与解锁',
                icon: Icons.shield_outlined,
                onPressed: () => unawaited(
                  showVideoAudioUnlockDialog(context, store, safety),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

Future<void> showVideoAudioUnlockDialog(
  BuildContext context,
  VideoPlaybackPreferencesStore store,
  AudiophileSafetyCoordinator coordinator,
) async {
  final prefs = store.read();
  final routeMode = coordinator.resolveRouteMode(prefs.audiophilePreferences);
  bool routeUnchanged() {
    final latest = store.read();
    return coordinator.resolveRouteMode(latest.audiophilePreferences) ==
            routeMode &&
        latest.qualityConfig.audioDevice == prefs.qualityConfig.audioDevice;
  }

  final canProbe =
      routeMode == AudioOutputRouteMode.exclusiveAudioOutput ||
      routeMode == AudioOutputRouteMode.androidBitPerfectUsb;

  final confirmed = await showKonataGlassDialog<bool>(
    context: context,
    builder: (dialogCtx) {
      String? probeNotice;
      var probing = false;
      return StatefulBuilder(
        builder: (innerCtx, setDialogState) {
          final p = innerCtx.palette;
          final verified = coordinator.deviceSafetyState.isBackendMeterVerified;
          return KonataGlassDialog(
            title: '当次会话满幅输出安全确认',
            width: 460,
            actions: [
              KonataPillButton.ghost(
                label: '保持安全限幅',
                onPressed: () => Navigator.of(dialogCtx).pop(false),
              ),
              if (!verified && canProbe)
                KonataPillButton.ghost(
                  label: probing ? '检测中…' : '检测直通链路',
                  onPressed: probing
                      ? null
                      : () async {
                          setDialogState(() {
                            probing = true;
                            probeNotice = null;
                          });
                          if (!routeUnchanged()) {
                            Navigator.of(dialogCtx).pop(false);
                            return;
                          }
                          final res = await coordinator
                              .verifyActiveHardwareRoute(
                                prefs.audiophilePreferences,
                              );
                          if (dialogCtx.mounted) {
                            setDialogState(() {
                              probing = false;
                              probeNotice = res.detail;
                            });
                          }
                        },
                ),
              KonataPillButton.primary(
                label: verified ? '确认解锁本次满幅' : '验证门锁状态',
                onPressed: probing || !verified
                    ? null
                    : () => Navigator.of(dialogCtx).pop(true),
              ),
            ],
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  verified
                      ? '当前外设已完成直通核验，确认后将仅对本次会话解锁安全限幅。'
                      : '${AudiophileSafetyPolicy.unverifiedFullScaleLockReason}。',
                  style: TextStyle(color: p.textSecondary, fontSize: 13),
                ),
                if (probeNotice != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    probeNotice!,
                    style: TextStyle(color: p.accent, fontSize: 12),
                  ),
                ],
              ],
            ),
          );
        },
      );
    },
  );

  if (confirmed == true && context.mounted) {
    if (!routeUnchanged()) {
      showKonataToast(context, '输出路由已变更，请重新核验', isError: true);
      return;
    }
    final unlocked = await coordinator.confirmSessionFullScaleUnlock(
      prefs.audiophilePreferences,
    );
    if (!context.mounted) return;
    showKonataToast(
      context,
      unlocked
          ? '已核验硬件直通链路并解锁本次会话满幅输出'
          : AudiophileSafetyPolicy.unverifiedFullScaleLockReason,
      isError: !unlocked,
    );
  }
}
