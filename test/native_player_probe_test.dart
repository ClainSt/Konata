import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:ccplayer/core/timeline_frames.dart';

void main() {
  final video = Platform.environment['CCPLAYER_TEST_VIDEO'];
  final dll = Platform.environment['CCPLAYER_TEST_MPV'];
  test('native silent decoder extracts a frame without a playback player', () async {
    MediaKit.ensureInitialized(libmpv: dll);
    final frames = TimelineFrames(video!);
    try {
      final image = await frames.frame(const Duration(seconds: 1));
      expect(image, isNotNull);
      expect(image!.length, greaterThan(100));
    } finally { await frames.dispose(); }
  }, skip: video == null || dll == null, timeout: const Timeout(Duration(seconds: 30)));
}
