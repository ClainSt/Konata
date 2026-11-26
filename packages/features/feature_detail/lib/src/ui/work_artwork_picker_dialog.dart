import 'dart:async';
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/work_artwork_options.dart';
import '../state/work_detail_controller.dart';
import 'artwork_crop_dialog.dart';
import 'detail_artwork_view.dart';
import 'video_frame_candidates_grid.dart';

/// 作品艺术图编辑目标类型。
enum WorkArtworkKind {
  /// 竖版海报封面（`2:3`）。
  poster,

  /// 横版背景原画（`16:9`）。
  backdrop,

  /// 竖版无字原画（`2:3` / 竖屏沉浸顶栏背景）。
  portraitBackdrop,

  /// 透明标题徽标（ClearLogo）。
  logo,
}

enum _ClearLogoGalleryOrientation {
  landscape(15 / 8, 200),
  portrait(4 / 5, 152),
  compact(4 / 3, 176);

  const _ClearLogoGalleryOrientation(
    this.tileAspectRatio,
    this.maxCrossAxisExtent,
  );

  final double tileAspectRatio;
  final double maxCrossAxisExtent;
}

/// 编辑作品封面、背景原画与透明标题徽标的多源挑选与裁切弹窗。
class WorkArtworkPickerDialog extends StatefulWidget {
  /// 创建作品艺术图选择器弹窗。
  const WorkArtworkPickerDialog({
    super.key,
    required this.controller,
    required this.work,
    required this.imageLoader,
    required this.kind,
  });

  /// 详情页状态控制器。
  final WorkDetailController controller;

  /// 目标作品实体。
  final Work work;

  /// 受管图片加载器。
  final ManagedImageLoader imageLoader;

  /// 当前编辑的图片槽位类型。
  final WorkArtworkKind kind;

  @override
  State<WorkArtworkPickerDialog> createState() =>
      _WorkArtworkPickerDialogState();
}

class _WorkArtworkPickerDialogState extends State<WorkArtworkPickerDialog> {
  final TextEditingController _customPathCtrl = TextEditingController();
  final ScrollController _gridCtrl = ScrollController();

  List<WorkArtworkOption> _candidates = const <WorkArtworkOption>[];
  List<VideoFrameSample> _extractedFrames = const <VideoFrameSample>[];
  String? _selectedPath;
  int? _selectedVideoFrameIndex;
  String? _initialAppliedPath;
  bool _loading = true;
  bool _saving = false;
  bool _extractingFrames = false;
  int _extractBatchCount = 0;
  int _singlePreviewRetryEpoch = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _initialAppliedPath = switch (widget.kind) {
      WorkArtworkKind.poster => widget.work.posterPath?.trim(),
      WorkArtworkKind.backdrop => widget.work.backdropPath?.trim(),
      WorkArtworkKind.portraitBackdrop =>
        widget.work.portraitBackdropPath?.trim(),
      WorkArtworkKind.logo => widget.work.logoPath?.trim(),
    };
    _selectedPath = _initialAppliedPath;
    if (_initialAppliedPath != null && _initialAppliedPath!.isNotEmpty) {
      _customPathCtrl.text = _initialAppliedPath!;
    }
    unawaited(_loadCandidates());
  }

  @override
  void dispose() {
    _disposed = true;
    _customPathCtrl.dispose();
    _gridCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCandidates() async {
    try {
      final options = await widget.controller.fetchArtworkOptions(
        includeLogos: widget.kind == WorkArtworkKind.logo,
      );
      if (!mounted) return;
      final list = switch (widget.kind) {
        WorkArtworkKind.poster => options.posters,
        WorkArtworkKind.backdrop => options.backdrops,
        WorkArtworkKind.portraitBackdrop => options.portraitBackdrops,
        WorkArtworkKind.logo => options.logos,
      };
      setState(() {
        _candidates = list;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showKonataToast(context, '加载候选图片列表失败：$error', isError: true);
    }
  }

  Future<void> _pickLocalImage() async {
    if (_saving) return;
    final dialogTitle = switch (widget.kind) {
      WorkArtworkKind.poster => '选择本地封面海报图片',
      WorkArtworkKind.backdrop => '选择本地背景原画图片',
      WorkArtworkKind.portraitBackdrop => '选择本地竖版无字原画图片',
      WorkArtworkKind.logo => '选择本地透明标题徽标 (PNG/WebP)',
    };
    final picked = await widget.controller.pickLocalImageFile(
      dialogTitle: dialogTitle,
    );
    if (!mounted || picked == null || picked.trim().isEmpty) return;
    final sourcePath = picked.trim();

    if (widget.kind == WorkArtworkKind.logo) {
      setState(() => _saving = true);
      try {
        await widget.controller.saveLocalLogoArtwork(sourcePath);
        if (mounted) {
          PaintingBinding.instance.imageCache.clear();
          Navigator.of(context).pop(true);
        }
      } catch (error) {
        if (mounted) {
          setState(() => _saving = false);
          showKonataToast(context, '导入本地标题徽标失败：$error', isError: true);
        }
      }
      return;
    }

    try {
      final loaded = await widget.controller.loadLocalArtworkForCrop(
        sourcePath,
      );
      if (!mounted) {
        loaded.dispose();
        return;
      }
      var savedFromCrop = false;
      try {
        savedFromCrop =
            await showKonataGlassDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => ArtworkCropDialog(
                source: loaded,
                isPoster:
                    widget.kind == WorkArtworkKind.poster ||
                    widget.kind == WorkArtworkKind.portraitBackdrop,
                onSaveCrop: (rect) async {
                  await widget.controller.cropAndSaveLocalArtwork(
                    isPoster: widget.kind == WorkArtworkKind.poster,
                    isPortraitBackdrop:
                        widget.kind == WorkArtworkKind.portraitBackdrop,
                    source: loaded,
                    cropRect: rect,
                  );
                },
              ),
            ) ??
            false;
      } finally {
        loaded.dispose();
      }
      if (savedFromCrop && mounted) {
        PaintingBinding.instance.imageCache.clear();
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        showKonataToast(context, '读取本地图片失败：$error', isError: true);
      }
    }
  }

  Future<void> _extractMainVideoFrames() async {
    if (_extractingFrames || _saving) return;
    final batch = _extractBatchCount;
    setState(() {
      _extractingFrames = true;
      _extractBatchCount++;
    });
    try {
      final offset = (batch * 0.13) % 1.0;
      final frames = await widget.controller.extractBackdropFrameCandidates(
        sampleCount: 8,
        phaseOffset: offset,
        isCancelled: () => _disposed || !mounted,
      );
      if (!mounted) return;
      if (frames.isEmpty) {
        setState(() => _extractingFrames = false);
        showKonataToast(context, '未在正片文件中提取到可用的视频帧', isError: true);
        return;
      }
      setState(() {
        _extractedFrames = frames;
        _selectedVideoFrameIndex = 0;
        _selectedPath = null;
        _customPathCtrl.clear();
        _extractingFrames = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _extractingFrames = false);
      showKonataToast(context, '正片视频抽帧失败：$error', isError: true);
    }
  }

  Future<void> _applySelection() async {
    if (_saving) return;
    final frameIdx = _selectedVideoFrameIndex;
    if (frameIdx != null &&
        frameIdx >= 0 &&
        frameIdx < _extractedFrames.length) {
      setState(() => _saving = true);
      try {
        await widget.controller.applyExtractedBackdropFrame(
          _extractedFrames[frameIdx].imageBytes,
        );
        if (mounted) {
          PaintingBinding.instance.imageCache.clear();
          Navigator.of(context).pop(true);
        }
      } catch (error) {
        if (mounted) {
          setState(() => _saving = false);
          showKonataToast(context, '保存视频抽帧失败：$error', isError: true);
        }
      }
      return;
    }

    final raw = (_selectedPath ?? _customPathCtrl.text).trim();
    if (raw.isEmpty) {
      showKonataToast(context, '请先选择候选图片或输入图片路径', isError: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await switch (widget.kind) {
        WorkArtworkKind.poster => widget.controller.updateWorkArtwork(
          posterPath: raw,
        ),
        WorkArtworkKind.backdrop => widget.controller.updateWorkArtwork(
          backdropPath: raw,
        ),
        WorkArtworkKind.portraitBackdrop => widget.controller.updateWorkArtwork(
          portraitBackdropPath: raw,
        ),
        WorkArtworkKind.logo => widget.controller.updateWorkArtwork(
          logoPath: raw,
        ),
      };
      if (mounted) {
        PaintingBinding.instance.imageCache.clear();
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '应用选中图片失败：$error', isError: true);
      }
    }
  }

  Future<void> _resetToAuto() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.controller.resetArtworkLockToAuto(
        resetPoster: widget.kind == WorkArtworkKind.poster,
        resetBackdrop: widget.kind == WorkArtworkKind.backdrop,
        resetPortraitBackdrop: widget.kind == WorkArtworkKind.portraitBackdrop,
        resetLogo: widget.kind == WorkArtworkKind.logo,
      );
      if (mounted) {
        PaintingBinding.instance.imageCache.clear();
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '恢复自动默认失败：$error', isError: true);
      }
    }
  }

  int _findMatchedCandidateIndex(
    String? path,
    List<WorkArtworkOption> candidates,
  ) {
    final target = path?.trim();
    if (target == null || target.isEmpty) return -1;
    for (var i = 0; i < candidates.length; i++) {
      final opt = candidates[i];
      if (opt.filePath.trim() == target || opt.previewPath?.trim() == target) {
        return i;
      }
    }
    return -1;
  }

  _ClearLogoGalleryOrientation _resolveLogoOrientation() {
    var landscape = 0;
    var portrait = 0;
    for (final c in _candidates) {
      final w = c.width ?? 0;
      final h = c.height ?? 0;
      if (w <= 0 || h <= 0) continue;
      final ratio = w / h;
      if (ratio >= 1.25) {
        landscape++;
      } else if (ratio < 0.85) {
        portrait++;
      }
    }
    if (portrait > landscape) return _ClearLogoGalleryOrientation.portrait;
    return landscape > 0
        ? _ClearLogoGalleryOrientation.landscape
        : _ClearLogoGalleryOrientation.compact;
  }

  String _buildCandidateHeaderText() {
    final hasBgm = _candidates.any((e) => e.isBangumi);
    final hasFanart = _candidates.any((e) => e.isFanart);
    final hasTmdb = _candidates.any((e) => !e.isBangumi && !e.isFanart);
    if (hasFanart) {
      final sources = <String>[
        if (hasBgm) 'Bangumi',
        if (hasTmdb) 'TMDB',
        'Fanart.tv',
      ];
      return '${sources.join(' / ')} 候选图片 (${_candidates.length})';
    }
    if (hasBgm && hasTmdb) {
      return 'Bangumi / TMDB 官方候选图片 (${_candidates.length})';
    }
    if (hasBgm) {
      return 'Bangumi 官方候选图片 (${_candidates.length})';
    }
    return 'TMDB 官方候选图集 (${_candidates.length})';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final isPoster =
        widget.kind == WorkArtworkKind.poster ||
        widget.kind == WorkArtworkKind.portraitBackdrop;
    final isLogo = widget.kind == WorkArtworkKind.logo;
    final isLocked = switch (widget.kind) {
      WorkArtworkKind.poster => widget.work.posterLocked,
      WorkArtworkKind.backdrop => widget.work.backdropLocked,
      WorkArtworkKind.portraitBackdrop => widget.work.portraitBackdropLocked,
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
    final logoOrientation = isLogo
        ? _resolveLogoOrientation()
        : _ClearLogoGalleryOrientation.landscape;
    final relayHealth = widget.controller.fanartRelayHealth;
    final dialogTitle = switch (widget.kind) {
      WorkArtworkKind.poster => '编辑作品封面海报',
      WorkArtworkKind.backdrop => '编辑作品背景原画',
      WorkArtworkKind.portraitBackdrop => '编辑竖版无字原画',
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
          LayoutBuilder(
            builder: (context, constraints) {
              final hasFrameAction = widget.kind == WorkArtworkKind.backdrop;
              final narrow =
                  constraints.maxWidth < (hasFrameAction ? 480 : 320);
              final pathField = KonataSoftTextField(
                controller: _customPathCtrl,
                label: isLogo
                    ? '透明徽标 URL、TMDB 路径或本地 PNG/WebP 路径'
                    : '图片 URL、TMDB 路径或本地路径',
                hintText: 'https://... 或本地图片路径',
                onChanged: (value) => setState(() {
                  _selectedVideoFrameIndex = null;
                  _selectedPath = value.trim();
                }),
              );
              final buttons = Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  KonataPillButton.secondary(
                    key: const ValueKey('artwork_picker_local_image_btn'),
                    label: '本地图片',
                    icon: Icons.folder_open_rounded,
                    compact: true,
                    onPressed: _saving ? null : _pickLocalImage,
                  ),
                  if (hasFrameAction)
                    KonataPillButton.secondary(
                      key: const ValueKey(
                        'artwork_picker_extract_video_frames_btn',
                      ),
                      label: _extractingFrames
                          ? '抽帧中...'
                          : (_extractedFrames.isEmpty ? '视频抽帧' : '换一批'),
                      icon: _extractedFrames.isEmpty
                          ? Icons.movie_filter_rounded
                          : Icons.refresh_rounded,
                      compact: true,
                      onPressed: (_saving || _extractingFrames)
                          ? null
                          : _extractMainVideoFrames,
                    ),
                ],
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    pathField,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: buttons),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: pathField),
                  const SizedBox(width: 8),
                  buttons,
                ],
              );
            },
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
                style: KonataTheme.captionStyle(
                  p,
                ).copyWith(color: p.warning, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            _extractedFrames.isNotEmpty
                ? '正片视频抽帧候选 (${_extractedFrames.length})'
                : _buildCandidateHeaderText(),
            style: KonataTheme.bodyLabelStyle(
              p,
              color: p.textSecondary,
              fontSize: KonataTheme.fontSizeBodyXs,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _buildGalleryBody(
              p: p,
              isPoster: isPoster,
              isLogo: isLogo,
              logoOrientation: logoOrientation,
              selectedIndex: selectedIndex,
              currentSavedIndex: currentSavedIndex,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGalleryBody({
    required KonataPalette p,
    required bool isPoster,
    required bool isLogo,
    required _ClearLogoGalleryOrientation logoOrientation,
    required int selectedIndex,
    required int currentSavedIndex,
  }) {
    if (_loading ||
        (_extractingFrames &&
            _extractedFrames.isEmpty &&
            _candidates.isEmpty)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (_extractingFrames) ...[
              const SizedBox(height: 12),
              Text(
                '正在从正片视频抽取候选画面（严格跳过特典）...',
                style: KonataTheme.bodyLabelStyle(
                  p,
                  color: p.textSecondary,
                  fontSize: KonataTheme.fontSizeBodyXs,
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (_extractedFrames.isEmpty && _candidates.isEmpty) {
      return _buildSinglePreview(p, isPoster: isPoster, isLogo: isLogo);
    }

    final gridDelegate = isPoster
        ? const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 152,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2 / 3,
          )
        : SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: isLogo
                ? logoOrientation.maxCrossAxisExtent
                : 260,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: isLogo ? logoOrientation.tileAspectRatio : 16 / 9,
          );

    return KonataDraggableScrollbar(
      controller: _gridCtrl,
      builder: (_, ctrl) => CustomScrollView(
        controller: ctrl,
        slivers: [
          if (_extractedFrames.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 260,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 16 / 9,
                ),
                delegate: SliverChildBuilderDelegate((_, index) {
                  return VideoFrameCandidateTile(
                    key: ValueKey('video_frame_candidate_$index'),
                    sample: _extractedFrames[index],
                    selected: _selectedVideoFrameIndex == index,
                    onTap: () => setState(() {
                      _selectedVideoFrameIndex = index;
                      _selectedPath = null;
                      _customPathCtrl.clear();
                    }),
                  );
                }, childCount: _extractedFrames.length),
              ),
            ),
          if (_candidates.isNotEmpty) ...[
            if (_extractedFrames.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
                  child: Text(
                    _buildCandidateHeaderText(),
                    style: KonataTheme.bodyLabelStyle(
                      p,
                      color: p.textSecondary,
                      fontSize: KonataTheme.fontSizeBodyXs,
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
              sliver: SliverGrid(
                gridDelegate: gridDelegate,
                delegate: SliverChildBuilderDelegate((_, index) {
                  final item = _candidates[index];
                  return _ArtworkGridTile(
                    option: item,
                    kind: widget.kind,
                    workId: widget.work.id,
                    imageLoader: widget.imageLoader,
                    selected:
                        _selectedVideoFrameIndex == null &&
                        index == selectedIndex,
                    isCurrentSaved: index == currentSavedIndex,
                    onTap: () => setState(() {
                      _selectedVideoFrameIndex = null;
                      _selectedPath = item.filePath;
                      _customPathCtrl.text = item.filePath;
                    }),
                  );
                }, childCount: _candidates.length),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSinglePreview(
    KonataPalette p, {
    required bool isPoster,
    required bool isLogo,
  }) {
    final preview = _selectedPath ?? '';
    if (preview.isEmpty) {
      return Center(
        child: Text(
          widget.kind == WorkArtworkKind.backdrop
              ? '暂无在线候选背景图，可点击右上「视频抽帧」从正片取帧或挑选本地图片'
              : '暂无可选候选图片',
          textAlign: TextAlign.center,
          style: KonataTheme.bodyLabelStyle(p, color: p.textMuted),
        ),
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
              if (isLogo) const DarkLogoCheckerBackground(),
              Padding(
                padding: isLogo ? const EdgeInsets.all(16) : EdgeInsets.zero,
                child: DetailManagedImage(
                  preview,
                  key: ValueKey(
                    'single_preview_${preview}_$_singlePreviewRetryEpoch',
                  ),
                  loader: widget.imageLoader,
                  owner: widget.work.id,
                  artwork: isLogo
                      ? ManagedArtwork.logo
                      : (isPoster
                            ? ManagedArtwork.poster
                            : ManagedArtwork.backdrop),
                  decodeWidth: isLogo ? 1200 : 780,
                  fit: isLogo ? BoxFit.contain : BoxFit.cover,
                  errorBuilder: (_, _, _) => ArtworkErrorFallback(
                    compact: false,
                    onRetry: () {
                      PaintingBinding.instance.imageCache.clear();
                      setState(() => _singlePreviewRetryEpoch++);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtworkGridTile extends StatefulWidget {
  const _ArtworkGridTile({
    required this.option,
    required this.kind,
    required this.workId,
    required this.imageLoader,
    required this.selected,
    required this.isCurrentSaved,
    required this.onTap,
  });

  final WorkArtworkOption option;
  final WorkArtworkKind kind;
  final String workId;
  final ManagedImageLoader imageLoader;
  final bool selected;
  final bool isCurrentSaved;
  final VoidCallback onTap;

  @override
  State<_ArtworkGridTile> createState() => _ArtworkGridTileState();
}

class _ArtworkGridTileState extends State<_ArtworkGridTile> {
  bool _hovered = false;
  int _retryEpoch = 0;
  Size? _resolvedSize;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final option = widget.option;
    final selected = widget.selected;
    final isLogo = widget.kind == WorkArtworkKind.logo;
    final isPoster =
        widget.kind == WorkArtworkKind.poster ||
        widget.kind == WorkArtworkKind.portraitBackdrop;
    final previewUrl = option.previewPath?.trim().isNotEmpty == true
        ? option.previewPath!.trim()
        : option.filePath;
    final resolutionText =
        option.resolutionLabel ??
        (_resolvedSize != null
            ? '${_resolvedSize!.width.round()}×${_resolvedSize!.height.round()}'
            : null);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: KonataTheme.motionFast,
          decoration: BoxDecoration(
            borderRadius: KonataTheme.borderRadiusControl,
            color: p.softFill,
            border: Border.all(
              color: selected
                  ? p.accent
                  : (_hovered ? p.hoverBorder : p.posterBorder),
              width: selected ? 2.2 : 1.0,
            ),
          ),
          child: ClipRRect(
            borderRadius: KonataTheme.borderRadiusThumb,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (isLogo) const DarkLogoCheckerBackground(),
                Padding(
                  padding: isLogo ? const EdgeInsets.all(12) : EdgeInsets.zero,
                  child: DetailManagedImage(
                    previewUrl,
                    key: ValueKey('tile_${previewUrl}_$_retryEpoch'),
                    loader: widget.imageLoader,
                    owner: widget.workId,
                    artwork: isLogo
                        ? ManagedArtwork.logo
                        : (isPoster
                              ? ManagedArtwork.poster
                              : ManagedArtwork.backdrop),
                    decodeWidth: isLogo ? 720 : 480,
                    fit: isLogo ? BoxFit.contain : BoxFit.cover,
                    onImageResolved: (ui.Image image, _) {
                      if (!mounted || _resolvedSize != null) return;
                      setState(() {
                        _resolvedSize = Size(
                          image.width.toDouble(),
                          image.height.toDouble(),
                        );
                      });
                    },
                    errorBuilder: (_, _, _) => ArtworkErrorFallback(
                      compact: true,
                      onRetry: () {
                        PaintingBinding.instance.imageCache.clear();
                        setState(() => _retryEpoch++);
                      },
                    ),
                  ),
                ),
                Positioned(
                  left: 6,
                  right: (selected || widget.isCurrentSaved) ? 44 : 6,
                  top: 6,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildSourceBadge(option),
                        if (option.langTag != null &&
                            option.langTag!.trim().isNotEmpty) ...[
                          const SizedBox(width: 4),
                          ArtworkOverlayMiniBadge(
                            text: option.langTag!,
                            backgroundColor: KonataTheme.scrimBlackDeep,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: ArtworkOverlayMiniBadge(
                      text: '已选',
                      backgroundColor: p.accent,
                      borderColor: KonataTheme.overlayWhiteTextMid,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else if (widget.isCurrentSaved)
                  const Positioned(
                    top: 6,
                    right: 6,
                    child: ArtworkOverlayMiniBadge(
                      text: '当前',
                      backgroundColor: KonataTheme.scrimBlackDeep,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                if (resolutionText != null)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: ArtworkOverlayMiniBadge.resolution(resolutionText),
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
      return ArtworkOverlayMiniBadge(
        text: displayLabel,
        backgroundColor: KonataTheme.bangumiPink,
        fontWeight: FontWeight.w700,
        borderColor: KonataTheme.overlayWhiteStroke,
      );
    }
    if (displayLabel.startsWith('TMDB')) {
      return ArtworkOverlayMiniBadge(
        text: displayLabel,
        backgroundColor: KonataTheme.tmdbNavy,
        textGradient: KonataTheme.tmdbBrandGradient,
        fontWeight: FontWeight.w700,
        borderColor: KonataTheme.tmdbCyan.withValues(alpha: 0.28),
      );
    }
    if (option.isFanart || displayLabel.startsWith('Fanart')) {
      return ArtworkOverlayMiniBadge(
        text: displayLabel,
        backgroundColor: KonataTheme.specReleaseBlue.withValues(alpha: 0.24),
        fontWeight: FontWeight.w700,
        borderColor: KonataTheme.specReleaseBlue.withValues(alpha: 0.55),
      );
    }
    return ArtworkOverlayMiniBadge(
      text: displayLabel,
      backgroundColor: KonataTheme.scrimBlackDense,
    );
  }
}
