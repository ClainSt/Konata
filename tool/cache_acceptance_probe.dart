// Explicit live-network acceptance entry point. Never used by lib/main.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ObservedClient implements HttpClient {
  _ObservedClient(this.requests);
  final List<String> requests;
  final HttpClient delegate = HttpClient();
  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    requests.add('${uri.host}${uri.path}');
    return delegate.getUrl(uri);
  }

  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<Map<String, Object?>> runCacheAcceptance() async {
  final support = await getApplicationSupportDirectory();
  final temporary = await getTemporaryDirectory();
  final normalArtwork = await ImageStore.directory();
  final run = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  // Isolate downloads, while retaining the production provider's parent path.
  final root = Directory(p.join(support.path, 'cache-acceptance', run));
  await root.create(recursive: true);
  await ImageStore.close();
  ImageStore.root = Directory(p.join(root.path, 'artwork'));
  await MetadataHttp.initialize();
  MetadataHttp.cacheDirectory = Directory(p.join(root.path, 'metadata_cache'));
  await MetadataHttp.cacheDirectory!.create();
  final prefs = await SharedPreferences.getInstance();
  final previous = prefs.getString(OptionalFeatures.preferenceKey);
  await prefs.setString(OptionalFeatures.preferenceKey, '{"characters":true}');
  final settings = OptionalFeatures();
  await settings.initialize();
  await MetadataServers.load();
  Metadata.token = '';
  Metadata.apiKey = '';
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'timestamp': run,
    'executable': Platform.resolvedExecutable,
    'support': support.path,
    'temporary': temporary.path,
    'defaultArtwork': normalArtwork.path,
    'measuredArtwork': ImageStore.root!.path,
    'servers': MetadataServers.values,
    'tmdbAuthenticated': false,
    'samples': <Object?>[],
  };
  void record(Map<String, Object?> value) {
    (report['samples'] as List).add(value);
    // ignore: avoid_print
    print('CACHE_SAMPLE ${jsonEncode(value)}');
  }

  try {
    for (final subject
        in const bool.fromEnvironment('CACHE_PROBE_SCRAPE_ONLY')
            ? <int>[]
            : [12, 302189]) {
      final work = <String, Object?>{
        'id': 'probe-$subject',
        'bangumi_id': subject,
      };
      List<String> urls = [];
      for (final mode in ['cold', 'warm']) {
        final requests = <String>[];
        final session = OptionalPeopleSession(
          settings,
          OptionalFeature.characters,
          clientFactory: () => _ObservedClient(requests),
        );
        final watch = Stopwatch()..start();
        int? cardsMs;
        Future<List<Object?>>? pictures;
        Future<List<Object?>> loadPictures(
          List<Map<String, dynamic>> cards,
        ) async {
          urls = cards
              .map((c) => c['image'])
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .take(4)
              .toList();
          return Future.wait(
            urls.map((url) async {
              final imageWatch = Stopwatch()..start();
              try {
                final bytes = await session.image(
                  url,
                  Completer<void>().future,
                );
                return <String, Object?>{
                  'ms': imageWatch.elapsedMilliseconds,
                  'readyFromStartMs': watch.elapsedMilliseconds,
                  'bytes': bytes.length,
                };
              } catch (error) {
                return <String, Object?>{'error': '$error'};
              }
            }),
          );
        }

        session.onCardsReady = (cards) {
          cardsMs ??= watch.elapsedMilliseconds;
          pictures ??= loadPictures(cards);
        };
        try {
          final cards = await session.load(work, 'zh');
          final completeMs = watch.elapsedMilliseconds;
          cardsMs ??= completeMs;
          pictures ??= loadPictures(cards);
          record({
            'kind': 'characters',
            'subject': subject,
            'mode': mode,
            'cards': cards.length,
            'cardsMs': cardsMs,
            'enrichmentMs': completeMs,
            'images': await pictures!,
            'networkRequests': requests.length,
            'requests': requests,
          });
        } catch (error) {
          record({
            'kind': 'characters',
            'subject': subject,
            'mode': mode,
            'error': '$error',
            'requests': requests,
          });
        } finally {
          session.dispose();
          await ImageStore.close();
        }
      }
      // Reopen SQLite and a new session with networking forbidden: proves disk hits.
      final offline = OptionalPeopleSession(
        settings,
        OptionalFeature.characters,
        clientFactory: () =>
            throw StateError('Unexpected network during disk check'),
      );
      final watch = Stopwatch()..start();
      try {
        final sizes = <int>[];
        for (final url in urls) {
          sizes.add(
            (await offline.image(url, Completer<void>().future)).length,
          );
        }
        record({
          'kind': 'offlineImages',
          'subject': subject,
          'count': sizes.length,
          'bytes': sizes,
          'ms': watch.elapsedMilliseconds,
        });
      } catch (error) {
        record({
          'kind': 'offlineImages',
          'subject': subject,
          'error': '$error',
        });
      } finally {
        offline.dispose();
      }
    }
    for (final work in [
      <String, Object?>{'title': '地狱乐', 'year': 2023},
      <String, Object?>{'title': 'ちょびっツ', 'year': 2002},
    ]) {
      final scraper = PersonalMetadataScraper();
      final watch = Stopwatch()..start();
      try {
        final result = await scraper.scrape(work);
        record({
          'kind': 'scrape',
          'query': work['title'],
          'ms': watch.elapsedMilliseconds,
          'matched': result != null,
          'provider': result?.provider,
          'subject': result?.bangumiId,
          'title': result?.title,
        });
      } catch (error) {
        record({'kind': 'scrape', 'query': work['title'], 'error': '$error'});
      } finally {
        scraper.close();
      }
    }
    report['diskBytes'] = await ImageStore.diskBytes();
    report['files'] = await root
        .list(recursive: true, followLinks: false)
        .where((e) => e is File)
        .map((e) => p.relative(e.path, from: root.path))
        .toList();
  } finally {
    settings.dispose();
    await ImageStore.close();
    if (previous == null) {
      await prefs.remove(OptionalFeatures.preferenceKey);
    } else {
      await prefs.setString(OptionalFeatures.preferenceKey, previous);
    }
  }
  await File(
    p.join(root.path, 'result.json'),
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  return report;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('图片缓存与刮削验收中，不播放视频'))),
    ),
  );
  try {
    final report = await runCacheAcceptance();
    final encoded = base64Encode(utf8.encode(jsonEncode(report)));
    for (var i = 0; i < encoded.length; i += 700) {
      // ignore: avoid_print
      print(
        'CACHE_RESULT_PART ${encoded.substring(i, i + 700 > encoded.length ? encoded.length : i + 700)}',
      );
    }
    // ignore: avoid_print
    print('CACHE_PROBE_DONE');
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('图片缓存与刮削采样完成'))),
      ),
    );
  } catch (error, stack) {
    // ignore: avoid_print
    print('CACHE_PROBE_FAILED $error\n$stack');
  }
}
