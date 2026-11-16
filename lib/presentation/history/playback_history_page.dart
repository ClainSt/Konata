import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_dispatcher.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/playback_providers.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../audio/mini_audio_bar.dart';
import '../detail/work_detail_page.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../video/embedded_video_page.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_page_header.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';

/// 播放记录时间轴页面。
class PlaybackHistoryPage extends ConsumerStatefulWidget {
  /// 创建播放记录页面。
  const PlaybackHistoryPage({super.key});

  @override
  ConsumerState<PlaybackHistoryPage> createState() =>
      _PlaybackHistoryPageState();
}

class _PlaybackHistoryPageState extends ConsumerState<PlaybackHistoryPage> {
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _progressLabel(PlaybackRecord rec) {
    if (rec.isCompleted) return '已看完';
    if (rec.positionSeconds > 0 && rec.durationSeconds > 0) {
      return '观看至 ${PlaybackRecord.formatClock(rec.positionSeconds)} / '
          '${PlaybackRecord.formatClock(rec.durationSeconds)}';
    }
    if (rec.positionSeconds > 0) {
      return '观看至 ${PlaybackRecord.formatClock(rec.positionSeconds)}';
    }
    return '刚刚打开';
  }

  Future<void> _confirmClearAll(BuildContext context, WidgetRef ref) async {
    final ok = await showKonataGlassDialog<bool>(
      context: context,
      builder: (ctx) => KonataGlassDialog(
        width: 390,
        title: '清空播放记录',
        onClose: () => Navigator.of(ctx).pop(false),
        actions: [
          KonataPillButton.ghost(
            label: '取消',
            compact: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          KonataPillButton.primary(
            label: '确认清空',
            compact: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
        child: const Text('确认清空全部观看历史记录？此操作不会影响本地或远程媒体文件。'),
      ),
    );
    if (ok == true) {
      await ref.read(playbackCoordinatorProvider).clearAllHistory();
      if (context.mounted) {
        showKonataToast(context, '已清空全部播放记录');
      }
    }
  }

  Future<void> _resumeRecord({
    required BuildContext context,
    required WidgetRef ref,
    required PlaybackRecord rec,
    required PreferredPlaybackEngine overrideEngine,
  }) async {
    final navigator = Navigator.of(context);
    final bundle = await ref.read(workDetailBundleProvider(rec.workId).future);
    if (bundle == null) {
      if (context.mounted) {
        showKonataToast(context, '关联作品已不存在或已被移除', isError: true);
      }
      return;
    }
    Episode? targetEp;
    for (final ep in bundle.episodes) {
      if (ep.id == rec.episodeId) {
        targetEp = ep;
        break;
      }
    }
    if (targetEp == null) {
      if (context.mounted) {
        showKonataToast(context, '该条记录对应的剧集已不存在', isError: true);
      }
      return;
    }
    final epVariants = bundle.variantsForEpisode(targetEp.id);
    if (epVariants.isEmpty) {
      if (context.mounted) {
        showKonataToast(context, '该剧集暂无可用视频文件', isError: true);
      }
      return;
    }
    MediaVariant targetVariant = epVariants.first;
    for (final v in epVariants) {
      if (v.id == rec.variantId) {
        targetVariant = v;
        break;
      }
    }
    final decision = await ref
        .read(playbackDispatcherProvider)
        .dispatchVideoVariant(
          bundle: bundle,
          episode: targetEp,
          variant: targetVariant,
          startSeconds: rec.isCompleted ? 0 : rec.positionSeconds,
          overrideEngine: overrideEngine,
        );
    switch (decision) {
      case OpenBuiltinVideoDecision(:final request):
        await EmbeddedVideoPage.push(navigator, request);
      case LaunchedExternalVideoDecision(:final result):
        if (context.mounted && result.message.isNotEmpty) {
          showKonataToast(context, result.message, isError: !result.launched);
        }
    }
  }

  Future<void> _showRowMenu({
    required BuildContext context,
    required WidgetRef ref,
    required Offset globalPos,
    required PlaybackRecord rec,
  }) async {
    final pos = RelativeRect.fromLTRB(
      globalPos.dx,
      globalPos.dy,
      globalPos.dx,
      globalPos.dy,
    );
    final action = await showMenu<String>(
      context: context,
      position: pos,
      items: [
        const PopupMenuItem<String>(
          value: 'builtin',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_display_outlined, size: 17),
              SizedBox(width: 8),
              Text('使用内置播放器续播'),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'external',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.open_in_new_rounded, size: 17),
              SizedBox(width: 8),
              Text('使用外部播放器续播'),
            ],
          ),
        ),
        if (!rec.isCompleted)
          const PopupMenuItem<String>(
            value: 'complete',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline_rounded, size: 17),
                SizedBox(width: 8),
                Text('标为已看'),
              ],
            ),
          ),
        const PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded, size: 17),
              SizedBox(width: 8),
              Text('删除记录'),
            ],
          ),
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'builtin':
        await _resumeRecord(
          context: context,
          ref: ref,
          rec: rec,
          overrideEngine: PreferredPlaybackEngine.builtinLibmpv,
        );
      case 'external':
        await _resumeRecord(
          context: context,
          ref: ref,
          rec: rec,
          overrideEngine: PreferredPlaybackEngine.externalPlayer,
        );
      case 'complete':
        await ref.read(playbackCoordinatorProvider).markRecordCompleted(rec);
      case 'delete':
        await ref.read(playbackCoordinatorProvider).deleteHistoryRecord(rec);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final historyAsync = ref.watch(playbackHistoryProvider);
    final itemsAsync = ref.watch(libraryItemsProvider);
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final bottomClearance = ref.watch(miniAudioBottomClearanceProvider);
    final hasRecords =
        (historyAsync.valueOrNull ?? const <PlaybackRecord>[]).isNotEmpty;

    final workById = <String, WorkLibraryItem>{
      for (final item in itemsAsync.valueOrNull ?? const <WorkLibraryItem>[])
        item.work.id: item,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KonataPageHeader(
          title: '播放记录',
          actions: [
            if (hasRecords)
              KonataPillButton.secondary(
                label: '清空全部',
                icon: Icons.delete_sweep_outlined,
                compact: true,
                onPressed: () => _confirmClearAll(context, ref),
              ),
          ],
        ),
        Expanded(
          child: historyAsync.when(
            data: (records) {
              if (records.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.history_rounded,
                        size: 48,
                        color: p.textMuted,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '暂无播放记录',
                        style: KonataTheme.cardTitleStyle(p, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '在任意番剧详情页点击播放后，将在此按时间轴展示',
                        style: KonataTheme.captionStyle(p, fontSize: 13),
                      ),
                    ],
                  ),
                );
              }

              return KonataDraggableScrollbar(
                controller: _scrollCtrl,
                builder: (_, ctrl) => ListView.separated(
                  controller: ctrl,
                  padding: EdgeInsets.fromLTRB(
                    KonataTheme.pageHorizontalPadding,
                    0,
                    KonataTheme.pageHorizontalPadding,
                    28 + bottomClearance,
                  ),
                    itemCount: records.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, index) {
                      final rec = records[index];
                      final item = workById[rec.workId];
                      final work = item?.work;
                      final epLabel =
                          EpisodeTitleFormatter.formatHistorySubtitle(
                            record: rec,
                            work: work,
                            mainEpisodeCount: item?.episodeCount,
                          );
                      final progressText = _progressLabel(rec);

                      return GestureDetector(
                        onSecondaryTapUp: (details) => _showRowMenu(
                          context: context,
                          ref: ref,
                          globalPos: details.globalPosition,
                          rec: rec,
                        ),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      WorkDetailPage(workId: rec.workId),
                                ),
                              );
                            },
                            child: KonataSurfaceCard(
                            padding: const EdgeInsets.all(14),
                            enableHover: true,
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 46,
                                    height: 64,
                                    child: work?.posterPath != null
                                        ? ManagedImage(
                                            work!.posterPath!,
                                            loader: imageLoader,
                                            owner: work.id,
                                            fit: BoxFit.cover,
                                          )
                                        : Container(color: p.softFill),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: double.infinity,
                                        child: EllipsisTextWithTooltip(
                                          text: work?.title ?? '未知作品',
                                          maxLines: 1,
                                          style: TextStyle(
                                            color: p.textPrimary,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      SizedBox(
                                        width: double.infinity,
                                        child: EllipsisTextWithTooltip(
                                          text: epLabel,
                                          maxLines: 1,
                                          style: TextStyle(
                                            color: p.textSecondary,
                                            fontSize: 12.5,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: [
                                          Text(
                                            progressText,
                                            style: TextStyle(
                                              color: rec.isCompleted
                                                  ? p.success
                                                  : p.accent,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          if (!rec.isCompleted &&
                                              rec.progressRatio > 0) ...[
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: SizedBox(
                                                height: 3.5,
                                                child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(2),
                                                  child:
                                                      LinearProgressIndicator(
                                                        value:
                                                            rec.progressRatio,
                                                        backgroundColor:
                                                            p.softFill,
                                                        valueColor:
                                                            AlwaysStoppedAnimation(
                                                              p.accent,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 28),
                                Text(
                                  MediaDisplayFormatter.formatDateTimeMinute(
                                    rec.playedAt,
                                  ),
                                  style: TextStyle(
                                    color: p.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                if (!rec.isCompleted)
                                  IconButton(
                                    tooltip: '标为已看',
                                    onPressed: () => ref
                                        .read(playbackCoordinatorProvider)
                                        .markRecordCompleted(rec),
                                    icon: Icon(
                                      Icons.check_circle_outline_rounded,
                                      size: 18,
                                      color: p.textSecondary,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                IconButton(
                                  tooltip: '删除记录',
                                  onPressed: () => ref
                                      .read(playbackCoordinatorProvider)
                                      .deleteHistoryRecord(rec),
                                  icon: Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                    color: p.textMuted,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                        ),
                        ),
                      );
                    },
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Text(
                  '加载播放记录失败: $err',
                  style: TextStyle(color: p.danger),
                ),
              ),
            ),
          ),
        ],
      );
  }
}
