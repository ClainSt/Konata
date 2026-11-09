import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/local_media.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
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
}

class _Player extends Fake implements NativePlayer {
  final streams = _Streams();
  final properties = <String, String>{};
  final opened = Completer<void>();
  final closed = Completer<void>();
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
  testWidgets(
    'opened media stays usable while sibling subtitle listing fails',
    (tester) async {
      final listing = Completer<List<Object?>>();
      final listingStarted = Completer<void>();
      final native = _Player();
      final messenger = tester.binding.defaultBinaryMessenger;
      const surface = MethodChannel('ccplayer/native_video');
      messenger.setMockMethodCallHandler(surface, (call) async {
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
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WatchPage(
            key: key,
            asset: const {
              'id': 'clip',
              'source_id': 'local',
              'relative_path': 'readable.mkv',
              'name': 'Readable clip',
            },
            configurationStore: MpvConfigStore(rootOverride: root),
            createPlayer: (_) => Player(platformPlayer: native),
          ),
        ),
      );
      try {
        for (var i = 0; i < 100 && !listingStarted.isCompleted; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
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
