import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_dispatcher.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/playback_providers.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../audio/mini_audio_bar.dart';
import '../detail/work_detail_page.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../video/embedded_video_page.dart';
import '../widgets/design_system/adaptive_action_header.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';
import '../widgets/playback/konata_foobar_beefweb_dialog.dart';
import 'playback_history_cards.dart';

/// 播放记录分类页签（视频 / 音频）。
enum PlaybackHistoryCategory { video, audio }

enum _HistoryBatchMode { markCompleted, delete }

/// 播放记录页面（支持全端音视频五层紧凑卡片、桌面双列等高网格与批量多选管理）。
class PlaybackHistoryPage extends ConsumerStatefulWidget {
  /// 创建播放记录页面。
  const PlaybackHistoryPage({super.key});

  @override
  ConsumerState<PlaybackHistoryPage> createState() =>
      _PlaybackHistoryPageState();
}

class _PlaybackHistoryPageState extends ConsumerState<PlaybackHistoryPage> {
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _selectionFocusNode = FocusNode();
  PlaybackHistoryCategory _activeTab = PlaybackHistoryCategory.video;
  _HistoryBatchMode? _batchMode;
  final Set<String> _selectedIds = <String>{};

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _selectionFocusNode.dispose();
    super.dispose();
  }

  bool _isAudioRecord(PlaybackRecord rec, WorkLibraryItem? item) {
    if (rec.isAudioRecord) return true;
    final variants = item?.variants;
    if (variants != null) {
      for (final v in variants) {
        if (v.id == rec.variantId && v.assetKind == AssetKind.cdAlbum) {
          return true;
        }
      }
    }
    return false;
  }

  void _switchTab(PlaybackHistoryCategory next) {
    if (_activeTab == next) return;
    setState(() {
      _activeTab = next;
      _batchMode = null;
      _selectedIds.clear();
    });
  }

  void _enterBatchMode(_HistoryBatchMode mode) {
    setState(() {
      _batchMode = mode;
      _selectedIds.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _selectionFocusNode.requestFocus();
    });
  }

  void _exitBatchMode() {
    if (_batchMode == null && _selectedIds.isEmpty) return;
    setState(() {
      _batchMode = null;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleSelectAll(List<PlaybackRecord> records) {
    setState(() {
      if (_selectedIds.length == records.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(records.map((r) => r.id));
      }
    });
  }

  Future<void> _confirmBatchAction(
    BuildContext context,
    WidgetRef ref,
    List<PlaybackRecord> records,
  ) async {
    final mode = _batchMode;
    if (mode == null) return;
    final targets = records
        .where((r) => _selectedIds.contains(r.id))
        .toList(growable: false);
    if (targets.isEmpty) return;

    final isAudio = _activeTab == PlaybackHistoryCategory.audio;
    final isDelete = mode == _HistoryBatchMode.delete;
    final markActionLabel = isAudio ? '标记为已听' : '标记为已看';
    final completedStateLabel = isAudio ? '已听完' : '已看完';
    final ok = await showKonataGlassDialog<bool>(
      context: context,
      builder: (ctx) => KonataGlassDialog(
        width: 410,
        title: isDelete ? '清理播放记录' : markActionLabel,
        onClose: () => Navigator.of(ctx).pop(false),
        actions: [
          KonataPillButton.ghost(
            label: '取消',
            compact: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          isDelete
              ? KonataPillButton.danger(
                  label: '确认清理',
                  compact: true,
                  onPressed: () => Navigator.of(ctx).pop(true),
                )
              : KonataPillButton.primary(
                  label: '确认标记',
                  compact: true,
                  onPressed: () => Navigator.of(ctx).pop(true),
                ),
        ],
        child: Text(
          isDelete
              ? '确认清理选中的 ${targets.length} 条播放记录？此操作不会影响本地或远程媒体文件。'
              : '确认将选中的 ${targets.length} 条播放记录标记为「$completedStateLabel」？',
        ),
      ),
    );
    if (ok != true) return;

    final coordinator = ref.read(playbackCoordinatorProvider);
    if (isDelete) {
      await coordinator.deleteHistoryRecords(targets);
    } else {
      await coordinator.markRecordsCompleted(targets);
    }
    if (!mounted) return;
    _exitBatchMode();
    if (context.mounted) {
      showKonataToast(
        context,
        isDelete
            ? '已清理 ${targets.length} 条播放记录'
            : '已将 ${targets.length} 条记录标记为${isAudio ? '已听' : '已看'}',
      );
    }
  }

  Future<void> _openWorkDetail(
    BuildContext context,
    PlaybackRecord rec,
    WorkLibraryItem? item,
  ) async {
    var targetId = rec.workId;
    if (item == null) {
      final redirects = ref.read(workRedirectMapProvider);
      targetId = resolveWorkRedirectChain(redirects, targetId);
      final found = await ref
          .read(libraryRepositoryProvider)
          .findWorkById(targetId);
      if (!context.mounted) return;
      if (found == null) {
        showKonataToast(context, '该作品记录已变更或被移出媒体库');
        return;
      }
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => WorkDetailPage(workId: targetId)),
    );
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
        await EmbeddedVideoPage.push(navigator, request, ref: ref);
      case LaunchedExternalVideoDecision(:final result):
        if (context.mounted && result.message.isNotEmpty) {
          showKonataToast(context, result.message, isError: !result.launched);
        }
    }
  }

  Future<void> _resumeAudioRecord({
    required BuildContext context,
    required WidgetRef ref,
    required PlaybackRecord rec,
    PreferredPlaybackEngine? overrideEngine,
  }) async {
    final bundle = await ref.read(workDetailBundleProvider(rec.workId).future);
    if (bundle == null) {
      if (context.mounted) {
        showKonataToast(context, '关联作品已不存在或已被移除', isError: true);
      }
      return;
    }
    final trackMatch = RegExp(
      r'^cd::(.+?)::track_(\d+)$',
    ).firstMatch(rec.episodeId);
    final extractedCueId = trackMatch?.group(1);
    final cueTrackNumber = trackMatch != null
        ? int.tryParse(trackMatch.group(2)!)
        : null;

    MediaVariant? targetVariant;
    if (extractedCueId != null) {
      for (final v in bundle.cdVariants) {
        if (v.id == extractedCueId) {
          targetVariant = v;
          break;
        }
      }
    }
    if (targetVariant == null) {
      for (final v in bundle.cdVariants) {
        if (v.id == rec.variantId) {
          targetVariant = v;
          break;
        }
      }
    }
    targetVariant ??= bundle.cdVariants.isNotEmpty
        ? bundle.cdVariants.first
        : null;
    if (targetVariant == null) {
      if (context.mounted) {
        showKonataToast(context, '未找到对应 CD 音频文件', isError: true);
      }
      return;
    }
    final resolvedTarget = targetVariant;
    final resumeSec = rec.isCompleted ? 0 : rec.positionSeconds;
    if (!context.mounted) return;
    await ExternalAudioRelayUiHelper.dispatchWithGuide(
      context: context,
      ref: ref,
      action: ({required forceAllowWithoutBeefweb}) => ref
          .read(playbackDispatcherProvider)
          .playCdVariant(
            work: bundle.work,
            variant: resolvedTarget,
            cdPlaylist: bundle.cdVariants,
            sourcesById: bundle.sourcesById,
            overrideEngine: overrideEngine,
            expandImmersive: true,
            initialCueTrackNumber: cueTrackNumber,
            startSeconds: resumeSec,
            forceAllowWithoutBeefweb: forceAllowWithoutBeefweb,
          ),
    );
  }

  Future<void> _showRowMenu({
    required BuildContext context,
    required WidgetRef ref,
    required Offset globalPos,
    required PlaybackRecord rec,
    required bool isAudio,
  }) async {
    final pos = RelativeRect.fromLTRB(
      globalPos.dx,
      globalPos.dy,
      globalPos.dx,
      globalPos.dy,
    );
    final itemHeight = KonataAdaptiveTokens.isAndroid
        ? KonataAdaptiveTokens.touchTarget
        : kMinInteractiveDimension;
    final resumeLabel = KonataAdaptiveTokens.isAndroid
        ? (isAudio ? '继续收听' : '继续观看')
        : (isAudio ? '使用内置音频续播' : '使用内置播放器续播');
    final action = await showMenu<String>(
      context: context,
      position: pos,
      items: [
        PopupMenuItem<String>(
          value: 'builtin',
          height: itemHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isAudio
                    ? Icons.graphic_eq_rounded
                    : (KonataAdaptiveTokens.isAndroid
                          ? Icons.play_circle_outline_rounded
                          : Icons.smart_display_outlined),
                size: 17,
              ),
              const SizedBox(width: 8),
              Text(resumeLabel),
            ],
          ),
        ),
        if (KonataAdaptiveTokens.isWindows)
          PopupMenuItem<String>(
            value: 'external',
            height: itemHeight,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.open_in_new_rounded, size: 17),
                SizedBox(width: 8),
                Text('使用外部播放器续播'),
              ],
            ),
          ),
        if (!rec.isCompleted)
          PopupMenuItem<String>(
            value: 'complete',
            height: itemHeight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_outline_rounded, size: 17),
                const SizedBox(width: 8),
                Text(isAudio ? '标为已听' : '标为已看'),
              ],
            ),
          ),
        PopupMenuItem<String>(
          value: 'delete',
          height: itemHeight,
          child: const Row(
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
        if (isAudio) {
          await _resumeAudioRecord(
            context: context,
            ref: ref,
            rec: rec,
            overrideEngine: PreferredPlaybackEngine.builtinLibmpv,
          );
        } else {
          await _resumeRecord(
            context: context,
            ref: ref,
            rec: rec,
            overrideEngine: PreferredPlaybackEngine.builtinLibmpv,
          );
        }
      case 'external':
        if (isAudio) {
          await _resumeAudioRecord(
            context: context,
            ref: ref,
            rec: rec,
            overrideEngine: PreferredPlaybackEngine.desktopRelay,
          );
        } else {
          await _resumeRecord(
            context: context,
            ref: ref,
            rec: rec,
            overrideEngine: PreferredPlaybackEngine.desktopRelay,
          );
        }
      case 'complete':
        await ref.read(playbackCoordinatorProvider).markRecordCompleted(rec);
      case 'delete':
        await ref.read(playbackCoordinatorProvider).deleteHistoryRecord(rec);
    }
  }

  String? _resolveAudioDirectoryLabel(
    PlaybackRecord rec,
    WorkLibraryItem? item,
    Map<String, CdAlbumGroupSummary> cdSummaryCache,
  ) {
    if (item == null) {
      return null;
    }
    final summary = cdSummaryCache.putIfAbsent(item.work.id, () {
      final cdVariants = item.variants
          .where((v) => v.assetKind == AssetKind.cdAlbum)
          .toList(growable: false);
      return SupplementarySubclassifier.groupCdVariants(cdVariants);
    });
    final label = summary.byVariantId[rec.variantId]?.chipLabel.trim();
    if (label != null && label.isNotEmpty) {
      return label;
    }
    return null;
  }

  Widget _buildRecordItemCard({
    required BuildContext context,
    required PlaybackRecord rec,
    required WorkLibraryItem? item,
    required bool isAudio,
    required bool stretchHeight,
    required String? audioDirLabel,
    required ManagedImageLoader imageLoader,
  }) {
    final inSelection = _batchMode != null;
    final selected = inSelection && _selectedIds.contains(rec.id);
    final isDeleteMode = _batchMode == _HistoryBatchMode.delete;
    return PlaybackHistoryItemCard(
      record: rec,
      workItem: item,
      imageLoader: imageLoader,
      isAudio: isAudio,
      stretchHeight: stretchHeight,
      inSelection: inSelection,
      selected: selected,
      isDeleteMode: isDeleteMode,
      audioDirLabel: audioDirLabel,
      onTapCard: () {
        if (inSelection) {
          _toggleSelected(rec.id);
        } else {
          _openWorkDetail(context, rec, item);
        }
      },
      onShowMenu: (globalPos, targetRec, targetAudio) => _showRowMenu(
        context: context,
        ref: ref,
        globalPos: globalPos,
        rec: targetRec,
        isAudio: targetAudio,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final historyAsync = ref.watch(playbackHistoryProvider);
    final itemsAsync = ref.watch(libraryItemsProvider);
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final bottomClearance = KonataBottomClearanceScope.resolve(context, ref);
    final workById = <String, WorkLibraryItem>{
      for (final item in itemsAsync.valueOrNull ?? const <WorkLibraryItem>[])
        item.work.id: item,
    };

    final allRecords = historyAsync.valueOrNull ?? const <PlaybackRecord>[];
    final isAudioTab = _activeTab == PlaybackHistoryCategory.audio;
    final records = allRecords
        .where((r) {
          final isAudio = _isAudioRecord(r, workById[r.workId]);
          return isAudioTab ? isAudio : !isAudio;
        })
        .toList(growable: false);

    final hasRecords = records.isNotEmpty;
    final inSelection = _batchMode != null;
    final allSelected =
        hasRecords && records.every((r) => _selectedIds.contains(r.id));
    final selectedCount = records
        .where((r) => _selectedIds.contains(r.id))
        .length;
    final markCompletedLabel = isAudioTab ? '标记为已听' : '标记为已看';

    return Focus(
      focusNode: _selectionFocusNode,
      child: CallbackShortcuts(
        bindings: {
          if (inSelection)
            const SingleActivator(LogicalKeyboardKey.escape): _exitBatchMode,
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AdaptiveActionHeader(
              title: '播放记录',
              badge: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.15,
                child: KonataSegmentedCapsule<PlaybackHistoryCategory>(
                  compact: true,
                  options: const [
                    KonataSegmentOption(
                      value: PlaybackHistoryCategory.video,
                      label: '视频',
                    ),
                    KonataSegmentOption(
                      value: PlaybackHistoryCategory.audio,
                      label: '音频',
                    ),
                  ],
                  selected: _activeTab,
                  onChanged: _switchTab,
                ),
              ),
              primaryActions: [
                if (hasRecords && !inSelection) ...[
                  AdaptiveHeaderAction(
                    icon: Icons.done_all_rounded,
                    label: markCompletedLabel,
                    wideWidget: KonataPillButton.secondary(
                      label: markCompletedLabel,
                      icon: Icons.done_all_rounded,
                      compact: true,
                      onPressed: () =>
                          _enterBatchMode(_HistoryBatchMode.markCompleted),
                    ),
                    onPressed: () =>
                        _enterBatchMode(_HistoryBatchMode.markCompleted),
                  ),
                  AdaptiveHeaderAction(
                    icon: Icons.delete_sweep_outlined,
                    label: '清理记录',
                    wideWidget: KonataPillButton.secondary(
                      label: '清理记录',
                      icon: Icons.delete_sweep_outlined,
                      compact: true,
                      onPressed: () => _enterBatchMode(_HistoryBatchMode.delete),
                    ),
                    onPressed: () => _enterBatchMode(_HistoryBatchMode.delete),
                  ),
                ],
              ],
            ),
            if (inSelection)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  KonataAdaptiveTokens.isAndroid &&
                          MediaQuery.sizeOf(context).width <
                              KonataAdaptiveTokens.tabletBreakpoint
                      ? KonataAdaptiveTokens.horizontalInset
                      : KonataTheme.pageHorizontalPadding,
                  0,
                  KonataAdaptiveTokens.isAndroid &&
                          MediaQuery.sizeOf(context).width <
                              KonataAdaptiveTokens.tabletBreakpoint
                      ? KonataAdaptiveTokens.horizontalInset
                      : KonataTheme.pageHorizontalPadding,
                  10,
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '已选 $selectedCount / ${records.length}',
                      style: TextStyle(
                        color: p.textSecondary,
                        fontSize: KonataTheme.fontSizeBodySm,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    KonataPillButton.ghost(
                      label: allSelected ? '取消全选' : '全选',
                      compact: true,
                      onPressed: hasRecords
                          ? () => _toggleSelectAll(records)
                          : null,
                    ),
                    KonataPillButton.ghost(
                      label: '取消',
                      compact: true,
                      onPressed: _exitBatchMode,
                    ),
                    if (_batchMode == _HistoryBatchMode.delete)
                      KonataPillButton.danger(
                        label: '确认清理',
                        icon: Icons.delete_outline_rounded,
                        compact: true,
                        onPressed: selectedCount > 0
                            ? () => _confirmBatchAction(context, ref, records)
                            : null,
                      )
                    else
                      KonataPillButton.primary(
                        label: '确认标记',
                        icon: Icons.check_rounded,
                        compact: true,
                        onPressed: selectedCount > 0
                            ? () => _confirmBatchAction(context, ref, records)
                            : null,
                      ),
                  ],
                ),
              ),
            Expanded(
              child: historyAsync.when(
                data: (loadedRecords) {
                  if (records.isEmpty) {
                    final emptyTitle = loadedRecords.isEmpty
                        ? '暂无播放记录'
                        : (isAudioTab ? '暂无音频播放记录' : '暂无视频播放记录');
                    final emptySubtitle = isAudioTab
                        ? '播放作品 CD / 无损音轨后，将在此按时间轴展示'
                        : '在任意番剧详情页点击播放后，将在此按时间轴展示';
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isAudioTab
                                ? Icons.album_outlined
                                : Icons.history_rounded,
                            size: 52,
                            color: p.textMuted,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            emptyTitle,
                            style: KonataTheme.cardTitleStyle(p, fontSize: KonataTheme.fontSizeTitleLg),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            emptySubtitle,
                            style: KonataTheme.captionStyle(p, fontSize: KonataTheme.fontSizeBodyMd),
                          ),
                        ],
                      ),
                    );
                  }

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final mqSize = MediaQuery.sizeOf(context);
                      final isPortraitTablet =
                          KonataAdaptiveTokens.isAndroid &&
                          mqSize.shortestSide >=
                              KonataAdaptiveTokens.tabletBreakpoint &&
                          mqSize.height >= mqSize.width;
                      final compactList =
                          KonataAdaptiveTokens.isAndroid &&
                          constraints.maxWidth <
                              KonataAdaptiveTokens.tabletBreakpoint;
                      final listPadH = compactList
                          ? KonataAdaptiveTokens.horizontalInset
                          : KonataTheme.pageHorizontalPadding;
                      final twoColumns =
                          !isPortraitTablet &&
                          constraints.maxWidth >=
                              PlaybackHistoryCardMetrics.twoColumnBreakpoint;
                      final rowCount = twoColumns
                          ? (records.length + 1) ~/ 2
                          : records.length;
                      final cdSummaryCache = <String, CdAlbumGroupSummary>{};

                      return KonataDraggableScrollbar(
                        controller: _scrollCtrl,
                        builder: (_, ctrl) => ListView.separated(
                          controller: ctrl,
                          padding: EdgeInsets.fromLTRB(
                            listPadH,
                            0,
                            listPadH,
                            36 + bottomClearance,
                          ),
                          itemCount: rowCount,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, rowIndex) {
                            if (!twoColumns) {
                              final rec = records[rowIndex];
                              final workItem = workById[rec.workId];
                              final dirLabel = isAudioTab
                                  ? _resolveAudioDirectoryLabel(
                                      rec,
                                      workItem,
                                      cdSummaryCache,
                                    )
                                  : null;
                              return _buildRecordItemCard(
                                context: context,
                                rec: rec,
                                item: workItem,
                                isAudio: isAudioTab,
                                stretchHeight: false,
                                audioDirLabel: dirLabel,
                                imageLoader: imageLoader,
                              );
                            }

                            final leftIndex = rowIndex * 2;
                            final rightIndex = leftIndex + 1;
                            final leftRec = records[leftIndex];
                            final rightRec = rightIndex < records.length
                                ? records[rightIndex]
                                : null;
                            final leftItem = workById[leftRec.workId];
                            final rightItem = rightRec != null
                                ? workById[rightRec.workId]
                                : null;
                            final leftDirLabel = isAudioTab
                                ? _resolveAudioDirectoryLabel(
                                    leftRec,
                                    leftItem,
                                    cdSummaryCache,
                                  )
                                : null;
                            final rightDirLabel =
                                (isAudioTab && rightRec != null)
                                ? _resolveAudioDirectoryLabel(
                                    rightRec,
                                    rightItem,
                                    cdSummaryCache,
                                  )
                                : null;

                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: _buildRecordItemCard(
                                    context: context,
                                    rec: leftRec,
                                    item: leftItem,
                                    isAudio: isAudioTab,
                                    stretchHeight: true,
                                    audioDirLabel: leftDirLabel,
                                    imageLoader: imageLoader,
                                  ),
                                ),
                                const SizedBox(
                                  width: PlaybackHistoryCardMetrics.colGap,
                                ),
                                Expanded(
                                  child: rightRec != null
                                      ? _buildRecordItemCard(
                                          context: context,
                                          rec: rightRec,
                                          item: rightItem,
                                          isAudio: isAudioTab,
                                          stretchHeight: true,
                                          audioDirLabel: rightDirLabel,
                                          imageLoader: imageLoader,
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            );
                          },
                        ),
                      );
                    },
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
        ),
      ),
    );
  }
}
