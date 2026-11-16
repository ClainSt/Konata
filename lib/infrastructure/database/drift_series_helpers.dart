import 'package:drift/drift.dart';

import '../../domain/models/series_group.dart';
import 'konata_database.dart';

/// 新增或更新系列（Series）分组记录。
Future<void> upsertSeriesGroupInDb(
  KonataDatabase db,
  SeriesGroup group,
) async {
  await db
      .into(db.seriesGroups)
      .insertOnConflictUpdate(
        SeriesGroupsCompanion(
          id: Value(group.id),
          title: Value(group.title),
          tmdbCollectionId: Value(group.tmdbCollectionId),
          rootFolderHint: Value(group.rootFolderHint),
          createdAt: Value(group.createdAt),
          updatedAt: Value(group.updatedAt),
        ),
      );
}

/// 根据主键 ID 查询系列分组。
Future<SeriesGroup?> findSeriesGroupByIdInDb(
  KonataDatabase db,
  String seriesId,
) async {
  final query = db.select(db.seriesGroups)
    ..where((t) => t.id.equals(seriesId));
  final row = await query.getSingleOrNull();
  return row == null ? null : mapSeriesGroupRow(row);
}

/// 查询库内全部系列分组。
Future<List<SeriesGroup>> getAllSeriesGroupsInDb(KonataDatabase db) async {
  final query = db.select(db.seriesGroups)
    ..orderBy([(t) => OrderingTerm.asc(t.title)]);
  final rows = await query.get();
  return [for (final row in rows) mapSeriesGroupRow(row)];
}

/// 删除系列分组并将成员作品的系列归属字段置空。
Future<void> deleteSeriesGroupInDb(
  KonataDatabase db,
  String seriesId,
) async {
  await db.transaction(() async {
    await (db.update(db.works)..where((t) => t.seriesId.equals(seriesId))).write(
      const WorksCompanion(
        seriesId: Value(null),
        seriesOrder: Value(null),
        seriesLabel: Value(null),
      ),
    );
    await (db.delete(db.seriesGroups)..where((t) => t.id.equals(seriesId)))
        .go();
  });
}

/// 将 Drift 行对象映射为纯领域 [SeriesGroup] 实体。
SeriesGroup mapSeriesGroupRow(SeriesGroupRow row) => SeriesGroup(
  id: row.id,
  title: row.title,
  tmdbCollectionId: row.tmdbCollectionId,
  rootFolderHint: row.rootFolderHint,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
);
