import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/series_group.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:ccplayer/presentation/detail/detail_bottom_drawer.dart';
import 'package:ccplayer/presentation/detail/detail_full_list_dialog.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/video/video_side_sheet.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_osd_stroked_text.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_spec_badge.dart';

final Uint8List _transparentPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeVideoLibMpvClient implements LibMpvClient {
  final List<List<String>> commands = <List<String>>[];
  final Map<String, double> doubles = {'time-pos': 45.0, 'duration': 1440.0};
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 99;

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
  int setOptionString(String name, String value) => 0;

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
  bool? getPropertyFlag(String name) => false;
  @override
  double? getPropertyDouble(String name) => doubles[name];
  @override
  int? getPropertyInt64(String name) => 0;
  @override
  String? getPropertyString(String name) => '';
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
  List<MpvTrackInfo> readTrackList() => const [];
  @override
  int requestLogMessages(String minLevel) => 0;
  @override
  int setPropertyDouble(String name, double value) {
    doubles[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) => 0;
  @override
  int setPropertyInt64(String name, int value) => 0;
  @override
  int setPropertyString(String name, String value) => 0;
}

void main() {
  group('阶段 3：正片/特典双徽章、准确季名排序与跨季连播越过特典状态机验证', () {
    test('SeriesSeasonFormatter 精准提炼第 X 季/剧场版/OVA 名称、剥离噪点并按时间线排列', () {
      const s2Noise = Work(
        id: 'w-s2',
        title: '[VCB-Studio] 葬送的芙莉莲 第二季 BDrip 1080p HEVC FLAC',
        year: 2026,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 2,
      );
      const s1Clean = Work(
        id: 'w-s1',
        title: '[ReinForce] 葬送的芙莉莲 第一季 1080p',
        year: 2023,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        seriesLabel: '第 1 季',
      );
      const movieWork = Work(
        id: 'w-mov',
        title: '剧场版 间谍过家家 代号：白 [BDrip]',
        year: 2023,
        tmdbMediaType: TmdbMediaType.movie,
        seriesLabel: '剧场版',
      );
      const ovaWork = Work(
        id: 'w-ova',
        title: '[VCB-Studio] 某科学的超电磁炮 OVA BDrip',
        year: 2010,
      );

      final sorted = SeriesSeasonFormatter.sortSeriesMembers([
        movieWork,
        ovaWork,
        s2Noise,
        s1Clean,
      ]);
      expect(
        sorted.map((w) => w.id).toList(),
        ['w-s1', 'w-s2', 'w-ova', 'w-mov'],
      );

      expect(
        SeriesSeasonFormatter.formatMemberLabel(s1Clean, sorted),
        '第 1 季 · 葬送的芙莉莲',
      );
      expect(
        SeriesSeasonFormatter.formatMemberLabel(s2Noise, sorted),
        '第 2 季 · 葬送的芙莉莲',
      );
      expect(
        SeriesSeasonFormatter.formatMemberLabel(movieWork, sorted),
        '剧场版 · 间谍过家家 代号：白',
      );
      expect(
        SeriesSeasonFormatter.formatMemberLabel(ovaWork, sorted),
        'OVA · 某科学的超电磁炮',
      );
    });

    testWidgets('选集详情抽屉、完整列表弹窗与播放器选集列表均显式渲染「正片」与「特典」双徽章', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const work = Work(
        id: 'w1',
        title: '测验动画',
        year: 2024,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      const epMain = Episode(
        id: 'ep-main-1',
        workId: 'w1',
        seasonNumber: 1,
        episodeNumber: 1,
        category: EpisodeCategory.main,
        title: '第一话 初遇',
      );
      const epExtra = Episode(
        id: 'ep-extra-1',
        workId: 'w1',
        seasonNumber: 0,
        episodeNumber: 1,
        category: EpisodeCategory.extra,
        extraType: ExtraKind.ncop,
        title: 'NCOP1',
      );
      const varMain = MediaVariant(
        id: 'v-m1',
        workId: 'w1',
        episodeId: 'ep-main-1',
        sourceId: 's1',
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 1000,
      );
      const varExtra = MediaVariant(
        id: 'v-e1',
        workId: 'w1',
        episodeId: 'ep-extra-1',
        sourceId: 's1',
        relativePath: 'NCOP1.mkv',
        fileName: 'NCOP1.mkv',
        fileSize: 500,
      );
      const bundle = WorkDetailBundle(
        work: work,
        episodes: [epMain, epExtra],
        variants: [varMain, varExtra],
        sourcesById: {
          's1': MediaSource(
            id: 's1',
            label: 'Local',
            kind: MediaSourceKind.local,
            location: 'D:/Anime',
          ),
        },
        latestPlayback: null,
      );

      // 1. 详情抽屉正片页签显示「正片」徽章
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: DetailBottomDrawer(
                  bundle: bundle,
                  activeTab: DetailDrawerTab.main,
                  preferredTab: DetailDrawerTab.main,
                  showRawVideoFilename: false,
                  showCdTab: false,
                  showScanTab: false,
                  imageLoader: (_, {targetWidth, imageSize}) async =>
                      _transparentPng,
                  onToggleTab: (_) {},
                  onCollapse: () {},
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
                  onSelectSeriesWork: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 正片不再渲染冗余「正片」徽章，保持卡片视觉干净
      expect(find.byType(EpisodeCategoryBadge), findsNothing);

      // 2. 完整列表弹窗中正片不显示冗余徽章，切至特典后呈现「特典」徽章
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('full-list-scope'),
          overrides: [
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _transparentPng,
            ),
          ],
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: DetailFullListDialog(
                bundle: bundle,
                imageLoader: (_, {targetWidth, imageSize}) async =>
                    _transparentPng,
                initialTab: DetailDrawerTab.main,
                onEpisodeTap: (_) {},
                onEpisodeAdjustSlot: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(EpisodeCategoryBadge), findsNothing);
      await tester.tap(find.text('特典 (1)'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(EpisodeCategoryBadge),
          matching: find.text('特典'),
        ),
        findsWidgets,
      );
    });

    testWidgets(
      'VideoSideSheet 浏览多季不中断播放、高亮严格校验 workId+epId，且 S1 末集正片越过 NCOP1 直连 S2 第 01 集并归档旧 workId 进度',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);

        await repo.upsertMediaSource(
          const MediaSource(
            id: 's1',
            label: 'Local',
            kind: MediaSourceKind.local,
            location: r'D:\Anime',
          ),
        );
        final now = DateTime(2026, 11, 16);
        await repo.upsertSeriesGroup(
          SeriesGroup(
            id: 'ser-frieren',
            title: '葬送的芙莉莲',
            createdAt: now,
            updatedAt: now,
          ),
        );

        const s1Work = Work(
          id: 'w-s1',
          title: '葬送的芙莉莲',
          year: 2023,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 1,
          scrapeStatus: ScrapeStatus.matched,
          seriesId: 'ser-frieren',
          seriesOrder: 1,
          seriesLabel: '第 1 季',
        );
        const s2Work = Work(
          id: 'w-s2',
          title: '[VCB-Studio] 葬送的芙莉莲 第二季 BDrip',
          year: 2026,
          tmdbMediaType: TmdbMediaType.tv,
          matchedSeason: 2,
          scrapeStatus: ScrapeStatus.matched,
          seriesId: 'ser-frieren',
          seriesOrder: 2,
          seriesLabel: '第 2 季',
        );
        await repo.upsertWork(s1Work);
        await repo.upsertWork(s2Work);

        const s1Ep11 = Episode(
          id: 's1-ep11',
          workId: 'w-s1',
          seasonNumber: 1,
          episodeNumber: 11,
          category: EpisodeCategory.main,
          title: '北国寒冬',
        );
        const s1Ep12 = Episode(
          id: 's1-ep12',
          workId: 'w-s1',
          seasonNumber: 1,
          episodeNumber: 12,
          category: EpisodeCategory.main,
          title: '真正的勇者',
        );
        const s1Ncop = Episode(
          id: 's1-ncop',
          workId: 'w-s1',
          seasonNumber: 0,
          episodeNumber: 1,
          category: EpisodeCategory.extra,
          extraType: ExtraKind.ncop,
          title: 'NCOP1',
        );
        const s1Nced = Episode(
          id: 's1-nced',
          workId: 'w-s1',
          seasonNumber: 0,
          episodeNumber: 1,
          category: EpisodeCategory.extra,
          extraType: ExtraKind.nced,
          title: 'NCED1',
        );
        const s2Ep01 = Episode(
          id: 's2-ep01',
          workId: 'w-s2',
          seasonNumber: 2,
          episodeNumber: 1,
          category: EpisodeCategory.main,
          title: '新旅途启程',
        );
        const s2Nced = Episode(
          id: 's2-nced',
          workId: 'w-s2',
          seasonNumber: 0,
          episodeNumber: 1,
          category: EpisodeCategory.extra,
          extraType: ExtraKind.nced,
          title: 'S2 NCED1',
        );

        for (final ep in [s1Ep11, s1Ep12, s1Ncop, s1Nced, s2Ep01, s2Nced]) {
          await repo.upsertEpisode(ep);
        }

        const vS1Ep11 = MediaVariant(
          id: 'v-s1-11',
          workId: 'w-s1',
          episodeId: 's1-ep11',
          sourceId: 's1',
          relativePath: 'Frieren/S1/11.mkv',
          fileName: '11.mkv',
          fileSize: 1000,
        );
        const vS1Ep12 = MediaVariant(
          id: 'v-s1-12',
          workId: 'w-s1',
          episodeId: 's1-ep12',
          sourceId: 's1',
          relativePath: 'Frieren/S1/12.mkv',
          fileName: '12.mkv',
          fileSize: 1000,
        );
        const vS1Ncop = MediaVariant(
          id: 'v-s1-ncop',
          workId: 'w-s1',
          episodeId: 's1-ncop',
          sourceId: 's1',
          relativePath: 'Frieren/S1/NCOP1.mkv',
          fileName: 'NCOP1.mkv',
          fileSize: 400,
        );
        const vS1Nced = MediaVariant(
          id: 'v-s1-nced',
          workId: 'w-s1',
          episodeId: 's1-nced',
          sourceId: 's1',
          relativePath: 'Frieren/S1/NCED1.mkv',
          fileName: 'NCED1.mkv',
          fileSize: 400,
        );
        const vS2Ep01 = MediaVariant(
          id: 'v-s2-01',
          workId: 'w-s2',
          episodeId: 's2-ep01',
          sourceId: 's1',
          relativePath: 'Frieren/S2/01.mkv',
          fileName: '01.mkv',
          fileSize: 1200,
        );
        const vS2Nced = MediaVariant(
          id: 'v-s2-nced',
          workId: 'w-s2',
          episodeId: 's2-nced',
          sourceId: 's1',
          relativePath: 'Frieren/S2/NCED1.mkv',
          fileName: 'NCED1.mkv',
          fileSize: 400,
        );
        for (final v in [
          vS1Ep11,
          vS1Ep12,
          vS1Ncop,
          vS1Nced,
          vS2Ep01,
          vS2Nced,
        ]) {
          await repo.upsertMediaVariant(v);
        }

        const initialBundle = WorkDetailBundle(
          work: s1Work,
          episodes: [s1Ep11, s1Ep12, s1Ncop, s1Nced],
          variants: [vS1Ep11, vS1Ep12, vS1Ncop, vS1Nced],
          sourcesById: {
            's1': MediaSource(
              id: 's1',
              label: 'Local',
              kind: MediaSourceKind.local,
              location: r'D:\Anime',
            ),
          },
          latestPlayback: null,
          seriesMembers: [s1Work, s2Work],
        );

        const req = VideoLaunchRequest(
          work: s1Work,
          episode: s1Ep12,
          variant: vS1Ep12,
          bundle: initialBundle,
        );

        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        const d3d11Channel = MethodChannel('konata/d3d11_video');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(d3d11Channel, (call) async {
          switch (call.method) {
            case 'createSession':
              return <String, Object?>{
                'sessionId': 1,
                'textureId': 101,
                'backend': 'd3d11',
                'adapterName': 'Mock D3D11 GPU',
              };
            case 'resize':
            case 'disposeSession':
              return null;
          }
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(d3d11Channel, null);
        });

        final tempRoot = await tester.runAsync(
          () => Directory.systemTemp.createTemp('konata_stage3_test_'),
        );
        addTearDown(() async {
          if (tempRoot != null && tempRoot.existsSync()) {
            await tempRoot.delete(recursive: true);
          }
        });
        final testStorage = StorageRootService(overrideRoot: tempRoot);

        late _FakeVideoLibMpvClient fakeClient;
        late VideoPlaybackController controller;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              storageRootProvider.overrideWithValue(testStorage),
              videoPlaybackProvider(req).overrideWith((ref) {
                fakeClient = _FakeVideoLibMpvClient();
                controller = VideoPlaybackController(
                  ref,
                  req,
                  sessionFactory: () => EmbeddedMpvSession(
                    storageRoot: testStorage,
                    streamBridge: LocalStreamBridge(storageRoot: testStorage),
                    clientFactory: () => fakeClient,
                  ),
                );
                return controller;
              }),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: const EmbeddedVideoPage(request: req),
            ),
          ),
        );
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (controller.state.hasFirstFrame ||
              controller.state.errorMessage != null) {
            break;
          }
        }
        expect(controller.state.errorMessage, isNull);

        // 1. 打开选集侧栏，展示同系列切换栏与显式「正片」/「特典」双徽章
        controller.setSideSheetOpen(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        expect(find.byType(VideoSideSheet), findsOneWidget);
        expect(find.text('第 1 季 · 葬送的芙莉莲'), findsOneWidget);
        expect(find.text('第 2 季 · 葬送的芙莉莲'), findsOneWidget);
        expect(find.text('正片'), findsWidgets);
        expect(find.text('特典'), findsWidgets);

        final loadCountBeforeBrowse = fakeClient.commands
            .where((c) => c.first == 'loadfile')
            .length;
        expect(loadCountBeforeBrowse, 1);

        // 2. 在侧栏点击「第 2 季 · 葬送的芙莉莲」仅切换浏览，绝不中断当前 S1 播放！
        await tester.tap(find.text('第 2 季 · 葬送的芙莉莲'));
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          if (find.textContaining('新旅途启程').evaluate().isNotEmpty) break;
        }
        await tester.pump(const Duration(milliseconds: 250));

        final loadCountAfterBrowse = fakeClient.commands
            .where((c) => c.first == 'loadfile')
            .length;
        expect(loadCountAfterBrowse, 1);
        expect(controller.activeWork.id, 'w-s1');
        expect(controller.state.currentEpisode.id, 's1-ep12');
        // 浏览 S2 列表中绝不误亮 `s2-ep01`
        expect(find.textContaining('新旅途启程'), findsOneWidget);
        final activePlayIcons = tester.widgetList<Icon>(
          find.descendant(
            of: find.byType(VideoSideSheet),
            matching: find.byIcon(Icons.play_arrow_rounded),
          ),
        );
        // 仅季度条上留有一枚播放小标识，列表卡片内无误高亮
        expect(activePlayIcons.length, 1);

        controller.setSideSheetOpen(false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // 3. 模拟观看进度与 S1 末集正片完播：越过 S1 NCOP1/NCED1，直连 S2 第 01 集正片！
        fakeClient.emitEvent(
          const MpvPropertyChangeEvent(
            name: 'duration',
            replyUserdata: 202,
            format: MpvFormat.double_,
            doubleValue: 1440.0,
          ),
        );
        fakeClient.emitEvent(
          const MpvPropertyChangeEvent(
            name: 'time-pos',
            replyUserdata: 201,
            format: MpvFormat.double_,
            doubleValue: 1380.0,
          ),
        );
        await tester.pump();

        expect(controller.hasNextEpisodeAny, isTrue);
        final advanced = await tester.runAsync(
          () => controller.goToNextEpisode(isAutoAdvance: true),
        );
        expect(advanced, isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        // 验证 3a：先以旧 workId='w-s1' & episodeId='s1-ep12' 精准写入历史记录！
        final s1Records = await repo.getPlaybacksByWork('w-s1');
        expect(s1Records.length, 1);
        expect(s1Records.first.workId, 'w-s1');
        expect(s1Records.first.episodeId, 's1-ep12');
        expect(s1Records.first.positionSeconds, 1380);
        expect(s1Records.first.isCompleted, isTrue);

        // 验证 3b：热切更新为 S2 第 01 集正片，顶栏与描边 OSD 同步展示且仅再调用 1 次 loadfile
        expect(controller.activeWork.id, 'w-s2');
        expect(controller.state.currentEpisode.id, 's2-ep01');
        expect(
          fakeClient.commands.where((c) => c.first == 'loadfile').length,
          2,
        );
        expect(
          fakeClient.commands.last[1],
          contains(r'Frieren\S2\01.mkv'),
        );
        expect(
          find.ancestor(
            of: find.textContaining('已跨季连播').first,
            matching: find.byType(KonataOsdStrokedText),
          ),
          findsOneWidget,
        );

        // 4. 在最终季 S2 末集正片：hasNextEpisodeAny 为 false，绝不误跳入 S2 NCED1 特典
        expect(controller.hasNextEpisodeAny, isFalse);
        final finalNext = await tester.runAsync(
          () => controller.resolveNextEpisodeTarget(),
        );
        expect(finalNext, isNull);

        // 5. 在 S2 第 01 集对称点击「上一集」：回退至 S1 末集正片 s1-ep12
        expect(controller.hasPreviousEpisodeAny, isTrue);
        final rewound = await tester.runAsync(
          () => controller.goToPreviousEpisode(),
        );
        expect(rewound, isTrue);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.activeWork.id, 'w-s1');
        expect(controller.state.currentEpisode.id, 's1-ep12');

        // 6. 主动点播 S1 特典：仅在 S1 特典内顺序连播（NCOP1 -> NCED1 -> null，绝不跨入 S2）
        await tester.runAsync(() => controller.switchToEpisode(s1Ncop));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.state.currentEpisode.id, 's1-ncop');
        final nextExtra = await tester.runAsync(
          () => controller.resolveNextEpisodeTarget(),
        );
        expect(nextExtra, isNotNull);
        expect(nextExtra!.episode.id, 's1-nced');
        expect(nextExtra.isCrossSeason, isFalse);

        await tester.runAsync(() => controller.switchToEpisode(s1Nced));
        await tester.pump();
        expect(
          await tester.runAsync(() => controller.resolveNextEpisodeTarget()),
          isNull,
        );

        final closing = controller.closeAndRelease();
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await closing;
        await tester.pump(const Duration(milliseconds: 250));
        debugDefaultTargetPlatformOverride = null;
      },
    );
  });
}
