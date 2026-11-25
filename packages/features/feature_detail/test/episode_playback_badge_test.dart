import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'support/detail_test_fixtures.dart';

void main() {
  testWidgets('选集卡右上播放状态与底边进度在三种状态正确显示', (tester) async {
    for (final complete in [null, false, true]) {
      final record = complete == null
          ? null
          : PlaybackRecord(
              id: 'r',
              workId: 'w',
              episodeId: 'e',
              variantId: 'v',
              seasonNumber: 1,
              episodeNumber: 1,
              episodeTitle: 'Test',
              sourceType: MediaSourceKind.local,
              playedAt: DateTime.utc(2026),
              positionSeconds: complete ? 24 : 5,
              durationSeconds: 24,
              isCompleted: complete,
            );
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Center(
            child: EpisodeDrawerCard(
              episode: const Episode(
                id: 'e',
                workId: 'w',
                seasonNumber: 1,
                episodeNumber: 1,
                category: EpisodeCategory.main,
                title: 'Test',
              ),
              variants: const [],
              playback: record,
              imageLoader: createStubImageLoader(),
              onTap: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final badge = find.byKey(const ValueKey('episode_playback_badge'));
      final progress = find.byKey(const ValueKey('episode_playback_progress'));
      if (complete == null) {
        expect(badge, findsNothing);
        expect(progress, findsNothing);
      } else {
        expect(find.text(complete ? '已看' : '00:05'), findsOneWidget);
        expect(
          tester.getCenter(badge).dx,
          greaterThan(tester.getCenter(find.byType(EpisodeDrawerCard)).dx),
        );
        expect(progress, findsOneWidget);
        expect(tester.getSize(progress).height, 3);
        final fill = find.descendant(
          of: progress,
          matching: find.byType(FractionallySizedBox),
        );
        expect(
          tester.widget<FractionallySizedBox>(fill).widthFactor,
          closeTo(complete ? 1 : 5 / 24, 0.001),
        );
        expect(
          tester
              .getSize(
                find.descendant(of: fill, matching: find.byType(DecoratedBox)),
              )
              .height,
          3,
        );
      }
      expect(tester.takeException(), isNull);
    }
  });
}
