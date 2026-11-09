import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/bangumi_episode_mapping.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/bangumi_episode_mapping_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final locale in [
    const Locale('en'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ]) {
    testWidgets(
      'review/save/revoke on narrow large-text ${locale.toLanguageTag()}',
      (tester) async {
        final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('ccplayer-bgm-dialog-'),
        ))!;
        final cat = Catalog.instance;
        const key = 'tmdb:tv:42:s1:e1';
        await tester.runAsync(() async {
          await cat.initialize(dataDirectory: dir);
          await cat.db.insert('works', {
            'id': 'w',
            'title': 'Test',
            'tmdb_id': 42,
            'tmdb_type': 'tv',
          });
          await cat.db.insert('assets', {
            'id': 'a',
            'source_id': 's',
            'work_id': 'w',
            'relative_path': 'a.mkv',
            'name': 'a.mkv',
            'category': 'main',
            'season': 1,
            'episode': 1,
          });
          await cat.logicalEpisodes.confirm('a', key);
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await cat.db.close();
            await dir.delete(recursive: true);
          });
        });
        final l10n = lookupAppLocalizations(locale);
        final store = BangumiEpisodeMapping(cat.db);
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'id': 999,
              'subject_id': 100,
              'type': 0,
              'sort': 13.5,
              'name': 'different numbering',
            }),
            200,
          ),
        );
        addTearDown(client.close);
        await tester.binding.setSurfaceSize(const Size(320, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              platform: locale.languageCode == 'en'
                  ? TargetPlatform.windows
                  : TargetPlatform.android,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => BangumiEpisodeMappingDialog(
                      store: store,
                      assetId: 'a',
                      episodeKey: key,
                      title: 'Test title',
                      verifier: BangumiEpisodeVerifier(client),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        Future<void> settle() async {
          await tester.pump();
          // SQLite runs outside the fake clock. Wait for its busy indicator
          // instead of assuming the real I/O finishes within a fixed 100 ms.
          for (var i = 0; i < 200; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
            await tester.pump();
            if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
          }
          expect(find.byType(LinearProgressIndicator), findsNothing);
          await tester.pumpAndSettle();
        }

        await tester.tap(find.text('Open'));
        await settle();
        expect(
          (tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, l10n.save),
          )).onPressed,
          isNull,
        );
        await tester.enterText(
          find.byKey(const ValueKey('bgm-subject')),
          '100',
        );
        await tester.enterText(
          find.byKey(const ValueKey('bgm-episode')),
          '999',
        );
        await tester.ensureVisible(find.text(l10n.verifyBangumiEpisode));
        await tester.tap(find.text(l10n.verifyBangumiEpisode));
        await settle();
        expect(
          find.textContaining('13.5 · different numbering'),
          findsOneWidget,
        );
        expect(await tester.runAsync(() => store.current(key)), isNull);
        await tester.tap(find.widgetWithText(FilledButton, l10n.save));
        await settle();
        expect(
          (await tester.runAsync(() => store.current(key)))!['episode_id'],
          999,
        );
        await tester.tap(find.text('Open'));
        await settle();
        await tester.ensureVisible(find.text(l10n.revokeBangumiMapping));
        await tester.tap(find.text(l10n.revokeBangumiMapping));
        await settle();
        expect(await tester.runAsync(() => store.current(key)), isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
