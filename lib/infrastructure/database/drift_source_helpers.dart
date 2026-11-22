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

    final staleVariantIds = <String>[];
    for (final v in existingVariants) {
      if (!inScope(v.relativePath)) continue;
      if (!activeVariantIds.contains(v.id)) {
        staleVariantIds.add(v.id);
      }
    }

    // 分块批量删除失效变体，避免逐行 DELETE 往返。
    const chunkSize = 400;
    for (var i = 0; i < staleVariantIds.length; i += chunkSize) {
      final end = (i + chunkSize) > staleVariantIds.length
          ? staleVariantIds.length
          : i + chunkSize;
      final chunk = staleVariantIds.sublist(i, end);
      await (db.delete(
        db.mediaVariants,
      )..where((t) => t.id.isIn(chunk))).go();
    }

    // 一次索引聚合查询找出仍拥有至少一个物理变体的作品 ID，彻底消除逐作品 N+1 查询。
    final occupiedRows = await db
        .customSelect('SELECT DISTINCT work_id FROM media_variants')
        .get();
    final occupiedWorkIds = <String>{
      for (final row in occupiedRows) row.read<String>('work_id'),
    };

    final allWorkIdRows = await db.customSelect('SELECT id FROM works').get();
    final emptyWorkIds = <String>[];
    for (final row in allWorkIdRows) {
      final workId = row.read<String>('id');
      if (activeWorkIds.contains(workId) || occupiedWorkIds.contains(workId)) {
        continue;
      }
      emptyWorkIds.add(workId);
    }

    for (var i = 0; i < emptyWorkIds.length; i += chunkSize) {
      final end = (i + chunkSize) > emptyWorkIds.length
          ? emptyWorkIds.length
          : i + chunkSize;
      final chunk = emptyWorkIds.sublist(i, end);
      await (db.delete(db.episodes)..where((t) => t.workId.isIn(chunk))).go();
      await (db.delete(db.works)..where((t) => t.id.isIn(chunk))).go();
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
    final orphanIds = <String>[
      for (final ep in episodes)
        if (!referencedEpisodeIds.contains(ep.id)) ep.id,
    ];
    if (orphanIds.isEmpty) return;
    const chunkSize = 400;
    for (var i = 0; i < orphanIds.length; i += chunkSize) {
      final end = (i + chunkSize) > orphanIds.length
          ? orphanIds.length
          : i + chunkSize;
      final chunk = orphanIds.sublist(i, end);
      await (db.delete(db.episodes)..where((t) => t.id.isIn(chunk))).go();
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
