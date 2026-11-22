import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/playback/video_playback_controller.dart';
import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/scraping_providers.dart';
import 'package:konata/application/providers/theme_providers.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/network_config.dart';
import 'package:konata/domain/models/playback_record.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/cache/photos_storage.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/players/mpv_quality_profile.dart';
import 'package:konata/infrastructure/storage/storage_root_provider.dart';
import 'package:konata/presentation/audio/immersive_audio_page.dart';
import 'package:konata/presentation/audio/mini_audio_bar.dart';
import 'package:konata/presentation/detail/detail_hero_info.dart';
import 'package:konata/presentation/detail/inline_expandable_synopsis.dart';
import 'package:konata/presentation/history/playback_history_page.dart';
import 'package:konata/presentation/library/hidden_works_dialog.dart';
import 'package:konata/presentation/library/library_page.dart';
import 'package:konata/presentation/settings/photo_custom_cleanup_dialog.dart';
import 'package:konata/presentation/settings/settings_page.dart';
import 'package:konata/presentation/settings/settings_players_panel.dart';
import 'package:konata/presentation/theme/konata_palette.dart';
import 'package:konata/presentation/theme/konata_playback_tokens.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/video/video_side_sheet.dart';
import 'package:konata/presentation/widgets/design_system/konata_pill_button.dart';
import 'package:konata/presentation/widgets/design_system/konata_surface_card.dart';
import 'package:konata/presentation/widgets/managed_image.dart';
import 'package:konata/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:konata/presentation/widgets/playback/konata_volume_control.dart';

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

Widget _wrapStage8App(
  Widget child, {
  ThemeMode mode = ThemeMode.dark,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: Consumer(
      builder: (context, ref, _) {
        final effectiveMode = mode == ThemeMode.system
            ? ref.watch(themeModeProvider)
            : mode;
        return MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: KonataTheme.lightTheme(),
          darkTheme: KonataTheme.darkTheme(),
          themeMode: effectiveMode,
          home: Scaffold(body: child),
        );
      },
    ),
  );
}

class _StubAudioNotifier extends AudioPlaybackNotifier {
  _StubAudioNotifier(AudioPlaybackState initial) : super(initialState: initial);

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume.clamp(0.0, 100.0));
  }

  @override
  Future<void> toggleMute() async {
    state = state.copyWith(isMuted: !state.isMuted);
  }
}

class _FakeVideoController extends VideoPlaybackController {
  _FakeVideoController(super.request) : super(deferBootstrap: true);

  @override
  void setVolume(double volume) {
    state = state.copyWith(volume: volume.clamp(0.0, 100.0));
  }
}

VideoLaunchRequest _buildVideoRequest() {
  const work = Work(id: 'w_v1', title: '测试番剧');
  const ep = Episode(
    id: 'e1',
    workId: 'w_v1',
    category: EpisodeCategory.main,
    seasonNumber: 1,
    episodeNumber: 1,
    title: '第一话',
  );
  const variant = MediaVariant(
    id: 'v1',
    workId: 'w_v1',
    episodeId: 'e1',
    sourceId: 's1',
    relativePath: '01.mkv',
    fileName: '01.mkv',
    fileSize: 1024,
    assetKind: AssetKind.video,
  );
  const bundle = WorkDetailBundle(
    work: work,
    episodes: [ep],
    variants: [variant],
    sourcesById: {
      's1': MediaSource(
        id: 's1',
        kind: MediaSourceKind.local,
        label: 'Local',
        location: 'D:/Anime',
      ),
    },
    latestPlayback: null,
    playbackByEpisodeId: {},
  );
  return const VideoLaunchRequest(
    work: work,
    episode: ep,
    variant: variant,
    bundle: bundle,
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Phase 1 · 全站双主题一致性与就绪标签蓝底修正', () {
    testWidgets('播放器与浮层组件在浅色模式下响应 Light Brightness（无强制深色覆盖）', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      final req = _buildVideoRequest();

      const audioItem = AudioQueueItem(
        id: 'trk_1',
        work: Work(id: 'w_a1', title: '结束乐队'),
        variant: MediaVariant(
          id: 'va1',
          workId: 'w_a1',
          sourceId: 's1',
          relativePath: '01.flac',
          fileName: '01.flac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        ),
        title: '吉他与孤独与蓝色星球',
      );

      await tester.pumpWidget(
        _wrapStage8App(
          Stack(
            children: [
              ImmersiveAudioPage(key: UniqueKey()),
              Align(
                alignment: Alignment.centerRight,
                child: VideoSideSheet(
                  request: req,
                  initialTab: VideoSideSheetTab.episodes,
                  onClose: () {},
                ),
              ),
              const Align(
                alignment: Alignment.bottomRight,
                child: KonataFloatingMiniPlayer.standalone(
                  kind: FloatingMiniPlayerKind.audio,
                ),
              ),
            ],
          ),
          mode: ThemeMode.light,
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _sample1x1Png,
            ),
            videoPlaybackProvider(
              req,
            ).overrideWith(() => _FakeVideoController(req)),
            audioPlaybackProvider.overrideWith(
              () => _StubAudioNotifier(
                const AudioPlaybackState(
                  isActive: true,
                  isPlaying: true,
                  queue: [audioItem],
                  currentIndex: 0,
                  positionSeconds: 18,
                  durationSeconds: 180,
                  volume: 68.0,
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final sideSheetContext = tester.element(find.byType(VideoSideSheet));
      final audioPageContext = tester.element(find.byType(ImmersiveAudioPage));
      expect(Theme.of(sideSheetContext).brightness, Brightness.light);
      expect(Theme.of(audioPageContext).brightness, Brightness.light);
      expect(
        KonataPlaybackTokens.auroraCanvas(KonataPalette.light),
        isNot(equals(KonataPlaybackTokens.auroraCanvas(KonataPalette.dark))),
      );
    });

    testWidgets('SettingsPlayersPanel 移除内置核心与默认路由并保留核心画质卡片', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        _wrapStage8App(
          const SingleChildScrollView(child: SettingsPlayersPanel()),
          mode: ThemeMode.light,
          overrides: [
            mpvRuntimeVersionsProvider.overrideWith(
              (_) async => const MpvRuntimeVersions(
                isAvailable: true,
                mpvVersion: 'mpv 0.40.0',
                ffmpegVersion: 'n7.1',
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('内置核心与默认路由'), findsNothing);
      expect(find.text('mpv 0.40.0 · FFmpeg n7.1'), findsNothing);
      expect(find.text('视频渲染与看番体验'), findsOneWidget);
      expect(find.text('无损音频与着色器链路'), findsOneWidget);
    });
  });

  group('Phase 2 · 外观与显示拆分页、标题徽标四态、纯中文五分类与隐藏作品管理', () {
    testWidgets('Settings 拆分为「外观」与「显示」独立导航，显示页含「标题显示」多选与「显示作品简介」', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final tempDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_s8_set_'),
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
        _wrapStage8App(
          const SettingsPage(),
          mode: ThemeMode.system,
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

      expect(find.text('外观与显示'), findsNothing);
      expect(find.text('外观'), findsAtLeastNWidgets(1));
      expect(find.text('显示'), findsOneWidget);
      expect(find.text('已隐藏作品'), findsNothing);
      expect(find.text('详情页显示'), findsNothing);

      // 切换至「显示」面板
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();

      expect(find.text('详情页显示'), findsNothing);
      expect(find.text('详情页标题'), findsOneWidget);
      expect(find.text('作品简介'), findsOneWidget);
      expect(find.text('本地图片存储'), findsOneWidget);

      // 点击默认「标题徽标」多选触发器：勾选「文字标题」后浮层不收起
      await tester.tap(find.text('标题徽标').first);
      await tester.pumpAndSettle();
      expect(find.text('标题徽标'), findsNWidgets(3));
      expect(find.text('文字标题'), findsOneWidget);
      await tester.tap(find.text('文字标题').last);
      await tester.pumpAndSettle();
      // 多选浮层仍保持打开状态，触发器文案更新为双选组合
      expect(find.text('文字标题 · 标题徽标'), findsOneWidget);
      // 按 Esc 收起浮层
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });

    testWidgets('DetailHeroInfo 覆盖「标题显示」4 种组合及「显示作品简介」开关', (tester) async {
      const workWithLogo = Work(
        id: 'w_hero',
        title: '轻音少女',
        originalTitle: 'けいおん!',
        year: 2009,
        bangumiScore: 8.8,
        logoPath: '/logos/kon.png',
        overview: '四名少女在轻音部的日常故事。',
      );
      const workNoLogo = Work(
        id: 'w_nologo',
        title: '无徽标作品',
        year: 2024,
        overview: '简介文本',
      );
      const bundleWithLogo = WorkDetailBundle(
        work: workWithLogo,
        episodes: [],
        variants: [],
        sourcesById: {},
        latestPlayback: null,
        playbackByEpisodeId: {},
      );
      const bundleNoLogo = WorkDetailBundle(
        work: workNoLogo,
        episodes: [],
        variants: [],
        sourcesById: {},
        latestPlayback: null,
        playbackByEpisodeId: {},
      );

      Future<Uint8List> fakeLoader(
        String _, {
        int? targetWidth,
        TmdbImageSize? imageSize,
      }) async => _sample1x1Png;

      // 1. 仅勾选 文字标题（默认）
      await tester.pumpWidget(
        _wrapStage8App(
          DetailHeroInfo(
            bundle: bundleWithLogo,
            imageLoader: fakeLoader,
            onPrimaryPlay: () {},
            showTitleText: true,
            showTitleLogo: false,
            showOverview: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('轻音少女'), findsOneWidget);
      expect(find.byType(ManagedImage), findsNothing);
      expect(find.byType(InlineExpandableSynopsis), findsOneWidget);

      // 2. 仅勾选 标题徽标：有 Logo 时只展示透明徽标，不展示文字标题
      await tester.pumpWidget(
        _wrapStage8App(
          DetailHeroInfo(
            bundle: bundleWithLogo,
            imageLoader: fakeLoader,
            onPrimaryPlay: () {},
            showTitleText: false,
            showTitleLogo: true,
            showOverview: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ManagedImage), findsOneWidget);
      expect(find.text('轻音少女'), findsNothing);

      // 无 Logo 时回落显示文本标题
      await tester.pumpWidget(
        _wrapStage8App(
          DetailHeroInfo(
            bundle: bundleNoLogo,
            imageLoader: fakeLoader,
            onPrimaryPlay: () {},
            showTitleText: false,
            showTitleLogo: true,
            showOverview: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('无徽标作品'), findsOneWidget);

      // 3. 同时勾选：Logo 在上、文字标题在下
      await tester.pumpWidget(
        _wrapStage8App(
          DetailHeroInfo(
            bundle: bundleWithLogo,
            imageLoader: fakeLoader,
            onPrimaryPlay: () {},
            showTitleText: true,
            showTitleLogo: true,
            showOverview: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ManagedImage), findsOneWidget);
      expect(find.text('轻音少女'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(ManagedImage)).dy,
        lessThan(tester.getTopLeft(find.text('轻音少女')).dy),
      );

      // 4. 两者全取消 + 关闭作品简介：不留文本、Logo 或简介占位
      await tester.pumpWidget(
        _wrapStage8App(
          DetailHeroInfo(
            bundle: bundleWithLogo,
            imageLoader: fakeLoader,
            onPrimaryPlay: () {},
            showTitleText: false,
            showTitleLogo: false,
            showOverview: false,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ManagedImage), findsNothing);
      expect(find.text('轻音少女'), findsNothing);
      expect(find.byType(InlineExpandableSynopsis), findsNothing);
      expect(find.text('开始播放'), findsOneWidget);
    });

    testWidgets('PhotoCustomCleanupDialog 五类纯中文标签同一横排等宽对齐', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final tempDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('konata_s8_photo_'),
      );
      addTearDown(() async {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final storageRoot = StorageRootService(overrideRoot: tempDir);
      final storage = PhotosStorage(storageRoot: storageRoot);
      await tester.runAsync(
        () => storage.resolveRootDirectory().create(recursive: true),
      );

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await tester.pumpWidget(
        _wrapStage8App(
          const PhotoCustomCleanupDialog(),
          overrides: [
            storageRootProvider.overrideWithValue(storageRoot),
            photosStorageProvider.overrideWithValue(storage),
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => Uint8List(0),
            ),
          ],
        ),
      );
      await tester.pump();
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (find.text('清理所选').evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();

      const pureChineseLabels = ['封面海报', '背景原画', '标题徽标', '分集剧照', '扫图微缩图'];
      final topPositions = <double>[];
      for (final label in pureChineseLabels) {
        final f = find.text(label);
        expect(f, findsOneWidget);
        topPositions.add(tester.getTopLeft(f).dy);
      }
      // 同一横排：所有标签纵坐标一致
      for (final dy in topPositions) {
        expect((dy - topPositions.first).abs(), lessThanOrEqualTo(1.5));
      }
      // 禁止残余英文后缀或括号
      expect(find.textContaining('('), findsNothing);
      expect(find.textContaining('Scan 微缩图'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('媒体库页头无边框眼睛按钮呼出居中 HiddenWorksDialog 并支持取消隐藏', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_1',
          kind: MediaSourceKind.local,
          label: '番剧盘',
          location: 'D:/Anime',
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_hid',
          title: '隐藏测试作品',
          year: 2023,
          isHidden: true,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'mv_hid',
          workId: 'w_hid',
          sourceId: 'src_1',
          relativePath: 'HiddenAnime/01.mkv',
          fileName: '01.mkv',
          fileSize: 1024,
        ),
      );

      await tester.pumpWidget(
        _wrapStage8App(
          const LibraryPage(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => Uint8List(0),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final eyeBtn = find.byIcon(Icons.visibility_off_outlined);
      expect(eyeBtn, findsOneWidget);
      await tester.tap(eyeBtn);
      await tester.pumpAndSettle();

      expect(find.byType(HiddenWorksDialog), findsOneWidget);
      expect(find.text('已隐藏作品'), findsOneWidget);
      expect(find.text('隐藏测试作品 (2023)'), findsOneWidget);
      expect(find.text('[番剧盘] HiddenAnime'), findsOneWidget);

      await tester.tap(find.text('取消隐藏'));
      await tester.pumpAndSettle();

      // 取消隐藏至 0 部后自动关闭弹窗，且媒体库顶栏隐藏作品图标彻底收起
      expect(find.byType(HiddenWorksDialog), findsNothing);
      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
      final updatedWork = await repo.findWorkById('w_hid');
      expect(updatedWork?.isHidden, isFalse);
    });
  });

  group('Phase 3 · 极简音量无数字、视频播放居中对称与高可见底置进度条', () {
    testWidgets('KonataPlaybackCapsule 视频模式隐藏标题、宽屏居中对称且窄屏零溢出', (tester) async {
      // 1. 桌面宽屏 (1280x800)：Play/Pause 几何中心严格落在胶囊宽度 / 2
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _wrapStage8App(
          Center(
            child: SizedBox(
              width: 900,
              child: KonataPlaybackCapsule(
                title: null,
                positionSeconds: 18,
                durationSeconds: 1421,
                isPlaying: true,
                onTogglePlayPause: () {},
                onSeek: (_) {},
                onPrevious: () {},
                onNext: () {},
                onToggleList: () {},
                rightSlot: KonataVolumeControl(
                  volume: 100,
                  isMuted: false,
                  onVolumeChanged: (_) {},
                  onToggleMute: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('00:18 / 23:41'), findsOneWidget);
      expect(find.text('100'), findsNothing);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

      final capsuleBox = tester.getRect(find.byType(KonataPlaybackCapsule));
      final playBtnRect = tester.getRect(find.byIcon(Icons.pause_rounded));
      expect(
        (playBtnRect.center.dx - capsuleBox.center.dx).abs(),
        lessThanOrEqualTo(1.5),
      );

      // 验证顶沿发光细进度条倍增几何 Token 规范
      expect(KonataPlaybackTokens.capsuleProgressRestHeight, equals(2.5));
      expect(KonataPlaybackTokens.capsuleProgressHoverHeight, equals(5.0));
      expect(
        KonataPlaybackTokens.capsuleProgressHitHeight,
        greaterThanOrEqualTo(
          KonataPlaybackTokens.capsuleProgressHoverHeight + 8,
        ),
      );

      // 2. 窄窗降级 (800x600)：零溢出
      tester.view.physicalSize = const Size(800, 600);
      await tester.pumpWidget(
        _wrapStage8App(
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: KonataPlaybackCapsule(
                title: null,
                positionSeconds: 18,
                durationSeconds: 1421,
                isPlaying: false,
                onTogglePlayPause: () {},
                onSeek: (_) {},
                onPrevious: () {},
                onNext: () {},
                onToggleList: () {},
                rightSlot: KonataVolumeControl(
                  volume: 50,
                  isMuted: false,
                  onVolumeChanged: (_) {},
                  onToggleMute: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('Phase 4 · 播放记录双列等高网格与批量多选已看/清理', () {
    testWidgets('桌面端双列同行等高对齐、长标题折行展示，并支持「标记为已看」与「清理记录」批量操作', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const shortTitle = '短标题作品';
      const longTitle = '这是一个非常非常长需要在双列网格卡片内自动折行完整展示而不做单行省略的动画番剧标题第二季';

      await repo.upsertWork(
        const Work(
          id: 'w_h1',
          title: shortTitle,
          posterPath: '/p1.jpg',
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_h2',
          title: longTitle,
          posterPath: '/p2.jpg',
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );

      await repo.recordPlayback(
        PlaybackRecord(
          id: 'r_h1',
          workId: 'w_h1',
          episodeId: 'e_h1',
          variantId: 'v_h1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '起始之章',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 16, 18, 0),
          positionSeconds: 120,
          durationSeconds: 1440,
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'r_h2',
          workId: 'w_h2',
          episodeId: 'e_h2',
          variantId: 'v_h2',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '延长回',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 16, 17, 0),
          positionSeconds: 240,
          durationSeconds: 1440,
        ),
      );

      await tester.pumpWidget(
        _wrapStage8App(
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

      expect(tester.takeException(), isNull);
      // 移除单卡操作按钮与清空全部按钮
      expect(find.text('清空全部'), findsNothing);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsNothing);
      expect(find.text('标记为已看'), findsOneWidget);
      expect(find.text('清理记录'), findsOneWidget);
      expect(find.text('2026.11.16'), findsOneWidget);

      // 验证长标题最多两行省略截断
      final longTitleText = tester.widget<Text>(find.text(longTitle));
      expect(longTitleText.maxLines, equals(2));
      expect(longTitleText.overflow, equals(TextOverflow.ellipsis));

      // 验证同一日期时间轴下两张作品聚合卡垂直排列且左/右边缘齐平
      final cards = find.byType(KonataSurfaceCard);
      expect(cards, findsNWidgets(2));
      final topCardRect = tester.getRect(cards.at(0));
      final bottomCardRect = tester.getRect(cards.at(1));
      expect((topCardRect.left - bottomCardRect.left).abs(), lessThanOrEqualTo(1.0));
      expect((topCardRect.width - bottomCardRect.width).abs(), lessThanOrEqualTo(1.0));
      expect(bottomCardRect.top, greaterThan(topCardRect.bottom));

      // 批量「标记为已看」：选中第一张并二次确认
      await tester.tap(find.text('标记为已看'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(shortTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认标记'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确认将选中的 1 条播放记录'), findsOneWidget);
      // 点击弹窗内确认按钮
      await tester.tap(
        find
            .ancestor(
              of: find.text('确认标记'),
              matching: find.byType(KonataPillButton),
            )
            .last,
      );
      await tester.pumpAndSettle();

      // 点击卡片原地展开后可见「已看完」状态
      await tester.tap(find.text(shortTitle));
      await tester.pumpAndSettle();
      expect(find.text('已看完'), findsOneWidget);

      // 批量「清理记录」：全选 -> 确认清理 (danger) -> 清空完成
      await tester.tap(find.text('清理记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确认清理选中的 2 条播放记录'), findsOneWidget);
      await tester.tap(
        find
            .ancestor(
              of: find.text('确认清理'),
              matching: find.byType(KonataPillButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无播放记录'), findsOneWidget);

      // 验证窄屏 < 680px 单列降级不溢出
      tester.view.physicalSize = const Size(600, 800);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
