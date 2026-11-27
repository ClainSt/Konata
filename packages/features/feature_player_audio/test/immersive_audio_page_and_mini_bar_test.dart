import 'package:engine_playback/engine_playback.dart';
import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show kSecondaryMouseButton, PointerDeviceKind;
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

final class _RelaySpy implements DesktopRelayGateway {
  final requests = <ExternalAudioAlbumRelayRequest>[];
  ExternalAudioProgressCallback? progress;
  bool missing = true;
  bool failLaunch = false;
  int stops = 0;

  @override
  Future<LaunchPlaybackResult> launchAudioAlbum(
    ExternalAudioAlbumRelayRequest request, {
    ExternalAudioProgressCallback? onTrackProgress,
  }) async {
    requests.add(request);
    progress = onTrackProgress;
    if (missing && !request.allowWithoutBeefweb) {
      return const LaunchPlaybackResult(
        launched: false,
        requiresBeefwebPrompt: true,
        message: '需要 Beefweb',
      );
    }
    if (failLaunch) {
      return const LaunchPlaybackResult(launched: false, message: '启动失败');
    }
    if (!missing) {
      await onTrackProgress?.call(
        request.initialTrack,
        17,
        60,
        isCompleted: false,
        isFinal: false,
      );
    }
    return const LaunchPlaybackResult(launched: true, message: '已移交外部播放器');
  }

  @override
  Future<void> stopActiveExternalAudioSession({int beefwebPort = 8880}) async {
    stops++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
    DesktopRelayGateway? relay,
    Map<String, Uint8List> extraFiles = const {},
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
      ...extraFiles,
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
      desktopRelayGateway: relay,
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

  test('默认外部音频直接接力，无内置客户端且保留选中轨及断点', () async {
    final relay = _RelaySpy()..missing = false;
    final h = createHarness(relay: relay);
    addTearDown(() async {
      h.controller.dispose();
      await h.db.close();
    });
    final variants = [
      makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
      makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Second Song.flac'),
    ];
    final result = await h.controller.relayCdCollectionToDesktop(
      work: makeTestWork(),
      variants: variants,
      sources: [makeTestSource()],
      initialVariant: variants.last,
      startPositionSeconds: 8,
    );
    expect(result?.launched, isTrue);
    expect(h.clients, isEmpty);
    expect(h.controller.activeListenable.value, isFalse);
    final request = relay.requests.single;
    expect(request.tracks.length, 2);
    expect(request.initialTrack.variant.id.value, 'v2');
    expect(request.exactStartSeconds, 8);
    expect(
      h.db.userState.playbackRecords
          .listAllWithTombstones()
          .single
          .positionSeconds,
      17,
    );
  });

  test('默认外部音频缺组件及启动失败不创建新解码会话', () async {
    final relay = _RelaySpy();
    final h = createHarness(relay: relay);
    addTearDown(() async {
      h.controller.dispose();
      await h.db.close();
    });
    final variants = [
      makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
      makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Second Song.flac'),
    ];
    await h.controller.playCdCollection(
      work: makeTestWork(),
      variants: variants,
      sources: [makeTestSource()],
    );
    await h.controller.setPlaying(true);
    final result = await h.controller.relayCdCollectionToDesktop(
      work: makeTestWork(),
      variants: variants,
      sources: [makeTestSource()],
      initialVariant: variants.last,
    );
    expect(result?.requiresBeefwebPrompt, isTrue);
    expect(h.clients.length, 1);
    expect(h.controller.playingListenable.value, isTrue);
    expect(
      h.controller.snapshotListenable.value.currentItem?.variant.id.value,
      'v1',
    );
    relay.missing = false;
    relay.failLaunch = true;
    final failed = await h.controller.relayCdCollectionToDesktop(
      work: makeTestWork(),
      variants: variants,
      sources: [makeTestSource()],
      initialVariant: variants.last,
    );
    expect(failed?.launched, isFalse);
    expect(h.clients.length, 1);
    expect(h.controller.playingListenable.value, isTrue);
    final invalid = await h.controller.relayCdCollectionToDesktop(
      work: makeTestWork(),
      variants: variants,
      sources: [makeTestSource()],
      initialVariant: variants.last,
      initialCueTrackIndex: 9,
    );
    expect(invalid?.launched, isFalse);
    expect(relay.requests.length, 2);
    expect(h.controller.playingListenable.value, isTrue);
  });

  test('专辑接力保留真实曲目身份及独立进度，失败恢复内置会话', () async {
    final relay = _RelaySpy()
      ..missing = false
      ..failLaunch = true;
    final h = createHarness(relay: relay);
    addTearDown(() async {
      h.controller.dispose();
      await h.db.close();
    });
    final variants = [
      makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
      makeTestCdVariant(id: 'v2', relativePath: 'CD/02. Second Song.flac'),
    ];
    await h.controller.playCdCollection(
      work: makeTestWork(),
      variants: variants,
      sources: [makeTestSource()],
      initialVariant: variants[1],
      startPositionSeconds: 8,
    );
    await h.controller.setPlaying(true);
    final failed = await h.controller.relayActiveToDesktop();
    expect(failed?.launched, isFalse);
    expect(h.controller.playingListenable.value, isTrue);
    expect(h.controller.activeListenable.value, isTrue);
    relay.failLaunch = false;
    final success = await h.controller.relayActiveToDesktop();
    expect(success?.launched, isTrue);
    expect(h.controller.activeListenable.value, isFalse);
    final request = relay.requests.last;
    expect(request.tracks.length, 2);
    expect(request.initialTrack.variant.id.value, 'v2');
    expect(request.initialTrackIndex, 1);
    final records = h.db.userState.playbackRecords.listAllWithTombstones();
    expect(
      records.singleWhere((r) => r.variantId.value == 'v2').positionSeconds,
      17,
    );
    await relay.progress!(
      request.tracks.first,
      23,
      60,
      isCompleted: false,
      isFinal: false,
    );
    expect(
      h.db.userState.playbackRecords
          .listAllWithTombstones()
          .singleWhere((r) => r.variantId.value == 'v1')
          .positionSeconds,
      23,
    );
    final oldProgress = relay.progress!;
    await h.controller.playCdCollection(
      work: makeTestWork(),
      variants: variants,
      sources: [makeTestSource()],
    );
    expect(relay.stops, 1);
    await oldProgress(
      request.tracks[1],
      44,
      60,
      isCompleted: false,
      isFinal: true,
    );
    expect(
      h.db.userState.playbackRecords
          .listAllWithTombstones()
          .singleWhere((r) => r.variantId.value == 'v2')
          .positionSeconds,
      17,
    );
  });

  for (final mismatched in [false, true]) {
    test('CUE 接力 ${mismatched ? "拒绝错误物理文件关联" : "保留分轨身份与相对时间"}', () async {
      final relay = _RelaySpy()..missing = false;
      final cue =
          '''
TITLE "Audit Album"
FILE "album.flac" WAVE
  TRACK 01 AUDIO
    TITLE "First"
    INDEX 01 00:00:00
${mismatched ? 'FILE "other.flac" WAVE' : ''}
  TRACK 02 AUDIO
    TITLE "Second"
    INDEX 01 00:30:00
''';
      final h = createHarness(
        relay: relay,
        extraFiles: {
          'CD/album.cue': Uint8List.fromList(cue.codeUnits),
          'CD/album.flac': Uint8List.fromList([1, 2, 3]),
        },
      );
      addTearDown(() async {
        h.controller.dispose();
        await h.db.close();
      });
      final audio = makeTestCdVariant(
        id: 'album',
        relativePath: 'CD/album.flac',
      );
      final manifest = makeTestCdVariant(
        id: 'cue',
        relativePath: 'CD/album.cue',
      );
      await h.controller.playCdCollection(
        work: makeTestWork(),
        variants: [audio, manifest],
        sources: [makeTestSource()],
        initialVariant: manifest,
        initialCueTrackIndex: 2,
        startPositionSeconds: 8,
      );
      final before = h.controller.snapshotListenable.value;
      expect(before.currentItem?.cueTrackIndex, 2);
      expect(before.currentItem?.startSeconds, 30);
      final result = await h.controller.relayActiveToDesktop();
      if (mismatched) {
        expect(result?.launched, isFalse);
        expect(relay.requests, isEmpty);
        expect(h.controller.activeListenable.value, isTrue);
      } else {
        expect(result?.launched, isTrue);
        final request = relay.requests.single;
        expect(request.initialTrackIndex, 1);
        expect(request.tracks.length, 2);
        expect(request.parsedCueSheet?.tracks.length, 2);
        expect(request.initialTrack.cueStartSeconds, 30);
        expect(request.initialTrack.recordId, endsWith('album#cue:2'));
        expect(request.initialTrack.variant.id.value, 'album');
        expect(request.exactStartSeconds, closeTo(8, 0.1));
        expect(
          h.db.userState.playbackRecords
              .listAllWithTombstones()
              .singleWhere((r) => r.id == request.initialTrack.recordId)
              .positionSeconds,
          17,
        );
        expect(h.controller.activeListenable.value, isFalse);
      }
    });
  }

  testWidgets('外部接力缺组件提示取消及显式降级', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final relay = _RelaySpy();
    final h = createHarness(relay: relay);
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
    await h.controller.setPlaying(true);
    await tester.pumpWidget(
      _wrapWithApp(
        ImmersiveAudioPage(
          controller: h.controller,
          paletteCache: ArtworkPaletteCache(),
          alignmentCache: SmartCoverAlignmentCache(),
          desktopRelayAvailable: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    final button = find.byKey(const ValueKey('audio_top_external_relay'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Foobar2000 未安装 Beefweb'), findsOneWidget);
    expect(relay.requests.single.tracks.length, 2);
    expect(relay.requests.single.allowWithoutBeefweb, isFalse);
    expect(h.controller.playingListenable.value, isTrue);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.controller.activeListenable.value, isTrue);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('仅启动播放器'));
    for (var i = 0; i < 30 && h.controller.activeListenable.value; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      // 原生句柄释放涉及真实异步队列，推进真实事件循环后再刷新测试帧。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(relay.requests.length, 3);
    expect(relay.requests.last.allowWithoutBeefweb, isTrue);
    expect(h.controller.activeListenable.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空闲音频安全弹窗显示检测拒绝和重新锁定结果', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('硬件核验与解锁'));
    await tester.pumpAndSettle();
    final unlock = find.widgetWithText(KonataPillButton, '解锁当次会话满幅输出');
    expect(tester.widget<KonataPillButton>(unlock).onPressed, isNull);
    final feedback = find.byKey(const ValueKey('audio_safety_action_feedback'));
    await tester.tap(find.text('检测当前硬件直通链路'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(feedback).data, contains('未检测到正在运行的音频会话'));
    await tester.tap(find.text('恢复并重新锁定 -12 dBFS 安全天花板'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(feedback).data, contains('安全门锁已恢复'));
    expect(h.prefsRepo.read().audiophileSafetyLimiterEnabled, isTrue);
    expect(tester.widget<KonataPillButton>(unlock).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('模拟独占输出的安全弹窗检测、解锁与重锁均反馈实际滤镜状态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final h = createHarness();
    addTearDown(() async {
      h.controller.dispose();
      await h.db.close();
    });
    h.prefsRepo.update((p) => p.copyWith(exclusiveAudioOutput: true));
    await h.controller.playCdCollection(
      work: makeTestWork(),
      variants: [
        makeTestCdVariant(id: 'v1', relativePath: 'CD/01. First Song.flac'),
      ],
      sources: [makeTestSource()],
    );
    await tester.pumpWidget(
      _wrapWithApp(
        SingleChildScrollView(
          child: SettingsAudioPanel(
            preferences: h.prefsRepo,
            controller: h.controller,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('硬件核验与解锁'));
    await tester.pumpAndSettle();
    final unlock = find.widgetWithText(KonataPillButton, '解锁当次会话满幅输出');
    final feedback = find.byKey(const ValueKey('audio_safety_action_feedback'));
    final mpv = h.clients.single;
    expect(tester.widget<KonataPillButton>(unlock).onPressed, isNull);
    expect(
      mpv.currentAf,
      contains(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
    );
    await tester.tap(find.text('检测当前硬件直通链路'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(feedback).data, contains('已核验 Windows WASAPI'));
    expect(tester.widget<KonataPillButton>(unlock).onPressed, isNotNull);
    await tester.tap(unlock);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(feedback).data, contains('本次会话已解锁'));
    expect(mpv.currentAf, isEmpty);
    expect(h.prefsRepo.read().audiophileSafetyLimiterEnabled, isTrue);
    await tester.tap(find.text('恢复并重新锁定 -12 dBFS 安全天花板'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(feedback).data, contains('安全门锁已恢复'));
    expect(
      mpv.currentAf,
      contains(AudiophileSafetyPolicy.postDspSafetyLimiterFilter),
    );
    expect(tester.widget<KonataPillButton>(unlock).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ImmersiveAudioPage 桌面双栏无歌词视口时优雅降级，并隔离叶子进度时钟更新', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final spyWindow = SpyHostWindowPort();
    addTearDown(spyWindow.dispose);
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

    // 模拟缩窗后的真实视口，确认仍使用同一音频实例、曲目及播放位置。
    final loadCount = mpv.commands.where((c) => c.first == 'loadfile').length;
    final trackId = h.controller.snapshot.currentItem!.itemId;
    await tester.tap(find.byIcon(Icons.picture_in_picture_alt_rounded));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(72, 72));
    await tester.pump();
    expect(spyWindow.enterMiniCount, 1);
    expect(spyWindow.enterAudioMiniCount, 1);
    expect(spyWindow.lastMiniWidth, 72);
    expect(spyWindow.lastMiniHeight, 72);
    final initialDisc = find.byKey(const ValueKey('mini_audio_disc_surface'));
    expect(initialDisc, findsOneWidget);
    expect(find.byKey(const ValueKey('audio_playing_bars')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mini_audio_expanded_capsule')),
      findsNothing,
    );
    await tester.tap(initialDisc);
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(336, 76));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('audio_desktop_mini_stage')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mini_audio_expanded_capsule')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('salt_smoke_playback_capsule')),
      findsNothing,
    );
    expect(find.text('First Song'), findsOneWidget);
    final title = find.byKey(const ValueKey('mini_audio_track_title'));

    expect(tester.widget<Text>(title).textAlign, TextAlign.start);
    final titleArea = find
        .ancestor(of: title, matching: find.byType(Align))
        .first;
    expect(tester.getSize(titleArea).width, greaterThanOrEqualTo(90));
    expect(find.byKey(const ValueKey('audio_playing_bars')), findsNothing);
    // 模拟窗口尺寸事件与胶囊形态暂时不同步，不能出现溢出。
    await tester.binding.setSurfaceSize(const Size(72, 88));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(336, 76));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(h.clients.single, same(mpv));
    expect(h.controller.currentTrackPositionSeconds, closeTo(65, 0.1));
    spyWindow.blurEvents.add(null);
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(72, 72));
    await tester.pump();
    expect(initialDisc, findsOneWidget);
    expect(spyWindow.lastMiniWidth, 72);
    await tester.tap(initialDisc);
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(336, 76));
    await tester.pump();
    spyWindow.moveEvents.add(null);
    await tester.pump();
    expect(spyWindow.snapCount, 1);
    expect(
      find.byKey(const ValueKey('mini_audio_expanded_capsule')),
      findsOneWidget,
    );
    spyWindow.nextDockSide = DesktopMiniDockSide.left;
    spyWindow.moveEvents.add(null);
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(40, 88));
    await tester.pump();
    expect(find.byKey(const ValueKey('mini_audio_tucked_tab')), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    spyWindow.nextDockSide = null;
    spyWindow.moveEvents.add(null);
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(72, 72));
    await tester.pump();
    expect(initialDisc, findsOneWidget);
    expect(find.byKey(const ValueKey('mini_audio_tucked_tab')), findsNothing);
    expect(spyWindow.lastMiniWidth, 72);
    expect(spyWindow.lastMiniHeight, 72);
    await tester.tap(find.byKey(const ValueKey('mini_audio_disc_surface')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(336, 76));
    await tester.pump();
    spyWindow.nextDockSide = DesktopMiniDockSide.right;
    spyWindow.moveEvents.add(null);
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(40, 88));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    spyWindow.nextDockSide = null;
    spyWindow.moveEvents.add(null);
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(72, 72));
    await tester.pump();
    expect(initialDisc, findsOneWidget);
    expect(find.byKey(const ValueKey('mini_audio_tucked_tab')), findsNothing);
    expect(spyWindow.lastMiniWidth, 72);
    expect(spyWindow.lastMiniHeight, 72);
    spyWindow.nextDockSide = DesktopMiniDockSide.right;
    spyWindow.moveEvents.add(null);
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(40, 88));
    await tester.pump();
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mini_audio_tucked_tab')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(72, 72));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mini_audio_disc_surface')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(336, 76));
    await tester.pump();
    await tester.tap(find.byTooltip('收起'));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(72, 72));
    await tester.pump();
    expect(spyWindow.lastMiniWidth, 72);
    expect(spyWindow.lastMiniHeight, 72);
    expect(
      find.byKey(const ValueKey('mini_audio_disc_surface')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('mini_audio_disc_surface')),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(40, 88));
    await tester.pump();
    expect(spyWindow.lastMiniWidth, 40);
    expect(spyWindow.lastMiniHeight, 88);
    expect(find.byKey(const ValueKey('mini_audio_tucked_tab')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mini_audio_tucked_tab')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(72, 72));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('mini_audio_disc_surface')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('mini_audio_disc_surface')));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(336, 76));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('mini_audio_expanded_capsule')),
      findsOneWidget,
    );
    await tester.tap(find.text('First Song'));
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pump();
    expect(spyWindow.exitMiniCount, 1);
    expect(
      find.byKey(const ValueKey('audio_desktop_mini_stage')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('salt_smoke_playback_capsule')),
      findsOneWidget,
    );
    expect(h.controller.snapshot.currentItem!.itemId, trackId);
    expect(mpv.commands.where((c) => c.first == 'loadfile').length, loadCount);
  });

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

      expect(
        find.byKey(const ValueKey('custom_lyrics_viewport')),
        findsOneWidget,
      );
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

  test('桌面音频小窗失败时回滚状态，保留原播放会话并允许重试', () async {
    final host = SpyHostWindowPort();
    final h = createHarness(windowPort: host);
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
    final mpv = h.clients.single;
    mpv.emitDuration(240);
    mpv.emitTimePos(65);
    await Future<void>.delayed(Duration.zero);
    final loads = mpv.commands.where((c) => c.first == 'loadfile').length;
    host.failEnterMini = true;
    await expectLater(
      h.controller.setDesktopMiniWindow(true),
      throwsStateError,
    );
    expect(h.controller.snapshot.isDesktopMiniWindow, isFalse);
    host.failEnterMini = false;
    await h.controller.setDesktopMiniWindow(true);
    host.failEnterMini = true;
    await expectLater(
      h.controller.resizeDesktopMiniWindow(width: 72, height: 72),
      throwsStateError,
    );
    expect(h.controller.snapshot.isDesktopMiniWindow, isTrue);
    host.failEnterMini = false;
    await h.controller.resizeDesktopMiniWindow(width: 72, height: 72);
    expect(host.lastMiniWidth, 72);
    host.failExitMini = true;
    await expectLater(
      h.controller.setDesktopMiniWindow(false),
      throwsStateError,
    );
    expect(h.controller.snapshot.isDesktopMiniWindow, isTrue);
    await expectLater(h.controller.stopAndClose(), throwsStateError);
    expect(h.controller.snapshot.isDesktopMiniWindow, isTrue);
    expect(h.controller.activeListenable.value, isTrue);
    expect(mpv.isDisposed, isFalse);
    host.failExitMini = false;
    await h.controller.setDesktopMiniWindow(false);
    expect(h.controller.snapshot.isDesktopMiniWindow, isFalse);
    expect(h.clients.single, same(mpv));
    expect(mpv.commands.where((c) => c.first == 'loadfile').length, loads);
    expect(h.controller.currentTrackPositionSeconds, closeTo(65, 0.1));
  });
  testWidgets('长队列定位当前曲目，普通重建不抢占滚动，换曲重新定位且边缘渐隐', (tester) async {
    final h = createHarness();
    addTearDown(() async {
      h.controller.dispose();
      await h.db.close();
    });
    final source = makeTestSource();
    final queue = AudioPlaybackQueueBuilder.buildInitialQueue(
      work: makeTestWork(),
      variants: [
        for (var i = 0; i < 48; i++)
          makeTestCdVariant(
            id: 'track_$i',
            relativePath: 'CD/${i.toString().padLeft(2, '0')}. Song $i.flac',
          ),
      ],
      sourceById: {source.id.value: source},
    );
    AudioPlaybackSnapshot snapshot(int index) =>
        AudioPlaybackSnapshot(queue: queue, currentIndex: index);
    Widget app(int index) => _wrapWithApp(
      Center(
        child: SizedBox(
          width: 300,
          height: 280,
          child: AudioQueueListView(
            controller: h.controller,
            snapshot: snapshot(index),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(40));
    await tester.pump();
    final list = find.byType(ListView);
    final scroll = tester.widget<ListView>(list).controller!;
    expect(scroll.offset, greaterThan(0));
    final current = find.text(queue[40].title);
    expect(current, findsOneWidget);
    expect(tester.getRect(list).contains(tester.getCenter(current)), isTrue);
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.byKey(const ValueKey('audio_playing_bars')), findsOneWidget);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pumpWidget(app(40));
    await tester.pump();
    expect(scroll.offset, 0);
    await tester.pumpWidget(app(25));
    await tester.pump();
    expect(scroll.offset, greaterThan(0));
    expect(
      tester
          .getRect(list)
          .contains(tester.getCenter(find.text(queue[25].title))),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('MiniAudioBar 拖拽直连叶子 ValueNotifier<Offset> 且支持点击展开胶囊控制与暂停止钟', (
    tester,
  ) async {
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

    // 多次指针移动后吸右边，纵向位置不随速度或吸附动画跳至顶端。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    dragOffset.value = const Offset(700, 280);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(discFinder));
    await gesture.moveBy(const Offset(50, 10));
    await tester.pump();
    await gesture.moveBy(const Offset(30, -10));
    await tester.pump();
    await gesture.moveBy(const Offset(120, 0));
    await gesture.up();
    await tester.pump();
    final rightEar = find.byKey(const ValueKey('mini_audio_tucked_tab'));
    expect(rightEar, findsOneWidget);
    expect(dragOffset.value.dy, closeTo(280, 1));
    expect(tester.getRect(rightEar).right, closeTo(900, 1));
    await tester.tap(rightEar);
    await tester.pump();
    expect(discFinder, findsOneWidget);
    expect(dragOffset.value.dy, closeTo(280, 1));

    // 点击圆盘展开胶囊播控条并验证切歌与进入全屏舞台。
    await tester.tap(discFinder);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('mini_audio_expanded_capsule')),
      findsOneWidget,
    );
    expect(find.text('First Song'), findsOneWidget);
    expect(find.byKey(const ValueKey('audio_playing_bars')), findsNothing);
    expect(find.text('CD'), findsNothing);

    await tester.tapAt(const Offset(80, 80));
    await tester.pump();
    expect(discFinder, findsOneWidget);
    expect(
      find.byKey(const ValueKey('mini_audio_expanded_capsule')),
      findsNothing,
    );
    await tester.tap(discFinder);
    await tester.pump();
    await tester.tap(find.text('First Song'));
    await tester.pump();
    expect(expandCalled, 1);

    // 贴边时仍展示播放状态；暂停后停止持续重绘。
    await tester.drag(
      find.byKey(const ValueKey('mini_audio_expanded_capsule')),
      const Offset(-900, 0),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('mini_audio_tucked_tab')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio_playing_bars')), findsOneWidget);
    await h.controller.setPlaying(false);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.tap(find.byKey(const ValueKey('mini_audio_tucked_tab')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('mini_audio_disc_surface')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('独立视频接管前结束音频浮窗且随后视频句柄不受影响', () async {
    final h = createHarness();
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
    final old = h.clients.single;
    await h.controller.pauseForVideoSession();
    expect(h.controller.activeListenable.value, isFalse);
    expect(h.controller.snapshot.isActive, isFalse);
    expect(old.isDisposed, isTrue);

    final lease = await h.engine.acquireExclusiveNativeClient(
      stage: PlaybackStageKind.video,
      factoryOverride: FakeLibMpvClient.new,
    );
    await h.controller.pauseForVideoSession();
    expect(h.engine.activeNativeClient, same(lease.client));
    expect(lease.client.isDisposed, isFalse);
    await h.engine.releaseNativeClient(lease.client);
  });

  testWidgets('手机 375dp 音频设置标题与下拉框、滑杆同排对齐', (tester) async {
    final h = createHarness();
    addTearDown(() async {
      h.controller.dispose();
      await h.db.close();
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(375, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _wrapWithApp(
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: SettingsAudioPanel(
            preferences: h.prefsRepo,
            controller: h.controller,
            isDesktopPlatform: false,
            isAndroidPlatform: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rows = <(Finder, Finder)>[
      (
        find.text('重采样精度'),
        find.byKey(const ValueKey('audio_resampler_precision')),
      ),
      (find.text('回放增益'), find.byKey(const ValueKey('audio_replay_gain'))),
      (
        find.textContaining('前置增益 ('),
        find.byKey(const ValueKey('audio_preamp_slider')),
      ),
      (
        find.textContaining('起播音量 ('),
        find.byKey(const ValueKey('audio_volume_slider')),
      ),
    ];
    double? right;
    for (final (label, control) in rows) {
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();
      final l = tester.getRect(label);
      final r = tester.getRect(control);
      expect(l.right, lessThanOrEqualTo(r.left));
      expect(l.center.dy, inInclusiveRange(r.top, r.bottom));
      if (right != null) expect(r.right, closeTo(right, 0.1));
      right = r.right;
    }
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('audio_replay_gain')));
    await tester.tap(find.byKey(const ValueKey('audio_replay_gain')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按单曲').last);
    await tester.pumpAndSettle();
    expect(h.prefsRepo.read().replayGainMode, AudioReplayGainMode.track);
  });

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

    expect(find.text('输出与安全保护'), findsOneWidget);
    expect(find.text('增益与音量'), findsOneWidget);
    expect(find.text('桌面端外部音频转发接力'), findsNothing);
    expect(find.textContaining('Beefweb'), findsNothing);
    expect(featurePlayerAudioManifest.settingsSections.single.title, '音频');
    final engine = find.byKey(const ValueKey('audio_engine_selector'));
    expect(engine, findsOneWidget);
    await tester.ensureVisible(engine);
    await tester.tap(find.descendant(of: engine, matching: find.text('外部播放器')));
    await tester.pumpAndSettle();
    expect(
      h.prefsRepo.read().preferredAudioEngine,
      PreferredPlaybackEngine.desktopRelay,
    );
    await tester.tap(
      find.descendant(of: engine, matching: find.text('内置流光音频')),
    );
    await tester.pumpAndSettle();
    expect(
      h.prefsRepo.read().preferredAudioEngine,
      PreferredPlaybackEngine.builtinLibmpv,
    );

    // 校验声明式清单与 Riverpod Provider 正常注入解析。
    expect(featurePlayerAudioManifest.id, 'feature_player_audio');
    expect(featurePlayerAudioManifest.settingsSections.length, 1);
    expect(
      featurePlayerAudioManifest.settingsSections.first.id,
      'audio_playback',
    );

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

  testWidgets('Salt 级舞台在浅色系统主题下保持恒定深邃暗底、纯白发光排版、无白边倒影与烟熏顶边胶囊', (tester) async {
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
    expect(find.byKey(const ValueKey('desktop_tab_queue_chip')), findsNothing);
    final format = find.byKey(const ValueKey('audio_format_badge'));
    expect(format, findsOneWidget);
    await tester.tap(format);
    await tester.pump();
    expect(find.text('音频安全设置'), findsNothing);
    expect(
      find.byKey(const ValueKey('salt_smoke_playback_capsule')),
      findsOneWidget,
    );
    final queue = find.byKey(const ValueKey('audio_desktop_queue_button'));
    expect(queue, findsOneWidget);
    expect(tester.widget<KonataCapsuleIconButton>(queue).highlighted, isFalse);
    expect(
      tester.widget<KonataCapsuleIconButton>(queue).icon,
      Icons.queue_music_rounded,
    );
    expect(
      find.byKey(const ValueKey('immersive_cover_reflection')),
      findsOneWidget,
    );
    await tester.tap(queue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('audio_desktop_queue_stage')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('audio_desktop_lyrics_stage')),
      findsNothing,
    );
    expect(find.byType(KonataGlassSideSheet), findsNothing);
    expect(tester.widget<KonataCapsuleIconButton>(queue).highlighted, isFalse);
    expect(
      tester.widget<KonataCapsuleIconButton>(queue).icon,
      Icons.lyrics_outlined,
    );
    expect(find.byKey(const ValueKey('audio_playing_bars')), findsOneWidget);
    expect(find.text('Second Song'), findsOneWidget);
    await tester.tap(queue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('audio_desktop_lyrics_stage')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('audio_desktop_queue_stage')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android 手机锁纯竖屏、无作品详情、格式徽标紧贴曲名右侧、顶栏极简且右上菜单统筹歌词与无损信息', (
    tester,
  ) async {
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
  });
}
