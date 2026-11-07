import 'dart:async';
import 'dart:typed_data';

import 'package:ccplayer/core/timeline_frames.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

// Control native completion order without a network or a real decoder.
class PreviewDecoder implements NativePlayer {
  int disposals = 0;
  int screenshots = 0;
  final seeks = <Duration>[];
  final screenshotStarted = Completer<void>();
  final openStarted = Completer<void>();
  Completer<void>? pendingOpen;
  Completer<Uint8List?>? pendingScreenshot;
  int imageBytes = 64;

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) async {
    if (!openStarted.isCompleted) openStarted.complete();
    await pendingOpen?.future;
  }

  @override
  Future<void> seek(Duration position, {bool synchronized = true}) async {
    seeks.add(position);
  }

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {}
  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async =>
      property == 'seeking' ? 'no' : '${seeks.last.inMilliseconds / 1000}';
  @override
  Future<Uint8List?> screenshot({
    String? format = 'image/jpeg',
    bool synchronized = true,
    bool includeLibassSubtitles = false,
  }) async {
    screenshots++;
    if (!screenshotStarted.isCompleted) screenshotStarted.complete();
    return pendingScreenshot?.future ?? Uint8List(imageBytes);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late PreviewDecoder decoder;
  late TimelineFrames frames;
  setUp(() {
    decoder = PreviewDecoder();
    frames = TimelineFrames(
      'fixture',
      createDecoder: () => Player(platformPlayer: decoder),
    );
  });
  tearDown(() => frames.dispose());

  test(
    'closing starts decoder disposal before a pending screenshot completes',
    () async {
      decoder.pendingScreenshot = Completer<Uint8List?>();
      final request = frames.frame(Duration.zero);
      await decoder.screenshotStarted.future;
      final closing = frames.dispose();
      await Future<void>.delayed(Duration.zero);
      // Complete even if the assertion fails so teardown cannot hang.
      final disposalsBeforeCompletion = decoder.disposals;
      decoder.pendingScreenshot!.complete(Uint8List(64));
      final image = await request;
      await closing;
      expect(disposalsBeforeCompletion, 1);
      expect(image, isNull);
      expect(await frames.frame(Duration.zero), isNull);
      await frames.dispose();
      expect(decoder.disposals, 1);
    },
  );

  test('a newer cached request invalidates an in-flight screenshot', () async {
    final cached = await frames.frame(Duration.zero);
    decoder.pendingScreenshot = Completer<Uint8List?>();
    final pending = frames.frame(const Duration(seconds: 1));
    // Drain the immediate property/open/seek futures.
    await Future<void>.delayed(Duration.zero);
    expect(decoder.screenshots, 2);
    expect(await frames.frame(Duration.zero), same(cached));
    decoder.pendingScreenshot!.complete(Uint8List(64));
    expect(await pending, isNull);
  });

  test(
    'encoded frame cache evicts least recently used data above 8 MiB',
    () async {
      decoder.imageBytes = 3 * 1024 * 1024;
      await frames.frame(Duration.zero);
      await frames.frame(const Duration(seconds: 1));
      await frames.frame(Duration.zero); // Make zero the most recent.
      await frames.frame(const Duration(seconds: 2));
      await frames.frame(Duration.zero);
      expect(decoder.screenshots, 3);
      await frames.frame(const Duration(seconds: 1));
      expect(decoder.screenshots, 4);
    },
  );

  test('small frames still obey the 24-frame limit', () async {
    for (var i = 0; i < 25; i++) {
      await frames.frame(Duration(seconds: i));
    }
    await frames.frame(const Duration(seconds: 1));
    expect(decoder.screenshots, 25);
    await frames.frame(Duration.zero);
    expect(decoder.screenshots, 26);
  });

  test(
    'closing during open prevents subsequent seeking and decoding',
    () async {
      decoder.pendingOpen = Completer<void>();
      final request = frames.frame(Duration.zero);
      await decoder.openStarted.future;
      final closing = frames.dispose();
      decoder.pendingOpen!.complete();
      expect(await request, isNull);
      await closing;
      expect(decoder.seeks, isEmpty);
      expect(decoder.screenshots, 0);
      expect(decoder.disposals, 1);
    },
  );

  test('a single oversized image is not retained in the frame cache', () async {
    decoder.imageBytes = 8 * 1024 * 1024 + 1;
    expect(await frames.frame(Duration.zero), isNotNull);
    await frames.frame(Duration.zero);
    expect(decoder.screenshots, 2);
  });

  test('queued preview requests decode only the newest position', () async {
    decoder.pendingOpen = Completer<void>();
    final first = frames.frame(Duration.zero);
    await decoder.openStarted.future;
    final requests = [
      for (var i = 1; i <= 20; i++) frames.frame(Duration(seconds: i)),
    ];
    decoder.pendingOpen!.complete();
    expect(await first, isNull);
    final images = await Future.wait(requests);
    expect(images.take(19), everyElement(isNull));
    expect(images.last, isNotNull);
    expect(decoder.seeks, [const Duration(seconds: 20)]);
  });
}
