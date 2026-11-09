import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/app_header.dart';
import 'package:ccplayer/ui/horizontal_rail.dart';
import 'package:ccplayer/ui/library_source_filter.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final works = <Map<String, Object?>>[
    {'id': 'a', 'title': 'Alpha'},
    {'id': 'b', 'title': 'Beta'},
    {'id': 'c', 'title': 'Gamma'},
  ];
  final sources = <Map<String, Object?>>[
    {'id': 'l', 'kind': 'local'},
    {'id': 'w', 'kind': 'webdav'},
    {'id': 's', 'kind': 'smb'},
  ];
  final assets = <Map<String, Object?>>[
    {'work_id': 'a', 'source_id': 'l'},
    {'work_id': 'a', 'source_id': 'w'},
    {'work_id': 'b', 'source_id': 'w'},
    {'work_id': 'c', 'source_id': 's'},
  ];
  test('source union deduplicates works and intersects search', () {
    List<String> ids(Set<String> kinds, [String query = '']) =>
        filterLibraryWorks(
          works: works,
          sources: sources,
          assets: assets,
          kinds: kinds,
          query: query,
        ).map((w) => w['id'] as String).toList();
    expect(ids({'local'}), ['a']);
    expect(ids({'local', 'webdav'}), ['a', 'b']);
    expect(ids({'webdav', 'smb'}), ['a', 'b', 'c']);
    expect(ids({'webdav'}, ' BETA '), ['b']);
    expect(ids({}), isEmpty);
  });

  test('navigation responds to usable space, including split windows', () {
    expect(
      navigationLayout(const Size(1280, 800), desktop: true),
      KonataNavigationLayout.top,
    );
    expect(
      navigationLayout(const Size(1024, 768), desktop: false),
      KonataNavigationLayout.rail,
    );
    expect(
      navigationLayout(const Size(768, 1024), desktop: false),
      KonataNavigationLayout.bottom,
    );
    expect(
      navigationLayout(const Size(850, 390), desktop: false),
      KonataNavigationLayout.bottom,
    );
    expect(
      navigationLayout(const Size(600, 900), desktop: false),
      KonataNavigationLayout.bottom,
    );
  });

  testWidgets(
    'library filter and search update count, no overflowing toolbar',
    (tester) async {
      final cat = Catalog.instance;
      final old = (cat.works, cat.sources, cat.assets);
      cat.works = works;
      cat.sources = sources;
      cat.assets = assets;
      libraryDestination.value = false;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        cat.works = old.$1;
        cat.sources = old.$2;
        cat.assets = old.$3;
        await tester.binding.setSurfaceSize(null);
      });
      for (final brightness in Brightness.values) {
        for (final locale in [const Locale('zh'), const Locale('en')]) {
          for (final size in [
            const Size(320, 640),
            const Size(390, 844),
            const Size(850, 390),
            const Size(768, 1024),
            const Size(1024, 768),
            const Size(1596, 804),
          ]) {
            await tester.binding.setSurfaceSize(size);
            await tester.pumpWidget(
              MaterialApp(
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: NipaPlayStyle.theme(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.3)),
                  child: child!,
                ),
                home: const LibraryPage(),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$size $locale $brightness',
            );
          }
        }
      }
      await tester.tap(find.byKey(const ValueKey('library-source-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-filter-all')).first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('source-filter-webdav')).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-filter-local')).first);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'Beta',
      );
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    },
  );

  testWidgets(
    'horizontal rail supports mouse and keyboard without accidental play',
    (tester) async {
      var plays = 0;
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: HorizontalRail(
                  controller: controller,
                  itemCount: 8,
                  itemWidth: 260,
                  itemBuilder: (_, i) =>
                      InkWell(onTap: () => plays++, child: Text('Episode $i')),
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        const Offset(300, 50),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-190, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(plays, 0);
      final railFocus = find
          .descendant(
            of: find.byType(HorizontalRail),
            matching: find.byType(Focus),
          )
          .first;
      Focus.of(
        tester.element(
          find
              .descendant(
                of: railFocus,
                matching: find.byType(ScrollConfiguration),
              )
              .first,
        ),
      ).requestFocus();
      final before = controller.offset;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(before));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
