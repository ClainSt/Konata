import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'tablet landscape uses two panes and phone width uses category home',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const SettingsPage(embedded: true),
        ),
      );
      await tester.pumpAndSettle();
      final category = find.byKey(const ValueKey('settings-category-0'));
      expect(
        tester.getRect(category).right,
        lessThan(tester.getRect(find.text('主题模式')).left),
      );
      await tester.tap(find.byKey(const ValueKey('settings-category-1')));
      await tester.pumpAndSettle();
      expect(find.text('TMDB API 设置'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-category-0')), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      expect(find.text('TMDB API 设置'), findsNothing);
      expect(find.text('主题模式'), findsNothing);
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('刮削服务'), findsOneWidget);
      expect(find.text('关于'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [390.0, 1100.0]) {
    testWidgets('search opens inline without moving toolbar at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      libraryDestination.value = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: NipaPlayStyle.theme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: LibraryPage(mobile: width < 600),
        ),
      );
      await tester.pumpAndSettle();
      final toolbar = find.byKey(const ValueKey('library-toolbar-row'));
      final before = tester.getRect(toolbar);
      await tester.tap(find.byKey(const ValueKey('library-search-toggle')));
      await tester.pumpAndSettle();
      expect(tester.getRect(toolbar), before);
      expect(
        tester.getRect(find.byType(TextField)).height,
        tester
            .getRect(find.byKey(const ValueKey('library-search-toggle')))
            .height,
      );
      await tester.tap(find.byKey(const ValueKey('library-search-toggle')));
      await tester.pumpAndSettle();
      expect(tester.getRect(toolbar), before);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
