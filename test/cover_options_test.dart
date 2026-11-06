import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ccplayer/core/cover_options.dart';
import 'package:ccplayer/core/metadata.dart';

void main() {
  test(
    'cover editor discovers TMDB and Bangumi options without dandanplay',
    () async {
      final oldToken = Metadata.token, oldMode = Metadata.authMode;
      Metadata.token = 'token-testing';
      Metadata.authMode = 'token';
      final requested = <String>[];
      final client = MockClient((req) async {
        requested.add(req.url.path);
        if (req.url.path.contains('/3/tv/')) {
          expect(req.headers['Authorization'], 'Bearer token-testing');
          return http.Response(
            jsonEncode({'poster_path': '/tmdb-latest.jpg'}),
            200,
          );
        }
        if (req.url.path.contains('/v0/subjects/')) {
          return http.Response(
            jsonEncode({
              'images': {
                'large': 'https://lain.bgm.tv/bangumi.jpg',
                'common': 'https://lain.bgm.tv/smaller.jpg',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final service = CoverOptionService(client: client);
      try {
        final covers = await service.fetch({
          'tmdb_id': 7123,
          'tmdb_type': 'tv',
          'bangumi_id': 1234,
          'poster': 'https://images.tmdb.org/t/p/w500/old.jpg',
        });
        expect(covers.tmdb, 'https://images.tmdb.org/t/p/original/tmdb-latest.jpg');
        expect(covers.bangumi, 'https://lain.bgm.tv/bangumi.jpg');
        expect(requested, contains('/3/tv/7123'));
        expect(requested, contains('/v0/subjects/1234'));
        expect(requested.where((p) => p.contains('dandan')), isEmpty);
      } finally {
        service.close();
        client.close();
        Metadata.token = oldToken;
        Metadata.authMode = oldMode;
      }
    },
  );
  test(
    'source candidates fallback to stored URLs without provider IDs',
    () async {
      final service = CoverOptionService();
      try {
        final covers = await service.fetch({
          'poster': 'https://images.tmdb.org/t/p/w500/old.jpg',
          'poster_fallback': 'https://lain.bgm.tv/stored.jpg',
        });
        expect(covers.tmdb, 'https://images.tmdb.org/t/p/w500/old.jpg');
        expect(covers.bangumi, 'https://lain.bgm.tv/stored.jpg');
        expect(CoverOptionService.validUrl('javascript:alert(1)'), isNull);
      } finally {
        service.close();
      }
    },
  );
}
