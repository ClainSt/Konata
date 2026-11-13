import 'package:ccplayer/core/detail_metadata.dart';
import 'package:ccplayer/core/optional_people.dart';
import 'package:ccplayer/ui/people_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'credits prioritize directors and producers, then photos within each role',
    () {
      final cards = OptionalPeopleSession.creditsCards(
        {
          'crew': [
            {
              'id': 1,
              'name': 'Camera',
              'job': 'Director of Photography',
              'profile_path': '/camera.jpg',
            },
            {'id': 2, 'name': 'Director no photo', 'job': 'Director'},
            {'id': 3, 'name': 'Producer no photo', 'job': 'Producer'},
            {
              'id': 4,
              'name': 'Director with photo',
              'job': 'Director',
              'profile_path': '/director.jpg',
            },
            {
              'id': 5,
              'name': 'Producer with photo',
              'job': 'Executive Producer',
              'profile_path': '/producer.jpg',
            },
            {'id': 6, 'name': 'Writer no photo', 'job': 'Writer'},
            {
              'id': 7,
              'name': 'Writer with photo',
              'job': 'Screenplay',
              'profile_path': '/writer.jpg',
            },
          ],
        },
        {},
        'zh-Hant',
      );
      expect(cards.map((card) => card['title']), [
        'Director with photo',
        'Director no photo',
        'Producer with photo',
        'Producer no photo',
        'Writer with photo',
        'Writer no photo',
        'Camera',
      ]);
      final cached = OptionalPeopleSession.creditsCards({}, {
        'crew': [
          {
            'name': '攝影甲',
            'roles': ['攝影'],
            'image': '/camera.jpg',
          },
          {
            'name': '製片甲',
            'roles': ['製片人'],
            'image': '/producer.jpg',
          },
          {
            'name': '導演甲',
            'roles': ['導演'],
          },
        ],
      }, 'zh-Hant');
      expect(cached.map((card) => card['title']), ['導演甲', '製片甲', '攝影甲']);
    },
  );
  for (final type in ['movie', 'tv']) {
    test(
      '$type core metadata does not request or interpret optional credits',
      () async {
        final service = DetailMetadataService(
          tmdbRequest: (path, params) async {
            if (path != '/$type/42') return {};
            expect(params.containsKey('append_to_response'), isFalse);
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
        expect(result['cast'], isNull);
        expect(result['crew'], isNull);
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
                const PeopleCards(cards: []),
                PeopleCards(
                  imageBuilder: (_) => const SizedBox(width: 80, height: 80),
                  cards: List.generate(
                    12,
                    (i) => {
                      'title': '演员$i',
                      'subtitle': '很长的饰演角色 / 第二个角色',
                      'section': '演员',
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

  testWidgets('voice-actor mode places the actor above the character', (
    tester,
  ) async {
    Future<void> render(bool voice) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeopleCards(
            showVoiceActors: voice,
            cards: const [
              {'title': '角色名称', 'subtitle': '声优名称'},
              {'title': '未列声优的角色', 'subtitle': ''},
            ],
            imageBuilder: (_) => const SizedBox(width: 80, height: 80),
          ),
        ),
      ),
    );
    await render(false);
    final character = find.text('角色名称');
    final actor = find.text('声优名称');
    expect(
      tester.getTopLeft(character).dy,
      lessThan(tester.getTopLeft(actor).dy),
    );
    await render(true);
    expect(
      tester.getTopLeft(actor).dy,
      lessThan(tester.getTopLeft(character).dy),
    );
    expect(find.text('未列声优的角色'), findsOneWidget);
  });
}
