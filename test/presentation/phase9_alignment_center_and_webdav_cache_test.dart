import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/domain/formatting/media_display_formatter.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/cache/photos_storage.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/d3d11_video_bridge.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';
import 'package:ccplayer/presentation/audio/immersive_audio_page.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/detail/detail_hero_info.dart';
import 'package:ccplayer/presentation/detail/detail_secondary_filter_bar.dart';
import 'package:ccplayer/presentation/dialogs/source_files_review_dialog.dart';
import 'package:ccplayer/presentation/history/playback_history_page.dart';
import 'package:ccplayer/presentation/library/hidden_works_dialog.dart';
import 'package:ccplayer/presentation/library/library_page.dart';
import 'package:ccplayer/presentation/settings/settings_display_panel.dart';
import 'package:ccplayer/presentation/theme/konata_palette.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_dropdown.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_pill_button.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_soft_text_field.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_spec_badge.dart';

final Uint8List _sample1x1Png = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Widget _wrapPhase9App(
  Widget child, {
  Key? scopeKey,
  ThemeMode mode = ThemeMode.light,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    key: scopeKey,
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: mode,
      home: Scaffold(body: child),
    ),
  );
}

class _Phase9FakeD3D11VideoBridge implements D3D11VideoBridge {
  @override
  Stream<D3D11TextureChangedEvent> get textureChanges =>
      const Stream<D3D11TextureChangedEvent>.empty();

  @override
  Future<D3D11VideoSessionHandle> createSession({
    required int mpvHandleAddress,
    int width = 1280,
    int height = 720,
    bool preferSoftware = false,
  }) async {
    return const D3D11VideoSessionHandle(
      sessionId: 1,
      textureId: 1,
      backend: 'sw',
      adapterName: 'Test-SW',
    );
  }

  @override
  Future<void> resize({
    required int sessionId,
    required int width,
    required int height,
  }) async {}

  @override
  Future<void> disposeSession(int sessionId) async {}

  @override
  Future<({bool available, String adapterName})> getAdapterInfo() async =>
      (available: true, adapterName: 'Test-SW');

  @override
  Future<void> dispose() async {}
}

class _StubAudioNotifier extends AudioPlaybackNotifier {
  _StubAudioNotifier(super.ref, AudioPlaybackState initial) {
    state = initial;
  }

  @override
  Future<void> togglePlayPause() async {
    state = state.copyWith(isPlaying: !state.isPlaying);
  }
}

class _StubVideoController extends VideoPlaybackController {
  _StubVideoController(super.ref, super.request) : super(deferBootstrap: true) {
    state = state.copyWith(
      isInitializing: false,
      isBuffering: false,
      hasFirstFrame: true,
      isPlaying: true,
      positionSeconds: 7,
      durationSeconds: 1422,
      probeStats: const PlaybackProbeStats(
        videoWidth: 1920,
        videoHeight: 1080,
        videoCodec: 'hevc',
        videoPixelFormat: 'yuv420p10le',
        hwdecCurrent: 'd3d11va',
      ),
    );
  }
}

class _Phase9FakeMpvClient implements LibMpvClient {
  final Map<String, String> options = <String, String>{};
  final Map<String, String> stringProps = <String, String>{};
  final Map<String, bool> boolProps = <String, bool>{};
  final Map<String, int> intProps = <String, int>{};
  final Map<String, double> doubleProps = <String, double>{};
  final List<List<String>> commands = <List<String>>[];
  List<MpvSeekableRange> seekableRanges = const [];

  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  void emitEvent(MpvClientEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  bool isInitialized = true;
  @override
  bool isDisposed = false;
  @override
  int get handleAddress => 99;
  @override
  Stream<MpvClientEvent> get events => _events.stream;
  @override
  String errorString(int code) => 'err($code)';
  @override
  int setOptionString(String name, String value) {
    options[name] = value;
    return 0;
  }

  @override
  int initialize() {
    isInitialized = true;
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    stringProps[name] = value;
    return 0;
  }

  @override
  int setPropertyFlag(String name, bool value) {
    boolProps[name] = value;
    return 0;
  }

  @override
  int setPropertyInt64(String name, int value) {
    intProps[name] = value;
    return 0;
  }

  @override
  int setPropertyDouble(String name, double value) {
    doubleProps[name] = value;
    return 0;
  }

  @override
  String? getPropertyString(String name) => stringProps[name];
  @override
  bool? getPropertyFlag(String name) => boolProps[name];
  @override
  int? getPropertyInt64(String name) => intProps[name];
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
  List<MpvSeekableRange> readDemuxerSeekableRanges() => seekableRanges;
  @override
  int observeProperty(int replyUserdata, String name, int format) => 0;
  @override
  int requestLogMessages(String minLevel) => 0;
  @override
  int command(List<String> args) {
    commands.add(List<String>.from(args));
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Phase 1 · 查看源文件对齐、隐藏作品按需入口与 172px 居中下拉', () {
    testWidgets('SourceFilesReviewDialog 过滤栏同高 36px，源文件行 46px 单行垂直中心偏差 < 0.5px', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const source = MediaSource(
        id: 'dav1',
        kind: MediaSourceKind.webdav,
        label: 'dav (192.168.1.247)',
        location: 'http://192.168.1.247:5244/dav',
      );
      const work = Work(
        id: 'w_aw',
        title: 'Accel World EX',
        scrapeStatus: ScrapeStatus.needsReview,
      );
      const v1 = MediaVariant(
        id: 'v_ex1',
        workId: 'w_aw',
        sourceId: 'dav1',
        relativePath:
            '未添加TMDB ID/加速世界 TV+Movie/[VCB-Studio] Accel World [EX1][Ma10p_1080p][x265_flac].mkv',
        fileName: '[VCB-Studio] Accel World [EX1][Ma10p_1080p][x265_flac].mkv',
        fileSize: 1245540516,
        assetKind: AssetKind.video,
      );
      const v2 = MediaVariant(
        id: 'v_menu1',
        workId: 'w_aw',
        sourceId: 'dav1',
        relativePath:
            '未添加TMDB ID/加速世界 TV+Movie/SPs/[VCB-Studio] Accel World [MenuEX1][Hi444pp_1080p][x264_flac].mkv',
        fileName:
            '[VCB-Studio] Accel World [MenuEX1][Hi444pp_1080p][x264_flac].mkv',
        fileSize: 39111884,
        assetKind: AssetKind.video,
      );
      final item = WorkLibraryItem(
        work: work,
        episodeCount: 0,
        releaseGroups: const ['VCB-Studio'],
        variants: const [v1, v2],
      );

      await tester.pumpWidget(
        _wrapPhase9App(
          SourceFilesReviewDialog(item: item),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            mediaSourcesProvider.overrideWith((_) async => const [source]),
            workDetailBundleProvider(work.id).overrideWith(
              (_) async => const WorkDetailBundle(
                work: work,
                episodes: [],
                variants: [v1, v2],
                sourcesById: {'dav1': source},
                latestPlayback: null,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 废弃原生 Checkbox
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('SPs/'), findsOneWidget);

      // 过滤栏搜索框与「全选视频」胶囊严格同高 36px 且水平居中对齐
      final searchRect = tester.getRect(find.byType(KonataSoftTextField));
      final selectAllBtnFinder = find.ancestor(
        of: find.text('全选视频'),
        matching: find.byType(KonataPillButton),
      );
      final selectAllRect = tester.getRect(selectAllBtnFinder);
      expect(searchRect.height, closeTo(36.0, 0.5));
      expect(selectAllRect.height, closeTo(36.0, 0.5));
      expect(
        (searchRect.center.dy - selectAllRect.center.dy).abs(),
        lessThan(0.5),
      );

      // 每一行高度 46px，徽章/文件名/大小均与行垂直中心偏差 < 0.5px
      final badgeRect = tester.getRect(find.text('SPs/'));
      final fileNameRect = tester.getRect(find.text(v2.fileName));
      final sizeRect = tester.getRect(find.text('37.3 MB'));
      expect((badgeRect.center.dy - sizeRect.center.dy).abs(), lessThan(0.5));
      expect(
        (fileNameRect.center.dy - sizeRect.center.dy).abs(),
        lessThan(0.5),
      );
    });

    testWidgets(
      'LibraryPage 0 部隐藏作品时不占空间隐藏眼睛图标，HiddenWorksDialog 空态全宽居中无重复关闭键',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        SharedPreferences.setMockInitialValues({});
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);

        await tester.pumpWidget(
          _wrapPhase9App(
            const LibraryPage(),
            scopeKey: const ValueKey('phase9_lib_scope'),
            overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);

        // 直接验证 HiddenWorksDialog 空态兜底：无底部关闭按钮、宽 620px、提示文本水平正居中
        await tester.pumpWidget(
          _wrapPhase9App(
            const HiddenWorksDialog(),
            scopeKey: const ValueKey('phase9_hidden_dialog_scope'),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => Uint8List(0),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('关闭'), findsNothing);
        expect(find.text('当前没有隐藏任何作品'), findsOneWidget);
        final emptyTextRect = tester.getRect(find.text('当前没有隐藏任何作品'));
        expect((emptyTextRect.center.dx - 640.0).abs(), lessThan(1.0));
      },
    );

    testWidgets('设置「显示 → 标题显示」触发器与浮层同为 172px 并正中心对齐', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final tempDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_p9_disp_'),
      );
      addTearDown(() async {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final storageRoot = StorageRootService(overrideRoot: tempDir);
      final photos = PhotosStorage(storageRoot: storageRoot);
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await tester.pumpWidget(
        _wrapPhase9App(
          const SingleChildScrollView(child: SettingsDisplayPanel()),
          overrides: [
            storageRootProvider.overrideWithValue(storageRoot),
            photosStorageProvider.overrideWithValue(photos),
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final dropdownFinder = find.byWidgetPredicate(
        (w) => w is KonataMultiSelectDropdown,
      );
      expect(dropdownFinder, findsOneWidget);
      final triggerRect = tester.getRect(dropdownFinder);
      expect(triggerRect.width, closeTo(172.0, 0.5));

      await tester.tap(dropdownFinder);
      await tester.pumpAndSettle();

      final overlayOptionRect = tester.getRect(find.text('标题徽标').last);
      expect(
        (overlayOptionRect.center.dx - triggerRect.center.dx).abs(),
        lessThan(16.0),
      );
    });
  });

  group('Phase 2 · 详情页清空白色字影、日文标题规则与双主题色阶', () {
    test('lightDetailTextShadows 为空且中文主标题自动隐藏重复日文原名', () {
      expect(KonataTheme.lightDetailTextShadows, isEmpty);
      expect(
        MediaDisplayFormatter.shouldShowOriginalSubtitle(
          title: '加速世界',
          originalTitle: 'アクセル・ワールド',
        ),
        isFalse,
      );
      expect(
        MediaDisplayFormatter.shouldShowOriginalSubtitle(
          title: 'Accel World',
          originalTitle: 'アクセル・ワールド',
        ),
        isTrue,
      );
    });

    testWidgets('DetailHeroInfo 中文标题不渲染日文副标题，且二级筛选胶囊在浅色与深色模式下配色区分', (
      tester,
    ) async {
      const work = Work(
        id: 'w_aw_detail',
        title: '加速世界',
        originalTitle: 'アクセル・ワールド',
        year: 2012,
        bangumiScore: 6.7,
        overview: '近未来神经连结装置的虚拟加速世界。',
      );
      const bundle = WorkDetailBundle(
        work: work,
        episodes: [],
        variants: [],
        sourcesById: {},
        latestPlayback: null,
      );

      await tester.pumpWidget(
        _wrapPhase9App(
          DetailHeroInfo(
            bundle: bundle,
            imageLoader: (_, {targetWidth, imageSize}) async => Uint8List(0),
            onPrimaryPlay: () {},
          ),
          mode: ThemeMode.light,
        ),
      );
      await tester.pump();
      expect(find.text('加速世界'), findsOneWidget);
      expect(find.text('アクセル・ワールド'), findsNothing);

      expect(
        KonataPlaybackTokens.secondaryFilterPillBg(
          KonataPalette.light,
          selected: true,
          hovered: false,
        ),
        isNot(
          equals(
            KonataPlaybackTokens.secondaryFilterPillBg(
              KonataPalette.dark,
              selected: true,
              hovered: false,
            ),
          ),
        ),
      );
      expect(
        KonataPlaybackTokens.heroPlayButtonFill(
          KonataPalette.dark,
          enabled: true,
          hovered: false,
          pressed: false,
        ).computeLuminance(),
        lessThan(0.1),
      );

      await tester.pumpWidget(
        _wrapPhase9App(
          DetailSecondaryFilterBar(
            items: const [
              DetailSecondaryFilterItem(key: 'ncop', label: '无字幕片头', count: 3),
            ],
            totalCount: 30,
            selectedKey: null,
            onSelected: (_) {},
          ),
          mode: ThemeMode.dark,
        ),
      );
      await tester.pump();
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('无字幕片头'), findsOneWidget);
    });
  });

  group('Phase 3 · 三枚播控胶囊 50% 正中心校准 (<0.5px) 与纯图标循环键无文字', () {
    testWidgets('视频、迷你音频栏、全屏音频页三枚胶囊播放/暂停键中心偏差均 < 0.5px，循环键无 Text 子节点', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      const work = Work(id: 'w_cap', title: '加速世界');
      const ep = Episode(
        id: 'ep_1',
        workId: 'w_cap',
        seasonNumber: 1,
        episodeNumber: 1,
        title: '加速',
      );
      const vidVar = MediaVariant(
        id: 'mv_1',
        workId: 'w_cap',
        episodeId: 'ep_1',
        sourceId: 's1',
        relativePath: '01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
      );
      const vidBundle = WorkDetailBundle(
        work: work,
        episodes: [ep],
        variants: [vidVar],
        sourcesById: {},
        latestPlayback: null,
      );
      const vidReq = VideoLaunchRequest(
        work: work,
        episode: ep,
        variant: vidVar,
        bundle: vidBundle,
      );

      // 1. EmbeddedVideoPage 胶囊：居中 < 0.5px 且底栏无重复 1080p 规格标
      await tester.pumpWidget(
        _wrapPhase9App(
          const EmbeddedVideoPage(request: vidReq),
          scopeKey: const ValueKey('phase9_video_capsule_scope'),
          mode: ThemeMode.dark,
          overrides: [
            videoPlaybackProvider(
              vidReq,
            ).overrideWith((ref) => _StubVideoController(ref, vidReq)),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final videoCapsuleRect = tester.getRect(
        find.byType(KonataPlaybackCapsule),
      );
      final videoPlayRect = tester.getRect(
        find.byKey(const ValueKey('konata_capsule_play_pause_button')),
      );
      expect(
        (videoPlayRect.center.dx - videoCapsuleRect.center.dx).abs(),
        lessThan(0.5),
      );
      // 底栏胶囊内部不包含 1080p SpecBadge（仅顶栏存在 1080p）
      expect(
        find.descendant(
          of: find.byType(KonataPlaybackCapsule),
          matching: find.byType(KonataSpecBadge),
        ),
        findsNothing,
      );
      expect(find.text('1080p'), findsOneWidget);

      // 2. MiniAudioBar 胶囊：居中 < 0.5px + 纯图标 32x32 循环键无 Text 子节点
      const audioItem = AudioQueueItem(
        id: 'cd_1',
        work: work,
        variant: MediaVariant(
          id: 'va_1',
          workId: 'w_cap',
          sourceId: 's1',
          relativePath: 'CD/01.flac',
          fileName: '01.flac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        ),
        title: 'ハルユキの災難',
      );
      await tester.pumpWidget(
        _wrapPhase9App(
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              child: MiniAudioBar(),
            ),
          ),
          scopeKey: const ValueKey('phase9_mini_audio_scope'),
          mode: ThemeMode.dark,
          overrides: [
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _sample1x1Png,
            ),
            audioPlaybackProvider.overrideWith(
              (ref) => _StubAudioNotifier(
                ref,
                const AudioPlaybackState(
                  isActive: true,
                  isPlaying: true,
                  queue: [audioItem],
                  currentIndex: 0,
                  positionSeconds: 16,
                  durationSeconds: 1549,
                  loopMode: AudioLoopMode.loopAll,
                  audioCodecLabel: 'FLAC',
                  sampleRateAndBitDepthLabel: '16-bit · 44.1 kHz',
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final miniCapsuleRect = tester.getRect(
        find.byType(KonataPlaybackCapsule),
      );
      final miniPlayRect = tester.getRect(
        find.byKey(const ValueKey('konata_capsule_play_pause_button')),
      );
      expect(
        (miniPlayRect.center.dx - miniCapsuleRect.center.dx).abs(),
        lessThan(0.5),
      );
      final miniLoopBtn = find.byType(KonataAudioLoopButton);
      expect(miniLoopBtn, findsOneWidget);
      expect(tester.getSize(miniLoopBtn), equals(const Size(32, 32)));
      expect(
        find.descendant(of: miniLoopBtn, matching: find.byType(Text)),
        findsNothing,
      );

      // 3. ImmersiveAudioPage 胶囊：居中 < 0.5px + 纯图标循环键无 Text 子节点
      await tester.pumpWidget(
        _wrapPhase9App(
          const ImmersiveAudioPage(),
          scopeKey: const ValueKey('phase9_immersive_audio_scope'),
          mode: ThemeMode.dark,
          overrides: [
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _sample1x1Png,
            ),
            audioPlaybackProvider.overrideWith(
              (ref) => _StubAudioNotifier(
                ref,
                const AudioPlaybackState(
                  isActive: true,
                  isPlaying: false,
                  queue: [audioItem],
                  currentIndex: 0,
                  positionSeconds: 16,
                  durationSeconds: 1549,
                  loopMode: AudioLoopMode.loopOne,
                  audioCodecLabel: 'FLAC',
                  sampleRateAndBitDepthLabel: '16-bit · 44.1 kHz',
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final immCapsuleRect = tester.getRect(find.byType(KonataPlaybackCapsule));
      final immPlayRect = tester.getRect(
        find.byKey(const ValueKey('konata_capsule_play_pause_button')),
      );
      expect(
        (immPlayRect.center.dx - immCapsuleRect.center.dx).abs(),
        lessThan(0.5),
      );
      final immLoopBtn = find.byType(KonataAudioLoopButton);
      expect(immLoopBtn, findsOneWidget);
      expect(tester.getSize(immLoopBtn), equals(const Size(32, 32)));
      expect(
        find.descendant(of: immLoopBtn, matching: find.byType(Text)),
        findsNothing,
      );
    });
  });

  group('Phase 4 · 播放记录双页签、翻倍大封面、专辑封面优先与同行日期', () {
    testWidgets(
      '视频 112x160 / 音频 120x120 切换，音频优先读取专辑 Folder.jpg，日期固定在进度条同行最右侧',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        SharedPreferences.setMockInitialValues({});
        final tempAlbumDir = await tester.runAsync(
          () => Directory.systemTemp.createTemp('konata_p9_album_'),
        );
        addTearDown(() async {
          if (tempAlbumDir != null && await tempAlbumDir.exists()) {
            await tempAlbumDir.delete(recursive: true);
          }
        });
        await tester.runAsync(() async {
          final cdDir = Directory(p.join(tempAlbumDir!.path, 'AccelCD'))
            ..createSync(recursive: true);
          await File(
            p.join(cdDir.path, 'Folder.jpg'),
          ).writeAsBytes(_sample1x1Png);
          await File(p.join(cdDir.path, '01.flac')).writeAsBytes([1, 2, 3, 4]);
        });

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);

        await repo.upsertMediaSource(
          MediaSource(
            id: 'src_loc',
            kind: MediaSourceKind.local,
            label: 'Local',
            location: tempAlbumDir!.path,
          ),
        );
        await repo.upsertWork(
          const Work(
            id: 'w_p4',
            title: '加速世界',
            posterPath: '/poster.jpg',
            tmdbMediaType: TmdbMediaType.tv,
            scrapeStatus: ScrapeStatus.matched,
          ),
        );
        await repo.upsertMediaVariant(
          const MediaVariant(
            id: 'v_cd1',
            workId: 'w_p4',
            sourceId: 'src_loc',
            relativePath: 'AccelCD/01.flac',
            fileName: '01.flac',
            fileSize: 4,
            assetKind: AssetKind.cdAlbum,
          ),
        );
        await repo.recordPlayback(
          PlaybackRecord(
            id: 'rec_vid',
            workId: 'w_p4',
            episodeId: 'ep_1',
            variantId: 'v_vid1',
            seasonNumber: 1,
            episodeNumber: 1,
            episodeTitle: '加速',
            sourceType: MediaSourceKind.local,
            playedAt: DateTime(2026, 11, 16, 21, 58),
            positionSeconds: 7,
            durationSeconds: 1422,
          ),
        );
        await repo.recordPlayback(
          PlaybackRecord(
            id: 'cd::track_1',
            workId: 'w_p4',
            episodeId: 'cd::track_1',
            variantId: 'v_cd1',
            seasonNumber: 0,
            episodeNumber: 1,
            episodeTitle: 'ハルユキの災難',
            sourceType: MediaSourceKind.local,
            playedAt: DateTime(2026, 11, 16, 22, 12),
            positionSeconds: 665,
            durationSeconds: 1549,
          ),
        );

        await tester.pumpWidget(
          _wrapPhase9App(
            const PlaybackHistoryPage(),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _sample1x1Png,
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // 顶栏存在 视频 / 音频 双页签
        expect(find.text('视频'), findsOneWidget);
        expect(find.text('音频'), findsOneWidget);
        expect(find.text('标记为已看'), findsOneWidget);

        // 视频封面 112x160
        expect(
          tester
              .widgetList<SizedBox>(find.byType(SizedBox))
              .where((s) => s.width == 112 && s.height == 160),
          hasLength(1),
        );

        // 日期与进度条在同一水平行，日期位于进度条右侧
        final progressBarRect = tester.getRect(
          find.byType(LinearProgressIndicator),
        );
        final dateRect = tester.getRect(find.text('2026-11-16 21:58'));
        expect(
          (dateRect.center.dy - progressBarRect.center.dy).abs(),
          lessThan(4.0),
        );
        expect(dateRect.left, greaterThan(progressBarRect.right));

        // 切换至「音频」页签
        await tester.tap(find.text('音频'));
        await tester.pumpAndSettle();

        expect(find.text('标记为已听'), findsOneWidget);
        expect(find.text('ハルユキの災難'), findsOneWidget);
        expect(find.text('2026-11-16 22:12'), findsOneWidget);
        // 音频封面 120x120，且成功加载 Folder.jpg (Image.memory)
        expect(
          tester
              .widgetList<SizedBox>(find.byType(SizedBox))
              .where((s) => s.width == 120 && s.height == 120),
          hasLength(1),
        );
        expect(find.byType(Image), findsAtLeastNWidgets(1));
      },
    );
  });

  group('Phase 5 · WebDAV 单连接 Keep-Alive 冷启动与内存缓存零等待回跳', () {
    test('MpvQualityProfile 远程音视频冷启动与双向内存缓存参数齐全', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_p9_mpv_');
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final videoClient = _Phase9FakeMpvClient();
      MpvQualityProfile.applyPreInitVideoOptions(
        videoClient,
        config: const PlaybackQualityConfig(),
        mpvConfigDir: tempDir,
        isRemoteStream: true,
        isWindowsOverride: true,
        isAndroidOverride: false,
      );
      expect(videoClient.options['cache'], equals('yes'));
      expect(videoClient.options['cache-on-disk'], equals('no'));
      expect(
        videoClient.options['stream-lavf-o'],
        equals(
          'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2,multiple_requests=1',
        ),
      );
      expect(videoClient.options['demuxer-lavf-probesize'], equals('524288'));
      expect(
        videoClient.options['demuxer-lavf-analyzeduration'],
        equals('1.5'),
      );
      expect(videoClient.options['demuxer-max-bytes'], equals('180MiB'));
      expect(videoClient.options['demuxer-max-back-bytes'], equals('120MiB'));

      final audioClient = _Phase9FakeMpvClient();
      MpvQualityProfile.applyPreInitAudioOptions(
        audioClient,
        config: const PlaybackQualityConfig(),
        mpvConfigDir: tempDir,
        isRemoteStream: true,
        isWindowsOverride: true,
      );
      expect(audioClient.options['vid'], equals('no'));
      expect(audioClient.options['cover-art-auto'], equals('no'));
      expect(audioClient.options['cache'], equals('yes'));
      expect(audioClient.options['cache-on-disk'], equals('no'));
      expect(audioClient.options['prefetch-playlist'], equals('yes'));
      expect(
        audioClient.options['stream-lavf-o'],
        equals(
          'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2,multiple_requests=1',
        ),
      );
      expect(audioClient.options['demuxer-lavf-probesize'], equals('262144'));
      expect(
        audioClient.options['demuxer-lavf-analyzeduration'],
        equals('0.8'),
      );
      expect(audioClient.options['demuxer-max-bytes'], equals('64MiB'));
      expect(audioClient.options['demuxer-max-back-bytes'], equals('48MiB'));
    });

    test(
      'EmbeddedMpvSession 查询 seekable-ranges 命中 14:15 -> 11:00 抑制缓冲 Loading',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'konata_p9_sess_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final storageRoot = StorageRootService(overrideRoot: tempDir);
        final bridge = LocalStreamBridge(storageRoot: storageRoot);
        addTearDown(bridge.dispose);
        final fakeClient = _Phase9FakeMpvClient()
          ..seekableRanges = const [MpvSeekableRange(start: 510.0, end: 920.0)];

        final session = EmbeddedMpvSession(
          storageRoot: storageRoot,
          streamBridge: bridge,
          d3d11Bridge: _Phase9FakeD3D11VideoBridge(),
          clientFactory: () => fakeClient,
        );
        addTearDown(session.dispose);

        final bufferingEvents = <bool>[];
        session.onBufferingChanged = bufferingEvents.add;

        const variant = MediaVariant(
          id: 'v_s',
          workId: 'w_s',
          sourceId: 's_loc',
          relativePath: r'C:\nonexistent\01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
        );

        await session.initializeAndLoad(
          request: const EmbeddedVideoLoadRequest(
            workId: 'w_s',
            variant: variant,
          ),
          qualityConfig: const PlaybackQualityConfig(),
        );
        bufferingEvents.clear();

        // 11:00 = 660s，落在 08:30(510s) - 15:20(920s) 内存区间内 -> 瞬切且抑制转圈
        final hit = session.seekAbsolute(660.0);
        expect(hit, isTrue);
        expect(bufferingEvents, equals([false]));

        // 即便此时 core-idle 短暂报 true，依然抑制缓冲 Loading 遮罩
        fakeClient.emitEvent(
          const MpvPropertyChangeEvent(
            name: 'core-idle',
            replyUserdata: 204,
            format: MpvFormat.flag,
            boolValue: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(bufferingEvents.contains(true), isFalse);

        // 跳至未缓存的 20:00 = 1200s -> 返回 false（允许常规缓冲状态）
        final miss = session.seekAbsolute(1200.0);
        expect(miss, isFalse);
      },
    );
  });
}
