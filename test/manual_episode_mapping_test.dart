import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:flutter/material.dart';
import 'package:ccplayer/ui/manual_episode_page.dart';
import 'package:ccplayer/l10n/app_localizations.dart';

void main() {
  testWidgets(
    'manual editor selects specials, matches file, and keeps edits local until save',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: ManualEpisodePage(
            work: const {'id': 'w'},
            assets: const [
              {'id': 'file', 'name': 'CM01.mkv'},
            ],
            searchTitles: (query) async {
              expect(query, '42');
              return [Candidate(provider: 'tmdb', id: 42, title: 'Show')];
            },
            loadTitle: (id, season) async => season == null
                ? {
                    'seasons': [
                      {'season_number': 0, 'name': 'Specials'},
                    ],
                  }
                : {
                    'episodes': [
                      {'episode_number': 2, 'name': 'Bonus episode'},
                    ],
                  },
          ),
        ),
      );
      expect(find.text('CM01.mkv'), findsNothing);
      expect(find.text('Save'), findsNothing);
      await tester.enterText(find.byType(TextField), '42');
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.text('TMDB 42 · '), findsOneWidget);
      expect(find.text('CM01.mkv'), findsNothing);
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(find.text('TMDB 42'), findsOneWidget);
      expect(find.text('CM01.mkv'), findsNothing);
      await tester.tap(find.text('0 · Specials'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CM01.mkv'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('Ep. 2 · Bonus episode'),
          matching: find.byType(SimpleDialogOption),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('0 · 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'manual specials persist on scan, progress stays, invalid batch rolls back',
    () async {
      final dir = await Directory.systemTemp.createTemp('ccplayer-map-');
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      try {
        await cat.indexVideo('s', 'Show/CM01.mkv', null, workFolder: 'Show');
        final asset = (await cat.db.query('assets')).single;
        final id = asset['id'].toString(), work = asset['work_id'].toString();
        await cat.progress(id, 12345, 50000);
        final candidate = Candidate(
          provider: 'tmdb',
          id: 42,
          title: 'Correct title',
        );
        await cat.saveEpisodeMappings(work, candidate, {
          id: (season: 0, episode: 2),
        });
        await cat.indexVideo('s', 'Show/CM01.mkv', null, workFolder: 'Show');
        await cat.reload();
        final corrected = cat.forWork(work).single;
        expect(corrected['season'], 0);
        expect(corrected['episode'], 2);
        expect(corrected['extra_type'], 'SP');
        expect(corrected['manual_mapping'], true);
        expect((await cat.db.query('progress')).single['position_ms'], 12345);
        await expectLater(
          cat.saveEpisodeMappings(work, candidate, {
            id: (season: 1, episode: 3),
            'missing': (season: 0, episode: 1),
          }),
          throwsStateError,
        );
        expect((await cat.db.query('assets')).single['episode'], 2);
        expect((await cat.db.query('asset_overrides')).single['season'], 0);
      } finally {
        await cat.db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
