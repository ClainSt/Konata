import 'dart:typed_data';
import 'package:media_kit/media_kit.dart';

/// A separate, silent decoder; preview never seeks the playback player.
class TimelineFrames {
  TimelineFrames(this.source, {Player Function()? createDecoder})
    : _createDecoder = createDecoder ?? _newDecoder;
  final String source;
  final Player Function() _createDecoder;
  static Player _newDecoder() =>
      Player(configuration: const PlayerConfiguration(vo: 'null'));
  Player? _decoder;
  Future<void> _tail = Future.value();
  final _cache = <int, Uint8List>{};
  int _cacheBytes = 0;
  static const _maxCacheBytes = 8 * 1024 * 1024;
  int _generation = 0;
  bool _closed = false;
  Future<void>? _disposal;
  Future<Uint8List?> frame(Duration position) async {
    if (_closed) return null;
    final generation = ++_generation;
    final key = position.inMilliseconds;
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    Uint8List? result;
    _tail = _tail
        .then((_) async {
          if (_closed || generation != _generation) return;
          if (_decoder == null) {
            final decoder = _createDecoder();
            _decoder = decoder;
            final native = decoder.platform;
            if (native is! NativePlayer) return;
            for (final option in const {
              'vid': 'auto',
              'aid': 'no',
              'sid': 'no',
              'vf': 'scale=320:-2',
              'hr-seek': 'yes',
            }.entries) {
              if (_closed) return;
              await native.setProperty(option.key, option.value);
            }
            if (_closed) return;
            await decoder.open(Media(source), play: false);
          }
          if (_closed || generation != _generation) return;
          final decoder = _decoder!;
          final native = decoder.platform as NativePlayer;
          // open() queues loading; it does not wait for a decoded video frame.
          // Seeking before time-pos is available can be ignored by mpv.
          var ready = false;
          for (var i = 0; i < 100; i++) {
            if (_closed || generation != _generation) return;
            final time = double.tryParse(await native.getProperty('time-pos'));
            if (time != null && time.isFinite) {
              ready = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          if (!ready || _closed || generation != _generation) return;
          await decoder.seek(position);
          var reached = false;
          for (var i = 0; i < 100; i++) {
            if (_closed || generation != _generation) return;
            final seeking = await native.getProperty('seeking');
            final time = double.tryParse(await native.getProperty('time-pos'));
            if (seeking == 'no' &&
                time != null &&
                (time - position.inMilliseconds / 1000).abs() < 0.25) {
              reached = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          // A timeout must not label the previous frame as the requested one.
          if (!reached || _closed || generation != _generation) return;
          final image = await decoder.screenshot();
          if (_closed || generation != _generation) return;
          result = image;
          if (image != null && image.lengthInBytes <= _maxCacheBytes) {
            _cache[key] = image;
            _cacheBytes += image.lengthInBytes;
            while (_cache.length > 24 || _cacheBytes > _maxCacheBytes) {
              _cacheBytes -= _cache.remove(_cache.keys.first)!.lengthInBytes;
            }
          }
        })
        .catchError((Object _) {
          /* Missing/unseekable frames are optional. */
        });
    await _tail;
    return result;
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _closed = true;
    _generation++;
    _cache.clear();
    _cacheBytes = 0;
    final decoder = _decoder;
    _decoder = null;
    // Initiate native shutdown now, including when a frame is still pending.
    // media_kit serializes its native operations and owns final destruction.
    await Future.wait([_tail, if (decoder != null) decoder.dispose()]);
  }
}
