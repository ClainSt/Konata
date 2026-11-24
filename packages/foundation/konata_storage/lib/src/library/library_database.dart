import 'package:konata_contracts/konata_contracts.dart';

import '../engine/konata_sqlite_engine.dart';
import 'dao/episode_dao.dart';
import 'dao/ignored_folder_dao.dart';
import 'dao/media_source_dao.dart';
import 'dao/media_variant_dao.dart';
import 'dao/series_group_dao.dart';
import 'dao/work_dao.dart';
import 'library_migrations.dart';

/// `library.db` 核心媒体资产库门面（聚合 6 张核心资产表 DAO）。
final class LibraryDatabase {
  LibraryDatabase._(this.engine)
    : mediaSources = MediaSourceDao(engine),
      seriesGroups = SeriesGroupDao(engine),
      works = WorkDao(engine),
      episodes = EpisodeDao(engine),
      mediaVariants = MediaVariantDao(engine),
      ignoredFolders = IgnoredFolderDao(engine);

  /// 打开物理文件型 `library.db`（默认分配 8 MiB 页缓存）。
  factory LibraryDatabase.openFile(
    String filePath, {
    int cacheSizeKib = 8192,
  }) {
    final engine = KonataSqliteEngine.openFile(
      filePath: filePath,
      databaseName: 'library',
      migrations: LibraryMigrations.steps,
      postOpenStatements: LibraryMigrations.indexStatements,
      cacheSizeKib: cacheSizeKib,
    );
    return LibraryDatabase._(engine);
  }

  /// 打开纯内存 `library.db`（用于 `:memory:` 单元测试）。
  factory LibraryDatabase.openInMemory() {
    final engine = KonataSqliteEngine.openInMemory(
      databaseName: 'library',
      migrations: LibraryMigrations.steps,
      postOpenStatements: LibraryMigrations.indexStatements,
    );
    return LibraryDatabase._(engine);
  }

  /// 底层响应式 SQLite 引擎。
  final KonataSqliteEngine engine;

  /// 媒体源表 DAO。
  final MediaSourceDao mediaSources;

  /// 系列编组表 DAO。
  final SeriesGroupDao seriesGroups;

  /// 作品主表 DAO。
  final WorkDao works;

  /// 逻辑剧集表 DAO。
  final EpisodeDao episodes;

  /// 物理版本表 DAO。
  final MediaVariantDao mediaVariants;

  /// 忽略目录表 DAO。
  final IgnoredFolderDao ignoredFolders;

  /// 构造跨包只读媒体库查询端口适配器。
  LibraryReadPort createReadPort() => StorageLibraryReadAdapter(this);

  /// 关闭数据库连接。
  Future<void> close() => engine.close();
}

/// 将 [LibraryDatabase] 适配为 `konata_contracts` 定义的极薄只读 [LibraryReadPort]。
final class StorageLibraryReadAdapter implements LibraryReadPort {
  /// 创建媒体库只读适配器。
  const StorageLibraryReadAdapter(this._db);

  final LibraryDatabase _db;

  @override
  Future<WorkSummaryView?> findWorkSummary(WorkId workId) async =>
      _db.works.findById(workId)?.toSummaryView();

  @override
  Future<List<WorkSummaryView>> listVisibleWorks() async => <WorkSummaryView>[
    for (final work in _db.works.listVisible()) work.toSummaryView(),
  ];

  @override
  Future<List<EpisodeSummaryView>> listEpisodesForWork(WorkId workId) async =>
      <EpisodeSummaryView>[
        for (final ep in _db.episodes.listByWork(workId)) ep.toSummaryView(),
      ];

  @override
  Future<MediaSourceView?> findMediaSource(SourceId sourceId) async =>
      _db.mediaSources.findById(sourceId)?.toReadView();

  @override
  Future<List<MediaSourceView>> listMediaSources() async => <MediaSourceView>[
    for (final src in _db.mediaSources.listAll()) src.toReadView(),
  ];
}
