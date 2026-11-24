import 'dart:math' as math;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';
import 'managed_image.dart';

/// 混合匹配面板：先选定 Bangumi 词条定义独立标题/评分/封面，再映射 TMDB 母剧单季及起始集号。
class HybridMatchPanel extends ConsumerStatefulWidget {
  /// 创建混合匹配操作面板。
  const HybridMatchPanel({
    super.key,
    required this.work,
    required this.quickTerms,
    this.splitFiles,
    required this.onBoundSuccess,
  });

  /// 当前正在修正或拆包绑定的作品。
  final Work work;

  /// 从文件夹与文件名提取的干净快捷检索词条。
  final List<String> quickTerms;

  /// 可选待拆分为独立作品的视频文件子集。
  final List<MediaVariant>? splitFiles;

  /// 绑定完成并刷新后的成功回调。
  final VoidCallback onBoundSuccess;

  @override
  ConsumerState<HybridMatchPanel> createState() => _HybridMatchPanelState();
}

class _HybridMatchPanelState extends ConsumerState<HybridMatchPanel> {
  final ScrollController _panelScrollController = ScrollController();
  final ScrollController _bgmScrollController = ScrollController();
  final ScrollController _tmdbScrollController = ScrollController();
  final TextEditingController _bgmQueryController = TextEditingController();
  final TextEditingController _tmdbQueryController = TextEditingController();
  final TextEditingController _startEpController = TextEditingController(
    text: '1',
  );

  bool _searchingBgm = false;
  bool _searchingTmdb = false;
  bool _loadingTmdbDetail = false;
  bool _loadingSeasonDetail = false;
  bool _submitting = false;

  List<BangumiSubjectCandidate> _bgmResults = const <BangumiSubjectCandidate>[];
  BangumiSubjectCandidate? _selectedBgm;

  List<TmdbSearchResult> _tmdbResults = const <TmdbSearchResult>[];
  TmdbWorkDetail? _selectedTmdbDetail;
  int _selectedSeasonNumber = 1;
  TmdbSeasonDetail? _seasonDetail;
  int _startEpisodeNumber = 1;

  @override
  void initState() {
    super.initState();
    final initial = widget.quickTerms.isNotEmpty
        ? widget.quickTerms.first
        : widget.work.title;
    _bgmQueryController.text = initial;
    _tmdbQueryController.text = initial;
  }

  @override
  void dispose() {
    _panelScrollController.dispose();
    _bgmScrollController.dispose();
    _tmdbScrollController.dispose();
    _bgmQueryController.dispose();
    _tmdbQueryController.dispose();
    _startEpController.dispose();
    super.dispose();
  }

  void _setStartEpisode(int next) {
    final safe = next < 1 ? 1 : next;
    final text = '$safe';
    if (_startEpController.text != text) {
      _startEpController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    setState(() => _startEpisodeNumber = safe);
  }

  Future<void> _searchBangumi() async {
    final query = _bgmQueryController.text.trim();
    if (query.isEmpty || _searchingBgm) return;
    setState(() => _searchingBgm = true);
    try {
      final list = await ref
          .read(workManagementControllerProvider)
          .searchBangumi(query);
      if (!mounted) return;
      setState(() {
        _bgmResults = list;
        if (list.isNotEmpty &&
            (_selectedBgm == null ||
                list.every((e) => e.id != _selectedBgm!.id))) {
          _selectedBgm = list.first;
        }
      });
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, 'Bangumi 检索失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _searchingBgm = false);
      }
    }
  }

  Future<void> _searchTmdb() async {
    final query = _tmdbQueryController.text.trim();
    if (query.isEmpty || _searchingTmdb) return;
    setState(() => _searchingTmdb = true);
    try {
      final list = await ref
          .read(workManagementControllerProvider)
          .searchTmdb(query);
      if (!mounted) return;
      setState(() => _tmdbResults = list);
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, 'TMDB 检索失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _searchingTmdb = false);
      }
    }
  }

  Future<void> _selectTmdbCandidate(TmdbSearchResult hit) async {
    if (_loadingTmdbDetail) return;
    setState(() {
      _loadingTmdbDetail = true;
      _selectedTmdbDetail = null;
      _seasonDetail = null;
    });
    _setStartEpisode(1);
    try {
      final mgmt = ref.read(workManagementControllerProvider);
      final detail = await mgmt.fetchTmdbDetail(hit.tmdbId, hit.mediaType);
      if (!mounted) return;
      if (detail == null) {
        showKonataToast(context, '无法获取该 TMDB 条目详情', isError: true);
        setState(() => _loadingTmdbDetail = false);
        return;
      }
      final preferredSeason = detail.seasons
          .where((s) => s.seasonNumber > 0)
          .map((s) => s.seasonNumber)
          .firstOrNull ??
          (detail.seasons.isNotEmpty ? detail.seasons.first.seasonNumber : 1);
      setState(() {
        _selectedTmdbDetail = detail;
        _selectedSeasonNumber = preferredSeason;
        _loadingTmdbDetail = false;
      });
      if (detail.mediaType == TmdbMediaType.tv) {
        await _loadSeasonDetail(detail.tmdbId, preferredSeason);
      }
    } catch (err) {
      if (!mounted) return;
      setState(() => _loadingTmdbDetail = false);
      showKonataToast(context, '拉取 TMDB 详情失败：$err', isError: true);
    }
  }

  Future<void> _loadSeasonDetail(int tmdbId, int seasonNumber) async {
    setState(() {
      _loadingSeasonDetail = true;
      _seasonDetail = null;
    });
    try {
      final detail = await ref
          .read(workManagementControllerProvider)
          .fetchTmdbSeasonDetail(tmdbId, seasonNumber);
      if (!mounted) return;
      final firstEp = detail?.episodes.isNotEmpty == true
          ? detail!.episodes.first.episodeNumber
          : 1;
      setState(() {
        _seasonDetail = detail;
        _loadingSeasonDetail = false;
      });
      _setStartEpisode(firstEp);
    } catch (_) {
      if (mounted) {
        setState(() => _loadingSeasonDetail = false);
      }
    }
  }

  Future<void> _submit() async {
    final bgm = _selectedBgm;
    final tmdb = _selectedTmdbDetail;
    if (bgm == null || tmdb == null || _submitting) return;

    setState(() => _submitting = true);
    final mgmt = ref.read(workManagementControllerProvider);
    final library = ref.read(libraryControllerProvider);
    try {
      var targetWorkId = widget.work.id;
      final split = widget.splitFiles;
      if (split != null && split.isNotEmpty) {
        targetWorkId = await mgmt.splitVariantsToIndependentWork(
          sourceWorkId: widget.work.id,
          variantIds: split.map((v) => v.id).toList(growable: false),
          initialTitle: bgm.displayTitle,
        );
      }
      await mgmt.bindWorkHybrid(
        workId: targetWorkId,
        request: HybridMatchRequest(
          bangumiSubject: bgm,
          tmdbDetail: tmdb,
          tmdbSeasonNumber: tmdb.mediaType == TmdbMediaType.movie
              ? 1
              : _selectedSeasonNumber,
          startEpisodeNumber: _startEpisodeNumber,
        ),
      );
      await library.reload();
      if (!mounted) return;
      showKonataToast(
        context,
        '已完成混合绑定：${bgm.displayTitle} ↔ ${tmdb.title}',
      );
      widget.onBoundSuccess();
    } catch (err) {
      if (!mounted) return;
      showKonataToast(context, '混合绑定失败：$err', isError: true);
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selectedBgm = _selectedBgm;
    final selectedTmdb = _selectedTmdbDetail;
    final episodes = _seasonDetail?.episodes ?? const <TmdbEpisodeDetail>[];

    final tmdbTerms = <String>{
      if (selectedBgm != null) selectedBgm.displayTitle,
      if (selectedBgm != null && selectedBgm.name.trim().isNotEmpty)
        selectedBgm.name.trim(),
      ...widget.quickTerms,
    }.toList(growable: false);

    return KonataDraggableScrollbar(
      controller: _panelScrollController,
      builder: (_, panelSc) => SingleChildScrollView(
        controller: panelSc,
        padding: const EdgeInsets.only(right: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _StepSectionHeader(
              step: 1,
              title: '检索并选定 Bangumi 词条（确定独立标题、评分与简介）',
              done: selectedBgm != null,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: KonataSearchField(
                    controller: _bgmQueryController,
                    onSubmitted: (_) => _searchBangumi(),
                    onClear: () => _bgmQueryController.clear(),
                  ),
                ),
                const SizedBox(width: 8),
                KonataPillButton.secondary(
                  label: _searchingBgm ? '检索中…' : '搜 BGM',
                  compact: true,
                  onPressed: _searchingBgm ? null : _searchBangumi,
                ),
              ],
            ),
            if (widget.quickTerms.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              KonataQuickFillRow(
                terms: widget.quickTerms,
                disabled: _searchingBgm,
                onPick: (term) {
                  _bgmQueryController.text = term;
                  _searchBangumi();
                },
              ),
            ],
            if (_bgmResults.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 156),
                child: KonataDraggableScrollbar(
                  controller: _bgmScrollController,
                  builder: (_, sc) => ListView.separated(
                    controller: sc,
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(right: 12),
                    itemCount: _bgmResults.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, index) {
                      final item = _bgmResults[index];
                      final active = _selectedBgm?.id == item.id;
                      return _HybridSelectableCard(
                        selected: active,
                        imagePath: item.posterUrl,
                        title: item.displayTitle,
                        subtitle: [
                          'BGM #${item.id}',
                          if (item.year != null) '${item.year}',
                          if (item.totalEpisodes != null)
                            '${item.totalEpisodes} 话',
                          if (item.score != null && item.score! > 0)
                            '评分 ${item.score!.toStringAsFixed(1)}',
                        ].join(' · '),
                        onTap: () {
                          setState(() => _selectedBgm = item);
                          if (_tmdbQueryController.text.trim().isEmpty) {
                            _tmdbQueryController.text = item.displayTitle;
                          }
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            _StepSectionHeader(
              step: 2,
              title: '选择 TMDB 母剧条目并设定季集映射偏移（提供剧照与背景图）',
              done: selectedTmdb != null,
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: KonataSearchField(
                    controller: _tmdbQueryController,
                    onSubmitted: (_) => _searchTmdb(),
                    onClear: () => _tmdbQueryController.clear(),
                  ),
                ),
                const SizedBox(width: 8),
                KonataPillButton.secondary(
                  label: _searchingTmdb ? '检索中…' : '搜 TMDB',
                  compact: true,
                  onPressed: _searchingTmdb ? null : _searchTmdb,
                ),
              ],
            ),
            if (tmdbTerms.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              KonataQuickFillRow(
                terms: tmdbTerms.take(5).toList(growable: false),
                disabled: _searchingTmdb,
                onPick: (term) {
                  _tmdbQueryController.text = term;
                  _searchTmdb();
                },
              ),
            ],
            if (_tmdbResults.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 156),
                child: KonataDraggableScrollbar(
                  controller: _tmdbScrollController,
                  builder: (_, sc) => ListView.separated(
                    controller: sc,
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(right: 12),
                    itemCount: _tmdbResults.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, index) {
                      final hit = _tmdbResults[index];
                      final active =
                          selectedTmdb?.tmdbId == hit.tmdbId &&
                          selectedTmdb?.mediaType == hit.mediaType;
                      return _HybridSelectableCard(
                        selected: active,
                        imagePath: hit.posterPath,
                        title: hit.title,
                        subtitle: [
                          'TMDB #${hit.tmdbId}',
                          hit.mediaType == TmdbMediaType.tv ? '剧集' : '剧场版',
                          if (hit.year != null) '${hit.year}',
                        ].join(' · '),
                        onTap: () => _selectTmdbCandidate(hit),
                      );
                    },
                  ),
                ),
              ),
            ],
            if (_loadingTmdbDetail) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('正在拉取 TMDB 季集详情…', style: KonataTheme.captionStyle(p)),
                ],
              ),
            ],
            if (selectedTmdb != null &&
                selectedTmdb.mediaType == TmdbMediaType.tv) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: p.softFill,
                  borderRadius: KonataTheme.borderRadiusControl,
                  border: Border.all(color: p.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '目标季别与起始集映射',
                      style: KonataTheme.cardTitleStyle(
                        p,
                        fontSize: KonataTheme.fontSizeBodySm,
                      ),
                    ),
                    const SizedBox(height: 8),
                    LayoutBuilder(
                      builder: (_, constraints) {
                        final seasonDrop = selectedTmdb.seasons.isNotEmpty
                            ? KonataDropdown<int>(
                                dense: true,
                                value: _selectedSeasonNumber,
                                options: <KonataDropdownOption<int>>[
                                  for (final s in selectedTmdb.seasons)
                                    KonataDropdownOption<int>(
                                      value: s.seasonNumber,
                                      label:
                                          '第 ${s.seasonNumber} 季 · ${s.name} (${s.episodeCount} 话)',
                                    ),
                                ],
                                onChanged: (season) {
                                  setState(
                                    () => _selectedSeasonNumber = season,
                                  );
                                  _loadSeasonDetail(
                                    selectedTmdb.tmdbId,
                                    season,
                                  );
                                },
                              )
                            : Container(
                                height: 34,
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: p.surface,
                                  borderRadius: KonataTheme.borderRadiusControl,
                                  border: Border.all(
                                    color: KonataTheme.subtleControlBorder(p),
                                  ),
                                ),
                                child: Text(
                                  '第 $_selectedSeasonNumber 季',
                                  style: KonataTheme.captionStyle(p),
                                ),
                              );
                        final epWidget = episodes.isNotEmpty
                            ? KonataDropdown<int>(
                                dense: true,
                                value: _startEpisodeNumber,
                                options: <KonataDropdownOption<int>>[
                                  for (final ep in episodes)
                                    KonataDropdownOption<int>(
                                      value: ep.episodeNumber,
                                      label:
                                          '从第 ${ep.episodeNumber} 集 · ${ep.title}',
                                    ),
                                ],
                                onChanged: _setStartEpisode,
                              )
                            : _EpisodeNumberInputField(
                                controller: _startEpController,
                                value: _startEpisodeNumber,
                                onChanged: _setStartEpisode,
                              );

                        if (constraints.maxWidth < 460) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              seasonDrop,
                              const SizedBox(height: 8),
                              epWidget,
                            ],
                          );
                        }
                        return Row(
                          children: <Widget>[
                            Expanded(child: seasonDrop),
                            const SizedBox(width: 10),
                            Expanded(child: epWidget),
                          ],
                        );
                      },
                    ),
                    if (_loadingSeasonDetail) ...<Widget>[
                      const SizedBox(height: 8),
                      Text('正在加载单季分集列表…', style: KonataTheme.captionStyle(p)),
                    ] else if (episodes.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      _buildMappingPreview(p, episodes),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                KonataPillButton.primary(
                  label: _submitting ? '绑定提交中…' : '确认混合绑定',
                  icon: Icons.link_rounded,
                  onPressed: (selectedBgm == null ||
                          selectedTmdb == null ||
                          _submitting)
                      ? null
                      : _submit,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMappingPreview(
    KonataPalette p,
    List<TmdbEpisodeDetail> episodes,
  ) {
    final startIdx = episodes.indexWhere(
      (e) => e.episodeNumber == _startEpisodeNumber,
    );
    final safeStart = startIdx < 0 ? 0 : startIdx;
    final previewCount = math.min(3, episodes.length - safeStart);
    final sCode = _selectedSeasonNumber.toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '映射预览（前 $previewCount 集）',
          style: KonataTheme.captionStyle(
            p,
            fontSize: KonataTheme.fontSizeCaptionXs,
          ),
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < previewCount; i++) ...<Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Builder(
              builder: (_) {
                final ep = episodes[safeStart + i];
                final eCode = ep.episodeNumber.toString().padLeft(2, '0');
                return Text(
                  '本地第 ${i + 1} 集  ↔  TMDB S${sCode}E$eCode：${ep.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: KonataTheme.textStyle(
                    color: p.textSecondary,
                    fontSize: KonataTheme.fontSizeCaptionSm,
                    tabularFigures: true,
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _StepSectionHeader extends StatelessWidget {
  const _StepSectionHeader({
    required this.step,
    required this.title,
    required this.done,
  });

  final int step;
  final String title;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: <Widget>[
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? p.success : p.accent,
          ),
          child: done
              ? const Icon(
                  Icons.check_rounded,
                  size: 13,
                  color: KonataTheme.pureWhite,
                )
              : Text(
                  '$step',
                  style: KonataTheme.textStyle(
                    color: KonataTheme.pureWhite,
                    fontSize: KonataTheme.fontSizeCaptionXs,
                    weight: KonataTheme.weightActive,
                    tabularFigures: true,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: KonataTheme.cardTitleStyle(
              p,
              fontSize: KonataTheme.fontSizeBodySm,
            ),
          ),
        ),
      ],
    );
  }
}

class _HybridSelectableCard extends StatefulWidget {
  const _HybridSelectableCard({
    required this.selected,
    required this.imagePath,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String? imagePath;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  State<_HybridSelectableCard> createState() => _HybridSelectableCardState();
}

class _HybridSelectableCardState extends State<_HybridSelectableCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionMicro,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.accentBadge.bg
                : (_hovered ? p.surfaceHover : p.softFill),
            borderRadius: KonataTheme.borderRadiusControl,
            border: Border.all(
              color: widget.selected
                  ? KonataTheme.activeControlBorder(p)
                  : (_hovered ? p.hoverBorder : p.hairline),
            ),
          ),
          child: Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: KonataTheme.borderRadiusChipSm,
                child: SizedBox(
                  width: 38,
                  height: 54,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.surface,
                      borderRadius: KonataTheme.borderRadiusChipSm,
                      border: Border.all(color: p.posterBorder),
                    ),
                    child: ManagedImage(
                      path: widget.imagePath,
                      targetWidth: 100,
                      fit: BoxFit.cover,
                      errorWidget: Icon(
                        Icons.movie_outlined,
                        size: 16,
                        color: p.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.cardTitleStyle(
                        p,
                        fontSize: KonataTheme.fontSizeBodySm,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: KonataTheme.captionStyle(
                        p,
                        fontSize: KonataTheme.fontSizeCaptionXs,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.selected) ...<Widget>[
                const SizedBox(width: 8),
                Icon(Icons.check_circle_rounded, size: 17, color: p.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 当目标季缺少分集列表时提供的直填高集号数字框与微调按钮组合。
class _EpisodeNumberInputField extends StatelessWidget {
  const _EpisodeNumberInputField({
    required this.controller,
    required this.value,
    required this.onChanged,
  });

  final TextEditingController controller;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: <Widget>[
        Expanded(
          child: KonataSoftTextField(
            controller: controller,
            dense: true,
            height: 34,
            hintText: '起始集号（可直填高集号）',
            keyboardType: TextInputType.number,
            onChanged: (raw) {
              final parsed = int.tryParse(raw.trim());
              if (parsed != null && parsed >= 1) {
                onChanged(parsed);
              }
            },
          ),
        ),
        const SizedBox(width: 6),
        KonataCapsuleIconButton(
          icon: Icons.remove_rounded,
          tooltip: '起始集减一',
          color: p.textSecondary,
          size: 16,
          fixedSize: 28,
          onTap: value > 1 ? () => onChanged(value - 1) : null,
        ),
        const SizedBox(width: 4),
        KonataCapsuleIconButton(
          icon: Icons.add_rounded,
          tooltip: '起始集加一',
          color: p.textSecondary,
          size: 16,
          fixedSize: 28,
          onTap: () => onChanged(value + 1),
        ),
      ],
    );
  }
}
