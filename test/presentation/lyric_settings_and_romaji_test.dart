import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/lyrics_resolver.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/domain/lyrics/lyric_candidate.dart';
import 'package:konata/domain/lyrics/lyric_search_query.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/infrastructure/lyrics/lrclib_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/lyric_http_transport.dart';
import 'package:konata/infrastructure/lyrics/netease_lyric_provider.dart';
import 'package:konata/infrastructure/lyrics/qqmusic_lyric_provider.dart';
import 'package:konata/infrastructure/network/metered_network_detector.dart';
import 'package:konata/presentation/audio/immersive_audio_sub_widgets.dart';
import 'package:konata/presentation/settings/settings_lyrics_card.dart';
import 'package:konata/presentation/theme/konata_theme.dart';

void main() {
  group('S2 提供者与开关联动（QQ 音乐 / LRCLIB get / 网易云 rv=1）', () {
    test('QQ 音乐 provider 解析 DoSearchForQQMusicMobile 与 GetPlayLyricInfo Base64 双语', () async {
      final rawLrc = base64Encode(
        utf8.encode(
          '[00:00.00]unravel - TK\n'
          '[00:00.50]词：TK\n'
          '[00:01.00]教えて 教えてよ &apos;その仕組み&apos;を\n'
          '[00:08.00]僕の中に誰がいるの？\n'
          '[00:15.00]壊れた 壊れたよ この世界で',
        ),
      );
      final rawTrans = base64Encode(
        utf8.encode(
          '[00:00.00]//\n'
          '[00:00.50]//\n'
          '[00:01.00]告诉我 告诉我 其中的构造\n'
          '[00:08.00]在我体内究竟有谁\n'
          '[00:15.00]崩坏了 崩坏了 在这个世界',
        ),
      );

      final transport = ClientLyricTransport(
        MockClient((req) async {
          expect(req.method, equals('POST'));
          expect(req.headers['Referer'], equals(LyricLookupConfig.qqMusicReferer));
          final body = jsonDecode(req.body) as Map;
          final method = body['req']?['method'];
          if (method == 'DoSearchForQQMusicMobile') {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'req': {
                    'code': 0,
                    'data': {
                      'body': {
                        'item_song': [
                          {
                            'mid': '001midTEST',
                            'id': 123456,
                            'name': 'unravel',
                            'singer': [
                              {'name': 'TK from 凛として時雨'},
                            ],
                            'album': {'name': 'unravel'},
                            'interval': 240,
                          },
                        ],
                      },
                    },
                  },
                }),
              ),
              200,
            );
          }
          if (method == 'GetPlayLyricInfo') {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'req': {
                    'code': 0,
                    'data': {'lyric': rawLrc, 'trans': rawTrans},
                  },
                }),
              ),
              200,
            );
          }
          return http.Response('{}', 404);
        }),
      );

      final provider = QqMusicLyricProvider(transport);
      final query = LyricSearchQuery(
        title: 'unravel',
        artist: 'TK from 凛として時雨',
        durationSeconds: 240,
      );
      final hits = await provider.searchSongs(query);
      expect(hits, hasLength(1));
      expect(hits.first.mid, equals('001midTEST'));

      final cand = await provider.fetchLyric(hits.first);
      expect(cand, isNotNull);
      expect(cand!.source, equals(LyricSource.qq));
      expect(cand.hasTranslation, isTrue);
      final doc = LrcParser.parseText(cand.lrcContent);
      expect(doc.lines, hasLength(3));
      expect(doc.lines.first.primaryText, equals("教えて 教えてよ 'その仕組み'を"));
      expect(doc.lines.first.secondaryLines, equals(['告诉我 告诉我 其中的构造']));
    });

    test('LRCLIB 优先 /api/get 精确时长匹配，404 自动回退 /api/search，并保留纯文本候选', () async {
      final paths = <String>[];
      final transport = ClientLyricTransport(
        MockClient((req) async {
          paths.add(req.url.path);
          if (req.url.path == '/api/get') {
            return http.Response('Not Found', 404);
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode([
                {
                  'id': 99,
                  'trackName': 'Plain Song',
                  'artistName': 'Artist',
                  'duration': 200.0,
                  'syncedLyrics': '',
                  'plainLyrics': '第一行纯文本歌词\n第二行纯文本歌词\n第三行纯文本歌词',
                },
              ]),
            ),
            200,
          );
        }),
      );

      final provider = LrclibLyricProvider(transport);
      final results = await provider.fetchCandidates(
        LyricSearchQuery(title: 'Plain Song', artist: 'Artist', durationSeconds: 200.4),
      );
      expect(paths, equals(['/api/get', '/api/search']));
      expect(results, hasLength(1));
      expect(results.first.isSynced, isFalse);
      expect(results.first.plainLyrics, contains('第一行纯文本歌词'));
    });

    test('网易云 fetchLyric 携带 rv=1 参数并产出独立 roma: 罗马音轨道', () async {
      Uri? capturedUri;
      final transport = ClientLyricTransport(
        MockClient((req) async {
          capturedUri = req.url;
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'lrc': {
                  'lyric':
                      '[00:01.00]無敵の笑顔\n[00:05.00]秘密ミステリアス\n[00:09.00]彼女のエリア',
                },
                'tlyric': {
                  'lyric': '[00:01.00]无敌的笑容\n[00:05.00]神秘的秘密\n[00:09.00]她的领域',
                },
                'romalrc': {
                  'lyric':
                      '[00:01.00]mu te ki no e ga o\n[00:05.00]hi mi tsu mi su te ri a su\n[00:09.00]ka no jo no e ri a',
                },
              }),
            ),
            200,
          );
        }),
      );

      final provider = NeteaseLyricProvider(transport);
      final cand = await provider.fetchLyric(
        const NeteaseSongHit(id: '100', title: 'アイドル', artist: 'YOASOBI'),
      );
      expect(capturedUri?.queryParameters['rv'], equals('1'));
      expect(cand, isNotNull);
      expect(cand!.hasTranslation, isTrue);
      expect(cand.hasRomaji, isTrue);
      final doc = LrcParser.parseText(cand.lrcContent);
      expect(doc.lines.first.secondaryLines, equals(['无敌的笑容']));
      expect(doc.lines.first.romajiText, equals('mu te ki no e ga o'));
    });

    test('lyricsResolverProvider 默认不请求 QQ 音乐，开启 QQ 开关后参与并行竞速', () async {
      SharedPreferences.setMockInitialValues({});
      var qqRequestCount = 0;
      final mockHttp = MockClient((req) async {
        if (req.url.host == 'u.y.qq.com') {
          qqRequestCount++;
          final body = jsonDecode(req.body) as Map;
          if (body['req']?['method'] == 'DoSearchForQQMusicMobile') {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'req': {
                    'data': {
                      'body': {
                        'item_song': [
                          {
                            'mid': 'qq_only_mid',
                            'id': 77,
                            'name': 'QQ独占曲',
                            'singer': [
                              {'name': '测试歌手'},
                            ],
                            'interval': 210,
                          },
                        ],
                      },
                    },
                  },
                }),
              ),
              200,
            );
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'req': {
                  'data': {
                    'lyric': base64Encode(
                      utf8.encode(
                        '[00:01.00]QQ第一句\n[00:05.00]QQ第二句\n[00:09.00]QQ第三句',
                      ),
                    ),
                    'trans': '',
                  },
                },
              }),
            ),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final container = ProviderContainer(
        overrides: [
          playbackPreferencesProvider.overrideWith(
            () => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          lyricHttpTransportProvider.overrideWith(
            (ref) async => ClientLyricTransport(mockHttp),
          ),
          meteredNetworkDetectorProvider.overrideWithValue(
            MeteredNetworkDetector(overrideProbe: () async => false),
          ),
          lyricCacheRepositoryProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      final resolver = container.read(lyricsResolverProvider);
      final req = LyricResolveRequest(
        trackKey: 'local::qq_test.flac|100|',
        query: LyricSearchQuery(
          title: 'QQ独占曲',
          artist: '测试歌手',
          durationSeconds: 210,
        ),
      );

      // 默认 QQ 关闭：绝不请求 u.y.qq.com。
      final r1 = await resolver.resolve(req);
      expect(qqRequestCount, equals(0));
      expect(r1.lrcDocument, isNull);

      // 开启 QQ 开关后：参与竞速并成功命中。
      await container
          .read(playbackPreferencesProvider.notifier)
          .setLyricSourceQqEnabled(true, disclaimerAccepted: true);
      final r2 = await resolver.resolve(req);
      expect(qqRequestCount, greaterThan(0));
      expect(r2.source, equals(LyricSource.qq));
      expect(r2.lrcDocument?.lines.first.primaryText, equals('QQ第一句'));
    });
  });

  group('设置面板 QQ 免责弹窗与罗马音独立显隐组件测试', () {
    testWidgets('QQ 音乐默认关闭，首次开启弹毛玻璃免责框；取消保持关闭，确认后开启且不再重复弹窗', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          playbackPreferencesProvider.overrideWith(
            () => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(child: SettingsLyricsCard()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 初始默认值检查。
      final initPrefs = container.read(playbackPreferencesProvider);
      expect(initPrefs.lyricSourceNeteaseEnabled, isTrue);
      expect(initPrefs.lyricSourceAmllEnabled, isTrue);
      expect(initPrefs.lyricSourceLrclibEnabled, isTrue);
      expect(initPrefs.lyricSourceQqEnabled, isFalse);
      expect(initPrefs.qqLyricDisclaimerAccepted, isFalse);
      expect(initPrefs.showLyricRomaji, isFalse);

      // 首次点击 QQ 开关 -> 弹出免责弹窗 -> 点击“暂不开启”保持关闭。
      final qqSwitch = find.byKey(
        const ValueKey('settings_lyric_source_qq_switch'),
      );
      await tester.tap(qqSwitch);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('qq_lyric_disclaimer_glass_dialog')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('qq_lyric_disclaimer_cancel')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(playbackPreferencesProvider).lyricSourceQqEnabled,
        isFalse,
      );

      // 再次点击 QQ 开关 -> 弹出免责弹窗 -> 点击“了解并开启”正式启用。
      await tester.tap(qqSwitch);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('qq_lyric_disclaimer_confirm')),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(playbackPreferencesProvider).lyricSourceQqEnabled,
        isTrue,
      );
      expect(
        container.read(playbackPreferencesProvider).qqLyricDisclaimerAccepted,
        isTrue,
      );

      // 关闭后再开启不再重复弹出免责提示。
      await tester.tap(qqSwitch);
      await tester.pumpAndSettle();
      expect(
        container.read(playbackPreferencesProvider).lyricSourceQqEnabled,
        isFalse,
      );
      await tester.tap(qqSwitch);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('qq_lyric_disclaimer_glass_dialog')),
        findsNothing,
      );
      expect(
        container.read(playbackPreferencesProvider).lyricSourceQqEnabled,
        isTrue,
      );
    });

    testWidgets('ImmersiveLyricLineLeaf 默认隐藏罗马音，开启开关后独立展示且不混入中文译文', (
      tester,
    ) async {
      const line = LrcCueLine(
        startSeconds: 1.0,
        endSeconds: 5.0,
        primaryText: '無敵の笑顔',
        secondaryLines: ['无敌的笑容'],
        romajiText: 'mu te ki no e ga o',
      );
      final container = ProviderContainer(
        overrides: [
          playbackPreferencesProvider.overrideWith(
            () => PlaybackPreferencesNotifier(enablePersistence: false),
          ),
          audioPlaybackProvider.overrideWith(
            () => AudioPlaybackNotifier(
              initialState: const AudioPlaybackState(activeLyricIndex: -1),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: ImmersiveLyricLineLeaf(
                index: 0,
                line: line,
                compact: false,
                userScrolling: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('無敵の笑顔'), findsOneWidget);
      expect(find.text('无敌的笑容'), findsOneWidget);
      expect(find.text('mu te ki no e ga o'), findsNothing);

      // 开启罗马音注音开关后即时渲染独立罗马音节点。
      await container
          .read(playbackPreferencesProvider.notifier)
          .setShowLyricRomaji(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lyric_line_romaji_0')), findsOneWidget);
      expect(find.text('mu te ki no e ga o'), findsOneWidget);
      expect(find.text('无敌的笑容'), findsOneWidget);
    });
  });
}
