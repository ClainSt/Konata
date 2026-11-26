import 'dart:math' as math;

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'sync_models.dart';

/// 跨设备可同步的单条播放历史与墓碑条目。
final class SyncPlaybackHistoryItem {
  /// 创建可同步播放历史条目。
  const SyncPlaybackHistoryItem({
    required this.id,
    required this.playbackKey,
    required this.canonicalWorkKey,
    this.secondaryWorkKeys = const <String>[],
    required this.workId,
    required this.episodeId,
    required this.variantId,
    required this.seasonNumber,
    this.episodeNumber,
    required this.isAudio,
    required this.episodeTitle,
    required this.sourceKind,
    required this.playedAtMs,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.isCompleted,
    required this.updatedAtMs,
    this.sourceDeviceId = '',
    this.deletedAtMs,
  });

  /// 本地主键标识。
  final String id;

  /// 跨设备稳定逻辑播放键。
  final String playbackKey;

  /// 所属作品主跨端身份键。
  final String canonicalWorkKey;

  /// 所属作品辅助身份键列表。
  final List<String> secondaryWorkKeys;

  /// 来源设备作品主键。
  final String workId;

  /// 来源设备剧集主键。
  final String episodeId;

  /// 来源设备物理版本主键。
  final String variantId;

  /// 季号。
  final int seasonNumber;

  /// 集号或音轨序号。
  final int? episodeNumber;

  /// 是否为 CD 音频播放记录。
  final bool isAudio;

  /// 单集或音轨展示标题。
  final String episodeTitle;

  /// 媒体源协议类型。
  final MediaSourceKind sourceKind;

  /// 最近播放时间戳（UTC 毫秒）。
  final int playedAtMs;

  /// 播放进度（秒）。
  final int positionSeconds;

  /// 总时长（秒）。
  final int durationSeconds;

  /// 是否已达完播状态。
  final bool isCompleted;

  /// 最近状态更新时间戳（UTC 毫秒）。
  final int updatedAtMs;

  /// 最近修改设备标识。
  final String sourceDeviceId;

  /// 软删除墓碑时间戳（UTC 毫秒）。
  final int? deletedAtMs;

  /// 是否已软删除。
  bool get isDeleted => deletedAtMs != null;

  /// 用于墓碑与活跃记录裁决的有效时间戳。
  int get effectiveTimestampMs {
    if (deletedAtMs != null) {
      return math.max(deletedAtMs!, updatedAtMs);
    }
    return updatedAtMs > 0 ? updatedAtMs : playedAtMs;
  }

  /// 全部可用于跨设备匹配本地作品的身份键。
  Iterable<String> get allWorkKeys sync* {
    if (canonicalWorkKey.isNotEmpty) yield canonicalWorkKey;
    yield* secondaryWorkKeys;
  }

  /// 复制并按需替换字段。
  SyncPlaybackHistoryItem copyWith({
    String? id,
    String? playbackKey,
    String? canonicalWorkKey,
    List<String>? secondaryWorkKeys,
    String? workId,
    String? episodeId,
    String? variantId,
    int? seasonNumber,
    int? episodeNumber,
    bool? isAudio,
    String? episodeTitle,
    MediaSourceKind? sourceKind,
    int? playedAtMs,
    int? positionSeconds,
    int? durationSeconds,
    bool? isCompleted,
    int? updatedAtMs,
    String? sourceDeviceId,
    int? deletedAtMs,
    bool clearDeletedAtMs = false,
  }) {
    return SyncPlaybackHistoryItem(
      id: id ?? this.id,
      playbackKey: playbackKey ?? this.playbackKey,
      canonicalWorkKey: canonicalWorkKey ?? this.canonicalWorkKey,
      secondaryWorkKeys: secondaryWorkKeys ?? this.secondaryWorkKeys,
      workId: workId ?? this.workId,
      episodeId: episodeId ?? this.episodeId,
      variantId: variantId ?? this.variantId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      isAudio: isAudio ?? this.isAudio,
      episodeTitle: episodeTitle ?? this.episodeTitle,
      sourceKind: sourceKind ?? this.sourceKind,
      playedAtMs: playedAtMs ?? this.playedAtMs,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      isCompleted: isCompleted ?? this.isCompleted,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      sourceDeviceId: sourceDeviceId ?? this.sourceDeviceId,
      deletedAtMs: clearDeletedAtMs ? null : (deletedAtMs ?? this.deletedAtMs),
    );
  }

  /// 序列化为 JSON 对象（严格不含凭据与本机磁盘路径）。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'playbackKey': playbackKey,
    'canonicalWorkKey': canonicalWorkKey,
    if (secondaryWorkKeys.isNotEmpty) 'secondaryWorkKeys': secondaryWorkKeys,
    'workId': workId,
    'episodeId': episodeId,
    'variantId': variantId,
    'seasonNumber': seasonNumber,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
    'isAudio': isAudio,
    'episodeTitle': episodeTitle,
    'sourceKind': sourceKind.name,
    'playedAtMs': playedAtMs,
    'positionSeconds': positionSeconds,
    'durationSeconds': durationSeconds,
    'isCompleted': isCompleted,
    'updatedAtMs': updatedAtMs,
    if (sourceDeviceId.isNotEmpty) 'sourceDeviceId': sourceDeviceId,
    if (deletedAtMs != null) 'deletedAtMs': deletedAtMs,
  };

  /// 从 JSON 对象反序列化播放历史条目；结构无效时返回 `null`。
  static SyncPlaybackHistoryItem? tryFromJson(Map<String, Object?> json) {
    final id = (json['id'] ?? '').toString().trim();
    final playbackKey = (json['playbackKey'] ?? '').toString().trim();
    final canonicalWorkKey = (json['canonicalWorkKey'] ?? '').toString().trim();
    final workId = (json['workId'] ?? '').toString().trim();
    final episodeId = (json['episodeId'] ?? '').toString().trim();
    final variantId = (json['variantId'] ?? '').toString().trim();
    if (id.isEmpty ||
        playbackKey.isEmpty ||
        workId.isEmpty ||
        episodeId.isEmpty ||
        variantId.isEmpty) {
      return null;
    }

    final rawKind = (json['sourceKind'] ?? '').toString();
    final sourceKind = MediaSourceKind.values.firstWhere(
      (k) => k.name == rawKind,
      orElse: () => throw const FormatException('同步包含未知播放来源类型'),
    );
    final rawSecondary = json['secondaryWorkKeys'];
    final secondary = rawSecondary is List
        ? <String>[
            for (final item in rawSecondary)
              if (item.toString().trim().isNotEmpty) item.toString().trim(),
          ]
        : const <String>[];
    final playedAt = (json['playedAtMs'] as num?)?.toInt() ?? 0;
    final updatedAt = (json['updatedAtMs'] as num?)?.toInt() ?? playedAt;
    return SyncPlaybackHistoryItem(
      id: id,
      playbackKey: playbackKey,
      canonicalWorkKey: canonicalWorkKey,
      secondaryWorkKeys: List<String>.unmodifiable(secondary),
      workId: workId,
      episodeId: episodeId,
      variantId: variantId,
      seasonNumber: (json['seasonNumber'] as num?)?.toInt() ?? 1,
      episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
      isAudio: json['isAudio'] == true,
      episodeTitle: (json['episodeTitle'] ?? '').toString(),
      sourceKind: sourceKind,
      playedAtMs: playedAt,
      positionSeconds: (json['positionSeconds'] as num?)?.toInt() ?? 0,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      isCompleted: json['isCompleted'] == true,
      updatedAtMs: updatedAt,
      sourceDeviceId: (json['sourceDeviceId'] ?? '').toString(),
      deletedAtMs: (json['deletedAtMs'] as num?)?.toInt(),
    );
  }
}

/// 播放历史切片合并执行计划数据载荷。
final class PlaybackHistoryMergePlan {
  /// 创建播放历史合并计划载荷。
  const PlaybackHistoryMergePlan({
    required this.recordsToUpsert,
    this.clearExistingBeforeApply = false,
  });

  /// 需要原子写入 `playback_records` 的最终合并条目清单。
  final List<SyncPlaybackHistoryItem> recordsToUpsert;

  /// 是否在写入前以软删除墓碑清空现有记录（仅覆盖还原模式使用）。
  final bool clearExistingBeforeApply;
}

/// 播放历史与观看进度同步切片贡献者（`sliceId: 'playback_history_slice'`）。
///
/// 基于 `PlaybackRecordDao.listAllWithTombstones()`，完整支持：
/// - 跨数据源（`tmdb:` / `bgm:` / 标题）等价作品聚类合流；
/// - 完播态单调或合并（`isCompleted` 一旦完成绝不回退未看）；
/// - 最大观看进度保留（`max(positionSeconds)`）；
/// - 软删除墓碑裁决（阻止旧记录复活，同时允许删除后重播重新激活）。
final class PlaybackHistorySyncSlice
    implements SyncSliceContributor<PlaybackHistoryMergePlan> {
  /// 创建绑定三库存储器的播放历史同步切片实例。
  const PlaybackHistorySyncSlice({
    required KonataDatabaseBundle this._databases,
    this._nowMs,
  });

  /// 创建仅用于元数据声明与纯函数合并规划的未绑定切片实例。
  const PlaybackHistorySyncSlice.unbound() : _databases = null, _nowMs = null;

  /// 切片稳定唯一标识。
  static const String id = 'playback_history_slice';

  /// 跨设备同步墓碑默认保留天数（超过 90 天可自动裁剪回收）。
  static const int tombstoneRetentionDays = 90;

  final KonataDatabaseBundle? _databases;
  final int Function()? _nowMs;

  @override
  String get sliceId => id;

  @override
  String get displayName => '观看进度与播放历史';

  @override
  int get schemaVersion => 1;

  @override
  Future<SyncSlicePayload> exportSlice({required String localDeviceId}) async {
    final db = _databases;
    if (db == null) {
      throw StateError('PlaybackHistorySyncSlice 未绑定数据库，无法执行导出');
    }

    final records = db.userState.playbackRecords.listAllWithTombstones();
    final works = db.library.works.listAllWithTombstones();
    final variants = db.library.mediaVariants.listAll(includeDeleted: true);

    final workById = <String, WorkRecord>{for (final w in works) w.id.value: w};
    final variantById = <String, MediaVariantRecord>{
      for (final v in variants) v.id.value: v,
    };

    final items = <SyncPlaybackHistoryItem>[];
    for (final rec in records) {
      final work = workById[rec.workId.value];
      final variant = variantById[rec.variantId.value];
      final isAudio =
          variant?.assetKind == AssetKind.cdAlbum ||
          rec.id.startsWith('audio::') ||
          rec.episodeId.value.startsWith('audio::');

      final String primaryWorkKey;
      final List<String> secondaryKeys;
      if (work != null) {
        primaryWorkKey = SyncSanitizer.primaryWorkKeyFor(work);
        secondaryKeys = SyncSanitizer.allWorkKeysFor(
          work,
        ).where((k) => k != primaryWorkKey).toList(growable: false);
      } else {
        primaryWorkKey = _extractWorkKeyFromPlaybackCanonical(
          rec.canonicalKey,
          rec.workId.value,
        );
        secondaryKeys = const <String>[];
      }

      final playbackKey = SyncSanitizer.buildPlaybackKey(
        canonicalWorkKey: primaryWorkKey,
        seasonNumber: rec.seasonNumber,
        episodeNumber: rec.episodeNumber,
        isAudio: isAudio,
        audioTrackHint: isAudio ? rec.episodeTitle : null,
      );

      final updatedAtMs = rec.updatedAtMs > 0
          ? rec.updatedAtMs
          : rec.playedAtMs;
      items.add(
        SyncPlaybackHistoryItem(
          id: rec.id,
          playbackKey: playbackKey,
          canonicalWorkKey: primaryWorkKey,
          secondaryWorkKeys: secondaryKeys,
          workId: rec.workId.value,
          episodeId: rec.episodeId.value,
          variantId: rec.variantId.value,
          seasonNumber: rec.seasonNumber,
          episodeNumber: rec.episodeNumber,
          isAudio: isAudio,
          episodeTitle: rec.episodeTitle,
          sourceKind: rec.sourceKind,
          playedAtMs: rec.playedAtMs,
          positionSeconds: rec.positionSeconds,
          durationSeconds: rec.durationSeconds,
          isCompleted: rec.isCompleted,
          updatedAtMs: updatedAtMs,
          sourceDeviceId: rec.sourceDeviceId.isEmpty
              ? localDeviceId
              : rec.sourceDeviceId,
          deletedAtMs: rec.deletedAtMs,
        ),
      );
    }

    items.sort((a, b) => a.playbackKey.compareTo(b.playbackKey));
    final now = _nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    return SyncSlicePayload(
      sliceId: sliceId,
      schemaVersion: schemaVersion,
      exportedAtMs: now,
      sourceDeviceId: localDeviceId,
      data: <String, Object?>{
        'records': <Map<String, Object?>>[
          for (final item in items) item.toJson(),
        ],
      },
    );
  }

  @override
  SyncMergePlan<PlaybackHistoryMergePlan> planMerge({
    required SyncSlicePayload local,
    required SyncSlicePayload remote,
  }) {
    final localItems = _parseItems(local.data);
    final remoteItems = _parseItems(remote.data);

    // 1. 构建跨数据源强身份键（tmdb: 与 bgm:）并查集聚类。
    final aliasUnion = _PlaybackWorkAliasUnion();
    for (final item in localItems) {
      aliasUnion.registerKeys(item.allWorkKeys);
    }
    for (final item in remoteItems) {
      aliasUnion.registerKeys(item.allWorkKeys);
    }

    String buildClusterKey(SyncPlaybackHistoryItem item) {
      final repWorkKey = aliasUnion.resolveGroupKey(
        item.allWorkKeys,
        item.canonicalWorkKey,
      );
      return SyncSanitizer.buildPlaybackKey(
        canonicalWorkKey: repWorkKey,
        seasonNumber: item.seasonNumber,
        episodeNumber: item.episodeNumber,
        isAudio: item.isAudio,
        audioTrackHint: item.isAudio ? item.episodeTitle : null,
      );
    }

    // 2. 先按集群键收敛本地已有条目。
    final localByCluster = <String, SyncPlaybackHistoryItem>{};
    for (final item in localItems) {
      final key = buildClusterKey(item);
      final existing = localByCluster[key];
      if (existing == null) {
        localByCluster[key] = item.copyWith(playbackKey: key);
      } else {
        localByCluster[key] = _mergeTwoItems(
          existing,
          item.copyWith(playbackKey: key),
        );
      }
    }

    // 3. 收敛远端同键条目后再与本地逐项裁决。
    final remoteByCluster = <String, SyncPlaybackHistoryItem>{};
    for (final item in remoteItems) {
      final key = buildClusterKey(item);
      final existing = remoteByCluster[key];
      if (existing == null) {
        remoteByCluster[key] = item.copyWith(playbackKey: key);
      } else {
        remoteByCluster[key] = _mergeTwoItems(
          existing,
          item.copyWith(playbackKey: key),
        );
      }
    }

    final toUpsert = <SyncPlaybackHistoryItem>[];
    var insertCount = 0;
    var updateCount = 0;
    var deleteCount = 0;
    var skippedCount = 0;

    for (final entry in remoteByCluster.entries) {
      final key = entry.key;
      final remoteItem = entry.value;
      final localItem = localByCluster[key];

      if (localItem == null) {
        if (remoteItem.isDeleted) {
          // 远端墓碑同步至本机持久化，防止后续其他旧设备再次复活。
          toUpsert.add(remoteItem);
          skippedCount++;
        } else {
          insertCount++;
          toUpsert.add(remoteItem);
        }
        continue;
      }

      final merged = _mergeTwoItems(localItem, remoteItem);
      if (!_itemMateriallyChanged(localItem, merged)) {
        skippedCount++;
        continue;
      }

      if (!localItem.isDeleted && merged.isDeleted) {
        deleteCount++;
      } else if (localItem.isDeleted && !merged.isDeleted) {
        insertCount++;
      } else {
        updateCount++;
      }
      toUpsert.add(merged);
    }

    return SyncMergePlan<PlaybackHistoryMergePlan>(
      sliceId: sliceId,
      insertCount: insertCount,
      updateCount: updateCount,
      deleteCount: deleteCount,
      skippedCount: skippedCount,
      planData: PlaybackHistoryMergePlan(
        recordsToUpsert: List<SyncPlaybackHistoryItem>.unmodifiable(toUpsert),
      ),
      summaryLines: <String>[
        '播放进度：新增 $insertCount 条，更新 $updateCount 条，删除 $deleteCount 条，跳过 $skippedCount 条',
      ],
    );
  }

  @override
  SyncApplyCompletion applyMergePlan(
    SyncTransactionContext tx,
    SyncMergePlan<PlaybackHistoryMergePlan> plan,
  ) {
    final items = plan.planData.recordsToUpsert;
    if (!plan.hasChanges &&
        items.isEmpty &&
        !plan.planData.clearExistingBeforeApply) {
      return SyncApplyCompletion.completed;
    }
    final db = _databases;
    if (db == null) {
      throw StateError('PlaybackHistorySyncSlice 未绑定数据库，无法应用合并计划');
    }

    final handle = tx.rawHandleFor('user_state');
    if (handle is! SqliteTransaction) {
      throw StateError('播放历史同步缺少宿主写事务');
    }
    _applyInTransaction(db, handle, tx, plan.planData);
    return SyncApplyCompletion.completed;
  }

  void _applyInTransaction(
    KonataDatabaseBundle db,
    SqliteTransaction userTx,
    SyncTransactionContext txCtx,
    PlaybackHistoryMergePlan planData,
  ) {
    if (planData.clearExistingBeforeApply) {
      userTx.execute(
        '''
UPDATE ${PlaybackRecordsSchema.table}
SET ${PlaybackRecordsSchema.colDeletedAtMs} = ?,
    ${PlaybackRecordsSchema.colUpdatedAtMs} = ?,
    ${PlaybackRecordsSchema.colSourceDeviceId} = ?
WHERE ${PlaybackRecordsSchema.colDeletedAtMs} IS NULL;
''',
        <Object?>[txCtx.appliedAtMs, txCtx.appliedAtMs, txCtx.localDeviceId],
        const <String>{PlaybackRecordsSchema.table},
      );
    }

    final localWorks = db.library.works.listAll(includeDeleted: false);
    final worksByKey = <String, List<WorkRecord>>{};
    for (final work in localWorks) {
      for (final key in SyncSanitizer.allWorkKeysFor(work)) {
        worksByKey.putIfAbsent(key, () => <WorkRecord>[]).add(work);
      }
    }

    final existingLocalRecords = db.userState.playbackRecords
        .listAllWithTombstones();
    final existingByWorkEp = <String, PlaybackRecordEntity>{
      for (final rec in existingLocalRecords)
        '${rec.workId.value}::${rec.episodeId.value}': rec,
    };
    final existingById = <String, PlaybackRecordEntity>{
      for (final rec in existingLocalRecords) rec.id: rec,
    };

    final episodesByWork = <String, List<EpisodeRecord>>{};
    final variantsByWork = <String, List<MediaVariantRecord>>{};

    for (final item in planData.recordsToUpsert) {
      final matchedWorks = _resolveWorks(item.allWorkKeys, worksByKey);
      if (matchedWorks.isEmpty) {
        final fallbackId = existingById[item.id]?.id ?? item.id;
        db.userState.playbackRecords.upsertInTx(
          userTx,
          PlaybackRecordEntity(
            id: fallbackId,
            canonicalKey: item.playbackKey,
            workId: WorkId.trusted(item.workId),
            episodeId: EpisodeId.trusted(item.episodeId),
            variantId: VariantId.trusted(item.variantId),
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            episodeTitle: item.episodeTitle,
            sourceKind: item.sourceKind,
            playedAtMs: item.playedAtMs,
            positionSeconds: item.positionSeconds,
            durationSeconds: item.durationSeconds,
            isCompleted: item.isCompleted,
            updatedAtMs: item.updatedAtMs,
            sourceDeviceId: item.sourceDeviceId,
            deletedAtMs: item.deletedAtMs,
          ),
        );
        continue;
      }

      for (final work in matchedWorks) {
        final workIdStr = work.id.value;
        final workEps = episodesByWork.putIfAbsent(
          workIdStr,
          () => db.library.episodes.listByWork(work.id),
        );
        final workVars = variantsByWork.putIfAbsent(
          workIdStr,
          () => db.library.mediaVariants.listByWork(work.id),
        );

        String? targetEpisodeId;
        String? targetVariantId;
        String? targetTitle;

        if (item.isAudio) {
          final cdVariant = _matchLocalAudioVariant(workVars, item);
          targetVariantId = cdVariant?.id.value ?? item.variantId;
          if (cdVariant != null) {
            targetEpisodeId =
                item.episodeNumber != null &&
                    cdVariant.fileName.toLowerCase().endsWith('.cue')
                ? 'audio::${cdVariant.id.value}::track_${item.episodeNumber}'
                : 'audio::${cdVariant.id.value}';
          } else {
            targetEpisodeId = item.episodeId;
          }
          targetTitle = item.episodeTitle.isNotEmpty
              ? item.episodeTitle
              : (cdVariant?.fileName ?? '');
        } else {
          final matchedEp = _matchLocalEpisode(workEps, item);
          if (matchedEp != null) {
            targetEpisodeId = matchedEp.id.value;
            targetTitle = item.episodeTitle.isNotEmpty
                ? item.episodeTitle
                : (matchedEp.title ?? work.title);
            for (final v in workVars) {
              if (v.episodeId == matchedEp.id) {
                targetVariantId = v.id.value;
                break;
              }
            }
          } else {
            targetEpisodeId = item.episodeId;
            targetTitle = item.episodeTitle;
          }
          targetVariantId ??= item.variantId;
        }

        final existing =
            existingByWorkEp['$workIdStr::$targetEpisodeId'] ??
            existingById[item.id];
        final recordId = existing?.id ?? '$workIdStr::$targetEpisodeId';

        final entity = PlaybackRecordEntity(
          id: recordId,
          canonicalKey: item.playbackKey,
          workId: work.id,
          episodeId: EpisodeId.trusted(targetEpisodeId),
          variantId: VariantId.trusted(targetVariantId),
          seasonNumber: item.seasonNumber,
          episodeNumber: item.episodeNumber,
          episodeTitle: targetTitle,
          sourceKind: item.sourceKind,
          playedAtMs: item.playedAtMs,
          positionSeconds: item.positionSeconds,
          durationSeconds: item.durationSeconds,
          isCompleted: item.isCompleted,
          updatedAtMs: item.updatedAtMs,
          sourceDeviceId: item.sourceDeviceId,
          deletedAtMs: item.deletedAtMs,
        );
        db.userState.playbackRecords.upsertInTx(userTx, entity);
        existingByWorkEp['$workIdStr::$targetEpisodeId'] = entity;
        existingById[recordId] = entity;
      }
    }
  }

  static SyncPlaybackHistoryItem _mergeTwoItems(
    SyncPlaybackHistoryItem local,
    SyncPlaybackHistoryItem remote,
  ) {
    // 1. 若任一或双方均为软删除墓碑，严格比较时间裁决。
    if (local.isDeleted && remote.isDeleted) {
      final pickRemote =
          remote.effectiveTimestampMs > local.effectiveTimestampMs;
      return (pickRemote ? remote : local).copyWith(
        id: local.id,
        workId: local.workId,
        episodeId: local.episodeId,
        variantId: local.variantId,
      );
    }

    if (local.isDeleted || remote.isDeleted) {
      final tomb = local.isDeleted ? local : remote;
      final active = local.isDeleted ? remote : local;
      // 删除时间戳大于等于活跃更新时间戳时，墓碑胜出防止旧进度复活；
      // 若用户删除后再次观看产生更新的时间戳，则活跃记录胜出并清除墓碑。
      final tombWins = tomb.effectiveTimestampMs >= active.effectiveTimestampMs;
      if (tombWins) {
        return tomb.copyWith(
          id: local.id,
          workId: local.workId,
          episodeId: local.episodeId,
          variantId: local.variantId,
        );
      }
      return active.copyWith(
        id: local.id,
        workId: local.workId,
        episodeId: local.episodeId,
        variantId: local.variantId,
        clearDeletedAtMs: true,
      );
    }

    // 2. 双方均有效时：完播态单调或合并，进度与时长保留最大值，身份键并集归约。
    final allKeys = <String>[
      local.canonicalWorkKey,
      ...local.secondaryWorkKeys,
      remote.canonicalWorkKey,
      ...remote.secondaryWorkKeys,
    ];
    final primaryKey = _pickPreferredWorkKey(allKeys);
    final secondaryKeys = <String>{
      for (final k in allKeys)
        if (k.isNotEmpty && k != primaryKey) k,
    }.toList(growable: false);

    final newer = remote.effectiveTimestampMs >= local.effectiveTimestampMs
        ? remote
        : local;
    final older = identical(newer, remote) ? local : remote;

    return local.copyWith(
      playbackKey: local.playbackKey.isNotEmpty
          ? local.playbackKey
          : remote.playbackKey,
      canonicalWorkKey: primaryKey,
      secondaryWorkKeys: secondaryKeys,
      episodeTitle: newer.episodeTitle.isNotEmpty
          ? newer.episodeTitle
          : older.episodeTitle,
      playedAtMs: math.max(local.playedAtMs, remote.playedAtMs),
      positionSeconds: math.max(local.positionSeconds, remote.positionSeconds),
      durationSeconds: math.max(local.durationSeconds, remote.durationSeconds),
      isCompleted: local.isCompleted || remote.isCompleted,
      updatedAtMs: math.max(local.updatedAtMs, remote.updatedAtMs),
      sourceDeviceId: newer.sourceDeviceId.isNotEmpty
          ? newer.sourceDeviceId
          : older.sourceDeviceId,
      clearDeletedAtMs: true,
    );
  }

  static bool _itemMateriallyChanged(
    SyncPlaybackHistoryItem local,
    SyncPlaybackHistoryItem merged,
  ) {
    return local.deletedAtMs != merged.deletedAtMs ||
        local.isCompleted != merged.isCompleted ||
        local.positionSeconds != merged.positionSeconds ||
        local.durationSeconds != merged.durationSeconds ||
        local.playedAtMs != merged.playedAtMs ||
        local.episodeTitle != merged.episodeTitle;
  }

  static List<SyncPlaybackHistoryItem> _parseItems(Map<String, Object?> data) {
    final rawList = data['records'];
    if (rawList is! List) return const <SyncPlaybackHistoryItem>[];
    final out = <SyncPlaybackHistoryItem>[];
    for (final raw in rawList) {
      if (raw is! Map) continue;
      final parsed = SyncPlaybackHistoryItem.tryFromJson(
        SyncSanitizer.coerceStringKeyMap(raw),
      );
      if (parsed != null) {
        out.add(parsed);
      }
    }
    return out;
  }

  static String _extractWorkKeyFromPlaybackCanonical(
    String? canonicalKey,
    String fallbackWorkId,
  ) {
    final raw = canonicalKey?.trim() ?? '';
    if (raw.startsWith('playback::')) {
      final body = raw.substring('playback::'.length);
      final sepIdx = body.indexOf('::s');
      final audioIdx = body.indexOf('::audio::');
      if (audioIdx > 0) return body.substring(0, audioIdx);
      if (sepIdx > 0) return body.substring(0, sepIdx);
    }
    return raw.isNotEmpty ? raw : 'work:$fallbackWorkId';
  }

  static String _pickPreferredWorkKey(List<String> keys) {
    for (final k in keys) {
      if (k.startsWith('tmdb:')) return k;
    }
    for (final k in keys) {
      if (k.startsWith('bgm:')) return k;
    }
    return keys.isEmpty ? '' : keys.first;
  }

  static List<WorkRecord> _resolveWorks(
    Iterable<String> keys,
    Map<String, List<WorkRecord>> index,
  ) {
    final seen = <String>{};
    final result = <WorkRecord>[];
    for (final k in keys) {
      final hits = index[k];
      if (hits == null) continue;
      for (final w in hits) {
        if (seen.add(w.id.value)) {
          result.add(w);
        }
      }
    }
    return result;
  }

  static EpisodeRecord? _matchLocalEpisode(
    List<EpisodeRecord> episodes,
    SyncPlaybackHistoryItem item,
  ) {
    if (episodes.isEmpty) return null;
    for (final ep in episodes) {
      if (ep.seasonNumber == item.seasonNumber &&
          ep.episodeNumber == item.episodeNumber) {
        return ep;
      }
    }
    if (item.episodeNumber != null) {
      for (final ep in episodes) {
        if (ep.category == EpisodeCategory.main &&
            ep.episodeNumber == item.episodeNumber) {
          return ep;
        }
      }
    } else {
      final mainEps = episodes
          .where((e) => e.category == EpisodeCategory.main)
          .toList(growable: false);
      if (mainEps.length == 1) {
        return mainEps.first;
      }
    }
    return null;
  }

  static MediaVariantRecord? _matchLocalAudioVariant(
    List<MediaVariantRecord> variants,
    SyncPlaybackHistoryItem item,
  ) {
    final cds = variants
        .where((v) => v.assetKind == AssetKind.cdAlbum)
        .toList(growable: false);
    if (cds.isEmpty) return null;
    final targetKey = SyncSanitizer.normalizeTitleKey(item.episodeTitle);
    if (targetKey.isNotEmpty) {
      for (final v in cds) {
        final dot = v.fileName.lastIndexOf('.');
        final base = dot > 0 ? v.fileName.substring(0, dot) : v.fileName;
        if (SyncSanitizer.normalizeTitleKey(base) == targetKey) {
          return v;
        }
      }
    }
    if (cds.length == 1) return cds.first;
    return null;
  }
}

/// 跨源强身份键并查集（保证 `tmdb:` 优先于 `bgm:` 作为聚类代表键）。
final class _PlaybackWorkAliasUnion {
  final Map<String, String> _parent = <String, String>{};

  void registerKeys(Iterable<String> keys) {
    final strong = <String>[
      for (final k in keys)
        if (k.startsWith('tmdb:') || k.startsWith('bgm:')) k,
    ];
    if (strong.length < 2) return;
    for (var i = 1; i < strong.length; i++) {
      _union(strong.first, strong[i]);
    }
  }

  String resolveGroupKey(Iterable<String> keys, String fallback) {
    for (final k in keys) {
      if (k.startsWith('tmdb:') || k.startsWith('bgm:')) {
        return _parent.containsKey(k) ? _find(k) : k;
      }
    }
    return fallback;
  }

  void _union(String a, String b) {
    _parent.putIfAbsent(a, () => a);
    _parent.putIfAbsent(b, () => b);
    final ra = _find(a);
    final rb = _find(b);
    if (ra == rb) return;
    if (_rank(ra) <= _rank(rb)) {
      _parent[rb] = ra;
    } else {
      _parent[ra] = rb;
    }
  }

  String _find(String x) {
    final p = _parent[x];
    if (p == null || p == x) return x;
    final root = _find(p);
    _parent[x] = root;
    return root;
  }

  int _rank(String key) {
    if (key.startsWith('tmdb:')) return 0;
    if (key.startsWith('bgm:')) return 1;
    return 2;
  }
}
