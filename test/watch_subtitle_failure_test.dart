import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/local_media.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/player_fullscreen.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/player_dialog.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
// The fake has no native allocation or decoder.
// ignore: implementation_imports
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Streams extends PlatformPlayer {
  _Streams() : super(configuration: const PlayerConfiguration());
  void emitLog(PlayerLog event) => logController.add(event);
  void emitPosition(Duration position, Duration duration) {
    state = state.copyWith(position: position, duration: duration);
    positionController.add(position);
  }

  void emitCompleted() => completedController.add(true);
}

class _Player extends Fake implements NativePlayer {
  @override
  void Function(int)? onFileError;
  final streams = _Streams();
  final properties = <String, String>{};
  final opened = Completer<void>();
  final closed = Completer<void>();
  int pauseCalls = 0;
  @override
  Future<void> observeProperty(
    String name,
    Future<void> Function(String) listener, {
    bool waitForInitialization = true,
  }) async {}
  @override
  Future<void> unobserveProperty(
    String name, {
    bool waitForInitialization = true,
  }) async {}
  @override
  Future<void> pause({bool synchronized = true}) async {
    pauseCalls++;
    streams.state = state.copyWith(playing: false);
  }

  @override
  PlayerConfiguration get configuration => const PlayerConfiguration();
  @override
  PlayerState get state => streams.state;
  @override
  PlayerStream get stream => streams.stream;
  @override
  Pointer<mpv.mpv_handle> get ctx => Pointer.fromAddress(1);
  @override
  Future<void> setProperty(
    String key,
    String value, {
    bool waitForInitialization = true,
  }) async => properties[key] = value;
  @override
  Future<String> getProperty(
    String key, {
    bool waitForInitialization = true,
  }) async => properties[key] ?? '';
  @override
  Future<void> open(
    Playable media, {
    bool play = true,
    bool synchronized = true,
  }) async {
    streams.state = state.copyWith(playing: play);
    opened.complete();
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    await streams.dispose();
    closed.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final catalog = Catalog.instance;
  setUpAll(() async {
    // The mocked surface consumes only the library path. No mpv symbol is used;
    // use an existing system library so this regression needs no packaged DLL.
    if (Platform.isWindows) {
      NativeLibrary.ensureInitialized(libmpv: 'kernel32.dll');
    }
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('konata-subtitle-failure-');
    await catalog.initialize(dataDirectory: root);
    catalog.sources = [
      {
        'id': 'local',
        'kind': 'local',
        'location': 'content://fixture/tree/root',
      },
    ];
  });
  tearDownAll(() async {
    await catalog.db.close();
    await root.delete(recursive: true);
  });
  for (final scenario in [
    'subtitles',
    'hdr',
    'dv5',
    'dv81',
    'chapter-dialog',
    'chapter-eof',
    'chapter-direct',
    'manual-return',
  ]) {
    final hdrConflict = scenario == 'hdr';
    final chapter = scenario.startsWith('chapter-');
    final manualReturn = scenario == 'manual-return';
    final pushPlayback = chapter || manualReturn;
    final chapterEof = scenario == 'chapter-eof';
    final chapterDialog = chapter && scenario != 'chapter-direct';
    testWidgets(
      switch (scenario) {
        'dv5' =>
          'Dolby Vision Profile 5 pauses with a clear unsupported message',
        'dv81' => 'Dolby Vision Profile 8 remains playable',
        'hdr' =>
          'HDR target conflict pauses once and shows an actionable error',
        'chapter-dialog' =>
          'chapter returns its completion after dialog closes',
        'chapter-eof' =>
          'chapter returns its EOF completion after dialog closes',
        'chapter-direct' => 'chapter returns its completion without a dialog',
        'manual-return' => 'playback back hides the native surface before disposal',
        _ => 'opened media stays usable while sibling subtitle listing fails',
      },
      (tester) async {
        final listing = Completer<List<Object?>>();
        final listingStarted = Completer<void>();
        final native = _Player();
        if (scenario == 'dv5' || scenario == 'dv81') {
          native.properties.addAll({
            'track-list/count': '1',
            'track-list/0/type': 'video',
            'track-list/0/selected': 'yes',
            'track-list/0/dolby-vision-profile': scenario == 'dv5' ? '5' : '8',
          });
        }
        final messenger = tester.binding.defaultBinaryMessenger;
        const surface = MethodChannel('ccplayer/native_video');
        final surfaceCalls = <String>[];
        messenger.setMockMethodCallHandler(surface, (call) async {
          surfaceCalls.add(call.method);
          if (call.method == 'hide' && !native.closed.isCompleted) {
            surfaceCalls.add('hide-before-dispose');
          }
          if (call.method == 'create') return 1;
          if (call.method == 'pointerAtControls') return false;
          return null;
        });
        messenger.setMockMethodCallHandler(LocalMedia.channel, (call) async {
          if (call.method == 'resolve') return '${root.path}/readable.mkv';
          if (call.method == 'list') {
            listingStarted.complete();
            return listing.future;
          }
          return null;
        });
        final key = GlobalKey();
        final navigatorKey = GlobalKey<NavigatorState>();
        final watch = WatchPage(
          key: key,
          asset: const {
            'id': 'clip',
            'source_id': 'local',
            'relative_path': 'readable.mkv',
            'name': 'Readable clip',
          },
          configurationStore: MpvConfigStore(rootOverride: root),
          createPlayer: (_) => Player(platformPlayer: native),
          chapterEndMs: chapter && !chapterEof ? 1000 : null,
          returnOnCompletion: chapter,
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: pushPlayback ? const Scaffold() : watch,
          ),
        );
        bool? chapterResult;
        if (pushPlayback) {
          unawaited(
            navigatorKey.currentState!
                .push<bool>(MaterialPageRoute(builder: (_) => watch))
                .then((result) => chapterResult = result),
          );
        }
        try {
          for (var i = 0; i < 100 && !listingStarted.isCompleted; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          if (manualReturn) {
            expect(native.opened.isCompleted, isTrue);
            surfaceCalls.clear();
            playingHeader.value!.onBack();
            await tester.pump();
            expect(surfaceCalls, contains('hide-before-dispose'));
            expect(navigatorKey.currentState!.canPop(), isFalse);
            return;
          }
          if (scenario == 'dv5') {
            final dynamic page = key.currentState;
            expect(page.error, 'dv-profile-5');
            expect(native.pauseCalls, 1);
            expect(native.state.playing, isFalse);
            expect(
              find.textContaining('Dolby Vision Profile 5 is not supported'),
              findsOneWidget,
            );
            expect(listingStarted.isCompleted, isFalse);
            expect(tester.takeException(), isNull);
            return;
          }
          expect(listingStarted.isCompleted, isTrue);
          final dynamic page = key.currentState;
          expect(native.opened.isCompleted, isTrue);
          expect(native.state.playing, isTrue);
          expect(
            page.loading,
            isFalse,
            reason: 'Directory enumeration must not gate controls',
          );
          expect(page.error, isNull);
          if (pushPlayback) {
            if (chapterDialog) {
              unawaited(
                showPlayerDialog(
                  key.currentContext!,
                  const Text('Track picker'),
                ),
              );
              await tester.pumpAndSettle();
            }
            final position = chapterEof ? 2000 : 1000;
            native.streams.emitPosition(
              Duration(milliseconds: position),
              const Duration(seconds: 2),
            );
            if (chapterEof) native.streams.emitCompleted();
            await tester.pump();
            expect(native.pauseCalls, 1);
            if (chapterDialog) {
              final saved = await tester.runAsync(() async {
                for (var i = 0; i < 100; i++) {
                  final rows = await catalog.db.query(
                    'progress',
                    columns: ['position_ms'],
                    where: 'asset_id = ?',
                    whereArgs: ['clip'],
                  );
                  if (rows.singleOrNull?['position_ms'] == position) {
                    return true;
                  }
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                }
                return false;
              });
              await tester.pump();
              expect(saved, isTrue);
              expect(find.text('Track picker'), findsOneWidget);
              expect(chapterResult, isNull);
              navigatorKey.currentState!.pop();
            }
            for (var i = 0; i < 100 && chapterResult == null; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(chapterResult, isTrue);
            expect(native.pauseCalls, 1);
            expect(tester.takeException(), isNull);
            return;
          }
          if (hdrConflict) {
            native.streams.emitLog(
              const PlayerLog(
                prefix: 'vo/gpu/opengl',
                level: 'warn',
                text: 'HDR EGL surface unavailable; returning to SDR',
              ),
            );
            await tester.pump();
            expect(page.error, isNull);
            expect(native.pauseCalls, 0);
            for (var i = 0; i < 2; i++) {
              native.streams.emitLog(
                PlayerLog(
                  prefix: 'vo/gpu/opengl',
                  level: 'error',
                  text:
                      'Explicit HDR target is incompatible with this output${i == 0 ? '\n' : ''}',
                ),
              );
              await tester.pump();
            }
            expect(page.error, 'hdr-target');
            expect(native.pauseCalls, 1);
            expect(native.state.playing, isFalse);
            expect(
              find.text(
                'The HDR target in your MPV configuration is incompatible with the current video output. Change the target settings or disable the custom configuration, then reopen the video.',
              ),
              findsOneWidget,
            );
            listing.complete([]);
            await tester.pump();
            expect(page.error, 'hdr-target');
            expect(tester.takeException(), isNull);
            return;
          }
          listing.completeError(PlatformException(code: 'directory_denied'));
          await tester.pump();
          await tester.pump();
          expect(
            page.error,
            isNull,
            reason: 'Optional subtitle failure must not hide opened media',
          );
          expect(native.state.playing, isTrue);
          expect(find.byType(Slider), findsWidgets);
          expect(tester.takeException(), isNull);
        } finally {
          if (!listing.isCompleted) listing.complete([]);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          if (chapter) {
            for (var i = 0; i < 100 && !native.closed.isCompleted; i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump();
            }
          }
          await tester.runAsync(
            () => native.closed.future.timeout(const Duration(seconds: 10)),
          );
          messenger.setMockMethodCallHandler(surface, null);
          messenger.setMockMethodCallHandler(LocalMedia.channel, null);
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
