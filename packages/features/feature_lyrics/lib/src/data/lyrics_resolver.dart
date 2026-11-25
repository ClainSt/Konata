import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';

import '../domain/bangumi_track_enricher.dart';
import '../domain/lyric_candidate.dart';
import '../domain/lyric_candidate_scorer.dart';
import '../domain/lyric_cleaner.dart';
import '../domain/lyric_merger.dart';
import '../domain/lyric_search_query.dart';
import 'lyric_cache_store.dart';
import 'lyric_candidate_sources.dart';
import 'lyric_http_transport.dart';
import 'lyric_race_engine.dart';

/// 单曲歌词解析请求。
class LyricResolveRequest {
  /// 创建解析请求。
  const LyricResolveRequest({
    required this.trackKey,
    required this.query,
    this.albumKey = '',
    this.bangumiSubjectId,
    this.trackNumber,
    this.embeddedLrcText,
  });

  /// 物理曲目缓存键（见 [LyricsResolver.buildTrackKey]）。
  final String trackKey;

  /// 检索请求。
  final LyricSearchQuery query;

  /// 所属专辑缓存键（用于读取专辑级统一偏移）。
  final String albumKey;

  /// 所属作品已刮削的 Bangumi 条目编号（可选，用于弱文件名曲目表补全）。
  final int? bangumiSubjectId;

  /// 曲目在碟片内的轨号（可选，配合音乐曲目表定位）。
  final int? trackNumber;

  /// 文件内嵌或同目录外挂歌词文本（可选）。
  final String? embeddedLrcText;
}

/// 单曲歌词解析结果。
class LyricResolveOutcome {
  /// 创建解析结果。
  const LyricResolveOutcome({
    this.lrcDocument,
    this.activeSpanLines = const [],
    this.source,
    this.sourceId = '',
    this.fromCache = false,
    this.userEdited = false,
    this.trackOffsetMillis = 0,
    this.userOffsetLocked = false,
    this.candidates = const [],
    this.shortCircuitedInstrumental = false,
    this.staleAborted = false,
  });

  /// 解析后的同步歌词文档。
  final LrcDocument? lrcDocument;

  /// 主唱与和声逐字片段（仅含逐字标签或和声层时非空）。
  final List<ActiveSpanLyricLine> activeSpanLines;

  /// 命中来源。
  final LyricSource? source;

  /// 来源内部歌曲标识（用于在候选列表中高亮当前生效条目）。
  final String sourceId;

  /// 是否直接命中本地内嵌或持久化缓存（零网络）。
  final bool fromCache;

  /// 是否为用户手动选定或编辑锁定（永不被自动流程覆盖）。
  final bool userEdited;

  /// 该曲目持久化的单曲时间轴偏移（毫秒）。
  final int trackOffsetMillis;

  /// 单曲偏移是否已锁定。
  final bool userOffsetLocked;

  /// 本次竞速或手动检索得到的候选列表（供换源面板零延迟展示）。
  final List<ScoredLyricCandidate> candidates;

  /// 是否识别为伴奏或纯音乐并零网络短路。
  final bool shortCircuitedInstrumental;

  /// 是否因切歌或取消导致结果作废。
  final bool staleAborted;
}

/// 在线与本地歌词解析器：伴奏短路、用户锁定优先、内嵌与侧车零网命中、缓存复用、多源竞速与按网络分级预取。
class LyricsResolver {
  /// 非计量网络下的队列预取曲目数。
  static const int wifiPrefetchCount = 2;

  /// 移动计量网络下的队列预取曲目数。
  static const int meteredPrefetchCount = 1;

  /// 渐进升级热替换所需的最低原文按行对齐比例。
  static const double progressiveUpgradeMinMatchRatio = 0.90;

  /// 渐进升级热替换允许的最大时间差中位数（秒），防止切换导致正在唱的句段错位。
  static const double progressiveUpgradeMaxMedianShiftSeconds = 0.25;

  static const int _maxCandidateCacheTracks = 32;

  /// 创建解析器。
  LyricsResolver({
    required this.sourcesFactory,
    this.playbackEngine,
    this.cacheRepository,
    this.isMeteredNetwork,
    this.bangumiMusicTracksLoader,
    this.raceEngine = const LyricRaceEngine(
      firstPaintGrace: LyricLookupConfig.firstPaintGrace,
      lowConfidencePaintAfter: LyricLookupConfig.lowConfidencePaintAfter,
      deadline: LyricLookupConfig.raceDeadline,
    ),
    this.logPort,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 可选统一播放内核（与任务隔离域联动）。
  final UnifiedPlaybackEngine? playbackEngine;

  /// 按需构建本次竞速的候选来源（异步获取网络传输与来源开关状态）。
  final Future<List<LyricCandidateSource>> Function() sourcesFactory;

  /// 持久化缓存与三级偏移仓储（为空时不读写持久层）。
  final LyricCacheRepository? cacheRepository;

  /// 计量移动网络探测回调（控制队列预取数量）。
  final Future<bool> Function()? isMeteredNetwork;

  /// 可选 Bangumi 关联音乐曲目表拉取器（用于弱文件名补全与跨语种别名）。
  final Future<List<BangumiMusicTrack>> Function(int animeSubjectId)?
  bangumiMusicTracksLoader;

  /// 并行竞速器。
  final LyricRaceEngine raceEngine;

  /// 结构化脱敏诊断日志端口。
  final DiagnosticLogPort? logPort;

  final DateTime Function() _now;
  final Map<String, List<ScoredLyricCandidate>> _candidatesByTrackKey = {};
  LyricRaceSession? _activeSession;
  LyricRaceSession? _activePrefetchSession;
  int _lookupGeneration = 0;
  int _prefetchGeneration = 0;

  /// 生成物理曲目缓存键（媒体文件标识 + 文件大小 + 分轨起点）。
  static String buildTrackKey({
    required String physicalFileKey,
    required int fileSize,
    double? cueStartSeconds,
  }) {
    final cue = cueStartSeconds == null
        ? ''
        : cueStartSeconds.toStringAsFixed(3);
    return '$physicalFileKey|$fileSize|$cue';
  }

  /// 读取当前内存保留的指定曲目最近候选列表（用于换源面板秒开）。
  List<ScoredLyricCandidate> cachedCandidatesForTrack(String trackKey) {
    return _candidatesByTrackKey[trackKey] ?? const [];
  }

  /// 立即作废当前在途歌词解析并取消竞速与后台预取（切歌或停止播放时调用）。
  void cancelPendingLookups() {
    _lookupGeneration++;
    playbackEngine?.cancelTaskDomain(PlaybackTaskDomain.lyricLookup);
    _activeSession?.cancel();
    _activeSession = null;
    cancelPrefetch();
  }

  /// 仅取消后台队列预取任务（不影响当前曲目的在线检索）。
  void cancelPrefetch() {
    _prefetchGeneration++;
    _activePrefetchSession?.cancel();
    _activePrefetchSession = null;
  }

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

  /// 结合关联 Bangumi 音乐曲目表对弱文件名曲目恢复日文原名并注入额外标题别名。
  Future<LyricSearchQuery> enrichQueryWithBangumi(
    LyricResolveRequest request,
  ) async {
    final loader = bangumiMusicTracksLoader;
    final subjectId = request.bangumiSubjectId;
    final baseQuery = request.query;
    if (loader == null || subjectId == null || subjectId <= 0) {
      return baseQuery;
    }
    final isWeak = BangumiTrackEnricher.isWeakTrackTitle(baseQuery.title);
    // 常规已有清晰曲名时仅设置极短等待预算，绝不拖慢首屏。
    final budget = isWeak
        ? const Duration(milliseconds: 1200)
        : const Duration(milliseconds: 150);
    try {
      final tracks = await loader(subjectId).timeout(budget);
      if (tracks.isEmpty) return baseQuery;
      final enriched = BangumiTrackEnricher.enrich(
        title: baseQuery.title,
        album: baseQuery.album,
        trackNumber: request.trackNumber,
        musicTracks: tracks,
      );
      if (!enriched.hasEnhancement) return baseQuery;
      return LyricSearchQuery(
        title: enriched.recoveredTitle ?? baseQuery.title,
        artist: baseQuery.artist,
        album: baseQuery.album,
        fileName: baseQuery.fileName,
        durationSeconds: baseQuery.durationSeconds,
        extraTitleAliases: [
          ...baseQuery.extraTitleAliases,
          ...enriched.extraTitleAliases,
        ],
      );
    } on Object {
      return baseQuery;
    }
  }

  /// 解析单曲歌词；[onNetworkLookupStarted] 在缓存未命中、即将发起网络竞速时回调；
  /// [onProgressiveUpgrade] 在首屏上屏后若更优逐字/译文/罗马音候选安全对齐到达时回调，供播放器在行边界热替换；
  /// [onCandidatesSettled] 在全部来源收束后回传完整候选列表供换源面板即开即用。
  Future<LyricResolveOutcome> resolve(
    LyricResolveRequest request, {
    bool bypassCache = false,
    void Function()? onNetworkLookupStarted,
    void Function(LyricResolveOutcome upgraded)? onProgressiveUpgrade,
    void Function(List<ScoredLyricCandidate> candidates)? onCandidatesSettled,
  }) async {
    final lookupGen = ++_lookupGeneration;
    final ScopedTaskToken? engineToken = playbackEngine?.acquireTaskToken(
      PlaybackTaskDomain.lyricLookup,
    );
    bool isAlive() {
      if (lookupGen != _lookupGeneration) return false;
      if (engineToken != null && playbackEngine != null) {
        return playbackEngine!.isTaskAlive(engineToken);
      }
      return true;
    }

    final query = await enrichQueryWithBangumi(request);
    if (!isAlive()) {
      return const LyricResolveOutcome(staleAborted: true);
    }
    if (LyricVersionMatcher.isInstrumentalTrack(
      title: query.title,
      fileName: query.fileName,
    )) {
      return const LyricResolveOutcome(shortCircuitedInstrumental: true);
    }

    final existingRow = await _safeFindByTrackKey(request.trackKey);
    if (!isAlive()) {
      return const LyricResolveOutcome(staleAborted: true);
    }
    final preservedOffset = existingRow?.userOffsetLocked == true
        ? existingRow!.offsetMillis
        : 0;
    final preservedLock = existingRow?.userOffsetLocked ?? false;

    if (!bypassCache) {
      if (existingRow != null &&
          existingRow.userEdited &&
          existingRow.status == LyricCacheStatus.found) {
        final userOutcome = _buildOutcome(
          existingRow.lrcContent,
          existingRow.source ?? LyricSource.local,
          sourceId: existingRow.sourceId,
          fromCache: true,
          userEdited: true,
          trackOffsetMillis: preservedOffset,
          userOffsetLocked: preservedLock,
          candidates: cachedCandidatesForTrack(request.trackKey),
        );
        if (userOutcome != null) return userOutcome;
      }

      final embedded = request.embeddedLrcText?.trim();
      if (embedded != null && embedded.isNotEmpty) {
        final cleanedEmbedded = LyricCleaner.clean(embedded);
        final effectiveEmbedded = cleanedEmbedded.isPlaceholder
            ? embedded
            : cleanedEmbedded.cleanedLrc;
        final embeddedOutcome = _buildOutcome(
          effectiveEmbedded,
          LyricSource.local,
          sourceId: 'embedded',
          fromCache: true,
          trackOffsetMillis: preservedOffset,
          userOffsetLocked: preservedLock,
          candidates: cachedCandidatesForTrack(request.trackKey),
        );
        if (embeddedOutcome != null) return embeddedOutcome;
      }

      // 占位曲名无法建立可靠歌曲身份，不采用旧自动缓存或跨文件复用。
      if (BangumiTrackEnricher.isWeakTrackTitle(query.title)) {
        return LyricResolveOutcome(
          trackOffsetMillis: preservedOffset,
          userOffsetLocked: preservedLock,
        );
      }

      final cached = await _readCache(
        request.trackKey,
        query.songKey,
        existingByTrack: existingRow,
      );
      if (!isAlive()) {
        return const LyricResolveOutcome(staleAborted: true);
      }
      if (cached != null) {
        if (cached.status == LyricCacheStatus.notFound) {
          return LyricResolveOutcome(
            fromCache: true,
            trackOffsetMillis: preservedOffset,
            userOffsetLocked: preservedLock,
          );
        }
        final outcome = _buildOutcome(
          cached.lrcContent,
          cached.source,
          sourceId: cached.sourceId,
          fromCache: true,
          userEdited: cached.userEdited,
          trackOffsetMillis: cached.userOffsetLocked
              ? cached.offsetMillis
              : preservedOffset,
          userOffsetLocked: cached.userOffsetLocked || preservedLock,
          candidates: cachedCandidatesForTrack(request.trackKey),
        );
        if (outcome != null) return outcome;
      }
    }

    // 重试仍属于自动匹配，用户可以通过独立手动检索提供真实曲名。
    if (BangumiTrackEnricher.isWeakTrackTitle(query.title)) {
      return LyricResolveOutcome(
        trackOffsetMillis: preservedOffset,
        userOffsetLocked: preservedLock,
      );
    }

    final List<LyricCandidateSource> sources;
    try {
      sources = await sourcesFactory();
    } on Object catch (e, st) {
      _logWarn(
        'LYRIC_TRANSPORT_INIT',
        '歌词检索网络传输初始化失败',
        error: e,
        stackTrace: st,
      );
      return LyricResolveOutcome(
        trackOffsetMillis: preservedOffset,
        userOffsetLocked: preservedLock,
      );
    }
    if (!isAlive()) {
      return const LyricResolveOutcome(staleAborted: true);
    }

    onNetworkLookupStarted?.call();
    final session = raceEngine.start(query, sources);
    _activeSession = session;

    final first = await session.firstPaint;
    unawaited(
      session.settled.then((settlement) async {
        if (settlement.allCandidates.isNotEmpty) {
          _rememberCandidates(request.trackKey, settlement.allCandidates);
          if (isAlive()) {
            onCandidatesSettled?.call(settlement.allCandidates);
          }
        }
        await _persistSettlement(
          request,
          query,
          settlement,
          allowOverwriteUserEdited: bypassCache,
        );
        if (onProgressiveUpgrade == null ||
            first == null ||
            settlement.cancelled ||
            !isAlive()) {
          return;
        }
        final settledBest = settlement.best;
        if (settledBest == null) return;
        if (!shouldApplyProgressiveUpgrade(first, settledBest)) return;
        final upgraded = _buildOutcome(
          settledBest.candidate.lrcContent,
          settledBest.candidate.source,
          sourceId: settledBest.candidate.sourceId,
          trackOffsetMillis: preservedOffset,
          userOffsetLocked: preservedLock,
          candidates: settlement.allCandidates,
        );
        if (upgraded != null && isAlive()) {
          onProgressiveUpgrade(upgraded);
        }
      }),
    );

    if (!isAlive()) {
      return const LyricResolveOutcome(staleAborted: true);
    }
    if (first == null) {
      return LyricResolveOutcome(
        trackOffsetMillis: preservedOffset,
        userOffsetLocked: preservedLock,
      );
    }
    return _buildOutcome(
          first.candidate.lrcContent,
          first.candidate.source,
          sourceId: first.candidate.sourceId,
          trackOffsetMillis: preservedOffset,
          userOffsetLocked: preservedLock,
          candidates: cachedCandidatesForTrack(request.trackKey),
        ) ??
        LyricResolveOutcome(
          trackOffsetMillis: preservedOffset,
          userOffsetLocked: preservedLock,
        );
  }

  /// 手动关键词重搜：并行查询全部已启用源并返回所有非占位同步候选（含低置信度结果，供用户自行挑选）。
  Future<List<ScoredLyricCandidate>> searchCandidatesManual(
    LyricSearchQuery query, {
    String? trackKey,
  }) async {
    final List<LyricCandidateSource> sources;
    try {
      sources = await sourcesFactory();
    } on Object catch (e, st) {
      _logWarn('LYRIC_MANUAL_INIT', '手动歌词检索初始化失败', error: e, stackTrace: st);
      return const [];
    }
    if (sources.isEmpty) return const [];

    final deduped = <String, LyricCandidate>{};
    await Future.wait([
      for (final source in sources)
        source
            .candidates(query)
            .forEach((candidate) {
              if (!candidate.isSynced || candidate.lrcContent.trim().isEmpty) {
                return;
              }
              if (LyricCleaner.clean(candidate.lrcContent).isPlaceholder) {
                return;
              }
              final key = '${candidate.source.name}::${candidate.sourceId}';
              final prev = deduped[key];
              if (prev == null ||
                  (candidate.hasWordTiming && !prev.hasWordTiming) ||
                  (candidate.hasTranslation && !prev.hasTranslation)) {
                deduped[key] = candidate;
              }
            })
            .timeout(LyricLookupConfig.raceDeadline)
            .catchError((Object e) {
              _logWarn(
                'LYRIC_MANUAL_SOURCE',
                '${source.label} 手动检索降级忽略',
                error: e,
              );
            }),
    ]);

    final scored = <ScoredLyricCandidate>[];
    final crossCache = LyricCrossSourceCache();
    final allList = deduped.values.toList(growable: false)
      ..sort((a, b) {
        final richA = (a.hasTranslation ? 2 : 0) + (a.hasRomaji ? 1 : 0);
        final richB = (b.hasTranslation ? 2 : 0) + (b.hasRomaji ? 1 : 0);
        return richB.compareTo(richA);
      });
    for (var i = 0; i < allList.length; i++) {
      final raw = allList[i];
      final others = <LyricCandidate>[
        for (var j = 0; j < allList.length; j++)
          if (j != i && allList[j].source != raw.source) allList[j],
      ];
      final enriched = others.isEmpty
          ? CrossSourceEnrichment(
              candidate: raw,
              crossSourceAgreed: false,
              borrowedTranslation: false,
              borrowedRomaji: false,
            )
          : LyricMerger.enrichWithCrossSource(raw, others, cache: crossCache);
      final fullScore = LyricCandidateScorer.score(
        query,
        enriched.candidate,
        crossSourceAgree: enriched.crossSourceAgreed,
        precleaned: crossCache.cleanedFor(raw),
      );
      final displayScore =
          fullScore ??
          LyricCandidateScorer.scoreMetadata(
            query,
            title: enriched.candidate.title,
            artist: enriched.candidate.artist,
            album: enriched.candidate.album,
            durationSeconds: enriched.candidate.durationSeconds,
          ) ??
          0.0;
      scored.add(
        ScoredLyricCandidate(
          enriched.candidate,
          displayScore,
          crossSourceAgreed: enriched.crossSourceAgreed,
        ),
      );
    }

    scored.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      final capA =
          (a.candidate.hasWordTiming ? 4 : 0) +
          (a.candidate.hasTranslation ? 2 : 0) +
          (a.candidate.hasRomaji ? 1 : 0);
      final capB =
          (b.candidate.hasWordTiming ? 4 : 0) +
          (b.candidate.hasTranslation ? 2 : 0) +
          (b.candidate.hasRomaji ? 1 : 0);
      return capB.compareTo(capA);
    });

    if (trackKey != null && scored.isNotEmpty) {
      _rememberCandidates(trackKey, scored);
    }
    return List<ScoredLyricCandidate>.unmodifiable(scored);
  }

  /// 应用用户手动选定的歌词候选并写入锁定状态（永不被自动流程覆盖）。
  Future<LyricResolveOutcome?> applyManualCandidate({
    required String trackKey,
    String? songKey,
    required ScoredLyricCandidate selected,
  }) async {
    final existing = await _safeFindByTrackKey(trackKey);
    final preservedOffset = existing?.userOffsetLocked == true
        ? existing!.offsetMillis
        : 0;
    final preservedLock = existing?.userOffsetLocked ?? false;
    final outcome = _buildOutcome(
      selected.candidate.lrcContent,
      selected.candidate.source,
      sourceId: selected.candidate.sourceId,
      userEdited: true,
      trackOffsetMillis: preservedOffset,
      userOffsetLocked: preservedLock,
      candidates: cachedCandidatesForTrack(trackKey),
    );
    if (outcome == null) return null;

    final repo = cacheRepository;
    if (repo != null) {
      try {
        await repo.save(
          LyricCacheEntry(
            trackKey: trackKey,
            songKey: songKey ?? existing?.songKey,
            status: LyricCacheStatus.found,
            source: selected.candidate.source,
            sourceId: selected.candidate.sourceId,
            lrcContent: selected.candidate.lrcContent,
            score: selected.score,
            engineVersion: LyricLookupConfig.engineVersion,
            updatedAt: _now(),
            offsetMillis: preservedOffset,
            userOffsetLocked: preservedLock,
            userEdited: true,
          ),
        );
      } on Object catch (e) {
        _logWarn('LYRIC_SAVE_MANUAL', '保存手动选定歌词失败已降级', error: e);
      }
    }
    return outcome;
  }

  /// 解除当前曲目的用户手动锁定（保留单曲偏移），供后续恢复自动匹配。
  Future<void> unlockUserEdit(String trackKey) async {
    final repo = cacheRepository;
    if (repo == null) return;
    try {
      await repo.unlockUserEdit(trackKey);
    } on Object catch (e) {
      _logWarn('LYRIC_UNLOCK_EDIT', '解除歌词锁定降级忽略', error: e);
    }
  }

  /// 读取单曲与所属专辑的持久化偏移（同时适用于本地外挂与在线歌词）。
  Future<
    ({int trackOffsetMillis, bool userOffsetLocked, int albumOffsetMillis})
  >
  readPersistedOffsets({
    required String trackKey,
    required String albumKey,
  }) async {
    final repo = cacheRepository;
    if (repo == null) {
      return (
        trackOffsetMillis: 0,
        userOffsetLocked: false,
        albumOffsetMillis: 0,
      );
    }
    try {
      final entry = await repo.findByTrackKey(trackKey);
      final albumMs = albumKey.trim().isEmpty
          ? 0
          : await repo.findAlbumOffsetMillis(albumKey);
      return (
        trackOffsetMillis: entry?.offsetMillis ?? 0,
        userOffsetLocked: entry?.userOffsetLocked ?? false,
        albumOffsetMillis: albumMs,
      );
    } on Object catch (e) {
      _logWarn('LYRIC_READ_OFFSETS', '读取歌词偏移降级忽略', error: e);
      return (
        trackOffsetMillis: 0,
        userOffsetLocked: false,
        albumOffsetMillis: 0,
      );
    }
  }

  /// 持久化单曲时间轴偏移并锁定，保证自动缓存刷新不丢失用户校准值。
  Future<void> saveTrackOffset(
    String trackKey, {
    required int offsetMillis,
    bool userOffsetLocked = true,
  }) async {
    final repo = cacheRepository;
    if (repo == null) return;
    try {
      await repo.updateTrackOffset(
        trackKey,
        offsetMillis: offsetMillis,
        userOffsetLocked: userOffsetLocked,
      );
    } on Object catch (e) {
      _logWarn('LYRIC_SAVE_TRACK_OFFSET', '保存单曲歌词偏移降级忽略', error: e);
    }
  }

  /// 持久化专辑级统一歌词偏移。
  Future<void> saveAlbumOffset(String albumKey, int offsetMillis) async {
    final repo = cacheRepository;
    if (repo == null || albumKey.trim().isEmpty) return;
    try {
      await repo.saveAlbumOffsetMillis(albumKey, offsetMillis);
    } on Object catch (e) {
      _logWarn('LYRIC_SAVE_ALBUM_OFFSET', '保存专辑歌词偏移降级忽略', error: e);
    }
  }

  /// 按当前网络类型分级串行预取队列后续曲目歌词并写入持久缓存（非计量网络 2 首，计量网络 1 首）。
  ///
  /// 返回本次实际通过网络预取并落盘的曲目数量（已命中缓存、内嵌歌词、伴奏或中途被取消的不计入）。
  Future<int> prefetchUpcomingTracks(
    List<LyricResolveRequest> upcomingRequests,
  ) async {
    if (upcomingRequests.isEmpty || cacheRepository == null) return 0;
    final gen = ++_prefetchGeneration;
    _activePrefetchSession?.cancel();
    _activePrefetchSession = null;

    var metered = false;
    final probe = isMeteredNetwork;
    if (probe != null) {
      try {
        metered = await probe();
      } on Object {
        metered = false;
      }
    }
    if (gen != _prefetchGeneration) return 0;

    final maxCount = metered ? meteredPrefetchCount : wifiPrefetchCount;
    final targets = upcomingRequests.take(maxCount).toList(growable: false);
    if (targets.isEmpty) return 0;

    List<LyricCandidateSource>? sources;
    var fetchedCount = 0;

    for (final req in targets) {
      if (gen != _prefetchGeneration) break;
      final query = await enrichQueryWithBangumi(req);
      if (gen != _prefetchGeneration) break;
      if (LyricVersionMatcher.isInstrumentalTrack(
        title: query.title,
        fileName: query.fileName,
      )) {
        continue;
      }
      if (BangumiTrackEnricher.isWeakTrackTitle(query.title) ||
          (req.embeddedLrcText ?? '').trim().isNotEmpty) {
        continue;
      }

      final existing = await _safeFindByTrackKey(req.trackKey);
      if (gen != _prefetchGeneration) break;
      final cached = await _readCache(
        req.trackKey,
        query.songKey,
        existingByTrack: existing,
      );
      if (gen != _prefetchGeneration) break;
      if (cached != null) continue;

      if (sources == null) {
        try {
          sources = await sourcesFactory();
        } on Object catch (e) {
          _logWarn('LYRIC_PREFETCH_INIT', '队列歌词预取初始化降级忽略', error: e);
          break;
        }
        if (sources.isEmpty || gen != _prefetchGeneration) break;
      }

      final session = raceEngine.start(query, sources);
      _activePrefetchSession = session;
      final settlement = await session.settled;
      if (identical(_activePrefetchSession, session)) {
        _activePrefetchSession = null;
      }
      if (gen != _prefetchGeneration || settlement.cancelled) break;
      if (settlement.allCandidates.isNotEmpty) {
        _rememberCandidates(req.trackKey, settlement.allCandidates);
      }
      await _persistSettlement(req, query, settlement);
      if (settlement.best != null) {
        fetchedCount++;
      }
    }
    return fetchedCount;
  }

  void _logWarn(
    String code,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    logPort?.logEvent(
      subsystem: DiagnosticSubsystem.audio,
      code: code,
      message: message,
      severity: DiagnosticSeverity.warn,
      source: 'LyricsResolver',
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _rememberCandidates(
    String trackKey,
    List<ScoredLyricCandidate> candidates,
  ) {
    _candidatesByTrackKey.remove(trackKey);
    _candidatesByTrackKey[trackKey] = List<ScoredLyricCandidate>.unmodifiable(
      candidates,
    );
    while (_candidatesByTrackKey.length > _maxCandidateCacheTracks) {
      _candidatesByTrackKey.remove(_candidatesByTrackKey.keys.first);
    }
  }

  Future<LyricCacheEntry?> _safeFindByTrackKey(String trackKey) async {
    final repo = cacheRepository;
    if (repo == null) return null;
    try {
      return await repo.findByTrackKey(trackKey);
    } on Object catch (e) {
      _logWarn('LYRIC_READ_TRACK', '读取单曲缓存降级忽略', error: e);
      return null;
    }
  }

  Future<LyricCacheEntry?> _readCache(
    String trackKey,
    String? songKey, {
    LyricCacheEntry? existingByTrack,
  }) async {
    final repo = cacheRepository;
    if (repo == null) return null;
    try {
      final byTrack = existingByTrack ?? await repo.findByTrackKey(trackKey);
      if (byTrack != null) {
        // 用户手动选定或编辑锁定条目永不因引擎版本更新失效。
        if (byTrack.userEdited && byTrack.status == LyricCacheStatus.found) {
          return byTrack;
        }
        if (byTrack.engineVersion == LyricLookupConfig.engineVersion) {
          if (byTrack.status == LyricCacheStatus.found) return byTrack;
          final age = _now().difference(byTrack.updatedAt);
          if (age < LyricLookupConfig.notFoundRetryAfter) return byTrack;
        }
      }
      if (songKey == null) return null;
      final bySong = await repo.findFoundBySongKey(songKey);
      if (bySong == null ||
          (!bySong.userEdited &&
              bySong.engineVersion != LyricLookupConfig.engineVersion)) {
        return null;
      }
      final preservedOffset = byTrack?.userOffsetLocked == true
          ? byTrack!.offsetMillis
          : 0;
      final preservedLock = byTrack?.userOffsetLocked ?? false;
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
          offsetMillis: preservedOffset,
          userOffsetLocked: preservedLock,
          userEdited: false,
        ),
      );
      return bySong.copyWith(
        offsetMillis: preservedOffset,
        userOffsetLocked: preservedLock,
        userEdited: false,
      );
    } on Object catch (e) {
      _logWarn('LYRIC_READ_CACHE', '歌词缓存读取降级忽略', error: e);
      return null;
    }
  }

  Future<void> _persistSettlement(
    LyricResolveRequest request,
    LyricSearchQuery resolvedQuery,
    LyricRaceSettlement settlement, {
    bool allowOverwriteUserEdited = false,
  }) async {
    final repo = cacheRepository;
    if (repo == null) return;
    final existing = await _safeFindByTrackKey(request.trackKey);
    // 严格保护用户手动选定与编辑：自动检索与后台预取绝不覆盖已锁定条目。
    if (!allowOverwriteUserEdited && existing != null && existing.userEdited) {
      return;
    }
    final preservedOffset = existing?.userOffsetLocked == true
        ? existing!.offsetMillis
        : 0;
    final preservedLock = existing?.userOffsetLocked ?? false;

    final best = settlement.best;
    final LyricCacheEntry entry;
    if (best != null) {
      if (_buildOutcome(best.candidate.lrcContent, best.candidate.source) ==
          null) {
        return;
      }
      entry = LyricCacheEntry(
        trackKey: request.trackKey,
        songKey: resolvedQuery.songKey,
        status: LyricCacheStatus.found,
        source: best.candidate.source,
        sourceId: best.candidate.sourceId,
        lrcContent: best.candidate.lrcContent,
        score: best.score,
        engineVersion: LyricLookupConfig.engineVersion,
        updatedAt: _now(),
        offsetMillis: preservedOffset,
        userOffsetLocked: preservedLock,
        userEdited: false,
      );
    } else if (settlement.isConfirmedNotFound) {
      entry = LyricCacheEntry(
        trackKey: request.trackKey,
        songKey: resolvedQuery.songKey,
        status: LyricCacheStatus.notFound,
        engineVersion: LyricLookupConfig.engineVersion,
        updatedAt: _now(),
        offsetMillis: preservedOffset,
        userOffsetLocked: preservedLock,
        userEdited: false,
      );
    } else {
      return;
    }
    try {
      await repo.save(entry);
    } on Object catch (e) {
      _logWarn('LYRIC_WRITE_CACHE', '歌词缓存写入降级忽略', error: e);
    }
  }

  static LyricResolveOutcome? _buildOutcome(
    String lrcContent,
    LyricSource? source, {
    String sourceId = '',
    bool fromCache = false,
    bool userEdited = false,
    int trackOffsetMillis = 0,
    bool userOffsetLocked = false,
    List<ScoredLyricCandidate> candidates = const [],
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
      sourceId: sourceId,
      fromCache: fromCache,
      userEdited: userEdited,
      trackOffsetMillis: trackOffsetMillis,
      userOffsetLocked: userOffsetLocked,
      candidates: candidates,
    );
  }
}
