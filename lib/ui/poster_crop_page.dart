import '../l10n/strings.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'uniform_action_bar.dart';
import 'package:flutter/widget_previews.dart';

enum _CropDragMode {
  move,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  left,
  right,
  top,
  bottom,
}

/// Crop geometry is in source pixels; resize never changes the selected area.
class PosterCropPage extends StatefulWidget {
  const PosterCropPage({
    super.key,
    required this.bytes,
    this.aspectRatio = 2 / 3,
    this.maxExportWidth = 1000,
    this.isBackdrop = false,
  });
  final Uint8List bytes;
  final double aspectRatio;
  final int maxExportWidth;
  final bool isBackdrop;
  @override
  State<PosterCropPage> createState() => _PosterCropPageState();
}

class _PosterCropPageState extends State<PosterCropPage> {
  ui.Image? image;
  String? error;
  double zoom = 1, initialZoom = 1;
  Offset center = Offset.zero,
      startCenter = Offset.zero,
      startFocal = Offset.zero;
  Rect startCrop = Rect.zero;
  _CropDragMode _dragMode = _CropDragMode.move;
  MouseCursor _cursor = SystemMouseCursors.basic;
  bool _dragging = false;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(widget.bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final maxDimension = math.max(descriptor.width, descriptor.height);
      final factor = math.min(1.0, 4096 / maxDimension);
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * factor).round()),
        targetHeight: math.max(1, (descriptor.height * factor).round()),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        image = frame.image;
        center = Offset(image!.width / 2, image!.height / 2);
      });
    } catch (_) {
      if (mounted) setState(() => error = 'decode');
    }
  }

  @override
  void dispose() {
    image?.dispose();
    super.dispose();
  }

  double get baseWidth =>
      math.min(image!.width.toDouble(), image!.height * widget.aspectRatio);

  Rect get crop {
    final w = baseWidth / zoom, h = w / widget.aspectRatio;
    final x = center.dx.clamp(w / 2, image!.width - w / 2),
        y = center.dy.clamp(h / 2, image!.height - h / 2);
    return Rect.fromCenter(center: Offset(x, y), width: w, height: h);
  }

  void _zoom(double value) {
    setState(() {
      zoom = value.clamp(1, 8);
      center = crop.center;
    });
  }

  ({double scale, Rect imageRect, Rect cropRect}) _layout(
    BoxConstraints bounds,
  ) {
    final imgW = image!.width.toDouble(), imgH = image!.height.toDouble();
    final availW = math.max(1.0, bounds.maxWidth - 40);
    final availH = math.max(1.0, bounds.maxHeight - 40);
    final scale = math.min(availW / imgW, availH / imgH);
    final imageRect = Rect.fromCenter(
      center: Offset(bounds.maxWidth / 2, bounds.maxHeight / 2),
      width: imgW * scale,
      height: imgH * scale,
    );
    final c = crop;
    final cropRect = Rect.fromLTWH(
      imageRect.left + c.left * scale,
      imageRect.top + c.top * scale,
      c.width * scale,
      c.height * scale,
    );
    return (scale: scale, imageRect: imageRect, cropRect: cropRect);
  }

  _CropDragMode? _hitTestMode(Offset pos, Rect frame) {
    const cornerRadius = 22.0;
    const edgeRadius = 16.0;
    if ((pos - frame.topLeft).distance <= cornerRadius) {
      return _CropDragMode.topLeft;
    }
    if ((pos - frame.topRight).distance <= cornerRadius) {
      return _CropDragMode.topRight;
    }
    if ((pos - frame.bottomLeft).distance <= cornerRadius) {
      return _CropDragMode.bottomLeft;
    }
    if ((pos - frame.bottomRight).distance <= cornerRadius) {
      return _CropDragMode.bottomRight;
    }
    if (pos.dy >= frame.top - edgeRadius &&
        pos.dy <= frame.bottom + edgeRadius) {
      if ((pos.dx - frame.left).abs() <= edgeRadius) return _CropDragMode.left;
      if ((pos.dx - frame.right).abs() <= edgeRadius) {
        return _CropDragMode.right;
      }
    }
    if (pos.dx >= frame.left - edgeRadius &&
        pos.dx <= frame.right + edgeRadius) {
      if ((pos.dy - frame.top).abs() <= edgeRadius) return _CropDragMode.top;
      if ((pos.dy - frame.bottom).abs() <= edgeRadius) {
        return _CropDragMode.bottom;
      }
    }
    if (frame.contains(pos)) return _CropDragMode.move;
    return null;
  }

  MouseCursor _cursorForMode(_CropDragMode? mode) => switch (mode) {
    _CropDragMode.topLeft ||
    _CropDragMode.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    _CropDragMode.topRight ||
    _CropDragMode.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
    _CropDragMode.left ||
    _CropDragMode.right => SystemMouseCursors.resizeLeftRight,
    _CropDragMode.top ||
    _CropDragMode.bottom => SystemMouseCursors.resizeUpDown,
    _CropDragMode.move => SystemMouseCursors.move,
    null => SystemMouseCursors.basic,
  };

  void _applyResize(_CropDragMode mode, Offset deltaSrc) {
    final imgW = image!.width.toDouble(), imgH = image!.height.toDouble();
    final ratio = widget.aspectRatio;
    final minW = baseWidth / 8.0;
    switch (mode) {
      case _CropDragMode.bottomRight:
        final anchor = startCrop.topLeft;
        final maxW = math.min(
          baseWidth,
          math.min(imgW - anchor.dx, (imgH - anchor.dy) * ratio),
        );
        final candW =
            ((startCrop.width + deltaSrc.dx) +
                (startCrop.height + deltaSrc.dy) * ratio) /
            2;
        final newW = candW.clamp(minW, math.max(minW, maxW));
        final newH = newW / ratio;
        zoom = (baseWidth / newW).clamp(1.0, 8.0);
        center = Offset(anchor.dx + newW / 2, anchor.dy + newH / 2);
      case _CropDragMode.topLeft:
        final anchor = startCrop.bottomRight;
        final maxW = math.min(
          baseWidth,
          math.min(anchor.dx, anchor.dy * ratio),
        );
        final candW =
            ((startCrop.width - deltaSrc.dx) +
                (startCrop.height - deltaSrc.dy) * ratio) /
            2;
        final newW = candW.clamp(minW, math.max(minW, maxW));
        final newH = newW / ratio;
        zoom = (baseWidth / newW).clamp(1.0, 8.0);
        center = Offset(anchor.dx - newW / 2, anchor.dy - newH / 2);
      case _CropDragMode.topRight:
        final anchor = startCrop.bottomLeft;
        final maxW = math.min(
          baseWidth,
          math.min(imgW - anchor.dx, anchor.dy * ratio),
        );
        final candW =
            ((startCrop.width + deltaSrc.dx) +
                (startCrop.height - deltaSrc.dy) * ratio) /
            2;
        final newW = candW.clamp(minW, math.max(minW, maxW));
        final newH = newW / ratio;
        zoom = (baseWidth / newW).clamp(1.0, 8.0);
        center = Offset(anchor.dx + newW / 2, anchor.dy - newH / 2);
      case _CropDragMode.bottomLeft:
        final anchor = startCrop.topRight;
        final maxW = math.min(
          baseWidth,
          math.min(anchor.dx, (imgH - anchor.dy) * ratio),
        );
        final candW =
            ((startCrop.width - deltaSrc.dx) +
                (startCrop.height + deltaSrc.dy) * ratio) /
            2;
        final newW = candW.clamp(minW, math.max(minW, maxW));
        final newH = newW / ratio;
        zoom = (baseWidth / newW).clamp(1.0, 8.0);
        center = Offset(anchor.dx - newW / 2, anchor.dy + newH / 2);
      case _CropDragMode.right:
        final anchorX = startCrop.left;
        final maxW = math.min(baseWidth, imgW - anchorX);
        final newW = (startCrop.width + deltaSrc.dx).clamp(
          minW,
          math.max(minW, maxW),
        );
        final newH = newW / ratio;
        zoom = (baseWidth / newW).clamp(1.0, 8.0);
        center = Offset(
          anchorX + newW / 2,
          startCrop.center.dy.clamp(newH / 2, imgH - newH / 2),
        );
      case _CropDragMode.left:
        final anchorX = startCrop.right;
        final maxW = math.min(baseWidth, anchorX);
        final newW = (startCrop.width - deltaSrc.dx).clamp(
          minW,
          math.max(minW, maxW),
        );
        final newH = newW / ratio;
        zoom = (baseWidth / newW).clamp(1.0, 8.0);
        center = Offset(
          anchorX - newW / 2,
          startCrop.center.dy.clamp(newH / 2, imgH - newH / 2),
        );
      case _CropDragMode.bottom:
        final anchorY = startCrop.top;
        final minH = minW / ratio;
        final maxH = math.min(baseWidth / ratio, imgH - anchorY);
        final newH = (startCrop.height + deltaSrc.dy).clamp(
          minH,
          math.max(minH, maxH),
        );
        final newW = newH * ratio;
        zoom = (baseWidth / newW).clamp(1.0, 8.0);
        center = Offset(
          startCrop.center.dx.clamp(newW / 2, imgW - newW / 2),
          anchorY + newH / 2,
        );
      case _CropDragMode.top:
        final anchorY = startCrop.bottom;
        final minH = minW / ratio;
        final maxH = math.min(baseWidth / ratio, anchorY);
        final newH = (startCrop.height - deltaSrc.dy).clamp(
          minH,
          math.max(minH, maxH),
        );
        final newW = newH * ratio;
        zoom = (baseWidth / newW).clamp(1.0, 8.0);
        center = Offset(
          startCrop.center.dx.clamp(newW / 2, imgW - newW / 2),
          anchorY - newH / 2,
        );
      case _CropDragMode.move:
        center = startCenter + deltaSrc;
    }
    center = crop.center;
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final rect = crop;
      final int w;
      final int h;
      if (widget.isBackdrop) {
        w = math
            .min(widget.maxExportWidth, (rect.width / 16).floor() * 16)
            .clamp(16, widget.maxExportWidth);
        h = w * 9 ~/ 16;
      } else if ((widget.aspectRatio - 2 / 3).abs() < 1e-6) {
        // Never upscale low resolution source; export a true 2:3 PNG.
        w = math
            .min(widget.maxExportWidth, (rect.width / 2).floor() * 2)
            .clamp(2, widget.maxExportWidth);
        h = w * 3 ~/ 2;
      } else {
        w = math
            .min(widget.maxExportWidth, rect.width.floor())
            .clamp(2, widget.maxExportWidth);
        h = math.max(2, (w / widget.aspectRatio).round());
      }
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image!,
        rect,
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final output = await picture.toImage(w, h);
      picture.dispose();
      final bytes = await output.toByteData(format: ui.ImageByteFormat.png);
      output.dispose();
      if (mounted) {
        Navigator.pop(context, <String, Object>{
          'bytes': bytes!.buffer.asUint8List(),
          'crop': {
            'rect': [rect.left, rect.top, rect.width, rect.height],
            'decodedWidth': image!.width,
            'decodedHeight': image!.height,
          },
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = 'export';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final minWarnW = widget.isBackdrop ? 640 : 400;
    final minWarnH = widget.isBackdrop ? 360 : 600;
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        title: Text(
          widget.isBackdrop
              ? context.l10n.cropBackdrop
              : context.l10n.cropPoster,
        ),
        leading: IconButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                context.l10n.cropHint,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: image == null
                  ? ColoredBox(
                      color: const Color(0xff141618),
                      child: Center(
                        child: error != null
                            ? Text(
                                error == 'decode'
                                    ? context.l10n.imageDecodeFailed
                                    : context.l10n.cropFailed,
                                style: const TextStyle(color: Colors.white70),
                              )
                            : const CircularProgressIndicator(),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, bounds) {
                        final geom = _layout(bounds);
                        return MouseRegion(
                          cursor: _cursor,
                          onHover: (event) {
                            if (_dragging) return;
                            final next = _cursorForMode(
                              _hitTestMode(event.localPosition, geom.cropRect),
                            );
                            if (next != _cursor) {
                              setState(() => _cursor = next);
                            }
                          },
                          child: Listener(
                            onPointerSignal: (event) {
                              if (event is PointerScrollEvent) {
                                _zoom(
                                  zoom * math.exp(-event.scrollDelta.dy / 600),
                                );
                              }
                            },
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onScaleStart: (d) {
                                initialZoom = zoom;
                                startCrop = crop;
                                startCenter = startCrop.center;
                                startFocal = d.localFocalPoint;
                                _dragMode = d.pointerCount > 1
                                    ? _CropDragMode.move
                                    : (_hitTestMode(
                                            d.localFocalPoint,
                                            geom.cropRect,
                                          ) ??
                                          _CropDragMode.move);
                                setState(() {
                                  _dragging = true;
                                  _cursor = _cursorForMode(_dragMode);
                                });
                              },
                              onScaleUpdate: (d) {
                                setState(() {
                                  final deltaSrc =
                                      (d.localFocalPoint - startFocal) /
                                      geom.scale;
                                  if (d.pointerCount > 1 ||
                                      (d.scale - 1.0).abs() > 0.001) {
                                    zoom = (initialZoom * d.scale).clamp(1, 8);
                                    center = startCenter + deltaSrc;
                                    center = crop.center;
                                  } else {
                                    _applyResize(_dragMode, deltaSrc);
                                  }
                                });
                              },
                              onScaleEnd: (_) {
                                setState(() => _dragging = false);
                              },
                              child: CustomPaint(
                                key: const ValueKey('poster-crop-canvas'),
                                size: Size(bounds.maxWidth, bounds.maxHeight),
                                painter: _CropPainter(
                                  image!,
                                  geom.imageRect,
                                  geom.cropRect,
                                  showGrid: _dragging,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            ColoredBox(
              color: colors.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (image != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Slider(
                        value: zoom,
                        min: 1,
                        max: 8,
                        onChanged: saving ? null : _zoom,
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        error == 'decode'
                            ? context.l10n.imageDecodeFailed
                            : context.l10n.cropFailed,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                  if (image != null &&
                      (image!.width < minWarnW || image!.height < minWarnH))
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        context.l10n.lowResImage,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: UniformActionBar(
                      children: [
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: colors.onSurface,
                          ),
                          onPressed: saving
                              ? null
                              : () => Navigator.pop(context),
                          child: Text(context.l10n.cancel),
                        ),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colors.onSurface,
                            side: BorderSide(color: colors.outline),
                          ),
                          onPressed: saving || image == null
                              ? null
                              : () => setState(() {
                                  zoom = 1;
                                  center = Offset(
                                    image!.width / 2,
                                    image!.height / 2,
                                  );
                                }),
                          child: Text(context.l10n.reset),
                        ),
                        FilledButton(
                          onPressed: saving || image == null ? null : _save,
                          child: Text(
                            saving
                                ? context.l10n.saving
                                : context.l10n.confirmSave,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.imageRect, this.frame, {this.showGrid = false});
  final ui.Image image;
  final Rect imageRect, frame;
  final bool showGrid;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xff141618), BlendMode.src);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      imageRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: .62));

    if (showGrid) {
      final gridPaint = Paint()
        ..color = Colors.white.withValues(alpha: .35)
        ..strokeWidth = 1;
      for (var i = 1; i <= 2; i++) {
        final gx = frame.left + frame.width * i / 3;
        final gy = frame.top + frame.height * i / 3;
        canvas.drawLine(
          Offset(gx, frame.top),
          Offset(gx, frame.bottom),
          gridPaint,
        );
        canvas.drawLine(
          Offset(frame.left, gy),
          Offset(frame.right, gy),
          gridPaint,
        );
      }
    }

    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Draw 4 corner L-handles and 4 midpoint edge handles so users can resize
    // the crop box intuitively from any side or corner.
    final handlePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.square;
    final cornerLen = math.min(
      18.0,
      math.min(frame.width, frame.height) * 0.25,
    );

    void drawCorner(Offset c, double dx, double dy) {
      final path = Path()
        ..moveTo(c.dx + dx * cornerLen, c.dy)
        ..lineTo(c.dx, c.dy)
        ..lineTo(c.dx, c.dy + dy * cornerLen);
      canvas.drawPath(path, handlePaint);
    }

    drawCorner(frame.topLeft, 1, 1);
    drawCorner(frame.topRight, -1, 1);
    drawCorner(frame.bottomLeft, 1, -1);
    drawCorner(frame.bottomRight, -1, -1);

    final edgeLen = math.min(16.0, math.min(frame.width, frame.height) * 0.2);
    if (frame.width >= 60) {
      final cx = frame.center.dx;
      canvas.drawLine(
        Offset(cx - edgeLen / 2, frame.top),
        Offset(cx + edgeLen / 2, frame.top),
        handlePaint,
      );
      canvas.drawLine(
        Offset(cx - edgeLen / 2, frame.bottom),
        Offset(cx + edgeLen / 2, frame.bottom),
        handlePaint,
      );
    }
    if (frame.height >= 60) {
      final cy = frame.center.dy;
      canvas.drawLine(
        Offset(frame.left, cy - edgeLen / 2),
        Offset(frame.left, cy + edgeLen / 2),
        handlePaint,
      );
      canvas.drawLine(
        Offset(frame.right, cy - edgeLen / 2),
        Offset(frame.right, cy + edgeLen / 2),
        handlePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.imageRect != imageRect ||
      old.frame != frame ||
      old.image != image ||
      old.showGrid != showGrid;
}

@Preview(name: '封面裁剪操作', size: Size(390, 720))
Widget cropPreview() => MaterialApp(
  home: FutureBuilder<Uint8List>(
    future: _previewImage(),
    builder: (context, snapshot) => snapshot.hasData
        ? PosterCropPage(bytes: snapshot.data!)
        : const Center(child: CircularProgressIndicator()),
  ),
);

Future<Uint8List> _previewImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const rect = Rect.fromLTWH(0, 0, 1000, 700);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xff35647c), Color(0xffdfaa65)],
      ).createShader(rect),
  );
  canvas.drawCircle(
    const Offset(650, 280),
    180,
    Paint()..color = const Color(0xfff7e0b4),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(1000, 700);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}
