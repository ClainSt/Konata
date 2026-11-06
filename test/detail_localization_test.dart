import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/nipaplay_detail_page.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final traditional in [false, true]) {
    testWidgets('localized detail controls at narrow large text: $traditional', (
      tester,
    ) async {
      final db = (await tester.runAsync(() async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        await db.execute(
          'CREATE TABLE work_details (work_id TEXT PRIMARY KEY, identity TEXT, payload TEXT, fetched_at TEXT)',
        );
        await db.execute(
          'CREATE TABLE assets (id TEXT PRIMARY KEY, work_id TEXT)',
        );
        await db.execute(
          'CREATE TABLE progress (asset_id TEXT PRIMARY KEY, position_ms INTEGER, duration_ms INTEGER, completed INTEGER, updated_at TEXT)',
        );
        return db;
      }))!;
      Catalog.instance.db = db;
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(db.close);
        await tester.binding.setSurfaceSize(null);
      });
      var edits = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: traditional
              ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
              : const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: NipaPlayDetailPage(
            work: const {'id': 'local', 'title': '原始作品名'},
            assets: const [],
            onBack: () {},
            onEditMetadata: () => edits++,
            onEditCover: () {},
            onDelete: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tabs = find.byKey(const ValueKey('detail-section-tabs'));
      final labels = find.descendant(of: tabs, matching: find.byType(Text));
      final positions = tester
          .widgetList<Text>(labels)
          .map((label) => tester.getTopLeft(find.byWidget(label)).dy)
          .toList();
      expect(positions, hasLength(2));
      expect(positions.first, positions.last);
      expect(find.text('原始作品名'), findsOneWidget);
      expect(find.text(traditional ? '暫無作品簡介' : 'No synopsis'), findsOneWidget);
      expect(find.text(traditional ? '暫無正片' : 'No episodes'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('detail-more-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(traditional ? '編輯中繼資料' : 'Edit details'));
      await tester.pumpAndSettle();
      expect(edits, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
