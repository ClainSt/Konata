import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/ui/poster_title.dart';

void main() {
  testWidgets('short and long titles have the same compact type scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 180,
                child: PosterTitle(
                  key: ValueKey('short-title'),
                  title: '86 -不存在的战区-',
                ),
              ),
              SizedBox(
                width: 180,
                child: PosterTitle(
                  key: ValueKey('long-title'),
                  title:
                      'DEEMO 樱花之音 -你奏响的音乐，如今依旧回荡- I still hear the sound of your piano',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final short = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('short-title')),
        matching: find.byType(Text),
      ),
    );
    final long = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('long-title')),
        matching: find.byType(Text),
      ),
    );
    expect(short.style!.fontSize, 16);
    expect(long.style!.fontSize, short.style!.fontSize);
    expect(short.style!.fontWeight, FontWeight.w600);
    expect(short.maxLines, 1);
    expect(long.maxLines, 1);
    expect(short.overflow, TextOverflow.ellipsis);
    expect(long.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);

    final longTooltip = tester.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const ValueKey('long-title')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(longTooltip.message, contains('I still hear'));
  });

  testWidgets('compact text does not grow to fill a wide card', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, child: PosterTitle(title: '86')),
        ),
      ),
    );
    final title = tester.widget<Text>(
      find.byKey(const ValueKey('poster-title-text')),
    );
    expect(title.style!.fontSize, 16);
    expect(title.maxLines, 1);
  });
}
