import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_localizations/flutter_localizations.dart' show GlobalWidgetsLocalizations;
import 'package:konata/application/providers/konata_value_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:konata/application/playback/audio_playback_notifier.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/providers/artwork_provider.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/presentation/audio/immersive_audio_page.dart';
import 'package:konata/presentation/audio/mini_audio_bar.dart';
import 'package:konata/presentation/detail/detail_gear_menu.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_glass_dialog.dart';
import 'package:konata/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:konata/presentation/widgets/playback/konata_spec_badge.dart';
import 'package:konata/presentation/widgets/playback/konata_volume_control.dart';

final Uint8List _testCoverPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
  0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A, 0x73, 0x00, 0x00, 0x00,
  0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x80,
  0x01, 0x31, 0x20, 0x05, 0x00, 0x32, 0x10, 0x04, 0x01, 0x96, 0x6E, 0x2B,
  0x1B, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
  0x82,
]);

class _Stage3StubAudioNotifier extends AudioPlaybackNotifier {
  _Stage3StubAudioNotifier(AudioPlaybackState initial)
    : super(initialState: initial);

  @override
  Future<void> togglePlayPause() async {
    state = state.copyWith(isPlaying: !state.isPlaying);
  }

  @override
  Future<void> previous() async {}

  @override
  Future<void> next() async {}
}

AudioPlaybackState _buildSampleAudioState() {
  const work = Work(id: 'w_stage3', title: '孤独摇滚！');
  const v1 = MediaVariant(
    id: 'v1',
    workId: 'w_stage3',
    sourceId: 's1',
    relativePath: 'CD/01.flac',
    fileName: '01.flac',
    fileSize: 1024,
    assetKind: AssetKind.cdAlbum,
  );
  const v2 = MediaVariant(
    id: 'v2',
    workId: 'w_stage3',
    sourceId: 's1',
    relativePath: 'CD/02.flac',
    fileName: '02.flac',
    fileSize: 1024,
    assetKind: AssetKind.cdAlbum,
  );
  return AudioPlaybackState(
    isActive: true,
    isPlaying: true,
    queue: const [
      AudioQueueItem(
        id: 'q1',
        work: work,
        variant: v1,
        title: '青春コンプレックス',
        albumTitle: '結束バンド',
        duration: Duration(seconds: 204),
      ),
      AudioQueueItem(
        id: 'q2',
        work: work,
        variant: v2,
        title: 'ひとりぼっち東京',
        albumTitle: '結束バンド',
        duration: Duration(seconds: 232),
      ),
    ],
    currentIndex: 0,
    positionSeconds: 42.0,
    durationSeconds: 204.0,
    volume: 85.0,
    audioCodecLabel: 'FLAC',
    sampleRateAndBitDepthLabel: '48kHz/24bit',
    cover: MemoryAudioCover(_testCoverPng),
  );
}

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('阶段 3 · 手机与平板双方向音频键位等距、右侧徽章与模态返回抽屉测试', () {
    testWidgets('12 & 21. 手机横屏与平板横竖屏五键严格等距（循环、上一首、播放暂停居中、下一首、音量），平板格式徽章固定最右', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewPadding();
          tester.view.resetPadding();
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              konataDatabaseProvider.overrideWith((ref) {
                final db = KonataDatabase(NativeDatabase.memory());
                ref.onDispose(db.close);
                return db;
              }),
              playbackPreferencesProvider.overrideWith(
                () => PlaybackPreferencesNotifier(enablePersistence: false),
              ),
              tmdbImageLoaderProvider.overrideWithValue(
                (_, {targetWidth, imageSize}) async => _testCoverPng,
              ),
              audioPlaybackProvider.overrideWith(
                () => _Stage3StubAudioNotifier(_buildSampleAudioState()),
              ),
            ],
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const ImmersiveAudioPage(),
            ),
          ),
        );

        // 1. 手机横屏（844x390）：与平板同源底部居中光学长胶囊，五键从左到右等距对称（循环/上一项/播放暂停/下一项/歌词队列切换）
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(844, 390);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        expect(find.byType(KonataPlaybackCapsule), findsOneWidget);
        final phoneCapsuleCenter = tester
            .getCenter(find.byType(KonataPlaybackCapsule))
            .dx;
        final phoneXs = <double>[
          tester
              .getCenter(find.byKey(const ValueKey('konata_audio_loop_button')))
              .dx,
          tester.getCenter(find.byTooltip('上一项')).dx,
          tester
              .getCenter(
                find.byKey(const ValueKey('konata_capsule_play_pause_button')),
              )
              .dx,
          tester.getCenter(find.byTooltip('下一项')).dx,
          tester
              .getCenter(
                find.byKey(const ValueKey('immersive_toggle_pane_button')),
              )
              .dx,
        ];

        for (var i = 0; i < phoneXs.length - 1; i++) {
          expect(phoneXs[i], lessThan(phoneXs[i + 1]));
        }
        final phoneStep = phoneXs[1] - phoneXs[0];
        for (var i = 1; i < phoneXs.length - 1; i++) {
          expect(phoneXs[i + 1] - phoneXs[i], closeTo(phoneStep, 0.5));
        }
        expect(phoneXs[2], closeTo(phoneCapsuleCenter, 0.5));

        // 2. 平板横屏（1280x800）与平板竖屏（800x1280）：五键等距对称（循环/上一项/播放暂停/下一项/歌词队列切换），右侧为规格徽章与音量
        for (final tabletSize in const [Size(1280, 800), Size(800, 1280)]) {
          tester.view.physicalSize = tabletSize;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final capsuleCenter = tester
              .getCenter(find.byType(KonataPlaybackCapsule))
              .dx;
          final tabletXs = <double>[
            tester
                .getCenter(
                  find.byKey(const ValueKey('konata_audio_loop_button')),
                )
                .dx,
            tester.getCenter(find.byTooltip('上一项')).dx,
            tester
                .getCenter(
                  find.byKey(
                    const ValueKey('konata_capsule_play_pause_button'),
                  ),
                )
                .dx,
            tester.getCenter(find.byTooltip('下一项')).dx,
            tester
                .getCenter(
                  find.byKey(const ValueKey('immersive_toggle_pane_button')),
                )
                .dx,
          ];

          for (var i = 0; i < tabletXs.length - 1; i++) {
            expect(tabletXs[i], lessThan(tabletXs[i + 1]));
          }
          final tabletStep = tabletXs[1] - tabletXs[0];
          for (var i = 1; i < tabletXs.length - 1; i++) {
            expect(tabletXs[i + 1] - tabletXs[i], closeTo(tabletStep, 0.5));
          }
          // 播放暂停严格处于第 3 位正中央及控制栏水平中心
          expect(tabletXs[2], closeTo(capsuleCenter, 0.5));

          // 规格徽章与音量键位于五键最右侧之后
          final toggleRect = tester.getRect(
            find.byKey(const ValueKey('immersive_toggle_pane_button')),
          );
          final badgeRect = tester.getRect(find.byType(KonataSpecBadge));
          final volRect = tester.getRect(find.byType(KonataVolumeControl));
          expect(badgeRect.left, greaterThan(toggleRect.right));
          expect(volRect.left, greaterThan(badgeRect.right));
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('06. 手机竖屏播放队列抽屉与全站抽屉/菜单：支持顶部横条跟手下拉收起及 Android 系统侧滑返回栈', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
        tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewPadding();
          tester.view.resetPadding();
        });

        final container = ProviderContainer(
          overrides: [
            konataDatabaseProvider.overrideWith((ref) {
              final db = KonataDatabase(NativeDatabase.memory());
              ref.onDispose(db.close);
              return db;
            }),
            playbackPreferencesProvider.overrideWith(
              () => PlaybackPreferencesNotifier(enablePersistence: false),
            ),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => _testCoverPng,
            ),
            audioPlaybackProvider.overrideWith(
              () => _Stage3StubAudioNotifier(_buildSampleAudioState()),
            ),
            immersiveAudioExpandedProvider.overrideWith(
              () => KonataValueNotifier.value(true),
            ),
          ],
        );
        addTearDown(container.dispose);

        late BuildContext homeContext;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: KonataTheme.darkTheme(),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) => MiniAudioOverlayHost(
                child: child ?? const SizedBox.shrink(),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (ctx) {
                    homeContext = ctx;
                    return Align(
                      alignment: Alignment.topRight,
                      child: DetailOpsCapsule(
                        isExpanded: false,
                        hasContent: true,
                        onOpenFullList: () {},
                        onManualMatch: () {},
                        onManualEdit: () {},
                        onEditPoster: () {},
                        onEditBackdrop: () {},
                        onHideWork: () {},
                        onDeleteWork: () {},
                        onRescrape: () {},
                        onOpenLocalDir: () {},
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. 打开播放队列抽屉，验证顶部横条 1:1 跟手下移，小距离回弹、大距离关闭
        await tester.tap(
          find.byKey(const ValueKey('portrait_open_queue_button')),
        );
        await tester.pumpAndSettle();
        final sheetFinder = find.byKey(
          const ValueKey('portrait_queue_sheet_overlay'),
        );
        final handleFinder = find.byKey(
          const ValueKey('portrait_queue_drag_handle'),
        );
        expect(sheetFinder, findsOneWidget);
        expect(handleFinder, findsOneWidget);

        final topBeforeDrag = tester.getTopLeft(sheetFinder).dy;
        final gesture = await tester.startGesture(tester.getCenter(handleFinder));
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        // 跟手实时下移
        expect(tester.getTopLeft(sheetFinder).dy, closeTo(topBeforeDrag + 30, 2.0));
        await gesture.up();
        await tester.pumpAndSettle();
        // 30dp < 阈值且无快速初速，平滑回弹保持打开
        expect(sheetFinder, findsOneWidget);

        // 按住顶部横条下拉 90dp 触发关闭
        await tester.drag(handleFinder, const Offset(0, 90));
        await tester.pumpAndSettle();
        expect(sheetFinder, findsNothing);

        // 2. 再次打开队列抽屉，触发 Android 系统侧滑返回（handlePopRoute）：
        //    必须先收起队列抽屉，全屏音频页保持展开！
        await tester.tap(
          find.byKey(const ValueKey('portrait_open_queue_button')),
        );
        await tester.pumpAndSettle();
        expect(sheetFinder, findsOneWidget);
        expect(container.read(immersiveAudioExpandedProvider), isTrue);

        final popConsumed1 = await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(popConsumed1, isTrue);
        expect(sheetFinder, findsNothing);
        expect(container.read(immersiveAudioExpandedProvider), isTrue);

        // 再次触发系统侧滑返回：收起全屏音频页
        final popConsumed2 = await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(popConsumed2, isTrue);
        expect(container.read(immersiveAudioExpandedProvider), isFalse);

        // 3. 验证其他抽屉与菜单（详情齿轮菜单 & 公共底部抽屉）同样支持系统返回与横条下拉
        await tester.tap(find.byTooltip('作品管理选项'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('detail_gear_menu_container')),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('detail_gear_menu_container')),
          findsNothing,
        );

        showKonataGlassBottomSheet<void>(
          context: homeContext,
          title: '排序与筛选',
          builder: (_) => const SizedBox(height: 160, child: Text('面板内容')),
        );
        await tester.pumpAndSettle();
        expect(find.text('排序与筛选'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('排序与筛选'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
