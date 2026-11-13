import 'dart:async';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'WebDAV failure can retry and buffered playback advances',
    (tester) async {
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      if (Platform.isWindows) {
        await windowManager.ensureInitialized();
        await windowManager.show();
      }
      final root = await Directory.systemTemp.createTemp(
        'konata-network-retry-',
      );
      final catalog = Catalog.instance;
      final fixtureClient = HttpClient();
      final clip = File('${root.path}/clip.mkv');
      final response = await (await fixtureClient.getUrl(
        Uri.parse('http://127.0.0.1:18770/sdr.mkv'),
      )).close();
      expect(response.statusCode, 200);
      await response.pipe(clip.openWrite());
      fixtureClient.close();
      final size = await clip.length();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const midplay = bool.fromEnvironment('NETWORK_MIDPLAY');
      const skipStall = bool.fromEnvironment('NETWORK_SKIP_STALL');
      const cutAt = 6 * 1024 * 1024;
      const dropAt = 11 * 1024 * 1024;
      var unavailable = !midplay;
      var failures = 0;
      final held = Completer<void>();
      final release = Completer<void>();
      final beforeDrop = Completer<void>();
      final drop = Completer<void>();
      if (midplay && skipStall) release.complete();
      var inject = midplay;
      server.listen((request) async {
        final out = request.response;
        try {
          if (request.method != 'GET' && request.method != 'HEAD') {
            out.statusCode = HttpStatus.methodNotAllowed;
          } else if (unavailable) {
            failures++;
            out.statusCode = HttpStatus.serviceUnavailable;
          } else {
            final range = request.headers.value('range');
            final match = range == null
                ? null
                : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
            final start = match == null ? 0 : int.parse(match[1]!);
            final end = match == null || match[2]!.isEmpty
                ? size - 1
                : int.parse(match[2]!).clamp(start, size - 1);
            out.headers.set('accept-ranges', 'bytes');
            out.contentLength = end - start + 1;
            if (match != null) {
              out.statusCode = 206;
              out.headers.set('content-range', 'bytes $start-$end/$size');
            }
            if (request.method == 'GET') {
              if (inject && start < cutAt && end >= dropAt) {
                final socket = await out.detachSocket();
                try {
                  await socket.addStream(clip.openRead(start, cutAt));
                  if (!held.isCompleted) held.complete();
                  await release.future;
                  await socket.addStream(clip.openRead(cutAt, dropAt));
                  if (!beforeDrop.isCompleted) beforeDrop.complete();
                  await drop.future;
                } finally {
                  socket.destroy();
                }
                return;
              }
              if (!midplay) {
                if (!held.isCompleted) held.complete();
                await release.future;
              }
              await out.addStream(clip.openRead(start, end + 1));
            }
          }
          await out.close();
        } on IOException {
          // libmpv cancels superseded byte ranges.
        }
      });
      await catalog.initialize(dataDirectory: root);
      final source = await catalog.addSource(
        'webdav',
        'fault injection',
        'http://127.0.0.1:${server.port}/',
      );
      final asset = <String, Object?>{
        'id': 'clip',
        'work_id': 'clip',
        'source_id': source,
        'name': 'Network clip',
        'relative_path': 'clip.mkv',
        'category': 'main',
      };
      await catalog.db.insert('works', {'id': 'clip', 'title': 'Network clip'});
      await catalog.db.insert('assets', asset);
      final store = MpvConfigStore(rootOverride: Directory('${root.path}/mpv'));
      await store.initialize();
      Future<void> until(
        bool Function() condition,
        String phase, {
        int seconds = 20,
      }) async {
        final clock = Stopwatch()..start();
        while (!condition() && clock.elapsed.inSeconds < seconds) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(condition(), isTrue, reason: phase);
      }

      Player? player;
      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WatchPage(asset: asset, configurationStore: store),
          ),
        );
        final dynamic page = tester.state(find.byType(WatchPage));
        player = page.player as Player;
        final active = player;
        await active.setVolume(0);
        if (midplay) {
          final retry = find.text('Retry');
          await until(
            () =>
                held.isCompleted && active.state.position.inMilliseconds > 800,
            'playing before the source stalls',
          );
          if (!skipStall) {
            debugPrint(
              'MIDPLAY_BEFORE_STALL ms=${active.state.position.inMilliseconds}',
            );
            await until(
              () => active.state.buffering,
              'media cache drains while source stalls',
            );
            final stalledAt = active.state.position;
            expect(page.error, isNull);
            release.complete();
            await until(
              () =>
                  !active.state.buffering &&
                  active.state.position >
                      stalledAt + const Duration(milliseconds: 300),
              'source resumes and playback advances without Retry',
            );
            debugPrint(
              'MIDPLAY_BUFFER_RECOVERED ms=${active.state.position.inMilliseconds}',
            );
          }
          await until(
            () => beforeDrop.isCompleted,
            'second section is in flight',
          );
          final beforeFailure = active.state.position;
          unavailable = true;
          drop.complete();
          debugPrint('MIDPLAY_SOCKET_CUT ms=${beforeFailure.inMilliseconds}');
          try {
            await until(
              () => retry.evaluate().isNotEmpty,
              'truncated transfer exposes Retry',
            );
          } finally {
            final native = active.platform as NativePlayer;
            debugPrint(
              'MIDPLAY_AFTER_CUT position=${active.state.position.inMilliseconds} '
              'duration=${active.state.duration.inMilliseconds} completed=${active.state.completed} '
              'idle=${await native.getProperty('idle-active')} eof=${await native.getProperty('eof-reached')} '
              'failures=$failures error=${page.error}',
            );
          }
          unavailable = false;
          inject = false;
          final endedAt = active.state.position;
          final failedUri = active.state.playlist.medias.single.uri;
          await tester.tap(retry);
          await until(
            () =>
                active.state.playlist.medias.length == 1 &&
                active.state.playlist.medias.single.uri != failedUri &&
                !active.state.buffering &&
                active.state.position >
                    endedAt + const Duration(milliseconds: 200),
            'Retry resumes near the interruption instead of restarting',
          );
          expect(active.state.playlist.medias.single.start, endedAt);
          expect(
            active.state.position - endedAt,
            lessThan(const Duration(seconds: 3)),
          );
          expect(page.error, isNull);
          expect(identical(page.player, active), isTrue);
          expect(
            await (active.platform as NativePlayer).getProperty(
              'video-params/primaries',
            ),
            'bt.709',
          );
          debugPrint(
            'MIDPLAY_RETRY_PASSED ms=${active.state.position.inMilliseconds}',
          );
          await active.seek(
            active.state.duration - const Duration(milliseconds: 700),
          );
          await until(() => active.state.completed, 'normal end after retry');
          await tester.pump();
          expect(retry, findsNothing);
          expect(page.error, isNull);
          debugPrint('MIDPLAY_CLEAN_EOF');
          return;
        }
        await until(() => failures > 0, '503 returned by source');
        debugPrint('NETWORK_RETRY_SOURCE_503');
        final retry = find.text('Retry');
        await until(
          () => retry.evaluate().isNotEmpty,
          'terminal open failure shows Retry',
          seconds: 8,
        );
        unavailable = false;
        debugPrint('NETWORK_RETRY_TAP');
        await tester.tap(retry);
        await until(
          () => held.isCompleted && active.state.buffering,
          'delayed response puts player in buffering',
        );
        expect(page.error, isNull);
        debugPrint('NETWORK_RETRY_BUFFERING');
        release.complete();
        await until(
          () =>
              active.state.position.inMilliseconds > 800 &&
              !active.state.buffering,
          'buffer recovers and playback advances',
        );
        final native = active.platform as NativePlayer;
        expect(await native.getProperty('video-params/primaries'), 'bt.709');
        expect(identical(page.player, active), isTrue);
        expect(page.error, isNull);
        debugPrint(
          'NETWORK_RETRY_PASSED failures=$failures positionMs=${active.state.position.inMilliseconds}',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        if (!drop.isCompleted) drop.complete();
        await tester.pumpWidget(const SizedBox());
        if (player != null) {
          await player.stream.position.drain<void>().timeout(
            const Duration(seconds: 20),
          );
        }
        await server.close(force: true);
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
