import 'package:ccplayer/core/playback_probe.dart';
import 'package:ccplayer/ui/playback_inspector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'statistics refresh without loading flicker and stop when closed',
    (tester) async {
      var reads = 0;
      final probe = PlaybackProbe((name) async {
        if (name == 'video-codec') return 'codec-${++reads}';
        return '0';
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackInspector(
              probe: probe,
              position: () => Duration.zero,
              onSeek: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('codec-1'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('codec-2'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(reads, 2);
    },
  );
  test(
    'opaque hardware formats and average bpp never imply screen or component depth',
    () async {
      expect(PlaybackProbe.componentDepth('p010le'), 10);
      expect(PlaybackProbe.componentDepth('p010'), 10);
      expect(PlaybackProbe.componentDepth('yuv420p10'), 10);
      expect(PlaybackProbe.componentDepth('yuv420p10le'), 10);
      expect(PlaybackProbe.componentDepth('nv12'), 8);
      expect(PlaybackProbe.componentDepth('d3d11'), isNull);
      expect(PlaybackProbe.componentDepth('mediacodec'), isNull);
      final probe = PlaybackProbe(
        (name) async => switch (name) {
          'video-params/pixelformat' => 'd3d11',
          'hwdec-current' => 'd3d11va',
          _ => throw StateError('Unavailable'),
        },
      );
      final stats = await probe.statistics();
      expect(stats.containsKey('source-component-depth'), isFalse);
      expect(stats.containsKey('flutter-texture-size'), isFalse);
      expect(stats['hwdec-current'], 'd3d11va');
    },
  );
  test(
    'source format, filtered video size and texture size are separate observations',
    () async {
      final probe = PlaybackProbe(
        (name) async => switch (name) {
          'video-params/pixelformat' => 'yuv420p10le',
          'video-params/w' => '3840',
          'video-out-params/w' => '1920',
          'mpv-version' => 'test-engine',
          _ => throw StateError('Unavailable'),
        },
        textureResolution: () => '1280 × 720',
      );
      final stats = await probe.statistics();
      expect(stats['source-component-depth'], '10');
      expect(stats['video-params/w'], '3840');
      expect(stats['video-out-params/w'], '1920');
      expect(stats['flutter-texture-size'], '1280 × 720');
    },
  );
  testWidgets(
    'read-only statistics show unavailable values and texture size on narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackInspector(
              probe: PlaybackProbe(
                (_) async => throw StateError('Unavailable'),
                textureResolution: () => '333 × 222',
              ),
              position: () => Duration.zero,
              onSeek: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('未知'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Flutter 纹理尺寸'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('333 × 222'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
