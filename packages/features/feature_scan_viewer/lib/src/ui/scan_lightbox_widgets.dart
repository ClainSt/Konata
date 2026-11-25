part of 'scan_lightbox_dialog.dart';

/// 灯箱顶栏、视口手势画布与底部只读缓存胶片条分片视图。
extension _ScanLightboxDialogViews on _ScanLightboxDialogState {
  Widget _buildTopBar({
    required KonataPalette p,
    required MediaVariant current,
    required MediaSourceView? source,
    required int safeIdx,
    required double dialogWidth,
    required bool compact,
  }) {
    final hasVolumes = _scanSummary.chips.isNotEmpty;
    final activeVolumeLabel = _selectedVolumeKey == null
        ? '全部分卷 (${widget.scans.length})'
        : (_scanSummary.chips
                  .where((c) => c.key == _selectedVolumeKey)
                  .firstOrNull
                  ?.label ??
              '当前分卷');

    final isAndroid = widget.platform != null
        ? widget.platform != KonataPlatform.windows
        : KonataAdaptiveTokens.isAndroid;
    final isWindows = widget.platform != null
        ? widget.platform == KonataPlatform.windows
        : KonataAdaptiveTokens.isWindows;
    final buttonFixedSize = isAndroid ? KonataAdaptiveTokens.touchTarget : null;
    final denseHeader = compact || dialogWidth < 520.0;
    final sizeText = ScanDisplayFormatter.formatBytes(
      _activeByteLength ?? current.fileSize,
    );

    final subtitleParts = <String>[
      '${safeIdx + 1} / ${_scopedScans.length}',
      if (_activePixelWidth != null && _activePixelHeight != null)
        '$_activePixelWidth×$_activePixelHeight',
      if (!denseHeader && sizeText.isNotEmpty) sizeText,
      if (!denseHeader) current.relativePath,
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(
        denseHeader ? 12.0 : 16.0,
        denseHeader ? 6.0 : 10.0,
        denseHeader ? 6.0 : 12.0,
        denseHeader ? 6.0 : 8.0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  current.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: KonataTheme.detailTextStyle(
                    color: KonataTheme.pureWhite,
                    fontSize: denseHeader ? 13 : 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitleParts.join(' · '),
                  key: const ValueKey('scan_lightbox_info_line'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: KonataTheme.detailTextStyle(
                    color: KonataTheme.overlayWhiteTextMuted,
                    fontSize: KonataTheme.fontSizeCaptionSm,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          if (!denseHeader && hasVolumes) ...[
            const SizedBox(width: 8),
            Builder(
              builder: (anchorCtx) => _GlassPillTrigger(
                tooltip: '切换画册分卷范围',
                onTap: () => unawaited(_showVolumeGlassMenu(anchorCtx)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(
                        activeVolumeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: KonataTheme.pureWhite,
                          fontSize: KonataTheme.fontSizeCaptionSm,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: KonataTheme.pureWhite,
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (!denseHeader) ...[
            const SizedBox(width: 6),
            Builder(
              builder: (anchorCtx) => _GlassPillTrigger(
                tooltip: '缩放适应模式',
                onTap: () => unawaited(_showFitModeGlassMenu(anchorCtx)),
                child: Text(
                  '${(_currentScale * 100).round()}%',
                  style: const TextStyle(
                    color: KonataTheme.pureWhite,
                    fontSize: KonataTheme.fontSizeCaptionSm,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            KonataCapsuleIconButton(
              icon: Icons.fit_screen_rounded,
              tooltip: '重置缩放（双击画面也可还原）',
              color: KonataTheme.pureWhite,
              size: 19,
              fixedSize: buttonFixedSize,
              onTap: _currentScale > 1.005 ? _resetZoom : null,
            ),
            if (_scopedScans.length > 1)
              KonataCapsuleIconButton(
                icon: _showFilmstrip
                    ? Icons.view_carousel_rounded
                    : Icons.view_carousel_outlined,
                tooltip: _showFilmstrip ? '隐藏底部胶片条' : '显示底部胶片条',
                color: KonataTheme.pureWhite,
                size: 19,
                fixedSize: buttonFixedSize,
                onTap: _toggleFilmstrip,
              ),
          ] else ...[
            Builder(
              builder: (anchorCtx) => KonataCapsuleIconButton(
                icon: Icons.more_horiz_rounded,
                tooltip: '更多画册操作',
                color: KonataTheme.pureWhite,
                size: 20,
                fixedSize: buttonFixedSize,
                onTap: () => unawaited(
                  _showCompactActionsMenu(anchorCtx, safeIdx, hasVolumes),
                ),
              ),
            ),
          ],
          KonataCapsuleIconButton(
            icon: _fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            tooltip: _fullscreen ? '退出全屏 (F)' : '沉浸全屏 (F)',
            color: KonataTheme.pureWhite,
            size: 20,
            fixedSize: buttonFixedSize,
            onTap: _toggleFullscreen,
          ),
          if (!denseHeader && isWindows)
            KonataCapsuleIconButton(
              icon: Icons.open_in_new_rounded,
              tooltip: '用系统图片查看器打开',
              color: KonataTheme.pureWhite,
              size: 19,
              fixedSize: buttonFixedSize,
              onTap: () => unawaited(_openInSystemViewer(current, source)),
            ),
          if (!denseHeader && _scopedScans.length > 1) ...[
            KonataCapsuleIconButton(
              icon: Icons.chevron_left_rounded,
              tooltip: '上一张 (←)',
              color: KonataTheme.pureWhite,
              size: 22,
              fixedSize: buttonFixedSize,
              onTap: safeIdx > 0
                  ? () => unawaited(_selectIndex(safeIdx - 1))
                  : null,
            ),
            KonataCapsuleIconButton(
              icon: Icons.chevron_right_rounded,
              tooltip: '下一张 (→)',
              color: KonataTheme.pureWhite,
              size: 22,
              fixedSize: buttonFixedSize,
              onTap: safeIdx < _scopedScans.length - 1
                  ? () => unawaited(_selectIndex(safeIdx + 1))
                  : null,
            ),
          ],
          KonataCapsuleIconButton(
            icon: Icons.close_rounded,
            tooltip: '关闭 (Esc)',
            color: KonataTheme.pureWhite,
            size: 20,
            fixedSize: buttonFixedSize,
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Future<void> _showVolumeGlassMenu(BuildContext anchorContext) async {
    final items = <KonataGlassMenuItem<String>>[
      KonataGlassMenuItem<String>(
        value: '__all__',
        label: '全部分卷 (${widget.scans.length})',
        icon: _selectedVolumeKey == null ? Icons.check_rounded : null,
      ),
      for (final chip in _scanSummary.chips)
        KonataGlassMenuItem<String>(
          value: chip.key,
          label: '${chip.label} (${chip.count})',
          icon: _selectedVolumeKey == chip.key ? Icons.check_rounded : null,
        ),
    ];
    final selected = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: items,
    );
    if (selected == null || !mounted) return;
    await _selectVolume(selected == '__all__' ? null : selected);
  }

  Future<void> _showFitModeGlassMenu(BuildContext anchorContext) async {
    final selected = await showKonataGlassMenu<_ScanFitMode>(
      anchorContext: anchorContext,
      items: [
        for (final mode in _ScanFitMode.values)
          KonataGlassMenuItem<_ScanFitMode>(
            value: mode,
            label: mode.label,
            icon: _fitMode == mode
                ? Icons.check_rounded
                : Icons.crop_free_rounded,
          ),
      ],
    );
    if (selected == null || !mounted) return;
    _applyFitMode(selected);
  }

  Future<void> _showCompactActionsMenu(
    BuildContext anchorContext,
    int safeIdx,
    bool hasVolumes,
  ) async {
    final items = <KonataGlassMenuItem<String>>[
      if (_scopedScans.length > 1 && safeIdx > 0)
        const KonataGlassMenuItem<String>(
          value: 'prev',
          label: '上一张',
          icon: Icons.chevron_left_rounded,
        ),
      if (_scopedScans.length > 1 && safeIdx < _scopedScans.length - 1)
        const KonataGlassMenuItem<String>(
          value: 'next',
          label: '下一张',
          icon: Icons.chevron_right_rounded,
        ),
      if (_currentScale > 1.005)
        const KonataGlassMenuItem<String>(
          value: 'reset_zoom',
          label: '重置缩放',
          icon: Icons.fit_screen_rounded,
        ),
      if (_scopedScans.length > 1)
        KonataGlassMenuItem<String>(
          value: 'toggle_filmstrip',
          label: _showFilmstrip ? '隐藏底部胶片条' : '显示底部胶片条',
          icon: _showFilmstrip
              ? Icons.view_carousel_rounded
              : Icons.view_carousel_outlined,
        ),
      for (final mode in _ScanFitMode.values)
        KonataGlassMenuItem<String>(
          value: 'fit:${mode.name}',
          label: mode.label,
          icon: _fitMode == mode
              ? Icons.check_rounded
              : Icons.crop_free_rounded,
        ),
      if (hasVolumes)
        const KonataGlassMenuItem<String>(
          value: 'vol:__all__',
          label: '查看全部分卷',
          icon: Icons.layers_outlined,
        ),
      if (hasVolumes)
        for (final chip in _scanSummary.chips)
          KonataGlassMenuItem<String>(
            value: 'vol:${chip.key}',
            label: '${chip.label} (${chip.count})',
            icon: _selectedVolumeKey == chip.key ? Icons.check_rounded : null,
          ),
    ];

    final action = await showKonataGlassMenu<String>(
      anchorContext: anchorContext,
      items: items,
    );
    if (action == null || !mounted) return;
    if (action == 'prev') {
      await _selectIndex(safeIdx - 1);
    } else if (action == 'next') {
      await _selectIndex(safeIdx + 1);
    } else if (action == 'reset_zoom') {
      _resetZoom();
    } else if (action == 'toggle_filmstrip') {
      _toggleFilmstrip();
    } else if (action.startsWith('fit:')) {
      final modeName = action.substring(4);
      final target = _ScanFitMode.values
          .where((m) => m.name == modeName)
          .firstOrNull;
      if (target != null) _applyFitMode(target);
    } else if (action.startsWith('vol:')) {
      final volKey = action.substring(4);
      await _selectVolume(volKey == '__all__' ? null : volKey);
    }
  }

  Widget _buildViewportBody(KonataPalette p, int safeIdx) {
    final displayProvider = _activeImageProvider ?? _placeholderProvider;

    if (displayProvider == null && _loadingFull) {
      return const Center(child: CircularProgressIndicator());
    }
    if (displayProvider == null && _errorText != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _errorText!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: p.danger,
                    fontSize: KonataTheme.fontSizeBody,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                KonataPillButton.primary(
                  label: '重新加载',
                  icon: Icons.refresh_rounded,
                  onPressed: () => unawaited(_loadCurrentScan()),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (displayProvider == null) {
      return const Center(
        child: Text(
          '无法读取当前画集图像内容',
          style: TextStyle(color: KonataTheme.overlayWhiteTextDim),
        ),
      );
    }

    final isUnzoomed = _currentScale <= 1.02;

    return LayoutBuilder(
      builder: (_, constraints) {
        final vw = constraints.maxWidth;
        final vh = constraints.maxHeight;
        _lastViewportSize = Size(vw, vh);

        return Listener(
          onPointerSignal: (event) => _handleWheelZoom(event, vw, vh),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleChromeVisible,
            onDoubleTapDown: (details) =>
                _lastDoubleTapLocalPos = details.localPosition,
            onDoubleTap: () => _toggleDoubleTapZoom(vw, vh),
            onHorizontalDragStart: isUnzoomed && _scopedScans.length > 1
                ? (_) => _touchSwipeDeltaX = 0.0
                : null,
            onHorizontalDragUpdate: isUnzoomed && _scopedScans.length > 1
                ? (details) => _touchSwipeDeltaX += details.delta.dx
                : null,
            onHorizontalDragEnd: isUnzoomed && _scopedScans.length > 1
                ? (details) {
                    final velocity = details.primaryVelocity ?? 0.0;
                    if (_touchSwipeDeltaX <= -48.0 || velocity < -380.0) {
                      if (safeIdx < _scopedScans.length - 1) {
                        unawaited(_selectIndex(safeIdx + 1));
                      }
                    } else if (_touchSwipeDeltaX >= 48.0 || velocity > 380.0) {
                      if (safeIdx > 0) {
                        unawaited(_selectIndex(safeIdx - 1));
                      }
                    }
                    _touchSwipeDeltaX = 0.0;
                  }
                : null,
            child: InteractiveViewer(
              transformationController: _transformController,
              panEnabled: !isUnzoomed,
              scaleEnabled: true,
              minScale: _ScanLightboxDialogState._minScale,
              maxScale: _ScanLightboxDialogState._maxScale,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: vw,
                height: vh,
                child: Center(
                  child: Image(
                    image: displayProvider,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const Text(
                      '图像解码失败或格式不受支持',
                      style: TextStyle(color: KonataTheme.overlayWhiteTextDim),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFilmstrip(KonataPalette p, int safeIdx) {
    return SizedBox(
      key: const ValueKey('scan_lightbox_filmstrip'),
      height: 76,
      child: ListView.separated(
        controller: _filmstripController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        itemCount: _scopedScans.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, idx) {
          final v = _scopedScans[idx];
          final isSelected = idx == safeIdx;
          _ensureFilmstripThumbnail(v);
          final cachedThumb = _filmstripCache[v.id];

          return GestureDetector(
            onTap: () => unawaited(_selectIndex(idx)),
            child: AnimatedContainer(
              duration: KonataTheme.motionFast,
              width: 58,
              height: 60,
              decoration: BoxDecoration(
                color: KonataTheme.cinemaObsidian.withValues(alpha: 0.72),
                borderRadius: KonataTheme.borderRadiusSm,
                border: Border.all(
                  color: isSelected
                      ? KonataTheme.pureWhite
                      : KonataTheme.overlayWhiteBorder,
                  width: isSelected ? 1.8 : 0.9,
                ),
              ),
              child: ClipRRect(
                borderRadius: KonataTheme.borderRadiusChip,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (cachedThumb != null && cachedThumb.isNotEmpty)
                      Image.memory(
                        cachedThumb,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    else
                      Center(
                        child: Text(
                          '${idx + 1}',
                          style: TextStyle(
                            color: isSelected
                                ? KonataTheme.pureWhite
                                : KonataTheme.overlayWhiteTextMuted,
                            fontSize: KonataTheme.fontSizeCaptionSm,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 3.5,
                          vertical: 1,
                        ),
                        decoration: const BoxDecoration(
                          color: KonataTheme.scrimBlackDense,
                          borderRadius: KonataTheme.borderRadiusChipSm,
                        ),
                        child: Text(
                          '${idx + 1}',
                          style: const TextStyle(
                            color: KonataTheme.pureWhite,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GlassPillTrigger extends StatefulWidget {
  const _GlassPillTrigger({
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_GlassPillTrigger> createState() => _GlassPillTriggerState();
}

class _GlassPillTriggerState extends State<_GlassPillTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return KonataTooltip(
      message: widget.tooltip,
      waitDuration: KonataTheme.tooltipSlowWaitDuration,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: KonataTheme.motionFast,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _hovered
                  ? KonataTheme.overlayWhiteMuted
                  : KonataTheme.overlayWhiteSubtle,
              borderRadius: KonataTheme.borderRadiusPill,
              border: Border.all(color: KonataTheme.overlayWhiteMuted),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
