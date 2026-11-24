import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'hybrid_match_panel.dart';
import 'managed_image.dart';

enum _ManualMatchMode {
  tmdb('TMDB 匹配'),
  hybrid('Bangumi × TMDB 混合'),
  bangumiOnly('仅 Bangumi');

  const _ManualMatchMode(this.label);

  final String label;
}

/// 弹出人工匹配与重新刮削弹窗（支持拆包选中文件绑定为独立作品）。
Future<bool> showManualMatchDialog(
  BuildContext context, {
  required Work work,
  List<MediaVariant>? splitFiles,
}) async {
  final result = await showKonataGlassDialog<bool>(
    context: context,
    builder: (_) => _ManualMatchDialog(work: work, splitFiles: splitFiles),
  );
  return result == true;
}

class _ManualMatchDialog extends ConsumerStatefulWidget {
  const _ManualMatchDialog({required this.work, this.splitFiles});

  final Work work;
  final List<MediaVariant>? splitFiles;

  @override
  ConsumerState<_ManualMatchDialog> createState() => _ManualMatchDialogState();
}

class _ManualMatchDialogState extends ConsumerState<_ManualMatchDialog> {
  final ScrollController _resultsScrollController = ScrollController();
  final TextEditingController _queryController = TextEditingController();
  final TextEditingController _directIdController = TextEditingController();

  _ManualMatchMode _mode = _ManualMatchMode.tmdb;
  TmdbMediaType _directMediaType = TmdbMediaType.tv;
  bool _writeIdToFolderName = false;
  bool _resetManualLocks = false;

  bool _searching = false;
  bool _hasSearchedTmdb = false;
  bool _binding = false;
  List<String> _quickTerms = const <String>[];
  List<ScrapeCandidateSummary> _savedCandidates =
      const <ScrapeCandidateSummary>[];
  List<TmdbSearchResult> _tmdbResults = const <TmdbSearchResult>[];
  List<BangumiSubjectCandidate> _bgmResults = const <BangumiSubjectCandidate>[];

  @override
  void initState() {
    super.initState();
    _initQuickTermsAndSavedCandidates();
  }

  Future<void> _initQuickTermsAndSavedCandidates() async {
    final mgmt = ref.read(workManagementControllerProvider);
    final variants =
        widget.splitFiles ?? await mgmt.getVariantsByWork(widget.work.id);
    final saved = await mgmt.getScrapeCandidates(widget.work.id);
    final rawTerms = SearchQuerySanitizer.buildQuickSourceTerms(
      variants.map(
        (v) => (fileName: v.fileName, relativePath: v.relativePath),
      ),
    );
    final fallbackTitle = SearchQuerySanitizer.sanitize(widget.work.title);
    final merged = <String>{
      if (rawTerms.isNotEmpty) ...rawTerms,
      if (fallbackTitle.isNotEmpty) fallbackTitle,
      if (widget.work.title.trim().isNotEmpty) widget.work.title.trim(),
    }.take(5).toList(growable: false);

    if (!mounted) return;
    setState(() {
      _quickTerms = merged;
      _savedCandidates = saved;
      if (_queryController.text.trim().isEmpty) {
        _queryController.text = merged.isNotEmpty
            ? merged.first
            : widget.work.title;
      }
    });
  }

  @override
  void dispose() {
    _resultsScrollController.dispose();
    _queryController.dispose();
    _directIdController.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _searching) return;
    setState(() => _searching = true);
    final mgmt = ref.read(workManagementControllerProvider);
    try {
      if (_mode == _ManualMatchMode.tmdb) {
        final list = await mgmt.searchTmdb(query);
        if (!mounted) return;
        setState(() {
          _hasSearchedTmdb = true;
          _tmdbResults = list;
        });
      } else if (_mode == _ManualMatchMode.bangumiOnly) {
        final list = await mgmt.searchBangumi(query);
        if (!mounted) return;
        setState(() => _bgmResults = list);
      }
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, '检索失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _searching = false);
      }
    }
  }

  Future<String> _resolveTargetWorkId({String? initialTitle}) async {
    final split = widget.splitFiles;
    if (split == null || split.isEmpty) {
      return widget.work.id;
    }
    return ref
        .read(workManagementControllerProvider)
        .splitVariantsToIndependentWork(
          sourceWorkId: widget.work.id,
          variantIds: split.map((v) => v.id).toList(growable: false),
          initialTitle: initialTitle,
        );
  }

  Future<void> _bindTmdb(
    int tmdbId,
    TmdbMediaType mediaType, {
    String? titleHint,
  }) async {
    if (_binding) return;
    setState(() => _binding = true);
    final mgmt = ref.read(workManagementControllerProvider);
    final library = ref.read(libraryControllerProvider);
    try {
      final targetWorkId = await _resolveTargetWorkId(initialTitle: titleHint);
      final updated = await mgmt.bindWorkToTmdb(
        workId: targetWorkId,
        tmdbId: tmdbId,
        mediaType: mediaType,
        writeIdToFolderName: _writeIdToFolderName,
        resetManualLocks: _resetManualLocks,
      );
      await library.reload();
      if (!mounted) return;
      showKonataToast(context, '已绑定「${updated.title}」');
      Navigator.of(context).pop(true);
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, '绑定 TMDB 失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _binding = false);
      }
    }
  }

  Future<void> _bindByDirectId() async {
    final parsed = int.tryParse(_directIdController.text.trim());
    if (parsed == null || parsed <= 0) {
      showKonataToast(context, '请输入有效的正整数 TMDB 条目编号', isError: true);
      return;
    }
    await _bindTmdb(parsed, _directMediaType);
  }

  Future<void> _bindBangumiOnly(BangumiSubjectCandidate subject) async {
    if (_binding) return;
    setState(() => _binding = true);
    final mgmt = ref.read(workManagementControllerProvider);
    final library = ref.read(libraryControllerProvider);
    try {
      final targetWorkId = await _resolveTargetWorkId(
        initialTitle: subject.displayTitle,
      );
      final updated = await mgmt.bindWorkBangumiOnly(
        workId: targetWorkId,
        bangumiSubject: subject,
      );
      await library.reload();
      if (!mounted) return;
      showKonataToast(context, '已绑定 Bangumi 词条「${updated.title}」');
      Navigator.of(context).pop(true);
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, '绑定 Bangumi 失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _binding = false);
      }
    }
  }

  Future<void> _toggleResetLocks(bool next) async {
    if (!next || !widget.work.isManualLocked) {
      setState(() => _resetManualLocks = next);
      return;
    }
    final confirm = await showKonataGlassDialog<bool>(
      context: context,
      builder: (dlgCtx) {
        final p = dlgCtx.palette;
        return KonataGlassDialog(
          width: 420,
          title: '解除人工锁确认',
          onClose: () => Navigator.of(dlgCtx).pop(false),
          actions: <Widget>[
            KonataPillButton.ghost(
              label: '保留锁定',
              onPressed: () => Navigator.of(dlgCtx).pop(false),
            ),
            KonataPillButton.primary(
              label: '确认解除',
              onPressed: () => Navigator.of(dlgCtx).pop(true),
            ),
          ],
          child: Text(
            '开启该选项后，将清除当前作品上已锁定的海报、剧照或标题保护，并以新选定条目全量覆盖元数据。确定继续吗？',
            style: KonataTheme.bodyLabelStyle(p).copyWith(height: 1.5),
          ),
        );
      },
    );
    if (!mounted) return;
    setState(() => _resetManualLocks = confirm == true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final split = widget.splitFiles;

    return KonataGlassDialog(
      width: 740,
      height: 600,
      title: split != null && split.isNotEmpty
          ? '拆分绑定为独立作品（${split.length} 个文件）'
          : '手动匹配元数据：${widget.work.title}',
      onClose: _binding ? null : () => Navigator.of(context).pop(false),
      actions: <Widget>[
        KonataPillButton.ghost(
          label: '取消',
          onPressed: _binding ? null : () => Navigator.of(context).pop(false),
        ),
      ],
      child: Builder(
        builder: (dialogCtx) {
          final compactIme =
              KonataGlassDialog.isLandscapeCompactInputActive(dialogCtx);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Offstage(
                offstage: compactIme,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (split != null && split.isNotEmpty) ...<Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: p.accentBadge.bg,
                          borderRadius: KonataTheme.borderRadiusControl,
                          border: Border.all(color: p.accentBadge.border),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              Icons.call_split_rounded,
                              size: 16,
                              color: p.accentBadge.fg,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '已选定 ${split.length} 个视频文件，确认绑定后将自动脱离「${widget.work.title}」并生成独立作品条目。',
                                style: KonataTheme.textStyle(
                                  color: p.accentBadge.fg,
                                  fontSize: KonataTheme.fontSizeCaption,
                                  weight: KonataTheme.weightActive,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    KonataSegmentedCapsule<_ManualMatchMode>(
                      compact: true,
                      selected: _mode,
                      onChanged: (next) => setState(() => _mode = next),
                      options: <KonataSegmentOption<_ManualMatchMode>>[
                        for (final m in _ManualMatchMode.values)
                          KonataSegmentOption<_ManualMatchMode>(
                            value: m,
                            label: m.label,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              if (_mode == _ManualMatchMode.hybrid)
                Expanded(
                  child: HybridMatchPanel(
                    work: widget.work,
                    quickTerms: _quickTerms,
                    splitFiles: widget.splitFiles,
                    onBoundSuccess: () => Navigator.of(context).pop(true),
                  ),
                )
              else ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: KonataSearchField(
                        controller: _queryController,
                        onSubmitted: (_) => _runSearch(),
                        onClear: () => _queryController.clear(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    KonataPillButton.primary(
                      label: _searching ? '搜索中…' : '搜索',
                      icon: Icons.search_rounded,
                      compact: true,
                      onPressed: _searching || _binding ? null : _runSearch,
                    ),
                  ],
                ),
                Offstage(
                  offstage: compactIme,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (_quickTerms.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 6),
                        KonataQuickFillRow(
                          terms: _quickTerms,
                          disabled: _searching || _binding,
                          onPick: (term) {
                            _queryController.text = term;
                            _runSearch();
                          },
                        ),
                      ],
                      if (_mode == _ManualMatchMode.tmdb) ...<Widget>[
                        const SizedBox(height: 10),
                        _buildTmdbOptionsCard(p),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _mode == _ManualMatchMode.tmdb
                      ? _buildTmdbResults(p)
                      : _buildBangumiResults(p),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildTmdbOptionsCard(KonataPalette p) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.softFill,
        borderRadius: KonataTheme.borderRadiusControl,
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LayoutBuilder(
            builder: (_, constraints) {
              final narrow = constraints.maxWidth < 460;
              final idField = KonataSoftTextField(
                controller: _directIdController,
                dense: true,
                hintText: '直接按 TMDB ID 绑定（如 94951）',
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _bindByDirectId(),
              );
              final typeCapsule = KonataSegmentedCapsule<TmdbMediaType>(
                compact: true,
                selected: _directMediaType,
                onChanged: (v) => setState(() => _directMediaType = v),
                options: const <KonataSegmentOption<TmdbMediaType>>[
                  KonataSegmentOption<TmdbMediaType>(
                    value: TmdbMediaType.tv,
                    label: '剧集',
                  ),
                  KonataSegmentOption<TmdbMediaType>(
                    value: TmdbMediaType.movie,
                    label: '剧场版',
                  ),
                ],
              );
              final bindBtn = KonataPillButton.secondary(
                label: '按 ID 绑定',
                compact: true,
                onPressed: _binding ? null : _bindByDirectId,
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    idField,
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[typeCapsule, bindBtn],
                    ),
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: idField),
                  const SizedBox(width: 8),
                  typeCapsule,
                  const SizedBox(width: 8),
                  bindBtn,
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: <Widget>[
              _InlineOptionCheck(
                value: _writeIdToFolderName,
                label: '向本地文件夹名写入 [tmdbid-xxx]',
                onChanged: (v) => setState(() => _writeIdToFolderName = v),
              ),
              _InlineOptionCheck(
                value: _resetManualLocks,
                label: '重置已锁定元数据与海报',
                onChanged: _toggleResetLocks,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTmdbResults(KonataPalette p) {
    if (_searching && _tmdbResults.isEmpty) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
        ),
      );
    }

    if (_tmdbResults.isEmpty && !_hasSearchedTmdb && _savedCandidates.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '自动刮削推荐候选（点击可直接采纳绑定）',
              style: KonataTheme.captionStyle(
                p,
                fontSize: KonataTheme.fontSizeCaptionSm,
              ),
            ),
          ),
          Expanded(
            child: KonataDraggableScrollbar(
              controller: _resultsScrollController,
              builder: (_, sc) => ListView.separated(
                controller: sc,
                padding: const EdgeInsets.only(right: 12),
                itemCount: _savedCandidates.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final cand = _savedCandidates[i];
                  final pct = (cand.score * 100).round().clamp(0, 100);
                  final reasonTexts = ReviewReasonLabels.formatAll(
                    cand.reasons,
                  );
                  return _ManualCandidateTile(
                    imagePath: cand.posterPath,
                    title: cand.title,
                    originalTitle: cand.originalTitle,
                    chips: <String>[
                      'TMDB #${cand.tmdbId}',
                      cand.mediaType == TmdbMediaType.tv ? '剧集' : '剧场版',
                      '匹配度 $pct%',
                      if (cand.year != null) '${cand.year}',
                      ...reasonTexts.take(2),
                    ],
                    actionLabel: _binding ? '绑定中…' : '采纳绑定',
                    disabled: _binding,
                    onAction: () => _bindTmdb(
                      cand.tmdbId,
                      cand.mediaType,
                      titleHint: cand.title,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      );
    }

    if (_tmdbResults.isEmpty) {
      return Center(
        child: Text(
          _hasSearchedTmdb
              ? '未检索到匹配的 TMDB 条目，请调整搜索词或直接使用下方编号绑定'
              : '输入作品名点击搜索，或在上方填入已知 TMDB 编号直连绑定',
          textAlign: TextAlign.center,
          style: KonataTheme.captionStyle(p),
        ),
      );
    }

    return KonataDraggableScrollbar(
      controller: _resultsScrollController,
      builder: (_, sc) => ListView.separated(
        controller: sc,
        padding: const EdgeInsets.only(right: 12),
        itemCount: _tmdbResults.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final hit = _tmdbResults[i];
          return _ManualCandidateTile(
            imagePath: hit.posterPath,
            title: hit.title,
            originalTitle: hit.originalTitle,
            chips: <String>[
              'TMDB #${hit.tmdbId}',
              hit.mediaType == TmdbMediaType.tv ? '剧集' : '剧场版',
              if (hit.year != null) '${hit.year}',
            ],
            overview: hit.overview,
            actionLabel: _binding ? '绑定中…' : '绑定',
            disabled: _binding,
            onAction: () => _bindTmdb(
              hit.tmdbId,
              hit.mediaType,
              titleHint: hit.title,
            ),
          );
        },
      ),
    );
  }

  Widget _buildBangumiResults(KonataPalette p) {
    if (_searching && _bgmResults.isEmpty) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
        ),
      );
    }
    if (_bgmResults.isEmpty) {
      return Center(
        child: Text(
          '适用于 TMDB 未收录的同人或冷门作品，仅绑定 Bangumi 元数据并静默尝试匹配背景图',
          textAlign: TextAlign.center,
          style: KonataTheme.captionStyle(p),
        ),
      );
    }
    return KonataDraggableScrollbar(
      controller: _resultsScrollController,
      builder: (_, sc) => ListView.separated(
        controller: sc,
        padding: const EdgeInsets.only(right: 12),
        itemCount: _bgmResults.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final bgm = _bgmResults[i];
          return _ManualCandidateTile(
            imagePath: bgm.posterUrl,
            title: bgm.displayTitle,
            originalTitle: bgm.name != bgm.displayTitle ? bgm.name : null,
            chips: <String>[
              'BGM #${bgm.id}',
              if (bgm.year != null) '${bgm.year}',
              if (bgm.totalEpisodes != null) '${bgm.totalEpisodes} 话',
              if (bgm.score != null && bgm.score! > 0)
                '评分 ${bgm.score!.toStringAsFixed(1)}',
            ],
            overview: bgm.summary,
            actionLabel: _binding ? '绑定中…' : '仅绑 BGM',
            disabled: _binding,
            onAction: () => _bindBangumiOnly(bgm),
          );
        },
      ),
    );
  }
}

class _InlineOptionCheck extends StatelessWidget {
  const _InlineOptionCheck({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: value,
              activeColor: p.accent,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: KonataTheme.captionStyle(
              p,
              fontSize: KonataTheme.fontSizeCaptionSm,
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualCandidateTile extends StatelessWidget {
  const _ManualCandidateTile({
    required this.imagePath,
    required this.title,
    this.originalTitle,
    required this.chips,
    this.overview,
    required this.actionLabel,
    required this.disabled,
    required this.onAction,
  });

  final String? imagePath;
  final String title;
  final String? originalTitle;
  final List<String> chips;
  final String? overview;
  final String actionLabel;
  final bool disabled;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataSurfaceCard(
      enableHover: true,
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ClipRRect(
            borderRadius: KonataTheme.borderRadiusSm,
            child: SizedBox(
              width: 48,
              height: 70,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: KonataTheme.borderRadiusSm,
                  border: Border.all(color: p.posterBorder),
                ),
                child: ManagedImage(
                  path: imagePath,
                  targetWidth: 140,
                  fit: BoxFit.cover,
                  errorWidget: Icon(
                    Icons.movie_outlined,
                    size: 18,
                    color: p.textMuted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: KonataTheme.cardTitleStyle(
                    p,
                    fontSize: KonataTheme.fontSizeBody,
                  ),
                ),
                if (originalTitle != null &&
                    originalTitle!.trim().isNotEmpty &&
                    originalTitle!.trim() != title) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    originalTitle!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: KonataTheme.captionStyle(
                      p,
                      fontSize: KonataTheme.fontSizeCaptionXs,
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final c in chips)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: p.softFill,
                          borderRadius: KonataTheme.borderRadiusChip,
                          border: Border.all(color: p.hairline),
                        ),
                        child: Text(
                          c,
                          style: KonataTheme.textStyle(
                            color: p.textSecondary,
                            fontSize: KonataTheme.fontSizeCaptionXs,
                            tabularFigures: true,
                          ),
                        ),
                      ),
                  ],
                ),
                if (overview != null && overview!.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 5),
                  Text(
                    overview!.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: KonataTheme.captionStyle(
                      p,
                      fontSize: KonataTheme.fontSizeCaptionXs,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          KonataPillButton.primary(
            label: actionLabel,
            compact: true,
            onPressed: disabled ? null : onAction,
          ),
        ],
      ),
    );
  }
}
