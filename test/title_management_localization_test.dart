import 'dart:io';
import 'dart:ui' as ui;
import 'package:ccplayer/core/app_language.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/poster_crop_page.dart';
import 'package:ccplayer/ui/work_edit_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('English hidden-title restore keeps saved progress', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final previous = AppLanguage.instance.choice;
    await AppLanguage.instance.setChoice(AppLanguageChoice.en);
    final dir = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp(
        'ccplayer-hidden-language-',
      );
      final cat = Catalog.instance;
      await cat.initialize(dataDirectory: dir);
      await cat.db.insert('works', {
        'id': 'hidden',
        'title': '日本語 title',
        'hidden': 1,
        'keep_hidden': 1,
      });
      await cat.progress('saved-file', 12345, 50000);
      await cat.reload();
      return dir;
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Catalog.instance.db.close();
        await dir.delete(recursive: true);
      });
      await AppLanguage.instance.setChoice(previous);
      libraryDestination.value = false;
    });
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    libraryDestination.value = false;
    await tester.pumpWidget(const CCPlayer(mobile: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hidden titles'));
    await tester.pumpAndSettle();
    expect(find.text('日本語 title'), findsOneWidget);
    expect(find.text('Keep hidden after rescans'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('Restore')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('No hidden titles'), findsOneWidget);
    expect(Catalog.instance.works.single['id'], 'hidden');
    expect(
      await tester.runAsync(
        () => Catalog.instance.resumePosition('saved-file'),
      ),
      12345,
    );
    expect(tester.takeException(), isNull);
  });
  for (final traditional in [false, true]) {
    final locale = traditional
        ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
        : const Locale('en');
    testWidgets(
      'metadata validates, cancels and hands off search, hant=$traditional',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final work = <String, Object?>{
          'id': 'edit',
          'title': '日本語 title',
          'year': 2023,
          'overview': 'Original synopsis',
        };
        var searched = false;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
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
                builder: (context) => TextButton(
                  onPressed: () => WorkEditDialogs.metadata(
                    context,
                    work,
                    searchAndBind: () async {
                      searched = true;
                    },
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final field = find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.labelText ==
                  (traditional ? '關聯 Bangumi ID' : 'Bangumi IDs'),
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, '-1');
        await tester.tap(find.byKey(const ValueKey('metadata-save')));
        await tester.pumpAndSettle();
        expect(
          find.text(
            traditional ? '請輸入有效的 Bangumi ID' : 'Enter valid Bangumi IDs.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text(traditional ? '取消' : 'Cancel'));
        await tester.pumpAndSettle();
        expect(work['title'], '日本語 title');
        expect(work['year'], 2023);
        expect(work['bangumi_id'], isNull);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('metadata-search-bind')));
        await tester.pumpAndSettle();
        expect(searched, true);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'crop copy is localized and cancel returns no image, hant=$traditional',
      (tester) async {
        final bytes = (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(200, 300);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          return data!.buffer.asUint8List();
        }))!;
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var returned = false;
        Map<String, Object>? output;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
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
                builder: (context) => TextButton(
                  onPressed: () async {
                    output = await Navigator.of(context)
                        .push<Map<String, Object>>(
                          MaterialPageRoute(
                            builder: (_) => PosterCropPage(bytes: bytes),
                          ),
                        );
                    returned = true;
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() => tester.tap(find.text('Open')));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(traditional ? '裁剪封面 · 2:3' : 'Crop poster · 2:3'),
          findsOneWidget,
        );
        expect(
          find.text(
            traditional
                ? '原圖解析度較低，將保留原有清晰度'
                : 'Low-resolution image. No upscaling.',
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.widgetWithText(TextButton, traditional ? '取消' : 'Cancel'),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(returned, true);
        expect(output, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
