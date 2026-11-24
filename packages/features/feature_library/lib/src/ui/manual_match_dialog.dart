import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../providers.dart';
import 'hybrid_match_panel.dart';
import 'managed_image.dart';

enum _ManualMatchMode { tmdb, bangumiOnly, hybrid }

/// 弹出手动匹配与条目纠偏弹窗（支持 TMDB 绑定、纯 Bangumi 绑定及双源混合绑定）。
Future<bool> showManualMatchDialog(
  BuildContext context, {
  required Work work,
}) async {
  final result = await showKonataGlassDialog<bool>(
    context: context,
    builder: (_) => _ManualMatchDialog(work: work),
  );
  return result ?? false;
}

class _ManualMatchDialog extends ConsumerStatefulWidget {
  const _ManualMatchDialog({required this.work});

  final Work work;

  @override
  ConsumerState<_ManualMatchDialog> createState() => _ManualMatchDialogState();
}

class _ManualMatchDialogState extends ConsumerState<_ManualMatchDialog> {
  _ManualMatchMode _mode = _ManualMatchMode.tmdb;
  late final TextEditingController _queryCtrl;
  List<TmdbSearchResult> _tmdbHits = const <TmdbSearchResult>[];
  List<BangumiSubjectCandidate> _bgmHits = const <BangumiSubjectCandidate>[];
  bool _searching = false;
  bool _binding = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _queryCtrl = TextEditingController(text: widget.work.title);
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSearch());
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _errorText = null;
    });
    final mgmt = ref.read(workManagementControllerProvider);
    try {
      if (_mode == _ManualMatchMode.tmdb) {
        final hits = await mgmt.searchTmdb(query);
        if (!mounted) return;
        setState(() {
          _tmdbHits = hits;
          _searching = false;
        });
      } else if (_mode == _ManualMatchMode.bangumiOnly) {
        final hits = await mgmt.searchBangumi(query);
        if (!mounted) return;
        setState(() {
          _bgmHits = hits;
          _searching = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _errorText = '检索失败：$error';
      });
    }
  }

  Future<void> _bindTmdb(TmdbSearchResult hit) async {
    if (_binding) return;
    setState(() {
      _binding = true;
      _errorText = null;
    });
    try {
      await ref
          .read(workManagementControllerProvider)
          .bindWorkToTmdb(
            workId: widget.work.id,
            tmdbId: hit.tmdbId,
            mediaType: hit.mediaType,
          );
      if (!mounted) return;
      showKonataToast(context, '已绑定并锁定为「${hit.title}」');
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _binding = false;
        _errorText = '绑定失败：$error';
      });
    }
  }

  Future<void> _bindBangumiOnly(BangumiSubjectCandidate subject) async {
    if (_binding) return;
    setState(() {
      _binding = true;
      _errorText = null;
    });
    try {
      await ref
          .read(workManagementControllerProvider)
          .bindWorkBangumiOnly(
            workId: widget.work.id,
            bangumiSubject: subject,
          );
      if (!mounted) return;
      showKonataToast(context, '已独立绑定 Bangumi 条目「${subject.displayTitle}」');
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _binding = false;
        _errorText = '绑定失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final screen = MediaQuery.sizeOf(context);
    final bodyHeight = (screen.height * 0.68).clamp(280.0, 560.0);

    return KonataGlassDialog(
      title: '手动匹配纠偏 · ${widget.work.title}',
      width: (screen.width - 28).clamp(300.0, 640.0),
      actions: [
        KonataPillButton.ghost(
          label: '关闭',
          onPressed: _binding ? null : () => Navigator.of(context).pop(false),
        ),
      ],
      child: SizedBox(
        height: bodyHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KonataSegmentedCapsule<_ManualMatchMode>(
              selected: _mode,
              expand: true,
              compact: true,
              options: const [
                KonataSegmentOption(
                  value: _ManualMatchMode.tmdb,
                  label: 'TMDB 绑定',
                ),
                KonataSegmentOption(
                  value: _ManualMatchMode.bangumiOnly,
                  label: 'Bangumi 独立',
                ),
                KonataSegmentOption(
                  value: _ManualMatchMode.hybrid,
                  label: '双源混合',
                ),
              ],
              onChanged: (next) {
                setState(() {
                  _mode = next;
                  _errorText = null;
                });
                if (next != _ManualMatchMode.hybrid) {
                  _runSearch();
                }
              },
            ),
            const SizedBox(height: 12),
            if (_mode == _ManualMatchMode.hybrid)
              Expanded(
                child: HybridMatchPanel(
                  initialQuery: widget.work.title,
                  onBindHybrid: (req) async {
                    await ref
                        .read(workManagementControllerProvider)
                        .bindWorkHybrid(workId: widget.work.id, request: req);
                    if (!context.mounted) return;
                    showKonataToast(
                      context,
                      '已完成双源混合绑定并锁定「${req.bangumiSubject.displayTitle}」',
                    );
                    Navigator.of(context).pop(true);
                  },
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: KonataSoftTextField(
                      controller: _queryCtrl,
                      hintText: _mode == _ManualMatchMode.tmdb
                          ? '输入番剧标题或英文名检索 TMDB…'
                          : '输入番剧或 OVA 标题检索 Bangumi…',
                      dense: true,
                      onSubmitted: (_) => _runSearch(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  KonataPillButton.primary(
                    label: _searching ? '搜索中…' : '搜索',
                    compact: true,
                    onPressed: _searching ? null : _runSearch,
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
              const SizedBox(height: 10),
              Expanded(
                child: _searching
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        ),
                      )
                    : _mode == _ManualMatchMode.tmdb
                    ? _buildTmdbList(p)
                    : _buildBangumiList(p),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTmdbList(KonataPalette p) {
    if (_tmdbHits.isEmpty) {
      return Center(
        child: Text(
          '暂无 TMDB 搜索结果，可尝试简化标题关键词',
          style: TextStyle(fontSize: 13, color: p.textMuted),
        ),
      );
    }
    return KonataDraggableScrollbar(
      builder: (context, scrollCtrl) => ListView.separated(
        controller: scrollCtrl,
        padding: const EdgeInsets.only(right: 6),
        itemCount: _tmdbHits.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final hit = _tmdbHits[index];
          return _CandidateResultCard(
            title: hit.title,
            subtitle: [
              hit.mediaType == TmdbMediaType.movie ? '剧场版' : 'TV 动画',
              if (hit.year != null) '${hit.year}',
              'TMDB ${hit.tmdbId}',
            ].join(' · '),
            overview: hit.overview,
            posterPath: hit.posterPath,
            binding: _binding,
            onApply: () => _bindTmdb(hit),
          );
        },
      ),
    );
  }

  Widget _buildBangumiList(KonataPalette p) {
    if (_bgmHits.isEmpty) {
      return Center(
        child: Text(
          '暂无 Bangumi 搜索结果，可尝试更换日文原名或简写',
          style: TextStyle(fontSize: 13, color: p.textMuted),
        ),
      );
    }
    return KonataDraggableScrollbar(
      builder: (context, scrollCtrl) => ListView.separated(
        controller: scrollCtrl,
        padding: const EdgeInsets.only(right: 6),
        itemCount: _bgmHits.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final subject = _bgmHits[index];
          return _CandidateResultCard(
            title: subject.displayTitle,
            subtitle: [
              'BGM ${subject.id}',
              if (subject.year != null) '${subject.year}',
              if (subject.score != null) '评分 ${subject.score!.toStringAsFixed(1)}',
            ].join(' · '),
            overview: subject.summary,
            posterPath: subject.posterUrl,
            binding: _binding,
            onApply: () => _bindBangumiOnly(subject),
          );
        },
      ),
    );
  }
}

class _CandidateResultCard extends StatelessWidget {
  const _CandidateResultCard({
    required this.title,
    required this.subtitle,
    required this.overview,
    required this.posterPath,
    required this.binding,
    required this.onApply,
  });

  final String title;
  final String subtitle;
  final String? overview;
  final String? posterPath;
  final bool binding;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.elevatedSurface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 46,
              height: 69,
              child: ManagedImage(
                path: posterPath,
                targetWidth: 256,
                subfolder: PhotoSubfolder.posters,
              ),
            ),
          ),
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
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: p.textMuted),
                ),
                if (overview != null && overview!.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    overview!.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: p.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          KonataPillButton.primary(
            label: binding ? '写入中…' : '绑定',
            compact: true,
            onPressed: binding ? null : onApply,
          ),
        ],
      ),
    );
  }
}
