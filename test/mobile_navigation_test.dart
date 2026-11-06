import 'package:ccplayer/main.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:ccplayer/ui/metadata_server_settings.dart';
import 'package:ccplayer/ui/settings_navigation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'phone uses safe area, three columns and settings routes without stacking dialogs',
    (tester) async {
      tester.binding.platformDispatcher.localesTestValue = const [
        Locale('zh', 'CN'),
      ];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      tester.view.padding = FakeViewPadding(top: 32, bottom: 20);
      final catalog = Catalog.instance;
      final oldWorks = catalog.works;
      libraryDestination.value = false;
      catalog.works = [
        for (var i = 0; i < 4; i++) {'id': 'mobile-$i', 'title': '作品 $i'},
      ];
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        catalog.works = oldWorks;
        libraryDestination.value = false;
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPadding();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(const CCPlayer(mobile: true));
      await tester.pumpAndSettle();
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        3,
      );
      expect(tester.getRect(find.text('4 部作品')).top, greaterThanOrEqualTo(32));
      for (final size in [const Size(1219, 813), const Size(2200, 1000)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        final wideGrid = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            wideGrid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, size.width < 2000 ? 7 : 13);
      }
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.text('主题模式'), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.text('主题模式'), findsNothing);
      await tester.tap(find.text('刮削服务').first);
      await tester.pumpAndSettle();
      final serviceTile = find.widgetWithText(ListTile, '刮削服务');
      await tester.ensureVisible(serviceTile);
      await tester.tap(serviceTile);
      await tester.pumpAndSettle();
      expect(find.byType(MetadataServerSettings), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(MetadataServerSettings))),
        isA<PageRoute>(),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MetadataServerSettings), findsNothing);
      await tester.tap(find.text('TMDB API 设置'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsFormSurface), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-library')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(find.byType(GridView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
