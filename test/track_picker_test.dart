import 'dart:async';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/track_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  for (final mode in ['audio', 'subtitle', 'import']) {
    testWidgets('rapid $mode selection submits only once before rebuild', (
      tester,
    ) async {
      final pending = Completer<void>();
      var calls = 0;
      Future<void> select() async {
        calls++;
        await pending.future;
      }

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: TrackPicker(
              subtitles: mode != 'audio',
              selectedId: 'auto',
              audioTracks: const [AudioTrack('1', 'Japanese', 'jpn')],
              subtitleTracks: const [SubtitleTrack('1', 'English', 'eng')],
              onAudio: (_) => select(),
              onSubtitle: (_) => select(),
              onImport: () async {
                await select();
                return false;
              },
            ),
          ),
        ),
      );
      final tile = mode == 'import'
          ? find.widgetWithIcon(ListTile, Icons.file_open_outlined)
          : find.byKey(ValueKey('$mode-track-1'));
      await tester.tap(tile);
      await tester.tap(tile);
      final submitted = calls;
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await tester.pump();
      expect(submitted, 1);
      expect(tester.takeException(), isNull);
    });
  }
  for (final traditional in [false, true]) {
    for (final subtitles in [false, true]) {
      testWidgets(
        'track picker localizes choices, deduplicates and selects, hant=$traditional subtitles=$subtitles',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(320, 640));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          String? chosen;
          await tester.pumpWidget(
            MaterialApp(
              locale: traditional
                  ? const Locale.fromSubtags(
                      languageCode: 'zh',
                      scriptCode: 'Hant',
                    )
                  : const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.5)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => TrackPicker(
                        subtitles: subtitles,
                        selectedId: '1',
                        audioTracks: [
                          AudioTrack.auto(),
                          AudioTrack.auto(),
                          AudioTrack.no(),
                          const AudioTrack('1', '日本語', 'ja', codec: 'FLAC'),
                        ],
                        subtitleTracks: [
                          SubtitleTrack.no(),
                          SubtitleTrack.no(),
                          SubtitleTrack.auto(),
                          const SubtitleTrack('1', '日本語', 'ja', codec: 'ASS'),
                        ],
                        onAudio: (track) async {
                          chosen = track.id;
                        },
                        onSubtitle: (track) async {
                          chosen = track.id;
                        },
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(find.text(traditional ? '自動選擇' : 'Auto'), findsNothing);
          expect(
            find.text(
              subtitles
                  ? (traditional ? '日語 · ass · 內封' : 'Japanese · ass · Muxed')
                  : '日本語',
            ),
            findsOneWidget,
          );
          final prefix = subtitles ? 'subtitle' : 'audio';
          final off = find.byKey(ValueKey('$prefix-track-no'));
          expect(off, findsOneWidget);
          expect(
            tester
                .widget<ListTile>(find.byKey(ValueKey('$prefix-track-1')))
                .selected,
            true,
          );
          await tester.tap(off);
          await tester.pumpAndSettle();
          expect(chosen, 'no');
          expect(find.byType(TrackPicker), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('failed switch keeps picker open and permits retry', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TrackPicker(
            subtitles: false,
            selectedId: 'auto',
            audioTracks: [const AudioTrack('1', 'Japanese', 'jpn')],
            onAudio: (_) async {
              calls++;
              throw StateError('backend error');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final track = find.byKey(const ValueKey('audio-track-1'));
    await tester.tap(track);
    await tester.pumpAndSettle();
    expect(find.text("Couldn't switch tracks. Try again."), findsOneWidget);
    expect(find.byType(TrackPicker), findsOneWidget);
    await tester.tap(track);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });
}
