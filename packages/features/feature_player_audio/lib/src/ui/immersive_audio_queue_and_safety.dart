import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/data.dart';
import '../state/state.dart';

/// 专辑队列列表（支持普通曲目、`CUE` 分轨动态展开/折叠与激活高光）。
class AudioQueueListView extends StatelessWidget {
  /// 创建队列列表。
  const AudioQueueListView({
    super.key,
    required this.controller,
    required this.snapshot,
  });

  final AudioPlaybackController controller;
  final AudioPlaybackSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final rows = AudioPlaybackQueueBuilder.buildDisplayRows(
      queue: snapshot.queue,
      currentIndex: snapshot.currentIndex,
    );
    if (rows.isEmpty) {
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

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, idx) {
        final row = rows[idx];
        final item = row.item;
        final isActive = row.isActive;
        final isCueHeader = row.kind == AudioQueueDisplayRowKind.cueHeader;
        final cuePath = item.cueSheetPath;
        final isCueExpanded =
            cuePath != null &&
            snapshot.expandedCuePaths.contains(
              AudioPlaybackQueueBuilder.normalizeQueuePath(
                cuePath,
              ).toLowerCase(),
            );

        if (isCueHeader && cuePath != null) {
          return _QueueRowTile(
            title: item.isCueTrack ? item.album : item.title,
            subtitle: isCueExpanded ? '已展开分轨 · 点击可折叠' : '点击展开 .cue 分轨清单',
            leadingIcon: Icons.album_outlined,
            trailingText: isCueExpanded ? '收起' : '展开',
            isActive: isActive,
            onTap: () => unawaited(controller.toggleCueExpansion(cuePath)),
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
          indented: row.kind == AudioQueueDisplayRowKind.cueTrack,
          onTap: () => unawaited(
            controller.playQueueIndex(row.queueIndex, manualSelection: true),
          ),
        );
      },
    );
  }
}

/// 弹出发烧音频 `-12 dBFS` 安全门锁验证与输出设备调节弹窗。
Future<void> showAudiophileSafetyDialog(
  BuildContext context,
  AudioPlaybackController controller,
) {
  return showKonataGlassDialog<void>(
    context: context,
    builder: (dialogCtx) {
      return ValueListenableBuilder<AudioPlaybackSnapshot>(
        valueListenable: controller.snapshotListenable,
        builder: (context, snap, _) {
          final plan = snap.audiophilePlan;
          final safety = snap.audiophileSafetyState;
          final routeLabel = switch (plan.routeMode) {
            AudioOutputRouteMode.sharedResampled => '系统共享重采样',
            AudioOutputRouteMode.exclusiveAudioOutput => '桌面独占直通',
            AudioOutputRouteMode.bitstreamPassthrough => 'HDMI / S/PDIF 透传',
            AudioOutputRouteMode.androidBitPerfectUsb => 'USB DAC 逐位直通',
          };

          return KonataGlassDialog(
            title: '发烧音频与 -12 dBFS 安全护耳链',
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      KonataSpecBadge(
                        label: routeLabel,
                        icon: Icons.surround_sound_outlined,
                      ),
                      const SizedBox(width: 8),
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
                        color: dialogCtx.palette.textSecondary,
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      KonataPillButton.secondary(
                        label: safety.isBackendMeterVerified
                            ? '硬件链路已实证'
                            : '实证当前硬件直通链路',
                        compact: true,
                        icon: Icons.fact_check_outlined,
                        onPressed: () =>
                            unawaited(controller.verifyAudiophileHardwareRoute()),
                      ),
                      const SizedBox(width: 10),
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
                        color: dialogCtx.palette.textPrimary,
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
  });

  final String title;
  final String? subtitle;
  final String? leadingText;
  final IconData? leadingIcon;
  final String? trailingText;
  final bool isActive;
  final VoidCallback onTap;
  final bool indented;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(left: indented ? 14 : 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isActive
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive
                ? Colors.white.withValues(alpha: 0.34)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: leadingIcon != null
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
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.90),
                      fontSize: 13.5,
                      fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
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
