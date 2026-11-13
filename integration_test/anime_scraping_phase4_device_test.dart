import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/scan_recognition.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';
import 'package:ccplayer/ui/scan_reviews_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _reply(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json'},
);

Uint8List _fixtureVideo() {
  const width = 64, height = 48;
  final bytes = BytesBuilder(copy: false)
    ..add(ascii.encode('YUV4MPEG2 W64 H48 F12:1 Ip A1:1 C420jpeg\n'));
  for (var i = 0; i < 48; i++) {
    bytes.add(ascii.encode('FRAME\n'));
    bytes.add(
      Uint8List(width * height)..fillRange(0, width * height, 32 + i * 3),
    );
    bytes.add(
      Uint8List(width * height ~/ 2)..fillRange(0, width * height ~/ 2, 128),
    );
  }
  return bytes.takeBytes();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'isolated phase 4 scan, group, numbering, TV, reopen and playback',
    (tester) async {
      final cache = await getTemporaryDirectory();
      if (Platform.isAndroid &&
          !cache.path.contains('com.anime.konata.validation')) {
        throw StateError('Android phase 4 requires the .validation package');
      }
      final root = await cache.createTemp('konata-phase4-device-');
      final dbFolder = Directory('${root.path}/catalog');
      final media = await Directory('${root.path}/media').create();
      final catalog = Catalog.instance;
      SharedPreferences.setMockInitialValues({});
      Metadata.token = 'fixture-only-token';
      Metadata.authMode = 'token';
      MetadataServers.fallback = false;
      Future<void> open({bool automatic = true}) => catalog.initialize(
        dataDirectory: dbFolder,
        enableFoundation: true,
        enableTasks: true,
        enableMappings: true,
        enableRecognition: true,
        enableAutomaticRecognition: automatic,
      );
      final bytes = _fixtureVideo();
      Future<File> video(String relative) async {
        final file = File('${media.path}/$relative');
        await file.parent.create(recursive: true);
        return file.writeAsBytes(bytes, flush: true);
      }

      var opened = false;
      Player? player;
      final checks = <String>[];
      try {
        await open();
        opened = true;
        final source = await catalog.addSource(
          'local',
          'Phase 4 fixture',
          media.path,
        );
        await catalog.addScanRoot(source, '');
        final first = await video(
          'Device Series (2024)/Device Series S01E01.mkv',
        );
        await video('Device Series (2024)/Device Series S01E03.mkv');
        await video('Device Series (2024)/SP 2.5.mkv');
        await video('Grouped Series/First S01E01.mkv');
        await video('Grouped Series/Lower S01E01.mkv');
        await video('Grouped Series/Lower S01E03.mkv');
        await video('Grouped Series/Lower SP 2.5.mkv');
        var identityRequests = 0;
        const titles = [
          'A Quiet Morning',
          'Across the Water',
          'A Lantern at Night',
        ];
        final runner = ScrapeTaskRunner(
          catalog,
          requests: SharedMetadataRequests(
            catalog.taskStore!,
            retryDelays: const [],
            clientFactory: () => MockClient((req) async {
              final path = req.url.path;
              if (path == '/3/search/multi') {
                identityRequests++;
                return _reply({
                  'results': [
                    if (req.url.queryParameters['query'] == 'Device Series')
                      {
                        'id': 42,
                        'media_type': 'tv',
                        'name': 'Device Series',
                        'first_air_date': '2024-01-01',
                      },
                  ],
                  'total_pages': 1,
                });
              }
              if (path == '/v0/search/subjects') {
                identityRequests++;
                return _reply({
                  'data': [
                    if ((jsonDecode(req.body) as Map)['keyword'] ==
                        'Device Series')
                      {
                        'id': 21,
                        'type': 2,
                        'name': 'Device Series',
                        'date': '2024-01-01',
                      },
                  ],
                });
              }
              if (path == '/3/tv/42') {
                return _reply({
                  'id': 42,
                  'seasons': [
                    {
                      'season_number': 1,
                      'episode_count': 3,
                      'air_date': '2024-01-01',
                    },
                  ],
                });
              }
              if (path == '/v0/episodes') {
                return _reply({
                  'total': 3,
                  'data': [
                    for (var n = 1; n <= 3; n++)
                      {
                        'id': 200 + n,
                        'subject_id': 21,
                        'type': 0,
                        'sort': n,
                        'name': titles[n - 1],
                        'airdate': '2024-01-0$n',
                      },
                  ],
                });
              }
              if (path == '/3/tv/42/season/1' || path == '/3/tv/101/season/1') {
                final count = path.contains('/101/') ? 12 : 3;
                return _reply({
                  'season_number': 1,
                  'episodes': [
                    for (var n = 1; n <= count; n++)
                      {
                        'id': 300 + n,
                        'season_number': 1,
                        'episode_number': n,
                        'name': n <= 3 ? titles[n - 1] : 'Fixture episode $n',
                        'air_date': '2024-01-0$n',
                      },
                  ],
                });
              }
              return http.Response('{}', 404);
            }),
          ),
        );
        Future<void> scan() async =>
            runner.run(await runner.enqueueScan(source));
        await scan();
        final auto = await catalog.db.query(
          'scan_bindings',
          where: "reason='verified_tv_chapters' AND layer='episode'",
        );
        expect(auto, hasLength(4));
        expect(
          auto
              .where((row) => row['provider'] == 'tmdb')
              .map((row) => ScanRecognition.adopted(row)!['episode']),
          unorderedEquals([1, 3]),
        );
        checks.add('no_mapping_tv_auto_preserves_episode_gap');

        final work = catalog.works.singleWhere(
          (row) => row['title'] == 'Grouped Series',
        )['id'];
        Future<Map<String, Object?>> binding(
          String layer, {
          String? scope,
        }) async => (await catalog.db.rawQuery(
          '''SELECT b.*,s.session,p.revision AS identity_revision
          FROM scan_bindings b JOIN library_work_protection p ON p.work_id=b.work_id
          CROSS JOIN scrape_runtime s WHERE b.work_id=? AND b.provider='tmdb'
          AND b.layer=? AND (? IS NULL OR b.scope=?)''',
          [work, layer, scope, scope],
        )).single;
        await runner.recognition.decide(await binding('work'), {
          'type': 'tv',
          'id': 101,
        });
        final base = await binding('range');
        await runner.recognition.decide(base, {
          'season': 1,
          'first': 1,
          'last': 3,
          'offset': 0,
        });

        await tester.pumpWidget(
          MaterialApp(
            home: ScanReviewsPage(runner: runner, source: source),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show adopted and skipped reviews'));
        await tester.pumpAndSettle();
        Finder rangeTile(String name) => find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.title is Text &&
              (widget.title as Text).data == name &&
              (widget.subtitle as Text).data!.contains('Season or part · TMDB'),
        );
        Future<void> tapVisible(Finder target) async {
          await tester.ensureVisible(target);
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        await tapVisible(rangeTile('Grouped Series'));
        await tapVisible(find.byKey(const ValueKey('scan-file-group')));
        await tester.enterText(
          find.byKey(const ValueKey('scan-group-name')),
          'Lower part',
        );
        for (final name in [
          'Lower S01E01.mkv',
          'Lower S01E03.mkv',
          'Lower SP 2.5.mkv',
        ]) {
          await tapVisible(find.widgetWithText(CheckboxListTile, name));
        }
        await tapVisible(find.byKey(const ValueKey('scan-save-group')));
        expect(await catalog.db.query('scan_file_group_members'), hasLength(3));
        final group = (await catalog.db.query('scan_file_groups')).single;
        final range = await binding('range', scope: group['scope'] as String);
        await runner.recognition.decide(range, {
          'season': 1,
          'first': 10,
          'last': 12,
          'offset': 9,
        });
        await runner.run(
          await runner.recognition.enqueueRange(source, range['id'] as String),
        );
        await tester.pumpAndSettle();
        await tapVisible(rangeTile('Grouped Series · Lower part'));
        await tapVisible(find.byKey(const ValueKey('scan-numbering-preview')));
        expect(find.text('2 ready · 1 need individual review'), findsOneWidget);
        await tapVisible(find.byKey(const ValueKey('scan-apply-numbering')));
        final batch = await catalog.db.query(
          'scan_bindings',
          where: "reason='confirmed_numbering'",
        );
        expect(
          batch.map((row) => ScanRecognition.adopted(row)!['episode']),
          unorderedEquals([10, 12]),
        );
        checks.add('group_and_numbering_preview_commits_two_regular_files');

        final before = identityRequests;
        await video('Device Series (2024)/Device Series S01E02.mkv');
        await scan();
        expect(identityRequests, before);
        checks.add('incremental_scan_does_not_repeat_identity_search');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await catalog.db.close();
        opened = false;
        await open(automatic: false);
        opened = true;
        expect(await catalog.db.query('scan_file_group_members'), hasLength(3));
        expect(
          await catalog.db.query(
            'scan_bindings',
            where: "reason='confirmed_numbering'",
          ),
          hasLength(2),
        );
        expect(
          await catalog.db.query(
            'scan_bindings',
            where: "reason='verified_tv_chapters' AND layer='episode'",
          ),
          hasLength(4),
        );
        checks.add('reopen_and_disable_automatic_preserves_decisions');

        // Native first-frame check reads only the generated fixture. No network
        // transport, preferences, credentials or user-media paths are involved.
        MediaKit.ensureInitialized();
        final native = Player();
        player = native;
        final controller = VideoController(
          native,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: false,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Video(controller: controller)),
          ),
        );
        await tester.pump();
        await native.open(Media(first.path));
        final firstFrame = controller.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 20),
        );
        var rendered = false;
        final rendering = firstFrame.then((_) => rendered = true);
        final clock = Stopwatch()..start();
        while (!rendered && clock.elapsed < const Duration(seconds: 20)) {
          await tester.pump(const Duration(milliseconds: 40));
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        await rendering;
        expect(native.state.width, 64);
        checks.add('offline_native_video_first_frame');
        debugPrint(
          'KONATA_PHASE4_DEVICE ${jsonEncode({'platform': Platform.operatingSystem, 'schema': (await catalog.db.rawQuery('PRAGMA user_version')).single.values.single, 'checks': checks, 'identityRequests': identityRequests})}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await player?.dispose();
        catalog.taskStore?.dispose();
        catalog.taskStore = null;
        if (opened) await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
