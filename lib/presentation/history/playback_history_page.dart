import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/playback_dispatcher.dart';
import '../../application/playback/playback_preferences_provider.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/playback_providers.dart';
import '../../domain/formatting/media_display_formatter.dart';
import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../audio/mini_audio_bar.dart';
import '../audio/smart_cover_framing.dart';
import '../detail/work_detail_page.dart';
import '../theme/konata_adaptive_tokens.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../video/embedded_video_page.dart';
import '../widgets/design_system/adaptive_action_header.dart';
import '../widgets/design_system/ellipsis_text_with_tooltip.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';

/// 播放记录分类页签（视频 / 音频）。
enum PlaybackHistoryCategory { video, audio }

enum _HistoryBatchMode { markCompleted, delete }

/// 播放记录页面（桌面端响应式双列等高网格卡片 + 批量多选标记已看/清理记录）。
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

  static const double _twoColumnBreakpoint = 680.0;
  static const double _videoCoverWidth = 112.0;
  static const double _videoCoverHeight = 160.0;
  static const double _audioCoverSize = 120.0;
  static const double _cardPadding = 16.0;
  static const double _coverTextGap = 18.0;
  static const double _colGap = 14.0;

  // 统一排版字号与间距常量（渲染与双列等高测量严格同源）
  static const double _titleFontSize = 20.5;
  static const double _titleLineHeight = 1.28;
  static const double _subtitleFontSize = 15.5;
  static const double _audioDirFontSize = 13.5;
  static const double _audioDirTopGap = 5.0;
  static const double _progressFontSize = 14.0;
  static const double _dateFontSize = 13.5;
  static const double _progressBarHeight = 6.5;
  static const double _titleSubtitleGap = 8.0;
  static const double _progressBarGap = 10.0;

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

  String _progressLabel(PlaybackRecord rec, {required bool isAudio}) {
    if (rec.isCompleted) return isAudio ? '已听完' : '已看完';
    final verb = isAudio ? '收听至' : '观看至';
    if (rec.positionSeconds > 0 && rec.durationSeconds > 0) {
      return '$verb ${PlaybackRecord.formatClock(rec.positionSeconds)} / '
          '${PlaybackRecord.formatClock(rec.durationSeconds)}';
    }
    if (rec.positionSeconds > 0) {
      return '$verb ${PlaybackRecord.formatClock(rec.positionSeconds)}';
    }
    return '刚刚打开';
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
    final action = await showMenu<String>(
      context: context,
      position: pos,
      items: [
        if (!isAudio) ...[
          PopupMenuItem<String>(
            value: 'builtin',
            height: itemHeight,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.smart_display_outlined, size: 17),
                SizedBox(width: 8),
                Text('使用内置播放器续播'),
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
        ],
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

  double _measureSingleLineHeight(BuildContext context, TextStyle style) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final painter = TextPainter(
      text: TextSpan(text: 'Hg测试01', style: effective),
      maxLines: 1,
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    return painter.height;
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

  double _measureCardHeight({
    required BuildContext context,
    required WorkLibraryItem? item,
    required double titleMaxWidth,
    required double titleTrailingMinHeight,
    required double epLineHeight,
    required double extraAudioDirHeight,
    required double progressLineHeight,
    required double dateLineHeight,
    required double coverHeight,
  }) {
    final work = item?.work;
    final title = work?.title ?? '未知作品';
    final effectiveTitleStyle = DefaultTextStyle.of(context).style.merge(
      const TextStyle(
        fontSize: _titleFontSize,
        fontWeight: FontWeight.w700,
        height: _titleLineHeight,
      ),
    );
    final painter = TextPainter(
      text: TextSpan(text: title, style: effectiveTitleStyle),
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout(maxWidth: math.max(40.0, titleMaxWidth));

    final titleRowHeight = math.max(painter.height, titleTrailingMinHeight);
    final stackedBottomRow = titleMaxWidth < 260.0;
    final bottomRowH = stackedBottomRow
        ? (_progressBarHeight + 8.0 + dateLineHeight)
        : math.max(_progressBarHeight, dateLineHeight);
    final rightHeight =
        titleRowHeight +
        _titleSubtitleGap +
        epLineHeight +
        extraAudioDirHeight +
        16.0 +
        progressLineHeight +
        _progressBarGap +
        bottomRowH;
    return math.max(
      coverHeight + _cardPadding * 2 + 2,
      rightHeight + _cardPadding * 2 + 8,
    );
  }

  Widget _buildCard({
    required BuildContext context,
    required KonataPalette p,
    required PlaybackRecord rec,
    required WorkLibraryItem? item,
    required ManagedImageLoader imageLoader,
    required bool isAudio,
    required bool stretchHeight,
    String? audioDirLabel,
  }) {
    final work = item?.work;
    final epLabel = EpisodeTitleFormatter.formatHistorySubtitle(
      record: rec,
      work: work,
      mainEpisodeCount: item?.episodeCount,
    );
    final progressText = _progressLabel(rec, isAudio: isAudio);
    final inSelection = _batchMode != null;
    final selected = inSelection && _selectedIds.contains(rec.id);
    final isDeleteMode = _batchMode == _HistoryBatchMode.delete;
    final selectedAccent = isDeleteMode ? p.danger : p.accent;
    final poster =
        work?.posterPath ?? work?.bangumiPosterPath ?? work?.posterFallback;
    final showTouchMore = KonataAdaptiveTokens.isAndroid && !inSelection;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final compactCard =
        KonataAdaptiveTokens.isAndroid &&
        viewportWidth < KonataAdaptiveTokens.tabletBreakpoint;
    final veryNarrow = compactCard && viewportWidth < 380.0;
    final cardPad = veryNarrow ? 10.0 : (compactCard ? 12.0 : _cardPadding);
    final coverGap = veryNarrow ? 10.0 : (compactCard ? 12.0 : _coverTextGap);
    final coverWidth = isAudio
        ? (veryNarrow ? 74.0 : (compactCard ? 92.0 : _audioCoverSize))
        : (veryNarrow ? 74.0 : (compactCard ? 88.0 : _videoCoverWidth));
    final coverHeight = isAudio
        ? (veryNarrow ? 74.0 : (compactCard ? 92.0 : _audioCoverSize))
        : (veryNarrow ? 106.0 : (compactCard ? 126.0 : _videoCoverHeight));
    final coverRadius = isAudio ? 12.0 : 10.0;

    final Widget coverWidget = isAudio
        ? _AudioHistoryCover(
            workId: rec.workId,
            variantId: rec.variantId,
            fallbackPoster: poster,
            imageLoader: imageLoader,
            size: coverWidth,
          )
        : (poster != null && poster.isNotEmpty
              ? ManagedImage(
                  poster,
                  loader: imageLoader,
                  owner: work?.id ?? rec.workId,
                  artwork: ManagedArtwork.poster,
                  decodeWidth: 280,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _posterFallback(p, isAudio: false),
                )
              : _posterFallback(p, isAudio: false));

    final topBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                work?.title ?? '未知作品',
                softWrap: true,
                maxLines: veryNarrow ? 2 : null,
                overflow: veryNarrow ? TextOverflow.ellipsis : null,
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: veryNarrow
                      ? 15.5
                      : (compactCard ? 17.5 : _titleFontSize),
                  fontWeight: FontWeight.w700,
                  height: _titleLineHeight,
                ),
              ),
            ),
            if (inSelection) ...[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected ? selectedAccent : p.textMuted,
                ),
              ),
            ] else if (showTouchMore) ...[
              const SizedBox(width: 4),
              Builder(
                builder: (btnContext) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    final box = btnContext.findRenderObject() as RenderBox?;
                    final anchor = box != null
                        ? box.localToGlobal(box.size.center(Offset.zero))
                        : Offset.zero;
                    _showRowMenu(
                      context: context,
                      ref: ref,
                      globalPos: anchor,
                      rec: rec,
                      isAudio: isAudio,
                    );
                  },
                  child: SizedBox.square(
                    key: ValueKey('history_more_${rec.id}'),
                    dimension: KonataAdaptiveTokens.touchTarget,
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 20,
                      color: p.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: _titleSubtitleGap),
        EllipsisTextWithTooltip(
          text: epLabel,
          maxLines: 1,
          style: TextStyle(
            color: p.textSecondary,
            fontSize: _subtitleFontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (isAudio &&
            audioDirLabel != null &&
            audioDirLabel.trim().isNotEmpty) ...[
          const SizedBox(height: _audioDirTopGap),
          EllipsisTextWithTooltip(
            text: audioDirLabel.trim(),
            maxLines: 1,
            style: TextStyle(
              color: p.textMuted,
              fontSize: _audioDirFontSize,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ],
    );

    final bottomBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          progressText,
          style: KonataTheme.textStyle(
            color: rec.isCompleted ? p.success : p.progressFill,
            fontSize: _progressFontSize,
            weight: 600,
            tabularFigures: true,
          ),
        ),
        const SizedBox(height: _progressBarGap),
        LayoutBuilder(
          builder: (context, barBox) {
            final progressBar = SizedBox(
              height: _progressBarHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: rec.isCompleted ? 1.0 : rec.progressRatio,
                  backgroundColor: p.progressTrack,
                  valueColor: AlwaysStoppedAnimation(
                    rec.isCompleted ? p.success : p.progressFill,
                  ),
                ),
              ),
            );
            final dateLabel = MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.15,
              child: Text(
                MediaDisplayFormatter.formatDateTimeMinute(rec.playedAt),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: KonataTheme.textStyle(
                  color: p.textMuted,
                  fontSize: veryNarrow ? 12.0 : _dateFontSize,
                  weight: 500,
                  tabularFigures: true,
                ),
              ),
            );
            if (barBox.maxWidth < 260.0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  progressBar,
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: dateLabel),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: progressBar),
                const SizedBox(width: 10),
                Flexible(flex: 0, child: dateLabel),
              ],
            );
          },
        ),
      ],
    );

    final Widget card = KonataSurfaceCard(
      padding: EdgeInsets.all(cardPad),
      enableHover: !selected,
      backgroundColor: selected
          ? selectedAccent.withValues(alpha: p.isDark ? 0.14 : 0.08)
          : null,
      borderColor: selected ? selectedAccent.withValues(alpha: 0.72) : null,
      child: Row(
        crossAxisAlignment: stretchHeight
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.start,
        children: [
          Align(
            alignment: isAudio ? Alignment.center : Alignment.topCenter,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(coverRadius),
              child: SizedBox(
                width: coverWidth,
                height: coverHeight,
                child: coverWidget,
              ),
            ),
          ),
          SizedBox(width: coverGap),
          Expanded(
            child: stretchHeight
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [topBlock, bottomBlock],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      topBlock,
                      const SizedBox(height: 16),
                      bottomBlock,
                    ],
                  ),
          ),
        ],
      ),
    );

    return GestureDetector(
      onSecondaryTapUp: inSelection
          ? null
          : (details) => _showRowMenu(
              context: context,
              ref: ref,
              globalPos: details.globalPosition,
              rec: rec,
              isAudio: isAudio,
            ),
      onLongPressStart: inSelection
          ? null
          : (details) => _showRowMenu(
              context: context,
              ref: ref,
              globalPos: details.globalPosition,
              rec: rec,
              isAudio: isAudio,
            ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (inSelection) {
              _toggleSelected(rec.id);
            } else {
              _openWorkDetail(context, rec, item);
            }
          },
          child: card,
        ),
      ),
    );
  }

  Widget _posterFallback(KonataPalette p, {required bool isAudio}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.softFill,
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Center(
        child: Icon(
          isAudio ? Icons.album_outlined : Icons.movie_outlined,
          size: 30,
          color: p.textMuted,
        ),
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
    final activeCoverWidth = isAudioTab ? _audioCoverSize : _videoCoverWidth;
    final activeCoverHeight = isAudioTab ? _audioCoverSize : _videoCoverHeight;

    return Focus(
      focusNode: _selectionFocusNode,
      child: CallbackShortcuts(
        bindings: {
          if (inSelection)
            const SingleActivator(LogicalKeyboardKey.escape): _exitBatchMode,
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                        fontSize: 13,
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
                            style: KonataTheme.cardTitleStyle(p, fontSize: 18),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            emptySubtitle,
                            style: KonataTheme.captionStyle(p, fontSize: 14),
                          ),
                        ],
                      ),
                    );
                  }

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final compactList =
                          KonataAdaptiveTokens.isAndroid &&
                          constraints.maxWidth <
                              KonataAdaptiveTokens.tabletBreakpoint;
                      final listPadH = compactList
                          ? KonataAdaptiveTokens.horizontalInset
                          : KonataTheme.pageHorizontalPadding;
                      final twoColumns =
                          constraints.maxWidth >= _twoColumnBreakpoint;
                      final rowCount = twoColumns
                          ? (records.length + 1) ~/ 2
                          : records.length;
                      final contentWidth =
                          constraints.maxWidth - listPadH * 2;
                      final cardWidth = twoColumns
                          ? math.max(120.0, (contentWidth - _colGap) / 2)
                          : contentWidth;
                      final trailingWidth = inSelection
                          ? 30.0
                          : (KonataAdaptiveTokens.isAndroid ? 52.0 : 0.0);
                      final titleMaxWidth =
                          cardWidth -
                          _cardPadding * 2 -
                          2 -
                          activeCoverWidth -
                          _coverTextGap -
                          trailingWidth;
                      final epH = twoColumns
                          ? _measureSingleLineHeight(
                              context,
                              const TextStyle(
                                fontSize: _subtitleFontSize,
                                fontWeight: FontWeight.w500,
                              ),
                            )
                          : 0.0;
                      final progH = twoColumns
                          ? _measureSingleLineHeight(
                              context,
                              KonataTheme.textStyle(
                                color: p.progressFill,
                                fontSize: _progressFontSize,
                                weight: 600,
                                tabularFigures: true,
                              ),
                            )
                          : 0.0;
                      final dateH = twoColumns
                          ? _measureSingleLineHeight(
                              context,
                              KonataTheme.textStyle(
                                color: p.textMuted,
                                fontSize: _dateFontSize,
                                weight: 500,
                                tabularFigures: true,
                              ),
                            )
                          : 0.0;
                      final audioDirLineH = twoColumns && isAudioTab
                          ? _measureSingleLineHeight(
                              context,
                              const TextStyle(
                                fontSize: _audioDirFontSize,
                                fontWeight: FontWeight.w400,
                              ),
                            )
                          : 0.0;
                      final cdSummaryCache = <String, CdAlbumGroupSummary>{};

                      return KonataDraggableScrollbar(
                        controller: _scrollCtrl,
                        builder: (_, ctrl) => ListView.separated(
                          controller: ctrl,
                          padding: EdgeInsets.fromLTRB(
                            listPadH,
                            0,
                            listPadH,
                            28 + bottomClearance,
                          ),
                          itemCount: rowCount,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 14),
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
                              return _buildCard(
                                context: context,
                                p: p,
                                rec: rec,
                                item: workItem,
                                imageLoader: imageLoader,
                                isAudio: isAudioTab,
                                stretchHeight: false,
                                audioDirLabel: dirLabel,
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

                            final titleTrailingMinHeight = inSelection
                                ? 24.0
                                : (KonataAdaptiveTokens.isAndroid
                                      ? KonataAdaptiveTokens.touchTarget
                                      : 0.0);
                            final leftHeight = _measureCardHeight(
                              context: context,
                              item: leftItem,
                              titleMaxWidth: titleMaxWidth,
                              titleTrailingMinHeight: titleTrailingMinHeight,
                              epLineHeight: epH,
                              extraAudioDirHeight: leftDirLabel != null
                                  ? (_audioDirTopGap + audioDirLineH)
                                  : 0.0,
                              progressLineHeight: progH,
                              dateLineHeight: dateH,
                              coverHeight: activeCoverHeight,
                            );
                            final rightHeight = rightRec == null
                                ? leftHeight
                                : _measureCardHeight(
                                    context: context,
                                    item: rightItem,
                                    titleMaxWidth: titleMaxWidth,
                                    titleTrailingMinHeight:
                                        titleTrailingMinHeight,
                                    epLineHeight: epH,
                                    extraAudioDirHeight: rightDirLabel != null
                                        ? (_audioDirTopGap + audioDirLineH)
                                        : 0.0,
                                    progressLineHeight: progH,
                                    dateLineHeight: dateH,
                                    coverHeight: activeCoverHeight,
                                  );
                            final rowHeight = math.max(leftHeight, rightHeight);

                            return SizedBox(
                              height: rowHeight,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: _buildCard(
                                      context: context,
                                      p: p,
                                      rec: leftRec,
                                      item: leftItem,
                                      imageLoader: imageLoader,
                                      isAudio: isAudioTab,
                                      stretchHeight: true,
                                      audioDirLabel: leftDirLabel,
                                    ),
                                  ),
                                  const SizedBox(width: _colGap),
                                  Expanded(
                                    child: rightRec != null
                                        ? _buildCard(
                                            context: context,
                                            p: p,
                                            rec: rightRec,
                                            item: rightItem,
                                            imageLoader: imageLoader,
                                            isAudio: isAudioTab,
                                            stretchHeight: true,
                                            audioDirLabel: rightDirLabel,
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ),
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

/// 音频播放记录 `128×128` 专辑封面：优先读取专辑目录 Folder/Cover 或内嵌 CD 封面，无专属图时回退作品封面。
class _AudioHistoryCover extends ConsumerWidget {
  const _AudioHistoryCover({
    required this.workId,
    required this.variantId,
    required this.fallbackPoster,
    required this.imageLoader,
    required this.size,
  });

  final String workId;
  final String variantId;
  final String? fallbackPoster;
  final ManagedImageLoader imageLoader;
  final double size;

  Widget _buildFallback(KonataPalette p) {
    if (fallbackPoster != null && fallbackPoster!.isNotEmpty) {
      return ManagedImage(
        fallbackPoster!,
        loader: imageLoader,
        owner: workId,
        artwork: ManagedArtwork.poster,
        decodeWidth: 280,
        fit: BoxFit.cover,
        alignment: SmartCoverFraming.defaultPosterAlignment,
        errorBuilder: (_, _, _) => _buildIconPlaceholder(p),
      );
    }
    return _buildIconPlaceholder(p);
  }

  Widget _buildIconPlaceholder(KonataPalette p) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.softFill,
        border: Border.all(color: p.hairline, width: 1),
      ),
      child: Center(
        child: Icon(Icons.album_outlined, size: 34, color: p.textMuted),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final albumBytesAsync = ref.watch(
      audioRecordAlbumCoverProvider((workId: workId, variantId: variantId)),
    );
    final bytes = albumBytesAsync.valueOrNull;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => _buildFallback(p),
      );
    }
    return _buildFallback(p);
  }
}
