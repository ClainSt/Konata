import 'dart:async';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

/// Coordinates MPV options and the host swapchain without calling blocking MPV
/// APIs on the render thread. Presentation stays gated until both agree.
class WindowsHdrOutput {
  WindowsHdrOutput(this.native, this.host, this.onError);
  final NativePlayer native;
  final int host;
  final void Function(Object) onError;
  static const _channel = MethodChannel('ccplayer/native_video');
  static final _outputs = <int, WindowsHdrOutput>{};
  final _original = <String, String>{};
  Future<void> _pending = Future.value();
  Future<void>? _initialization;
  Future<void>? _closing;
  bool _closed = false;
  bool _dirty = false;
  bool _observed = false;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (_closed) return;
    for (final key in ['target-prim', 'target-trc', 'target-peak']) {
      _original[key] = await native.getProperty(key);
      if (_closed) return;
    }
    _outputs[host] = this;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'displayChanged') _outputs[call.arguments]?.refresh();
    });
    await native.observeProperty('video-params/gamma', (_) async {
      refresh();
    }, waitForInitialization: false);
    _observed = true;
    if (_closed) return;
    await refresh();
  }

  Future<void> refresh() {
    if (_closed) return Future.value();
    _dirty = true;
    _pending = _pending.then((_) async {
      while (_dirty && !_closed) {
        _dirty = false;
        try {
          await _apply();
        } catch (error) {
          if (!_closed && !_dirty) onError(error);
        }
      }
    });
    return _pending;
  }

  Future<void> _apply() async {
    final display = await _channel.invokeMapMethod<String, Object?>(
      'beginColor',
      [host],
    );
    if (_closed || display == null) return;
    final epoch = display['epoch'] as int;
    final peak = display['peak'] as int;
    var sourcePq = false;
    try {
      sourcePq = await native.getProperty('video-params/gamma') == 'pq';
    } catch (_) {
      // Before loadfile there is no video format yet.
    }
    final trc = _original['target-trc']!;
    final prim = _original['target-prim']!;
    var hdr =
        sourcePq &&
        display['hdrActive'] == true &&
        peak >= 100 &&
        peak <= 10000 &&
        (trc == 'auto' || trc == 'pq') &&
        (prim == 'auto' || prim == 'bt.2020');
    if (!hdr && (trc == 'pq' || trc == 'hlg')) {
      throw StateError(
        'The configured HDR target is unavailable on this display.',
      );
    }
    Future<void> targets(bool pq) async {
      for (final entry in {
        'target-prim': pq ? 'bt.2020' : _original['target-prim']!,
        'target-trc': pq ? 'pq' : _original['target-trc']!,
        'target-peak': pq && _original['target-peak'] == 'auto'
            ? '$peak'
            : _original['target-peak']!,
      }.entries) {
        if (_closed) return;
        await native.setProperty(entry.key, entry.value);
      }
    }

    await targets(hdr);
    if (_closed) return;
    try {
      await _channel.invokeMethod<void>('commitColor', [host, hdr, epoch]);
    } on PlatformException {
      if (_dirty || _closed) return;
      // A rejected PQ swapchain must return to the previous valid SDR encoding
      // before any pixels become visible. Explicit user HDR is never rewritten.
      if (!hdr || trc != 'auto') rethrow;
      hdr = false;
      await targets(false);
      final fallback = await _channel.invokeMapMethod<String, Object?>(
        'beginColor',
        [host],
      );
      if (_closed || _dirty) return;
      await _channel.invokeMethod<void>('commitColor', [
        host,
        hdr,
        fallback!['epoch'],
      ]);
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      await _initialization;
    } catch (_) {
      // initialize() reports its failure to the owner; cleanup must still run.
    }
    _outputs.remove(host);
    if (_outputs.isEmpty) _channel.setMethodCallHandler(null);
    if (_observed && !native.disposed) {
      await native.unobserveProperty(
        'video-params/gamma',
        waitForInitialization: false,
      );
    }
    await _pending;
    if (!native.disposed && _original.length == 3) {
      // A recreated renderer must snapshot the user's original preferences,
      // not the temporary HDR targets from the preceding renderer.
      await _channel.invokeMethod<void>('beginColor', [host]);
      for (final entry in _original.entries) {
        await native.setProperty(entry.key, entry.value);
      }
    }
  }
}
