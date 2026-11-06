import 'dart:async';
import 'dart:io';

import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'webdav_trial_support.dart';

// Collect only glyph selection messages. Verbose native logs can contain
// private media URLs and must never be forwarded wholesale.
class FontProbeConfig extends MpvConfigStore {
  FontProbeConfig({required super.rootOverride});

  @override
  PlayerConfiguration get playerConfiguration {
    final base = super.playerConfiguration;
    return PlayerConfiguration(
      libass: base.libass,
      mpvConfigurationDirectory: base.mpvConfigurationDirectory,
      logLevel: MPVLogLevel.v,
    );
  }
}

Future<void> verifySdr(
  WidgetTester tester,
  Map<String, Object?> asset,
  MpvConfigStore config,
) async {
  const extra = bool.fromEnvironment('DAV_SDR_EXTRA');
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
  final n = player.platform as NativePlayer;
  final fontProbe = const bool.fromEnvironment('DAV_FONT_PROBE');
  final fonts = fontProbe
      ? player.stream.log.listen((line) {
          if (line.prefix == 'sub/ass' &&
              line.text.contains('fontselect:') &&
              (line.text.contains('DFGSoGei-W7') ||
                  line.text.contains('方正综艺_GBK'))) {
            record('font_selection', {'message': line.text.trim()});
          }
        })
      : null;
  Future<Map<String, String>> read(List<String> keys) async => {
    for (final k in keys) k: await n.getProperty(k),
  };
  Future<void> seek(double t) async {
    await player.pause();
    await n.command(['seek', '$t', 'absolute+exact']);
    await poll(
      tester,
      () async =>
          ((double.tryParse(await n.getProperty('time-pos')) ?? -100) - t)
                  .abs() <
              .045 &&
          await n.getProperty('seeking') == 'no',
      seconds: 45,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  Future<void> capture(String mode, String name) async {
    record('sdr_capture', {
      'mode': mode,
      'name': name,
      ...await read([
        'time-pos',
        'sid',
        'sub-font',
        'hwdec-current',
        'video-params/pixelformat',
        'video-params/hw-pixelformat',
        'osd-width',
        'osd-height',
      ]),
      'sub_text': (await n.getProperty('sub-text')).isNotEmpty,
    });
    await Future<void>.delayed(Duration(seconds: Platform.isWindows ? 6 : 3));
  }

  try {
    await player.setVolume(0);
    await poll(
      tester,
      () async =>
          !page.loading &&
          (page.addedSubtitles as List<SubtitleTrack>).any(
            (t) => t.title?.endsWith('.sc.ass') ?? false,
          ),
      seconds: 60,
    );
    await poll(tester, () async {
      final count = int.tryParse(await n.getProperty('track-list/count')) ?? 0;
      final sid = await n.getProperty('sid');
      for (var i = 0; i < count; i++) {
        if (await n.getProperty('track-list/$i/type') == 'sub' &&
            await n.getProperty('track-list/$i/id') == sid &&
            (await n.getProperty('track-list/$i/title')).endsWith('.sc.ass')) {
          return true;
        }
      }
      return false;
    }, seconds: 30);
    final video = tester.state<VideoState>(find.byType(Video).first);
    unawaited(video.enterFullscreen());
    if (Platform.isWindows) await windowManager.focus();
    await Future<void>.delayed(const Duration(seconds: 4));
    record(
      'sdr_meta',
      await read([
        'mpv-version',
        'ffmpeg-version',
        'current-vo',
        'hwdec-current',
        'video-params/pixelformat',
        'video-params/hw-pixelformat',
        'video-params/primaries',
        'video-params/gamma',
        'video-params/colorlevels',
        'scale',
        'cscale',
        'dscale',
        'dither',
        'dither-depth',
        'deband',
        'sub-font',
        'sid',
        'display-fps',
      ]),
    );
    if (Platform.isWindows && !config.enabled) {
      final screen = View.of(key.currentContext!).physicalSize;
      final width = int.parse(await n.getProperty('osd-width'));
      final height = int.parse(await n.getProperty('osd-height'));
      // This reference episode is 16:9. A taller viewport must expose its
      // letterbox to libass, including after a source-size notification.
      if (screen.aspectRatio < 16 / 9) {
        expect(width / height, closeTo(screen.aspectRatio, .002));
        expect(await n.getProperty('sub-ass-force-margins'), 'yes');
      }
    }
    if (fontProbe &&
        Platform.isAndroid &&
        const bool.fromEnvironment('DAV_FONT_TC')) {
      final directory = await Directory.systemTemp.createTemp(
        'cc-font-variant-',
      );
      try {
        await Link(
          '${directory.path}/reference.ttf',
        ).create('/system/fonts/MiSansTCVF.ttf');
        await n.setProperty('sub-fonts-dir', directory.path);
        await n.setProperty('sub-font', 'Misans TC VF');
        final sid = await n.getProperty('sid');
        await n.command(['sub-reload', sid]);
        await seek(1388.33);
        await capture('font', 'karaoke');
        await n.setProperty('sub-visibility', 'no');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await capture('font', 'karaoke-clean');
      } finally {
        await directory.delete(recursive: true);
      }
      return;
    }
    if (fontProbe) {
      for (final scene in {'karaoke': 1388.33, 'position': 176.2}.entries) {
        await seek(scene.value);
        await capture('font', scene.key);
        await n.setProperty('sub-visibility', 'no');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await capture('font', '${scene.key}-clean');
        await n.setProperty('sub-visibility', 'yes');
      }
      return;
    }
    if (const bool.fromEnvironment('DAV_SDR_GRADIENTS')) {
      for (final mode in ['default', 'software']) {
        if (mode == 'software') await n.setProperty('hwdec', 'no');
        for (final shot in {'dusk': 22.0, 'mist': 37.7}.entries) {
          await seek(shot.value);
          await capture(mode, shot.key);
        }
      }
      return;
    }
    for (final scene
        in (extra
                ? {'sky': 7.216}
                : {
                    'shadow': 137.012,
                    'line': 123.957,
                    'position': 176.2,
                    'karaoke': 1388.33,
                  })
            .entries) {
      await seek(scene.value);
      await capture('default', scene.key);
      if (scene.key == 'position' || scene.key == 'karaoke') {
        await n.setProperty('sub-visibility', 'no');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await capture('default', '${scene.key}-clean');
        await n.setProperty('sub-visibility', 'yes');
      }
    }
    for (final section in {'pan': 1144.75, 'peak': 1335.0}.entries) {
      await seek(section.value);
      final before = await read([
        'frame-drop-count',
        'decoder-frame-drop-count',
      ]);
      final samples = <Map<String, String>>[];
      await player.play();
      final watch = Stopwatch()..start();
      record('sdr_segment', {'name': section.key, 'pid': pid, ...before});
      while (watch.elapsedMilliseconds < 15000) {
        samples.add(
          await read([
            'time-pos',
            'avsync',
            'frame-drop-count',
            'decoder-frame-drop-count',
            'paused-for-cache',
          ]),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await player.pause();
      for (final sample in samples) {
        record('sdr_sample', {'name': section.key, ...sample});
      }
    }
    if (Platform.isAndroid) {
      await n.setProperty('hwdec', 'no');
      await seek(extra ? 7.216 : 137.012);
      expect(await n.getProperty('hwdec-current'), 'no');
      await capture('software', extra ? 'sky' : 'shadow');
      if (extra) return;
      await seek(123.957);
      await capture('software', 'line');
    }
  } finally {
    await fonts?.cancel();
    final states = find.byType(Video).evaluate();
    if (states.isNotEmpty) {
      final v = tester.state<VideoState>(find.byType(Video).first);
      if (v.isFullscreen()) await v.exitFullscreen();
    }
    await tester.pumpWidget(const SizedBox());
    await poll(tester, () async => n.disposed);
  }
}
