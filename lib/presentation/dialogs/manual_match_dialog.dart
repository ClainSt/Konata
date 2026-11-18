import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers/artwork_provider.dart';
import '../../application/providers/library_providers.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/source_actions_provider.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/formatting/network_error_sanitizer.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/scraping/search_query_sanitizer.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_segmented_capsule.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_surface_card.dart';
import '../widgets/managed_image.dart';
import 'hybrid_match_panel.dart';

enum _ManualMatchMode { tmdb, hybrid, bangumiOnly }

/// 手动纠错匹配与文件拆分独立绑定工作台弹窗（全部采用流光无框原子组件）。
class ManualMatchDialog extends ConsumerStatefulWidget {
  /// 创建手动纠错弹窗。
  const ManualMatchDialog({
    super.key,
    required this.workId,
    required this.initialQuery,
  }) : splitVariants = const [];

  /// 创建将选中源文件拆分为独立作品的绑定工作台弹窗。
  const ManualMatchDialog.splitFiles({
    super.key,
    required this.workId,
    required this.splitVariants,
    required this.initialQuery,
  });

  /// 作品唯一 ID（拆分模式下为来源作品 ID）。
  final String workId;

  /// 待拆分为独立作品的源文件列表（非空时进入拆分模式）。
  final List<MediaVariant> splitVariants;

  /// 初始检索词。
  final String initialQuery;

  /// 当前是否处于「文件级拆分为独立作品」模式。
  bool get isSplitMode => splitVariants.isNotEmpty;

  @override
  ConsumerState<ManualMatchDialog> createState() => _ManualMatchDialogState();
}

class _ManualMatchDialogState extends ConsumerState<ManualMatchDialog> {
  final ScrollController _tmdbSearchScrollCtrl = ScrollController();
  final ScrollController _tmdbCandScrollCtrl = ScrollController();
  final ScrollController _bgmScrollCtrl = ScrollController();
  final FocusNode _tmdbQueryFocusNode = FocusNode();
  final FocusNode _directIdFocusNode = FocusNode();
  final FocusNode _bgmQueryFocusNode = FocusNode();
  late final TextEditingController _queryController;
  late final TextEditingController _bgmQueryController;
  final TextEditingController _directIdController = TextEditingController();
  _ManualMatchMode _mode = _ManualMatchMode.tmdb;
  TmdbMediaType _directType = TmdbMediaType.tv;
  bool _writeIdToFolder = false;
  bool _searching = false;
  bool _searchingBgm = false;
  bool _binding = false;
  String? _errorText;
  List<TmdbSearchResult> _searchResults = const [];
  List<BangumiSubjectCandidate> _bgmOnlyResults = const [];

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    _bgmQueryController = TextEditingController(text: widget.initialQuery);
    if (widget.isSplitMode) {
      _mode = _ManualMatchMode.hybrid;
    }
    _tmdbQueryFocusNode.addListener(_onFocusUpdated);
    _directIdFocusNode.addListener(_onFocusUpdated);
    _bgmQueryFocusNode.addListener(_onFocusUpdated);
  }

  void _onFocusUpdated() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tmdbSearchScrollCtrl.dispose();
    _tmdbCandScrollCtrl.dispose();
    _bgmScrollCtrl.dispose();
    _tmdbQueryFocusNode.removeListener(_onFocusUpdated);
    _directIdFocusNode.removeListener(_onFocusUpdated);
    _bgmQueryFocusNode.removeListener(_onFocusUpdated);
    _tmdbQueryFocusNode.dispose();
    _directIdFocusNode.dispose();
    _bgmQueryFocusNode.dispose();
    _queryController.dispose();
    _bgmQueryController.dispose();
    _directIdController.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _errorText = null;
    });
    try {
      final results = await ref
          .read(konataActionsProvider)
          .searchTmdbInteractive(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _searching = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = NetworkErrorSanitizer.toUserMessage(
            error,
            prefix: 'TMDB 搜索失败',
          );
          _searching = false;
        });
      }
    }
  }

  Future<void> _bindTarget(int tmdbId, TmdbMediaType mediaType) async {
    final currentBundle = ref.read(workDetailBundleProvider(widget.workId)).valueOrNull;
    var resetLocks = false;
    if (currentBundle != null &&
        currentBundle.work.tmdbId != null &&
        currentBundle.work.tmdbId != tmdbId) {
      final hasLocks =
          currentBundle.work.metadataLocked ||
          currentBundle.work.posterLocked ||
          currentBundle.work.backdropLocked ||
          currentBundle.variants.any((v) => v.mappingLocked);
      if (hasLocks && mounted) {
        final choice = await showKonataGlassDialog<bool>(
          context: context,
          builder: (ctx) => KonataGlassDialog(
            width: 440,
            title: '更换 TMDB 绑定条目',
            onClose: () => Navigator.of(ctx).pop(),
            actions: [
              KonataPillButton.ghost(
                label: '保留现有锁定',
                compact: true,
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
              KonataPillButton.primary(
                label: '重置并重新映射',
                compact: true,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ],
            child: Text(
              '检测到当前作品存在人工锁定的元数据、封面/背景或文件映射。切换到新 TMDB 条目后，是否重置这些锁定并重新自动映射剧集？',
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
          ),
        );
        if (choice == null || !mounted) return;
        resetLocks = choice;
      } else {
        resetLocks = true;
      }
    }

    setState(() {
      _binding = true;
      _errorText = null;
    });
    try {
      final Work resultWork;
      if (widget.isSplitMode) {
        resultWork = await ref
            .read(workManagementProvider)
            .splitVariantsToIndependentWork(
              sourceWorkId: widget.workId,
              variantIds: [for (final v in widget.splitVariants) v.id],
              tmdbTarget: (tmdbId: tmdbId, mediaType: mediaType),
              writeTmdbIdToFolderName: _writeIdToFolder,
            );
      } else {
        resultWork = await ref
            .read(scrapeControllerProvider.notifier)
            .rebindWork(
              workId: widget.workId,
              tmdbId: tmdbId,
              mediaType: mediaType,
              writeIdToFolderName: _writeIdToFolder,
              resetManualLocks: resetLocks,
            );
      }
      if (mounted) {
        Navigator.of(context).pop(resultWork);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = NetworkErrorSanitizer.toUserMessage(
            error,
            prefix: '绑定失败',
          );
          _binding = false;
        });
      }
    }
  }

  Future<void> _submitHybrid(HybridMatchRequest request) async {
    setState(() {
      _binding = true;
      _errorText = null;
    });
    try {
      final actions = ref.read(workManagementProvider);
      final resultWork = widget.isSplitMode
          ? await actions.splitVariantsToIndependentWork(
              sourceWorkId: widget.workId,
              variantIds: [for (final v in widget.splitVariants) v.id],
              hybridRequest: request,
            )
          : await actions.bindWorkHybrid(
              workId: widget.workId,
              request: request,
            );
      if (mounted) {
        Navigator.of(context).pop(resultWork);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = NetworkErrorSanitizer.toUserMessage(
            error,
            prefix: '混合绑定失败',
          );
          _binding = false;
        });
      }
    }
  }

  Future<void> _searchBangumiOnly() async {
    final query = _bgmQueryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searchingBgm = true;
      _errorText = null;
    });
    try {
      final results = await ref
          .read(konataActionsProvider)
          .searchBangumiInteractive(query);
      if (!mounted) return;
      setState(() {
        _bgmOnlyResults = results;
        _searchingBgm = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = NetworkErrorSanitizer.toUserMessage(
          error,
          prefix: 'Bangumi 搜索失败',
        );
        _searchingBgm = false;
      });
    }
  }

  Future<void> _bindBangumiOnly(BangumiSubjectCandidate subject) async {
    setState(() {
      _binding = true;
      _errorText = null;
    });
    try {
      final actions = ref.read(workManagementProvider);
      final resultWork = widget.isSplitMode
          ? await actions.splitVariantsToIndependentWork(
              sourceWorkId: widget.workId,
              variantIds: [for (final v in widget.splitVariants) v.id],
              bangumiOnlySubject: subject,
            )
          : await actions.bindWorkBangumiOnly(
              workId: widget.workId,
              bangumiSubject: subject,
            );
      if (mounted) {
        Navigator.of(context).pop(resultWork);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = NetworkErrorSanitizer.toUserMessage(
            error,
            prefix: '绑定失败',
          );
          _binding = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final candidatesAsync = ref.watch(
      workScrapeCandidatesProvider(widget.workId),
    );
    final variants = widget.isSplitMode
        ? widget.splitVariants
        : (ref.watch(workDetailBundleProvider(widget.workId)).valueOrNull?.variants ??
              const <MediaVariant>[]);
    final quickTerms = SearchQuerySanitizer.buildQuickSourceTerms(
      variants.map((v) => (fileName: v.fileName, relativePath: v.relativePath)),
      excludeQuery: widget.initialQuery,
    );
    final imageLoader = ref.watch(tmdbImageLoaderProvider);

    return KonataGlassDialog(
      width: 680,
      height: 600,
      title: widget.isSplitMode
          ? '绑定为独立作品 (${widget.splitVariants.length} 个源文件)'
          : '手动纠错匹配',
      onClose: _binding ? () {} : () => Navigator.of(context).pop(),
      child: Builder(
        builder: (dialogCtx) {
          final landscapeCompactInput =
              KonataGlassDialog.isLandscapeCompactInputActive(dialogCtx);
          final tmdbSearchingByDirectId =
              landscapeCompactInput && _directIdFocusNode.hasFocus;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Offstage(
                offstage: landscapeCompactInput,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.isSplitMode)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: p.softFill,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: p.hairline),
                        ),
                        child: Text(
                          '已选源文件：${widget.splitVariants.first.fileName}${widget.splitVariants.length > 1 ? ' 等 ${widget.splitVariants.length} 个视频' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.textSecondary, fontSize: 12),
                        ),
                      ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.15,
                        child: KonataSegmentedCapsule<_ManualMatchMode>(
                          compact: MediaQuery.sizeOf(dialogCtx).width < 560,
                          selected: _mode,
                          options: const [
                            KonataSegmentOption(
                              value: _ManualMatchMode.tmdb,
                              label: 'TMDB 匹配',
                            ),
                            KonataSegmentOption(
                              value: _ManualMatchMode.hybrid,
                              label: 'Bangumi × TMDB 混合',
                            ),
                            KonataSegmentOption(
                              value: _ManualMatchMode.bangumiOnly,
                              label: '仅 Bangumi',
                            ),
                          ],
                          onChanged: _binding
                              ? (_) {}
                              : (m) => setState(() {
                                  _mode = m;
                                  _errorText = null;
                                }),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
              if (_mode == _ManualMatchMode.tmdb)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Offstage(
                        offstage: tmdbSearchingByDirectId,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: KonataSoftTextField(
                                    controller: _queryController,
                                    focusNode: _tmdbQueryFocusNode,
                                    hintText: '输入作品中文名 / 日文原名 / 英文名搜索 TMDB',
                                    prefixIcon: Icons.search_rounded,
                                    onSubmitted: (_) => _performSearch(),
                                    dense: true,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                KonataPillButton.primary(
                                  label: _searching ? '搜索中...' : '搜索',
                                  compact:
                                      MediaQuery.sizeOf(dialogCtx).width < 520,
                                  onPressed: _searching || _binding
                                      ? null
                                      : _performSearch,
                                ),
                              ],
                            ),
                            KonataQuickFillRow(
                              terms: quickTerms,
                              disabled: _searching || _binding,
                              onPick: (term) {
                                _queryController.text = term;
                                _queryController.selection =
                                    TextSelection.collapsed(
                                  offset: term.length,
                                );
                              },
                            ),
                            SizedBox(height: landscapeCompactInput ? 4 : 10),
                          ],
                        ),
                      ),
                      Offstage(
                        offstage:
                            landscapeCompactInput && !tmdbSearchingByDirectId,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 148,
                                  child: KonataSoftTextField(
                                    controller: _directIdController,
                                    focusNode: _directIdFocusNode,
                                    hintText: '直接输入 TMDB ID',
                                    keyboardType: TextInputType.number,
                                    dense: true,
                                  ),
                                ),
                                MediaQuery.withClampedTextScaling(
                                  maxScaleFactor: 1.15,
                                  child: KonataSegmentedCapsule<TmdbMediaType>(
                                    compact: true,
                                    options: const [
                                      KonataSegmentOption(
                                        value: TmdbMediaType.tv,
                                        label: 'TV 番剧',
                                      ),
                                      KonataSegmentOption(
                                        value: TmdbMediaType.movie,
                                        label: '剧场版',
                                      ),
                                    ],
                                    selected: _directType,
                                    onChanged: (v) =>
                                        setState(() => _directType = v),
                                  ),
                                ),
                                KonataPillButton.secondary(
                                  label: '强制绑定',
                                  compact: true,
                                  onPressed: _binding
                                      ? null
                                      : () {
                                          final id = int.tryParse(
                                            _directIdController.text.trim(),
                                          );
                                          if (id != null && id > 0) {
                                            _bindTarget(id, _directType);
                                          } else {
                                            setState(
                                              () => _errorText =
                                                  '请输入有效的数字 TMDB ID',
                                            );
                                          }
                                        },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (!widget.isSplitMode)
                              Material(
                                type: MaterialType.transparency,
                                child: CheckboxListTile(
                                  value: _writeIdToFolder,
                                  onChanged: (v) => setState(
                                    () => _writeIdToFolder = v ?? false,
                                  ),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    '同时将 [tmdbid=xxx] 写入本地作品目录名（永久防错）',
                                    style: TextStyle(
                                      color: p.textSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_errorText != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            _errorText!,
                            style: TextStyle(color: p.danger, fontSize: 12),
                          ),
                        ),
                      SizedBox(height: landscapeCompactInput ? 4 : 10),
                      Expanded(
                        child: _searchResults.isNotEmpty
                            ? KonataDraggableScrollbar(
                                controller: _tmdbSearchScrollCtrl,
                                builder: (_, ctrl) => ListView.separated(
                                  controller: ctrl,
                                  padding: const EdgeInsets.only(right: 14),
                                  itemCount: _searchResults.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (_, index) {
                                    final item = _searchResults[index];
                                    return _MatchResultTile(
                                      title: item.title,
                                      subtitle:
                                          '${item.mediaType == TmdbMediaType.tv ? 'TV' : '剧场版'} · ${item.year ?? '未知年份'} · TMDB #${item.tmdbId}',
                                      posterPath: item.posterPath,
                                      imageLoader: imageLoader,
                                      disabled: _binding,
                                      onSelect: () => _bindTarget(
                                        item.tmdbId,
                                        item.mediaType,
                                      ),
                                    );
                                  },
                                ),
                              )
                            : (widget.isSplitMode
                                  ? Center(
                                      child: Text(
                                        '搜索 TMDB 词条或直接填入 TMDB ID 创建独立作品',
                                        style: TextStyle(
                                          color: p.textMuted,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    )
                                  : candidatesAsync.when(
                                      data: (candidates) {
                                        if (candidates.isEmpty) {
                                          return Center(
                                            child: Text(
                                              '输入关键词搜索或直接填入 TMDB ID 进行强制锁定',
                                              style: TextStyle(
                                                color: p.textMuted,
                                                fontSize: 12.5,
                                              ),
                                            ),
                                          );
                                        }
                                        return KonataDraggableScrollbar(
                                          controller: _tmdbCandScrollCtrl,
                                          builder: (_, ctrl) =>
                                              ListView.separated(
                                                controller: ctrl,
                                                padding: const EdgeInsets.only(
                                                  right: 14,
                                                ),
                                                itemCount: candidates.length,
                                                separatorBuilder: (_, _) =>
                                                    const SizedBox(height: 8),
                                                itemBuilder: (_, index) {
                                                  final c = candidates[index];
                                                  return _MatchResultTile(
                                                    title: c.title,
                                                    subtitle:
                                                        '推荐候选 #${c.rank} · 匹配度 ${c.score.toStringAsFixed(0)} · ${c.year ?? '未知年份'}',
                                                    posterPath: c.posterPath,
                                                    imageLoader: imageLoader,
                                                    disabled: _binding,
                                                    onSelect: () => _bindTarget(
                                                      c.tmdbId,
                                                      c.mediaType,
                                                    ),
                                                  );
                                                },
                                              ),
                                        );
                                      },
                                      loading: () => const Center(
                                        child: CircularProgressIndicator(),
                                      ),
                                      error: (_, _) => const SizedBox.shrink(),
                                    )),
                      ),
                    ],
                  ),
                )
              else if (_mode == _ManualMatchMode.hybrid)
                Expanded(
                  child: HybridMatchPanel(
                    initialQuery: widget.initialQuery,
                    fileCount: widget.isSplitMode
                        ? widget.splitVariants.length
                        : 1,
                    imageLoader: imageLoader,
                    disabled: _binding,
                    onSubmit: _submitHybrid,
                    quickTerms: quickTerms,
                  ),
                )
              else
                Expanded(
                  child: _buildBangumiOnlyTab(
                    p,
                    imageLoader,
                    quickTerms,
                    landscapeCompactInput: landscapeCompactInput,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBangumiOnlyTab(
    KonataPalette p,
    ManagedImageLoader imageLoader,
    List<String> quickTerms, {
    bool landscapeCompactInput = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: KonataSoftTextField(
                controller: _bgmQueryController,
                focusNode: _bgmQueryFocusNode,
                hintText: '输入作品中文名 / 日文名检索 Bangumi 条目',
                prefixIcon: Icons.search_rounded,
                dense: true,
                onSubmitted: (_) => _searchBangumiOnly(),
              ),
            ),
            const SizedBox(width: 8),
            KonataPillButton.primary(
              label: _searchingBgm ? '搜索中...' : '搜索',
              compact: MediaQuery.sizeOf(context).width < 520,
              onPressed: _searchingBgm || _binding ? null : _searchBangumiOnly,
            ),
          ],
        ),
        KonataQuickFillRow(
          terms: quickTerms,
          disabled: _searchingBgm || _binding,
          onPick: (term) {
            _bgmQueryController.text = term;
            _bgmQueryController.selection = TextSelection.collapsed(
              offset: term.length,
            );
          },
        ),
        if (_errorText != null) ...[
          const SizedBox(height: 8),
          Text(_errorText!, style: TextStyle(color: p.danger, fontSize: 12)),
        ],
        SizedBox(height: landscapeCompactInput ? 4 : 10),
        Expanded(
          child: _bgmOnlyResults.isEmpty
              ? Center(
                  child: Text(
                    '仅绑定 Bangumi 条目（使用 Bangumi 官方封面、简介与评分）',
                    style: TextStyle(color: p.textMuted, fontSize: 12.5),
                  ),
                )
              : KonataDraggableScrollbar(
                  controller: _bgmScrollCtrl,
                  builder: (_, ctrl) => ListView.separated(
                    controller: ctrl,
                    padding: const EdgeInsets.only(right: 14),
                    itemCount: _bgmOnlyResults.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final item = _bgmOnlyResults[index];
                      final scoreStr = item.score != null && item.score! > 0
                          ? 'Bangumi ${item.score!.toStringAsFixed(1)}'
                          : '暂无评分';
                      return _MatchResultTile(
                        title: item.displayTitle,
                        subtitle:
                            '${item.year ?? '未知年份'} · ${item.platform ?? 'Anime'} · $scoreStr',
                        posterPath: item.posterUrl,
                        imageLoader: imageLoader,
                        disabled: _binding,
                        onSelect: () => _bindBangumiOnly(item),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _MatchResultTile extends StatelessWidget {
  const _MatchResultTile({
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
      padding: const EdgeInsets.all(10),
      enableHover: true,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 42,
              height: 60,
              child: posterPath != null
                  ? ManagedImage(
                      posterPath!,
                      loader: imageLoader,
                      fit: BoxFit.cover,
                    )
                  : Container(color: p.softFill),
            ),
          ),
          const SizedBox(width: 12),
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
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          KonataPillButton.secondary(
            label: '绑定',
            compact: true,
            onPressed: disabled ? null : onSelect,
          ),
        ],
      ),
    );
  }
}
