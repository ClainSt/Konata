import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/cloud_media_asset_presentation.dart';

void main() {
  test(
    'extra display removes release metadata but retains content and number',
    () {
      expect(
        CloudMediaAssetPresentation.cleanedExtraFilename({
          'name':
              '[SweetSub&VCB-Studio] 16bit Sensation [IV01][Ma10p_1080p][x265_flac][A1B2C3D4].mkv',
        }),
        '16bit Sensation IV01',
      );
      expect(
        CloudMediaAssetPresentation.cleanedExtraFilename({
          'name': '制作访谈 [导演篇] 02 (1080p HEVC AAC).mkv',
        }),
        '制作访谈 导演篇 02',
      );
      expect(
        CloudMediaAssetPresentation.cleanedExtraFilename({
          'name': '86 - 幕后记录 01.mkv',
        }),
        '86 - 幕后记录 01',
      );
    },
  );
}
