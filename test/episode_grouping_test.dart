import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/episode_grouping.dart';

void main() {
  Map<String, Object?> file(
    String id,
    int? episode, {
    int season = 1,
    int size = 100,
    String category = 'main',
    String? source,
  }) => {
    'id': id,
    'source_id': source ?? 'dav',
    'work_id': 'anime',
    'episode': episode,
    'season': season,
    'category': category,
    'name': '$id.mkv',
    'relative_path': 'anime/$id.mkv',
    'size': size,
  };
  test('two encodes for each of 13 episodes become exactly 13 cards', () {
    final all = <Map<String, Object?>>[];
    for (var n = 1; n <= 13; n++) {
      all.add(file('VCB-$n', n, size: 300));
      all.add(file('SweetSub-$n', n, size: 200));
    }
    final grouped = EpisodeGrouping.main(all);
    expect(grouped.length, 13);
    expect(grouped.every((group) => group.versions.length == 2), isTrue);
    expect(grouped.first.preferred({})['episode'], 1);
    expect(grouped.first.preferred({})['id'], 'VCB-1');
    // All 26 physical files still exist and can be selected.
    expect(grouped.expand((g) => g.versions).length, 26);
    expect(all.length, 26);
  });
  test('season and work separate episodes with the same number', () {
    final items = [
      file('first-1', 1),
      file('second-1', 1, season: 2),
      {...file('another-work', 1), 'work_id': 'else'},
      file('unindexed1', null),
      file('unindexed2', null),
      file('CM01', null, category: 'extra'),
    ];
    expect(EpisodeGrouping.main(items).length, 5);
  });
  test('resume picks in-progress version and preserves other file', () {
    final files = [file('a', 1, size: 900), file('b', 1, size: 200)];
    final group = EpisodeGrouping.main(files).single;
    final progress = {
      'b': <String, Object?>{
        'position_ms': 120000,
        'updated_at': '2026-11-04T10:00:00Z',
      },
    };
    expect(group.preferred(progress)['id'], 'b');
    expect(group.versions.length, 2);
  });
}
