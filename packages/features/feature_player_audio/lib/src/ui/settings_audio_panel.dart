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
    return StreamBuilder<AudioPlaybackPrefsData>(
      stream: preferences.watch(),
      initialData: preferences.read(),
      builder: (context, snapshot) {
        final prefs = snapshot.data ?? preferences.read();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 一、发烧音频安全链路与直通策略。
            KonataSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '发烧输出与 -12 dBFS 防爆耳安全链',
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      KonataSpecBadge(
                        label: prefs.audiophileSafetyLimiterEnabled
                            ? '-12 dBFS 安全门锁开启'
                            : '用户已解锁满幅上限',
                        highlighted: prefs.audiophileSafetyLimiterEnabled,
                        icon: Icons.verified_user_outlined,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  AdaptiveSettingTile(
                    title: '启用发烧输出 -12 dBFS 安全天花板',
                    subtitle: '未经物理电平实证或新接入 DAC 时在末端强制串联限幅与 150ms 淡入斜坡',
                    trailing: KonataSwitch(
                      value: prefs.audiophileSafetyLimiterEnabled,
                      semanticLabel: '安全限幅',
                      onChanged: (val) {
                        final ctrl = controller;
                        if (ctrl != null) {
                          unawaited(
                            ctrl.setAudiophileSafetyLimiterEnabled(val),
                          );
                        } else {
                          preferences.update(
                            (p) =>
                                p.copyWith(audiophileSafetyLimiterEnabled: val),
                          );
                        }
                      },
                    ),
                  ),
                  if (controller != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 4),
                      child: KonataPillButton.secondary(
                        label: '检查硬件实证并管理当次会话满幅解锁',
                        compact: true,
                        icon: Icons.shield_outlined,
                        onPressed: () => unawaited(
                          showAudiophileSafetyDialog(context, controller!),
                        ),
                      ),
                    ),
                  if (isDesktopPlatform)
                    AdaptiveSettingTile(
                      title: '默认 CD 音频引擎',
                      subtitle: '内置音频支持沉浸式舞台、迷你播放器与分轨歌词',
                      estimatedTrailingWidth: 300,
                      trailing: KonataSegmentedCapsule<PreferredPlaybackEngine>(
                        key: const ValueKey('audio_engine_selector'),
                        compact: true,
                        selected: prefs.preferredAudioEngine,
                        options: const [
                          KonataSegmentOption(
                            value: PreferredPlaybackEngine.builtinLibmpv,
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
                    title: 'libsoxr 线性相位重采样精度',
                    subtitle: '在需要采样率变换时使用的精度档位（28-bit 为推荐高保真均衡值）',
                    estimatedTrailingWidth: 160,
                    trailing: SizedBox(
                      width: 165,
                      child: KonataDropdown<int>(
                        value: prefs.audioResamplerPrecision,
                        dense: true,
                        options: const [
                          KonataDropdownOption(value: 20, label: '20-bit (轻量)'),
                          KonataDropdownOption(value: 24, label: '24-bit (高精)'),
                          KonataDropdownOption(value: 28, label: '28-bit (推荐)'),
                          KonataDropdownOption(value: 32, label: '32-bit (极致)'),
                        ],
                        onChanged: (v) => _updateAndSync(
                          (p) => p.copyWith(audioResamplerPrecision: v),
                        ),
                      ),
                    ),
                  ),
                  if (isDesktopPlatform) ...[
                    AdaptiveSettingTile(
                      title: '桌面独占输出模式 (WASAPI Exclusive)',
                      subtitle: '绕过系统混音器以低抖动独占声卡（配合安全门锁防首次切设备爆音）',
                      trailing: KonataSwitch(
                        value: prefs.exclusiveAudioOutput,
                        onChanged: (val) => _updateAndSync(
                          (p) => p.copyWith(exclusiveAudioOutput: val),
                        ),
                      ),
                    ),
                    AdaptiveSettingTile(
                      title: 'HDMI / S/PDIF 压缩源码透传',
                      subtitle: '透传 AC3 / DTS 等原始压缩流至功放；与软件 DSP 严格互斥',
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
                      title: 'Android USB DAC 逐位直通协商',
                      subtitle: 'Android 14+ 外接解码器时优先协商 BIT_PERFECT 物理直出',
                      trailing: KonataSwitch(
                        value: prefs.androidBitPerfectUsb,
                        onChanged: (val) => _updateAndSync(
                          (p) => p.copyWith(androidBitPerfectUsb: val),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // 二、回放增益、音高保持与常规音控偏好。
            KonataSurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '回放增益与常规音控',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  AdaptiveSettingTile(
                    title: '回放增益 (ReplayGain)',
                    subtitle: '读取内嵌或标签中的响度元数据以平衡不同专辑间音量跳跃',
                    estimatedTrailingWidth: 165,
                    trailing: SizedBox(
                      width: 165,
                      child: KonataDropdown<AudioReplayGainMode>(
                        value: prefs.replayGainMode,
                        dense: true,
                        options: [
                          for (final mode in AudioReplayGainMode.values)
                            KonataDropdownOption(
                              value: mode,
                              label: mode.label,
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
                        '前置增益微调 (${prefs.replayGainPreampDb.toStringAsFixed(1)} dB)',
                    subtitle: '正向增量时将自动受末端 -12 dBFS 限幅保护约束',
                    estimatedTrailingWidth: 190,
                    trailing: SizedBox(
                      width: 180,
                      child: Slider(
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
                    title: '默认起播音量 (${prefs.defaultVolume.round()}%)',
                    subtitle: '新会话开启时的初始安全缩放百分比',
                    estimatedTrailingWidth: 190,
                    trailing: SizedBox(
                      width: 180,
                      child: Slider(
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
                    title: '变速保持音高不失真',
                    subtitle: '倍速播放期间启用 Scaletempo2 保持人声与乐器原调',
                    trailing: KonataSwitch(
                      value: prefs.keepPitch,
                      onChanged: (val) =>
                          _updateAndSync((p) => p.copyWith(keepPitch: val)),
                    ),
                  ),
                  AdaptiveSettingTile(
                    title: '启用页内可拖拽迷你悬浮唱片栏',
                    subtitle: '收起全屏音频舞台后在屏幕边角保留可自由拖拽与停靠的便携控制条',
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
