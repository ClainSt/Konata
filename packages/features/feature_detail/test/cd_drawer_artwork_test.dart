import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/src/ui/supplementary_asset_cards.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

import 'support/detail_test_fixtures.dart';

void main() {
  testWidgets('无专辑独立封面时显示智能裁切作品海报而非唱片占位', (tester) async {
    const variant = MediaVariant(
      id: 'cd-test',
      workId: 'work-test',
      sourceId: 'src-test',
      relativePath: 'CD/Track.flac',
      fileName: 'Track.flac',
      fileSize: 100,
      assetKind: AssetKind.cdAlbum,
    );
    const source = MediaSource(
      id: 'src-test',
      kind: MediaSourceKind.local,
      label: '测试',
      location: 'D:/Test',
    );
    Widget card({required bool hasPoster, required bool hasAlbum}) =>
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: Center(
              child: CdDrawerCard(
                variant: variant,
                source: source,
                workId: 'work-test',
                workPosterPath: hasPoster ? '/poster-test.png' : null,
                imageLoader: createStubImageLoader(),
                coverLoader: (_, _) async => hasAlbum
                    ? await createStubImageLoader()('/album-test.png')
                    : null,
                showSeriesSharedBadge: false,
                onTap: () {},
              ),
            ),
          ),
        );
    await tester.pumpWidget(card(hasPoster: true, hasAlbum: false));
    await tester.pumpAndSettle();
    expect(find.byType(KonataCoverAlignmentBuilder), findsOneWidget);
    expect(find.byType(KonataCdDiscPlaceholder), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(card(hasPoster: false, hasAlbum: false));
    await tester.pumpAndSettle();
    expect(find.byType(KonataCdDiscPlaceholder), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(card(hasPoster: true, hasAlbum: true));
    await tester.pumpAndSettle();
    expect(find.byType(KonataCoverAlignmentBuilder), findsNothing);
    expect(find.byType(KonataCdDiscPlaceholder), findsNothing);
    expect(find.byType(Image), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
