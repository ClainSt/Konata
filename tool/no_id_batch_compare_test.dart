// Explicit development comparison, same inputs, separate isolated libraries.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ccplayer/core/scan_recognition.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/selected_scan_workflow.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';

class ReviewClient extends http.BaseClient {
  final inner = http.Client();
  static int calls = 0;
  static final statuses = <String, int>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (++calls > 240) throw StateError('Review case request budget exhausted');
    try {
      final response = await inner.send(request).timeout(const Duration(seconds: 8));
      statuses.update('${response.statusCode}', (n) => n + 1, ifAbsent: () => 1);
      return response;
    } catch (_) {
      statuses.update('transport_failure', (n) => n + 1, ifAbsent: () => 1);
      rethrow;
    }
  }
  @override
  void close() => inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const output = String.fromEnvironment('REVIEW_COMPARE_DIRECTORY');
  const mode = String.fromEnvironment('REVIEW_COMPARE_MODE');
  const recheck = String.fromEnvironment('REVIEW_RECHECK_AUTOMATIC');
  const roundTrip = String.fromEnvironment('REVIEW_ROUND_TRIP');
  const ordinary = String.fromEnvironment('REVIEW_ORDINARY_TV');
  test('same batch legacy/new development observation', () async {
    HttpOverrides.global = null;
    // Opt-in Flutter test kept outside test/ to avoid normal network test runs.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    expect(['legacy', 'new'], contains(mode));
    final secrets = Directory(const String.fromEnvironment('KONATA_SECRETS'));
    final storage = FlutterSecureStorageWindows(directory: secrets, readLegacy: (_) async => null);
    await Metadata.loadCredentials((key) async =>
      await File('${secrets.path}/${base64Url.encode(utf8.encode(key))}.bin').exists()
        ? storage.read(key: key, options: const {}) : null);
    MetadataServers.fallback = false;
    final batch = jsonDecode(await File('$output/review-batch.json').readAsString()) as List;
    final catalog = Catalog.instance;
    final reports = <Map<String, Object?>>[];
    final run = await Directory(output).createTemp('$mode-');
    try {
      for (final sample in batch.cast<Map>()) {
        final key = sample['review_id'] as String;
        final media = await Directory('${run.path}/$key/media').create(recursive: true);
        for (final row in (sample['files'] as List).cast<Map>()) {
          final input = row['input'] as Map;
          final relative = '${input['path']}/${input['name']}'.replaceFirst(RegExp(r'^/+'), '');
          final file = File('${media.path}/$relative');
          await file.parent.create(recursive: true);
          await file.writeAsBytes([0, 0]);
        }
        ReviewClient.calls = 0; ReviewClient.statuses.clear();
        final clock = Stopwatch()..start();
        final revised = mode == 'new';
        await catalog.initialize(dataDirectory: Directory('${run.path}/$key/library'),
          enableFoundation: revised, enableTasks: revised, enableMappings: revised,
          enableRecognition: revised, enableAutomaticRecognition: revised);
        final report = <String, Object?>{'review_id': key, 'mode': mode};
        final legacyClient = ReviewClient();
        final scraper = PersonalMetadataScraper(client: legacyClient);
        try {
          final source = await catalog.addSource('local', 'Isolated review', media.path);
          for (final root in (sample['files'] as List).cast<Map>().map((r) => (r['input'] as Map)['root'] as String).toSet()) {
            await catalog.addScanRoot(source, root);
          }
          if (revised) {
            final runner = ScrapeTaskRunner(catalog, requests: SharedMetadataRequests(
              catalog.taskStore!, clientFactory: ReviewClient.new,
              deadline: const Duration(seconds: 8), retryDelays: const []));
            if (recheck.isNotEmpty) {
              expect(['automatic', 'manual', 'locked'], contains(recheck));
              // Seed only this newly created isolated catalog. Inventory comes
              // from the original sample; the known old automatic decision is
              // reproduced without invoking an old matcher or production data.
              final seed = ScrapeTaskRunner(catalog, requests: SharedMetadataRequests(
                catalog.taskStore!, clientFactory: () => MockClient((request) async => http.Response(
                  jsonEncode(request.url.path.contains('/3/')
                      ? {'results': [], 'total_pages': 1} : {'data': [], 'total': 0}), 200,
                  headers: {'content-type': 'application/json'}))));
              await seed.run(await seed.enqueueScan(source));
              final row = (await catalog.db.query('scan_bindings',
                  where: "layer='work' AND provider='bangumi'")).single;
              await seed.recognition.decide({...row,
                'session': (await catalog.db.query('scrape_runtime')).single['session'],
                'identity_revision': (await catalog.db.query('library_work_protection')).single['revision'],
              }, {'id': 92430, 'type': 'anime', 'title': '人生', 'year': 2014});
              final decision = (await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [row['id']])).single;
              if (recheck != 'manual') {
                await catalog.db.update('scan_bindings', {'reason': 'verified_bangumi',
                  'adopted': jsonEncode({...ScanRecognition.adopted(decision)!, 'by': 'verified_bangumi'})},
                  where: 'id=?', whereArgs: [row['id']]);
              }
              if (recheck == 'locked') {
                await catalog.db.update('library_work_protection', {'identity_locked': 1});
              }
              report['before_bindings'] = await catalog.db.query('scan_bindings', orderBy: 'id');
            }
            await runner.run(await runner.enqueueScan(source));
            if (recheck.isNotEmpty) {
              final after = await catalog.db.query('scan_bindings', orderBy: 'id');
              if (recheck == 'automatic') {
                for (final entry in {'tmdb': 44163, 'bangumi': 95618}.entries) {
                  final identity = after.singleWhere((r) => r['layer'] == 'work' && r['provider'] == entry.key);
                  expect(ScanRecognition.adopted(identity)?['id'], entry.value);
                  final episodes = after.where((r) => r['layer'] == 'episode' && r['provider'] == entry.key && r['state'] == 'confirmed');
                  expect(episodes.length, 12);
                  final assets = await catalog.db.query('assets');
                  for (final episode in episodes) {
                    final asset = assets.singleWhere((a) => a['id'] == episode['asset_id']);
                    expect(asset['category'], 'main');
                    final choice = ScanRecognition.adopted(episode)!;
                    expect(choice[entry.key == 'tmdb' ? 'episode' : 'sort'], asset['episode']);
                    if (entry.key == 'tmdb') expect(choice['season'], 1);
                  }
                }
              } else {
                expect(after, report['before_bindings']);
                expect(ReviewClient.calls, 0);
              }
              await runner.run(await runner.enqueueScan(source));
              expect(await catalog.db.query('scan_bindings', orderBy: 'id'), after);
              report['recheck_assertions'] = 'passed';
              if (roundTrip.isNotEmpty) {
                expect(recheck, 'automatic');
                expect(['delete', 'rename', 'mixed', 'manual', 'locked'], contains(roundTrip));
                final stages = <Map<String, Object?>>[];
                report['round_trip'] = stages;
                Future<List<Map<String, Object?>>> snapshot(String stage) async {
                  final bindings = await catalog.db.query('scan_bindings', orderBy: 'id');
                  stages.add({'stage': stage, 'bindings': bindings,
                    'assets': await catalog.db.query('assets'), 'requests': ReviewClient.calls,
                    'statuses': Map<String, int>.from(ReviewClient.statuses)});
                  return bindings;
                }
                final fixture = jsonDecode(await File('test/fixtures/breakblade_identity.json').readAsString()) as Map;
                Future<void> verifyMapping(List<Map<String, Object?>> bindings) async {
                  final assets = await catalog.db.query('assets');
                  for (final entry in {'tmdb': 44163, 'bangumi': 95618}.entries) {
                    final identity = bindings.singleWhere((b) => b['layer'] == 'work' && b['provider'] == entry.key);
                    expect(ScanRecognition.adopted(identity)?['id'], entry.value);
                    final episodes = bindings.where((b) => b['layer'] == 'episode' && b['provider'] == entry.key && b['state'] == 'confirmed').toList();
                    expect(episodes.length, 12);
                    for (final episode in episodes) {
                      final asset = assets.singleWhere((a) => a['id'] == episode['asset_id']);
                      expect(asset['category'], 'main');
                      final choice = ScanRecognition.adopted(episode)!;
                      final n = asset['episode'] as int;
                      if (entry.key == 'tmdb') {
                        expect(choice['season'], 1);
                        expect(choice['episode'], n);
                        final expected = (fixture['season']['episodes'] as List).singleWhere((e) => e['episode_number'] == n);
                        expect(choice['chapter_id'], expected['id']);
                      } else {
                        expect(choice['sort'], n);
                        expect(choice['subject'], 95618);
                        final expected = (fixture['episodes']['data'] as List).singleWhere((e) => e['sort'] == n);
                        expect(choice['id'], expected['id']);
                      }
                    }
                    expect(episodes.map((e) => assets.singleWhere((a) => a['id'] == e['asset_id'])['episode']).toSet(),
                        {for (var n = 1; n <= 12; n++) n});
                  }
                  for (final row in bindings.where((b) => b['parent'] != null)) {
                    final token = jsonDecode(row['parent'] as String) as List;
                    expect(bindings.singleWhere((b) => b['id'] == token[0])['revision'], token[1]);
                  }
                }
                final corrected = await snapshot('corrected');
                await verifyMapping(corrected);
                final asset = (await catalog.db.query('assets')).singleWhere((a) => a['category'] == 'main' && a['episode'] == 12);
                final target = File('${media.path}/${asset['relative_path']}');
                // All mutations are under the fresh isolated media directory.
                final changed = File('${target.parent.path}/[Other] Jinsei - ${roundTrip == 'mixed' ? '13' : '12'}.mkv');
                if (roundTrip == 'mixed') {
                  await changed.writeAsBytes([0, 0]);
                } else if (roundTrip == 'rename') {
                  await target.rename(changed.path);
                } else {
                  await target.delete();
                }
                await runner.run(await runner.enqueueScan(source));
                final revoked = await snapshot('revoked');
                if (roundTrip == 'mixed' || roundTrip == 'rename') {
                  final changedAsset = (await catalog.db.query('assets')).singleWhere((a) => a['name'] == changed.uri.pathSegments.last);
                  expect(changedAsset['category'], 'main');
                }
                expect(revoked.where((b) => b['state'] == 'confirmed'), isEmpty);
                expect(revoked.where((b) => b['layer'] == 'work').every((b) => b['reason'] == 'corrected_inventory_changed'), isTrue);
                expect(ReviewClient.calls, stages.first['requests']);
                if (roundTrip == 'manual') {
                  final row = revoked.singleWhere((b) => b['layer'] == 'work' && b['provider'] == 'bangumi');
                  await runner.recognition.decide({...row,
                    'session': (await catalog.db.query('scrape_runtime')).single['session'],
                    'identity_revision': (await catalog.db.query('library_work_protection')).single['revision'],
                  }, {'id': 95618, 'type': 'anime', 'title': '破刃之剑', 'year': 2014});
                } else if (roundTrip == 'locked') {
                  await catalog.db.update('library_work_protection', {'identity_locked': 1});
                }
                final beforeRestore = await snapshot('before_restore');
                final requestsBeforeRestore = ReviewClient.calls;
                if (roundTrip == 'mixed') {
                  await changed.delete();
                } else if (roundTrip == 'rename') {
                  await changed.rename(target.path);
                } else {
                  await target.writeAsBytes([0, 0]);
                }
                await runner.run(await runner.enqueueScan(source));
                final restored = await snapshot('restored');
                if (['manual', 'locked'].contains(roundTrip)) {
                  expect(restored, beforeRestore);
                  expect(ReviewClient.calls, requestsBeforeRestore);
                } else {
                  expect(ReviewClient.calls, greaterThan(requestsBeforeRestore));
                  await verifyMapping(restored);
                }
                await runner.run(await runner.enqueueScan(source));
                expect(await snapshot('rescan_unchanged'), restored);
                expect(ReviewClient.calls, stages[stages.length - 2]['requests']);
                if (roundTrip == 'locked') {
                  expect((await catalog.db.query('library_work_protection')).single['identity_locked'], 1);
                }
                report['round_trip_assertions'] = 'passed';
              }
            }
            if (ordinary.isNotEmpty) {
              expect(['fresh', 'existing', 'manual_bg', 'manual_tmdb', 'locked'], contains(ordinary));
              final all = jsonDecode(await File('test/fixtures/ordinary_tv_identity.json').readAsString()) as List;
              final fixture = all.where((r) => r['key'] == key).singleOrNull as Map?;
              Future<void> verifyOrdinary() async {
                final rows = await catalog.db.query('scan_bindings');
                final bgEpisodes = rows.where((r) => r['provider'] == 'bangumi' && r['layer'] == 'episode' && r['state'] == 'confirmed').toList();
                if (fixture == null) {
                  expect(key, 'review-014');
                  expect(bgEpisodes, isEmpty); // Unverified filename abbreviation.
                  return;
                }
                final assets = await catalog.db.query('assets');
                final bgWork = rows.singleWhere((r) => r['provider'] == 'bangumi' && r['layer'] == 'work');
                final tvWork = rows.singleWhere((r) => r['provider'] == 'tmdb' && r['layer'] == 'work');
                expect(ScanRecognition.adopted(bgWork)?['id'], fixture['bangumi']['id']);
                expect(ScanRecognition.adopted(tvWork)?['id'], fixture['tmdb']['id']);
                expect(bgEpisodes.length, (fixture['episodes']['data'] as List).length);
                for (final row in bgEpisodes) {
                  final asset = assets.singleWhere((a) => a['id'] == row['asset_id']);
                  final choice = ScanRecognition.adopted(row)!;
                  final expected = (fixture['episodes']['data'] as List).singleWhere((e) => e['sort'] == asset['episode']);
                  expect(choice['id'], expected['id']);
                  expect(choice['subject'], fixture['bangumi']['id']);
                  final tvEpisode = rows.singleWhere((r) => r['asset_id'] == row['asset_id'] && r['provider'] == 'tmdb');
                  final tvChoice = ScanRecognition.adopted(tvEpisode)!;
                  final expectedTv = (fixture['season']['episodes'] as List).singleWhere((e) => e['episode_number'] == asset['episode']);
                  expect(tvChoice['season'], 1);
                  expect(tvChoice['episode'], asset['episode']);
                  expect(tvChoice['chapter_id'], expectedTv['id']);
                }
                expect(rows.where((r) => r['provider'] == 'bangumi' && r['state'] == 'confirmed' &&
                    assets.any((a) => a['id'] == r['asset_id'] && (a['category'] != 'main' || a['episode'] == 0))), isEmpty);
              }
              await verifyOrdinary();
              if (ordinary != 'fresh') {
                expect(fixture, isNotNull);
                // Reproduce the observed old state in this isolated library:
                // identities are automatic, Bangumi ranges/episodes unconfirmed.
                await catalog.db.rawUpdate("UPDATE scan_bindings SET state='pending', adopted=NULL, previous=NULL, candidates='[]', reason=CASE WHEN layer='range' THEN 'range_unconfirmed' ELSE 'episode_unconfirmed' END, revision=revision+1 WHERE provider='bangumi' AND layer!='work'");
                final bgWork = (await catalog.db.query('scan_bindings', where: "provider='bangumi' AND layer='work'")).single;
                await catalog.db.update('scan_bindings', {'reason': 'verified_bangumi',
                  'adopted': jsonEncode({...ScanRecognition.adopted(bgWork)!, 'by': 'verified_bangumi'})},
                  where: 'id=?', whereArgs: [bgWork['id']]);
                if (ordinary.startsWith('manual_')) {
                  final provider = ordinary == 'manual_bg' ? 'bangumi' : 'tmdb';
                  final row = (await catalog.db.query('scan_bindings', where: 'provider=? AND layer=?', whereArgs: [provider, 'work'])).single;
                  await runner.recognition.decide({...row,
                    'session': (await catalog.db.query('scrape_runtime')).single['session'],
                    'identity_revision': (await catalog.db.query('library_work_protection')).single['revision'],
                  }, ScanRecognition.adopted(row)!);
                } else if (ordinary == 'locked') {
                  await catalog.db.update('library_work_protection', {'identity_locked': 1});
                }
                report['ordinary_before'] = await catalog.db.query('scan_bindings', orderBy: 'id');
                final priorRequests = ReviewClient.calls;
                await runner.run(await runner.enqueueScan(source));
                report['ordinary_recheck_requests'] = ReviewClient.calls - priorRequests;
                if (ordinary == 'existing') {
                  expect(ReviewClient.calls, greaterThan(priorRequests));
                  await verifyOrdinary();
                } else {
                  expect(await catalog.db.query('scan_bindings', orderBy: 'id'), report['ordinary_before']);
                  expect(ReviewClient.calls, priorRequests);
                }
              }
              final stable = await catalog.db.query('scan_bindings', orderBy: 'id');
              await runner.run(await runner.enqueueScan(source));
              expect(await catalog.db.query('scan_bindings', orderBy: 'id'), stable);
              report['ordinary_assertions'] = 'passed';
            }
          } else {
            await SelectedScanWorkflow.run(catalog.sources.single, scraper: scraper);
          }
          report['works'] = await catalog.db.query('works');
          report['assets'] = await catalog.db.query('assets');
          if (revised) {
            report['bindings'] = await catalog.db.query('scan_bindings');
            report['tasks'] = await catalog.db.query('scrape_tasks', columns: ['id', 'state']);
          }
          report['status'] = 'observed';
        } catch (error) {
          report['status'] = 'execution_failure'; report['error_type'] = error.runtimeType.toString();
        } finally {
          scraper.close(); legacyClient.close();
          catalog.taskStore?.dispose(); catalog.taskStore = null;
          await catalog.db.close();
          report['elapsed_ms'] = clock.elapsedMilliseconds;
          report['requests'] = ReviewClient.calls;
          report['statuses'] = Map<String, int>.from(ReviewClient.statuses);
          reports.add(report);
          await File('$output/$mode-results.json').writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
        }
      }
    } finally { Metadata.token = ''; Metadata.apiKey = ''; }
    expect(reports.length, batch.length);
    if (recheck.isNotEmpty) {
      expect(reports.every((r) => r['status'] == 'observed' && r['recheck_assertions'] == 'passed'), isTrue);
    }
    if (roundTrip.isNotEmpty) {
      expect(reports.every((r) => r['round_trip_assertions'] == 'passed'), isTrue);
    }
    if (ordinary.isNotEmpty) {
      expect(reports.every((r) => r['ordinary_assertions'] == 'passed' && r['status'] == 'observed'), isTrue);
    }
  }, skip: output.isEmpty, timeout: const Timeout(Duration(minutes: 30)));
}
