import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:ccplayer/ui/settings_panel.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/main.dart';

void main() {
  testWidgets('one card theme update reaches settings and media sources', (
    tester,
  ) async {
    final previous = Catalog.instance.sources;
    Catalog.instance.sources = [
      {
        'id': 'example',
        'kind': 'local',
        'label': 'Theme sample',
        'location': 'Videos',
      },
    ];
    libraryDestination.value = true;
    addTearDown(() {
      Catalog.instance.sources = previous;
      libraryDestination.value = false;
    });
    for (final color in [Colors.teal, Colors.purple]) {
      final theme = NipaPlayStyle.theme(Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            cardTheme: theme.cardTheme.copyWith(color: color),
          ),
          home: const Scaffold(
            body: Column(
              children: [
                SettingsPanel(child: Text('Settings sample')),
                Expanded(child: LibraryPage()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['Settings sample', 'Theme sample']) {
        final surface = find
            .ancestor(of: find.text(label), matching: find.byType(Material))
            .first;
        expect(tester.widget<Material>(surface).color, color);
      }
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets('all settings panels share edges and surface: $brightness', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: NipaPlayStyle.theme(brightness),
          home: const Scaffold(body: SettingsPage(wideLayout: true)),
        ),
      );
      Rect? reference;
      for (final category in ['外观', '语言', '刮削服务', '记录与同步', '关于']) {
        await tester.tap(find.text(category).first);
        await tester.pumpAndSettle();
        if (category == '关于') {
          expect(find.text('关于'), findsOneWidget);
          expect(find.text('启用调试日志'), findsNothing);
          expect(
            tester.getTopLeft(find.text('Konata')).dy,
            lessThan(tester.getTopLeft(find.text('详细调试日志')).dy),
          );
          final logPanel = find.ancestor(
            of: find.text('导出最近异常日志'),
            matching: find.byType(SettingsPanel),
          );
          expect(
            find.descendant(
              of: logPanel,
              matching: find.byIcon(Icons.chevron_right),
            ),
            findsOneWidget,
          );
        }
        final panels = find.byType(SettingsPanel);
        expect(panels, findsWidgets);
        for (final panel in panels.evaluate()) {
          final finder = find.byWidget(panel.widget);
          final rect = tester.getRect(finder);
          reference ??= rect;
          expect(rect.left, reference.left);
          expect(rect.right, reference.right);
          final card = tester.widget<Card>(
            find.descendant(of: finder, matching: find.byType(Card)).first,
          );
          expect(card.margin, EdgeInsets.zero);
          final surface = tester.widget<Material>(
            find.descendant(of: finder, matching: find.byType(Material)).first,
          );
          expect(surface.color, Theme.of(panel).cardTheme.color);
          expect(surface.shape, Theme.of(panel).cardTheme.shape);
          expect(surface.elevation, 0);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}
