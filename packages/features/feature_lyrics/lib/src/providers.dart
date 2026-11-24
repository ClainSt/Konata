import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'data/amll_lyric_provider.dart';
import 'data/lrclib_lyric_provider.dart';
import 'data/lyric_cache_store.dart';
import 'data/lyric_candidate_sources.dart';
import 'data/lyric_http_transport.dart';
import 'data/lyric_overrides_sync_slice.dart';
import 'data/lyric_race_engine.dart';
import 'data/lyrics_preferences.dart';
import 'data/lyrics_resolver.dart';
import 'data/netease_lyric_provider.dart';
import 'data/qqmusic_lyric_provider.dart';
import 'state/lyric_display_controller.dart';

/// 宿主应用壳向 `feature_lyrics` 注入的显式依赖契约（仅限跨包基础设施与播放端口）。
@immutable
final class FeatureLyricsDependencies {
  /// 构造歌词模块运行期依赖集合。
  const FeatureLyricsDependencies({
    required this.databases,
    required this.scopedPrefs,
    required this.httpClient,
    this.diagnosticLog,
    this.domainEventBus,
    this.bangumiMusicTracksLoader,
    this.isMeteredNetwork,
    this.playbackEngine,
    this.positionListenable,
    this.isPlayingListenable,
    this.onSeekRequested,
    this.localDeviceId = '',
  });

  /// 三库 SQLite 组合（`cache.db` 保持惰性按需打开）。
  final KonataDatabaseBundle databases;

  /// 分命名空间偏好设置存储器。
  final ScopedPrefsStore scopedPrefs;

  /// 跨包统一网络客户端端口。
  final KonataHttpClientPort httpClient;

  /// 可选结构化脱敏诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  /// 可选低频领域事件总线（严禁用于逐字时钟推送）。
  final DomainEventBus? domainEventBus;

  /// 可选 Bangumi 关联音乐曲目表查询器覆盖回调。
  final Future<List<BangumiMusicTrack>> Function(int animeSubjectId)?
  bangumiMusicTracksLoader;

  /// 可选移动计量网络探测回调（决定队列预取数量）。
  final Future<bool> Function()? isMeteredNetwork;

  /// 可选统一播放协调内核（用于分域任务代数隔离）。
  final UnifiedPlaybackEngine? playbackEngine;

  /// 可选外部实时播放位置叶子监听句柄。
  final ValueListenable<Duration>? positionListenable;

  /// 可选外部播放暂停状态叶子监听句柄。
  final ValueListenable<bool>? isPlayingListenable;

  /// 可选歌词时间轴点选跳转回调。
  final void Function(double targetSeconds, {bool resumePlayback})?
  onSeekRequested;

  /// 本机设备标识（供用户覆盖记录与同步切片写入）。
  final String localDeviceId;
}

/// 歌词模块基础依赖注入槽位（必须在应用启动容器或测试容器中通过 `overrideWithValue` 覆盖）。
final featureLyricsDependenciesProvider = Provider<FeatureLyricsDependencies>((
  ref,
) {
  throw UnimplementedError(
    'featureLyricsDependenciesProvider 必须由应用组装根或测试容器显式覆盖',
  );
});

/// 歌词偏好设置存取器提供者（持久化于分命名空间 `lyrics`）。
final lyricsPreferencesStoreProvider = Provider<LyricsPreferencesStore>((ref) {
  final deps = ref.watch(featureLyricsDependenciesProvider);
  return LyricsPreferencesStore(
    deps.scopedPrefs,
    eventBus: deps.domainEventBus,
  );
});

/// 响应式歌词偏好设置快照流提供者。
final lyricsPreferencesProvider = StreamProvider<LyricsPreferences>((ref) async* {
  final store = ref.watch(lyricsPreferencesStoreProvider);
  yield store.read();
  yield* store.watch();
});

/// 歌词在线检索传输适配器提供者（复用全局网络客户端端口）。
final lyricHttpTransportProvider = Provider<LyricHttpTransport>((ref) {
  final deps = ref.watch(featureLyricsDependenciesProvider);
  return KonataHttpClientLyricTransport(deps.httpClient);
});

/// 歌词双库分离存储仓储提供者（保持 `cache.db` 惰性不提前打开）。
final lyricCacheStoreProvider = Provider<LyricCacheRepository>((ref) {
  final deps = ref.watch(featureLyricsDependenciesProvider);
  return StorageLyricCacheRepository.fromBundle(
    deps.databases,
    localDeviceId: deps.localDeviceId,
  );
});

/// Bangumi 关联音乐曲目表查询器提供者（弱文件名曲目补全）。
final bangumiMusicTracksLoaderProvider =
    Provider<Future<List<BangumiMusicTrack>> Function(int)>((ref) {
      final deps = ref.watch(featureLyricsDependenciesProvider);
      if (deps.bangumiMusicTracksLoader != null) {
        return deps.bangumiMusicTracksLoader!;
      }
      BangumiService? cachedService;
      return (subjectId) {
        final service = cachedService ??= BangumiService(
          httpClient: deps.httpClient,
        );
        return service.getRelatedMusicTracks(subjectId);
      };
    });

/// 在线与本地歌词解析器提供者（容器销毁时自动取消在途网络检索与预取）。
final lyricsResolverProvider = Provider<LyricsResolver>((ref) {
  final deps = ref.watch(featureLyricsDependenciesProvider);
  final prefsStore = ref.watch(lyricsPreferencesStoreProvider);
  final transport = ref.watch(lyricHttpTransportProvider);
  final cacheStore = ref.watch(lyricCacheStoreProvider);
  final bgmLoader = ref.watch(bangumiMusicTracksLoaderProvider);

  final resolver = LyricsResolver(
    playbackEngine: deps.playbackEngine,
    cacheRepository: cacheStore,
    isMeteredNetwork: deps.isMeteredNetwork,
    bangumiMusicTracksLoader: bgmLoader,
    logPort: deps.diagnosticLog,
    raceEngine: LyricRaceEngine(
      firstPaintGrace: LyricLookupConfig.firstPaintGrace,
      lowConfidencePaintAfter: LyricLookupConfig.lowConfidencePaintAfter,
      deadline: LyricLookupConfig.raceDeadline,
      onSourceError: (label, error) => deps.diagnosticLog?.logEvent(
        subsystem: DiagnosticSubsystem.audio,
        code: 'LYRIC_SOURCE_DEGRADED',
        message: '$label 歌词检索降级忽略',
        severity: DiagnosticSeverity.warn,
        source: 'LyricRaceEngine',
        error: error,
      ),
    ),
    sourcesFactory: () async {
      final prefs = prefsStore.read();
      if (!prefs.neteaseEnabled &&
          !prefs.amllEnabled &&
          !prefs.lrclibEnabled &&
          !prefs.qqEnabled) {
        return const <LyricCandidateSource>[];
      }
      var metered = false;
      final meteredProbe = deps.isMeteredNetwork;
      if (meteredProbe != null) {
        try {
          metered = await meteredProbe();
        } on Object {
          metered = false;
        }
      }
      return <LyricCandidateSource>[
        if (prefs.neteaseEnabled || prefs.amllEnabled)
          NeteaseAmllCandidateSource(
            netease: NeteaseLyricProvider(transport),
            amll: AmllLyricProvider(
              transport,
              hedgeDelay: metered
                  ? LyricLookupConfig.amllMeteredHedgeDelay
                  : LyricLookupConfig.amllHedgeDelay,
            ),
            includeNetease: prefs.neteaseEnabled,
            includeAmll: prefs.amllEnabled,
            onAmllError: (error) => deps.diagnosticLog?.logEvent(
              subsystem: DiagnosticSubsystem.audio,
              code: 'AMLL_LYRIC_DEGRADED',
              message: '逐字歌词开源源降级忽略',
              severity: DiagnosticSeverity.warn,
              source: 'NeteaseAmllCandidateSource',
              error: error,
            ),
          ),
        if (prefs.qqEnabled)
          QqMusicCandidateSource(QqMusicLyricProvider(transport)),
        if (prefs.lrclibEnabled)
          LrclibCandidateSource(LrclibLyricProvider(transport)),
      ];
    },
  );
  ref.onDispose(resolver.cancelPendingLookups);
  return resolver;
});

/// 歌词手选与偏移覆盖同步切片贡献者提供者。
final lyricOverridesSyncSliceProvider = Provider<LyricOverridesSyncSlice>((ref) {
  final deps = ref.watch(featureLyricsDependenciesProvider);
  return LyricOverridesSyncSlice(userStateDb: deps.databases.userState);
});

/// 歌词展示与控制状态协调器提供者（零外部注入，生命周期随容器自动释放）。
final lyricDisplayControllerProvider = Provider<LyricDisplayController>((ref) {
  final deps = ref.watch(featureLyricsDependenciesProvider);
  final resolver = ref.watch(lyricsResolverProvider);
  final prefsStore = ref.watch(lyricsPreferencesStoreProvider);
  final controller = LyricDisplayController(
    resolver: resolver,
    preferencesStore: prefsStore,
    positionListenable: deps.positionListenable,
    isPlayingListenable: deps.isPlayingListenable,
    onSeekRequested: deps.onSeekRequested,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// 跨包歌词协同抽象端口提供者（供宿主注入音频播放舞台）。
final lyricDisplayPortProvider = Provider<LyricDisplayPort>((ref) {
  return ref.watch(lyricDisplayControllerProvider);
});
