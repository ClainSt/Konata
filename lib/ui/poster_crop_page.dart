import '../l10n/strings.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'uniform_action_bar.dart';
import 'package:flutter/widget_previews.dart';

/// Crop geometry is in source pixels; resize never changes the selected area.
class PosterCropPage extends StatefulWidget {
  const PosterCropPage({super.key, required this.bytes});
  final Uint8List bytes;
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
      math.min(image!.width.toDouble(), image!.height * 2 / 3);
  Rect get crop {
    final w = baseWidth / zoom, h = w * 1.5;
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

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final rect = crop;
      // Never upscale low resolution source; export a true 2:3 PNG.
      final w = math.min(1000, (rect.width / 2).floor() * 2).clamp(2, 1000),
          h = w * 3 ~/ 2;
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.l10n.cropPoster),
      leading: IconButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        icon: const Icon(Icons.close),
      ),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(context.l10n.cropHint),
          ),
          Expanded(
            child: image == null
                ? Center(
                    child: error != null
                        ? Text(
                            error == 'decode'
                                ? context.l10n.imageDecodeFailed
                                : context.l10n.cropFailed,
                          )
                        : const CircularProgressIndicator(),
                  )
                : LayoutBuilder(
                    builder: (context, bounds) {
                      final h = math.max(
                            1.0,
                            math.min(
                              bounds.maxHeight - 32,
                              (bounds.maxWidth - 32) * 1.5,
                            ),
                          ),
                          w = h * 2 / 3;
                      final frame = Rect.fromCenter(
                        center: Offset(
                          bounds.maxWidth / 2,
                          bounds.maxHeight / 2,
                        ),
                        width: w,
                        height: h,
                      );
                      return Listener(
                        onPointerSignal: (event) {
                          if (event is PointerScrollEvent) {
                            _zoom(zoom * math.exp(-event.scrollDelta.dy / 600));
                          }
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: (d) {
                            initialZoom = zoom;
                            startCenter = crop.center;
                            startFocal = d.localFocalPoint;
                          },
                          onScaleUpdate: (d) {
                            setState(() {
                              zoom = (initialZoom * d.scale).clamp(1, 8);
                              center =
                                  startCenter -
                                  (d.localFocalPoint - startFocal) *
                                      (baseWidth / zoom / w);
                              center = crop.center;
                            });
                          },
                          child: CustomPaint(
                            size: Size(bounds.maxWidth, bounds.maxHeight),
                            painter: _CropPainter(image!, crop, frame),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (image != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Slider(
                value: zoom,
                min: 1,
                max: 8,
                onChanged: saving ? null : _zoom,
              ),
            ),
          if (error != null)
            Text(
              error == 'decode'
                  ? context.l10n.imageDecodeFailed
                  : context.l10n.cropFailed,
            ),
          if (image != null && (image!.width < 400 || image!.height < 600))
            Text(context.l10n.lowResImage),
          Padding(
            padding: const EdgeInsets.all(12),
            child: UniformActionBar(
              children: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: Text(context.l10n.cancel),
                ),
                OutlinedButton(
                  onPressed: saving || image == null
                      ? null
                      : () => setState(() {
                          zoom = 1;
                          center = Offset(image!.width / 2, image!.height / 2);
                        }),
                  child: Text(context.l10n.reset),
                ),
                FilledButton(
                  onPressed: saving || image == null ? null : _save,
                  child: Text(
                    saving ? context.l10n.saving : context.l10n.confirmSave,
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

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop, this.frame);
  final ui.Image image;
  final Rect crop, frame;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xff191919), BlendMode.src);
    final scale = frame.width / crop.width;
    final dst = Rect.fromLTWH(
      frame.left - crop.left * scale,
      frame.top - crop.top * scale,
      image.width * scale,
      image.height * scale,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: .65));
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.crop != crop || old.frame != frame || old.image != image;
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
