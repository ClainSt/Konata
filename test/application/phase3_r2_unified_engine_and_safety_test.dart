import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/audiophile_safety_coordinator.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/application/playback/subtitle_memory_engine.dart';
import 'package:ccplayer/application/playback/unified_playback_engine.dart';
import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/playback_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/domain/playback/subtitle_content_processor.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/domain/repositories/file_system_gateway.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/embedded_mpv_session.dart';
import 'package:ccplayer/infrastructure/players/libmpv_ffi.dart';
import 'package:ccplayer/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:ccplayer/infrastructure/sources/source_gateway_factory.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/infrastructure/stream_bridge/local_stream_bridge.dart';

/// 面向批次 R2 核心回归测试的模拟 `libmpv` 客户端（完整追踪命令、属性、音频设备列表与事件分发）。
class _R2FakeMpvClient implements LibMpvClient {
  _R2FakeMpvClient();

  bool failSubsequentLoads = false;
  final List<List<String>> commands = <List<String>>[];
  final List<double> volumeHistory = <double>[];
  final Map<String, String> stringProps = <String, String>{};
  final Map<String, double> doubleProps = <String, double>{
    'time-pos': 10.0,
    'duration': 1420.0,
  };
  final Map<String, bool> flagProps = <String, bool>{'pause': false};
  final Map<String, int> intProps = <String, int>{};
  final List<MpvTrackInfo> tracks = <MpvTrackInfo>[];
  List<MpvAudioDevice> audioDevices = const <MpvAudioDevice>[
    MpvAudioDevice(name: 'auto', description: '自动'),
    MpvAudioDevice(name: 'wasapi/{dac-usb-1}', description: 'USB DAC'),
  ];
  final StreamController<MpvClientEvent> _events =
      StreamController<MpvClientEvent>.broadcast();

  int _nextPlaylistEntryId = 1;
  int _nextTrackId = 20;

  @override
  bool isInitialized = false;

  @override
  bool isDisposed = false;

  @override
  int get handleAddress => 9001;

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
      final mode = args.length >= 3 ? args[2] : 'replace';
      if (mode == 'replace') {
        final entryId = _nextPlaylistEntryId++;
        intProps['playlist-entry-id'] = entryId;
        scheduleMicrotask(() {
          emitEvent(MpvStartFileEvent(entryId));
          if (failSubsequentLoads) {
            emitEvent(
              MpvEndFileEvent(
                reason: MpvEndFileReason.error,
                errorCode: MpvError.loadingFailed,
                playlistEntryId: entryId,
              ),
            );
          } else {
            emitEvent(const MpvFileLoadedEvent());
            emitEvent(const MpvPlaybackRestartEvent());
          }
        });
      }
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
  List<MpvAudioDevice> readAudioDeviceList() =>
      List<MpvAudioDevice>.of(audioDevices);

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
    return 0;
  }

  @override
  int setPropertyString(String name, String value) {
    stringProps[name] = value;
    return 0;
  }
}

/// 面向远程音频预取流租约验证的轻量内存只读网关。
class _FakeRemoteAudioGateway
    implements MediaSourceGateway, ByteRangeReadableGateway {
  _FakeRemoteAudioGateway(this.files);

  final Map<String, List<int>> files;
  bool closed = false;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async =>
      const [];

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<int?> probeFileLength(String relativePath) async =>
      files[relativePath]?.length;

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final data = files[relativePath] ?? const <int>[];
    final clampedStart = start.clamp(0, data.length);
    final clampedEnd = endInclusive == null
        ? data.length
        : (endInclusive + 1).clamp(clampedStart, data.length);
    return Stream<List<int>>.value(data.sublist(clampedStart, clampedEnd));
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeGatewayFactory extends MediaSourceGatewayFactory {
  const _FakeGatewayFactory(this.gateway);

  final _FakeRemoteAudioGateway gateway;

  @override
  Future<MediaSourceGateway> create(
    MediaSource source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async {
    return gateway;
  }
}

Future<void> _pumpUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('批次 R2：UnifiedPlaybackEngine 真实收口与音视频共享发烧音频安全链', () {
    test(
      'VideoPlaybackController.switchToEpisode 递增物理代数、重置内存字幕缓存，并接入连续 3 次坏文件熔断器',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('konata_r2_vid_');
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });

        final ep1File = File(p.join(tempDir.path, 'ep01.mkv'))
          ..writeAsBytesSync(const [0, 1, 2, 3]);
        final ep2File = File(p.join(tempDir.path, 'ep02.mkv'))
          ..writeAsBytesSync(const [0, 1, 2, 3]);
        final ep3File = File(p.join(tempDir.path, 'ep03.mkv'))
          ..writeAsBytesSync(const [0, 1, 2, 3]);
        final ep4File = File(p.join(tempDir.path, 'ep04.mkv'))
          ..writeAsBytesSync(const [0, 1, 2, 3]);
        final subFile = File(p.join(tempDir.path, 'shared_sub.ass'))
          ..writeAsStringSync(
            '[Script Info]\nTitle: Test\n[Events]\n'
            'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
            'Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,測試臺詞\n',
          );

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final storageRoot = StorageRootService(overrideRoot: tempDir);
        final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
        addTearDown(streamBridge.dispose);
        final fakeClient = _R2FakeMpvClient();

        final source = MediaSource(
          id: 'src_local',
          label: '本地源',
          kind: MediaSourceKind.local,
          location: tempDir.path,
        );
        const work = Work(id: 'w_r2_1', title: 'R2 测试动画');
        await repo.upsertWork(work);
        final episodes = <Episode>[
          for (var i = 1; i <= 4; i++)
            Episode(
              id: 'ep_$i',
              workId: work.id,
              category: EpisodeCategory.main,
              seasonNumber: 1,
              episodeNumber: i,
              title: '第 $i 集',
            ),
        ];
        final files = [ep1File, ep2File, ep3File, ep4File];
        final variants = <MediaVariant>[
          for (var i = 0; i < 4; i++)
            MediaVariant(
              id: 'var_${i + 1}',
              workId: work.id,
              episodeId: episodes[i].id,
              sourceId: source.id,
              relativePath: p.basename(files[i].path),
              fileName: p.basename(files[i].path),
              fileSize: 4,
            ),
        ];
        final bundle = WorkDetailBundle(
          work: work,
          episodes: episodes,
          variants: variants,
          sourcesById: {source.id: source},
          latestPlayback: null,
        );
        final request = VideoLaunchRequest(
          work: work,
          bundle: bundle,
          episode: episodes[0],
          variant: variants[0],
          source: source,
        );

        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            storageRootProvider.overrideWithValue(storageRoot),
            localStreamBridgeProvider.overrideWithValue(streamBridge),
            videoPlaybackProvider(request).overrideWith(
              (ref) => VideoPlaybackController(
                ref,
                request,
                sessionFactory: () => EmbeddedMpvSession(
                  storageRoot: storageRoot,
                  streamBridge: streamBridge,
                  clientFactory: () => fakeClient,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final engine = container.read(unifiedPlaybackEngineProvider);
        final sub = container.listen(
          videoPlaybackProvider(request),
          (_, _) {},
        );
        addTearDown(sub.close);
        final controller = container.read(
          videoPlaybackProvider(request).notifier,
        );

        await _pumpUntil(() => controller.state.hasFirstFrame);
        expect(controller.state.errorMessage, isNull);
        final epochAfterBoot = engine.physicalMediaEpoch;
        expect(epochAfterBoot, greaterThanOrEqualTo(1));

        // 1. 在第 1 集注入一次内存字幕，记录 sub-add 次数。
        final r1 = await controller.applyMemorySubtitleIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.memory(
              localFilePath: subFile.path,
              fileName: 'shared_sub.ass',
              displayTitle: '繁中',
              openCcMode: SubtitleOpenCcMode.toSimplified,
            ),
          ),
        );
        expect(r1.applied, isTrue);
        final subAddsAfterEp1 = fakeClient.commands
            .where((c) => c.isNotEmpty && c.first == 'sub-add')
            .length;
        expect(subAddsAfterEp1, equals(1));

        // 2. 切换至第 2 集：必须递增 physicalMediaEpoch，且内存字幕引擎重新注入（不沿用第 1 集过期缓存）。
        await controller.switchToEpisode(episodes[1], isAutoAdvance: false);
        await _pumpUntil(
          () =>
              controller.state.currentEpisode.id == 'ep_2' &&
              controller.state.hasFirstFrame,
        );
        expect(engine.physicalMediaEpoch, greaterThan(epochAfterBoot));

        final r2 = await controller.applyMemorySubtitleIntent(
          AuthoritativeSubtitleIntent(
            primary: SubtitleSlotRequest.memory(
              localFilePath: subFile.path,
              fileName: 'shared_sub.ass',
              displayTitle: '繁中',
              openCcMode: SubtitleOpenCcMode.toSimplified,
            ),
          ),
        );
        expect(r2.applied, isTrue);
        final subAddsAfterEp2 = fakeClient.commands
            .where((c) => c.isNotEmpty && c.first == 'sub-add')
            .length;
        expect(subAddsAfterEp2, equals(2));

        // 3. 连续 3 个物理坏文件触发自动跳集失败链：熔断器必须跳闸并停止无限跳集。
        fakeClient.failSubsequentLoads = true;
        final currentEntryId = fakeClient.intProps['playlist-entry-id'] ?? 1;
        fakeClient.emitEvent(
          MpvEndFileEvent(
            reason: MpvEndFileReason.error,
            errorCode: MpvError.loadingFailed,
            playlistEntryId: currentEntryId,
          ),
        );
        await _pumpUntil(() => engine.isCircuitBreakerTripped);
        expect(engine.consecutiveBadFiles, equals(3));
        expect(engine.isCircuitBreakerTripped, isTrue);
        expect(controller.state.errorMessage, contains('熔断'));

        // 4. 恢复文件可读后，用户手动点选目标集应重置熔断计数并恢复可播状态。
        fakeClient.failSubsequentLoads = false;
        await controller.switchToEpisode(episodes[2], isAutoAdvance: false);
        await _pumpUntil(
          () =>
              controller.state.currentEpisode.id == 'ep_3' &&
              controller.state.hasFirstFrame,
        );
        expect(engine.consecutiveBadFiles, equals(0));
        expect(engine.isCircuitBreakerTripped, isFalse);

        await controller.closeAndRelease();
      },
    );

    test(
      '音视频共享 AudiophileSafetyCoordinator：视频端同步生效 -12 dBFS、HDMI 互斥旁路、微淡入斜坡、Windows 热插拔瞬态静音与二次满幅确认闭环',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        final tempDir = await Directory.systemTemp.createTemp(
          'konata_r2_safe_',
        );
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });

        File(
          p.join(tempDir.path, 'movie.mkv'),
        ).writeAsBytesSync(const [0, 1, 2, 3]);
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final storageRoot = StorageRootService(overrideRoot: tempDir);
        final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
        addTearDown(streamBridge.dispose);
        final fakeClient = _R2FakeMpvClient();

        final source = MediaSource(
          id: 'src_safe',
          label: '本地源',
          kind: MediaSourceKind.local,
          location: tempDir.path,
        );
        const work = Work(id: 'w_safe', title: '音频安全测试作品');
        await repo.upsertWork(work);
        const ep = Episode(
          id: 'ep_safe',
          workId: 'w_safe',
          category: EpisodeCategory.main,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '剧场版',
        );
        const variant = MediaVariant(
          id: 'var_safe',
          workId: 'w_safe',
          episodeId: 'ep_safe',
          sourceId: 'src_safe',
          relativePath: 'movie.mkv',
          fileName: 'movie.mkv',
          fileSize: 4,
        );
        final request = VideoLaunchRequest(
          work: work,
          bundle: WorkDetailBundle(
            work: work,
            episodes: const [ep],
            variants: const [variant],
            sourcesById: {source.id: source},
            latestPlayback: null,
          ),
          episode: ep,
          variant: variant,
          source: source,
        );

        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            storageRootProvider.overrideWithValue(storageRoot),
            localStreamBridgeProvider.overrideWithValue(streamBridge),
            videoPlaybackProvider(request).overrideWith(
              (ref) => VideoPlaybackController(
                ref,
                request,
                sessionFactory: () => EmbeddedMpvSession(
                  storageRoot: storageRoot,
                  streamBridge: streamBridge,
                  clientFactory: () => fakeClient,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final coordinator = container.read(audiophileSafetyCoordinatorProvider);
        final sub = container.listen(
          videoPlaybackProvider(request),
          (_, _) {},
        );
        addTearDown(sub.close);
        final controller = container.read(
          videoPlaybackProvider(request).notifier,
        );

        await _pumpUntil(() => controller.state.hasFirstFrame);
        // 等待 150ms S 型微淡入斜坡完成并停钟。
        await Future<void>.delayed(const Duration(milliseconds: 240));

        // 1. 默认共享路径：视频引擎必须收到末级 -12 dBFS 安全限幅，且微淡入斜坡单调抬升后停钟。
        expect(fakeClient.stringProps['af'], contains('alimiter'));
        expect(fakeClient.volumeHistory.length, greaterThanOrEqualTo(2));
        expect(
          fakeClient.volumeHistory.first,
          lessThan(fakeClient.volumeHistory.last),
        );

        // 2. 开启 HDMI audio-spdif 互斥旁路：视频端立即写入 audio-spdif 并清空软 DSP 滤镜 af。
        await container
            .read(playbackPreferencesProvider.notifier)
            .setBitstreamPassthrough(true);
        await coordinator.reapplyAll(
          container.read(playbackPreferencesProvider),
        );
        expect(fakeClient.stringProps['audio-spdif'], isNotEmpty);
        expect(fakeClient.stringProps['af'], equals(''));

        // 关闭 HDMI 旁路并开启独占直通以验证满幅二次确认门锁。
        await container
            .read(playbackPreferencesProvider.notifier)
            .setBitstreamPassthrough(false);
        await container
            .read(playbackPreferencesProvider.notifier)
            .updateQualityConfig((c) => c.copyWith(exclusiveAudioOutput: true));
        await coordinator.reapplyAll(
          container.read(playbackPreferencesProvider),
        );
        expect(fakeClient.stringProps['af'], contains('alimiter'));

        // 未完成物理硬件电平仪实证时，当次会话确认必须拒绝解锁。
        final blocked = await coordinator.confirmSessionFullScaleUnlock(
          container.read(playbackPreferencesProvider),
        );
        expect(blocked, isFalse);
        expect(fakeClient.stringProps['af'], contains('alimiter'));

        // 模拟物理硬件电平仪实证通过后再执行二次确认：应成功解锁本次会话满幅直通。
        coordinator.setBackendMeterVerified(
          true,
          deviceFingerprint: 'wasapi/{dac-usb-1}',
        );
        final unlocked = await coordinator.confirmSessionFullScaleUnlock(
          container.read(playbackPreferencesProvider),
        );
        expect(unlocked, isTrue);
        expect(
          coordinator.deviceSafetyState.sessionFullScaleUnlocked,
          isTrue,
        );
        expect(fakeClient.stringProps['af'], equals(''));

        // 3. Windows 外设热拔出：先建立基线，再移除 USB DAC -> 视频端必须瞬态静音并复位满幅确认与安全限幅。
        coordinator.handleWindowsAudioDevicesChanged(
          devices: fakeClient.audioDevices,
          currentAudioDevice: 'wasapi/{dac-usb-1}',
        );
        fakeClient.audioDevices = const <MpvAudioDevice>[
          MpvAudioDevice(name: 'auto', description: '自动'),
        ];
        fakeClient.stringProps['audio-device'] = 'auto';
        fakeClient.emitEvent(
          const MpvPropertyChangeEvent(
            replyUserdata: 212,
            name: 'audio-device-list',
            format: MpvFormat.none,
          ),
        );
        await _pumpUntil(() => fakeClient.flagProps['mute'] == true);
        expect(fakeClient.flagProps['mute'], isTrue);
        expect(
          coordinator.deviceSafetyState.sessionFullScaleUnlocked,
          isFalse,
        );
        expect(fakeClient.stringProps['af'], contains('alimiter'));

        await controller.closeAndRelease();
      },
    );

    test(
      'AudioPlaybackNotifier 远程无缝预取流租约提升、旧租约及时注销、loopOne 释放预取及过期 playlistEntryId 事件过滤',
      () async {
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final streamBridge = LocalStreamBridge();
        addTearDown(streamBridge.dispose);
        final fakeClient = _R2FakeMpvClient();
        final fakeGateway = _FakeRemoteAudioGateway({
          'CD/01.flac': List<int>.filled(64, 1),
          'CD/02.flac': List<int>.filled(64, 2),
        });

        final source = MediaSource(
          id: 'src_webdav',
          label: '远端音乐',
          kind: MediaSourceKind.webdav,
          location: 'https://example.invalid/dav',
        );
        const work = Work(id: 'w_cd', title: '原声集');
        const v1 = MediaVariant(
          id: 'cd_1',
          workId: 'w_cd',
          episodeId: 'ep_cd',
          sourceId: 'src_webdav',
          relativePath: 'CD/01.flac',
          fileName: '01.flac',
          fileSize: 64,
        );
        const v2 = MediaVariant(
          id: 'cd_2',
          workId: 'w_cd',
          episodeId: 'ep_cd',
          sourceId: 'src_webdav',
          relativePath: 'CD/02.flac',
          fileName: '02.flac',
          fileSize: 64,
        );

        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            localStreamBridgeProvider.overrideWithValue(streamBridge),
            audioPlaybackProvider.overrideWith(
              (ref) => AudioPlaybackNotifier(
                ref,
                clientFactory: () => fakeClient,
                gatewayFactory: _FakeGatewayFactory(fakeGateway),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final engine = container.read(unifiedPlaybackEngineProvider);
        final notifier = container.read(audioPlaybackProvider.notifier);

        await notifier.playCdCollection(
          work: work,
          cdVariants: const [v1, v2],
          initialVariant: v1,
          sourcesById: {source.id: source},
        );
        await _pumpUntil(
          () =>
              engine.mainStreamLease?.leaseToken != null &&
              engine.prefetchStreamLease?.leaseToken != null,
        );

        final mainToken1 = engine.mainStreamLease!.leaseToken;
        final prefetchToken2 = engine.prefetchStreamLease!.leaseToken;
        expect(mainToken1, isNot(equals(prefetchToken2)));
        expect(streamBridge.activeSessionCount, equals(2));

        // 1. 注入过期 playlistEntryId 的 EOF 事件：必须被 UnifiedPlaybackEngine 静默拦截，不误切曲目。
        fakeClient.emitEvent(
          const MpvEndFileEvent(
            reason: MpvEndFileReason.eof,
            errorCode: 0,
            playlistEntryId: 99999,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(notifier.state.currentIndex, equals(0));
        expect(engine.mainStreamLease?.leaseToken, equals(mainToken1));

        // 2. 注入当前有效 playlistEntryId 的自然 EOF：应命中预取租约并原子晋升为主租约，同时注销旧租约。
        final activeEntryId = fakeClient.intProps['playlist-entry-id'] ?? 1;
        fakeClient.emitEvent(
          MpvEndFileEvent(
            reason: MpvEndFileReason.eof,
            errorCode: 0,
            playlistEntryId: activeEntryId,
          ),
        );
        await _pumpUntil(
          () =>
              notifier.state.currentIndex == 1 &&
              engine.mainStreamLease?.leaseToken == prefetchToken2,
        );
        // loopAll 模式下第 2 首起播后会自动为循环回到第 1 首创建新预取租约，但旧主流租约 mainToken1 必须已被注销（总会话数仍 <= 2）。
        expect(engine.mainStreamLease?.leaseToken, equals(prefetchToken2));
        expect(
          engine.prefetchStreamLease?.leaseToken,
          isNot(equals(mainToken1)),
        );
        expect(streamBridge.activeSessionCount, lessThanOrEqualTo(2));
        expect(
          fakeClient.commands.any(
            (c) =>
                c.length >= 2 &&
                c[0] == 'loadfile' &&
                c[1].contains(prefetchToken2),
          ),
          isTrue,
        );

        // 3. 重新回到第 1 首触发预取后切换为单曲循环（loopOne），应主动释放预取租约。
        await notifier.playQueueIndex(0);
        await _pumpUntil(() => engine.prefetchStreamLease != null);
        expect(streamBridge.activeSessionCount, equals(2));

        // 从列表循环切换为单曲循环模式，验证预取租约被主动释放。
        notifier.cycleLoopMode();
        expect(notifier.state.loopMode, equals(AudioLoopMode.loopOne));
        await _pumpUntil(() => engine.prefetchStreamLease == null);
        expect(streamBridge.activeSessionCount, equals(1));

        await notifier.stopAndClose();
        expect(streamBridge.activeSessionCount, equals(0));
      },
    );

    test(
      '播音频 -> 点播视频 -> 关闭视频 -> 恢复音频播至 EOF 自动原子重绑代数并切入下一首',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'konata_r3_av_epoch_',
        );
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });

        final track1File = File(p.join(tempDir.path, '01_track_one.flac'))
          ..writeAsBytesSync(const [1, 2, 3, 4]);
        final track2File = File(p.join(tempDir.path, '02_track_two.flac'))
          ..writeAsBytesSync(const [5, 6, 7, 8]);
        final videoFile = File(p.join(tempDir.path, 'ep01.mkv'))
          ..writeAsBytesSync(const [9, 10, 11, 12]);

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final storageRoot = StorageRootService(overrideRoot: tempDir);
        final streamBridge = LocalStreamBridge(storageRoot: storageRoot);
        addTearDown(streamBridge.dispose);

        final audioClient = _R2FakeMpvClient();
        final videoClient = _R2FakeMpvClient();
        final source = MediaSource(
          id: 'src_av_epoch',
          label: 'LocalAV',
          kind: MediaSourceKind.local,
          location: tempDir.path,
        );
        const work = Work(id: 'w_av_epoch', title: 'AV Epoch Regression');
        await repo.upsertWork(work);
        final vTrack1 = MediaVariant(
          id: 'cd_1',
          workId: work.id,
          sourceId: source.id,
          relativePath: p.basename(track1File.path),
          fileName: p.basename(track1File.path),
          fileSize: 4,
        );
        final vTrack2 = MediaVariant(
          id: 'cd_2',
          workId: work.id,
          sourceId: source.id,
          relativePath: p.basename(track2File.path),
          fileName: p.basename(track2File.path),
          fileSize: 4,
        );
        final ep1 = Episode(
          id: 'ep_1',
          workId: work.id,
          category: EpisodeCategory.main,
          seasonNumber: 1,
          episodeNumber: 1,
          title: '第 1 话',
        );
        final vVideo = MediaVariant(
          id: 'vid_1',
          workId: work.id,
          episodeId: ep1.id,
          sourceId: source.id,
          relativePath: p.basename(videoFile.path),
          fileName: p.basename(videoFile.path),
          fileSize: 4,
        );

        final videoReq = VideoLaunchRequest(
          work: work,
          episode: ep1,
          variant: vVideo,
          source: source,
          bundle: WorkDetailBundle(
            work: work,
            episodes: [ep1],
            variants: [vVideo],
            sourcesById: {source.id: source},
            latestPlayback: null,
          ),
        );

        final container = ProviderContainer(
          overrides: [
            storageRootProvider.overrideWithValue(storageRoot),
            localStreamBridgeProvider.overrideWithValue(streamBridge),
            libraryRepositoryProvider.overrideWithValue(repo),
            audioPlaybackProvider.overrideWith(
              (ref) => AudioPlaybackNotifier(
                ref,
                clientFactory: () => audioClient,
                microFadeStepInterval: const Duration(milliseconds: 5),
              ),
            ),
            videoPlaybackProvider(videoReq).overrideWith(
              (ref) => VideoPlaybackController(
                ref,
                videoReq,
                sessionFactory: () => EmbeddedMpvSession(
                  storageRoot: storageRoot,
                  streamBridge: streamBridge,
                  clientFactory: () => videoClient,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final engine = container.read(unifiedPlaybackEngineProvider);
        final audio = container.read(audioPlaybackProvider.notifier);

        // 1. 起播第 1 首音频（epoch=1, instance=1）。
        await audio.playCdCollection(
          work: work,
          cdVariants: [vTrack1, vTrack2],
          initialVariant: vTrack1,
          sourcesById: {source.id: source},
        );
        await _pumpUntil(() => audio.state.isPlaying);
        expect(audio.state.currentIndex, equals(0));
        expect(engine.activeStage, equals(PlaybackStageKind.audio));
        final audioEntryId = audioClient.intProps['playlist-entry-id'] ?? 1;

        // 2. 点播视频：触发视频激活通知暂停音频并推进共享内核代数至视频实例。
        container.read(videoPlaybackActiveProvider.notifier).state = true;
        await _pumpUntil(() => !audio.state.isPlaying);
        final videoSub = container.listen(
          videoPlaybackProvider(videoReq),
          (_, _) {},
        );
        final videoCtrl = container.read(
          videoPlaybackProvider(videoReq).notifier,
        );
        await _pumpUntil(() => !videoCtrl.state.isInitializing);
        expect(engine.activeStage, equals(PlaybackStageKind.video));

        // 3. 关闭视频会话：共享内核执行 resetSession(stage: video)，保留音频暂挂快照。
        await videoCtrl.closeAndRelease();
        videoSub.close();
        expect(container.read(videoPlaybackActiveProvider), isFalse);

        // 4. 恢复音频播放：仅调用 setPlaying(true) 必须原子重绑统一内核代数与 playlistEntryId。
        await audio.setPlaying(true);
        expect(audio.state.isPlaying, isTrue);
        expect(engine.activeStage, equals(PlaybackStageKind.audio));
        expect(engine.currentPlaylistEntryId, equals(audioEntryId));

        // 5. 音频播放至自然 EOF：绝不被陈旧代数拦截，必须自动切入第 2 首曲目。
        audioClient.emitEvent(
          MpvEndFileEvent(
            reason: MpvEndFileReason.eof,
            errorCode: 0,
            playlistEntryId: audioEntryId,
          ),
        );
        await _pumpUntil(() => audio.state.currentIndex == 1);
        expect(audio.state.currentIndex, equals(1));
        expect(audio.state.currentItem?.variant.id, equals(vTrack2.id));

        await audio.stopAndClose();
      },
    );
  });
}
