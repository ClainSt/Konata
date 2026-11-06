import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/playback_history.dart';
import 'package:ccplayer/core/watched_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'v14 migration preserves old progress; intervals persist, deduplicate and respect manual status',
    () async {
      final dir = await Directory.systemTemp.createTemp('ccplayer-watched-');
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      var db = cat.db;
      try {
        await db.execute('ALTER TABLE progress DROP COLUMN watched_ranges');
        await db.setVersion(14);
        await db.insert('progress', {
          'asset_id': 'legacy',
          'position_ms': 95000,
          'duration_ms': 100000,
          'completed': 1,
          'manual_completed': null,
          'updated_at': '2026-11-01T00:00:00Z',
        });
        await db.close();
        await cat.initialize(dataDirectory: dir);
        db = cat.db;
        expect(await db.getVersion(), 18);
        final old = (await db.query('progress')).single;
        expect(old['position_ms'], 95000);
        expect(old['completed'], 1);
        expect(old['watched_ranges'], isNull);
        await cat.progress('legacy', 1000, 100000);
        expect(
          (await db.query(
            'progress',
            where: 'asset_id=?',
            whereArgs: ['legacy'],
          )).single['completed'],
          1,
        );

        // A fresh record with a seek to the end remains unwatched.
        await cat.progress('new', 99000, 100000);
        var row = (await db.query(
          'progress',
          where: 'asset_id=?',
          whereArgs: ['new'],
        )).single;
        expect(row['completed'], 0);
        await cat.progress(
          'new',
          50000,
          100000,
          watchedRanges: [const WatchedRange(0, 50000)],
        );
        await db.close();
        await cat.initialize(dataDirectory: dir);
        db = cat.db;
        // Repeated and overlapping snapshots merge across sessions.
        await Future.wait([
          cat.progress(
            'new',
            70000,
            100000,
            watchedRanges: [const WatchedRange(40000, 70000)],
          ),
          cat.progress(
            'new',
            90000,
            100000,
            watchedRanges: [const WatchedRange(60000, 90000)],
          ),
        ]);
        row = (await db.query(
          'progress',
          where: 'asset_id=?',
          whereArgs: ['new'],
        )).single;
        expect(
          WatchedTimeline.decode(
            row['watched_ranges'],
          ).coveredMilliseconds(100000),
          90000,
        );
        expect(row['completed'], 1);
        await cat.progress('new', 1000, 100000);
        expect(
          (await db.query(
            'progress',
            where: 'asset_id=?',
            whereArgs: ['new'],
          )).single['completed'],
          1,
        );
        await PlaybackHistory(db).setCompleted('new', false);
        await cat.progress(
          'new',
          100000,
          100000,
          watchedRanges: [const WatchedRange(0, 100000)],
        );
        expect(
          (await db.query(
            'progress',
            where: 'asset_id=?',
            whereArgs: ['new'],
          )).single['completed'],
          0,
        );
        await PlaybackHistory(db).remove('new');
        expect(await cat.resumePosition('new'), 0);
        await cat.progress('new', 99000, 100000);
        expect(
          (await db.query(
            'progress',
            where: 'asset_id=?',
            whereArgs: ['new'],
          )).single['completed'],
          0,
        );
        await cat.progress(
          'custom',
          75000,
          100000,
          watchedRanges: [const WatchedRange(0, 75000)],
          completionPercent: 75,
        );
        expect(
          (await db.query(
            'progress',
            where: 'asset_id=?',
            whereArgs: ['custom'],
          )).single['completed'],
          1,
        );
        await PlaybackHistory(db).clear();
        expect(await db.query('progress'), isEmpty);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
