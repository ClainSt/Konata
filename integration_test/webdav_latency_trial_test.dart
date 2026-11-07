// Opt-in experiment: the frozen baseline is captured before editing the relay.
// Opt in with DAV_LATENCY_TARGET pointing to an anonymous test media URL.
// Uses an isolated temporary catalog and alternates the same player between relays.
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/debug_log.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/webdav_stream.dart' as candidate;
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/webdav_stream_baseline.dart' as baseline;
import 'webdav_trial_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Video must follow engine frame scheduling, not the polling/pump cadence.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const targetText = String.fromEnvironment('DAV_LATENCY_TARGET');
  testWidgets(
    'same WatchPage player with alternating relay implementations',
    (tester) async {
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('konata-dav-latency-');
      final target = Uri.parse(targetText);
      final before = baseline.WebDavStream(
        target: target,
        authorization: 'Basic YW5vbnltb3VzOg==',
      );
      final after = candidate.WebDavStream(
        target: target,
        authorization: 'Basic YW5vbnltb3VzOg==',
      );
      final a = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final b = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      a.listen(before.serve);
      b.listen(after.serve);
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      DebugLog.directory = Directory('${root.path}/logs');
      await DebugLog.directory!.create();
      DebugLog.enabled = true;
      try {
        final source = await catalog.addSource(
          'webdav',
          'benchmark',
          'http://127.0.0.1:${b.port}/',
        );
        final asset = <String, Object?>{
          'id': 'clip',
          'source_id': source,
          'relative_path': 'clip.mkv',
          'name': 'benchmark',
          'work_id': 'work',
          'category': 'main',
        };
        await catalog.db.insert('works', {'id': 'work', 'title': 'benchmark'});
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
              .timeout(const Duration(seconds: 30));
          await native.setProperty('sub-auto', 'no');
          await native.setProperty('sid', 'no');
          await native.setProperty('sub-visibility', 'no');
          final props = <String, String>{};
          for (final name in [
            'mpv-version',
            'hwdec-current',
            'video-params/pixelformat',
            'current-vo',
            'network-timeout',
            'demuxer-max-bytes',
          ]) {
            props[name] = await native.getProperty(name);
          }
          record('latency_config', props);
          Future<double> measure(
            List<String> command,
            double targetPosition,
          ) async {
            final clock = Stopwatch()..start();
            await native.command(command);
            double? firstPosition;
            while (clock.elapsed < const Duration(seconds: 30)) {
              final pos = double.tryParse(await native.getProperty('time-pos'));
              final seeking = await native.getProperty('seeking');
              final buffering = await native.getProperty('paused-for-cache');
              final paused = await native.getProperty('pause');
              if (pos != null &&
                  pos >= targetPosition - .15 &&
                  pos <= targetPosition + 5 &&
                  seeking == 'no' &&
                  buffering == 'no' &&
                  paused == 'no') {
                firstPosition ??= pos;
                if (pos - firstPosition >= .2) {
                  return clock.elapsedMicroseconds / 1000;
                }
              } else {
                firstPosition = null;
              }
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            throw StateError('No sustained playback within 30 seconds');
          }

          // Warm both paths and leave playback far from zero before timed loads,
          // so an old opening frame cannot satisfy the next load's position check.
          for (final port in [a.port, b.port]) {
            await measure([
              'loadfile',
              'http://127.0.0.1:$port/ticket',
              'replace',
            ], 0);
            await measure(['seek', '60', 'absolute+exact'], 60);
          }
          record('latency_scope', {'both_paths_warmed': true});
          // Equal, alternating order; initial page setup is excluded from timing.
          final results = <Map<String, Object>>[];
          for (final label in [
            'before',
            'after',
            'after',
            'before',
            'before',
            'after',
            'after',
            'before',
            'before',
            'after',
            'after',
            'before',
          ]) {
            final port = label == 'before' ? a.port : b.port;
            final opened = await measure([
              'loadfile',
              'http://127.0.0.1:$port/ticket',
              'replace',
            ], 0);
            results.add({
              'source': label,
              'kind': 'open',
              'advancing_200ms_ms': opened,
            });
            for (final position in [67.5, 1300.0, 60.0]) {
              final elapsed = await measure([
                'seek',
                position.toString(),
                'absolute+exact',
              ], position);
              results.add({
                'source': label,
                'kind': 'seek',
                'target': position,
                'advancing_200ms_ms': elapsed,
              });
            }
            record('latency_round', {
              'round': results.length ~/ 4,
              'source': label,
              'open_ms': opened,
            });
          }
          binding.reportData = {
            'platform': Platform.operatingSystem,
            'rows': results,
          };
          for (final row in results) {
            record('latency_sample', row);
          }
          for (final name in ['decoder-frame-drop-count', 'frame-drop-count']) {
            record('latency_drops', {
              'property': name,
              'value': await native.getProperty(name),
            });
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          await poll(tester, () async => native.disposed, seconds: 10);
        }
        before.close();
        after.close();
        await DebugLog.flush();
        final log = await File('${root.path}/logs/current.log').readAsString();
        record('latency_relay_counts', {
          'reused': RegExp(
            r'connectionReused=true|"event":"request_end"[^\n]*"connectionReused":true',
          ).allMatches(log).length,
          'fresh': RegExp(
            r'connectionReused=false|"event":"request_end"[^\n]*"connectionReused":false',
          ).allMatches(log).length,
        });
      } finally {
        before.close();
        after.close();
        await a.close(force: true);
        await b.close(force: true);
        await DebugLog.flush();
        DebugLog.enabled = false;
        DebugLog.directory = null;
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    skip: targetText.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
