import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/ui/managed_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('konata-artwork-');
    ImageStore.root = root;
  });
  tearDown(() async {
    await ImageStore.close();
    ImageStore.root = null;
    await root.delete(recursive: true);
  });

  test(
    'removing one work does not cancel another work sharing its download',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (!received.isCompleted) received.complete();
        await release.future;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
        await request.response.close();
      });
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          final url = 'http://127.0.0.1:${server.port}/shared.png';
          final first = ImageStore.load(url, owner: 'one');
          final removed = expectLater(first, throwsStateError);
          await received.future;
          final second = ImageStore.load(url, owner: 'two');
          // Let the second consumer join the in-flight request before removal.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await ImageStore.removeWork('one');
          release.complete();
          expect(await second, png);
          await removed;
          expect(requests, 1);
          expect(await ImageStore.readCached(url), png);
          await ImageStore.removeWork('two');
          expect(await ImageStore.readCached(url), isNull);
        }, _RealHttp());
      } finally {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
      }
    },
  );

  test(
    'decoded image keys share across routes but isolate different work owners',
    () async {
      const url = 'https://lain.bgm.tv/shared.png';
      final first = await const ManagedImageProvider(
        url,
        owner: 'one',
      ).obtainKey(ImageConfiguration.empty);
      final same = await const ManagedImageProvider(
        url,
        owner: 'one',
      ).obtainKey(ImageConfiguration.empty);
      final other = await const ManagedImageProvider(
        url,
        owner: 'two',
      ).obtainKey(ImageConfiguration.empty);
      expect(first, same);
      expect(first, isNot(other));
      // Drain ownership writes started by obtainKey before closing the test DB.
      await ImageStore.retain('two', [url]);
    },
  );

  test(
    'persistent images deduplicate content and survive reopen and trim',
    () async {
      await ImageStore.retain('a', ['https://lain.bgm.tv/a.png']);
      await ImageStore.retain('b', ['https://lain.bgm.tv/b.png']);
      await ImageStore.storeCached('https://lain.bgm.tv/a.png', png);
      await ImageStore.storeCached('https://lain.bgm.tv/b.png', png);
      var cache = await ImageStore.cache;
      expect(
        await cache.images.list(recursive: true).where((f) => f is File).length,
        1,
      );
      await cache.trimUnowned(limit: 0);
      await ImageStore.close();
      expect(await ImageStore.readCached('https://lain.bgm.tv/a.png'), png);
      await ImageStore.removeWork('a');
      cache = await ImageStore.cache;
      expect(
        await cache.images.list(recursive: true).where((f) => f is File).length,
        1,
      );
      expect(await ImageStore.readCached('https://lain.bgm.tv/b.png'), png);
      await ImageStore.removeWork('b');
      expect(
        await cache.images.list(recursive: true).where((f) => f is File).length,
        0,
      );
    },
  );

  test(
    'same URL shared by works remains until the last owner is removed',
    () async {
      const url = 'https://lain.bgm.tv/shared.png';
      await ImageStore.retain('one', [url]);
      await ImageStore.retain('two', [url]);
      await ImageStore.storeCached(url, png);
      await ImageStore.removeWork('one');
      expect(await ImageStore.readCached(url), png);
      await ImageStore.removeWork('two');
      expect(await ImageStore.readCached(url), isNull);
    },
  );

  test(
    'higher-resolution variant replaces the lower one and is reused by smaller cards',
    () async {
      const small = 'https://image.tmdb.org/t/p/w300/frame.jpg';
      const large = 'https://image.tmdb.org/t/p/original/frame.jpg';
      await ImageStore.retain('one', [small]);
      await ImageStore.storeCached(small, png);
      expect(await ImageStore.readCached(large), isNull);
      final high = Uint8List.fromList([...png, 0]);
      await ImageStore.storeCached(large, high);
      expect(await ImageStore.readCached(small), high);
      await ImageStore.storeCached(small, png);
      expect(await ImageStore.readCached(large), high);
      expect(
        await (await ImageStore.cache).images
            .list(recursive: true)
            .where((f) => f is File)
            .length,
        1,
      );
    },
  );

  test(
    'old cache migrates locally; mirror URLs share the canonical identity',
    () async {
      const url = 'https://image.tmdb.org/t/p/w500/example.jpg';
      final hash = sha256.convert(utf8.encode(ImageStore.legacyIdentity(url)));
      final legacy = File('${root.path}/cache_$hash');
      await legacy.writeAsBytes(png);
      expect(await ImageStore.readCached(url), png);
      expect(await legacy.exists(), false);
      expect(
        await ImageStore.readCached(
          '${MetadataServers.defaults[1]}w500/example.jpg',
        ),
        png,
      );
    },
  );

  test(
    'cancelled writes never publish bytes or index; user originals survive removal',
    () async {
      final cache = await ImageStore.cache;
      var checks = 0;
      await expectLater(
        cache.write(
          'cancelled',
          png,
          checkActive: () {
            if (++checks == 2) throw StateError('cancelled');
          },
        ),
        throwsStateError,
      );
      expect(await cache.read('cancelled'), isNull);
      expect(
        await cache.images.list(recursive: true).where((f) => f is File).length,
        0,
      );
      final original = await ImageStore.save(png, 'original');
      await ImageStore.removeWork('one');
      expect(await ImageStore.load(original), png);
    },
  );

  test(
    'disk usage measures existing files, including manual additions/removals',
    () async {
      expect(await ImageStore.diskBytes(), 0);
      final file = File('${root.path}/actual.jpg');
      await file.writeAsBytes(Uint8List(12345));
      expect(await ImageStore.diskBytes(), 12345);
      await file.delete();
      expect(await ImageStore.diskBytes(), 0);
    },
  );

  test(
    'a damaged higher-quality file can be replaced by a valid download',
    () async {
      const high = 'https://image.tmdb.org/t/p/original/broken.jpg';
      const low = 'https://image.tmdb.org/t/p/w300/broken.jpg';
      await ImageStore.storeCached(high, png);
      final files = await (await ImageStore.cache).images
          .list(recursive: true)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      await files.single.writeAsBytes([1, 2, 3]);
      expect(await ImageStore.readCached(low), isNull);
      await ImageStore.storeCached(low, png);
      expect(await ImageStore.readCached(low), png);
    },
  );

  test(
    'successful optional metadata survives restart and is removed with its owner',
    () async {
      var cache = await ImageStore.cache;
      await cache.writeData('one', 'cards', [
        {'title': '角色'},
      ], checkActive: () {});
      await ImageStore.close();
      cache = await ImageStore.cache;
      expect(await cache.readData('one', 'cards'), [
        {'title': '角色'},
      ]);
      await ImageStore.removeWork('one');
      expect(await cache.readData('one', 'cards'), isNull);
    },
  );
}
