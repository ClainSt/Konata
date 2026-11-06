import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/ui/people_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final type in ['movie', 'tv']) {
    test(
      '$type credits preserve actor roles and selected production jobs',
      () async {
        final service = DetailMetadataService(
          tmdbRequest: (path, params) async {
            if (path != '/$type/42') return {};
            expect(
              params['append_to_response'],
              type == 'movie' ? 'credits' : 'aggregate_credits',
            );
            return {
              'genres': [
                {'id': 18, 'name': '剧情'},
              ],
              'backdrop_path': '/scene.jpg',
              type == 'movie' ? 'credits' : 'aggregate_credits': {
                'cast': [
                  {
                    'id': 1,
                    'name': '演员甲',
                    'character': '角色甲',
                    'roles': [
                      {'character': '角色乙'},
                    ],
                  },
                  {'id': 1, 'name': '演员甲', 'character': '角色丙'},
                  {'id': 2, 'name': '演员乙'},
                  {'id': 3, 'name': ''},
                ],
                'crew': [
                  {'id': 4, 'name': '导演甲', 'job': 'Director'},
                  {
                    'id': 4,
                    'name': '导演甲',
                    'jobs': [
                      {'job': 'Writer'},
                    ],
                  },
                  {'id': 5, 'name': '制片甲', 'job': 'Producer'},
                  {'id': 6, 'name': '其他人员', 'job': 'Unverified job'},
                ],
              },
            };
          },
        );
        final result = await service.fetch({'tmdb_id': 42, 'tmdb_type': type});
        expect(result['isAnimation'], false);
        final cast = result['cast'] as List;
        expect(cast.length, 2);
        expect(cast.first['roles'], ['角色甲', '角色乙', '角色丙']);
        expect(cast.last['roles'], isEmpty);
        expect((result['crew'] as List).first['roles'], ['导演', '编剧']);
        expect((result['crew'] as List).length, 2);
        service.close();
      },
    );
  }

  test(
    'animation credits do not replace Bangumi character presentation',
    () async {
      final service = DetailMetadataService(
        tmdbRequest: (_, _) async => {
          'genres': [
            {'id': 16, 'name': '动画'},
          ],
          'backdrop_path': '/scene.jpg',
          'credits': {
            'cast': [
              {'id': 1, 'name': '声优'},
            ],
          },
        },
      );
      final result = await service.fetch({'tmdb_id': 42, 'tmdb_type': 'movie'});
      expect(result['isAnimation'], true);
      expect(result['cast'], isNull);
      service.close();
    },
  );

  test(
    'missing optional credits retain overview without invented people',
    () async {
      final service = DetailMetadataService(
        tmdbRequest: (_, _) async => {
          'overview': '作品简介',
          'backdrop_path': '/scene.jpg',
        },
      );
      final result = await service.fetch({'tmdb_id': 42, 'tmdb_type': 'movie'});
      expect(result['overview'], '作品简介');
      expect(result['cast'], isNull);
      expect(result['crew'], isNull);
      service.close();
    },
  );

  testWidgets(
    'people cards scroll at narrow width with large text; empty sections hide',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                const PeopleSection(title: '制作人员', people: []),
                PeopleSection(
                  title: '演员',
                  people: List.generate(
                    12,
                    (i) => {
                      'name': '演员$i',
                      'roles': ['很长的饰演角色', '第二个角色'],
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('制作人员'), findsNothing);
      expect(find.text('演员'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(-1100, 0));
      await tester.pumpAndSettle();
      expect(find.text('演员0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
