part of 'scan_lightbox_dialog.dart';

/// 灯箱顶栏、视口手势画布与底部只读缓存胶片条分片视图。
extension _ScanLightboxDialogViews on _ScanLightboxDialogState {
  Widget _buildTopBar({
    required KonataPalette p,
    required MediaVariant current,
    required MediaSource? source,
    required int safeIdx,
    required bool compact,
    required BoxConstraints? iconConstraints,
  }) {
    final hasVolumes = _scanSummary.chips.length >= 2;
    final activeVolumeLabel = _selectedVolumeKey == null
        ? '全部分卷 (${widget.bundle.scanVariants.length})'
        : (_scanSummary.chips
                  .where((c) => c.key == _selectedVolumeKey)
                  .firstOrNull
                  ?.label ??
              '当前分卷');

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 12.0 : 16.0,
        compact ? 6.0 : 10.0,
        compact ? 6.0 : 12.0,
        compact ? 6.0 : 8.0,
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
                    fontSize: compact ? 13 : 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${safeIdx + 1} / ${_scopedScans.length}'
                  '${_activePixelWidth != null && _activePixelHeight != null ? ' · $_activePixelWidth×$_activePixelHeight' : ''}'
                  ' · ${current.relativePath}',
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
          if (hasVolumes && !compact) ...[
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: '切换画册分卷范围',
              onSelected: (value) =>
                  unawaited(_selectVolume(value == '__all__' ? null : value)),
              itemBuilder: (_) => [
                PopupMenuItem<String>(
                  value: '__all__',
                  child: Text('全部分卷 (${widget.bundle.scanVariants.length})'),
                ),
                for (final chip in _scanSummary.chips)
                  PopupMenuItem<String>(
                    value: chip.key,
                    child: Text('${chip.label} (${chip.count})'),
                  ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: KonataTheme.overlayWhiteSubtle,
                  borderRadius: KonataTheme.borderRadiusPill,
                  border: Border.all(color: KonataTheme.overlayWhiteMuted),
                ),
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
          if (!compact) ...[
            const SizedBox(width: 6),
            PopupMenuButton<_ScanFitMode>(
              tooltip: '缩放适应模式',
              onSelected: _applyFitMode,
              itemBuilder: (_) => [
                for (final mode in _ScanFitMode.values)
                  PopupMenuItem<_ScanFitMode>(
                    value: mode,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _fitMode == mode
                              ? Icons.check_rounded
                              : Icons.crop_free_rounded,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(mode.label),
                      ],
                    ),
                  ),
              ],
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: KonataTheme.overlayWhiteSubtle,
                  borderRadius: KonataTheme.borderRadiusSm,
                  border: Border.all(color: KonataTheme.overlayWhiteMuted),
                ),
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
          ],
          IconButton(
            tooltip: '重置缩放（双击画面也可还原）',
            constraints: iconConstraints,
            onPressed: _currentScale > 1.005 ? _resetZoom : null,
            icon: const Icon(
              Icons.fit_screen_rounded,
              color: KonataTheme.pureWhite,
              size: 19,
            ),
          ),
          if (_scopedScans.length > 1)
            IconButton(
              tooltip: _showFilmstrip ? '隐藏底部胶片条' : '显示底部胶片条',
              constraints: iconConstraints,
              onPressed: _toggleFilmstrip,
              icon: Icon(
                _showFilmstrip
                    ? Icons.view_carousel_rounded
                    : Icons.view_carousel_outlined,
                color: KonataTheme.pureWhite,
                size: 19,
              ),
            ),
          IconButton(
            tooltip: _fullscreen ? '退出全屏 (F)' : '沉浸全屏 (F)',
            constraints: iconConstraints,
            onPressed: _toggleFullscreen,
            icon: Icon(
              _fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              color: KonataTheme.pureWhite,
              size: 20,
            ),
          ),
          if (KonataAdaptiveTokens.isWindows)
            IconButton(
              tooltip: '用系统图片查看器打开',
              constraints: iconConstraints,
              onPressed: () => unawaited(_openInSystemViewer(current, source)),
              icon: const Icon(
                Icons.open_in_new_rounded,
                color: KonataTheme.pureWhite,
                size: 19,
              ),
            ),
          if (_scopedScans.length > 1) ...[
            IconButton(
              tooltip: '上一张 (←)',
              constraints: iconConstraints,
              onPressed: safeIdx > 0
                  ? () => unawaited(_selectIndex(safeIdx - 1))
                  : null,
              icon: const Icon(
                Icons.chevron_left_rounded,
                color: KonataTheme.pureWhite,
              ),
            ),
            IconButton(
              tooltip: '下一张 (→)',
              constraints: iconConstraints,
              onPressed: safeIdx < _scopedScans.length - 1
                  ? () => unawaited(_selectIndex(safeIdx + 1))
                  : null,
              icon: const Icon(
                Icons.chevron_right_rounded,
                color: KonataTheme.pureWhite,
              ),
            ),
          ],
          IconButton(
            tooltip: '关闭 (Esc)',
            constraints: iconConstraints,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(
              Icons.close_rounded,
              color: KonataTheme.pureWhite,
            ),
          ),
        ],
      ),
    );
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
          child: Text(
            _errorText!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: p.danger,
              fontSize: KonataTheme.fontSizeBody,
            ),
          ),
        ),
      );
    }
    if (displayProvider == null) {
      return Center(
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
                    errorBuilder: (_, _, _) => Text(
                      '图像解码失败或格式不受支持',
                      style: TextStyle(
                        color: KonataTheme.overlayWhiteTextDim,
                      ),
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
                        decoration: BoxDecoration(
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
