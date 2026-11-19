import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../../infrastructure/players/online_lyric_lookup_service.dart';
import '../providers/diagnostics_providers.dart';
import 'unified_playback_engine.dart';

/// 四级开源歌词协调器执行结果。
class LyricLookupOutcome {
  /// 创建歌词检索结果。
  const LyricLookupOutcome({
    this.lrcDocument,
    this.activeSpanLines = const [],
    this.matchedTier,
    this.matchedCandidate,
    this.shortCircuitedInstrumental = false,
    this.needsMobileAmllConfirmation = false,
    this.staleAborted = false,
  });

  /// 解析后的同步歌词文档。
  final LrcDocument? lrcDocument;

  /// 解析后的主唱/和声逐字 Active Span Set（若存在逐字或 `bg:` 和声层）。
  final List<ActiveSpanLyricLine> activeSpanLines;

  /// 最终命中的四级来源层级。
  final LyricLookupTier? matchedTier;

  /// 经 `LyricVersionMatcher.selectBestCandidate` 胜出的最优候选元数据。
  final LyricCandidateMeta? matchedCandidate;

  /// 是否识别为伴奏/纯音乐/Off Vocal 并直接零网络短路跳过。
  final bool shortCircuitedInstrumental;

  /// 移动计量网络下尚未获用户授权拉取 AMLL 索引，需界面弹窗/横幅确认。
  final bool needsMobileAmllConfirmation;

  /// 是否因切歌或手动取消导致 `PlaybackTaskDomain.lyricLookup` 令牌失效而中止。
  final bool staleAborted;
}

/// 四级开源歌词检索协调器（严格绑定 `PlaybackTaskDomain.lyricLookup` 分域取消与版本消歧）。
///
/// 检索链路严格串行分级：
/// 1. 第一级：本地同级/内嵌 `.lrc` 零网络直出；
/// 2. 伴奏门禁：`LyricVersionMatcher.isInstrumentalTrack` 命中 Off Vocal / Instrumental 立即短路；
/// 3. 第二级：LRCLIB 开源同步歌词 + `LyricVersionMatcher.selectBestCandidate` 版本与时长消歧；
/// 4. 第三级：AMLL TTML 开源逐字与和声库（移动计量网络下经 `evaluateLookupDirective` 强制弹窗确认）；
/// 5. 第四级：公开社区双语歌词兜底源 + 版本消歧。
class LyricLookupCoordinator {
  /// 创建四级歌词检索协调器。
  LyricLookupCoordinator({
    required this.playbackEngine,
    required this.lookupService,
    this.meteredNetworkDetector = const MeteredNetworkDetector(),
    this.logStore,
  });

  /// 统一四维代数播放引擎（仅取消/隔离 `PlaybackTaskDomain.lyricLookup` 域）。
  final UnifiedPlaybackEngine playbackEngine;

  /// 底层开源歌词 HTTP 检索服务。
  final OnlineLyricLookupService lookupService;

  /// 移动计量网络状态探测器。
  final MeteredNetworkDetector meteredNetworkDetector;

  /// 诊断日志存储。
  final DiagnosticsLogStore? logStore;

  /// 立即作废当前一切在途歌词检索任务（切歌或停止播放时调用，不影响其余三个异步域）。
  void cancelPendingLookups() {
    playbackEngine.cancelTaskDomain(PlaybackTaskDomain.lyricLookup);
  }

  /// 执行四级开源歌词检索与版本消歧，并在每个异步边界核验 `PlaybackTaskDomain.lyricLookup` 令牌有效性。
  Future<LyricLookupOutcome> lookupForTrack({
    required String trackTitle,
    required String fileName,
    String artist = '',
    double? durationSeconds,
    LrcDocument? localLrc,
    List<ActiveSpanLyricLine> localActiveSpans = const [],
    bool mobileAmllConfirmed = false,
  }) async {
    final token = playbackEngine.acquireTaskToken(
      PlaybackTaskDomain.lyricLookup,
    );

    // 第一级：本地外挂/内嵌歌词命中直接返回，零网络请求。
    if (localLrc != null && localLrc.lines.isNotEmpty) {
      return LyricLookupOutcome(
        lrcDocument: localLrc,
        activeSpanLines: localActiveSpans,
        matchedTier: LyricLookupTier.localSidecar,
      );
    }

    // 伴奏 / Off Vocal / 纯音乐门禁短路，严禁向远端抓取误匹配歌词。
    if (LyricVersionMatcher.isInstrumentalTrack(
      title: trackTitle,
      fileName: fileName,
    )) {
      return const LyricLookupOutcome(shortCircuitedInstrumental: true);
    }

    final initialDirective = LyricVersionMatcher.evaluateLookupDirective(
      title: trackTitle,
      fileName: fileName,
    );
    if (initialDirective == LyricLookupDirective.shortCircuitInstrumental) {
      return const LyricLookupOutcome(shortCircuitedInstrumental: true);
    }

    // 第二级：LRCLIB 开源精确歌词库。
    try {
      final lrclibCandidates = await lookupService.searchLrclib(
        title: trackTitle,
        artist: artist,
      );
      if (!playbackEngine.isTaskAlive(token)) {
        return const LyricLookupOutcome(staleAborted: true);
      }
      final picked = _pickAndParseCandidate(
        candidates: lrclibCandidates,
        trackTitle: trackTitle,
        artist: artist,
        durationSeconds: durationSeconds,
      );
      if (picked != null) return picked;
    } on Object catch (e) {
      logStore?.record('AUDIO-LYRIC', 'LRCLIB 检索降级忽略：$e');
    }

    if (!playbackEngine.isTaskAlive(token)) {
      return const LyricLookupOutcome(staleAborted: true);
    }

    // 第三级：AMLL TTML 逐字/和声开源索引（移动计量网络下先征求用户确认）。
    final isMetered = await meteredNetworkDetector.isMeteredMobileNetwork();
    if (!playbackEngine.isTaskAlive(token)) {
      return const LyricLookupOutcome(staleAborted: true);
    }
    final amllDirective = LyricVersionMatcher.evaluateLookupDirective(
      title: trackTitle,
      fileName: fileName,
      targetingAmllIndex: true,
      isMeteredMobileNetwork: isMetered,
      mobileAmllConfirmed: mobileAmllConfirmed,
    );
    if (amllDirective == LyricLookupDirective.promptMobileAmllConfirmation) {
      return const LyricLookupOutcome(needsMobileAmllConfirmation: true);
    }

    try {
      final amllCandidates = await lookupService.searchAmllTtmlDb(
        title: trackTitle,
        artist: artist,
        durationSeconds: durationSeconds,
      );
      if (!playbackEngine.isTaskAlive(token)) {
        return const LyricLookupOutcome(staleAborted: true);
      }
      final picked = _pickAndParseCandidate(
        candidates: amllCandidates,
        trackTitle: trackTitle,
        artist: artist,
        durationSeconds: durationSeconds,
      );
      if (picked != null) return picked;
    } on Object catch (e) {
      logStore?.record('AUDIO-LYRIC', 'AMLL 逐字索引检索降级忽略：$e');
    }

    if (!playbackEngine.isTaskAlive(token)) {
      return const LyricLookupOutcome(staleAborted: true);
    }

    // 第四级：公开社区双语歌词兜底源。
    try {
      final fallbackCandidates = await lookupService.searchCommunityFallback(
        title: trackTitle,
        artist: artist,
      );
      if (!playbackEngine.isTaskAlive(token)) {
        return const LyricLookupOutcome(staleAborted: true);
      }
      final picked = _pickAndParseCandidate(
        candidates: fallbackCandidates,
        trackTitle: trackTitle,
        artist: artist,
        durationSeconds: durationSeconds,
      );
      if (picked != null) return picked;
    } on Object catch (e) {
      logStore?.record('AUDIO-LYRIC', '社区兜底歌词检索降级忽略：$e');
    }

    return const LyricLookupOutcome();
  }

  LyricLookupOutcome? _pickAndParseCandidate({
    required List<OnlineLyricCandidate> candidates,
    required String trackTitle,
    required String artist,
    required double? durationSeconds,
  }) {
    if (candidates.isEmpty) return null;
    final bestMeta = LyricVersionMatcher.selectBestCandidate(
      trackTitle: trackTitle,
      trackArtist: artist,
      trackDurationSeconds: durationSeconds,
      candidates: [for (final c in candidates) c.meta],
    );
    if (bestMeta == null) return null;
    OnlineLyricCandidate? matched;
    for (final c in candidates) {
      if (c.meta.id == bestMeta.id) {
        matched = c;
        break;
      }
    }
    if (matched == null) return null;
    final parsedLrc = LrcParser.parseText(matched.lrcContent);
    if (parsedLrc.lines.isEmpty) return null;
    final spans = LyricVersionMatcher.parseActiveSpanLines(matched.lrcContent);
    final hasEnhancedSpans = spans.any(
      (line) =>
          line.spans.length > 1 || line.spans.any((span) => span.isHarmony),
    );
    return LyricLookupOutcome(
      lrcDocument: parsedLrc,
      activeSpanLines: hasEnhancedSpans ? spans : const [],
      matchedTier: matched.tier,
      matchedCandidate: matched.meta,
    );
  }
}

/// 移动计量网络探测器 Provider。
final meteredNetworkDetectorProvider = Provider<MeteredNetworkDetector>(
  (ref) => const MeteredNetworkDetector(),
);

/// 开源歌词网络检索服务 Provider。
final onlineLyricLookupServiceProvider = Provider<OnlineLyricLookupService>((
  ref,
) {
  final service = OnlineLyricLookupService();
  ref.onDispose(service.dispose);
  return service;
});

/// 四级开源歌词检索协调器 Provider（绑定 `UnifiedPlaybackEngine` 与 `PlaybackTaskDomain.lyricLookup`）。
final lyricLookupCoordinatorProvider = Provider<LyricLookupCoordinator>(
  (ref) => LyricLookupCoordinator(
    playbackEngine: ref.read(unifiedPlaybackEngineProvider),
    lookupService: ref.read(onlineLyricLookupServiceProvider),
    meteredNetworkDetector: ref.read(meteredNetworkDetectorProvider),
    logStore: ref.read(diagnosticsLogStoreProvider),
  ),
);
