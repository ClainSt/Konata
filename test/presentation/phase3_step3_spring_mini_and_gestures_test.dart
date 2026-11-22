import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/pip_recovery_store.dart';
import 'package:konata/application/playback/unified_playback_coordinator.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/composition/windows_composition_root.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/domain/playback/track_preferences.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/players/embedded_mpv_session.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:konata/presentation/audio/mini_audio_bar.dart';
import 'package:konata/presentation/shell/adaptive_capsule_layout.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/video/embedded_video_page.dart';

class _InMemoryPipRecoveryStore implements PipRecoveryStore {
  PipPlaybackRecoverySnapshot? stored;

  @override
  Future<void> clear() async {
    stored = null;
  }

  @override
  Future<PipPlaybackRecoverySnapshot?> load() async => stored;

  @override
  Future<void> save(PipPlaybackRecoverySnapshot snapshot) async {
    stored = snapshot;
  }
}

class _Step3FakeMpvClient implements LibMpvClient {
  final Map<String, double> doubleProps = <String, double>{'time-pos': 120.0};
  final List<List<String>> commands = <List<String>>[];
  final List<double> speedHistory = <double>[];
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  @override
  bool isInitialized = true;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 9;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  String errorString(int code) => 'err($code)';

  @override
  int setOptionString(String name, String value) => 0;

  @override
  int initialize() => 0;

  @override
  int setPropertyString(String name, String value) => 0;

  @override
  int setPropertyFlag(String name, bool value) => 0;

  @override
  int setPropertyInt64(String name, int value) => 0;

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
    if (name == 'speed') {
      speedHistory.add(value);
    }
    return 0;
  }

  @override
  String? getPropertyString(String name) => null;

  @override
  bool? getPropertyFlag(String name) => false;

  @override
  int? getPropertyInt64(String name) => null;

  @override
  double? getPropertyDouble(String name) => doubleProps[name];

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
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int command(List<String> args) {
    commands.add(List<String>.from(args));
    if (args.length >= 2 && args[0] == 'seek') {
      final v = double.tryParse(args[1]);
      if (v != null) {
        doubleProps['time-pos'] = v;
      }
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await _events.close();
  }
}

class _Step3ShortcutTestController extends VideoPlaybackController {
  _Step3ShortcutTestController(super.request) : super(deferBootstrap: true);

  final List<double> relativeSeeks = <double>[];

  @override
  void seekRelative(double deltaSeconds) {
    relativeSeeks.add(deltaSeconds);
    super.seekRelative(deltaSeconds);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Step 3 · Android PiP 引擎存活重绑 vs 进程死亡快照冷恢复', () {
    test('双态恢复准确区分引擎存活重绑与冷启动快照重建，退出后自动清空快照', () async {
      SharedPreferences.setMockInitialValues({});
      final tempDir = await Directory.systemTemp.createTemp('konata_step3_pip_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final storage = StorageRootService(overrideRoot: tempDir);
      final bridge = LocalStreamBridge(storageRoot: storage);
      addTearDown(bridge.dispose);
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const source = MediaSource(
        id: 's_pip',
        kind: MediaSourceKind.local,
        label: 'Local',
        location: 'D:/Anime',
      );
      const work = Work(id: 'w_pip', title: '画中画恢复测试');
      const episode = Episode(
        id: 'e_pip',
        workId: 'w_pip',
        category: EpisodeCategory.main,
        seasonNumber: 1,
        episodeNumber: 3,
      );
      const variant = MediaVariant(
        id: 'v_pip',
        workId: 'w_pip',
        sourceId: 's_pip',
        relativePath: '03.mkv',
        fileName: '03.mkv',
        fileSize: 4096,
      );
      await repo.upsertMediaSource(source);
      await repo.upsertWork(work);
      await repo.upsertEpisode(episode);
      await repo.upsertMediaVariant(variant);

      const bundle = WorkDetailBundle(
        work: work,
        episodes: [episode],
        variants: [variant],
        sourcesById: {'s_pip': source},
        latestPlayback: null,
      );
      const req = VideoLaunchRequest(
        work: work,
        episode: episode,
        variant: variant,
        bundle: bundle,
      );

      final store = _InMemoryPipRecoveryStore();
      final client = _Step3FakeMpvClient();

      // 1. 引擎存活分支：进入 PiP 写入快照 -> 退出 PiP 命中 engineAliveRebind 且清空快照
      final aliveContainer = ProviderContainer(
        overrides: [
          ...WindowsCompositionRoot.providerOverrides(),
          storageRootProvider.overrideWithValue(storage),
          libraryRepositoryProvider.overrideWithValue(repo),
          pipRecoveryStoreProvider.overrideWithValue(store),
          videoPlaybackProvider(req).overrideWith(
            () => VideoPlaybackController(
              req,
              sessionFactory: () => EmbeddedMpvSession(
                storageRoot: storage,
                streamBridge: bridge,
                clientFactory: () => client,
              ),
            ),
          ),
        ],
      );
      addTearDown(aliveContainer.dispose);
      final aliveSub = aliveContainer.listen(
        videoPlaybackProvider(req),
        (_, _) {},
      );
      addTearDown(aliveSub.close);

      final activeNotifier = aliveContainer.read(
        activeVideoSessionProvider.notifier,
      );
      await activeNotifier.openVideo(req);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      activeNotifier.debugSetPipMode(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.stored, isNotNull);
      expect(store.stored!.workId, equals('w_pip'));
      expect(store.stored!.episodeId, equals('e_pip'));
      expect(store.stored!.wasInPip, isTrue);

      activeNotifier.debugSetPipMode(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        activeNotifier.lastRecoveryMode,
        equals(PipRecoveryMode.engineAliveRebind),
      );
      expect(store.stored, isNull);
      await activeNotifier.closeVideo();

      // 2. 进程死亡冷恢复分支：预置持久化快照 -> 全新容器调用 recoverPlaybackIfNeeded 命中 coldSnapshotRestore
      store.stored = PipPlaybackRecoverySnapshot(
        workId: 'w_pip',
        episodeId: 'e_pip',
        variantId: 'v_pip',
        positionSeconds: 327.6,
        audioOnly: false,
        wasInPip: true,
        savedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      );

      final coldClient = _Step3FakeMpvClient();
      final coldContainer = ProviderContainer(
        overrides: [
          ...WindowsCompositionRoot.providerOverrides(),
          storageRootProvider.overrideWithValue(storage),
          libraryRepositoryProvider.overrideWithValue(repo),
          pipRecoveryStoreProvider.overrideWithValue(store),
          workDetailBundleProvider('w_pip').overrideWith((_) async => bundle),
          videoPlaybackProvider.overrideWith2(
            (coldReq) => VideoPlaybackController(
              coldReq,
              sessionFactory: () => EmbeddedMpvSession(
                storageRoot: storage,
                streamBridge: bridge,
                clientFactory: () => coldClient,
              ),
            ),
          ),
        ],
      );
      addTearDown(coldContainer.dispose);

      final coldNotifier = coldContainer.read(
        activeVideoSessionProvider.notifier,
      );
      final mode = await coldNotifier.recoverPlaybackIfNeeded();
      expect(mode, equals(PipRecoveryMode.coldSnapshotRestore));
      final restoredSession = coldContainer.read(activeVideoSessionProvider);
      expect(restoredSession.request, isNotNull);
      expect(restoredSession.request!.startSeconds, closeTo(327.6, 0.001));
      expect(restoredSession.isExpanded, isTrue);
      expect(store.stored, isNull);
      await coldNotifier.closeVideo();
    });
  });

  group('Step 3 · Windows 窗口快捷键精修（Left 250ms 节流与 Right 失焦/切后台复原）', () {
    testWidgets('Left 按住 250ms 节流连发快退，Right 长按 2.0x 在失焦与切后台时必恢复原倍速', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      const work = Work(id: 'w_k', title: '快捷键测试');
      const episode = Episode(
        id: 'e_k',
        workId: 'w_k',
        category: EpisodeCategory.main,
        seasonNumber: 1,
        episodeNumber: 1,
      );
      const variant = MediaVariant(
        id: 'v_k',
        workId: 'w_k',
        sourceId: 's_k',
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      );
      const bundle = WorkDetailBundle(
        work: work,
        episodes: [episode],
        variants: [variant],
        sourcesById: {},
        latestPlayback: null,
      );
      const req = VideoLaunchRequest(
        work: work,
        episode: episode,
        variant: variant,
        bundle: bundle,
      );

      late _Step3ShortcutTestController controller;
      final container = ProviderContainer(
        overrides: [
          ...WindowsCompositionRoot.providerOverrides(),
          videoPlaybackProvider(req).overrideWith(() {
            controller = _Step3ShortcutTestController(req);
            return controller;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const EmbeddedVideoPage(request: req),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(EmbeddedVideoPage));
      await tester.pump();

      // 设置用户常驻倍速 1.25x
      controller.setPlaybackSpeed(1.25);
      await tester.pump();
      expect(container.read(videoPlaybackProvider(req)).speed, closeTo(1.25, 0.01));

      // 1. ArrowLeft：Down 立即快退 -5s，250ms 内 Repeat 被节流，270ms 后 Repeat 再次触发
      controller.relativeSeeks.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(controller.relativeSeeks, equals([-5.0]));

      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(controller.relativeSeeks, equals([-5.0]));

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 270)),
      );
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(controller.relativeSeeks, equals([-5.0, -5.0]));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);

      // 2. ArrowRight 长按进入 2.0x，应用切入 inactive（模拟 Alt-Tab 失焦不发 KeyUp）仍必恢复 1.25x
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(videoPlaybackProvider(req)).isSpeedBoostActive, isTrue);
      expect(container.read(videoPlaybackProvider(req)).speed, closeTo(2.0, 0.01));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(
        container.read(videoPlaybackProvider(req)).isSpeedBoostActive,
        isFalse,
      );
      expect(
        container.read(videoPlaybackProvider(req)).speed,
        closeTo(1.25, 0.01),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);

      // 3. ArrowRight 再次长按进入 2.0x，焦点主动移走（FocusManager.primaryFocus.unfocus）仍必恢复 1.25x
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(videoPlaybackProvider(req)).isSpeedBoostActive, isTrue);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(
        container.read(videoPlaybackProvider(req)).isSpeedBoostActive,
        isFalse,
      );
      expect(
        container.read(videoPlaybackProvider(req)).speed,
        closeTo(1.25, 0.01),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  group('Step 3 · 120Hz 物理弹簧吸附与临界视口矩阵零溢出验证', () {
    testWidgets('悬浮小窗带速度拖放经 SpringSimulation 吸附并立即停钟，零溢出覆盖 599/600dp、矮横屏与 1.15x 字号', (
      tester,
    ) async {
      final viewports = <(String, Size, bool)>[
        ('phone_599_boundary', const Size(599, 800), true),
        ('tablet_600_boundary', const Size(600, 800), true),
        ('short_landscape_390', const Size(844, 390), true),
        ('tablet_portrait', const Size(768, 1024), true),
        ('tablet_landscape', const Size(1024, 700), true),
      ];

      try {
        for (final (label, size, isAndroid) in viewports) {
          debugDefaultTargetPlatformOverride = isAndroid
              ? TargetPlatform.android
              : TargetPlatform.windows;
          await tester.binding.setSurfaceSize(size);

          final layout = AdaptiveCapsuleLayout(
            size: size,
            safe: const EdgeInsets.only(top: 24, bottom: 20),
            android: isAndroid,
            navigationVisible: true,
            miniKind: FloatingMiniPlayerKind.audio,
          );

          await tester.pumpWidget(
            ProviderScope(
              overrides: [...WindowsCompositionRoot.providerOverrides()],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: const TextScaler.linear(1.15),
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      KonataFloatingMiniPlayer(
                        kind: FloatingMiniPlayerKind.audio,
                        layout: layout,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: '$label (1.15x) 渲染不应产生溢出异常',
          );

          // 带惯性速度拖拽并松手，验证 SpringSimulation 在有界帧数内收敛停钟（pumpAndSettle 不超时）
          final finder = find.byKey(
            const ValueKey('konata_floating_mini_player'),
          );
          expect(finder, findsOneWidget);
          await tester.fling(
            finder,
            const Offset(-160, -80),
            900,
            warnIfMissed: false,
          );
          await tester.pumpAndSettle(const Duration(milliseconds: 16));
          expect(
            tester.takeException(),
            isNull,
            reason: '$label 弹簧甩动吸附后不应异常',
          );

          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$label 不越出左边界');
          expect(
            rect.right,
            lessThanOrEqualTo(size.width + 0.5),
            reason: '$label 不越出右边界',
          );
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.binding.setSurfaceSize(null);
      }
    });
  });
}
