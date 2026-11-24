import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/library_models.dart';
import '../providers.dart';

/// Bangumi 独立条目与 TMDB 母系列双源混搭混合绑定子面板。
///
/// 适用场景：OVA / 剧场版 / SP / 拆分季度在 Bangumi 拥有独立条目，而 TMDB 归属母系列特别篇或同季。
class HybridMatchPanel extends ConsumerStatefulWidget {
  /// 创建双源混合绑定面板。
  const HybridMatchPanel({
    super.key,
    required this.initialQuery,
    required this.onBindHybrid,
  });

  /// 预设搜索关键词（来自原作品目录或标题）。
  final String initialQuery;

  /// 点击「确认混合绑定」时回传完整 [HybridMatchRequest] 的异步回调。
  final Future<void> Function(HybridMatchRequest request) onBindHybrid;

  @override
  ConsumerState<HybridMatchPanel> createState() => _HybridMatchPanelState();
}

class _HybridMatchPanelState extends ConsumerState<HybridMatchPanel> {
  late final TextEditingController _bgmQueryCtrl;
  late final TextEditingController _tmdbQueryCtrl;
  final TextEditingController _seasonCtrl = TextEditingController(text: '1');
  final TextEditingController _startEpCtrl = TextEditingController(text: '1');

  List<BangumiSubjectCandidate> _bgmResults = const <BangumiSubjectCandidate>[];
  List<TmdbSearchResult> _tmdbResults = const <TmdbSearchResult>[];
  BangumiSubjectCandidate? _selectedBgm;
  TmdbWorkDetail? _selectedTmdbDetail;
  bool _searchingBgm = false;
  bool _searchingTmdb = false;
  bool _submitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _bgmQueryCtrl = TextEditingController(text: widget.initialQuery);
    _tmdbQueryCtrl = TextEditingController(text: widget.initialQuery);
  }

  @override
  void dispose() {
    _bgmQueryCtrl.dispose();
    _tmdbQueryCtrl.dispose();
    _seasonCtrl.dispose();
    _startEpCtrl.dispose();
    super.dispose();
  }

  Future<void> _searchBangumi() async {
    final q = _bgmQueryCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searchingBgm = true;
      _errorText = null;
    });
    try {
      final list = await ref
          .read(workManagementControllerProvider)
          .searchBangumi(q);
      if (!mounted) return;
      setState(() {
        _bgmResults = list;
        _searchingBgm = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searchingBgm = false;
        _errorText = 'Bangumi 搜索失败：$error';
      });
    }
  }

  Future<void> _searchTmdb() async {
    final q = _tmdbQueryCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searchingTmdb = true;
      _errorText = null;
    });
    try {
      final list = await ref
          .read(workManagementControllerProvider)
          .searchTmdb(q);
      if (!mounted) return;
      setState(() {
        _tmdbResults = list;
        _searchingTmdb = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searchingTmdb = false;
        _errorText = 'TMDB 搜索失败：$error';
      });
    }
  }

  Future<void> _selectTmdbCandidate(TmdbSearchResult hit) async {
    setState(() => _errorText = null);
    try {
      final detail = await ref
          .read(workManagementControllerProvider)
          .fetchTmdbDetail(hit.tmdbId, hit.mediaType);
      if (!mounted) return;
      setState(() {
        _selectedTmdbDetail =
            detail ??
            TmdbWorkDetail(
              tmdbId: hit.tmdbId,
              mediaType: hit.mediaType,
              title: hit.title,
              originalTitle: hit.originalTitle,
              year: hit.year,
              overview: hit.overview,
              posterPath: hit.posterPath,
              backdropPath: hit.backdropPath,
              genreIds: hit.genreIds,
            );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorText = '获取 TMDB 详情失败：$error');
    }
  }

  Future<void> _submit() async {
    final bgm = _selectedBgm;
    final tmdb = _selectedTmdbDetail;
    if (bgm == null || tmdb == null) return;
    final season = int.tryParse(_seasonCtrl.text.trim()) ?? 1;
    final startEp = int.tryParse(_startEpCtrl.text.trim()) ?? 1;

    setState(() {
      _submitting = true;
      _errorText = null;
    });
    try {
      await widget.onBindHybrid(
        HybridMatchRequest(
          bangumiSubject: bgm,
          tmdbDetail: tmdb,
          tmdbSeasonNumber: season < 0 ? 0 : season,
          startEpisodeNumber: startEp < 1 ? 1 : startEp,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorText = '混合绑定失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return KonataDraggableScrollbar(
      builder: (context, scrollCtrl) => ListView(
        controller: scrollCtrl,
        padding: const EdgeInsets.only(right: 6),
        children: [
          Text(
            '1. 选择提供主标题、封面与评分的 Bangumi 独立条目',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: KonataSoftTextField(
                  controller: _bgmQueryCtrl,
                  hintText: '搜索 Bangumi 条目名称…',
                  dense: true,
                  onSubmitted: (_) => _searchBangumi(),
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.secondary(
                label: _searchingBgm ? '搜索中…' : '搜 BGM',
                compact: true,
                onPressed: _searchingBgm ? null : _searchBangumi,
              ),
            ],
          ),
          if (_bgmResults.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final bgm in _bgmResults.take(4))
              _SelectableRow(
                selected: _selectedBgm?.id == bgm.id,
                title: bgm.displayTitle,
                subtitle: 'BGM ${bgm.id} · ${bgm.year ?? '未知年份'}',
                onTap: () => setState(() => _selectedBgm = bgm),
              ),
          ],
          const SizedBox(height: 12),
          Text(
            '2. 选择提供横版原画与剧集剧照的 TMDB 母系列',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: KonataSoftTextField(
                  controller: _tmdbQueryCtrl,
                  hintText: '搜索 TMDB 系列名称…',
                  dense: true,
                  onSubmitted: (_) => _searchTmdb(),
                ),
              ),
              const SizedBox(width: 8),
              KonataPillButton.secondary(
                label: _searchingTmdb ? '搜索中…' : '搜 TMDB',
                compact: true,
                onPressed: _searchingTmdb ? null : _searchTmdb,
              ),
            ],
          ),
          if (_tmdbResults.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final hit in _tmdbResults.take(4))
              _SelectableRow(
                selected: _selectedTmdbDetail?.tmdbId == hit.tmdbId,
                title: hit.title,
                subtitle:
                    'TMDB ${hit.tmdbId} · ${hit.mediaType == TmdbMediaType.movie ? '剧场版' : 'TV'} · ${hit.year ?? ''}',
                onTap: () => _selectTmdbCandidate(hit),
              ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: KonataSoftTextField(
                  controller: _seasonCtrl,
                  label: '目标 TMDB 季号（SP 填 0）',
                  dense: true,
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: KonataSoftTextField(
                  controller: _startEpCtrl,
                  label: '起始集号',
                  dense: true,
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          if (_errorText != null) ...[
            const SizedBox(height: 8),
            Text(
              _errorText!,
              style: TextStyle(fontSize: 12, color: p.danger),
            ),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: KonataPillButton.primary(
              label: _submitting ? '正在混合绑定…' : '确认混合绑定并锁定',
              onPressed:
                  (_submitting ||
                      _selectedBgm == null ||
                      _selectedTmdbDetail == null)
                  ? null
                  : _submit,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectableRow extends StatelessWidget {
  const _SelectableRow({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? p.accent.withValues(alpha: 0.14)
                : p.elevatedSurface.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? p.accent : p.hairline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: p.textMuted),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, size: 17, color: p.accent),
            ],
          ),
        ),
      ),
    );
  }
}
