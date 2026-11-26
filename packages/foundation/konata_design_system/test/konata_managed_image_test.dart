import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

void main() {
  test('目标宽度按档位向上规整并服从解码上限', () {
    expect(quantizeKonataImageWidth(193), 256);
    expect(quantizeKonataImageWidth(960), 960);
    expect(quantizeKonataImageWidth(961, maxWidth: 1000), 1000);
    expect(quantizeKonataImageWidth(9000), 3840);
  });

  test('缩略图缓存命中后调整淘汰顺序并过滤超大图', () {
    final lru = KonataThumbnailByteLru(maxEntries: 2, maxBytesPerEntry: 2);
    final image = Uint8List.fromList([1, 2]);
    lru.put('海报', image);
    lru.put('剧照', image);
    expect(lru.get('海报'), same(image));

    lru.put('背景', image);
    lru.put('原图', Uint8List(3));
    expect(lru.get('剧照'), isNull);
    expect(lru.get('原图'), isNull);
    expect(lru.get('海报'), same(image));
    expect(lru.get('背景'), same(image));

    lru.clear();
    expect(lru.get('背景'), isNull);
  });
  for (final resized in [false, true]) {
    testWidgets('解码失败后同键可重新加载，缩放模式=$resized', (tester) async {
      await tester.runAsync(() async {
        final lru = KonataThumbnailByteLru();
        final broken = Uint8List.fromList([0, 1, 2, 3]);
        final valid = Uint8List.fromList([
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          0x00,
          0x00,
          0x00,
          0x0D,
          0x49,
          0x48,
          0x44,
          0x52,
          0x00,
          0x00,
          0x00,
          0x01,
          0x00,
          0x00,
          0x00,
          0x01,
          0x08,
          0x06,
          0x00,
          0x00,
          0x00,
          0x1F,
          0x15,
          0xC4,
          0x89,
          0x00,
          0x00,
          0x00,
          0x0A,
          0x49,
          0x44,
          0x41,
          0x54,
          0x78,
          0x9C,
          0x63,
          0x00,
          0x01,
          0x00,
          0x00,
          0x05,
          0x00,
          0x01,
          0x0D,
          0x0A,
          0x2D,
          0xB4,
          0x00,
          0x00,
          0x00,
          0x00,
          0x49,
          0x45,
          0x4E,
          0x44,
          0xAE,
          0x42,
          0x60,
          0x82,
        ]);
        var calls = 0;
        final base = KonataManagedImageProvider(
          'isolated-decode-$resized',
          loader: (_, {required targetWidth, variantKey}) async {
            calls++;
            return calls == 1 ? broken : valid;
          },
          targetWidth: 1,
          byteLru: lru,
          applyDecodeWidthCap: !resized,
        );
        final ImageProvider provider = resized
            ? ResizeImage(base, width: 1)
            : base;
        final key = await base.obtainKey(ImageConfiguration.empty);
        final other = Uint8List.fromList([42]);
        lru.put('unrelated', other);
        Future<Object?> resolve() async {
          final result = Completer<Object?>();
          final stream = provider.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener(
            (info, _) {
              if (!result.isCompleted) result.complete(null);
              info.dispose();
            },
            onError: (error, _) {
              if (!result.isCompleted) result.complete(error);
            },
          );
          stream.addListener(listener);
          try {
            return await result.future.timeout(const Duration(seconds: 5));
          } finally {
            stream.removeListener(listener);
          }
        }

        try {
          expect(await resolve(), isNotNull);
          await Future<void>.delayed(Duration.zero);
          expect(calls, 1);
          expect(lru.get(key), isNull, reason: '损坏字节不得滞留热点缓存');
          expect(lru.get('unrelated'), same(other));

          expect(await resolve(), isNull);
          expect(calls, 2);
          expect(lru.get(key), same(valid));
          await provider.evict();
          expect(await resolve(), isNull);
          expect(calls, 2, reason: '正常编码字节仍可复用');
        } finally {
          await provider.evict();
          lru.clear();
        }
      });
    });
  }
  test('迟到的解码失败不驱逐同键已替换字节', () {
    final lru = KonataThumbnailByteLru();
    final old = Uint8List.fromList([1]);
    final next = Uint8List.fromList([2]);
    lru.put('key', old);
    lru.put('key', next);
    lru.evictIfSame('key', old);
    expect(lru.get('key'), same(next));
    lru.evictIfSame('key', next);
    expect(lru.get('key'), isNull);
  });
}
