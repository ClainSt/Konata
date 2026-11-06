import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/sources.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'webdav_trial_support.dart';
import 'webdav_sdr_probe.dart';
import 'webdav_network_probe.dart';
import 'paced_dav.dart';

Future<void> showStage(WidgetTester tester, String message) =>
    tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xff151515),
          child: Center(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
        ),
      ),
    );

Stream<List<int>> progressStream(
  WidgetTester tester,
  Stream<List<int>> stream,
  String stage,
  int total,
) async* {
  var received = 0;
  final clock = Stopwatch()..start();
  await showStage(tester, stage);
  await for (final chunk in stream) {
    received += chunk.length;
    if (clock.elapsedMilliseconds >= 1000) {
      final progress = total > 0
          ? '${(received * 100 / total).toStringAsFixed(1)}%'
          : '${received ~/ 1048576} MiB';
      await showStage(tester, '$stage  $progress');
      clock.reset();
    }
    yield chunk;
  }
}

Future<void> verifyRepeatRanges(HttpClient client, Uri uri, File local) async {
  final length = await local.length();
  const span = 65536;
  final reader = await local.open();
  try {
    for (final start in [0, length ~/ 2, length - span]) {
      final req = await client.getUrl(uri);
      req.headers.set('Range', 'bytes=$start-${start + span - 1}');
      final response = await req.close().timeout(const Duration(seconds: 45));
      expect(response.statusCode, 206);
      expect(
        response.headers.value('Content-Range'),
        'bytes $start-${start + span - 1}/$length',
      );
      final actual = await sha256
          .bind(response.timeout(const Duration(seconds: 45)))
          .first;
      await reader.setPosition(start);
      expect(actual, sha256.convert(await reader.read(span)));
    }
  } finally {
    await reader.close();
  }
}

Future<void> runArm(
  WidgetTester tester,
  String arm,
  Map<String, Object?> asset,
  MpvConfigStore config,
) async {
  final key = GlobalKey();
  final clock = Stopwatch()..start();
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
  final controller = page.controller as VideoController;
  final errors = <String>[];
  final err = player.stream.error.listen((_) => errors.add('player error'));
  try {
    await player.setVolume(0);
    int? frameMs;
    unawaited(
      controller.waitUntilFirstFrameRendered.then((_) {
        frameMs = clock.elapsedMilliseconds;
      }),
    );
    await poll(tester, () async => frameMs != null, seconds: 120);
    record('first_frame', {'arm': arm, 'ms': frameMs});
    await poll(tester, () async => page.loading == false, seconds: 120);
    await poll(
      tester,
      () async => (page.addedSubtitles as List<SubtitleTrack>).any(
        (t) => t.title?.endsWith('.sc.ass') ?? false,
      ),
    );
    final added = page.addedSubtitles as List<SubtitleTrack>;
    final sc = added.firstWhere((t) => t.title!.endsWith('.sc.ass'));
    final selected = player.state.track.subtitle;
    if (selected.id != sc.id) await player.setSubtitleTrack(sc);
    const switchUnix = int.fromEnvironment('DAV_SWITCH_UNIX');
    const stopUnix = int.fromEnvironment('DAV_STOP_UNIX');
    if (stopUnix > 0) {
      final first = Platform.isWindows ? arm == 'local' : arm == 'webdav';
      final end = DateTime.fromMillisecondsSinceEpoch(
        (first ? switchUnix : stopUnix) * 1000,
      );
      final startPos = player.state.position.inMilliseconds;
      final interval = Stopwatch()..start();
      var stalls = 0, milliseconds = 0, vo = 0, dec = 0;
      int? since;
      final buffering = player.stream.buffering.distinct().listen((value) {
        if (value && since == null) {
          since = interval.elapsedMilliseconds;
          stalls++;
        }
        if (!value && since != null) {
          milliseconds += interval.elapsedMilliseconds - since!;
          since = null;
        }
      });
      try {
        record('from_head', {
          'arm': arm,
          'ready_ms': clock.elapsedMilliseconds,
          'pos_ms': startPos,
          'pause_wait': await native.getProperty('cache-pause-wait'),
        });
        int last = 0;
        while (DateTime.now().isBefore(
          end.subtract(const Duration(seconds: 9)),
        )) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          vo = int.tryParse(await native.getProperty('frame-drop-count')) ?? vo;
          dec =
              int.tryParse(
                await native.getProperty('decoder-frame-drop-count'),
              ) ??
              dec;
          if (interval.elapsed.inSeconds >= last + 15) {
            last = interval.elapsed.inSeconds;
            record('head_sample', {
              'arm': arm,
              'wall_ms': interval.elapsedMilliseconds,
              'pos_ms': player.state.position.inMilliseconds,
              'buffer_s': await native.getProperty('demuxer-cache-duration'),
              'stalls': stalls,
              'vo': vo,
              'dec': dec,
            });
          }
        }
        if (since != null) {
          milliseconds += interval.elapsedMilliseconds - since!;
        }
        record('head_end', {
          'arm': arm,
          'wall_ms': interval.elapsedMilliseconds,
          'pos_ms': player.state.position.inMilliseconds,
          'buffer_events': stalls,
          'buffer_ms': milliseconds,
          'vo': vo,
          'decoder': dec,
          'errors': errors.length,
        });
      } finally {
        await buffering.cancel();
      }
      if (DateTime.now().isBefore(end.subtract(const Duration(seconds: 5)))) {
        await player.pause();
        final seek = Stopwatch()..start();
        await native.command(['seek', '7.216', 'absolute+exact']);
        await poll(
          tester,
          () async =>
              ((double.tryParse(await native.getProperty('time-pos')) ?? 0) -
                          7.216)
                      .abs() <
                  0.04 &&
              await native.getProperty('seeking') == 'no',
          seconds: 5,
        );
        final seekMs = seek.elapsedMilliseconds;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final video = await player.screenshot(format: null);
        final ass = await player.screenshot(
          format: null,
          includeLibassSubtitles: true,
        );
        if (video != null && ass != null) {
          record('head_frame', {
            'arm': arm,
            'seek_ms': seekMs,
            'pts': await native.getProperty('time-pos'),
            'video': sha256.convert(video).toString(),
            'ass': sha256.convert(ass).toString(),
            'sub_text': (await native.getProperty('sub-text')).isNotEmpty,
          });
        }
      }
      return;
    }
    for (final target in [124, 717, 22, 1300]) {
      final timer = Stopwatch()..start();
      await player.seek(Duration(seconds: target));
      double? first;
      await poll(tester, () async {
        final pos = double.tryParse(await native.getProperty('time-pos'));
        if (pos == null || pos < target - 0.07 || pos > target + 5) {
          return false;
        }
        first ??= pos;
        return pos - first! >= 0.035 &&
            await native.getProperty('seeking') == 'no' &&
            await native.getProperty('paused-for-cache') != 'yes';
      });
      record('seek', {
        'arm': arm,
        'target': target,
        'ms': timer.elapsedMilliseconds,
      });
    }
    await player.pause();
    for (final target in [7.2, 123.957]) {
      await native.command(['seek', '$target', 'absolute+exact']);
      await poll(tester, () async {
        final pos = double.tryParse(await native.getProperty('time-pos'));
        return pos != null &&
            (pos - target).abs() < 0.05 &&
            await native.getProperty('seeking') == 'no';
      });
      await Future<void>.delayed(const Duration(milliseconds: 220));
      final video = await player.screenshot(format: null);
      final sub = await player.screenshot(
        format: null,
        includeLibassSubtitles: true,
      );
      expect(video, isNotNull);
      expect(sub, isNotNull);
      record('frame', {
        'arm': arm,
        'pts': await native.getProperty('time-pos'),
        'video': sha256.convert(video!).toString(),
        'ass': sha256.convert(sub!).toString(),
        'sub_text': (await native.getProperty('sub-text')).isNotEmpty,
        'sid': await native.getProperty('sid'),
        'hwdec': await native.getProperty('hwdec-current'),
        'format': await native.getProperty('video-params/pixelformat'),
      });
    }
    await player.seek(Duration.zero);
    await poll(
      tester,
      () async =>
          (double.tryParse(await native.getProperty('time-pos')) ?? 99) < 0.2 &&
          await native.getProperty('seeking') == 'no',
    );
    final duration = player.state.duration.inMilliseconds;
    expect(duration, greaterThan(20 * 60 * 1000));
    final timer = Stopwatch()..start();
    int? since;
    var stalls = 0, stallMs = 0, cacheSamples = 0, nextReport = 60;
    final subscription = player.stream.buffering.distinct().listen((v) {
      if (v && since == null) {
        since = timer.elapsedMilliseconds;
        stalls++;
      }
      if (!v && since != null) {
        stallMs += timer.elapsedMilliseconds - since!;
        since = null;
      }
    });
    int maxVo = 0, maxDec = 0;
    try {
      await player.play();
      record('start_episode', {'arm': arm, 'duration_ms': duration});
      while (!player.state.completed) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final vo =
            int.tryParse(await native.getProperty('frame-drop-count')) ?? 0;
        final dec =
            int.tryParse(
              await native.getProperty('decoder-frame-drop-count'),
            ) ??
            0;
        if (vo > maxVo) maxVo = vo;
        if (dec > maxDec) maxDec = dec;
        if (await native.getProperty('paused-for-cache') == 'yes') {
          cacheSamples++;
        }
        if (timer.elapsed.inSeconds >= nextReport) {
          record('minute', {
            'arm': arm,
            'elapsed': timer.elapsed.inSeconds,
            'pos_ms': player.state.position.inMilliseconds,
            'stalls': stalls,
            'vo': maxVo,
            'decoder': maxDec,
          });
          nextReport += 60;
        }
        if (timer.elapsed.inMinutes > 33) {
          throw TimeoutException('episode did not finish');
        }
      }
      if (since != null) stallMs += timer.elapsedMilliseconds - since!;
      record('eof', {
        'arm': arm,
        'elapsed_ms': timer.elapsedMilliseconds,
        'duration_ms': duration,
        'cache_pause_samples': cacheSamples,
        'buffer_events': stalls,
        'buffer_ms': stallMs,
        'vo_drops': maxVo,
        'decoder_drops': maxDec,
        'errors': errors.length,
      });
    } finally {
      await subscription.cancel();
    }
  } finally {
    await err.cancel();
    await tester.pumpWidget(const SizedBox());
    await poll(tester, () async => native.disposed, seconds: 20);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const token = String.fromEnvironment('DAV_USB_TOKEN');
  const remoteOnly = bool.fromEnvironment('DAV_WINDOWS_REMOTE_ONLY');
  const localOnly = bool.fromEnvironment('DAV_WINDOWS_LOCAL_ONLY');
  const tuning = bool.fromEnvironment('DAV_CACHE_TRIALS');
  const sdr = bool.fromEnvironment('DAV_SDR');
  const corrected = bool.fromEnvironment('DAV_ANDROID_RETEST');
  const originalDigest = String.fromEnvironment('DAV_VERIFIED_VIDEO_SHA256');
  const name = String.fromEnvironment('DAV_EPISODE_NAME');
  testWidgets(
    'local and direct WebDAV full episode',
    (tester) async {
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'ccplayer-dav-round3-',
      );
      final catalog = Catalog.instance;
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      Future<HttpClientRequest> bridge(String method, String route) async {
        final req = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:18879/$route'),
        );
        req.headers.set('Authorization', 'Bearer $token');
        return req;
      }

      String? temporarySource;
      await catalog.initialize(dataDirectory: root);
      try {
        late Map<String, Object?> source;
        late String relative;
        late String folder;
        if (Platform.isWindows) {
          await windowManager.ensureInitialized();
          await windowManager.show();
          final live = await databaseFactoryFfi.openDatabase(
            p.join(
              Platform.environment['APPDATA']!,
              'com.clainst',
              'Konata',
              'ccplayer.db',
            ),
            options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
          );
          try {
            source = (await live.rawQuery(
              'SELECT s.*,a.relative_path AS asset_path FROM sources s JOIN assets a ON s.id=a.source_id WHERE s.kind=? AND a.name=?',
              ['webdav', name],
            )).single;
          } finally {
            await live.close();
          }
          relative = source['asset_path'] as String;
          folder = const String.fromEnvironment('DAV_LOCAL_DIR');
          if (!remoteOnly && !localOnly) {
            final auth = await catalog.withCredentials(source);
            final transfer = await bridge('POST', 'handoff');
            transfer.headers.contentType = ContentType.json;
            final payload = utf8.encode(
              jsonEncode({
                'location': source['location'],
                'username': source['username'],
                'password': auth['password'],
                'relative': relative,
              }),
            );
            transfer.contentLength = payload.length;
            transfer.add(payload);
            final receipt = await transfer.close();
            expect(receipt.statusCode, 204);
            await receipt.drain<void>();
          }
          if (tuning || corrected || const bool.fromEnvironment('DAV_SDR_GRADIENTS')) return;
          source = Map.of(source)..remove('asset_path');
          await catalog.db.insert('sources', source);
        } else {
          await showStage(tester, '等待 USB 测试配置');
          Map<String, dynamic>? auth;
          await poll(tester, () async {
            final response = await (await bridge('GET', 'handoff')).close();
            if (response.statusCode == 204) {
              await response.drain<void>();
              await Future<void>.delayed(const Duration(seconds: 1));
              return false;
            }
            expect(response.statusCode, 200);
            auth =
                jsonDecode(await response.transform(utf8.decoder).join())
                    as Map<String, dynamic>;
            return true;
          }, seconds: 180);
          relative = auth!['relative'] as String;
          temporarySource = await catalog.addSource(
            'webdav',
            'isolated',
            auth!['location'] as String,
            username: auth!['username'] as String,
            password: auth!['password'] as String,
          );
          source = catalog.sourceOf(temporarySource);
          auth = null;
          folder = root.path;
          for (final route
              in (sdr || tuning || corrected)
                  ? <String>[]
                  : ['video', 'sc', 'tc']) {
            final filename = route == 'video'
                ? name
                : '${p.basenameWithoutExtension(name)}.$route.ass';
            final local = File(p.join(folder, filename));
            final resp = await (await bridge('GET', route)).close();
            expect(resp.statusCode, 200);
            await progressStream(
              tester,
              resp,
              '正在暂存本地对照文件',
              resp.contentLength,
            ).pipe(local.openWrite());
            final remote = await StreamBroker.instance.issue(
              source,
              p.posix.join(p.posix.dirname(relative), filename),
            );
            try {
              if (route == 'video' && originalDigest.isNotEmpty) {
                final digest = await sha256
                    .bind(
                      progressStream(
                        tester,
                        local.openRead(),
                        '正在复核已暂存原片',
                        await local.length(),
                      ),
                    )
                    .first;
                expect(digest.toString(), originalDigest);
                await verifyRepeatRanges(client, remote, local);
                record('repeat_byte_check', {
                  'type': route,
                  'local_sha256': digest.toString(),
                  'remote_ranges': 3,
                  'range_size': 65536,
                  'bytes': await local.length(),
                });
                continue;
              }
              final body = await (await client.getUrl(remote)).close();
              expect(body.statusCode, 200);
              final digest = await sha256
                  .bind(
                    progressStream(
                      tester,
                      body.timeout(const Duration(seconds: 45)),
                      '正在校验 WebDAV 原片',
                      await local.length(),
                    ),
                  )
                  .first;
              expect(
                digest,
                await sha256
                    .bind(
                      progressStream(
                        tester,
                        local.openRead(),
                        '正在校验本地对照片',
                        await local.length(),
                      ),
                    )
                    .first,
              );
              record('byte_proof', {
                'type': route,
                'bytes': await local.length(),
                'sha256': digest.toString(),
              });
            } finally {
              StreamBroker.instance.revoke(remote);
            }
          }
        }
        final localId = await catalog.addSource('local', 'local', folder);
        await catalog.db.insert('works', {'id': 'round3', 'title': 'round3'});
        final configDir = Directory(p.join(root.path, 'mpv'));
        final config = const bool.fromEnvironment('DAV_FONT_PROBE')
            ? FontProbeConfig(rootOverride: configDir)
            : MpvConfigStore(rootOverride: configDir);
        await config.initialize();
        if (Platform.isWindows && const bool.fromEnvironment('DAV_FONT_PROFILE')) {
          await config.saveConfig('mpv.conf', await MpvConfigStore.instance.readConfig('mpv.conf'));
          await config.setConfigEnabled(true);
        }
        for (final arm
            in Platform.isWindows ? ['local', 'webdav'] : ['webdav', 'local']) {
          if ((sdr || remoteOnly || tuning || corrected) && arm == 'local') {
            continue;
          }
          if (localOnly && arm == 'webdav') continue;
          final asset = <String, Object?>{
            'id': 'round3-$arm',
            'name': name,
            'relative_path': arm == 'local' ? name : relative,
            'work_id': 'round3',
            'category': 'main',
            'source_id': arm == 'local' ? localId : source['id'],
          };
          await catalog.db.insert('assets', asset);
          if (arm == 'webdav' &&
              Platform.isWindows &&
              !sdr &&
              !remoteOnly &&
              const int.fromEnvironment('DAV_STOP_UNIX') == 0) {
            // Keep the two devices from competing for the same remote throughput.
            await poll(tester, () async {
              final r = await (await bridge('GET', 'android-done')).close();
              await r.drain<void>();
              if (r.statusCode == 200) return true;
              await Future<void>.delayed(const Duration(seconds: 2));
              return false;
            }, seconds: 1800);
          }
          if (sdr) {
            if (Platform.isAndroid && !const bool.fromEnvironment('DAV_SDR_GRADIENTS')) {
              await showStage(tester, '等待 Windows 完成同源对照');
              await poll(tester, () async {
                final r = await (await bridge('GET', 'android-done')).close();
                await r.drain<void>();
                if (r.statusCode == 200) return true;
                await Future<void>.delayed(const Duration(seconds: 1));
                return false;
              }, seconds: 300);
            }
            await verifySdr(tester, asset, config);
            if (Platform.isWindows && !remoteOnly) {
              await (await (await bridge(
                'POST',
                'android-done',
              )).close()).drain<void>();
            }
            return;
          }
          if (tuning) {
            const cap = int.fromEnvironment('DAV_CAP_BYTES_PER_SECOND');
            final facade = cap > 0
                ? await PacedDav.open(source, relative, cap)
                : null;
            String? facadeSource;
            try {
              if (facade != null) {
                facadeSource = await catalog.addSource(
                  'webdav',
                  'paced trial',
                  facade.location,
                );
                asset['source_id'] = facadeSource;
                asset['relative_path'] = name;
                record('paced_dav', {'payload_cap_bytes_s': cap});
              }
              await networkPlaybackTrials(tester, asset, config, () async {
                final r = await (await bridge('GET', 'weak-band')).close();
                await r.drain<void>();
                return r.statusCode == 200;
              });
            } finally {
              await facade?.close();
              if (facadeSource != null) {
                await catalog.removeSource(facadeSource);
              }
            }
            return;
          }
          await runArm(tester, arm, asset, config);
          if (arm == 'webdav' && Platform.isAndroid) {
            await (await (await bridge(
              'POST',
              'android-done',
            )).close()).drain<void>();
          }
        }
      } finally {
        client.close(force: true);
        if (temporarySource != null) {
          await catalog.removeSource(temporarySource);
        }
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    skip:
        name.isEmpty ||
        (token.length < 32 &&
            !(Platform.isWindows && (remoteOnly || localOnly))),
    timeout: const Timeout(Duration(minutes: 83)),
  );
}
