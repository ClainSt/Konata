import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Owns only the Android output. Video continues to own touch controls,
/// wakelock and background pause; the same Player owns decoding and tracks.
class AndroidNativeVideo extends PlatformVideoController {
  AndroidNativeVideo(super.player, super.configuration);

  final ready = Completer<void>();
  Future<void> _pending = Future.value();
  Future<PlatformVideoController>? _initialization;
  Future<void>? _closing;
  MethodChannel? _channel;
  int _wid = 0;
  int _hdrPeak = 0;
  bool _closed = false;
  bool _notifiersDisposed = false;
  NativePlayer get _native => player.platform as NativePlayer;

  Future<void> _set(String key, String value) =>
      _native.setProperty(key, value, waitForInitialization: false);

  Future<PlatformVideoController> initialize() =>
      _initialization ??= _initialize();

  Future<PlatformVideoController> _initialize() async {
    await player.handle;
    if (_closed) return this;
    for (final entry in {
      'vo': 'null',
      'vid': 'auto',
      'gpu-api': 'opengl',
      'gpu-context': 'android',
      'opengl-es': 'yes',
      'egl-output-format': 'rgb10_a2',
      'sub-font-provider': 'none',
      'sub-scale-with-window': 'yes',
      'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1',
      if (!player.platform!.configuration.mpvRespectRenderingConfiguration)
        'hwdec': configuration.hwdec ?? 'auto-safe',
    }.entries) {
      if (_closed) return this;
      await _set(entry.key, entry.value);
    }
    // WatchPage closes the output before disposing Player. This callback also
    // covers callers that dispose the player directly.
    player.platform!.release.add(() async {
      await close();
    });
    return this;
  }

  Future<void> _update(Map<Object?, Object?>? state) {
    final operation = _pending.then((_) async {
      if (_closed) return;
      final next = (state?['wid'] as int?) ?? 0;
      final width = (state?['width'] as int?) ?? 0;
      final height = (state?['height'] as int?) ?? 0;
      final hdrPeak = (state?['hdrPeak'] as int?) ?? 0;
      if (next != 0 && (width <= 0 || height <= 0)) return;
      final previous = _wid;
      if (next != 0 && next == previous && hdrPeak == _hdrPeak) {
        // surfaceChanged also reports size changes on the existing surface.
        // Recreating the VO here unnecessarily restarts the video decoder.
        await _set('android-surface-size', '${width}x$height');
        rect.value = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
        return;
      }
      // Detach EGL before replacing/releasing a JNI global surface reference.
      await _set('vo', 'null');
      await _set('wid', '0');
      _wid = 0;
      if (previous != 0 && previous != next) {
        await _channel?.invokeMethod<void>('release', previous);
      }
      if (next == 0) return;
      // Native MPV pairs the actual PQ framebuffer space with rendering before
      // the first frame. Capability changes rebuild only this output surface.
      await _set('android-hdr-peak', '$hdrPeak');
      _hdrPeak = hdrPeak;
      await _set('android-surface-size', '${width}x$height');
      await _set('wid', '$next');
      await _set('vo', 'gpu');
      _wid = next;
      rect.value = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      if (!ready.isCompleted) ready.complete();
    });
    _pending = operation.catchError((Object error, StackTrace stack) {
      if (!ready.isCompleted) ready.completeError(error, stack);
    });
    return operation;
  }

  Widget buildSurface(BuildContext context) => PlatformViewLink(
    viewType: 'ccplayer/android_surface',
    surfaceFactory: (_, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    ),
    onCreatePlatformView: (params) {
      final channel = _channel = MethodChannel(
        'ccplayer/android_surface/${params.id}',
      );
      channel.setMethodCallHandler((call) async {
        if (call.method == 'changed') {
          await _update(Map<Object?, Object?>.from(call.arguments as Map));
        } else if (call.method == 'lost') {
          await _update(null);
        }
      });
      return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'ccplayer/android_surface',
          layoutDirection: TextDirection.ltr,
        )
        ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
        ..create();
    },
  );

  Future<Map<Object?, Object?>> capture({
    bool pixels = false,
    bool packed10 = false,
  }) async =>
      await _channel?.invokeMapMethod<Object?, Object?>(
        pixels ? 'captureFrame' : 'capturePrecision',
        {
          'pq': await _native.getProperty('video-target-params/gamma') == 'pq',
          'packed10': packed10,
        },
      ) ??
      {};

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      await _initialization;
    } catch (_) {
      // Initialization reports its error to the owner; still clean up output.
    }
    try {
      try {
        await _pending;
        // NativePlayer.dispose stops playback before invoking release callbacks.
        // Its public property API rejects calls once disposed is set.
        if (!_native.disposed) {
          await _set('vo', 'null');
          await _set('wid', '0');
        }
      } catch (_) {
        // Only retry before native references can have been released. A failed
        // releaseAll may have partially completed and is not safe to replay.
        _closing = null;
        rethrow;
      }
      await _channel?.invokeMethod<void>('releaseAll');
      _wid = 0;
    } finally {
      _channel?.setMethodCallHandler(null);
      if (!_notifiersDisposed) {
        _notifiersDisposed = true;
        super.dispose();
      }
    }
  }

  @override
  Future<void> setSize({int? width, int? height}) async {}
}
