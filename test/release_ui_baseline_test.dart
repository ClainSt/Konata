// Run with flutter test --dart-define=UI_BASELINE_DIR=<new directory>.
// Screenshots are rendered with the Windows system font, outside app assets.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/nipaplay_detail_page.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:ccplayer/ui/player_dialog.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:ccplayer/ui/track_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const output = String.fromEnvironment('UI_BASELINE_DIR');
  testWidgets(
    'capture representative release screens at both widths and brightnesses',
    (tester) async {
      final out = Directory(output);
      final catalog = Catalog.instance;
      final work = <String, Object?>{
        'id': 'sample',
        'title': '测试动画',
        'year': 2023,
      };
      final asset = <String, Object?>{
        'id': 'sample-01',
        'work_id': 'sample',
        'source_id': 'local',
        'name': '01.mkv',
        'relative_path': '01.mkv',
        'episode': 1,
        'category': 'main',
        'season': 1,
      };
      SharedPreferences.setMockInitialValues({});
      final root = await tester.runAsync(() async {
        if (out.existsSync()) {
          throw StateError('Choose a new capture directory.');
        }
        await out.create(recursive: true);
        final folder = await Directory.systemTemp.createTemp(
          'ccplayer-visual-',
        );
        final font = File('${Platform.environment['WINDIR']}/Fonts/msyh.ttc');
        final loader = FontLoader('Microsoft YaHei')
          ..addFont(font.readAsBytes().then((b) => ByteData.sublistView(b)));
        await loader.load();
        await catalog.initialize(dataDirectory: folder);
        await catalog.db.insert('sources', {
          'id': 'local',
          'kind': 'local',
          'label': '动画收藏',
          'location': 'Videos',
        });
        await catalog.db.insert('works', work);
        await catalog.db.insert('assets', asset);
        await catalog.reload();
        return folder;
      });
      expect(root, isNotNull);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        libraryDestination.value = false;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await catalog.db.close();
        await root!.delete(recursive: true);
      });
      tester.view.devicePixelRatio = 1;
      for (final narrow in [false, true]) {
        tester.view.physicalSize = narrow
            ? const Size(390, 844)
            : const Size(1280, 800);
        for (final brightness in Brightness.values) {
          final boundaryKey = GlobalKey();
          Future<void> page(Widget body) async {
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundaryKey,
                child: MaterialApp(
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  locale: const Locale('zh', 'CN'),
                  theme: NipaPlayStyle.theme(brightness).copyWith(
                    platform: narrow
                        ? TargetPlatform.android
                        : TargetPlatform.windows,
                  ),
                  home: Scaffold(body: body),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          Future<void> capture(String name) async {
            expect(tester.takeException(), isNull);
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final width = narrow ? 'narrow' : 'desktop';
                await File(
                  '${out.path}/$width-${brightness.name}-$name.png',
                ).writeAsBytes(
                  bytes!.buffer.asUint8List(
                    bytes.offsetInBytes,
                    bytes.lengthInBytes,
                  ),
                );
              } finally {
                image.dispose();
              }
            });
          }

          libraryDestination.value = false;
          await page(LibraryPage(mobile: narrow));
          await capture('library');
          libraryDestination.value = true;
          await tester.pumpAndSettle();
          await capture('sources');
          await page(
            SettingsPage(embedded: true, category: 0, wideLayout: !narrow),
          );
          await capture('settings');
          await page(
            NipaPlayDetailPage(
              work: work,
              assets: [asset],
              onBack: () {},
              onEditCover: () {},
              onDelete: () {},
              onEditMetadata: () {},
            ),
          );
          await capture('detail');
          await page(
            const ColoredBox(color: Colors.black, child: SizedBox.expand()),
          );
          showPlayerDialog(
            tester.element(find.byType(ColoredBox).last),
            const TrackPicker(subtitles: true, selectedId: 'no'),
          );
          await tester.pumpAndSettle();
          await capture('player-dialog');
          Navigator.of(tester.element(find.byType(TrackPicker))).pop();
          await tester.pumpAndSettle();
        }
      }
    },
    skip: output.isEmpty || !Platform.isWindows,
  );
}
