import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/work.dart';

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
  ],
)
class KonataDatabase extends _$KonataDatabase {
  /// 使用指定的 [QueryExecutor] 创建数据库实例（测试可传入内存库）。
  KonataDatabase(super.e);

  /// 打开本地持久化数据库 `konata_v2.sqlite`。
  factory KonataDatabase.openDefault() => KonataDatabase(_openConnection());

  @override
  int get schemaVersion => 13;

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
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final supportDir = await getApplicationSupportDirectory();
    await supportDir.create(recursive: true);
    final file = File(p.join(supportDir.path, 'konata_v2.sqlite'));
    // 直接通过 sqlite3 FFI + WAL 模式访问本地元数据库，消除常驻后台 Drift Isolate 堆拷贝与跨 Isolate 序列化开销。
    return NativeDatabase(
      file,
      setup: (rawDb) {
        rawDb.execute('PRAGMA journal_mode = WAL;');
        rawDb.execute('PRAGMA synchronous = NORMAL;');
        rawDb.execute('PRAGMA temp_store = MEMORY;');
        rawDb.execute('PRAGMA cache_size = -128;');
      },
    );
  });
}
