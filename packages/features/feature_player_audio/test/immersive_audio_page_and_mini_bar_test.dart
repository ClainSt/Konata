import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import 'test_fakes.dart';

Widget _wrapWithApp(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? KonataTheme.darkTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  ({
    KonataDatabaseBundle db,
    ScopedPrefsStore store,
    AudioPlaybackPreferences prefsRepo,
    UnifiedPlaybackEngine engine,
    AudiophileSafetyCoordinator safetyCoordinator,
    List<FakeLibMpvClient> clients,
    AudioPlaybackController controller,
  })
  createHarness({
    PlaybackHostWindowPort windowPort = const NoopPlaybackHostWindowPort(),
    LyricDisplayPort? lyricPort,
  }) {
    final db = KonataDatabaseBundle.openInMemory();
    final store = ScopedPrefsStore(db.userState);
    final prefsRepo = AudioPlaybackPreferences(store: store);
    final engine = UnifiedPlaybackEngine();
    final safetyCoordinator = AudiophileSafetyCoordinator(
      engine: engine,
      isWindowsOverride: true,
    );
    final clients = <FakeLibMpvClient>[];
    final files = <String, Uint8List>{
      'CD/01. First Song.flac': Uint8List.fromList([1, 2, 3]),
      'CD/02. Second Song.flac': Uint8List.fromList([4, 5, 6]),
    };
    final controller = AudioPlaybackController(
      preferences: prefsRepo,
      assets: AudioPlaybackAssets(),
      engine: engine,
      safetyCoordinator: safetyCoordinator,
      gatewayFactory: FakeGatewayFactory(files),
      streamBridge: FakeStreamBridge(),
      windowPort: windowPort,
      lyricPort: lyricPort,
      database: db,
      isWindowsOverride: true,
      mpvClientFactoryOverride: () {
        final c = FakeLibMpvClient();
        clients.add(c);
        return c;
      },
    );
    return (
      db: db,
      store: store,
      prefsRepo: prefsRepo,
      engine: engine,
      safetyCoordinator: safetyCoordinator,
      clients: clients,
      controller: controller,
    );
  }

  testWidgets(
    'ImmersiveAudioPage 桌面双栏无歌词视口时优雅降级，并隔离叶子进度时钟更新',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final spyWindow = SpyHostWindowPort();
      final h = createHarness(windowPort: spyWindow);
      h.prefsRepo.update((p) => p.copyWith(exclusiveAudioOutput: true));
      addTearDown(() async {
        h.controller.dispose();
        await h.db.close();
      });

      await h.controller.playCdCollection(
        work: makeTestWork(),
        variants: [
          makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
          makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Second Song.flac'),
        ],
        sources: [makeTestSource()],
      );

      var outerBuilds = 0;
      await tester.pumpWidget(
        _wrapWithApp(
          Builder(
            builder: (context) {
              outerBuilds++;
              return ImmersiveAudioPage(
                controller: h.controller,
                paletteCache: ArtworkPaletteCache(),
                alignmentCache: SmartCoverAlignmentCache(),
                desktopMiniWindowSupported: true,
                lyricsViewportBuilder: null,
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(outerBuilds, 1);
      expect(find.text('First Song'), findsWidgets);
      expect(find.textContaining('未接入实时歌词视图插件'), findsOneWidget);
      expect(find.text('-12 dBFS'), findsOneWidget);

      // 高频推进叶子时钟仅局部重绘进度条，严禁引起外部宿主重建。
      final mpv = h.clients.single;
      mpv.emitDuration(240.0);
      mpv.emitTimePos(65.0);
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(find.text('01:05'), findsOneWidget);
      expect(outerBuilds, 1);

      // 点击桌面迷你窗切换按钮触发宿主窗口端口。
      await tester.tap(find.byIcon(Icons.picture_in_picture_alt_rounded));
      await tester.pump();
      expect(spyWindow.enterMiniCount, 1);
    },
  );

  testWidgets(
    'ImmersiveAudioPage 支持外挂歌词视口注入、过滤 PlayerMediaMode.audio 扩展侧栏及竖屏封面切换',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final h = createHarness(lyricPort: SpyLyricDisplayPort());
      addTearDown(() async {
        h.controller.dispose();
        await h.db.close();
      });

      await h.controller.playCdCollection(
        work: makeTestWork(),
        variants: [
          makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
        ],
        sources: [makeTestSource()],
      );

      final extraPanels = <PlayerSidePanelContribution>[
        PlayerSidePanelContribution(
          id: 'lyric_calibration',
          label: '歌词时间轴校准',
          iconKey: 'lyrics',
          order: 10,
          supportedModes: const <PlayerMediaMode>{PlayerMediaMode.audio},
          viewBuilder: (ctx) => Text(
            '校准面板:${ctx.arguments['title']}',
            key: const ValueKey('injected_audio_side_panel_body'),
          ),
        ),
        PlayerSidePanelContribution(
          id: 'video_subtitle_only',
          label: '仅视频字幕面板',
          iconKey: 'player',
          order: 20,
          supportedModes: const <PlayerMediaMode>{PlayerMediaMode.video},
          viewBuilder: (_) => const Text('不应展示在音频舞台'),
        ),
      ];

      await tester.pumpWidget(
        _wrapWithApp(
          ImmersiveAudioPage(
            controller: h.controller,
            paletteCache: ArtworkPaletteCache(),
            alignmentCache: SmartCoverAlignmentCache(),
            extraSidePanels: extraPanels,
            lyricsViewportBuilder: (_, viewport) => Text(
              '自定义歌词视口:${viewport.trackKey}',
              key: const ValueKey('custom_lyrics_viewport'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('custom_lyrics_viewport')), findsOneWidget);
      // 验证只渲染 audio 侧栏图标按钮，video 侧栏已被过滤。
      expect(find.byIcon(KonataIconRegistry.resolve('lyrics')), findsOneWidget);
      expect(find.byIcon(KonataIconRegistry.resolve('player')), findsNothing);

      // 点击动态注入的音频侧栏按钮应打开玻璃侧边抽屉。
      await tester.tap(find.byIcon(KonataIconRegistry.resolve('lyrics')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const ValueKey('injected_audio_side_panel_body')),
        findsOneWidget,
      );
      expect(find.text('校准面板:First Song'), findsOneWidget);

      // 切换至手机竖屏尺寸验证封面 <-> 歌词切换。
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pump();
      expect(find.byKey(const ValueKey('portrait_cover')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('portrait_cover')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('portrait_lyrics')), findsOneWidget);
    },
  );

  testWidgets(
    'MiniAudioBar 拖拽直连叶子 ValueNotifier<Offset> 且支持点击展开胶囊控制与暂停止钟',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final h = createHarness();
      addTearDown(() async {
        h.controller.dispose();
        await h.db.close();
      });

      await h.controller.playCdCollection(
        work: makeTestWork(),
        variants: [
          makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
          makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Second Song.flac'),
        ],
        sources: [makeTestSource()],
      );

      final dragOffset = ValueNotifier<Offset>(const Offset(180, 180));
      addTearDown(dragOffset.dispose);

      var outerBuilds = 0;
      var expandCalled = 0;
      await tester.pumpWidget(
        _wrapWithApp(
          Builder(
            builder: (context) {
              outerBuilds++;
              return MiniAudioBar(
                controller: h.controller,
                dragOffsetNotifier: dragOffset,
                onExpandFullStage: () => expandCalled++,
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final discFinder = find.byKey(const ValueKey('mini_audio_disc_surface'));
      expect(discFinder, findsOneWidget);

      // 拖拽悬浮唱片：坐标直接写入叶子 ValueNotifier<Offset> 且外层不重建。
      await tester.drag(discFinder, const Offset(80, 50));
      await tester.pump();
      expect(dragOffset.value.dx, greaterThan(180));
      expect(outerBuilds, 1);

      // 点击圆盘展开胶囊播控条并验证切歌与进入全屏舞台。
      await tester.tap(discFinder);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('mini_audio_expanded_capsule')),
        findsOneWidget,
      );
      expect(find.text('First Song'), findsOneWidget);

      await tester.tap(find.text('First Song'));
      await tester.pump();
      expect(expandCalled, 1);

      // 暂停后重新渲染确保平稳无残留挂起动画。
      await h.controller.setPlaying(false);
      await tester.pump();
    },
  );

  testWidgets('SettingsAudioPanel 与 featurePlayerAudioManifest 正确协同持久化和装配', (
    tester,
  ) async {
    final h = createHarness();
    addTearDown(() async {
      h.controller.dispose();
      await h.db.close();
    });

    await tester.pumpWidget(
      _wrapWithApp(
        SingleChildScrollView(
          child: SettingsAudioPanel(
            preferences: h.prefsRepo,
            controller: h.controller,
            isDesktopPlatform: true,
            isAndroidPlatform: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('发烧输出与 -12 dBFS 防爆耳安全链'), findsOneWidget);
    expect(find.text('回放增益与常规音控'), findsOneWidget);
    expect(find.text('桌面端外部音频转发接力'), findsOneWidget);

    // 校验声明式清单与 Riverpod Provider 正常注入解析。
    expect(featurePlayerAudioManifest.id, 'feature_player_audio');
    expect(featurePlayerAudioManifest.settingsSections.length, 1);
    expect(featurePlayerAudioManifest.settingsSections.first.id, 'audio_playback');

    final container = ProviderContainer(
      overrides: [
        featurePlayerAudioDependenciesProvider.overrideWithValue(
          FeaturePlayerAudioDependencies(
            engine: h.engine,
            safetyCoordinator: h.safetyCoordinator,
            prefsStore: h.store,
            gatewayFactory: FakeGatewayFactory(const <String, Uint8List>{}),
            streamBridge: FakeStreamBridge(),
            isWindowsOverride: true,
            mpvClientFactoryOverride: FakeLibMpvClient.new,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final providedCtrl = container.read(audioPlaybackControllerProvider);
    expect(providedCtrl, isA<AudioPlaybackController>());
  });

  testWidgets(
    'Salt 级舞台在浅色系统主题下保持恒定深邃暗底、纯白发光排版、无白边倒影与烟熏顶边胶囊',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final h = createHarness();
      addTearDown(() async {
        h.controller.dispose();
        await h.db.close();
      });

      await h.controller.playCdCollection(
        work: makeTestWork(),
        variants: [
          makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
          makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Second Song.flac'),
        ],
        sources: [makeTestSource()],
      );

      final mpv = h.clients.single;
      mpv.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'audio-codec-name',
          replyUserdata: 14,
          format: MpvFormat.string,
          stringValue: 'flac',
        ),
      );
      mpv.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'audio-params/samplerate',
          replyUserdata: 12,
          format: MpvFormat.int64,
          intValue: 96000,
        ),
      );
      mpv.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'audio-params/format',
          replyUserdata: 13,
          format: MpvFormat.string,
          stringValue: 's24',
        ),
      );
      await tester.pump();

      await tester.pumpWidget(
        _wrapWithApp(
          theme: KonataTheme.lightTheme(),
          ImmersiveAudioPage(
            controller: h.controller,
            paletteCache: ArtworkPaletteCache(),
            alignmentCache: SmartCoverAlignmentCache(),
            desktopRelayAvailable: true,
            onMinimizeToMiniBar: () {},
          ),
        ),
      );
      await tester.pump();

      // 1. 外部传入浅色主题时，背景基底仍锁定恒定深邃暗光域，绝不漂白成浅灰底墙。
      final backdrop = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('salt_audio_aurora_backdrop')),
      );
      final bgColor = (backdrop.decoration as BoxDecoration?)?.color;
      expect(bgColor, isNotNull);
      expect(bgColor!.computeLuminance(), lessThan(0.04));

      // 2. 封面默认关闭硬白边，水面倒影具备高斯模糊层。
      final coverArt = tester.widget<AudioCoverArtworkView>(
        find.byType(AudioCoverArtworkView).first,
      );
      expect(coverArt.showBorder, isFalse);
      expect(find.byType(ImageFiltered), findsWidgets);

      // 3. 宽屏底部呈现超轻烟熏玻璃顶边发光进度胶囊，右侧一键切换歌词/队列。
      expect(
        find.byKey(const ValueKey('salt_smoke_playback_capsule')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('salt_smoke_top_progress_line')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('desktop_tab_queue_chip')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop_tab_queue_chip')));
      await tester.pump();
      expect(find.text('Second Song'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop_tab_lyrics_chip')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android 手机锁纯竖屏、无作品详情、格式徽标紧贴曲名右侧、顶栏极简且右上菜单统筹歌词与无损信息',
    (tester) async {
      final recordedOrientations = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setPreferredOrientations') {
              recordedOrientations.add(call.arguments);
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.binding.setSurfaceSize(const Size(390, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final h = createHarness();
      addTearDown(() async {
        h.controller.dispose();
        await h.db.close();
      });

      await h.controller.playCdCollection(
        work: makeTestWork(),
        variants: [
          makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
          makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Second Song.flac'),
        ],
        sources: [makeTestSource()],
      );

      final mpv = h.clients.single;
      mpv.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'audio-codec-name',
          replyUserdata: 14,
          format: MpvFormat.string,
          stringValue: 'flac',
        ),
      );
      mpv.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'audio-params/samplerate',
          replyUserdata: 12,
          format: MpvFormat.int64,
          intValue: 96000,
        ),
      );
      mpv.emitEvent(
        const MpvPropertyChangeEvent(
          name: 'audio-params/format',
          replyUserdata: 13,
          format: MpvFormat.string,
          stringValue: 's24',
        ),
      );
      await tester.pump();

      final extraPanels = <PlayerSidePanelContribution>[
        PlayerSidePanelContribution(
          id: 'lyrics_control',
          label: '歌词换源与校准',
          iconKey: 'lyrics',
          order: 10,
          supportedModes: const <PlayerMediaMode>{PlayerMediaMode.audio},
          viewBuilder: (ctx) => Column(
            key: const ValueKey('embedded_lyrics_menu_slot'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('已内嵌:${ctx.arguments['embedded']}'),
              const Text('双语开关 / -0.2s / 归零 / +0.2s'),
            ],
          ),
        ),
      ];

      await tester.pumpWidget(
        _wrapWithApp(
          theme: KonataTheme.lightTheme(),
          ImmersiveAudioPage(
            controller: h.controller,
            paletteCache: ArtworkPaletteCache(),
            alignmentCache: SmartCoverAlignmentCache(),
            platform: KonataPlatform.androidPhone,
            extraSidePanels: extraPanels,
            onMinimizeToMiniBar: () {},
            lyricsViewportBuilder: (_, viewport) => Center(
              child: Text(
                'Pure Lyrics:${viewport.trackKey}',
                key: const ValueKey('pure_portrait_lyrics_view'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 1. 进入 Android 手机舞台即锁定纯竖屏 DeviceOrientation.portraitUp。
      expect(
        recordedOrientations,
        contains(equals(const ['DeviceOrientation.portraitUp'])),
      );

      // 2. 封面态顶栏中央留空，彻底移除「作品详情」按钮，格式徽标直接位于曲名右侧。
      expect(
        find.byKey(const ValueKey('portrait_top_empty_center')),
        findsOneWidget,
      );
      expect(find.textContaining('作品详情'), findsNothing);
      final titleRect = tester.getRect(find.text('First Song'));
      final badgeFinder = find.byKey(
        const ValueKey('audio_portrait_format_badge'),
      );
      expect(badgeFinder, findsOneWidget);
      final badgeRect = tester.getRect(badgeFinder);
      expect(badgeRect.left, greaterThanOrEqualTo(titleRect.right - 2.0));
      expect((badgeRect.center.dy - titleRect.center.dy).abs(), lessThan(24.0));

      // 3. 轻触封面切入歌词态：顶部中央淡入迷你封面返回胶囊，轻触返回封面。
      await tester.tap(find.byKey(const ValueKey('portrait_cover')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('pure_portrait_lyrics_view')),
        findsOneWidget,
      );
      final miniPillFinder = find.byKey(
        const ValueKey('portrait_top_mini_cover_pill'),
      );
      expect(miniPillFinder, findsOneWidget);
      await tester.tap(miniPillFinder);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('portrait_cover')), findsOneWidget);

      // 4. 点击右上角菜单：统一呈现无损输出链路信息及 embedded=true 动态歌词面板。
      await tester.tap(find.byKey(const ValueKey('audio_top_menu_button')));
      await tester.pump(const Duration(milliseconds: 220));
      expect(
        find.byKey(const ValueKey('audio_unified_menu_overlay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('audio_lossless_chain_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('embedded_lyrics_menu_slot')),
        findsOneWidget,
      );
      expect(find.text('已内嵌:true'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 5. 四档多视口与横屏尺寸验证零溢出、停用手机横屏妥协布局并最终恢复系统方向。
      for (final scenario in <({Size size, KonataPlatform platform})>[
        (size: const Size(390, 780), platform: KonataPlatform.androidPhone),
        (size: const Size(780, 380), platform: KonataPlatform.androidPhone),
        (size: const Size(768, 1024), platform: KonataPlatform.androidTablet),
        (size: const Size(1024, 700), platform: KonataPlatform.androidTablet),
        (size: const Size(1440, 900), platform: KonataPlatform.windows),
      ]) {
        await tester.binding.setSurfaceSize(scenario.size);
        await tester.pumpWidget(
          _wrapWithApp(
            theme: KonataTheme.lightTheme(),
            ImmersiveAudioPage(
              controller: h.controller,
              paletteCache: ArtworkPaletteCache(),
              alignmentCache: SmartCoverAlignmentCache(),
              platform: scenario.platform,
              extraSidePanels: extraPanels,
              desktopRelayAvailable: true,
              onMinimizeToMiniBar: () {},
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }

      // 销毁页面后恢复系统旋转方向为空列表。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(recordedOrientations.last, isEmpty);
    },
  );
}
