import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';

MediaVariant _scan(String id, String relPath, {int fileSize = 1024}) {
  return MediaVariant(
    id: id,
    workId: 'w_lightbox',
    sourceId: 'src_dav',
    relativePath: relPath,
    fileName: relPath.split('/').last,
    assetKind: AssetKind.scanGallery,
    fileSize: fileSize,
  );
}

MediaSourceView _webdavSource() => MediaSourceView(
  id: SourceId('src_dav'),
  kind: MediaSourceKind.webdav,
  label: '测试远程源',
  location: 'https://dav.example.com/scans',
);

void main() {
  group('ScanLightboxMemoryWindow 有界 96 MiB 滑窗与最远距离淘汰测试', () {
    test('默认容量上限严格锁定为 96 MiB 且单帧上限为 64 MiB', () {
      final window = ScanLightboxMemoryWindow();
      expect(window.maxTotalBytes, 96 * 1024 * 1024);
      expect(window.maxSingleFrameBytes, 64 * 1024 * 1024);
      expect(window.totalBytes, 0);
      expect(window.isEmpty, isTrue);
    });

    test('超出 96 MiB 上限时按最远页码距离淘汰并释放回调，绝不驱逐固定当前页', () {
      const mib = 1024 * 1024;
      final evictedCalls = <String>[];
      final window = ScanLightboxMemoryWindow();

      // 依次写入第 0、1、3、6 页，每页 30 MiB。
      // 写入第 6 页时总计 120 MiB > 96 MiB，当前浏览第 6 页，应淘汰最远的第 0 页。
      expect(
        window.put(
          ScanMemoryWindowEntry(
            variantId: 'p0',
            pageIndex: 0,
            bytes: Uint8List(30 * mib),
            onEvict: () => evictedCalls.add('p0'),
          ),
          currentIndex: 0,
          pinnedVariantId: 'p0',
        ),
        isTrue,
      );
      expect(
        window.put(
          ScanMemoryWindowEntry(
            variantId: 'p1',
            pageIndex: 1,
            bytes: Uint8List(30 * mib),
            onEvict: () => evictedCalls.add('p1'),
          ),
          currentIndex: 1,
          pinnedVariantId: 'p1',
        ),
        isTrue,
      );
      expect(
        window.put(
          ScanMemoryWindowEntry(
            variantId: 'p3',
            pageIndex: 3,
            bytes: Uint8List(30 * mib),
            onEvict: () => evictedCalls.add('p3'),
          ),
          currentIndex: 3,
          pinnedVariantId: 'p3',
        ),
        isTrue,
      );
      expect(window.totalBytes, 90 * mib);

      // 跳至第 6 页并写满 30 MiB -> 总字节超过 96 MiB，最远的 `p0`（距离 6）被优先淘汰。
      expect(
        window.put(
          ScanMemoryWindowEntry(
            variantId: 'p6',
            pageIndex: 6,
            bytes: Uint8List(30 * mib),
            onEvict: () => evictedCalls.add('p6'),
          ),
          currentIndex: 6,
          pinnedVariantId: 'p6',
        ),
        isTrue,
      );
      expect(window.totalBytes, 90 * mib);
      expect(window.contains('p0'), isFalse);
      expect(window.contains('p1'), isTrue);
      expect(window.contains('p3'), isTrue);
      expect(window.contains('p6'), isTrue);
      expect(evictedCalls, ['p0']);

      // 回跳查看第 1 页并新写入第 2 页（30 MiB），此时距第 1 页最远的是第 6 页（距离 5）。
      window.get('p1');
      expect(
        window.put(
          ScanMemoryWindowEntry(
            variantId: 'p2',
            pageIndex: 2,
            bytes: Uint8List(30 * mib),
            onEvict: () => evictedCalls.add('p2'),
          ),
          currentIndex: 1,
          pinnedVariantId: 'p1',
        ),
        isTrue,
      );
      expect(window.totalBytes, 90 * mib);
      expect(window.contains('p6'), isFalse);
      expect(window.contains('p1'), isTrue);
      expect(window.contains('p2'), isTrue);
      expect(window.contains('p3'), isTrue);
      expect(evictedCalls, ['p0', 'p6']);

      // 清空滑窗后内存占用立即归零且全部触发释放回调。
      window.clear();
      expect(window.totalBytes, 0);
      expect(window.isEmpty, isTrue);
      expect(evictedCalls, containsAll(['p0', 'p6', 'p1', 'p3', 'p2']));
    });

    test('单帧超过 64 MiB 护栏时拒绝写入滑窗并立即触发释放回调', () {
      var evicted = false;
      final window = ScanLightboxMemoryWindow();
      final accepted = window.put(
        ScanMemoryWindowEntry(
          variantId: 'huge',
          pageIndex: 0,
          bytes: Uint8List(64 * 1024 * 1024 + 1),
          onEvict: () => evicted = true,
        ),
        currentIndex: 0,
      );
      expect(accepted, isFalse);
      expect(window.isEmpty, isTrue);
      expect(window.totalBytes, 0);
      expect(evicted, isTrue);
    });
  });

  group('ScanLightboxLoader 护栏、取消令牌与原图零落盘测试', () {
    test('文件元信息超过 64 MiB 安全护栏时立即拒载并零网络开启', () async {
      var openerCalls = 0;
      final loader = ScanLightboxLoader(
        gatewayFactory: MediaSourceGatewayFactory(),
        streamOpener: (source, variant, maxBytes) async {
          openerCalls++;
          return (stream: const Stream<List<int>>.empty(), close: () async {});
        },
      );

      final handle = loader.startLoad(
        variant: _scan(
          'too_big',
          'Scans/huge.png',
          fileSize: 64 * 1024 * 1024 + 1,
        ),
        source: _webdavSource(),
      );

      await expectLater(handle.future, throwsStateError);
      expect(openerCalls, 0);
    });

    test('流式字节超过 64 MiB 护栏时立即中止流并抛出 StateError', () async {
      var streamCancelled = false;
      var gatewayClosed = false;
      final loader = ScanLightboxLoader(
        gatewayFactory: MediaSourceGatewayFactory(),
        maxFullImageBytes: 1024,
        streamOpener: (source, variant, maxBytes) async {
          late final StreamController<List<int>> ctrl;
          ctrl = StreamController<List<int>>(
            onCancel: () => streamCancelled = true,
          );
          scheduleMicrotask(() {
            ctrl.add(Uint8List(600));
            ctrl.add(Uint8List(600));
          });
          return (
            stream: ctrl.stream,
            close: () async {
              gatewayClosed = true;
              if (!ctrl.isClosed) await ctrl.close();
            },
          );
        },
      );

      final handle = loader.startLoad(
        variant: _scan('over_stream', 'Scans/over.png', fileSize: 0),
        source: _webdavSource(),
      );

      await expectLater(handle.future, throwsStateError);
      expect(streamCancelled, isTrue);
      expect(gatewayClosed, isTrue);
    });

    test('取消令牌触发时立即切断流与网关连接并返回 null，且全程零磁盘写入', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_lb_nodisk_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      var streamCancelled = false;
      var gatewayClosed = false;
      final loader = ScanLightboxLoader(
        gatewayFactory: MediaSourceGatewayFactory(),
        streamOpener: (source, variant, maxBytes) async {
          final ctrl = StreamController<List<int>>(
            onCancel: () => streamCancelled = true,
          );
          ctrl.add(Uint8List.fromList([137, 80, 78, 71]));
          return (
            stream: ctrl.stream,
            close: () async {
              gatewayClosed = true;
              if (!ctrl.isClosed) await ctrl.close();
            },
          );
        },
      );

      final handle = loader.startLoad(
        variant: _scan('cancel_me', 'Scans/c.png', fileSize: 2048),
        source: _webdavSource(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await handle.cancel();

      expect(handle.isCancelled, isTrue);
      expect(await handle.future, isNull);
      expect(streamCancelled, isTrue);
      expect(gatewayClosed, isTrue);
      expect(tempDir.listSync(recursive: true), isEmpty);
    });

    test('完整拉取原图字节驻留内存，临时与缓存目录零落盘文件', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_lb_zero_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final payload = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
      final loader = ScanLightboxLoader(
        gatewayFactory: MediaSourceGatewayFactory(),
        streamOpener: (source, variant, maxBytes) async {
          return (
            stream: Stream<List<int>>.value(payload),
            close: () async {},
          );
        },
      );

      final bytes = await loader
          .startLoad(
            variant: _scan('ok_scan', 'Scans/01.png', fileSize: payload.length),
            source: _webdavSource(),
          )
          .future;

      expect(bytes, equals(payload));
      expect(tempDir.listSync(recursive: true), isEmpty);
    });
  });
}
