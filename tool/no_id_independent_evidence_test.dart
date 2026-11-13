// Opt-in raw official API evidence; no scraper matching, library, or truth inference.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:http/http.dart' as http;
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const directory = String.fromEnvironment('REVIEW_EVIDENCE_DIRECTORY');
  test('collect independent public evidence plan', () async {
    HttpOverrides.global = null;
    final secrets = Directory(const String.fromEnvironment('KONATA_SECRETS'));
    final storage = FlutterSecureStorageWindows(directory: secrets, readLegacy: (_) async => null);
    await Metadata.loadCredentials((key) async =>
      await File('${secrets.path}/${base64Url.encode(utf8.encode(key))}.bin').exists()
        ? storage.read(key: key, options: const {}) : null);
    expect(Metadata.credentials.isConfigured, isTrue);
    final plan = jsonDecode(await File('$directory/plan.json').readAsString()) as List;
    expect(plan.length, lessThanOrEqualTo(300));
    final client = http.Client();
    final results = <Map<String, Object?>>[];
    try {
      for (final item in plan.cast<Map>()) {
        final record = <String, Object?>{'key': item['key'], 'provider': item['provider'],
          'path': item['path'], 'query': item['query'], 'body': item['body'],
          'route': item['route'] ?? 'official'};
        try {
          final query = Map<String, String>.from(item['query'] as Map? ?? {});
          final tmdb = item['provider'] == 'tmdb';
          var uri = tmdb ? Metadata.credentials.uri(item['path'] as String, query)
            : Uri.https('api.bgm.tv', item['path'] as String, query);
          if (item['route'] == 'backup') {
            final index = tmdb ? 0 : 2;
            uri = MetadataServers.endpoint(index, item['path'] as String,
                base: MetadataServers.defaults[index]).replace(queryParameters: uri.queryParameters);
          }
          record['host'] = uri.host;
          final headers = tmdb ? Metadata.credentials.headers : {
            'User-Agent': 'Konata/0.1 (independent metadata review)', 'Content-Type': 'application/json'};
          final response = await (item['body'] == null ? client.get(uri, headers: headers)
            : client.post(uri, headers: headers, body: jsonEncode(item['body'])))
            .timeout(const Duration(seconds: 8));
          record['status'] = response.statusCode;
          if (response.statusCode == 200) record['data'] = jsonDecode(utf8.decode(response.bodyBytes));
        } catch (error) {
          record['error_type'] = error.runtimeType.toString();
        }
        results.add(record);
        await File('$directory/evidence.json').writeAsString(const JsonEncoder.withIndent('  ').convert(results));
      }
    } finally {
      client.close(); Metadata.token = ''; Metadata.apiKey = '';
    }
    expect(results.length, plan.length);
  }, skip: directory.isEmpty, timeout: const Timeout(Duration(minutes: 15)));
}
