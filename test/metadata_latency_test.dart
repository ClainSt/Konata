import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/artwork_cache.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/optional_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'optional_features_test.dart' show LocalPeopleClient;

class _PictureSession extends OptionalPeopleSession {
  _PictureSession(super.settings, super.feature);
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  @override
  Future<List<Map<String, dynamic>>> load(
    Map<String, Object?> work,
    String locale, {
    List<Map> characters = const [],
    Map<String, List<Map>> credits = const {},
  }) async => [
    {
      'title': 'Character',
      'subtitle': '',
      'image': 'https://lain.bgm.tv/pic.jpg',
    },
  ];
  @override
  Future<Uint8List> image(
    String url,
    Future<void> cancelled, {
    int? displayWidth,
  }) async => bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'partial Chinese names survive reopen and only missing names are retried',
    () async {
      final root = await (await Directory(
        'build/metadata-latency-tests',
      ).absolute.create(recursive: true)).createTemp('partial-');
      SharedPreferences.setMockInitialValues({});
      ImageStore.root = Directory('${root.path}/artwork');
      final settings = OptionalFeatures(legacyRoot: root);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var lists = 0, firstNames = 0, secondNames = 0;
      server.listen((request) async {
        if (request.uri.path.endsWith('/subjects/42/characters')) {
          lists++;
          request.response.write(
            '[{"id":1,"name":"First"},{"id":2,"name":"Second"}]',
          );
        } else if (request.uri.path.endsWith('/characters/1')) {
          firstNames++;
          request.response.write('{"name_cn":"第一"}');
        } else {
          secondNames++;
          if (secondNames == 1) {
            request.response.statusCode = 429;
          } else {
            request.response.write('{"name_cn":"第二"}');
          }
        }
        await request.response.close();
      });
      try {
        await settings.initialize();
        for (var round = 0; round < 3; round++) {
          final snapshots = <List<String>>[];
          final session = OptionalPeopleSession(
            settings,
            OptionalFeature.characters,
            clientFactory: () => LocalPeopleClient(server.port, []),
          );
          session.onCardsReady = (cards) =>
              snapshots.add(cards.map((c) => c['title'] as String).toList());
          final cards = await session.load({
            'id': 'partial',
            'bangumi_id': 42,
            'original_language': 'ja',
          }, 'zh');
          if (round == 1) expect(snapshots.first, ['第一', 'Second']);
          expect(
            cards.map((c) => c['title']),
            round == 0 ? ['第一', 'Second'] : ['第一', '第二'],
          );
          session.dispose();
          await ImageStore.close();
        }
        expect(lists, 1);
        expect(firstNames, 1);
        expect(secondNames, 2);
        final db = await (await ImageStore.cache).database;
        final rows = await db.query(
          'data',
          where: 'owner=?',
          whereArgs: ['partial'],
        );
        final state = jsonDecode(rows.single['payload'] as String) as Map;
        state['expiresAt'] = 0;
        await db.update(
          'data',
          {'payload': jsonEncode(state)},
          where: 'owner=?',
          whereArgs: ['partial'],
        );
        final refreshed = OptionalPeopleSession(
          settings,
          OptionalFeature.characters,
          clientFactory: () => LocalPeopleClient(server.port, []),
        );
        await refreshed.load({
          'id': 'partial',
          'bangumi_id': 42,
          'original_language': 'ja',
        }, 'zh');
        refreshed.dispose();
        expect(
          lists,
          2,
          reason:
              'Expired fields must refresh instead of staying cached forever',
        );
      } finally {
        settings.dispose();
        await server.close(force: true);
        await ImageStore.close();
        ImageStore.root = null;
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'mirror character and voice URLs survive normalization and stale empty cards refresh',
    () async {
      final root = await (await Directory(
        'build/metadata-latency-tests',
      ).absolute.create(recursive: true)).createTemp('mirror-');
      final previous = List<String>.of(MetadataServers.values);
      SharedPreferences.setMockInitialValues({});
      ImageStore.root = Directory('${root.path}/artwork');
      final settings = OptionalFeatures(legacyRoot: root);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final urls = <Uri>[];
      final picture = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      server.listen((request) async {
        if (request.uri.path.endsWith('/characters')) {
          request.response.write(
            jsonEncode([
              {
                'id': 1,
                'name': 'Mirror',
                'images': {
                  'medium': 'https://lain.bangumi.lat/r/400/pic.jpg?r=123',
                },
                'actors': [
                  {
                    'id': 2,
                    'name': 'Voice',
                    'images': {
                      'medium': 'https://pictures.example/art/voice.jpg',
                    },
                  },
                ],
              },
              {
                'id': 3,
                'name': 'Untrusted',
                'images': {
                  'medium': 'https://lain.bgm.tv.evil.invalid/pic.jpg',
                },
              },
              {
                'id': 4,
                'name': 'Credential URL',
                'images': {'medium': 'https://user@lain.bangumi.lat/pic.jpg'},
              },
            ]),
          );
        } else {
          request.response.add(picture);
        }
        await request.response.close();
      });
      OptionalPeopleSession? session;
      try {
        await settings.initialize();
        MetadataServers.values = [...previous]
          ..[3] = 'https://pictures.example/art';
        final oldKey = ArtworkCache.digest(
          jsonEncode([
            'people-v3',
            'characters',
            [42],
            null,
            null,
            'en',
            'ja',
            null,
            [],
            {},
          ]),
        );
        await (await ImageStore.cache).writeData('mirror-work', oldKey, [
          {'title': 'Old', 'image': ''},
        ], checkActive: () {});
        session = OptionalPeopleSession(
          settings,
          OptionalFeature.characters,
          clientFactory: () => LocalPeopleClient(server.port, urls),
        );
        final cards = await session.load({
          'id': 'mirror-work',
          'bangumi_id': 42,
          'original_language': 'ja',
        }, 'en');
        expect(cards, hasLength(3));
        expect(cards[0]['image'], 'https://lain.bgm.tv/r/400/pic.jpg?r=123');
        expect(cards[0]['alternateImage'], 'https://lain.bgm.tv/voice.jpg');
        expect(cards[1]['image'], isEmpty);
        expect(cards[2]['image'], isEmpty);
        expect(
          await session.image(
            cards[0]['image'] as String,
            Completer<void>().future,
          ),
          picture,
        );
        expect(urls.last.toString(), 'https://lain.bgm.tv/r/400/pic.jpg?r=123');
        session.dispose();
        await ImageStore.close();
        session = OptionalPeopleSession(
          settings,
          OptionalFeature.characters,
          clientFactory: () =>
              throw StateError('Disk cache must not use network'),
        );
        expect(
          await session.image(
            cards[0]['image'] as String,
            Completer<void>().future,
          ),
          picture,
        );
      } finally {
        session?.dispose();
        settings.dispose();
        await server.close(force: true);
        await ImageStore.close();
        ImageStore.root = null;
        MetadataServers.values = previous;
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'DPI changes evict old role thumbnails and disable evicts the current one',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        OptionalFeatures.preferenceKey: '{"characters":true}',
      });
      final settings = OptionalFeatures();
      await settings.initialize();
      Widget app(double dpr) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(devicePixelRatio: dpr),
          child: OptionalDetails(
            settings: settings,
            work: const {'is_animation': 1},
            sessionFactory: (s, f) => _PictureSession(s, f),
          ),
        ),
      );
      try {
        await tester.pumpWidget(app(1));
        await tester.pumpAndSettle();
        final first = tester.widget<Image>(find.byType(Image)).image;
        final firstKey = await first.obtainKey(ImageConfiguration.empty);
        expect(PaintingBinding.instance.imageCache.containsKey(firstKey), true);
        await tester.pumpWidget(app(2));
        await tester.pumpAndSettle();
        final second = tester.widget<Image>(find.byType(Image)).image;
        final secondKey = await second.obtainKey(ImageConfiguration.empty);
        expect(firstKey, isNot(secondKey));
        expect(
          PaintingBinding.instance.imageCache.containsKey(firstKey),
          false,
        );
        await settings.setEnabled(OptionalFeature.characters, false);
        await tester.pumpAndSettle();
        expect(
          PaintingBinding.instance.imageCache.containsKey(secondKey),
          false,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        settings.dispose();
      }
    },
  );
  test(
    'failed name enrichment is retried on the next visit instead of cached forever',
    () async {
      final root = await (await Directory(
        'build/metadata-latency-tests',
      ).absolute.create(recursive: true)).createTemp('retry-');
      SharedPreferences.setMockInitialValues({});
      ImageStore.root = Directory('${root.path}/artwork');
      final settings = OptionalFeatures(legacyRoot: root);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var names = 0;
      server.listen((r) async {
        if (r.uri.path.endsWith('/subjects/42/characters')) {
          r.response.write('[{"id":1,"name":"Original"}]');
        } else if (++names == 1) {
          r.response.statusCode = 429;
        } else {
          r.response.write('{"name_cn":"中文"}');
        }
        await r.response.close();
      });
      try {
        await settings.initialize();
        for (final expected in ['Original', '中文', '中文']) {
          final session = OptionalPeopleSession(
            settings,
            OptionalFeature.characters,
            clientFactory: () => LocalPeopleClient(server.port, []),
          );
          final cards = await session.load({
            'id': 42,
            'bangumi_id': 42,
            'original_language': 'ja',
          }, 'zh');
          expect(cards.single['title'], expected);
          session.dispose();
        }
        expect(
          names,
          2,
          reason: 'Retry partial data, then reuse a complete cached result',
        );
      } finally {
        settings.dispose();
        await server.close(force: true);
        await ImageStore.close();
        ImageStore.root = null;
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'optional people use configured API/artwork endpoints and bounded fallback',
    () async {
      final root = await (await Directory(
        'build/metadata-latency-tests',
      ).absolute.create(recursive: true)).createTemp('routing-');
      final previous = List<String>.of(MetadataServers.values);
      final fallback = MetadataServers.fallback;
      SharedPreferences.setMockInitialValues({});
      ImageStore.root = Directory('${root.path}/artwork');
      final settings = OptionalFeatures(legacyRoot: root);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final urls = <Uri>[];
      server.listen((r) async {
        if (r.uri.path.endsWith('/characters')) {
          r.response.write('[]');
        } else {
          r.response.add(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
          );
        }
        await r.response.close();
      });
      try {
        await settings.initialize();
        MetadataServers.values = [...previous];
        MetadataServers.values[2] = 'https://metadata.example/mirror/v0';
        MetadataServers.values[3] = 'https://pictures.example/art';
        MetadataServers.fallback = true;
        final session = OptionalPeopleSession(
          settings,
          OptionalFeature.characters,
          clientFactory: () => LocalPeopleClient(
            server.port,
            urls,
            fail: (uri) => ['api.bgm.tv', 'lain.bgm.tv'].contains(uri.host),
          ),
        );
        await session.load({'bangumi_id': 42, 'original_language': 'ja'}, 'en');
        expect(
          urls[0].toString(),
          'https://api.bgm.tv/v0/subjects/42/characters',
        );
        expect(urls[1].host, 'metadata.example');
        await session.image(
          'https://lain.bgm.tv/pic.jpg',
          Completer<void>().future,
        );
        expect(urls.last.toString(), 'https://pictures.example/art/pic.jpg');
        session.dispose();
        Metadata.token = 'synthetic-token';
        MetadataServers.values[0] = 'https://untrusted.example/3';
        MetadataServers.trustCustomTmdb = false;
        await settings.setEnabled(OptionalFeature.credits, true);
        final credits = OptionalPeopleSession(
          settings,
          OptionalFeature.credits,
          clientFactory: () => LocalPeopleClient(
            server.port,
            urls,
            fail: (uri) => uri.host == 'api.themoviedb.org',
          ),
        );
        final before = urls.length;
        await expectLater(
          credits.load({'tmdb_id': 1, 'tmdb_type': 'tv'}, 'en'),
          throwsStateError,
        );
        expect(
          urls.skip(before).map((uri) => uri.host),
          everyElement('api.themoviedb.org'),
          reason: 'Untrusted custom host must receive no token',
        );
        credits.dispose();
      } finally {
        settings.dispose();
        await server.close(force: true);
        await ImageStore.close();
        ImageStore.root = null;
        MetadataServers.values = previous;
        MetadataServers.fallback = fallback;
        Metadata.token = '';
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'character cards render before slow optional Chinese name enrichment',
    (tester) async {
      final root = await tester.runAsync(
        () async => (await Directory(
          'build/metadata-latency-tests',
        ).absolute.create(recursive: true)).createTemp('cards-'),
      );
      SharedPreferences.setMockInitialValues({});
      ImageStore.root = Directory('${root!.path}/artwork');
      final settings = OptionalFeatures(legacyRoot: root);
      final gate = Completer<void>();
      final namesStarted = Completer<void>();
      final server = await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      );
      final urls = <Uri>[];
      server!.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        Object data = {};
        if (request.uri.path.endsWith('/characters')) {
          data = [
            {'id': 1, 'name': 'Original character', 'relation': '主角'},
          ];
        } else if (request.uri.path == '/v0/characters/1') {
          if (!namesStarted.isCompleted) namesStarted.complete();
          await gate.future;
          data = {'name_cn': '角色中文名'};
        }
        request.response.write(jsonEncode(data));
        await request.response.close();
      });
      try {
        await tester.runAsync(settings.initialize);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: OptionalDetails(
                work: const {'bangumi_id': 42, 'original_language': 'ja'},
                settings: settings,
                sessionFactory: (settings, feature) => OptionalPeopleSession(
                  settings,
                  feature,
                  clientFactory: () => LocalPeopleClient(server.port, urls),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 100 && !namesStarted.isCompleted; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(namesStarted.isCompleted, true);
        expect(
          find.text('Original character'),
          findsOneWidget,
          reason:
              'Optional name lookup must not keep the entire character row hidden',
        );
        gate.complete();
        for (var i = 0; i < 100 && find.text('角色中文名').evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(find.text('角色中文名'), findsOneWidget);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await tester.pumpWidget(const SizedBox());
        settings.dispose();
        await tester.runAsync(() async {
          await server.close(force: true);
          await ImageStore.close();
          ImageStore.root = null;
          await root.delete(recursive: true);
        });
      }
    },
  );

  test(
    'independent TV and movie searches overlap without changing ambiguous-match rules',
    () async {
      Metadata.token = 'synthetic-test-token';
      var searches = 0;
      var active = 0, maximum = 0;
      final watch = Stopwatch()..start();
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/search/tv') ||
            request.url.path.endsWith('/search/movie')) {
          searches++;
          active++;
          if (active > maximum) maximum = active;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          active--;
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'id': 7,
                  'name': 'Exact Title',
                  'title': 'Exact Title',
                  'first_air_date': '2024-01-01',
                  'release_date': '2024-01-01',
                },
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });
      final scraper = PersonalMetadataScraper(client: client);
      try {
        final result = await scraper.scrape({
          'title': 'Exact Title',
          'year': 2024,
        });
        expect(searches, 2);
        // ignore: avoid_print
        print(
          'SEARCH_BENCH elapsedMs=${watch.elapsedMilliseconds} maxConcurrent=$maximum',
        );
        expect(maximum, 2);
        expect(
          result?.tmdbId,
          isNull,
          reason: 'Two matching media types remain ambiguous',
        );
      } finally {
        scraper.close();
        Metadata.token = '';
      }
    },
  );
}
