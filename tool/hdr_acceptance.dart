// Isolated on-device acceptance entry, never the product entrypoint.
// The loopback scenario and bounded reports avoid Flutter test frame pumping
// during timing measurements. Build only with the validation package suffix.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/watch_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Acceptance entry only: never read/write real profile preferences.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final client = HttpClient();
  const endpoint = 'http://127.0.0.1:18770';
  final response = await (await client.getUrl(
    Uri.parse('$endpoint/scenario.json'),
  )).close();
  final scenario = jsonDecode(await utf8.decodeStream(response)) as Map;
  final tag = scenario['tag'] as String;
  if (!RegExp(r'^[a-z0-9-]{1,80}$').hasMatch(tag)) {
    throw ArgumentError('Invalid run tag');
  }
  Future<void> save(String name, Object value) async {
    final bytes = value is List<int> ? value : utf8.encode(jsonEncode(value));
    final request = await client.postUrl(Uri.parse('$endpoint/$tag-$name'));
    request.contentLength = bytes.length;
    request.add(bytes);
    final result = await request.close();
    if (result.statusCode != 201) {
      throw StateError('Evidence HTTP ${result.statusCode}');
    }
    await result.drain<void>();
  }

  final root = await Directory.systemTemp.createTemp('konata-hdr-acceptance-');
  final eglProbe = File(
    '${root.parent.parent.path}/cache/konata-egl-probe.bin',
  );
  final stageDir = Directory('${eglProbe.parent.path}/konata-stages');
  final queuedProbe = File('${eglProbe.parent.path}/konata-queued-probe.bin');
  final failureControl = File('${eglProbe.parent.path}/konata-egl-fault.txt');
  final failureEvents = File('${eglProbe.parent.path}/konata-egl-events.jsonl');
  final captureGate = File('${eglProbe.parent.path}/konata-egl-capture');
  final failureMode = scenario['mode'] == 'failure';
  if (failureMode) {
    if (await failureEvents.exists()) await failureEvents.delete();
    await failureControl.writeAsString(scenario['fault'] as String? ?? 'none');
  }
  if (scenario['queuedProbe'] == true && await queuedProbe.exists()) {
    await queuedProbe.delete();
  }
  if (scenario['stageProbe'] == true && await stageDir.exists()) {
    await stageDir.delete(recursive: true);
  }
  if (scenario['eglProbe'] == true && await eglProbe.exists()) {
    await eglProbe.delete();
  }
  final catalog = Catalog.instance;
  final key = GlobalKey();
  Player? player;
  final subscriptions = <StreamSubscription>[];
  try {
    final fixture = scenario['fixture'] as String? ?? 'pq.mkv';
    final media = await (await client.getUrl(
      Uri.parse('$endpoint/$fixture'),
    )).close();
    if (media.statusCode != 200) throw StateError('Fixture unavailable');
    await media.pipe(File('${root.path}/input.mkv').openWrite());
    await catalog.initialize(dataDirectory: root);
    final source = await catalog.addSource(
      'local',
      'HDR acceptance',
      root.path,
    );
    final asset = <String, Object?>{
      'id': tag,
      'work_id': tag,
      'name': 'HDR acceptance',
      'relative_path': 'input.mkv',
      'source_id': source,
      'category': 'main',
    };
    await catalog.db.insert('works', {'id': tag, 'title': tag});
    await catalog.db.insert('assets', asset);
    final store = MpvConfigStore(rootOverride: Directory('${root.path}/mpv'));
    await store.initialize();
    final explicitConfig = scenario['config'] as String?;
    if (explicitConfig != null) {
      await store.saveConfig('mpv.conf', explicitConfig);
      await store.setConfigEnabled(true);
    }
    runApp(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WatchPage(key: key, asset: asset, configurationStore: store),
      ),
    );
    for (var i = 0; i < 300 && player == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        player = (key.currentState as dynamic).player as Player;
      } on Error {
        /* creating */
      }
    }
    final active = player!;
    final native = active.platform as NativePlayer;
    await active.setVolume(0);
    if (scenario['mode'] == 'unsupportedDv5' ||
        scenario['mode'] == 'supportedDv81') {
      final reject = scenario['mode'] == 'unsupportedDv5';
      for (
        var i = 0;
        i < 200 &&
            (reject
                ? (key.currentState as dynamic).error == null
                : (await native.getProperty(
                        'track-list/0/dolby-vision-profile',
                      )) !=
                      '8');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final pageError = (key.currentState as dynamic).error;
      final paused = await native.getProperty('pause');
      final profile = await native.getProperty(
        'track-list/0/dolby-vision-profile',
      );
      final labels = <String>[];
      void visit(Element element) {
        final widget = element.widget;
        if (widget is Text && widget.data != null) labels.add(widget.data!);
        element.visitChildren(visit);
      }

      visit(key.currentContext! as Element);
      if (reject &&
          (pageError != 'dv-profile-5' ||
              paused != 'yes' ||
              profile != '5' ||
              !labels.any((text) => text.contains('Dolby Vision Profile 5')))) {
        throw StateError(
          'Profile 5 rejection failed: $pageError/$paused/$profile/$labels',
        );
      }
      if (!reject && (pageError != null || profile != '8')) {
        throw StateError(
          'Profile 8.1 was incorrectly rejected: $pageError/$profile',
        );
      }
      await save(reject ? 'unsupported.json' : 'supported.json', {
        'error': pageError,
        'pause': paused,
        'profile': profile,
        'visibleText': labels,
      });
      runApp(const SizedBox());
      await active.stream.position.drain<void>().timeout(
        const Duration(seconds: 20),
      );
      await save('released.json', {'rssBytes': ProcessInfo.currentRss});
      return;
    }
    final formatMode = scenario['mode'] == 'format';
    if (formatMode) await active.pause();
    for (
      var i = 0;
      !formatMode && i < 200 && active.state.position.inMilliseconds < 500;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final logs = <String>[];
    subscriptions.add(
      active.stream.log.listen((event) {
        if (logs.length == 100) logs.removeAt(0);
        logs.add(event.toString());
      }),
    );
    Future<Map<String, Object?>> stats({bool full = false}) async {
      final result = <String, Object?>{'rssBytes': ProcessInfo.currentRss};
      for (final name in [
        'time-pos',
        'frame-drop-count',
        'decoder-frame-drop-count',
        'avsync',
        'paused-for-cache',
        'pause',
        'seeking',
        'vo-delayed-frame-count',
        if (full) ...[
          'video-params',
          'video-out-params',
          'vf',
          'video-dec-params',
          'video-target-params',
          'hwdec-current',
          'current-vo',
          'display-fps',
          'estimated-display-fps',
          'dither',
          'osd-width',
          'osd-height',
          'mpv-version',
          'scale',
          'cscale',
          'dscale',
          'fbo-format',
          'target-prim',
          'target-trc',
          'target-peak',
          'tone-mapping',
          'hdr-compute-peak',
          'android-hdr-peak',
          'video',
          'vid',
        ],
      ]) {
        try {
          result[name] = await native.getProperty(name);
        } catch (_) {
          result[name] = null;
        }
      }
      final proc = await File('/proc/self/stat').readAsString();
      final fields = proc.substring(proc.lastIndexOf(')') + 2).split(' ');
      result['cpuTicks'] = int.parse(fields[11]) + int.parse(fields[12]);
      return result;
    }

    const window = MethodChannel('ccplayer/playback_window');
    final mode = scenario['mode'] as String? ?? 'measure';
    if (scenario['landscape'] == true) {
      // Isolated timing scenario: match the previously reported landscape
      // output size without changing the user's global rotation setting.
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (mode != 'orientation' && mode != 'manual') {
      await window.invokeMethod<void>('orientationLocked', true);
    }
    await native.setProperty('loop-file', 'inf');
    // Installation notifications can transiently take audio focus. Start the
    // measurement only after an explicit playback action and startup settling.
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!formatMode && (key.currentState as dynamic).error == null) {
      await active.play();
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final clock = Stopwatch()..start();
    final changes = <Map<String, Object?>>[];
    String? previousDropCount;
    await native.observeProperty('frame-drop-count', (value) async {
      if (value == previousDropCount) return;
      previousDropCount = value;
      changes.add({
        'ms': clock.elapsedMilliseconds,
        'count': value,
        'position': active.state.position.inMilliseconds,
      });
    });
    await save('ready.json', {
      'build': kReleaseMode ? 'release' : 'debug',
      'scenario': scenario,
      'initial': await stats(full: true),
    });
    final samples = <Map<String, Object?>>[];
    final seconds = (scenario['seconds'] as int? ?? 180).clamp(1, 240);
    Future<void> capture(String name) async {
      if (scenario['directOnly'] == true) {
        final bytes = await eglProbe.readAsBytes();
        await save('$name.json', {'mpv': await stats(full: true)});
        await save('$name-egl.bin', bytes);
        if (!listEquals(bytes, await eglProbe.readAsBytes())) {
          throw StateError('EGL framebuffer changed during direct capture');
        }
        return;
      }
      final beforeQueued = scenario['queuedProbe'] == true
          ? await queuedProbe.readAsBytes()
          : null;
      final beforeEgl = scenario['eglProbe'] == true
          ? await eglProbe.readAsBytes()
          : null;
      final surface = Map<Object?, Object?>.from(
        await (key.currentState as dynamic).capturePresentedBuffer(
              pixels: true,
              packed10: scenario['packed10'] == true,
            )
            as Map,
      );
      final bytes = surface.remove('pixels') as List<int>;
      await save('$name.json', {
        'mpv': await stats(full: true),
        'surface': surface,
      });
      await save('$name.raw', bytes);
      if (beforeEgl != null) {
        final afterEgl = await eglProbe.readAsBytes();
        if (!listEquals(beforeEgl, afterEgl)) {
          throw StateError('EGL framebuffer changed during PixelCopy pairing');
        }
        await save('$name-egl.bin', beforeEgl);
      }
      if (beforeQueued != null) {
        if (!listEquals(beforeQueued, await queuedProbe.readAsBytes())) {
          throw StateError('Queued buffer changed during PixelCopy pairing');
        }
        await save('$name-queued.bin', beforeQueued);
      }
      if (scenario['stageProbe'] == true) {
        final files = await stageDir.list().toList();
        if (files.isEmpty || files.length > 256) {
          throw StateError('Missing or unbounded stage evidence');
        }
        for (final entry in files.whereType<File>()) {
          final data = await entry.readAsBytes();
          await save('$name-stage-${entry.uri.pathSegments.last}', data);
          if (!listEquals(data, await entry.readAsBytes())) {
            throw StateError('Stage changed during paused capture');
          }
        }
      }
    }

    if (mode == 'format') {
      for (final disabled in [false, true]) {
        await captureGate.writeAsString('');
        if (disabled) {
          await native.command([
            'vf',
            'add',
            scenario['disableFilter'] as String,
          ]);
        }
        await active.open(Media('${root.path}/input.mkv'), play: false);
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        if (scenario['settleRedraw'] == true) {
          // A paused single-frame clip may only have submitted the bootstrap
          // surface. Request a redraw, then restore the exact original framing.
          await native.setProperty('video-pan-x', '0.001');
          await Future<void>.delayed(const Duration(milliseconds: 150));
          await native.setProperty('video-pan-x', '0');
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        await captureGate.delete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await capture(disabled ? 'metadata-off' : 'metadata-on');
        if ((key.currentState as dynamic).error != null) {
          throw StateError('Format output failed');
        }
      }
    } else if (mode == 'failure') {
      Future<List<dynamic>> events() async =>
          (await failureEvents.readAsLines())
              .where((line) => line.isNotEmpty)
              .map(jsonDecode)
              .toList();
      final expected = scenario['expected'] as String? ?? 'sdr';
      final before = await stats(full: true);
      final trace = await events();
      var visibleErrorCount = 0;
      final message = AppLocalizations.of(
        key.currentContext!,
      ).hdrTargetIncompatible;
      void inspect(Element element) {
        if (element.widget is Text &&
            (element.widget as Text).data == message) {
          visibleErrorCount++;
        }
        element.visitChildren(inspect);
      }

      (key.currentContext! as Element).visitChildren(inspect);
      await save('failure-before.json', {
        'mpv': before,
        'events': trace,
        'pageError': (key.currentState as dynamic).error,
        'visibleErrorCount': visibleErrorCount,
        'config': explicitConfig,
      });
      final target = before['video-target-params'] as String? ?? '';
      final gamma = target.isEmpty ? '' : (jsonDecode(target) as Map)['gamma'];
      if (expected == 'rejected') {
        if (!trace.any((e) => e['event'] == 'explicit-rejected') ||
            trace.any((e) => e['event'] == 'submitted' && e['pq'] == true)) {
          throw StateError(
            'Explicit incompatible target was not rejected safely',
          );
        }
        if ((key.currentState as dynamic).error != 'hdr-target' ||
            visibleErrorCount != 1 ||
            before['pause'] != 'yes') {
          throw StateError(
            'HDR target rejection needs one visible error and paused playback',
          );
        }
      } else {
        if ((gamma == 'pq') != (expected == 'pq') ||
            !trace.any(
              (e) => e['event'] == 'submitted' && e['pq'] == (expected == 'pq'),
            )) {
          throw StateError('EGL fallback/output state did not match target');
        }
        final positions = [active.state.position.inMilliseconds];
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          positions.add(active.state.position.inMilliseconds);
        }
        await save('failure-progress.json', {'positionsMs': positions});
        if (positions.toSet().length < 2 ||
            (key.currentState as dynamic).error != null) {
          throw StateError('Output path did not continue playing');
        }
      }
      if (explicitConfig != null) {
        if (await store.readConfig('mpv.conf') != explicitConfig) {
          throw StateError('Explicit configuration was overwritten');
        }
      }
      if (scenario['recover'] == true) {
        await failureControl.writeAsString('none');
        await native.setProperty('vo', 'null');
        await native.setProperty('vo', 'gpu');
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (await native.getProperty('video-target-params/gamma') == 'pq') {
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final recovered = await stats(full: true);
        final recoveredTrace = await events();
        await save('failure-recovered.json', {
          'mpv': recovered,
          'events': recoveredTrace,
        });
        if (await native.getProperty('video-target-params/gamma') != 'pq' ||
            !recoveredTrace.any(
              (e) => e['event'] == 'submitted' && e['pq'] == true,
            )) {
          throw StateError('New VO did not recover after EGL fault removed');
        }
      }
    } else if (mode == 'manual') {
      await save('manual-ready.json', await stats(full: true));
      for (var i = 0; i < 150; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        samples.add({
          'ms': clock.elapsedMilliseconds,
          'gamma': await native.getProperty('video-target-params/gamma'),
          'width': await native.getProperty('osd-width'),
          'height': await native.getProperty('osd-height'),
        });
        final control = await (await client.getUrl(
          Uri.parse('$endpoint/manual.json'),
        )).close();
        final command = jsonDecode(await utf8.decodeStream(control)) as Map;
        if (command['done'] == true) break;
      }
    } else if (mode == 'pattern') {
      await active.pause();
      await native.setProperty('dither', 'no');
      final properties = scenario['properties'] as Map? ?? {};
      for (final entry in properties.entries) {
        if (![
          'target-peak',
          'fbo-format',
          'video-unscaled',
        ].contains(entry.key)) {
          throw ArgumentError('Unsupported diagnostic property');
        }
        await native.setProperty(entry.key as String, entry.value.toString());
      }
      for (final frame in (scenario['frames'] as List? ?? [0, 1, 2])) {
        await native.command(['seek', '$frame', 'absolute+exact']);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await capture('pattern-$frame');
      }
    } else if (mode == 'orientation') {
      bool selected() =>
          (findButton(
                    (b) => b.key == const ValueKey('playback-orientation'),
                  ).widget
                  as IconButton)
              .isSelected ==
          true;
      Future<void> toggle() =>
          tapButton((b) => b.key == const ValueKey('playback-orientation'));
      await toggle();
      if (!selected()) {
        throw StateError('Orientation lock did not become selected');
      }
      await save('check-locked.json', await stats(full: true));
      await Future<void>.delayed(const Duration(seconds: 2));
      await tapButton(
        (b) => b.icon is Icon && (b.icon as Icon).icon == Icons.fullscreen_exit,
      );
      if (!selected()) {
        throw StateError('Leaving fullscreen cleared orientation lock');
      }
      await tapButton(
        (b) => b.icon is Icon && (b.icon as Icon).icon == Icons.fullscreen,
      );
      await toggle();
      if (selected()) throw StateError('Orientation unlock failed');
      await save('check-unlocked.json', await stats(full: true));
      await Future<void>.delayed(const Duration(seconds: 2));
      await toggle(); // Leaving the page must also restore a currently locked orientation.
      if (!selected()) throw StateError('Second orientation lock failed');
      if (await native.getProperty('video-target-params/gamma') != 'pq') {
        throw StateError('Orientation interaction lost native HDR');
      }
    } else if (mode == 'sleep') {
      await save('sleep-ready.json', await stats(full: true));
      await Future<void>.delayed(const Duration(seconds: 8));
      final resumeClock = Stopwatch()..start();
      while (WidgetsBinding.instance.lifecycleState !=
          AppLifecycleState.resumed) {
        if (resumeClock.elapsed > const Duration(seconds: 45)) {
          throw StateError(
            'Device was not unlocked/resumed; recovery not measured',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await active.play();
      final before = active.state.position;
      final recoveryClock = Stopwatch()..start();
      Map? surface;
      var emptyCopies = 0;
      while (surface == null &&
          recoveryClock.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (active.state.position == before) continue;
        try {
          surface =
              await (key.currentState as dynamic).capturePresentedBuffer()
                  as Map;
        } on PlatformException catch (failure) {
          if (failure.code != 'surface_unavailable' &&
              !(failure.code == 'surface_copy_failed' &&
                  failure.message == 'PixelCopy status 3')) {
            rethrow;
          }
          emptyCopies++;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      if (surface == null ||
          active.state.position == before ||
          await native.getProperty('video-target-params/gamma') != 'pq') {
        throw StateError('Playback did not recover after short screen off');
      }
      await save('after-sleep.json', {
        'mpv': await stats(full: true),
        'surface': surface,
        'resumeWaitMs':
            resumeClock.elapsedMilliseconds - recoveryClock.elapsedMilliseconds,
        'recoveryMs': recoveryClock.elapsedMilliseconds,
        'emptyCopies': emptyCopies,
      });
    } else {
      for (var i = 0; i < seconds; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final sample = {'ms': clock.elapsedMilliseconds, ...await stats()};
        samples.add(sample);
        if (sample['pause'] != 'no' ||
            (samples.length > 2 &&
                sample['time-pos'] ==
                    samples[samples.length - 2]['time-pos'])) {
          await save('interrupted.json', {
            'samples': samples,
            'dropChanges': changes,
          });
          throw StateError('Timing run interrupted; not a zero-drop pass');
        }
      }
    }
    await active.pause();
    await save('measure.json', {
      'samples': samples,
      'dropChanges': changes,
      'final': await stats(full: true),
      'logs': logs,
      'pageError': (key.currentState as dynamic).error,
    });
    // Host reads PSS/thermal state only after timing has finished.
    await Future<void>.delayed(const Duration(seconds: 6));
    await native.unobserveProperty('frame-drop-count');
    runApp(const SizedBox());
    await active.stream.position.drain<void>().timeout(
      const Duration(seconds: 20),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await save('released.json', {'rssBytes': ProcessInfo.currentRss});
  } catch (error, stack) {
    await save('error.json', {
      'error': error.toString(),
      'stack': stack.toString(),
    });
  } finally {
    if (await captureGate.exists()) await captureGate.delete();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    runApp(const SizedBox());
    await Future<void>.delayed(const Duration(seconds: 1));
    await catalog.db.close();
    await root.delete(recursive: true);
    if (scenario['eglProbe'] == true) {
      for (final suffix in ['bin', 'tmp']) {
        final file = File('${eglProbe.parent.path}/konata-egl-probe.$suffix');
        if (await file.exists()) await file.delete();
      }
    }
    if (scenario['stageProbe'] == true && await stageDir.exists()) {
      await stageDir.delete(recursive: true);
    }
    if (scenario['queuedProbe'] == true) {
      for (final suffix in ['bin', 'tmp']) {
        final file = File(
          '${eglProbe.parent.path}/konata-queued-probe.$suffix',
        );
        if (await file.exists()) await file.delete();
      }
    }
    if (failureMode) {
      for (final file in [failureControl, failureEvents]) {
        if (await file.exists()) await file.delete();
      }
    }
    client.close(force: true);
    await SystemNavigator.pop();
  }
}

Element findButton(bool Function(IconButton) match) {
  Element? found;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is IconButton && match(widget)) found = element;
    if (found == null) element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildElements(visit);
  return found ?? (throw StateError('Playback action is not mounted'));
}

Future<void> tapButton(bool Function(IconButton) match) async {
  Element? element;
  var hidden = false;
  try {
    element = findButton(match);
  } on StateError {
    hidden = true;
  }
  element?.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is AnimatedOpacity && widget.opacity == 0) hidden = true;
    return true;
  });
  Future<void> tap(Offset position) async {
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: 42, position: position),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: 42, position: position),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  if (hidden) {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    await tap(
      Offset(
        view.physicalSize.width / view.devicePixelRatio / 2,
        view.physicalSize.height / view.devicePixelRatio / 2,
      ),
    );
    element = findButton(match);
  }
  // Physical touch and sensor following are covered by the user's device run.
  // Invoke the mounted action here to isolate fullscreen/state/native policy
  // from synthetic pointer routing through the Android platform view.
  final action = (element!.widget as IconButton).onPressed;
  if (action == null) throw StateError('Playback action is disabled');
  action();
  await Future<void>.delayed(const Duration(milliseconds: 500));
}
