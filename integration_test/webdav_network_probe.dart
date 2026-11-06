import 'dart:async';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/sources.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'webdav_trial_support.dart';

Future<void> compareTransport(
  Map<String, Object?> source,
  String relative,
) async {
  final endpoint = WebDav(await Catalog.instance.withCredentials(source));
  final ticket = await StreamBroker.instance.issue(source, relative);
  try {
    // Match byte ranges in opposite orders, without following an authenticated redirect.
    for (final offset in [32 << 20, 512 << 20]) {
      String? reference;
      for (final direct
          in offset == (32 << 20) ? [true, false] : [false, true]) {
        final client = HttpClient()
          ..autoUncompress = false
          ..connectionTimeout = const Duration(seconds: 15);
        try {
          final timer = Stopwatch()..start();
          final req = await client.getUrl(
            direct ? endpoint.fileUri(relative) : ticket,
          );
          req.followRedirects = false;
          req.headers.set('Accept-Encoding', 'identity');
          const size = 8 << 20;
          req.headers.set('Range', 'bytes=$offset-${offset + size - 1}');
          if (direct && endpoint.username.isNotEmpty) {
            req.headers.set('Authorization', endpoint.auth);
          }
          final rsp = await req.close().timeout(const Duration(seconds: 30));
          final headerMs = timer.elapsedMilliseconds;
          if (rsp.statusCode != 206) {
            record('range_unavailable', {
              'direct': direct,
              'status': rsp.statusCode,
            });
            continue;
          }
          int bytes = 0, chunks = 0;
          final digest = await sha256
              .bind(
                rsp.timeout(const Duration(seconds: 40)).map((c) {
                  bytes += c.length;
                  chunks++;
                  return c;
                }),
              )
              .first;
          expect(bytes, size);
          reference ??= digest.toString();
          expect(digest.toString(), reference);
          record('range_speed', {
            'direct': direct,
            'offset': offset,
            'bytes': bytes,
            'chunks': chunks,
            'head_ms': headerMs,
            'total_ms': timer.elapsedMilliseconds,
          });
        } finally {
          client.close(force: true);
        }
      }
    }
  } finally {
    StreamBroker.instance.revoke(ticket);
  }
}

Future<void> networkPlaybackTrials(
  WidgetTester tester,
  Map<String, Object?> asset,
  MpvConfigStore config,
  Future<bool> Function() onWeakBand,
) async {
  if (const bool.fromEnvironment('DAV_LATENCY')) {
    for (final start in [0, 717000, 0]) {
      final cat = Catalog.instance;
      await cat.db.delete(
        'progress',
        where: 'asset_id=?',
        whereArgs: [asset['id']],
      );
      if (start > 0) {
        await cat.db.insert('progress', {
          'asset_id': asset['id'],
          'position_ms': start,
          'duration_ms': 1421098,
          'completed': 0,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
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
      final n = player.platform as NativePlayer;
      try {
        await player.setVolume(0);
        int? frame;
        unawaited(
          (page.controller as VideoController).waitUntilFirstFrameRendered.then(
            (_) {
              frame = clock.elapsedMilliseconds;
            },
          ),
        );
        await poll(
          tester,
          () async =>
              !page.loading &&
              frame != null &&
              player.state.position.inMilliseconds >= start + 40,
          seconds: 60,
        );
        record('open_latency', {
          'resume': start,
          'ms': clock.elapsedMilliseconds,
          'frame_ms': frame,
          'position': player.state.position.inMilliseconds,
          'seek_framedrop': await n.getProperty('hr-seek-framedrop'),
        });
        for (final target in [124, 717, 22, 1300, 7]) {
          final timer = Stopwatch()..start();
          await player.seek(Duration(seconds: target));
          double? first;
          await poll(tester, () async {
            final pos = double.tryParse(await n.getProperty('time-pos'));
            if (pos == null || pos < target - 0.08 || pos > target + 4) {
              return false;
            }
            first ??= pos;
            return pos - first! >= 0.035 &&
                await n.getProperty('seeking') == 'no' &&
                await n.getProperty('paused-for-cache') != 'yes';
          });
          record('seek_latency', {
            'resume': start,
            'target': target,
            'ms': timer.elapsedMilliseconds,
          });
        }
        await poll(
          tester,
          () async => (await n.getProperty('sub-text')).isNotEmpty,
          seconds: 12,
        );
        await player.pause();
        await n.command(['seek', '7.216', 'absolute+exact']);
        await poll(
          tester,
          () async =>
              ((double.tryParse(await n.getProperty('time-pos')) ?? 0) - 7.216)
                      .abs() <
                  0.01 &&
              await n.getProperty('seeking') == 'no',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final clean = await player.screenshot(format: null);
        final styled = await player.screenshot(
          format: null,
          includeLibassSubtitles: true,
        );
        expect(clean, isNotNull);
        expect(styled, isNotNull);
        record('picture_parity', {
          'resume': start,
          'pts': await n.getProperty('time-pos'),
          'video': sha256.convert(clean!).toString(),
          'ass': sha256.convert(styled!).toString(),
          'hwdec': await n.getProperty('hwdec-current'),
          'format': await n.getProperty('video-params/pixelformat'),
        });
        if (start == 717000) {
          final bars = find.byType(MaterialSeekBar);
          final video = tester.getRect(find.byType(Video).first);
          if (bars.evaluate().isEmpty) {
            await tester.tapAt(
              Offset(video.left + video.width * .3, video.center.dy),
            );
          }
          await poll(
            tester,
            () async => bars.evaluate().isNotEmpty,
            seconds: 8,
          );
          final listener = find
              .descendant(
                of: bars.last,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Listener &&
                      w.onPointerUp != null &&
                      w.onPointerMove != null,
                ),
              )
              .first;
          await tester.pump(const Duration(milliseconds: 350));
          final rect = tester.getRect(listener);
          Offset at(double x) =>
              Offset(rect.left + rect.width * x, rect.center.dy);
          final gesture = await tester.startGesture(at(0.1));
          for (final x in [0.2, 0.3, 0.4, 0.5, 0.6]) {
            await gesture.moveTo(at(x));
            await tester.pump();
          }
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final held = double.parse(await n.getProperty('time-pos'));
          await gesture.up();
          await tester.pump();
          expect(held, closeTo(7.216, 0.05));
          final target = player.state.duration.inMilliseconds * 0.6 / 1000;
          await poll(
            tester,
            () async =>
                ((double.tryParse(await n.getProperty('time-pos')) ?? 0) -
                            target)
                        .abs() <
                    2 &&
                await n.getProperty('seeking') == 'no',
          );
          record('drag_release', {
            'held': held,
            'target': target,
            'landed': await n.getProperty('time-pos'),
          });
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await poll(tester, () async => n.disposed);
      }
    }
    return;
  }
  const cutoff = int.fromEnvironment('DAV_STOP_UNIX');
  final deadline = cutoff > 0
      ? DateTime.fromMillisecondsSinceEpoch(cutoff * 1000)
      : DateTime.now().add(const Duration(minutes: 9));
  final profile = File('${(await config.directory).path}/mpv.conf');
  if (const bool.fromEnvironment('DAV_SUB_CHECK')) {
    for (final mode in ['default', 'custom', 'custom_family']) {
      var extra = '';
      if (mode == 'custom_family') extra = 'sub-font=Noto Sans CJK TC\n';
      await profile.writeAsString(
        'scale=bilinear\ndscale=bilinear\ndither=no\ncache-pause-wait=1\n$extra',
      );
      await config.setConfigEnabled(mode != 'default');
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
      await player.setVolume(0);
      try {
        await poll(
          tester,
          () async =>
              page.loading == false &&
              player.state.position.inMilliseconds > 100,
          seconds: 45,
        );
        await player.pause();
        await native.command(['seek', '7.216', 'absolute+exact']);
        await poll(
          tester,
          () async =>
              ((double.tryParse(await native.getProperty('time-pos')) ?? 0) -
                          7.216)
                      .abs() <
                  0.01 &&
              await native.getProperty('seeking') == 'no',
        );
        await Future<void>.delayed(const Duration(milliseconds: 650));
        final sid = await native.getProperty('sid');
        final count =
            int.tryParse(await native.getProperty('track-list/count')) ?? 0;
        var isSc = false;
        for (var i = 0; i < count; i++) {
          final k = 'track-list/$i';
          if (await native.getProperty('$k/type') == 'sub' &&
              await native.getProperty('$k/id') == sid) {
            isSc = (await native.getProperty('$k/title')).endsWith('.sc.ass');
          }
        }
        final clean = await player.screenshot(format: null);
        final styled = await player.screenshot(
          format: null,
          includeLibassSubtitles: true,
        );
        expect(
          isSc,
          isTrue,
          reason: 'The automatic track must be simplified Chinese.',
        );
        expect((await native.getProperty('sub-text')).isNotEmpty, isTrue);
        expect(clean, isNotNull);
        expect(styled, isNotNull);
        final plainHash = sha256.convert(clean!).toString();
        final styledHash = sha256.convert(styled!).toString();
        expect(
          styledHash,
          isNot(plainHash),
          reason: 'Selected ASS produced no rendered pixels.',
        );
        final font = await native.getProperty('sub-font');
        expect(
          font,
          mode == 'custom_family' ? 'Noto Sans CJK TC' : 'Noto Sans CJK SC',
        );
        record('sub_check', {
          'mode': mode,
          'sid': sid,
          'sc': isSc,
          'pts': await native.getProperty('time-pos'),
          'text': true,
          'overlay': true,
          'font': font,
          'plain_sha256': plainHash,
          'ass_sha256': styledHash,
        });
        await Future<void>.delayed(const Duration(seconds: 4));
      } finally {
        await tester.pumpWidget(const SizedBox());
        await poll(tester, () async => native.disposed);
      }
    }
    return;
  }
  for (final entry in [1, 15, 15, 1].asMap().entries) {
    final label = entry.key + 1;
    final wait = entry.value;
    while (!await onWeakBand() && DateTime.now().isBefore(deadline)) {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('等待 2.4 GHz Wi-Fi'))),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (deadline.difference(DateTime.now()).inSeconds < 85) break;
    await Catalog.instance.db.delete(
      'progress',
      where: 'asset_id=?',
      whereArgs: [asset['id']],
    );
    // Both arms use the same bundled rendering defaults. The only variable is the recovery threshold.
    await profile.writeAsString(
      'scale=bilinear\ndscale=bilinear\ndither=no\ncache-pause-wait=$wait\n',
    );
    await config.setConfigEnabled(true);
    final clock = Stopwatch()..start();
    record('weak_open', {
      'run': label,
      'wait': wait,
      'unix_ms': DateTime.now().millisecondsSinceEpoch,
    });
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
    var buffering = false, events = 0, total = 0, since = 0, firstMs = -1;
    final spans = <Map<String, int>>[];
    final sub = player.stream.buffering.distinct().listen((v) {
      if (v == buffering) return;
      buffering = v;
      if (firstMs < 0) return;
      if (v) {
        events++;
        since = clock.elapsedMilliseconds;
      } else {
        final duration = clock.elapsedMilliseconds - since;
        spans.add({
          "start_ms": since,
          "duration_ms": duration,
          "pos_ms": player.state.position.inMilliseconds,
        });
        total += duration;
      }
    });
    try {
      final controller = page.controller as VideoController;
      await player.setVolume(0);
      await controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 45),
      );
      firstMs = clock.elapsedMilliseconds;
      if (buffering) {
        events++;
        since = firstMs;
      }
      final effective = await native.getProperty('cache-pause-wait');
      expect(double.tryParse(effective), wait.toDouble());
      record('weak_start', {
        'run': label,
        'wait': wait,
        'first_ms': firstMs,
        'pos': player.state.position.inMilliseconds,
        'initial': await native.getProperty('cache-pause-initial'),
        'capacity': await native.getProperty('demuxer-max-bytes'),
      });
      var last = 0, valid = true, checkedAss = false;
      while (player.state.position.inMilliseconds < 75000 &&
          DateTime.now().isBefore(
            deadline.subtract(const Duration(seconds: 4)),
          )) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!checkedAss &&
            player.state.position.inMilliseconds >= 6700 &&
            player.state.position.inMilliseconds < 8200) {
          final sid = await native.getProperty('sid');
          final count =
              int.tryParse(await native.getProperty('track-list/count')) ?? 0;
          var sc = false;
          for (var i = 0; i < count; i++) {
            if (await native.getProperty('track-list/$i/type') == 'sub' &&
                await native.getProperty('track-list/$i/id') == sid) {
              sc = (await native.getProperty(
                'track-list/$i/title',
              )).endsWith('.sc.ass');
            }
          }
          checkedAss = sc && (await native.getProperty('sub-text')).isNotEmpty;
          if (checkedAss) {
            record('auto_ass', {
              'run': label,
              'sc': sc,
              'sid': sid,
              'visible': await native.getProperty('sub-visibility'),
              'font': await native.getProperty('sub-font'),
            });
          }
        }
        if (clock.elapsed.inSeconds >= last + 10) {
          last = clock.elapsed.inSeconds;
          valid = await onWeakBand() && valid;
          record('weak_sample', {
            'run': label,
            'wait': wait,
            'wall_ms': clock.elapsedMilliseconds,
            'pos': player.state.position.inMilliseconds,
            'stalls': events,
            'buffer_ms':
                total + (buffering ? clock.elapsedMilliseconds - since : 0),
            'cache_secs': await native.getProperty('demuxer-cache-duration'),
            'paused_for_cache': await native.getProperty('paused-for-cache'),
            'band_valid': valid,
          });
        }
      }
      if (buffering) {
        final duration = clock.elapsedMilliseconds - since;
        spans.add({
          'start_ms': since,
          'duration_ms': duration,
          'pos_ms': player.state.position.inMilliseconds,
        });
        total += duration;
      }
      record('weak_end', {
        'run': label,
        'wait': wait,
        'first_ms': firstMs,
        'wall_ms': clock.elapsedMilliseconds,
        'pos': player.state.position.inMilliseconds,
        'stalls': events,
        'buffer_ms': total,
        'buffer_spans': spans,
        'band_valid': await onWeakBand() && valid,
        'unix_ms': DateTime.now().millisecondsSinceEpoch,
        'vo': await native.getProperty('frame-drop-count'),
        'decoder': await native.getProperty('decoder-frame-drop-count'),
      });
      if (label == 1) {
        await player.pause();
        await native.command(['seek', '7.216', 'absolute+exact']);
        await poll(
          tester,
          () async =>
              ((double.tryParse(await native.getProperty('time-pos')) ?? 0) -
                          7.216)
                      .abs() <
                  0.01 &&
              await native.getProperty('seeking') == 'no',
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final plain = await player.screenshot(format: null);
        final styled = await player.screenshot(
          format: null,
          includeLibassSubtitles: true,
        );
        expect(plain, isNotNull);
        expect(styled, isNotNull);
        final clean = sha256.convert(plain!).toString(),
            ass = sha256.convert(styled!).toString();
        expect(ass, isNot(clean));
        expect(checkedAss, isTrue);
        record('rendered_auto_ass', {
          'pts': await native.getProperty('time-pos'),
          'plain': clean,
          'ass': ass,
        });
      }
    } finally {
      await sub.cancel();
      await tester.pumpWidget(const SizedBox());
      await poll(tester, () async => native.disposed, seconds: 10);
    }
  }
}
