import 'dart:async';

import 'package:flutter/services.dart';

/// The playback page owns this bridge; silent preview decoders never request focus.
/// Interruptions pause video. Only an explicit playback action requests it again.
class AndroidAudioFocus {
  AndroidAudioFocus(Stream<bool> playing, this._pause) {
    _owner = this;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'loss' || !_active) return;
      _epoch++;
      _focused = false;
      _lastPlaying = false;
      await _pause();
      if (_active) await _channel.invokeMethod<void>('abandon');
    });
    _subscription = playing.listen(updatePlaying);
  }

  static const _channel = MethodChannel('ccplayer/audio_focus');
  static AndroidAudioFocus? _owner;
  final Future<void> Function() _pause;
  late final StreamSubscription<bool> _subscription;
  Future<void> _tail = Future.value();
  bool _focused = false, _closed = false;
  bool? _lastPlaying;
  int _epoch = 0;
  Future<void>? _disposal;
  bool get _active => !_closed && identical(_owner, this);

  // Native input.conf commands can bypass media_kit's Dart playing-state gate.
  // Coalesce both event sources without cancelling an identical pending grant.
  void updatePlaying(bool playing) {
    if (!_active || _lastPlaying == playing) return;
    _lastPlaying = playing;
    final epoch = ++_epoch;
    _tail = _tail
        .then((_) async {
          if (!_active || epoch != _epoch) return;
          if (!playing) {
            _focused = false;
            await _channel.invokeMethod<void>('abandon');
          } else if (!_focused) {
            final granted =
                await _channel.invokeMethod<bool>('request') == true;
            if (!_active || epoch != _epoch) {
              if (granted && identical(_owner, this)) {
                await _channel.invokeMethod<void>('abandon');
              }
              return;
            }
            _focused = granted;
            if (!granted) await _pause();
          }
        })
        .catchError((Object _) async {
          _focused = false;
          if (_active && playing && epoch == _epoch) await _pause();
        });
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _closed = true;
    _epoch++;
    if (identical(_owner, this)) _channel.setMethodCallHandler(null);
    await _subscription.cancel();
    await _tail;
    if (identical(_owner, this)) {
      _owner = null;
      await _channel.invokeMethod<void>('abandon');
    }
  }
}
