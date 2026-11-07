import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/timeline_preview.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'webdav_trial_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const fixture = String.fromEnvironment('PREVIEW_TEST_VIDEO');
  testWidgets('three preview sessions leave primary playback usable', (
    tester,
  ) async {
    MediaKit.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('konata-preview-');
    final catalog = Catalog.instance;
    await catalog.initialize(dataDirectory: root);
    try {
      final file = File(fixture);
      final source = await catalog.addSource(
        'local',
        'fixture',
        file.parent.path,
      );
      final asset = <String, Object?>{
        'id': 'preview-clip',
        'source_id': source,
        'relative_path': file.uri.pathSegments.last,
        'name': 'Preview fixture',
        'work_id': 'preview-work',
        'category': 'main',
      };
      await catalog.db.insert('works', {
        'id': 'preview-work',
        'title': 'fixture',
      });
      await catalog.db.insert('assets', asset);
      final config = MpvConfigStore(
        rootOverride: Directory('${root.path}/mpv'),
      );
      await config.initialize();
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WatchPage(key: key, asset: asset, configurationStore: config),
        ),
      );
      final dynamic page = key.currentState;
      final player = page.player as Player;
      final native = player.platform as NativePlayer;
      try {
        await player.setVolume(0);
        await (page.controller as VideoController).waitUntilFirstFrameRendered
            .timeout(const Duration(seconds: 20));
        await player.pause();
        await tester.pump();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(const Offset(200, 200));
        await tester.pump();
        final toggle = find.widgetWithIcon(IconButton, Icons.image_outlined);
        expect(toggle, findsOneWidget);
        TimelinePreview timeline() =>
            tester.widget<TimelinePreview>(find.byType(TimelinePreview).first);
        // Show the controls before exercising the product's button callback.
        Future<void> switchPreview() async {
          await mouse.moveTo(const Offset(201, 201));
          await tester.pump();
          tester.widget<IconButton>(toggle).onPressed!();
          await tester.pump();
        }

        expect(await timeline().loadFrame(const Duration(seconds: 1)), isNull);
        await switchPreview();
        final staleRequest = timeline().loadFrame(const Duration(seconds: 1));
        // Close and reopen before the old source-resolution future completes.
        tester.widget<IconButton>(toggle).onPressed!();
        tester.widget<IconButton>(toggle).onPressed!();
        expect(await staleRequest, isNull);
        await tester.pump();
        await switchPreview();
        for (var round = 0; round < 3; round++) {
          await switchPreview();
          expect(tester.widget<IconButton>(toggle).isSelected, isTrue);
          final image = await timeline()
              .loadFrame(const Duration(seconds: 1))
              .timeout(const Duration(seconds: 10));
          expect(image, isNotNull);
          expect(image!.length, greaterThan(100));
          await switchPreview();
          expect(tester.widget<IconButton>(toggle).isSelected, isFalse);
          expect(
            await timeline().loadFrame(const Duration(seconds: 1)),
            isNull,
          );
          expect(native.disposed, isFalse);
          await player.seek(Duration.zero);
          await player.play();
          await poll(
            tester,
            () async =>
                player.state.playing &&
                player.state.position.inMilliseconds > 300,
            seconds: 5,
          );
          await player.pause();
          record('preview_session_closed', {
            'round': round + 1,
            'frame_bytes': image.length,
            'main_disposed': native.disposed,
            'main_position_ms': player.state.position.inMilliseconds,
          });
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await poll(tester, () async => native.disposed, seconds: 10);
      }
    } finally {
      await catalog.db.close();
      await root.delete(recursive: true);
    }
  }, skip: fixture.isEmpty);
}
