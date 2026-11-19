import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/artwork_palette_service.dart';
import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/playback/unified_playback_engine.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/audiophile_safety_policy.dart';
import 'package:ccplayer/domain/playback/cue_and_lrc_parser.dart';
import 'package:ccplayer/domain/playback/lyric_version_matcher.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/subtitle_content_processor.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/android/android_audio_route_bridge.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:ccplayer/presentation/audio/immersive_audio_sub_widgets.dart';
import 'package:ccplayer/presentation/settings/settings_players_panel.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/video_side_sheet.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_switch.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_toast.dart';

/// 面向端到端联调测试的轻量模拟 `libmpv` 客户端（完整记录音量斜坡、字幕内存直注与滤镜属性）。
class _EndToEndFakeMpvClient implements LibMpvClient {
  final List<List<String>> commands = <List<String>>[];
  final List<double> volumeHistory = <double>[];
  final Map<String, String> stringProps = <String, String>{};
  final Map<String, double> doubleProps = <String, double>{
    'time-pos': 12.0,
    'duration': 1440.0,
  };
  final Map<String, bool> flagProps = <String, bool>{'pause': false};
  final Map<String, int> intProps = <String, int>{};
  final List<MpvTrackInfo> tracks = <MpvTrackInfo>[];
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  int _nextTrackId = 10;

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 777;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  void emitEvent(MpvClientEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

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
    commands.add(List<String>.from(args));
    if (args.isNotEmpty && args.first == 'loadfile') {
      scheduleMicrotask(() {
        emitEvent(const MpvFileLoadedEvent());
        emitEvent(const MpvPlaybackRestartEvent());
      });
    } else if (args.length >= 2 && args.first == 'sub-add') {
      final source = args[1];
      final title = args.length >= 4 ? args[3] : 'MemSub';
      final newId = _nextTrackId++;
      tracks.add(
        MpvTrackInfo(
          id: newId,
          type: MpvTrackType.subtitle,
          title: title,
          codec: 'ass',
          isExternal: true,
          externalFilename: source,
          selected: false,
        ),
      );
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    if (!_events.isClosed) await _events.close();
  }

  @override
  bool? getPropertyFlag(String name) => flagProps[name];

  @override
  double? getPropertyDouble(String name) => doubleProps[name];

  @override
  int? getPropertyInt64(String name) => intProps[name];

  @override
  String? getPropertyString(String name) => stringProps[name];

  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvTrackInfo> readTrackList() => List<MpvTrackInfo>.of(tracks);

  @override
  int requestLogMessages(String minLevel) => 0;

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
    if (name == 'volume') {
      volumeHistory.add(value);
    }
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    flagProps[name] = value;
    return 0;
  }

  @override
  int setPropertyInt64(String name, int value) {
    intProps[name] = value;
    if (name == 'sid') {
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        if (t.type == MpvTrackType.subtitle) {
          tracks[i] = MpvTrackInfo(
            id: t.id,
            type: t.type,
            title: t.title,
            lang: t.lang,
            codec: t.codec,
            isExternal: t.isExternal,
            externalFilename: t.externalFilename,
            selected: t.id == value,
          );
        }
      }
    }
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    stringProps[name] = value;
    if (name == 'sid' && value == 'no') {
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        if (t.type == MpvTrackType.subtitle) {
          tracks[i] = MpvTrackInfo(
            id: t.id,
            type: t.type,
            title: t.title,
            lang: t.lang,
            codec: t.codec,
            isExternal: t.isExternal,
            externalFilename: t.externalFilename,
            selected: false,
          );
        }
      }
    }
    return 0;
  }
}

class _StaticAudioNotifier extends AudioPlaybackNotifier {
  _StaticAudioNotifier(super.ref, AudioPlaybackState initial) {
    state = initial;
  }

  void updatePosition(double seconds) {
    state = state.copyWith(positionSeconds: seconds);
  }
}

Widget _wrapTestApp(Widget home, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: KonataTheme.darkTheme(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            home,
            const KonataToastViewport(),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('第三阶段端到端界面与运行时联调验收', () {
    test('AudioPlaybackNotifier 启播施加 150ms S 型微淡入并在终态立即停钟，HDMI 直通严格互斥清零滤镜', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final tempDir = await Directory.systemTemp.createTemp('konata_fade_e2e_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final audioFile = File(p.join(tempDir.path, '01_test.flac'));
      await audioFile.writeAsBytes(const <int>[0x66, 0x4C, 0x61, 0x43, 0, 0]);
      final fakeClient = _EndToEndFakeMpvClient();
      final db = KonataDatabase(NativeDatabase.memory());

      final container = ProviderContainer(
        overrides: [
          konataDatabaseProvider.overrideWith((ref) {
            ref.onDispose(db.close);
            return db;
          }),
          storageRootProvider.overrideWithValue(
            StorageRootService(overrideRoot: tempDir),
          ),
          playbackPreferencesProvider.overrideWith(
            (_) => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          audioPlaybackProvider.overrideWith(
            (ref) => AudioPlaybackNotifier(
              ref,
              clientFactory: () => fakeClient,
              microFadeStepInterval: const Duration(milliseconds: 25),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const work = Work(id: 'w_audio', title: '孤独摇滚！');
      final source = MediaSource(
        id: 'src_local',
        label: '本地音乐',
        kind: MediaSourceKind.local,
        location: tempDir.path,
      );
      const variant = MediaVariant(
        id: 'v_audio',
        workId: 'w_audio',
        sourceId: 'src_local',
        relativePath: '01_test.flac',
        fileName: '01_test.flac',
        fileSize: 6,
        assetKind: AssetKind.cdAlbum,
      );

      final notifier = container.read(audioPlaybackProvider.notifier);
      await notifier.playCdCollection(
        work: work,
        cdVariants: const [variant],
        initialVariant: variant,
        sourcesById: {'src_local': source},
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // 刚起播时应施加末级 -12 dBFS 安全限幅并启动有界 150ms S 型微淡入。
      expect(
        fakeClient.stringProps['af'],
        contains('alimiter=limit=0.251'),
      );
      expect(notifier.isMicroFadeActive, isTrue);
      expect(fakeClient.volumeHistory, isNotEmpty);
      expect(fakeClient.volumeHistory.contains(0.0), isTrue);

      // 等待 240ms 后 S 型微淡入必须平滑抵达目标音量并彻底停钟，零常驻计时器残留。
      await Future<void>.delayed(const Duration(milliseconds: 240));
      expect(notifier.isMicroFadeActive, isFalse);
      expect(fakeClient.doubleProps['volume'], equals(100.0));
      expect(
        fakeClient.volumeHistory.any((v) => v > 0.0 && v < 100.0),
        isTrue,
      );

      // 开启 Windows HDMI audio-spdif 直通后必须立即清空所有软件 DSP 与限幅滤镜。
      await container
          .read(playbackPreferencesProvider.notifier)
          .setBitstreamPassthrough(true);
      await notifier.reapplyAudiophileSafetyChain();
      expect(fakeClient.stringProps['af'], isEmpty);
      expect(
        fakeClient.stringProps['audio-spdif'],
        equals(AudiophileSafetyPolicy.defaultSpdifCodecs),
      );
      expect(notifier.activeSafetyPlan.microFadeInDurationMs, equals(0));
    });

    testWidgets('ImmersiveLyricLineLeaf 激活行并行渲染主唱与和声 Active Span Set 逐字扫光，非激活行纯净展示', (
      tester,
    ) async {
      const rawEnhanced =
          '[00:10.00]<00:10.00>光る<00:10.50>なら\n'
          '[00:10.00]bg:<00:10.20>Ah~<00:10.70>yeah\n'
          '[00:15.00]<00:15.00>次の<00:15.50>夜へ';
      final lrcDoc = LrcParser.parseText(rawEnhanced);
      final spanLines = LyricVersionMatcher.parseActiveSpanLines(rawEnhanced);
      late _StaticAudioNotifier audioNotifier;

      await tester.pumpWidget(
        _wrapTestApp(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ImmersiveLyricLineLeaf(
                index: 0,
                line: lrcDoc.lines[0],
                activeSpanLine: LyricVersionMatcher.matchLineForTimestamp(
                  spanLines,
                  lrcDoc.lines[0].startSeconds,
                ),
                compact: false,
                userScrolling: false,
                onSeekLine: () {},
              ),
              ImmersiveLyricLineLeaf(
                index: 1,
                line: lrcDoc.lines[1],
                activeSpanLine: LyricVersionMatcher.matchLineForTimestamp(
                  spanLines,
                  lrcDoc.lines[1].startSeconds,
                ),
                compact: false,
                userScrolling: false,
                onSeekLine: () {},
              ),
            ],
          ),
          overrides: [
            audioPlaybackProvider.overrideWith((ref) {
              audioNotifier = _StaticAudioNotifier(
                ref,
                AudioPlaybackState(
                  isActive: true,
                  isPlaying: true,
                  positionSeconds: 10.4,
                  lrcDocument: lrcDoc,
                  activeSpanLines: spanLines,
                  activeLyricIndex: 0,
                ),
              );
              return audioNotifier;
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 第 0 行为当前激活行：同时渲染主唱与和声并行扫光叶子。
      expect(find.byKey(const ValueKey('active_lead_spans')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('active_harmony_spans')),
        findsOneWidget,
      );
      // 第 1 行为非激活行：不应泄漏原始 `<00:15.00>` 尖括号标签。
      expect(find.text('次の夜へ'), findsOneWidget);
      expect(find.textContaining('<00:15.00>'), findsNothing);

      // 推进播放秒数触发局部叶子刷新且不抛异常。
      audioNotifier.updatePosition(10.65);
      await tester.pump();
      expect(find.byKey(const ValueKey('active_harmony_spans')), findsOneWidget);
    });

    testWidgets('VideoSideSheet 字幕面板串联内存 OpenCC、混淆子集保护徽标、离线固化时间轴与双语副字幕', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        const d3d11Channel = MethodChannel('konata/d3d11_video');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(d3d11Channel, (call) async {
            if (call.method == 'createSession') {
              return <String, Object?>{
                'sessionId': 1,
                'textureId': 101,
                'backend': 'd3d11',
                'adapterName': 'Mock D3D11 GPU',
              };
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(d3d11Channel, null);
      });

      final tempDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_sub_ui_'),
      ))!;
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final videoFile = File(p.join(tempDir.path, 'EP01.mkv'));
      final tradAssFile = File(p.join(tempDir.path, 'EP01.cht.ass'));
      final opaqueAssFile = File(p.join(tempDir.path, 'EP01.opaque.ass'));
      await tester.runAsync(() async {
        await videoFile.writeAsBytes(const <int>[0x1A, 0x45, 0xDF, 0xA3]);
        await tradAssFile.writeAsString(
          '[Script Info]\nTitle: Test\n\n'
          '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,歡迎來到動畫世界\n',
        );
        await opaqueAssFile.writeAsString(
          '[Script Info]\nTitle: Opaque\n\n'
          '[V4+ Styles]\n'
          'Style: Default,ABCDEF12+SubsetFont,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1\n\n'
          '[Events]\n'
          'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,\uE001\uE002\uE003\uE004\uE005\uE006\n',
        );
      });

      final fakeClient = _EndToEndFakeMpvClient();
      fakeClient.tracks.addAll([
        MpvTrackInfo(
          id: 1,
          type: MpvTrackType.subtitle,
          title: '繁体外挂',
          lang: 'cht',
          codec: 'ass',
          isExternal: true,
          externalFilename: tradAssFile.path,
          selected: true,
        ),
        MpvTrackInfo(
          id: 2,
          type: MpvTrackType.subtitle,
          title: '混淆子集外挂',
          lang: 'chi',
          codec: 'ass',
          isExternal: true,
          externalFilename: opaqueAssFile.path,
          selected: false,
        ),
      ]);

      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);
      const work = Work(id: 'w_sub', title: '测试动画');
      await tester.runAsync(() => repo.upsertWork(work));
      const ep = Episode(
        id: 'ep1',
        workId: 'w_sub',
        seasonNumber: 1,
        episodeNumber: 1,
      );
      final source = MediaSource(
        id: 'src_sub',
        label: '本地',
        kind: MediaSourceKind.local,
        location: tempDir.path,
      );
      final variant = MediaVariant(
        id: 'var1',
        workId: 'w_sub',
        sourceId: 'src_sub',
        episodeId: 'ep1',
        relativePath: 'EP01.mkv',
        fileName: 'EP01.mkv',
        fileSize: 4,
        externalSubtitles: [tradAssFile.path, opaqueAssFile.path],
      );
      final bundle = WorkDetailBundle(
        work: work,
        episodes: const [ep],
        variants: [variant],
        sourcesById: {'src_sub': source},
        latestPlayback: null,
      );
      final req = VideoLaunchRequest(
        work: work,
        episode: ep,
        variant: variant,
        bundle: bundle,
        source: source,
      );

      late VideoPlaybackController controller;
      final testStorage = StorageRootService(overrideRoot: tempDir);
      final streamBridge = LocalStreamBridge(storageRoot: testStorage);
      addTearDown(streamBridge.dispose);

      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrapTestApp(
          Align(
            alignment: Alignment.centerRight,
            child: VideoSideSheet(
              request: req,
              initialTab: VideoSideSheetTab.subtitles,
              onClose: () {},
            ),
          ),
          overrides: [
            konataDatabaseProvider.overrideWith((ref) {
              ref.onDispose(db.close);
              return db;
            }),
            libraryRepositoryProvider.overrideWithValue(repo),
            storageRootProvider.overrideWithValue(testStorage),
            playbackPreferencesProvider.overrideWith(
              (_) => PlaybackPreferencesNotifier(enablePersistence: false),
            ),
            videoPlaybackProvider(req).overrideWith((ref) {
              controller = VideoPlaybackController(
                ref,
                req,
                sessionFactory: () => EmbeddedMpvSession(
                  storageRoot: testStorage,
                  streamBridge: streamBridge,
                  clientFactory: () => fakeClient,
                ),
              );
              return controller;
            }),
          ],
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (controller.state.hasFirstFrame &&
            controller.state.subtitles.isNotEmpty) {
          break;
        }
      }
      expect(controller.state.errorMessage, isNull);
      expect(controller.state.hasFirstFrame, isTrue);
      expect(controller.state.subtitles, isNotEmpty);

      Future<void> flushRealIo() async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pump(const Duration(milliseconds: 220));
      }

      // 1. 选中繁体外挂并切换 OpenCC 为「转简体」：应经 `sub-add memory://... auto` 直注，且绝不触碰全局 sub-codepage。
      final firstSub = controller.state.subtitles.firstWhere(
        (s) => s.mpvTrackId == 1,
      );
      controller.selectSubtitle(firstSub);
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        find.byKey(const ValueKey('subtitle_opencc_segmented')),
        findsOneWidget,
      );
      await tester.tap(find.text('转简体'));
      await flushRealIo();
      expect(
        fakeClient.commands.any(
          (c) =>
              c.length >= 3 &&
              c[0] == 'sub-add' &&
              c[1].startsWith('memory://') &&
              c[1].contains('欢迎来到动画世界') &&
              c[2] == 'cached',
        ),
        isTrue,
      );
      expect(fakeClient.stringProps.containsKey('sub-codepage'), isFalse);

      // 2. 设置非零字幕延迟后出现「固化时间轴」按钮，点击后通过 memory:// 重映射并原子归零 sub-delay。
      controller.setSubtitleDelay(1.5);
      await tester.pump(const Duration(milliseconds: 40));
      final bakeBtn = find.byKey(
        const ValueKey('bake_subtitle_timeline_button'),
      );
      expect(bakeBtn, findsOneWidget);
      await tester.ensureVisible(bakeBtn);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(bakeBtn);
      await flushRealIo();
      expect(controller.state.subtitleDelaySeconds, equals(0.0));
      expect(fakeClient.doubleProps['sub-delay'], equals(0.0));
      expect(
        fakeClient.commands.any(
          (c) =>
              c.length >= 2 &&
              c[0] == 'sub-add' &&
              c[1].contains('0:00:02.50,0:00:04.50'),
        ),
        isTrue,
      );

      // 3. 切换双语副字幕（secondary-sid），验证不破坏当前主字幕 sid。
      final secondSub = controller.state.subtitles.firstWhere(
        (s) => s.mpvTrackId == 2,
      );
      final secFuture = controller.selectSecondarySubtitle(secondSub);
      await flushRealIo();
      await secFuture;
      expect(fakeClient.intProps['secondary-sid'], equals(2));
      expect(controller.state.secondarySubtitleTrackId, equals(2));

      // 4. 切换至混淆子集外挂并尝试「转简体」：自动保护原文并展示混淆子集保护徽标。
      controller.selectSubtitle(secondSub);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('转简体'));
      await flushRealIo();
      expect(
        controller.state.activeSubtitleSubsetState,
        equals(SubtitleSubsetState.opaqueObfuscatedSubset),
      );
      expect(
        find.byKey(const ValueKey('subtitle_subset_guard_badge')),
        findsOneWidget,
      );
      final closing = controller.closeAndRelease();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await closing;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 250));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('SettingsPlayersPanel 严格按端过滤音频开关，并串联 FontInAss 逐 Origin 授权与仅限 cloudSubset 域撤权', (
      tester,
    ) async {
      try {
      final tempDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_set_ui_'),
      ))!;
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      // --- 场景一：Windows 桌面端 ---
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final engine = UnifiedPlaybackEngine();
      final rawSubToken = engine.acquireTaskToken(
        PlaybackTaskDomain.rawSubtitleFetch,
      );
      final lyricToken = engine.acquireTaskToken(
        PlaybackTaskDomain.lyricLookup,
      );
      final cloudToken = engine.acquireTaskToken(
        PlaybackTaskDomain.cloudSubset,
      );

      await tester.pumpWidget(
        _wrapTestApp(
          const SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: SettingsPlayersPanel(),
          ),
          overrides: [
            storageRootProvider.overrideWithValue(
              StorageRootService(overrideRoot: tempDir),
            ),
            unifiedPlaybackEngineProvider.overrideWithValue(engine),
            playbackPreferencesProvider.overrideWith(
              (_) => PlaybackPreferencesNotifier(enablePersistence: false),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings_hdmi_spdif_switch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings_android_bit_perfect_usb')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('settings_audiophile_safety_notice')),
        findsOneWidget,
      );

      // 严禁残留原生 Material Switch，全部统一使用 KonataSwitch。
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(KonataSwitch), findsWidgets);

      // 开启 FontInAss 云端子集化开关，输入地址并授权 Origin。
      final cloudToggle = find.descendant(
        of: find.byKey(const ValueKey('settings_cloud_subset_toggle')),
        matching: find.byType(KonataSwitch),
      );
      await tester.ensureVisible(cloudToggle);
      await tester.tap(cloudToggle);
      await tester.pumpAndSettle();

      final endpointField = find.descendant(
        of: find.byKey(const ValueKey('settings_cloud_subset_endpoint_field')),
        matching: find.byType(TextField),
      );
      await tester.enterText(
        endpointField,
        'https://Subset.Example.COM:443/api/v1/subset',
      );
      await tester.pumpAndSettle();

      expect(
        find.text('未授权 https://subset.example.com:443'),
        findsOneWidget,
      );
      final authBtn = find.byKey(
        const ValueKey('settings_cloud_subset_authorize_button'),
      );
      await tester.ensureVisible(authBtn);
      await tester.tap(authBtn);
      await tester.pumpAndSettle();
      expect(
        find.text('已授权 https://subset.example.com:443'),
        findsOneWidget,
      );

      // 点击「撤销授权」：仅取消 cloudSubset 任务域，绝不误杀 rawSubtitleFetch 与 lyricFetch。
      final revokeBtn = find.byKey(
        const ValueKey('settings_cloud_subset_revoke_button'),
      );
      await tester.ensureVisible(revokeBtn);
      await tester.tap(revokeBtn);
      await tester.pumpAndSettle();

      expect(engine.isTaskAlive(cloudToken), isFalse);
      expect(engine.isTaskAlive(rawSubToken), isTrue);
      expect(engine.isTaskAlive(lyricToken), isTrue);
      expect(
        find.text('未授权 https://subset.example.com:443'),
        findsOneWidget,
      );

      // --- 场景二：Android 端严格隐藏桌面独占项并展示 USB DAC 逐位直通 ---
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        _wrapTestApp(
          const SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: SettingsPlayersPanel(key: ValueKey('android_players_panel')),
          ),
          overrides: [
            storageRootProvider.overrideWithValue(
              StorageRootService(overrideRoot: tempDir),
            ),
            playbackPreferencesProvider.overrideWith(
              (_) => PlaybackPreferencesNotifier(enablePersistence: false),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings_hdmi_spdif_switch')),
        findsNothing,
      );
      expect(find.text('WASAPI 音频独占模式'), findsNothing);
      expect(
        find.byKey(const ValueKey('settings_android_bit_perfect_usb')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings_audiophile_safety_notice')),
        findsOneWidget,
      );
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(KonataSwitch), findsWidgets);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('后台 Isolate 封面主色聚类与 Riverpod LRU 缓存无静态泄漏', () async {
      // 构造 4x4 高饱和红/蓝/绿像素块，验证 Isolate 聚类返回三色非空色板
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        final offset = i * 4;
        if (i < 8) {
          rgba[offset] = 220;
          rgba[offset + 1] = 40;
          rgba[offset + 2] = 60;
        } else if (i < 12) {
          rgba[offset] = 40;
          rgba[offset + 1] = 110;
          rgba[offset + 2] = 230;
        } else {
          rgba[offset] = 50;
          rgba[offset + 1] = 210;
          rgba[offset + 2] = 100;
        }
        rgba[offset + 3] = 255;
      }

      final palette = await extractAuroraPaletteInIsolate(rgba);
      expect(palette, isNotNull);
      expect(palette!.length, equals(3));

      final cache = ArtworkPaletteCache(maxEntries: 2);
      cache.put('k1', palette);
      cache.put('k2', palette);
      expect(cache.get('k1'), isNotNull);
      cache.put('k3', palette);
      expect(cache.get('k2'), isNull);
      expect(cache.get('k1'), isNotNull);
      expect(cache.get('k3'), isNotNull);
    });

    test('AndroidAudioRouteBridge 可实例化多监听隔离且 dispose 自动清理', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('ccplayer/audio_route_unit_test');
      final bridge = AndroidAudioRouteBridge(
        channel: channel,
        isSupported: () => true,
      );

      final ownerA = Object();
      final ownerB = Object();
      final eventsA = <String>[];
      final eventsB = <String>[];

      bridge.bindRouteListeners(
        owner: ownerA,
        onOutputDeviceRemoved: (r) => eventsA.add('rm:$r'),
        onOutputDeviceAdded: (f) => eventsA.add('add:$f'),
      );
      bridge.bindRouteListeners(
        owner: ownerB,
        onOutputDeviceRemoved: (r) => eventsB.add('rm:$r'),
      );

      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(
              const MethodCall('outputDeviceRemoved', 'bt_disconnect'),
            ),
            (_) {},
          );
      expect(eventsA, equals(['rm:bt_disconnect']));
      expect(eventsB, equals(['rm:bt_disconnect']));

      bridge.unbindRouteListeners(owner: ownerB);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(
              const MethodCall('outputDeviceAdded', 'usb_dac_01'),
            ),
            (_) {},
          );
      expect(eventsA, equals(['rm:bt_disconnect', 'add:usb_dac_01']));
      expect(eventsB, equals(['rm:bt_disconnect']));

      bridge.dispose();
    });
  });
}
