import 'dart:math' as math;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'library_foundation.dart';
import 'watched_timeline.dart';

typedef ChapterPart = ({String asset, int? start, int? end});

class ChapterRelations {
  const ChapterRelations(this.db);
  final Database db;
  static const portableTables = [
    'media_chapters',
    'chapter_editions',
    'chapter_parts',
  ];

  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''CREATE TABLE media_chapters (
      id TEXT PRIMARY KEY, work_id TEXT NOT NULL, title TEXT NOT NULL,
      watched INTEGER, revision INTEGER NOT NULL DEFAULT 0)''');
    await tx.execute(
      'CREATE INDEX media_chapters_work ON media_chapters(work_id)',
    );
    await tx.execute('''CREATE TABLE chapter_editions (
      id TEXT PRIMARY KEY, chapter_id TEXT NOT NULL, label TEXT NOT NULL,
      expected_parts INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0)''');
    await tx.execute(
      'CREATE INDEX chapter_editions_chapter ON chapter_editions(chapter_id)',
    );
    await tx.execute('''CREATE TABLE chapter_parts (
      edition_id TEXT NOT NULL, ordinal INTEGER NOT NULL, asset_id TEXT NOT NULL,
      content_revision INTEGER NOT NULL, start_ms INTEGER, end_ms INTEGER,
      PRIMARY KEY(edition_id,ordinal))''');
    await tx.execute(
      'CREATE INDEX chapter_parts_asset ON chapter_parts(asset_id)',
    );
    for (final (owner, table, key) in [
      ('works', 'media_chapters', 'work_id'),
      ('media_chapters', 'chapter_editions', 'chapter_id'),
      ('chapter_editions', 'chapter_parts', 'edition_id'),
      ('assets', 'chapter_parts', 'asset_id'),
    ]) {
      await tx.execute(
        '''CREATE TRIGGER chapter_cleanup_$owner AFTER DELETE ON $owner BEGIN
        DELETE FROM $table WHERE $key=OLD.id; END''',
      );
    }
    await tx.execute(
      '''CREATE TRIGGER chapter_asset_reassigned AFTER UPDATE OF work_id ON assets
      WHEN NEW.work_id IS NOT OLD.work_id BEGIN
      DELETE FROM chapter_parts WHERE asset_id=NEW.id; END''',
    );
  }

  Future<String> session() async =>
      (await db.query('scrape_runtime', columns: ['session'])).single['session']
          as String;

  static Future<void> _checkSession(
    DatabaseExecutor tx,
    String expected,
  ) async {
    final rows = await tx.query('scrape_runtime', columns: ['session']);
    if (rows.single['session'] != expected) throw StateError('Library changed');
  }

  static bool _validPart(int? start, int? end) =>
      (start == null && end == null) ||
      (start != null && start >= 0 && end != null && end > start);

  Future<String> saveEdition({
    required String work,
    String? chapter,
    String? edition,
    required String title,
    required String label,
    required int expectedParts,
    required List<ChapterPart> parts,
    required String session,
    int? chapterRevision,
    int? editionRevision,
  }) async {
    final name = title.trim(), editionLabel = label.trim();
    if (name.isEmpty ||
        name.length > 300 ||
        editionLabel.isEmpty ||
        editionLabel.length > 160 ||
        parts.isEmpty ||
        expectedParts < parts.length ||
        expectedParts > 50 ||
        parts.toSet().length != parts.length ||
        parts.any((p) => !_validPart(p.start, p.end))) {
      throw const FormatException('Invalid chapter edition');
    }
    for (var i = 0; i < parts.length; i++) {
      for (final other
          in parts.take(i).where((p) => p.asset == parts[i].asset)) {
        final part = parts[i];
        if (part.start == null ||
            other.end == null ||
            part.start! < other.end!) {
          throw const FormatException('Overlapping or unordered chapter spans');
        }
      }
    }
    return db.transaction((tx) async {
      await _checkSession(tx, session);
      final owner = await tx.query(
        'works',
        columns: ['id'],
        where: 'id=? AND hidden=0',
        whereArgs: [work],
      );
      if (owner.isEmpty) throw StateError('Work is unavailable');
      final chapterId = chapter ?? LibraryFoundation.newId('chapter:');
      final editionId = edition ?? LibraryFoundation.newId('edition:');
      if (chapter == null) {
        await tx.insert('media_chapters', {
          'id': chapterId,
          'work_id': work,
          'title': name,
        });
      } else {
        final existing = (await tx.query(
          'media_chapters',
          where: 'id=? AND work_id=?',
          whereArgs: [chapter, work],
        )).firstOrNull;
        if (existing == null || existing['revision'] != chapterRevision)
          throw StateError('Chapter changed');
        await tx.update(
          'media_chapters',
          {'title': name, 'revision': (chapterRevision ?? 0) + 1},
          where: 'id=?',
          whereArgs: [chapter],
        );
      }
      if (edition == null) {
        await tx.insert('chapter_editions', {
          'id': editionId,
          'chapter_id': chapterId,
          'label': editionLabel,
          'expected_parts': expectedParts,
        });
      } else {
        final existing = (await tx.query(
          'chapter_editions',
          where: 'id=? AND chapter_id=?',
          whereArgs: [edition, chapterId],
        )).firstOrNull;
        if (existing == null || existing['revision'] != editionRevision)
          throw StateError('Edition changed');
        await tx.update(
          'chapter_editions',
          {
            'label': editionLabel,
            'expected_parts': expectedParts,
            'revision': (editionRevision ?? 0) + 1,
          },
          where: 'id=?',
          whereArgs: [edition],
        );
        await tx.delete(
          'chapter_parts',
          where: 'edition_id=?',
          whereArgs: [edition],
        );
      }
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final file = (await tx.rawQuery(
          '''SELECT c.revision,c.state,p.duration_ms FROM assets a
          JOIN library_content c ON c.asset_id=a.id LEFT JOIN progress p ON p.asset_id=a.id
          WHERE a.id=? AND a.work_id=? AND NOT EXISTS
            (SELECT 1 FROM scan_missing_assets m WHERE m.asset_id=a.id)''',
          [part.asset, work],
        )).firstOrNull;
        final length = file?['duration_ms'] as int?;
        if (file == null ||
            file['state'] != 'current' ||
            (length != null &&
                length > 0 &&
                part.end != null &&
                part.end! > length)) {
          throw StateError('File or span needs verification');
        }
        await tx.insert('chapter_parts', {
          'edition_id': editionId,
          'ordinal': i,
          'asset_id': part.asset,
          'content_revision': file['revision'],
          'start_ms': part.start,
          'end_ms': part.end,
        });
      }
      return chapterId;
    });
  }

  Future<void> mark(
    String id,
    int revision,
    bool? watched,
    String session,
  ) async {
    await db.transaction((tx) async {
      await _checkSession(tx, session);
      final changes = await tx.update(
        'media_chapters',
        {
          'watched': watched == null
              ? null
              : watched
              ? 1
              : 0,
          'revision': revision + 1,
        },
        where: 'id=? AND revision=?',
        whereArgs: [id, revision],
      );
      if (changes != 1) throw StateError('Chapter changed');
    });
  }

  Future<List<Map<String, Object?>>> chapters(String work) =>
      db.transaction((tx) async {
        final heads = await tx.query(
          'media_chapters',
          where: 'work_id=?',
          whereArgs: [work],
          orderBy: 'title',
        );
        final editions = await tx.rawQuery(
          '''SELECT e.* FROM chapter_editions e
      JOIN media_chapters c ON c.id=e.chapter_id WHERE c.work_id=? ORDER BY e.label''',
          [work],
        );
        final parts = await tx.rawQuery(
          '''SELECT p.*,a.name,a.relative_path,a.source_id,
        a.work_id AS asset_work,c.work_id,w.position_ms,w.duration_ms,w.updated_at,w.watched_ranges,
        (v.revision=p.content_revision AND v.state='current' AND a.work_id=c.work_id
          AND m.asset_id IS NULL) AS available
      FROM chapter_parts p JOIN chapter_editions e ON e.id=p.edition_id
      JOIN media_chapters c ON c.id=e.chapter_id
      LEFT JOIN assets a ON a.id=p.asset_id LEFT JOIN library_content v ON v.asset_id=a.id
      LEFT JOIN progress w ON w.asset_id=a.id LEFT JOIN scan_missing_assets m ON m.asset_id=a.id
      WHERE c.work_id=? ORDER BY p.ordinal''',
          [work],
        );
        final byEdition = <Object?, List<Map<String, Object?>>>{};
        final byChapter = <Object?, List<Map<String, Object?>>>{};
        for (final part in parts) {
          (byEdition[part['edition_id']] ??= []).add(part);
        }
        for (final edition in editions) {
          (byChapter[edition['chapter_id']] ??= []).add({
            ...edition,
            'parts': byEdition[edition['id']] ?? <Map<String, Object?>>[],
          });
        }
        return [
          for (final head in heads)
            {
              ...head,
              'editions': byChapter[head['id']] ?? <Map<String, Object?>>[],
            },
        ];
      });

  static List<Map<String, Object?>> parts(Map edition) =>
      (edition['parts'] as List).cast<Map<String, Object?>>();
  static List<Map<String, Object?>> editions(Map chapter) =>
      (chapter['editions'] as List).cast<Map<String, Object?>>();

  static bool playable(Map edition) =>
      parts(edition).length == edition['expected_parts'] &&
      parts(edition).asMap().entries.every(
        (entry) =>
            entry.value['available'] == 1 &&
            entry.value['ordinal'] == entry.key,
      );

  static bool partWatched(Map part, int percent) {
    if (part['available'] != 1) return false;
    final start = part['start_ms'] as int? ?? 0;
    final duration = part['duration_ms'] as int? ?? 0;
    final end = part['end_ms'] as int? ?? duration;
    if (end <= start || end > duration) return false;
    final watched = WatchedTimeline.decode(part['watched_ranges']).ranges.fold(
      0,
      (sum, range) =>
          sum +
          math.max(0, math.min(range.end, end) - math.max(range.start, start)),
    );
    return watched * 100 >= (end - start) * percent;
  }

  static bool completed(Map chapter, int percent) {
    final manual = chapter['watched'] as int?;
    return manual == null
        ? editions(chapter).any(
            (edition) =>
                playable(edition) &&
                parts(edition).every((part) => partWatched(part, percent)),
          )
        : manual == 1;
  }

  static Map<String, Object?>? preferredEdition(Map chapter) {
    final candidates = editions(chapter).where(playable).toList();
    String latest(Map edition) => parts(edition)
        .map((part) => part['updated_at'] as String?)
        .whereType<String>()
        .fold('', (latest, next) => next.compareTo(latest) > 0 ? next : latest);
    candidates.sort((a, b) => latest(b).compareTo(latest(a)));
    return candidates.firstOrNull;
  }

  static int startPosition(Map part) {
    final start = part['start_ms'] as int? ?? 0;
    final last = part['position_ms'] as int? ?? 0;
    final end = part['end_ms'] as int? ?? part['duration_ms'] as int? ?? 0;
    return last >= start && last < end ? last : start;
  }

  static void validateSnapshot(Map<String, dynamic> tables) {
    final works = {for (final w in tables['works'] as List) w['id']};
    final assets = {
      for (final a in tables['assets'] as List) a['id']: a['work_id'],
    };
    final chapters = <Object?, Object?>{};
    final versions = <Object?, Map>{};
    for (final row in tables['media_chapters'] as List) {
      if (!works.contains(row['work_id']) ||
          row['id'] is! String ||
          row['title'] is! String ||
          row['title'].trim().isEmpty ||
          row['revision'] is! int ||
          row['revision'] < 0 ||
          ![0, 1, null].contains(row['watched']) ||
          chapters.containsKey(row['id'])) {
        throw const FormatException('Invalid chapter');
      }
      chapters[row['id']] = row['work_id'];
    }
    for (final row in tables['chapter_editions'] as List) {
      if (!chapters.containsKey(row['chapter_id']) ||
          row['id'] is! String ||
          row['label'] is! String ||
          row['expected_parts'] is! int ||
          row['expected_parts'] < 1 ||
          row['expected_parts'] > 50 ||
          row['revision'] is! int ||
          row['revision'] < 0 ||
          versions.containsKey(row['id'])) {
        throw const FormatException('Invalid chapter edition');
      }
      versions[row['id']] = row;
    }
    final spans = <(Object?, Object?)>{};
    for (final row in tables['chapter_parts'] as List) {
      final edition = versions[row['edition_id']];
      if (edition == null ||
          assets[row['asset_id']] != chapters[edition['chapter_id']] ||
          row['content_revision'] is! int ||
          row['content_revision'] < 0 ||
          row['ordinal'] is! int ||
          row['ordinal'] < 0 ||
          row['ordinal'] >= edition['expected_parts'] ||
          !spans.add((row['edition_id'], row['ordinal'])) ||
          !_validPart(row['start_ms'] as int?, row['end_ms'] as int?)) {
        throw const FormatException('Invalid chapter part');
      }
    }
  }
}
