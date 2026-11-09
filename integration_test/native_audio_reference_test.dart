import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

// Offline decoding, optionally comparing the stereo downmix with a reference.
// This does not stand in for audio routing, speaker playback or listening tests.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'export bounded PCM from the packaged native player',
    (tester) async {
      const tag = String.fromEnvironment('AUDIO_TAG');
      const downmixOnly = bool.fromEnvironment('AUDIO_DOWNMIX_ONLY');
      expect(tag, isNotEmpty);
      MediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('konata-pcm-');
      final client = HttpClient();
      const endpoint = 'http://127.0.0.1:18769';
      Future<void> save(String name, List<int> bytes) async {
        final request = await client.postUrl(Uri.parse('$endpoint/$tag-$name'));
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        expect(response.statusCode, 201);
        await response.drain<void>();
      }

      try {
        for (final (name, fixture, aid, channels)
            in downmixOnly
                ? [('dtshd51-stereo', 'audio-dtshd.mkv', '1', 2)]
                : [
                    ('truehd', 'audio-truehd.mkv', '1', 2),
                    ('dtshd51', 'audio-dtshd.mkv', '1', 6),
                    ('dtshd2', 'audio-dtshd.mkv', '2', 2),
                    ('alac', 'audio-alac.mp4', '1', 2),
                  ]) {
          final file = File('${root.path}/$fixture');
          if (!await file.exists()) {
            final response = await (await client.getUrl(
              Uri.parse('$endpoint/$fixture'),
            )).close();
            expect(response.statusCode, 200);
            await response.pipe(file.openWrite());
          }
          final pcm = File('${root.path}/$name.pcm');
          final player = Player(
            configuration: const PlayerConfiguration(libass: false),
          );
          final native = player.platform as NativePlayer;
          final audioEvents = <String>[];
          final subscription = player.stream.audioParams.listen(
            (event) => audioEvents.add(event.toString()),
          );
          final record = <String, Object?>{};
          try {
            await player.handle;
            for (final entry in {
              'vo': 'null',
              'vid': 'no',
              'sid': 'no',
              'aid': aid,
              'audio-display': 'no',
              'ao': 'pcm',
              'ao-pcm-file': pcm.path,
              'ao-pcm-waveheader': 'no',
              'audio-format': 's32',
              'audio-channels': downmixOnly ? 'stereo' : 'auto',
              'volume': '100',
              'replaygain': 'no',
              'gapless-audio': 'no',
              'length': '10',
              'keep-open': 'no',
            }.entries) {
              await native.setProperty(entry.key, entry.value);
            }
            record['mpv-version'] = await native.getProperty('mpv-version');
            record['ffmpeg-version'] = await native.getProperty(
              'ffmpeg-version',
            );
            expect(record['mpv-version'], 'mpv v0.42.0');
            expect(record['ffmpeg-version'], '9.0.2');
            await player.open(Media(file.path));
            final clock = Stopwatch()..start();
            while (!player.state.completed &&
                clock.elapsed < const Duration(seconds: 30)) {
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 20));
              final params = await native.getProperty('audio-out-params');
              if (params.isNotEmpty) record['audio-out-params'] = params;
            }
            expect(player.state.completed, isTrue);
            record['elapsedMs'] = clock.elapsedMilliseconds;
            record['audioEvents'] = audioEvents;
            await player.stop();
          } finally {
            await subscription.cancel();
            await player.dispose();
          }
          final bytes = await pcm.readAsBytes();
          expect(bytes.length, greaterThan(48000 * channels * 4 * 8));
          expect(bytes.length % (channels * 4), 0);
          record['bytes'] = bytes.length;
          record['expectedChannels'] = channels;
          if (downmixOnly) {
            final response = await (await client.getUrl(
              Uri.parse('$endpoint/downmix-reference.pcm'),
            )).close();
            expect(response.statusCode, 200);
            final reference = <int>[];
            await for (final chunk in response) {
              reference.addAll(chunk);
            }
            expect(bytes.length, reference.length);
            final a = ByteData.sublistView(bytes);
            final b = ByteData.sublistView(Uint8List.fromList(reference));
            var maxDifference = 0;
            double sumSquares = 0;
            for (var i = 0; i < bytes.length; i += 4) {
              final delta =
                  (a.getInt32(i, Endian.little) - b.getInt32(i, Endian.little))
                      .abs();
              maxDifference = math.max(maxDifference, delta);
              sumSquares += delta * delta;
            }
            record['sha256'] = sha256.convert(bytes).toString();
            record['referenceSha256'] = sha256.convert(reference).toString();
            record['maxDifferenceS32'] = maxDifference;
            record['rmsDifferenceS32'] = math.sqrt(
              sumSquares / (bytes.length / 4),
            );
            final params =
                jsonDecode(record['audio-out-params'] as String) as Map;
            expect(params['channel-count'], 2);
            expect(maxDifference, lessThanOrEqualTo(512));
          } else {
            await save('$name.pcm', bytes);
          }
          await save('$name.json', utf8.encode(jsonEncode(record)));
        }
      } finally {
        client.close(force: true);
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
