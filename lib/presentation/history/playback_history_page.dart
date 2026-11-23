import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../application/playback/playback_dispatcher.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/playback_providers.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/playback/playback_history_timeline.dart';
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

sealed class _TimelineListItem {
  const _TimelineListItem();
}

final class _DayHeaderItem extends _TimelineListItem {
  const _DayHeaderItem({
    required this.section,
    required this.showTopConnector,
  });

  final PlaybackHistoryDaySection section;
  final bool showTopConnector;
}

final class _WorkGroupRowItem extends _TimelineListItem {
  const _WorkGroupRowItem({
    required this.groups,
    required this.isLastRowInDay,
    required this.isLastSection,
  });

  final List<PlaybackHistoryWorkGroup> groups;
  final bool isLastRowInDay;
  final bool isLastSection;
}

/// 播放记录页面（日记式时间轴 + 单日作品聚合 + 原地展开分集剧照/专辑封面与进度条）。
class PlaybackHistoryPage extends ConsumerStatefulWidget {
  /// 创建播放记录页面。
  const PlaybackHistoryPage({super.key});

  @override
  ConsumerState<PlaybackHistoryPage> createState() =>
      _PlaybackHistoryPageState();
}

class _PlaybackHistoryPageState extends ConsumerState<PlaybackHistoryPage> {
  final ScrollController _videoScrollCtrl = ScrollController();
  final ScrollController _audioScrollCtrl = ScrollController();
  final FocusNode _selectionFocusNode = FocusNode();
  PlaybackHistoryCategory _activeTab = PlaybackHistoryCategory.video;
  _HistoryBatchMode? _batchMode;
  final Set<String> _selectedIds = <String>{};
  final Set<String> _expandedVideoGroups = <String>{};
  final Set<String> _expandedAudioGroups = <String>{};

  ScrollController get _activeScrollCtrl =>
      _activeTab == PlaybackHistoryCategory.audio
      ? _audioScrollCtrl
      : _videoScrollCtrl;

  Set<String> get _activeExpandedGroups =>
      _activeTab == PlaybackHistoryCategory.audio
      ? _expandedAudioGroups
      : _expandedVideoGroups;

  @override
  void dispose() {
    _videoScrollCtrl.dispose();
    _audioScrollCtrl.dispose();
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

  void _toggleExpanded(String groupKey) {
    setState(() {
      if (!_activeExpandedGroups.remove(groupKey)) {
        _activeExpandedGroups.add(groupKey);
      }
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

  void _toggleSelectedRecord(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleSelectedGroup(PlaybackHistoryWorkGroup group) {
    setState(() {
      final allSelected = group.records.every(
        (r) => _selectedIds.contains(r.id),
      );
      if (allSelected) {
        for (final r in group.records) {
          _selectedIds.remove(r.id);
        }
      } else {
        for (final r in group.records) {
          _selectedIds.add(r.id);
        }
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

  /// 点击作品封面进入作品详情页，并在返回播放记录页后精确恢复进入前的滚动位置。
  Future<void> _openWorkDetail(
    BuildContext context,
    PlaybackRecord rec,
    WorkLibraryItem? item,
  ) async {
    final scrollCtrl = _activeScrollCtrl;
    final savedOffset = scrollCtrl.hasClients ? scrollCtrl.offset : null;

    var targetId = rec.workId;
    if (item == null) {
      final redirects = ref.read(workRedirectMapProvider);
      targetId = resolveWorkRedirectChain(redirects, targetId);
      final found = await ref
          .read(libraryRepositoryProvider)
          .findWorkById(targetId);
      if (!context.mounted) return;
      if (found == null) {
        showKonataToast(context, '该作品记录已变更或被移出媒体库', isError: true);
        return;
      }
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => WorkDetailPage(workId: targetId)),
    );
    if (!mounted || savedOffset == null) return;

    // 返回时在下一帧复核滚动位置，防止详情页触发列表刷新后偏移归零回顶。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollCtrl.hasClients) return;
      final maxExtent = scrollCtrl.position.maxScrollExtent;
      final clamped = savedOffset.clamp(0.0, maxExtent);
      if ((scrollCtrl.offset - clamped).abs() > 0.5) {
        scrollCtrl.jumpTo(clamped);
      }
    });
  }

  Future<void> _resumeRecord({
    required BuildContext context,
    required WidgetRef ref,
    required PlaybackRecord rec,
    PreferredPlaybackEngine? overrideEngine,
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

  PopupMenuItem<String> _buildHistoryMenuItem({
    required String value,
    required double height,
    required IconData icon,
    required String label,
  }) => PopupMenuItem<String>(
    value: value,
    height: height,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 17), const SizedBox(width: 8), Text(label)],
    ),
  );

  Future<void> _resumeWithEngine({
    required BuildContext context,
    required WidgetRef ref,
    required PlaybackRecord rec,
    required bool isAudio,
    required PreferredPlaybackEngine engine,
  }) => isAudio
      ? _resumeAudioRecord(
          context: context,
          ref: ref,
          rec: rec,
          overrideEngine: engine,
        )
      : _resumeRecord(
          context: context,
          ref: ref,
          rec: rec,
          overrideEngine: engine,
        );

  Future<void> _showContextMenu({
    required BuildContext context,
    required WidgetRef ref,
    required Offset globalPos,
    required PlaybackRecord targetRecord,
    required List<PlaybackRecord> actionRecords,
    required bool isAudio,
    required bool showDetailAction,
    WorkLibraryItem? workItem,
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
    final isMulti = actionRecords.length > 1;
    final hasIncomplete = actionRecords.any((r) => !r.isCompleted);

    final action = await showMenu<String>(
      context: context,
      position: pos,
      items: [
        _buildHistoryMenuItem(
          value: 'builtin',
          height: itemHeight,
          icon: isAudio
              ? Icons.graphic_eq_rounded
              : (KonataAdaptiveTokens.isAndroid
                    ? Icons.play_circle_outline_rounded
                    : Icons.smart_display_outlined),
          label: resumeLabel,
        ),
        if (KonataAdaptiveTokens.isWindows)
          _buildHistoryMenuItem(
            value: 'external',
            height: itemHeight,
            icon: Icons.open_in_new_rounded,
            label: '使用外部播放器续播',
          ),
        if (showDetailAction)
          _buildHistoryMenuItem(
            value: 'detail',
            height: itemHeight,
            icon: Icons.info_outline_rounded,
            label: '查看作品详情',
          ),
        if (hasIncomplete)
          _buildHistoryMenuItem(
            value: 'complete',
            height: itemHeight,
            icon: Icons.check_circle_outline_rounded,
            label: isMulti
                ? '当日全部标为${isAudio ? '已听' : '已看'}'
                : (isAudio ? '标为已听' : '标为已看'),
          ),
        _buildHistoryMenuItem(
          value: 'delete',
          height: itemHeight,
          icon: Icons.delete_outline_rounded,
          label: isMulti ? '删除当日记录' : '删除记录',
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'builtin':
        await _resumeWithEngine(
          context: context,
          ref: ref,
          rec: targetRecord,
          isAudio: isAudio,
          engine: PreferredPlaybackEngine.builtinLibmpv,
        );
      case 'external':
        await _resumeWithEngine(
          context: context,
          ref: ref,
          rec: targetRecord,
          isAudio: isAudio,
          engine: PreferredPlaybackEngine.desktopRelay,
        );
      case 'detail':
        await _openWorkDetail(context, targetRecord, workItem);
      case 'complete':
        await ref
            .read(playbackCoordinatorProvider)
            .markRecordsCompleted(actionRecords);
      case 'delete':
        await ref
            .read(playbackCoordinatorProvider)
            .deleteHistoryRecords(actionRecords);
    }
  }

  Future<void> _showGroupMenu({
    required BuildContext context,
    required WidgetRef ref,
    required Offset globalPos,
    required PlaybackHistoryWorkGroup group,
    required WorkLibraryItem? workItem,
    required bool isAudio,
  }) => _showContextMenu(
    context: context,
    ref: ref,
    globalPos: globalPos,
    targetRecord: group.latestRecord,
    actionRecords: group.records,
    isAudio: isAudio,
    showDetailAction: true,
    workItem: workItem,
  );

  Future<void> _showEntryMenu({
    required BuildContext context,
    required WidgetRef ref,
    required Offset globalPos,
    required PlaybackRecord rec,
    required bool isAudio,
  }) => _showContextMenu(
    context: context,
    ref: ref,
    globalPos: globalPos,
    targetRecord: rec,
    actionRecords: [rec],
    isAudio: isAudio,
    showDetailAction: false,
  );

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

  List<_TimelineListItem> _flattenSections(
    List<PlaybackHistoryDaySection> sections, {
    required int columns,
  }) {
    final safeColumns = columns <= 1 ? 1 : 2;
    final flat = <_TimelineListItem>[];
    for (var sIdx = 0; sIdx < sections.length; sIdx++) {
      final section = sections[sIdx];
      final isLastSection = sIdx == sections.length - 1;
      flat.add(_DayHeaderItem(section: section, showTopConnector: sIdx > 0));
      for (var wIdx = 0; wIdx < section.works.length; wIdx += safeColumns) {
        final end = (wIdx + safeColumns).clamp(0, section.works.length);
        flat.add(
          _WorkGroupRowItem(
            groups: section.works.sublist(wIdx, end),
            isLastRowInDay: end >= section.works.length,
            isLastSection: isLastSection,
          ),
        );
      }
    }
    return flat;
  }

  Widget _buildWorkGroupCard({
    required BuildContext context,
    required PlaybackHistoryWorkGroup group,
    required Map<String, WorkLibraryItem> workById,
    required ManagedImageLoader imageLoader,
    required bool isAudioTab,
    required Set<String> expandedGroups,
    required bool isLastRowInDay,
    required bool isLastSection,
    required bool inSelection,
    required bool isDeleteMode,
    required Map<String, CdAlbumGroupSummary> cdSummaryCache,
  }) {
    return PlaybackHistoryWorkGroupCard(
      group: group,
      workItem: workById[group.workId],
      imageLoader: imageLoader,
      isAudio: isAudioTab,
      isExpanded: expandedGroups.contains(group.groupKey),
      isLastInDay: isLastRowInDay,
      isLastSection: isLastSection,
      inSelection: inSelection,
      selectedIds: _selectedIds,
      isDeleteMode: isDeleteMode,
      showTimelineRail: false,
      audioDirLabelResolver: (rec) => _resolveAudioDirectoryLabel(
        rec,
        workById[rec.workId],
        cdSummaryCache,
      ),
      onTapCover: () {
        if (inSelection) {
          _toggleSelectedGroup(group);
        } else {
          _openWorkDetail(
            context,
            group.latestRecord,
            workById[group.workId],
          );
        }
      },
      onTapCardBody: () {
        if (inSelection) {
          _toggleSelectedGroup(group);
        } else {
          _toggleExpanded(group.groupKey);
        }
      },
      onTapEntry: (rec) {
        if (inSelection) {
          _toggleSelectedRecord(rec.id);
        } else if (isAudioTab) {
          _resumeAudioRecord(context: context, ref: ref, rec: rec);
        } else {
          _resumeRecord(context: context, ref: ref, rec: rec);
        }
      },
      onShowGroupMenu: (globalPos, targetGroup, targetAudio) =>
          _showGroupMenu(
            context: context,
            ref: ref,
            globalPos: globalPos,
            group: targetGroup,
            workItem: workById[targetGroup.workId],
            isAudio: targetAudio,
          ),
      onShowEntryMenu: (globalPos, targetRec, targetAudio) =>
          _showEntryMenu(
            context: context,
            ref: ref,
            globalPos: globalPos,
            rec: targetRec,
            isAudio: targetAudio,
          ),
    );
  }

  Widget _buildTimelineBody({
    required BuildContext context,
    required KonataPalette p,
    required List<PlaybackRecord> loadedRecords,
    required List<PlaybackRecord> records,
    required Map<String, WorkLibraryItem> workById,
    required ManagedImageLoader imageLoader,
    required bool isAudioTab,
    required bool inSelection,
    required double bottomClearance,
  }) {
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
              isAudioTab ? Icons.album_outlined : Icons.history_rounded,
              size: 52,
              color: p.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              emptyTitle,
              style: KonataTheme.cardTitleStyle(
                p,
                fontSize: KonataTheme.fontSizeTitleLg,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              emptySubtitle,
              style: KonataTheme.captionStyle(
                p,
                fontSize: KonataTheme.fontSizeBodyMd,
              ),
            ),
          ],
        ),
      );
    }

    final sections = PlaybackHistoryTimelineBuilder.build(records);
    final cdSummaryCache = <String, CdAlbumGroupSummary>{};
    final scrollCtrl = _activeScrollCtrl;
    final expandedGroups = _activeExpandedGroups;
    final isDeleteMode = _batchMode == _HistoryBatchMode.delete;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compactList =
            KonataAdaptiveTokens.isAndroid &&
            constraints.maxWidth < KonataAdaptiveTokens.tabletBreakpoint;
        final listPadH = compactList
            ? KonataAdaptiveTokens.horizontalInset
            : KonataTheme.pageHorizontalPadding;
        final cardsAreaWidth =
            constraints.maxWidth -
            listPadH * 2 -
            PlaybackHistoryCardMetrics.timelineRailWidth -
            10.0;
        final columns =
            cardsAreaWidth >= PlaybackHistoryCardMetrics.twoColumnWorkBreakpoint
            ? 2
            : 1;
        final flatItems = _flattenSections(sections, columns: columns);

        return KonataDraggableScrollbar(
          controller: scrollCtrl,
          builder: (_, ctrl) => ListView.builder(
            key: PageStorageKey<String>(
              isAudioTab
                  ? 'playback_history_timeline_audio'
                  : 'playback_history_timeline_video',
            ),
            controller: ctrl,
            padding: EdgeInsets.fromLTRB(
              listPadH,
              4,
              listPadH,
              36 + bottomClearance,
            ),
            itemCount: flatItems.length,
            itemBuilder: (_, index) {
              final item = flatItems[index];
              return switch (item) {
                _DayHeaderItem(:final section, :final showTopConnector) =>
                  PlaybackHistoryDayHeader(
                    section: section,
                    showTopConnector: showTopConnector,
                  ),
                _WorkGroupRowItem(
                  :final groups,
                  :final isLastRowInDay,
                  :final isLastSection,
                ) =>
                  PlaybackHistoryTimelineRow(
                    columns: columns,
                    isLastRowInDay: isLastRowInDay,
                    isLastSection: isLastSection,
                    children: [
                      for (final group in groups)
                        _buildWorkGroupCard(
                          context: context,
                          group: group,
                          workById: workById,
                          imageLoader: imageLoader,
                          isAudioTab: isAudioTab,
                          expandedGroups: expandedGroups,
                          isLastRowInDay: isLastRowInDay,
                          isLastSection: isLastSection,
                          inSelection: inSelection,
                          isDeleteMode: isDeleteMode,
                          cdSummaryCache: cdSummaryCache,
                        ),
                    ],
                  ),
              };
            },
          ),
        );
      },
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
      for (final item in itemsAsync.value ?? const <WorkLibraryItem>[])
        item.work.id: item,
    };

    final loadedRecords = historyAsync.value;
    final allRecords = loadedRecords ?? const <PlaybackRecord>[];
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

    Widget bodyWidget;
    if (loadedRecords != null) {
      bodyWidget = _buildTimelineBody(
        context: context,
        p: p,
        loadedRecords: loadedRecords,
        records: records,
        workById: workById,
        imageLoader: imageLoader,
        isAudioTab: isAudioTab,
        inSelection: inSelection,
        bottomClearance: bottomClearance,
      );
    } else if (historyAsync.hasError) {
      bodyWidget = Center(
        child: Text(
          '加载播放记录失败: ${historyAsync.error}',
          style: TextStyle(color: p.danger),
        ),
      );
    } else {
      bodyWidget = const Center(child: CircularProgressIndicator());
    }

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
            Expanded(child: bodyWidget),
          ],
        ),
      ),
    );
  }
}
