import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_dispatcher.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/composition/platform_composition.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/external_player_config.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/domain/repositories/external_player_launcher.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/desktop_external_player_store.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/players/mpv_quality_profile.dart';
import 'package:ccplayer/infrastructure/players/windows_desktop_relay_gateway.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';

class _SpyExternalLauncher implements ExternalPlayerLauncher {
  int callCount = 0;
  int stopExternalAudioCount = 0;
  ExternalPlayerConfig? lastPlayer;
  int? lastStartSeconds;
  double? lastExactStartSeconds;
  ExternalAudioAlbumRelayRequest? lastAlbumRequest;

  @override
  Future<LaunchPlaybackResult> launch({
    required Work work,
    required Episode episode,
    required MediaVariant variant,
    ExternalPlayerConfig? player,
    MediaSource? source,
    int startSeconds = 0,
    double? exactStartSeconds,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  }) async {
    callCount += 1;
    lastPlayer = player;
    lastStartSeconds = startSeconds;
    lastExactStartSeconds = exactStartSeconds;
    return const LaunchPlaybackResult(launched: true, message: '外部拉起成功');
  }

  @override
  Future<LaunchPlaybackResult> launchAudioAlbum({
    required ExternalAudioAlbumRelayRequest request,
    ExternalPlayerConfig? player,
    ExternalAudioProgressCallback? onTrackProgress,
  }) async {
    callCount += 1;
    lastPlayer = player;
    lastStartSeconds = request.startSeconds;
    lastExactStartSeconds = request.exactStartSeconds;
    lastAlbumRequest = request;
    return const LaunchPlaybackResult(launched: true, message: '外部专辑拉起成功');
  }

  @override
  Future<FoobarComponentStatusSnapshot> probeAudioPlayerStatus({
    required ExternalPlayerConfig? player,
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async {
    return FoobarComponentStatusSnapshot(
      state: FoobarComponentState.connected,
      executablePath: player?.executablePath ?? '',
      port: beefwebPort,
    );
  }

  @override
  Future<void> stopActiveExternalAudioSession({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async {
    stopExternalAudioCount += 1;
  }
}

class _FakeAudioClient implements LibMpvClient {
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  @override
  bool isInitialized = true;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 99;

  @override
  Stream<MpvClientEvent> get events => _events.stream;

  @override
  String errorString(int code) => 'ok';

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
  int setPropertyDouble(String name, double value) => 0;

  @override
  String? getPropertyString(String name) => null;

  @override
  bool? getPropertyFlag(String name) => null;

  @override
  int? getPropertyInt64(String name) => null;

  @override
  double? getPropertyDouble(String name) => null;

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
  int command(List<String> args) => 0;

  @override
  int commandAsync(int replyUserdata, List<String> args) => 0;

  @override
  Future<void> dispose() async {
    isDisposed = true;
    await _events.close();
  }
}

void main() {
  group('EmbeddedSessionMutex FIFO 串行互斥与故障恢复测试', () {
    test('并发请求按严格 FIFO 串行执行且异常不会死锁后续队列', () async {
      final mutex = EmbeddedSessionMutex();
      final order = <String>[];

      final f1 = mutex.runExclusive(() async {
        order.add('start-1');
        await Future<void>.delayed(const Duration(milliseconds: 25));
        order.add('end-1');
      });
      final f2 = mutex.runExclusive(() async {
        order.add('start-2-fail');
        throw StateError('simulated error');
      });
      final f3 = mutex.runExclusive(() async {
        order.add('start-3');
        return 42;
      });

      await f1;
      await expectLater(f2, throwsStateError);
      expect(await f3, equals(42));
      expect(order, equals(['start-1', 'end-1', 'start-2-fail', 'start-3']));
    });
  });

  group('PlaybackDispatcher 统一引擎路由与降级测试', () {
    late Directory tempRoot;
    late KonataDatabase db;
    late DriftLibraryRepository repo;
    late _SpyExternalLauncher spyLauncher;

    const work = Work(
      id: 'w1',
      title: '葬送的芙莉莲',
    );
    const ep1 = Episode(
      id: 'ep1',
      workId: 'w1',
      seasonNumber: 1,
      episodeNumber: 1,
      title: '冒险的终点',
    );
    const videoVar = MediaVariant(
      id: 'v1',
      workId: 'w1',
      episodeId: 'ep1',
      sourceId: 's1',
      relativePath: '01.mkv',
      fileName: '01.mkv',
      fileSize: 1024,
    );
    const cdVar = MediaVariant(
      id: 'cd1',
      workId: 'w1',
      episodeId: 'cd_ep',
      sourceId: 's1',
      assetKind: AssetKind.cdAlbum,
      relativePath: 'CD/track01.flac',
      fileName: 'track01.flac',
      fileSize: 2048,
    );
    const source = MediaSource(
      id: 's1',
      kind: MediaSourceKind.local,
      label: '本地',
      location: 'C:/does_not_exist_for_unit_test',
    );
    final bundle = WorkDetailBundle(
      work: work,
      episodes: const [ep1],
      variants: const [videoVar, cdVar],
      latestPlayback: null,
      playbackByEpisodeId: const {},
      sourcesById: const {'s1': source},
    );

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('konata_disp_test_');
      db = KonataDatabase(NativeDatabase.memory());
      repo = DriftLibraryRepository(db);
      spyLauncher = _SpyExternalLauncher();
      await repo.upsertMediaSource(source);
      await repo.upsertWork(work);
      await repo.upsertEpisode(ep1);
      await repo.upsertMediaVariant(videoVar);
    });

    tearDown(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    ProviderContainer createContainer({required bool runtimeAvailable}) {
      return ProviderContainer(
        overrides: [
          storageRootProvider.overrideWithValue(
            StorageRootService(overrideRoot: tempRoot),
          ),
          libraryRepositoryProvider.overrideWithValue(repo),
          desktopRelayGatewayProvider.overrideWithValue(
            WindowsDesktopRelayGateway(
              store: DesktopExternalPlayerStore(db),
              launcher: spyLauncher,
            ),
          ),
          playbackPreferencesProvider.overrideWith(
            (_) => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          mpvRuntimeVersionsProvider.overrideWith(
            (_) async => MpvRuntimeVersions(
              isAvailable: runtimeAvailable,
              mpvVersion: runtimeAvailable ? 'mpv 0.42.0' : '',
              ffmpegVersion: runtimeAvailable ? '9.0.2' : '',
            ),
          ),
          audioPlaybackProvider.overrideWith(
            (ref) => AudioPlaybackNotifier(
              ref,
              clientFactory: () => _FakeAudioClient(),
            ),
          ),
        ],
      );
    }

    test('默认内置且运行时可用时返回 OpenBuiltinVideoDecision', () async {
      final container = createContainer(runtimeAvailable: true);
      addTearDown(container.dispose);

      final decision = await container
          .read(playbackDispatcherProvider)
          .dispatchVideoVariant(
            bundle: bundle,
            episode: ep1,
            variant: videoVar,
            startSeconds: 120,
          );

      expect(decision, isA<OpenBuiltinVideoDecision>());
      final builtin = decision as OpenBuiltinVideoDecision;
      expect(builtin.request.startSeconds, equals(120));
      expect(spyLauncher.callCount, equals(0));
    });

    test('内置运行时未就绪时自动回退至外部播放器并携带降级说明', () async {
      final container = createContainer(runtimeAvailable: false);
      addTearDown(container.dispose);

      final decision = await container
          .read(playbackDispatcherProvider)
          .dispatchVideoVariant(
            bundle: bundle,
            episode: ep1,
            variant: videoVar,
            startSeconds: 45,
          );

      expect(decision, isA<LaunchedExternalVideoDecision>());
      final ext = decision as LaunchedExternalVideoDecision;
      expect(ext.result.launched, isTrue);
      expect(ext.result.message, contains('自动回退外部播放器'));
      expect(spyLauncher.callCount, equals(1));
      expect(spyLauncher.lastStartSeconds, equals(45));
    });

    test('单次显式指定外部播放器或覆写偏好时直出外部播放器', () async {
      final container = createContainer(runtimeAvailable: true);
      addTearDown(container.dispose);

      const customExt = ExternalPlayerConfig(
        id: 'pot',
        name: 'PotPlayer',
        kind: ExternalPlayerKind.potplayer,
        executablePath: r'C:\PotPlayerMini64.exe',
      );
      await DesktopExternalPlayerStore(db).upsertExternalPlayer(customExt);
      final decision = await container
          .read(playbackDispatcherProvider)
          .dispatchVideoVariant(
            bundle: bundle,
            episode: ep1,
            variant: videoVar,
            explicitTargetId: customExt.id,
          );

      expect(decision, isA<LaunchedExternalVideoDecision>());
      expect(spyLauncher.lastPlayer?.id, equals('pot'));
      expect(spyLauncher.callCount, equals(1));
    });

    test('CD 分发支持指定内置流光全屏与外置播放路由', () async {
      final container = createContainer(runtimeAvailable: true);
      addTearDown(container.dispose);

      await container.read(playbackDispatcherProvider).playCdVariant(
        work: work,
        variant: cdVar,
        cdPlaylist: const [cdVar],
        sourcesById: const {'s1': source},
        expandImmersive: true,
      );
      expect(container.read(immersiveAudioExpandedProvider), isTrue);

      await container.read(playbackDispatcherProvider).playCdVariant(
        work: work,
        variant: cdVar,
        cdPlaylist: const [cdVar],
        sourcesById: const {'s1': source},
        overrideEngine: PreferredPlaybackEngine.desktopRelay,
      );
      expect(spyLauncher.callCount, equals(1));
    });

    test('整轨音频变体拉起外部播放器时自动配对同目录 CUE 展开多曲目并继承子轨断点', () async {
      final container = createContainer(runtimeAvailable: true);
      addTearDown(container.dispose);

      final cdDir = Directory('${tempRoot.path}/DramaCD');
      await cdDir.create(recursive: true);
      final flacFile = File('${cdDir.path}/drama1.flac');
      await flacFile.writeAsBytes(const <int>[1, 2, 3, 4]);
      final cueFile = File('${cdDir.path}/drama1.cue');
      await cueFile.writeAsString('''
PERFORMER "川原礫"
TITLE "ドラマCD-1"
FILE "drama1.wav" WAVE
  TRACK 01 AUDIO
    TITLE "キリトの受難"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "ハルユキの災難"
    INDEX 01 27:55:00
''');

      final localSource = MediaSource(
        id: 's_local_cd',
        kind: MediaSourceKind.local,
        label: '本地抓轨',
        location: tempRoot.path,
      );
      final cueBytesLen = await cueFile.length();
      const flacVar = MediaVariant(
        id: 'v_drama_flac',
        workId: 'w1',
        sourceId: 's_local_cd',
        assetKind: AssetKind.cdAlbum,
        relativePath: 'DramaCD/drama1.flac',
        fileName: 'drama1.flac',
        fileSize: 4,
      );
      final cueVar = MediaVariant(
        id: 'v_drama_cue',
        workId: 'w1',
        sourceId: 's_local_cd',
        assetKind: AssetKind.cdAlbum,
        relativePath: 'DramaCD/drama1.cue',
        fileName: 'drama1.cue',
        fileSize: cueBytesLen,
      );
      await repo.upsertMediaSource(localSource);
      await repo.upsertMediaVariant(flacVar);
      await repo.upsertMediaVariant(cueVar);

      // 预先写入第 1 轨听到 10 秒（共 1675 秒 = 27:55）的历史记录。
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'cd::v_drama_cue::track_1',
          workId: 'w1',
          episodeId: 'cd::v_drama_cue::track_1',
          variantId: 'v_drama_flac',
          seasonNumber: 0,
          episodeNumber: 1,
          episodeTitle: 'キリトの受難',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 20, 16, 0),
          positionSeconds: 10,
          durationSeconds: 1675,
          isCompleted: false,
        ),
      );

      // 即便详情页传入的是过滤掉 `.cue` 后的 `.flac` 变体，也必须自动配对拆出 2 首曲目并继承 10 秒断点。
      final res = await container.read(playbackDispatcherProvider).playCdVariant(
        work: work,
        variant: flacVar,
        cdPlaylist: [flacVar, cueVar],
        sourcesById: {'s_local_cd': localSource},
        overrideEngine: PreferredPlaybackEngine.desktopRelay,
      );

      expect(res.launched, isTrue);
      final req = spyLauncher.lastAlbumRequest;
      expect(req, isNotNull);
      expect(req!.tracks.length, equals(2));
      expect(req.tracks[0].title, equals('キリトの受難'));
      expect(req.tracks[1].title, equals('ハルユキの災難'));
      expect(req.initialTrackIndex, equals(0));
      expect(req.startSeconds, equals(10));

      // 当第 1 轨已听完后再次从详情页点击整轨卡片，自动推进到第 2 轨从 0 秒起播。
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'cd::v_drama_cue::track_1',
          workId: 'w1',
          episodeId: 'cd::v_drama_cue::track_1',
          variantId: 'v_drama_flac',
          seasonNumber: 0,
          episodeNumber: 1,
          episodeTitle: 'キリトの受難',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 20, 16, 30),
          positionSeconds: 1675,
          durationSeconds: 1675,
          isCompleted: true,
        ),
      );

      await container.read(playbackDispatcherProvider).playCdVariant(
        work: work,
        variant: flacVar,
        cdPlaylist: [flacVar, cueVar],
        sourcesById: {'s_local_cd': localSource},
        overrideEngine: PreferredPlaybackEngine.desktopRelay,
      );
      expect(spyLauncher.lastAlbumRequest!.initialTrackIndex, equals(1));
      expect(spyLauncher.lastAlbumRequest!.startSeconds, equals(0));

      // 切回内置视频播放时，自动通知外部接力网关停止活跃音频会话释放独占声卡。
      await container.read(playbackDispatcherProvider).dispatchVideoVariant(
        bundle: bundle,
        episode: ep1,
        variant: videoVar,
      );
      expect(spyLauncher.stopExternalAudioCount, greaterThanOrEqualTo(1));
    });
  });
}
