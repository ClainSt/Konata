import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/scrape_task_runner.dart';
import 'package:ccplayer/core/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const clipPath = String.fromEnvironment('KONATA_READONLY_CLIP');
  test(
    'strict WebDAV scan, incomplete listing, and real Range bytes',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final root = await Directory.systemTemp.createTemp('konata-scrape-dav-');
      final clip = clipPath.isEmpty
          ? await File(
              '${root.path}/clip.mkv',
            ).writeAsBytes(List<int>.generate(4096, (i) => i % 256))
          : File(clipPath);
      final length = await clip.length();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var incomplete = false;
      var listingRequests = 0, rangeRequests = 0;
      server.listen((request) async {
        final response = request.response;
        try {
          if (request.method == 'PROPFIND' && request.uri.path == '/fixture/') {
            listingRequests++;
            response.statusCode = 207;
            response.headers.contentType = ContentType(
              'application',
              'xml',
              charset: 'utf-8',
            );
            response.write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/fixture/</d:href><d:propstat>
  <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
  <d:status>HTTP/1.1 200 OK</d:status>
 </d:propstat></d:response>
 <d:response><d:href>/fixture/E01.mkv</d:href>
  ${incomplete ? '<d:status>HTTP/1.1 403 Forbidden</d:status>' : '''
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>$length</d:getcontentlength></d:prop>
  <d:status>HTTP/1.1 200 OK</d:status></d:propstat>'''}
 </d:response>
</d:multistatus>''');
            return;
          }
          if (request.uri.path != '/fixture/E01.mkv' ||
              !['GET', 'HEAD'].contains(request.method)) {
            response.statusCode = 404;
            return;
          }
          response.headers.set('Accept-Ranges', 'bytes');
          final match = RegExp(
            r'^bytes=(\d+)-(\d*)$',
          ).firstMatch(request.headers.value('Range') ?? '');
          final start = match == null ? 0 : int.parse(match[1]!);
          final end = match == null || match[2]!.isEmpty
              ? length - 1
              : int.parse(match[2]!);
          if (start >= length || end < start || end >= length) {
            response.statusCode = 416;
            response.headers.set('Content-Range', 'bytes */$length');
            return;
          }
          if (match != null) {
            rangeRequests++;
            response.statusCode = 206;
            response.headers.set('Content-Range', 'bytes $start-$end/$length');
          }
          response.contentLength = end - start + 1;
          if (request.method == 'GET')
            await response.addStream(clip.openRead(start, end + 1));
        } finally {
          await response.close();
        }
      });
      final cat = Catalog.instance;
      SharedPreferences.setMockInitialValues({});
      HttpClient? client;
      Uri? ticket;
      var opened = false;
      try {
        await cat.initialize(
          dataDirectory: Directory('${root.path}/library'),
          enableFoundation: true,
          enableTasks: true,
          enableMappings: true,
          enableRecognition: true,
          enableScopedArtwork: true,
          enableChapterRelations: true,
          enableLibraryMerge: true,
        );
        opened = true;
        final source = await cat.addSource(
          'webdav',
          'Controlled DAV',
          'http://127.0.0.1:${server.port}/fixture/',
        );
        await cat.addScanRoot(source, '');
        final runner = ScrapeTaskRunner.forCatalog(cat);
        final initial = await runner.enqueueScan(source);
        await runner.run(initial);
        expect(cat.assets, hasLength(1));
        expect(cat.assets.single['size'], length);
        final assetId = cat.assets.single['id'];
        incomplete = true;
        final second = await runner.enqueueScan(source);
        await runner.run(second);
        expect(
          (await cat.db.query(
            'scrape_tasks',
            where: 'id=?',
            whereArgs: [second],
          )).single['state'],
          'failed',
        );
        expect(await cat.db.query('scan_missing_assets'), isEmpty);
        expect(cat.assets.single['id'], assetId);
        ticket = await StreamBroker.instance.issue(
          cat.sourceOf(source),
          'E01.mkv',
          purpose: 'playback',
        );
        client = HttpClient();
        final request = await client.getUrl(ticket);
        request.headers.set('Range', 'bytes=200-455');
        final response = await request.close();
        expect(response.statusCode, 206);
        final bytes = await response.expand((chunk) => chunk).toList();
        final original = await clip
            .openRead(200, 456)
            .expand((chunk) => chunk)
            .toList();
        expect(bytes, original);
        // ignore: avoid_print
        print(
          'KONATA_SCRAPE_DAV ${jsonEncode({'actual_fixture': clipPath.isNotEmpty, 'asset_bytes': length, 'listings': listingRequests, 'upstream_ranges': rangeRequests, 'verified_range_bytes': bytes.length, 'partial_listing_kept_asset': true})}',
        );
      } finally {
        client?.close(force: true);
        if (ticket != null) StreamBroker.instance.revoke(ticket);
        await server.close(force: true);
        if (opened) {
          cat.taskStore?.dispose();
          cat.taskStore = null;
          await cat.db.close();
        }
        await root.delete(recursive: true);
      }
    }, _LoopbackHttpOverrides()),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
