import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata/bootstrap/android_platform_bridges.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('媒体封面发送失败后同键重发，成功后正常去重，停止失败可重试', () async {
    const channel = MethodChannel('konata/test_media_delivery');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final adapter = AndroidMediaSessionAdapter(
      channel: channel,
      isSupported: () => true,
    );
    addTearDown(adapter.dispose);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final calls = <MethodCall>[];
    var failUpdate = true;
    var failStop = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'update' && failUpdate) {
        failUpdate = false;
        throw PlatformException(code: 'update_failed');
      }
      if (call.method == 'stop' && failStop) {
        failStop = false;
        throw PlatformException(code: 'stop_failed');
      }
      return null;
    });
    final bytes = Uint8List.fromList([1, 2, 3]);
    Future<void> send() => adapter.syncSession(
      trackId: 'track',
      title: 'track',
      artist: '',
      album: '',
      durationSeconds: 60,
      positionSeconds: 1,
      isPlaying: true,
      coverKey: 'cover',
      coverBytes: bytes,
    );
    await send();
    await send();
    await send();
    expect(calls, hasLength(2));
    for (final call in calls) {
      expect((call.arguments as Map<Object?, Object?>)['coverBytes'], bytes);
    }
    await adapter.stopSession();
    await adapter.stopSession();
    await adapter.stopSession();
    expect(calls.map((c) => c.method), ['update', 'update', 'stop', 'stop']);
    await send();
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['coverBytes'],
      bytes,
    );
  });

  test('在途媒体更新完成后才执行停止与下一曲发布', () async {
    const channel = MethodChannel('konata/test_media_delivery_order');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final adapter = AndroidMediaSessionAdapter(
      channel: channel,
      isSupported: () => true,
    );
    addTearDown(adapter.dispose);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final firstStarted = Completer<void>();
    final firstRelease = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'update') {
        final args = call.arguments as Map<Object?, Object?>;
        calls.add(args['title'] as String);
        if (args['title'] == 'A') {
          firstStarted.complete();
          await firstRelease.future;
        }
      } else {
        calls.add(call.method);
      }
      return null;
    });
    Future<void> send(String track) => adapter.syncSession(
      trackId: track,
      title: track,
      artist: '',
      album: '',
      durationSeconds: 60,
      positionSeconds: 1,
      isPlaying: true,
      coverKey: track,
      coverBytes: Uint8List.fromList([1, 2, 3]),
    );
    final a = send('A');
    await firstStarted.future;
    final stop = adapter.stopSession();
    final b = send('B');
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['A']);
    firstRelease.complete();
    await Future.wait([a, stop, b]);
    expect(calls, ['A', 'stop', 'B']);
  });
}
