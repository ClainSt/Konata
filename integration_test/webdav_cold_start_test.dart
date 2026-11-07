// Explicitly opted-in diagnostics on the tablet's existing WebDAV service.
// No proxy to the PC, cache clearing, settings changes, or automatic retries.
import 'dart:async';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/debug_log.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

import 'webdav_trial_support.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Video must follow engine frame scheduling, not the polling/pump cadence.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const sourceUrl = String.fromEnvironment('DAV_COLD_ROOT');
  const relative = String.fromEnvironment('DAV_COLD_FILE');
  const resumeMs = int.fromEnvironment('DAV_COLD_RESUME_MS');
  testWidgets(
    'cold app on the original tablet WebDAV chain',
    (tester) async {
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('konata-dav-cold-');
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      DebugLog.directory = Directory('${root.path}/logs');
      await DebugLog.directory!.create();
      DebugLog.enabled = true;
      final result = <String, dynamic>{
        'platform': Platform.operatingSystem,
        'scope': 'fresh app/player; upstream cache unknown and not cleared',
        'started_utc': DateTime.now().toUtc().toIso8601String(),
      };
      try {
        final sourceId = await catalog.addSource(
          'webdav',
          'cold diagnostic',
          sourceUrl,
          username: 'anonymous',
        );
        final source = catalog.sourceOf(sourceId);
        final asset = <String, Object?>{
          'id': 'clip',
          'source_id': sourceId,
          'relative_path': relative,
          'name': 'Cold diagnostic',
          'work_id': 'work',
          'category': 'main',
        };
        await catalog.db.insert('works', {'id': 'work', 'title': 'diagnostic'});
        await catalog.db.insert('assets', asset);
        if (resumeMs > 0) {
          await catalog.db.insert('progress', {
            'asset_id': 'clip',
            'position_ms': resumeMs,
            'duration_ms': 1421098,
            'completed': 0,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          });
        }
        result['requested_resume_ms'] = resumeMs;
        final config = MpvConfigStore(
          rootOverride: Directory('${root.path}/mpv'),
        );
        await config.initialize();
        final key = GlobalKey();
        final clock = Stopwatch()..start();
        // First access to video bytes is through the real product WatchPage.
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
        final errors = <Map<String, Object>>[];
        final subscription = player.stream.error.listen((error) {
          final kinds = RegExp(
            r'HTTP (?:error )?\d{3}|timed out|connection refused|failed to open',
            caseSensitive: false,
          ).allMatches(error).map((m) => m.group(0)!).toList();
          errors.add({'ms': clock.elapsedMilliseconds, 'kinds': kinds});
        });
        int? frameMs;
        var disposed = false;
        unawaited(
          (page.controller as VideoController).waitUntilFirstFrameRendered
              .then((_) {
                if (!disposed) frameMs = clock.elapsedMilliseconds;
              })
              .catchError((Object _) {}),
        );
        try {
          await player.setVolume(0);
          while (clock.elapsed < const Duration(seconds: 25)) {
            await tester.pump();
            if (frameMs != null &&
                player.state.position.inMilliseconds >= resumeMs + 6000 &&
                !player.state.buffering &&
                await native.getProperty('seeking') == 'no') {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          final props = <String, String>{};
          for (final property in [
            'network-timeout',
            'demuxer-max-bytes',
            'hwdec-current',
            'current-vo',
            'time-pos',
            'paused-for-cache',
            'decoder-frame-drop-count',
            'frame-drop-count',
          ]) {
            try {
              props[property] = await native
                  .getProperty(property)
                  .timeout(const Duration(seconds: 2));
            } catch (_) {
              props[property] = 'unavailable';
            }
          }
          result['playback'] = {
            'frame_ms': frameMs,
            'frame_signal_scope':
                'Android controller surface-size callback; not physical first frame',
            'observed_ms': clock.elapsedMilliseconds,
            'position_ms': player.state.position.inMilliseconds,
            'errors': errors,
            'properties': props,
          };
          record('cold_playback', result['playback'] as Map<String, Object?>);
        } finally {
          disposed = true;
          await subscription.cancel();
          await tester.pumpWidget(const SizedBox());
          await poll(tester, () async => native.disposed, seconds: 10);
        }

        // Only after first playback: distinguish product-generated 502 from
        // upstream errors, with the same bounded range via both HTTP paths.
        final ticket = await StreamBroker.instance.issue(source, relative);
        final dav = WebDav(await catalog.withCredentials(source));
        final probes = <Map<String, Object?>>[];
        try {
          for (final offset in [0, if (resumeMs > 0) 532364675]) {
            for (final direct in [false, true]) {
              final client = HttpClient()..autoUncompress = false;
              final watch = Stopwatch()..start();
              final row = <String, Object?>{
                'path': direct ? 'direct_device_cd2' : 'product_relay',
                'offset': offset,
              };
              try {
                final req = await client
                    .getUrl(direct ? dav.fileUri(relative) : ticket)
                    .timeout(const Duration(seconds: 20));
                row['connected_ms'] = watch.elapsedMilliseconds;
                req.followRedirects = false;
                req.headers.set('Range', 'bytes=$offset-${offset + 65535}');
                if (direct) req.headers.set('Authorization', dav.auth);
                final rsp = await req.close().timeout(
                  const Duration(seconds: 20),
                );
                row['headers_ms'] = watch.elapsedMilliseconds;
                row['status'] = rsp.statusCode;
                row['range_valid'] = RegExp(
                  '^bytes $offset-${offset + 65535}/[0-9]+\$',
                ).hasMatch(rsp.headers.value('content-range') ?? '');
                if (rsp.statusCode == 206 && row['range_valid'] == true) {
                  var bytes = 0;
                  final digest = await sha256
                      .bind(
                        rsp.timeout(const Duration(seconds: 15)).map((chunk) {
                          row['first_byte_ms'] ??= watch.elapsedMilliseconds;
                          bytes += chunk.length;
                          if (bytes > 65536) {
                            throw const HttpException('Excess range bytes');
                          }
                          return chunk;
                        }),
                      )
                      .first;
                  row['bytes'] = bytes;
                  row['sha256'] = digest.toString();
                }
              } catch (e) {
                row['error_type'] = e.runtimeType.toString();
              } finally {
                row['total_ms'] = watch.elapsedMilliseconds;
                client.close(force: true);
              }
              probes.add(row);
              record('cold_probe', row);
            }
          }
        } finally {
          StreamBroker.instance.revoke(ticket);
        }
        result['probes'] = probes;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await DebugLog.flush();
        final log = File('${root.path}/logs/current.log');
        result['relay_log'] = await log.exists()
            ? (await log.readAsLines()).map(DebugLog.redact).toList()
            : <String>[];
        for (final line in result['relay_log'] as List<String>) {
          record('cold_relay', {'line': line});
        }
        binding.reportData = result;
        result['incident_txt'] = await DebugLog.latestIncidentText();
        // A failed stream is diagnostic data, not a reason to discard the report.
        expect(probes, hasLength(resumeMs > 0 ? 4 : 2));
      } finally {
        await DebugLog.flush();
        DebugLog.enabled = false;
        DebugLog.directory = null;
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    skip: sourceUrl.isEmpty || relative.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
