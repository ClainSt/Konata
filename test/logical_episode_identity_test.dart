import 'package:ccplayer/core/logical_episode_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const work = <String, Object?>{
    'id': 'device-one-work',
    'tmdb_type': 'tv',
    'tmdb_id': 100565,
    'title': '86',
  };

  test('same verified episode across sources and encodes has one key', () {
    final first = LogicalEpisodeIdentity.forAsset(
      work: work,
      asset: {
        'id': 'a1',
        'source_id': 'nas',
        'relative_path': '86/01.mkv',
        'category': 'main',
        'season': 1,
        'episode': 1,
      },
    );
    final second = LogicalEpisodeIdentity.forAsset(
      work: {...work, 'id': 'other-device-work', 'title': 'EIGHTY-SIX'},
      asset: {
        'id': 'a2',
        'source_id': 'webdav',
        'relative_path': 'another/BD/01[x265].mkv',
        'category': 'main',
        'season': 1,
        'episode': 1,
      },
    );
    expect(first, 'tmdb:tv:100565:s1:e1');
    expect(second, first);
  });

  test('season and episode remain distinct including verified season zero', () {
    String? key(int season, int episode) => LogicalEpisodeIdentity.forAsset(
      work: work,
      asset: {'category': 'main', 'season': season, 'episode': episode},
    );
    expect(key(0, 1), 'tmdb:tv:100565:s0:e1');
    expect(key(1, 1), isNot(key(0, 1)));
    expect(key(1, 1), isNot(key(1, 2)));
  });

  test('unverified identity, unnumbered content, extras and films are excluded', () {
    String? key(Map<String, Object?> w, Map<String, Object?> a) =>
        LogicalEpisodeIdentity.forAsset(work: w, asset: a);
    const episode = <String, Object?>{
      'category': 'main', 'season': 1, 'episode': 3,
    };
    expect(key({...work, 'tmdb_id': null}, episode), isNull);
    expect(key({...work, 'tmdb_type': 'movie'}, episode), isNull);
    expect(key(work, {...episode, 'category': 'extra'}), isNull);
    expect(key(work, {...episode, 'season': null}), isNull);
    expect(key(work, {...episode, 'episode': null}), isNull);
    expect(key(work, {...episode, 'episode': 0}), isNull);
    expect(key(work, {...episode, 'season': -1}), isNull);
    expect(key(work, {...episode, 'episode': 3.5}), isNull);
  });
}
