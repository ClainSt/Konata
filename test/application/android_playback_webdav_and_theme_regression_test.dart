import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/playback/unified_playback_coordinator.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/playback_providers.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/domain/playback/track_preferences.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/players/android/android_video_surface_controller.dart';
import 'package:konata/infrastructure/players/embedded_mpv_session.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/players/mpv_quality_profile.dart';
import 'package:konata/infrastructure/sources/webdav_source_gateway.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:konata/presentation/settings/settings_appearance_panel.dart';
import 'package:konata/presentation/theme/konata_theme.dart';

/// 记录关闭阶段静音、解绑与销毁顺序的轻量模拟 `libmpv` 客户端。
class _CloseGuardFakeMpvClient implements LibMpvClient, LibMpvUnobservable {
  final List<String> ops = <String>[];
  final Map<String, String> stringProps = <String, String>{};
  final Map<String, bool> flagProps = <String, bool>{'pause': false};
  final Map<String, double> doubleProps = <String, double>{
    'time-pos': 42.0,
    'duration': 1440.0,
  };
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();
  bool autoEmitLoadEvents = true;

  void emitEvent(MpvClientEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 9527;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  String errorString(int code) => 'err($code)';

  @override
  int setOptionString(String name, String value) {
    stringProps['opt:$name'] = value;
    return 0;
  }

  @override
  int initialize() {
    isInitialized = true;
    return 0;
  }

  @override
  int command(List<String> args) {
    ops.add('cmd:${args.join(' ')}');
    if (autoEmitLoadEvents && args.isNotEmpty && args.first == 'loadfile') {
      Future.microtask(() {
        if (!_events.isClosed) {
          _events.add(const MpvFileLoadedEvent());
          _events.add(const MpvPlaybackRestartEvent());
        }
      });
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  int setPropertyString(String name, String value) {
    ops.add('str:$name=$value');
    stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    ops.add('flag:$name=$value');
    flagProps[name] = value;
    return 0;
  }

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
    return 0;
  }

  @override
  int setPropertyInt64(String name, int value) => 0;

  @override
  String? getPropertyString(String name) => stringProps[name];

  @override
  bool? getPropertyFlag(String name) => flagProps[name];

  @override
  double? getPropertyDouble(String name) => doubleProps[name];

  @override
  int? getPropertyInt64(String name) => null;

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int unobserveProperty(int replyUserdata) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  List<MpvTrackInfo> readTrackList() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  Future<void> dispose() async {
    ops.add('dispose');
    isDisposed = true;
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Android 播放退出释放、WebDAV 多 propstat 与外观预览回归', () {
    test(
      'ActiveVideoSessionNotifier.closeVideo 在 autoDispose 立即销毁后仍完成静音解绑与底层会话释放',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final tempDir = await Directory.systemTemp.createTemp('konata_close_');
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });
        final videoFile = File(p.join(tempDir.path, 'ep01.mkv'))
          ..writeAsBytesSync(const [0, 1, 2, 3]);

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final storageRoot = StorageRootService(overrideRoot: tempDir);
        final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
        addTearDown(streamBridge.dispose);
        final fakeClient = _CloseGuardFakeMpvClient();

        final source = MediaSource(
          id: 'src_local',
          label: '本地源',
          kind: MediaSourceKind.local,
          location: tempDir.path,
        );
        const work = Work(id: 'w_close_1', title: '退出释放回归番剧');
        await repo.upsertWork(work);
        const ep = Episode(
          id: 'ep_close_1',
          workId: 'w_close_1',
          category: EpisodeCategory.main,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '第 1 集',
        );
        final variant = MediaVariant(
          id: 'var_close_1',
          workId: work.id,
          episodeId: ep.id,
          sourceId: source.id,
          relativePath: p.basename(videoFile.path),
          fileName: p.basename(videoFile.path),
          fileSize: 4,
        );
        final bundle = WorkDetailBundle(
          work: work,
          episodes: const [ep],
          variants: [variant],
          sourcesById: {source.id: source},
          latestPlayback: null,
        );
        final req = VideoLaunchRequest(
          work: work,
          bundle: bundle,
          episode: ep,
          variant: variant,
          source: source,
        );

        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            storageRootProvider.overrideWithValue(storageRoot),
            localStreamBridgeProvider.overrideWithValue(streamBridge),
            videoPlaybackProvider(req).overrideWith(
              () => VideoPlaybackController(
                req,
                sessionFactory: () => EmbeddedMpvSession(
                  storageRoot: storageRoot,
                  streamBridge: streamBridge,
                  clientFactory: () => fakeClient,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // 模拟播放器页面临时订阅 autoDispose 的 videoPlaybackProvider，并在 closeVideo 时立即卸载。
        final sub = container.listen(
          videoPlaybackProvider(req),
          (_, _) {},
          fireImmediately: true,
        );
        final activeNotifier = container.read(
          activeVideoSessionProvider.notifier,
        );
        await activeNotifier.openVideo(req);

        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline) && !fakeClient.isInitialized) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        expect(fakeClient.isInitialized, isTrue);

        // 模拟活跃会话被清空时播放器组件立刻卸载并取消订阅，触发 autoDispose 竞态。
        final activeSub = container.listen(
          activeVideoSessionProvider,
          (prev, next) {
            if (next.request == null) {
              sub.close();
            }
          },
        );
        addTearDown(activeSub.close);

        await expectLater(activeNotifier.closeVideo(), completes);

        expect(fakeClient.flagProps['pause'], isTrue);
        expect(fakeClient.flagProps['mute'], isTrue);
        expect(fakeClient.isDisposed, isTrue);
        expect(container.read(activeVideoSessionProvider).request, isNull);
        expect(container.read(videoPlaybackActiveProvider), isFalse);
      },
    );

    test('WebDavSourceGateway 正确合并多段 propstat（404 位于 200 之前仍识别目录）', () async {
      const multiPropstatXml = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/</D:href>
    <D:propstat>
      <D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/光鸭云盘</D:href>
    <D:propstat>
      <D:prop><D:getetag/></D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
    <D:propstat>
      <D:prop>
        <D:resourcetype><D:collection/></D:resourcetype>
        <D:getlastmodified>Mon, 23 Nov 2026 12:00:00 GMT</D:getlastmodified>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/01.mkv</D:href>
    <D:propstat>
      <D:prop><D:getetag/></D:prop>
      <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
    <D:propstat>
      <D:prop>
        <D:resourcetype/>
        <D:getcontentlength>1048576</D:getcontentlength>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>''';
      final mockClient = MockClient(
        (_) async => http.Response(
          multiPropstatXml,
          207,
          headers: const {'content-type': 'application/xml; charset=utf-8'},
        ),
      );
      final gateway = WebDavSourceGateway(
        rootUri: Uri.parse('http://127.0.0.1:19798/dav/'),
        httpClient: mockClient,
      );
      addTearDown(gateway.close);

      final entries = await gateway.listDirectory('');
      expect(entries, hasLength(2));
      expect(entries.first.name, '光鸭云盘');
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.name, '01.mkv');
      expect(entries.last.isDirectory, isFalse);
      expect(entries.last.size, 1048576);
    });

    testWidgets('SettingsAppearancePanel 跟随系统选项渲染非零高度的深浅分屏预览卡片', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(child: SettingsAppearancePanel()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('跟随系统'), findsOneWidget);
      final followCard = find.ancestor(
        of: find.text('跟随系统'),
        matching: find.byType(GestureDetector),
      );
      final previewClip = find.descendant(
        of: followCard,
        matching: find.byType(ClipRRect),
      );
      final previewTiles = find
          .descendant(of: previewClip, matching: find.byType(DecoratedBox))
          .evaluate()
          .where((e) {
            final box = e.renderObject as RenderBox?;
            return box != null && box.size.height >= 58 && box.size.width >= 30;
          })
          .toList();
      expect(
        previewTiles.length,
        greaterThanOrEqualTo(2),
        reason: '跟随系统卡片必须同时渲染左右两半非零高度的深色/浅色分屏缩略预览',
      );
    });

    test(
      'Android 硬件解码回落软解前先暂停并置空 vo=null 隔离 AImageReader，再切 hwdec=no 并恢复输出',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('konata_hwfb_');
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });
        final storageRoot = StorageRootService(overrideRoot: tempDir);
        final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
        addTearDown(streamBridge.dispose);

        final client = _CloseGuardFakeMpvClient()
          ..autoEmitLoadEvents = false
          ..stringProps['current-tracks/video/codec'] = 'h264'
          ..stringProps['current-tracks/video/codec-profile'] = 'High 10'
          ..stringProps['video-params/pixelformat'] = 'yuv420p10le';
        final session = EmbeddedMpvSession(
          storageRoot: storageRoot,
          streamBridge: streamBridge,
          clientFactory: () => client,
        );
        addTearDown(session.dispose);

        final surface = _RegressionFakeAndroidSurface(
          const AndroidSurfaceDescriptor(
            wid: 77,
            width: 1920,
            height: 1080,
            hdrPeak: 0,
          ),
        );
        await session.initializeAndLoad(
          request: const EmbeddedVideoLoadRequest(
            workId: 'w_hi10p_rt',
            variant: MediaVariant(
              id: 'v_rt',
              workId: 'w_hi10p_rt',
              sourceId: 's_rt',
              relativePath: 'sample.mkv',
              fileName: 'sample.mkv',
              fileSize: 1024,
            ),
          ),
          qualityConfig: const PlaybackQualityConfig(),
          androidSurfaceSupplier: () async => surface,
        );
        client.ops.clear();

        client.emitEvent(const MpvFileLoadedEvent());
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final idxPause = client.ops.indexOf('flag:pause=true');
        final idxVoNull = client.ops.indexOf('str:vo=null');
        final idxHwNo = client.ops.indexOf('str:hwdec=no');
        final idxReload = client.ops.indexOf('cmd:video-reload');
        final idxVoBack = client.ops.indexOf('str:vo=gpu-next');
        expect(idxPause, greaterThanOrEqualTo(0));
        expect(idxVoNull, greaterThan(idxPause));
        expect(idxHwNo, greaterThan(idxVoNull));
        expect(idxReload, greaterThan(idxHwNo));
        expect(idxVoBack, greaterThan(idxReload));
      },
    );

    test('Android 装载已知 AVC 10-bit 结构化片源时在 loadfile 前直接切至软解', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_preload_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });
      final storageRoot = StorageRootService(overrideRoot: tempDir);
      final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
      addTearDown(streamBridge.dispose);

      final client = _CloseGuardFakeMpvClient()..autoEmitLoadEvents = false;
      final session = EmbeddedMpvSession(
        storageRoot: storageRoot,
        streamBridge: streamBridge,
        clientFactory: () => client,
      );
      addTearDown(session.dispose);

      final surface = _RegressionFakeAndroidSurface(
        const AndroidSurfaceDescriptor(
          wid: 79,
          width: 1920,
          height: 1080,
          hdrPeak: 0,
        ),
      );
      await session.initializeAndLoad(
        request: const EmbeddedVideoLoadRequest(
          workId: 'w_hi10p_pre',
          variant: MediaVariant(
            id: 'v_pre',
            workId: 'w_hi10p_pre',
            sourceId: 's_pre',
            relativePath: 'hi10p.mkv',
            fileName: 'hi10p.mkv',
            fileSize: 2048,
            videoCodec: 'AVC',
            bitDepth: '10bit',
          ),
        ),
        qualityConfig: const PlaybackQualityConfig(),
        androidSurfaceSupplier: () async => surface,
      );

      final idxHwNo = client.ops.indexOf('str:hwdec=no');
      final idxLoad = client.ops.indexWhere((o) => o.startsWith('cmd:loadfile'));
      expect(idxHwNo, greaterThanOrEqualTo(0));
      expect(idxLoad, greaterThan(idxHwNo));
      expect(session.isUsingSoftwareFallback, isTrue);
    });

    test('Android MainActivity 已迁移 getFlutterEngineFlags 并对联发科关闭 Impeller Vulkan', () {
      final mainActivity = File(
        p.join(
          Directory.current.path,
          'android/app/src/main/kotlin/com/anime/konata/MainActivity.kt',
        ),
      ).readAsStringSync();
      expect(mainActivity, contains('override fun getFlutterEngineFlags()'));
      expect(mainActivity, isNot(contains('override fun getFlutterShellArgs()')));
      expect(mainActivity, contains('--enable-impeller=false'));
      expect(mainActivity, contains('shouldDisableImpellerForCurrentDevice'));
    });
  });
}

class _RegressionFakeAndroidSurface extends AndroidVideoSurfaceController {
  _RegressionFakeAndroidSurface(this._descriptor);

  final AndroidSurfaceDescriptor _descriptor;

  @override
  AndroidSurfaceDescriptor? get current => _descriptor;

  @override
  Stream<AndroidSurfaceDescriptor?> get surfaceChanges => const Stream.empty();

  @override
  Future<AndroidSurfaceDescriptor?> queryCurrent() async => _descriptor;

  @override
  Future<void> releaseReference(int wid) async {}

  @override
  Future<void> dispose() async {}
}
