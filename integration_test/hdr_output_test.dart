import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/playback_probe.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:ccplayer/ui/track_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'native HDR and affected output transitions',
    (tester) async {
      const tag = String.fromEnvironment('HDR_TAG');
      const hlgOnly = bool.fromEnvironment('HDR_HLG_ONLY');
      const formatOnly = bool.fromEnvironment('HDR_METADATA_ONLY');
      final formatNames = const String.fromEnvironment(
        'HDR_FORMAT_CASES',
        defaultValue: 'hdr10plus,dv84,dv7',
      ).split(',');
      expect(tag, isNotEmpty);
      const endpoint = 'http://127.0.0.1:18770';
      const expectedHdr = bool.fromEnvironment(
        'EXPECT_HDR',
        defaultValue: true,
      );
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('konata-hdr-');
      final catalog = Catalog.instance;
      final client = HttpClient();
      await catalog.initialize(dataDirectory: root);
      Future<void> wait(int ms) async {
        final clock = Stopwatch()..start();
        while (clock.elapsedMilliseconds < ms) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }

      Future<void> save(String name, List<int> bytes) async {
        final request = await client.postUrl(Uri.parse('$endpoint/$tag-$name'));
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        expect(response.statusCode, 201);
        await response.drain<void>();
      }

      if (Platform.isWindows) {
        await windowManager.ensureInitialized();
        await windowManager.show();
      }
      try {
        for (final name
            in formatOnly
                ? formatNames
                : hlgOnly
                ? ['hlg']
                : ['pq', 'sdr']) {
          final response = await (await client.getUrl(
            Uri.parse('$endpoint/$name.mkv'),
          )).close();
          expect(response.statusCode, 200);
          await response.pipe(File('${root.path}/$name.mkv').openWrite());
        }
        final source = await catalog.addSource('local', 'HDR', root.path);
        final asset = <String, Object?>{
          'id': 'hdr',
          'work_id': 'hdr',
          'name': 'HDR',
          'relative_path': formatOnly
              ? '${formatNames.first}.mkv'
              : hlgOnly
              ? 'hlg.mkv'
              : 'pq.mkv',
          'source_id': source,
          'category': 'main',
        };
        await catalog.db.insert('works', {'id': 'hdr', 'title': 'HDR'});
        await catalog.db.insert('assets', asset);
        final store = MpvConfigStore(
          rootOverride: Directory('${root.path}/mpv'),
        );
        await store.initialize();
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: WatchPage(asset: asset, configurationStore: store),
          ),
        );
        final dynamic page = tester.state(find.byType(WatchPage));
        Player? created;
        for (var i = 0; i < 200 && created == null; i++) {
          await wait(20);
          try {
            created = page.player as Player;
          } on Error {
            /* initialization */
          }
        }
        final player = created!;
        final native = player.platform as NativePlayer;
        await player.setVolume(0);
        final logs = <String>[];
        final subscription = player.stream.log.listen((event) {
          if (logs.length == 150) logs.removeAt(0);
          logs.add(event.toString());
        });
        Future<void> checkpoint(
          String name,
          bool hdr, {
          bool pixels = false,
          bool waitForProgress = true,
        }) async {
          for (var i = 0; waitForProgress && i < 200; i++) {
            await wait(100);
            if (player.state.position.inMilliseconds > 300 &&
                (await native.getProperty(
                          Platform.isWindows
                              ? 'target-trc'
                              : 'video-target-params/gamma',
                        ) ==
                        'pq') ==
                    hdr) {
              break;
            }
          }
          await player.pause();
          await wait(300);
          final fields = <String, String>{};
          for (final key
              in 'video-params video-out-params vf video-dec-params video-target-params hwdec-current current-vo time-pos video-pts osd-width osd-height target-prim target-trc target-peak scale cscale dscale dither dither-depth correct-downscaling linear-downscaling sigmoid-upscaling hdr-compute-peak deband interpolation tone-mapping frame-drop-count decoder-frame-drop-count fbo-format gpu-shader-cache-dir vo-passes'
                  .split(' ')) {
            fields[key] = await native.getProperty(key);
          }
          final target = fields['video-target-params']!.isEmpty
              ? <String, Object?>{}
              : jsonDecode(fields['video-target-params']!) as Map;
          final decoded = jsonDecode(fields['video-dec-params']!) as Map;
          final capture = Map<Object?, Object?>.from(
            await page.capturePresentedBuffer(pixels: pixels) as Map,
          );
          final bytes = capture.remove('pixels') as Uint8List?;
          await save(
            '$name.json',
            utf8.encode(
              jsonEncode({'mpv': fields, 'surface': capture, 'logs': logs}),
            ),
          );
          debugPrint('HDR_CHECKPOINT $tag $name ${jsonEncode(target)}');
          if (Platform.isWindows) {
            // libmpv render API does not export VO target parameters.
            expect(capture['outputColorSpace'], hdr ? 'bt.2020/pq' : 'sdr');
          } else {
            expect(target['gamma'] == 'pq', hdr);
          }
          if (hdr) {
            expect(
              Platform.isWindows ? fields['target-prim'] : target['primaries'],
              'bt.2020',
            );
            expect(
              PlaybackProbe.componentDepth(decoded['pixelformat'] as String?) ??
                  PlaybackProbe.componentDepth(
                    decoded['hw-pixelformat'] as String?,
                  ),
              greaterThanOrEqualTo(10),
            );
          }
          if (pixels && bytes != null) {
            await save('$name.raw', bytes);
            if (formatOnly) return;
            await native.setProperty('screenshot-high-bit-depth', 'yes');
            // mpv's screenshot FBO has no display color space. Mirror the
            // already-presented target for this diagnostic capture only.
            if (hdr) {
              await native.setProperty('target-prim', 'bt.2020');
              await native.setProperty('target-trc', 'pq');
              await native.setProperty(
                'target-peak',
                Platform.isWindows
                    ? fields['target-peak']!
                    : '${(target['max-luma'] as num).round()}',
              );
            }
            final png = File('${root.path}/$name.png');
            await native.command(['screenshot-to-file', png.path, 'window']);
            await save('$name.png', await png.readAsBytes());
            if (hdr) {
              for (final key in ['target-prim', 'target-trc', 'target-peak']) {
                await native.setProperty(key, fields[key]!);
              }
            }
          }
          // Host captures the actual layer dataspace while this frame is visible.
          await wait(3000);
        }

        if (formatOnly) {
          expect(Platform.isWindows, isTrue);
          const dv81Software = bool.fromEnvironment('HDR_DV81_SOFTWARE');
          if (const bool.fromEnvironment('HDR_DIAGNOSTIC_NO_ZIMG')) {
            await native.setProperty('sws-allow-zimg', 'no');
          }
          const repeatCapture = bool.fromEnvironment('HDR_REPEAT_CAPTURE');
          if (dv81Software) await native.setProperty('hwdec', 'no');
          const diagnosticFbo = String.fromEnvironment('HDR_DIAGNOSTIC_FBO');
          if (diagnosticFbo.isNotEmpty) {
            await native.setProperty('fbo-format', diagnosticFbo);
          }
          const diagnosticNearest = bool.fromEnvironment(
            'HDR_DIAGNOSTIC_NEAREST',
          );
          if (diagnosticNearest) {
            for (final key in ['scale', 'cscale', 'dscale']) {
              await native.setProperty(key, 'nearest');
            }
          }
          const diagnosticScale = String.fromEnvironment(
            'HDR_DIAGNOSTIC_SCALE',
          );
          const diagnosticCscale = String.fromEnvironment(
            'HDR_DIAGNOSTIC_CSCALE',
          );
          if (diagnosticScale.isNotEmpty) {
            await native.setProperty('scale', diagnosticScale);
          }
          if (diagnosticCscale.isNotEmpty) {
            await native.setProperty('cscale', diagnosticCscale);
          }
          if (const bool.fromEnvironment('HDR_DIAGNOSTIC_UNSCALED')) {
            await native.setProperty('video-unscaled', 'yes');
          }
          const rejectDv5 = bool.fromEnvironment('HDR_DV5_ONLY');
          if (rejectDv5) {
            await wait(1500);
            expect(page.error, 'dv-profile-5');
            expect(await native.getProperty('pause'), 'yes');
            expect(
              await native.getProperty('track-list/0/dolby-vision-profile'),
              '5',
            );
            expect(
              find.textContaining('Dolby Vision Profile 5'),
              findsOneWidget,
            );
            await save(
              'unsupported.json',
              utf8.encode(
                jsonEncode({
                  'error': page.error,
                  'pause': await native.getProperty('pause'),
                  'profile': '5',
                  'visibleTextVerified': true,
                }),
              ),
            );
          }
          const dvProbe = bool.fromEnvironment('HDR_DV84_PROBE');
          const crossBoth = bool.fromEnvironment('HDR_CROSS_BOTH');
          if (crossBoth) {
            for (final decoder in dv81Software ? ['no'] : ['auto-safe', 'no']) {
              await native.setProperty('hwdec', decoder);
              await player.open(
                Media('${root.path}/${formatNames.first}.mkv'),
                play: false,
              );
              await wait(1000);
              const frames = bool.fromEnvironment('HDR_CROSS_LATER_FRAMES')
                  ? [0.25, 0.5, 0.75]
                  : bool.fromEnvironment('HDR_CROSS_EXTRA_FRAMES')
                  ? [0.0, 0.5, 1.0]
                  : [0.0];
              for (var frame = 0; frame < frames.length; frame++) {
                if (frame > 0 || frames[frame] > 0) {
                  await native.command([
                    'seek',
                    '${frames[frame]}',
                    'absolute+exact',
                  ]);
                  await wait(750);
                }
                await checkpoint(
                  '${decoder == 'no' ? 'sw' : 'hw'}${frames.length > 1 ? '-$frame' : ''}',
                  false,
                  pixels: true,
                  waitForProgress: false,
                );
                expect(page.error, isNull);
              }
            }
          }
          const crossPerf = bool.fromEnvironment('HDR_CROSS_PERF');
          const interlaceOnly = bool.fromEnvironment('HDR_INTERLACE_ONLY');
          if (interlaceOnly) {
            final modes = <String, Object?>{};
            for (final mode in ['default', 'auto']) {
              if (mode == 'auto') {
                await native.setProperty('deinterlace', 'auto');
              }
              await player.open(
                Media('${root.path}/${formatNames.first}.mkv'),
                play: false,
              );
              await wait(1000);
              final frames = <Map<String, String>>[];
              for (var n = 0; n < 8; n++) {
                await native.command(['frame-step']);
                await wait(200);
                final values = <String, String>{};
                for (final key in [
                  'time-pos',
                  'deinterlace',
                  'video-frame-info',
                  'estimated-vf-fps',
                  'container-fps',
                  'hwdec-current',
                ]) {
                  values[key] = await native.getProperty(key);
                }
                frames.add(values);
              }
              modes[mode] = frames;
              expect(page.error, isNull);
            }
            await save('interlace.json', utf8.encode(jsonEncode(modes)));
          }
          const repackBoundaries = bool.fromEnvironment(
            'HDR_REPACK_BOUNDARIES',
          );
          if (repackBoundaries) {
            for (final entry in {
              'forced-zimg': 'format=fmt=p010:convert=yes:force-scaler=zimg',
              'resize': 'format=fmt=p010:w=1280:h=720:convert=yes',
            }.entries) {
              await native.setProperty('vf', entry.value);
              await player.open(
                Media('${root.path}/${formatNames.first}.mkv'),
                play: false,
              );
              await wait(1000);
              final output =
                  jsonDecode(await native.getProperty('video-out-params'))
                      as Map<String, dynamic>;
              expect(output['pixelformat'], 'p010');
              if (entry.key == 'resize') {
                expect(output['w'], 1280);
                expect(output['h'], 720);
              }
              await checkpoint(
                entry.key,
                false,
                pixels: true,
                waitForProgress: false,
              );
              expect(page.error, isNull);
            }
          }
          if (crossPerf) {
            const paired = bool.fromEnvironment('HDR_COST_PAIR');
            for (var round = 0; round < (paired ? 4 : 1); round++) {
              if (paired) {
                await native.setProperty(
                  'sws-allow-zimg',
                  round.isEven ? 'yes' : 'no',
                );
                logs.clear();
              }
              await native.setProperty('loop-file', 'inf');
              await player.open(Media('${root.path}/${formatNames.first}.mkv'));
              await wait(3000);
              Future<Map<String, dynamic>> processSample() async {
                final result = await Process.run('powershell.exe', [
                  '-NoProfile',
                  '-NonInteractive',
                  '-WindowStyle',
                  'Hidden',
                  '-Command',
                  '\$p = Get-Process -Id $pid; @{cpu=\$p.CPU; workingSet=\$p.WorkingSet64; privateBytes=\$p.PrivateMemorySize64; threads=\$p.Threads.Count; time=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()} | ConvertTo-Json -Compress',
                ]);
                expect(result.exitCode, 0);
                return jsonDecode(result.stdout as String)
                    as Map<String, dynamic>;
              }

              final before = await processSample();
              await wait(12000);
              final after = await processSample();
              final fields = <String, String>{};
              for (final key in [
                'hwdec-current',
                'video-out-params',
                'frame-drop-count',
                'decoder-frame-drop-count',
                'paused-for-cache',
                'vo-passes',
                'sws-allow-zimg',
              ]) {
                fields[key] = await native.getProperty(key);
              }
              await save(
                paired ? 'performance-$round.json' : 'performance.json',
                utf8.encode(
                  jsonEncode({
                    'before': before,
                    'after': after,
                    'mpv': fields,
                    'logs': logs,
                  }),
                ),
              );
              await player.pause();
            }
          }
          if (dvProbe) {
            for (final entry in {
              'light': 'format=dolbyvision=no:enhancement-layer=no:light=hlg',
              'peak':
                  'format=dolbyvision=no:enhancement-layer=no:max-luma=1000',
              'both':
                  'format=dolbyvision=no:enhancement-layer=no:light=hlg:max-luma=1000',
            }.entries) {
              await native.setProperty('vf', entry.value);
              await player.open(Media('${root.path}/dv84.mkv'), play: false);
              await wait(1000);
              await checkpoint(
                entry.key,
                false,
                pixels: true,
                waitForProgress: false,
              );
              expect(page.error, isNull);
            }
          }
          for (final name
              in dvProbe ||
                      rejectDv5 ||
                      crossPerf ||
                      crossBoth ||
                      repackBoundaries ||
                      interlaceOnly
                  ? <String>[]
                  : formatNames) {
            const diagnosticVf = String.fromEnvironment('HDR_DIAGNOSTIC_VF');
            await native.setProperty('vf', diagnosticVf);
            if (diagnosticVf.isEmpty) {
              expect(await native.getProperty('vf'), isEmpty);
            }
            await player.open(Media('${root.path}/$name.mkv'), play: false);
            for (final disabled in [false, true]) {
              if (disabled) {
                await native.setProperty(
                  'vf',
                  name == 'hdr10plus'
                      ? 'format=hdr10plus=no'
                      : 'format=dolbyvision=no:enhancement-layer=no${diagnosticVf.isEmpty ? '' : ',$diagnosticVf'}',
                );
              }
              await player.open(Media('${root.path}/$name.mkv'), play: false);
              await wait(1000);
              await checkpoint(
                '$name-metadata-${disabled ? 'off' : 'on'}',
                false,
                pixels: true,
                waitForProgress: false,
              );
              if (repeatCapture) {
                for (
                  var repetition = 0;
                  repetition <
                      const int.fromEnvironment(
                        'HDR_REPEAT_COUNT',
                        defaultValue: 1,
                      );
                  repetition++
                ) {
                  await checkpoint(
                    '$name-metadata-${disabled ? 'off' : 'on'}-repeat${repetition == 0 ? '' : '-$repetition'}',
                    false,
                    pixels: true,
                    waitForProgress: false,
                  );
                }
              }
              expect(page.error, isNull);
            }
          }
        } else if (hlgOnly) {
          expect(Platform.isWindows, isTrue);
          await native.setProperty('loop-file', 'inf');
          await wait(1500);
          await player.pause();
          for (final frame in [0, 1]) {
            await native.command(['seek', '$frame', 'absolute+exact']);
            await wait(700);
            final fields = <String, String>{};
            for (final field in [
              'time-pos',
              'video-params',
              'video-dec-params',
              'video-target-params',
              'hwdec-current',
              'current-vo',
              'target-trc',
              'target-prim',
              'target-peak',
              'hdr-compute-peak',
              'tone-mapping',
              'dither',
            ]) {
              fields[field] = await native.getProperty(field);
            }
            final capture = Map<Object?, Object?>.from(
              await page.capturePresentedBuffer(pixels: true) as Map,
            );
            final bytes = capture.remove('pixels') as Uint8List;
            await save(
              'pattern-$frame.json',
              utf8.encode(
                jsonEncode({'mpv': fields, 'surface': capture, 'logs': logs}),
              ),
            );
            await save('pattern-$frame.raw', bytes);
            expect(jsonDecode(fields['video-params']!)['gamma'], 'hlg');
            expect(fields['target-trc'], 'auto');
            expect(capture['outputColorSpace'], 'sdr');
            expect(capture['format'], 'R10G10B10A2_UNORM');
            expect(page.error, isNull);
          }
        } else if (const bool.fromEnvironment('HDR_STABILITY_ONLY')) {
          expect(Platform.isAndroid, isTrue);
          await native.setProperty('loop-file', 'inf');
          final samples = <Map<String, Object?>>[];
          try {
            for (var i = 0; i < 36; i++) {
              if (i == 0 || i == 3 || i == 6) {
                await SystemChrome.setPreferredOrientations([
                  i == 3
                      ? DeviceOrientation.portraitUp
                      : DeviceOrientation.landscapeLeft,
                ]);
              }
              await wait(5000);
              final sample = <String, Object?>{'elapsedSeconds': (i + 1) * 5};
              for (final key in [
                'time-pos',
                'video-target-params',
                'video-dec-params',
                'hwdec-current',
                'frame-drop-count',
                'decoder-frame-drop-count',
                'paused-for-cache',
                'osd-width',
                'osd-height',
              ]) {
                sample[key] = await native.getProperty(key);
              }
              sample['viewWidth'] = tester.view.physicalSize.width;
              sample['viewHeight'] = tester.view.physicalSize.height;
              samples.add(sample);
              if (i == 1 || i == 17 || i == 35) {
                debugPrint('HDR_RESOURCE $tag sample-$i');
              }
            }
            // Give the host time to read the final live layer/resource state.
            await wait(3000);
            await save('stability.json', utf8.encode(jsonEncode(samples)));
            expect(
              samples.every(
                (s) =>
                    (jsonDecode(s['video-target-params'] as String)
                        as Map)['gamma'] ==
                    'pq',
              ),
              isTrue,
            );
            expect(samples.every((s) => s['paused-for-cache'] == 'no'), isTrue);
            expect(page.error, isNull);
          } finally {
            await SystemChrome.setPreferredOrientations([]);
          }
        } else if (const bool.fromEnvironment('HDR_RECOVERY_ONLY')) {
          expect(Platform.isWindows, isTrue);
          // Exercise the detached interval deterministically as well as the
          // actual asynchronous recovery below. A live HWND need not own a VO.
          const channel = MethodChannel('ccplayer/native_video');
          final detached = await channel.invokeMethod<int>('create', true);
          try {
            for (final method in [
              'captureD3D11',
              'beginColor',
              'commitColor',
            ]) {
              await expectLater(
                channel.invokeMethod<void>(method, [detached, false, 0]),
                throwsA(
                  isA<PlatformException>().having(
                    (e) => e.code,
                    'code',
                    'output_unavailable',
                  ),
                ),
              );
            }
          } finally {
            await channel.invokeMethod<void>('destroy', [detached]);
          }
          for (
            var i = 0;
            i < 200 && player.state.position.inMilliseconds < 500;
            i++
          ) {
            await wait(100);
          }
          final before = await page.capturePresentedBuffer() as Map;
          await page.simulateNativeOutputFailure();
          Map? recovered;
          for (var i = 0; i < 150; i++) {
            await wait(100);
            try {
              final candidate = await page.capturePresentedBuffer() as Map;
              if (candidate['generation'] != before['generation']) {
                recovered = candidate;
                break;
              }
            } catch (_) {
              /* Recovery owns the output until reattached. */
            }
          }
          expect(recovered, isNotNull);
          expect(recovered!['outputColorSpace'], 'sdr');
          expect(await native.getProperty('target-trc'), 'auto');
          await checkpoint('recreated-output', false);
          expect(page.error, isNull);
        } else if (const bool.fromEnvironment('PLAYER_TRACK_REVIEW')) {
          // WatchPage waits for the Android Surface before its initial open.
          // Do not race that initial request with this diagnostic's own open.
          for (
            var i = 0;
            i < 200 && player.state.position.inMilliseconds < 300;
            i++
          ) {
            await wait(100);
          }
          expect(
            player.state.position.inMilliseconds,
            greaterThanOrEqualTo(300),
          );
          await player.open(Media('${root.path}/sdr.mkv'));
          await wait(1200);
          await player.pause();
          final audio = player.state.tracks.audio.firstWhere(
            (t) => t.id != 'auto' && t.id != 'no',
          );
          final subtitleFile = File('${root.path}/review.srt');
          await subtitleFile.writeAsString(
            '1\n00:00:00,000 --> 00:00:20,000\nKonata track review\n',
          );
          final subtitle = SubtitleTrack.uri(subtitleFile.uri.toString());
          Future<void> select(
            String mode,
            Future<void> Function() action,
          ) async {
            final gate = Completer<void>();
            var calls = 0;
            Future<void> apply() async {
              calls++;
              await gate.future;
              await action();
            }

            final dialog = showDialog<void>(
              context: tester.element(find.byType(WatchPage)),
              builder: (_) => Dialog(
                child: TrackPicker(
                  subtitles: mode != 'audio',
                  selectedId: 'auto',
                  audioTracks: [audio],
                  onAudio: (_) => apply(),
                  onSubtitle: (_) => apply(),
                  onImport: () async {
                    await apply();
                    return true;
                  },
                ),
              ),
            );
            await wait(400);
            final tile = mode == 'import'
                ? find.widgetWithIcon(ListTile, Icons.file_open_outlined)
                : find.byKey(
                    ValueKey(
                      mode == 'audio'
                          ? 'audio-track-${audio.id}'
                          : 'subtitle-track-no',
                    ),
                  );
            // Deliver both events before a rebuilt disabled tile can hide re-entry.
            final callback = tester.widget<ListTile>(tile).onTap!;
            callback();
            callback();
            expect(calls, 1);
            gate.complete();
            for (
              var i = 0;
              i < 100 && find.byType(TrackPicker).evaluate().isNotEmpty;
              i++
            ) {
              await wait(50);
            }
            expect(find.byType(TrackPicker), findsNothing);
            await dialog;
            expect(find.byType(WatchPage), findsOneWidget);
          }

          await player.setAudioTrack(AudioTrack.no());
          await select('audio', () => player.setAudioTrack(audio));
          expect(await native.getProperty('aid'), audio.id);
          await select('import', () => player.setSubtitleTrack(subtitle));
          expect(await native.getProperty('sid'), isNot('no'));
          await select(
            'subtitle',
            () => player.setSubtitleTrack(SubtitleTrack.no()),
          );
          expect(await native.getProperty('sid'), 'no');
          await player.play();
          await checkpoint('tracks-restored', false);
          expect(page.error, isNull);
          debugPrint('PLAYER_TRACK_REVIEW_PASSED $tag');
        } else if (const bool.fromEnvironment('ANDROID_PLAYER_EXIT_ONLY')) {
          await checkpoint('exit-source', expectedHdr);
        } else if (const bool.fromEnvironment('ANDROID_PLAYER_REVIEW')) {
          await checkpoint('before-switch', expectedHdr);
          await player.open(Media('${root.path}/sdr.mkv'));
          await checkpoint('switch-sdr', false);
          await player.open(Media('${root.path}/pq.mkv'));
          await checkpoint('switch-pq', expectedHdr);
          await player.play();
          debugPrint('ANDROID_REVIEW_HOME_READY $tag');
          await wait(10000);
          expect(binding.lifecycleState, AppLifecycleState.resumed);
          await player.play();
          await checkpoint('after-background', expectedHdr);
          expect(page.error, isNull);
        } else if (const bool.fromEnvironment('HDR_LIFECYCLE_ONLY')) {
          for (
            var i = 0;
            i < 200 && player.state.position.inMilliseconds < 500;
            i++
          ) {
            await wait(100);
          }
          debugPrint('HDR_HOME_READY $tag');
          await wait(8000);
          await player.play();
          await wait(700);
          await player.pause();
          await native.command(['seek', '5.005', 'absolute+exact']);
          await native.setProperty('dither', 'no');
          await wait(1000);
          await checkpoint('after-home', expectedHdr, pixels: true);
          final ass = File('${root.path}/hdr-white.ass');
          await ass.writeAsString(
            '[Script Info]\nScriptType: v4.00+\nPlayResX: 1920\nPlayResY: 1080\n'
            '[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n'
            'Style: Default,sans-serif,40,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n'
            '[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
            r'Dialogue: 0,0:00:00.00,0:05:00.00,Default,,0,0,0,,{\an7\pos(100,100)\bord0\shad0\p1}m 0 0 l 180 0 180 180 0 180'
            '\n',
          );
          await native.command(['sub-add', ass.path, 'select']);
          await wait(500);
          await checkpoint('hdr-subtitle-white', expectedHdr, pixels: true);
        } else {
          await checkpoint('pq-first', expectedHdr, pixels: true);
          await player.open(Media('${root.path}/sdr.mkv'));
          await checkpoint('pq-to-sdr', false);
          await player.open(Media('${root.path}/pq.mkv'));
          await checkpoint('sdr-to-pq', expectedHdr);
          if (Platform.isAndroid) {
            // New capability-loss recovery only; no old SDR picture matrix.
            final peak = await native.getProperty('android-hdr-peak');
            await native.setProperty('android-hdr-peak', '0');
            await native.setProperty('vo', 'null');
            await native.setProperty('vo', 'gpu');
            await player.play();
            await checkpoint('hdr-unavailable', false);
            await native.setProperty('android-hdr-peak', peak);
            await native.setProperty('vo', 'null');
            await native.setProperty('vo', 'gpu');
            await player.play();
            await checkpoint('hdr-restored', expectedHdr);
          }
        }
        await tester.pumpWidget(const SizedBox());
        await subscription.cancel();
        await player.stream.position.drain<void>().timeout(
          const Duration(seconds: 20),
        );
        debugPrint('HDR_OUTPUT_RELEASED $tag');
        await wait(1000);
      } finally {
        client.close(force: true);
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
