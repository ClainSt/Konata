import '../models/episode.dart';

/// Bangumi 观看进度同步模式。
enum BangumiSyncMode {
  /// 双向合并：拉取 Bangumi 已看集数补齐本地，并将本地已看集数批量上报至 Bangumi。
  bidirectional('双向同步'),

  /// 仅上报：仅将本地看完进度单向上报至 Bangumi，不修改本地观看记录。
  pushOnly('仅上报进度');

  const BangumiSyncMode(this.label);

  /// 简体中文界面展示名。
  final String label;
}

/// Bangumi 收藏状态常量（对应官方 v0 API `type` 枚举）。
abstract final class BangumiCollectionType {
  /// 想看。
  static const int wish = 1;

  /// 看过。
  static const int collect = 2;

  /// 在看。
  static const int doing = 3;

  /// 搁置。
  static const int onHold = 4;

  /// 抛弃。
  static const int dropped = 5;
}

/// Bangumi 单集观看状态常量（对应官方 v0 API 章节 `type` 枚举）。
abstract final class BangumiEpisodeWatchStatus {
  /// 未看。
  static const int unwatched = 0;

  /// 想看。
  static const int wish = 1;

  /// 看过。
  static const int watched = 2;

  /// 抛弃。
  static const int dropped = 3;
}

/// 已通过 PAT 验证的 Bangumi 公开账号信息（非敏感元数据）。
class BangumiUserProfile {
  /// 创建 Bangumi 账号信息。
  const BangumiUserProfile({
    required this.id,
    required this.username,
    required this.nickname,
    this.avatarUrl = '',
  });

  final int id;
  final String username;
  final String nickname;
  final String avatarUrl;

  /// 用于设置页展示的简明账号标签。
  String get displayLabel =>
      nickname.trim().isNotEmpty ? '$nickname (@$username)' : '@$username';

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'username': username,
    'nickname': nickname,
    'avatarUrl': avatarUrl,
  };

  factory BangumiUserProfile.fromJson(Map<String, Object?> json) {
    final avatarRaw = json['avatar'];
    var avatarUrl = (json['avatarUrl'] ?? '').toString();
    if (avatarUrl.isEmpty && avatarRaw is Map) {
      avatarUrl =
          (avatarRaw['medium'] ?? avatarRaw['large'] ?? avatarRaw['small'] ?? '')
              .toString();
    }
    return BangumiUserProfile(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: (json['username'] ?? '').toString(),
      nickname: (json['nickname'] ?? '').toString(),
      avatarUrl: avatarUrl,
    );
  }
}

/// Bangumi PAT 同步持久化配置（PAT 仅保存在安全存储，绝不进入日志或备份）。
class BangumiSyncConfig {
  /// Bangumi 官方个人访问令牌生成页地址。
  static const String tokenPortalUrl = 'https://next.bgm.tv/demo/access-token';

  /// 创建 Bangumi 同步配置。
  const BangumiSyncConfig({
    this.enabled = false,
    this.personalAccessToken = '',
    this.syncMode = BangumiSyncMode.bidirectional,
    this.autoPushOnComplete = true,
    this.autoMarkSubjectCompleted = true,
  });

  final bool enabled;
  final String personalAccessToken;
  final BangumiSyncMode syncMode;
  final bool autoPushOnComplete;
  final bool autoMarkSubjectCompleted;

  /// 是否已填写非空 PAT 令牌。
  bool get hasToken => personalAccessToken.trim().isNotEmpty;

  BangumiSyncConfig copyWith({
    bool? enabled,
    String? personalAccessToken,
    BangumiSyncMode? syncMode,
    bool? autoPushOnComplete,
    bool? autoMarkSubjectCompleted,
  }) {
    return BangumiSyncConfig(
      enabled: enabled ?? this.enabled,
      personalAccessToken: personalAccessToken ?? this.personalAccessToken,
      syncMode: syncMode ?? this.syncMode,
      autoPushOnComplete: autoPushOnComplete ?? this.autoPushOnComplete,
      autoMarkSubjectCompleted:
          autoMarkSubjectCompleted ?? this.autoMarkSubjectCompleted,
    );
  }
}

/// Bangumi 远端单集与用户观看状态快照。
class BangumiRemoteEpisodeProgress {
  /// 创建远端单集进度项。
  const BangumiRemoteEpisodeProgress({
    required this.episodeId,
    required this.episodeType,
    required this.sort,
    this.ep,
    this.name = '',
    this.nameCn = '',
    this.watchStatus = BangumiEpisodeWatchStatus.unwatched,
  });

  /// Bangumi 全局单集 ID。
  final int episodeId;

  /// Bangumi 章节类型：`0` 为本篇，`1` 为 SP 特别篇。
  final int episodeType;

  /// 条目内章节序号（兼容浮点如 `1.5`，主线通常为整数）。
  final double sort;

  /// 季内相对集号（部分多季连播番剧 `sort` 累计而 `ep` 从 1 起算）。
  final double? ep;

  final String name;
  final String nameCn;

  /// 当前用户观看状态（`2` 为看过）。
  final int watchStatus;

  /// 是否为本篇正片章节。
  bool get isMainEpisode => episodeType == 0;

  /// 是否为 SP 特别篇章节。
  bool get isSpecialEpisode => episodeType == 1;

  /// 用户在 Bangumi 上是否已标记为看过。
  bool get isWatched => watchStatus == BangumiEpisodeWatchStatus.watched;
}

/// 单部作品与 Bangumi 双向进度同步结果。
class BangumiWorkSyncResult {
  /// 创建单作品同步结果。
  const BangumiWorkSyncResult({
    required this.workId,
    required this.subjectId,
    this.pulledWatchedCount = 0,
    this.pushedWatchedCount = 0,
    this.promotedCollectionTo,
    this.error,
  });

  final String workId;
  final int subjectId;
  final int pulledWatchedCount;
  final int pushedWatchedCount;
  final int? promotedCollectionTo;
  final String? error;

  bool get isSuccess => error == null;

  /// 生成用于 Toast 展示的简明中文结果。
  String toSummaryMessage() {
    if (error != null) return error!;
    final parts = <String>[];
    if (pulledWatchedCount > 0) parts.add('拉取 $pulledWatchedCount 集已看');
    if (pushedWatchedCount > 0) parts.add('上报 $pushedWatchedCount 集已看');
    if (promotedCollectionTo == BangumiCollectionType.collect) {
      parts.add('条目已标记为「看过」');
    } else if (promotedCollectionTo == BangumiCollectionType.doing) {
      parts.add('条目已标记为「在看」');
    }
    return parts.isEmpty ? '与 Bangumi 进度已一致' : parts.join(' · ');
  }
}

/// 全库 Bangumi 批量同步统计报告。
class BangumiLibrarySyncReport {
  /// 创建全库同步报告。
  const BangumiLibrarySyncReport({
    required this.worksProcessed,
    required this.worksSucceeded,
    required this.worksFailed,
    required this.totalPulled,
    required this.totalPushed,
    required this.queueFlushed,
    required this.remainingQueued,
    this.firstError,
  });

  final int worksProcessed;
  final int worksSucceeded;
  final int worksFailed;
  final int totalPulled;
  final int totalPushed;
  final int queueFlushed;
  final int remainingQueued;
  final String? firstError;

  String toSummaryMessage() {
    if (worksProcessed == 0 && queueFlushed == 0) {
      return '媒体库中暂无已绑定 Bangumi ID 的作品';
    }
    final parts = <String>[
      '同步 $worksSucceeded/$worksProcessed 部作品',
      if (totalPulled > 0) '拉取 $totalPulled 集',
      if (totalPushed > 0) '上报 $totalPushed 集',
      if (queueFlushed > 0) '补发队列 $queueFlushed 条',
      if (worksFailed > 0) '$worksFailed 部失败',
    ];
    return parts.join(' · ');
  }
}

/// 纯领域 Bangumi 单集对齐器：将本地逻辑剧集与 Bangumi 远端 `episodeId` 精确双向映射。
abstract final class BangumiEpisodeAligner {
  /// 根据本地剧集属性在远端章节列表中定位对应的 Bangumi 单集。
  ///
  /// 规则：
  /// 1. 本地正片有明确集号时，优先匹配 `isMainEpisode` 中 `ep == N`（适配续作独立计集），再匹配 `sort == N`；
  /// 2. 本地独立剧场版/单部正片（`episodeNumber == null` 且 `category == main`），若远端仅 1 集本篇或存在 `sort == 1`，自动对齐；
  /// 3. 本地 `seasonNumber == 0` 的特别篇（SP），按集号匹配 `isSpecialEpisode`。
  static BangumiRemoteEpisodeProgress? matchRemoteEpisode({
    required List<BangumiRemoteEpisodeProgress> remoteEpisodes,
    required int seasonNumber,
    required int? episodeNumber,
    bool isSpecial = false,
  }) {
    if (remoteEpisodes.isEmpty) return null;
    final wantSp = isSpecial || seasonNumber == 0;
    final pool = remoteEpisodes
        .where((e) => wantSp ? e.isSpecialEpisode : e.isMainEpisode)
        .toList(growable: false);
    if (pool.isEmpty) return null;

    if (episodeNumber == null) {
      if (wantSp) return null;
      if (pool.length == 1) return pool.first;
      for (final item in pool) {
        if ((item.ep != null && (item.ep! - 1.0).abs() < 0.001) ||
            (item.sort - 1.0).abs() < 0.001) {
          return item;
        }
      }
      return null;
    }

    final target = episodeNumber.toDouble();
    for (final item in pool) {
      if (item.ep != null && (item.ep! - target).abs() < 0.001) {
        return item;
      }
    }
    for (final item in pool) {
      if ((item.sort - target).abs() < 0.001) {
        return item;
      }
    }
    return null;
  }

  /// 将 Bangumi 远端单集反查至本地对应的逻辑剧集 [Episode]。
  static Episode? matchLocalEpisode({
    required List<Episode> localEpisodes,
    required BangumiRemoteEpisodeProgress remoteEpisode,
  }) {
    if (localEpisodes.isEmpty) return null;
    final targetNum = _asWholeNumber(remoteEpisode.ep) ??
        _asWholeNumber(remoteEpisode.sort);

    if (remoteEpisode.isMainEpisode) {
      final mainEps = localEpisodes
          .where((e) => e.category == EpisodeCategory.main)
          .toList(growable: false);
      if (targetNum != null) {
        for (final ep in mainEps) {
          if (ep.episodeNumber == targetNum) return ep;
        }
      }
      if (mainEps.length == 1 &&
          mainEps.first.episodeNumber == null &&
          targetNum == 1) {
        return mainEps.first;
      }
      return null;
    }

    if (remoteEpisode.isSpecialEpisode && targetNum != null) {
      for (final ep in localEpisodes) {
        if (ep.seasonNumber == 0 && ep.episodeNumber == targetNum) {
          return ep;
        }
      }
    }
    return null;
  }

  static int? _asWholeNumber(double? value) {
    if (value == null || value <= 0) return null;
    final rounded = value.round();
    if ((value - rounded).abs() > 0.001) return null;
    return rounded;
  }
}
