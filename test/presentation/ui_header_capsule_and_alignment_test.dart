import 'dart:ui' show FontVariation, PointerDeviceKind;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/scraping/scrape_progress.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/sources/scrape_progress_banner.dart';
import 'package:ccplayer/presentation/sources/sources_page.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/adaptive_action_header.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_page_header.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_pill_button.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_segmented_capsule.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_surface_card.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';

class _FakeScrapeController extends ScrapeController {
  _FakeScrapeController(super.ref, ScrapeProgress initial) {
    state = initial;
  }
}

Widget _wrapUiApp(
  Widget child, {
  List<Override> overrides = const [],
  ThemeMode mode = ThemeMode.light,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: mode,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('KonataPageHeader、分段胶囊、媒体源边缘对齐与播控胶囊测试', () {
    testWidgets('KonataPageHeader 在有无操作按钮与徽章时主标题 X/Y 坐标零像素跳动且使用 Inter VF', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _wrapUiApp(
          KonataPageHeader(
            title: '媒体库',
            badge: const Text('24 部'),
            actions: [
              KonataPillButton.primary(
                label: '添加媒体源',
                icon: Icons.add_rounded,
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final posWithActions = tester.getTopLeft(find.text('媒体库'));
      final titleWidget = tester.widget<Text>(find.text('媒体库'));
      expect(titleWidget.style?.fontFamily, equals(KonataTheme.uiFontFamily));
      expect(titleWidget.style?.fontSize, equals(26));
      expect(
        titleWidget.style?.fontVariations,
        contains(const FontVariation('wght', 600)),
      );

      await tester.pumpWidget(
        _wrapUiApp(
          const KonataPageHeader(title: '设置'),
        ),
      );
      await tester.pumpAndSettle();

      final posWithoutActions = tester.getTopLeft(find.text('设置'));
      expect(posWithoutActions.dx, closeTo(posWithActions.dx, 0.01));
      expect(posWithoutActions.dy, closeTo(posWithActions.dy, 0.01));
    });

    testWidgets('SourcesPage 顶部按钮、扫描横幅与卡片右边缘 100% 像素级对齐且不压滚动条', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);

      const src1 = MediaSource(
        id: 'src_1',
        kind: MediaSourceKind.local,
        label: 'NAS 动画',
        location: r'D:\Anime',
      );
      const src2 = MediaSource(
        id: 'src_2',
        kind: MediaSourceKind.webdav,
        label: 'WebDAV 仓库',
        location: 'https://nas.local/dav',
      );
      await repo.upsertMediaSource(src1);
      await repo.upsertMediaSource(src2);

      await tester.pumpWidget(
        _wrapUiApp(
          const SourcesPage(),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            scrapeControllerProvider.overrideWith(
              (ref) => _FakeScrapeController(
                ref,
                const ScrapeProgress(
                  phase: ScrapePhase.completed,
                  sourceId: 'src_1',
                  sourceLabel: 'NAS 动画',
                  totalWorks: 12,
                  processedWorks: 12,
                  matchedWorks: 11,
                  reviewWorks: 1,
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final headerBtn = find.descendant(
        of: find.byType(AdaptiveActionHeader),
        matching: find.byType(KonataPillButton),
      );
      final banner = find.byType(ScrapeProgressBanner);
      final sourceCard = find.ancestor(
        of: find.text('NAS 动画'),
        matching: find.byType(KonataSurfaceCard),
      );

      final btnRight = tester.getTopRight(headerBtn).dx;
      final bannerRight = tester.getTopRight(banner).dx;
      final cardRight = tester.getTopRight(sourceCard).dx;

      expect(bannerRight, closeTo(btnRight, 0.5));
      expect(cardRight, closeTo(btnRight, 0.5));
      expect(
        1280.0 - cardRight,
        greaterThanOrEqualTo(KonataTheme.pageHorizontalPadding - 0.5),
      );
    });

    testWidgets('KonataSegmentedCapsule 丝滑切换滑块且零 InkWell 水波纹残留', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var selected = 'local';
      await tester.pumpWidget(
        _wrapUiApp(
          StatefulBuilder(
            builder: (context, setState) {
              return Center(
                child: KonataSegmentedCapsule<String>(
                  selected: selected,
                  options: const [
                    KonataSegmentOption(value: 'local', label: '本地目录'),
                    KonataSegmentOption(value: 'webdav', label: 'WebDAV'),
                    KonataSegmentOption(value: 'smb', label: 'SMB 共享'),
                  ],
                  onChanged: (next) => setState(() => selected = next),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(KonataSegmentedCapsule<String>),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );

      final initialThumb = tester.widget<AnimatedPositioned>(
        find.descendant(
          of: find.byType(KonataSegmentedCapsule<String>),
          matching: find.byType(AnimatedPositioned),
        ),
      );
      final initialLeft = initialThumb.left ?? 0.0;

      await tester.tap(find.text('SMB 共享'));
      await tester.pumpAndSettle();

      expect(selected, equals('smb'));
      final movedThumb = tester.widget<AnimatedPositioned>(
        find.descendant(
          of: find.byType(KonataSegmentedCapsule<String>),
          matching: find.byType(AnimatedPositioned),
        ),
      );
      expect(movedThumb.left ?? 0.0, greaterThan(initialLeft));
    });

    testWidgets('KonataPlaybackCapsule 单层紧凑结构、无双重转圈且顶边进度线悬停加粗弹出章节气泡', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      double? seekedTo;
      await tester.pumpWidget(
        _wrapUiApp(
          Center(
            child: KonataPlaybackCapsule(
              title: '葬送的芙莉莲 · 第 01 话',
              positionSeconds: 60,
              durationSeconds: 300,
              isPlaying: true,
              chapters: const [
                PlaybackChapter(index: 0, title: 'OP', startSeconds: 120),
              ],
              onTogglePlayPause: () {},
              onSeek: (target) => seekedTo = target,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(KonataPlaybackCapsule),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );

      final capsuleSize = tester.getSize(find.byType(KonataPlaybackCapsule));
      expect(capsuleSize.height, closeTo(KonataPlaybackTokens.capsuleHeight, 0.5));
      expect(find.textContaining('OP'), findsNothing);

      final capsuleTopLeft = tester.getTopLeft(find.byType(KonataPlaybackCapsule));
      final hoverTarget = Offset(
        capsuleTopLeft.dx + capsuleSize.width * 0.5,
        capsuleTopLeft.dy +
            KonataPlaybackTokens.capsuleProgressTopInset +
            KonataPlaybackTokens.capsuleProgressRestHeight * 0.5,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(hoverTarget);
      await tester.pumpAndSettle();

      expect(find.textContaining('OP'), findsOneWidget);
      final expandedBarFinder = find.descendant(
        of: find.byType(KonataPlaybackCapsule),
        matching: find.byWidgetPredicate(
          (w) =>
              w is AnimatedContainer &&
              w.constraints?.maxHeight ==
                  KonataPlaybackTokens.capsuleProgressHoverHeight,
        ),
      );
      expect(expandedBarFinder, findsOneWidget);

      await tester.tapAt(hoverTarget);
      await tester.pumpAndSettle();
      expect(seekedTo, isNotNull);
    });
  });
}
