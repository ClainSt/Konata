import 'dart:io';
import 'dart:ui' as ui;
import 'package:ccplayer/core/artwork_settings.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/image_cache_settings.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:ccplayer/ui/work_edit_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_ARTWORK_UI')) {
      final font = File('C:/Windows/Fonts/msyh.ttc');
      if (font.existsSync()) {
        for (final family in ['Microsoft YaHei', 'Roboto', 'Ahem']) {
          await (FontLoader(family)..addFont(
                Future.value(ByteData.sublistView(font.readAsBytesSync())),
              ))
              .load();
        }
      }
    }
  });
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final size in [
      const Size(320, 640),
      const Size(844, 390),
      const Size(768, 1024),
      const Size(1366, 900),
    ]) {
      testWidgets('cache settings and metadata scroll gutter $platform $size', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        await ArtworkSettings.instance.load();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.binding.setSurfaceSize(size);
        final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('konata-cache-ui-'),
        ))!;
        ImageStore.root = root;
        await tester.runAsync(
          () => File(
            '${root.path}/sample.png',
          ).writeAsBytes(List.filled(2048, 0)),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.binding.setSurfaceSize(null);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.runAsync(() async {
            await ImageStore.close();
            ImageStore.root = null;
            await root.delete(recursive: true);
          });
        });
        final capture = GlobalKey();
        Widget app(Widget body) => RepaintBoundary(
          key: capture,
          child: MaterialApp(
            locale: platform == TargetPlatform.windows
                ? const Locale('en')
                : const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: NipaPlayStyle.theme(
              Brightness.light,
            ).copyWith(platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(body: SingleChildScrollView(child: body)),
          ),
        );
        await tester.runAsync(
          () => tester.pumpWidget(app(const ImageCacheSettings())),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();
        expect(find.text('2.00 KiB'), findsOneWidget);
        final open = find.byKey(const ValueKey('open-image-cache'));
        final usage = find.byKey(const ValueKey('image-cache-bytes'));
        expect(
          tester.getRect(open).left,
          greaterThan(tester.getRect(usage).right),
        );
        expect(tester.getRect(open).right, closeTo(size.width - 16, 1));
        await tester.tap(find.byKey(const ValueKey('detail-backdrop-switch')));
        await tester.pumpAndSettle();
        expect(ArtworkSettings.instance.backdrop, false);
        await ArtworkSettings.instance.load();
        expect(ArtworkSettings.instance.backdrop, false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          app(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => WorkEditDialogs.metadata(context, {
                  'id': 'test',
                  'title': 'Long title 长标题',
                  'year': 2021,
                  'overview': List.filled(80, '作品简介 synopsis').join(' '),
                }, searchAndBind: () async {}),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.textContaining('302189'), findsNothing);
        final scroll = find.byKey(const ValueKey('metadata-scrollbar'));
        final fields = find.byType(TextField);
        expect(
          tester.getRect(fields.first).right,
          lessThanOrEqualTo(tester.getRect(scroll).right - 18),
        );
        final outer = tester.widget<Scrollbar>(scroll);
        expect(outer.controller!.hasClients, true);
        outer.controller!.jumpTo(outer.controller!.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const ValueKey('metadata-save'))).bottom,
          lessThanOrEqualTo(size.height),
        );
        if (size.width < 600) {
          expect(
            tester
                .getRect(find.byKey(const ValueKey('metadata-search-bind')))
                .bottom,
            lessThan(
              tester.getRect(find.byKey(const ValueKey('metadata-save'))).top,
            ),
          );
        }
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CAPTURE_ARTWORK_UI')) {
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'output/artwork-ui/metadata-${platform.name}-${size.width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }
}
