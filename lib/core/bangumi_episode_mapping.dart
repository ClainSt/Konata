import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'logical_episode_store.dart';
import 'watch_event_origin.dart';

/// Official public API, without mirrors, cached fallback or account credentials.
class BangumiEpisodeVerifier {
  BangumiEpisodeVerifier(this.client);
  final http.Client client;
  Future<Map<String, Object?>> verify(
    int subjectId,
    int episodeId,
    int expectedType,
  ) async {
    if (subjectId < 1 || episodeId < 1 || ![0, 1].contains(expectedType)) {
      throw ArgumentError(
        'Explicit subject, episode and content type required',
      );
    }
    final request =
        http.Request('GET', Uri.https('api.bgm.tv', '/v0/episodes/$episodeId'))
          ..followRedirects = false
          ..headers['User-Agent'] =
              'ClainSt/Konata/1.0.0 (https://github.com/ClainSt/Konata)'
          ..headers['Accept'] = 'application/json';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Bangumi HTTP ${response.statusCode}');
    }
    if ((response.contentLength ?? 0) > 1048576) {
      throw const FormatException('Episode response too large');
    }
    final bytes = <int>[];
    await for (final part in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      bytes.addAll(part);
      if (bytes.length > 1048576) {
        throw const FormatException('Episode response too large');
      }
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> ||
        data['id'] != episodeId ||
        data['subject_id'] != subjectId ||
        data['type'] != expectedType ||
        data['name'] is! String ||
        data['sort'] is! num ||
        !(data['sort'] as num).isFinite ||
        data['sort'] < 0) {
      throw const FormatException(
        'Episode does not match the reviewed subject or type',
      );
    }
    return {
      'subject_id': subjectId,
      'episode_id': episodeId,
      'episode_type': expectedType,
      'episode_sort': (data['sort'] as num).toDouble(),
      'episode_name': data['name'],
    };
  }
}

class BangumiEpisodeMapping {
  const BangumiEpisodeMapping(this.db);
  final Database db;
  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE IF NOT EXISTS bangumi_episode_mappings (
      id INTEGER PRIMARY KEY AUTOINCREMENT, episode_key TEXT NOT NULL,
      asset_id TEXT NOT NULL, revision INTEGER NOT NULL,
      subject_id INTEGER NOT NULL, episode_id INTEGER NOT NULL,
      episode_type INTEGER NOT NULL, episode_sort REAL NOT NULL,
      episode_name TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
      verified_at TEXT NOT NULL)''');
    await tx.execute(
      'CREATE INDEX IF NOT EXISTS bangumi_mapping_key ON bangumi_episode_mappings(episode_key,id)',
    );
  }

  static Future<Map<String, Object?>?> _head(
    DatabaseExecutor tx,
    String key,
  ) async {
    final rows = await tx.query(
      'bangumi_episode_mappings',
      where: 'episode_key=?',
      whereArgs: [key],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  static Future<bool> _valid(
    DatabaseExecutor tx,
    Map<String, Object?> row,
  ) async =>
      row['revoked'] == 0 &&
      row['revision'] ==
          await WatchEventOrigin.revision(tx, row['asset_id'] as String) &&
      await LogicalEpisodeStore.resolveIn(tx, row['asset_id'] as String) ==
          row['episode_key'];
  Future<Map<String, Object?>?> current(String key) =>
      db.transaction((tx) async {
        final row = await _head(tx, key);
        return row != null && await _valid(tx, row) ? row : null;
      });

  /// Explicit user review is required by the caller. Verify again before save,
  /// then compare identity revision and mapping head to reject stale dialogs.
  Future<int> confirm({
    required BangumiEpisodeVerifier verifier,
    required String assetId,
    required String expectedKey,
    required int expectedRevision,
    required int subjectId,
    required int episodeId,
    required int expectedType,
    required int? expectedPreviousId,
  }) async {
    final verified = await verifier.verify(subjectId, episodeId, expectedType);
    return db.transaction((tx) async {
      if (await LogicalEpisodeStore.resolveIn(tx, assetId) != expectedKey ||
          await WatchEventOrigin.revision(tx, assetId) != expectedRevision) {
        throw StateError('Episode identity changed during verification');
      }
      final head = await _head(tx, expectedKey);
      if (head?['id'] != expectedPreviousId) {
        throw StateError('Mapping changed during verification');
      }
      final others = await tx.rawQuery(
        '''SELECT m.* FROM bangumi_episode_mappings m
        WHERE m.id=(SELECT MAX(n.id) FROM bangumi_episode_mappings n WHERE n.episode_key=m.episode_key)
        AND m.episode_id=? AND m.episode_key<>? AND m.revoked=0''',
        [episodeId, expectedKey],
      );
      for (final other in others) {
        if (await _valid(tx, other)) {
          throw StateError(
            'Bangumi episode already bound to another logical episode',
          );
        }
      }
      return tx.insert('bangumi_episode_mappings', {
        'episode_key': expectedKey,
        'asset_id': assetId,
        'revision': expectedRevision,
        ...verified,
        'verified_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<int?> headId(String key) =>
      db.transaction((tx) async => (await _head(tx, key))?['id'] as int?);
  Future<void> revoke(String key, int expectedId) => db.transaction((tx) async {
    final head = await _head(tx, key);
    if (head == null || head['id'] != expectedId) {
      throw StateError('Mapping changed');
    }
    if (head['revoked'] == 1) return;
    final data = Map<String, Object?>.from(head)..remove('id');
    await tx.insert('bangumi_episode_mappings', {
      ...data,
      'revoked': 1,
      'verified_at': DateTime.now().toUtc().toIso8601String(),
    });
  });
}
