import 'package:konata_contracts/konata_contracts.dart';

/// 详情页主播放按钮及续播推荐的强类型计算结果。
class PlaybackResumePlan {
  /// 创建续播计划。
  const PlaybackResumePlan({
    required this.targetEpisode,
    required this.startSeconds,
    required this.buttonLabel,
    required this.isResume,
  });

  /// 主播放按钮将直接播放的目标逻辑集。
  final EpisodeSummaryView targetEpisode;

  /// 若需要断点续播则携带精确秒数，否则为 `0`。
  final int startSeconds;

  /// 主按钮展示文案（有播放进度或自动推进时显示 `继续播放`，否则显示 `开始播放`）。
  final String buttonLabel;

  /// 是否基于既有观看记录自动推演的续播动作。
  final bool isResume;
}

/// 纯领域续播推演器：严格实现未完播秒级续播与完播后自动推进下一集规则。
class PlaybackResumeResolver {
  const PlaybackResumeResolver._();

  /// 根据剧集列表与最近/分集播放进度计算主播放按钮目标与文案。
  static PlaybackResumePlan? resolve({
    required List<EpisodeSummaryView> episodes,
    PlaybackResumeView? latestPlayback,
    Map<EpisodeId, PlaybackResumeView> playbackByEpisodeId = const {},
    String? workTitle,
    TmdbMediaType? workMediaType,
  }) {
    final playableEpisodes = _sortedPlayableEpisodes(episodes);
    if (playableEpisodes.isEmpty) {
      return null;
    }

    if (latestPlayback != null) {
      final latestEp = _findEpisodeById(
        playableEpisodes,
        latestPlayback.episodeId,
      );

      // 情况 1：最近观看集未完播 -> 超过 5 秒记录精确断点续播秒数，主按钮统一显示「继续播放」
      if (latestEp != null && !latestPlayback.completed) {
        return PlaybackResumePlan(
          targetEpisode: latestEp,
          startSeconds: latestPlayback.positionSeconds > 5
              ? latestPlayback.positionSeconds
              : 0,
          buttonLabel: '继续播放',
          isResume: true,
        );
      }

      // 情况 2：最近一集已看完 -> 自动推进下一集（若下一集有未完播进度一并带上）
      if (latestEp != null && latestPlayback.completed) {
        final nextEp = _findNextEpisode(playableEpisodes, latestEp);
        if (nextEp != null) {
          final nextRecord = playbackByEpisodeId[nextEp.id];
          final startSec =
              (nextRecord != null &&
                  !nextRecord.completed &&
                  nextRecord.positionSeconds > 5)
              ? nextRecord.positionSeconds
              : 0;
          return PlaybackResumePlan(
            targetEpisode: nextEp,
            startSeconds: startSec,
            buttonLabel: '继续播放',
            isResume: true,
          );
        }
      }
    }

    // 情况 3：无历史记录或已看完最后一集 -> 返回首集与标准默认主按钮文案「开始播放」。
    final first = playableEpisodes.first;
    return PlaybackResumePlan(
      targetEpisode: first,
      startSeconds: 0,
      buttonLabel: '开始播放',
      isResume: false,
    );
  }

  static List<EpisodeSummaryView> _sortedPlayableEpisodes(
    List<EpisodeSummaryView> all,
  ) {
    final mains =
        all.where((e) => e.category == EpisodeCategory.main).toList()
          ..sort((a, b) {
            final s = a.seasonNumber.compareTo(b.seasonNumber);
            if (s != 0) {
              return s;
            }
            return (a.episodeNumber ?? 1 << 20).compareTo(
              b.episodeNumber ?? 1 << 20,
            );
          });
    if (mains.isNotEmpty) {
      return mains;
    }

    final sortedAll = [...all]
      ..sort((a, b) {
        final s = a.seasonNumber.compareTo(b.seasonNumber);
        if (s != 0) {
          return s;
        }
        return (a.episodeNumber ?? 1 << 20).compareTo(
          b.episodeNumber ?? 1 << 20,
        );
      });
    return sortedAll;
  }

  static EpisodeSummaryView? _findEpisodeById(
    List<EpisodeSummaryView> list,
    EpisodeId id,
  ) {
    for (final ep in list) {
      if (ep.id == id) {
        return ep;
      }
    }
    return null;
  }

  static EpisodeSummaryView? _findNextEpisode(
    List<EpisodeSummaryView> ordered,
    EpisodeSummaryView current,
  ) {
    final idx = ordered.indexWhere((e) => e.id == current.id);
    if (idx >= 0 && idx + 1 < ordered.length) {
      return ordered[idx + 1];
    }
    return null;
  }
}
