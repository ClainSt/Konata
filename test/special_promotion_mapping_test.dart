import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/cloud_media_asset_presentation.dart';
import 'package:ccplayer/core/episode_metadata.dart';

void main() {
  const episode = <String, dynamic>{
    'name': 'OVA story', 'episode_number': 1,
  };
  Map<String, Object?> asset(String name) => {
    'name': name, 'relative_path': 'Bonus/$name', 'category': 'extra',
  };

  for (final name in [
    '[LoliHouse] Sasaki to Miyano - OVA CM [BDRip 1080p HEVC-10bit FLAC].mkv',
    'Show OAD PV01.mkv', 'Show OVA01 [CM02].mkv',
    'Show OVA PV_01.mkv', 'Show OAD TVCM.mkv',
  ]) {
    test('promotion cannot consume story episode: $name', () {
      final file = asset(name);
      expect(CloudMediaAssetPresentation.mapSpecialEpisodes(
        assets: [file], specials: [episode],
      ), isEmpty);
      expect(CloudMediaAssetPresentation.specialEpisode(file, {'0': [episode]}), isNull);
    });
  }
  for (final name in ['Show OVA01.mkv', 'Show OAD.mkv', 'Acme OVA01.mkv']) {
    test('ordinary special remains matchable: $name', () {
      final file = asset(name);
      expect(CloudMediaAssetPresentation.mapSpecialEpisodes(
        assets: [file], specials: [episode],
      )[file['relative_path']], episode);
    });
  }
  test('explicit manual promotion mapping is retained', () {
    final file = {...asset('Show OVA CM.mkv'),
      'manual_mapping': true, 'season': 0, 'episode': 1};
    expect(EpisodeMetadata.lookup({}, {'specials': {'1': episode}}, file), episode);
  });
}
