import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/playback/audio_playback_notifier.dart';
import '../../application/providers/artwork_provider.dart';
import '../../application/providers/work_management_provider.dart';
import '../../domain/models/work.dart';
import '../../domain/sources/artwork_crop_math.dart';
import '../theme/konata_palette.dart';
import '../theme/konata_theme.dart';
import '../widgets/design_system/konata_draggable_scrollbar.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';
import '../widgets/design_system/konata_soft_text_field.dart';
import '../widgets/design_system/konata_toast.dart';
import '../widgets/managed_image.dart';
import 'artwork_crop_dialog.dart';

/// 图像编辑目标类型（竖版海报封面 / 横版大片背景图）。
enum WorkArtworkKind { poster, backdrop }

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
    final initial = widget.kind == WorkArtworkKind.poster
        ? (widget.work.posterPath?.trim().isNotEmpty == true
              ? widget.work.posterPath!.trim()
              : (widget.work.bangumiPosterPath?.trim() ?? ''))
        : (widget.work.backdropPath?.trim() ?? '');
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

  /// 兼容 TMDB 相对路径（`/abc.jpg`）、完整 HTTPS URL 与本地反斜杠路径的等价匹配。
  bool _isSameArtworkPath(String? a, String b) {
    final left = (a ?? '').trim();
    final right = b.trim();
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
        (widget.kind == WorkArtworkKind.poster &&
            (widget.work.bangumiId != null ||
                (widget.work.bangumiPosterPath?.trim().isNotEmpty ?? false)));
    if (!hasRemoteArtwork) {
      return;
    }
    setState(() => _loading = true);
    try {
      final options = await ref
          .read(workManagementProvider)
          .fetchWorkArtworkOptions(widget.work);
      if (mounted) {
        final rawList = widget.kind == WorkArtworkKind.poster
            ? options.posters
            : options.backdrops;
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
    final isPoster = widget.kind == WorkArtworkKind.poster;
    final files = await FilePicker.pickFiles(
      dialogTitle: isPoster ? '选择本地封面海报图片' : '选择本地背景图片',
      type: FileType.image,
    );
    final path = files.firstOrNull?.path;
    if (path == null || path.isEmpty || !mounted) return;

    final actions = ref.read(workManagementProvider);
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
        showKonataToast(context, '裁剪应用失败: $e');
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
      showKonataToast(context, '请先选择候选图片、输入链接或挑选本地文件');
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
          );
      if (mounted) {
        showKonataToast(
          context,
          widget.kind == WorkArtworkKind.poster ? '已更新作品封面海报' : '已更新作品背景原画',
        );
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
        showKonataToast(context, '更新失败: $e');
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
          );
      if (mounted) {
        showKonataToast(context, '已恢复自动抓取默认图像');
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
        showKonataToast(context, '恢复默认失败: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final imageLoader = ref.watch(tmdbImageLoaderProvider);
    final isPoster = widget.kind == WorkArtworkKind.poster;
    final isLocked = isPoster
        ? widget.work.posterLocked
        : widget.work.backdropLocked;
    final canResetToAuto = widget.work.tmdbId != null && isLocked;

    final selectedIndex = _findMatchedCandidateIndex(
      _selectedPath,
      _candidates,
    );
    final currentSavedIndex = _findMatchedCandidateIndex(
      _initialAppliedPath,
      _candidates,
    );

    return KonataGlassDialog(
      width: 680,
      maxHeight: 620,
      title: isPoster ? '编辑作品封面海报' : '编辑作品背景图',
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
                  label: '图片 URL、TMDB 路径或本地路径',
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
          const SizedBox(height: 14),
          Text(
            _buildCandidateHeaderText(isPoster),
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
                ? _buildSinglePreview(p, imageLoader, isPoster)
                : KonataDraggableScrollbar(
                    controller: _gridCtrl,
                    builder: (_, ctrl) => GridView.builder(
                      controller: ctrl,
                      padding: const EdgeInsets.fromLTRB(4, 4, 14, 6),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: isPoster ? 148 : 260,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: isPoster ? 2 / 3 : 16 / 9,
                      ),
                      itemCount: _candidates.length,
                      itemBuilder: (_, index) {
                        final item = _candidates[index];
                        return _ArtworkGridTile(
                          option: item,
                          workId: widget.work.id,
                          isPoster: isPoster,
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

  String _buildCandidateHeaderText(bool isPoster) {
    if (_candidates.isEmpty) {
      if (widget.work.tmdbId == null && widget.work.bangumiId == null) {
        return '尚未绑定条目 ID，可直接填写图片 URL 或挑选本地图片文件';
      }
      return isPoster ? '暂无可用候选封面' : 'TMDB 官方候选背景图 (0)';
    }
    if (!isPoster) {
      return 'TMDB 官方候选背景图 (${_candidates.length})';
    }
    final hasBgm = _candidates.any((e) => e.isBangumi);
    final hasTmdb = _candidates.any((e) => !e.isBangumi);
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
    bool isPoster,
  ) {
    final preview = _selectedPath ?? '';
    if (preview.isEmpty) {
      return Center(
        child: Text('暂无可选候选图片', style: TextStyle(color: p.textMuted)),
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio: isPoster ? 2 / 3 : 16 / 9,
        child: ClipRRect(
          borderRadius: KonataTheme.borderRadiusCard,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ManagedImage(
                preview,
                loader: imageLoader,
                owner: widget.work.id,
                decodeWidth: 780,
                fit: BoxFit.cover,
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
    required this.workId,
    required this.isPoster,
    required this.selected,
    required this.isCurrentSaved,
    required this.imageLoader,
    required this.onTap,
  });

  final WorkArtworkOption option;
  final String workId;
  final bool isPoster;
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
    final staticRes = widget.option.resolutionLabel;
    final asyncDims = staticRes != null
        ? null
        : ref
              .watch(artworkOriginalDimensionsProvider(widget.option.filePath))
              .valueOrNull;
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
          // 使用 foregroundDecoration 将高亮选中边框直接绘制在海报最顶层，杜绝被图像裁剪覆盖
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
                ManagedImage(
                  widget.option.filePath,
                  loader: widget.imageLoader,
                  owner: widget.workId,
                  decodeWidth: widget.isPoster ? 342 : 780,
                  fit: BoxFit.cover,
                ),
                Positioned(
                  top: 6,
                  left: 6,
                  child: _buildSourceBadge(widget.option),
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
                            color: Colors.white,
                          ),
                          const SizedBox(width: 2.5),
                          Text(
                            isCurrentSaved ? '当前' : '已选',
                            style: const TextStyle(
                              color: Colors.white,
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
        textColor: Colors.white,
        fontWeight: FontWeight.w700,
        borderColor: KonataTheme.overlayWhiteStroke,
      );
    }
    if (displayLabel.startsWith('TMDB')) {
      return _OverlayMiniBadge(
        text: displayLabel,
        backgroundColor: KonataTheme.tmdbNavy,
        textColor: Colors.white,
        textGradient: KonataTheme.tmdbBrandGradient,
        fontWeight: FontWeight.w700,
        borderColor: KonataTheme.tmdbCyan.withValues(alpha: 0.28),
      );
    }
    return _OverlayMiniBadge(
      text: displayLabel,
      backgroundColor: KonataTheme.scrimBlackDense,
    );
  }
}

class _AsyncResolutionBadge extends ConsumerWidget {
  const _AsyncResolutionBadge({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dims = ref.watch(artworkOriginalDimensionsProvider(path)).valueOrNull;
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
    this.textColor = Colors.white,
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
        color: textGradient != null ? Colors.white : textColor,
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
