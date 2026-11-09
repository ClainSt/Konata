// Run only in the isolated .profile application, never against the user catalog.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/extensions_panel.dart';
import 'package:ccplayer/ui/optional_details.dart';
import 'package:ccplayer/ui/optional_scraping_settings.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FixtureClient implements HttpClient {
  _FixtureClient(this.port);
  final int port;
  final delegate = HttpClient();
  @override
  Future<HttpClientRequest> getUrl(Uri uri) => delegate.getUrl(
    Uri.http('127.0.0.1:$port', uri.path, uri.queryParameters),
  );
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('OPTIONAL_LIVE_ONLY')) {
    testWidgets('Bangumi HTTPS metadata and native image decoding on device', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(OptionalFeatures.preferenceKey);
      await prefs.setString(OptionalFeatures.preferenceKey, '{}');
      final settings = OptionalFeatures();
      await settings.initialize();
      await settings.setCharacterPresentation(1);
      final session = OptionalPeopleSession(
        settings,
        OptionalFeature.characters,
      );
      try {
        final cards = await session.load({'bangumi_id': 12}, 'en');
        expect(cards, isNotEmpty);
        final url = cards
            .map((c) => c['image'])
            .whereType<String>()
            .firstWhere((s) => s.isNotEmpty);
        final bytes = await session.image(url, Completer<void>().future);
        expect(bytes, isNotEmpty);
        await settings.setCharacterPresentation(0);
        expect(session.disposed, true);
        expect(session.cachedImageBytes, 0);
        binding.reportData = {
          'liveBangumi': {
            'passed': true,
            'subjectId': 12,
            'cards': cards.length,
            'imageBytes': bytes.length,
            'disposedOnDisable': true,
          },
        };
      } finally {
        session.dispose();
        settings.dispose();
        if (saved == null) {
          await prefs.remove(OptionalFeatures.preferenceKey);
        } else {
          await prefs.setString(OptionalFeatures.preferenceKey, saved);
        }
      }
    });
    return;
  }
  testWidgets(
    'optional features: device IO, decoded images, toggles and idle resources',
    (tester) async {
      final report = <String, dynamic>{
        'mode': 'profile',
        'samples': [],
        'checks': <String>[],
      };
      binding.reportData = report;
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(OptionalFeatures.preferenceKey);
      await prefs.setString(OptionalFeatures.preferenceKey, '{}');
      final settings = OptionalFeatures();
      await settings.initialize();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final portrait = (await rootBundle.load(
        'assets/brand/tmdb-logo.png',
      )).buffer.asUint8List();
      var requests = 0;
      var stall = false;
      final sessions = <OptionalPeopleSession>[];
      server.listen((request) async {
        requests++;
        if (stall) return;
        if (request.uri.path.endsWith('.png')) {
          request.response.add(portrait);
        } else {
          Object data = {};
          if (request.uri.path.contains('/subjects/')) {
            data = List.generate(
              12,
              (i) => {
                'id': i + 1,
                'name': '角色 ${i + 1}',
                'name_cn': '角色 ${i + 1}',
                'relation': '主角',
                'images': {'medium': 'https://lain.bgm.tv/character$i.png'},
                'actors': [
                  {
                    'id': i + 101,
                    'name': '声优 ${i + 1}',
                    'name_cn': '声优 ${i + 1}',
                    'images': {'medium': 'https://lain.bgm.tv/voice$i.png'},
                  },
                ],
              },
            );
          } else if (request.uri.path.contains('/credits')) {
            data = {
              'cast': List.generate(
                12,
                (i) => {
                  'id': i + 1,
                  'name': '演员 ${i + 1}',
                  'character': '角色 ${i + 1}',
                  'profile_path': '/actor$i.png',
                },
              ),
            };
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(data));
        }
        await request.response.close();
      });
      Metadata.token = 'local-fixture-only';
      Metadata.authMode = 'token';
      OptionalPeopleSession create(OptionalFeatures s, OptionalFeature f) {
        final session = OptionalPeopleSession(
          s,
          f,
          clientFactory: () => _FixtureClient(server.port),
        );
        sessions.add(session);
        return session;
      }

      Widget host(Widget child) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SafeArea(child: child)),
      );
      Future<void> waitFor(bool Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (!condition() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(condition(), true);
      }

      Future<void> select(String label) async {
        await tester.tap(
          find.byKey(const ValueKey('extension-animation-mode')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pump();
        await waitFor(() => !settings.saving);
        await tester.pump();
      }

      Future<Map<String, Object?>> resources(String phase) async {
        final sample = <String, Object?>{
          'phase': phase,
          'time': DateTime.now().toUtc().toIso8601String(),
          'rssBytes': ProcessInfo.currentRss,
          'requests': requests,
          'imageCacheBytes':
              PaintingBinding.instance.imageCache.currentSizeBytes,
          'liveImages': PaintingBinding.instance.imageCache.liveImageCount,
          'sessionsAlive': sessions.where((s) => !s.disposed).length,
          'clients': sessions.fold<int>(0, (n, s) => n + s.activeClients),
          'timers': sessions.fold<int>(0, (n, s) => n + s.activeTimers),
          'encodedImageBytes': sessions.fold<int>(
            0,
            (n, s) => n + s.cachedImageBytes,
          ),
        };
        try {
          final stat = await File('/proc/self/stat').readAsString();
          final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
          sample['cpuTicks'] = int.parse(fields[11]) + int.parse(fields[12]);
          final mem = await File('/proc/self/smaps_rollup').readAsString();
          sample['pssKiB'] = int.parse(
            RegExp(r'^Pss:\s+(\d+)', multiLine: true).firstMatch(mem)![1]!,
          );
          sample['fdCount'] = await Directory('/proc/self/fd').list().length;
        } catch (e) {
          sample['procMetricError'] = e.runtimeType.toString();
        }
        (report['samples'] as List).add(sample);
        debugPrint('OPTIONAL_DEVICE ${jsonEncode(sample)}');
        return sample;
      }

      Future<void> idle(String phase) async {
        await tester.pumpAndSettle();
        await resources('${phase}_start');
        // No forced frames or periodic sampling during the measured idle interval.
        await Future<void>.delayed(const Duration(seconds: 10));
        await resources('${phase}_end');
      }

      try {
        await tester.pumpWidget(
          host(
            SingleChildScrollView(
              child: Column(
                children: [
                  ExtensionsPanel(settings: settings),
                  OptionalScrapingSettings(settings: settings),
                  OptionalDetails(
                    settings: settings,
                    work: const {'is_animation': 1, 'bangumi_id': 42},
                    sessionFactory: create,
                  ),
                  OptionalDetails(
                    settings: settings,
                    work: const {
                      'is_animation': 0,
                      'tmdb_id': 42,
                      'tmdb_type': 'movie',
                    },
                    sessionFactory: create,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await idle('initial_off');
        expect(sessions, isEmpty);
        expect(requests, 0);
        (report['checks'] as List).add('off creates no services or requests');
        for (var round = 1; round <= 4; round++) {
          await select('角色');
          await tester.tap(find.byKey(const ValueKey('extension-credits')));
          await waitFor(
            () => settings.enabled(OptionalFeature.credits) && !settings.saving,
          );
          await waitFor(
            () =>
                find.text('演员 1').evaluate().isNotEmpty &&
                find.text('角色 1').evaluate().isNotEmpty,
          );
          await waitFor(
            () => PaintingBinding.instance.imageCache.currentSizeBytes > 0,
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('scraping-characters')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('scraping-credits')),
            findsOneWidget,
          );
          await resources('round_${round}_on');
          await select('声优');
          await waitFor(() => find.text('声优 1').evaluate().isNotEmpty);
          final restored = OptionalFeatures();
          await restored.initialize();
          expect(restored.characterPresentation, 2);
          expect(restored.enabled(OptionalFeature.credits), true);
          restored.dispose();
          await select('关闭');
          await tester.tap(find.byKey(const ValueKey('extension-credits')));
          await waitFor(
            () =>
                !settings.enabled(OptionalFeature.credits) && !settings.saving,
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('scraping-characters')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('scraping-credits')), findsNothing);
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
          expect(PaintingBinding.instance.imageCache.currentSizeBytes, 0);
          expect(PaintingBinding.instance.imageCache.liveImageCount, 0);
          final count = requests;
          await idle('round_${round}_off');
          expect(requests, count);
          sessions.clear();
        }
        (report['checks'] as List).add(
          'four enable/voice/disable cycles; native decoded image cache cleared; idle receives no requests',
        );
        stall = true;
        await select('角色');
        await waitFor(
          () => sessions.isNotEmpty && sessions.last.activeClients > 0,
        );
        await select('关闭');
        await tester.pumpAndSettle();
        expect(
          sessions.every(
            (s) => s.disposed && s.activeClients == 0 && s.activeTimers == 0,
          ),
          true,
        );
        (report['checks'] as List).add(
          'in-flight device HTTP request cancelled by UI',
        );
        stall = false;

        // Genuine HTTPS provider and image fetch from this device, separate from fixtures.
        await settings.setCharacterPresentation(1);
        final live = OptionalPeopleSession(
          settings,
          OptionalFeature.characters,
        );
        try {
          final cards = await live.load({'bangumi_id': 12}, 'en');
          final url = cards
              .map((c) => c['image'])
              .whereType<String>()
              .firstWhere((s) => s.isNotEmpty);
          final bytes = await live.image(url, Completer<void>().future);
          report['liveBangumi'] = {
            'passed': cards.isNotEmpty && bytes.isNotEmpty,
            'subjectId': 12,
            'cards': cards.length,
            'imageBytes': bytes.length,
          };
        } catch (e) {
          report['liveBangumi'] = {
            'passed': false,
            'errorType': e.runtimeType.toString(),
          };
        } finally {
          live.dispose();
          await settings.setCharacterPresentation(0);
        }
        // Screenshot real settings navigation after the resource measurements.
        await tester.pumpWidget(
          host(
            SettingsPage(
              embedded: true,
              wideLayout: true,
              featureSettings: settings,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-category-6')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('extension-animation-mode')),
          findsOneWidget,
        );
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        await binding.takeScreenshot('tablet-extensions-off');
        await select('声优');
        await tester.tap(find.byKey(const ValueKey('extension-credits')));
        await tester.pumpAndSettle();
        await binding.takeScreenshot('tablet-extensions-on');
        await tester.tap(find.byKey(const ValueKey('settings-category-1')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('scraping-characters')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('scraping-credits')), findsOneWidget);
        await binding.takeScreenshot('tablet-scraping-enabled');
        expect(tester.takeException(), isNull);
        (report['checks'] as List).add(
          'real settings navigation and screenshots',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (final session in sessions) {
          session.dispose();
        }
        settings.dispose();
        await server.close(force: true);
        Metadata.token = '';
        if (saved == null) {
          await prefs.remove(OptionalFeatures.preferenceKey);
        } else {
          await prefs.setString(OptionalFeatures.preferenceKey, saved);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
