import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/sources/artwork_crop_math.dart';
import '../../infrastructure/cache/local_artwork_cropper.dart';
import '../theme/konata_palette.dart';
import '../widgets/design_system/konata_glass_dialog.dart';
import '../widgets/design_system/konata_pill_button.dart';

/// 本地图片固定比例（海报 2:3 / 背景 16:9）可视化框选裁切弹窗。
///
/// 在框内左键拖拽平移、四角锚点拖拽等比缩放或滚轮缩放后，
/// 返回归一化至原图真实分辨率坐标系的 [ArtworkNormalizedCropRect]。
class ArtworkCropDialog extends StatefulWidget {
  /// 创建固定比例框选裁切弹窗。
  const ArtworkCropDialog({
    super.key,
    required this.source,
    required this.isPoster,
  });

  /// 按原始像素分辨率完整解码后的本地图片句柄。
  final LoadedLocalArtwork source;

  /// `true` 表示竖版封面（锁定 `2 : 3`）；`false` 表示横版背景（锁定 `16 : 9`）。
  final bool isPoster;

  @override
  State<ArtworkCropDialog> createState() => _ArtworkCropDialogState();
}

class _ArtworkCropDialogState extends State<ArtworkCropDialog> {
  static const double _stagePad = 14.0;
  static const double _cornerHitRadius = 18.0;

  late final double _aspectRatio;
  late ArtworkNormalizedCropRect _cropRect;

  ArtworkCropCorner? _activeCorner;
  bool _draggingMove = false;
  ArtworkCropCorner? _hoveredCorner;
  bool _hoveredInterior = false;

  @override
  void initState() {
    super.initState();
    _aspectRatio = widget.isPoster
        ? ArtworkCropMath.posterAspectRatio
        : ArtworkCropMath.backdropAspectRatio;
    _cropRect = ArtworkCropMath.initialMaxCenteredRect(
      imageWidth: widget.source.width,
      imageHeight: widget.source.height,
      aspectRatio: _aspectRatio,
    );
  }

  Rect _computeDisplayRect(Size stageSize) {
    final innerW = math.max(1.0, stageSize.width - _stagePad * 2);
    final innerH = math.max(1.0, stageSize.height - _stagePad * 2);
    final fitted = ArtworkCropMath.fitContainDisplayRect(
      stageWidth: innerW,
      stageHeight: innerH,
      imageWidth: widget.source.width,
      imageHeight: widget.source.height,
    );
    return Rect.fromLTWH(
      _stagePad + fitted.left,
      _stagePad + fitted.top,
      fitted.width,
      fitted.height,
    );
  }

  Rect _toCanvasCropRect(Rect displayRect) {
    return Rect.fromLTWH(
      displayRect.left + _cropRect.left * displayRect.width,
      displayRect.top + _cropRect.top * displayRect.height,
      _cropRect.width * displayRect.width,
      _cropRect.height * displayRect.height,
    );
  }

  ArtworkCropCorner? _hitTestCorner(Offset pos, Rect cropCanvasRect) {
    final corners = <(ArtworkCropCorner, Offset)>[
      (ArtworkCropCorner.topLeft, cropCanvasRect.topLeft),
      (ArtworkCropCorner.topRight, cropCanvasRect.topRight),
      (ArtworkCropCorner.bottomLeft, cropCanvasRect.bottomLeft),
      (ArtworkCropCorner.bottomRight, cropCanvasRect.bottomRight),
    ];
    ArtworkCropCorner? best;
    var bestDist = double.infinity;
    for (final entry in corners) {
      final d = (pos - entry.$2).distance;
      if (d <= _cornerHitRadius && d < bestDist) {
        best = entry.$1;
        bestDist = d;
      }
    }
    return best;
  }

  MouseCursor _resolveCursor() {
    final corner = _activeCorner ?? _hoveredCorner;
    if (corner != null) {
      return switch (corner) {
        ArtworkCropCorner.topLeft ||
        ArtworkCropCorner.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
        ArtworkCropCorner.topRight ||
        ArtworkCropCorner.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
      };
    }
    if (_draggingMove || _hoveredInterior) {
      return SystemMouseCursors.move;
    }
    return SystemMouseCursors.basic;
  }

  void _resetCrop() {
    setState(() {
      _cropRect = ArtworkCropMath.initialMaxCenteredRect(
        imageWidth: widget.source.width,
        imageHeight: widget.source.height,
        aspectRatio: _aspectRatio,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ratioLabel = widget.isPoster ? '2 : 3' : '16 : 9';
    final px = ArtworkCropMath.toSourcePixelRect(
      _cropRect,
      imageWidth: widget.source.width,
      imageHeight: widget.source.height,
    );

    return KonataGlassDialog(
      width: 760,
      height: 620,
      title: widget.isPoster ? '裁剪作品封面海报' : '裁剪作品背景图',
      headerTrailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: p.softFill,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: p.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.aspect_ratio_rounded, size: 13.5, color: p.accent),
            const SizedBox(width: 5),
            Text(
              '锁定比例 $ratioLabel',
              style: TextStyle(
                color: p.textSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      actions: [
        KonataPillButton.ghost(
          label: '重置选框',
          icon: Icons.restart_alt_rounded,
          compact: true,
          onPressed: _resetCrop,
        ),
        KonataPillButton.ghost(
          label: '取消',
          compact: true,
          onPressed: () => Navigator.of(context).pop(null),
        ),
        KonataPillButton.primary(
          key: const Key('artworkCropConfirmButton'),
          label: '确认应用',
          icon: Icons.check_rounded,
          compact: true,
          onPressed: () => Navigator.of(context).pop(_cropRect),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: p.isDark ? 0.45 : 0.72),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: p.hairline),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final stageSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    final displayRect = _computeDisplayRect(stageSize);
                    final cropCanvasRect = _toCanvasCropRect(displayRect);

                    return Listener(
                      onPointerSignal: (event) {
                        if (event is PointerScrollEvent) {
                          final dy = event.scrollDelta.dy;
                          if (dy == 0) return;
                          final scale = dy < 0 ? 0.90 : 1.11;
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
                      child: MouseRegion(
                        cursor: _resolveCursor(),
                        onHover: (event) {
                          final corner = _hitTestCorner(
                            event.localPosition,
                            cropCanvasRect,
                          );
                          final interior =
                              corner == null &&
                              cropCanvasRect.contains(event.localPosition);
                          if (corner != _hoveredCorner ||
                              interior != _hoveredInterior) {
                            setState(() {
                              _hoveredCorner = corner;
                              _hoveredInterior = interior;
                            });
                          }
                        },
                        onExit: (_) {
                          if (_hoveredCorner != null || _hoveredInterior) {
                            setState(() {
                              _hoveredCorner = null;
                              _hoveredInterior = false;
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
                            if (displayRect.width <= 0 ||
                                displayRect.height <= 0) {
                              return;
                            }
                            if (_activeCorner != null) {
                              final normX =
                                  (details.localPosition.dx -
                                      displayRect.left) /
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
                              final dNormX =
                                  details.delta.dx / displayRect.width;
                              final dNormY =
                                  details.delta.dy / displayRect.height;
                              setState(() {
                                _cropRect = ArtworkCropMath.panCrop(
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
                                  image: widget.source.fullImage,
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
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.open_with_rounded,
                size: 14,
                color: p.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '拖拽选框移动位置 · 拖拽四角锚点或滚动滚轮等比缩放',
                  style: TextStyle(color: p.textSecondary, fontSize: 12),
                ),
              ),
              Text(
                '原图 ${widget.source.width}×${widget.source.height}  ·  裁切区域 ${px.width}×${px.height}',
                style: TextStyle(
                  color: p.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
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
    // 1. 仅对原图显示区域内、裁切选框之外铺设半透明暗色遮罩
    final maskPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(displayRect)
      ..addRect(cropRect);
    canvas.drawPath(
      maskPath,
      Paint()..color = Colors.black.withValues(alpha: 0.58),
    );

    // 2. 九宫格构图辅助线
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 0.85;
    final thirdW = cropRect.width / 3.0;
    final thirdH = cropRect.height / 3.0;
    for (var i = 1; i <= 2; i++) {
      final vx = cropRect.left + thirdW * i;
      canvas.drawLine(
        Offset(vx, cropRect.top),
        Offset(vx, cropRect.bottom),
        gridPaint,
      );
      final hy = cropRect.top + thirdH * i;
      canvas.drawLine(
        Offset(cropRect.left, hy),
        Offset(cropRect.right, hy),
        gridPaint,
      );
    }

    // 3. 选框 1.5px 细边
    canvas.drawRect(
      cropRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.94)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 4. 四角 L 型加粗锚点与圆点手柄
    const bracketLen = 16.0;
    final bracketPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3.0;
    final dotFill = Paint()..color = Colors.white;
    final dotBorder = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    void drawCorner(Offset pt, double dx, double dy) {
      canvas.drawLine(pt, pt + Offset(dx * bracketLen, 0), bracketPaint);
      canvas.drawLine(pt, pt + Offset(0, dy * bracketLen), bracketPaint);
      canvas.drawCircle(pt, 4.5, dotFill);
      canvas.drawCircle(pt, 4.5, dotBorder);
    }

    drawCorner(cropRect.topLeft, 1, 1);
    drawCorner(cropRect.topRight, -1, 1);
    drawCorner(cropRect.bottomLeft, 1, -1);
    drawCorner(cropRect.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(covariant _ArtworkCropOverlayPainter oldDelegate) {
    return oldDelegate.displayRect != displayRect ||
        oldDelegate.cropRect != cropRect ||
        oldDelegate.accentColor != accentColor;
  }
}
