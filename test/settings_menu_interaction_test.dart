import 'package:ccplayer/ui/settings_choice_card.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1200, 800)]) {
    testWidgets(
      'outside tap closes settings menu and activates target once $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var saved = 0, otherTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: NipaPlayStyle.theme(Brightness.light),
            home: Scaffold(
              body: Column(
                children: [
                  SettingsChoiceCard<int>(
                    title: 'Setting',
                    description: 'Description',
                    icon: Icons.palette,
                    value: saved,
                    options: const [0, 1],
                    label: (n) => 'Option $n',
                    onChanged: (n) async => saved = n,
                    selectorKey: const ValueKey('choice'),
                  ),
                  const SizedBox(height: 220),
                  TextButton(
                    onPressed: () => otherTaps++,
                    child: const Text('Other setting'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('choice')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Other setting'));
        await tester.pumpAndSettle();
        expect(saved, 0);
        expect(
          otherTaps,
          1,
          reason: 'Outside click must reach the intended control',
        );
        expect(find.text('Option 1'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('choice')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Option 1'));
        await tester.pumpAndSettle();
        expect(saved, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
