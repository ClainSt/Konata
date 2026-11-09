import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/unclassified_page.dart';

void main() {
  for (final size in [
    const Size(320, 800),
    const Size(800, 360),
    const Size(1024, 768),
    const Size(480, 480),
  ]) {
    testWidgets('batch classification stays usable at $size with large text', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      final cat = Catalog.instance;
      final oldWorks = cat.works, oldAssets = cat.assets;
      addTearDown(() async {
        cat.works = oldWorks;
        cat.assets = oldAssets;
        await tester.binding.setSurfaceSize(null);
      });
      cat.works = [
        {'id': 'work:s:pending', 'title': 'Pending', 'needs_review': 1},
        {
          'id': 'work:s:target',
          'title': 'A very long title / 中日文作品名称 / ちょびっツ',
          'needs_review': 0,
        },
        {
          'id': 'work:other:pending',
          'title': 'Other source',
          'needs_review': 1,
        },
      ];
      cat.assets = [
        {
          'id': 'a',
          'source_id': 's',
          'work_id': 'work:s:pending',
          'name': '第一部 - 01.mkv',
          'relative_path': 'Mixed/第一部 - 01.mkv',
        },
        {
          'id': 'b',
          'source_id': 's',
          'work_id': 'work:s:pending',
          'name': 'Second - 01.mkv',
          'relative_path': 'Mixed/Second - 01.mkv',
        },
        {
          'id': 'c',
          'source_id': 'other',
          'work_id': 'work:other:pending',
          'name': 'Other.mkv',
          'relative_path': 'Other.mkv',
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const UnclassifiedPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Select all from this source'));
      await tester.pumpAndSettle();
      expect(find.text('Assign to title (2)'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('pending-file-c')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      final other = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('pending-file-c')),
      );
      expect(other.onChanged, isNull);
      await tester.tap(find.text('Assign to title (2)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ちょびっツ');
      await tester.pumpAndSettle();
      expect(find.text('A very long title / 中日文作品名称 / ちょびっツ'), findsOneWidget);
      expect(find.text('Other source'), findsNothing);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
