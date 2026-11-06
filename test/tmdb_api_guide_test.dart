import 'package:ccplayer/ui/tmdb_api_guide.dart';
import 'package:ccplayer/ui/tmdb_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'API help opens from credential field and returns on $platform',
      (tester) async {
        await tester.binding.setSurfaceSize(
          platform == TargetPlatform.android
              ? const Size(320, 640)
              : const Size(1100, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => TmdbSettingsDialog.show(context),
                  child: const Text('设置'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        final help = find.byKey(const ValueKey('tmdb-api-help'));
        await tester.ensureVisible(help);
        await tester.tap(help);
        await tester.pumpAndSettle();
        expect(find.byType(TmdbApiGuide), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TmdbApiGuide),
            matching: find.textContaining('API Read Access Token'),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('两种凭据不能混用'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        expect(find.byType(TmdbApiGuide), findsNothing);
        expect(help, findsOneWidget);
        await tester.tap(find.byTooltip('关闭 TMDB 设置'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
