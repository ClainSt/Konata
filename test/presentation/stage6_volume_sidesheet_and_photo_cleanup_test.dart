import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/playback/video_playback_controller.dart';
import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/playback/track_preferences.dart';
import 'package:ccplayer/infrastructure/cache/photos_storage.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/infrastructure/storage/storage_root_provider.dart';
import 'package:ccplayer/presentation/settings/photo_custom_cleanup_dialog.dart';
import 'package:ccplayer/presentation/settings/settings_photos_storage_card.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/video/embedded_video_page.dart';
import 'package:ccplayer/presentation/video/video_side_sheet.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_dropdown.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_glass_dialog.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_volume_control.dart';

final Uint8List _samplePng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeVideoController extends VideoPlaybackController {
  _FakeVideoController(super.ref, super.request);

  void forceState(VideoPlaybackState next) {
    state = next;
  }

  @override
  void setVolume(double volume) {
    final clamped = volume.clamp(0.0, 100.0);
    if (clamped > 0 && state.isMuted) {
      state = state.copyWith(volume: clamped, isMuted: false);
    } else {
      state = state.copyWith(volume: clamped);
    }
  }

  @override
  void adjustVolume(double delta) => setVolume(state.volume + delta);

  @override
  void toggleMute() => state = state.copyWith(isMuted: !state.isMuted);

  @override
  void setSideSheetOpen(bool open) =>
      state = state.copyWith(sideSheetOpen: open);
}

VideoLaunchRequest _buildDummyRequest() {
  const work = Work(id: 'w_v1', title: '测试剧集作品');
  const ep = Episode(
    id: 'e1',
    workId: 'w_v1',
    category: EpisodeCategory.main,
    seasonNumber: 1,
    episodeNumber: 1,
    title: '第一话',
  );
  const variant = MediaVariant(
    id: 'v1',
    workId: 'w_v1',
    episodeId: 'e1',
    sourceId: 's1',
    relativePath: '01.mkv',
    fileName: '01.mkv',
    fileSize: 2048,
  );
  const bundle = WorkDetailBundle(
    work: work,
    episodes: [ep],
    variants: [variant],
    sourcesById: {
      's1': MediaSource(
        id: 's1',
        label: 'Local',
        kind: MediaSourceKind.local,
        location: 'D:/Anime',
      ),
    },
    latestPlayback: null,
    playbackByEpisodeId: {},
  );
  return const VideoLaunchRequest(
    work: work,
    episode: ep,
    variant: variant,
    bundle: bundle,
  );
}

void main() {
  group('收官三合一回归测试', () {
    testWidgets(
      '1. 音量控件无遮挡 Tooltip、框外拖拽精准命中 67/79、滚轮 1% 步进且浮层激活时锁定视频底栏不淡出',
      (tester) async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        SharedPreferences.setMockInitialValues({});
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final req = _buildDummyRequest();
        late _FakeVideoController fakeCtrl;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              videoPlaybackProvider(req).overrideWith((ref) {
                fakeCtrl = _FakeVideoController(ref, req);
                fakeCtrl.forceState(
                  VideoPlaybackState(
                    isInitializing: false,
                    isBuffering: false,
                    hasFirstFrame: true,
                    isPlaying: true,
                    currentEpisode: req.episode,
                    currentVariant: req.variant,
                    volume: 50.0,
                    durationSeconds: 1440.0,
                  ),
                );
                return fakeCtrl;
              }),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: EmbeddedVideoPage(request: req),
            ),
          ),
        );
        await tester.pump();

        // 音量控件本身不带 Tooltip 遮挡滑轨
        expect(
          find.descendant(
            of: find.byType(KonataVolumeControl),
            matching: find.byType(Tooltip),
          ),
          findsNothing,
        );

        final volCtrlFinder = find.byType(KonataVolumeControl);
        final volBtnCenter = tester.getCenter(volCtrlFinder);
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.addPointer(location: Offset.zero));
        addTearDown(() async {
          await tester.sendEventToBinding(pointer.removePointer());
        });
        await tester.pump();

        // 悬停打开纵向浮层并推进时间超过 2000ms，底栏保持可见 (opacity == 1.0)
        await tester.sendEventToBinding(pointer.hover(volBtnCenter));
        await tester.pumpAndSettle();

        final popoverTrackFinder = find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.constraints?.maxWidth ==
                  KonataPlaybackTokens.volumePopoverWidth &&
              w.constraints?.maxHeight ==
                  KonataPlaybackTokens.volumePopoverHeight,
        );
        expect(popoverTrackFinder, findsOneWidget);
        expect(
          find.descendant(
            of: popoverTrackFinder,
            matching: find.byType(Tooltip),
          ),
          findsNothing,
        );

        // 滚轮单格精确 +1% (50 -> 51)
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
        await tester.pump();
        expect(fakeCtrl.state.volume.round(), equals(51));

        // 纵向浮层内 0 延迟点击精准命中非 5 倍数：67
        final popRect = tester.getRect(popoverTrackFinder);
        const topPad = KonataPlaybackTokens.volumePopoverVerticalPadding;
        final trackH = KonataPlaybackTokens.volumePopoverHeight - topPad * 2;
        final y67 = popRect.top + topPad + (1.0 - 0.67) * trackH;
        await tester.sendEventToBinding(
          pointer.down(Offset(popRect.center.dx, y67)),
        );
        await tester.pump();
        await tester.sendEventToBinding(pointer.up());
        await tester.pump();
        expect(fakeCtrl.state.volume.round(), equals(67));

        // 按住左键拖拽出窄框 140px 之外纵向移动至 79 位置，仍持续 1:1 精确更新为 79，且底栏保持显示
        await tester.sendEventToBinding(
          pointer.down(Offset(popRect.center.dx, y67)),
        );
        await tester.pump();
        final y79 = popRect.top + topPad + (1.0 - 0.79) * trackH;
        await tester.sendEventToBinding(
          pointer.move(Offset(popRect.center.dx + 140, y79)),
        );
        await tester.pump();
        expect(fakeCtrl.state.volume.round(), equals(79));

        // 拖拽锁定期间推进 2600ms，底部胶囊必须保持 opacity == 1.0
        await tester.pump(const Duration(milliseconds: 2600));
        final bottomAnimatedOpacity = tester.widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byType(KonataPlaybackCapsule),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );
        expect(bottomAnimatedOpacity.opacity, equals(1.0));

        await tester.sendEventToBinding(pointer.up());
        await tester.pump();
        await tester.sendEventToBinding(pointer.hover(const Offset(20, 20)));
        await tester.pump(const Duration(milliseconds: 200));

        // 离开浮层并超时 2500ms 后，底栏与浮层一并淡出关闭
        await tester.pump(const Duration(milliseconds: 2500));
        await tester.pumpAndSettle();
        final fadedOpacity = tester.widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byType(KonataPlaybackCapsule),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        );
        expect(fadedOpacity.opacity, equals(0.0));
        expect(popoverTrackFinder, findsNothing);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '2. VideoSideSheet 在 1280x720 与 1024x640 下严格避让底部播控胶囊且字幕样式下拉无溢出',
      (tester) async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        SharedPreferences.setMockInitialValues({});
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);
        final req = _buildDummyRequest();

        for (final size in const [Size(1280, 720), Size(1024, 640)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);

          late _FakeVideoController fakeCtrl;
          await tester.pumpWidget(
            ProviderScope(
              key: ValueKey('side_sheet_viewport_${size.width}x${size.height}'),
              overrides: [
                libraryRepositoryProvider.overrideWithValue(repo),
                videoPlaybackProvider(req).overrideWith((ref) {
                  fakeCtrl = _FakeVideoController(ref, req);
                  fakeCtrl.forceState(
                    VideoPlaybackState(
                      isInitializing: false,
                      isBuffering: false,
                      hasFirstFrame: true,
                      isPlaying: true,
                      sideSheetOpen: true,
                      currentEpisode: req.episode,
                      currentVariant: req.variant,
                      volume: 80.0,
                      durationSeconds: 1440.0,
                    ),
                  );
                  return fakeCtrl;
                }),
              ],
              child: MaterialApp(
                theme: KonataTheme.darkTheme(),
                locale: const Locale('zh', 'CN'),
                supportedLocales: const [Locale('zh', 'CN')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                home: EmbeddedVideoPage(request: req),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final sheetRect = tester.getRect(
            find
                .descendant(
                  of: find.byType(VideoSideSheet),
                  matching: find.byType(ClipRRect),
                )
                .first,
          );
          final capsuleRect = tester.getRect(
            find.byType(KonataPlaybackCapsule),
          );
          expect(
            sheetRect.bottom,
            lessThanOrEqualTo(capsuleRect.top - 12.0),
          );

          // 切至「字幕」页并滚动到底部展开 ASS 样式覆写模式，零溢出
          await tester.tap(
            find.descendant(
              of: find.byType(VideoSideSheet),
              matching: find.text('字幕'),
            ),
          );
          await tester.pumpAndSettle();

          final subScrollable = find.descendant(
            of: find.byType(VideoSideSheet),
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(
            find.byType(KonataDropdown<SubtitleAssOverrideMode>),
            120.0,
            scrollable: subScrollable.first,
          );
          await tester.ensureVisible(
            find.byType(KonataDropdown<SubtitleAssOverrideMode>),
          );
          await tester.pumpAndSettle();
          expect(find.text('ASS 样式覆写模式'), findsOneWidget);
          await tester.tap(
            find.byType(KonataDropdown<SubtitleAssOverrideMode>),
          );
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(find.text('统一覆写字体与边距 (Force)'), findsOneWidget);
          // 再切回，确保关闭后可正常复原不残留 Overlay
          await tester.tap(find.text('高保真保留原盘特效 (推荐)').last);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();

          // 拖动「字号」滑块时自动由 preserveAss 提升为 scaleOnly；拖动「底部边距」自动提升为 forceStyle
          final sliders = find.descendant(
            of: find.byType(VideoSideSheet),
            matching: find.byType(Slider),
          );
          final fontSlider = tester.widget<Slider>(sliders.at(0));
          fontSlider.onChanged!(64.0);
          await tester.pumpAndSettle();
          expect(find.text('仅允许缩放字号 (Scale)'), findsOneWidget);

          final marginSlider = tester.widget<Slider>(sliders.at(1));
          marginSlider.onChanged!(0.0);
          await tester.pumpAndSettle();
          expect(find.text('统一覆写字体与边距 (Force)'), findsOneWidget);

          final resetBtn = find.descendant(
            of: find.byType(VideoSideSheet),
            matching: find.text('恢复默认'),
          );
          expect(resetBtn, findsOneWidget);
          await tester.ensureVisible(resetBtn);
          await tester.pumpAndSettle();
          await tester.tap(resetBtn);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(find.text('高保真保留原盘特效 (推荐)'), findsOneWidget);
          expect(resetBtn, findsNothing);
          expect(tester.takeException(), isNull);
        }
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      '3. SettingsPhotosStorageCard 五卡中性外观统一 + PhotoCustomCleanupDialog 精准清理且不误伤未选文件',
      (tester) async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final tempRoot = await tester.runAsync(
          () => Directory.systemTemp.createTemp('konata_stage6_photos_'),
        );
        addTearDown(() async {
          if (tempRoot != null && tempRoot.existsSync()) {
            await tempRoot.delete(recursive: true);
          }
        });
        final storageRoot = StorageRootService(overrideRoot: tempRoot);
        final photos = PhotosStorage(storageRoot: storageRoot);

        final db = KonataDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = DriftLibraryRepository(db);

        const workA = Work(id: 'wa', title: '作品甲', year: 2024);
        const workB = Work(id: 'wb', title: '作品乙', year: 2025);
        await repo.upsertWork(workA);
        await repo.upsertWork(workB);

        late File posterA;
        late File posterB;
        await tester.runAsync(() async {
          posterA = (await photos.writeArtwork(
            workId: workA.id,
            title: workA.title,
            subfolder: PhotoSubfolder.posters,
            fileKey: 'poster_a.png',
            bytes: _samplePng,
          ))!;
          posterB = (await photos.writeArtwork(
            workId: workB.id,
            title: workB.title,
            subfolder: PhotoSubfolder.posters,
            fileKey: 'poster_b.png',
            bytes: _samplePng,
          ))!;
        });

        expect(posterA.existsSync(), isTrue);
        expect(posterB.existsSync(), isTrue);

        // 仅含海报（scans + thumbnails == 0 B）时验证 5 卡边框一致且「自定义清理」依然可用
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              storageRootProvider.overrideWithValue(storageRoot),
              photosStorageProvider.overrideWithValue(photos),
              libraryRepositoryProvider.overrideWithValue(repo),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _samplePng,
              ),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const Scaffold(body: SettingsPhotosStorageCard()),
            ),
          ),
        );
        // 等待真实文件系统快照统计异步完成
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.textContaining('2 部作品 · 2 张').evaluate().isNotEmpty) {
            break;
          }
        }
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.textContaining('可再生缓存 (scans + thumbnails)：0 B（0 张）'),
          findsOneWidget,
        );

        // 5 张分类卡边框颜色与填充背景完全统一（无蓝色边框高亮）
        const categoryLabels = [
          '封面海报',
          '背景原画',
          '标题徽标',
          '分集剧照',
          '扫图微缩图',
        ];
        final decorations = <BoxDecoration>[];
        for (final label in categoryLabels) {
          final container = tester.widget<Container>(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(Container),
                )
                .first,
          );
          decorations.add(container.decoration! as BoxDecoration);
        }
        for (final dec in decorations.skip(1)) {
          expect(dec.color, equals(decorations.first.color));
          expect(dec.border, equals(decorations.first.border));
        }

        // 仅有海报时点击「自定义清理」仍能成功弹出弹窗
        expect(find.text('自定义清理'), findsOneWidget);
        await tester.tap(find.text('自定义清理'));
        await tester.pump();
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.text('清理所选').evaluate().isNotEmpty) break;
        }
        expect(find.byType(PhotoCustomCleanupDialog), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();

        // 补充 thumbnails 与已移出数据库的残留目录 scans，刷新后验证精准自定义清理
        late File thumbA;
        late File orphanScan;
        await tester.runAsync(() async {
          thumbA = (await photos.writeArtwork(
            workId: workA.id,
            title: workA.title,
            subfolder: PhotoSubfolder.thumbnails,
            fileKey: 'thumb_a.png',
            bytes: _samplePng,
          ))!;
          final orphanDir = Directory(
            p.join(
              photos.resolveRootDirectory().path,
              '已移除老番 [w_orphan_999]',
              PhotoSubfolder.scans.dirName,
            ),
          );
          await orphanDir.create(recursive: true);
          orphanScan = File(p.join(orphanDir.path, 'scan_01.webp'));
          await orphanScan.writeAsBytes(_samplePng, flush: true);
        });
        expect(thumbA.existsSync(), isTrue);
        expect(orphanScan.existsSync(), isTrue);

        await tester.tap(find.text('刷新'));
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.textContaining('3 部作品 · 4 张').evaluate().isNotEmpty) {
            break;
          }
        }

        await tester.tap(find.text('自定义清理'));
        await tester.pump();
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.text('清理所选').evaluate().isNotEmpty) break;
        }
        await tester.pumpAndSettle();

        expect(find.byType(PhotoCustomCleanupDialog), findsOneWidget);
        expect(find.text('残留目录'), findsOneWidget);

        // 验证 0 延迟拖拽弹窗标题栏
        final handleFinder = find.descendant(
          of: find.byType(KonataGlassDialog),
          matching: find.text('自定义图片清理'),
        );
        final beforeDrag = tester.getCenter(handleFinder);
        await tester.timedDragFrom(
          beforeDrag,
          const Offset(64, 32),
          const Duration(milliseconds: 120),
        );
        await tester.pumpAndSettle();
        final afterDrag = tester.getCenter(handleFinder);
        expect(afterDrag.dx, greaterThan(beforeDrag.dx + 30));

        // 取消全选 -> 验证计数归零 -> 单选作品甲 -> 再全选 -> 再仅选作品甲
        final dialogScope = find.byType(PhotoCustomCleanupDialog);
        await tester.tap(
          find.descendant(of: dialogScope, matching: find.text('取消全选')),
        );
        await tester.pumpAndSettle();
        expect(find.text('已选 0 / 3 部作品'), findsOneWidget);
        expect(find.textContaining('共 0 张图片'), findsOneWidget);

        await tester.tap(
          find.descendant(of: dialogScope, matching: find.text('全选')),
        );
        await tester.pumpAndSettle();
        expect(find.text('已选 3 / 3 部作品'), findsOneWidget);
        expect(find.textContaining('共 2 张图片'), findsOneWidget); // thumbA + orphanScan

        // 勾选「封面海报」后出现提示且总数增长到 4 张
        await tester.tap(
          find.descendant(
            of: dialogScope,
            matching: find.text('封面海报'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('需刷新元数据或重新刮削'), findsOneWidget);
        expect(find.textContaining('共 4 张图片'), findsOneWidget);

        // 切回「仅微缩图」恢复 2 张，并测试多选仅勾选「作品甲」
        await tester.tap(
          find.descendant(of: dialogScope, matching: find.text('仅微缩图')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('共 2 张图片'), findsOneWidget);

        await tester.tap(
          find.descendant(of: dialogScope, matching: find.text('取消全选')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: dialogScope, matching: find.text('作品甲')),
        );
        await tester.pumpAndSettle();
        expect(find.text('已选 1 / 3 部作品'), findsOneWidget);
        expect(find.textContaining('共 1 张图片'), findsOneWidget);

        // 执行清理：仅作品甲的 thumbnails 被删，作品甲 posters、作品乙 posters、残留目录 scans 100% 完好
        await tester.tap(
          find.descendant(of: dialogScope, matching: find.text('清理所选')),
        );
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.byType(PhotoCustomCleanupDialog).evaluate().isEmpty) break;
        }
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(PhotoCustomCleanupDialog), findsNothing);
        expect(thumbA.existsSync(), isFalse);
        expect(posterA.existsSync(), isTrue);
        expect(posterB.existsSync(), isTrue);
        expect(orphanScan.existsSync(), isTrue);
      },
    );
  });
}
