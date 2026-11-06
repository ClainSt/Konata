import 'dart:convert';
import 'catalog.dart';
import 'logical_episode_store.dart';
import 'watch_event_store.dart';
import 'logical_episode_identity.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Local history operations use existing tables and never touch media files.
class PlaybackHistory {
  const PlaybackHistory(this.db);
  final Database db;

  Future<List<Map<String, Object?>>> entries() async {
    final rows = await db.rawQuery('''
    SELECT assets.*, works.title AS work_title, sources.label AS source_label,
      progress.position_ms, progress.duration_ms, progress.completed,
      progress.updated_at
    FROM progress
    JOIN assets ON assets.id=progress.asset_id
    LEFT JOIN works ON works.id=assets.work_id
    LEFT JOIN sources ON sources.id=assets.source_id
    ORDER BY progress.updated_at DESC, assets.id
  ''');
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name']).toSet();
    final works = {for (final w in await db.query('works')) w['id']: w};
    final cached = <Object?, Map<String, dynamic>>{};
    if (tables.contains('work_details')) {
      for (final detail in await db.query('work_details')) {
        final work = works[detail['work_id']];
        if (work == null ||
            detail['identity'] != Catalog.detailIdentity(work)) {
          continue;
        }
        try {
          final payload = jsonDecode(detail['payload'].toString());
          if (payload is Map<String, dynamic>) {
            cached[detail['work_id']] = payload;
          }
        } catch (_) {
          /* A damaged optional cache never hides history. */
        }
      }
    }
    final locked = tables.contains('asset_overrides')
        ? (await db.query(
            'asset_overrides',
            columns: ['asset_id'],
          )).map((r) => r['asset_id']).toSet()
        : <Object?>{};
    final entries = rows
        .map(
          (row) => <String, Object?>{
            ...row,
            '_work': works[row['work_id']] ?? <String, Object?>{},
            '_details': cached[row['work_id']] ?? <String, dynamic>{},
            if (locked.contains(row['id'])) 'manual_mapping': true,
          },
        )
        .toList();
    if (tables.contains('watch_events')) {
      final states = <String, LogicalWatchState>{};
      for (final row in entries) {
        final id = row['id'] as String;
        final key = await LogicalEpisodeStore(db).resolve(id);
        row['_logical_key'] = key;
        row['_candidate_key'] = LogicalEpisodeIdentity.forAsset(
          work: row['_work'] as Map<String, Object?>,
          asset: row,
        );
        if (key != null) {
          final state = states[key] ??= await WatchEventStore(db).state(key);
          row['_logical_conflict'] = state.conflict;
          row['_logical_completed'] = state.completed;
        }
      }
    }
    return entries;
  }

  Future<void> setCompleted(String assetId, bool completed) async {
    await db.transaction((tx) async {
      final count = await tx.update(
        'progress',
        {
          'completed': completed ? 1 : 0,
          'manual_completed': completed ? 1 : 0,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'asset_id=?',
        whereArgs: [assetId],
      );
      if (count != 1) throw StateError('播放记录已不存在，请刷新后重试');
      if ((await tx.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='watch_events'",
      )).isNotEmpty) {
        final key = await LogicalEpisodeStore.resolveIn(tx, assetId);
        if (key != null) {
          await WatchEventStore.recordManual(
            tx,
            key,
            completed,
            assetId: assetId,
          );
        }
      }
    });
  }

  Future<void> remove(String assetId) async {
    await db.delete('progress', where: 'asset_id=?', whereArgs: [assetId]);
  }

  Future<void> clear() async {
    await db.delete('progress');
  }

  static String time(Object? milliseconds) {
    final raw = milliseconds is num ? milliseconds.toInt() : 0;
    final seconds = (raw < 0 ? 0 : raw) ~/ 1000;
    final h = seconds ~/ 3600;
    final m = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
