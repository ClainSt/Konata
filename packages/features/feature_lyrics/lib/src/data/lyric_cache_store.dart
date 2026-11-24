import 'package:konata_storage/konata_storage.dart';

import '../domain/lyric_candidate.dart';
import '../domain/lyric_offset_resolver.dart';
import 'lyric_http_transport.dart';

/// 歌词缓存条目状态。
enum LyricCacheStatus {
  /// 已命中并保存了歌词正文。
  found,

  /// 各来源均有响应但无合格候选（负缓存，按有效期重试）。
  notFound,
}

/// 持久化的单曲歌词检索结果（含单曲偏移与用户手动锁定标记，保障用户修改永不被自动流程覆盖）。
class LyricCacheEntry {
  /// 创建缓存条目。
  const LyricCacheEntry({
    required this.trackKey,
    required this.status,
    required this.engineVersion,
    required this.updatedAt,
    this.songKey,
    this.source,
    this.sourceId = '',
    this.lrcContent = '',
    this.score = 0.0,
    this.offsetMillis = 0,
    this.userOffsetLocked = false,
    this.userEdited = false,
  });

  /// 物理曲目键。
  final String trackKey;

  /// 跨文件共享的歌曲身份键（时长未知时为空）。
  final String? songKey;

  /// 缓存状态。
  final LyricCacheStatus status;

  /// 命中来源（未命中时为空）。
  final LyricSource? source;

  /// 来源内部歌曲标识。
  final String sourceId;

  /// 增强 LRC 正文。
  final String lrcContent;

  /// 命中候选得分。
  final double score;

  /// 生成该条目时的歌词引擎版本。
  final int engineVersion;

  /// 最近写入时间。
  final DateTime updatedAt;

  /// 单曲级手动时间轴偏移（毫秒，正值使歌词提前、负值使歌词延后）。
  final int offsetMillis;

  /// 单曲偏移是否由用户主动锁定（自动更新缓存时必须保留）。
  final bool userOffsetLocked;

  /// 当前歌词是否由用户手动切换候选或编辑锁定（自动检索与引擎版本升级绝不覆盖）。
  final bool userEdited;

  /// 复制并修改局部字段。
  LyricCacheEntry copyWith({
    String? songKey,
    LyricCacheStatus? status,
    LyricSource? source,
    String? sourceId,
    String? lrcContent,
    double? score,
    int? engineVersion,
    DateTime? updatedAt,
    int? offsetMillis,
    bool? userOffsetLocked,
    bool? userEdited,
  }) {
    return LyricCacheEntry(
      trackKey: trackKey,
      songKey: songKey ?? this.songKey,
      status: status ?? this.status,
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      lrcContent: lrcContent ?? this.lrcContent,
      score: score ?? this.score,
      engineVersion: engineVersion ?? this.engineVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      offsetMillis: offsetMillis ?? this.offsetMillis,
      userOffsetLocked: userOffsetLocked ?? this.userOffsetLocked,
      userEdited: userEdited ?? this.userEdited,
    );
  }
}

/// 歌词检索结果与三级偏移持久化仓储接口。
abstract interface class LyricCacheRepository {
  /// 按物理曲目键读取缓存或用户手选覆盖。
  Future<LyricCacheEntry?> findByTrackKey(String trackKey);

  /// 按歌曲身份键读取任一已命中在线缓存（跨文件复用同一首歌）。
  Future<LyricCacheEntry?> findFoundBySongKey(String songKey);

  /// 写入或覆盖在线缓存或用户手选锁定条目。
  Future<void> save(LyricCacheEntry entry);

  /// 读取指定专辑键的专辑级歌词偏移（毫秒，不存在返回 0）。
  Future<int> findAlbumOffsetMillis(String albumKey);

  /// 持久化指定专辑键的专辑级歌词偏移（毫秒，为 0 时记录软删除墓碑）。
  Future<void> saveAlbumOffsetMillis(String albumKey, int offsetMillis);

  /// 仅更新单曲偏移与偏移锁定标记（不覆盖已有歌词正文与用户编辑状态）。
  Future<void> updateTrackOffset(
    String trackKey, {
    required int offsetMillis,
    required bool userOffsetLocked,
  });

  /// 解除用户手动选定锁定，允许后续自动检索重新评估（保留已锁定的单曲偏移）。
  Future<void> unlockUserEdit(String trackKey);
}

/// 基于双库分离架构的歌词存储实现：
/// - 用户手选歌词与单曲/专辑偏移落盘至 `user_state.db`，清空或重置 `cache.db` 时严禁丢失；
/// - 自动在线检索命中与负缓存落盘至惰性打开的 `cache.db`。
class StorageLyricCacheRepository implements LyricCacheRepository {
  /// 使用双库访问句柄构造歌词持久化仓储。
  StorageLyricCacheRepository({
    required this._userStateDb,
    required this._cacheDbProvider,
    this._isCacheOpen,
    this.localDeviceId = '',
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 直接基于统一三库组合构建（保持惰性缓存库在冷启动与只读偏移场景下不提前打开）。
  factory StorageLyricCacheRepository.fromBundle(
    KonataDatabaseBundle bundle, {
    String localDeviceId = '',
    DateTime Function()? now,
  }) {
    return StorageLyricCacheRepository(
      userStateDb: bundle.userState,
      cacheDbProvider: () => bundle.cache,
      isCacheOpen: () => bundle.isCacheOpen,
      localDeviceId: localDeviceId,
      now: now,
    );
  }

  final UserStateDatabase _userStateDb;
  final CacheDatabase Function() _cacheDbProvider;
  final bool Function()? _isCacheOpen;
  final DateTime Function() _now;

  /// 本机设备标识（写入用户覆盖记录以便多设备同步）。
  final String localDeviceId;

  /// 构造单曲覆盖记录主键。
  static String trackOverrideKey(String trackKey) => 'track::$trackKey';

  /// 构造专辑覆盖记录主键。
  static String albumOverrideKey(String albumKey) => 'album::$albumKey';

  LyricUserOverrideDao get _overrides => _userStateDb.lyricUserOverrides;

  @override
  Future<LyricCacheEntry?> findByTrackKey(String trackKey) async {
    final override = _overrides.findByKey(trackOverrideKey(trackKey));
    if (override != null &&
        override.userEdited &&
        (override.lrcContent ?? '').trim().isNotEmpty) {
      LyricCacheEntryRecord? cacheMeta;
      if (_isCacheOpen?.call() ?? false) {
        cacheMeta = _cacheDbProvider().lyricCache.findByTrackKey(trackKey);
      }
      return LyricCacheEntry(
        trackKey: trackKey,
        songKey: cacheMeta?.songKey,
        status: LyricCacheStatus.found,
        source: _parseLyricSource(cacheMeta?.source) ?? LyricSource.local,
        sourceId: cacheMeta?.sourceId ?? '',
        lrcContent: override.lrcContent!,
        score: cacheMeta?.score ?? 1.0,
        engineVersion: LyricLookupConfig.engineVersion,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          override.updatedAtMs,
          isUtc: true,
        ),
        offsetMillis: override.userOffsetLocked ? override.offsetMillis : 0,
        userOffsetLocked: override.userOffsetLocked,
        userEdited: true,
      );
    }

    final cacheRec = _cacheDbProvider().lyricCache.findByTrackKey(trackKey);
    if (cacheRec == null) {
      if (override != null && override.userOffsetLocked) {
        return LyricCacheEntry(
          trackKey: trackKey,
          status: LyricCacheStatus.notFound,
          engineVersion: 0,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            override.updatedAtMs,
            isUtc: true,
          ),
          offsetMillis: override.offsetMillis,
          userOffsetLocked: true,
          userEdited: false,
        );
      }
      return null;
    }

    return _mapCacheRecord(
      cacheRec,
      offsetMillis: override?.userOffsetLocked == true
          ? override!.offsetMillis
          : 0,
      userOffsetLocked: override?.userOffsetLocked ?? false,
    );
  }

  @override
  Future<LyricCacheEntry?> findFoundBySongKey(String songKey) async {
    final cacheRec = _cacheDbProvider().lyricCache.findBestHitBySongKey(songKey);
    if (cacheRec == null) return null;
    return _mapCacheRecord(cacheRec);
  }

  @override
  Future<void> save(LyricCacheEntry entry) async {
    final nowMs = entry.updatedAt.toUtc().millisecondsSinceEpoch;
    final clampedOffset = LyricOffsetSnapshot.clampTrackOrAlbum(
      entry.offsetMillis,
    );
    if (entry.userEdited) {
      _overrides.upsert(
        LyricUserOverrideRecord(
          overrideKey: trackOverrideKey(entry.trackKey),
          scope: LyricOverrideScope.track,
          trackKey: entry.trackKey,
          lrcContent: entry.lrcContent,
          offsetMillis: clampedOffset,
          userOffsetLocked: entry.userOffsetLocked,
          userEdited: true,
          updatedAtMs: nowMs,
          sourceDeviceId: localDeviceId,
          deletedAtMs: null,
        ),
      );
    }

    _cacheDbProvider().lyricCache.upsert(
      LyricCacheEntryRecord(
        trackKey: entry.trackKey,
        songKey: entry.songKey,
        status: entry.status == LyricCacheStatus.found
            ? LyricCacheHitStatus.hit
            : LyricCacheHitStatus.miss,
        source: entry.source?.name,
        sourceId: entry.sourceId,
        lrcContent: entry.lrcContent,
        score: entry.score,
        engineVersion: entry.engineVersion,
        updatedAtMs: nowMs,
      ),
    );
  }

  @override
  Future<int> findAlbumOffsetMillis(String albumKey) async {
    final trimmed = albumKey.trim();
    if (trimmed.isEmpty) return 0;
    final rec = _overrides.findByKey(albumOverrideKey(trimmed));
    return rec?.offsetMillis ?? 0;
  }

  @override
  Future<void> saveAlbumOffsetMillis(String albumKey, int offsetMillis) async {
    final trimmed = albumKey.trim();
    if (trimmed.isEmpty) return;
    final key = albumOverrideKey(trimmed);
    final clamped = LyricOffsetSnapshot.clampTrackOrAlbum(offsetMillis);
    final nowMs = _now().toUtc().millisecondsSinceEpoch;
    if (clamped == 0) {
      final existing = _overrides.findByKey(key);
      if (existing != null) {
        _overrides.softDelete(
          key,
          deletedAtMs: nowMs,
          sourceDeviceId: localDeviceId,
        );
      }
      return;
    }
    _overrides.upsert(
      LyricUserOverrideRecord(
        overrideKey: key,
        scope: LyricOverrideScope.album,
        albumKey: trimmed,
        offsetMillis: clamped,
        userOffsetLocked: true,
        userEdited: false,
        updatedAtMs: nowMs,
        sourceDeviceId: localDeviceId,
        deletedAtMs: null,
      ),
    );
  }

  @override
  Future<void> updateTrackOffset(
    String trackKey, {
    required int offsetMillis,
    required bool userOffsetLocked,
  }) async {
    final key = trackOverrideKey(trackKey);
    final clamped = LyricOffsetSnapshot.clampTrackOrAlbum(offsetMillis);
    final nowMs = _now().toUtc().millisecondsSinceEpoch;
    final existing = _overrides.findByKey(key, includeDeleted: true);
    final preserveEdited = existing != null &&
        existing.deletedAtMs == null &&
        existing.userEdited;

    if (clamped == 0 && !userOffsetLocked && !preserveEdited) {
      if (existing != null && existing.deletedAtMs == null) {
        _overrides.softDelete(
          key,
          deletedAtMs: nowMs,
          sourceDeviceId: localDeviceId,
        );
      }
      return;
    }

    _overrides.upsert(
      LyricUserOverrideRecord(
        overrideKey: key,
        scope: LyricOverrideScope.track,
        trackKey: trackKey,
        lrcContent: preserveEdited ? existing.lrcContent : null,
        offsetMillis: clamped,
        userOffsetLocked: userOffsetLocked,
        userEdited: preserveEdited,
        updatedAtMs: nowMs,
        sourceDeviceId: localDeviceId,
        deletedAtMs: null,
      ),
    );
  }

  @override
  Future<void> unlockUserEdit(String trackKey) async {
    final key = trackOverrideKey(trackKey);
    final nowMs = _now().toUtc().millisecondsSinceEpoch;
    final existing = _overrides.findByKey(key);
    if (existing != null) {
      if (existing.userOffsetLocked || existing.offsetMillis != 0) {
        _overrides.upsert(
          LyricUserOverrideRecord(
            overrideKey: key,
            scope: LyricOverrideScope.track,
            trackKey: trackKey,
            lrcContent: null,
            offsetMillis: existing.offsetMillis,
            userOffsetLocked: existing.userOffsetLocked,
            userEdited: false,
            updatedAtMs: nowMs,
            sourceDeviceId: localDeviceId,
            deletedAtMs: null,
          ),
        );
      } else {
        _overrides.softDelete(
          key,
          deletedAtMs: nowMs,
          sourceDeviceId: localDeviceId,
        );
      }
    }

    if (_isCacheOpen?.call() ?? false) {
      final cacheDao = _cacheDbProvider().lyricCache;
      final cached = cacheDao.findByTrackKey(trackKey);
      if (cached != null) {
        cacheDao.upsert(
          LyricCacheEntryRecord(
            trackKey: cached.trackKey,
            songKey: cached.songKey,
            status: cached.status,
            source: cached.source,
            sourceId: cached.sourceId,
            lrcContent: cached.lrcContent,
            score: cached.score,
            engineVersion: 0,
            updatedAtMs: nowMs,
          ),
        );
      }
    }
  }

  static LyricCacheEntry _mapCacheRecord(
    LyricCacheEntryRecord rec, {
    int offsetMillis = 0,
    bool userOffsetLocked = false,
  }) {
    return LyricCacheEntry(
      trackKey: rec.trackKey,
      songKey: rec.songKey,
      status: rec.status == LyricCacheHitStatus.hit
          ? LyricCacheStatus.found
          : LyricCacheStatus.notFound,
      source: _parseLyricSource(rec.source),
      sourceId: rec.sourceId,
      lrcContent: rec.lrcContent,
      score: rec.score,
      engineVersion: rec.engineVersion,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        rec.updatedAtMs,
        isUtc: true,
      ),
      offsetMillis: offsetMillis,
      userOffsetLocked: userOffsetLocked,
      userEdited: false,
    );
  }

  static LyricSource? _parseLyricSource(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    for (final value in LyricSource.values) {
      if (value.name == raw) return value;
    }
    return null;
  }
}
