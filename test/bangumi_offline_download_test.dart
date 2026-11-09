import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive_io.dart' as archive;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/bangumi_offline_index.dart';

class _Routes extends HttpOverrides {
  _Routes(this.port);
  final int port;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _Client(super.createHttpClient(context), port);
}

class _Client implements HttpClient {
  _Client(this.inner, this.port);
  final HttpClient inner;
  final int port;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) => inner.getUrl(
    Uri(scheme: 'http', host: '127.0.0.1', port: port, path: uri.path),
  );
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancelled official download resumes and validates before atomic replacement',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final root = await Directory.systemTemp.createTemp(
        'konata-offline-resume-',
      );
      addTearDown(() => root.delete(recursive: true));
      final random = Random(19);
      final lines = List.generate(
        3500,
        (i) => jsonEncode({
          'id': i + 1,
          'type': 2,
          'name': 'Work $i',
          'name_cn': '',
          'date': '2020-01-01',
          'summary': base64Encode(
            List.generate(768, (_) => random.nextInt(256)),
          ),
        }),
      );
      final content = utf8.encode('${lines.join('\n')}\n');
      final bytes = archive.ZipEncoder().encode(
        archive.Archive()..addFile(
          archive.ArchiveFile('subject.jsonlines', content.length, content),
        ),
      );
      final digest = sha256.convert(bytes).toString();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final ranges = <String?>[];
      var manifests = 0;
      var rawUnavailable = false;
      var apiFallbacks = 0;
      var redirects = 0;
      server.listen((request) async {
        try {
          if (request.uri.path.endsWith('latest.json')) {
            manifests++;
            final manifest = {
              'browser_download_url':
                  'https://github.com/bangumi/Archive/releases/download/archive/dump-test.zip',
              'size': bytes.length,
              'digest': 'sha256:$digest',
              'name': 'dump-test.zip',
            };
            if (request.uri.path.startsWith('/repos/')) {
              apiFallbacks++;
              request.response.write(
                jsonEncode({
                  'encoding': 'base64',
                  'content': base64Encode(utf8.encode(jsonEncode(manifest))),
                }),
              );
            } else if (rawUnavailable) {
              request.response.statusCode = 503;
            } else {
              request.response.write(jsonEncode(manifest));
            }
          } else if (request.uri.path.contains('/releases/download/')) {
            redirects++;
            request.response.statusCode = 302;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              'https://release-assets.githubusercontent.com/archive.zip',
            );
          } else {
            final range = request.headers.value(HttpHeaders.rangeHeader);
            ranges.add(range);
            final start = range == null
                ? 0
                : int.parse(RegExp(r'\d+').firstMatch(range)![0]!);
            request.response.statusCode = start == 0 ? 200 : 206;
            request.response.contentLength = bytes.length - start;
            if (start > 0) {
              request.response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes $start-${bytes.length - 1}/${bytes.length}',
              );
            }
            for (var offset = start; offset < bytes.length; offset += 65536) {
              request.response.add(
                bytes.sublist(offset, min(offset + 65536, bytes.length)),
              );
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
          }
          await request.response.close();
        } catch (_) {
          /* Deliberately cancelled client closes its connection. */
        }
      });
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _Routes(server.port);
      addTearDown(() => HttpOverrides.global = oldOverrides);
      final index = BangumiOfflineIndex(root);
      final snapshot = await index.checkLatest();
      expect(snapshot.bytes, bytes.length);
      await expectLater(
        index.install(
          progress: (phase, done, total) {
            if (phase == 'download') index.cancel();
          },
        ),
        throwsA(isA<OfflineIndexCancelled>()),
      );
      final saved = await File('${root.path}/archive.part').length();
      expect(saved, greaterThan(0));
      expect(saved, lessThan(bytes.length));
      expect(await index.status(), isNull);
      // A new instance models reopening settings after restarting the app.
      final reopened = BangumiOfflineIndex(root);
      await reopened.install(snapshot: snapshot);
      expect(redirects, greaterThanOrEqualTo(2));
      expect(
        manifests,
        2,
        reason: 'Pinned update must not fetch another manifest',
      );
      expect(ranges.last, 'bytes=$saved-');
      expect((await index.status())?['subjects'], '3500');
      expect(await File('${root.path}/archive.part').exists(), false);
      final downloads = ranges.length;
      await index.install();
      expect(
        ranges.length,
        downloads,
        reason: 'An up-to-date index must not download again',
      );
      final before = await File('${root.path}/animation.sqlite').readAsBytes();
      final generation = BangumiOfflineIndex.generation;
      await expectLater(
        index.install(
          snapshot: (
            url: snapshot.url,
            bytes: snapshot.bytes,
            digest: 'b' * 64,
            version: 'dump-next.zip',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await File('${root.path}/animation.sqlite').readAsBytes(), before);
      expect(BangumiOfflineIndex.generation, generation);
      expect(await File('${root.path}/archive.part').exists(), false);

      final local = File('${root.path}/renamed-official.zip');
      await local.writeAsBytes(bytes);
      await expectLater(
        index.install(
          zip: local,
          progress: (phase, done, total) {
            if (phase == 'index') index.cancel();
          },
        ),
        throwsA(isA<OfflineIndexCancelled>()),
      );
      expect(await File('${root.path}/animation.sqlite').readAsBytes(), before);
      expect(BangumiOfflineIndex.generation, generation);
      await index.install(zip: local);
      expect((await index.status())?['version'], 'renamed-official.zip');
      final beforeCheck = ranges.length;
      await index.install(snapshot: snapshot);
      expect(
        ranges.length,
        beforeCheck,
        reason: 'A renamed local copy of the latest archive is already current',
      );
      expect(
        await root.list().where((e) => e is Directory).toList(),
        isEmpty,
        reason: 'Success, cancellation and failure must clean staging data',
      );
      rawUnavailable = true;
      expect((await index.checkLatest()).digest, digest);
      expect(apiFallbacks, 1);
    },
  );
}
