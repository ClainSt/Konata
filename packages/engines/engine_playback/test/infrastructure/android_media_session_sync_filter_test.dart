import 'dart:typed_data';

import 'package:engine_playback/engine_playback.dart';
import 'package:test/test.dart';

void main() {
  test('封面按当前资源键失效，切回原曲重新发送且同键进度不重复发送', () {
    final filter = AndroidMediaSessionSyncFilter();
    final bytesA = Uint8List.fromList([1, 2, 3]);
    final bytesB = Uint8List.fromList([4, 5, 6]);
    final now = DateTime.utc(2026, 1, 1);
    Map<String, Object?>? send(
      String track,
      String key,
      Uint8List? bytes, {
      bool force = false,
    }) => filter.buildPayloadIfChanged(
      trackId: track,
      title: track,
      artist: '',
      album: '',
      durationSeconds: 60,
      positionSeconds: 1,
      isPlaying: true,
      coverKey: key,
      coverBytes: bytes,
      forcePositionSync: force,
      nowOverride: now,
    );

    expect(send('A', 'cover-A', bytesA)?['coverBytes'], bytesA);
    expect(send('A', 'cover-A', bytesA), isNull);
    expect(
      send('A', 'cover-A', null, force: true)?.containsKey('coverBytes'),
      isFalse,
    );
    expect(send('B', 'cover-B', null)?['coverKey'], 'cover-B');
    expect(send('A', 'cover-A', bytesA)?['coverBytes'], bytesA);
    expect(send('B', 'cover-B', null)?.containsKey('coverBytes'), isFalse);
    expect(send('B', 'cover-B', bytesB)?['coverBytes'], bytesB);
    expect(send('C', '', null)?['coverKey'], '');
    expect(send('B', 'cover-B', bytesB)?['coverBytes'], bytesB);
    expect(filter.markStopped(), isTrue);
    expect(send('B', 'cover-B', bytesB)?['coverBytes'], bytesB);
  });
}
