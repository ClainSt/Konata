import 'dart:typed_data';

import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/detail_display_preferences_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/providers/scraping_providers.dart';
import 'package:konata/domain/formatting/detail_title_typography.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/network/fanart_service.dart';
import 'package:konata/presentation/detail/detail_gear_menu.dart';
import 'package:konata/presentation/detail/detail_hero_info.dart';
import 'package:konata/presentation/detail/detail_stylized_title_block.dart';
import 'package:konata/presentation/detail/work_detail_sub_views.dart';
import 'package:konata/presentation/dialogs/work_artwork_picker_dialog.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:konata/application/providers/konata_value_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

final Uint8List _sample1x1Png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget _wrapTestApp(
  Widget child, {
  ThemeData? theme,
  List<Override> overrides = const [],
  double textScale = 1.0,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: theme ?? KonataTheme.darkTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
}

void main() {
  group('DetailStylizedTitleBlock 风格化文字兜底与多端自适应', () {
    testWidgets('浅色主题叠图场景保持纯白高字重与三层投影并挂载局部椭圆柔晕', (tester) async {
      const work = Work(
        id: 'w_movie',
        title: '千与千寻',
        originalTitle: '千と千尋の神隠し',
        tmdbMediaType: TmdbMediaType.movie,
      );

      await tester.pumpWidget(
        _wrapTestApp(
          const ColoredBox(
            color: Colors.white,
            child: Padding(
              padding: EdgeInsets.all(48),
              child: DetailStylizedTitleBlock(
                work: work,
                viewport: DetailTitleViewportProfile.desktop,
                mode: DetailTitlePresentationMode.heroEmblem,
                onBackdrop: true,
              ),
            ),
          ),
          theme: KonataTheme.lightTheme(),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('detail_stylized_title_kicker')), findsOneWidget);
      expect(find.text('剧场版'), findsOneWidget);
      expect(find.text('千与千寻'), findsOneWidget);
      expect(find.text('千と千尋の神隠し'), findsNothing);
      expect(find.byKey(const ValueKey('detail_stylized_title_hairline')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail_stylized_title_backdrop_halo')),
        findsOneWidget,
      );

      final titleText = tester.widget<Text>(find.text('千与千寻'));
      expect(titleText.style?.color, KonataTheme.pureWhite);
      expect(titleText.style?.shadows?.length, 3);
      expect(
        titleText.style?.fontVariations?.first.value,
        greaterThan(650.0),
      );
    });

    testWidgets('五类视口与 1.3x 字体缩放下的超长轻改标题均零溢出', (tester) async {
      const longWork = Work(
        id: 'w_ln',
        title: '关于我转生变成史莱姆这档事：末日时在做什么？有没有空？可以来拯救吗？',
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 3,
      );

      const cases = <(Size, DetailTitleViewportProfile, bool)>[
        (Size(1280, 800), DetailTitleViewportProfile.desktop, true),
        (Size(1280, 800), DetailTitleViewportProfile.tabletLandscape, true),
        (Size(800, 1280), DetailTitleViewportProfile.tabletPortrait, false),
        (Size(390, 844), DetailTitleViewportProfile.phonePortrait, false),
        (Size(844, 390), DetailTitleViewportProfile.phoneLandscape, true),
      ];

      for (final (size, profile, onBackdrop) in cases) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          _wrapTestApp(
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: DetailStylizedTitleBlock(
                  work: longWork,
                  viewport: profile,
                  onBackdrop: onBackdrop,
                ),
              ),
            ),
            textScale: 1.3,
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('detail_stylized_title_block')), findsOneWidget);
      }
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('平板竖屏透明徽标加载 404 时平滑回退风格化文字标题不留空白', (tester) async {
      const work = Work(
        id: 'w_pad_404',
        title: '葬送的芙莉莲',
        logoPath: '/missing_logo.png',
        backdropPath: '/backdrop.jpg',
      );
      Future<Uint8List> failingLogoLoader(
        String path, {
        int? targetWidth,
        TmdbImageSize? imageSize,
      }) async {
        if (path == '/missing_logo.png') {
          throw StateError('HTTP 404');
        }
        return _sample1x1Png;
      }

      await tester.pumpWidget(
        _wrapTestApp(
          DetailPortraitHeroHeader(
            work: work,
            imageLoader: failingLogoLoader,
            screenSize: const Size(800, 1280),
            isTablet: true,
            showTitleLogo: true,
            showTitleText: false,
            logoMaxHeight: 68,
            logoMaxWidth: 300,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('葬送的芙莉莲'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail_stylized_title_block')), findsOneWidget);
    });

    testWidgets('桌面端与手机竖屏透明徽标加载失败回退多行风格化标题且带季别眉标时零像素溢出', (
      tester,
    ) async {
      const work = Work(
        id: 'w_milky_td',
        title: '侦探歌剧 少女福尔摩斯 TD',
        year: 2014,
        bangumiScore: 6.1,
        matchedSeason: 4,
        tmdbMediaType: TmdbMediaType.tv,
        logoPath: '/broken_td_logo.png',
      );
      const bundle = WorkDetailBundle(
        work: work,
        episodes: [],
        variants: [],
        sourcesById: {},
        latestPlayback: null,
        playbackByEpisodeId: {},
      );
      Future<Uint8List> failingLoader(
        String path, {
        int? targetWidth,
        TmdbImageSize? imageSize,
      }) async {
        throw StateError('HTTP 404');
      }

      // 1. 桌面端 DetailHeroInfo（maxHeight: 80）徽标加载失败后跳出限高图片盒，零溢出。
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _wrapTestApp(
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(36),
              child: DetailHeroInfo(
                bundle: bundle,
                imageLoader: failingLoader,
                showTitleLogo: true,
                showTitleText: false,
                logoMaxHeight: 80.0,
                logoMaxWidth: 340.0,
                viewportProfile: DetailTitleViewportProfile.desktop,
                onPrimaryPlay: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('第 4 季'), findsOneWidget);
      expect(find.text('侦探歌剧 少女福尔摩斯 TD'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail_stylized_title_block')),
        findsOneWidget,
      );

      // 2. 手机竖屏 lockInFlowLogoHeight=true 场景下同样自动解除固定槽位高度约束，零溢出。
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        _wrapTestApp(
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DetailHeroInfo(
                bundle: bundle,
                imageLoader: failingLoader,
                showTitleLogo: true,
                showTitleText: false,
                lockInFlowLogoHeight: true,
                logoMaxHeight: 56.0,
                logoMaxWidth: 260.0,
                viewportProfile: DetailTitleViewportProfile.phonePortrait,
                onBackdrop: false,
                onPrimaryPlay: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('侦探歌剧 少女福尔摩斯 TD'), findsOneWidget);
    });

    testWidgets('手机横屏头图尊重 showTitleLogo 与 showTitleText 组合开关并复用风格化标题', (
      tester,
    ) async {
      const workNoLogo = Work(id: 'w_phone_ls', title: '孤独摇滚！', year: 2022);
      const bundle = WorkDetailBundle(
        work: workNoLogo,
        episodes: [],
        variants: [],
        sourcesById: {},
        latestPlayback: null,
        playbackByEpisodeId: {},
      );
      Future<Uint8List> fakeLoader(
        String _, {
        int? targetWidth,
        TmdbImageSize? imageSize,
      }) async => _sample1x1Png;

      await tester.pumpWidget(
        _wrapTestApp(
          DetailLandscapeHeroBanner(
            bundle: bundle,
            imageLoader: fakeLoader,
            displayPrefs: const DetailDisplayPreferences(
              showTitleLogo: false,
              showTitleText: false,
            ),
            screenSize: const Size(844, 390),
            leadingBackButton: const SizedBox.shrink(),
            onPrimaryPlay: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('孤独摇滚！'), findsNothing);

      await tester.pumpWidget(
        _wrapTestApp(
          DetailLandscapeHeroBanner(
            bundle: bundle,
            imageLoader: fakeLoader,
            displayPrefs: const DetailDisplayPreferences(
              showTitleLogo: true,
              showTitleText: false,
            ),
            screenSize: const Size(844, 390),
            leadingBackButton: const SizedBox.shrink(),
            onPrimaryPlay: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('孤独摇滚！'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail_stylized_title_block')), findsOneWidget);
    });
  });

  group('详情页「编辑标题徽标」入口门控与透明徽标选择器', () {
    testWidgets('仅当传入 onEditLogo（开启标题徽标显示）时齿轮菜单才出现「编辑标题徽标」', (
      tester,
    ) async {
      final link = LayerLink();
      Widget buildOverlay({VoidCallback? onEditLogo}) {
        return _wrapTestApp(
          Stack(
            children: [
              Positioned(
                bottom: 40,
                right: 40,
                child: CompositedTransformTarget(
                  link: link,
                  child: const SizedBox(width: 40, height: 40),
                ),
              ),
              DetailGearMenuOverlay(
                link: link,
                onDismiss: () {},
                onSelect: (fn) => fn(),
                onManualMatch: () {},
                onManualEdit: () {},
                onEditPoster: () {},
                onEditBackdrop: () {},
                onEditLogo: onEditLogo,
                onHideWork: () {},
                onDeleteWork: () {},
                onRescrape: () {},
                onOpenLocalDir: () {},
              ),
            ],
          ),
        );
      }

      await tester.pumpWidget(buildOverlay(onEditLogo: null));
      await tester.pump();
      expect(find.text('编辑标题徽标'), findsNothing);

      var logoEditTapped = false;
      await tester.pumpWidget(
        buildOverlay(onEditLogo: () => logoEditTapped = true),
      );
      await tester.pump();
      expect(find.text('编辑标题徽标'), findsOneWidget);
      await tester.tap(find.text('编辑标题徽标'));
      expect(logoEditTapped, isTrue);
    });

    testWidgets('WorkArtworkPickerDialog logo 模式在中继降级时展示明确中文引导文案', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const work = Work(id: 'w_logo_dlg', title: '测试番剧');
      await tester.pumpWidget(
        _wrapTestApp(
          const WorkArtworkPickerDialog(
            work: work,
            kind: WorkArtworkKind.logo,
          ),
          overrides: [
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _sample1x1Png,
            ),
            fanartRelayHealthProvider.overrideWith(
              () => KonataValueNotifier.value(
                const FanartRelayHealthSnapshot(
                  status: FanartRelayStatus.quotaExhausted,
                  message: '内置 Fanart.tv 中继今日免费额度已达上限，请填个人 Key',
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('编辑作品标题徽标'), findsOneWidget);
      expect(find.textContaining('免费额度已达上限'), findsOneWidget);
    });
  });
}
