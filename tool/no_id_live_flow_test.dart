// Explicit isolated scan-to-binding verification; no production library access.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/scan_recognition.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/shared_metadata_requests.dart';

class _Observed extends http.BaseClient {
  final http.Client inner = http.Client();
  static int calls = 0;
  static const requestLimit = int.fromEnvironment('NO_ID_FLOW_REQUEST_LIMIT', defaultValue: 120);
  static final statuses = <String, int>{};
  static final resources = <Map<String, Object?>>[];
  static final transportErrors = <Map<String, Object?>>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (requestLimit < 1 || requestLimit > 400 || ++calls > requestLimit) {
      throw StateError('Probe request budget exhausted');
    }
    resources.add({
      'host': request.url.host,
      'path': request.url.path,
      for (final key in ['query', 'page', 'offset'])
        if (request.url.queryParameters.containsKey(key)) key: request.url.queryParameters[key],
    });
    try {
      final response = await inner.send(request);
      final key = '${request.url.host}:${response.statusCode}';
      statuses.update(key, (v) => v + 1, ifAbsent: () => 1);
      return response;
    } catch (error) {
      statuses.update('transport_failure', (v) => v + 1, ifAbsent: () => 1);
      // Never record exception text or request headers: they can contain
      // credentials or full private URLs. Types and OS codes suffice here.
      transportErrors.add({'host': request.url.host, 'type': '${error.runtimeType}',
        if (error is SocketException) 'os_error': error.osError?.errorCode});
      rethrow;
    }
  }
  @override
  void close() => inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const output = String.fromEnvironment('NO_ID_FLOW_DIRECTORY');
  test('isolated live no-ID scan and persisted bindings', () async {
    HttpOverrides.global = null;
    // This opt-in Flutter test lives under tool/ to avoid normal test runs.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final secretDir = Directory(const String.fromEnvironment('KONATA_SECRETS'));
    final storage = FlutterSecureStorageWindows(directory: secretDir, readLegacy: (_) async => null);
    await Metadata.loadCredentials((key) async {
      if (!await File('${secretDir.path}/${base64Url.encode(utf8.encode(key))}.bin').exists()) return null;
      return storage.read(key: key, options: const {});
    });
    expect(Metadata.credentials.isConfigured, true);
    MetadataServers.fallback = const bool.fromEnvironment('NO_ID_FLOW_FALLBACK');
    final samples = (jsonDecode(await File('$output/samples.json').readAsString()) as List).cast<Map>();
    const resume = String.fromEnvironment('NO_ID_FLOW_RESUME_RUN');
    if (resume.isNotEmpty) expect(RegExp(r'^run-[a-f0-9]+$').hasMatch(resume), isTrue);
    final scratch = resume.isEmpty ? await Directory(output).createTemp('run-') : Directory('$output/$resume');
    if (resume.isNotEmpty) {
      final root = (await Directory(output).resolveSymbolicLinks()).toLowerCase();
      final resolved = (await scratch.resolveSymbolicLinks()).toLowerCase();
      expect(resolved.startsWith('$root${Platform.pathSeparator}'), isTrue);
      expect(await File('${scratch.path}/library/ccplayer.db').exists(), isTrue);
    }
    final media = await Directory('${scratch.path}/media').create();
    for (final sample in resume.isEmpty ? samples : <Map>[]) {
      if (sample['add_after_scan'] == true) continue;
      final file = File('${media.path}/${sample['folder']}/${sample['name']}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([0, 0]); // Naming fixture only; never played.
    }
    final catalog = Catalog.instance;
    await catalog.initialize(dataDirectory: Directory('${scratch.path}/library'),
      enableFoundation: true, enableTasks: true, enableMappings: true,
      enableRecognition: true, enableAutomaticRecognition: true);
    final watch = Stopwatch()..start();
    try {
      final sources = resume.isEmpty ? <Map<String, Object?>>[] : await catalog.db.query('sources');
      if (resume.isNotEmpty) {
        expect(sources, hasLength(1));
        expect(sources.single['label'], 'Isolated live samples');
        expect(sources.single['kind'], 'local');
        expect((await Directory(sources.single['location'] as String).resolveSymbolicLinks()).toLowerCase(),
            (await media.resolveSymbolicLinks()).toLowerCase());
      }
      final source = resume.isEmpty
          ? await catalog.addSource('local', 'Isolated live samples', media.path)
          : sources.single['id'] as String;
      if (resume.isEmpty) await catalog.addScanRoot(source, '');
      final runner = ScrapeTaskRunner(catalog, requests: SharedMetadataRequests(
        catalog.taskStore!, clientFactory: _Observed.new,
        deadline: const Duration(seconds: 8), retryDelays: const []));
      await runner.run(await runner.enqueueScan(source));
      final transition = <String, Object?>{};
      const mutation = String.fromEnvironment('NO_ID_FLOW_MUTATION');
      final mutationResult = <String, Object?>{};
      Map<String, Object?>? manualDecision;
      final manualMode = mutation.startsWith('manual_');
      if (mutation.isNotEmpty) {
        expect(['delete', 'rename', 'mix', 'manual_tmdb_range', 'manual_tmdb_episode',
          'manual_bangumi_range', 'manual_bangumi_episode'], contains(mutation));
        final initial = await catalog.db.query('scan_bindings', orderBy: 'id');
        await File('$output/before-mutation.json').writeAsString(const JsonEncoder.withIndent('  ').convert(initial));
        final bound = initial.where((r) => r['layer'] == 'episode' && r['state'] == 'confirmed').toList();
        expect(bound, hasLength(26));
        expect(bound.where((r) => r['provider'] == 'tmdb').map((r) => ScanRecognition.adopted(r)?['episode']), unorderedEquals([for (var n = 1; n <= 13; n++) n]));
        expect(bound.where((r) => r['provider'] == 'bangumi').map((r) => ScanRecognition.adopted(r)?['sort']), unorderedEquals([for (var n = 14; n <= 26; n++) n]));
        if (manualMode) {
          final parts = mutation.split('_');
          final row = initial.firstWhere((r) => r['provider'] == parts[1] && r['layer'] == parts[2]);
          await runner.recognition.decide({
            ...row,
            'session': (await catalog.db.query('scrape_runtime')).single['session'],
            'identity_revision': (await catalog.db.query('library_work_protection',
              where: 'work_id=?', whereArgs: [row['work_id']])).single['revision'],
          }, ScanRecognition.adopted(row)!);
          manualDecision = (await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [row['id']])).single;
          await File('$output/manual-before.json').writeAsString(const JsonEncoder.withIndent('  ').convert(manualDecision));
        }
        final sample = samples.singleWhere((s) => s['expected_bangumi_sort'] == 20);
        final original = File('${media.path}/${sample['folder']}/${sample['name']}');
        final changedName = (sample['name'] as String).replaceFirst('[20]', '[01]');
        final target = File('${media.path}/${sample['folder']}/$changedName');
        final calls = _Observed.calls;
        if (mutation == 'delete') {
          await original.delete();
        } else if (mutation == 'rename') {
          await original.rename(target.path);
        } else {
          await target.writeAsBytes([0, 0]);
        }
        await runner.run(await runner.enqueueScan(source));
        if (manualDecision != null) {
          final after = (await catalog.db.query('scan_bindings', where: 'id=?', whereArgs: [manualDecision['id']])).single;
          await File('$output/manual-after.json').writeAsString(const JsonEncoder.withIndent('  ').convert(after));
          expect(after, manualDecision);
        }
        mutationResult.addAll({'kind': mutation, 'initial_confirmed_episodes': bound.length,
          if (manualMode) 'manual_record_unchanged': true,
          'additional_requests': _Observed.calls - calls});
      }
      if (samples.any((sample) => sample['add_after_scan'] == true)) {
        final initial = await catalog.db.query('scan_bindings', orderBy: 'id');
        await File('$output/before-fill.json').writeAsString(const JsonEncoder.withIndent('  ').convert(initial));
        expect(initial.where((row) => row['layer'] == 'episode' && ScanRecognition.adopted(row) != null), isEmpty);
        final calls = _Observed.calls;
        for (final sample in samples.where((sample) => sample['add_after_scan'] == true)) {
          final file = File('${media.path}/${sample['folder']}/${sample['name']}');
          await file.writeAsBytes([0, 0]);
        }
        await runner.run(await runner.enqueueScan(source));
        transition.addAll({'executed': true, 'initial_confirmed_episodes': 0,
          'additional_requests': _Observed.calls - calls});
      }
      final locations = await catalog.db.query('library_locations', where: "kind='work'");
      final rows = await catalog.db.query('scan_bindings', where: "layer='work'");
      final assets = await catalog.db.query('library_locations', where: "kind='asset'");
      final episodeRows = await catalog.db.query('scan_bindings', where: "layer='episode'");
      final before = await catalog.db.query('scan_bindings', orderBy: 'id');
      final beforeRequests = _Observed.calls;
      const rescan = bool.fromEnvironment('NO_ID_FLOW_RESCAN');
      if (rescan) {
        await runner.run(await runner.enqueueScan(source));
      }
      final unchanged = !rescan || jsonEncode(before) == jsonEncode(await catalog.db.query('scan_bindings', orderBy: 'id'));
      final report = {
        'scope': 'live isolated naming fixtures; identity truth not globally annotated',
        'elapsed_ms': watch.elapsedMilliseconds, 'requests': _Observed.calls,
        'statuses': _Observed.statuses,
        'fallback_enabled': MetadataServers.fallback,
        'resumed_run': resume.isEmpty ? null : resume,
        'resources': _Observed.resources,
        'transport_errors': _Observed.transportErrors,
        'fill_transition': transition,
        'mutation': mutationResult,
        'rescan': {'executed': rescan, 'bindings_unchanged': unchanged,
          'additional_requests': _Observed.calls - beforeRequests},
        'ranges': [for (final row in await catalog.db.query('scan_bindings', where: "layer='range'")) {
          'folder': locations.where((l) => l['entity_id'] == row['work_id']).firstOrNull?['relative_path'],
          'provider': row['provider'], 'state': row['state'], 'reason': row['reason'],
          'selection': {for (final field in ['season', 'first', 'last', 'offset', 'id'])
            field: ScanRecognition.adopted(row)?[field]},
        }],
        'episodes': [for (final row in episodeRows) {
          'file': assets.where((a) => a['entity_id'] == row['scope']).firstOrNull?['relative_path'],
          'folder': locations.where((l) => l['entity_id'] == row['work_id']).firstOrNull?['relative_path'],
          'provider': row['provider'], 'state': row['state'],
          'selection': {for (final field in ['id', 'subject', 'sort', 'season', 'episode', 'chapter_id'])
            field: ScanRecognition.adopted(row)?[field]},
        }],
        'bindings': [for (final row in rows) {
          'folder': locations.where((l) => l['entity_id'] == row['work_id']).firstOrNull?['relative_path'],
          'provider': row['provider'], 'state': row['state'], 'reason': row['reason'],
          'adopted': ScanRecognition.adopted(row),
          'candidates': ScanRecognition.candidates(row),
        }],
      };
      await File('$output/results.json').writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      final folders = samples.map((sample) => sample['folder']).toSet();
      expect(locations.length, folders.length);
      expect(rows.length, folders.length * 2);
      expect(unchanged, isTrue);
      for (final sample in samples.where((s) => s['expected_tmdb_movie'] != null)) {
        final work = locations.singleWhere((l) => l['relative_path'] == sample['folder'])['entity_id'];
        final tv = rows.singleWhere((r) => r['work_id'] == work && r['provider'] == 'tmdb');
        final bg = rows.singleWhere((r) => r['work_id'] == work && r['provider'] == 'bangumi');
        expect(tv['state'], 'confirmed');
        expect(ScanRecognition.adopted(tv)?['type'], 'movie');
        expect(ScanRecognition.adopted(tv)?['id'], sample['expected_tmdb_movie']);
        expect(bg['state'], 'confirmed');
        expect(ScanRecognition.adopted(bg)?['id'], sample['expected_bangumi_subject']);
      }
      if (mutation.isNotEmpty) {
        final remaining = episodeRows.where((r) => ScanRecognition.adopted(r) != null).toList();
        if (manualDecision == null) {
          expect(remaining, isEmpty);
        } else if (manualDecision['layer'] == 'episode') {
          expect(remaining, [manualDecision]);
        } else {
          expect(remaining.every((r) => r['provider'] == manualDecision!['provider']), isTrue);
        }
        final ranges = await catalog.db.query('scan_bindings', where: "layer='range'");
        expect(ranges, hasLength(2));
        for (final range in ranges) {
          if (range['id'] == manualDecision?['id']) {
            expect(range, manualDecision);
            continue;
          }
          expect(range['state'], 'pending');
          expect(range['reason'], 'part_inventory_changed');
          expect(ScanRecognition.adopted(range), isNull);
        }
      }
      for (final sample in samples.where((sample) => sample['expected_unbound'] == true)) {
        final asset = assets.singleWhere((a) => a['relative_path'] == '${sample['folder']}/${sample['name']}');
        for (final provider in ['tmdb', 'bangumi']) {
          final matching = episodeRows.where((r) => r['provider'] == provider && r['scope'] == asset['entity_id']).toList();
          expect(matching.length, lessThanOrEqualTo(1));
          // An unconfirmed range may intentionally have no episode row yet.
          for (final row in matching) {
            expect(row['state'], 'pending');
            expect(ScanRecognition.adopted(row), isNull);
          }
        }
      }
      for (final sample in samples.where((sample) => mutation.isEmpty && sample['expected_tmdb_episode'] != null)) {
        final asset = assets.singleWhere((a) => a['relative_path'] == '${sample['folder']}/${sample['name']}');
        for (final provider in ['tmdb', 'bangumi']) {
          final matching = episodeRows.where((r) => r['provider'] == provider && r['scope'] == asset['entity_id']).toList();
          expect(matching, hasLength(1),
              reason: 'Missing or duplicate $provider episode binding: ${sample['folder']}/${sample['name']}');
          final row = matching.single;
          expect(row['state'], 'confirmed');
          final selected = ScanRecognition.adopted(row)!;
          if (provider == 'tmdb') {
            expect(selected['season'], sample['expected_tmdb_season'] ?? 2);
            expect(selected['episode'], sample['expected_tmdb_episode']);
          } else {
            expect(selected['subject'], sample['expected_bangumi_subject'] ?? 130230);
            expect(selected['sort'], sample['expected_bangumi_sort']);
            if (sample['expected_bangumi_episode'] != null) {
              expect(selected['id'], sample['expected_bangumi_episode']);
            }
          }
        }
      }
    } finally {
      catalog.taskStore?.dispose();
      catalog.taskStore = null;
      await catalog.db.close();
      Metadata.token = '';
      Metadata.apiKey = '';
    }
  }, skip: output.isEmpty, timeout: const Timeout(Duration(minutes: 10)));
}
