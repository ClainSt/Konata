import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/ui/poster_title.dart';

void main() {
  testWidgets('mixed language poster labels share a baseline and left edge', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 180,
                child: PosterTitle(title: '16bit的感动 ANOTHER LAYER'),
              ),
              SizedBox(width: 180, child: PosterTitle(title: '86 -不存在的战区-')),
              SizedBox(width: 180, child: PosterTitle(title: '古树旋律 剧场版')),
            ],
          ),
        ),
      ),
    );
    final labels = find.byKey(const ValueKey('poster-title-text'));
    final baselines = <double>[];
    for (var i = 0; i < 3; i++) {
      final text = labels.at(i);
      final label = tester.widget<Text>(text);
      final painter = TextPainter(
        text: TextSpan(text: label.data, style: label.style),
        textDirection: label.textDirection!,
        strutStyle: label.strutStyle,
        textHeightBehavior: label.textHeightBehavior,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 180);
      baselines.add(
        tester.getTopLeft(text).dy +
            painter.computeLineMetrics().single.baseline,
      );
      painter.dispose();
      expect(tester.getTopLeft(text).dx, closeTo(i * 180, .1));
      expect(tester.getSize(text).height, closeTo(24, .1));
    }
    expect(baselines[1], closeTo(baselines[0], .1));
    expect(baselines[2], closeTo(baselines[0], .1));
  });
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
