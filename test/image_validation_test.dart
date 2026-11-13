import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:ccplayer/core/image_store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff8855bb), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [(1, 1), (1, 256), (256, 1), (640, 480)]) {
    test(
      'validation decodes a bounded thumbnail without upscaling $size',
      () async {
        final bytes = await png(size.$1, size.$2);
        final created = <ui.Size>[];
        var released = 0;
        final onCreate = ui.Image.onCreate;
        final onDispose = ui.Image.onDispose;
        ui.Image.onCreate = (image) {
          created.add(ui.Size(image.width.toDouble(), image.height.toDouble()));
          onCreate?.call(image);
        };
        ui.Image.onDispose = (image) {
          released++;
          onDispose?.call(image);
        };
        try {
          await ImageStore.validate(bytes);
          expect(created, hasLength(1));
          expect(created.single.width, lessThanOrEqualTo(size.$1.clamp(1, 64)));
          expect(
            created.single.height,
            lessThanOrEqualTo(size.$2.clamp(1, 64)),
          );
          expect(released, 1);
        } finally {
          ui.Image.onCreate = onCreate;
          ui.Image.onDispose = onDispose;
        }
      },
    );
  }
  test('validation still rejects corrupt image data', () async {
    await expectLater(
      ImageStore.validate(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
  });

  test(
    'display keeps the aspect ratio when only a large image is available',
    () async {
      final original = await png(1200, 1800);
      final resized = await ImageStore.fitForDisplay(original, 160);
      expect(await ImageStore.dimensions(resized), (width: 160, height: 240));
      expect(resized.length, lessThan(original.length));
      expect(await ImageStore.fitForDisplay(resized, 320), same(resized));
    },
  );

  test('TMDB display sizes cap cards while allowing full background width', () {
    const url = 'https://image.tmdb.org/t/p/original/fixture.jpg';
    expect(
      ImageStore.tmdbDisplayUrl(url, 510, backdrop: false),
      contains('/w300/'),
    );
    expect(
      ImageStore.tmdbDisplayUrl(url, 270, backdrop: false, poster: true),
      contains('/w342/'),
    );
    expect(
      ImageStore.tmdbDisplayUrl(url, 1510, backdrop: true),
      contains('/original/'),
    );
  });
}
