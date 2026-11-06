import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/sources.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const video = String.fromEnvironment('DAV_LOCAL_VIDEO');
  testWidgets(
    'verify original bytes through the configured DAV playback broker',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('ccplayer-dav-audit-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      final live = await databaseFactoryFfi.openDatabase(
        p.join(
          Platform.environment['APPDATA']!,
          'com.clainst',
          'Konata',
          'ccplayer.db',
        ),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final client = HttpClient();
      try {
        final matches = await live.rawQuery(
          'SELECT s.*, a.relative_path AS audit_path FROM sources s JOIN assets a ON a.source_id=s.id WHERE s.kind=? AND a.name=?',
          ['webdav', p.basename(video)],
        );
        expect(matches.length, 1);
        final source = matches.single;
        final path = source['audit_path'] as String;
        final broker = StreamBroker.instance;
        final subtitles = await broker.subtitles(source, path);
        final paths = [
          path,
          ...subtitles.where(
            (v) => File(
              p.join(p.dirname(video), p.posix.basename(v)),
            ).existsSync(),
          ),
        ];
        expect(paths.any((v) => v.endsWith('.sc.ass')), isTrue);
        for (final relative in paths) {
          final local = File(
            p.join(p.dirname(video), p.posix.basename(relative)),
          );
          final uri = await broker.issue(source, relative);
          try {
            final request = await client.getUrl(uri);
            final response = await request.close().timeout(
              const Duration(seconds: 40),
            );
            expect(response.statusCode, 200);
            var bytes = 0;
            final remoteDigest = await sha256
                .bind(
                  response.timeout(const Duration(seconds: 45)).map((chunk) {
                    bytes += chunk.length;
                    return chunk;
                  }),
                )
                .first;
            final localDigest = await sha256.bind(local.openRead()).first;
            expect(bytes, await local.length());
            expect(remoteDigest, localDigest);
            debugPrint(
              'DAV_BYTE_PROOF ${jsonEncode({'suffix': p.posix.basename(relative).split(']').last, 'bytes': bytes, 'sha256': remoteDigest.toString()})}',
            );
          } finally {
            broker.revoke(uri);
          }
        }
      } finally {
        client.close(force: true);
        await live.close();
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || video.isEmpty,
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
