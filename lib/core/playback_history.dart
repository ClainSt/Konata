import 'dart:convert';
import 'catalog.dart';
import 'logical_episode_store.dart';
import 'watch_event_store.dart';
import 'logical_episode_identity.dart';
import 'metadata_servers.dart';
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
    final artwork = <Object?, Map<String, Object?>>{};
    if (tables.containsAll(['scan_bindings', 'library_content', 'scan_missing_assets'])) {
      final scoped = tables.contains('scoped_artwork');
      for (final row in await db.rawQuery('''
        SELECT e.asset_id, json_extract(e.adopted,'\$.still') AS still,
          ${scoped ? 's.state AS artwork_state, s.selected' : 'NULL AS artwork_state, NULL AS selected'}
        FROM progress p JOIN scan_bindings e ON e.asset_id=p.asset_id
        JOIN library_content c ON c.asset_id=e.asset_id AND c.state='current'
        JOIN scan_bindings r ON r.work_id=e.work_id AND r.provider='tmdb'
          AND r.layer='range' AND r.state='confirmed'
          AND e.parent=json_array(r.id,r.revision)
        JOIN scan_bindings w ON w.work_id=e.work_id AND w.provider='tmdb'
          AND w.layer='work' AND w.state='confirmed'
          AND r.parent=json_array(w.id,w.revision)
        ${scoped ? """
          LEFT JOIN scoped_artwork s ON s.work_id=e.work_id AND s.kind='still'
            AND s.scope=json_array('episode',json_extract(w.adopted,'\$.id'),
              json_extract(e.adopted,'\$.season'),json_extract(e.adopted,'\$.episode'))
          """ : ''}
        WHERE e.provider='tmdb' AND e.layer='episode' AND e.state='confirmed'
          AND NOT EXISTS (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=e.asset_id)
      ''')) {
        if (row['artwork_state'] == 'empty') {
          artwork[row['asset_id']] = {'_blank_still': true};
        } else if (row['artwork_state'] == 'manual' && row['selected'] is String) {
          final selection = jsonDecode(row['selected'] as String) as Map;
          if (selection['url'] is String) {
            artwork[row['asset_id']] = {'_recognized_still': selection['url']};
          }
        } else if (row['still'] case final String still
            when MetadataServers.imageResource(still)?.$1 == 1) {
          artwork[row['asset_id']] = {'_recognized_still': still};
        }
      }
    }
    final entries = rows
        .map(
          (row) => <String, Object?>{
            ...row,
            ...?artwork[row['id']],
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
    await removeMany([assetId]);
  }

  Future<void> removeMany(Iterable<String> assetIds) async {
    // One transaction: cancellation or a failure must not partly delete a selection.
    await db.transaction((tx) async {
      final batch = tx.batch();
      for (final id in assetIds.toSet()) {
        batch.delete('progress', where: 'asset_id=?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    });
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
