import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_merger.dart';
import '../../domain/lyrics/lyric_search_query.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../../domain/repositories/lyric_cache_repository.dart';
import '../../infrastructure/database/drift_library_repository.dart';
import '../../infrastructure/database/drift_lyric_cache_repository.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/lyrics/amll_lyric_provider.dart';
import '../../infrastructure/lyrics/app_network_lyric_transport.dart';
import '../../infrastructure/lyrics/lrclib_lyric_provider.dart';
import '../../infrastructure/lyrics/lyric_http_transport.dart';
import '../../infrastructure/lyrics/netease_lyric_provider.dart';
import '../../infrastructure/lyrics/qqmusic_lyric_provider.dart';
import '../../infrastructure/network/metered_network_detector.dart';
import '../providers/diagnostics_providers.dart';
import '../providers/library_providers.dart';
import '../providers/scraping_providers.dart';
import 'lyric_candidate_sources.dart';
import 'lyric_race_engine.dart';
import 'playback_preferences_provider.dart';
import 'unified_playback_engine.dart';

/// 单曲歌词解析请求。
class LyricResolveRequest {
  /// 创建解析请求。
  const LyricResolveRequest({required this.trackKey, required this.query});

  /// 物理曲目缓存键（见 [LyricsResolver.buildTrackKey]）。
  final String trackKey;

  /// 检索请求。
  final LyricSearchQuery query;
}

/// 单曲歌词解析结果。
class LyricResolveOutcome {
  /// 创建解析结果。
  const LyricResolveOutcome({
    this.lrcDocument,
    this.activeSpanLines = const [],
    this.source,
    this.fromCache = false,
    this.shortCircuitedInstrumental = false,
    this.staleAborted = false,
  });

  /// 解析后的同步歌词文档。
  final LrcDocument? lrcDocument;

  /// 主唱 / 和声逐字片段（仅含逐字标签或 `bg:` 和声层时非空）。
  final List<ActiveSpanLyricLine> activeSpanLines;

  /// 命中来源。
  final LyricSource? source;

  /// 是否直接命中持久化缓存（零网络）。
  final bool fromCache;

  /// 是否识别为伴奏 / 纯音乐并零网络短路。
  final bool shortCircuitedInstrumental;

  /// 是否因切歌或取消导致结果作废。
  final bool staleAborted;
}

/// 在线歌词解析器：伴奏短路 → 持久化缓存 → 多来源并行竞速，并把最终最优结果写回缓存。
///
/// 严格绑定 `PlaybackTaskDomain.lyricLookup` 分域令牌，切歌即作废并取消在途竞速。
class LyricsResolver {
  /// 创建解析器。
  LyricsResolver({
    required this.playbackEngine,
    required this.sourcesFactory,
    this.cacheRepository,
    this.raceEngine = const LyricRaceEngine(
      firstPaintGrace: LyricLookupConfig.firstPaintGrace,
      lowConfidencePaintAfter: LyricLookupConfig.lowConfidencePaintAfter,
      deadline: LyricLookupConfig.raceDeadline,
    ),
    this.logStore,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 统一播放引擎（仅取消 / 隔离 `PlaybackTaskDomain.lyricLookup` 域）。
  final UnifiedPlaybackEngine playbackEngine;

  /// 按需构建本次竞速的候选来源（异步获取网络传输与计量网络状态）。
  final Future<List<LyricCandidateSource>> Function() sourcesFactory;

  /// 持久化缓存仓储（为空时不读写缓存）。
  final LyricCacheRepository? cacheRepository;

  /// 并行竞速器。
  final LyricRaceEngine raceEngine;

  /// 诊断日志存储。
  final DiagnosticsLogStore? logStore;

  final DateTime Function() _now;
  LyricRaceSession? _activeSession;

  /// 生成物理曲目缓存键（媒体源 + 相对路径 + 文件大小 + CUE 分轨起点）。
  static String buildTrackKey({
    required String physicalFileKey,
    required int fileSize,
    double? cueStartSeconds,
  }) {
    final cue = cueStartSeconds == null ? '' : cueStartSeconds.toStringAsFixed(3);
    return '$physicalFileKey|$fileSize|$cue';
  }

  /// 立即作废当前在途歌词解析并取消竞速（切歌或停止播放时调用）。
  void cancelPendingLookups() {
    playbackEngine.cancelTaskDomain(PlaybackTaskDomain.lyricLookup);
    _activeSession?.cancel();
    _activeSession = null;
  }

  /// 渐进升级热替换所需的最低原文按行对齐比例。
  static const double progressiveUpgradeMinMatchRatio = 0.90;

  /// 渐进升级热替换允许的最大时间差中位数（秒），防止切换导致正在唱的句段错位。
  static const double progressiveUpgradeMaxMedianShiftSeconds = 0.25;

  /// 判定收束后的最终候选 [settled] 是否相对首屏候选 [first] 具备有效能力升级且时间轴高度一致。
  static bool shouldApplyProgressiveUpgrade(
    ScoredLyricCandidate first,
    ScoredLyricCandidate settled,
  ) {
    final a = first.candidate;
    final b = settled.candidate;
    if (a.lrcContent == b.lrcContent) return false;

    final addsWord = !a.hasWordTiming && b.hasWordTiming;
    final addsTranslation = !a.hasTranslation && b.hasTranslation;
    final addsRomaji = !a.hasRomaji && b.hasRomaji;
    final upgradesToAmll =
        a.hasWordTiming &&
        b.hasWordTiming &&
        a.source != LyricSource.amll &&
        b.source == LyricSource.amll &&
        settled.score >= first.score - 0.02;
    if (!addsWord && !addsTranslation && !addsRomaji && !upgradesToAmll) {
      return false;
    }

    final firstRows = LyricMerger.extractPrimaryRows(a.lrcContent);
    final settledRows = LyricMerger.extractPrimaryRows(b.lrcContent);
    if (firstRows.isEmpty || settledRows.isEmpty) return false;

    final alignment = LyricMerger.crossSourceAlign(firstRows, settledRows);
    return alignment.matchRatio >= progressiveUpgradeMinMatchRatio &&
        alignment.medianShiftSeconds.abs() <=
            progressiveUpgradeMaxMedianShiftSeconds;
  }

  /// 解析单曲歌词；[onNetworkLookupStarted] 在缓存未命中、即将发起网络竞速时回调；
  /// [onProgressiveUpgrade] 在首屏上屏后若更优逐字/译文/罗马音候选安全对齐到达时回调，供播放器在行边界热替换。
  Future<LyricResolveOutcome> resolve(
    LyricResolveRequest request, {
    void Function()? onNetworkLookupStarted,
    void Function(LyricResolveOutcome upgraded)? onProgressiveUpgrade,
  }) async {
    final token = playbackEngine.acquireTaskToken(
      PlaybackTaskDomain.lyricLookup,
    );
    final query = request.query;
    if (LyricVersionMatcher.isInstrumentalTrack(
      title: query.title,
      fileName: query.fileName,
    )) {
      return const LyricResolveOutcome(shortCircuitedInstrumental: true);
    }

    final cached = await _readCache(request.trackKey, query.songKey);
    if (!playbackEngine.isTaskAlive(token)) {
      return const LyricResolveOutcome(staleAborted: true);
    }
    if (cached != null) {
      if (cached.status == LyricCacheStatus.notFound) {
        return const LyricResolveOutcome(fromCache: true);
      }
      final outcome = _buildOutcome(
        cached.lrcContent,
        cached.source,
        fromCache: true,
      );
      if (outcome != null) return outcome;
    }

    final List<LyricCandidateSource> sources;
    try {
      sources = await sourcesFactory();
    } on Object catch (e) {
      logStore?.record('AUDIO-LYRIC', '歌词检索网络传输初始化失败：$e');
      return const LyricResolveOutcome();
    }
    if (!playbackEngine.isTaskAlive(token)) {
      return const LyricResolveOutcome(staleAborted: true);
    }

    onNetworkLookupStarted?.call();
    final session = raceEngine.start(query, sources);
    _activeSession = session;

    final first = await session.firstPaint;
    unawaited(
      session.settled.then((settlement) async {
        await _persistSettlement(request, settlement);
        if (onProgressiveUpgrade == null ||
            first == null ||
            settlement.cancelled ||
            !playbackEngine.isTaskAlive(token)) {
          return;
        }
        final settledBest = settlement.best;
        if (settledBest == null) return;
        if (!shouldApplyProgressiveUpgrade(first, settledBest)) return;
        final upgraded = _buildOutcome(
          settledBest.candidate.lrcContent,
          settledBest.candidate.source,
        );
        if (upgraded != null && playbackEngine.isTaskAlive(token)) {
          onProgressiveUpgrade(upgraded);
        }
      }),
    );

    if (!playbackEngine.isTaskAlive(token)) {
      return const LyricResolveOutcome(staleAborted: true);
    }
    if (first == null) return const LyricResolveOutcome();
    return _buildOutcome(first.candidate.lrcContent, first.candidate.source) ??
        const LyricResolveOutcome();
  }

  Future<LyricCacheEntry?> _readCache(String trackKey, String? songKey) async {
    final repo = cacheRepository;
    if (repo == null) return null;
    try {
      final byTrack = await repo.findByTrackKey(trackKey);
      if (byTrack != null &&
          byTrack.engineVersion == LyricLookupConfig.engineVersion) {
        if (byTrack.status == LyricCacheStatus.found) return byTrack;
        final age = _now().difference(byTrack.updatedAt);
        if (age < LyricLookupConfig.notFoundRetryAfter) return byTrack;
      }
      if (songKey == null) return null;
      final bySong = await repo.findFoundBySongKey(songKey);
      if (bySong == null ||
          bySong.engineVersion != LyricLookupConfig.engineVersion) {
        return null;
      }
      await repo.save(
        LyricCacheEntry(
          trackKey: trackKey,
          songKey: songKey,
          status: LyricCacheStatus.found,
          source: bySong.source,
          sourceId: bySong.sourceId,
          lrcContent: bySong.lrcContent,
          score: bySong.score,
          engineVersion: LyricLookupConfig.engineVersion,
          updatedAt: _now(),
        ),
      );
      return bySong;
    } on Object catch (e) {
      logStore?.record('AUDIO-LYRIC', '歌词缓存读取降级忽略：$e');
      return null;
    }
  }

  Future<void> _persistSettlement(
    LyricResolveRequest request,
    LyricRaceSettlement settlement,
  ) async {
    final repo = cacheRepository;
    if (repo == null) return;
    final best = settlement.best;
    final LyricCacheEntry entry;
    if (best != null) {
      if (_buildOutcome(best.candidate.lrcContent, best.candidate.source) ==
          null) {
        return;
      }
      entry = LyricCacheEntry(
        trackKey: request.trackKey,
        songKey: request.query.songKey,
        status: LyricCacheStatus.found,
        source: best.candidate.source,
        sourceId: best.candidate.sourceId,
        lrcContent: best.candidate.lrcContent,
        score: best.score,
        engineVersion: LyricLookupConfig.engineVersion,
        updatedAt: _now(),
      );
    } else if (settlement.isConfirmedNotFound) {
      entry = LyricCacheEntry(
        trackKey: request.trackKey,
        songKey: request.query.songKey,
        status: LyricCacheStatus.notFound,
        engineVersion: LyricLookupConfig.engineVersion,
        updatedAt: _now(),
      );
    } else {
      return;
    }
    try {
      await repo.save(entry);
    } on Object catch (e) {
      logStore?.record('AUDIO-LYRIC', '歌词缓存写入降级忽略：$e');
    }
  }

  static LyricResolveOutcome? _buildOutcome(
    String lrcContent,
    LyricSource? source, {
    bool fromCache = false,
  }) {
    final doc = LrcParser.parseText(lrcContent);
    if (doc.lines.isEmpty) return null;
    final spans = LyricVersionMatcher.hasExplicitEnhancedTags(lrcContent)
        ? LyricVersionMatcher.parseActiveSpanLines(lrcContent)
        : const <ActiveSpanLyricLine>[];
    return LyricResolveOutcome(
      lrcDocument: doc,
      activeSpanLines: spans,
      source: source,
      fromCache: fromCache,
    );
  }
}

/// 移动计量网络探测器 Provider。
final meteredNetworkDetectorProvider = Provider<MeteredNetworkDetector>(
  (ref) => const MeteredNetworkDetector(),
);

/// 歌词检索 HTTP 传输 Provider（复用全局代理 / DoH / 连接池网络栈）。
final lyricHttpTransportProvider = FutureProvider<LyricHttpTransport>((
  ref,
) async {
  final client = await ref.watch(appTmdbHttpClientProvider.future);
  return AppNetworkLyricTransport(client);
});

/// 歌词检索结果持久化缓存仓储 Provider（与媒体库仓储共用同一 Drift 连接；非 Drift 媒体库实现时不缓存）。
final lyricCacheRepositoryProvider = Provider<LyricCacheRepository?>((ref) {
  final library = ref.watch(libraryRepositoryProvider);
  return library is DriftLibraryRepository
      ? DriftLyricCacheRepository(library.database)
      : null;
});

/// 歌词解析器 Provider（绑定 `UnifiedPlaybackEngine` 与 `PlaybackTaskDomain.lyricLookup`）。
final lyricsResolverProvider = Provider<LyricsResolver>((ref) {
  final logStore = ref.read(diagnosticsLogStoreProvider);
  return LyricsResolver(
    playbackEngine: ref.read(unifiedPlaybackEngineProvider),
    cacheRepository: ref.read(lyricCacheRepositoryProvider),
    logStore: logStore,
    raceEngine: LyricRaceEngine(
      firstPaintGrace: LyricLookupConfig.firstPaintGrace,
      lowConfidencePaintAfter: LyricLookupConfig.lowConfidencePaintAfter,
      deadline: LyricLookupConfig.raceDeadline,
      onSourceError: (label, error) =>
          logStore.record('AUDIO-LYRIC', '$label 歌词检索降级忽略：$error'),
    ),
    sourcesFactory: () async {
      final prefs = ref.read(playbackPreferencesProvider);
      final enableNetease = prefs.lyricSourceNeteaseEnabled;
      final enableAmll = prefs.lyricSourceAmllEnabled;
      final enableLrclib = prefs.lyricSourceLrclibEnabled;
      final enableQq = prefs.lyricSourceQqEnabled;
      if (!enableNetease && !enableAmll && !enableLrclib && !enableQq) {
        return const [];
      }

      final transport = await ref.read(lyricHttpTransportProvider.future);
      final metered = await ref
          .read(meteredNetworkDetectorProvider)
          .isMeteredMobileNetwork();
      return [
        if (enableNetease || enableAmll)
          NeteaseAmllCandidateSource(
            netease: NeteaseLyricProvider(transport),
            amll: AmllLyricProvider(
              transport,
              hedgeDelay: metered
                  ? LyricLookupConfig.amllMeteredHedgeDelay
                  : LyricLookupConfig.amllHedgeDelay,
            ),
            includeNetease: enableNetease,
            includeAmll: enableAmll,
            onAmllError: (error) =>
                logStore.record('AUDIO-LYRIC', 'AMLL 逐字歌词降级忽略：$error'),
          ),
        if (enableQq) QqMusicCandidateSource(QqMusicLyricProvider(transport)),
        if (enableLrclib) LrclibCandidateSource(LrclibLyricProvider(transport)),
      ];
    },
  );
});
