import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in [
    const Locale('en'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ]) {
    testWidgets('backup export is available in history settings: $locale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SettingsPage(wideLayout: true)),
      ));
      await tester.tap(find.byKey(const ValueKey('settings-category-3')));
      await tester.pumpAndSettle();
      final inspect = find.byKey(const ValueKey('library-backup-inspect'));
      expect(inspect, findsOneWidget);
      expect(tester.widget<ListTile>(inspect).onTap, isNotNull);
      final export = find.byKey(const ValueKey('library-backup-export'));
      expect(export, findsOneWidget);
      final tile = tester.widget<ListTile>(export);
      expect(tile.onTap, isNotNull);
      expect(
        find.descendant(
          of: export,
          matching: find.byIcon(Icons.archive_outlined),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
