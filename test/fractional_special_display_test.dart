import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/cloud_media_asset_presentation.dart';

void main() {
  for (final number in ['11.5', '17.5', '18.5', '21.5']) {
    test('fractional special $number retains its number without metadata', () {
      final file = <String, Object?>{'category': 'extra',
        'name': '[UHA-WINGS&VCB-Studio] EIGHTY SIX [$number${number == '17.5' ? '(Visual Commentary)' : ''}][Ma10p_1080p][x265_flac].mkv'};
      expect(CloudMediaAssetPresentation.extraType(file), 'SP');
      expect(CloudMediaAssetPresentation.extraTitle(file), 'SP$number');
      expect(CloudMediaAssetPresentation.cleanedExtraFilename(file), contains(number));
    });
  }
}
