import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/presentation/audio/immersive_audio_page.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_volume_control.dart';

final Uint8List _sampleCoverPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
  0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A, 0x73, 0x00, 0x00, 0x00,
  0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x80,
  0x01, 0x31, 0x20, 0x05, 0x00, 0x32, 0x10, 0x04, 0x01, 0x96, 0x6E, 0x2B,
  0x1B, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
  0x82,
]);

class _FakeAudioLibMpvClient implements LibMpvClient {
  final Map<String, String> options = {};
  final List<List<String>> commands = [];
  final Map<String, double> doubles = {};
  final Map<String, String> strings = {'audio-codec-name': 'flac'};
  final Map<String, int> ints = {
    'audio-params/samplerate': 44100,
    'audio-bitrate': 960000,
  };
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 77;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  void emitEvent(MpvClientEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void emitTimePos(double seconds) {
    doubles['time-pos'] = seconds;
    emitEvent(
      MpvPropertyChangeEvent(
        name: 'time-pos',
        replyUserdata: 101,
        format: MpvFormat.double_,
        doubleValue: seconds,
      ),
    );
  }

  void emitDuration(double seconds) {
    doubles['duration'] = seconds;
    emitEvent(
      MpvPropertyChangeEvent(
        name: 'duration',
        replyUserdata: 102,
        format: MpvFormat.double_,
        doubleValue: seconds,
      ),
    );
  }

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
  int? getPropertyInt64(String name) => ints[name];

  @override
  String? getPropertyString(String name) => strings[name];

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
  int setPropertyString(String name, String value) {
    strings[name] = value;
    return 0;
  }
}

class _StubAudioNotifier extends AudioPlaybackNotifier {
  _StubAudioNotifier(super.ref, AudioPlaybackState initial) {
    state = initial;
  }

  int playQueueIndexCalls = 0;
  int? lastPlayedIndex;
  int stopAndCloseCalls = 0;

  @override
  Future<void> togglePlayPause() async {
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> previous() async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> playQueueIndex(int index) async {
    playQueueIndexCalls++;
    lastPlayedIndex = index;
    state = state.copyWith(currentIndex: index);
  }

  @override
  Future<void> seekRelativeTrackSeconds(double trackSeconds) async {
    state = state.copyWith(positionSeconds: trackSeconds);
  }

  @override
  void toggleMute() {
    state = state.copyWith(isMuted: !state.isMuted);
  }

  @override
  Future<void> stopAndClose() async {
    stopAndCloseCalls++;
    state = const AudioPlaybackState();
  }
}

Widget _wrapStage4App(
  Widget child, {
  required List<Override> overrides,
  ThemeMode mode = ThemeMode.dark,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: mode,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('阶段 4：CUE 尾轨回填、无损过界、零闪烁封面缓存与迷你栏/全屏歌词重构验证', () {
    test(
      'CUE 尾轨时长回填、同母文件自然无损过界 vs 手动 seek 防抖、极速音频选项与零闪烁封面缓存',
      () async {
        SharedPreferences.setMockInitialValues({});
        final tempRoot = await Directory.systemTemp.createTemp(
          'konata_stage4_audio_test_',
        );
        addTearDown(() async {
          if (tempRoot.existsSync()) {
            await tempRoot.delete(recursive: true);
          }
        });

        final albumWithCoverDir = Directory(p.join(tempRoot.path, 'AlbumA'));
        await albumWithCoverDir.create(recursive: true);
        await File(p.join(albumWithCoverDir.path, 'Album.flac')).writeAsBytes(
          const [0x66, 0x4C, 0x61, 0x43], // fLaC header marker
        );
        await File(
          p.join(albumWithCoverDir.path, 'cover.jpg'),
        ).writeAsBytes(_sampleCoverPng);
        await File(p.join(albumWithCoverDir.path, 'Album.cue')).writeAsString(
          'PERFORMER "Kessoku Band"\n'
          'TITLE "Kessoku Band OST"\n'
          'FILE "Album.flac" WAVE\n'
          '  TRACK 01 AUDIO\n'
          '    TITLE "Seishun Complex"\n'
          '    INDEX 01 00:00:00\n'
          '  TRACK 02 AUDIO\n'
          '    TITLE "Guitar, Loneliness and Blue Planet"\n'
          '    INDEX 01 03:00:00\n'
          '  TRACK 03 AUDIO\n'
          '    TITLE "That Band"\n'
          '    INDEX 01 06:00:00\n',
        );

        final albumNoCoverDir = Directory(p.join(tempRoot.path, 'AlbumNoArt'));
        await albumNoCoverDir.create(recursive: true);
        await File(
          p.join(albumNoCoverDir.path, 'Solo.flac'),
        ).writeAsBytes(const [0x66, 0x4C, 0x61, 0x43]);

        final fakeClient = _FakeAudioLibMpvClient();
        final storage = StorageRootService(overrideRoot: tempRoot);
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final container = ProviderContainer(
          overrides: [
            storageRootProvider.overrideWithValue(storage),
            libraryRepositoryProvider.overrideWithValue(repo),
            playbackPreferencesProvider.overrideWith(
              (_) => PlaybackPreferencesNotifier(enablePersistence: false),
            ),
            audioPlaybackProvider.overrideWith(
              (ref) => AudioPlaybackNotifier(
                ref,
                clientFactory: () => fakeClient,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final recordedCovers = <AudioCoverSource>[];
        final sub = container.listen(
          audioPlaybackProvider.select((s) => s.cover),
          (_, next) => recordedCovers.add(next),
        );
        addTearDown(sub.close);

        final source = MediaSource(
          id: 'src-local',
          label: 'Local',
          kind: MediaSourceKind.local,
          location: tempRoot.path,
        );
        const work = Work(
          id: 'w-bocchi',
          title: '孤独摇滚！',
          posterPath: 'tmdb://poster/bocchi.jpg',
        );
        const vCue = MediaVariant(
          id: 'v-cue',
          workId: 'w-bocchi',
          sourceId: 'src-local',
          relativePath: 'AlbumA/Album.cue',
          fileName: 'Album.cue',
          fileSize: 512,
          assetKind: AssetKind.cdAlbum,
        );
        const vFlac = MediaVariant(
          id: 'v-flac',
          workId: 'w-bocchi',
          sourceId: 'src-local',
          relativePath: 'AlbumA/Album.flac',
          fileName: 'Album.flac',
          fileSize: 4096,
          assetKind: AssetKind.cdAlbum,
        );

        final notifier = container.read(audioPlaybackProvider.notifier);
        await notifier.playCdCollection(
          work: work,
          cdVariants: const [vCue, vFlac],
          initialVariant: vCue,
          sourcesById: {'src-local': source},
        );
        for (var i = 0; i < 40; i++) {
          if (container.read(audioPlaybackProvider).cover is MemoryAudioCover) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }

        // 1. 验证全部极速纯音频前置参数已精确写入 libmpv
        expect(fakeClient.options['vid'], 'no');
        expect(fakeClient.options['video'], 'no');
        expect(fakeClient.options['audio-display'], 'no');
        expect(fakeClient.options['cover-art-auto'], 'no');
        expect(fakeClient.options['sub-auto'], 'no');
        expect(fakeClient.options['audio-file-auto'], 'no');
        expect(fakeClient.options['cache-pause'], 'no');

        // 2. 验证尾轨初值为 Duration.zero；一旦母文件 duration=540s 到达，尾轨立即回填为 180s
        expect(container.read(audioPlaybackProvider).queue.length, 3);
        expect(
          container.read(audioPlaybackProvider).queue[2].duration,
          Duration.zero,
        );
        expect(container.read(audioPlaybackProvider).cover, isA<MemoryAudioCover>());
        expect(
          recordedCovers.whereType<ManagedPosterAudioCover>(),
          isEmpty,
        );

        fakeClient.emitDuration(540.0);
        await Future<void>.delayed(Duration.zero);
        expect(
          container.read(audioPlaybackProvider).queue[2].duration,
          const Duration(seconds: 180),
        );

        // 3. 同母文件自然跨过第 1 轨 endOffset(180s)：原子切入第 2 轨且 0 seek / 0 loadfile，封面 0 闪烁
        final loadCountBeforeRollover =
            fakeClient.commands.where((c) => c.first == 'loadfile').length;
        final seekCountBeforeRollover =
            fakeClient.commands.where((c) => c.first == 'seek').length;
        expect(loadCountBeforeRollover, 1);
        expect(seekCountBeforeRollover, 0);

        recordedCovers.clear();
        fakeClient.emitTimePos(180.05);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final afterRollover = container.read(audioPlaybackProvider);
        expect(afterRollover.currentIndex, 1);
        expect(afterRollover.positionSeconds, closeTo(0.05, 0.01));
        expect(afterRollover.durationSeconds, closeTo(180.0, 0.01));
        expect(
          fakeClient.commands.where((c) => c.first == 'loadfile').length,
          1,
        );
        expect(fakeClient.commands.where((c) => c.first == 'seek').length, 0);
        expect(recordedCovers.whereType<ManagedPosterAudioCover>(), isEmpty);

        // 4. 手动点选尾轨 Track 3：仅下发高精度 seek(360.000 absolute exact)，不重发 loadfile，显示 180s
        await notifier.playQueueIndex(2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(container.read(audioPlaybackProvider).currentIndex, 2);
        expect(container.read(audioPlaybackProvider).durationSeconds, 180.0);
        expect(
          fakeClient.commands.where((c) => c.first == 'loadfile').length,
          1,
        );
        expect(fakeClient.commands.last, ['seek', '360.000', 'absolute', 'exact']);

        // 5. 手动跳回 Track 1 后紧随旧分轨残余 time-pos=365.0：防抖吞掉旧时间戳，不误回跳 Track 2
        await notifier.playQueueIndex(0);
        fakeClient.emitTimePos(365.0);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(audioPlaybackProvider).currentIndex, 0);

        fakeClient.emitTimePos(1.2);
        await Future<void>.delayed(Duration.zero);
        expect(container.read(audioPlaybackProvider).currentIndex, 0);
        expect(container.read(audioPlaybackProvider).positionSeconds, closeTo(1.2, 0.01));

        // 6. 切入无任何专属封面的目录：先经历 EmptyAudioCover，仅异步探测确认缺失后才回退海报
        const vNoArt = MediaVariant(
          id: 'v-no-art',
          workId: 'w-bocchi',
          sourceId: 'src-local',
          relativePath: 'AlbumNoArt/Solo.flac',
          fileName: 'Solo.flac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        );
        recordedCovers.clear();
        await notifier.playCdCollection(
          work: work,
          cdVariants: const [vNoArt],
          initialVariant: vNoArt,
          sourcesById: {'src-local': source},
        );
        // 首次启动未确认无封面之前绝不先闪海报，最终探测缺失后才回退 ManagedPosterAudioCover
        expect(recordedCovers.first, isA<EmptyAudioCover>());
        for (var i = 0; i < 40; i++) {
          if (container.read(audioPlaybackProvider).cover
              is ManagedPosterAudioCover) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(
          container.read(audioPlaybackProvider).cover,
          isA<ManagedPosterAudioCover>(),
        );
      },
    );

    testWidgets(
      'MiniAudioBar 严格限制跳转热区、点击 ☰ 弹出 OverlayPortal 曲目浮层且支持 Esc 与外部点击自动收起',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        const work = Work(id: 'w1', title: '孤独摇滚！');
        const variant = MediaVariant(
          id: 'v1',
          workId: 'w1',
          sourceId: 's1',
          relativePath: 'Album/Album.flac',
          fileName: 'Album.flac',
          fileSize: 2048,
          assetKind: AssetKind.cdAlbum,
        );
        final queue = [
          const AudioQueueItem(
            id: 'q1',
            work: work,
            variant: variant,
            title: 'Track One',
            performer: 'Artist A',
            albumTitle: 'Best Album',
            trackNumber: 1,
            cueStartSeconds: 0,
            cueEndSeconds: 180,
            duration: Duration(seconds: 180),
          ),
          const AudioQueueItem(
            id: 'q2',
            work: work,
            variant: variant,
            title: 'Track Two',
            performer: 'Artist A',
            albumTitle: 'Best Album',
            trackNumber: 2,
            cueStartSeconds: 180,
            cueEndSeconds: 360,
            duration: Duration(seconds: 180),
          ),
          const AudioQueueItem(
            id: 'q3',
            work: work,
            variant: variant,
            title: 'Tail Track Three',
            performer: 'Artist B',
            albumTitle: 'Best Album',
            trackNumber: 3,
            cueStartSeconds: 360,
            cueEndSeconds: null,
            duration: Duration(seconds: 180),
          ),
        ];

        late _StubAudioNotifier stubNotifier;
        final container = ProviderContainer(
          overrides: [
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _sampleCoverPng,
            ),
            audioPlaybackProvider.overrideWith((ref) {
              stubNotifier = _StubAudioNotifier(
                ref,
                AudioPlaybackState(
                  isActive: true,
                  isPlaying: true,
                  queue: queue,
                  currentIndex: 0,
                  positionSeconds: 25.0,
                  durationSeconds: 180.0,
                  volume: 100.0,
                  audioCodecLabel: 'FLAC',
                  sampleRateAndBitDepthLabel: '16-bit · 44.1 kHz',
                  cover: MemoryAudioCover(_sampleCoverPng),
                ),
              );
              return stubNotifier;
            }),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: KonataTheme.lightTheme(),
              darkTheme: KonataTheme.darkTheme(),
              themeMode: ThemeMode.dark,
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 18),
                    child: MiniAudioBar(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // 1. 点击中区/右区按钮及间隙严禁触发全屏跳转
        await tester.tap(find.byIcon(Icons.pause_rounded));
        await tester.pump();
        expect(container.read(immersiveAudioExpandedProvider), isFalse);

        final prevBox = tester.getRect(find.byIcon(Icons.skip_previous_rounded));
        final playBox = tester.getRect(find.byIcon(Icons.play_arrow_rounded));
        await tester.tapAt(Offset((prevBox.right + playBox.left) / 2, playBox.center.dy));
        await tester.pump();
        expect(container.read(immersiveAudioExpandedProvider), isFalse);

        // 2. 点击 ☰ 不跳转全屏，且在正上方弹出曲目浮层、菜单按钮呈高亮激活态
        await tester.tap(find.byIcon(Icons.menu_rounded));
        await tester.pump(const Duration(milliseconds: 180));
        expect(container.read(immersiveAudioExpandedProvider), isFalse);
        expect(find.text('专辑曲目 (3)'), findsOneWidget);
        expect(find.text('Tail Track Three'), findsOneWidget);
        expect(find.text('03:00'), findsWidgets);

        final menuBtn = tester.widget<KonataCapsuleIconButton>(
          find.ancestor(
            of: find.byIcon(Icons.menu_rounded),
            matching: find.byType(KonataCapsuleIconButton),
          ),
        );
        expect(menuBtn.highlighted, isTrue);

        // 浮层正位于 MiniAudioBar 上方
        final capsuleTop = tester.getRect(find.byType(KonataPlaybackCapsule)).top;
        final popoverBottom = tester.getRect(find.text('Tail Track Three')).bottom;
        expect(popoverBottom, lessThan(capsuleTop));

        // 在浮层内点选尾轨立即切歌并保持菜单可控
        await tester.tap(find.text('Tail Track Three'));
        await tester.pump();
        expect(stubNotifier.playQueueIndexCalls, 1);
        expect(stubNotifier.lastPlayedIndex, 2);

        // 3. 按 Esc 自动收起曲目浮层
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.text('专辑曲目 (3)'), findsNothing);

        // 4. 再打开浮层后点击外部空白区自动收起
        await tester.tap(find.byIcon(Icons.menu_rounded));
        await tester.pump();
        expect(find.text('专辑曲目 (3)'), findsOneWidget);
        await tester.tapAt(const Offset(40, 40));
        await tester.pump();
        expect(find.text('专辑曲目 (3)'), findsNothing);

        // 5. 点击左侧信息区可展开沉浸页
        await tester.tap(find.text('Tail Track Three').first);
        await tester.pump();
        expect(container.read(immersiveAudioExpandedProvider), isTrue);

        // 复位后测试显式 ↗ 按钮亦可展开全屏页
        container.read(immersiveAudioExpandedProvider.notifier).state = false;
        await tester.pump();
        await tester.tap(find.byIcon(Icons.open_in_full_rounded));
        await tester.pump();
        expect(container.read(immersiveAudioExpandedProvider), isTrue);
      },
    );

    testWidgets(
      'ImmersiveAudioPage 独立「曲目列表 / 同步歌词」双图标、空歌词克制提示及 800px 窄屏 0 溢出',
      (tester) async {
        tester.view.physicalSize = const Size(800, 620);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        const work = Work(id: 'w1', title: '孤独摇滚！');
        const variant = MediaVariant(
          id: 'v1',
          workId: 'w1',
          sourceId: 's1',
          relativePath: 'Album/Album.flac',
          fileName: 'Album.flac',
          fileSize: 2048,
          assetKind: AssetKind.cdAlbum,
        );
        final queue = [
          const AudioQueueItem(
            id: 'q1',
            work: work,
            variant: variant,
            title: 'Very Long Track Name For Narrow 800px Viewport Ellipsis Verification',
            performer: 'Kessoku Band',
            albumTitle: 'Kessoku Band Complete',
            trackNumber: 1,
            cueStartSeconds: 0,
            cueEndSeconds: 180,
            duration: Duration(seconds: 180),
          ),
          const AudioQueueItem(
            id: 'q2',
            work: work,
            variant: variant,
            title: 'Tail Track With Backfilled Duration',
            performer: 'Kessoku Band',
            albumTitle: 'Kessoku Band Complete',
            trackNumber: 2,
            cueStartSeconds: 180,
            cueEndSeconds: null,
            duration: Duration(seconds: 180),
          ),
        ];

        await tester.pumpWidget(
          _wrapStage4App(
            const ImmersiveAudioPage(),
            overrides: [
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _sampleCoverPng,
              ),
              audioPlaybackProvider.overrideWith(
                (ref) => _StubAudioNotifier(
                  ref,
                  AudioPlaybackState(
                    isActive: true,
                    isPlaying: true,
                    queue: queue,
                    currentIndex: 0,
                    positionSeconds: 30.0,
                    durationSeconds: 180.0,
                    volume: 100.0,
                    audioCodecLabel: 'FLAC',
                    sampleRateAndBitDepthLabel: '24-bit · 96 kHz',
                    cover: MemoryAudioCover(_sampleCoverPng),
                    lrcDocument: null,
                  ),
                ),
              ),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(tester.takeException(), isNull);

        // 验证拆分出独立双图标，且旧版合并 menu_rounded 已移除
        expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
        expect(find.byIcon(Icons.lyrics_rounded), findsOneWidget);
        expect(find.byIcon(Icons.menu_rounded), findsNothing);

        // 音量组件仅保留精简动态喇叭图标，不再展示冗余数字文本
        expect(find.text('100'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(KonataVolumeControl),
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsOneWidget,
        );

        // 无歌词默认高亮曲目列表，且尾轨展示回填时长 03:00
        var queueBtn = tester.widget<KonataCapsuleIconButton>(
          find.ancestor(
            of: find.byIcon(Icons.queue_music_rounded),
            matching: find.byType(KonataCapsuleIconButton),
          ),
        );
        var lyricsBtn = tester.widget<KonataCapsuleIconButton>(
          find.ancestor(
            of: find.byIcon(Icons.lyrics_rounded),
            matching: find.byType(KonataCapsuleIconButton),
          ),
        );
        expect(queueBtn.highlighted, isTrue);
        expect(lyricsBtn.highlighted, isFalse);
        expect(find.text('Tail Track With Backfilled Duration'), findsOneWidget);
        expect(find.text('03:00'), findsWidgets);

        // 点击「同步歌词」切入清晰克制的空状态文案
        await tester.tap(find.byIcon(Icons.lyrics_rounded));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));

        expect(find.text('当前曲目暂无同步歌词'), findsOneWidget);
        queueBtn = tester.widget<KonataCapsuleIconButton>(
          find.ancestor(
            of: find.byIcon(Icons.queue_music_rounded),
            matching: find.byType(KonataCapsuleIconButton),
          ),
        );
        lyricsBtn = tester.widget<KonataCapsuleIconButton>(
          find.ancestor(
            of: find.byIcon(Icons.lyrics_rounded),
            matching: find.byType(KonataCapsuleIconButton),
          ),
        );
        expect(queueBtn.highlighted, isFalse);
        expect(lyricsBtn.highlighted, isTrue);

        // 点击「曲目列表」切回曲目列表
        await tester.tap(find.byIcon(Icons.queue_music_rounded));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        expect(find.text('Tail Track With Backfilled Duration'), findsOneWidget);
      },
    );
  });
}
