import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';
import 'audio_playing_bars.dart';

/// 专辑队列列表（支持普通曲目、`CUE` 分轨动态展开/折叠与激活高光）。
class AudioQueueListView extends StatefulWidget {
  /// 创建队列列表。
  const AudioQueueListView({
    super.key,
    required this.controller,
    required this.snapshot,
  });

  final AudioPlaybackController controller;
  final AudioPlaybackSnapshot snapshot;

  @override
  State<AudioQueueListView> createState() => _AudioQueueListViewState();
}

class _AudioQueueListViewState extends State<AudioQueueListView> {
  final _scrollController = ScrollController();
  ({String id, int index, int count, double extent})? _lastTarget;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // 仅在当前曲目或列表结构改变时定位，普通滚动和播放进度不抢占用户操作。
  void _revealActive(List<AudioQueueDisplayRow> rows, double extent) {
    final index = rows.indexWhere((row) => row.isActive);
    if (index < 0) {
      _lastTarget = null;
      return;
    }
    final target = (
      id: rows[index].item.itemId,
      index: index,
      count: rows.length,
      extent: extent,
    );
    if (_lastTarget == target) return;
    _lastTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lastTarget != target || !_scrollController.hasClients) {
        return;
      }
      final position = _scrollController.position;
      if (!position.hasContentDimensions) return;
      final start = 24 + index * extent;
      final end = start + extent;
      if (start >= position.pixels + 12 &&
          end <= position.pixels + position.viewportDimension - 12) {
        return;
      }
      final next = (start - (position.viewportDimension - extent) / 2)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (next != position.pixels) _scrollController.jumpTo(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = AudioPlaybackQueueBuilder.buildDisplayRows(
      queue: widget.snapshot.queue,
      currentIndex: widget.snapshot.currentIndex,
    );
    if (rows.isEmpty) {
      _lastTarget = null;
      return Center(
        child: Text(
          '当前播放队列为空',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.56),
            fontSize: 14,
          ),
        ),
      );
    }

    final scaler = MediaQuery.textScalerOf(context);
    final extent =
        30 +
        1.3 *
            (scaler.scale(KonataPlaybackTokens.queueRowTitleActiveFontSize) +
                scaler.scale(KonataPlaybackTokens.queueRowSubtitleFontSize));
    _revealActive(rows, extent);
    return KonataDraggableScrollbar(
      controller: _scrollController,
      trackInsets: const EdgeInsets.only(top: 24, bottom: 32, right: 4),
      builder: (_, scrollController) => ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0, 0.06, 0.94, 1],
        ).createShader(bounds),
        blendMode: BlendMode.dstIn,
        child: ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(4, 24, 6, 32),
          itemCount: rows.length,
          itemExtent: extent,
          itemBuilder: (context, idx) {
            final row = rows[idx];
            final item = row.item;
            final isActive = row.isActive;
            final isCueHeader = row.kind == AudioQueueDisplayRowKind.cueHeader;
            final cuePath = item.cueSheetPath;
            final isCueExpanded =
                cuePath != null &&
                widget.snapshot.expandedCuePaths.contains(
                  AudioPlaybackQueueBuilder.normalizeQueuePath(
                    cuePath,
                  ).toLowerCase(),
                );

            if (isCueHeader && cuePath != null) {
              return _QueueRowTile(
                title: item.isCueTrack ? item.album : item.title,
                subtitle: null,
                leadingIcon: Icons.album_outlined,
                trailingText: isCueExpanded ? '收起' : '展开',
                isActive: isActive,
                playing: widget.controller.playingListenable,
                onTap: () =>
                    unawaited(widget.controller.toggleCueExpansion(cuePath)),
              );
            }

            final durSec = item.durationSeconds.round();
            return _QueueRowTile(
              title: item.title,
              subtitle: item.artist.isNotEmpty ? item.artist : item.album,
              leadingText: item.cueTrackIndex != null
                  ? item.cueTrackIndex!.toString().padLeft(2, '0')
                  : '${row.queueIndex + 1}'.padLeft(2, '0'),
              trailingText: durSec > 0
                  ? PlaybackRecordHelper.formatClock(durSec)
                  : null,
              isActive: isActive,
              playing: widget.controller.playingListenable,
              indented: row.kind == AudioQueueDisplayRowKind.cueTrack,
              onTap: () => unawaited(
                widget.controller.playQueueIndex(
                  row.queueIndex,
                  manualSelection: true,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 弹出发烧音频 `-12 dBFS` 安全门锁验证与输出设备调节弹窗。
Future<void> showAudiophileSafetyDialog(
  BuildContext context,
  AudioPlaybackController controller, {
  bool forceDarkTheme = true,
}) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (dialogCtx) {
      final body = ValueListenableBuilder<AudioPlaybackSnapshot>(
        valueListenable: controller.snapshotListenable,
        builder: (context, snap, _) {
          final p = context.palette;
          final plan = snap.audiophilePlan;
          final safety = snap.audiophileSafetyState;
          final routeLabel = switch (plan.routeMode) {
            AudioOutputRouteMode.sharedResampled => '系统共享重采样',
            AudioOutputRouteMode.exclusiveAudioOutput => '桌面独占直通',
            AudioOutputRouteMode.bitstreamPassthrough => 'HDMI / S/PDIF 透传',
            AudioOutputRouteMode.androidBitPerfectUsb => 'USB DAC 逐位直通',
          };

          return KonataGlassDialog(
            title: '音频安全设置',
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      KonataSpecBadge(
                        label: routeLabel,
                        icon: Icons.surround_sound_outlined,
                      ),
                      KonataSpecBadge(
                        label: plan.safetyLimiterEngaged
                            ? '-12 dBFS 限幅保护生效中'
                            : '未挂接末级限幅',
                        highlighted: plan.safetyLimiterEngaged,
                        icon: Icons.verified_user_outlined,
                      ),
                    ],
                  ),
                  if (plan.fullScaleLockNotice != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      plan.fullScaleLockNotice!,
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      KonataPillButton.secondary(
                        label: safety.isBackendMeterVerified
                            ? '硬件链路已实证'
                            : '实证当前硬件直通链路',
                        compact: true,
                        icon: Icons.fact_check_outlined,
                        onPressed: () => unawaited(
                          controller.verifyAudiophileHardwareRoute(),
                        ),
                      ),
                      KonataPillButton.primary(
                        label: '解锁当次会话满幅输出',
                        compact: true,
                        icon: Icons.lock_open_rounded,
                        onPressed: () =>
                            unawaited(controller.confirmFullScaleUnlock()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  KonataPillButton.ghost(
                    label: '恢复并重新锁定 -12 dBFS 安全天花板',
                    compact: true,
                    icon: Icons.shield_outlined,
                    onPressed: () => unawaited(
                      controller.setAudiophileSafetyLimiterEnabled(true),
                    ),
                  ),
                  if (snap.availableAudioDevices.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      '可用音频输出终端（切换设备会自动重置安全门锁）',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final dev in snap.availableAudioDevices.take(8))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: KonataListTile(
                          title: dev.description.isNotEmpty
                              ? dev.description
                              : dev.name,
                          subtitle: dev.name,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          onTap: () =>
                              unawaited(controller.selectAudioDevice(dev.name)),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      );
      if (!forceDarkTheme) return body;
      return Theme(data: KonataTheme.darkTheme(), child: body);
    },
  );
}

class _QueueRowTile extends StatelessWidget {
  const _QueueRowTile({
    required this.title,
    this.subtitle,
    this.leadingText,
    this.leadingIcon,
    this.trailingText,
    required this.isActive,
    required this.onTap,
    this.indented = false,
    this.playing,
  });

  final String title;
  final String? subtitle;
  final String? leadingText;
  final IconData? leadingIcon;
  final String? trailingText;
  final bool isActive;
  final VoidCallback onTap;
  final bool indented;
  final ValueListenable<bool>? playing;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(left: indented ? 14 : 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: isActive && playing != null
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: AudioPlayingBars(
                        playing: playing!,
                        color: Colors.white,
                      ),
                    )
                  : leadingIcon != null
                  ? Icon(
                      leadingIcon,
                      size: 18,
                      color: isActive
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.72),
                    )
                  : Text(
                      leadingText ?? '',
                      style: TextStyle(
                        color: isActive
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.56),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.90),
                      fontSize: isActive
                          ? KonataPlaybackTokens.queueRowTitleActiveFontSize
                          : KonataPlaybackTokens.queueRowTitleInactiveFontSize,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.56),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailingText != null) ...[
              const SizedBox(width: 8),
              Text(
                trailingText!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.58),
                  fontSize: 11.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
