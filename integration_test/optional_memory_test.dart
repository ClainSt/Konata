// Diagnostic entry point for the isolated Profile application only.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/ui/extensions_panel.dart';
import 'package:ccplayer/ui/optional_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryFixtureClient implements HttpClient {
  _MemoryFixtureClient(this.port);
  final int port;
  final delegate = HttpClient();
  @override
  Future<HttpClientRequest> getUrl(Uri uri) =>
      delegate.getUrl(Uri.http('127.0.0.1:$port', uri.path));
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const images = bool.fromEnvironment('MEMORY_IMAGES', defaultValue: true);
  const rounds = int.fromEnvironment('MEMORY_ROUNDS', defaultValue: 24);
  final weakSessions = <WeakReference<OptionalPeopleSession>>[];
  String phase = 'starting';
  Completer<void>? gate;
  var requests = 0;
  Future<Map<String, Object?>> sample() async {
    final rollup = await File('/proc/self/smaps_rollup').readAsString();
    return {
      'phase': phase,
      'images': images,
      'rssBytes': ProcessInfo.currentRss,
      'pssKiB': int.parse(
        RegExp(r'^Pss:\s+(\d+)', multiLine: true).firstMatch(rollup)![1]!,
      ),
      'requests': requests,
      'reachableSessions': weakSessions.where((r) => r.target != null).length,
      'activeSessions': weakSessions
          .where((r) => r.target?.disposed == false)
          .length,
      'imageCacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
      'liveImages': PaintingBinding.instance.imageCache.liveImageCount,
    };
  }

  developer.registerExtension('ext.konata.memoryProbe', (
    method,
    parameters,
  ) async {
    if (parameters['action'] == 'continue') {
      final pending = gate;
      gate = null;
      pending?.complete();
      return developer.ServiceExtensionResponse.result('{}');
    }
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'waiting': gate != null, ...await sample()}),
    );
  });
  Future<void> checkpoint(String label) async {
    phase = label;
    final pending = gate = Completer<void>();
    debugPrint('OPTIONAL_MEMORY_CHECKPOINT $label');
    await pending.future.timeout(const Duration(seconds: 90));
    weakSessions.removeWhere((r) => r.target == null);
  }

  testWidgets(
    'bounded repeated optional feature memory experiment',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final original = prefs.getString(OptionalFeatures.preferenceKey);
      await prefs.setString(OptionalFeatures.preferenceKey, '{}');
      final settings = OptionalFeatures();
      await settings.initialize();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final bytes = (await rootBundle.load(
        'assets/brand/tmdb-logo.png',
      )).buffer.asUint8List();
      server.listen((r) async {
        requests++;
        if (r.uri.path.endsWith('.png')) {
          r.response.add(bytes);
        } else {
          final data = r.uri.path.contains('/subjects/')
              ? List.generate(
                  12,
                  (i) => {
                    'id': i + 1,
                    'name': 'Character $i',
                    if (images)
                      'images': {'medium': 'https://lain.bgm.tv/char$i.png'},
                    'actors': [
                      {
                        'id': i + 101,
                        'name': 'Voice $i',
                        if (images)
                          'images': {
                            'medium': 'https://lain.bgm.tv/voice$i.png',
                          },
                      },
                    ],
                  },
                )
              : {
                  'cast': List.generate(
                    12,
                    (i) => {
                      'id': i + 1,
                      'name': 'Actor $i',
                      'character': 'Role $i',
                      if (images) 'profile_path': '/actor$i.png',
                    },
                  ),
                };
          r.response.headers.contentType = ContentType.json;
          r.response.write(jsonEncode(data));
        }
        await r.response.close();
      });
      Metadata.token = 'fixture-only';
      Metadata.authMode = 'token';
      OptionalPeopleSession create(OptionalFeatures s, OptionalFeature f) {
        final session = OptionalPeopleSession(
          s,
          f,
          clientFactory: () => _MemoryFixtureClient(port),
        );
        weakSessions.add(WeakReference(session));
        return session;
      }

      Future<void> waitFor(bool Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 15));
        while (!condition() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 50));
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

      final observations = <Map<String, Object?>>[];
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SafeArea(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      ExtensionsPanel(settings: settings),
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
            ),
          ),
        );
        await tester.pumpAndSettle();
        await checkpoint('off_0');
      for (var round = 1; round <= rounds; round++) {
          await select('角色');
          await tester.tap(find.byKey(const ValueKey('extension-credits')));
          await waitFor(
            () => !settings.saving && settings.enabled(OptionalFeature.credits),
          );
          await waitFor(
            () =>
                find.text('Actor 0').evaluate().isNotEmpty &&
                find.text('Character 0').evaluate().isNotEmpty,
          );
          if (images) {
            await waitFor(
              () => PaintingBinding.instance.imageCache.currentSizeBytes > 0,
            );
          }
          await tester.pumpAndSettle();
          await select('声优');
          await tester.pumpAndSettle();
          await select('关闭');
          await tester.tap(find.byKey(const ValueKey('extension-credits')));
          await waitFor(
            () =>
                !settings.saving && !settings.enabled(OptionalFeature.credits),
          );
          await tester.pumpAndSettle();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          expect(PaintingBinding.instance.imageCache.currentSizeBytes, 0);
          expect(PaintingBinding.instance.imageCache.liveImageCount, 0);
          expect(
            weakSessions.every((r) => r.target == null || r.target!.disposed),
            true,
          );
          phase = 'off_$round';
          observations.add(await sample());
        if ([4, 12, 24, 60, 100].contains(round) || round == rounds) {
          await checkpoint(phase);
        }
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(seconds: 5));
        await checkpoint('unmounted');
        binding.reportData = {'images': images, 'observations': observations};
      } finally {
        await tester.pumpWidget(const SizedBox());
        await server.close(force: true);
        settings.dispose();
        Metadata.token = '';
        if (original == null) {
          await prefs.remove(OptionalFeatures.preferenceKey);
        } else {
          await prefs.setString(OptionalFeatures.preferenceKey, original);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
