import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:feature_scan_viewer/feature_scan_viewer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

class _PassthroughHttpOverrides extends HttpOverrides {}

class _NoopSourceCredentialStore extends SourceCredentialStore {
  _NoopSourceCredentialStore() : super(storage: InMemorySecureStorage());

  @override
  Future<String?> readPassword(String sourceId) async => null;
}

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

MediaVariant _scanVariant(
  String id,
  String relPath, {
  String sourceId = 'src_1',
  int size = 500000,
}) {
  return MediaVariant(
    id: id,
    workId: 'w_scan',
    sourceId: sourceId,
    relativePath: relPath,
    fileName: relPath.split('/').last,
    assetKind: AssetKind.scanGallery,
    fileSize: size,
  );
}

MediaSourceView _sourceView({
  required String id,
  required MediaSourceKind kind,
  required String location,
}) {
  return MediaSourceView(
    id: SourceId(id),
    kind: kind,
    label: '测试源_$id',
    location: location,
  );
}

void main() {
  group('ScanThumbnailScheduler 三级并发调度与帧头解析测试', () {
    testWidgets(
      '1600x2400 原图压缩生成 <=35KB 的 .webp 且原生可逆向解码还原并零原图落盘',
      (tester) async {
        await tester.runAsync(() async {
          final tempPhotos = await Directory.systemTemp.createTemp(
            'konata_scan_webp_',
          );
          final sourceDir = await Directory.systemTemp.createTemp(
            'konata_scan_src_',
          );
          addTearDown(() async {
            if (tempPhotos.existsSync()) {
              await tempPhotos.delete(recursive: true);
            }
            if (sourceDir.existsSync()) {
              await sourceDir.delete(recursive: true);
            }
          });

          final pngBytes = await _createSyntheticHighResPng();
          final scansFolder = Directory(p.join(sourceDir.path, 'Scans'));
          scansFolder.createSync(recursive: true);
          await File(p.join(scansFolder.path, 'booklet_01.png')).writeAsBytes(
            pngBytes,
            flush: true,
          );

          final storage = PhotosStorage(overrideRoot: tempPhotos);
          final scheduler = ScanThumbnailScheduler(photosStorage: storage);
          addTearDown(scheduler.dispose);

          final source = _sourceView(
            id: 'src_local',
            kind: MediaSourceKind.local,
            location: sourceDir.path,
          );
          final variant = _scanVariant(
            'scan_1',
            'Scans/booklet_01.png',
            sourceId: 'src_local',
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
          expect(String.fromCharCodes(webpBytes.sublist(0, 4)), 'RIFF');
          expect(String.fromCharCodes(webpBytes.sublist(8, 16)), 'WEBPVP8L');

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
              final distinctColors = <int>{};
              for (var i = 0; i < raw.length; i += 64) {
                distinctColors.add(
                  (raw[i] << 16) | (raw[i + 1] << 8) | raw[i + 2],
                );
              }
              expect(distinctColors.length, greaterThan(3));
            } finally {
              frame.image.dispose();
            }
          } finally {
            codec.dispose();
          }

          // 确认磁盘图片根目录中仅存放微缩图文件，零原图落盘。
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
      'Local 源并发上限严格锁定为 4 且支持 LIFO 后入先出与取消',
      (tester) async {
        await tester.runAsync(() async {
          final tempPhotos = await Directory.systemTemp.createTemp(
            'konata_scan_local_limit_',
          );
          addTearDown(() async {
            if (tempPhotos.existsSync()) {
              await tempPhotos.delete(recursive: true);
            }
          });

          final pngBytes = await _createSyntheticHighResPng(
            width: 600,
            height: 800,
          );
          final startedOrder = <String>[];
          final controllers = <String, StreamController<List<int>>>{};
          var activeCount = 0;
          var peakActive = 0;

          final scheduler = ScanThumbnailScheduler(
            photosStorage: PhotosStorage(overrideRoot: tempPhotos),
            streamOpener: (source, variant, maxBytes) async {
              startedOrder.add(variant.id);
              activeCount++;
              if (activeCount > peakActive) peakActive = activeCount;
              final ctrl = StreamController<List<int>>();
              controllers[variant.id] = ctrl;
              return (
                stream: ctrl.stream,
                close: () async {
                  if (activeCount > 0) activeCount--;
                  if (!ctrl.isClosed) await ctrl.close();
                },
              );
            },
          );
          addTearDown(scheduler.dispose);

          final localSource = _sourceView(
            id: 'src_local',
            kind: MediaSourceKind.local,
            location: r'D:\Anime',
          );

          final jobs = <({Future<Uint8List> future, ScanThumbnailTicket ticket})>[
            for (var i = 0; i < 6; i++)
              scheduler.schedule(
                workId: 'w_local',
                variant: _scanVariant(
                  'loc_$i',
                  'Scans/$i.png',
                  sourceId: 'src_local',
                ),
                source: localSource,
              ),
          ];

          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(peakActive, 4);
          expect(scheduler.activeLocalCount, 4);
          expect(scheduler.pendingLocalCount, 2);
          expect(startedOrder, ['loc_0', 'loc_1', 'loc_2', 'loc_3']);

          // 完成第一个任务后，后入栈的 `loc_5` 应优先于 `loc_4` 启动。
          controllers['loc_0']!.add(pngBytes);
          await controllers['loc_0']!.close();
          expect(await jobs[0].future, isNotEmpty);

          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(startedOrder, ['loc_0', 'loc_1', 'loc_2', 'loc_3', 'loc_5']);
          expect(peakActive, 4);

          scheduler.cancelAll();
          await Future.wait([for (final j in jobs) j.future]);
          expect(scheduler.activeLocalCount, 0);
          expect(scheduler.pendingLocalCount, 0);
        });
      },
    );

    testWidgets(
      'WebDAV 远程源严格串行 concurrency=1 + LIFO 抢占优先 + cancel/cancelAll 立即切断底层流',
      (tester) async {
        await tester.runAsync(() async {
          final tempPhotos = await Directory.systemTemp.createTemp(
            'konata_scan_remote_',
          );
          addTearDown(() async {
            if (tempPhotos.existsSync()) {
              await tempPhotos.delete(recursive: true);
            }
          });

          final tinyRgba = Uint8List.fromList([
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 0, 255,
          ]);
          final validTinyWebp = CompactWebpEncoder.encodeRgba(
            rgba: tinyRgba,
            width: 2,
            height: 2,
          );
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

          final webdavSource = _sourceView(
            id: 'src_dav',
            kind: MediaSourceKind.webdav,
            location: 'https://dav.example.com/anime',
          );

          final v0 = _scanVariant('scan_0', 'Scans/00.png', sourceId: 'src_dav');
          final v1 = _scanVariant('scan_1', 'Scans/01.png', sourceId: 'src_dav');
          final v2 = _scanVariant('scan_2', 'Scans/02.png', sourceId: 'src_dav');
          final v3 = _scanVariant('scan_3', 'Scans/03.png', sourceId: 'src_dav');

          final j0 = scheduler.schedule(
            workId: 'w_dav',
            workTitle: '远程番剧',
            variant: v0,
            source: webdavSource,
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(startedOrder, ['scan_0']);
          expect(scheduler.activeRemoteCount, 1);

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
          expect(scheduler.activeWebDavCount, 1);
          expect(scheduler.pendingRemoteCount, 3);
          expect(startedOrder, ['scan_0']);

          // 取消排队中的 `scan_2` 并让 `scan_0` 完成传输。
          j2.ticket.cancel();
          final cancelled2 = await j2.future;
          expect(cancelled2, isEmpty);
          expect(scheduler.pendingRemoteCount, 2);

          controllers['scan_0']!.add(pngBytes);
          await controllers['scan_0']!.close();
          final out0 = await j0.future;
          expect(out0, isNotEmpty);

          // 按后入先出规则，`scan_3` 必须优先于 `scan_1` 启动。
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(startedOrder, ['scan_0', 'scan_3']);
          expect(peakActiveStreams, 1);
          expect(scheduler.activeWebDavCount, 1);
          expect(scheduler.pendingRemoteCount, 1);

          // 当 `scan_3` 仍在传输中触发单项取消，应立即切断底层流并自动放行下一个任务 `scan_1`。
          controllers['scan_3']!.add(pngBytes.sublist(0, pngBytes.length ~/ 2));
          await Future<void>.delayed(const Duration(milliseconds: 10));
          j3.ticket.cancel();

          final out3 = await j3.future;
          await Future<void>.delayed(const Duration(milliseconds: 25));

          expect(out3, isEmpty);
          expect(cancelledStreams, contains('scan_3'));
          expect(closedGateways, contains('scan_3'));
          expect(startedOrder, ['scan_0', 'scan_3', 'scan_1']);
          expect(peakActiveStreams, 1);

          scheduler.cancelAll();
          final out1 = await j1.future;
          expect(out1, isEmpty);
          expect(cancelledStreams, contains('scan_1'));
          expect(closedGateways, contains('scan_1'));
          expect(scheduler.activeRemoteCount, 0);
          expect(scheduler.pendingRemoteCount, 0);
        });
      },
    );

    testWidgets(
      'SMB 并发上限 2、pauseRemote(abortActive: true) 抢占回退与本地 64KB 帧头预热零远程探测',
      (tester) async {
        await tester.runAsync(() async {
          final tempPhotos = await Directory.systemTemp.createTemp(
            'konata_scan_smb_stage_',
          );
          final localDir = await Directory.systemTemp.createTemp(
            'konata_scan_header_',
          );
          addTearDown(() async {
            if (tempPhotos.existsSync()) {
              await tempPhotos.delete(recursive: true);
            }
            if (localDir.existsSync()) {
              await localDir.delete(recursive: true);
            }
          });

          // 1. 验证 ImageHeaderParser 精确解析 PNG 尺寸并测试 64KB 帧头只读预热。
          final pngBytes = await _createSyntheticHighResPng(
            width: 1200,
            height: 1600,
          );
          final pngDims = ImageHeaderParser.parseDimensions(pngBytes);
          expect(pngDims, (width: 1200, height: 1600));
          expect(
            ImageHeaderParser.parseAspectRatio(pngBytes),
            closeTo(0.75, 0.001),
          );

          final localSub = Directory(p.join(localDir.path, 'Scans'));
          localSub.createSync(recursive: true);
          await File(p.join(localSub.path, 'local_only.png')).writeAsBytes(
            pngBytes,
            flush: true,
          );

          // 2. 验证 SMB 并发上限为 2，且 pauseRemote(abortActive: true) / resumeRemote 生效。
          final smbControllers = <String, StreamController<List<int>>>{};
          final cancelledIds = <String>[];
          var activeSmb = 0;
          var peakSmb = 0;
          var remoteOpenedCount = 0;

          final smbScheduler = ScanThumbnailScheduler(
            photosStorage: PhotosStorage(overrideRoot: tempPhotos),
            streamOpener: (source, variant, maxBytes) async {
              if (source.kind != MediaSourceKind.local) {
                remoteOpenedCount++;
              }
              activeSmb++;
              if (activeSmb > peakSmb) peakSmb = activeSmb;
              late final StreamController<List<int>> ctrl;
              ctrl = StreamController<List<int>>(
                onCancel: () => cancelledIds.add(variant.id),
              );
              smbControllers[variant.id] = ctrl;
              return (
                stream: ctrl.stream,
                close: () async {
                  if (activeSmb > 0) activeSmb--;
                  if (!ctrl.isClosed) await ctrl.close();
                },
              );
            },
          );
          addTearDown(smbScheduler.dispose);

          final localSource = _sourceView(
            id: 'src_loc',
            kind: MediaSourceKind.local,
            location: localDir.path,
          );
          final smbSource = _sourceView(
            id: 'src_smb',
            kind: MediaSourceKind.smb,
            location: 'smb://192.168.1.2/anime',
          );

          final localVariant = _scanVariant(
            'loc_header_1',
            'Scans/local_only.png',
            sourceId: 'src_loc',
          );
          final remoteVariant = _scanVariant(
            'smb_remote_1',
            'Scans/remote_only.png',
            sourceId: 'src_smb',
          );

          // 预热帧头仅读本地前 64KB，对未缓存的远程源严禁发起任何探测请求。
          await smbScheduler.prewarmCachedAndLocalAspectRatios(
            workId: 'w_prewarm',
            variants: [localVariant, remoteVariant],
            sourcesById: {'src_loc': localSource, 'src_smb': smbSource},
          );
          expect(
            smbScheduler.cachedAspectRatio('loc_header_1'),
            closeTo(0.75, 0.001),
          );
          expect(smbScheduler.cachedAspectRatio('smb_remote_1'), isNull);
          expect(remoteOpenedCount, 0);

          smbScheduler.pauseRemote();
          expect(smbScheduler.isRemotePaused, isTrue);
          final s0 = smbScheduler.schedule(
            workId: 'w_smb',
            variant: _scanVariant('smb_0', 'Scans/s0.png', sourceId: 'src_smb'),
            source: smbSource,
          );
          final s1 = smbScheduler.schedule(
            workId: 'w_smb',
            variant: _scanVariant('smb_1', 'Scans/s1.png', sourceId: 'src_smb'),
            source: smbSource,
          );
          final s2 = smbScheduler.schedule(
            workId: 'w_smb',
            variant: _scanVariant('smb_2', 'Scans/s2.png', sourceId: 'src_smb'),
            source: smbSource,
          );
          await Future<void>.delayed(const Duration(milliseconds: 25));
          expect(smbScheduler.activeSmbCount, 0);
          expect(smbScheduler.pendingRemoteCount, 3);

          // 恢复后 SMB 并发自动拉满 2 通道，余下 1 个排队。
          smbScheduler.resumeRemote();
          await Future<void>.delayed(const Duration(milliseconds: 25));
          expect(smbScheduler.isRemotePaused, isFalse);
          expect(smbScheduler.activeSmbCount, 2);
          expect(peakSmb, 2);
          expect(smbScheduler.pendingRemoteCount, 1);

          // 灯箱打开抢占取消在途任务并退回队列，关闭灯箱恢复后自动续传。
          smbScheduler.pauseRemote(abortActive: true);
          await Future<void>.delayed(const Duration(milliseconds: 25));
          expect(smbScheduler.activeSmbCount, 0);
          expect(smbScheduler.pendingRemoteCount, 3);
          expect(cancelledIds, isNotEmpty);

          smbScheduler.resumeRemote();
          await Future<void>.delayed(const Duration(milliseconds: 25));
          expect(smbScheduler.activeSmbCount, 2);

          smbScheduler.cancelAll();
          await Future.wait([s0.future, s1.future, s2.future]);

          // 3. 本地回环 HTTP 服务模拟 WebDAV：验证 0 次 HEAD 请求、单次 GET 与灯箱复用。
          await HttpOverrides.runWithHttpOverrides(() async {
            final requestLog = <String>[];
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            server.listen((req) async {
              requestLog.add('${req.method} ${req.uri.path}');
              if (req.method == 'HEAD') {
                req.response.statusCode = HttpStatus.methodNotAllowed;
                await req.response.close();
                return;
              }
              req.response.statusCode = HttpStatus.ok;
              req.response.headers.contentLength = pngBytes.length;
              req.response.add(pngBytes);
              await req.response.close();
            });

            final pool = WebDavConnectionPool();
            addTearDown(pool.dispose);
            final factory = MediaSourceGatewayFactory(
              credentialStore: _NoopSourceCredentialStore(),
              webDavPool: pool,
            );
            final davSource = _sourceView(
              id: 'src_dav_real',
              kind: MediaSourceKind.webdav,
              location: 'http://127.0.0.1:${server.port}/',
            );
            final davVariant = _scanVariant(
              'dav_scan_1',
              'Scans/page01.png',
              sourceId: 'src_dav_real',
              size: pngBytes.length,
            );

            final realStorage = PhotosStorage(overrideRoot: tempPhotos);
            final realScheduler = ScanThumbnailScheduler(
              photosStorage: realStorage,
              gatewayFactory: factory,
            );
            addTearDown(realScheduler.dispose);

            final thumb = await realScheduler
                .schedule(
                  workId: 'w_dav_real',
                  workTitle: '回环测试',
                  variant: davVariant,
                  source: davSource,
                )
                .future;
            expect(thumb, isNotEmpty);
            expect(
              realScheduler.cachedAspectRatio(davVariant.id),
              closeTo(0.75, 0.01),
            );
            expect(requestLog, ['GET /Scans/page01.png']);

            // 校验灯箱直读原图同样仅发 1 次 GET，零 HEAD 探测。
            requestLog.clear();
            final lightboxLoader = ScanLightboxLoader(
              gatewayFactory: factory,
              diagnosticLog: DiagnosticLogStore(),
            );
            final loadedBytes = await lightboxLoader
                .startLoad(variant: davVariant, source: davSource)
                .future;
            expect(loadedBytes, isNotNull);
            expect(loadedBytes!.length, pngBytes.length);
            expect(requestLog, ['GET /Scans/page01.png']);
          }, _PassthroughHttpOverrides());
        });
      },
    );
  });
}
