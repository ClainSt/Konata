import 'package:file_picker/file_picker.dart' show FileType, PlatformFile;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/scraping_providers.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/fanart_models.dart';
import '../../domain/models/work.dart';
import '../../domain/sources/artwork_crop_math.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_system_file_picker.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';
import 'artwork_crop_dialog.dart';

/// 图像编辑目标类型（竖版海报封面 / 横版大片背景图 / 透明标题徽标）。
enum WorkArtworkKind { poster, backdrop, logo }

/// 作品封面与背景图选择弹窗（支持 TMDB/Bangumi 候选图集、自定义 URL 与本地图片裁剪）。
class WorkArtworkPickerDialog extends ConsumerStatefulWidget {
  /// 创建图片选择弹窗。
  const WorkArtworkPickerDialog({
    super.key,
    required this.work,
    required this.kind,
  });

  /// 目标作品。
  final Work work;

  /// 修改海报还是背景图。
  final WorkArtworkKind kind;

  @override
  ConsumerState<WorkArtworkPickerDialog> createState() =>
      _WorkArtworkPickerDialogState();
}

class _WorkArtworkPickerDialogState
    extends ConsumerState<WorkArtworkPickerDialog> {
  final ScrollController _gridCtrl = ScrollController();
  late final TextEditingController _customPathCtrl;
  late final String _initialAppliedPath;
  List<WorkArtworkOption> _candidates = const [];
  bool _loading = false;
  bool _saving = false;
  String? _selectedPath;

  @override
  void initState() {
    super.initState();
    final initial = switch (widget.kind) {
      WorkArtworkKind.poster =>
        widget.work.posterPath?.trim().isNotEmpty == true
            ? widget.work.posterPath!.trim()
            : (widget.work.bangumiPosterPath?.trim() ?? ''),
      WorkArtworkKind.backdrop => widget.work.backdropPath?.trim() ?? '',
      WorkArtworkKind.logo => widget.work.logoPath?.trim() ?? '',
    };
    _initialAppliedPath = initial;
    _selectedPath = initial;
    _customPathCtrl = TextEditingController(text: initial);
    _loadArtworkCandidates();
  }

  @override
  void dispose() {
    _gridCtrl.dispose();
    _customPathCtrl.dispose();
    super.dispose();
  }

  /// 兼容 TMDB 相对路径（`/abc.jpg`）、Fanart 预览/原图 URL 与本地反斜杠路径的等价匹配。
  bool _isSameArtworkPath(String? a, String b) {
    final left = FanartUrlHelper.toOriginalUrl((a ?? '').trim());
    final right = FanartUrlHelper.toOriginalUrl(b.trim());
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;

    String normalizeTail(String input) {
      final noQuery = input.split('?').first.replaceAll('\\', '/');
      final idx = noQuery.lastIndexOf('/');
      return idx >= 0 ? noQuery.substring(idx + 1) : noQuery;
    }

    final tailA = normalizeTail(left);
    final tailB = normalizeTail(right);
    // TMDB / Bangumi 哈希文件名具备全局高唯一性，忽略前缀尺寸档位精准配对
    if (tailA.length >= 12 && tailA == tailB) {
      return true;
    }
    return false;
  }

  int _findMatchedCandidateIndex(String? path, List<WorkArtworkOption> list) {
    if (path == null || path.trim().isEmpty) return -1;
    final exactIdx = list.indexWhere((e) => e.filePath.trim() == path.trim());
    if (exactIdx >= 0) return exactIdx;
    return list.indexWhere((e) => _isSameArtworkPath(path, e.filePath));
  }

  Future<void> _loadArtworkCandidates() async {
    final hasRemoteArtwork =
        widget.work.tmdbId != null ||
        widget.work.tvdbId != null ||
        widget.work.bangumiId != null ||
        (widget.kind == WorkArtworkKind.poster &&
            (widget.work.bangumiPosterPath?.trim().isNotEmpty ?? false));
    if (!hasRemoteArtwork) {
      return;
    }
    setState(() => _loading = true);
    try {
      final options = await ref
          .read(workManagementProvider)
          .fetchWorkArtworkOptions(
            widget.work,
            includeLogos: widget.kind == WorkArtworkKind.logo,
          );
      if (mounted) {
        final rawList = switch (widget.kind) {
          WorkArtworkKind.poster => options.posters,
          WorkArtworkKind.backdrop => options.backdrops,
          WorkArtworkKind.logo => options.logos,
        };
        setState(() {
          _candidates = rawList;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickLocalImage() async {
    final isLogo = widget.kind == WorkArtworkKind.logo;
    final isPoster = widget.kind == WorkArtworkKind.poster;
    final List<PlatformFile> files;
    try {
      files = await ref.read(konataSystemFilePickerProvider).pickFiles(
        dialogTitle: isLogo
            ? '选择本地透明标题徽标（PNG / WebP）'
            : (isPoster ? '选择本地封面海报图片' : '选择本地背景图片'),
        type: FileType.image,
        allowMultiple: false,
      );
    } catch (e) {
      if (mounted) {
        showKonataToast(context, '打开本地图片选择器失败：$e', isError: true);
      }
      return;
    }
    final path = files.firstOrNull?.path;
    if (path == null || path.isEmpty || !mounted) return;

    final actions = ref.read(workManagementProvider);
    if (isLogo) {
      setState(() => _saving = true);
      try {
        final savedPath = await actions.saveLocalLogoArtwork(
          work: widget.work,
          sourceFilePath: path,
        );
        if (mounted) {
          _selectedPath = savedPath;
          _customPathCtrl.text = savedPath;
          showKonataToast(context, '已更新作品透明标题徽标');
          PaintingBinding.instance.imageCache.clear();
          Navigator.of(context).pop(true);
        }
      } catch (e) {
        if (mounted) {
          setState(() => _saving = false);
          showKonataToast(context, '保存透明徽标失败: $e', isError: true);
        }
      }
      return;
    }

    final loaded = await actions.loadLocalArtworkForCrop(path);
    try {
      if (!mounted) return;
      final cropRect = await showKonataGlassDialog<ArtworkNormalizedCropRect>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ArtworkCropDialog(source: loaded, isPoster: isPoster),
      );
      if (cropRect == null || !mounted) return;

      setState(() => _saving = true);
      final savedPath = await actions.cropAndSaveLocalArtwork(
        work: widget.work,
        isPoster: isPoster,
        source: loaded,
        cropRect: cropRect,
      );
      if (mounted) {
        _selectedPath = savedPath;
        _customPathCtrl.text = savedPath;
        showKonataToast(context, isPoster ? '已裁剪并更新作品封面海报' : '已裁剪并更新作品背景原画');
        PaintingBinding.instance.imageCache.clear();
        ref
            .read(audioPlaybackProvider.notifier)
            .refreshWorkPosterById(widget.work.id)
            .ignore();
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '裁剪应用失败: $e', isError: true);
      }
    } finally {
      loaded.dispose();
    }
  }

  Future<void> _applySelection() async {
    final target = _customPathCtrl.text.trim().isNotEmpty
        ? _customPathCtrl.text.trim()
        : (_selectedPath ?? '');
    if (target.isEmpty) {
      showKonataToast(context, '请先选择候选图片、输入链接或挑选本地文件', isError: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(workManagementProvider)
          .updateWorkArtwork(
            workId: widget.work.id,
            posterPath: widget.kind == WorkArtworkKind.poster ? target : null,
            backdropPath: widget.kind == WorkArtworkKind.backdrop
                ? target
                : null,
            logoPath: widget.kind == WorkArtworkKind.logo ? target : null,
          );
      if (mounted) {
        final toastMsg = switch (widget.kind) {
          WorkArtworkKind.poster => '已更新作品封面海报',
          WorkArtworkKind.backdrop => '已更新作品背景原画',
          WorkArtworkKind.logo => '已更新作品透明标题徽标',
        };
        showKonataToast(context, toastMsg);
        PaintingBinding.instance.imageCache.clear();
        if (widget.kind == WorkArtworkKind.poster) {
          ref
              .read(audioPlaybackProvider.notifier)
              .refreshWorkPosterById(widget.work.id)
              .ignore();
        }
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '更新失败: $e', isError: true);
      }
    }
  }

  Future<void> _resetToAuto() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(workManagementProvider)
          .resetArtworkLockToAuto(
            workId: widget.work.id,
            resetPoster: widget.kind == WorkArtworkKind.poster,
            resetBackdrop: widget.kind == WorkArtworkKind.backdrop,
            resetLogo: widget.kind == WorkArtworkKind.logo,
          );
      if (mounted) {
        showKonataToast(context, '已恢复自动抓取默认图像');
        PaintingBinding.instance.imageCache.clear();
        if (widget.kind == WorkArtworkKind.poster) {
          ref
              .read(audioPlaybackProvider.notifier)
              .refreshWorkPosterById(widget.work.id)
              .ignore();
        }
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '恢复默认失败: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final relayHealth = ref.watch(fanartRelayHealthProvider);
    final isPoster = widget.kind == WorkArtworkKind.poster;
    final isLogo = widget.kind == WorkArtworkKind.logo;
    final isLocked = switch (widget.kind) {
      WorkArtworkKind.poster => widget.work.posterLocked,
      WorkArtworkKind.backdrop => widget.work.backdropLocked,
      WorkArtworkKind.logo => widget.work.logoLocked,
    };
    final canResetToAuto =
        (widget.work.tmdbId != null ||
            widget.work.bangumiId != null ||
            widget.work.tvdbId != null) &&
        isLocked;

    final selectedIndex = _findMatchedCandidateIndex(
      _selectedPath,
      _candidates,
    );
    final currentSavedIndex = _findMatchedCandidateIndex(
      _initialAppliedPath,
      _candidates,
    );

    final dialogTitle = switch (widget.kind) {
      WorkArtworkKind.poster => '编辑作品封面海报',
      WorkArtworkKind.backdrop => '编辑作品背景图',
      WorkArtworkKind.logo => '编辑作品标题徽标',
    };

    return KonataGlassDialog(
      width: 680,
      maxHeight: 620,
      title: dialogTitle,
      onClose: _saving ? null : () => Navigator.of(context).pop(false),
      actions: [
        if (canResetToAuto)
          KonataPillButton.ghost(
            label: '恢复自动抓取默认',
            compact: true,
            onPressed: _saving ? null : _resetToAuto,
          ),
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        KonataPillButton.primary(
          label: _saving ? '应用中...' : '应用选中图片',
          compact: true,
          onPressed: _saving ? null : _applySelection,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: KonataSoftTextField(
                  controller: _customPathCtrl,
                  label: isLogo
                      ? '透明徽标 URL、TMDB 路径或本地 PNG/WebP 路径'
                      : '图片 URL、TMDB 路径或本地路径',
                  hintText: 'https://... 或本地图片路径',
                  onChanged: (v) => setState(() => _selectedPath = v.trim()),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: KonataPillButton.secondary(
                  label: '本地...',
                  icon: Icons.folder_open_rounded,
                  compact: true,
                  onPressed: _pickLocalImage,
                ),
              ),
            ],
          ),
          if (relayHealth.isDegraded && relayHealth.message != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: p.warning.withValues(alpha: 0.14),
                borderRadius: KonataTheme.borderRadiusSm,
                border: Border.all(
                  color: p.warning.withValues(alpha: 0.35),
                  width: 0.9,
                ),
              ),
              child: Text(
                relayHealth.message!,
                style: TextStyle(
                  color: p.warning,
                  fontSize: KonataTheme.fontSizeCaption,
                  height: 1.4,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            _buildCandidateHeaderText(),
            style: TextStyle(
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeBodyXs,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _candidates.isEmpty
                ? _buildSinglePreview(p, imageLoader)
                : KonataDraggableScrollbar(
                    controller: _gridCtrl,
                    builder: (_, ctrl) => GridView.builder(
                      controller: ctrl,
                      padding: const EdgeInsets.fromLTRB(4, 4, 14, 6),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: isPoster
                            ? 148
                            : (isLogo ? 280 : 260),
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: isPoster
                            ? 2 / 3
                            : (isLogo ? 16 / 7 : 16 / 9),
                      ),
                      itemCount: _candidates.length,
                      itemBuilder: (_, index) {
                        final item = _candidates[index];
                        return _ArtworkGridTile(
                          option: item,
                          kind: widget.kind,
                          selected: index == selectedIndex,
                          isCurrentSaved: index == currentSavedIndex,
                          imageLoader: imageLoader,
                          onTap: () {
                            setState(() {
                              _selectedPath = item.filePath;
                              _customPathCtrl.text = item.filePath;
                            });
                          },
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _buildCandidateHeaderText() {
    if (_candidates.isEmpty) {
      if (widget.work.tmdbId == null &&
          widget.work.bangumiId == null &&
          widget.work.tvdbId == null) {
        return '尚未绑定条目 ID，可直接填写图片 URL 或挑选本地图片文件';
      }
      return switch (widget.kind) {
        WorkArtworkKind.poster => '暂无可用候选封面',
        WorkArtworkKind.backdrop => 'TMDB / Fanart.tv 候选背景图 (0)',
        WorkArtworkKind.logo => '暂无可用在线透明标题徽标（详情页将自动使用风格化文字兜底）',
      };
    }
    if (widget.kind == WorkArtworkKind.logo) {
      final hasTmdb = _candidates.any((e) => !e.isFanart);
      final hasFanart = _candidates.any((e) => e.isFanart);
      if (hasTmdb && hasFanart) {
        return 'TMDB / Fanart.tv 透明标题徽标候选 (${_candidates.length})';
      }
      if (hasFanart) {
        return 'Fanart.tv 透明标题徽标候选 (${_candidates.length})';
      }
      return 'TMDB 透明标题徽标候选 (${_candidates.length})';
    }
    if (widget.kind == WorkArtworkKind.backdrop) {
      final hasTmdb = _candidates.any((e) => !e.isFanart);
      final hasFanart = _candidates.any((e) => e.isFanart);
      if (hasTmdb && hasFanart) {
        return 'TMDB / Fanart.tv 候选背景图 (${_candidates.length})';
      }
      if (hasFanart) {
        return 'Fanart.tv 候选背景图 (${_candidates.length})';
      }
      return 'TMDB / Fanart.tv 候选背景图 (${_candidates.length})';
    }
    final hasBgm = _candidates.any((e) => e.isBangumi);
    final hasFanart = _candidates.any((e) => e.isFanart);
    final hasTmdb = _candidates.any((e) => !e.isBangumi && !e.isFanart);
    if (hasFanart) {
      final sources = <String>[
        if (hasBgm) 'Bangumi',
        if (hasTmdb) 'TMDB',
        'Fanart.tv',
      ];
      return '${sources.join(' / ')} 候选封面 (${_candidates.length})';
    }
    if (hasBgm && hasTmdb) {
      return 'Bangumi / TMDB 官方候选封面 (${_candidates.length})';
    }
    if (hasBgm) {
      return 'Bangumi 官方候选封面 (${_candidates.length})';
    }
    return 'TMDB 官方候选图集 (${_candidates.length})';
  }

  Widget _buildSinglePreview(
    KonataPalette p,
    ManagedImageLoader imageLoader,
  ) {
    final preview = _selectedPath ?? '';
    if (preview.isEmpty) {
      return Center(
        child: Text('暂无可选候选图片', style: TextStyle(color: p.textMuted)),
      );
    }
    final isPoster = widget.kind == WorkArtworkKind.poster;
    final isLogo = widget.kind == WorkArtworkKind.logo;
    return Center(
      child: AspectRatio(
        aspectRatio: isPoster ? 2 / 3 : (isLogo ? 16 / 7 : 16 / 9),
        child: ClipRRect(
          borderRadius: KonataTheme.borderRadiusCard,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (isLogo) const _DarkLogoCheckerBackground(),
              Padding(
                padding: isLogo ? const EdgeInsets.all(16) : EdgeInsets.zero,
                child: ManagedImage(
                  preview,
                  loader: imageLoader,
                  owner: widget.work.id,
                  artwork: isLogo
                      ? ManagedArtwork.logo
                      : (isPoster
                            ? ManagedArtwork.poster
                            : ManagedArtwork.backdrop),
                  decodeWidth: isLogo ? 1200 : 780,
                  fit: isLogo ? BoxFit.contain : BoxFit.cover,
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [_AsyncResolutionBadge(path: preview)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtworkGridTile extends ConsumerStatefulWidget {
  const _ArtworkGridTile({
    required this.option,
    required this.kind,
    required this.selected,
    required this.isCurrentSaved,
    required this.imageLoader,
    required this.onTap,
  });

  final WorkArtworkOption option;
  final WorkArtworkKind kind;
  final bool selected;
  final bool isCurrentSaved;
  final ManagedImageLoader imageLoader;
  final VoidCallback onTap;

  @override
  ConsumerState<_ArtworkGridTile> createState() => _ArtworkGridTileState();
}

class _ArtworkGridTileState extends ConsumerState<_ArtworkGridTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isPoster = widget.kind == WorkArtworkKind.poster;
    final isLogo = widget.kind == WorkArtworkKind.logo;
    final staticRes = widget.option.resolutionLabel;
    final asyncDims = staticRes != null
        ? null
        : ref
              .watch(artworkOriginalDimensionsProvider(widget.option.filePath))
              .value;
    final resolutionText =
        staticRes ??
        (asyncDims != null && asyncDims.$1 > 0 && asyncDims.$2 > 0
            ? '${asyncDims.$1}×${asyncDims.$2}'
            : null);

    final selected = widget.selected;
    final isCurrentSaved = widget.isCurrentSaved;
    final borderColor = selected
        ? p.accent
        : (_hovered
              ? p.accent.withValues(alpha: 0.55)
              : KonataTheme.darkInkBorder(p));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionFast,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: KonataTheme.borderRadiusCard,
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: p.accent.withValues(alpha: 0.42),
                      blurRadius: 12,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
          // 使用 foregroundDecoration 将高亮选中边框直接绘制在图像最顶层，杜绝被图像裁剪覆盖
          foregroundDecoration: BoxDecoration(
            borderRadius: KonataTheme.borderRadiusCard,
            border: Border.all(
              color: borderColor,
              width: selected ? 3.5 : (_hovered ? 1.8 : 1.0),
            ),
          ),
          child: ClipRRect(
            borderRadius: KonataTheme.borderRadiusCard,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (isLogo) const _DarkLogoCheckerBackground(),
                Padding(
                  padding: isLogo
                      ? const EdgeInsets.fromLTRB(12, 24, 12, 22)
                      : EdgeInsets.zero,
                  child: ManagedImage(
                    widget.option.previewPath ?? widget.option.filePath,
                    loader: widget.imageLoader,
                    owner: null,
                    artwork: isLogo
                        ? ManagedArtwork.logo
                        : (isPoster
                              ? ManagedArtwork.poster
                              : ManagedArtwork.backdrop),
                    decodeWidth: isLogo ? 1200 : (isPoster ? 342 : 780),
                    fit: isLogo ? BoxFit.contain : BoxFit.cover,
                  ),
                ),
                Positioned(
                  top: 6,
                  left: 6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildSourceBadge(widget.option),
                      if (widget.option.langTag != null &&
                          widget.option.langTag!.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        _OverlayMiniBadge(
                          text: widget.option.langTag!,
                          backgroundColor: KonataTheme.scrimBlackDeep,
                        ),
                      ],
                    ],
                  ),
                ),
                if (selected)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: p.accent,
                        borderRadius: KonataTheme.borderRadiusPill,
                        border: Border.all(
                          color: KonataTheme.overlayWhiteTextMid,
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: KonataTheme.scrimBlackSubtle,
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.check_rounded,
                            size: 12,
                            color: KonataTheme.pureWhite,
                          ),
                          const SizedBox(width: 2.5),
                          Text(
                            isCurrentSaved ? '当前' : '已选',
                            style: const TextStyle(
                              color: KonataTheme.pureWhite,
                              fontSize: KonataTheme.fontSizeBadge,
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (isCurrentSaved)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _OverlayMiniBadge(
                      text: '当前',
                      backgroundColor: KonataTheme.scrimBlackDeep,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (resolutionText != null)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: _OverlayMiniBadge.resolution(resolutionText),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _compactSourceLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed == 'TMDB 第0季' ||
        RegExp(r'^TMDB\s*第\s*0\s*季$').hasMatch(trimmed)) {
      return 'TMDB·SP';
    }
    final seasonMatch = RegExp(r'^TMDB\s*第\s*(\d+)\s*季$').firstMatch(trimmed);
    if (seasonMatch != null) {
      return 'TMDB·S${seasonMatch.group(1)}';
    }
    return trimmed;
  }

  Widget _buildSourceBadge(WorkArtworkOption option) {
    final displayLabel = _compactSourceLabel(option.sourceLabel);
    final isBangumi = option.isBangumi || displayLabel.startsWith('Bangumi');
    if (isBangumi) {
      return _OverlayMiniBadge(
        text: displayLabel,
        backgroundColor: KonataTheme.bangumiPink,
        textColor: KonataTheme.pureWhite,
        fontWeight: FontWeight.w700,
        borderColor: KonataTheme.overlayWhiteStroke,
      );
    }
    if (displayLabel.startsWith('TMDB')) {
      return _OverlayMiniBadge(
        text: displayLabel,
        backgroundColor: KonataTheme.tmdbNavy,
        textColor: KonataTheme.pureWhite,
        textGradient: KonataTheme.tmdbBrandGradient,
        fontWeight: FontWeight.w700,
        borderColor: KonataTheme.tmdbCyan.withValues(alpha: 0.28),
      );
    }
    if (option.isFanart || displayLabel.startsWith('Fanart')) {
      return _OverlayMiniBadge(
        text: displayLabel,
        backgroundColor: KonataTheme.specReleaseBlue.withValues(alpha: 0.24),
        textColor: KonataTheme.pureWhite,
        fontWeight: FontWeight.w700,
        borderColor: KonataTheme.specReleaseBlue.withValues(alpha: 0.55),
      );
    }
    return _OverlayMiniBadge(
      text: displayLabel,
      backgroundColor: KonataTheme.scrimBlackDense,
    );
  }
}

class _DarkLogoCheckerBackground extends StatelessWidget {
  const _DarkLogoCheckerBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _DarkLogoCheckerPainter());
  }
}

class _DarkLogoCheckerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 12.0;
    final paintA = Paint()..color = KonataTheme.logoCheckerDarkCellA;
    final paintB = Paint()..color = KonataTheme.logoCheckerDarkCellB;
    canvas.drawRect(Offset.zero & size, paintA);
    for (double y = 0; y < size.height; y += cell) {
      final rowEven = ((y / cell).floor() % 2) == 0;
      for (double x = rowEven ? cell : 0; x < size.width; x += cell * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), paintB);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AsyncResolutionBadge extends ConsumerWidget {
  const _AsyncResolutionBadge({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dims = ref.watch(artworkOriginalDimensionsProvider(path)).value;
    if (dims == null || dims.$1 <= 0 || dims.$2 <= 0) {
      return const SizedBox.shrink();
    }
    return _OverlayMiniBadge.resolution('${dims.$1}×${dims.$2}');
  }
}

class _OverlayMiniBadge extends StatelessWidget {
  const _OverlayMiniBadge({
    required this.text,
    required this.backgroundColor,
    this.textColor = KonataTheme.pureWhite,
    this.textGradient,
    this.borderColor,
    this.fontWeight = FontWeight.w600,
    this.tabularFigures = false,
    this.shadows,
  });

  factory _OverlayMiniBadge.resolution(String text) => _OverlayMiniBadge(
    text: text,
    backgroundColor: KonataTheme.overlayWhiteTextStrong,
    textColor: KonataTheme.resolutionBadgeTextDark,
    borderColor: KonataTheme.scrimBlackHairline,
    fontWeight: FontWeight.w700,
    tabularFigures: true,
    shadows: [
      BoxShadow(
        color: KonataTheme.scrimBlackSoft,
        blurRadius: 6,
        offset: const Offset(0, 2),
      ),
    ],
  );

  final String text;
  final Color backgroundColor;
  final Color textColor;
  final Gradient? textGradient;
  final Color? borderColor;
  final FontWeight fontWeight;
  final bool tabularFigures;
  final List<BoxShadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final textWidget = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: textGradient != null ? KonataTheme.pureWhite : textColor,
        fontSize: KonataTheme.fontSizeMicro,
        fontWeight: fontWeight,
        fontFeatures: tabularFigures
            ? const [FontFeature.tabularFigures()]
            : null,
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 2.5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: KonataTheme.borderRadiusChip,
        border: Border.all(
          color: borderColor ?? KonataTheme.overlayWhiteBorderStrong,
          width: 0.8,
        ),
        boxShadow: shadows,
      ),
      child: textGradient == null
          ? textWidget
          : ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) => textGradient!.createShader(bounds),
              child: textWidget,
            ),
    );
  }
}
