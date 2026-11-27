import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';
import 'immersive_audio_queue_and_safety.dart';

/// 音频播放、发烧直通 `-12 dBFS` 安全保护、回放增益与桌面外部转发设置面板。
class SettingsAudioPanel extends StatelessWidget {
  /// 构造音频设置分区面板。
  const SettingsAudioPanel({
    super.key,
    required this.preferences,
    this.controller,
    this.isDesktopPlatform = true,
    this.isAndroidPlatform = false,
  });

  /// 基于 `ScopedPrefsStore(playback_audio)` 的强类型偏好读写器。
  final AudioPlaybackPreferences preferences;

  /// 可选活跃音频控制器（存在时设置变更立即热更新至音频管线）。
  final AudioPlaybackController? controller;

  /// 当前是否运行于桌面平台（控制桌面独占与外部转发设置项显隐）。
  final bool isDesktopPlatform;

  /// 当前是否运行于 Android 平台（控制 USB DAC 逐位直通选项显隐）。
  final bool isAndroidPlatform;

  void _updateAndSync(
    AudioPlaybackPrefsData Function(AudioPlaybackPrefsData current) transform,
  ) {
    final next = preferences.update(transform);
    final ctrl = controller;
    if (ctrl != null) {
      unawaited(ctrl.syncPreferencesFromStore(overridePrefs: next));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // 手机窄屏采用紧凑右侧控件，桌面宽屏保持原尺寸。
    final compact = isAndroidPlatform && MediaQuery.sizeOf(context).width < 600;
    final dropdownWidth = compact ? 128.0 : 165.0;
    final sliderWidth = compact ? 136.0 : 180.0;
    return StreamBuilder<AudioPlaybackPrefsData>(
      stream: preferences.watch(),
      initialData: preferences.read(),
      builder: (context, snapshot) {
        final prefs = snapshot.data ?? preferences.read();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 一、发烧音频安全链路与直通策略。
            ListenableBuilder(
              listenable:
                  controller?.snapshotListenable ??
                  const AlwaysStoppedAnimation(0),
              builder: (context, _) {
                final active = controller?.snapshot;
                final unlocked =
                    active?.isActive == true &&
                    active!.audiophileSafetyState.allowFullScaleBypass;
                return KonataSurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '输出与安全保护',
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          KonataSpecBadge(
                            label: unlocked ? '已解锁' : '保护中',
                            highlighted: !unlocked,
                            icon: Icons.verified_user_outlined,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      AdaptiveSettingTile(
                        title: '-12 dBFS 安全限幅',
                        subtitle: '更换设备或未经核验时自动限幅。',
                        trailing: KonataSwitch(
                          value: !unlocked,
                          semanticLabel: '安全限幅',
                          onChanged: (val) {
                            final ctrl = controller;
                            if (!val) {
                              if (ctrl != null) {
                                unawaited(
                                  showAudiophileSafetyDialog(context, ctrl),
                                );
                              } else {
                                showKonataToast(
                                  context,
                                  '请先启动音频播放并核验直通链路。',
                                  isError: true,
                                );
                              }
                              return;
                            }
                            if (ctrl != null) {
                              unawaited(
                                ctrl
                                    .setAudiophileSafetyLimiterEnabled(true)
                                    .then((_) {
                                      if (context.mounted) {
                                        showKonataToast(context, '安全门锁已恢复');
                                      }
                                    })
                                    .catchError((Object error) {
                                      if (context.mounted) {
                                        showKonataToast(
                                          context,
                                          '恢复安全门锁失败',
                                          isError: true,
                                        );
                                      }
                                    }),
                              );
                            } else {
                              preferences.update(
                                (p) => p.copyWith(
                                  audiophileSafetyLimiterEnabled: true,
                                ),
                              );
                            }
                          },
                        ),
                      ),
                      if (controller != null)
                        KonataListTile(
                          title: '硬件核验与解锁',
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          estimatedTrailingWidth: 24,
                          trailing: Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: palette.textMuted,
                          ),
                          onTap: () => unawaited(
                            showAudiophileSafetyDialog(context, controller!),
                          ),
                        ),
                      if (isDesktopPlatform)
                        AdaptiveSettingTile(
                          title: '默认 CD 音频引擎',
                          estimatedTrailingWidth: 300,
                          trailing:
                              KonataSegmentedCapsule<PreferredPlaybackEngine>(
                                key: const ValueKey('audio_engine_selector'),
                                compact: true,
                                selected: prefs.preferredAudioEngine,
                                options: const [
                                  KonataSegmentOption(
                                    value:
                                        PreferredPlaybackEngine.builtinLibmpv,
                                    label: '内置流光音频',
                                  ),
                                  KonataSegmentOption(
                                    value: PreferredPlaybackEngine.desktopRelay,
                                    label: '外部播放器',
                                  ),
                                ],
                                onChanged: (e) => _updateAndSync(
                                  (p) => p.copyWith(preferredAudioEngine: e),
                                ),
                              ),
                        ),
                      AdaptiveSettingTile(
                        title: '重采样精度',
                        minLeadingWidth: compact ? 112 : 140,
                        estimatedTrailingWidth: dropdownWidth,
                        trailing: SizedBox(
                          width: dropdownWidth,
                          child: KonataDropdown<int>(
                            key: const ValueKey('audio_resampler_precision'),
                            value: prefs.audioResamplerPrecision,
                            dense: true,
                            options: const [
                              KonataDropdownOption(
                                value: 20,
                                label: '20-bit (轻量)',
                              ),
                              KonataDropdownOption(
                                value: 24,
                                label: '24-bit (高精)',
                              ),
                              KonataDropdownOption(
                                value: 28,
                                label: '28-bit (推荐)',
                              ),
                              KonataDropdownOption(
                                value: 32,
                                label: '32-bit (极致)',
                              ),
                            ],
                            onChanged: (v) => _updateAndSync(
                              (p) => p.copyWith(audioResamplerPrecision: v),
                            ),
                          ),
                        ),
                      ),
                      if (isDesktopPlatform) ...[
                        AdaptiveSettingTile(
                          title: 'WASAPI 独占输出',
                          subtitle: '绕过系统混音器，独占声卡。',
                          trailing: KonataSwitch(
                            value: prefs.exclusiveAudioOutput,
                            onChanged: (val) => _updateAndSync(
                              (p) => p.copyWith(exclusiveAudioOutput: val),
                            ),
                          ),
                        ),
                        AdaptiveSettingTile(
                          title: 'HDMI / S/PDIF 源码透传',
                          subtitle: '与软件 DSP 互斥。',
                          trailing: KonataSwitch(
                            value: prefs.bitstreamPassthrough,
                            onChanged: (val) => _updateAndSync(
                              (p) => p.copyWith(bitstreamPassthrough: val),
                            ),
                          ),
                        ),
                      ],
                      if (isAndroidPlatform)
                        AdaptiveSettingTile(
                          title: 'USB DAC 逐位直通',
                          subtitle: '需 Android 14+ 及兼容设备。',
                          trailing: KonataSwitch(
                            value: prefs.androidBitPerfectUsb,
                            onChanged: (val) => _updateAndSync(
                              (p) => p.copyWith(androidBitPerfectUsb: val),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
            // 二、回放增益、音高保持与常规音控偏好。
            KonataSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '增益与音量',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AdaptiveSettingTile(
                    title: '回放增益',
                    subtitle: '根据响度标签平衡音量。',
                    minLeadingWidth: compact ? 112 : 140,
                    estimatedTrailingWidth: dropdownWidth,
                    trailing: SizedBox(
                      width: dropdownWidth,
                      child: KonataDropdown<AudioReplayGainMode>(
                        key: const ValueKey('audio_replay_gain'),
                        value: prefs.replayGainMode,
                        dense: true,
                        options: [
                          for (final mode in AudioReplayGainMode.values)
                            KonataDropdownOption(
                              value: mode,
                              label: compact
                                  ? switch (mode) {
                                      AudioReplayGainMode.none => '关闭',
                                      AudioReplayGainMode.track => '按单曲',
                                      AudioReplayGainMode.album => '按专辑',
                                    }
                                  : mode.label,
                            ),
                        ],
                        onChanged: (m) => _updateAndSync(
                          (p) => p.copyWith(replayGainMode: m),
                        ),
                      ),
                    ),
                  ),
                  AdaptiveSettingTile(
                    title:
                        '前置增益 (${prefs.replayGainPreampDb.toStringAsFixed(1)} dB)',
                    subtitle: '受安全限幅保护（启用时）。',
                    minLeadingWidth: compact ? 112 : 140,
                    estimatedTrailingWidth: sliderWidth,
                    trailing: SizedBox(
                      width: sliderWidth,
                      child: Slider(
                        key: const ValueKey('audio_preamp_slider'),
                        value: prefs.replayGainPreampDb,
                        min: -12.0,
                        max: 6.0,
                        divisions: 36,
                        onChanged: (v) => _updateAndSync(
                          (p) => p.copyWith(replayGainPreampDb: v),
                        ),
                      ),
                    ),
                  ),
                  AdaptiveSettingTile(
                    title: '起播音量 (${prefs.defaultVolume.round()}%)',
                    minLeadingWidth: compact ? 112 : 140,
                    estimatedTrailingWidth: sliderWidth,
                    trailing: SizedBox(
                      width: sliderWidth,
                      child: Slider(
                        key: const ValueKey('audio_volume_slider'),
                        value: prefs.defaultVolume,
                        min: 5.0,
                        max: 100.0,
                        divisions: 19,
                        onChanged: (v) =>
                            _updateAndSync((p) => p.copyWith(defaultVolume: v)),
                      ),
                    ),
                  ),
                  AdaptiveSettingTile(
                    title: '变速保持音高',
                    trailing: KonataSwitch(
                      value: prefs.keepPitch,
                      onChanged: (val) =>
                          _updateAndSync((p) => p.copyWith(keepPitch: val)),
                    ),
                  ),
                  AdaptiveSettingTile(
                    title: '页内音频小窗',
                    trailing: KonataSwitch(
                      value: prefs.audioFloatingMiniEnabled,
                      onChanged: (val) => _updateAndSync(
                        (p) => p.copyWith(audioFloatingMiniEnabled: val),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
