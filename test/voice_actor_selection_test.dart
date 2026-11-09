import 'package:ccplayer/core/optional_people.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final actors = <Map<String, dynamic>>[
    {'id': 1, 'name': 'English dub', 'language': 'en'},
    {'id': 2, 'name': '日本声优', 'short_summary': '日本女性声优。'},
    {'id': 3, 'name': '中文配音', 'short_summary': '中国男性配音演员。'},
    {'id': 4, 'name': '另一位日语声优', 'language': 'ja'},
  ];
  test(
    'one original-language actor is selected independent of UI language',
    () {
      expect(OptionalPeopleSession.selectActor(actors, 'ja')?['id'], 2);
      expect(OptionalPeopleSession.selectActor(actors, 'zh')?['id'], 3);
      expect(OptionalPeopleSession.selectActor(actors, 'en')?['id'], 1);
      expect(OptionalPeopleSession.selectActor(actors, 'ko'), isNull);
    },
  );
  test(
    'unknown language preserves source order without guessing from names',
    () {
      expect(OptionalPeopleSession.selectActor(actors, null)?['id'], 1);
      expect(
        OptionalPeopleSession.selectActor([
          {'name': '中文译名'},
        ], 'ja')?['name'],
        '中文译名',
      );
      expect(
        OptionalPeopleSession.originalLanguage({'original_language': 'ja-JP'}),
        'ja',
      );
      expect(
        OptionalPeopleSession.originalLanguage({
          'origin_country': ['CN'],
        }),
        'zh',
      );
      expect(
        OptionalPeopleSession.originalLanguage({
          'origin_tags': ['科幻', '日本'],
        }),
        'ja',
      );
    },
  );
}
