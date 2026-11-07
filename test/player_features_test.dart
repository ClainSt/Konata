import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:ccplayer/core/track_preferences.dart';
import 'package:ccplayer/core/playback_probe.dart';
import 'package:ccplayer/core/player_fullscreen.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/timeline_preview.dart';
import 'package:ccplayer/ui/app_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'audio quality never outranks main content, language or decoder support',
    () {
      const main = AudioTrack(
        '1',
        'Main',
        'jpn',
        codec: 'aac',
        isDefault: true,
      );
      const commentary = AudioTrack(
        '2',
        'Audio Commentary',
        'jpn',
        codec: 'flac',
      );
      const english = AudioTrack('3', 'English dub', 'eng', codec: 'flac');
      const truehd = AudioTrack('4', 'Main', 'ja', codec: 'truehd');
      expect(TrackPreferences.audio([main, commentary]), main);
      expect(TrackPreferences.audio([main, english]), main);
      expect(
        TrackPreferences.audio([main, truehd], supportedCodecs: {'aac'}),
        main,
      );
      expect(
        TrackPreferences.audio(
          [main, truehd],
          supportedCodecs: {'aac', 'truehd'},
        ),
        truehd,
      );
      expect(
        TrackPreferences.audio([truehd], supportedCodecs: {'aac'}),
        isNull,
      );
      expect(TrackPreferences.audio([commentary]), commentary);
    },
  );
  test(
    'clipped opening chapter starts at the first playable position',
    () async {
      final probe = PlaybackProbe(
        (key) async => switch (key) {
          'chapter-list/count' => '1',
          'chapter-list/0/time' => '-0.083000',
          'chapter-list/0/title' => 'Chapter 02',
          _ => '',
        },
      );
      final chapters = await probe.chapters();
      expect(chapters.single.start, Duration.zero);
      expect(chapters.single.title, 'Chapter 02');
    },
  );
  test('subtitle preferences detect scripts and do not require Japanese', () {
    const simplified = SubtitleTrack('1', '简日双语 ASS', 'zho');
    const traditional = SubtitleTrack('2', 'CHT', 'chi');
    const japanese = SubtitleTrack('3', null, 'jpn');
    expect(
      TrackPreferences.subtitle([traditional, japanese, simplified]),
      simplified,
    );
    expect(TrackPreferences.subtitle([traditional, simplified]), simplified);
    expect(TrackPreferences.subtitle([traditional]), traditional);
    expect(TrackPreferences.subtitle([SubtitleTrack.no()]), isNull);
    expect(
      TrackPreferences.subtitleLanguage('zh-Hans', null),
      SubtitleLanguage.simplified,
    );
    expect(
      TrackPreferences.subtitleLanguage(null, 'name.chs.ass'),
      SubtitleLanguage.simplified,
    );
    expect(
      TrackPreferences.subtitleLanguage('zh-Hant', null),
      SubtitleLanguage.traditional,
    );
    expect(
      TrackPreferences.subtitleLanguage('ja', null),
      SubtitleLanguage.japanese,
    );
    expect(
      TrackPreferences.subtitleLanguage('zho', null),
      SubtitleLanguage.chinese,
    );
  });
  test(
    'lossless audio wins over lossy default without treating all DTS as lossless',
    () {
      const aac = AudioTrack('1', null, 'jpn', codec: 'aac', isDefault: true);
      const flac = AudioTrack('2', null, 'jpn', codec: 'flac');
      expect(TrackPreferences.audio([aac, flac]), flac);
      expect(TrackPreferences.audio([aac]), aac);
      expect(
        TrackPreferences.lossless(
          const AudioTrack('3', null, null, codec: 'dts'),
        ),
        false,
      );
      expect(
        TrackPreferences.lossless(
          const AudioTrack('4', 'DTS-HD MA', null, codec: 'dts'),
        ),
        true,
      );
      expect(
        TrackPreferences.lossless(
          const AudioTrack('5', null, null, codec: 'pcm_s24le'),
        ),
        true,
      );
    },
  );
  test(
    'chapters use real timestamps; optional stats fail independently',
    () async {
      final probe = PlaybackProbe(
        (name) async => switch (name) {
          'chapter-list/count' => '3',
          'chapter-list/0/time' => '0',
          'chapter-list/0/title' => 'Intro',
          'chapter-list/1/time' => '67.5',
          'chapter-list/1/title' => 'Chapter 02',
          'chapter-list/2/time' => 'NaN',
          'video-codec' => 'hevc',
          _ => throw StateError('unavailable'),
        },
      );
      final chapters = await probe.chapters();
      expect(chapters.length, 2);
      expect(chapters[1].start, const Duration(milliseconds: 67500));
      expect((await probe.statistics())['video-codec'], 'hevc');
    },
  );
  testWidgets('chapter markers stay centered on phone and desktop tracks', (
    tester,
  ) async {
    for (final size in [const Size(300, 2.4), const Size(700, 36)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: TimelinePreview(
                duration: const Duration(seconds: 100),
                fraction: null,
                width: size.width,
                chapters: const [
                  VideoChapter(0, Duration.zero, 'Start'),
                  VideoChapter(1, Duration(seconds: 67), 'Middle'),
                  VideoChapter(2, Duration(seconds: 100), 'End'),
                ],
                loadFrame: (_) async => null,
              ),
            ),
          ),
        ),
      );
      final timeline = find.byType(TimelinePreview);
      final rect = tester.getRect(timeline);
      final markers = find.descendant(
        of: timeline,
        matching: find.byType(Transform),
      );
      for (final (i, fraction) in [0.0, 0.67, 1.0].indexed) {
        final center = tester.getCenter(markers.at(i));
        expect(center.dx, closeTo(rect.left + rect.width * fraction, 0.01));
        expect(center.dy, closeTo(rect.center.dy, 0.01));
      }
    }
  });

  testWidgets('chapter hover snaps preview to node and labels its time', (
    tester,
  ) async {
    final requested = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 36,
              child: TimelinePreview(
                duration: const Duration(seconds: 100),
                fraction: .675,
                width: 300,
                chapters: const [
                  VideoChapter(1, Duration(seconds: 67), 'Chapter 02'),
                ],
                loadFrame: (position) async {
                  requested.add(position);
                  return null;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(requested.single, const Duration(seconds: 67));
    expect(find.text('Chapter 02'), findsOneWidget);
    expect(find.text('01:07'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('fullscreen hides app navigation and restores it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const CCPlayer(mobile: false));
    await tester.pumpAndSettle();
    expect(find.byType(AppHeader), findsOneWidget);
    playerFullscreen.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(AppHeader), findsNothing);
    playerFullscreen.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(AppHeader), findsOneWidget);
  });
}
