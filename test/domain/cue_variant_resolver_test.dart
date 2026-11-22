import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/domain/playback/cue_variant_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cue = MediaVariant(
    id: 'cue-1',
    workId: 'accel',
    sourceId: 'dav',
    relativePath: '加速世界/CDs/01/album.cue',
    fileName: 'album.cue',
    fileSize: 400,
    assetKind: AssetKind.cdAlbum,
  );
  const flac = MediaVariant(
    id: 'flac-1',
    workId: 'accel',
    sourceId: 'dav',
    relativePath: '加速世界/CDs/01/ドラマ CD.flac',
    fileName: 'ドラマ CD.flac',
    fileSize: 300000000,
    assetKind: AssetKind.cdAlbum,
  );
  test('外部播放器的 CUE 轨应指向 FILE 引用的物理 FLAC', () {
    const track = CueTrack(
      trackNumber: 1,
      title: 'Track 1',
      fileName: 'ドラマ CD.flac',
      startSeconds: 12,
    );
    expect(
      CueVariantResolver.resolve(
        cueVariant: cue,
        cueTrack: track,
        audioVariantsInDir: [flac],
        fallbackInitial: cue,
      )?.id,
      flac.id,
    );
  });

  test('CUE 中 Windows 反斜线文件路径按实际文件名匹配', () {
    const track = CueTrack(
      trackNumber: 1,
      title: 'Track 1',
      fileName: r'subfolder\\ドラマ CD.flac',
      startSeconds: 0,
    );
    expect(
      CueVariantResolver.resolve(
        cueVariant: cue,
        cueTrack: track,
        audioVariantsInDir: [flac],
        fallbackInitial: cue,
      )?.id,
      flac.id,
    );
  });

  test('不能把多份物理音频中无匹配的 CUE 指向错误的第一项', () {
    const extra = MediaVariant(
      id: 'flac-2',
      workId: 'accel',
      sourceId: 'dav',
      relativePath: '加速世界/CDs/01/another.flac',
      fileName: 'another.flac',
      fileSize: 10000,
      assetKind: AssetKind.cdAlbum,
    );
    const track = CueTrack(
      trackNumber: 1,
      title: 'Track',
      fileName: 'missing.flac',
      startSeconds: 0,
    );
    expect(
      CueVariantResolver.resolve(
        cueVariant: cue,
        cueTrack: track,
        audioVariantsInDir: [flac, extra],
        fallbackInitial: cue,
      ),
      isNull,
    );
  });

  test('同目录多整轨 FLAC 与同名 CUE 精确一一配对且识别 .cue 文件扩展名', () {
    const cd1Cue = MediaVariant(
      id: 'cd1-cue',
      workId: 'accel',
      sourceId: 'dav',
      relativePath: 'CDs/Drama/ドラマCD-1.cue',
      fileName: 'ドラマCD-1.cue',
      fileSize: 436,
      assetKind: AssetKind.cdAlbum,
    );
    const cd1Flac = MediaVariant(
      id: 'cd1-flac',
      workId: 'accel',
      sourceId: 'dav',
      relativePath: 'CDs/Drama/ドラマCD-1.flac',
      fileName: 'ドラマCD-1.flac',
      fileSize: 280000000,
      assetKind: AssetKind.cdAlbum,
    );
    const cd2Cue = MediaVariant(
      id: 'cd2-cue',
      workId: 'accel',
      sourceId: 'dav',
      relativePath: 'CDs/Drama/ドラマCD-2.cue',
      fileName: 'ドラマCD-2.cue',
      fileSize: 410,
      assetKind: AssetKind.cdAlbum,
    );
    const cd2Flac = MediaVariant(
      id: 'cd2-flac',
      workId: 'accel',
      sourceId: 'dav',
      relativePath: 'CDs/Drama/ドラマCD-2.flac',
      fileName: 'ドラマCD-2.flac',
      fileSize: 230000000,
      assetKind: AssetKind.cdAlbum,
    );

    expect(CueVariantResolver.isCueSheetFile(cd1Cue.fileName), isTrue);
    expect(CueVariantResolver.isCueSheetFile(cd1Flac.fileName), isFalse);
    expect(
      CueVariantResolver.matchCueVariantForAudio(
        audioVariant: cd1Flac,
        cueVariantsInDir: const [cd1Cue, cd2Cue],
        audioVariantsInDir: const [cd1Flac, cd2Flac],
      )?.id,
      equals('cd1-cue'),
    );
    expect(
      CueVariantResolver.matchCueVariantForAudio(
        audioVariant: cd2Flac,
        cueVariantsInDir: const [cd1Cue, cd2Cue],
        audioVariantsInDir: const [cd1Flac, cd2Flac],
      )?.id,
      equals('cd2-cue'),
    );
  });
}
