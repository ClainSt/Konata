import 'dart:async';
import 'package:ccplayer/ui/android_native_video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class _Native implements NativePlayer {
  final calls = <String>[];
  final callbacks = <Future<void> Function()>[];
  final entered = Completer<void>();
  final gate = Completer<void>();
  bool block = true;
  String? failProperty;
  final failure = StateError('synthetic detach failure');
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #disposed) return false;
    if (invocation.memberName == #configuration) {
      return const PlayerConfiguration();
    }
    if (invocation.memberName == #release) return callbacks;
    if (invocation.memberName == #setProperty) {
      calls.add(
        '${invocation.positionalArguments[0]}=${invocation.positionalArguments[1]}',
      );
      if (invocation.positionalArguments[0] == failProperty) {
        return Future<void>.error(failure);
      }
      if (block) {
        block = false;
        entered.complete();
        return gate.future;
      }
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Player implements Player {
  _Player(this.native);
  final _Native native;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #platform) return native;
    if (invocation.memberName == #handle) return Future<int>.value(1);
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final property in ['vo', 'wid']) {
    test(
      'failed $property detachment can fail repeatedly then recover',
      () async {
        final native = _Native()..block = false;
        final output = AndroidNativeVideo(
          _Player(native),
          const VideoControllerConfiguration(),
        );
        await output.initialize();
        native.calls.clear();
        native.failProperty = property;
        for (var attempt = 0; attempt < 2; attempt++) {
          final closing = output.close();
          expect(identical(output.close(), closing), isTrue);
          await expectLater(closing, throwsA(same(native.failure)));
          expect(() => output.rect.addListener(() {}), throwsFlutterError);
        }
        expect(
          native.calls,
          property == 'vo'
              ? ['vo=null', 'vo=null']
              : ['vo=null', 'wid=0', 'vo=null', 'wid=0'],
        );
        native.failProperty = null;
        await native.callbacks.single();
        expect(native.calls.sublist(native.calls.length - 2), [
          'vo=null',
          'wid=0',
        ]);
        final count = native.calls.length;
        await Future.wait([
          output.close(),
          output.close(),
          native.callbacks.single(),
        ]);
        expect(native.calls.length, count);
      },
    );
  }

  testWidgets(
    'releaseAll follows successful detachment and is not replayed on failure',
    (tester) async {
      final native = _Native()..block = false;
      final output = AndroidNativeVideo(
        _Player(native),
        const VideoControllerConfiguration(),
      );
      await output.initialize();
      final channel = MethodChannel(
        'ccplayer/android_surface/${platformViewsRegistry.getNextPlatformViewId() + 1}',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var releases = 0;
      messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'releaseAll');
        expect(native.calls.sublist(native.calls.length - 2), [
          'vo=null',
          'wid=0',
        ]);
        releases++;
        throw PlatformException(code: 'synthetic-release-failure');
      });
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: output.buildSurface),
        ),
      );
      try {
        native.failProperty = 'wid';
        await expectLater(output.close(), throwsA(same(native.failure)));
        expect(
          releases,
          0,
          reason: 'Never release a Surface before detachment',
        );
        native.failProperty = null;
        final closing = output.close();
        await expectLater(closing, throwsA(isA<PlatformException>()));
        expect(releases, 1);
        expect(identical(output.close(), closing), isTrue);
        await expectLater(output.close(), throwsA(isA<PlatformException>()));
        expect(
          releases,
          1,
          reason: 'Native partial release is not safe to replay',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      }
    },
  );

  test('player release after explicit close does not dispose twice', () async {
    final native = _Native()..block = false;
    final output = AndroidNativeVideo(
      _Player(native),
      const VideoControllerConfiguration(),
    );
    await output.initialize();
    expect(native.callbacks, hasLength(1));
    await output.close();
    final detachedCalls = native.calls.length;
    await native.callbacks.single();
    expect(native.calls.length, detachedCalls);
    expect(() => output.rect.addListener(() {}), throwsFlutterError);
  });
  test('concurrent close callers wait for detachment', () async {
    final native = _Native();
    final output = AndroidNativeVideo(
      _Player(native),
      const VideoControllerConfiguration(),
    );
    final first = output.close();
    await native.entered.future;
    var secondDone = false;
    final second = output.close().then((_) => secondDone = true);
    await Future<void>.delayed(Duration.zero);
    final completedBeforeDetach = secondDone;
    native.gate.complete();
    await Future.wait([first, second]);
    expect(completedBeforeDetach, isFalse);
    expect(native.calls, ['vo=null', 'wid=0']);
  });

  test('close waits for initialization and releases notifiers', () async {
    final native = _Native();
    final output = AndroidNativeVideo(
      _Player(native),
      const VideoControllerConfiguration(),
    );
    final initializing = output.initialize();
    await native.entered.future;
    var closed = false;
    final closing = output.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    final completedBeforeInitialization = closed;
    native.gate.complete();
    await initializing;
    await closing;
    expect(completedBeforeInitialization, isFalse);
    expect(() => output.rect.addListener(() {}), throwsFlutterError);
    expect(native.calls.where((value) => value == 'vo=gpu'), isEmpty);
  });
}
