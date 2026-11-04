import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/cloud_media_asset_presentation.dart';
import 'package:ccplayer/core/anime_detail_metadata.dart';

void main() {
  test(
    'Personal supplementary classification keeps CM MENU NCOP NCED PV and SP',
    () {
      for (final name in [
        '[VCB-Studio] Shomin Sample [CM01][x265].mkv',
        'MENU01.mkv',
        'NCOP.mkv',
        'NCED.mkv',
        'PV02.mkv',
        'SP03.mkv',
        'OVA01.mkv',
      ]) {
        final file = '动画-单作品/Example/SPs/$name';
        expect(Catalog.isExtra(file), isTrue, reason: name);
        final type = CloudMediaAssetPresentation.extraType({
          'name': name,
          'relative_path': file,
        });
        expect(type, isNotEmpty);
      }
      expect(Catalog.isExtra('动画-单作品/Example/[01].mkv'), isFalse);
    },
  );
  test('Personal anime tag priority, dedupe, and 8 tag limit', () {
    const work = <String, Object?>{
      'metadata_json':
          '{"tags":["2023","搞笑","TV","穿越","原创","TV","动画","幻想"],"production_companies":[{"name":"st.SILVER"}]}',
    };
    final tags = AnimeDetailMetadata.tags(work);
    expect(tags.first, 'TV');
    expect(tags[1], 'st.SILVER');
    expect(tags[2], '原创');
    expect(tags, contains('搞笑'));
    expect(tags, hasLength(lessThanOrEqualTo(8)));
    expect(tags, hasLength(tags.toSet().length));
    expect(tags, isNot(contains('2023')));
  });
}
