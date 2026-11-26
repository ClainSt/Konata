import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:feature_player_audio/feature_player_audio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_fakes.dart';

Future<Uint8List> _poster() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff242445), ui.BlendMode.src);
  // 上方合成头部与暖色面部，下方高频文字模拟版权信息。
  canvas.drawRect(
    const ui.Rect.fromLTWH(12, 3, 48, 26),
    ui.Paint()..color = const ui.Color(0xff111111),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(20, 12, 32, 23),
    ui.Paint()..color = const ui.Color(0xfff2c6a0),
  );
  for (var y = 87; y < 108; y += 3) {
    canvas.drawRect(
      ui.Rect.fromLTWH(2, y.toDouble(), 68, 1),
      ui.Paint()..color = const ui.Color(0xffffffff),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(72, 108);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

AudioQueueItem _item(
  String id, {
  String? posterPath = '/test-poster.jpg',
  String? relativePath,
}) {
  final source = makeTestSource();
  final path = relativePath ?? 'CD/$id.cue';
  final variant = makeTestCdVariant(id: id, relativePath: path, fileSize: 4096);
  return AudioQueueItem(
    itemId: id,
    workId: variant.workId,
    sourceId: source.id,
    variantId: variant.id,
    title: id,
    artist: '',
    album: '测试专辑',
    albumKey: 'album',
    fileName: variant.fileName,
    relativePath: path,
    source: source,
    variant: variant,
    posterFallback: posterPath,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('竖版作品海报实际解码后防切头裁为方形且同作品切歌共用衍生字节', () async {
    final poster = await _poster();
    final original = Uint8List.fromList(poster);
    final alignment = await SmartCoverFraming.computeAlignmentFromBytes(
      poster,
      isPosterFallback: true,
    );
    expect(alignment.y, lessThan(-0.6));
    final requests = <String>[];
    final assets = AudioPlaybackAssets(
      posterLoader: (path, owner) async {
        requests.add('$path:$owner');
        return poster;
      },
    );
    final gateway = FakeGatewayFactory({});
    final first = await assets.resolveTrackAuxiliary(
      item: _item('one'),
      gatewayFactory: gateway,
      probeLyrics: false,
    );
    final second = await assets.resolveTrackAuxiliary(
      item: _item('two'),
      gatewayFactory: gateway,
      probeLyrics: false,
    );
    expect(first.cover, isA<MemoryAudioCover>());
    expect(first.coverCacheKey, startsWith('poster-square::'));
    expect(second.coverCacheKey, first.coverCacheKey);
    expect(second.coverBytes, same(first.coverBytes));
    expect(requests, hasLength(2));
    expect(poster, orderedEquals(original));
    final codec = await ui.instantiateImageCodec(first.coverBytes!);
    final image = (await codec.getNextFrame()).image;
    try {
      expect(image.width, 72);
      expect(image.height, 72);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      const head = (5 * 72 + 36) * 4;
      const face = (20 * 72 + 36) * 4;
      expect(pixels.getUint8(head), 0x11);
      expect(pixels.getUint8(face), 0xf2);
    } finally {
      image.dispose();
      codec.dispose();
    }
  });

  test('有专辑目录封面时不请求海报，完全无图才显示唱片占位', () async {
    final poster = await _poster();
    var calls = 0;
    final assets = AudioPlaybackAssets(
      posterLoader: (_, _) async {
        calls++;
        return poster;
      },
    );
    final gateway = FakeGatewayFactory({
      'CD/song.flac': Uint8List(4096),
      'CD/cover.png': poster,
    });
    final dedicated = await assets.resolveTrackAuxiliary(
      item: _item('song', relativePath: 'CD/song.flac'),
      gatewayFactory: gateway,
      probeLyrics: false,
    );
    expect(dedicated.cover, isA<MemoryAudioCover>());
    expect(dedicated.coverCacheKey, startsWith('cd_cover::'));
    expect(dedicated.coverBytes, orderedEquals(poster));
    expect(calls, 0);
    final empty = await assets.resolveTrackAuxiliary(
      item: _item('empty', posterPath: null),
      gatewayFactory: FakeGatewayFactory({}),
      probeLyrics: false,
    );
    expect(empty.cover, isA<EmptyAudioCover>());
    expect(calls, 0);
  });
}
