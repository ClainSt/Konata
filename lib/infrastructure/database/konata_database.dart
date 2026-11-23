import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import '../../domain/lyrics/lyric_candidate.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/lyric_cache_repository.dart';

part 'konata_database.g.dart';

/// 媒体源元数据表（敏感密码由 FlutterSecureStorage 单独管理）。
@DataClassName('MediaSourceRow')
class MediaSources extends Table {
  /// 媒体源唯一主键。
  TextColumn get id => text()();

  /// 协议类型。
  TextColumn get kind => textEnum<MediaSourceKind>()();

  /// 显示名称。
  TextColumn get label => text()();

  /// 本地根路径或远程地址。
  TextColumn get location => text()();

  /// 可选用户名。
  TextColumn get username => text().nullable()();

  /// 创建时间戳。
  DateTimeColumn get createdAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 作品主表（主键与物理目录路径彻底解耦）。
@DataClassName('WorkRow')
class Works extends Table {
  /// 作品唯一主键（UUID）。
  TextColumn get id => text()();

  /// TMDB 绑定 ID。
  IntColumn get tmdbId => integer().nullable()();

  /// Bangumi 辅助条目 ID。
  IntColumn get bangumiId => integer().nullable()();

  /// TheTVDB 关联剧集 ID（用于直接对接 Fanart.tv 剧集接口）。
  IntColumn get tvdbId => integer().nullable()();

  /// TMDB 条目类型（`tv` / `movie`）。
  TextColumn get tmdbMediaType => textEnum<TmdbMediaType>().nullable()();

  /// 季级匹配绑定季号（例如 `Wake Up, Girls! 新章` 绑定第 2 季）。
  IntColumn get matchedSeason => integer().nullable()();

  /// 展示标题。
  TextColumn get title => text()();

  /// 原始语言标题。
  TextColumn get originalTitle => text().nullable()();

  /// 发行年份。
  IntColumn get year => integer().nullable()();

  /// 作品简介。
  TextColumn get overview => text().nullable()();

  /// 海报路径。
  TextColumn get posterPath => text().nullable()();

  /// 剧集级海报回退路径。
  TextColumn get posterFallback => text().nullable()();

  /// 关联的 Bangumi 官方封面 URL（用于详情页封面切换与回落展示）。
  TextColumn get bangumiPosterPath => text().nullable()();

  /// 背景图路径。
  TextColumn get backdropPath => text().nullable()();

  /// 官方透明 PNG 标题 Logo 路径。
  TextColumn get logoPath => text().nullable()();

  /// TMDB 评分（0.0 ~ 10.0）。
  RealColumn get voteAverage => real().nullable()();

  /// 关联 Bangumi 条目评分（0.0 ~ 10.0）。
  RealColumn get bangumiScore => real().nullable()();

  /// 从文件夹名提取的显式 TMDB ID 提示。
  IntColumn get folderTmdbHint => integer().nullable()();

  /// 是否已人工锁定（防止自动刮削更换绑定条目）。
  BoolColumn get isManualLocked =>
      boolean().withDefault(const Constant(false))();

  /// 基础元数据（标题/原名/年份/简介/匹配季）是否已人工锁定。
  BoolColumn get metadataLocked =>
      boolean().withDefault(const Constant(false))();

  /// 封面海报是否已人工锁定。
  BoolColumn get posterLocked => boolean().withDefault(const Constant(false))();

  /// 横版背景原画是否已人工锁定。
  BoolColumn get backdropLocked =>
      boolean().withDefault(const Constant(false))();

  /// 透明标题徽标是否已人工锁定。
  BoolColumn get logoLocked => boolean().withDefault(const Constant(false))();

  /// 透明标题徽标负缓存冷却截止时间。
  DateTimeColumn get logoNegativeUntil => dateTime().nullable()();

  /// 透明标题徽标负缓存探测数据源位掩码。
  IntColumn get logoNegativeMask => integer().withDefault(const Constant(0))();

  /// 是否在主媒体库隐藏。
  BoolColumn get isHidden => boolean().withDefault(const Constant(false))();

  /// 重扫时是否继续保持隐藏。
  BoolColumn get keepHidden => boolean().withDefault(const Constant(false))();

  /// 刮削状态。
  TextColumn get scrapeStatus => textEnum<ScrapeStatus>()();

  /// 作品级待复核/未匹配原因码。
  TextColumn get reviewReason => text().nullable()();

  /// 所属系列 ID。
  TextColumn get seriesId => text().nullable()();

  /// 在所属系列中的排序序号。
  IntColumn get seriesOrder => integer().nullable()();

  /// 在所属系列中的展示标签。
  TextColumn get seriesLabel => text().nullable()();

  /// 系列编组与标签是否已人工锁定。
  BoolColumn get seriesLocked => boolean().withDefault(const Constant(false))();

  /// 最近一次元数据或人工锁定变更的 UTC 毫秒时间戳（供多设备增量同步判定新旧）。
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 删除作品后可选写入的忽略目录表（防止重扫自动复活）。
@DataClassName('IgnoredFolderRow')
class IgnoredFolders extends Table {
  /// 忽略规则唯一主键 (`sourceId::relativePath`)。
  TextColumn get id => text()();

  /// 所属媒体源 ID。
  TextColumn get sourceId =>
      text().references(MediaSources, #id, onDelete: KeyAction.cascade)();

  /// 相对媒体源根目录的文件夹路径（POSIX）。
  TextColumn get relativePath => text()();

  /// 添加时间。
  DateTimeColumn get createdAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 逻辑剧集与特典表。
@DataClassName('EpisodeRow')
class Episodes extends Table {
  /// 剧集主键。
  TextColumn get id => text()();

  /// 所属作品 ID。
  TextColumn get workId =>
      text().references(Works, #id, onDelete: KeyAction.cascade)();

  /// 季号（特典通常为 0）。
  IntColumn get seasonNumber => integer()();

  /// 集号或特典序号（未识别集号时保持 null，不强行兜底为 1）。
  IntColumn get episodeNumber => integer().nullable()();

  /// 多集合并文件的区间结束集号（null 表示单集；仅正片使用）。
  IntColumn get episodeNumberEnd => integer().nullable()();

  /// 分类（正片 / 特典）。
  TextColumn get category => textEnum<EpisodeCategory>()();

  /// 特典细分类型。
  TextColumn get extraType => textEnum<ExtraKind>().nullable()();

  /// 单集标题。
  TextColumn get title => text().nullable()();

  /// 单集简介。
  TextColumn get overview => text().nullable()();

  /// 单集剧照路径。
  TextColumn get stillPath => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 物理文件与多版本规格表。
@DataClassName('MediaVariantRow')
class MediaVariants extends Table {
  /// 物理版本主键。
  TextColumn get id => text()();

  /// 所属作品 ID。
  TextColumn get workId =>
      text().references(Works, #id, onDelete: KeyAction.cascade)();

  /// 关联的逻辑剧集 ID（可空）。
  TextColumn get episodeId => text().nullable().references(
    Episodes,
    #id,
    onDelete: KeyAction.setNull,
  )();

  /// 所属媒体源 ID。
  TextColumn get sourceId =>
      text().references(MediaSources, #id, onDelete: KeyAction.cascade)();

  /// 相对媒体源路径。
  TextColumn get relativePath => text()();

  /// 文件名。
  TextColumn get fileName => text()();

  /// 文件大小（字节）。
  IntColumn get fileSize => integer()();

  /// 资产分类（视频 / CD 专辑 / 扫图画廊）。
  TextColumn get assetKind => textEnum<AssetKind>()();

  /// 压制组。
  TextColumn get releaseGroup => text().nullable()();

  /// 字幕组。
  TextColumn get subtitleGroup => text().nullable()();

  /// 视频编码。
  TextColumn get videoCodec => text().nullable()();

  /// 色深。
  TextColumn get bitDepth => text().nullable()();

  /// 分辨率。
  TextColumn get resolution => text().nullable()();

  /// 音频编码。
  TextColumn get audioCodec => text().nullable()();

  /// 外挂字幕相对路径列表 JSON。
  TextColumn get externalSubtitlesJson =>
      text().withDefault(const Constant('[]'))();

  /// 该文件映射槽位是否已人工锁定。
  BoolColumn get mappingLocked =>
      boolean().withDefault(const Constant(false))();

  /// 该物理文件的作品归属是否已人工锁定。
  BoolColumn get workLocked => boolean().withDefault(const Constant(false))();

  /// 作为附属资源在系列内的可见作用域。
  TextColumn get assetScope => textEnum<SupplementaryAssetScope>().withDefault(
    Constant(SupplementaryAssetScope.workExclusive.name),
  )();

  /// 该文件的系列作用域是否已人工锁定。
  BoolColumn get scopeLocked => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 待复核 Top-5 候选摘要表。
@DataClassName('ScrapeCandidateRow')
class ScrapeCandidates extends Table {
  /// 所属作品 ID。
  TextColumn get workId =>
      text().references(Works, #id, onDelete: KeyAction.cascade)();

  /// 候选排名（1..5）。
  IntColumn get rank => integer()();

  /// 候选 TMDB ID。
  IntColumn get tmdbId => integer()();

  /// 候选媒体类型。
  TextColumn get mediaType => textEnum<TmdbMediaType>()();

  /// 候选标题。
  TextColumn get title => text()();

  /// 候选原始标题。
  TextColumn get originalTitle => text().nullable()();

  /// 候选发行年份。
  IntColumn get year => integer().nullable()();

  /// 海报路径。
  TextColumn get posterPath => text().nullable()();

  /// 匹配得分。
  RealColumn get score => real()();

  /// 原因码列表 JSON。
  TextColumn get reasonsJson => text().withDefault(const Constant('[]'))();

  /// 候选总集数。
  IntColumn get episodeCount => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {workId, rank};
}

/// 播放历史记录表。
@DataClassName('PlaybackRecordRow')
class PlaybackRecords extends Table {
  /// 记录唯一主键（UUID）。
  TextColumn get id => text()();

  /// 所属作品 ID。
  TextColumn get workId =>
      text().references(Works, #id, onDelete: KeyAction.cascade)();

  /// 所属逻辑剧集 ID。
  TextColumn get episodeId => text()();

  /// 实际播放的物理版本 ID。
  TextColumn get variantId => text()();

  /// 季号。
  IntColumn get seasonNumber => integer()();

  /// 集号（未识别集号的单集作品保持 null）。
  IntColumn get episodeNumber => integer().nullable()();

  /// 单集展示标题。
  TextColumn get episodeTitle => text()();

  /// 媒体源协议类型。
  TextColumn get sourceType => textEnum<MediaSourceKind>()();

  /// 播放时间戳。
  DateTimeColumn get playedAt => dateTime()();

  /// 当前播放位置（秒）。
  IntColumn get positionSeconds => integer().withDefault(const Constant(0))();

  /// 视频总时长（秒）。
  IntColumn get durationSeconds => integer().withDefault(const Constant(0))();

  /// 是否已看完（自动阈值或手动标记）。
  BoolColumn get isCompleted => boolean().withDefault(const Constant(false))();

  /// 最近一次进度变更的 UTC 毫秒时间戳（供多设备冲突合并判定新旧）。
  IntColumn get updatedAtMs => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 系列（Series）编组主表。
@DataClassName('SeriesGroupRow')
class SeriesGroups extends Table {
  /// 系列唯一主键。
  TextColumn get id => text()();

  /// 系列展示标题。
  TextColumn get title => text()();

  /// 关联的 TMDB 电影合集 ID。
  IntColumn get tmdbCollectionId => integer().nullable()();

  /// 关联的合集根目录相对路径提示。
  TextColumn get rootFolderHint => text().nullable()();

  /// 创建时间。
  DateTimeColumn get createdAt => dateTime()();

  /// 最近更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 在线歌词检索结果持久化缓存表（命中永久复用，未命中按有效期重试）。
@DataClassName('LyricCacheRow')
class LyricCacheEntries extends Table {
  /// 物理曲目键（媒体源 + 相对路径 + 文件大小 + CUE 分轨起点）。
  TextColumn get trackKey => text()();

  /// 跨文件共享的歌曲身份键。
  TextColumn get songKey => text().nullable()();

  /// 缓存状态。
  TextColumn get status => textEnum<LyricCacheStatus>()();

  /// 命中来源。
  TextColumn get source => textEnum<LyricSource>().nullable()();

  /// 来源内部歌曲标识。
  TextColumn get sourceId => text().withDefault(const Constant(''))();

  /// 增强 LRC 正文。
  TextColumn get lrcContent => text().withDefault(const Constant(''))();

  /// 命中候选得分。
  RealColumn get score => real().withDefault(const Constant(0.0))();

  /// 歌词引擎版本。
  IntColumn get engineVersion => integer()();

  /// 最近写入时间。
  DateTimeColumn get updatedAt => dateTime()();

  /// 单曲级手动时间轴偏移（毫秒，正值使歌词提前、负值使歌词延后）。
  IntColumn get offsetMillis => integer().withDefault(const Constant(0))();

  /// 单曲偏移是否由用户主动锁定。
  BoolColumn get userOffsetLocked =>
      boolean().withDefault(const Constant(false))();

  /// 是否由用户手动选定或编辑歌词（自动流程与引擎版本升级永不覆盖）。
  BoolColumn get userEdited => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {trackKey};
}

/// 专辑级统一歌词时间轴偏移表（同一张 CD 专辑共享偏移，一键应用至全碟曲目）。
@DataClassName('AlbumLyricOffsetRow')
class AlbumLyricOffsets extends Table {
  /// 专辑缓存键（`workId::sourceId::normalizedDir`）。
  TextColumn get albumKey => text()();

  /// 专辑级时间轴偏移（毫秒，正值使歌词提前、负值使歌词延后）。
  IntColumn get offsetMillis => integer().withDefault(const Constant(0))();

  /// 最近更新时间。
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {albumKey};
}

/// 跨设备同步删除墓碑表（记录已删除/清除条目的逻辑时间，避免离线设备同步后死灰复燃）。
@DataClassName('SyncTombstoneRow')
class SyncTombstones extends Table {
  /// 逻辑实体唯一键（如 `playback::<canonicalKey>::s1::e3`）。
  TextColumn get entityKey => text()();

  /// 实体类型（`playback` / `work_override` / `series`）。
  TextColumn get entityType => text()();

  /// 删除发生的 UTC 毫秒时间戳。
  IntColumn get deletedAtMs => integer()();

  /// 产生该删除动作的设备标识。
  TextColumn get deviceId => text()();

  @override
  Set<Column<Object>> get primaryKey => {entityKey};
}

/// 同步与外部账号本地元信息键值表（仅存非敏感状态，如设备 ID、上次同步时间与用户昵称）。
@DataClassName('SyncKvMetaRow')
class SyncKvMeta extends Table {
  /// 元信息键名。
  TextColumn get key => text()();

  /// 元信息值文本。
  TextColumn get value => text()();

  /// 最近更新的 UTC 毫秒时间戳。
  IntColumn get updatedAtMs => integer()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Bangumi 观看进度离线持久化上报队列（支持弱网/离线重试与批量去重合并）。
@DataClassName('BangumiSyncQueueRow')
class BangumiSyncQueue extends Table {
  /// 队列项唯一去重键（如 `ep::<subjectId>::s<season>::e<ep>`）。
  TextColumn get queueKey => text()();

  /// Bangumi 条目 ID。
  IntColumn get subjectId => integer()();

  /// 本地季号（用于区分配对关系与特典 SP）。
  IntColumn get seasonNumber => integer()();

  /// 集号（单部剧场版可为空）。
  IntColumn get episodeNumber => integer().nullable()();

  /// 目标 Bangumi 单集观看状态（`2=看过`、`0=未看`）。
  IntColumn get targetStatus => integer()();

  /// 首次入队的 UTC 毫秒时间戳。
  IntColumn get enqueuedAtMs => integer()();

  /// 已失败重试次数。
  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  /// 最近一次失败原因（已脱敏）。
  TextColumn get lastError => text().nullable()();

  /// 下次允许重试的 UTC 毫秒时间戳。
  IntColumn get nextRetryAtMs => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {queueKey};
}

/// Konata 2.0 强类型 Drift 数据库（默认存储为 `konata_v2.sqlite`）。
@DriftDatabase(
  tables: [
    MediaSources,
    Works,
    Episodes,
    MediaVariants,
    ScrapeCandidates,
    PlaybackRecords,
    IgnoredFolders,
    SeriesGroups,
    LyricCacheEntries,
    AlbumLyricOffsets,
    SyncTombstones,
    SyncKvMeta,
    BangumiSyncQueue,
  ],
)
class KonataDatabase extends _$KonataDatabase {
  /// 使用指定的 [QueryExecutor] 创建数据库实例（测试可传入内存库）。
  KonataDatabase(super.e);

  /// 打开本地持久化数据库 `konata_v2.sqlite`。
  factory KonataDatabase.openDefault() => KonataDatabase(_openConnection());

  @override
  int get schemaVersion => 16;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(scrapeCandidates);
      }
      if (from < 3) {
        await m.addColumn(works, works.logoPath);
        await m.addColumn(works, works.voteAverage);
        await m.createTable(playbackRecords);
      }
      if (from < 5) {
        await m.addColumn(works, works.isHidden);
        await m.addColumn(works, works.keepHidden);
        await m.createTable(ignoredFolders);
      }
      if (from < 6) {
        await m.addColumn(works, works.reviewReason);
        await m.addColumn(scrapeCandidates, scrapeCandidates.episodeCount);
        await m.addColumn(playbackRecords, playbackRecords.positionSeconds);
        await m.addColumn(playbackRecords, playbackRecords.durationSeconds);
        await m.addColumn(playbackRecords, playbackRecords.isCompleted);
      }
      if (from < 7) {
        await m.addColumn(works, works.bangumiId);
        await m.addColumn(works, works.matchedSeason);
        await m.addColumn(works, works.posterFallback);
        await m.alterTable(TableMigration(episodes));
        await m.alterTable(TableMigration(playbackRecords));
      }
      if (from < 8) {
        await m.addColumn(works, works.bangumiPosterPath);
      }
      if (from < 9) {
        await customStatement('DROP TABLE IF EXISTS scan_roots');
      }
      if (from < 10) {
        await m.addColumn(works, works.metadataLocked);
        await m.addColumn(works, works.posterLocked);
        await m.addColumn(works, works.backdropLocked);
        await m.addColumn(mediaVariants, mediaVariants.mappingLocked);
      }
      if (from < 11) {
        await m.createTable(seriesGroups);
        await m.addColumn(works, works.bangumiScore);
        await m.addColumn(works, works.seriesId);
        await m.addColumn(works, works.seriesOrder);
        await m.addColumn(works, works.seriesLabel);
        await m.addColumn(works, works.seriesLocked);
        await m.addColumn(mediaVariants, mediaVariants.workLocked);
        await m.addColumn(mediaVariants, mediaVariants.assetScope);
        await m.addColumn(mediaVariants, mediaVariants.scopeLocked);
      }
      // v7 之前的库会在 `from < 7` 里按最新表定义重建 episodes（已含该列），无需重复添加。
      if (from < 12 && from >= 7) {
        await m.addColumn(episodes, episodes.episodeNumberEnd);
      }
      if (from < 13) {
        await m.addColumn(works, works.tvdbId);
        await m.addColumn(works, works.logoLocked);
        await m.addColumn(works, works.logoNegativeUntil);
        await m.addColumn(works, works.logoNegativeMask);
      }
      if (from < 14) {
        await m.createTable(lyricCacheEntries);
      }
      if (from < 15) {
        await m.addColumn(works, works.updatedAtMs);
        // v7 之前的库已在 `from < 7` 重建 playbackRecords（已包含该列），仅 v7..v14 追加。
        if (from >= 7) {
          await m.addColumn(playbackRecords, playbackRecords.updatedAtMs);
        }
        await m.createTable(syncTombstones);
        await m.createTable(syncKvMeta);
        await m.createTable(bangumiSyncQueue);
      }
      if (from < 16) {
        // v14 之前的库已在 `from < 14` 按最新表定义建表，仅 v14..v15 追加单曲偏移与编辑锁列。
        if (from >= 14) {
          await m.addColumn(lyricCacheEntries, lyricCacheEntries.offsetMillis);
          await m.addColumn(
            lyricCacheEntries,
            lyricCacheEntries.userOffsetLocked,
          );
          await m.addColumn(lyricCacheEntries, lyricCacheEntries.userEdited);
        }
        await m.createTable(albumLyricOffsets);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // 幂等创建核心高频查询与排序覆盖索引，消除全表扫描与临时 B-Tree 排序。
      for (final sql in _secondaryIndexStatements) {
        await customStatement(sql);
      }
    },
  );

  /// 本地数据库统一 SQLite 性能 PRAGMA 参数配置（WAL + 8 MiB 页缓存 + 内存临时表）。
  static void configureSqlitePragmas(
    sq.Database rawDb, {
    int cacheSizeKib = 8192,
    int mmapSizeBytes = 0,
  }) {
    rawDb.execute('PRAGMA journal_mode = WAL;');
    rawDb.execute('PRAGMA synchronous = NORMAL;');
    rawDb.execute('PRAGMA temp_store = MEMORY;');
    rawDb.execute('PRAGMA cache_size = -$cacheSizeKib;');
    if (mmapSizeBytes > 0) {
      rawDb.execute('PRAGMA mmap_size = $mmapSizeBytes;');
    }
  }

  static const List<String> _secondaryIndexStatements = <String>[
    'CREATE INDEX IF NOT EXISTS idx_episodes_work_order '
        'ON episodes (work_id, season_number, episode_number)',
    'CREATE INDEX IF NOT EXISTS idx_media_variants_work '
        'ON media_variants (work_id)',
    'CREATE INDEX IF NOT EXISTS idx_media_variants_source '
        'ON media_variants (source_id)',
    'CREATE INDEX IF NOT EXISTS idx_media_variants_episode '
        'ON media_variants (episode_id)',
    'CREATE INDEX IF NOT EXISTS idx_playback_records_work_played '
        'ON playback_records (work_id, played_at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_playback_records_work_episode '
        'ON playback_records (work_id, episode_id)',
    'CREATE INDEX IF NOT EXISTS idx_playback_records_played '
        'ON playback_records (played_at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_works_series '
        'ON works (series_id)',
    'CREATE INDEX IF NOT EXISTS idx_works_hidden '
        'ON works (is_hidden)',
    'CREATE INDEX IF NOT EXISTS idx_ignored_folders_source '
        'ON ignored_folders (source_id)',
    'CREATE INDEX IF NOT EXISTS idx_lyric_cache_song '
        'ON lyric_cache_entries (song_key)',
    'CREATE INDEX IF NOT EXISTS idx_sync_tombstones_type '
        'ON sync_tombstones (entity_type, deleted_at_ms DESC)',
    'CREATE INDEX IF NOT EXISTS idx_bangumi_sync_queue_next '
        'ON bangumi_sync_queue (next_retry_at_ms ASC)',
  ];
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final supportDir = await getApplicationSupportDirectory();
    await supportDir.create(recursive: true);
    final file = File(p.join(supportDir.path, 'konata_v2.sqlite'));
    // 直接通过 sqlite3 FFI + WAL 模式访问本地元数据库，消除常驻后台 Drift Isolate 堆拷贝与跨 Isolate 序列化开销。
    return NativeDatabase(
      file,
      setup: (rawDb) => KonataDatabase.configureSqlitePragmas(rawDb),
    );
  });
}
