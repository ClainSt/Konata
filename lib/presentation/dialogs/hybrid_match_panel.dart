import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/source_actions_provider.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/adaptive_responsive_row.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_dropdown.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/managed_image.dart';
import '../theme/konata_theme.dart';

/// Bangumi 独立条目 × TMDB 母系列指定季/集 双源混合匹配面板。
class HybridMatchPanel extends ConsumerStatefulWidget {
  /// 创建双源混合匹配面板。
  const HybridMatchPanel({
    super.key,
    required this.initialQuery,
    required this.fileCount,
    required this.imageLoader,
    required this.disabled,
    required this.onSubmit,
    this.quickTerms = const [],
  });

  /// 初始搜索词。
  final String initialQuery;

  /// 待绑定的视频文件数量（用于预览单集或集数区间映射）。
  final int fileCount;

  /// 图片加载器。
  final ManagedImageLoader imageLoader;

  /// 外部是否处于提交锁定态。
  final bool disabled;

  /// 提交混合绑定参数回调。
  final Future<void> Function(HybridMatchRequest request) onSubmit;

  /// 从源文件名 / 目录解析出的一键快捷填入词列表。
  final List<String> quickTerms;

  @override
  ConsumerState<HybridMatchPanel> createState() => _HybridMatchPanelState();
}

class _HybridMatchPanelState extends ConsumerState<HybridMatchPanel> {
  late final TextEditingController _bgmQueryCtrl;
  late final TextEditingController _tmdbQueryCtrl;
  final TextEditingController _episodeNumCtrl = TextEditingController(
    text: '1',
  );
  final FocusNode _bgmFocusNode = FocusNode();
  final FocusNode _tmdbFocusNode = FocusNode();
  final FocusNode _episodeNumFocusNode = FocusNode();
  final ScrollController _bgmScrollCtrl = ScrollController();
  final ScrollController _tmdbScrollCtrl = ScrollController();
  final ScrollController _epScrollCtrl = ScrollController();
  final ScrollController _outerScrollCtrl = ScrollController();

  bool _searchingBgm = false;
  bool _loadingBgmDetail = false;
  List<BangumiSubjectCandidate> _bgmResults = const [];
  BangumiSubjectCandidate? _selectedBgm;

  bool _searchingTmdb = false;
  bool _loadingTmdbDetail = false;
  bool _loadingTmdbSeason = false;
  List<TmdbSearchResult> _tmdbResults = const [];
  TmdbWorkDetail? _selectedTmdbDetail;
  int _selectedSeasonNumber = 0;
  TmdbSeasonDetail? _selectedSeasonDetail;
  int _startEpisodeNumber = 1;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _bgmQueryCtrl = TextEditingController(text: widget.initialQuery);
    _tmdbQueryCtrl = TextEditingController(text: widget.initialQuery);
    _bgmFocusNode.addListener(_onFocusUpdated);
    _tmdbFocusNode.addListener(_onFocusUpdated);
    _episodeNumFocusNode.addListener(_onFocusUpdated);
  }

  void _onFocusUpdated() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _bgmFocusNode.removeListener(_onFocusUpdated);
    _tmdbFocusNode.removeListener(_onFocusUpdated);
    _episodeNumFocusNode.removeListener(_onFocusUpdated);
    _bgmFocusNode.dispose();
    _tmdbFocusNode.dispose();
    _episodeNumFocusNode.dispose();
    _bgmQueryCtrl.dispose();
    _tmdbQueryCtrl.dispose();
    _episodeNumCtrl.dispose();
    _bgmScrollCtrl.dispose();
    _tmdbScrollCtrl.dispose();
    _epScrollCtrl.dispose();
    _outerScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _searchBangumi() async {
    final query = _bgmQueryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searchingBgm = true;
      _errorText = null;
    });
    try {
      final list = await ref
          .read(konataActionsProvider)
          .searchBangumiInteractive(query);
      if (!mounted) return;
      setState(() {
        _bgmResults = list;
        _searchingBgm = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = 'Bangumi 搜索失败: $e';
        _searchingBgm = false;
      });
    }
  }

  Future<void> _pickBangumi(BangumiSubjectCandidate item) async {
    setState(() {
      _selectedBgm = item;
      _loadingBgmDetail = true;
      _errorText = null;
    });
    try {
      final detail = await ref
          .read(konataActionsProvider)
          .getBangumiSubjectDetailInteractive(item.id);
      if (!mounted) return;
      setState(() {
        _selectedBgm = detail ?? item;
        _loadingBgmDetail = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingBgmDetail = false);
    }
  }

  Future<void> _searchTmdb() async {
    final query = _tmdbQueryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searchingTmdb = true;
      _errorText = null;
    });
    try {
      final results = await ref
          .read(konataActionsProvider)
          .searchTmdbInteractive(query);
      if (!mounted) return;
      setState(() {
        _tmdbResults = results;
        _searchingTmdb = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = 'TMDB 搜索失败: $e';
        _searchingTmdb = false;
      });
    }
  }

  Future<void> _pickTmdb(TmdbSearchResult item) async {
    setState(() {
      _loadingTmdbDetail = true;
      _errorText = null;
    });
    try {
      final detail = await ref
          .read(konataActionsProvider)
          .getTmdbWorkDetailInteractive(item.tmdbId, item.mediaType);
      if (!mounted) return;
      if (detail == null) {
        setState(() {
          _loadingTmdbDetail = false;
          _errorText = '未能加载 TMDB 条目 #${item.tmdbId} 详情';
        });
        return;
      }

      var initialSeason = 1;
      if (detail.mediaType == TmdbMediaType.tv) {
        final queryLower =
            '${widget.initialQuery} ${_selectedBgm?.displayTitle ?? ''} ${_selectedBgm?.platform ?? ''}'
                .toLowerCase();
        final prefersSpecials =
            (_selectedBgm?.isSpecialFormat ?? false) ||
            RegExp(r'ova|oad|special|sp|alternative').hasMatch(queryLower);
        final hasSeasonZero = detail.seasons.any((s) => s.seasonNumber == 0);
        if (prefersSpecials || hasSeasonZero) {
          initialSeason = 0;
        } else if (detail.seasons.isNotEmpty) {
          initialSeason = detail.seasons.first.seasonNumber;
        }
      }

      setState(() {
        _selectedTmdbDetail = detail;
        _selectedSeasonNumber = initialSeason;
        _selectedSeasonDetail = null;
        _loadingTmdbDetail = false;
      });

      if (detail.mediaType == TmdbMediaType.tv) {
        await _loadTmdbSeason(detail.tmdbId, initialSeason);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingTmdbDetail = false;
        _errorText = '加载 TMDB 母系列失败: $e';
      });
    }
  }

  Future<void> _loadTmdbSeason(int tmdbId, int seasonNumber) async {
    setState(() {
      _selectedSeasonNumber = seasonNumber;
      _loadingTmdbSeason = true;
    });
    try {
      final season = await ref
          .read(konataActionsProvider)
          .getTmdbSeasonDetailInteractive(tmdbId, seasonNumber);
      if (!mounted) return;
      final firstEp = (season?.episodes.isNotEmpty ?? false)
          ? season!.episodes.first.episodeNumber
          : 1;
      setState(() {
        _selectedSeasonDetail = season;
        _startEpisodeNumber = firstEp;
        _episodeNumCtrl.text = firstEp.toString();
        _loadingTmdbSeason = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTmdbSeason = false);
    }
  }

  Future<void> _handleSubmit() async {
    final bgm = _selectedBgm;
    final tmdb = _selectedTmdbDetail;
    if (bgm == null || tmdb == null) return;
    final epNum =
        int.tryParse(_episodeNumCtrl.text.trim()) ?? _startEpisodeNumber;
    await widget.onSubmit(
      HybridMatchRequest(
        bangumiSubject: bgm,
        tmdbDetail: tmdb,
        tmdbSeasonNumber: tmdb.mediaType == TmdbMediaType.movie
            ? 1
            : _selectedSeasonNumber,
        startEpisodeNumber: epNum <= 0 ? 1 : epNum,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final effectiveStartEp =
        int.tryParse(_episodeNumCtrl.text.trim()) ?? _startEpisodeNumber;
    final fileCount = widget.fileCount <= 0 ? 1 : widget.fileCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_errorText != null) ...[
          Text(_errorText!, style: TextStyle(color: p.danger, fontSize: KonataTheme.fontSizeCaption)),
          const SizedBox(height: 6),
        ],
        Expanded(
          child: KonataDraggableScrollbar(
            controller: _outerScrollCtrl,
            builder: (_, ctrl) => SingleChildScrollView(
              controller: ctrl,
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildStepHeader(
                    p,
                    index: 1,
                    title: 'Bangumi 独立条目（封面、标题、年份、简介、Bangumi 评分）',
                    done: _selectedBgm != null,
                  ),
                  const SizedBox(height: 6),
                  if (_selectedBgm != null)
                    _buildSelectedBgmCard(p, _selectedBgm!)
                  else
                    _buildBgmSearchArea(p),
                  const SizedBox(height: 12),
                  _buildStepHeader(
                    p,
                    index: 2,
                    title: 'TMDB 母系列与季/集映射（剧照、分集标题、共享背景图池）',
                    done: _selectedTmdbDetail != null,
                  ),
                  const SizedBox(height: 6),
                  if (_selectedTmdbDetail != null)
                    _buildSelectedTmdbArea(p, _selectedTmdbDetail!, fileCount)
                  else
                    _buildTmdbSearchArea(p),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        AdaptiveResponsiveRow(
          minLeadingWidth: 160,
          estimatedTrailingWidth: 170,
          leading: Text(
            (_selectedBgm != null && _selectedTmdbDetail != null)
                ? _buildMappingPreview(effectiveStartEp, fileCount)
                : '请依次选定 Bangumi 独立条目与 TMDB 母系列季/集',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeCaption),
          ),
          trailing: KonataPillButton.primary(
            label: widget.disabled ? '绑定中...' : '确认混合绑定并锁定',
            icon: Icons.merge_type_rounded,
            compact: true,
            onPressed:
                (widget.disabled ||
                    _selectedBgm == null ||
                    _selectedTmdbDetail == null)
                ? null
                : _handleSubmit,
          ),
        ),
      ],
    );
  }

  String _buildMappingPreview(int startEp, int fileCount) {
    final s = _selectedTmdbDetail?.mediaType == TmdbMediaType.movie
        ? 1
        : _selectedSeasonNumber;
    final sStr = 'S${s.toString().padLeft(2, '0')}';
    final eStart = 'E${startEp.toString().padLeft(2, '0')}';
    if (fileCount <= 1) {
      return '映射预览：$sStr$eStart（独立封面 ${_selectedBgm!.displayTitle}）';
    }
    final eEnd = 'E${(startEp + fileCount - 1).toString().padLeft(2, '0')}';
    return '映射范围：$sStr$eStart ~ $sStr$eEnd（共 $fileCount 个文件）';
  }

  Widget _buildStepHeader(
    KonataPalette p, {
    required int index,
    required String title,
    required bool done,
  }) {
    return Row(
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done ? p.accent : p.softFill,
            shape: BoxShape.circle,
          ),
          child: Text(
            done ? '✓' : '$index',
            style: TextStyle(
              color: done ? KonataTheme.pureWhite : p.textSecondary,
              fontSize: KonataTheme.fontSizeBadge,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: p.textPrimary,
              fontSize: KonataTheme.fontSizeCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBgmSearchArea(KonataPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: KonataSearchField(
                controller: _bgmQueryCtrl,
                focusNode: _bgmFocusNode,
                dense: true,
                onSubmitted: (_) => _searchBangumi(),
              ),
            ),
            const SizedBox(width: 8),
            KonataPillButton.secondary(
              label: _searchingBgm ? '搜索中...' : '搜索 Bangumi',
              compact: true,
              onPressed: _searchingBgm || widget.disabled
                  ? null
                  : _searchBangumi,
            ),
          ],
        ),
        KonataQuickFillRow(
          terms: widget.quickTerms,
          disabled: _searchingBgm || widget.disabled,
          onPick: (term) {
            _bgmQueryCtrl.text = term;
            _bgmQueryCtrl.selection = TextSelection.collapsed(
              offset: term.length,
            );
          },
        ),
        if (_bgmResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 168),
            child: KonataDraggableScrollbar(
              controller: _bgmScrollCtrl,
              builder: (_, ctrl) => ListView.separated(
                controller: ctrl,
                padding: const EdgeInsets.only(right: 12),
                shrinkWrap: true,
                itemCount: _bgmResults.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (_, index) {
                  final item = _bgmResults[index];
                  final scoreLabel = item.score != null && item.score! > 0
                      ? 'Bangumi ${item.score!.toStringAsFixed(1)}'
                      : '暂无评分';
                  return _CandidatePickCard(
                    title: item.displayTitle,
                    subtitle:
                        '${item.year ?? '未知年份'} · ${item.platform ?? 'Anime'} · $scoreLabel',
                    posterPath: item.posterUrl,
                    imageLoader: widget.imageLoader,
                    disabled: widget.disabled,
                    onSelect: () => _pickBangumi(item),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSelectedBgmCard(KonataPalette p, BangumiSubjectCandidate bgm) {
    final scoreText = bgm.score != null && bgm.score! > 0
        ? 'Bangumi ${bgm.score!.toStringAsFixed(1)}'
        : 'Bangumi #${bgm.id}';
    return KonataSurfaceCard(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          _SmallCover(path: bgm.posterUrl, imageLoader: widget.imageLoader),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bgm.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${bgm.year ?? '未知年份'} · $scoreText${_loadingBgmDetail ? ' · 补全详情中...' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeCaptionSm),
                ),
              ],
            ),
          ),
          KonataPillButton.ghost(
            label: '重选',
            compact: true,
            onPressed: widget.disabled
                ? null
                : () => setState(() => _selectedBgm = null),
          ),
        ],
      ),
    );
  }

  Widget _buildTmdbSearchArea(KonataPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: KonataSearchField(
                controller: _tmdbQueryCtrl,
                focusNode: _tmdbFocusNode,
                dense: true,
                onSubmitted: (_) => _searchTmdb(),
              ),
            ),
            const SizedBox(width: 8),
            KonataPillButton.secondary(
              label: _searchingTmdb || _loadingTmdbDetail
                  ? '查询中...'
                  : '搜索母系列',
              compact: true,
              onPressed: _searchingTmdb || _loadingTmdbDetail || widget.disabled
                  ? null
                  : _searchTmdb,
            ),
          ],
        ),
        KonataQuickFillRow(
          terms: widget.quickTerms,
          disabled: _searchingTmdb || _loadingTmdbDetail || widget.disabled,
          onPick: (term) {
            _tmdbQueryCtrl.text = term;
            _tmdbQueryCtrl.selection = TextSelection.collapsed(
              offset: term.length,
            );
          },
        ),
        if (_tmdbResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 168),
            child: KonataDraggableScrollbar(
              controller: _tmdbScrollCtrl,
              builder: (_, ctrl) => ListView.separated(
                controller: ctrl,
                padding: const EdgeInsets.only(right: 12),
                shrinkWrap: true,
                itemCount: _tmdbResults.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (_, index) {
                  final item = _tmdbResults[index];
                  return _CandidatePickCard(
                    title: item.title,
                    subtitle:
                        '${item.mediaType == TmdbMediaType.tv ? 'TV 系列' : '电影'} · ${item.year ?? '未知年份'} · TMDB #${item.tmdbId}',
                    posterPath: item.posterPath,
                    imageLoader: widget.imageLoader,
                    disabled: widget.disabled || _loadingTmdbDetail,
                    onSelect: () => _pickTmdb(item),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSelectedTmdbArea(
    KonataPalette p,
    TmdbWorkDetail detail,
    int fileCount,
  ) {
    final seasonMap = <int, String>{};
    if (detail.mediaType == TmdbMediaType.tv) {
      seasonMap[0] = 'Season 0 (特别篇)';
      for (final s in detail.seasons) {
        seasonMap[s.seasonNumber] = s.seasonNumber == 0
            ? 'Season 0 (特别篇)'
            : 'Season ${s.seasonNumber} (${s.name})';
      }
    }
    final seasonNumbers = seasonMap.keys.toList()..sort();
    final episodes = _selectedSeasonDetail?.episodes ?? const [];

    return KonataSurfaceCard(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _SmallCover(
                path: detail.posterPath,
                imageLoader: widget.imageLoader,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: KonataTheme.fontSizeBodySm,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${detail.mediaType == TmdbMediaType.tv ? 'TMDB 母系列' : 'TMDB 电影'} · #${detail.tmdbId}（自动共享该系列背景图池）',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeCaptionSm),
                    ),
                  ],
                ),
              ),
              KonataPillButton.ghost(
                label: '重选',
                compact: true,
                onPressed: widget.disabled
                    ? null
                    : () => setState(() {
                        _selectedTmdbDetail = null;
                        _selectedSeasonDetail = null;
                      }),
              ),
            ],
          ),
          if (detail.mediaType == TmdbMediaType.tv) ...[
            const SizedBox(height: 8),
            AdaptiveResponsiveRow(
              minLeadingWidth: 160,
              estimatedTrailingWidth: 96,
              expandTrailingWhenStacked: true,
              leading: Row(
                children: [
                  Text(
                    'TMDB 季：',
                    style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeCaption),
                  ),
                  Expanded(
                    child: KonataDropdown<int>(
                      dense: true,
                      enabled: !_loadingTmdbSeason,
                      value: seasonNumbers.contains(_selectedSeasonNumber)
                          ? _selectedSeasonNumber
                          : seasonNumbers.first,
                      options: [
                        for (final sn in seasonNumbers)
                          KonataDropdownOption(
                            value: sn,
                            label: seasonMap[sn] ?? 'Season $sn',
                          ),
                      ],
                      onChanged: (sn) => _loadTmdbSeason(detail.tmdbId, sn),
                    ),
                  ),
                ],
              ),
              trailing: SizedBox(
                width: 96,
                child: KonataSoftTextField(
                  controller: _episodeNumCtrl,
                  focusNode: _episodeNumFocusNode,
                  label: fileCount > 1 ? '起始集号' : '对应集号',
                  keyboardType: TextInputType.number,
                  dense: true,
                  onChanged: (v) {
                    final parsed = int.tryParse(v.trim());
                    if (parsed != null && parsed > 0) {
                      setState(() => _startEpisodeNumber = parsed);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 6),
            if (_loadingTmdbSeason)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (episodes.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 112),
                child: KonataDraggableScrollbar(
                  controller: _epScrollCtrl,
                  builder: (_, ctrl) => ListView.separated(
                    controller: ctrl,
                    padding: const EdgeInsets.only(right: 12),
                    shrinkWrap: true,
                    itemCount: episodes.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (_, index) {
                      final ep = episodes[index];
                      final picked = ep.episodeNumber == _startEpisodeNumber;
                      return InkWell(
                        borderRadius: KonataTheme.borderRadiusChip,
                        onTap: () => setState(() {
                          _startEpisodeNumber = ep.episodeNumber;
                          _episodeNumCtrl.text = ep.episodeNumber.toString();
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: picked
                                ? p.accent.withValues(alpha: 0.16)
                                : p.softFill,
                            borderRadius: KonataTheme.borderRadiusChip,
                            border: Border.all(
                              color: picked
                                  ? p.accent.withValues(alpha: 0.45)
                                  : p.hairline,
                            ),
                          ),
                          child: Row(
                            children: [
                              Text(
                                'S${ep.seasonNumber.toString().padLeft(2, '0')}E${ep.episodeNumber.toString().padLeft(2, '0')}',
                                style: TextStyle(
                                  color: picked ? p.accent : p.textSecondary,
                                  fontSize: KonataTheme.fontSizeCaptionXs,
                                  fontFamily: 'Consolas',
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  ep.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.textPrimary,
                                    fontSize: KonataTheme.fontSizeCaption,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              )
            else
              Text(
                'TMDB 该季暂未返回分集目录，可直接填入对应集号进行绑定',
                style: TextStyle(color: p.textMuted, fontSize: KonataTheme.fontSizeCaptionSm),
              ),
          ],
        ],
      ),
    );
  }
}

class _SmallCover extends StatelessWidget {
  const _SmallCover({required this.path, required this.imageLoader});

  final String? path;
  final ManagedImageLoader imageLoader;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: KonataTheme.borderRadiusChipSm,
      child: SizedBox(
        width: 34,
        height: 48,
        child: path != null && path!.isNotEmpty
            ? ManagedImage(path!, loader: imageLoader, fit: BoxFit.cover)
            : Container(color: p.softFill),
      ),
    );
  }
}

class _CandidatePickCard extends StatelessWidget {
  const _CandidatePickCard({
    required this.title,
    required this.subtitle,
    required this.posterPath,
    required this.imageLoader,
    required this.disabled,
    required this.onSelect,
  });

  final String title;
  final String subtitle;
  final String? posterPath;
  final ManagedImageLoader imageLoader;
  final bool disabled;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataSurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      enableHover: true,
      child: Row(
        children: [
          _SmallCover(path: posterPath, imageLoader: imageLoader),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: KonataTheme.fontSizeBodySm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.textSecondary, fontSize: KonataTheme.fontSizeCaptionSm),
                ),
              ],
            ),
          ),
          KonataPillButton.ghost(
            label: '选定',
            compact: true,
            onPressed: disabled ? null : onSelect,
          ),
        ],
      ),
    );
  }
}
