import 'dart:async';
import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart'
    show TmdbMediaType, WorkId;
import 'package:konata_design_system/konata_design_system.dart';

import '../data/detail_edit_models.dart';
import '../state/detail_supplementary_view_data.dart';
import '../state/work_detail_controller.dart';
import 'detail_managed_image.dart';

enum _ManualMatchMode { tmdb, bangumiHybrid, bangumiOnly }

/// 作品手动精确匹配与拆簇建新工作台弹窗（支持 TMDB 搜索/直绑、Bangumi+TMDB 双源混合与纯 Bangumi 锁定）。
class ManualMatchDialog extends StatefulWidget {
  /// 创建手动精确匹配弹窗。
  const ManualMatchDialog({
    super.key,
    required this.controller,
    required this.bundle,
    required this.imageLoader,
    this.splitVariantIds,
  });

  /// 详情页状态控制器。
  final WorkDetailController controller;

  /// 当前作品详情聚合包。
  final WorkDetailBundle bundle;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 若非空则进入「拆分选中物理文件为独立新作品」模式。
  final List<String>? splitVariantIds;

  bool get _isSplitMode =>
      splitVariantIds != null && splitVariantIds!.isNotEmpty;

  @override
  State<ManualMatchDialog> createState() => _ManualMatchDialogState();
}

class _ManualMatchDialogState extends State<ManualMatchDialog> {
  final TextEditingController _tmdbQueryCtrl = TextEditingController();
  final TextEditingController _tmdbIdCtrl = TextEditingController();
  final TextEditingController _bgmQueryCtrl = TextEditingController();
  final TextEditingController _hybridTmdbQueryCtrl = TextEditingController();
  final TextEditingController _startEpCtrl = TextEditingController(text: '1');
  final ScrollController _resultsScrollCtrl = ScrollController();

  _ManualMatchMode _mode = _ManualMatchMode.tmdb;
  TmdbMediaType _directMediaType = TmdbMediaType.tv;
  bool _writeFolderTag = false;
  bool _searchingTmdb = false;
  bool _searchingBgm = false;
  bool _submitting = false;

  List<TmdbSearchResult> _tmdbResults = const <TmdbSearchResult>[];
  List<BangumiSubjectCandidate> _bgmResults = const <BangumiSubjectCandidate>[];
  BangumiSubjectCandidate? _selectedBgm;
  TmdbWorkDetail? _selectedHybridTmdbDetail;
  int _selectedHybridSeason = 1;
  bool _loadingHybridDetail = false;

  @override
  void initState() {
    super.initState();
    final work = widget.bundle.work;
    _tmdbQueryCtrl.text = work.title;
    _bgmQueryCtrl.text = work.title;
    _hybridTmdbQueryCtrl.text = work.title;
    if (work.bangumiId != null && work.tmdbId == null && !widget._isSplitMode) {
      _mode = _ManualMatchMode.bangumiOnly;
    }
    if (work.tmdbMediaType != null) {
      _directMediaType = work.tmdbMediaType!;
    }
  }

  @override
  void dispose() {
    _tmdbQueryCtrl.dispose();
    _tmdbIdCtrl.dispose();
    _bgmQueryCtrl.dispose();
    _hybridTmdbQueryCtrl.dispose();
    _startEpCtrl.dispose();
    _resultsScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _searchTmdb(String rawQuery) async {
    final q = rawQuery.trim();
    if (q.isEmpty || _searchingTmdb) return;
    setState(() => _searchingTmdb = true);
    try {
      final results = await widget.controller.searchTmdbAnime(q);
      if (mounted) {
        setState(() {
          _tmdbResults = results;
          _searchingTmdb = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _searchingTmdb = false);
        showKonataToast(context, 'TMDB 搜索失败：$error', isError: true);
      }
    }
  }

  Future<void> _searchBangumi() async {
    final q = _bgmQueryCtrl.text.trim();
    if (q.isEmpty || _searchingBgm) return;
    setState(() => _searchingBgm = true);
    try {
      final results = await widget.controller.searchBangumiSubjects(q);
      if (mounted) {
        setState(() {
          _bgmResults = results;
          _searchingBgm = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _searchingBgm = false);
        showKonataToast(context, 'Bangumi 搜索失败：$error', isError: true);
      }
    }
  }

  Future<void> _selectHybridTmdbCandidate(TmdbSearchResult item) async {
    setState(() => _loadingHybridDetail = true);
    try {
      final detail = await widget.controller.getTmdbWorkDetail(
        item.tmdbId,
        item.mediaType,
      );
      if (!mounted) return;
      if (detail == null) {
        setState(() => _loadingHybridDetail = false);
        showKonataToast(context, '未找到该 TMDB 条目的详情数据', isError: true);
        return;
      }
      final defaultSeason = detail.seasons.any((s) => s.seasonNumber == 1)
          ? 1
          : (detail.seasons.isNotEmpty
                ? detail.seasons.first.seasonNumber
                : 1);
      setState(() {
        _selectedHybridTmdbDetail = detail;
        _selectedHybridSeason = defaultSeason;
        _loadingHybridDetail = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _loadingHybridDetail = false);
        showKonataToast(context, '获取 TMDB 分季信息失败：$error', isError: true);
      }
    }
  }

  Future<void> _applyTmdbBinding(int tmdbId, TmdbMediaType mediaType) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      if (widget._isSplitMode) {
        final created = await widget.controller.splitVariantsToIndependentWork(
          variantIds: widget.splitVariantIds!,
          tmdbTarget: (tmdbId: tmdbId, mediaType: mediaType),
          writeTmdbIdToFolderName: _writeFolderTag,
        );
        if (!mounted) return;
        Navigator.of(context).pop(true);
        await widget.controller.switchSeriesMember(WorkId.trusted(created.id));
        return;
      }

      await widget.controller.rebindWorkToTmdb(
        tmdbId: tmdbId,
        mediaType: mediaType,
        writeIdToFolderName: _writeFolderTag,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _submitting = false);
        showKonataToast(context, '绑定 TMDB 失败：$error', isError: true);
      }
    }
  }

  Future<void> _applyDirectTmdbId() async {
    final parsed = int.tryParse(_tmdbIdCtrl.text.trim());
    if (parsed == null || parsed <= 0) {
      showKonataToast(context, '请输入有效的正整数 TMDB ID', isError: true);
      return;
    }
    await _applyTmdbBinding(parsed, _directMediaType);
  }

  Future<void> _applyBangumiOnly(BangumiSubjectCandidate subject) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      if (widget._isSplitMode) {
        final created = await widget.controller.splitVariantsToIndependentWork(
          variantIds: widget.splitVariantIds!,
          bangumiOnlySubject: subject,
        );
        if (!mounted) return;
        Navigator.of(context).pop(true);
        await widget.controller.switchSeriesMember(WorkId.trusted(created.id));
        return;
      }

      await widget.controller.bindWorkBangumiOnly(subject);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _submitting = false);
        showKonataToast(context, '绑定纯 Bangumi 条目失败：$error', isError: true);
      }
    }
  }

  Future<void> _applyHybridBinding() async {
    final bgm = _selectedBgm;
    final tmdb = _selectedHybridTmdbDetail;
    if (bgm == null || tmdb == null || _submitting) return;
    final startEp = math.max(1, int.tryParse(_startEpCtrl.text.trim()) ?? 1);
    final req = HybridMatchRequest(
      bangumiSubject: bgm,
      tmdbDetail: tmdb,
      tmdbSeasonNumber: _selectedHybridSeason,
      startEpisodeNumber: startEp,
    );

    setState(() => _submitting = true);
    try {
      if (widget._isSplitMode) {
        final created = await widget.controller.splitVariantsToIndependentWork(
          variantIds: widget.splitVariantIds!,
          hybridRequest: req,
        );
        if (!mounted) return;
        Navigator.of(context).pop(true);
        await widget.controller.switchSeriesMember(WorkId.trusted(created.id));
        return;
      }

      await widget.controller.bindWorkHybrid(req);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _submitting = false);
        showKonataToast(context, '双源混合绑定失败：$error', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final title = widget._isSplitMode
        ? '拆分为独立作品 (${widget.splitVariantIds!.length} 个文件)'
        : '手动精确匹配 · ${widget.bundle.work.title}';

    return KonataGlassDialog(
      width: 680,
      height: 580,
      title: title,
      onClose: _submitting ? null : () => Navigator.of(context).pop(false),
      actions: [
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
        ),
        if (_mode == _ManualMatchMode.bangumiHybrid)
          KonataPillButton.primary(
            label: _submitting ? '正在绑定...' : '确认双源混合绑定',
            compact: true,
            onPressed:
                (_submitting ||
                    _selectedBgm == null ||
                    _selectedHybridTmdbDetail == null)
                ? null
                : _applyHybridBinding,
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KonataSegmentedCapsule<_ManualMatchMode>(
            expand: true,
            compact: true,
            selected: _mode,
            onChanged: (next) => setState(() => _mode = next),
            options: const [
              KonataSegmentOption(
                value: _ManualMatchMode.tmdb,
                label: 'TMDB 搜索 / ID 直绑',
              ),
              KonataSegmentOption(
                value: _ManualMatchMode.bangumiHybrid,
                label: 'Bangumi + TMDB 混合',
              ),
              KonataSegmentOption(
                value: _ManualMatchMode.bangumiOnly,
                label: '纯 Bangumi 绑定',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: switch (_mode) {
              _ManualMatchMode.tmdb => _buildTmdbTab(p),
              _ManualMatchMode.bangumiHybrid => _buildHybridTab(p),
              _ManualMatchMode.bangumiOnly => _buildBangumiOnlyTab(p),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTmdbTab(KonataPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: KonataSoftTextField(
                controller: _tmdbQueryCtrl,
                dense: true,
                prefixIcon: Icons.search_rounded,
                hintText: '输入作品中文/日文/英文标题搜索 TMDB...',
                onSubmitted: _searchTmdb,
              ),
            ),
            const SizedBox(width: 8),
            KonataPillButton.primary(
              label: _searchingTmdb ? '搜索中...' : '搜索',
              compact: true,
              onPressed: _searchingTmdb || _submitting
                  ? null
                  : () => _searchTmdb(_tmdbQueryCtrl.text),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 150,
              child: KonataSoftTextField(
                controller: _tmdbIdCtrl,
                dense: true,
                hintText: '直接输入 TMDB ID',
              ),
            ),
            const SizedBox(width: 8),
            KonataSegmentedCapsule<TmdbMediaType>(
              compact: true,
              selected: _directMediaType,
              onChanged: (v) => setState(() => _directMediaType = v),
              options: const [
                KonataSegmentOption(value: TmdbMediaType.tv, label: '剧集'),
                KonataSegmentOption(value: TmdbMediaType.movie, label: '电影'),
              ],
            ),
            const SizedBox(width: 8),
            KonataPillButton.secondary(
              label: '直绑 ID',
              compact: true,
              onPressed: _submitting ? null : _applyDirectTmdbId,
            ),
            const Spacer(),
            Text(
              '写入文件夹标签',
              style: KonataTheme.captionStyle(p).copyWith(color: p.textSecondary),
            ),
            const SizedBox(width: 6),
            KonataSwitch(
              value: _writeFolderTag,
              onChanged: (v) => setState(() => _writeFolderTag = v),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(child: _buildTmdbResultList(p)),
      ],
    );
  }

  Widget _buildTmdbResultList(
    KonataPalette p, {
    ValueChanged<TmdbSearchResult>? onPickOverride,
  }) {
    if (_searchingTmdb) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_tmdbResults.isEmpty) {
      return Center(
        child: Text(
          '输入标题并点击搜索，或直接填入已知 TMDB ID 绑定',
          style: KonataTheme.bodyLabelStyle(p, color: p.textMuted),
        ),
      );
    }
    return KonataDraggableScrollbar(
      controller: _resultsScrollCtrl,
      builder: (_, ctrl) => ListView.separated(
        controller: ctrl,
        itemCount: _tmdbResults.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, index) {
          final item = _tmdbResults[index];
          return KonataSurfaceCard(
            enableHover: true,
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                if (item.posterPath?.trim().isNotEmpty == true)
                  ClipRRect(
                    borderRadius: KonataTheme.borderRadiusChip,
                    child: SizedBox(
                      width: 42,
                      height: 60,
                      child: DetailManagedImage(
                        item.posterPath!,
                        loader: widget.imageLoader,
                        owner: widget.bundle.work.id,
                        artwork: ManagedArtwork.poster,
                        decodeWidth: 160,
                      ),
                    ),
                  )
                else
                  Container(
                    width: 42,
                    height: 60,
                    decoration: BoxDecoration(
                      color: p.softFill,
                      borderRadius: KonataTheme.borderRadiusChip,
                    ),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: KonataTheme.cardTitleStyle(
                          p,
                          fontSize: KonataTheme.fontSizeBodySm,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          item.mediaType == TmdbMediaType.tv ? 'TV 剧集' : '剧场版/电影',
                          if (item.year != null) '${item.year}',
                          'ID: ${item.tmdbId}',
                        ].join(' · '),
                        style: KonataTheme.captionStyle(
                          p,
                        ).copyWith(color: p.textMuted),
                      ),
                      if (item.overview?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.overview!.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: KonataTheme.captionStyle(p).copyWith(
                            color: p.textSecondary,
                            fontSize: KonataTheme.fontSizeCaptionXs,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                KonataPillButton.secondary(
                  label: onPickOverride != null ? '选择作为底图源' : '绑定',
                  compact: true,
                  onPressed: _submitting
                      ? null
                      : () {
                          if (onPickOverride != null) {
                            onPickOverride(item);
                          } else {
                            _applyTmdbBinding(item.tmdbId, item.mediaType);
                          }
                        },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBangumiOnlyTab(KonataPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: KonataSoftTextField(
                controller: _bgmQueryCtrl,
                dense: true,
                prefixIcon: Icons.search_rounded,
                hintText: '搜索 Bangumi 动画条目...',
                onSubmitted: (_) => _searchBangumi(),
              ),
            ),
            const SizedBox(width: 8),
            KonataPillButton.primary(
              label: _searchingBgm ? '搜索中...' : '搜索 Bangumi',
              compact: true,
              onPressed: _searchingBgm || _submitting ? null : _searchBangumi,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _buildBangumiResultList(
            p,
            buttonLabel: '绑定纯 BGM',
            onSelect: _applyBangumiOnly,
          ),
        ),
      ],
    );
  }

  Widget _buildHybridTab(KonataPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KonataSurfaceCard(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '1. Bangumi 独立条目：${_selectedBgm?.displayTitle ?? '未选择'}',
                style: KonataTheme.captionStyle(p).copyWith(
                  color: _selectedBgm != null ? p.accent : p.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '2. TMDB 母系列：${_selectedHybridTmdbDetail?.title ?? '未选择'}',
                style: KonataTheme.captionStyle(p).copyWith(
                  color: _selectedHybridTmdbDetail != null
                      ? p.accent
                      : p.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_selectedHybridTmdbDetail != null) ...[
                Text(
                  '季号：S${_selectedHybridSeason.toString().padLeft(2, '0')}',
                  style: KonataTheme.captionStyle(p).copyWith(color: p.textPrimary),
                ),
                SizedBox(
                  width: 96,
                  child: KonataSoftTextField(
                    controller: _startEpCtrl,
                    dense: true,
                    hintText: '起始集',
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (_selectedBgm == null) ...[
          Row(
            children: [
              Expanded(
                child: KonataSoftTextField(
                  controller: _bgmQueryCtrl,
                  dense: true,
                  prefixIcon: Icons.search_rounded,
                  hintText: '第一步：搜索 Bangumi 独立条目...',
                  onSubmitted: (_) => _searchBangumi(),
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.primary(
                label: _searchingBgm ? '搜索中...' : '搜 Bangumi',
                compact: true,
                onPressed: _searchingBgm ? null : _searchBangumi,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _buildBangumiResultList(
              p,
              buttonLabel: '选定 BGM',
              onSelect: (subject) => setState(() => _selectedBgm = subject),
            ),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: KonataSoftTextField(
                  controller: _hybridTmdbQueryCtrl,
                  dense: true,
                  prefixIcon: Icons.search_rounded,
                  hintText: '第二步：搜索关联 TMDB 系列...',
                  onSubmitted: _searchTmdb,
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.primary(
                label: _searchingTmdb ? '搜索中...' : '搜 TMDB',
                compact: true,
                onPressed: _searchingTmdb
                    ? null
                    : () => _searchTmdb(_hybridTmdbQueryCtrl.text),
              ),
              const SizedBox(width: 6),
              KonataPillButton.ghost(
                label: '重选 BGM',
                compact: true,
                onPressed: () => setState(() {
                  _selectedBgm = null;
                  _selectedHybridTmdbDetail = null;
                }),
              ),
            ],
          ),
          if (_selectedHybridTmdbDetail != null &&
              _selectedHybridTmdbDetail!.seasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 240,
              child: KonataDropdown<int>(
                dense: true,
                value: _selectedHybridSeason,
                options: [
                  for (final season in _selectedHybridTmdbDetail!.seasons)
                    KonataDropdownOption<int>(
                      value: season.seasonNumber,
                      label:
                          '第 ${season.seasonNumber} 季 · ${season.name} (${season.episodeCount} 集)',
                    ),
                ],
                onChanged: (next) =>
                    setState(() => _selectedHybridSeason = next),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: _loadingHybridDetail
                ? const Center(child: CircularProgressIndicator())
                : _buildTmdbResultList(
                    p,
                    onPickOverride: _selectHybridTmdbCandidate,
                  ),
          ),
        ],
      ],
    );
  }

  Widget _buildBangumiResultList(
    KonataPalette p, {
    required String buttonLabel,
    required ValueChanged<BangumiSubjectCandidate> onSelect,
  }) {
    if (_searchingBgm) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_bgmResults.isEmpty) {
      return Center(
        child: Text(
          '点击上方按钮搜索 Bangumi 条目候选',
          style: KonataTheme.bodyLabelStyle(p, color: p.textMuted),
        ),
      );
    }
    return KonataDraggableScrollbar(
      controller: _resultsScrollCtrl,
      builder: (_, ctrl) => ListView.separated(
        controller: ctrl,
        itemCount: _bgmResults.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, index) {
          final item = _bgmResults[index];
          return KonataSurfaceCard(
            enableHover: true,
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                if (item.posterUrl?.trim().isNotEmpty == true)
                  ClipRRect(
                    borderRadius: KonataTheme.borderRadiusChip,
                    child: SizedBox(
                      width: 42,
                      height: 60,
                      child: DetailManagedImage(
                        item.posterUrl!,
                        loader: widget.imageLoader,
                        owner: widget.bundle.work.id,
                        artwork: ManagedArtwork.poster,
                        decodeWidth: 160,
                      ),
                    ),
                  )
                else
                  Container(
                    width: 42,
                    height: 60,
                    decoration: BoxDecoration(
                      color: p.softFill,
                      borderRadius: KonataTheme.borderRadiusChip,
                    ),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: KonataTheme.cardTitleStyle(
                          p,
                          fontSize: KonataTheme.fontSizeBodySm,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (item.year != null) '${item.year}',
                          if (item.score != null)
                            'BGM ${item.score!.toStringAsFixed(1)}',
                          'ID: ${item.id}',
                        ].join(' · '),
                        style: KonataTheme.captionStyle(
                          p,
                        ).copyWith(color: p.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                KonataPillButton.secondary(
                  label: buttonLabel,
                  compact: true,
                  onPressed: _submitting ? null : () => onSelect(item),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
