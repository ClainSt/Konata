import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart' show AssetDataLoaderPort;
import 'package:test/test.dart';

final class _FileLoader implements AssetDataLoaderPort {
  int calls = 0;

  @override
  Future<Uint8List> loadBytes(String path) {
    calls++;
    expect(path, 'assets/data/release_groups.bin.gz');
    return File('../../../apps/konata/$path').readAsBytes();
  }
}

void main() {
  test('发行组按需读取，工作线程复用宿主资产并可释放', () async {
    final loader = _FileLoader();
    ReleaseGroups.configure(loader);
    addTearDown(() {
      ReleaseGroups.release();
      ReleaseGroups.configure(null);
    });
    final worker = const ScrapeComputeWorker().openSession();
    addTearDown(worker.dispose);
    expect(ReleaseGroups.isLoaded, isFalse);
    expect(ReleaseGroups.contains('nekomoe kissaten'), isTrue);
    expect(loader.calls, 0);

    const files = [
      ScannedFileInput(
        relativePath: '动画/[00d] 葬送的芙莉莲 - 01.mkv',
        fileName: '[00d] 葬送的芙莉莲 - 01.mkv',
        fileSize: 900 * 1024 * 1024,
        assetKind: AssetKind.video,
      ),
    ];
    final results = await Future.wait([
      worker.groupFiles(sourceId: 'sample', files: files),
      worker.groupFiles(sourceId: 'sample', files: files),
    ]);
    expect(results.first, isNotEmpty);
    expect(results.last.length, results.first.length);
    expect(loader.calls, 1);
    expect(ReleaseGroups.contains('00d'), isTrue);
    expect(ReleaseGroups.isLoaded, isTrue);
    ReleaseGroups.release();
    expect(ReleaseGroups.isLoaded, isFalse);
  });
}
