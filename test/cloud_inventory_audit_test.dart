// Opt-in private inventory audit. No media bytes or production catalog writes.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:http/http.dart' as http;
import 'package:ccplayer/core/auto_classifier.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/personal_filename_parser.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/work_season.dart';

class _ObservedMetadata extends http.BaseClient {
  static DateTime? resumeAfter;
  final inner = MetadataHttp();
  final responses = <Map<String, Object?>>[];
  final failures = <Map<String, Object?>>[];
  final verifiedTmdb = <String>{};
  int bytes = 0, requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final pause = resumeAfter?.difference(DateTime.now());
    if (pause != null && pause > Duration.zero) {
      await Future<void>.delayed(pause);
    }
    requests++;
    final safeUri = request.url.replace(
      queryParameters: {...request.url.queryParameters}..remove('api_key'),
    );
    final descriptor = <String, Object?>{
      'method': request.method,
      'uri': safeUri.toString(),
      if (request is http.Request && request.method == 'POST')
        'body': request.body,
    };
    try {
      final response = await inner.send(request);
      if (response.statusCode == 429) {
        final header = response.headers['retry-after'];
        final seconds = int.tryParse(header ?? '');
        DateTime? deadline;
        try {
          if (header != null) deadline = HttpDate.parse(header);
        } catch (_) {}
        final wait = seconds != null
            ? Duration(seconds: seconds)
            : deadline?.difference(DateTime.now()) ??
                  const Duration(seconds: 60);
        resumeAfter = DateTime.now().add(
          wait.isNegative ? Duration.zero : wait,
        );
      }
      final body = await response.stream.toBytes();
      Object? json;
      try {
        json = jsonDecode(utf8.decode(body));
      } catch (_) {}
      final identity = RegExp(
        r'^/3/(tv|movie)/(\d+)$',
      ).firstMatch(request.url.path);
      if (response.statusCode == 200 &&
          identity != null &&
          json is Map &&
          '${json['id']}' == identity[2]) {
        verifiedTmdb.add('${identity[1]}:${identity[2]}');
      }
      if (response.statusCode != 200 && response.statusCode != 404) {
        failures.add({...descriptor, 'status': response.statusCode});
      }
      if (bytes + body.length <= 2 * 1024 * 1024) {
        bytes += body.length;
        responses.add({
          ...descriptor,
          'status': response.statusCode,
          'response': json,
        });
      }
      return http.StreamedResponse(
        Stream.value(body),
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    } catch (error) {
      failures.add({...descriptor, 'error': error.runtimeType.toString()});
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

Map<String, Object?>? _identity(ScrapedWork? work) => work == null
    ? null
    : {
        'title': work.title,
        'tmdbId': work.tmdbId,
        'tmdbType': work.tmdbType,
        'bangumiId': work.bangumiId,
        'year': work.year,
        'provider': work.provider,
      };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'full private inventory online matching audit',
    () async {
      HttpOverrides.global = null;
      const input = String.fromEnvironment('CLOUD_INVENTORY');
      const output = String.fromEnvironment('AUDIT_OUTPUT');
      final root = Directory(output).absolute;
      await root.create(recursive: true);
      final fixtureDir = Directory('${root.path}/failures');
      await fixtureDir.create(recursive: true);
      final secrets = FlutterSecureStorageWindows(
        directory: Directory(const String.fromEnvironment('KONATA_SECRETS')),
        readLegacy: (_) async => null,
      );
      await Metadata.loadCredentials(
        (key) => secrets.read(key: key, options: const {}),
      );
      expect(Metadata.credentials.isConfigured, true);
      // Real network only: never miscount offline fallback as a fresh response.
      MetadataHttp.cacheDirectory = null;
      final rows = (jsonDecode(await File(input).readAsString()) as List)
          .cast<Map>();
      final groups = <String, List<Map<String, Object?>>>{};
      for (final row in rows) {
        final path = '${row['path']}/${row['name']}'.replaceFirst(
          RegExp(r'^/+'),
          '',
        );
        if (path
            .split('/')
            .any(
              (s) =>
                  RegExp(r'^(CDs?|Scans?)$', caseSensitive: false).hasMatch(s),
            )) {
          continue;
        }
        final decision = AutoClassifier.decide(
          selectedRoot: '${row['root']}',
          relativePath: path,
          rootHasDirectVideo: false,
          localRootName: '',
        );
        if (decision == null) continue;
        (groups[decision.folder] ??= []).add({
          'id': path,
          'name': row['name'],
          'category': Catalog.isExtra(path) ? 'extra' : 'main',
        });
      }
      final report = File('${root.path}/results.jsonl');
      final completed = <String>{};
      if (await report.exists()) {
        for (final line in await report.readAsLines()) {
          if (line.trim().isNotEmpty) {
            completed.add('${(jsonDecode(line) as Map)['folder']}');
          }
        }
      }
      final keys = groups.keys.toList()..sort();
      final limit = const int.fromEnvironment('AUDIT_LIMIT');
      final pending = keys
          .where((key) => !completed.contains(key))
          .take(limit > 0 ? limit : keys.length)
          .toList();
      var cursor = 0, fixtureBytes = 0, done = completed.length;
      for (final file in fixtureDir.listSync().whereType<File>()) {
        fixtureBytes += file.lengthSync();
      }
      final sink = report.openWrite(mode: FileMode.append);
      var writing = Future<void>.value();
      final concurrency = const int.fromEnvironment(
        'AUDIT_WORKERS',
        defaultValue: 2,
      ).clamp(1, 6);
      final stop = File('${root.path}/stop');
      final started = DateTime.now().toUtc();
      await File('${root.path}/run.json').writeAsString(
        jsonEncode({
          'started': started.toIso8601String(),
          'inventory': File(input).absolute.path,
          'totalFiles': rows.length,
          'groups': keys.length,
          'concurrency': concurrency,
          'credentialStoredInReport': false,
          'offlineFallback': false,
        }),
      );
      Future<void> worker() async {
        while (cursor < pending.length) {
          if (await stop.exists()) break;
          if (cursor >= pending.length) break;
          final folder = pending[cursor++];
          final files = groups[folder]!;
          final rawTitle = folder.split('/').last;
          final work = <String, Object?>{
            'id': 'work:audit:${Uri.encodeComponent(folder)}',
            'title': rawTitle,
          };
          final client = _ObservedMetadata();
          final scraper = PersonalMetadataScraper(client: client);
          final watch = Stopwatch()..start();
          final record = <String, Object?>{
            'folder': folder,
            'files': files.length,
            'expectedTmdbId': Catalog.tmdbId(folder),
            'year': Catalog.year(folder),
          };
          try {
            final baseline = await scraper.scrape(work);
            final baselineVerified =
                baseline?.tmdbId != null &&
                client.verifiedTmdb.contains(
                  '${baseline!.tmdbType}:${baseline.tmdbId}',
                );
            record['folderMatch'] = _identity(baseline);
            record['referenceFetched'] = baselineVerified;
            final plain = PersonalFilenameParser.withoutTmdbMarkers(
              rawTitle,
            ).trim();
            record['titleOnlyMatch'] = _identity(
              await scraper.scrape({
                'title': plain,
                'year': WorkSeason.year(work),
              }),
            );
            final distinct = <String, Map<String, Object?>>{};
            for (final file in files) {
              final parsed = PersonalMetadataScraper.filenameWork(
                '${file['name']}',
                supplementary: file['category'] == 'extra',
              );
              if (parsed != null) parsed['year'] ??= WorkSeason.year(work);
              final key = jsonEncode(parsed);
              final entry = distinct.putIfAbsent(
                key,
                () => {
                  'parsed': parsed,
                  'sample': file['name'],
                  'count': 0,
                  'main': file['category'] == 'main',
                },
              );
              entry['count'] = (entry['count'] as int) + 1;
              if (file['category'] == 'main') entry['main'] = true;
            }
            final decisions = <Map<String, Object?>>[];
            for (final entry in distinct.values) {
              final parsed = entry['parsed'] as Map<String, Object?>?;
              final result = parsed == null
                  ? null
                  : await scraper.scrape(parsed);
              final conflict =
                  result != null &&
                  baseline != null &&
                  !result.sameWork(baseline);
              final comparison = result == null
                  ? 'unmatched_or_ambiguous'
                  : baseline == null
                  ? 'no_reference'
                  : conflict
                  ? 'identity_conflict'
                  : baselineVerified
                  ? 'consistent_with_reference'
                  : 'consistent_unverified_reference';
              decisions.add({
                ...entry,
                'match': _identity(result),
                'comparison': parsed == null
                    ? 'episode_or_generic_extra'
                    : comparison,
              });
            }
            record['filenameIdentities'] = decisions;
            record['status'] =
                decisions.any((d) => d['comparison'] == 'identity_conflict')
                ? 'conflict'
                : baseline == null ||
                      decisions.any(
                        (d) =>
                            d['main'] == true &&
                            d['comparison'] == 'unmatched_or_ambiguous',
                      )
                ? 'needs_review'
                : 'matched';
          } catch (error) {
            record['status'] = 'error';
            record['error'] = error.runtimeType.toString();
          } finally {
            record['networkFailures'] = client.failures;
            record['requests'] = client.requests;
            record['ms'] = watch.elapsedMilliseconds;
            if (record['status'] != 'matched' &&
                fixtureBytes < 128 * 1024 * 1024) {
              final bytes = gzip.encode(
                utf8.encode(jsonEncode(client.responses)),
              );
              if (fixtureBytes + bytes.length <= 128 * 1024 * 1024) {
                final name =
                    '${keys.indexOf(folder).toString().padLeft(4, '0')}.json.gz';
                fixtureBytes += bytes.length;
                await File('${fixtureDir.path}/$name').writeAsBytes(bytes);
                record['fixture'] = 'failures/$name';
              }
            }
            scraper.close();
            client.close();
          }
          writing = writing.then((_) async {
            sink.writeln(jsonEncode(record));
            await sink.flush();
          });
          await writing;
          done++;
          // ignore: avoid_print
          print(
            'AUDIT_PROGRESS ${jsonEncode({'done': done, 'total': keys.length, 'folder': folder, 'status': record['status'], 'ms': record['ms'], 'requests': record['requests']})}',
          );
        }
      }

      try {
        await Future.wait(List.generate(concurrency, (_) => worker()));
      } finally {
        await writing;
        await sink.close();
        Metadata.token = '';
        Metadata.apiKey = '';
      }
    },
    timeout: const Timeout(Duration(hours: 24)),
    skip:
        const String.fromEnvironment('CLOUD_INVENTORY').isEmpty ||
        const String.fromEnvironment('AUDIT_OUTPUT').isEmpty,
  );
}
