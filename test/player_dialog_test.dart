import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:ccplayer/ui/player_dialog.dart';
import 'package:ccplayer/ui/track_picker.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(1280, 800)]) {
    testWidgets(
      'player popup is centered, compact and labels subtitle formats at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showPlayerDialog(
                    context,
                    TrackPicker(
                      subtitles: true,
                      selectedId: '1',
                      subtitleTracks: const [
                        SubtitleTrack('1', 'CHS_JPN', 'zho', codec: 'ass'),
                        SubtitleTrack('2', 'CHT_JPN', 'zho', codec: 'ssa'),
                      ],
                      onImport: () async => false,
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
        final rect = tester.getRect(
          find.byKey(const ValueKey('player-popup-panel')),
        );
        expect(rect.center.dx, closeTo(size.width / 2, 1));
        expect(rect.center.dy, closeTo(size.height / 2, 1));
        expect(rect.width, lessThanOrEqualTo(460));
        expect(rect.height, lessThanOrEqualTo(size.height * .65));
        expect(find.text('简日双语 · ass · 内封'), findsOneWidget);
        expect(find.text('繁日双语 · ssa · 内封'), findsOneWidget);
        expect(find.text('自动选择'), findsNothing);
        await tester.tap(find.text('导入字幕'));
        await tester.pumpAndSettle();
        expect(find.byType(TrackPicker), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
