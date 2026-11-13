// Opt-in public metadata probe. No library writes or credential output.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:http/http.dart' as http;
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/personal_scraper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const output = String.fromEnvironment('NO_ID_LIVE_OUTPUT');
  test('bounded live no-ID evidence probe', () async {
    HttpOverrides.global = null;
    final directory = Directory(const String.fromEnvironment('KONATA_SECRETS'));
    final storage = FlutterSecureStorageWindows(directory: directory, readLegacy: (_) async => null);
    await Metadata.loadCredentials((key) async {
      final name = base64Url.encode(utf8.encode(key));
      // Avoid the storage adapter's legacy migration/write path for absent keys.
      if (!await File('${directory.path}/$name.bin').exists()) return null;
      return storage.read(key: key, options: const {});
    });
    final records = <Map<String, Object?>>[];
    const partOutput = String.fromEnvironment('PART_EVIDENCE');
    if (partOutput.isNotEmpty) {
      final client = http.Client();
      try {
        final evidence = <String, Object?>{};
        for (final season in [1, 2]) {
          final response = await client.get(Metadata.credentials.uri('/tv/25891/season/$season', {'language': 'zh-CN'}), headers: Metadata.credentials.headers).timeout(const Duration(seconds: 8));
          expect(response.statusCode, 200);
          evidence['season_$season'] = jsonDecode(utf8.decode(response.bodyBytes));
        }
        final response = await client.get(Uri.parse('https://api.bgm.tv/v0/episodes?subject_id=130230&type=0&limit=100'), headers: {'User-Agent': 'Konata/0.1 (metadata verification)'}).timeout(const Duration(seconds: 8));
        expect(response.statusCode, 200);
        evidence['bangumi'] = jsonDecode(utf8.decode(response.bodyBytes));
        await File(partOutput).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
      } finally {
        client.close();
        Metadata.token = '';
        Metadata.apiKey = '';
      }
      return;
    }
    for (final query in ['NIGHT HEAD 2041', 'Soukyuu no Fafner Exodus', 'Urusei Yatsura', '蒼穹のファフナー EXODUS', 'うる星やつら']) {
      for (final provider in ['tmdb', 'bangumi']) {
        final client = http.Client();
        final watch = Stopwatch()..start();
        final record = <String, Object?>{'query': query, 'provider': provider};
        try {
          if (provider == 'tmdb' && !Metadata.credentials.isConfigured) {
            record['status'] = 'credential_unavailable';
            continue;
          }
          final response = provider == 'tmdb'
              ? await client.get(Metadata.credentials.uri('/search/multi', {'query': query, 'language': 'zh-CN'}), headers: Metadata.credentials.headers).timeout(const Duration(seconds: 8))
              : await client.post(Uri.parse('https://api.bgm.tv/v0/search/subjects?limit=10'), headers: {'Content-Type': 'application/json', 'User-Agent': 'Konata/0.1 (metadata verification)'}, body: jsonEncode({'keyword': query, 'sort': 'match', 'filter': {'type': [2]}})).timeout(const Duration(seconds: 8));
          record['http_status'] = response.statusCode;
          if (response.statusCode != 200) {
            record['status'] = 'http_failure';
            continue;
          }
          final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
          final rows = (data[provider == 'tmdb' ? 'results' : 'data'] as List).whereType<Map>().toList();
          record['status'] = 'received';
          record['total'] = data['total_results'] ?? data['total'];
          record['total_pages'] = data['total_pages'];
          record['candidates'] = [for (final row in rows.take(10)) {
            'id': row['id'], 'type': row['media_type'] ?? row['type'],
            'names': PersonalMetadataScraper.officialTitles(row).toList(),
            'date': row['first_air_date'] ?? row['release_date'] ?? row['date'],
          }];
          // Detail inspection is evidence collection, never an automatic binding.
          var exact = rows.where((row) => PersonalMetadataScraper.officialTitles(row).any((name) => PersonalMetadataScraper.exactTitle(query, name))).toList();
          record['detail_selection'] = 'unique_exact_name';
          if (exact.length != 1 && provider == 'tmdb') {
            final wanted = query.contains('Fafner') || query.contains('ファフナー') ? '2015' : query.contains('Yatsura') || query == 'うる星やつら' ? '1981' : '2021';
            exact = rows.where((row) => row['media_type'] == 'tv' && '${row['first_air_date']}'.startsWith(wanted)).toList();
            record['detail_selection'] = 'unique_tv_year_for_inspection_only';
          }
          if (exact.length == 1) {
            final row = exact.single;
            final type = row['media_type'];
            if (provider == 'bangumi' || ['tv', 'movie'].contains(type)) {
              final detail = provider == 'tmdb'
                  ? await client.get(Metadata.credentials.uri('/$type/${row['id']}', {'language': 'zh-CN', 'append_to_response': 'alternative_titles,translations'}), headers: Metadata.credentials.headers).timeout(const Duration(seconds: 8))
                  : await client.get(Uri.parse('https://api.bgm.tv/v0/subjects/${row['id']}'), headers: {'User-Agent': 'Konata/0.1 (metadata verification)'}).timeout(const Duration(seconds: 8));
              record['detail_status'] = detail.statusCode;
              if (detail.statusCode == 200) {
                final d = jsonDecode(utf8.decode(detail.bodyBytes)) as Map;
                record['detail'] = {'id': d['id'], 'names': PersonalMetadataScraper.officialTitles(d).toList(), 'date': d['first_air_date'] ?? d['release_date'] ?? d['date'], 'episodes': d['eps'], 'seasons': d['seasons']};
              }
            }
          }
        } catch (error) {
          record['status'] = 'request_or_decode_failure';
          record['error_type'] = error.runtimeType.toString();
        } finally {
          client.close();
          record['elapsed_ms'] = watch.elapsedMilliseconds;
          records.add(record);
          await File(output).writeAsString(const JsonEncoder.withIndent('  ').convert({'scope': 'public search/detail evidence, not production recognition or accuracy', 'records': records}));
        }
      }
    }
    Metadata.token = '';
    Metadata.apiKey = '';
    expect(records, hasLength(10));
  }, skip: output.isEmpty, timeout: const Timeout(Duration(minutes: 3)));
}
