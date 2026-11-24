import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// Bangumi 追番同步模式。
enum BangumiSyncMode {
  /// 自动补齐剧集并按观看进度更新收藏状态。
  autoCompleteAndPush,

  /// 仅向 Bangumi 推送本地已完成集数。
  pushOnly,
}

/// Bangumi 追番同步模式文案扩展。
extension BangumiSyncModeX on BangumiSyncMode {
  /// 持久化键值。
  String get wireName => switch (this) {
    BangumiSyncMode.autoCompleteAndPush => 'auto_complete_and_push',
    BangumiSyncMode.pushOnly => 'push_only',
  };

  /// 界面展示标题。
  String get label => switch (this) {
    BangumiSyncMode.autoCompleteAndPush => '双向对齐并自动标记看过',
    BangumiSyncMode.pushOnly => '仅单向推送本地进度',
  };

  /// 从持久化字段解析同步模式。
  static BangumiSyncMode fromWireName(String? raw) {
    for (final value in BangumiSyncMode.values) {
      if (value.wireName == raw) {
        return value;
      }
    }
    return BangumiSyncMode.autoCompleteAndPush;
  }
}

/// Bangumi 作品收藏状态码。
enum BangumiCollectionType {
  /// 想看。
  wish(1),

  /// 看过。
  collect(2),

  /// 在看。
  doing(3),

  /// 搁置。
  onHold(4),

  /// 抛弃。
  dropped(5);

  const BangumiCollectionType(this.apiValue);

  /// Bangumi 接口整数枚举值。
  final int apiValue;

  /// 中文展示标签。
  String get label => switch (this) {
    BangumiCollectionType.wish => '想看',
    BangumiCollectionType.collect => '看过',
    BangumiCollectionType.doing => '在看',
    BangumiCollectionType.onHold => '搁置',
    BangumiCollectionType.dropped => '抛弃',
  };

  /// 从接口整数值解析收藏类型。
  static BangumiCollectionType? fromApiValue(int? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in BangumiCollectionType.values) {
      if (value.apiValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Bangumi 单集观看状态码。
enum BangumiEpisodeWatchStatus {
  /// 未看过。
  unwatched(0),

  /// 想看。
  wish(1),

  /// 已看过。
  watched(2),

  /// 已抛弃。
  dropped(3);

  const BangumiEpisodeWatchStatus(this.apiValue);

  /// Bangumi 接口整数枚举值。
  final int apiValue;

  /// 从接口整数值解析单集状态。
  static BangumiEpisodeWatchStatus fromApiValue(int? raw) {
    for (final value in BangumiEpisodeWatchStatus.values) {
      if (value.apiValue == raw) {
        return value;
      }
    }
    return BangumiEpisodeWatchStatus.unwatched;
  }
}

/// Bangumi 鉴权失效异常（401 或 403）。
final class BangumiAuthException implements Exception {
  /// 创建鉴权异常实例。
  const BangumiAuthException({
    required this.statusCode,
    required this.message,
  });

  /// 服务返回的 HTTP 状态码。
  final int statusCode;

  /// 已脱敏的错误说明。
  final String message;

  @override
  String toString() => 'BangumiAuthException($statusCode): $message';
}

/// Bangumi 接口调用通用异常。
final class BangumiApiException implements Exception {
  /// 创建接口异常实例。
  const BangumiApiException({
    required this.message,
    this.statusCode,
    this.retryable = true,
  });

  /// HTTP 状态码，传输层失败时可为空。
  final int? statusCode;

  /// 已脱敏的错误描述。
  final String message;

  /// 是否允许队列退避重试。
  final bool retryable;

  @override
  String toString() => 'BangumiApiException($statusCode, retryable=$retryable): $message';
}

/// 已验证的 Bangumi 用户资料摘要。
final class BangumiUserProfile {
  /// 创建用户资料摘要。
  const BangumiUserProfile({
    required this.id,
    required this.username,
    required this.nickname,
    this.avatarUrl,
  });

  /// 用户数字编号。
  final int id;

  /// 用户唯一用户名。
  final String username;

  /// 用户显示昵称。
  final String nickname;

  /// 头像地址（可选）。
  final String? avatarUrl;

  /// 序列化为 JSON 映射。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'username': username,
    'nickname': nickname,
    if (avatarUrl != null && avatarUrl!.isNotEmpty) 'avatarUrl': avatarUrl,
  };

  /// 从 JSON 映射反序列化。
  static BangumiUserProfile? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final idRaw = raw['id'];
    final id = idRaw is int ? idRaw : int.tryParse(idRaw?.toString() ?? '');
    final username = (raw['username'] ?? '').toString().trim();
    final nickname = (raw['nickname'] ?? '').toString().trim();
    if (id == null || (username.isEmpty && nickname.isEmpty)) {
      return null;
    }
    final avatar = (raw['avatarUrl'] ?? '').toString().trim();
    return BangumiUserProfile(
      id: id,
      username: username,
      nickname: nickname.isEmpty ? username : nickname,
      avatarUrl: avatar.isEmpty ? null : avatar,
    );
  }
}

/// Bangumi 追番同步配置模型（不含 PAT 明文凭据）。
final class BangumiSyncConfig {
  /// 创建 Bangumi 同步配置。
  const BangumiSyncConfig({
    this.enabled = true,
    this.autoSyncOnEpisodeComplete = true,
    this.autoMarkCollectionCompleted = true,
    this.syncMode = BangumiSyncMode.autoCompleteAndPush,
    this.verifiedProfile,
    this.lastFullSyncAtMs,
  });

  /// 是否启用 Bangumi 追番同步。
  final bool enabled;

  /// 单集完播后是否自动入队同步。
  final bool autoSyncOnEpisodeComplete;

  /// 全部正片看完后是否自动将条目设为「看过」。
  final bool autoMarkCollectionCompleted;

  /// 同步策略模式。
  final BangumiSyncMode syncMode;

  /// 最近一次验证成功的账号信息。
  final BangumiUserProfile? verifiedProfile;

  /// 最近一次全库同步完成的 UTC 毫秒时间戳。
  final int? lastFullSyncAtMs;

  /// 复制并修改部分配置项。
  BangumiSyncConfig copyWith({
    bool? enabled,
    bool? autoSyncOnEpisodeComplete,
    bool? autoMarkCollectionCompleted,
    BangumiSyncMode? syncMode,
    BangumiUserProfile? verifiedProfile,
    bool clearVerifiedProfile = false,
    int? lastFullSyncAtMs,
    bool clearLastFullSyncAt = false,
  }) {
    return BangumiSyncConfig(
      enabled: enabled ?? this.enabled,
      autoSyncOnEpisodeComplete:
          autoSyncOnEpisodeComplete ?? this.autoSyncOnEpisodeComplete,
      autoMarkCollectionCompleted:
          autoMarkCollectionCompleted ?? this.autoMarkCollectionCompleted,
      syncMode: syncMode ?? this.syncMode,
      verifiedProfile: clearVerifiedProfile
          ? null
          : (verifiedProfile ?? this.verifiedProfile),
      lastFullSyncAtMs: clearLastFullSyncAt
          ? null
          : (lastFullSyncAtMs ?? this.lastFullSyncAtMs),
    );
  }

  /// 序列化为偏好存储 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'autoSyncOnEpisodeComplete': autoSyncOnEpisodeComplete,
    'autoMarkCollectionCompleted': autoMarkCollectionCompleted,
    'syncMode': syncMode.wireName,
    if (verifiedProfile != null) 'verifiedProfile': verifiedProfile!.toJson(),
    if (lastFullSyncAtMs != null) 'lastFullSyncAtMs': lastFullSyncAtMs,
  };

  /// 从偏好存储 JSON 反序列化。
  static BangumiSyncConfig fromJson(Object? raw) {
    if (raw is! Map) {
      return const BangumiSyncConfig();
    }
    final lastMsRaw = raw['lastFullSyncAtMs'];
    final lastMs = lastMsRaw is int
        ? lastMsRaw
        : int.tryParse(lastMsRaw?.toString() ?? '');
    return BangumiSyncConfig(
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      autoSyncOnEpisodeComplete: raw['autoSyncOnEpisodeComplete'] is bool
          ? raw['autoSyncOnEpisodeComplete'] as bool
          : true,
      autoMarkCollectionCompleted: raw['autoMarkCollectionCompleted'] is bool
          ? raw['autoMarkCollectionCompleted'] as bool
          : true,
      syncMode: BangumiSyncModeX.fromWireName(raw['syncMode']?.toString()),
      verifiedProfile: BangumiUserProfile.fromJson(raw['verifiedProfile']),
      lastFullSyncAtMs: lastMs,
    );
  }
}

/// Bangumi 远端单集与观看状态快照。
final class BangumiRemoteEpisodeProgress {
  /// 创建远端单集快照。
  const BangumiRemoteEpisodeProgress({
    required this.episodeId,
    required this.type,
    required this.sort,
    required this.ep,
    required this.status,
    this.name = '',
  });

  /// Bangumi 剧集编号。
  final int episodeId;

  /// Bangumi 剧集类型（`0` 为正片，`1` 为特典）。
  final int type;

  /// Bangumi 条目内总排序序号。
  final double sort;

  /// Bangumi 季度内正片序号。
  final double ep;

  /// 当前远端观看状态。
  final BangumiEpisodeWatchStatus status;

  /// 剧集名称（可选）。
  final String name;
}

/// 单部作品双向同步结果摘要。
final class BangumiWorkSyncResult {
  /// 创建单部作品同步结果。
  const BangumiWorkSyncResult({
    required this.workId,
    required this.workTitle,
    this.subjectId,
    this.matchedLocalEpisodeCount = 0,
    this.localCompletedEpisodeCount = 0,
    this.pushedEpisodes = 0,
    this.pulledEpisodes = 0,
    this.collectionUpdated = false,
    this.authInvalid = false,
    this.skippedReason,
    this.errorMessage,
  });

  /// 本地作品主键。
  final WorkId workId;

  /// 本地作品标题。
  final String workTitle;

  /// 关联 Bangumi 条目编号。
  final int? subjectId;

  /// 本地参与对齐的剧集总数。
  final int matchedLocalEpisodeCount;

  /// 本地当前已完成剧集数。
  final int localCompletedEpisodeCount;

  /// 本次向上游推送完成的集数。
  final int pushedEpisodes;

  /// 本次从上游回写本地完成的集数。
  final int pulledEpisodes;

  /// 是否更新了作品收藏状态。
  final bool collectionUpdated;

  /// 是否触发鉴权失效（401 或 403）。
  final bool authInvalid;

  /// 跳过同步原因（如未绑定编号或无正片剧集）。
  final String? skippedReason;

  /// 已脱敏的错误原因。
  final String? errorMessage;

  /// 本次同步是否失败。
  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
}

/// 全库同步执行汇总报告。
final class BangumiLibrarySyncReport {
  /// 创建全库同步报告。
  const BangumiLibrarySyncReport({
    required this.startedAt,
    required this.finishedAt,
    this.syncedWorks = 0,
    this.skippedWorks = 0,
    this.pushedEpisodes = 0,
    this.pulledEpisodes = 0,
    this.updatedCollections = 0,
    this.failedWorks = 0,
    this.authInvalid = false,
    this.errorMessages = const <String>[],
  });

  /// 同步开始时间。
  final DateTime startedAt;

  /// 同步结束时间。
  final DateTime finishedAt;

  /// 成功处理的作品数量。
  final int syncedWorks;

  /// 被跳过的作品数量。
  final int skippedWorks;

  /// 总计向上游推送完成的集数。
  final int pushedEpisodes;

  /// 总计从上游回填本地完成的集数。
  final int pulledEpisodes;

  /// 触发更新作品收藏状态的次数。
  final int updatedCollections;

  /// 同步失败的作品数。
  final int failedWorks;

  /// 本次全库同步是否遇到鉴权失效并提前中止。
  final bool authInvalid;

  /// 已脱敏的错误明细列表。
  final List<String> errorMessages;

  /// 同步耗时。
  Duration get duration => finishedAt.difference(startedAt);
}

/// 单部作品本地剧集与 Bangumi 剧集对齐方案。
final class BangumiAlignedEpisodePlan {
  /// 创建剧集对齐方案。
  const BangumiAlignedEpisodePlan({
    required this.episodeIdsToPushWatched,
    required this.localEpisodeIdsToPullWatched,
    required this.matchedLocalEpisodes,
    required this.allLocalCompletedAfterPull,
    required this.allRemoteCompletedAfterPush,
  });

  /// 需要向 Bangumi 推送为已看过的远端剧集 ID 列表。
  final List<int> episodeIdsToPushWatched;

  /// 需要将本地标记为已完成的本地剧集 ID 列表。
  final List<EpisodeId> localEpisodeIdsToPullWatched;

  /// 参与对齐的本地正片剧集列表。
  final List<EpisodeRecord> matchedLocalEpisodes;

  /// 对齐后本地全部正片是否均已完成。
  final bool allLocalCompletedAfterPull;

  /// 对齐后远端全部正片是否均已看过。
  final bool allRemoteCompletedAfterPush;
}

/// 本地剧集与 Bangumi 剧集序号对齐工具（纯函数，无副作用）。
abstract final class BangumiEpisodeAligner {
  /// 计算单集完播事件对应的 Bangumi 正片集号；不可映射时返回 `null`。
  ///
  /// 规则：仅同步正片分集；第 0 季或特典不直接按正片集号推送，避免错配远端编号。
  /// 剧场版单正片在缺省集号时统一映射至第 1 集。
  static int? resolveMainEpisodeNumberForPush({
    required WorkRecord work,
    required EpisodeRecord episode,
  }) {
    if (episode.category != EpisodeCategory.main || episode.seasonNumber <= 0) {
      return null;
    }
    if (episode.episodeNumber != null && episode.episodeNumber! > 0) {
      return episode.episodeNumber!;
    }
    if (work.tmdbMediaType == TmdbMediaType.movie) {
      return 1;
    }
    return null;
  }

  /// 在远端剧集列表中匹配指定正片集号对应的远端剧集 ID。
  static BangumiRemoteEpisodeProgress? matchRemoteMainEpisode(
    List<BangumiRemoteEpisodeProgress> remoteEpisodes,
    int episodeNumber,
  ) {
    final mainRemote = remoteEpisodes.where((ep) => ep.type == 0).toList();
    if (mainRemote.isEmpty) {
      return null;
    }

    for (final ep in mainRemote) {
      if (ep.ep > 0 && ep.ep.round() == episodeNumber && (ep.ep - episodeNumber).abs() < 0.01) {
        return ep;
      }
    }
    for (final ep in mainRemote) {
      if (ep.sort > 0 &&
          ep.sort.round() == episodeNumber &&
          (ep.sort - episodeNumber).abs() < 0.01) {
        return ep;
      }
    }

    final sortedBySort = List<BangumiRemoteEpisodeProgress>.of(mainRemote)
      ..sort((a, b) => a.sort.compareTo(b.sort));
    final zeroBased = episodeNumber - 1;
    if (zeroBased >= 0 && zeroBased < sortedBySort.length) {
      return sortedBySort[zeroBased];
    }
    return null;
  }

  /// 对齐单部作品的本地正片列表与 Bangumi 远端剧集状态。
  static BangumiAlignedEpisodePlan buildPlan({
    required WorkRecord work,
    required List<EpisodeRecord> localEpisodes,
    required Set<EpisodeId> completedLocalEpisodeIds,
    required List<BangumiRemoteEpisodeProgress> remoteEpisodes,
    required BangumiSyncMode syncMode,
  }) {
    final localMain = localEpisodes
        .where(
          (ep) =>
              !ep.isDeleted &&
              ep.category == EpisodeCategory.main &&
              ep.seasonNumber > 0,
        )
        .toList()
      ..sort((a, b) {
        final seasonCmp = a.seasonNumber.compareTo(b.seasonNumber);
        if (seasonCmp != 0) {
          return seasonCmp;
        }
        final epA = a.episodeNumber ?? 1;
        final epB = b.episodeNumber ?? 1;
        return epA.compareTo(epB);
      });

    final remoteMain = remoteEpisodes.where((ep) => ep.type == 0).toList()
      ..sort((a, b) => a.sort.compareTo(b.sort));

    if (localMain.isEmpty || remoteMain.isEmpty) {
      return const BangumiAlignedEpisodePlan(
        episodeIdsToPushWatched: <int>[],
        localEpisodeIdsToPullWatched: <EpisodeId>[],
        matchedLocalEpisodes: <EpisodeRecord>[],
        allLocalCompletedAfterPull: false,
        allRemoteCompletedAfterPush: false,
      );
    }

    final pushIds = <int>[];
    final pullLocalIds = <EpisodeId>[];
    final matchedRemoteByIndex = <int, BangumiRemoteEpisodeProgress>{};

    for (var i = 0; i < localMain.length; i++) {
      final localEp = localMain[i];
      final resolvedNum = resolveMainEpisodeNumberForPush(
        work: work,
        episode: localEp,
      );
      final remote = resolvedNum != null
          ? matchRemoteMainEpisode(remoteMain, resolvedNum)
          : (i < remoteMain.length ? remoteMain[i] : null);
      if (remote == null) {
        continue;
      }
      matchedRemoteByIndex[remote.episodeId] = remote;

      final localDone = completedLocalEpisodeIds.contains(localEp.id);
      final remoteDone = remote.status == BangumiEpisodeWatchStatus.watched;

      if (localDone && !remoteDone) {
        pushIds.add(remote.episodeId);
      } else if (!localDone &&
          remoteDone &&
          syncMode == BangumiSyncMode.autoCompleteAndPush) {
        pullLocalIds.add(localEp.id);
      }
    }

    final pullSet = pullLocalIds.toSet();
    final pushSet = pushIds.toSet();

    final allLocalDone = localMain.every(
      (ep) =>
          completedLocalEpisodeIds.contains(ep.id) || pullSet.contains(ep.id),
    );
    final allRemoteDone = remoteMain.every(
      (ep) =>
          ep.status == BangumiEpisodeWatchStatus.watched ||
          pushSet.contains(ep.episodeId),
    );

    return BangumiAlignedEpisodePlan(
      episodeIdsToPushWatched: pushIds,
      localEpisodeIdsToPullWatched: pullLocalIds,
      matchedLocalEpisodes: localMain,
      allLocalCompletedAfterPull: allLocalDone,
      allRemoteCompletedAfterPush: allRemoteDone,
    );
  }
}
