import 'dart:async';

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/lyrics/lyric_candidate_scorer.dart';
import '../../domain/lyrics/lyric_search_query.dart';
import '../../infrastructure/lyrics/amll_lyric_provider.dart';
import '../../infrastructure/lyrics/lrclib_lyric_provider.dart';
import '../../infrastructure/lyrics/netease_lyric_provider.dart';

/// 可并行竞速的歌词候选来源（流式产出候选，出错以流错误上报）。
abstract interface class LyricCandidateSource {
  /// 来源标签（用于诊断日志）。
  String get label;

  /// 产出候选流；流正常结束视为该来源已有效响应。
  Stream<LyricCandidate> candidates(LyricSearchQuery query);
}

/// LRCLIB 候选来源。
class LrclibCandidateSource implements LyricCandidateSource {
  /// 创建候选来源。
  const LrclibCandidateSource(this._provider);

  final LrclibLyricProvider _provider;

  @override
  String get label => 'LRCLIB';

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) async* {
    yield* Stream.fromIterable(await _provider.search(query));
  }
}

/// 网易云 + AMLL 联合候选来源：一次搜索拿到歌曲 ID 后，并行拉取网易云歌词与 AMLL 逐字 TTML。
class NeteaseAmllCandidateSource implements LyricCandidateSource {
  /// 创建联合候选来源。
  const NeteaseAmllCandidateSource({
    required this._netease,
    required this._amll,
    this.onAmllError,
  });

  final NeteaseLyricProvider _netease;
  final AmllLyricProvider _amll;

  /// AMLL 镜像异常回调（AMLL 失败不影响网易云结果与负缓存判定）。
  final void Function(Object error)? onAmllError;

  @override
  String get label => '网易云/AMLL';

  @override
  Stream<LyricCandidate> candidates(LyricSearchQuery query) {
    final controller = StreamController<LyricCandidate>();
    Future<void> run() async {
      try {
        final hits = await _netease.searchSongs(query);
        final best = _pickBestHit(query, hits);
        if (best == null) return;
        await Future.wait<void>([
          _netease.fetchLyric(best).then<void>(
            (c) {
              if (c != null && !controller.isClosed) controller.add(c);
            },
            onError: (Object e, StackTrace st) {
              if (!controller.isClosed) controller.addError(e, st);
            },
          ),
          _amll.fetchByNeteaseHit(best).then<void>(
            (c) {
              if (c != null && !controller.isClosed) controller.add(c);
            },
            onError: (Object e) => onAmllError?.call(e),
          ),
        ]);
      } on Object catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        if (!controller.isClosed) await controller.close();
      }
    }

    controller.onListen = () => unawaited(run());
    return controller.stream;
  }

  static NeteaseSongHit? _pickBestHit(
    LyricSearchQuery query,
    List<NeteaseSongHit> hits,
  ) {
    NeteaseSongHit? best;
    var bestScore = LyricMatchThresholds.lowConfidence;
    for (final hit in hits) {
      final score = LyricCandidateScorer.scoreMetadata(
        query,
        title: hit.title,
        artist: hit.artist,
        album: hit.album,
        durationSeconds: hit.durationSeconds,
      );
      if (score != null && score > bestScore) {
        bestScore = score;
        best = hit;
      }
    }
    return best;
  }
}
