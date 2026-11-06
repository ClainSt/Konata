import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/metadata_http.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/bangumi_links.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live Bangumi 86 subjects, cast, cover and avatar decode',
    () async {
      HttpOverrides.global = null;
      final client = MetadataHttp(raw: true);
      final groups = <List<Map<String, dynamic>>>[];
      try {
        for (final id in [302189, 331887]) {
          final response = await client.get(
            MetadataServers.endpoint(2, 'subjects/$id'),
          );
          expect(response.statusCode, 200);
          final subject = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
          expect(subject['id'], id);
          expect(subject['name'], isNotEmpty);
          final castResponse = await client.get(
            MetadataServers.endpoint(2, 'subjects/$id/characters'),
          );
          expect(castResponse.statusCode, 200);
          final cast = (jsonDecode(utf8.decode(castResponse.bodyBytes)) as List)
              .whereType<Map>()
              .map((c) => Map<String, dynamic>.from(c))
              .toList();
          expect(cast, isNotEmpty);
          groups.add(cast);
          final cover = MetadataServers.mapImage(subject['images']['large']);
          final bytes = await ImageStore.download(cover);
          expect(bytes.length, greaterThan(1000));
          final avatar =
              cast.firstWhere(
                    (c) =>
                        c['images'] is Map && c['images']['medium'] is String,
                  )['images']['medium']
                  as String;
          final avatarBytes = await ImageStore.download(
            MetadataServers.mapImage(avatar),
          );
          expect(avatarBytes.length, greaterThan(100));
          // Only public IDs and result sizes appear in test output.
          // ignore: avoid_print
          print(
            'Bangumi $id: characters=${cast.length} cover=${bytes.length} avatar=${avatarBytes.length} bytes',
          );
        }
        final merged = BangumiLinks.mergeCharacters(groups);
        expect(
          merged.length,
          lessThan(groups.fold<int>(0, (n, g) => n + g.length)),
        );
      } finally {
        client.close();
      }
    },
    skip: !const bool.fromEnvironment('RUN_LIVE_METADATA'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
