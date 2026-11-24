import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';

/// 仅直连控制器叶子 `ValueNotifier<Duration>` 的音频进度条，拖动过程绝不重建外围舞台。
class AudioLeafDurationScrubber extends StatefulWidget {
  /// 构造叶子进度条组件。
  const AudioLeafDurationScrubber({
    super.key,
    required this.positionListenable,
    required this.durationListenable,
    required this.onSeekTo,
    this.compact = false,
  });

  /// 叶子当前逻辑播放位置。
  final ValueListenable<Duration> positionListenable;

  /// 叶子当前曲目总时长。
  final ValueListenable<Duration> durationListenable;

  /// 松手定位回调。
  final Future<void> Function(Duration position) onSeekTo;

  /// 是否使用紧凑视觉尺寸（适配手机端）。
  final bool compact;

  @override
  State<AudioLeafDurationScrubber> createState() =>
      _AudioLeafDurationScrubberState();
}

class _AudioLeafDurationScrubberState extends State<AudioLeafDurationScrubber> {
  double? _draggingSeconds;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<Duration>(
        valueListenable: widget.durationListenable,
        builder: (context, duration, _) {
          final totalSec = duration.inMilliseconds > 0
              ? duration.inMilliseconds / 1000.0
              : 0.0;
          return ValueListenableBuilder<Duration>(
            valueListenable: widget.positionListenable,
            builder: (context, position, _) {
              final rawPosSec = position.inMilliseconds / 1000.0;
              final displaySec = _draggingSeconds ??
                  (totalSec > 0 ? rawPosSec.clamp(0.0, totalSec) : 0.0);
              final sliderMax = totalSec > 0.1 ? totalSec : 1.0;
              final sliderVal = displaySec.clamp(0.0, sliderMax);
              final timeStyle = TextStyle(
                color: Colors.white.withValues(alpha: 0.78),
                fontSize: widget.compact ? 11.0 : 12.0,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w500,
              );

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: widget.compact ? 3.5 : 4.5,
                      activeTrackColor: Colors.white.withValues(alpha: 0.92),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
                      thumbColor: Colors.white,
                      overlayColor: Colors.white.withValues(alpha: 0.18),
                    ),
                    child: Slider(
                      value: sliderVal,
                      min: 0.0,
                      max: sliderMax,
                      onChangeStart: totalSec > 0.1
                          ? (val) {
                              setState(() => _draggingSeconds = val);
                            }
                          : null,
                      onChanged: totalSec > 0.1
                          ? (val) {
                              setState(() => _draggingSeconds = val);
                            }
                          : null,
                      onChangeEnd: totalSec > 0.1
                          ? (val) {
                              setState(() => _draggingSeconds = null);
                              unawaited(
                                widget.onSeekTo(
                                  Duration(milliseconds: (val * 1000.0).round()),
                                ),
                              );
                            }
                          : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          PlaybackRecordHelper.formatClock(
                            displaySec.round(),
                          ),
                          style: timeStyle,
                        ),
                        Text(
                          totalSec > 0
                              ? PlaybackRecordHelper.formatClock(
                                  totalSec.round(),
                                )
                              : '--:--',
                          style: timeStyle,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// 沉浸式音频舞台底部 Salt 风格透明玻璃胶囊控制条。
class AudioPlaybackCapsule extends StatelessWidget {
  /// 构造沉浸音频控制胶囊。
  const AudioPlaybackCapsule({
    super.key,
    required this.controller,
    required this.snapshot,
    required this.sidePanels,
    required this.onToggleQueue,
    required this.onOpenSafetyDialog,
    required this.onOpenSidePanel,
    this.onRelayToDesktop,
    this.onToggleDesktopMini,
    this.isQueueOpen = false,
    this.activeSidePanelId,
    this.compact = false,
  });

  /// 音频播放控制器。
  final AudioPlaybackController controller;

  /// 低频不可变会话快照。
  final AudioPlaybackSnapshot snapshot;

  /// 按 `PlayerMediaMode.audio` 过滤后的声明式扩展侧栏按钮（例如歌词校准面板）。
  final List<PlayerSidePanelContribution> sidePanels;

  /// 开关队列侧栏或底部队列弹窗回调。
  final VoidCallback onToggleQueue;

  /// 打开 `-12 dBFS` 发烧安全与输出设备管理弹窗回调。
  final VoidCallback onOpenSafetyDialog;

  /// 点击打开外部扩展侧栏回调。
  final ValueChanged<PlayerSidePanelContribution> onOpenSidePanel;

  /// 桌面端外发接力回调（非空时显示接力按钮）。
  final VoidCallback? onRelayToDesktop;

  /// 桌面端切换顶置迷你窗回调。
  final VoidCallback? onToggleDesktopMini;

  /// 当前是否正展开队列面板。
  final bool isQueueOpen;

  /// 当前正打开的扩展侧栏标识。
  final String? activeSidePanelId;

  /// 紧凑宽度模式（适配手机竖屏与矮横屏）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final loopIcon = switch (snapshot.loopMode) {
      AudioLoopMode.sequence => Icons.repeat_rounded,
      AudioLoopMode.loopAll => Icons.repeat_rounded,
      AudioLoopMode.loopOne => Icons.repeat_one_rounded,
    };
    final loopTooltip = switch (snapshot.loopMode) {
      AudioLoopMode.sequence => '顺序播放',
      AudioLoopMode.loopAll => '列表循环',
      AudioLoopMode.loopOne => '单曲循环',
    };
    final loopActive = snapshot.loopMode != AudioLoopMode.sequence;

    return KonataGlassCapsule(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 20,
        vertical: compact ? 10 : 12,
      ),
      radius: compact ? 24 : 28,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AudioLeafDurationScrubber(
            positionListenable: controller.positionListenable,
            durationListenable: controller.durationListenable,
            onSeekTo: controller.seekToTrackPosition,
            compact: compact,
          ),
          SizedBox(height: compact ? 4 : 6),
          Row(
            children: [
              // 左侧模式与音量/安全徽标区。
              KonataCapsuleIconButton(
                icon: Icons.shuffle_rounded,
                tooltip: snapshot.shuffleEnabled ? '关闭随机播放' : '开启随机播放',
                color: Colors.white.withValues(alpha: 0.85),
                highlighted: snapshot.shuffleEnabled,
                onTap: controller.toggleShuffle,
                size: compact ? 16 : 20,
                fixedSize: compact ? 30.0 : 38.0,
              ),
              SizedBox(width: compact ? 2 : 4),
              KonataCapsuleIconButton(
                icon: loopIcon,
                tooltip: loopTooltip,
                color: Colors.white.withValues(alpha: 0.85),
                highlighted: loopActive,
                onTap: controller.cycleLoopMode,
                size: compact ? 16 : 20,
                fixedSize: compact ? 30.0 : 38.0,
              ),
              if (!compact) ...[
                const SizedBox(width: 8),
                KonataVolumeControl(
                  volume: snapshot.volume / 100.0,
                  isMuted: snapshot.isMuted,
                  onVolumeChanged: (v) =>
                      unawaited(controller.setVolume(v * 100.0)),
                  onToggleMute: () => unawaited(controller.toggleMute()),
                ),
              ],
              const Spacer(),
              // 居中三键主播控区：仅播放键订阅叶子 `playingListenable`。
              KonataCapsuleIconButton(
                icon: Icons.skip_previous_rounded,
                tooltip: '上一曲',
                color: Colors.white,
                onTap: () => unawaited(controller.previous()),
                size: compact ? 20 : 26,
                fixedSize: compact ? 34.0 : 42.0,
              ),
              SizedBox(width: compact ? 6 : 10),
              ValueListenableBuilder<bool>(
                valueListenable: controller.playingListenable,
                builder: (context, isPlaying, _) {
                  return KonataCapsuleIconButton(
                    icon: isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    tooltip: isPlaying ? '暂停 (Space)' : '继续播放 (Space)',
                    color: Colors.white,
                    highlighted: true,
                    size: compact ? 24 : 30,
                    fixedSize: compact ? 42.0 : 52.0,
                    onTap: () => unawaited(controller.togglePlayPause()),
                  );
                },
              ),
              SizedBox(width: compact ? 6 : 10),
              KonataCapsuleIconButton(
                icon: Icons.skip_next_rounded,
                tooltip: '下一曲',
                color: Colors.white,
                onTap: () => unawaited(controller.next(manual: true)),
                size: compact ? 20 : 26,
                fixedSize: compact ? 34.0 : 42.0,
              ),
              const Spacer(),
              // 右侧动态插件面板、安全直通、置顶小窗与队列按钮。
              for (final panel in sidePanels) ...[
                KonataCapsuleIconButton(
                  icon: KonataIconRegistry.resolve(panel.iconKey),
                  tooltip: panel.label,
                  color: Colors.white.withValues(alpha: 0.86),
                  highlighted: activeSidePanelId == panel.id,
                  size: compact ? 16 : 20,
                  fixedSize: compact ? 30.0 : 38.0,
                  onTap: () => onOpenSidePanel(panel),
                ),
                SizedBox(width: compact ? 2 : 4),
              ],
              KonataCapsuleIconButton(
                icon: snapshot.audiophilePlan.safetyLimiterEngaged
                    ? Icons.verified_user_outlined
                    : Icons.graphic_eq_rounded,
                tooltip: snapshot.audiophilePlan.safetyLimiterEngaged
                    ? '发烧安全输出 (-12 dBFS 已保护)'
                    : '发烧安全与直通控制',
                color: Colors.white.withValues(alpha: 0.86),
                highlighted: snapshot.audiophilePlan.safetyLimiterEngaged,
                size: compact ? 16 : 20,
                fixedSize: compact ? 30.0 : 38.0,
                onTap: onOpenSafetyDialog,
              ),
              if (onRelayToDesktop != null && !compact) ...[
                const SizedBox(width: 4),
                KonataCapsuleIconButton(
                  icon: Icons.open_in_new_rounded,
                  tooltip: '接力到外部发烧播放器',
                  color: Colors.white.withValues(alpha: 0.86),
                  size: 20,
                  fixedSize: 38.0,
                  onTap: onRelayToDesktop,
                ),
              ],
              if (onToggleDesktopMini != null && !compact) ...[
                const SizedBox(width: 4),
                KonataCapsuleIconButton(
                  icon: snapshot.isDesktopMiniWindow
                      ? Icons.open_in_full_rounded
                      : Icons.picture_in_picture_alt_rounded,
                  tooltip: snapshot.isDesktopMiniWindow ? '还原主窗口' : '置顶便携小窗',
                  color: Colors.white.withValues(alpha: 0.86),
                  highlighted: snapshot.isDesktopMiniWindow,
                  size: 20,
                  fixedSize: 38.0,
                  onTap: onToggleDesktopMini,
                ),
              ],
              SizedBox(width: compact ? 2 : 4),
              KonataCapsuleIconButton(
                icon: Icons.queue_music_rounded,
                tooltip: '播放队列 (${snapshot.queue.length})',
                color: Colors.white.withValues(alpha: 0.88),
                highlighted: isQueueOpen,
                size: compact ? 16 : 20,
                fixedSize: compact ? 30.0 : 38.0,
                onTap: onToggleQueue,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
