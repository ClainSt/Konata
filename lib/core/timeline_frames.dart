import 'dart:typed_data';
import 'package:media_kit/media_kit.dart';

/// A separate, silent decoder; preview never seeks the playback player.
class TimelineFrames {
  TimelineFrames(this.source);
  final String source;
  Player? _decoder;
  Future<void> _tail = Future.value();
  final _cache = <int, Uint8List>{};
  int _generation = 0;
  bool _closed = false;
  Future<Uint8List?> frame(Duration position) async {
    final key = position.inMilliseconds;
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }
    final generation = ++_generation;
    Uint8List? result;
    _tail = _tail
        .then((_) async {
          if (_closed || generation != _generation) return;
          if (_decoder == null) {
            final decoder = Player(
              configuration: const PlayerConfiguration(vo: 'null'),
            );
            _decoder = decoder;
            final native = decoder.platform;
            if (native is! NativePlayer) return;
            await native.setProperty('vid', 'auto');
            await native.setProperty('aid', 'no');
            await native.setProperty('sid', 'no');
            await native.setProperty('vf', 'scale=320:-2');
            await decoder.open(Media(source), play: false);
          }
          final decoder = _decoder!;
          await decoder.seek(position);
          final native = decoder.platform as NativePlayer;
          for (var i = 0; i < 30 && !_closed; i++) {
            final seeking = await native.getProperty('seeking');
            final time = double.tryParse(await native.getProperty('time-pos'));
            if (seeking == 'no' &&
                time != null &&
                (time - position.inMilliseconds / 1000).abs() < 1) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          if (_closed || generation != _generation) return;
          result = await decoder.screenshot();
          if (result != null) {
            _cache[key] = result!;
            while (_cache.length > 24) {
              _cache.remove(_cache.keys.first);
            }
          }
        })
        .catchError((Object _) {
          /* Missing/unseekable frames are optional. */
        });
    await _tail;
    return result;
  }

  Future<void> dispose() async {
    _closed = true;
    _generation++;
    await _tail;
    await _decoder?.dispose();
    _cache.clear();
  }
}
