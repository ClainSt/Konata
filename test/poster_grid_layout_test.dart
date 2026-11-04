import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/main.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('poster sizes stay equal for one-line and two-line titles', (
    tester,
  ) async {
    final db = await tester.runAsync(
      () => databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
    );
    final catalog = Catalog.instance;
    catalog.db = db!;
    await tester.runAsync(() async {
      await db.execute(
        'CREATE TABLE sources (id TEXT PRIMARY KEY, label TEXT)',
      );
      await db.execute(
        'CREATE TABLE works (id TEXT PRIMARY KEY, title TEXT, year INTEGER, '
        'manual_lock INTEGER, needs_review INTEGER, poster TEXT, '
        'poster_fallback TEXT, manual_cover_url TEXT)',
      );
      await db.execute(
        'CREATE TABLE assets (id TEXT PRIMARY KEY, episode INTEGER, name TEXT)',
      );
      await db.execute(
        'CREATE TABLE scan_roots (source_id TEXT, relative_path TEXT)',
      );
      await db.insert('works', {
        'id': 'short',
        'title': '86',
        'year': 2021,
        'manual_lock': 1,
        'needs_review': 0,
      });
      await db.insert('works', {
        'id': 'long',
        'title': '16bit的感动 ANOTHER LAYER',
        'year': 2023,
        'manual_lock': 1,
        'needs_review': 0,
      });
      await catalog.reload();
      catalog.updateStatus('就绪');
    });

    await tester.binding.setSurfaceSize(const Size(940, 760));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pumpAndSettle();

    final short = find.byKey(const ValueKey('library-poster-short'));
    final long = find.byKey(const ValueKey('library-poster-long'));
    expect(short, findsOneWidget);
    expect(long, findsOneWidget);
    final shortRect = tester.getRect(short);
    final longRect = tester.getRect(long);
    expect(shortRect.width, closeTo(longRect.width, 0.1));
    expect(shortRect.height, closeTo(longRect.height, 0.1));
    expect(shortRect.height / shortRect.width, closeTo(1.5, 0.01));
    expect(shortRect.top, closeTo(longRect.top, 0.1));

    // Metadata must follow the actual one-line title immediately instead
    // of being pushed down by a permanently reserved second title line.
    final shortTitle = find.byKey(const ValueKey('library-title-short'));
    final longTitle = find.byKey(const ValueKey('library-title-long'));
    final shortStatus = find.text('2021 · 已手动绑定');
    final longStatus = find.text('2023 · 已手动绑定');
    expect(shortStatus, findsOneWidget);
    expect(longStatus, findsOneWidget);
    expect(
      tester.getTopLeft(shortStatus).dy - tester.getBottomLeft(shortTitle).dy,
      closeTo(4, 0.5),
    );
    expect(
      tester.getTopLeft(longStatus).dy - tester.getBottomLeft(longTitle).dy,
      closeTo(4, 0.5),
    );

    await tester.binding.setSurfaceSize(const Size(700, 760));
    await tester.pumpAndSettle();
    final resizedShort = tester.getRect(short);
    final resizedLong = tester.getRect(long);
    expect(resizedShort.height, closeTo(resizedLong.height, 0.1));
    expect(resizedShort.height / resizedShort.width, closeTo(1.5, 0.01));
  });
}
