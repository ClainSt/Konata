import 'dart:async';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:test/test.dart';

void main() {
  for (final owned in [false, true]) {
    for (final path in ['https://fixture.invalid/poster.png', '/poster.png']) {
      test('网络图片请求跨越内存清理 owned=$owned path=$path', () async {
        final root = await Directory.systemTemp.createTemp(
          'konata_http_epoch_',
        );
        addTearDown(() => root.delete(recursive: true));
        final cache = ArtworkDiskCache(
          photosStorage: PhotosStorage(overrideRoot: root),
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        final bytes = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 42];
        var requests = 0;
        final client = TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'fixture'),
          scheduler: PriorityHttpScheduler(),
          httpClient: MockClient((_) async {
            requests++;
            if (requests == 1) {
              entered.complete();
              await release.future;
            }
            return http.Response.bytes(
              bytes,
              200,
              headers: {'content-type': 'image/png'},
            );
          }),
        );
        addTearDown(client.close);
        final service = TmdbService(httpClient: client, artworkCache: cache);
        final owner = owned ? 'work-fixture' : null;
        final folder = owned ? PhotoSubfolder.posters : null;
        Future<List<int>> fetch() => service.fetchImageBytes(
          path,
          size: TmdbImageSize.w500,
          ownerWorkId: owner,
          subfolder: folder,
        );
        final pending = fetch();
        try {
          await entered.future.timeout(const Duration(seconds: 5));
          cache.clearMemoryCache();
          expect(cache.memoryEntryCount, 0);
        } finally {
          release.complete();
        }
        expect(await pending, bytes);
        final lateEntries = cache.memoryEntryCount;
        stdout.writeln(
          'HTTP_EPOCH_VERIFIED owned=$owned path=$path lateEntries=$lateEntries',
        );
        // 清理前请求完成后不能重新占用已释放的内存预算。
        expect(lateEntries, 0);
        expect(await fetch(), bytes);
        expect(requests, owned ? 1 : 2);
        expect(cache.memoryEntryCount, 1);
      });
    }
  }
}
