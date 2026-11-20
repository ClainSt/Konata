import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/scraping_providers.dart';
import 'package:ccplayer/application/scraping/scrape_progress.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/detail/detail_bottom_drawer.dart';
import 'package:ccplayer/presentation/detail/work_detail_page.dart';
import 'package:ccplayer/presentation/shell/adaptive_capsule_layout.dart';
import 'package:ccplayer/presentation/sources/scan_progress_dialog.dart';
import 'package:ccplayer/presentation/sources/scrape_progress_banner.dart';
import 'package:ccplayer/presentation/theme/konata_palette.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_draggable_dialog.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_glass_dialog.dart';
import 'package:ccplayer/presentation/widgets/managed_image.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';

final Uint8List _transparentPng = Uint8List.fromList([
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

class _StubScrapeController extends ScrapeController {
  _StubScrapeController(super.ref, ScrapeProgress initial) {
    state = initial;
  }
}

class _StubAudioPlaybackNotifier extends AudioPlaybackNotifier {
  _StubAudioPlaybackNotifier(super.ref, AudioPlaybackState initial) {
    state = initial;
  }

  void emit(AudioPlaybackState next) {
    state = next;
  }
}

Widget _wrapStage1App(
  Widget child, {
  Key? scopeKey,
  List<Override> overrides = const [],
  ThemeMode mode = ThemeMode.light,
}) {
  return ProviderScope(
    key: scopeKey,
    overrides: [
      tmdbImageLoaderProvider.overrideWithValue(
        (_, {targetWidth, imageSize}) async => _transparentPng,
      ),
      ...overrides,
    ],
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
  group('阶段 1：进度条蓝色统一、跨模式毛玻璃材质、0 延迟拖拽弹窗与 MiniAudioBar 避让测试', () {
    testWidgets('全局 ProgressIndicatorTheme 与横幅/扫描弹窗/播控胶囊 100% 统一为同款蓝色且无孤立圆点', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      for (final isDark in [false, true]) {
        final expectedPal = isDark ? KonataPalette.dark : KonataPalette.light;
        final theme =
            isDark ? KonataTheme.darkTheme() : KonataTheme.lightTheme();
        expect(theme.progressIndicatorTheme.color, equals(expectedPal.progressFill));
        expect(
          theme.progressIndicatorTheme.linearTrackColor,
          equals(expectedPal.progressTrack),
        );
        expect(
          theme.progressIndicatorTheme.stopIndicatorColor,
          equals(Colors.transparent),
        );
        expect(theme.progressIndicatorTheme.stopIndicatorRadius, equals(0));
      }

      await tester.pumpWidget(
        _wrapStage1App(
          Column(
            children: [
              ScrapeProgressBanner(
                progress: const ScrapeProgress(
                  phase: ScrapePhase.scraping,
                  sourceId: 's1',
                  sourceLabel: 'NAS',
                  totalWorks: 10,
                  processedWorks: 4,
                ),
                onInspect: () {},
              ),
              const SizedBox(height: 16),
              KonataPlaybackCapsule(
                title: '待机态音频',
                positionSeconds: 0,
                durationSeconds: 0,
                isPlaying: false,
                onTogglePlayPause: () {},
                onSeek: (_) {},
              ),
              const SizedBox(height: 16),
              KonataPlaybackCapsule(
                title: '第 01 话',
                positionSeconds: 30,
                durationSeconds: 120,
                isPlaying: true,
                onTogglePlayPause: () {},
                onSeek: (_) {},
              ),
            ],
          ),
          mode: ThemeMode.light,
        ),
      );
      await tester.pump();

      final bannerIndicator = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: find.byType(ScrapeProgressBanner),
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      expect(
        (bannerIndicator.valueColor as AlwaysStoppedAnimation<Color>?)?.value,
        equals(KonataPalette.light.progressFill),
      );
      expect(
        bannerIndicator.backgroundColor,
        equals(KonataPalette.light.progressTrack),
      );

      final capsules = tester
          .widgetList<KonataPlaybackCapsule>(find.byType(KonataPlaybackCapsule))
          .toList();
      expect(capsules, hasLength(2));

      Color? extractFill(Widget w) {
        if (w is ColoredBox) return w.color;
        if (w is DecoratedBox) {
          final d = w.decoration;
          if (d is BoxDecoration) return d.color;
          if (d is ShapeDecoration) return d.color;
        }
        return null;
      }

      // duration == 0 的胶囊不绘制突兀灰色底轨条
      final idleVisuals = find.descendant(
        of: find.byWidget(capsules[0]),
        matching: find.byWidgetPredicate(
          (w) => extractFill(w) == KonataPlaybackTokens.capsuleProgressTrack,
        ),
      );
      expect(idleVisuals, findsNothing);

      // duration > 0 的胶囊内嵌底置滑轨填充采用全站统一蓝色，底轨采用低对比度暗轨
      final activeVisuals = tester
          .widgetList<Widget>(
            find.descendant(
              of: find.byWidget(capsules[1]),
              matching: find.byWidgetPredicate((w) => extractFill(w) != null),
            ),
          )
          .map((w) => extractFill(w)!)
          .toList();
      expect(
        activeVisuals.contains(KonataPlaybackTokens.capsuleProgressFill) ||
            activeVisuals.contains(KonataPalette.light.progressFill),
        isTrue,
      );
      expect(
        activeVisuals.contains(KonataPalette.dark.progressTrack) ||
            activeVisuals.contains(KonataPalette.light.progressTrack),
        isTrue,
      );

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      await tester.pumpWidget(
        _wrapStage1App(
          const ScanProgressDialog(),
          scopeKey: const ValueKey('scan_dialog_app'),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            scrapeControllerProvider.overrideWith(
              (ref) => _StubScrapeController(
                ref,
                const ScrapeProgress(
                  phase: ScrapePhase.scraping,
                  sourceId: 's1',
                  sourceLabel: 'NAS',
                  totalWorks: 10,
                  processedWorks: 5,
                ),
              ),
            ),
          ],
          mode: ThemeMode.dark,
        ),
      );
      await tester.pump();

      final dialogBar = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: find.byType(ScanProgressDialog),
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      expect(
        (dialogBar.valueColor as AlwaysStoppedAnimation<Color>?)?.value,
        equals(KonataPalette.dark.progressFill),
      );
      expect(
        dialogBar.backgroundColor,
        equals(KonataPalette.dark.progressTrack),
      );
    });

    testWidgets('KonataFloatingMiniPlayer 音频小窗在亮/暗模式下保持 1:1 封面加底部三键纯净形态', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const audioItem = AudioQueueItem(
        id: 'trk_1',
        work: Work(id: 'w1', title: '轻音少女'),
        variant: MediaVariant(
          id: 'v1',
          workId: 'w1',
          sourceId: 's1',
          relativePath: '01.flac',
          fileName: '01.flac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        ),
        title: 'Don\'t say "lazy"',
      );

      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        await tester.pumpWidget(
          _wrapStage1App(
            const Center(
              child: KonataFloatingMiniPlayer.standalone(
                kind: FloatingMiniPlayerKind.audio,
              ),
            ),
            mode: mode,
            overrides: [
              audioPlaybackProvider.overrideWith(
                (ref) => _StubAudioPlaybackNotifier(
                  ref,
                  const AudioPlaybackState(
                    isActive: true,
                    isPlaying: true,
                    queue: [audioItem],
                    currentIndex: 0,
                    positionSeconds: 12,
                    durationSeconds: 120,
                    volume: 100.0,
                    audioCodecLabel: 'FLAC',
                    sampleRateAndBitDepthLabel: '24-bit · 96 kHz',
                  ),
                ),
              ),
            ],
          ),
        );
        await tester.pump();

        final rect = tester.getRect(
          find.byKey(const ValueKey('konata_floating_mini_player')),
        );
        final expectedDisc = AdaptiveCapsuleLayout(
          size: const Size(1280, 800),
          safe: EdgeInsets.zero,
          android: false,
          navigationVisible: false,
          miniKind: FloatingMiniPlayerKind.audio,
        ).floatingMiniWindowRect!.size;
        expect(rect.width, closeTo(expectedDisc.width, 0.5));
        expect(rect.height, closeTo(expectedDisc.height, 0.5));
        expect(find.text('Don\'t say "lazy"'), findsNothing);
        expect(
          find.byKey(const ValueKey('floating_mini_audio_disc')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('floating_mini_audio_progress')),
          findsOneWidget,
        );
      }
    });

    testWidgets('KonataDraggableDialog 支持第 1px 即刻拖拽与长按停顿拖拽、视口收敛与双击归位且隔离输入/关闭', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final textCtrl = TextEditingController(text: '测试划选隔离文本');
      addTearDown(textCtrl.dispose);
      var closed = false;

      await tester.pumpWidget(
        _wrapStage1App(
          Builder(
            builder: (ctx) => Center(
              child: KonataGlassDialog(
                title: '可拖拽弹窗标题',
                width: 420,
                onClose: () => closed = true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: textCtrl),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Offset dialogOrigin() {
        return tester.getTopLeft(
          find.descendant(
            of: find.byType(KonataDraggableDialog),
            matching: find.byType(ClipRRect),
          ),
        );
      }

      final centerOrigin = dialogOrigin();

      // 1. 按下后立即移动，1px 级 0 延迟跟手
      final titleCenter = tester.getCenter(find.text('可拖拽弹窗标题'));
      final g1 = await tester.startGesture(titleCenter);
      await g1.moveBy(const Offset(2, 0));
      await tester.pump();
      await g1.moveBy(const Offset(28, 16));
      await tester.pump();
      await g1.up();
      await tester.pump();

      final afterImmediateDrag = dialogOrigin();
      expect(afterImmediateDrag.dx - centerOrigin.dx, closeTo(30.0, 2.0));
      expect(afterImmediateDrag.dy - centerOrigin.dy, closeTo(16.0, 2.0));

      // 2. 长按停顿 2 秒后再拖动，依然 0ms 延迟 1:1 跟手
      final g2 = await tester.startGesture(tester.getCenter(find.text('可拖拽弹窗标题')));
      await tester.pump(const Duration(seconds: 2));
      await g2.moveBy(const Offset(20, -10));
      await tester.pump();
      await g2.up();
      await tester.pump();

      final afterHoldDrag = dialogOrigin();
      expect(afterHoldDrag.dx - afterImmediateDrag.dx, closeTo(20.0, 2.0));
      expect(afterHoldDrag.dy - afterImmediateDrag.dy, closeTo(-10.0, 2.0));

      // 3. 隔离 TextField 横向划选与关闭按钮
      final beforeFieldDrag = dialogOrigin();
      await tester.drag(find.byType(TextField), const Offset(80, 0));
      await tester.pump();
      expect(dialogOrigin().dx, closeTo(beforeFieldDrag.dx, 0.5));
      expect(dialogOrigin().dy, closeTo(beforeFieldDrag.dy, 0.5));

      // 4. 越界钳制 & 窗口 resize 自动回拉至可视区
      final gExtreme = await tester.startGesture(
        tester.getCenter(find.text('可拖拽弹窗标题')),
      );
      await gExtreme.moveBy(const Offset(1800, 1200));
      await tester.pump();
      await gExtreme.up();
      await tester.pump();

      final maxRight = dialogOrigin().dx + 420.0;
      expect(
        maxRight,
        lessThanOrEqualTo(1280.0 - KonataTheme.dialogViewportMargin + 1.0),
      );

      tester.view.physicalSize = const Size(760, 540);
      await tester.pumpAndSettle();
      final resizedRight = dialogOrigin().dx + 420.0;
      expect(
        resizedRight,
        lessThanOrEqualTo(760.0 - KonataTheme.dialogViewportMargin + 1.0),
      );

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();

      // 5. 双击标题栏归位居中
      final titleFinder = find.text('可拖拽弹窗标题');
      await tester.tap(titleFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(titleFinder);
      await tester.pumpAndSettle();
      expect(dialogOrigin().dx, closeTo(centerOrigin.dx, 0.5));
      expect(dialogOrigin().dy, closeTo(centerOrigin.dy, 0.5));

      // 6. 关闭键独立响应不触发位移
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(closed, isTrue);
    });

    testWidgets('WorkDetailPage 在 MiniAudioBar 显隐时背景铺满全屏、底栏平滑避让且无遮挡', (
      tester,
    ) async {
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
          backdropPath: '/frieren_bd.jpg',
          scrapeStatus: ScrapeStatus.matched,
        ),
      );
      await repo.upsertEpisode(
        const Episode(
          id: 'ep1',
          workId: 'w1',
          seasonNumber: 1,
          episodeNumber: 1,
          title: '冒险的终点',
        ),
      );
      await repo.upsertMediaVariant(
        const MediaVariant(
          id: 'v1',
          workId: 'w1',
          episodeId: 'ep1',
          sourceId: 's1',
          relativePath: 'Frieren/01.mkv',
          fileName: '01.mkv',
          fileSize: 2048,
        ),
      );

      late _StubAudioPlaybackNotifier audioNotifier;
      const idleAudio = AudioPlaybackState(isActive: false);
      const activeAudio = AudioPlaybackState(
        isActive: true,
        isPlaying: true,
        queue: [
          AudioQueueItem(
            id: 'cd_1',
            work: Work(id: 'w1', title: '葬送的芙莉莲'),
            variant: MediaVariant(
              id: 'cdv_1',
              workId: 'w1',
              sourceId: 's1',
              relativePath: 'OST/01.flac',
              fileName: '01.flac',
              fileSize: 1024,
              assetKind: AssetKind.cdAlbum,
            ),
            title: 'Journey of a Lifetime',
          ),
        ],
        currentIndex: 0,
      );

      await tester.pumpWidget(
        _wrapStage1App(
          const WorkDetailPage(workId: 'w1'),
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            audioPlaybackProvider.overrideWith((ref) {
              audioNotifier = _StubAudioPlaybackNotifier(ref, idleAudio);
              return audioNotifier;
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final bgHeightBefore = tester.getSize(find.byType(ManagedImage).first).height;
      final chipBottomBefore = tester.getBottomLeft(find.text('正片 (1)')).dy;
      expect(bgHeightBefore, closeTo(800.0, 0.5));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkDetailPage)),
      );
      container.read(audioPlaybackProvider);
      audioNotifier.emit(activeAudio);
      await tester.pumpAndSettle();

      final bgHeightAfter = tester.getSize(find.byType(ManagedImage).first).height;
      final chipBottomAfter = tester.getBottomLeft(find.text('正片 (1)')).dy;
      // 桌面端悬浮小窗自由悬浮于最顶层，不顶起详情页底栏正片/特典/CD 卡片条
      expect(bgHeightAfter, closeTo(800.0, 0.5));
      expect(chipBottomAfter, closeTo(chipBottomBefore, 1.0));
      expect(
        tester.getBottomLeft(find.byType(DetailBottomDrawer)).dy,
        closeTo(800.0, 1.0),
      );

      // 关闭悬浮小窗后底栏依旧稳定贴底
      audioNotifier.emit(idleAudio);
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.text('正片 (1)')).dy, closeTo(chipBottomBefore, 1.0));
    });
  });
}
