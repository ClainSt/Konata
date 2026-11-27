import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

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
  test('缩略图按总字节预算淘汰，命中刷新顺序及替换计费准确', () {
    final lru = KonataThumbnailByteLru(
      maxEntries: 4,
      maxBytesPerEntry: 8,
      maxTotalBytes: 10,
    );
    final a = Uint8List(4);
    final b = Uint8List(4);
    final c = Uint8List(4);
    lru.put('a', a);
    lru.put('b', b);
    expect(lru.totalBytes, 8);
    expect(lru.get('a'), same(a));
    lru.put('c', c);
    expect(lru.get('b'), isNull);
    expect(lru.entryCount, 2);
    expect(lru.totalBytes, 8);
    final smaller = Uint8List(1);
    lru.put('a', smaller);
    expect(lru.totalBytes, 5);
    lru.evictIfSame('a', a);
    expect(lru.totalBytes, 5);
    expect(lru.get('a'), same(smaller));
    lru.evictIfSame('a', smaller);
    expect(lru.totalBytes, 4);
    expect(lru.entryCount, 1);
    lru.put('c', Uint8List(9));
    expect(lru.get('c'), same(c));
    expect(lru.totalBytes, 4);
    lru.clear();
    expect(lru.totalBytes, 0);
    expect(lru.entryCount, 0);
  });

  test('底层缓冲区视图保守计费，超预算及零容量不缓存', () {
    final lru = KonataThumbnailByteLru(maxBytesPerEntry: 16, maxTotalBytes: 8);
    final smallView = Uint8List.sublistView(Uint8List(32), 0, 1);
    lru.put('view', smallView);
    expect(lru.get('view'), isNull);
    expect(lru.totalBytes, 0);
    final valid = Uint8List.sublistView(Uint8List(8), 0, 1);
    lru.put('valid', valid);
    expect(lru.totalBytes, 8);
    expect(lru.get('valid'), same(valid));
    final disabled = KonataThumbnailByteLru(maxTotalBytes: 0);
    disabled.put('a', Uint8List(1));
    expect(disabled.entryCount, 0);
    expect(disabled.totalBytes, 0);
  });

  test('180 张 512 KiB 缩略图连续加载不突破默认 32 MiB 字节预算', () {
    final lru = KonataThumbnailByteLru();
    var peak = 0;
    for (var i = 0; i < 180; i++) {
      lru.put(i, Uint8List(512 * 1024));
      if (lru.totalBytes > peak) peak = lru.totalBytes;
      expect(lru.totalBytes, lessThanOrEqualTo(32 * 1024 * 1024));
    }
    expect(peak, 32 * 1024 * 1024);
    expect(lru.entryCount, 64);
    expect(lru.get(115), isNull);
    expect(lru.get(116), isNotNull);
    expect(lru.get(179), isNotNull);
    lru.clear();
    expect(lru.totalBytes, 0);
  });

  testWidgets('首帧观察器在异步读取结束后释放自己的图像引用', (tester) async {
    final bytes = Uint8List.fromList([
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
    final token = Object();
    Future<Uint8List?> load(
      String url, {
      required int targetWidth,
      Object? variantKey,
    }) async => bytes;
    final base = KonataManagedImageProvider(
      'isolated-observer',
      loader: load,
      targetWidth: 1,
      loaderToken: token,
    );
    final provider = ResizeImage(base, width: 1);
    late ImageStream stream;
    late ImageStreamListener keeper;
    await tester.runAsync(() async {
      final ready = Completer<void>();
      keeper = ImageStreamListener((info, _) {
        info.dispose();
        if (!ready.isCompleted) ready.complete();
      }, onError: (error, stack) => ready.completeError(error, stack));
      stream = provider.resolve(ImageConfiguration.empty);
      stream.addListener(keeper);
      await ready.future.timeout(const Duration(seconds: 5));
    });
    final release = Completer<void>();
    ui.Image? borrowed;
    ui.Image? independent;
    var calls = 0;
    try {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: KonataManagedImage(
            url: 'isolated-observer',
            loader: load,
            loaderToken: token,
            explicitTargetWidth: 1,
            onImageResolved: (image, _) async {
              calls++;
              borrowed = image;
              independent = image.clone();
              await release.future;
              expect(image.debugDisposed, isFalse);
            },
          ),
        ),
      );
      expect(calls, 1);
      expect(borrowed!.debugDisposed, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(borrowed!.debugDisposed, isFalse);
      release.complete();
      await tester.pump();
      expect(borrowed!.debugDisposed, isTrue);
      expect(independent!.debugDisposed, isFalse);
      expect(calls, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      independent?.dispose();
      stream.removeListener(keeper);
      await provider.evict();
    }
  });

  testWidgets('清理期间进行的缩略图加载仍可解码但不回填旧字节', (tester) async {
    await tester.runAsync(() async {
      final lru = KonataThumbnailByteLru();
      final bytes = Uint8List.fromList([
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
      final entered = Completer<void>();
      final release = Completer<Uint8List>();
      var calls = 0;
      final provider = KonataManagedImageProvider(
        'isolated-generation',
        loader: (_, {required targetWidth, variantKey}) async {
          calls++;
          if (calls == 1) {
            entered.complete();
            return release.future;
          }
          return bytes;
        },
        targetWidth: 1,
        byteLru: lru,
      );
      final key = await provider.obtainKey(ImageConfiguration.empty);
      Future<void> resolve({bool clearDuringLoad = false}) async {
        final ready = Completer<void>();
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener(
          (info, _) {
            info.dispose();
            if (!ready.isCompleted) ready.complete();
          },
          onError: (error, stack) {
            if (!ready.isCompleted) ready.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        try {
          if (clearDuringLoad) {
            await entered.future.timeout(const Duration(seconds: 5));
            lru.clear();
            release.complete(bytes);
          }
          await ready.future.timeout(const Duration(seconds: 5));
        } finally {
          stream.removeListener(listener);
        }
      }

      try {
        await resolve(clearDuringLoad: true);
        expect(lru.entryCount, 0);
        expect(lru.totalBytes, 0);
        await provider.evict();
        await resolve();
        expect(calls, 2);
        expect(lru.get(key), same(bytes));
      } finally {
        if (!release.isCompleted) release.complete(bytes);
        await provider.evict();
        lru.clear();
      }
    });
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
