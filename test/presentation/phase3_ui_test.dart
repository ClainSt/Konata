import 'dart:convert';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/providers/source_actions_provider.dart';
import 'package:ccplayer/application/providers/theme_providers.dart';
import 'package:ccplayer/composition/windows_composition_root.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/repositories/file_system_gateway.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/players/desktop_external_player_store.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:ccplayer/presentation/detail/variant_picker_dialog.dart';
import 'package:ccplayer/presentation/detail/work_detail_page.dart';
import 'package:ccplayer/presentation/history/playback_history_page.dart';
import 'package:ccplayer/presentation/library/library_page.dart';
import 'package:ccplayer/presentation/library/review_dialog.dart';
import 'package:ccplayer/presentation/settings/settings_about_panel.dart';
import 'package:ccplayer/presentation/settings/settings_appearance_panel.dart';
import 'package:ccplayer/presentation/settings/settings_external_tools_panel.dart';
import 'package:ccplayer/presentation/settings/settings_page.dart';
import 'package:ccplayer/presentation/settings/settings_players_panel.dart';
import 'package:ccplayer/presentation/shell/desktop_shell.dart';
import 'package:ccplayer/presentation/shell/top_nav_bar.dart';
import 'package:ccplayer/presentation/shell/window_controls.dart';
import 'package:ccplayer/presentation/sources/source_editor_dialog.dart';
import 'package:ccplayer/presentation/sources/source_folder_picker_dialog.dart';
import 'package:ccplayer/presentation/sources/sources_page.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_glass_dialog.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_surface_card.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_toast.dart';

// 1x1 透明 PNG 测试字节
final Uint8List _transparentPng = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Widget _wrapApp(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: [
      ...WindowsCompositionRoot.providerOverrides(),
      tmdbImageLoaderProvider.overrideWithValue(
        (_, {targetWidth, imageSize}) async => _transparentPng,
      ),
      ...overrides,
    ],
    child: Consumer(
      builder: (context, ref, _) {
        final mode = ref.watch(themeModeProvider);
        return MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: KonataTheme.lightTheme(),
          darkTheme: KonataTheme.darkTheme(),
          themeMode: mode,
          home: child,
        );
      },
    ),
  );
}

void main() {
  group('Phase 3 UI 与数据补强测试', () {
    test(
      'TmdbService.getWorkDetail 优先提取 zh -> ja -> en -> null 透明 PNG logoPath',
      () async {
        final mockClient = MockClient((request) async {
          expect(
            request.url.queryParameters['append_to_response'],
            contains('images'),
          );
          expect(
            request.url.queryParameters['include_image_language'],
            'zh,ja,en,null',
          );
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'id': 209867,
                'name': '葬送的芙莉莲',
                'vote_average': 8.9,
                'images': {
                  'logos': [
                    {
                      'iso_639_1': 'ja',
                      'file_path': '/ja_logo.png',
                      'vote_average': 9.0,
                    },
                    {
                      'iso_639_1': 'zh',
                      'file_path': '/zh_logo.png',
                      'vote_average': 5.0,
                    },
                  ],
                },
              }),
            ),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        });

        final service = TmdbService(
          httpClient: TmdbHttpClient(
            config: const TmdbNetworkConfig(credential: 'v3_test'),
            scheduler: PriorityHttpScheduler(),
            httpClient: mockClient,
          ),
        );
        final detail = await service.getWorkDetail(209867, TmdbMediaType.tv);
        expect(detail?.logoPath, '/zh_logo.png');
        expect(detail?.voteAverage, 8.9);
      },
    );

    testWidgets('顶部搜索框平滑展开与收起，并实时过滤海报墙', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertWork(
        const Work(
          id: 'w1',
          title: '葬送的芙莉莲',
          year: 2023,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w2',
          title: '轻音少女',
          year: 2009,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          const DesktopShell(),
          overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      // 验证极简无框顶栏无待复核按钮，待复核位于媒体库标题同行最右侧（0 时显示弱化「待复核」）
      expect(
        find.descendant(of: find.byType(TopNavBar), matching: find.text('待复核')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(LibraryPage),
          matching: find.text('待复核'),
        ),
        findsNothing,
      );
      expect(find.text('待复核 · 0'), findsNothing);
      expect(find.text('全部作品'), findsOneWidget);
      expect(find.text('2 部'), findsOneWidget);
      expect(find.text('葬送的芙莉莲'), findsAtLeastNWidgets(1));
      expect(find.text('轻音少女'), findsAtLeastNWidgets(1));

      // 验证「待复核」可点击弹出居中宽幅毛玻璃弹窗 ReviewDialog / KonataGlassDialog，无硬 Divider
      showReviewDialog(tester.element(find.byType(LibraryPage))).ignore();
      await tester.pumpAndSettle();
      expect(find.byType(ReviewDialog), findsOneWidget);
      expect(find.byType(KonataGlassDialog), findsOneWidget);
      expect(find.text('当前没有待复核的作品'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(KonataGlassDialog),
          matching: find.byType(Divider),
        ),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(ReviewDialog),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pumpAndSettle();

      // 点击放大镜图标展开搜索框并输入过滤词
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '芙莉莲');
      await tester.pumpAndSettle();

      expect(find.text('葬送的芙莉莲'), findsAtLeastNWidgets(1));
      expect(find.text('轻音少女'), findsNothing);

      // 按 Esc 收起搜索框并恢复全部作品
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('轻音少女'), findsAtLeastNWidgets(1));

      // 切换到「媒体源」页验证：无冗余副标题，空态仅右上角唯一添加按钮，点击弹出毛玻璃弹窗
      await tester.tap(find.text('媒体源'));
      await tester.pumpAndSettle();
      expect(find.text('媒体源管理'), findsOneWidget);
      expect(find.textContaining('支持本地磁盘'), findsNothing);
      expect(find.text('尚未配置任何媒体源'), findsOneWidget);
      expect(find.text('添加媒体源'), findsOneWidget);
      expect(find.text('立即添加媒体源'), findsNothing);
      await tester.tap(find.text('添加媒体源'));
      await tester.pumpAndSettle();
      expect(find.byType(KonataGlassDialog), findsOneWidget);
    });

    testWidgets('待复核与未命中作品从海报墙与全部作品计数严格隔离，点击忽略复核后立即入库', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertWork(
        const Work(
          id: 'w_ok',
          title: '已确认入库番剧',
          year: 2024,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_review',
          title: '未确认待复核新番',
          year: 2025,
          scrapeStatus: ScrapeStatus.needsReview,
          reviewReason: 'confidence_below_threshold',
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w_unmatched',
          title: '未命中未知作品',
          year: 2025,
          scrapeStatus: ScrapeStatus.unmatched,
          reviewReason: 'no_tmdb_match',
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          const DesktopShell(),
          overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('全部作品'), findsOneWidget);
      expect(find.text('1 部'), findsOneWidget);
      expect(find.text('待复核 · 2'), findsOneWidget);
      expect(find.text('已确认入库番剧'), findsAtLeastNWidgets(1));
      expect(find.text('未确认待复核新番'), findsNothing);
      expect(find.text('未命中未知作品'), findsNothing);

      // 打开「待复核 · 2」抽屉，点击第一条「忽略复核」
      await tester.tap(find.text('待复核 · 2'));
      await tester.pumpAndSettle();
      expect(find.text('未确认待复核新番'), findsOneWidget);
      await tester.tap(find.text('忽略复核').first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(ReviewDialog),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 部'), findsOneWidget);
      expect(find.text('待复核 · 1'), findsOneWidget);
      expect(find.text('未确认待复核新番'), findsAtLeastNWidgets(1));
      expect(find.text('未命中未知作品'), findsNothing);
    });

    testWidgets('空库时全部作品隐藏数字 0，并验证亮/暗模式悬浮毛玻璃待复核侧栏正常渲染', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await tester.pumpWidget(
        _wrapApp(
          const DesktopShell(),
          overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      // 空库：全部作品右侧不显示数字 0，右侧胶囊显示弱化「待复核」
      expect(find.text('全部作品'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.textContaining('·  0'), findsNothing);
      expect(find.text('待复核'), findsNothing);

      // 切换亮色模式后点击待复核，确认 ReviewDialog / KonataGlassDialog 正常渲染
      await tester.tap(find.byIcon(Icons.light_mode_outlined));
      await tester.pumpAndSettle();
      showReviewDialog(tester.element(find.byType(LibraryPage))).ignore();
      await tester.pumpAndSettle();
      expect(find.byType(ReviewDialog), findsOneWidget);
      expect(find.byType(KonataGlassDialog), findsOneWidget);
      expect(find.text('当前没有待复核的作品'), findsOneWidget);
    });

    testWidgets('详情页默认收起剧集抽屉，点击正片剧集展开，有播放记录时主按钮切换为继续播放', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertMediaSource(
        const MediaSource(
          id: 's1',
          kind: MediaSourceKind.local,
          label: '本地',
          location: r'D:\Anime',
        ),
      );
      await repo.upsertWork(
        const Work(
          id: 'w1',
          title: '葬送的芙莉莲',
          originalTitle: '葬送のフリーレン',
          year: 2023,
          voteAverage: 8.9,
          overview: '勇者一行打倒魔王之后的故事。',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep2',
          workId: 'w1',
          seasonNumber: 1,
          episodeNumber: 2,
          title: '没必要魔法',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v1',
          workId: 'w1',
          episodeId: 'ep2',
          sourceId: 's1',
          relativePath: 'Frieren/[VCB-Studio] Frieren [02].mkv',
          fileName: '[VCB-Studio] Frieren [02].mkv',
          fileSize: 1024,
          releaseGroup: 'VCB-Studio',
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'rec1',
          workId: 'w1',
          episodeId: 'ep2',
          variantId: 'v1',
          seasonNumber: 1,
          episodeNumber: 2,
          episodeTitle: '没必要魔法',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 14, 21, 0),
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          const WorkDetailPage(workId: 'w1'),
          overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      // 默认收起剧集抽屉：仅显示简洁主按钮「继续播放」、左侧正片/特典与右侧单枚齿轮，隐藏翻页键与折叠箭头
      expect(find.text('继续播放'), findsOneWidget);
      expect(find.textContaining('02 · 没必要魔法'), findsNothing);
      expect(find.textContaining('S01E'), findsNothing);
      expect(find.text('[VCB-Studio] Frieren [02].mkv'), findsNothing);
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
      expect(find.byIcon(Icons.settings_rounded), findsOneWidget);

      // 点击 正片 (1) 展开悬浮剧集条，右侧平滑显现 ⊞ / ⌄ 控制胶囊，且不再保留左右翻页箭头
      await tester.tap(find.text('正片 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('[VCB-Studio] Frieren [02].mkv'), findsOneWidget);
      expect(find.text('02 · 没必要魔法'), findsOneWidget);
      expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

      // 点击收起按钮一键折叠剧集缩略图条，恢复仅保留齿轮
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      await tester.pumpAndSettle();
      expect(find.text('[VCB-Studio] Frieren [02].mkv'), findsNothing);
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
      expect(find.byIcon(Icons.settings_rounded), findsOneWidget);
    });

    testWidgets('多版本选播弹窗正确渲染压制组、字幕组与编码胶囊徽章', (tester) async {
      await tester.pumpWidget(
        _wrapApp(
          Scaffold(
            body: VariantPickerDialog(
              episode: const Episode(
                id: 'ep1',
                workId: 'w1',
                seasonNumber: 1,
                episodeNumber: 1,
                title: '冒险的终点',
              ),
              variants: const [
                MediaVariant(
                  id: 'v1',
                  workId: 'w1',
                  episodeId: 'ep1',
                  sourceId: 's1',
                  relativePath: 'a.mkv',
                  fileName:
                      '[VCB-Studio] Frieren [01][Ma10p_1080p][x265_flac].mkv',
                  fileSize: 1000,
                  releaseGroup: 'VCB-Studio',
                  subtitleGroup: 'SweetSub',
                  videoCodec: 'HEVC',
                  bitDepth: '10bit',
                  resolution: '1080p',
                  audioCodec: 'FLAC',
                  externalSubtitles: ['a.sc.ass'],
                ),
                MediaVariant(
                  id: 'v2',
                  workId: 'w1',
                  episodeId: 'ep1',
                  sourceId: 's1',
                  relativePath: 'b.mkv',
                  fileName: '[ANK-Raws] Frieren [01].mkv',
                  fileSize: 900,
                  releaseGroup: 'ANK-Raws',
                ),
              ],
              sourcesById: const {
                's1': MediaSource(
                  id: 's1',
                  kind: MediaSourceKind.smb,
                  label: 'NAS',
                  location: 'smb://192.168.1.2/Anime',
                ),
              },
              players: const [],
              onPlay: (_, _, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('压制: VCB-Studio'), findsOneWidget);
      expect(find.text('字幕: SweetSub (1)'), findsOneWidget);
      expect(find.text('HEVC · 10bit · 1080p'), findsOneWidget);
      expect(find.text('音频: FLAC'), findsOneWidget);
      expect(find.text('压制: ANK-Raws'), findsOneWidget);
    });

    testWidgets('设置页双栏切换、TMDB 帮助弹窗、关于页声明与亮暗模式切换', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await tester.pumpWidget(
        _wrapApp(
          const Scaffold(body: SettingsPage()),
          overrides: [
            konataDatabaseProvider.overrideWithValue(db),
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 默认进入「外观」，点击切换到「浅色模式」与「云母」材质
      expect(find.text('主题模式'), findsOneWidget);
      expect(find.text('窗口材质'), findsOneWidget);
      await tester.tap(find.text('浅色模式'));
      await tester.pumpAndSettle();
      final lightContext = tester.element(find.text('外观').last);
      expect(Theme.of(lightContext).brightness, Brightness.light);
      await tester.tap(find.text('云母'));
      await tester.pumpAndSettle();
      expect(find.textContaining('柔和融合系统壁纸主色'), findsOneWidget);

      // 切换到「刮削与网络」并验证官方/备用自动回退设置卡、代理模式及「如何获取TMDB API」
      await tester.tap(find.text('刮削与网络'));
      await tester.pumpAndSettle();
      expect(find.text('TMDB 服务'), findsOneWidget);
      expect(find.text('Bangumi 服务'), findsOneWidget);
      expect(
        find.text('官方标准地址 · https://api.themoviedb.org/3'),
        findsOneWidget,
      );
      expect(find.text('官方标准地址 · https://api.bgm.tv/v0'), findsOneWidget);
      expect(find.text('API 连接测试'), findsNWidgets(2));
      expect(find.text('图片服务器连接测试'), findsNWidgets(2));
      expect(find.text('直连 + 内置 DoH'), findsNothing);
      expect(find.text('保存网络配置'), findsNothing);
      expect(find.text('如何获取TMDB API'), findsOneWidget);
      await tester.tap(find.text('如何获取TMDB API'));
      await tester.pumpAndSettle();
      expect(find.text('如何获取 TMDB API 密钥'), findsOneWidget);
      expect(find.text('一键复制英文模板'), findsOneWidget);
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();

      // 拆分为独立一级菜单「播放器」与「外部调用」，原合并菜单不再存在；并移除核心版本区块
      expect(find.text('播放与音画还原'), findsNothing);
      await tester.tap(find.text('播放器'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPlayersPanel), findsOneWidget);
      expect(find.text('内置核心与默认路由'), findsNothing);
      expect(find.text('视频渲染与看番体验'), findsOneWidget);
      expect(find.text('无损音频与着色器链路'), findsOneWidget);

      await tester.tap(find.text('外部调用'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsExternalToolsPanel), findsOneWidget);
      expect(find.text('保存外部调用配置'), findsNothing);
      await tester.enterText(
        find.descendant(
          of: find.byType(SettingsExternalToolsPanel),
          matching: find.byType(TextField),
        ).first,
        r'C:\Tools\mpv\mpv.exe',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      final savedPlayers = await DesktopExternalPlayerStore(
        db,
      ).getExternalPlayers();
      expect(
        savedPlayers.any((p) => p.executablePath == r'C:\Tools\mpv\mpv.exe'),
        isTrue,
      );

      // 切换到「关于」，验证真实图标、版本 1.0.0、日志开关、导出日志与 GitHub Octocat / TMDB 声明
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      expect(find.text('Konata'), findsOneWidget);
      expect(find.text('版本 1.0.0'), findsOneWidget);
      expect(find.text('版本 2.0.0'), findsNothing);
      expect(find.text('K'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              w.image is AssetImage &&
              (w.image as AssetImage).assetName ==
                  'assets/icons/konata_icon.png',
        ),
        findsOneWidget,
      );
      expect(find.text('详细调试日志'), findsOneWidget);
      expect(find.text('导出最近异常日志'), findsOneWidget);
      expect(find.text('ClainSt/Konata'), findsOneWidget);
      expect(find.text('https://github.com/ClainSt/Konata'), findsOneWidget);
      expect(find.text('TMDB'), findsAtLeastNWidgets(1));
      expect(
        find.textContaining('https://www.themoviedb.org/'),
        findsOneWidget,
      );
    });

    testWidgets('WindowControls 随原生窗口最大化与还原事件同步图标状态', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: const Scaffold(body: Center(child: WindowControls())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
      expect(find.byIcon(Icons.filter_none_rounded), findsNothing);

      final controlsState = tester.state<WindowControlsState>(
        find.byType(WindowControls),
      );
      controlsState.handleWindowEvent(const WindowMaximizedEvent(windowId: 1));
      await tester.pump();

      expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);
      expect(find.byIcon(Icons.crop_square_rounded), findsNothing);

      controlsState.handleWindowEvent(const WindowRestoredEvent(windowId: 1));
      await tester.pump();

      expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
      expect(find.byIcon(Icons.filter_none_rounded), findsNothing);
    });

    testWidgets('播放记录空态隐藏 0 计数', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await tester.pumpWidget(
        _wrapApp(
          const Scaffold(body: PlaybackHistoryPage()),
          overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('播放记录'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('播放记录时间轴统一展示 [集号] · [单集标题] 与特典短标题且不出现 S01E01', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertWork(
        const Work(
          id: 'w_hist_1',
          title: '动物朋友',
          tmdbMediaType: TmdbMediaType.tv,
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'rec_main',
          workId: 'w_hist_1',
          episodeId: 'ep1',
          variantId: 'v1',
          seasonNumber: 1,
          episodeNumber: 1,
          episodeTitle: '动物园GO!',
          sourceType: MediaSourceKind.webdav,
          playedAt: DateTime(2026, 11, 15, 10, 0),
          positionSeconds: 180,
          durationSeconds: 1440,
        ),
      );
      await repo.recordPlayback(
        PlaybackRecord(
          id: 'rec_extra',
          workId: 'w_hist_1',
          episodeId: 'ep_sp1',
          variantId: 'v2',
          seasonNumber: 0,
          episodeNumber: 1,
          episodeTitle: 'SP01',
          sourceType: MediaSourceKind.local,
          playedAt: DateTime(2026, 11, 15, 9, 0),
          positionSeconds: 60,
          durationSeconds: 300,
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          const Scaffold(body: PlaybackHistoryPage()),
          overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('01 · 动物园GO!'), findsOneWidget);
      expect(find.text('SP01'), findsOneWidget);
      expect(find.textContaining('WebDAV'), findsNothing);
      expect(find.textContaining('S01E01'), findsNothing);
      expect(find.textContaining('S00E01'), findsNothing);
    });

    testWidgets('设置双卡右边缘严格等宽对齐与关于页 38x38 图标对齐验证', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await tester.pumpWidget(
        _wrapApp(
          const Scaffold(body: SettingsPage()),
          overrides: [
            konataDatabaseProvider.overrideWithValue(db),
            libraryRepositoryProvider.overrideWithValue(repo),
            tmdbNetworkConfigProvider.overrideWith(
              (_) async => const TmdbNetworkConfig(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final cards = find.descendant(
        of: find.byType(SettingsAppearancePanel),
        matching: find.byType(KonataSurfaceCard),
      );
      expect(cards, findsNWidgets(2));
      final firstBox = tester.getRect(cards.at(0));
      final secondBox = tester.getRect(cards.at(1));
      expect(firstBox.width, closeTo(secondBox.width, 0.5));
      expect(firstBox.right, closeTo(secondBox.right, 0.5));

      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      final displayCards = find.descendant(
        of: find.byType(SettingsPage),
        matching: find.byType(KonataSurfaceCard),
      );
      expect(displayCards, findsNWidgets(2));
      final dispFirst = tester.getRect(displayCards.at(0));
      final dispSecond = tester.getRect(displayCards.at(1));
      expect(dispFirst.width, closeTo(dispSecond.width, 0.5));
      expect(dispFirst.right, closeTo(dispSecond.right, 0.5));

      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsAboutPanel), findsOneWidget);
      expect(find.text('TM\nDB'), findsOneWidget);

      final logTitleLeft = tester.getTopLeft(find.text('详细调试日志')).dx;
      final exportTitleLeft = tester.getTopLeft(find.text('导出最近异常日志')).dx;
      final githubTitleLeft = tester.getTopLeft(find.text('ClainSt/Konata')).dx;
      final tmdbTitleLeft = tester.getTopLeft(find.text('TMDB')).dx;
      expect(logTitleLeft, closeTo(exportTitleLeft, 0.5));
      expect(githubTitleLeft, closeTo(logTitleLeft, 0.5));
      expect(tmdbTitleLeft, closeTo(logTitleLeft, 0.5));

      expect(find.text('播放与音画还原'), findsNothing);
      await tester.tap(find.text('播放器'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPlayersPanel), findsOneWidget);
      expect(find.text('音频播放器与图片查看器将在后续版本中扩展'), findsNothing);

      await tester.tap(find.text('外部调用'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsExternalToolsPanel), findsOneWidget);
    });

    testWidgets('WebDAV 空名称自动补全保存成功', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      MediaSource? savedSource;
      await tester.pumpWidget(
        _wrapApp(
          Scaffold(
            body: SourceEditorDialog(
              onSave: (source, _, {clearPassword = false}) async {
                savedSource = source;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('WebDAV'));
      await tester.pumpAndSettle();
      // 输入框顺序：0=显示名称, 1=WebDAV 地址, 2=用户名, 3=密码
      await tester.enterText(
        find.byType(TextField).at(1),
        'https://nas.local:5006/Bangumi',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(savedSource, isNotNull);
      expect(savedSource!.kind, MediaSourceKind.webdav);
      expect(savedSource!.label, isNotEmpty);
    });

    testWidgets('媒体源选择目录弹窗与悬浮毛玻璃胶囊 Toast', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      await repo.upsertMediaSource(
        MediaSource(
          id: 'src_webdav',
          kind: MediaSourceKind.webdav,
          label: 'Bangumi WebDAV',
          location: 'https://nas.local:5006/Bangumi',
          createdAt: DateTime(2026),
        ),
      );

      await tester.pumpWidget(
        _wrapApp(
          const Scaffold(body: SourcesPage()),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            konataActionsProvider.overrideWith(
              (ref) => _FakeActionsCoordinator(ref),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('选择目录'), findsOneWidget);
      expect(find.text('https://nas.local:5006/Bangumi'), findsOneWidget);

      await tester.tap(find.text('选择目录'));
      await tester.pumpAndSettle();
      expect(find.byType(SourceFolderPickerDialog), findsOneWidget);
      expect(find.text('Season_2025'), findsOneWidget);

      final toastContext = tester.element(find.byType(SourcesPage));
      showKonataToast(toastContext, '测试玻璃胶囊提示');
      await tester.pump();
      expect(find.text('测试玻璃胶囊提示'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('测试玻璃胶囊提示'), findsNothing);
    });
  });
}

class _FakeActionsCoordinator extends KonataActionsCoordinator {
  _FakeActionsCoordinator(super.ref);

  @override
  Future<List<RemoteEntry>> listSourceDirectory(
    MediaSource source,
    String relativePath,
  ) async {
    return const [
      RemoteEntry(
        name: 'Season_2025',
        relativePath: 'Season_2025',
        isDirectory: true,
      ),
    ];
  }
}
