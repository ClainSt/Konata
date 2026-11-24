import 'dart:async';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_candidate_scorer.dart';
import '../../domain/lyrics/lyric_search_query.dart';
import '../../infrastructure/lyrics/amll_lyric_provider.dart';
import '../../infrastructure/lyrics/lrclib_lyric_provider.dart';
import '../../infrastructure/lyrics/netease_lyric_provider.dart';
import '../../infrastructure/lyrics/qqmusic_lyric_provider.dart';

/// 可并行竞速的歌词候选来源（流式产出候选，出错以流错误上报）。
abstract interface class LyricCandidateSource {
  /// 来源标签（用于诊断日志）。
  String get label;

  /// 产出候选流；流正常结束视为该来源已有效响应。
  Stream<LyricCandidate> candidates(LyricSearchQuery query);
}

/// 统一的取消安全候选流包装器：避免 `async*` 在订阅取消后因在途 HTTP 超时抛出未捕获异常。
Stream<LyricCandidate> _guardCandidateStream(
  Future<void> Function(
    void Function(LyricCandidate candidate) emit,
    void Function(Object error, StackTrace st) emitError,
    bool Function() isCancelled,
  )
  body,
) {
  final controller = StreamController<LyricCandidate>();
  var cancelled = false;
  controller.onCancel = () {
    cancelled = true;
  };
  controller.onListen = () {
    unawaited(() async {
      try {
        await body(
          (candidate) {
            if (!cancelled && !controller.isClosed) {
              controller.add(candidate);
            }
          },
          (error, st) {
            if (!cancelled && !controller.isClosed) {
              controller.addError(error, st);
            }
          },
          () => cancelled || controller.isClosed,
        );
      } on Object catch (e, st) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(e, st);
        }
      } finally {
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }());
  };
  return controller.stream;
}

/// LRCLIB 候选来源（优先 `/api/get` 精确时长匹配，未命中回退 `/api/search` 及别名降级搜索）。
class LrclibCandidateSource implements LyricCandidateSource {
  /// 创建候选来源。
  const LrclibCandidateSource(this._provider);

  final LrclibLyricProvider _provider;

  @override
  String get label => 'LRCLIB';

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) {
    return _guardCandidateStream((emit, _, isCancelled) async {
      final firstBatch = await _provider.fetchCandidates(query);
      if (isCancelled()) return;
      var hasQualifiedSynced = false;
      final ranked = <({LyricCandidate candidate, double score})>[];
      for (final c in firstBatch) {
        final score = LyricCandidateScorer.score(query, c);
        if (c.isSynced &&
            score != null &&
            score >= LyricMatchThresholds.lowConfidence) {
          hasQualifiedSynced = true;
        }
        ranked.add((candidate: c, score: score ?? -1.0));
      }
      // 按同步优先与基础分降序输出，保证高分匹配优先参与首屏与跨源验证短路。
      ranked.sort((a, b) {
        if (a.candidate.isSynced != b.candidate.isSynced) {
          return a.candidate.isSynced ? -1 : 1;
        }
        return b.score.compareTo(a.score);
      });
      for (final entry in ranked) {
        if (isCancelled()) return;
        emit(entry.candidate);
      }
      if (hasQualifiedSynced || isCancelled()) return;

      // 仅在首轮无合格同步候选时，使用清洗后的核心别名或声优名做一次轻量降级补搜。
      final aliases = query.titleAliases;
      final artists = query.searchArtists;
      final altTitle = aliases.length > 1 ? aliases[1] : query.title;
      final altArtist = artists.isNotEmpty ? artists.first : '';
      if (altTitle == query.title && altArtist == query.artist.trim()) return;
      final retry = await _provider.search(
        query,
        titleOverride: altTitle,
        artistOverride: altArtist,
      );
      if (isCancelled()) return;
      for (final c in retry) {
        emit(c);
      }
    });
  }
}

/// 网易云 + AMLL 联合候选来源：一次搜索拿到歌曲 ID 后，并行拉取网易云歌词（含译文与罗马音）与 AMLL 逐字 TTML。
class NeteaseAmllCandidateSource implements LyricCandidateSource {
  /// 创建联合候选来源。
  const NeteaseAmllCandidateSource({
    required this._netease,
    required this._amll,
    this.includeNetease = true,
    this.includeAmll = true,
    this.onAmllError,
  });

  final NeteaseLyricProvider _netease;
  final AmllLyricProvider _amll;

  /// 是否产出网易云歌词候选。
  final bool includeNetease;

  /// 是否按网易云 ID 并行拉取 AMLL TTML 逐字歌词。
  final bool includeAmll;

  /// AMLL 镜像异常回调（AMLL 失败不影响网易云结果与负缓存判定）。
  final void Function(Object error)? onAmllError;

  @override
  String get label => '网易云/AMLL';

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) {
    return _guardCandidateStream((emit, emitError, isCancelled) async {
      if (!includeNetease && !includeAmll) return;
      final rankedHits = await _searchWithFallback(query, isCancelled);
      if (rankedHits.isEmpty || isCancelled()) return;

      // 优先使用元数据得分最高的命中；若其歌词为占位或缺失，再顺延尝试次优命中。
      final top = rankedHits.first;
      LyricCandidate? neteaseResult;
      final tasks = <Future<void>>[
        if (includeNetease)
          _netease.fetchLyric(top).then<void>(
            (c) {
              neteaseResult = c;
              if (c != null) emit(c);
            },
            onError: emitError,
          ),
        if (includeAmll)
          _amll.fetchByNeteaseHit(top).then<void>(
            (c) {
              if (c != null) emit(c);
            },
            onError: (Object e) => onAmllError?.call(e),
          ),
      ];
      await Future.wait<void>(tasks);

      if (includeNetease &&
          neteaseResult == null &&
          rankedHits.length > 1 &&
          !isCancelled()) {
        final fallback = await _netease.fetchLyric(rankedHits[1]);
        if (fallback != null) emit(fallback);
      }
    });
  }

  Future<List<NeteaseSongHit>> _searchWithFallback(
    LyricSearchQuery query,
    bool Function() isCancelled,
  ) async {
    final keywords = query.buildSearchKeywords();
    final maxSteps = keywords.length > 3 ? 3 : keywords.length;
    for (var i = 0; i < maxSteps; i++) {
      if (isCancelled()) return const [];
      final hits = await _netease.searchSongs(
        query,
        keywordOverride: i == 0 ? null : keywords[i],
      );
      final ranked = _rankHits(query, hits);
      if (ranked.isNotEmpty) return ranked;
    }
    return const [];
  }

  static List<NeteaseSongHit> _rankHits(
    LyricSearchQuery query,
    List<NeteaseSongHit> hits,
  ) {
    final scored = <({NeteaseSongHit hit, double score})>[];
    for (final hit in hits) {
      final score = LyricCandidateScorer.scoreMetadata(
        query,
        title: hit.title,
        artist: hit.artist,
        album: hit.album,
        durationSeconds: hit.durationSeconds,
      );
      if (score != null && score >= LyricMatchThresholds.lowConfidence) {
        scored.add((hit: hit, score: score));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return [for (final s in scored.take(2)) s.hit];
  }
}

/// QQ 音乐非官方公开接口候选来源（默认关闭，用户确认免责声明并开启后参与并行竞速）。
class QqMusicCandidateSource implements LyricCandidateSource {
  /// 创建候选来源。
  const QqMusicCandidateSource(this._provider);

  final QqMusicLyricProvider _provider;

  @override
  String get label => 'QQ音乐';

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) {
    return _guardCandidateStream((emit, _, isCancelled) async {
      final keywords = query.buildSearchKeywords();
      final maxSteps = keywords.length > 3 ? 3 : keywords.length;
      List<QqMusicSongHit> ranked = const [];
      for (var i = 0; i < maxSteps; i++) {
        if (isCancelled()) return;
        final hits = await _provider.searchSongs(
          query,
          keywordOverride: i == 0 ? null : keywords[i],
        );
        ranked = _rankHits(query, hits);
        if (ranked.isNotEmpty) break;
      }
      if (ranked.isEmpty || isCancelled()) return;

      for (final hit in ranked) {
        if (isCancelled()) return;
        final candidate = await _provider.fetchLyric(hit);
        if (candidate != null) {
          emit(candidate);
          return;
        }
      }
    });
  }

  static List<QqMusicSongHit> _rankHits(
    LyricSearchQuery query,
    List<QqMusicSongHit> hits,
  ) {
    final scored = <({QqMusicSongHit hit, double score})>[];
    for (final hit in hits) {
      final score = LyricCandidateScorer.scoreMetadata(
        query,
        title: hit.title,
        artist: hit.artist,
        album: hit.album,
        durationSeconds: hit.durationSeconds,
      );
      if (score != null && score >= LyricMatchThresholds.lowConfidence) {
        scored.add((hit: hit, score: score));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return [for (final s in scored.take(2)) s.hit];
  }
}
