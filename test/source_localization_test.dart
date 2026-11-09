import 'dart:io';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/app_language.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/source_browser_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ccplayer/core/scan_activity.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/add_media_dialog.dart';
import 'package:ccplayer/ui/scan_progress_dialog.dart';
import 'package:ccplayer/ui/source_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'real English add-source form rejects invalid URL after closing safely',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final oldChoice = AppLanguage.instance.choice;
      await AppLanguage.instance.setChoice(AppLanguageChoice.en);
      final oldSources = Catalog.instance.sources,
          oldWorks = Catalog.instance.works;
      Catalog.instance.sources = [];
      Catalog.instance.works = [];
      libraryDestination.value = true;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        Catalog.instance.sources = oldSources;
        Catalog.instance.works = oldWorks;
        libraryDestination.value = false;
        await AppLanguage.instance.setChoice(oldChoice);
      });
      await tester.pumpWidget(const CCPlayer(mobile: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add source'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('source-type-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WebDAV').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'not-a-url');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an HTTP or HTTPS URL.'), findsOneWidget);
      expect(Catalog.instance.sources, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'English browser preserves folder names, search and scan selection',
    (tester) async {
      final folder = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'ccplayer-browser-language-',
        );
        await Directory(
          '${root.path}/media/日本語 series',
        ).create(recursive: true);
        await Catalog.instance.initialize(
          dataDirectory: Directory('${root.path}/data'),
        );
        return root;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await Catalog.instance.db.close();
          await folder.delete(recursive: true);
        });
      });
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: SourceBrowserPage(
              source: {
                'id': 'browser-language',
                'label': 'My media',
                'kind': 'local',
                'location': '${folder.path}/media',
              },
            ),
          ),
        ),
      );
      Future<void> settleIo({bool Function()? completed}) async {
        for (var attempt = 0; attempt < 200; attempt++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
              (completed?.call() ?? true)) {
            break;
          }
        }
        await tester.pumpAndSettle();
      }

      await settleIo();
      expect(find.text('日本語 series'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '日本語');
      await tester.pumpAndSettle();
      expect(find.text('1 of 1 items'), findsOneWidget);
      final tile = find.ancestor(
        of: find.descendant(
          of: find.byKey(const ValueKey('source-folder-browser')),
          matching: find.text('日本語 series'),
        ),
        matching: find.byType(ListTile),
      );
      await tester.runAsync(
        () => tester.tap(
          find.descendant(of: tile, matching: find.byType(Checkbox)),
        ),
      );
      // Selection writes SQLite without showing a loading spinner. Await its
      // observable result rather than assuming it finishes within 25 ms.
      await settleIo(
        completed: () =>
            Catalog.instance.rootsFor('browser-language').length == 1,
      );
      expect(find.text('Scan selected (1)'), findsOneWidget);
      expect(
        Catalog.instance.rootsFor('browser-language').single['relative_path'],
        '日本語 series',
      );
      await tester.runAsync(
        () => tester.tap(
          find.descendant(of: tile, matching: find.text('日本語 series')),
        ),
      );
      await settleIo();
      expect(
        find.byKey(const ValueKey('breadcrumb-日本語 series')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('folder-breadcrumbs')), findsOneWidget);
      expect(find.text('/日本語 series/'), findsNothing);
      await tester.runAsync(
        () => tester.tap(find.byKey(const ValueKey('breadcrumb-'))),
      );
      await settleIo();
      expect(find.byKey(const ValueKey('breadcrumb-日本語 series')), findsNothing);
      await tester.runAsync(
        () => Catalog.instance.addScanRoot(
          'browser-language',
          'Animation/Another series',
        ),
      );
      await settleIo();
      final panel = find.byKey(const ValueKey('selected-folder-panel'));
      expect(
        find.descendant(of: panel, matching: find.text('Another series')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: panel,
          matching: find.text('Animation/Another series'),
        ),
        findsNothing,
      );
      expect(find.byTooltip('Animation/Another series'), findsOneWidget);
      for (final size in [
        const Size(1200, 800),
        const Size(900, 650),
        const Size(390, 780),
        const Size(640, 480),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        final browserRect = tester.getRect(
          find.byKey(const ValueKey('source-folder-browser')),
        );
        final panelRect = tester.getRect(panel);
        if (size.width >= 840) {
          expect(panelRect.left, greaterThan(browserRect.right));
          expect(panelRect.top, browserRect.top);
        } else {
          expect(panelRect.top, greaterThanOrEqualTo(browserRect.bottom));
        }
        expect(Catalog.instance.rootsFor('browser-language'), hasLength(2));
        expect(tester.takeException(), isNull);
      }
      await tester.runAsync(
        () => tester.tap(
          find.byKey(
            const ValueKey('remove-selected-Animation/Another series'),
          ),
        ),
      );
      await settleIo(
        completed: () =>
            Catalog.instance.rootsFor('browser-language').length == 1,
      );
      expect(
        Catalog.instance.rootsFor('browser-language').single['relative_path'],
        '日本語 series',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final traditional in [false, true]) {
    testWidgets(
      'source choices, editor and scan labels at phone width, hant=$traditional',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final folder = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('ccplayer-source-labels-'),
        ))!;
        addTearDown(
          () => tester.runAsync(() => folder.delete(recursive: true)),
        );
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final id = 'scan-localized-$traditional';
        final store = ScanActivityStore.instance;
        store.begin(id, ['Anime/86']);
        store.beginFolder(id, 'Anime/86/SPs');
        store.video(id, 'Anime/86/SPs');
        String? chosen;
        await tester.pumpWidget(
          MaterialApp(
            locale: traditional
                ? const Locale.fromSubtags(
                    languageCode: 'zh',
                    scriptCode: 'Hant',
                  )
                : const Locale('en'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () async {
                        chosen = await AddMediaDialog.show(context);
                      },
                      child: const Text('Add'),
                    ),
                    TextButton(
                      onPressed: () => SourceEditor.show(context, {
                        'id': id,
                        'kind': 'local',
                        'label': '日本語 title',
                        'location': folder.path,
                      }),
                      child: const Text('Edit'),
                    ),
                    TextButton(
                      onPressed: () =>
                          ScanProgressDialog.show(context, sourceId: id),
                      child: const Text('Scan'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('WebDAV'));
        await tester.tap(find.text('WebDAV'));
        await tester.pumpAndSettle();
        expect(chosen, 'webdav');
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        expect(
          find.text(traditional ? '編輯媒體來源' : 'Edit source'),
          findsOneWidget,
        );
        final name = find.byType(TextField).first;
        await tester.enterText(name, '');
        await tester.tap(
          find.widgetWithText(FilledButton, traditional ? '儲存' : 'Save'),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(traditional ? '名稱和位址不能留空' : 'Enter a name and location.'),
          findsOneWidget,
        );
        await tester.tap(find.text(traditional ? '取消' : 'Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Scan'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.text(traditional ? '掃描進度' : 'Scan progress'),
          findsOneWidget,
        );
        expect(find.textContaining('Anime/86/SPs'), findsWidgets);
        expect(find.textContaining('NaN'), findsNothing);
        expect(tester.takeException(), isNull);
        store.endFolder(id, 'Anime/86/SPs');
        store.complete(id);
        await tester.pumpAndSettle();
        expect(
          find.text(traditional ? '掃描及資料取得已完成' : 'Scan complete'),
          findsOneWidget,
        );
        await tester.tap(find.text(traditional ? '關閉' : 'Close'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
