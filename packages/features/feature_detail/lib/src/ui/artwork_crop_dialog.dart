import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/artwork_crop_math.dart';
import '../data/local_artwork_cropper.dart';

/// 本地自定义封面（`2:3`）与背景图（`16:9`）交互式固定比例框选裁切弹窗。
class ArtworkCropDialog extends StatefulWidget {
  /// 创建固定比例图片裁切弹窗。
  const ArtworkCropDialog({
    super.key,
    required this.source,
    required this.isPoster,
    required this.onSaveCrop,
  });

  /// 已按完整分辨率解码的本地图片句柄。
  final LoadedLocalArtwork source;

  /// 是否裁切竖版封面（`true` 锁定 `2:3`；`false` 锁定 `16:9`）。
  final bool isPoster;

  /// 用户确认裁切后执行持久化的异步回调。
  final Future<void> Function(ArtworkNormalizedCropRect cropRect) onSaveCrop;

  @override
  State<ArtworkCropDialog> createState() => _ArtworkCropDialogState();
}

class _ArtworkCropDialogState extends State<ArtworkCropDialog> {
  static const double _cornerHitRadius = 22.0;

  late ArtworkNormalizedCropRect _cropRect;
  ArtworkCropCorner? _activeCorner;
  bool _draggingMove = false;
  bool _saving = false;

  double get _aspectRatio => widget.isPoster
      ? ArtworkCropMath.posterAspectRatio
      : ArtworkCropMath.backdropAspectRatio;

  @override
  void initState() {
    super.initState();
    _resetCropRect();
  }

  void _resetCropRect() {
    _cropRect = ArtworkCropMath.initialMaxCenteredRect(
      imageWidth: widget.source.width,
      imageHeight: widget.source.height,
      aspectRatio: _aspectRatio,
    );
  }

  ArtworkCropCorner? _hitTestCorner(Offset pos, Rect cropCanvasRect) {
    final candidates = <MapEntry<ArtworkCropCorner, Offset>>[
      MapEntry(ArtworkCropCorner.topLeft, cropCanvasRect.topLeft),
      MapEntry(ArtworkCropCorner.topRight, cropCanvasRect.topRight),
      MapEntry(ArtworkCropCorner.bottomLeft, cropCanvasRect.bottomLeft),
      MapEntry(ArtworkCropCorner.bottomRight, cropCanvasRect.bottomRight),
    ];
    ArtworkCropCorner? bestCorner;
    var bestDistance = _cornerHitRadius;
    for (final entry in candidates) {
      final distance = (pos - entry.value).distance;
      if (distance <= bestDistance) {
        bestDistance = distance;
        bestCorner = entry.key;
      }
    }
    return bestCorner;
  }

  Future<void> _confirmCrop() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSaveCrop(_cropRect);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        showKonataToast(context, '保存裁切图片失败：$error', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final srcPx = ArtworkCropMath.toSourcePixelRect(
      _cropRect,
      imageWidth: widget.source.width,
      imageHeight: widget.source.height,
    );
    final ratioLabel = widget.isPoster ? '2:3 竖版封面' : '16:9 横版背景';

    return KonataGlassDialog(
      width: 680,
      height: 540,
      title: '裁切自定义${widget.isPoster ? '封面海报' : '背景原画'} ($ratioLabel)',
      onClose: _saving ? null : () => Navigator.of(context).pop(false),
      actions: [
        KonataPillButton.ghost(
          label: '重置选框',
          icon: Icons.restart_alt_rounded,
          compact: true,
          onPressed: _saving ? null : () => setState(_resetCropRect),
        ),
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        ),
        KonataPillButton.primary(
          label: _saving ? '保存中...' : '确认裁切并应用',
          icon: Icons.crop_rounded,
          compact: true,
          onPressed: _saving ? null : _confirmCrop,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: KonataTheme.borderRadiusCard,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: KonataTheme.cinemaObsidian,
                  borderRadius: KonataTheme.borderRadiusCard,
                  border: Border.all(color: p.hairline, width: 1),
                ),
                child: LayoutBuilder(
                  builder: (_, constraints) {
                    final fitted = ArtworkCropMath.fitContainDisplayRect(
                      stageWidth: constraints.maxWidth,
                      stageHeight: constraints.maxHeight,
                      imageWidth: widget.source.width,
                      imageHeight: widget.source.height,
                    );
                    final displayRect = Rect.fromLTWH(
                      fitted.left,
                      fitted.top,
                      fitted.width,
                      fitted.height,
                    );
                    final cropCanvasRect = Rect.fromLTWH(
                      displayRect.left + _cropRect.left * displayRect.width,
                      displayRect.top + _cropRect.top * displayRect.height,
                      _cropRect.width * displayRect.width,
                      _cropRect.height * displayRect.height,
                    );

                    return Listener(
                      onPointerSignal: (event) {
                        if (event is PointerScrollEvent) {
                          final scale = event.scrollDelta.dy < 0 ? 0.92 : 1.08;
                          setState(() {
                            _cropRect = ArtworkCropMath.zoomAroundCenter(
                              _cropRect,
                              zoomScale: scale,
                              imageWidth: widget.source.width,
                              imageHeight: widget.source.height,
                              aspectRatio: _aspectRatio,
                            );
                          });
                        }
                      },
                      child: GestureDetector(
                        key: const Key('artworkCropCanvas'),
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (details) {
                          final pos = details.localPosition;
                          final corner = _hitTestCorner(pos, cropCanvasRect);
                          if (corner != null) {
                            _activeCorner = corner;
                            _draggingMove = false;
                            return;
                          }
                          if (cropCanvasRect.contains(pos)) {
                            _activeCorner = null;
                            _draggingMove = true;
                          }
                        },
                        onPanUpdate: (details) {
                          if (displayRect.width <= 0 || displayRect.height <= 0) {
                            return;
                          }
                          if (_activeCorner != null) {
                            final normX =
                                (details.localPosition.dx - displayRect.left) /
                                displayRect.width;
                            final normY =
                                (details.localPosition.dy - displayRect.top) /
                                displayRect.height;
                            setState(() {
                              _cropRect = ArtworkCropMath.resizeFromCorner(
                                _cropRect,
                                corner: _activeCorner!,
                                pointerNormX: normX,
                                pointerNormY: normY,
                                imageWidth: widget.source.width,
                                imageHeight: widget.source.height,
                                aspectRatio: _aspectRatio,
                              );
                            });
                          } else if (_draggingMove) {
                            final dNormX = details.delta.dx / displayRect.width;
                            final dNormY = details.delta.dy / displayRect.height;
                            setState(() {
                              _cropRect = ArtworkCropMath.moveRect(
                                _cropRect,
                                deltaNormX: dNormX,
                                deltaNormY: dNormY,
                              );
                            });
                          }
                        },
                        onPanEnd: (_) {
                          _activeCorner = null;
                          _draggingMove = false;
                        },
                        onPanCancel: () {
                          _activeCorner = null;
                          _draggingMove = false;
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned.fromRect(
                              rect: displayRect,
                              child: RawImage(
                                image: widget.source.image,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _ArtworkCropOverlayPainter(
                                  displayRect: displayRect,
                                  cropRect: cropCanvasRect,
                                  accentColor: p.accent,
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
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Text(
                '拖拽框内移动位置，拖拽四角或使用滚轮等比缩放',
                style: KonataTheme.captionStyle(
                  p,
                ).copyWith(color: p.textSecondary),
              ),
              Text(
                '输出像素：${srcPx.width} × ${srcPx.height}（原图 ${widget.source.width} × ${widget.source.height}）',
                style: KonataTheme.captionStyle(p).copyWith(
                  color: p.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArtworkCropOverlayPainter extends CustomPainter {
  const _ArtworkCropOverlayPainter({
    required this.displayRect,
    required this.cropRect,
    required this.accentColor,
  });

  final Rect displayRect;
  final Rect cropRect;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final dimPaint = Paint()..color = KonataTheme.scrimBlackHeavy;
    final outerPath = Path()..addRect(displayRect);
    final innerPath = Path()..addRect(cropRect);
    final diffPath = Path.combine(
      PathOperation.difference,
      outerPath,
      innerPath,
    );
    canvas.drawPath(diffPath, dimPaint);

    final borderPaint = Paint()
      ..color = KonataTheme.pureWhite
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRect(cropRect, borderPaint);

    final gridPaint = Paint()
      ..color = KonataTheme.pureWhite.withValues(alpha: 0.34)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (var i = 1; i <= 2; i++) {
      final gx = cropRect.left + cropRect.width * i / 3;
      final gy = cropRect.top + cropRect.height * i / 3;
      canvas.drawLine(
        Offset(gx, cropRect.top),
        Offset(gx, cropRect.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(cropRect.left, gy),
        Offset(cropRect.right, gy),
        gridPaint,
      );
    }

    final handlePaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.fill;
    final handleStroke = Paint()
      ..color = KonataTheme.pureWhite
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final corner in <Offset>[
      cropRect.topLeft,
      cropRect.topRight,
      cropRect.bottomLeft,
      cropRect.bottomRight,
    ]) {
      canvas.drawCircle(corner, 5.5, handlePaint);
      canvas.drawCircle(corner, 5.5, handleStroke);
    }
  }

  @override
  bool shouldRepaint(covariant _ArtworkCropOverlayPainter oldDelegate) {
    return displayRect != oldDelegate.displayRect ||
        cropRect != oldDelegate.cropRect ||
        accentColor != oldDelegate.accentColor;
  }
}
