import 'package:drift/drift.dart';

import 'konata_database.dart';

/// 清理媒体源下不再存在的失效文件变体与孤立作品。
///
/// 当 [scopedRoots] 非空时，仅修剪相对路径位于勾选目录范围内部的失效条目，
/// 处于范围外的已入库作品与变体一律原样保留。
Future<void> pruneStaleSourceEntriesInDb(
  KonataDatabase db, {
  required String sourceId,
  required Set<String> activeWorkIds,
  required Set<String> activeVariantIds,
  List<String> scopedRoots = const [],
}) async {
  final normalizedRoots = scopedRoots
      .map(
        (r) => r
            .trim()
            .replaceAll('\\', '/')
            .replaceAll(RegExp(r'^/+|/+$'), ''),
      )
      .where((r) => r.isNotEmpty)
      .toList(growable: false);

  bool inScope(String relativePath) {
    if (normalizedRoots.isEmpty) return true;
    final norm = relativePath
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    return normalizedRoots.any(
      (root) => norm == root || norm.startsWith('$root/'),
    );
  }

  await db.transaction(() async {
    final existingVariants = await (db.select(
      db.mediaVariants,
    )..where((t) => t.sourceId.equals(sourceId))).get();

    final affectedWorkIds = <String>{};
    final worksWithDeletedVariants = <String>{};
    for (final v in existingVariants) {
      if (!inScope(v.relativePath)) continue;
      affectedWorkIds.add(v.workId);
      if (!activeVariantIds.contains(v.id)) {
        worksWithDeletedVariants.add(v.workId);
        await (db.delete(
          db.mediaVariants,
        )..where((t) => t.id.equals(v.id))).go();
      }
    }

    // 活跃作品若有单集文件被删除，立即在同一事务内清掉失去关联的孤儿剧集，杜绝详情页残留不可播幽灵集。
    for (final workId in worksWithDeletedVariants) {
      if (!activeWorkIds.contains(workId)) continue;
      final remaining = await (db.select(
        db.mediaVariants,
      )..where((t) => t.workId.equals(workId))).get();
      final referencedEpisodeIds = {
        for (final v in remaining)
          if (v.episodeId != null) v.episodeId!,
      };
      final episodes = await (db.select(
        db.episodes,
      )..where((t) => t.workId.equals(workId))).get();
      for (final ep in episodes) {
        if (!referencedEpisodeIds.contains(ep.id)) {
          await (db.delete(
            db.episodes,
          )..where((t) => t.id.equals(ep.id))).go();
        }
      }
    }

    for (final workId in affectedWorkIds) {
      if (activeWorkIds.contains(workId)) continue;
      final remaining = await (db.select(
        db.mediaVariants,
      )..where((t) => t.workId.equals(workId))).get();
      if (remaining.isNotEmpty) continue;

      await (db.delete(
        db.episodes,
      )..where((t) => t.workId.equals(workId))).go();
      await (db.delete(
        db.works,
      )..where((t) => t.id.equals(workId))).go();
    }

    // 清理重扫合并或合集拆簇后已没有任何物理变体关联的遗留空作品（如合集拆簇前旧卡片）。
    final allWorks = await db.select(db.works).get();
    for (final w in allWorks) {
      if (activeWorkIds.contains(w.id)) continue;
      final remaining = await (db.select(
        db.mediaVariants,
      )..where((t) => t.workId.equals(w.id))).get();
      if (remaining.isNotEmpty) continue;
      await (db.delete(
        db.episodes,
      )..where((t) => t.workId.equals(w.id))).go();
      await (db.delete(
        db.works,
      )..where((t) => t.id.equals(w.id))).go();
    }
  });
}

/// 按 ID 批量删除已从物理目录移除的失效文件变体（分块防 SQLite 参数上限）。
Future<void> deleteMediaVariantsBatchInDb(
  KonataDatabase db,
  List<String> variantIds,
) async {
  if (variantIds.isEmpty) return;
  const chunkSize = 200;
  await db.transaction(() async {
    for (var i = 0; i < variantIds.length; i += chunkSize) {
      final end = (i + chunkSize < variantIds.length)
          ? i + chunkSize
          : variantIds.length;
      final chunk = variantIds.sublist(i, end);
      await (db.delete(
        db.mediaVariants,
      )..where((t) => t.id.isIn(chunk))).go();
    }
  });
}

/// 清理作品下无物理视频/资源关联的孤儿剧集。
Future<void> deleteOrphanEpisodesInDb(
  KonataDatabase db,
  String workId,
) async {
  await db.transaction(() async {
    final variants = await (db.select(
      db.mediaVariants,
    )..where((t) => t.workId.equals(workId))).get();
    final referencedEpisodeIds = {
      for (final v in variants)
        if (v.episodeId != null) v.episodeId!,
    };
    final episodes = await (db.select(
      db.episodes,
    )..where((t) => t.workId.equals(workId))).get();
    for (final ep in episodes) {
      if (!referencedEpisodeIds.contains(ep.id)) {
        await (db.delete(db.episodes)..where((t) => t.id.equals(ep.id))).go();
      }
    }
  });
}

/// 写入媒体源忽略目录。
Future<void> addIgnoredFolderInDb(
  KonataDatabase db,
  String sourceId,
  String relativePath,
) async {
  final normalized = relativePath.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) return;
  await db
      .into(db.ignoredFolders)
      .insertOnConflictUpdate(
        IgnoredFoldersCompanion(
          id: Value('$sourceId::$normalized'),
          sourceId: Value(sourceId),
          relativePath: Value(normalized),
          createdAt: Value(DateTime.now()),
        ),
      );
}

/// 读取媒体源全部忽略目录。
Future<List<String>> readIgnoredFoldersInDb(
  KonataDatabase db,
  String sourceId,
) async {
  final rows = await (db.select(
    db.ignoredFolders,
  )..where((t) => t.sourceId.equals(sourceId))).get();
  return [for (final r in rows) r.relativePath];
}

/// 删除一条媒体源忽略目录规则。
Future<void> removeIgnoredFolderInDb(
  KonataDatabase db,
  String sourceId,
  String relativePath,
) async {
  final normalized = relativePath.trim().replaceAll('\\', '/');
  await (db.delete(
    db.ignoredFolders,
  )..where((t) => t.id.equals('$sourceId::$normalized'))).go();
}

/// 仅从媒体库移除指定作品及衍生数据（绝不触碰源目录文件）。
Future<void> deleteWorkInDb(KonataDatabase db, String workId) async {
  await db.transaction(() async {
    await (db.delete(db.mediaVariants)..where((t) => t.workId.equals(workId)))
        .go();
    await (db.delete(db.episodes)..where((t) => t.workId.equals(workId))).go();
    await (db.delete(
      db.scrapeCandidates,
    )..where((t) => t.workId.equals(workId))).go();
    await (db.delete(
      db.playbackRecords,
    )..where((t) => t.workId.equals(workId))).go();
    await (db.delete(db.works)..where((t) => t.id.equals(workId))).go();
  });
}
