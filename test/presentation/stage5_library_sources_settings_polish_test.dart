import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/providers/desktop_external_tools_providers.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/theme_providers.dart';
import 'package:ccplayer/domain/models/external_player_config.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/presentation/library/poster_card.dart';
import 'package:ccplayer/presentation/settings/settings_appearance_panel.dart';
import 'package:ccplayer/presentation/settings/settings_external_tools_panel.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/bangumi_score_wordmark_badge.dart';

final Uint8List _sample1x1Png = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Widget _wrapApp(
  Widget child, {
  List<Override> overrides = const [],
  ThemeMode themeMode = ThemeMode.dark,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: themeMode,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  group('阶段 5 · 海报墙左下 Bangumi 粉色微标、外观流光画布开关与外部调用精简验收', () {
    testWidgets('桌面端悬停 PosterCard 在左下呈现粉色矢量 Bangumi 评分微标，无快捷播放圆钮', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const item = WorkLibraryItem(
        work: Work(
          id: 'w_bgm_1',
          title: '凉宫春日的忧郁',
          year: 2006,
          bangumiScore: 6.7,
          posterPath: '/haruhi.jpg',
          scrapeStatus: ScrapeStatus.matched,
        ),
        variants: [],
        episodeCount: 14,
        releaseGroups: ['VCB-Studio'],
      );

      await tester.pumpWidget(
        _wrapApp(
          Center(
            child: SizedBox(
              width: 180,
              height: 310,
              child: PosterCard(
                item: item,
                imageLoader: (_, {targetWidth, imageSize}) async =>
                    _sample1x1Png,
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final badgeFinder = find.byKey(
        const ValueKey('poster_bangumi_badge_w_bgm_1'),
      );
      expect(badgeFinder, findsOneWidget);
      expect(find.byType(BangumiScoreWordmarkBadge), findsOneWidget);
      expect(find.text('6.7'), findsOneWidget);
      // 悬停前保持透明隐藏
      final opacityBefore = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: badgeFinder,
          matching: find.byType(AnimatedOpacity),
        ).first,
      );
      expect(opacityBefore.opacity, 0.0);

      // 模拟桌面鼠标悬停卡片 -> 微标淡入并位于海报左下方，无快捷播放按钮
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(PosterCard)));
      await tester.pumpAndSettle();

      final opacityAfter = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: badgeFinder,
          matching: find.byType(AnimatedOpacity),
        ).first,
      );
      expect(opacityAfter.opacity, 1.0);
      final cardRect = tester.getRect(find.byType(PosterCard));
      final badgeRect = tester.getRect(badgeFinder);
      expect(badgeRect.left - cardRect.left, lessThan(24.0));
      expect(badgeRect.center.dy, greaterThan(cardRect.center.dy));
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('外观面板仅在 Windows 展示流光氛围画布开关且外部调用面板已彻底移除外部图片查看器', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(900, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(20),
                child: SettingsAppearancePanel(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final switchFinder = find.byKey(
        const ValueKey('settings_ambient_canvas_switch'),
      );
      expect(switchFinder, findsOneWidget);
      expect(container.read(ambientCanvasEnabledProvider), isFalse);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(container.read(ambientCanvasEnabledProvider), isTrue);

      // Android 端自动过滤桌面专属「流光氛围画布」与「窗口材质」卡片
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(20),
                child: SettingsAppearancePanel(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(switchFinder, findsNothing);

      // 校验桌面端外部调用面板已移除外部图片查看器输入框，仅保留视频与音频外部程序
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.pumpWidget(
        _wrapApp(
          const SingleChildScrollView(
            padding: EdgeInsets.all(20),
            child: SettingsExternalToolsPanel(),
          ),
          overrides: [
            desktopExternalPlayersProvider.overrideWith(
              (_) async => const <ExternalPlayerConfig>[],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('外部音频播放器'), findsWidgets);
      expect(find.textContaining('外部图片查看器'), findsNothing);
      expect(find.textContaining('Honeyview'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
