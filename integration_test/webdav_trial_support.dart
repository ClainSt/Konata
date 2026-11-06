import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void record(String event, Map<String, Object?> data) =>
    debugPrint('DAV_TRIAL ${jsonEncode({'event': event, ...data})}');

Future<void> poll(
  WidgetTester tester,
  Future<bool> Function() condition, {
  int seconds = 60,
}) async {
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed.inSeconds >= seconds) {
      throw TimeoutException('playback condition');
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}
