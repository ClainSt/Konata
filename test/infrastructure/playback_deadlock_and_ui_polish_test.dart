import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/matching/episode_title_formatter.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/external_player_config.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/repositories/file_system_gateway.dart';
import 'package:ccplayer/infrastructure/cache/artwork_cache.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:ccplayer/infrastructure/players/mpv_ipc_tracker.dart';
import 'package:ccplayer/infrastructure/players/player_tracking_isolates.dart';
import 'package:ccplayer/infrastructure/players/real_external_player_launcher.dart';
import 'package:ccplayer/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:ccplayer/infrastructure/sources/source_gateway_factory.dart';
import 'package:ccplayer/infrastructure/sources/webdav_source_gateway.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:ccplayer/presentation/detail/detail_bottom_drawer.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/managed_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _ConcurrentSlowHeadGateway
    implements MediaSourceGateway, ByteRangeReadableGateway {
  _ConcurrentSlowHeadGateway(this.totalBytes);

  final Uint8List totalBytes;
  bool firstHeadCancelled = false;
  final Completer<void> firstStreamStarted = Completer<void>();
  final Completer<void> firstStreamCancelled = Completer<void>();

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async => const [];

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<int?> probeFileLength(String relativePath) async => totalBytes.length;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    // 第 1 路从 0 起的顺序大流：先吐前 32 字节后挂起等待下游消费或中断，不阻断第 2 路尾部并发请求
    if (start == 0) {
      late final StreamController<List<int>> ctrl;
      ctrl = StreamController<List<int>>(
        onCancel: () {
          firstHeadCancelled = true;
          if (!firstStreamCancelled.isCompleted) {
            firstStreamCancelled.complete();
          }
        },
      );
      ctrl.add(totalBytes.sublist(0, 32));
      if (!firstStreamStarted.isCompleted) {
        firstStreamStarted.complete();
      }
      return ctrl.stream;
    }

    final end = endInclusive == null
        ? totalBytes.length
        : (endInclusive + 1).clamp(start, totalBytes.length);
    return Stream<List<int>>.value(totalBytes.sublist(start, end));
  }

  @override
  Future<void> close() async {}
}

class _FakeLoudProcess implements Process {
  _FakeLoudProcess({required this.pid}) {
    // 启动后立即持续向 stdout/stderr 喷出海量字节，若未及时 drain 会积压阻塞
    Future<void>.microtask(() {
      for (var i = 0; i < 64; i++) {
        _stdoutCtrl.add(List<int>.filled(512, 65));
        _stderrCtrl.add(List<int>.filled(512, 66));
      }
      _stdoutCtrl.close();
      _stderrCtrl.close();
    });
  }

  @override
  final int pid;
  final _stdoutCtrl = StreamController<List<int>>();
  final _stderrCtrl = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  bool killed = false;

  void finish([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish(-1);
    return true;
  }
}

class _NoopMpvClient implements MpvPipeClient {
  @override
  Future<double?> queryNumericProperty(String pipePath, String property) async =>
      null;
}

class _StubGatewayFactory extends MediaSourceGatewayFactory {
  _StubGatewayFactory(this.gateway);

  final _ConcurrentSlowHeadGateway gateway;

  @override
  Future<MediaSourceGateway> create(
    MediaSource source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async => gateway;
}

Future<Uint8List> _stubImageLoader(
  String url, {
  int? targetWidth,
  TmdbImageSize? imageSize,
}) async => Uint8List(0);

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  group('1. 流网桥并发 Range 防死锁与特殊文件名 URL 编码测试', () {
    test('含特殊字符文件名不产生 %25 双重编码，且支持 HEAD、UTF-8 Content-Disposition 与并发尾部分片 500ms 内完成', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
      final bridge = LocalStreamBridge();
      addTearDown(bridge.dispose);

      final payload = Uint8List.fromList(
        List<int>.generate(4096, (i) => i % 253),
      );
      final gw = _ConcurrentSlowHeadGateway(payload);
      const fileName = '[ANK-Raws] うる星やつら (BDrip 1920x1080 HEVC FLAC).mkv';

      final session = await bridge.registerSession(
        gateway: gw,
        relativePath: 'Anime/$fileName',
        fileName: fileName,
        knownLength: payload.length,
        ownsGateway: false,
      );

      final urlStr = session.url.toString();
      expect(urlStr, isNot(contains('%25')));
      expect(session.url.pathSegments.last, fileName);
      expect(Uri.decodeComponent(session.url.path.split('/').last), fileName);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      // HEAD 验证
      final headReq = await client.headUrl(session.url);
      final headRes = await headReq.close();
      await headRes.drain<void>();
      expect(headRes.statusCode, HttpStatus.ok);
      expect(headRes.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(headRes.headers.contentLength, payload.length);
      expect(
        headRes.headers.value('content-disposition'),
        contains("filename*=UTF-8''"),
      );

      // 并发开启第 1 路从 0 开始的长流
      final req1 = await client.getUrl(session.url);
      req1.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final res1 = await req1.close();
      expect(res1.statusCode, HttpStatus.partialContent);
      await gw.firstStreamStarted.future.timeout(const Duration(seconds: 2));

      // 第 1 路保持挂起的同时，并发发起第 2 路尾部 Cues Range 请求并要求 500ms 内成功返回
      final sw = Stopwatch()..start();
      final req2 = await client.getUrl(session.url);
      req2.headers.set(HttpHeaders.rangeHeader, 'bytes=3968-4095');
      final res2 = await req2.close();
      final tailBytes = await res2.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      sw.stop();

      expect(res2.statusCode, HttpStatus.partialContent);
      expect(tailBytes, equals(payload.sublist(3968, 4096)));
      expect(
        sw.elapsedMilliseconds,
        lessThan(500),
        reason: '第 2 路尾部 Range 请求绝不可被第 1 路流锁死',
      );

      // 强制中断第 1 路下游 Socket，验证网桥立刻取消上游流释放资源
      final sub1 = res1.listen((_) {});
      await sub1.cancel();
      await gw.firstStreamCancelled.future.timeout(const Duration(seconds: 2));
      expect(gw.firstHeadCancelled, isTrue);
      }, _LoopbackHttpOverrides());
    });

    test('WebDavSourceGateway 当 HEAD 未给长度时自动回退 bytes=0-0 Content-Range 探测总大小', () async {
      final mockHttp = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response('', 200);
        }
        if (request.method == 'GET' &&
            request.headers['Range'] == 'bytes=0-0') {
          return http.Response.bytes(
            [1],
            206,
            headers: {'content-range': 'bytes 0-0/987654321'},
          );
        }
        return http.Response('', 404);
      });

      final gw = WebDavSourceGateway(
        rootUri: Uri.parse('https://dav.example.com/Anime/'),
        httpClient: mockHttp,
      );
      final size = await gw.probeFileLength('test.mkv');
      expect(size, 987654321);
    });
  });

  group('2. 外部播放器参数防乱码、选项前置与 Isolate/stdio 防死锁测试', () {
    test('MpvIpcTracker 清理手写引号、将选项前置并透传干净 displayTitle', () {
      final args = MpvIpcTracker.buildLaunchArguments(
        targetUrlOrPath: 'http://127.0.0.1:50000/stream/tok/demo.mkv',
        pipePath: r'\\.\pipe\konata_mpv_1',
        displayTitle: '福星小子 - 03 · 爱与青春的宇宙',
        startSeconds: 120,
        argumentsTemplate: '"--fullscreen" "{url}"',
      );

      expect(
        args,
        contains('--force-media-title=福星小子 - 03 · 爱与青春的宇宙'),
      );
      expect(args, contains('--title=福星小子 - 03 · 爱与青春的宇宙'));
      expect(args, contains('--fullscreen'));
      expect(args.any((a) => a.contains('"')), isFalse, reason: '不得含手写引号');
      expect(args.last, 'http://127.0.0.1:50000/stream/tok/demo.mkv');
    });

    test('RealExternalPlayerLauncher 立即排空子进程 stdout/stderr 且后台 Isolate 不阻塞主事件循环', () async {
      final bridge = LocalStreamBridge();
      addTearDown(bridge.dispose);

      final fakeGateway = _ConcurrentSlowHeadGateway(Uint8List(128));
      late List<String> capturedArgs;
      late _FakeLoudProcess fakeProc;

      final launcher = RealExternalPlayerLauncher(
        streamBridge: bridge,
        gatewayFactory: _StubGatewayFactory(fakeGateway),
        mpvPipeClient: _NoopMpvClient(),
        verifyExecutableExists: false,
        processStarter: (exe, args) async {
          capturedArgs = args;
          fakeProc = _FakeLoudProcess(pid: 4321);
          return fakeProc;
        },
      );

      final result = await launcher.launch(
        work: const Work(
          id: 'w_movie',
          title: '剧场版 铃芽之旅',
          tmdbMediaType: TmdbMediaType.movie,
        ),
        episode: const Episode(
          id: 'ep_1',
          workId: 'w_movie',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '第 1 话',
        ),
        variant: const MediaVariant(
          id: 'v1',
          workId: 'w_movie',
          episodeId: 'ep_1',
          sourceId: 'src_dav',
          relativePath: 'Suzume/[ANK-Raws] Suzume.mkv',
          fileName: '[ANK-Raws] Suzume.mkv',
          fileSize: 128,
        ),
        player: const ExternalPlayerConfig(
          id: 'mpv',
          name: 'MPV',
          kind: ExternalPlayerKind.mpv,
          executablePath: 'mpv.exe',
        ),
        source: const MediaSource(
          id: 'src_dav',
          kind: MediaSourceKind.webdav,
          label: 'NAS',
          location: 'https://dav.example.com/Anime/',
        ),
        mainEpisodeCount: 1,
      );

      expect(result.launched, isTrue);
      expect(capturedArgs, contains('--force-media-title=剧场版 铃芽之旅'));
      expect(capturedArgs, contains('--title=剧场版 铃芽之旅'));

      // 同时拉起真实后台 Isolate 管道轮询，观测主 Isolate 10ms 心跳是否流畅不被阻塞
      var ticks = 0;
      final ticker = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => ticks++,
      );
      final isoHandle = await startMpvPipePollingIsolate(
        pipePath: r'\\.\pipe\konata_nonexistent_lock_test',
        pollInterval: const Duration(milliseconds: 50),
        onSnapshot: (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      ticker.cancel();
      await isoHandle.stop();
      fakeProc.finish(0);
      expect(ticks, greaterThanOrEqualTo(5), reason: '主事件循环心跳必须流畅推进');
    });
  });

  group('3. 单集正片/特典无多余序号前缀与抽屉左上角标题精简测试', () {
    test('EpisodeTitleFormatter 区分单一正片、多集番剧与特典映像卡片标题', () {
      const spExtra = Episode(
        id: 'e_menu',
        workId: 'w1',
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.menu,
        title: 'MENU 01',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: spExtra,
          workTitle: '芙莉莲',
          mainEpisodeCount: 28,
        ),
        'MENU 01',
      );

      const movieEp = Episode(
        id: 'e_mov',
        workId: 'w2',
        seasonNumber: 1,
        episodeNumber: 1,
        title: '第 1 话',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: movieEp,
          workTitle: '你的名字。',
          workMediaType: TmdbMediaType.movie,
          mainEpisodeCount: 1,
        ),
        '你的名字。',
      );

      const singleNumberedTvEp = Episode(
        id: 'e_ova',
        workId: 'w3',
        seasonNumber: 1,
        episodeNumber: 1,
        title: '第 1 话',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: singleNumberedTvEp,
          workTitle: '86 -不存在的战区-',
          workMediaType: TmdbMediaType.tv,
          mainEpisodeCount: 1,
        ),
        '第 01 话',
      );

      const singleNamedTvEp = Episode(
        id: 'e_tv1_named',
        workId: 'w3_86',
        seasonNumber: 1,
        episodeNumber: 1,
        title: 'Undertaker',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: singleNamedTvEp,
          workTitle: '86 -不存在的战区-',
          workMediaType: TmdbMediaType.tv,
          mainEpisodeCount: 1,
        ),
        '01 · Undertaker',
      );

      const singleUnnumberedOva = Episode(
        id: 'e_ova_unnumbered',
        workId: 'w3_ova',
        seasonNumber: 1,
        episodeNumber: null,
        title: '紫罗兰永恒花园 OVA',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: singleUnnumberedOva,
          workTitle: '紫罗兰永恒花园 OVA',
          workMediaType: TmdbMediaType.tv,
          mainEpisodeCount: 1,
        ),
        '紫罗兰永恒花园 OVA',
      );

      const seriesEp = Episode(
        id: 'e_tv2',
        workId: 'w4',
        seasonNumber: 1,
        episodeNumber: 2,
        title: '没必要魔法',
      );
      expect(
        EpisodeTitleFormatter.formatCardTitle(
          episode: seriesEp,
          workTitle: '芙莉莲',
          workMediaType: TmdbMediaType.tv,
          mainEpisodeCount: 28,
        ),
        '02 · 没必要魔法',
      );

      // 统一外部播放器与播放记录标题格式，彻底消除 S01E01 / S00E01
      const uruseiWork = Work(
        id: 'w_urusei',
        title: '福星小子',
        tmdbMediaType: TmdbMediaType.tv,
      );
      const uruseiEp3 = Episode(
        id: 'e_urusei3',
        workId: 'w_urusei',
        seasonNumber: 1,
        episodeNumber: 3,
        title: '爱与青春的宇宙',
      );
      final playerTitle = EpisodeTitleFormatter.formatPlayerMediaTitle(
        work: uruseiWork,
        episode: uruseiEp3,
        mainEpisodeCount: 23,
      );
      expect(playerTitle, '福星小子 - 03 · 爱与青春的宇宙');
      expect(playerTitle.contains(RegExp(r'S\d{2}E\d{2}')), isFalse);

      final extraPlayerTitle = EpisodeTitleFormatter.formatPlayerMediaTitle(
        work: uruseiWork,
        episode: spExtra,
        mainEpisodeCount: 23,
      );
      expect(extraPlayerTitle, '福星小子 · MENU 01');

      final historyMain = EpisodeTitleFormatter.formatHistorySubtitle(
        record: PlaybackRecord(
          id: 'r1',
          workId: 'w_urusei',
          episodeId: 'e_urusei3',
          variantId: 'v1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '动物园GO!',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 15),
        ),
        work: uruseiWork,
        mainEpisodeCount: 23,
      );
      expect(historyMain, '01 · 动物园GO!');

      final historyExtra = EpisodeTitleFormatter.formatHistorySubtitle(
        record: PlaybackRecord(
          id: 'r2',
          workId: 'w_urusei',
          episodeId: 'e_sp1',
          variantId: 'v2',
          seasonNumber: 0,
          episodeNumber: 1,
          episodeTitle: 'SP01',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 15),
        ),
        work: uruseiWork,
        mainEpisodeCount: 23,
      );
      expect(historyExtra, 'SP01');
    });

    testWidgets('DetailBottomDrawer 展开后显示精简标题 正片 (1) / 特典 (1)，且单集/特典无 01 · 前缀', (tester) async {
      tester.view.physicalSize = const Size(1280, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const work = Work(
        id: 'w_single',
        title: '剧场版 天气之子',
        tmdbMediaType: TmdbMediaType.movie,
      );
      const mainEp = Episode(
        id: 'm1',
        workId: 'w_single',
        seasonNumber: 1,
        episodeNumber: 1,
        title: '第 1 话',
      );
      const extraEp = Episode(
        id: 'ex1',
        workId: 'w_single',
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.menu,
        title: 'MENU 01',
      );
      final bundle = WorkDetailBundle(
        work: work,
        episodes: const [mainEp, extraEp],
        variants: const [
          MediaVariant(
            id: 'vm',
            workId: 'w_single',
            episodeId: 'm1',
            sourceId: 's1',
            relativePath: 'Weathering.mkv',
            fileName: 'Weathering.mkv',
            fileSize: 1000,
          ),
          MediaVariant(
            id: 've',
            workId: 'w_single',
            episodeId: 'ex1',
            sourceId: 's1',
            relativePath: 'SP/MENU 01.mkv',
            fileName: 'MENU 01.mkv',
            fileSize: 500,
          ),
        ],
        sourcesById: const {
          's1': MediaSource(
            id: 's1',
            kind: MediaSourceKind.local,
            label: '本地',
            location: r'C:\Anime',
          ),
        },
        latestPlayback: null,
      );

      DetailDrawerTab? tab = DetailDrawerTab.main;
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Align(
                alignment: Alignment.bottomCenter,
                child: DetailBottomDrawer(
                  bundle: bundle,
                  activeTab: tab,
                  imageLoader: _stubImageLoader,
                  onToggleTab: (next) => setState(() => tab = next),
                  onCollapse: () => setState(() => tab = null),
                  onEpisodeTap: (_) {},
                  onEpisodeAdjustSlot: (_) {},
                  onOpenManualMatch: () {},
                  onOpenManualEdit: () {},
                  onOpenPosterPicker: () {},
                  onOpenBackdropPicker: () {},
                  onHideWork: () {},
                  onDeleteWork: () {},
                  onRescrape: () {},
                  onOpenLocalDir: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('正片 (1)'), findsOneWidget);
      expect(find.text('剧场版 天气之子'), findsOneWidget);
      expect(find.textContaining('01 ·'), findsNothing);

      // 切换特典标签
      await tester.tap(find.text('特典 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('特典 (1)'), findsOneWidget);
      expect(find.text('MENU 01'), findsOneWidget);
      expect(find.textContaining('01 ·'), findsNothing);
    });
  });

  group('4. 详情页背景原画档位、缓存尺寸隔离与防降采样测试', () {
    test('ArtworkCache 对不同档位缓存隔离且 TmdbService 优先选取 >=1920 原画背景与 /original/ 请求', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_orig_cache_');
      final cache = ArtworkCache(tempDir);
      addTearDown(() async {
        cache.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final keyLow = ArtworkCache.buildSizedKey(TmdbImageSize.w500, 'bg.jpg');
      final keyHigh = ArtworkCache.buildSizedKey(TmdbImageSize.original, '/bg.jpg');
      expect(keyLow, 'w500_/bg.jpg');
      expect(keyHigh, 'original_/bg.jpg');
      expect(keyLow, isNot(equals(keyHigh)));

      await cache.write(keyLow, Uint8List.fromList([1, 2]), quality: 2);
      expect(await cache.read(keyHigh), isNull);

      final requestedPaths = <String>[];
      final mockHttp = MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path.contains('/tv/999')) {
          return http.Response(
            jsonEncode({
              'id': 999,
              'name': 'Demo',
              'backdrop_path': '/low_res.jpg',
              'images': {
                'backdrops': [
                  {
                    'file_path': '/low_res.jpg',
                    'iso_639_1': 'zh',
                    'width': 1280,
                    'height': 720,
                    'vote_average': 9.0,
                  },
                  {
                    'file_path': '/uhd_4k.jpg',
                    'iso_639_1': null,
                    'width': 3840,
                    'height': 2160,
                    'vote_average': 7.5,
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response.bytes([9, 8, 7, 6], 200);
      });

      final service = TmdbService(
        httpClient: TmdbHttpClient(
          config: const TmdbNetworkConfig(credential: 'v3_demo'),
          scheduler: PriorityHttpScheduler(),
          httpClient: mockHttp,
        ),
        artworkCache: cache,
      );

      final detail = await service.getWorkDetail(999, TmdbMediaType.tv);
      expect(detail?.backdropPath, '/uhd_4k.jpg');

      final origBytes = await service.fetchImageBytes(
        '/uhd_4k.jpg',
        size: TmdbImageSize.original,
        targetWidth: 260,
      );
      expect(origBytes, [9, 8, 7, 6]);
      expect(requestedPaths.any((p) => p.contains('/original/uhd_4k.jpg')), isTrue);
    });

    testWidgets('ManagedImage 原画与 Logo 模式下绕过 ResizeImage 降采样并开启 FilterQuality.high', (tester) async {
      TmdbImageSize? requestedSize;
      final png1x1 = Uint8List.fromList([
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

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  width: 300,
                  height: 180,
                  child: ManagedImage(
                    '/hero_4k.jpg',
                    loader: (url, {targetWidth, imageSize}) async {
                      requestedSize = imageSize;
                      return png1x1;
                    },
                    artwork: ManagedArtwork.backdrop,
                    isHeroBackdrop: true,
                    imageSize: TmdbImageSize.original,
                  ),
                ),
                SizedBox(
                  width: 180,
                  height: 240,
                  child: ManagedImage(
                    '/poster_thumb.jpg',
                    loader: (url, {targetWidth, imageSize}) async => png1x1,
                    artwork: ManagedArtwork.poster,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(requestedSize, TmdbImageSize.original);
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images.length, 2);
      // 第 1 张 Hero 背景原画不包裹 ResizeImage，且使用 FilterQuality.high
      expect(images[0].image, isA<ManagedImageProvider>());
      expect(images[0].filterQuality, FilterQuality.high);
      // 第 2 张海报缩略图继续使用 ResizeImage 控制解码内存
      expect(images[1].image, isA<ResizeImage>());
      expect(images[1].filterQuality, FilterQuality.medium);
    });
  });
}
