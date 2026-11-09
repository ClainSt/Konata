import 'dart:async';
import 'package:ccplayer/core/android_audio_focus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ccplayer/audio_focus');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late StreamController<bool> playing;
  late AndroidAudioFocus focus;
  late List<String> calls;
  late int pauses;
  bool granted = true;
  Completer<bool>? pending;
  Future<void> drain() => Future<void>.delayed(Duration.zero);
  Future<void> loss() async {
    final done = Completer<void>();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('loss')),
      (_) => done.complete(),
    );
    await done.future;
  }

  setUp(() {
    playing = StreamController<bool>();
    calls = [];
    pauses = 0;
    granted = true;
    pending = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'request') return pending?.future ?? granted;
      return null;
    });
    focus = AndroidAudioFocus(playing.stream, () async {
      pauses++;
      playing.add(false);
    });
  });
  tearDown(() async {
    await focus.dispose();
    await playing.close();
    messenger.setMockMethodCallHandler(channel, null);
  });
  test('requests only for playback and abandons on pause', () async {
    await drain();
    expect(calls, isEmpty);
    playing.add(true);
    await drain();
    expect(calls, ['request']);
    playing.add(true);
    await drain();
    expect(calls, ['request']);
    playing.add(false);
    await drain();
    expect(calls.last, 'abandon');
  });
  test(
    'focus loss pauses without automatically resuming or stealing focus',
    () async {
      playing.add(true);
      await drain();
      await loss();
      await drain();
      expect(pauses, 1);
      expect(calls.where((x) => x == 'request').length, 1);
      playing.add(true);
      await drain();
      expect(calls.where((x) => x == 'request').length, 2);
    },
  );
  test('a denied request pauses playback', () async {
    granted = false;
    playing.add(true);
    await drain();
    await drain();
    expect(pauses, 1);
    expect(calls.last, 'abandon');
  });

  test(
    'native resume requests focus when Dart playing stream stays paused',
    () async {
      playing.add(true);
      await drain();
      await loss();
      await drain();
      focus.updatePlaying(true);
      await drain();
      expect(calls.where((x) => x == 'request').length, 2);
    },
  );

  test('duplicate native and Dart events keep a pending grant', () async {
    pending = Completer<bool>();
    playing.add(true);
    await drain();
    focus.updatePlaying(true);
    pending!.complete(true);
    await drain();
    expect(calls, ['request']);
  });
  test('closing while request is pending releases a late grant', () async {
    pending = Completer<bool>();
    playing.add(true);
    await drain();
    final closing = focus.dispose();
    pending!.complete(true);
    await closing;
    expect(pauses, 0);
    expect(calls.last, 'abandon');
    expect(playing.hasListener, isFalse);
    final count = calls.length;
    await focus.dispose();
    expect(calls.length, count);
  });
  test(
    'late disposal of previous page cannot abandon the current focus',
    () async {
      playing.add(true);
      await drain();
      final nextPlaying = StreamController<bool>();
      var nextPauses = 0;
      final next = AndroidAudioFocus(nextPlaying.stream, () async {
        nextPauses++;
      });
      try {
        nextPlaying.add(true);
        await drain();
        calls.clear();
        await focus.dispose();
        expect(calls, isEmpty);
        await loss();
        expect(nextPauses, 1);
        expect(pauses, 0);
      } finally {
        await next.dispose();
        await nextPlaying.close();
      }
    },
  );
}
