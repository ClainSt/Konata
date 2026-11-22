import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/playback/subtitle_memory_engine.dart';
import 'package:konata/application/playback/unified_playback_coordinator.dart';
import 'package:konata/application/playback/unified_playback_engine.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/playback/playback_probe_stats.dart';
import 'package:konata/domain/playback/subtitle_and_audio_choices.dart';
import 'package:konata/domain/playback/track_preferences.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/logging/diagnostics_log_store.dart';
import 'package:konata/infrastructure/players/embedded_mpv_session.dart';
import 'package:konata/infrastructure/players/libmpv_ffi.dart';
import 'package:konata/infrastructure/players/mpv_quality_profile.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:konata/infrastructure/subtitles/fontinass_cloud_client.dart';
import 'package:konata/infrastructure/subtitles/subtitle_font_pool_manager.dart';
import 'package:konata/presentation/audio/mini_audio_bar.dart';
import 'package:konata/presentation/shell/adaptive_capsule_layout.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/video/embedded_video_page.dart';
import 'package:konata/presentation/video/video_side_sheet.dart';
import 'package:konata/presentation/widgets/design_system/konata_pill_button.dart';
import 'package:konata/presentation/widgets/playback/konata_spec_badge.dart';

class _PassthroughHttpOverrides extends HttpOverrides {}

/// 完整模拟字幕内存直注、字库目录切换与样式属性热更新的轻量 `LibMpvClient`。
class _RegressionFakeMpvClient implements LibMpvClient, LibMpvUnobservable {
  final List<List<String>> commands = <List<String>>[];
  final Map<String, String> stringProps = <String, String>{};
  final Map<String, double> doubleProps = <String, double>{
    'time-pos': 15.0,
    'duration': 1440.0,
  };
  final Map<String, bool> flagProps = <String, bool>{'pause': false};
  final Map<String, int> intProps = <String, int>{};
  final List<MpvTrackInfo> tracks = <MpvTrackInfo>[];
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  int _nextTrackId = 1;
  int _nextPlaylistEntryId = 1;

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 901;

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
    commands.add(List<String>.from(args));
    if (args.isEmpty) return 0;
    if (args.first == 'loadfile') {
      final entryId = _nextPlaylistEntryId++;
      scheduleMicrotask(() {
        if (!_events.isClosed) {
          _events.add(MpvStartFileEvent(entryId));
          _events.add(const MpvFileLoadedEvent());
          _events.add(const MpvPlaybackRestartEvent());
        }
      });
    } else if (args.first == 'sub-add' && args.length >= 2) {
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
    } else if (args.first == 'sub-remove' && args.length >= 2) {
      final targetId = int.tryParse(args[1]);
      if (targetId != null) {
        tracks.removeWhere(
          (t) => t.type == MpvTrackType.subtitle && t.id == targetId,
        );
      }
    }
    return 0;
  }

  @override
  int commandAsync(int replyUserdata, List<String> args) => command(args);

  @override
  Future<void> dispose() async {
    isDisposed = true;
    if (!_events.isClosed) {
      await _events.close();
    }
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
  int requestLogMessages(String minLevel) => 0;

  @override
  int unobserveProperty(int registeredReplyUserdata) => 0;

  @override
  List<MpvAudioDevice> readAudioDeviceList() => const [];

  @override
  List<PlaybackChapter> readChapterList({double? totalDurationSeconds}) =>
      const [];

  @override
  List<MpvSeekableRange> readDemuxerSeekableRanges() => const [];

  @override
  List<MpvTrackInfo> readTrackList() => List<MpvTrackInfo>.unmodifiable(tracks);

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
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
      stringProps['sid'] = '$value';
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
    if (name == 'sid') {
      final parsed = value == 'no' ? null : int.tryParse(value);
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
            selected: parsed != null && t.id == parsed,
          );
        }
      }
    }
    return 0;
  }
}

/// 构造满足 `SfntHeaderValidator` 真头校验的最小合法 TrueType SFNT 字节流。
Uint8List _buildMinimalValidTtfBytes() {
  final data = ByteData(12 + 16 + 16);
  data.setUint32(0, 0x00010000);
  data.setUint16(4, 1);
  data.setUint16(6, 16);
  data.setUint16(8, 0);
  data.setUint16(10, 0);
  data.setUint32(12, 0x68656164); // 'head'
  data.setUint32(16, 0);
  data.setUint32(20, 28);
  data.setUint32(24, 16);
  return data.buffer.asUint8List();
}

/// 将原始字节编码为 ASS `[Fonts]` 标准 UUE 文本块。
String _encodeAssUue(Uint8List bytes) {
  final sb = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final remain = bytes.length - i;
    if (remain >= 3) {
      final v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      sb.writeCharCode(((v >> 18) & 0x3F) + 33);
      sb.writeCharCode(((v >> 12) & 0x3F) + 33);
      sb.writeCharCode(((v >> 6) & 0x3F) + 33);
      sb.writeCharCode((v & 0x3F) + 33);
      i += 3;
    } else if (remain == 2) {
      final v = (bytes[i] << 16) | (bytes[i + 1] << 8);
      sb.writeCharCode(((v >> 18) & 0x3F) + 33);
      sb.writeCharCode(((v >> 12) & 0x3F) + 33);
      sb.writeCharCode(((v >> 6) & 0x3F) + 33);
      i += 2;
    } else {
      final v = bytes[i] << 16;
      sb.writeCharCode(((v >> 18) & 0x3F) + 33);
      sb.writeCharCode(((v >> 12) & 0x3F) + 33);
      i += 1;
    }
  }
  return sb.toString();
}

const String _sampleOriginalAss = '''[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,FZZhunYuan-M02,52,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,28,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,測試特效字幕樣式
''';

String _buildSubsettedAssWithEmbeddedFont() {
  final uue = _encodeAssUue(_buildMinimalValidTtfBytes());
  return '''[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,ALIAS_FZZY01,52,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,28,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,測試特效字幕樣式

[Fonts]
fontname: ALIAS_FZZY01_0.ttf
$uue
''';
}

VideoLaunchRequest _buildLaunchRequest({
  required String videoPath,
  String workId = 'work_16bit',
  List<String> externalSubtitles = const [],
}) {
  final work = Work(id: workId, title: '16bit的感動');
  final ep = Episode(
    id: 'ep_1',
    workId: workId,
    seasonNumber: 1,
    episodeNumber: 1,
    title: '第 1 集',
  );
  final videoDir = p.dirname(videoPath);
  final relativeSubtitles = externalSubtitles
      .map(
        (s) => p.isAbsolute(s)
            ? p.relative(s, from: videoDir).replaceAll('\\', '/')
            : s.replaceAll('\\', '/'),
      )
      .toList();
  final variant = MediaVariant(
    id: 'var_1',
    workId: workId,
    episodeId: ep.id,
    sourceId: 'src_local',
    relativePath: p.basename(videoPath),
    fileName: p.basename(videoPath),
    fileSize: 1024,
    externalSubtitles: relativeSubtitles,
  );
  final source = MediaSource(
    id: 'src_local',
    kind: MediaSourceKind.local,
    label: '本地片库',
    location: videoDir,
  );
  final bundle = WorkDetailBundle(
    work: work,
    episodes: [ep],
    variants: [variant],
    variantsByEpisodeId: {
      ep.id: [variant],
    },
    playbackByEpisodeId: const {},
    sourcesById: {'src_local': source},
    latestPlayback: null,
  );
  return VideoLaunchRequest(
    work: work,
    bundle: bundle,
    episode: ep,
    variant: variant,
    source: source,
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

  group('问题 A：退出视频收起悬浮小窗稳定性与跨类型起点防污染回归', () {
    testWidgets(
      '音频卡片起点绝不污染视频展开，且多次展开/收起/关播后均稳定呈现 16:9 悬浮小窗',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final tempDir = Directory.systemTemp.createTempSync(
          'konata_mini_collapse_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });
        final videoFile = File(p.join(tempDir.path, 'ep01.mkv'))
          ..writeAsBytesSync(const <int>[0, 1, 2, 3]);
        final req = _buildLaunchRequest(videoPath: videoFile.path);

        final db = KonataDatabase(NativeDatabase.memory());
        final repo = DriftLibraryRepository(db);
        await tester.runAsync(() => repo.upsertWork(req.work));
        final container = ProviderContainer(
          overrides: [
            konataDatabaseProvider.overrideWith((ref) {
              ref.onDispose(db.close);
              return db;
            }),
            libraryRepositoryProvider.overrideWithValue(repo),
            storageRootProvider.overrideWithValue(
              StorageRootService(overrideRoot: tempDir),
            ),
            playbackPreferencesProvider.overrideWith(
              () => PlaybackPreferencesNotifier(enablePersistence: false),
            ),
            videoPlaybackProvider(req).overrideWith(
              () => VideoPlaybackController(
                req,
                deferBootstrap: true,
                initialState: VideoPlaybackState(
                  isInitializing: false,
                  isBuffering: false,
                  hasFirstFrame: true,
                  isPlaying: true,
                  currentWork: req.work,
                  currentBundle: req.bundle,
                  currentEpisode: req.episode,
                  currentVariant: req.variant,
                  probeStats: const PlaybackProbeStats(
                    videoWidth: 1920,
                    videoHeight: 1080,
                  ),
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              navigatorKey: container.read(rootNavigatorKeyProvider),
              navigatorObservers: [container.read(rootRouteObserverProvider)],
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (_, child) => MiniAudioOverlayHost(child: child!),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomLeft,
                  child: Builder(
                    builder: (cdCtx) => GestureDetector(
                      key: const ValueKey('fake_cd_card'),
                      onTap: () => captureStageMorphOriginRect(
                        cdCtx,
                        kind: FloatingMiniPlayerKind.audio,
                      ),
                      child: const SizedBox(
                        width: 114,
                        height: 173,
                        child: ColoredBox(color: Colors.blueGrey),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. 先模拟点击左下角 2:3 音频 CD 卡片并处于历史贴边耳片态。
        await tester.tap(find.byKey(const ValueKey('fake_cd_card')));
        await tester.pump();
        container.read(floatingMiniVisualStateProvider.notifier).state =
            FloatingMiniVisualState.tucked;
        expect(container.read(stageMorphOriginRectProvider), isNotNull);
        expect(
          container.read(stageMorphOriginKindProvider),
          equals(FloatingMiniPlayerKind.audio),
        );

        // 2. 启动视频全屏并完成展开：音频起点不得被视频消费，展开完成后清空历史起点。
        await container.read(activeVideoSessionProvider.notifier).openVideo(req);
        await tester.pumpAndSettle();
        expect(find.byType(EmbeddedVideoPage), findsOneWidget);
        expect(
          container.read(floatingMiniVisualStateProvider),
          equals(FloatingMiniVisualState.collapsed),
        );
        expect(container.read(stageMorphOriginRectProvider), isNull);

        // 3. 连续 2 轮收起至小窗 -> 展开 -> 再收起：每轮均必须稳定呈现 16:9 横屏小窗且反向标记归零。
        for (var round = 0; round < 2; round++) {
          await container
              .read(activeVideoSessionProvider.notifier)
              .collapseToMini();
          await tester.pumpAndSettle();

          expect(
            container.read(stageMorphReverseVideoActiveProvider),
            isFalse,
          );
          expect(find.byType(EmbeddedVideoPage), findsNothing);
          final miniFinder = find.byKey(
            const ValueKey('konata_floating_mini_player'),
          );
          expect(miniFinder, findsOneWidget);
          final miniRect = tester.getRect(miniFinder);
          expect(miniRect.width, greaterThan(miniRect.height));
          expect(miniRect.width / miniRect.height, closeTo(16.0 / 9.0, 0.08));

          container.read(activeVideoSessionProvider.notifier).expandToFull();
          await tester.pumpAndSettle();
          expect(find.byType(EmbeddedVideoPage), findsOneWidget);
        }

        // 4. 彻底关闭再重开并收起：验证复用 OverlayEntry.opaque 绝不脱同步遮挡小窗。
        await container.read(activeVideoSessionProvider.notifier).closeVideo();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('konata_floating_mini_player')),
          findsNothing,
        );

        await container.read(activeVideoSessionProvider.notifier).openVideo(req);
        await tester.pumpAndSettle();
        await container
            .read(activeVideoSessionProvider.notifier)
            .collapseToMini();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('konata_floating_mini_player')),
          findsOneWidget,
        );
        expect(container.read(stageMorphReverseVideoActiveProvider), isFalse);

        await tester.runAsync(
          () => container.read(activeVideoSessionProvider.notifier).closeVideo(),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  group('问题 B：字幕子集化高辨识按钮、独立「子集化」轨道与真实 A/B 字库对比回归', () {
    test(
      'SubtitleMemoryEngine 与 mergeSubtitles 保留原轨并紧邻追加「子集化」轨，往返切换不回收子集轨',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'konata_subset_ab_unit_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        final assFile = File(
          p.join(
            tempDir.path,
            '[SweetSub&VCB-Studio] 16bit Sensation [01].cht.ass',
          ),
        );
        await assFile.writeAsString(_sampleOriginalAss);

        final fakeClient = _RegressionFakeMpvClient();
        fakeClient.initialize();
        final unifiedEngine = UnifiedPlaybackEngine();
        unifiedEngine.beginPhysicalMedia();
        final subsetAss = _buildSubsettedAssWithEmbeddedFont();
        final engine = SubtitleMemoryEngine(
          clientSupplier: () => fakeClient,
          playbackEngine: unifiedEngine,
          cloudSubsetTransform: (_) async => subsetAss,
        );

        // 1. 先挂载原始未子集化外挂 ASS 轨。
        final origMount = await engine.mountDiscoveredExternalSubtitles(
          textSubtitlePaths: [assFile.path],
          trackMemory: const CrossEpisodeTrackMemory(),
          trackPreferences: const TrackPreferences(),
          enableCloudSubsetForSelected: false,
        );
        expect(origMount.applied, isTrue);
        final origId = origMount.primaryTrackId!;

        // 2. 触发云端字体子集化：必须挂载独立新轨并自动切过去，原轨 ID 完整保留。
        final subsetRes = await engine.applyIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.memory(
              localFilePath: assFile.path,
              fileName: p.basename(assFile.path),
              displayTitle: '${p.basename(assFile.path)} [子集]',
              enableCloudSubset: true,
            ),
          ),
        );
        expect(subsetRes.applied, isTrue);
        expect(subsetRes.cloudSubsetApplied, isTrue);
        final subsetId = subsetRes.primaryTrackId!;
        expect(subsetId, isNot(equals(origId)));
        expect(
          engine.lookupOriginalTrackIdForSourcePath(assFile.path),
          equals(origId),
        );
        expect(engine.isCloudSubsetTrackId(subsetId), isTrue);

        List<SubtitleChoice> readChoices() =>
            SubtitleAndAudioChoices.mergeSubtitles(
              mpvTracks: fakeClient.readTrackList(),
              discoveredExternalPaths: [assFile.path],
              mountedSourcePathsByTrackId: engine.mountedSourcePathsSnapshot,
              cloudSubsetTrackIds: engine.cloudSubsetTrackIdsSnapshot,
              authoritativeSelectedTrackId: int.tryParse(
                fakeClient.getPropertyString('sid') ?? '',
              ),
            );

        final afterSubset = readChoices();
        expect(afterSubset, hasLength(2));
        expect(afterSubset[0].mpvTrackId, equals(origId));
        expect(afterSubset[0].isCloudSubset, isFalse);
        expect(afterSubset[0].sourceFormatBadge, equals('外挂 ASS'));
        expect(afterSubset[0].selected, isFalse);

        expect(afterSubset[1].mpvTrackId, equals(subsetId));
        expect(afterSubset[1].isCloudSubset, isTrue);
        expect(afterSubset[1].sourceFormatBadge, equals('子集化'));
        expect(afterSubset[1].selected, isTrue);

        // 3. 切回原轨：子集化轨道严禁被 sub-remove 回收，仍保留在列表中供来回对比。
        final backToOrig = await engine.applyIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.existingTrack(origId),
          ),
        );
        expect(backToOrig.applied, isTrue);
        final afterOrig = readChoices();
        expect(afterOrig, hasLength(2));
        expect(afterOrig[0].selected, isTrue);
        expect(afterOrig[1].selected, isFalse);

        // 4. 再次切回子集化轨道。
        final backToSubset = await engine.applyIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.existingTrack(subsetId),
          ),
        );
        expect(backToSubset.applied, isTrue);
        final afterSecondSubset = readChoices();
        expect(afterSecondSubset, hasLength(2));
        expect(afterSecondSubset[0].selected, isFalse);
        expect(afterSecondSubset[1].selected, isTrue);
      },
    );

    test(
      'VideoPlaybackController 手动触发字幕子集化后自动切换至「子集化」轨、提示指定文案且往返切换真实隔离字库目录',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final tempDir = await Directory.systemTemp.createTemp(
            'konata_subset_e2e_',
          );
          final videoFile = File(p.join(tempDir.path, '16bit_01.mkv'));
          await videoFile.writeAsBytes(const <int>[0, 1, 2, 3]);
          final assFile = File(
            p.join(
              tempDir.path,
              '[SweetSub&VCB-Studio] 16bit Sensation [01].cht.ass',
            ),
          );
          await assFile.writeAsString(_sampleOriginalAss);

          final subsetAssPayload = _buildSubsettedAssWithEmbeddedFont();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((httpReq) async {
            await httpReq.drain<void>();
            httpReq.response.statusCode = HttpStatus.ok;
            httpReq.response.headers.contentType = ContentType.text;
            httpReq.response.add(utf8.encode(subsetAssPayload));
            await httpReq.response.close();
          });
          final endpointUrl = 'http://127.0.0.1:${server.port}/api/subset';

          final fakeClient = _RegressionFakeMpvClient();
          final storageRoot = StorageRootService(overrideRoot: tempDir);
          final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
          final authStore = CloudSubsetAuthorizationStore();
          authStore.grant(Uri.parse(endpointUrl));
          final fontPool = SubtitleFontPoolManager(storageRoot: storageRoot);
          final cloudClient = FontInAssCloudClient(
            authorizationStore: authStore,
            storageRoot: storageRoot,
          );
          final unifiedEngine = UnifiedPlaybackEngine();
          final db = KonataDatabase(NativeDatabase.memory());
          final repo = DriftLibraryRepository(db);
          final req = _buildLaunchRequest(
            videoPath: videoFile.path,
            externalSubtitles: [assFile.path],
          );
          await repo.upsertWork(req.work);
          late EmbeddedMpvSession createdSession;

          final container = ProviderContainer(
            overrides: [
              konataDatabaseProvider.overrideWith((ref) {
                ref.onDispose(db.close);
                return db;
              }),
              libraryRepositoryProvider.overrideWithValue(repo),
              storageRootProvider.overrideWithValue(storageRoot),
              unifiedPlaybackEngineProvider.overrideWithValue(unifiedEngine),
              cloudSubsetAuthorizationStoreProvider.overrideWithValue(authStore),
              fontInAssCloudClientProvider.overrideWithValue(cloudClient),
              subtitleFontPoolManagerProvider.overrideWithValue(fontPool),
              playbackPreferencesProvider.overrideWith(
                () => PlaybackPreferencesNotifier(
                  enablePersistence: false,
                  initialState: PlaybackPreferencesState(
                    cloudSubsetEnabled: true,
                    cloudSubsetEndpoint: endpointUrl,
                  ),
                ),
              ),
              videoPlaybackProvider(req).overrideWith(
                () => VideoPlaybackController(
                  req,
                  sessionFactory: () {
                    createdSession = EmbeddedMpvSession(
                      streamBridge: streamBridge,
                      storageRoot: storageRoot,
                      fontPoolManager: fontPool,
                      clientFactory: () => fakeClient,
                    );
                    return createdSession;
                  },
                ),
              ),
            ],
          );

          final sub = container.listen(videoPlaybackProvider(req), (_, _) {});
          final ctrl = container.read(videoPlaybackProvider(req).notifier);
          try {
            for (var i = 0; i < 40; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
              final s = container.read(videoPlaybackProvider(req));
              if (!s.isInitializing && s.subtitles.any((t) => t.selected)) {
                break;
              }
            }
            expect(container.read(videoPlaybackProvider(req)).errorMessage, isNull);
            final initialSubs = container.read(videoPlaybackProvider(req)).subtitles;
            expect(initialSubs, hasLength(1));
            expect(initialSubs[0].sourceFormatBadge, equals('外挂 ASS'));
            expect(initialSubs[0].selected, isTrue);

            final baselineFontsDir = createdSession.baselineSubFontsDir;
            expect(baselineFontsDir, isNotEmpty);

            // 触发「字幕子集化」：新增独立「子集化」轨、自动切换过去并提示准确文案。
            final res = await ctrl.applyCloudSubsetToActiveSubtitle();
            expect(res?.applied, isTrue);
            expect(res?.cloudSubsetApplied, isTrue);
            await Future<void>.delayed(const Duration(milliseconds: 40));

            final stateAfterSubset = container.read(videoPlaybackProvider(req));
            expect(
              stateAfterSubset.transientNotice?.message,
              equals('已切换到经语义核验的子集化字幕'),
            );
            expect(stateAfterSubset.subtitles, hasLength(2));
            expect(stateAfterSubset.subtitles[0].sourceFormatBadge, equals('外挂 ASS'));
            expect(stateAfterSubset.subtitles[0].selected, isFalse);
            expect(stateAfterSubset.subtitles[1].sourceFormatBadge, equals('子集化'));
            expect(stateAfterSubset.subtitles[1].selected, isTrue);

            final subsetFontsDir = createdSession.activeSubFontsDir;
            expect(subsetFontsDir, isNot(equals(baselineFontsDir)));

            // 切回原字幕：sid 切回原轨且 sub-fonts-dir 恢复基准目录。
            ctrl.selectSubtitle(stateAfterSubset.subtitles[0]);
            await Future<void>.delayed(const Duration(milliseconds: 60));
            final stateAfterOrig = container.read(videoPlaybackProvider(req));
            expect(stateAfterOrig.subtitles[0].selected, isTrue);
            expect(stateAfterOrig.subtitles[1].selected, isFalse);
            expect(createdSession.activeSubFontsDir, equals(baselineFontsDir));

            // 再次切回子集化字幕：sid 切回子集轨且 sub-fonts-dir 恢复子集字体池。
            ctrl.selectSubtitle(stateAfterOrig.subtitles[1]);
            await Future<void>.delayed(const Duration(milliseconds: 60));
            final stateAfterBack = container.read(videoPlaybackProvider(req));
            expect(stateAfterBack.subtitles[0].selected, isFalse);
            expect(stateAfterBack.subtitles[1].selected, isTrue);
            expect(createdSession.activeSubFontsDir, equals(subsetFontsDir));
          } finally {
            await ctrl.closeAndRelease();
            sub.close();
            await streamBridge.dispose();
            container.dispose();
            await server.close(force: true);
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          }
        }, _PassthroughHttpOverrides());
      },
    );

    testWidgets(
      'VideoSideSheet 展示高对比主按钮「字幕子集化」与「外挂 ASS / 子集化」高亮对比轨道',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await tester.binding.setSurfaceSize(const Size(1280, 960));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        try {
          final tempDir = Directory.systemTemp.createTempSync(
            'konata_subset_ui_',
          );
          addTearDown(() {
            if (tempDir.existsSync()) {
              tempDir.deleteSync(recursive: true);
            }
          });
          final videoFile = File(p.join(tempDir.path, '16bit_01.mkv'))
            ..writeAsBytesSync(const <int>[0, 1, 2, 3]);
          final assPath = p.join(
            tempDir.path,
            '[SweetSub&VCB-Studio] 16bit Sensation [01].cht.ass',
          );
          final req = _buildLaunchRequest(
            videoPath: videoFile.path,
            externalSubtitles: [assPath],
          );
          final db = KonataDatabase(NativeDatabase.memory());
          final repo = DriftLibraryRepository(db);
          await tester.runAsync(() => repo.upsertWork(req.work));

          final container = ProviderContainer(
            overrides: [
              konataDatabaseProvider.overrideWith((ref) {
                ref.onDispose(db.close);
                return db;
              }),
              libraryRepositoryProvider.overrideWithValue(repo),
              storageRootProvider.overrideWithValue(
                StorageRootService(overrideRoot: tempDir),
              ),
              playbackPreferencesProvider.overrideWith(
                () => PlaybackPreferencesNotifier(
                  enablePersistence: false,
                  initialState: const PlaybackPreferencesState(
                    cloudSubsetEnabled: true,
                    cloudSubsetEndpoint: FontInAssCloudClient.defaultEndpointUrl,
                  ),
                ),
              ),
              videoPlaybackProvider(req).overrideWith(
                () => VideoPlaybackController(
                  req,
                  deferBootstrap: true,
                  initialState: VideoPlaybackState(
                    isInitializing: false,
                    isBuffering: false,
                    hasFirstFrame: true,
                    currentWork: req.work,
                    currentBundle: req.bundle,
                    currentEpisode: req.episode,
                    currentVariant: req.variant,
                    subtitles: [
                      SubtitleChoice(
                        mpvTrackId: 1,
                        title: p.basename(assPath),
                        codec: 'ass',
                        externalPath: assPath,
                        isExternal: true,
                        selected: false,
                      ),
                      SubtitleChoice(
                        mpvTrackId: 2,
                        title: p.basename(assPath),
                        codec: 'ass',
                        externalPath: assPath,
                        isExternal: true,
                        isCloudSubset: true,
                        selected: true,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
          addTearDown(container.dispose);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
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
                  body: VideoSideSheet(
                    request: req,
                    initialTab: VideoSideSheetTab.subtitles,
                    onClose: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final subsetBtnFinder = find.byKey(
            const ValueKey('apply_cloud_subset_button'),
          );
          expect(subsetBtnFinder, findsOneWidget);
          final subsetBtn = tester.widget<KonataPillButton>(subsetBtnFinder);
          expect(subsetBtn.label, equals('字幕子集化'));
          expect(subsetBtn.variant, equals(KonataPillVariant.primary));

          expect(find.text('外挂 ASS'), findsOneWidget);
          expect(
            find.byWidgetPredicate(
              (w) => w is KonataSpecBadge && w.label == '子集化' && w.highlighted,
            ),
            findsOneWidget,
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  group('问题 C：字幕字号与底部边距实时丝滑热更新与真实 libmpv-2.dll 验证', () {
    test(
      'applyLiveSubtitleStyleUpdate 仅写入字幕参数且动态映射 sub-pos，绝不触碰硬解与着色器',
      () {
        final client = _RegressionFakeMpvClient()..initialize();

        MpvQualityProfile.applyLiveSubtitleStyleUpdate(
          client,
          config: const PlaybackQualityConfig(
            subFontSize: 64,
            subBottomMargin: 60,
            subOverrideMode: SubtitleAssOverrideMode.scaleOnly,
          ),
        );

        expect(client.stringProps['sub-ass-override'], equals('scale'));
        expect(client.doubleProps['sub-scale'], closeTo(64.0 / 52.0, 1e-4));
        expect(client.intProps['sub-margin-y'], equals(60));
        expect(client.doubleProps['sub-pos'], closeTo(88.0, 1e-4));
        expect(client.stringProps.containsKey('hwdec'), isFalse);
        expect(client.stringProps.containsKey('glsl-shaders'), isFalse);
        expect(client.stringProps.containsKey('audio-device'), isFalse);

        // Force 模式写入 PlayResY 自动归一的 sub-font-size、sub-margin-y 与动态 sub-pos，并清空原生样式冲突覆写。
        MpvQualityProfile.applyLiveSubtitleStyleUpdate(
          client,
          config: const PlaybackQualityConfig(
            subFontSize: 44,
            subBottomMargin: 120,
            subOverrideMode: SubtitleAssOverrideMode.forceStyle,
          ),
        );
        expect(client.stringProps['sub-ass-override'], equals('force'));
        expect(client.doubleProps['sub-font-size'], equals(44.0));
        expect(client.doubleProps['sub-scale'], equals(1.0));
        expect(client.intProps['sub-margin-y'], equals(120));
        expect(client.doubleProps['sub-pos'], closeTo(76.0, 1e-4));
        expect(client.stringProps['sub-ass-style-overrides'], isEmpty);
      },
    );

    test(
      'Windows 真实 libmpv-2.dll 运行时热更新字号、底部边距与 sub-pos 零错误生效',
      () async {
        if (!Platform.isWindows) return;
        final dllPath = p.join(
          Directory.current.path,
          'native',
          'konata-native',
          'windows',
          'libmpv-2.dll',
        );
        expect(File(dllPath).existsSync(), isTrue);

        final logStore = DiagnosticsLogStore();
        final client = FfiLibMpvClient.create(preferredLibraryPath: dllPath);
        try {
          client.setOptionString('vo', 'null');
          client.setOptionString('ao', 'null');
          expect(client.initialize(), equals(0));

          MpvQualityProfile.applyLiveSubtitleStyleUpdate(
            client,
            config: const PlaybackQualityConfig(
              subFontSize: 72,
              subBottomMargin: 80,
              subOverrideMode: SubtitleAssOverrideMode.scaleOnly,
            ),
            logStore: logStore,
          );
          expect(client.getPropertyString('sub-ass-override'), equals('scale'));
          expect(
            client.getPropertyDouble('sub-scale'),
            closeTo(72.0 / 52.0, 1e-3),
          );
          expect(client.getPropertyDouble('sub-pos'), closeTo(84.0, 0.5));

          MpvQualityProfile.applyLiveSubtitleStyleUpdate(
            client,
            config: const PlaybackQualityConfig(
              subFontSize: 44,
              subBottomMargin: 100,
              subOverrideMode: SubtitleAssOverrideMode.forceStyle,
            ),
            logStore: logStore,
          );
          expect(client.getPropertyString('sub-ass-override'), equals('force'));
          expect(client.getPropertyDouble('sub-font-size'), closeTo(44.0, 0.1));
          expect(client.getPropertyDouble('sub-pos'), closeTo(80.0, 0.5));
          expect(logStore.buildRecentIncidentReport(), isNot(contains('skipped')));
        } finally {
          await client.dispose();
        }
      },
    );

    testWidgets(
      '拖动字号与底部边距滑块时零磁盘延迟实时同步写入 libmpv（字号切 Scale，底部边距切 Force 并动态映射 sub-pos）',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        await tester.binding.setSurfaceSize(const Size(1280, 960));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        VideoPlaybackController? activeCtrl;
        try {
        final tempDir = Directory.systemTemp.createTempSync(
          'konata_sub_slider_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });
        final videoFile = File(p.join(tempDir.path, 'ep.mkv'))
          ..writeAsBytesSync(const <int>[0, 1, 2, 3]);
        final fakeClient = _RegressionFakeMpvClient();
        final storageRoot = StorageRootService(overrideRoot: tempDir);
        final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
        addTearDown(streamBridge.dispose);
        final db = KonataDatabase(NativeDatabase.memory());
        final repo = DriftLibraryRepository(db);
        final req = _buildLaunchRequest(videoPath: videoFile.path);
        await tester.runAsync(() => repo.upsertWork(req.work));

        final container = ProviderContainer(
          overrides: [
            konataDatabaseProvider.overrideWith((ref) {
              ref.onDispose(db.close);
              return db;
            }),
            libraryRepositoryProvider.overrideWithValue(repo),
            storageRootProvider.overrideWithValue(storageRoot),
            playbackPreferencesProvider.overrideWith(
              () => PlaybackPreferencesNotifier(enablePersistence: false),
            ),
            videoPlaybackProvider(req).overrideWith(
              () => VideoPlaybackController(
                req,
                sessionFactory: () => EmbeddedMpvSession(
                  streamBridge: streamBridge,
                  storageRoot: storageRoot,
                  clientFactory: () => fakeClient,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
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
                body: VideoSideSheet(
                  request: req,
                  initialTab: VideoSideSheetTab.subtitles,
                  onClose: () {},
                ),
              ),
            ),
          ),
        );
        activeCtrl = container.read(videoPlaybackProvider(req).notifier);
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (!container.read(videoPlaybackProvider(req)).isInitializing) {
            break;
          }
        }
        expect(
          container.read(videoPlaybackProvider(req)).errorMessage,
          isNull,
        );

        // 拖动字号滑块：立即同步写入 sub-scale 并切至 scaleOnly。
        final sizeSlider = find.byKey(
          const ValueKey('subtitle_font_size_slider'),
        );
        await tester.ensureVisible(sizeSlider);
        await tester.drag(sizeSlider, const Offset(80, 0));
        await tester.pump();

        final afterSizeCfg = container
            .read(playbackPreferencesProvider)
            .qualityConfig;
        expect(afterSizeCfg.subFontSize, greaterThan(52));
        expect(
          afterSizeCfg.subOverrideMode,
          equals(SubtitleAssOverrideMode.scaleOnly),
        );
        expect(
          fakeClient.doubleProps['sub-scale'],
          closeTo(afterSizeCfg.subFontSize / 52.0, 1e-4),
        );

        // 拖动底部边距滑块：自动升级为 Force 模式并实时同步写入 sub-margin-y、sub-ass-force-margins 与动态 sub-pos。
        final marginSlider = find.byKey(
          const ValueKey('subtitle_bottom_margin_slider'),
        );
        await tester.ensureVisible(marginSlider);
        await tester.drag(marginSlider, const Offset(100, 0));
        await tester.pump();

        final afterMarginCfg = container
            .read(playbackPreferencesProvider)
            .qualityConfig;
        expect(afterMarginCfg.subBottomMargin, greaterThan(28));
        expect(
          afterMarginCfg.subOverrideMode,
          equals(SubtitleAssOverrideMode.forceStyle),
        );
        expect(
          fakeClient.intProps['sub-margin-y'],
          equals(afterMarginCfg.subBottomMargin),
        );
        expect(fakeClient.flagProps['sub-ass-force-margins'], isTrue);
        expect(
          fakeClient.doubleProps['sub-pos'],
          closeTo(
            (100.0 - afterMarginCfg.subBottomMargin * 0.20).clamp(70.0, 100.0),
            1e-4,
          ),
        );

        Future<void> closeControllerCleanly(
          VideoPlaybackController ctrl,
        ) async {
          final closing = ctrl.closeAndRelease();
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          await closing;
        }

        await closeControllerCleanly(activeCtrl!);
        activeCtrl = null;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 250));
        } finally {
          if (activeCtrl != null) {
            final closing = activeCtrl.closeAndRelease();
            for (var i = 0; i < 10; i++) {
              await tester.pump(const Duration(milliseconds: 20));
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
            }
            await closing;
          }
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
