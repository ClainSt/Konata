import 'package:ccplayer/ui/settings_page.dart';
import 'package:ccplayer/core/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'language follows appearance and about stays last on $platform',
      (tester) async {
        await tester.binding.setSurfaceSize(
          platform == TargetPlatform.windows
              ? const Size(1100, 800)
              : const Size(390, 844),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: const Scaffold(body: SettingsPage(embedded: true)),
          ),
        );
        await tester.pumpAndSettle();
        final order = [0, 4, 1, 5, 3, 2];
        for (var index = 1; index < order.length; index++) {
          expect(
            tester
                .getTopLeft(
                  find.byKey(ValueKey('settings-category-${order[index]}')),
                )
                .dy,
            greaterThan(
              tester
                  .getTopLeft(
                    find.byKey(
                      ValueKey('settings-category-${order[index - 1]}'),
                    ),
                  )
                  .dy,
            ),
          );
        }
        await tester.tap(find.byKey(const ValueKey('settings-category-4')));
        await tester.pumpAndSettle();
        final selector = find.byKey(const ValueKey('settings-language'));
        expect(selector, findsOneWidget);
        final selectedText = tester.widget<Text>(
          find.descendant(of: selector, matching: find.byType(Text)).first,
        );
        await tester.tap(selector);
        await tester.pumpAndSettle();
        final menuText = tester.widget<Text>(
          find
              .descendant(
            of: find.byType(PopupMenuItem<AppLanguageChoice>).first,
                matching: find.byType(Text),
              )
              .first,
        );
        expect(menuText.style, selectedText.style);
        expect(menuText.style!.fontSize, 16);
        expect(menuText.style!.fontWeight, FontWeight.w600);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
