import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ccplayer/core/player_fullscreen.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// The host captures the composed screen and sends Home / task resume at markers.
Future<void> androidDecoderTrials(WidgetTester tester, Player player) async {
  final native = player.platform as NativePlayer;
  Future<void> wait(Duration duration) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < duration) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<Map<String, String>> sample() async {
    return {
      for (final key in [
        'hwdec-current',
        'video-params/pixelformat',
        'video-params/hw-pixelformat',
        'time-pos',
        'frame-drop-count',
        'decoder-frame-drop-count',
        'avsync',
        'pause',
        'current-vo',
      ])
        key: await native.getProperty(key),
    };
  }

  void mark(
    String mode,
    String phase,
    Map<String, String> values,
  ) => debugPrint(
    'DECODER_TRIAL ${jsonEncode({'mode': mode, 'phase': phase, ...values})}',
  );
  for (final mode in ['mediacodec', 'mediacodec-copy', 'no']) {
    await player.pause();
    await native.setProperty('hwdec', mode);
    await native.command(['seek', '51.5', 'absolute+exact']);
    await wait(const Duration(seconds: 2));
    final frame = await sample();
    expect(frame['hwdec-current'], mode);
    expect(double.parse(frame['time-pos']!), closeTo(51.51, 0.06));
    mark(mode, 'frame', frame);
    await wait(const Duration(seconds: 4));
    await native.command(['seek', '5', 'absolute+exact']);
    await wait(const Duration(seconds: 1));
    await player.play();
    mark(mode, 'start', await sample());
    const seconds = int.fromEnvironment(
      'BASELINE_TRIAL_SECONDS',
      defaultValue: 60,
    );
    await wait(const Duration(seconds: seconds));
    mark(mode, 'end', await sample());
    mark(mode, 'background', await sample());
    await wait(const Duration(seconds: 12));
    mark(mode, 'returned', await sample());
    await wait(const Duration(seconds: 3));
    mark(mode, 'after_return', await sample());
    final beforeContinue = player.state.position;
    if (!player.state.playing) await player.play();
    await wait(const Duration(seconds: 3));
    final continued = await sample();
    expect(continued['pause'], 'no');
    expect(
      player.state.position - beforeContinue,
      greaterThan(const Duration(seconds: 1)),
    );
    mark(mode, 'manual_continue', continued);
    await player.pause();
    await native.command(['seek', '51.5', 'absolute+exact']);
    await wait(const Duration(seconds: 2));
    mark(mode, 'restored_frame', await sample());
    await wait(const Duration(seconds: 3));
  }
}

Future<void> windowsScreenTrial(WidgetTester tester, Player player) async {
  Future<void> pumpFor(int seconds) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed.inSeconds < seconds) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  await windowManager.focus();
  final native = player.platform as NativePlayer;
  await native.command(['seek', '51.5', 'absolute+exact']);
  await pumpFor(2);
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer();
  try {
    debugPrint('SCREEN_TRIAL controls');
    await pumpFor(2);
    final rect = tester.getRect(find.byType(Scaffold).first);
    await gesture.moveTo(rect.center);
    await gesture.moveTo(Offset(rect.center.dx, rect.bottom - 20));
    await tester.pump();
    final buttons = find.byIcon(Icons.fullscreen);
    expect(buttons, findsWidgets);
    await tester.tap(buttons.last);
    await pumpFor(2);
    expect(playerFullscreen.value, isTrue);
    debugPrint('SCREEN_TRIAL hide');
    await gesture.moveTo(rect.center);
    await pumpFor(5);
    debugPrint('SCREEN_TRIAL fullscreen_frame');
    await pumpFor(3);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await pumpFor(2);
    expect(playerFullscreen.value, isFalse);
    debugPrint('SCREEN_TRIAL restored');
    await pumpFor(2);
    await player.play();
    await pumpFor(2);
    expect(player.state.position.inMilliseconds, greaterThan(52000));
    debugPrint('SCREEN_TRIAL playback_ok');
  } finally {
    await gesture.removePointer();
  }
}
