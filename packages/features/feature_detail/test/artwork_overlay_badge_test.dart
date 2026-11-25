import 'package:feature_detail/src/ui/video_frame_candidates_grid.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

void main() {
  testWidgets('图片来源、语言及分辨率角标文字居中', (tester) async {
    const labels = [
      'Bangumi',
      'TMDB · S1',
      'Fanart.tv',
      '简中',
      '繁中',
      '日文',
      '无字',
      '已选',
      'HD',
      '1000×1500',
    ];
    for (final label in labels) {
      for (final scale in [1.0, 1.15]) {
        final badge = label == 'HD' || label == '1000×1500'
            ? ArtworkOverlayMiniBadge.resolution(label)
            : ArtworkOverlayMiniBadge(
                text: label,
                backgroundColor: const Color(0xff263040),
                textGradient: label.startsWith('TMDB')
                    ? KonataTheme.tmdbBrandGradient
                    : null,
                borderColor: const Color(0xff748090),
              );
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Center(child: badge),
            ),
          ),
        );
        final bounds = tester.getRect(find.byType(ArtworkOverlayMiniBadge));
        final text = tester.getRect(find.text(label));
        expect(text.center.dx, closeTo(bounds.center.dx, 0.01), reason: label);
        expect(text.center.dy, closeTo(bounds.center.dy, 0.01), reason: label);
        expect(
          tester.widget<Text>(find.text(label)).textAlign,
          TextAlign.center,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
}
