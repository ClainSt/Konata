import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/infrastructure/cache/compact_webp_encoder.dart';
import 'package:ccplayer/infrastructure/cache/photos_storage.dart';
import 'package:ccplayer/infrastructure/cache/scan_thumbnail_scheduler.dart';

Future<Uint8List> _createSyntheticHighResPng({
  int width = 1600,
  int height = 2400,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final bgPaint = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF1F4E78), Color(0xFFE07A5F), Color(0xFF81B29A)],
    ).createShader(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    bgPaint,
  );
  // 叠加几组几何图案与线条模拟扫描画册图文纹理
  final circlePaint = Paint()..color = const Color(0xFFF2CC8F);
  canvas.drawCircle(Offset(width * 0.48, height * 0.36), 340, circlePaint);
  final stripePaint = Paint()
    ..color = const Color(0xFF3D405B)
    ..strokeWidth = 28;
  for (var i = 0; i < 12; i++) {
    final y = 1100.0 + i * 90.0;
    canvas.drawLine(Offset(140, y), Offset(width - 140.0, y + 60), stripePaint);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

MediaVariant _scanVariant(String id, String relPath, {int size = 500000}) {
  return MediaVariant(
    id: id,
    workId: 'w_scan',
    sourceId: 'src_1',
    relativePath: relPath,
    fileName: relPath.split('/').last,
    assetKind: AssetKind.scanGallery,
    fileSize: size,
  );
}

void main() {
  group('ScanThumbnailScheduler 与 CompactWebpEncoder 验证测试', () {
    testWidgets(
      '1600x2400 原图压缩生成 <=35KB 的 .webp 且 ui.instantiateImageCodec 可逆向解码还原',
      (tester) async {
        await tester.runAsync(() async {
          final tempPhotos = await Directory.systemTemp.createTemp(
            'konata_scan_webp_',
          );
          final sourceDir = await Directory.systemTemp.createTemp(
            'konata_scan_src_',
          );
          addTearDown(() async {
            if (await tempPhotos.exists()) {
              await tempPhotos.delete(recursive: true);
            }
            if (await sourceDir.exists()) {
              await sourceDir.delete(recursive: true);
            }
          });

          final pngBytes = await _createSyntheticHighResPng();
          final scansFolder = Directory(p.join(sourceDir.path, 'Scans'));
          await scansFolder.create(recursive: true);
          await File(p.join(scansFolder.path, 'booklet_01.png')).writeAsBytes(
            pngBytes,
            flush: true,
          );

          final storage = PhotosStorage(overrideRoot: tempPhotos);
          final scheduler = ScanThumbnailScheduler(photosStorage: storage);
          addTearDown(scheduler.dispose);

          final source = MediaSource(
            id: 'src_local',
            label: '本地源',
            kind: MediaSourceKind.local,
            location: sourceDir.path,
            createdAt: DateTime(2026),
          );
          final variant = _scanVariant(
            'scan_1',
            'Scans/booklet_01.png',
            size: pngBytes.length,
          );

          final webpBytes = await scheduler
              .schedule(
                workId: 'work::scan::1',
                workTitle: '测试画册作品',
                variant: variant,
                source: source,
              )
              .future;

          expect(webpBytes.length, greaterThan(24));
          expect(webpBytes.length, lessThanOrEqualTo(35 * 1024));
          // 验证标准 RIFF + WEBPVP8L 容器头
          expect(String.fromCharCodes(webpBytes.sublist(0, 4)), 'RIFF');
          expect(String.fromCharCodes(webpBytes.sublist(8, 16)), 'WEBPVP8L');

          // 反向用 Flutter 原生图像编解码器解码验证有效性、降采样长边及非空像素
          final codec = await ui.instantiateImageCodec(webpBytes);
          try {
            final frame = await codec.getNextFrame();
            try {
              expect(frame.image.width, lessThanOrEqualTo(360));
              expect(frame.image.height, 360);
              final rgba = await frame.image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              expect(rgba, isNotNull);
              final raw = rgba!.buffer.asUint8List();
              final distinctAlphaOrRgb = <int>{};
              for (var i = 0; i < raw.length; i += 64) {
                distinctAlphaOrRgb.add(
                  (raw[i] << 16) | (raw[i + 1] << 8) | raw[i + 2],
                );
              }
              expect(distinctAlphaOrRgb.length, greaterThan(3));
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }

          // 确认磁盘 photos/ 中仅存放 scans/*.webp，零原图 PNG 落盘
          final allDiskFiles = tempPhotos
              .listSync(recursive: true)
              .whereType<File>()
              .toList(growable: false);
          expect(allDiskFiles.length, 1);
          expect(
            allDiskFiles.single.path.replaceAll('\\', '/'),
            contains('/scans/'),
          );
          expect(allDiskFiles.single.path.endsWith('.webp'), isTrue);
        });
      },
    );

    testWidgets(
      'WebDAV 远程源严格串行 concurrency=1 + LIFO 优先执行 + cancel/cancelAll 立即切断底层流',
      (tester) async {
        await tester.runAsync(() async {
          final tempPhotos = await Directory.systemTemp.createTemp(
            'konata_scan_remote_',
          );
          addTearDown(() async {
            if (await tempPhotos.exists()) {
              await tempPhotos.delete(recursive: true);
            }
          });

          // 提前准备小块有效 2x2 RGBA 编码字节验证 CompactWebpEncoder 极端单/双色完备性
          final tinyRgba = Uint8List.fromList([
            255, 0, 0, 255, 0, 255, 0, 255, //
            0, 0, 255, 255, 255, 255, 0, 255, //
          ]);
          final validTinyWebp = CompactWebpEncoder.encodeRgba(
            rgba: tinyRgba,
            width: 2,
            height: 2,
          );
          // 检验 Tiny 2x2 WebP 也能被原生解码
          final tinyCodec = await ui.instantiateImageCodec(validTinyWebp);
          tinyCodec.dispose();

          final pngBytes = await _createSyntheticHighResPng(
            width: 800,
            height: 800,
          );

          final startedOrder = <String>[];
          final cancelledStreams = <String>[];
          final closedGateways = <String>[];
          final controllers = <String, StreamController<List<int>>>{};
          var activeStreams = 0;
          var peakActiveStreams = 0;

          final scheduler = ScanThumbnailScheduler(
            photosStorage: PhotosStorage(overrideRoot: tempPhotos),
            streamOpener: (source, variant, maxBytes) async {
              startedOrder.add(variant.id);
              activeStreams++;
              if (activeStreams > peakActiveStreams) {
                peakActiveStreams = activeStreams;
              }
              late final StreamController<List<int>> ctrl;
              ctrl = StreamController<List<int>>(
                onCancel: () {
                  cancelledStreams.add(variant.id);
                },
              );
              controllers[variant.id] = ctrl;
              return (
                stream: ctrl.stream,
                close: () async {
                  closedGateways.add(variant.id);
                  if (activeStreams > 0) activeStreams--;
                  if (!ctrl.isClosed) {
                    await ctrl.close();
                  }
                },
              );
            },
          );
          addTearDown(scheduler.dispose);

          final webdavSource = MediaSource(
            id: 'src_dav',
            label: 'WebDAV 测试源',
            kind: MediaSourceKind.webdav,
            location: 'https://dav.example.com/anime',
            createdAt: DateTime(2026),
          );

          final v0 = _scanVariant('scan_0', 'Scans/00.png');
          final v1 = _scanVariant('scan_1', 'Scans/01.png');
          final v2 = _scanVariant('scan_2', 'Scans/02.png');
          final v3 = _scanVariant('scan_3', 'Scans/03.png');

          final j0 = scheduler.schedule(
            workId: 'w_dav',
            workTitle: '远程番剧',
            variant: v0,
            source: webdavSource,
          );
          // 等微任务使 scan_0 进入 active 状态
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(startedOrder, ['scan_0']);
          expect(scheduler.activeRemoteCount, 1);

          // 依次提交 1, 2, 3（均应压入 LIFO 栈排队，不可并发抢占）
          final j1 = scheduler.schedule(
            workId: 'w_dav',
            workTitle: '远程番剧',
            variant: v1,
            source: webdavSource,
          );
          final j2 = scheduler.schedule(
            workId: 'w_dav',
            workTitle: '远程番剧',
            variant: v2,
            source: webdavSource,
          );
          final j3 = scheduler.schedule(
            workId: 'w_dav',
            workTitle: '远程番剧',
            variant: v3,
            source: webdavSource,
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(peakActiveStreams, 1);
          expect(scheduler.activeRemoteCount, 1);
          expect(scheduler.pendingRemoteCount, 3);
          expect(startedOrder, ['scan_0']);

          // 取消排队中的 scan_2，并让 scan_0 完成传输
          j2.ticket.cancel();
          final cancelled2 = await j2.future;
          expect(cancelled2, isEmpty);
          expect(scheduler.pendingRemoteCount, 2);

          controllers['scan_0']!.add(pngBytes);
          await controllers['scan_0']!.close();
          final out0 = await j0.future;
          expect(out0, isNotEmpty);

          // 等下一步调度：按 LIFO 栈规则，scan_3 必须先于 scan_1 启动！
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(startedOrder, ['scan_0', 'scan_3']);
          expect(peakActiveStreams, 1);
          expect(scheduler.activeRemoteCount, 1);
          expect(scheduler.pendingRemoteCount, 1);

          // 当 scan_3 仍在传输中触发 cancelAll() -> 必须立即 cancel 底层流并清空队列
          controllers['scan_3']!.add(pngBytes.sublist(0, pngBytes.length ~/ 2));
          await Future<void>.delayed(const Duration(milliseconds: 10));
          scheduler.cancelAll();

          final out3 = await j3.future;
          final out1 = await j1.future;
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(out3, isEmpty);
          expect(out1, isEmpty);
          expect(cancelledStreams, contains('scan_3'));
          expect(closedGateways, contains('scan_3'));
          expect(startedOrder.contains('scan_1'), isFalse);
          expect(scheduler.activeRemoteCount, 0);
          expect(scheduler.pendingRemoteCount, 0);
        });
      },
    );
  });
}
