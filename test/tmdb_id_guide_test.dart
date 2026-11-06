import 'package:ccplayer/ui/settings_page.dart';
import 'package:ccplayer/ui/settings_panel.dart';
import 'package:ccplayer/ui/tmdb_id_guide.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [const Size(1100, 800), const Size(320, 640)]) {
    testWidgets('TMDB ID help opens a separate dialog at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(size.width < 400 ? 1.5 : 1),
            ),
            child: child!,
          ),
          home: const Scaffold(body: SettingsPage()),
        ),
      );
      await tester.tap(find.text('刮削服务').first);
      await tester.pumpAndSettle();
      expect(find.text('元数据与刮削服务'), findsNothing);
      final help = find.byKey(const ValueKey('tmdb-id-guide'));
      expect(help, findsOneWidget);
      if (size.width > 400) {
        expect(find.text('刮削服务'), findsNWidgets(2));
        expect(
          tester.getRect(help).right,
          tester.getRect(find.byType(SettingsPanel).first).right,
        );
      }
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.byType(TmdbIdGuide), findsOneWidget);
      expect(find.textContaining('{tmdb-100565}'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(TmdbIdGuide), findsNothing);
      expect(help, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
