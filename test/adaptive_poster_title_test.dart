import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/ui/adaptive_poster_title.dart';

void main() {
  testWidgets('short title grows and long title shrinks without truncation', (
    tester,
  ) async {
    const short = '86 -不存在的战区-';
    const long = '16bit的感动 ANOTHER LAYER';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 185,
                child: AdaptivePosterTitle(
                  key: ValueKey('short-title'),
                  title: short,
                ),
              ),
              SizedBox(
                width: 185,
                child: AdaptivePosterTitle(
                  key: ValueKey('long-title'),
                  title: long,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final shortText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('short-title')),
        matching: find.byType(Text),
      ),
    );
    final longText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('long-title')),
        matching: find.byType(Text),
      ),
    );
    expect(shortText.style!.fontSize, greaterThan(longText.style!.fontSize!));
    expect(shortText.maxLines, 2);
    expect(longText.maxLines, 2);
    expect(
      tester.getSize(find.byKey(const ValueKey('short-title'))).height,
      lessThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('long-title'))).height,
      lessThanOrEqualTo(48),
    );
  });

  testWidgets('small card width reduces font size without overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 125,
            child: AdaptivePosterTitle(title: '16bit的感动 ANOTHER LAYER'),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final title = find.byType(AdaptivePosterTitle);
    final text = tester.widget<Text>(
      find.descendant(of: title, matching: find.byType(Text)),
    );
    expect(text.style!.fontSize, lessThanOrEqualTo(28));
    expect(text.style!.fontSize, greaterThanOrEqualTo(14));
    expect(tester.getSize(title).height, lessThanOrEqualTo(48));
  });
}
