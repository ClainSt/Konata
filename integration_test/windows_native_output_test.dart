import 'dart:io';
import 'dart:ffi' as ffi;
import 'package:window_manager/window_manager.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:ccplayer/ui/timeline_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const path = String.fromEnvironment('CCPLAYER_NATIVE_TEST_VIDEO');
  testWidgets(
    'WatchPage drives the native D3D11 window from its playback session',
    (tester) async {
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'ccplayer-window-test-',
      );
      final db = Catalog.instance;
      const fixture = String.fromEnvironment('CCPLAYER_NATIVE_TEST_CATALOG');
      if (fixture.isNotEmpty) {
        await File(fixture).copy(p.join(root.path, 'ccplayer.db'));
      }
      await db.initialize(dataDirectory: root);
      final store = MpvConfigStore(
        rootOverride: Directory(p.join(root.path, 'mpv')),
      );
      await store.initialize();
      late final Map<String, Object?> asset;
      if (fixture.isEmpty) {
        final source = await db.addSource('local', 'test', p.dirname(path));
        asset = {
          'id': 'test',
          'name': p.basename(path),
          'relative_path': p.basename(path),
          'work_id': 'test',
          'category': 'main',
          'source_id': source,
        };
        await db.db.insert('works', {'id': 'test', 'title': 'test'});
        await db.db.insert('assets', asset);
      } else {
        asset = db.assets.singleWhere(
          (a) =>
              a['name'] == p.basename(path) &&
              db.sourceOf(a['source_id'].toString())['kind'] == 'webdav',
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WatchPage(asset: asset, configurationStore: store),
        ),
      );
      final dynamic page = tester.state(find.byType(WatchPage));
      final player = page.player as Player;
      try {
        await player.setVolume(0);
        await player.stream.position
            .firstWhere((v) => v.inSeconds >= 2)
            .timeout(const Duration(seconds: 30));
        final native = player.platform as NativePlayer;
        expect(await native.getProperty('current-vo'), 'gpu');
        expect(await native.getProperty('video-out-params/w'), isNotEmpty);
        expect(await native.getProperty('d3d11-output-format'), 'rgb10_a2');
        // Confirm MPV attached to an actual child HWND of our Flutter window.
        final hwnd = int.parse(await native.getProperty('wid'));
        final user32 = ffi.DynamicLibrary.open('user32.dll');
        final ancestor = user32
            .lookupFunction<
              ffi.IntPtr Function(ffi.IntPtr, ffi.Uint32),
              int Function(int, int)
            >('GetAncestor');
        final isVisible = user32
            .lookupFunction<ffi.Int32 Function(ffi.IntPtr), int Function(int)>(
              'IsWindowVisible',
            );
        expect(hwnd, greaterThan(0));
        expect(ancestor(hwnd, 1), greaterThan(0));
        expect(ancestor(hwnd, 2), isNot(hwnd));
        await windowManager.ensureInitialized();
        await windowManager.show();
        for (var i = 0; i < 100 && isVisible(hwnd) == 0; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(isVisible(hwnd), isNot(0));
        final kernel = ffi.DynamicLibrary.open('kernel32.dll');
        final alloc = kernel
            .lookupFunction<
              ffi.IntPtr Function(ffi.Uint32, ffi.UintPtr),
              int Function(int, int)
            >('LocalAlloc');
        final release = kernel
            .lookupFunction<ffi.IntPtr Function(ffi.IntPtr), int Function(int)>(
              'LocalFree',
            );
        final rect = ffi.Pointer<ffi.Int32>.fromAddress(alloc(0, 24));
        final cursor = rect + 4;
        final getRect = user32
            .lookupFunction<
              ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Int32>),
              int Function(int, ffi.Pointer<ffi.Int32>)
            >('GetWindowRect');
        final getCursor = user32
            .lookupFunction<
              ffi.Int32 Function(ffi.Pointer<ffi.Int32>),
              int Function(ffi.Pointer<ffi.Int32>)
            >('GetCursorPos');
        final move = user32
            .lookupFunction<
              ffi.Int32 Function(ffi.Int32, ffi.Int32),
              int Function(int, int)
            >('SetCursorPos');
        getCursor(cursor);
        try {
          await windowManager.focus();
          expect(getRect(hwnd, rect), isNot(0));
          final x = (rect[0] + rect[2]) ~/ 2;
          move(x, rect[3] - 10);
          final timeline = find.byType(TimelinePreview);
          for (var i = 0; i < 60; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            if (timeline.evaluate().isNotEmpty) break;
          }
          expect(timeline, findsOneWidget);
          if (int.parse(await native.getProperty('chapters')) > 0) {
            for (
              var i = 0;
              i < 30 &&
                  tester.widget<TimelinePreview>(timeline).chapters.isEmpty;
              i++
            ) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(
              tester.widget<TimelinePreview>(timeline).chapters,
              isNotEmpty,
            );
          }
          final height = await native.getProperty('osd-height');
          move(x, (rect[1] + rect[3]) ~/ 2);
          for (var i = 0; i < 60 && timeline.evaluate().isNotEmpty; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(timeline, findsNothing);
          expect(await native.getProperty('osd-height'), height);
          expect(int.parse(height), rect[3] - rect[1]);
        } finally {
          move(cursor[0], cursor[1]);
          release(rect.address);
        }
        final initialSize = await windowManager.getSize();
        final initialWidth = int.parse(await native.getProperty('osd-width'));
        expect(initialWidth, greaterThan(100));
        try {
          await windowManager.setSize(
            Size(initialSize.width + 96, initialSize.height),
          );
          for (var i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            if (await native.getProperty('osd-width') !=
                initialWidth.toString()) {
              break;
            }
          }
          expect(
            int.parse(await native.getProperty('osd-width')),
            isNot(initialWidth),
          );
        } finally {
          await windowManager.setSize(initialSize);
        }
        if (fixture.isNotEmpty) {
          final limit = DateTime.now().add(const Duration(seconds: 30));
          var selectedExternal = false;
          while (!selectedExternal && DateTime.now().isBefore(limit)) {
            final count =
                int.tryParse(await native.getProperty('track-list/count')) ?? 0;
            for (var i = 0; i < count; i++) {
              final key = 'track-list/$i';
              if (await native.getProperty('$key/type') == 'sub' &&
                  await native.getProperty('$key/external') == 'yes' &&
                  await native.getProperty('$key/selected') == 'yes') {
                selectedExternal = true;
                break;
              }
            }
            if (!selectedExternal) {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            }
          }
          expect(selectedExternal, true);
        }
        await player.seek(const Duration(seconds: 15));
        await player.stream.position
            .firstWhere((v) => v.inSeconds >= 15 && v.inSeconds < 20)
            .timeout(const Duration(seconds: 10));
      } finally {
        await tester.pumpWidget(const SizedBox());
        // WatchPage saves progress before asynchronously disposing its player.
        await player.stream.position.drain<void>().timeout(
          const Duration(seconds: 20),
        );
        await db.db.close();
        await root.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('CCPLAYER_NATIVE_SDR_OUTPUT') ||
        path.isEmpty,
  );
}
