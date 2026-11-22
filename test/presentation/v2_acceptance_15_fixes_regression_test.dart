import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/scan_lightbox_loader.dart';
import 'package:konata/composition/platform_composition.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/cache/scan_thumbnail_scheduler.dart';
import 'package:konata/infrastructure/logging/diagnostics_log_store.dart';
import 'package:konata/infrastructure/players/audio_art_extractor.dart';
import 'package:konata/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:konata/infrastructure/sources/source_access_error.dart';
import 'package:konata/infrastructure/sources/source_gateway_factory.dart';
import 'package:konata/infrastructure/sources/webdav_source_gateway.dart';
import 'package:konata/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:konata/presentation/detail/scan_lightbox_dialog.dart';
import 'package:konata/presentation/shell/adaptive_capsule_layout.dart';
import 'package:konata/presentation/theme/konata_palette.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/bangumi_score_wordmark_badge.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final Uint8List _sample1x1Png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

/// 模拟首块即抛出网络断连异常的远程媒体网关（复现 CloudDrive2 未开启场景）。
class _OfflineFirstChunkGateway implements ByteRangeReadableGateway {
  @override
  Future<int?> probeFileLength(String relativePath) async => 1048576;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    return Stream<List<int>>.error(
      const SocketException('Connection refused'),
    );
  }

  @override
  Future<void> close() async {}
}

/// 统计字节范围读取次数与长度的内存测试网关（验证两段式音频封面探测零冗余拉流）。
class _CountingFlacGateway implements ByteRangeReadableGateway {
  _CountingFlacGateway(this._data);

  final Uint8List _data;
  final List<(int start, int? end)> requests = [];

  @override
  Future<int?> probeFileLength(String relativePath) async => _data.length;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    requests.add((start, endInclusive));
    final safeEnd = endInclusive == null
        ? _data.length - 1
        : endInclusive.clamp(start, _data.length - 1);
    return Stream<List<int>>.value(_data.sublist(start, safeEnd + 1));
  }

  @override
  Future<void> close() async {}
}

/// 捕获 WebDAV 实际发出的 HTTP 请求头与底层响应流取消事件的模拟客户端。
class _RecordingWebDavHttpClient extends http.BaseClient {
  _RecordingWebDavHttpClient({required this.responseBytes});

  final Uint8List responseBytes;
  final List<http.BaseRequest> capturedRequests = [];
  bool lastResponseCancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    capturedRequests.add(request);
    final controller = StreamController<List<int>>(
      onCancel: () {
        lastResponseCancelled = true;
      },
    );
    controller.add(responseBytes);
    return http.StreamedResponse(
      controller.stream,
      200,
      contentLength: responseBytes.length,
      headers: <String, String>{
        HttpHeaders.contentLengthHeader: '${responseBytes.length}',
      },
    );
  }
}

/// 记录系统窗口全屏切换调用的测试宿主。
class _RecordingWindowHost extends NoopKonataWindowHost {
  bool fullScreen = false;
  final List<bool> history = [];

  @override
  Future<bool> isFullScreen() async => fullScreen;

  @override
  Future<void> setFullScreen(bool value) async {
    fullScreen = value;
    history.add(value);
  }
}

/// 立即返回固定高清图像字节的模拟扫图灯箱加载器。
class _InstantScanLoader extends ScanLightboxLoaderService {
  _InstantScanLoader({required this.bytes})
    : super(
        gatewayFactory: const MediaSourceGatewayFactory(),
        logStore: DiagnosticsLogStore(),
      );

  final Uint8List bytes;

  @override
  ScanImageLoadHandle startLoad({
    required MediaVariant variant,
    required MediaSource source,
  }) {
    return ScanImageLoadHandle(
      future: Future<Uint8List?>.value(bytes),
      onCancel: () async {},
    );
  }
}

/// 构造一段最小合法 FLAC 头部（可选是否包含一个内嵌图片元数据块）。
Uint8List _buildMinimalFlacHeader({Uint8List? pictureBytes}) {
  final out = BytesBuilder();
  out.add([0x66, 0x4C, 0x61, 0x43]); // fLaC 魔数
  // STREAMINFO 块（34 字节）
  final isLastStreamInfo = pictureBytes == null;
  out.add([isLastStreamInfo ? 0x80 : 0x00, 0x00, 0x00, 34]);
  out.add(Uint8List(34));
  if (pictureBytes != null) {
    final mime = 'image/png'.codeUnits;
    final picBlock = BytesBuilder();
    picBlock.add([0, 0, 0, 3]); // 封面类型：Front Cover
    picBlock.add([0, 0, 0, mime.length]);
    picBlock.add(mime);
    picBlock.add([0, 0, 0, 0]); // 空描述
    picBlock.add(Uint8List(16)); // 宽高色深占位
    final len = pictureBytes.length;
    picBlock.add([
      (len >> 24) & 0xFF,
      (len >> 16) & 0xFF,
      (len >> 8) & 0xFF,
      len & 0xFF,
    ]);
    picBlock.add(pictureBytes);
    final payload = picBlock.takeBytes();
    final plen = payload.length;
    out.add([0x86, (plen >> 16) & 0xFF, (plen >> 8) & 0xFF, plen & 0xFF]);
    out.add(payload);
  }
  out.add(Uint8List(1024));
  return out.takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v2 实机 15 项验收问题核心回归锁', () {
    test('1. LocalStreamBridge 上游首块 SocketException 返回 HTTP 502 并记录真实网络故障而非空 200', () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final bridge = LocalStreamBridge();
      addTearDown(bridge.dispose);

      final reg = await bridge.registerSession(
        gateway: _OfflineFirstChunkGateway(),
        relativePath: 'Anime/01.mkv',
        fileName: '01.mkv',
        knownLength: 1048576,
        sourceKind: MediaSourceKind.webdav,
      );

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(reg.url);
      final resp = await req.close();
      await resp.drain<void>();

      expect(resp.statusCode, equals(HttpStatus.badGateway));
      expect(
        bridge.lastErrorKind(token: reg.token, relativePath: 'Anime/01.mkv'),
        equals(SourceAccessProblemKind.network),
      );
      expect(
        bridge.describeLastError(token: reg.token, relativePath: 'Anime/01.mkv'),
        contains('WebDAV'),
      );
    });

    test('2. WebDavSourceGateway 整文件读取不发送开放 Range 与空文本 body，未消费关闭即释放底层流', () async {
      final fakeClient = _RecordingWebDavHttpClient(
        responseBytes: _sample1x1Png,
      );
      final gw = WebDavSourceGateway(
        rootUri: Uri.parse('http://127.0.0.1:19798/dav/'),
        httpClient: fakeClient,
      );

      final validated = await gw.openValidatedByteRange(
        'Scans/01.webp',
        start: 0,
        endInclusive: null,
      );
      expect(fakeClient.capturedRequests, hasLength(1));
      final req = fakeClient.capturedRequests.single;
      expect(req.method, equals('GET'));
      expect(req.headers.containsKey('Range'), isFalse);
      expect(req.headers.containsKey(HttpHeaders.contentTypeHeader), isFalse);

      // 模拟调用方未 listen 即取消关闭网关：必须立即释放底层 HttpClientResponse 防止连接池槽位泄漏。
      await gw.close();
      expect(fakeClient.lastResponseCancelled, isTrue);
      expect(validated.isPartialContent, isFalse);
    });

    test('3. AudioAssetExtractor 两段式极速探测：无封面 FLAC 仅首段探测零补读，有小封面单次往返直出', () async {
      final noCoverFlac = _buildMinimalFlacHeader();
      final gwNoCover = _CountingFlacGateway(noCoverFlac);
      final none = await AudioAssetExtractor.readEmbeddedCoverBytes(
        gwNoCover,
        '01.flac',
      );
      expect(none, isNull);
      expect(gwNoCover.requests, hasLength(1));
      expect(gwNoCover.requests.single.$2, equals(256 * 1024 - 1));

      final withCoverFlac = _buildMinimalFlacHeader(
        pictureBytes: _sample1x1Png,
      );
      final gwWithCover = _CountingFlacGateway(withCoverFlac);
      final cover = await AudioAssetExtractor.readEmbeddedCoverBytes(
        gwWithCover,
        '02.flac',
      );
      expect(cover, equals(_sample1x1Png));
      expect(gwWithCover.requests, hasLength(1));
    });

    test('4. ScanThumbnailScheduler pauseRemote(abortActive: true) 抢占中止在途 WebDAV 并在恢复后续传', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_scan_preempt_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 64, 64),
        Paint()..color = const Color(0xFF336699),
      );
      final img = await recorder.endRecording().toImage(64, 64);
      final pngData = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      final validPng = pngData!.buffer.asUint8List(
        pngData.offsetInBytes,
        pngData.lengthInBytes,
      );

      var attempts = 0;
      var firstAborted = false;
      final firstStarted = Completer<void>();
      final firstGate = Completer<void>();

      final scheduler = ScanThumbnailScheduler(
        photosStorage: PhotosStorage(overrideRoot: tempDir),
        streamOpener: (source, variant, maxBytes) async {
          attempts++;
          if (attempts == 1) {
            if (!firstStarted.isCompleted) firstStarted.complete();
            final controller = StreamController<List<int>>(
              onCancel: () {
                firstAborted = true;
              },
            );
            return (
              stream: controller.stream,
              close: () async {
                firstAborted = true;
                if (!firstGate.isCompleted) firstGate.complete();
                if (!controller.isClosed) await controller.close();
              },
            );
          }
          return (
            stream: Stream<List<int>>.value(validPng),
            close: () async {},
          );
        },
      );
      addTearDown(scheduler.dispose);

      const source = MediaSource(
        id: 'dav_1',
        kind: MediaSourceKind.webdav,
        label: 'CD2',
        location: 'http://127.0.0.1:19798/dav',
      );
      const variant = MediaVariant(
        id: 'scan_1',
        workId: 'w_scan',
        sourceId: 'dav_1',
        relativePath: 'Scans/01.png',
        fileName: '01.png',
        fileSize: 67,
        assetKind: AssetKind.scanGallery,
      );

      final scheduled = scheduler.schedule(
        workId: 'w_scan',
        workTitle: '测试作品',
        variant: variant,
        source: source,
      );
      await firstStarted.future;
      expect(scheduler.activeWebDavCount, equals(1));

      scheduler.pauseRemote(abortActive: true);
      await firstGate.future;
      expect(firstAborted, isTrue);
      expect(scheduler.activeWebDavCount, equals(0));
      expect(scheduler.pendingRemoteCount, equals(1));

      scheduler.resumeRemote();
      final result = await scheduled.future;
      expect(attempts, equals(2));
      expect(result, isNotEmpty);
    });

    test('5. opticalSheenGradient 预混底色不丢失填充，悬浮小窗纯视口驱动且桌面不顶起底栏', () {
      final lightBase = KonataPalette.light.surface;
      final gradient = KonataTheme.opticalSheenGradient(
        KonataPalette.light,
        baseColor: lightBase,
      );
      expect(gradient.colors.first.a, greaterThanOrEqualTo(lightBase.a));
      expect(gradient.colors.last.a, greaterThanOrEqualTo(lightBase.a));

      // 同尺寸下不同操作系统（android=true vs false）得到一致的视口悬浮视频尺寸，零包体分叉。
      final tabletAndroid = AdaptiveCapsuleLayout(
        size: const Size(1280, 800),
        safe: EdgeInsets.zero,
        android: true,
        navigationVisible: true,
        miniKind: FloatingMiniPlayerKind.video,
      );
      final tabletWindows = AdaptiveCapsuleLayout(
        size: const Size(1280, 800),
        safe: EdgeInsets.zero,
        android: false,
        navigationVisible: false,
        miniKind: FloatingMiniPlayerKind.video,
      );
      final phone = AdaptiveCapsuleLayout(
        size: const Size(390, 844),
        safe: EdgeInsets.zero,
        android: true,
        navigationVisible: false,
        miniKind: FloatingMiniPlayerKind.video,
      );

      expect(
        tabletAndroid.floatingMiniWindowRect!.width,
        closeTo(tabletWindows.floatingMiniWindowRect!.width, 0.5),
      );
      expect(
        tabletWindows.floatingMiniWindowRect!.width,
        greaterThan(phone.floatingMiniWindowRect!.width),
      );
      expect(tabletWindows.bottomClearance, equals(0.0));
    });

    testWidgets('6. BangumiScoreWordmarkBadge 双主题渲染主题自适应毛玻璃且无溢出', (tester) async {
      for (final theme in [KonataTheme.lightTheme(), KonataTheme.darkTheme()]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: Center(
                child: BangumiScoreWordmarkBadge(score: 8.7),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('8.7'), findsOneWidget);
        expect(find.byType(BackdropFilter), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('7. ScanLightboxDialog 在 Windows 端切换全屏同步调用系统窗口全屏并在关闭时自动还原', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tempDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_lightbox_fs_'),
      );
      addTearDown(() async {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final host = _RecordingWindowHost();
      const source = MediaSource(
        id: 'dav_fs',
        kind: MediaSourceKind.webdav,
        label: 'CD2',
        location: 'http://127.0.0.1:19798/dav',
      );
      const variant = MediaVariant(
        id: 'scan_fs_1',
        workId: 'w_fs',
        sourceId: 'dav_fs',
        relativePath: 'Scans/01.png',
        fileName: '01.png',
        fileSize: 67,
        assetKind: AssetKind.scanGallery,
      );
      const bundle = WorkDetailBundle(
        work: Work(id: 'w_fs', title: '16bit的感动'),
        episodes: [],
        variants: [variant],
        scanVariants: [variant],
        sourcesById: {'dav_fs': source},
        latestPlayback: null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            konataWindowHostProvider.overrideWithValue(host),
            photosStorageProvider.overrideWithValue(
              PhotosStorage(overrideRoot: tempDir),
            ),
            scanLightboxLoaderProvider.overrideWithValue(
              _InstantScanLoader(bytes: _sample1x1Png),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: ScanLightboxDialog(
                bundle: bundle,
                initialVariant: variant,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('沉浸全屏 (F)'));
      await tester.pumpAndSettle();
      expect(host.fullScreen, isTrue);
      expect(host.history, equals([true]));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(host.fullScreen, isFalse);
      expect(host.history, equals([true, false]));
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
