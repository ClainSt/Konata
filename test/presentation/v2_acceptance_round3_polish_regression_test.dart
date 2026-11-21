import 'dart:io';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/providers/source_actions_provider.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/cue_and_lrc_parser.dart';
import 'package:ccplayer/domain/playback/subtitle_and_audio_choices.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/domain/playback/video_aspect_mode.dart';
import 'package:ccplayer/infrastructure/players/android/android_video_surface_controller.dart';
import 'package:ccplayer/presentation/audio/immersive_audio_page.dart';
import 'package:ccplayer/presentation/audio/immersive_audio_sub_widgets.dart';
import 'package:ccplayer/presentation/audio/immersive_karaoke_sweep_text.dart';
import 'package:ccplayer/presentation/detail/detail_secondary_filter_bar.dart';
import 'package:ccplayer/presentation/dialogs/episode_slot_picker_popover.dart';
import 'package:ccplayer/presentation/dialogs/file_mapping_panel.dart';
import 'package:ccplayer/presentation/library/library_page.dart';
import 'package:ccplayer/presentation/library/review_dialog.dart';
import 'package:ccplayer/presentation/settings/settings_network_panel.dart';
import 'package:ccplayer/presentation/shell/adaptive_capsule_layout.dart';
import 'package:ccplayer/presentation/theme/konata_adaptive_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_draggable_scrollbar.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_pill_button.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_surface_card.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_floating_mini_player.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _StubAudioNotifier extends AudioPlaybackNotifier {
  _StubAudioNotifier(super.ref, AudioPlaybackState initial) {
    state = initial;
  }

  double? lastSeekTrackSeconds;

  @override
  Future<void> seekRelativeTrackSeconds(double seconds) async {
    lastSeekTrackSeconds = seconds;
    state = state.copyWith(positionSeconds: seconds);
  }
}

class _StubVideoController extends VideoPlaybackController {
  _StubVideoController(super.ref, super.req, VideoPlaybackState initial) {
    state = initial;
  }

  double? lastSeekSeconds;

  @override
  void seekAbsolute(double seconds) {
    lastSeekSeconds = seconds;
    state = state.copyWith(positionSeconds: seconds);
  }

  void setAspectModeForTest(VideoAspectMode mode) {
    state = state.copyWith(aspectMode: mode);
  }
}

VideoLaunchRequest _makeVideoRequest() {
  const work = Work(id: 'w_r3', title: '16bit的感动 ANOTHER LAYER');
  const ep = Episode(
    id: 'ep_r3_1',
    workId: 'w_r3',
    seasonNumber: 1,
    episodeNumber: 1,
    title: '我穿越了！？',
  );
  const variant = MediaVariant(
    id: 'var_r3_1',
    workId: 'w_r3',
    episodeId: 'ep_r3_1',
    sourceId: 'src_1',
    relativePath: '01.mkv',
    fileName: '01.mkv',
    fileSize: 1024,
  );
  const bundle = WorkDetailBundle(
    work: work,
    episodes: [ep],
    variants: [variant],
    playbackByEpisodeId: {},
    latestPlayback: null,
    sourcesById: {},
  );
  return const VideoLaunchRequest(
    work: work,
    episode: ep,
    variant: variant,
    bundle: bundle,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v2 第三轮视觉与播放核心缺陷 6 项验收回归', () {
    testWidgets('《65535》长间奏行按歌曲自身中位语速扫白，01:15 时已完整走完末字「です」', (
      tester,
    ) async {
      const sample65535 =
          '[01:00.95] 何が理由で何と思われど\n'
          '[01:03.91] 変わらないキミは特別です\n'
          '[01:06.97] 欲望そのままに世界を従えろ\n'
          '[01:10.62] ゲームだと思えば張り切れるのです\n'
          '[01:26.73] 推したって萌えたって同じ';
      final lrc = LrcParser.parseText(sample65535);
      final pace = lrc.estimatedSecondsPerChar;
      expect(pace, lessThan(0.28));
      expect(pace, greaterThanOrEqualTo(0.14));

      final line = lrc.lines[3];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlaybackProvider.overrideWith(
              (ref) => _StubAudioNotifier(
                ref,
                AudioPlaybackState(
                  isActive: true,
                  isPlaying: false,
                  positionSeconds: 75.0,
                  durationSeconds: 193.0,
                  lrcDocument: lrc,
                  activeLyricIndex: 3,
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: ImmersiveLyricLineLeaf(
                index: 3,
                line: line,
                nextLineStartSeconds: lrc.lines[4].startSeconds,
                estimatedSecondsPerChar: pace,
                compact: false,
                userScrolling: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final sweep = tester.widget<ImmersiveKaraokeSweepText>(
        find.byKey(const ValueKey('active_line_karaoke')),
      );
      // 70.62s 起唱、16 字 * ~0.23s ≈ 3.7s -> 75.0s（01:15）时已 100% 走完
      expect(sweep.progress.value, closeTo(1.0, 0.001));
    });

    testWidgets('全屏音视频底部胶囊进度条零缝贴边融合，顶沿上方无多余描边白线', (tester) async {
      expect(KonataPlaybackTokens.capsuleProgressTopInset, equals(0.0));

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: Center(
              child: KonataPlaybackCapsule(
                positionSeconds: 45,
                durationSeconds: 180,
                isPlaying: true,
                onTogglePlayPause: () {},
                onSeek: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final containers = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(KonataPlaybackCapsule),
          matching: find.byType(Container),
        ),
      );
      final hasOuterFullBorderOverlay = containers.any(
        (c) => c.foregroundDecoration != null,
      );
      expect(hasOuterFullBorderOverlay, isFalse);
    });

    testWidgets('Windows 视频悬浮小窗悬停后底部进度条支持点击与拖动跳转', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        SharedPreferences.setMockInitialValues({});
        final req = _makeVideoRequest();
        late _StubVideoController ctrl;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              videoPlaybackProvider(req).overrideWith((ref) {
                ctrl = _StubVideoController(
                  ref,
                  req,
                  VideoPlaybackState(
                    currentWork: req.work,
                    currentBundle: req.bundle,
                    currentEpisode: req.episode,
                    currentVariant: req.variant,
                    isPlaying: true,
                    hasFirstFrame: true,
                    positionSeconds: 30,
                    durationSeconds: 300,
                  ),
                );
                return ctrl;
              }),
              floatingMiniVisualStateProvider.overrideWith(
                (_) => FloatingMiniVisualState.collapsed,
              ),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              home: Scaffold(
                body: Center(
                  child: KonataFloatingMiniPlayer.standalone(
                    kind: FloatingMiniPlayerKind.video,
                    videoRequest: req,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final railFinder = find.byKey(
          const ValueKey('floating_mini_video_progress'),
        );
        expect(railFinder, findsOneWidget);
        final rect = tester.getRect(railFinder);

        // 点击底部进度条中点 -> 应提交约 150s 跳转
        await tester.tapAt(Offset(rect.center.dx, rect.bottom - 3));
        await tester.pump();
        expect(ctrl.lastSeekSeconds, isNotNull);
        expect(ctrl.lastSeekSeconds!, closeTo(150.0, 15.0));

        // 水平拖拽底部进度条至 75% 处 -> 应提交约 225s 跳转
        await tester.dragFrom(
          Offset(rect.left + rect.width * 0.25, rect.bottom - 3),
          Offset(rect.width * 0.50, 0),
        );
        await tester.pump();
        expect(ctrl.lastSeekSeconds!, closeTo(225.0, 20.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('字幕合并精准去重 memory:// 内存轨、不泄漏作品名作字幕组，且 Android 兜底落盘 subfont.ttf', () async {
      const chsPath =
          '/cache/[SweetSub&VCB-Studio] 16bit Sensation Another Layer [01][Ma10p_1080p][x265_flac].chs.ass';
      const chtPath =
          '/cache/[SweetSub&VCB-Studio] 16bit Sensation Another Layer [01][Ma10p_1080p][x265_flac].cht.ass';

      final merged = SubtitleAndAudioChoices.mergeSubtitles(
        mpvTracks: const [
          MpvTrackInfo(
            id: 1,
            type: MpvTrackType.subtitle,
            title:
                '[SweetSub&VCB-Studio] 16bit Sensation Another Layer [01][Ma10p_1080p][x265_flac].chs.ass',
            codec: 'ass',
            isExternal: true,
            externalFilename: 'memory://[Script Info]\nTitle: Test/Line',
            selected: true,
          ),
          MpvTrackInfo(
            id: 2,
            type: MpvTrackType.subtitle,
            title:
                '[SweetSub&VCB-Studio] 16bit Sensation Another Layer [01][Ma10p_1080p][x265_flac].cht.ass',
            codec: 'ass',
            isExternal: true,
            externalFilename: 'memory://[Script Info]\nTitle: Test/Line2',
            selected: false,
          ),
        ],
        discoveredExternalPaths: const [chsPath, chtPath],
        mountedSourcePathsByTrackId: const {1: chsPath, 2: chtPath},
      );

      // 严格去重为 2 条而非 4 条，且主标题仅保留语言 + 字幕组
      expect(merged, hasLength(2));
      expect(merged[0].primaryTitle, equals('简体中文 · SweetSub&VCB-Studio'));
      expect(merged[1].primaryTitle, equals('繁体中文 · SweetSub&VCB-Studio'));
      expect(merged[0].primaryTitle, isNot(contains('16bit')));
      expect(merged[0].primaryTitle, isNot(contains('1080p')));
      expect(merged[0].selected, isTrue);

      // Android 无系统可读字体时必须自动落盘 <mpvDir>/subfont.ttf 作为 libass 默认字体
      final tmpDir = await Directory.systemTemp.createTemp('konata_subfont_');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });
      final fakeFontBytes = Uint8List(2048)
        ..[0] = 0x00
        ..[1] = 0x01
        ..[2] = 0x00
        ..[3] = 0x00;

      await AndroidVideoSurfaceController.preparePortableCjkFontSymlinks(
        tmpDir,
        isAndroidOverride: true,
        systemFontRootsOverride: const [],
        assetLoaderOverride: (_) async => ByteData.sublistView(fakeFontBytes),
      );
      final subfont = File(p.join(tmpDir.path, 'subfont.ttf'));
      expect(await subfont.exists(), isTrue);
      expect(await subfont.length(), equals(2048));
    });

    testWidgets('Android 裁切铺满模式解除挖孔对称黑边约束，全屏边到边铺满', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1.0;
      tester.view.viewPadding = const FakeViewPadding(
        left: 44,
        top: 0,
        right: 0,
        bottom: 0,
      );
      addTearDown(tester.view.reset);
      try {
        SharedPreferences.setMockInitialValues({});
        final req = _makeVideoRequest();
        late _StubVideoController ctrl;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              videoPlaybackProvider(req).overrideWith((ref) {
                ctrl = _StubVideoController(
                  ref,
                  req,
                  VideoPlaybackState(
                    currentWork: req.work,
                    currentBundle: req.bundle,
                    currentEpisode: req.episode,
                    currentVariant: req.variant,
                    isPlaying: true,
                    hasFirstFrame: true,
                    durationSeconds: 1440,
                    aspectMode: VideoAspectMode.auto,
                  ),
                );
                return ctrl;
              }),
            ],
            child: MaterialApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: KonataTheme.darkTheme(),
              home: EmbeddedVideoPage(
                request: req,
                sharedVideoSurface: const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.pump();

        // 自适应模式下保留左右对称挖孔黑边
        final autoPadding = tester.widget<Padding>(
          find.byKey(const ValueKey('video_symmetric_cutout_frame')),
        );
        expect(autoPadding.padding.horizontal, greaterThan(0.0));

        // 切换为「裁切铺满」后黑边归零，画面全幅边到边铺满
        ctrl.setAspectModeForTest(VideoAspectMode.cover);
        await tester.pump();
        final coverPadding = tester.widget<Padding>(
          find.byKey(const ValueKey('video_symmetric_cutout_frame')),
        );
        expect(coverPadding.padding, equals(EdgeInsets.zero));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 4));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('文件映射面板：按目录全选与搜索框等宽等高，且每行仅展示多选框 + 原名 + 归属下拉（特典保留 PV01）', (
      tester,
    ) async {
      final selected = <String>{};
      final rows = [
        EditableFileMappingRow(
          variant: const MediaVariant(
            id: 'v_main',
            workId: 'w_1',
            episodeId: 'ep_1',
            sourceId: 's_1',
            relativePath: 'Main/Ep01.mkv',
            fileName: '[SweetSub] 16bit Sensation [01].mkv',
            fileSize: 1000,
          ),
          category: EpisodeCategory.main,
          seasonNumber: 1,
          episodeNumber: 1,
          extraType: ExtraKind.sp,
        ),
        EditableFileMappingRow(
          variant: const MediaVariant(
            id: 'v_pv',
            workId: 'w_1',
            episodeId: 'ep_pv1',
            sourceId: 's_1',
            relativePath: 'SPs/PV01.mkv',
            fileName: '[SweetSub] 16bit Sensation [PV01].mkv',
            fileSize: 500,
          ),
          category: EpisodeCategory.extra,
          seasonNumber: 0,
          episodeNumber: 0,
          extraType: ExtraKind.pv,
          recognizedExtraLabel: 'PV01',
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.lightTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 760,
              height: 520,
              child: FileMappingPanel(
                rows: rows,
                referenceEpisodes: const [
                  Episode(
                    id: 'ep_1',
                    workId: 'w_1',
                    seasonNumber: 1,
                    episodeNumber: 1,
                    title: '我穿越了！？',
                  ),
                ],
                defaultMainSeason: 1,
                selectedVariantIds: selected,
                saving: false,
                hasAnyMappingLock: false,
                onChanged: () {},
                onResetMappings: () {},
                onSplitSelected: () {},
                onMoveSelectedToWork: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 搜索框与「按目录全选」严格等宽等高
      final searchSize = tester.getSize(
        find.byKey(const ValueKey('file_mapping_search_field')),
      );
      final folderSize = tester.getSize(
        find.byKey(const ValueKey('file_mapping_folder_dropdown')),
      );
      expect((searchSize.width - folderSize.width).abs(), lessThanOrEqualTo(1.0));
      expect(
        (searchSize.height - folderSize.height).abs(),
        lessThanOrEqualTo(1.0),
      );

      // 正片行展示「正片 · 第 01 集」，特典行保留识别结果「PV01」而不强行标 S00E01
      expect(find.text('正片 · 第 01 集'), findsOneWidget);
      expect(find.text('PV01'), findsOneWidget);
      expect(find.textContaining('S00E01'), findsNothing);
    });

    testWidgets('Android 手机横屏二级筛选栏在存在左侧刘海时严格左对齐，不二次叠缩进', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(
        left: 44,
        top: 0,
        right: 0,
        bottom: 0,
      );
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: DetailSecondaryFilterBar(
                  items: const [
                    DetailSecondaryFilterItem(
                      key: 'nced',
                      label: '无字幕片尾',
                      count: 2,
                    ),
                    DetailSecondaryFilterItem(
                      key: 'pv',
                      label: '预告宣传',
                      count: 3,
                    ),
                  ],
                  totalCount: 5,
                  selectedKey: null,
                  horizontalPadding: 16,
                  compact: true,
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final allLeft = tester.getTopLeft(find.text('全部')).dx;
        // 若 ListView 二次消费了 44dp 左侧刘海，dx 会落到 > 68；归零后应贴近 16 + 胶囊内边距
        expect(allLeft, lessThan(40.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('全屏音乐竖屏去胶囊与黑框按钮、三端歌词无滚动条且支持网易云式时间轴定位与 3 秒自动回弹', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      try {
        const sampleLrc =
            '[00:05.00] 第一句测试歌词\n'
            '[00:15.00] 第二句测试歌词\n'
            '[00:25.00] 第三句测试歌词\n'
            '[00:35.00] 第四句测试歌词\n'
            '[00:45.00] 第五句测试歌词\n'
            '[00:55.00] 第六句测试歌词\n'
            '[01:05.00] 第七句测试歌词\n'
            '[01:15.00] 第八句测试歌词\n'
            '[01:25.00] 第九句测试歌词\n'
            '[01:35.00] 第十句测试歌词';
        final lrc = LrcParser.parseText(sampleLrc);
        const work = Work(id: 'w_lrc', title: '16bit的感动');
        const variant = MediaVariant(
          id: 'v_lrc',
          workId: 'w_lrc',
          sourceId: 's_1',
          relativePath: '01.flac',
          fileName: '01.flac',
          fileSize: 1024,
        );
        const queueItem = AudioQueueItem(
          id: 'q_1',
          work: work,
          variant: variant,
          title: '65535',
        );
        late _StubAudioNotifier audioNotifier;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackPreferencesProvider.overrideWith(
                (_) => PlaybackPreferencesNotifier(enablePersistence: false),
              ),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => Uint8List(0),
              ),
              audioPlaybackProvider.overrideWith((ref) {
                audioNotifier = _StubAudioNotifier(
                  ref,
                  AudioPlaybackState(
                    isActive: true,
                    isPlaying: true,
                    queue: const [queueItem],
                    currentIndex: 0,
                    positionSeconds: 8.0,
                    durationSeconds: 180.0,
                    lrcDocument: lrc,
                    activeLyricIndex: 0,
                    audioCodecLabel: 'FLAC',
                  ),
                );
                return audioNotifier;
              }),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const ImmersiveAudioPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 竖屏已去掉底部播控外层胶囊，五键平铺
        expect(
          find.byKey(const ValueKey('portrait_audio_transport_pill')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('portrait_audio_play_pause')),
          findsOneWidget,
        );

        // 点击封面切入歌词，无右上返回封面按钮且歌词无滚动条
        await tester.tap(find.byKey(const ValueKey('portrait_cover_stage')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('portrait_back_to_cover')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('portrait_lyrics_stage')),
            matching: find.byType(KonataDraggableScrollbar),
          ),
          findsNothing,
        );

        // 上下拖动歌词应唤出中央时间轴（左时间 + 右小播放键），且当前句扫白组件持续保留
        await tester.drag(
          find.byKey(const ValueKey('immersive_lyrics_list')),
          const Offset(0, -180),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('lyric_timeline_scrub_guide')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('lyric_timeline_scrub_timestamp')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('lyric_timeline_dashed_line')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('lyric_timeline_seek_play_button')),
          findsOneWidget,
        );
        expect(find.byType(ImmersiveKaraokeSweepText), findsOneWidget);

        // 松手停顿后点击右侧小播放键应执行跳转并隐藏时间轴
        await tester.pump(const Duration(milliseconds: 220));
        await tester.tap(
          find.byKey(const ValueKey('lyric_timeline_seek_play_button')),
        );
        await tester.pump();
        expect(audioNotifier.lastSeekTrackSeconds, isNotNull);
        expect(
          find.byKey(const ValueKey('lyric_timeline_scrub_guide')),
          findsNothing,
        );

        // 再次拖动后静置满 3 秒应自动回弹隐藏时间轴
        await tester.drag(
          find.byKey(const ValueKey('immersive_lyrics_list')),
          const Offset(0, -140),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('lyric_timeline_scrub_guide')),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(
          find.byKey(const ValueKey('lyric_timeline_scrub_guide')),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(
          find.byKey(const ValueKey('lyric_timeline_scrub_guide')),
          findsNothing,
        );

        // 正常快速单击歌词区域应切回封面
        await tester.tap(find.byKey(const ValueKey('portrait_lyrics_stage')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('portrait_cover_stage')),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'Android 手机竖屏在曲目中段反复快速点击切换封面与歌词：零 GlobalKey/ScrollController 冲突且自动精准居中聚焦当前句',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        try {
          final lrcBuf = StringBuffer();
          for (var i = 0; i < 36; i++) {
            final sec = 5 + i * 4;
            final mm = (sec ~/ 60).toString().padLeft(2, '0');
            final ss = (sec % 60).toString().padLeft(2, '0');
            lrcBuf.writeln('[$mm:$ss.00] 第${i + 1}句长歌词测试内容与伴奏对齐');
          }
          final lrc = LrcParser.parseText(lrcBuf.toString());
          const work = Work(id: 'w_lrc_rapid', title: '16bit的感动');
          const variant = MediaVariant(
            id: 'v_lrc_rapid',
            workId: 'w_lrc_rapid',
            sourceId: 's_1',
            relativePath: '01.flac',
            fileName: '01.flac',
            fileSize: 1024,
          );
          const queueItem = AudioQueueItem(
            id: 'q_rapid',
            work: work,
            variant: variant,
            title: '65535',
          );

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playbackPreferencesProvider.overrideWith(
                  (_) => PlaybackPreferencesNotifier(enablePersistence: false),
                ),
                tmdbImageLoaderProvider.overrideWithValue(
                  (_, {targetWidth, imageSize}) async => Uint8List(0),
                ),
                audioPlaybackProvider.overrideWith(
                  (ref) => _StubAudioNotifier(
                    ref,
                    AudioPlaybackState(
                      isActive: true,
                      isPlaying: true,
                      queue: const [queueItem],
                      currentIndex: 0,
                      positionSeconds: 81.0,
                      durationSeconds: 193.0,
                      lrcDocument: lrc,
                      activeLyricIndex: 19,
                      audioCodecLabel: 'FLAC',
                    ),
                  ),
                ),
              ],
              child: MaterialApp(
                theme: KonataTheme.lightTheme(),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                home: const ImmersiveAudioPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // 连续 9 次以 40ms 间隔高速反复点击切换封面 <-> 歌词（远短于 140ms 淡入淡出期），最终停留在歌词态
          for (var round = 0; round < 9; round++) {
            final showingCover = round.isEven;
            final target = showingCover
                ? find.byKey(const ValueKey('portrait_cover_stage')).last
                : find.byKey(const ValueKey('portrait_lyrics_stage')).last;
            await tester.tap(target);
            await tester.pump(const Duration(milliseconds: 40));
            expect(tester.takeException(), isNull);
          }

          // 推进动画与多轮像素精校帧至稳态
          await tester.pump(const Duration(milliseconds: 220));
          await tester.pump();
          await tester.pump();
          expect(tester.takeException(), isNull);

          final lyricsStage = find.byKey(
            const ValueKey('portrait_lyrics_stage'),
          );
          expect(lyricsStage, findsOneWidget);

          // 当前第 20 句（索引 19）必须已精准滚动入视口并处于清晰扫白激活态，绝不滞留顶部模糊态
          final listView = tester.widget<ListView>(
            find.byKey(const ValueKey('immersive_lyrics_list')),
          );
          expect(listView.controller!.offset, greaterThan(200.0));
          final activeSweep = find.byType(ImmersiveKaraokeSweepText);
          expect(activeSweep, findsOneWidget);

          final stageRect = tester.getRect(lyricsStage);
          final activeRect = tester.getRect(activeSweep);
          final expectedAnchorY =
              stageRect.top +
              stageRect.height * KonataPlaybackTokens.lyricViewportAnchorRatio;
          expect(
            (activeRect.center.dy - expectedAnchorY).abs(),
            lessThan(32.0),
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('Android 视频悬浮小窗无多余进度条且平板左侧导航胶囊离边并加宽', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        // 1. 平板左侧导航胶囊离边 >= tabletNavEdgeGap 且大于手机胶囊
        final phoneLayout = AdaptiveCapsuleLayout(
          size: const Size(390, 844),
          safe: EdgeInsets.zero,
          android: true,
        );
        final tabletLayout = AdaptiveCapsuleLayout(
          size: const Size(1280, 800),
          safe: EdgeInsets.zero,
          android: true,
        );
        expect(
          tabletLayout.navigationRect.left,
          equals(KonataAdaptiveTokens.tabletNavEdgeGap),
        );
        expect(
          tabletLayout.navigationThickness,
          greaterThan(phoneLayout.navigationThickness),
        );
        expect(
          tabletLayout.navigationLength,
          greaterThan(phoneLayout.navigationLength),
        );

        // 2. Android 视频悬浮小窗不挂载底部凸出进度条
        SharedPreferences.setMockInitialValues({});
        final req = _makeVideoRequest();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              videoPlaybackProvider(req).overrideWith(
                (ref) => _StubVideoController(
                  ref,
                  req,
                  VideoPlaybackState(
                    currentWork: req.work,
                    currentBundle: req.bundle,
                    currentEpisode: req.episode,
                    currentVariant: req.variant,
                    isPlaying: true,
                    hasFirstFrame: true,
                    positionSeconds: 30,
                    durationSeconds: 300,
                  ),
                ),
              ),
              floatingMiniVisualStateProvider.overrideWith(
                (_) => FloatingMiniVisualState.collapsed,
              ),
            ],
            child: MaterialApp(
              theme: KonataTheme.lightTheme(),
              home: Scaffold(
                body: Center(
                  child: KonataFloatingMiniPlayer.standalone(
                    kind: FloatingMiniPlayerKind.video,
                    videoRequest: req,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('floating_mini_video_progress')),
          findsNothing,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('待复核弹窗展开候选时窗口高度稳定不跳高且平滑过渡', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const work = Work(
        id: 'w_rev_1',
        title: 'Accel World EX',
        scrapeStatus: ScrapeStatus.needsReview,
        reviewReason: '标题相似度置信度不足，请从候选中选择准确作品',
      );
      const item = WorkLibraryItem(
        work: work,
        episodeCount: 0,
        releaseGroups: [],
        variants: [
          MediaVariant(
            id: 'v_rev_1',
            workId: 'w_rev_1',
            sourceId: 's_1',
            relativePath: 'Accel World EX/01.mkv',
            fileName: '01.mkv',
            fileSize: 1024,
          ),
        ],
      );
      const candidates = [
        ScrapeCandidateSummary(
          workId: 'w_rev_1',
          rank: 1,
          tmdbId: 43167,
          mediaType: TmdbMediaType.tv,
          title: '加速世界',
          year: 2012,
          episodeCount: 24,
          score: 67,
          reasons: ['title_high'],
        ),
        ScrapeCandidateSummary(
          workId: 'w_rev_1',
          rank: 2,
          tmdbId: 321652,
          mediaType: TmdbMediaType.tv,
          title: '加速世界 OVA',
          year: 2012,
          episodeCount: 1,
          score: 34,
          reasons: ['title_high'],
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            needsReviewItemsProvider.overrideWithValue(
              const AsyncValue.data([item]),
            ),
            workScrapeCandidatesProvider('w_rev_1').overrideWith(
              (_) async => candidates,
            ),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => Uint8List(0),
            ),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(body: Center(child: ReviewDialog())),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bodyFinder = find.byKey(const ValueKey('review_dialog_stable_body'));
      final beforeRect = tester.getRect(bodyFinder);
      final toggleFinder = find.text('展开候选 (2)');
      expect(toggleFinder, findsOneWidget);
      final btnTopBefore = tester.getTopLeft(toggleFinder).dy;

      await tester.tap(toggleFinder);
      await tester.pumpAndSettle();

      final afterRect = tester.getRect(bodyFinder);
      final btnTopAfter = tester.getTopLeft(find.text('收起候选')).dy;
      expect(afterRect.height, closeTo(beforeRect.height, 0.5));
      expect(afterRect.top, closeTo(beforeRect.top, 0.5));
      expect(btnTopAfter, closeTo(btnTopBefore, 1.0));
      expect(find.text('加速世界'), findsOneWidget);
    });

    testWidgets(
      'Android 平板双栏与手机竖屏执行图片服务器连接测试时按钮文案严禁溢出胶囊或压住状态文案',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(tester.view.reset);

        try {
          Future<void> verifyAtViewport(Size size) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;

            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  tmdbNetworkConfigProvider.overrideWith(
                    (_) async => const TmdbNetworkConfig(),
                  ),
                  konataActionsProvider.overrideWith(
                    (ref) => _StubNetworkProbeActions(ref),
                  ),
                ],
                child: MaterialApp(
                  theme: KonataTheme.lightTheme(),
                  home: const Scaffold(
                    body: SingleChildScrollView(
                      padding: EdgeInsets.all(16),
                      child: SettingsNetworkPanel(),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();

            final imageTestButtons = find.text('图片服务器连接测试');
            expect(imageTestButtons, findsNWidgets(2));
            for (var i = 0; i < 2; i++) {
              await tester.ensureVisible(imageTestButtons.at(i));
              await tester.tap(imageTestButtons.at(i));
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull);

            final tmdbStatus = find.text('官方不可达，已自动回退备用地址连通 (699ms)');
            final bgmStatus = find.text('官方不可达，备用地址返回 HTTP 404');
            expect(tmdbStatus, findsOneWidget);
            expect(bgmStatus, findsOneWidget);

            final statusFinders = [tmdbStatus, bgmStatus];
            for (var i = 0; i < 2; i++) {
              final labelFinder = imageTestButtons.at(i);
              final pillFinder = find
                  .ancestor(
                    of: labelFinder,
                    matching: find.byType(KonataPillButton),
                  )
                  .first;
              final cardFinder = find
                  .ancestor(
                    of: pillFinder,
                    matching: find.byType(KonataSurfaceCard),
                  )
                  .first;
              final labelRect = tester.getRect(labelFinder);
              final pillRect = tester.getRect(pillFinder);
              final cardRect = tester.getRect(cardFinder);
              final statusRect = tester.getRect(statusFinders[i]);

              // 按钮文字必须完整收容在胶囊内部，严禁越过胶囊右边界。
              expect(labelRect.left, greaterThanOrEqualTo(pillRect.left));
              expect(labelRect.right, lessThanOrEqualTo(pillRect.right + 0.5));
              // 按钮与连通性诊断状态文本严禁互相重叠，且全部收敛在卡片右边界内。
              expect(pillRect.overlaps(statusRect), isFalse);
              expect(pillRect.right, lessThanOrEqualTo(cardRect.right + 0.5));
              expect(statusRect.right, lessThanOrEqualTo(cardRect.right + 0.5));
            }
          }

          // 平板双栏临界宽度（内容区约 768dp，左右卡片各约 376dp）与手机竖屏（360dp）均须零出框。
          await verifyAtViewport(const Size(800, 900));
          await verifyAtViewport(const Size(360, 900));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      '媒体库空状态在桌面、Android 平板与手机三端均采用无外框居中布局，与媒体源和播放记录视觉一致',
      (tester) async {
        addTearDown(tester.view.reset);

        Future<void> verifyFramelessEmptyState(
          TargetPlatform platform,
          Size viewport,
        ) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
            tester.view.physicalSize = viewport;
            tester.view.devicePixelRatio = 1.0;

            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  filteredLibraryItemsProvider.overrideWithValue(
                    const AsyncValue.data([]),
                  ),
                  worksCountProvider.overrideWith((_) async => 0),
                  hiddenWorksProvider.overrideWith((_) async => const []),
                  needsReviewItemsProvider.overrideWithValue(
                    const AsyncValue.data([]),
                  ),
                ],
                child: MaterialApp(
                  theme: KonataTheme.darkTheme(),
                  home: const Scaffold(body: LibraryPage()),
                ),
              ),
            );
            await tester.pumpAndSettle();

            final emptyTitle = find.text('媒体库尚未入库任何作品');
            expect(emptyTitle, findsOneWidget);
            expect(find.text('前往添加媒体源'), findsOneWidget);
            // 空态提示外层严禁包裹带边框的 KonataSurfaceCard 方框。
            expect(
              find.ancestor(
                of: emptyTitle,
                matching: find.byType(KonataSurfaceCard),
              ),
              findsNothing,
            );
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }

        await verifyFramelessEmptyState(
          TargetPlatform.windows,
          const Size(1280, 800),
        );
        await verifyFramelessEmptyState(
          TargetPlatform.android,
          const Size(1024, 768),
        );
        await verifyFramelessEmptyState(
          TargetPlatform.android,
          const Size(390, 844),
        );
      },
    );
  });
}

class _StubNetworkProbeActions extends KonataActionsCoordinator {
  const _StubNetworkProbeActions(super.ref);

  @override
  Future<void> saveNetworkConfig(TmdbNetworkConfig config) async {}

  @override
  Future<ConnectivityReport> testTmdbImageConnectivity(
    TmdbNetworkConfig config,
  ) async {
    return const ConnectivityReport(
      reachable: true,
      latencyMs: 699,
      usedBackup: true,
    );
  }

  @override
  Future<ConnectivityReport> testBangumiImageConnectivity(
    TmdbNetworkConfig config,
  ) async {
    return const ConnectivityReport(
      reachable: false,
      latencyMs: 420,
      errorMessage: '官方不可达，备用地址返回 HTTP 404',
    );
  }
}
