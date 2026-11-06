import 'dart:convert';
import 'dart:io';
import 'package:ccplayer/core/bangumi_episode_mapping.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/watch_event_origin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const key = 'tmdb:tv:42:s1:e1';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cat = Catalog.instance;
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ccplayer-bgm-map-');
    await cat.initialize(dataDirectory: dir);
    await cat.db.insert('works', {
      'id': 'w',
      'title': 'Test',
      'tmdb_id': 42,
      'tmdb_type': 'tv',
    });
    for (final id in ['a', 'b']) {
      await cat.db.insert('assets', {
        'id': id,
        'source_id': 's',
        'work_id': 'w',
        'relative_path': '$id.mkv',
        'name': '$id.mkv',
        'category': 'main',
        'season': 1,
        'episode': id == 'a' ? 1 : 2,
      });
      await cat.logicalEpisodes.confirm(
        id,
        id == 'a' ? key : 'tmdb:tv:42:s1:e2',
      );
    }
  });
  tearDown(() async {
    await cat.db.close();
    await dir.delete(recursive: true);
  });
  Map<String, Object?> episode({int type = 0, int subject = 100}) => {
    'id': 999,
    'subject_id': subject,
    'type': type,
    'sort': 13.5,
    'name': 'different numbering',
  };
  Future<int> bind(
    BangumiEpisodeVerifier verifier, {
    String asset = 'a',
    String logical = key,
    int? previous,
  }) async => BangumiEpisodeMapping(cat.db).confirm(
    verifier: verifier,
    assetId: asset,
    expectedKey: logical,
    expectedRevision: await WatchEventOrigin.revision(cat.db, asset),
    subjectId: 100,
    episodeId: 999,
    expectedType: 0,
    expectedPreviousId: previous,
  );

  test(
    'explicit mapping tolerates different numbering and revalidates identity',
    () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://api.bgm.tv/v0/episodes/999');
        expect(request.followRedirects, isFalse);
        expect(request.headers.containsKey('Authorization'), isFalse);
        return http.Response(jsonEncode(episode()), 200);
      });
      final verifier = BangumiEpisodeVerifier(client);
      final store = BangumiEpisodeMapping(cat.db);
      final id = await bind(verifier);
      expect((await store.current(key))!['episode_sort'], 13.5);
      expect((await store.current(key))!['episode_id'], 999);
      await expectLater(bind(verifier), throwsStateError); // stale head
      await expectLater(
        bind(verifier, asset: 'b', logical: 'tmdb:tv:42:s1:e2'),
        throwsStateError,
      );
      await store.revoke(key, id);
      expect(await store.current(key), isNull);
      final tombstone = await store.headId(key);
      await bind(verifier, previous: tombstone);
      await cat.logicalEpisodes.revoke('a');
      await cat.logicalEpisodes.confirm('a', key);
      expect(await store.current(key), isNull);
      client.close();
    },
  );

  test(
    'wrong parent, specials, redirects, auth/rate errors and malformed JSON never persist',
    () async {
      for (final response in [
        http.Response(jsonEncode(episode(subject: 101)), 200),
        http.Response(jsonEncode(episode(type: 1)), 200),
        http.Response('bad json', 200),
        http.Response('{}', 302),
        http.Response('{}', 401),
        http.Response('{}', 429),
        http.Response('{}', 500),
      ]) {
        final client = MockClient((_) async => response);
        await expectLater(
          bind(BangumiEpisodeVerifier(client)),
          throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
        );
        expect(await cat.db.query('bangumi_episode_mappings'), isEmpty);
        client.close();
      }
    },
  );

  test(
    'identity edits during network verification abort persistence',
    () async {
      final client = MockClient((_) async {
        await cat.db.update(
          'assets',
          {'episode': 2},
          where: 'id=?',
          whereArgs: ['a'],
        );
        await cat.db.update(
          'assets',
          {'episode': 1},
          where: 'id=?',
          whereArgs: ['a'],
        );
        return http.Response(jsonEncode(episode()), 200);
      });
      await expectLater(bind(BangumiEpisodeVerifier(client)), throwsStateError);
      expect(await cat.db.query('bangumi_episode_mappings'), isEmpty);
      client.close();
    },
  );
}
