import 'dart:async';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/local_media.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/nipaplay_detail_page.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('sidecar selection and work-scoped review on the normal pages', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp(
      'konata-sidecar-review-',
    );
    final catalog = Catalog.instance;
    await catalog.initialize(
      dataDirectory: root,
      enableFoundation: true,
      enableTasks: true,
      enableMappings: true,
      enableRecognition: true,
    );
    if (Platform.isWindows) {
      await windowManager.ensureInitialized();
      await windowManager.show();
    }
    final messenger = tester.binding.defaultBinaryMessenger;
    try {
      final source = await catalog.addSource(
        'local',
        'Isolated sidecar fixture',
        'content://fixture/tree/root',
      );
      const video = 'Original.S01E1.mkv';
      const renamed = 'Renamed.S01E01.chs.srt';
      const alternative = 'Alternative.S01E1.en.srt';
      const wrong = 'Original.S01E10.chs.srt';
      const wrongSeason = 'Original.S02E1.chs.srt';
      const asset = {
        'id': 'clip',
        'work_id': 'current',
        'name': video,
        'relative_path': video,
        'category': 'episode',
        'season': 1,
        'episode': 1,
      };
      final savedAsset = {...asset, 'source_id': source};
      await catalog.db.insert('assets', savedAsset);
      final clip = File('${root.path}/$video');
      // A tiny YUV4MPEG fixture is probed by libmpv without bundling media.
      final sink = clip.openWrite();
      sink.write('YUV4MPEG2 W64 H48 F24:1 Ip A1:1 C420jpeg\n');
      final frame = List<int>.filled(64 * 48 * 3 ~/ 2, 128);
      for (var i = 0; i < 24 * 12; i++) {
        sink.write('FRAME\n');
        sink.add(frame);
      }
      await sink.close();
      for (final subtitle in [renamed, alternative, wrong, wrongSeason]) {
        await File(
          '${root.path}/$subtitle',
        ).writeAsString('1\n00:00:00,000 --> 00:00:11,900\n$subtitle\n');
      }
      Widget app(Widget child) => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      );
      Future<void> until(bool Function() ready) async {
        final clock = Stopwatch()..start();
        while (!ready()) {
          expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }

      for (final ambiguous in [false, true]) {
        final listing = Completer<List<Object?>>();
        messenger.setMockMethodCallHandler(LocalMedia.channel, (call) async {
          if (call.method == 'list') return listing.future;
          if (call.method == 'resolve') {
            final relative = (call.arguments as Map)['relative'];
            return '${root.path}/$relative';
          }
          return null;
        });
        Player? active;
        final watchKey = GlobalKey();
        try {
          await tester.pumpWidget(
            app(
              WatchPage(
                key: watchKey,
                asset: savedAsset,
                createPlayer: (configuration) =>
                    active = Player(configuration: configuration),
              ),
            ),
          );
          await until(() => (active?.state.position.inMilliseconds ?? 0) > 250);
          expect(listing.isCompleted, isFalse);
          listing.complete([
            for (final name in [
              video,
              renamed,
              if (ambiguous) alternative,
              wrong,
              wrongSeason,
            ])
              {'name': name, 'directory': false},
          ]);
          final dynamic page = watchKey.currentState;
          await until(() => page.addedSubtitles.length == (ambiguous ? 2 : 1));
          final candidates = page.addedSubtitles as List<SubtitleTrack>;
          expect(
            candidates.map((t) => t.title),
            unorderedEquals([renamed, if (ambiguous) alternative]),
          );
          final player = active!;
          if (ambiguous) {
            expect(player.state.track.subtitle.id, anyOf('auto', 'no'));
            final button = find.widgetWithIcon(
              IconButton,
              Icons.subtitles_outlined,
            );
            if (button.evaluate().isEmpty) {
              await tester.tapAt(tester.getCenter(find.byType(WatchPage)));
              await tester.pump();
            }
            await until(() => button.evaluate().isNotEmpty);
            tester.widget<IconButton>(button.first).onPressed!.call();
            final selected = find.text(alternative);
            await until(() => selected.evaluate().isNotEmpty);
            expect(find.text(renamed), findsOneWidget);
            await tester.ensureVisible(selected);
            await tester.tap(selected);
            await until(() => selected.evaluate().isEmpty);
          } else {
            await until(
              () =>
                  player.state.track.subtitle.id != 'no' &&
                  player.state.track.subtitle.id != 'auto',
            );
          }
          final native = player.platform as NativePlayer;
          expect(
            await native.getProperty('sub-text'),
            contains(ambiguous ? alternative : renamed),
          );
        } finally {
          if (!listing.isCompleted) listing.complete([]);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          if (active != null) {
            await active!.stream.position.drain<void>().timeout(
              const Duration(seconds: 15),
            );
          }
        }
      }

      for (final id in ['current', 'other']) {
        await catalog.db.insert('works', {'id': id, 'title': 'Title $id'});
        await catalog.db.insert('library_locations', {
          'kind': 'work',
          'entity_id': id,
          'source_id': source,
          'relative_path': '$id-review-fixture',
        });
        await catalog.db.insert('library_work_protection', {
          'work_id': id,
          'legacy_lock': 0,
          'identity_locked': 0,
          'legacy_json': '{}',
        });
        await catalog.db.insert('scan_bindings', {
          'id': id,
          'work_id': id,
          'provider': 'tmdb',
          'layer': 'work',
          'scope': '',
        });
      }
      await tester.pumpWidget(
        app(
          NipaPlayDetailPage(
            work: const {'id': 'current', 'title': 'Title current'},
            assets: [savedAsset],
            onEditMetadata: () {},
            onEditCover: () {},
            onDelete: () {},
            onBack: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Correct metadata match'));
      await until(
        () => find.text('current-review-fixture').evaluate().isNotEmpty,
      );
      expect(find.text('Review this title'), findsOneWidget);
      expect(find.text('other-review-fixture'), findsNothing);
    } finally {
      messenger.setMockMethodCallHandler(LocalMedia.channel, null);
      await tester.pumpWidget(const SizedBox.shrink());
      catalog.taskStore?.dispose();
      await catalog.db.close();
      await root.delete(recursive: true);
    }
  });
}
