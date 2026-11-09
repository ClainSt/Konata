import 'dart:io';
import 'package:ccplayer/core/local_media.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/selected_scanner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const tree =
      'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FSeries';
  test(
    'document tree lists names and resolves through its grant, never a raw path',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalMedia.channel, (call) async {
            calls.add(call);
            expect(call.arguments['root'], tree);
            if (call.method == 'list') {
              return [
                {'name': 'Episode 01.mkv', 'directory': false, 'size': 1234},
                {'name': 'Subs', 'directory': true, 'size': null},
              ];
            }
            return '$tree/document/opaque-provider-id';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalMedia.channel, null),
      );
      final entries = await LocalMedia.list(tree);
      expect(entries.first.name, 'Episode 01.mkv');
      expect(entries.first.size, 1234);
      expect(entries.last.directory, isTrue);
      expect(
        await LocalMedia.uri(tree, 'Episode 01.mkv'),
        contains('opaque-provider-id'),
      );
      expect(calls.last.arguments['relative'], 'Episode 01.mkv');
      expect(LocalMedia.label(tree), 'Series');
      await expectLater(
        LocalMedia.uri(tree, '../other.mkv'),
        throwsFormatException,
      );
      expect(calls.length, 2);
    },
  );
  test('filesystem source retains nested files without document API', () async {
    final root = await Directory.systemTemp.createTemp('konata-local-test-');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/Subs').create();
    await File('${root.path}/Episode 01.mkv').writeAsBytes([1, 2, 3]);
    final entries = await LocalMedia.list(root.path);
    expect(entries.where((e) => !e.directory).single.size, 3);
    expect(
      await File(
        await LocalMedia.uri(root.path, 'Episode 01.mkv'),
      ).readAsBytes(),
      [1, 2, 3],
    );
  });
  test(
    'granted folder scans nested episodes and preserves the source URI',
    () async {
      final folder = await Directory.systemTemp.createTemp('konata-saf-scan-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: folder);
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalMedia.channel, null);
        await catalog.db.close();
        await folder.delete(recursive: true);
      });
      var denied = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalMedia.channel, (call) async {
            expect(call.method, 'list');
            expect(call.arguments['root'], tree);
            if (denied) {
              throw PlatformException(code: 'local_media_unavailable');
            }
            switch (call.arguments['relative']) {
              case '':
                return [
                  {'name': '86 (2021) {tmdb-100565}', 'directory': true},
                ];
              case '86 (2021) {tmdb-100565}':
                return [
                  {'name': 'Season 01', 'directory': true},
                  {'name': 'Scans', 'directory': true},
                ];
              case '86 (2021) {tmdb-100565}/Season 01':
                return [
                  {'name': 'S01E01.mkv', 'directory': false, 'size': 9876},
                  {'name': 'S01E01.ass', 'directory': false, 'size': 123},
                ];
              default:
                fail('Unexpected directory listing');
            }
          });
      final id = await catalog.addSource('local', 'Granted media', tree);
      await catalog.addScanRoot(id, '');
      final result = await SelectedScanner.scanDetailed(catalog.sourceOf(id));
      expect(result.videoCount, 1);
      expect(
        catalog.assets.single['relative_path'],
        '86 (2021) {tmdb-100565}/Season 01/S01E01.mkv',
      );
      expect(catalog.sourceOf(id)['location'], tree);
      denied = true;
      await expectLater(
        SelectedScanner.scanDetailed(catalog.sourceOf(id)),
        throwsA(isA<PlatformException>()),
      );
      expect(catalog.scanning, isFalse);
      expect(catalog.assets, hasLength(1));
    },
  );
}
