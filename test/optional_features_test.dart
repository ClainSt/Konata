import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/core/request_budget.dart';
import 'package:ccplayer/ui/extensions_panel.dart';
import 'package:ccplayer/ui/optional_details.dart';
import 'package:ccplayer/ui/optional_scraping_settings.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttp extends HttpOverrides {}

class LocalPeopleClient implements HttpClient {
  LocalPeopleClient(this.port, this.urls);
  final int port;
  final List<Uri> urls;
  final HttpClient delegate = HttpOverrides.runWithHttpOverrides(
    () => HttpClient(),
    _RealHttp(),
  );
  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    urls.add(uri);
    return delegate.getUrl(
      Uri.http('127.0.0.1:$port', uri.path, uri.queryParameters),
    );
  }

  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OptionalFeatures settings;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('konata-optional-');
    ImageStore.root = Directory('${temp.path}/artwork');
    settings = OptionalFeatures(legacyRoot: temp);
  });
  tearDown(() async {
    settings.dispose();
    await ImageStore.close();
    ImageStore.root = null;
    await temp.delete(recursive: true);
    Metadata.token = '';
    Metadata.apiKey = '';
  });

  test(
    'fresh install defaults to Bangumi characters; explicit off survives restart',
    () async {
      await settings.initialize();
      expect(settings.characterPresentation, 1);
      expect(settings.enabled(OptionalFeature.credits), false);
      await settings.setEnabled(OptionalFeature.characters, false);
      expect(
        () => OptionalPeopleSession(settings, OptionalFeature.characters),
        throwsStateError,
      );
      await settings.setCharacterPresentation(2);
      final restored = OptionalFeatures(legacyRoot: temp);
      await restored.initialize();
      expect(restored.characterPresentation, 2);
      restored.dispose();
      await settings.setCharacterPresentation(0);
      expect(settings.voicePhotos, true);
      expect(settings.enabled(OptionalFeature.characters), false);
    },
  );

  test(
    'migrates official choices without executing scripts or modifying old files',
    () async {
      final bytes = utf8.encode(
        jsonEncode({
          'id': 'org.konata.bangumi-characters',
          'script': 'throw new Error("MUST NEVER RUN")',
        }),
      );
      final hash = sha256.convert(bytes).toString();
      final file = File('${temp.path}/$hash.json');
      await file.writeAsBytes(bytes);
      final registry = File('${temp.path}/registry.json');
      final original = jsonEncode([
        {'sha256': hash, 'enabled': true, 'alternateImages': true},
      ]);
      await registry.writeAsString(original);
      await settings.initialize();
      expect(settings.characterPresentation, 2);
      expect(await registry.readAsString(), original);
      expect(await file.readAsBytes(), bytes);
      await settings.setCharacterPresentation(0);
      final next = OptionalFeatures(legacyRoot: temp);
      await next.initialize();
      expect(
        next.characterPresentation,
        0,
      ); // Old enabled registry cannot re-enable.
      next.dispose();
    },
  );

  test(
    'corrupt legacy registry fails closed and remains available for rollback',
    () async {
      final file = File('${temp.path}/registry.json');
      await file.writeAsString('broken');
      await settings.initialize();
      expect(settings.characterPresentation, 0);
      expect(await file.readAsString(), 'broken');
    },
  );

  test('queued feature work cancels before a network slot opens', () async {
    await settings.initialize();
    await settings.setEnabled(OptionalFeature.characters, true);
    final hold = Completer<void>();
    var active = 0;
    final occupying = List.generate(
      6,
      (_) => RequestBudget.run(() async {
        active++;
        await hold.future;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(active, 6);
    var clients = 0;
    final session = OptionalPeopleSession(
      settings,
      OptionalFeature.characters,
      clientFactory: () {
        clients++;
        return HttpClient();
      },
    );
    final work = session.load({'bangumi_id': 1}, 'en');
    final check = expectLater(work, throwsStateError);
    await settings.setEnabled(OptionalFeature.characters, false);
    await check.timeout(const Duration(seconds: 2));
    expect(clients, 0);
    expect(session.activeTimers, 0);
    hold.complete();
    await Future.wait(occupying);
    expect(await RequestBudget.run(() async => 7), 7);
  });

  test(
    'disabling aborts a stalled response and releases clients/timers',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final arrived = Completer<void>();
      server.listen((request) {
        if (!arrived.isCompleted) arrived.complete();
      });
      final urls = <Uri>[];
      await settings.initialize();
      await settings.setCharacterPresentation(1);
      final session = OptionalPeopleSession(
        settings,
        OptionalFeature.characters,
        clientFactory: () => LocalPeopleClient(server.port, urls),
      );
      final result = session.load({'bangumi_id': 42}, 'en');
      final checked = expectLater(result, throwsStateError);
      await arrived.future.timeout(const Duration(seconds: 3));
      await settings.setCharacterPresentation(0);
      await checked.timeout(const Duration(seconds: 3));
      expect(session.activeClients, 0);
      expect(session.activeTimers, 0);
      expect(session.cachedImageBytes, 0);
      expect(urls.length, 1);
    },
  );

  test(
    'character names, manual ordering, preserved edits and voice photos',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        r.response.headers.contentType = ContentType.json;
        Object data = {};
        if (r.uri.path.endsWith('/subjects/42/characters')) {
          data = [
            {
              'id': 1,
              'name': 'Original',
              'relation': '主角',
              'images': {'medium': 'https://lain.bgm.tv/character.jpg'},
              'actors': [
                {
                  'id': 8,
                  'name': 'Actor',
                  'images': {'medium': 'https://lain.bgm.tv/actor.jpg'},
                },
              ],
            },
            {'id': 2, 'name': 'Second', 'relation': '配角'},
          ];
        }
        if (r.uri.path.endsWith('/persons/8')) {
          data = {
            'infobox': [
              {'key': '简体中文名', 'value': '声优中文'},
            ],
          };
        }
        r.response.write(jsonEncode(data));
        await r.response.close();
      });
      await settings.initialize();
      await settings.setCharacterPresentation(2);
      final session = OptionalPeopleSession(
        settings,
        OptionalFeature.characters,
        clientFactory: () => LocalPeopleClient(server.port, []),
      );
      final cards = await session.load(
        {'bangumi_id': 42, 'character_order': '[2,1]'},
        'zh',
        characters: [
          {'id': 1, 'name_cn': '手动中文'},
          {'id': 3, 'name': '自定义', 'manual': true},
        ],
      );
      expect(cards.map((c) => c['title']), ['Second', '手动中文', '自定义']);
      expect(cards[1]['alternateImage'], 'https://lain.bgm.tv/actor.jpg');
      expect(cards[1]['alternateSubtitle'], '声优中文');
      expect(cards[1]['subtitle'], '声优中文');
      expect(session.activeClients, 0);
      expect(session.activeTimers, 0);
      session.dispose();
    },
  );

  test(
    'credits merge roles, filter crew, preserve cached data and prevent credential redirects',
    () async {
      final cards = OptionalPeopleSession.creditsCards(
        {
          'cast': [
            {'id': 1, 'name': 'Actor', 'character': 'One'},
            {'id': 1, 'name': 'Actor', 'character': 'Two'},
          ],
          'crew': [
            {'id': 2, 'name': 'Director', 'job': 'Director'},
            {'id': 3, 'name': 'Ignore', 'job': 'Other'},
          ],
        },
        {},
        'zh',
      );
      expect(cards.length, 2);
      expect(cards.first['subtitle'], 'One / Two');
      expect(cards.last['subtitle'], '导演');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      server.listen((r) async {
        requests.add(r.uri.path);
        expect(r.headers.value('authorization'), 'Bearer test-token');
        r.response.statusCode = 302;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${server.port}/must-not-follow',
        );
        await r.response.close();
      });
      Metadata.token = 'test-token';
      Metadata.authMode = 'token';
      await settings.initialize();
      await settings.setEnabled(OptionalFeature.credits, true);
      final urls = <Uri>[];
      final session = OptionalPeopleSession(
        settings,
        OptionalFeature.credits,
        clientFactory: () => LocalPeopleClient(server.port, urls),
      );
      final result = await session.load(
        {'is_animation': 0, 'tmdb_id': 42, 'tmdb_type': 'tv'},
        'en',
        credits: {
          'cast': [
            {
              'id': 1,
              'name': 'Cached',
              'roles': ['Lead'],
            },
          ],
        },
      );
      expect(result.single['title'], 'Cached');
      expect(requests, ['/3/tv/42/aggregate_credits']);
      expect(urls.single.host, Uri.parse(MetadataServers.values[0]).host);
      session.dispose();
    },
  );

  test('image cache is scoped, reuses bytes and is cleared on disable', () async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final arrived = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/stalled.png') {
        arrived.complete();
      } else {
        request.response.add(png);
        await request.response.close();
      }
    });
    await settings.initialize();
    await settings.setCharacterPresentation(1);
    final urls = <Uri>[];
    final session = OptionalPeopleSession(
      settings,
      OptionalFeature.characters,
      clientFactory: () => LocalPeopleClient(server.port, urls),
    );
    final cancelled = Completer<void>();
    const url = 'https://lain.bgm.tv/test.png';
    expect(await session.image(url, cancelled.future), png);
    expect(await session.image(url, cancelled.future), png);
    expect(urls.length, 1);
    expect(session.cachedImageBytes, png.length);
    final secondSession = OptionalPeopleSession(
      settings,
      OptionalFeature.characters,
      clientFactory: () => LocalPeopleClient(server.port, urls),
    );
    expect(await secondSession.image(url, cancelled.future), png);
    secondSession.dispose();
    expect(urls.length, 1, reason: 'Reopening details must reuse disk artwork');
    await expectLater(
      session.image('https://untrusted.invalid/a.png', cancelled.future),
      throwsFormatException,
    );
    final pending = session.image(
      'https://lain.bgm.tv/stalled.png',
      cancelled.future,
    );
    final rejected = expectLater(
      pending,
      throwsA(anyOf(isA<Exception>(), isA<StateError>())),
    );
    await arrived.future.timeout(const Duration(seconds: 3));
    await settings.setCharacterPresentation(0);
    await rejected.timeout(const Duration(seconds: 3));
    expect(session.cachedImageBytes, 0);
    expect(session.activeClients, 0);
    expect(session.activeTimers, 0);
    cancelled.complete();
  });

  test(
    'reopening a work loads saved cards without any metadata requests',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((r) async {
        requests++;
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode([
            {
              'id': 1,
              'name': 'Character',
              'relation': '主角',
              'actors': [
                {'id': 2, 'name': 'Original voice', 'language': 'ja'},
                {'id': 3, 'name': 'English dub', 'language': 'en'},
              ],
            },
          ]),
        );
        await r.response.close();
      });
      await settings.initialize();
      const work = <String, Object?>{
        'id': 'persisted',
        'bangumi_id': 42,
        'original_language': 'ja',
      };
      final first = OptionalPeopleSession(
        settings,
        OptionalFeature.characters,
        clientFactory: () => LocalPeopleClient(server.port, []),
      );
      final cards = await first.load(work, 'en');
      expect(cards.single['subtitle'], 'Original voice');
      first.dispose();
      await ImageStore.close();
      final second = OptionalPeopleSession(
        settings,
        OptionalFeature.characters,
        clientFactory: () => throw StateError('Must stay offline'),
      );
      expect(await second.load(work, 'en'), cards);
      expect(requests, 1);
      second.dispose();
    },
  );

  testWidgets(
    'disabled details never construct services; repeated toggles release every session',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        OptionalFeatures.preferenceKey: '{}',
      });
      await settings.initialize();
      final sessions = <OptionalPeopleSession>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OptionalDetails(
              settings: settings,
              work: const {'is_animation': 1},
              legacyCharacters: const [
                {'id': 1, 'name': 'Cached'},
              ],
              sessionFactory: (s, f) {
                final session = OptionalPeopleSession(s, f);
                sessions.add(session);
                return session;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sessions, isEmpty);
      for (var i = 0; i < 3; i++) {
        await settings.setCharacterPresentation(1);
        await tester.pumpAndSettle();
        expect(find.text('Cached'), findsOneWidget);
        await settings.setCharacterPresentation(0);
        await tester.pumpAndSettle();
        expect(find.text('Cached'), findsNothing);
        expect(
          sessions.every(
            (s) =>
                s.disposed &&
                s.activeClients == 0 &&
                s.activeTimers == 0 &&
                s.cachedImageBytes == 0,
          ),
          true,
        );
      }
      expect(sessions.length, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'people source priority, row gate and persisted presentation are independent',
    () async {
      await settings.initialize();
      for (final bangumi in [false, true]) {
        await settings.setEnabled(OptionalFeature.characters, bangumi);
        for (final tmdb in [false, true]) {
          await settings.setEnabled(OptionalFeature.credits, tmdb);
          for (final visible in [false, true]) {
            await settings.setPeopleVisible(visible);
            for (final mode in [0, 1, 2]) {
              await settings.setBangumiPresentation(mode);
              for (final animation in [false, true]) {
                final expected = !visible
                    ? null
                    : animation && bangumi && mode != 0
                    ? OptionalFeature.characters
                    : tmdb
                    ? OptionalFeature.credits
                    : null;
                expect(settings.peopleSource(animation: animation), expected);
              }
              expect(settings.enabled(OptionalFeature.characters), bangumi);
            }
          }
        }
      }
      await settings.setBangumiPresentation(0);
      final restored = OptionalFeatures(legacyRoot: temp);
      await restored.initialize();
      expect(restored.enabled(OptionalFeature.characters), true);
      expect(restored.bangumiPresentation, 0);
      expect(restored.peopleSource(animation: true), OptionalFeature.credits);
      restored.dispose();
      final session = OptionalPeopleSession(settings, OptionalFeature.credits);
      await settings.setPeopleVisible(false);
      expect(session.disposed, true);
      expect(
        () => OptionalPeopleSession(settings, OptionalFeature.credits),
        throwsStateError,
      );
      await settings.setPeopleVisible(true);
      expect(settings.peopleSource(animation: true), OptionalFeature.credits);
    },
  );

  testWidgets(
    'switching Bangumi off uses TMDB for anime; hiding the row releases sessions',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        OptionalFeatures.preferenceKey: '{"characters":true}',
      });
      await settings.initialize();
      await settings.setEnabled(OptionalFeature.credits, true);
      final sessions = <OptionalPeopleSession>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OptionalDetails(
              settings: settings,
              work: const {'is_animation': 1},
              legacyCharacters: const [
                {'id': 1, 'name': 'Bangumi person'},
              ],
              legacyCredits: const {
                'cast': [
                  {
                    'id': 2,
                    'name': 'TMDB person',
                    'roles': ['Lead'],
                  },
                ],
              },
              sessionFactory: (s, f) {
                final session = OptionalPeopleSession(s, f);
                sessions.add(session);
                return session;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bangumi person'), findsOneWidget);
      await settings.setBangumiPresentation(0);
      await tester.pumpAndSettle();
      expect(sessions.first.disposed, true);
      expect(find.text('Bangumi person'), findsNothing);
      expect(find.text('TMDB person'), findsOneWidget);
      await settings.setPeopleVisible(false);
      await tester.pumpAndSettle();
      expect(find.text('TMDB person'), findsNothing);
      expect(
        sessions.every(
          (s) => s.disposed && s.activeClients == 0 && s.activeTimers == 0,
        ),
        true,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'extensions selector and gated scraping settings on $platform',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          OptionalFeatures.preferenceKey: '{}',
        });
        await settings.initialize();
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    ExtensionsPanel(settings: settings),
                    OptionalScrapingSettings(settings: settings),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Bangumi角色/声优资料'), findsOneWidget);
        expect(find.text('TMDB真人资料'), findsOneWidget);
        expect(find.byKey(const ValueKey('scraping-characters')), findsNothing);
        expect(find.byKey(const ValueKey('scraping-credits')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('extension-characters')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('scraping-bangumi-mode')),
        );
        await tester.tap(find.byKey(const ValueKey('scraping-bangumi-mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('声优').last);
        await tester.pumpAndSettle();
        expect(settings.characterPresentation, 2);
        expect(
          find.byKey(const ValueKey('scraping-people-visible')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('extension-credits')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('scraping-credits')), findsNothing);
        await settings.setCharacterPresentation(0);
        await settings.setEnabled(OptionalFeature.credits, false);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('scraping-characters')), findsNothing);
        expect(find.byKey(const ValueKey('scraping-credits')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'real settings puts extensions directly before about and routes options under scraping',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        OptionalFeatures.preferenceKey: '{}',
      });
      await settings.initialize();
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            embedded: true,
            wideLayout: true,
            featureSettings: settings,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final extension = find.byKey(const ValueKey('settings-category-6'));
      final about = find.byKey(const ValueKey('settings-category-2'));
      expect(
        tester.getTopLeft(about).dy,
        greaterThan(tester.getTopLeft(extension).dy),
      );
      await tester.tap(extension);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('extension-characters')),
        findsOneWidget,
      );
      await settings.setCharacterPresentation(1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scraping-characters')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('settings-category-1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('scraping-people-visible')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('extension-animation-mode')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
