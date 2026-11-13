// Opt-in verification of production classification against private inventory.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:ccplayer/core/auto_classifier.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/bangumi_offline_index.dart';
import 'package:ccplayer/core/personal_filename_parser.dart';

class _ObservedClient extends http.BaseClient {
  final http.Client inner = http.Client();
  int requests = 0, searches = 0, failures = 0;
  final statuses = <String, int>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    if (request.url.path.contains('/search')) searches++;
    try {
      final response = await inner.send(request);
      statuses.update(
        '${response.statusCode}',
        (v) => v + 1,
        ifAbsent: () => 1,
      );
      return response;
    } catch (_) {
      failures++;
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real inventory candidate fixes use live production classification',
    () async {
      HttpOverrides.global = null;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      const input = String.fromEnvironment('CLOUD_INVENTORY');
      const output = String.fromEnvironment('CANDIDATE_OUTPUT');
      final credentials = FlutterSecureStorageWindows(
        directory: Directory(const String.fromEnvironment('KONATA_SECRETS')),
        readLegacy: (_) async => null,
      );
      await Metadata.loadCredentials(
        (key) => credentials.read(key: key, options: const {}),
      );
      expect(Metadata.credentials.isConfigured, true);
      MetadataHttp.cacheDirectory = null;
      final selected = const String.fromEnvironment(
        'CANDIDATE_IDS',
      ).split(',').where((s) => s.isNotEmpty).map(int.parse).toSet();
      const remaining = String.fromEnvironment('CANDIDATE_REMAINING');
      final remainingFolders = <String>{};
      if (remaining.isNotEmpty) {
        for (final name in ['unmatched', 'conflicts', 'network-errors']) {
          final rows =
              jsonDecode(await File('$remaining/$name.json').readAsString())
                  as List;
          remainingFolders.addAll(rows.map((r) => r['folder'] as String));
        }
      }
      final groups = <String, List<Map<String, Object?>>>{};
      for (final row
          in (jsonDecode(await File(input).readAsString()) as List)
              .cast<Map>()) {
        final path = '${row['path']}/${row['name']}'.replaceFirst(
          RegExp(r'^/+'),
          '',
        );
        if (Catalog.isExtra(path)) continue;
        final decision = AutoClassifier.decide(
          selectedRoot: '${row['root']}',
          relativePath: path,
          rootHasDirectVideo: false,
          localRootName: '',
        );
        if (decision == null ||
            !(remaining.isEmpty
                ? selected.contains(Catalog.tmdbId(decision.folder))
                : remainingFolders.contains(decision.folder))) {
          continue;
        }
        (groups[decision.folder] ??= []).add({
          'id': path,
          'relative_path': path,
          'name': row['name'],
          'category': 'main',
        });
      }
      final report = File(output);
      await report.parent.create(recursive: true);
      final finished = <String>{};
      if (remaining.isNotEmpty && await report.exists()) {
        for (final line in await report.readAsLines()) {
          if (line.trim().isNotEmpty) {
            finished.add((jsonDecode(line) as Map)['folder'] as String);
          }
        }
      }
      final sink = report.openWrite(
        mode: remaining.isEmpty ? FileMode.write : FileMode.append,
      );
      Future<void> writing = Future.value();
      Future<void> recordRow(Map<String, Object?> row) {
        return writing = writing.then((_) async {
          sink.writeln(jsonEncode(row));
          await sink.flush();
        });
      }

      try {
        const compare = bool.fromEnvironment('CANDIDATE_AB');
        for (var round = 0; round < (compare ? 2 : 1); round++) {
          final queue = groups.entries
              .where((e) => !finished.contains(e.key))
              .iterator;
          Future<void> worker() async {
            while (queue.moveNext()) {
              final entry = queue.current;
              for (final enabled
                  in (compare
                      ? (round == 0 ? [false, true] : [true, false])
                      : [true])) {
                const offlinePath = String.fromEnvironment('BANGUMI_INDEX');
                final observed = _ObservedClient();
                final transport = MetadataHttp(inner: observed, fresh: compare);
                final scraper = PersonalMetadataScraper(
                  client: transport,
                  offlineIndex: !enabled || offlinePath.isEmpty
                      ? null
                      : BangumiOfflineIndex(Directory(offlinePath)),
                );
                final watch = Stopwatch()..start();
                Map<String, Object?> metrics() => {
                  'round': round + 1,
                  'offline': enabled && offlinePath.isNotEmpty,
                  'requests': observed.requests,
                  'searches': observed.searches,
                  'transportFailures': observed.failures,
                  'httpStatuses': observed.statuses,
                };
                try {
                  final rawTitle = entry.key.split('/').last;
                  final reasons = <String, String>{};
                  final results = await scraper.classify(
                    {
                      'title': const bool.fromEnvironment('CANDIDATE_NO_ID')
                          ? PersonalFilenameParser.withoutTmdbMarkers(rawTitle)
                          : rawTitle,
                    },
                    entry.value,
                    reasons: reasons,
                  );
                  final counts = <String, int>{};
                  final samples = <String, String>{};
                  for (final file in entry.value) {
                    final match = results[file['id']];
                    final key = match == null
                        ? 'pending'
                        : '${match.tmdbType}:${match.tmdbId}|bgm:${match.bangumiId}|${match.title}';
                    counts.update(key, (v) => v + 1, ifAbsent: () => 1);
                    samples.putIfAbsent(key, () => '${file['name']}');
                  }
                  final record = {
                    ...metrics(),
                    'folder': entry.key,
                    'files': entry.value.length,
                    'ms': watch.elapsedMilliseconds,
                    'decisions': counts,
                    'samples': samples,
                    'reasonCounts': {
                      for (final reason in reasons.values.toSet())
                        reason: reasons.values.where((r) => r == reason).length,
                    },
                  };
                  await recordRow(record);
                  // ignore: avoid_print
                  print('CANDIDATE_VERIFICATION ${jsonEncode(record)}');
                } catch (error) {
                  final record = {
                    ...metrics(),
                    'folder': entry.key,
                    'files': entry.value.length,
                    'ms': watch.elapsedMilliseconds,
                    'error': error.runtimeType.toString(),
                    'reasonCounts': {
                      observed.failures > 0 ||
                                  observed.statuses.keys.any(
                                    (s) => int.parse(s) >= 400 && s != '404',
                                  )
                              ? 'network_incomplete'
                              : 'processing_error':
                          entry.value.length,
                    },
                  };
                  await recordRow(record);
                  // ignore: avoid_print
                  print('CANDIDATE_ERROR ${jsonEncode(record)}');
                } finally {
                  scraper.close();
                  transport.close();
                }
              }
            }
          }

          await Future.wait(
            List.generate(remaining.isEmpty ? 1 : 4, (_) => worker()),
          );
        }
      } finally {
        await sink.close();
        Metadata.token = '';
        Metadata.apiKey = '';
      }
    },
    timeout: const Timeout(Duration(hours: 12)),
    skip:
        const String.fromEnvironment('CLOUD_INVENTORY').isEmpty ||
        const String.fromEnvironment('CANDIDATE_OUTPUT').isEmpty,
  );
}
