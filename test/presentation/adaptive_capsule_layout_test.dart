import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/widgets/design_system/adaptive_action_header.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_glass_capsule.dart';
import 'package:ccplayer/presentation/shell/adaptive_capsule_layout.dart';
import 'package:ccplayer/presentation/shell/capsule_navigation.dart';
import 'package:ccplayer/presentation/theme/konata_adaptive_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Audio extends AudioPlaybackNotifier {
  _Audio(super.ref) {
    state = _initial;
  }
  void emit(AudioPlaybackState next) => state = next;
  double? seek;
  int? selectedIndex;

  @override
  Future<void> playQueueIndex(int index) async {
    selectedIndex = index;
  }

  @override
  Future<void> seekRelativeTrackSeconds(double seconds) async {
    seek = seconds;
  }
}

class _ShellBody extends ConsumerWidget {
  const _ShellBody();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(capsuleNavigationHiddenProvider);
    final layout = AdaptiveCapsuleLayout(
      size: MediaQuery.sizeOf(context),
      safe: MediaQuery.paddingOf(context),
      android: true,
      navigationVisible: !hidden,
      playerVisible: true,
    );
    return Stack(
      children: [
        const _PageList(),
        if (!hidden)
          Positioned.fromRect(
            rect: layout.navigationRect,
            child: CapsuleNavigation(
              vertical: layout.tablet,
              selectedIndex: 0,
              onSelected: (_) {},
            ),
          ),
      ],
    );
  }
}

class _PageList extends StatelessWidget {
  const _PageList();
  @override
  Widget build(BuildContext context) => ListView.builder(
    itemCount: 5,
    itemBuilder: (_, index) => Text('页面列表 $index'),
  );
}

const _initial = AudioPlaybackState(
  isActive: true,
  isPlaying: true,
  currentIndex: 0,
  durationSeconds: 180,
  queue: [
    AudioQueueItem(
      id: 'track',
      title: '测试曲目',
      work: Work(id: 'work', title: '作品'),
      variant: MediaVariant(
        id: 'variant',
        workId: 'work',
        sourceId: 'source',
        relativePath: 'music.flac',
        fileName: 'music.flac',
        fileSize: 1,
      ),
    ),
  ],
);

void main() {
  for (final size in [
    const Size(1920, 1080),
    const Size(1280, 800),
    const Size(800, 1280),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('队列单行与空演唱者子曲目触控热区 $size', (tester) async {
      final android = size.width != 1920;
      debugDefaultTargetPlatformOverride = android
          ? TargetPlatform.android
          : TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late _Audio audio;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlaybackProvider.overrideWith((ref) {
              audio = _Audio(ref);
              audio.emit(
                _initial.copyWith(
                  queue: [
                    _initial.queue.single,
                    AudioQueueItem(
                      id: 'cue',
                      work: _initial.queue.single.work,
                      variant: _initial.queue.single.variant,
                      title: '无演唱者子曲目',
                      cueDiscTitle: '母碟',
                      cueStartSeconds: 0,
                      cueEndSeconds: 60,
                    ),
                  ],
                ),
              );
              return audio;
            }),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            builder: (_, child) => MiniAudioOverlayHost(child: child!),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (android) {
        await tester.longPress(
          find
              .ancestor(
                of: find.byKey(const ValueKey('mini_title_target')),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
      } else {
        await tester.tap(find.byTooltip('展开专辑曲目'));
      }
      await tester.pumpAndSettle();
      expect(find.text('专辑曲目 (2)'), findsOneWidget);
      for (final entry in {'测试曲目': 0, '无演唱者子曲目': 1}.entries) {
        final title = find.descendant(
          of: find.byType(ListView),
          matching: find.text(entry.key),
        );
        final target = find
            .ancestor(of: title, matching: find.byType(GestureDetector))
            .first;
        final rect = tester.getRect(target);
        if (android) {
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.width, greaterThanOrEqualTo(48));
        } else {
          final container = tester.widget<AnimatedContainer>(
            find
                .descendant(
                  of: target,
                  matching: find.byType(AnimatedContainer),
                )
                .first,
          );
          expect(container.constraints, isNull);
          expect(
            container.padding,
            EdgeInsets.fromLTRB(
              entry.value == 1 ? 26 : 10,
              entry.value == 1 ? 6 : 8,
              10,
              entry.value == 1 ? 6 : 8,
            ),
          );
        }
        audio.selectedIndex = null;
        await tester.tapAt(rect.topLeft + const Offset(1, 1));
        await tester.pump();
        expect(audio.selectedIndex, entry.value);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }
  testWidgets('自适应顶栏窄屏折叠搜索图标、点击原地展开与清除', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var query = '';
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: AdaptiveActionHeader(
              title: '全部作品',
              searchQuery: query,
              searchFocusNode: focus,
              onSearchChanged: (value) => query = value,
            ),
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '作品');
      await tester.pump();
      expect(query, '作品');
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(query, '');
      await tester.tap(find.byTooltip('收起搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
  test('手机矮横屏底部不足并排时自动切换左竖导航释放水平空间', () {
    final cramped = AdaptiveCapsuleLayout(
      size: const Size(568, 320),
      safe: const EdgeInsets.fromLTRB(0, 24, 0, 20),
      android: true,
      playerVisible: true,
    );
    expect(cramped.shortPhone, isTrue);
    expect(cramped.verticalNavigation, isTrue);
    expect(cramped.leftClearance, greaterThan(0));
    expect(cramped.playerRect.left, greaterThanOrEqualTo(cramped.leftClearance));
  });
  testWidgets('手机窄屏 MiniAudioBar 固定展示循环与上下首及播放暂停四键且零溢出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late _Audio audio;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlaybackProvider.overrideWith((ref) => audio = _Audio(ref)),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 336,
                    maxHeight: 64,
                  ),
                  child: const MiniAudioBar(),
                ),
              ),
            ),
          ),
        ),
      );
      audio.emit(
        _initial.copyWith(
          queue: [
            AudioQueueItem(
              id: 'track_narrow_1',
              title: '超长单曲名称测试避免垂直成列挤压',
              albumTitle: 'Album',
              work: _initial.queue.single.work,
              variant: _initial.queue.single.variant,
            ),
          ],
          isPlaying: true,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('mini_audio_loop_mode')), findsOneWidget);
      expect(find.byTooltip('上一曲'), findsOneWidget);
      expect(find.byTooltip('暂停'), findsOneWidget);
      expect(find.byTooltip('下一曲'), findsOneWidget);
      expect(find.byIcon(Icons.queue_music_rounded), findsNothing);
      expect(find.text('超长单曲名称测试避免垂直成列挤压'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });
  for (final size in [
    const Size(1920, 1080),
    const Size(1280, 800),
    const Size(800, 1280),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('真实播放宿主布局退出与进度隔离 $size', (tester) async {
      debugDefaultTargetPlatformOverride = size.width == 1920
          ? TargetPlatform.windows
          : TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        debugOnRebuildDirtyWidget = null;
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late _Audio audio;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioPlaybackProvider.overrideWith((ref) => audio = _Audio(ref)),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: const EdgeInsets.fromLTRB(0, 24, 0, 20)),
              child: MiniAudioOverlayHost(child: child!),
            ),
            home: const Scaffold(body: _ShellBody()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('测试曲目'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (size.width != 1920) {
        for (final key in [
          'mini_cover_target',
          'mini_title_target',
          'mini_progress_target',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.width, greaterThanOrEqualTo(48));
        }
        final container = ProviderScope.containerOf(
          tester.element(find.byType(MiniAudioBar)),
        );
        for (final key in ['mini_cover_target', 'mini_title_target']) {
          await tester.tap(
            find
                .ancestor(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(GestureDetector),
                )
                .first,
          );
          expect(container.read(immersiveAudioExpandedProvider), isTrue);
          container.read(immersiveAudioExpandedProvider.notifier).state = false;
        }
        await tester.pumpAndSettle();
        final rebuilt = <Type>[];
        debugOnRebuildDirtyWidget = (element, _) =>
            rebuilt.add(element.widget.runtimeType);
        final glass = tester.widget(find.byType(KonataGlassCapsule).first);
        final list = tester.widget(find.byType(_PageList));
        audio.emit(_initial.copyWith(positionSeconds: 30));
        await tester.pump();
        expect(
          identical(
            tester.widget(find.byType(KonataGlassCapsule).first),
            glass,
          ),
          isTrue,
        );
        expect(identical(tester.widget(find.byType(_PageList)), list), isTrue);
        debugOnRebuildDirtyWidget = null;
        expect(
          rebuilt.where((type) => type.toString() == '_TouchAudioProgress'),
          isNotEmpty,
        );
        expect(
          rebuilt.where(
            (type) =>
                type == KonataGlassCapsule ||
                type == CapsuleNavigation ||
                type == Scaffold ||
                type == _PageList,
          ),
          isEmpty,
        );
        final progress = find.byKey(const ValueKey('mini_progress_target'));
        final rect = tester.getRect(progress);
        await tester.dragFrom(
          Offset(rect.left + 20, rect.bottom - 1),
          const Offset(40, 0),
        );
        expect(audio.seek, isNotNull);
      }
      if (size.width != 1920) {
        final context = tester.element(find.byType(MiniAudioBar));
        final container = ProviderScope.containerOf(context);
        final before = tester.getTopLeft(find.byType(MiniAudioBar));
        container.read(capsuleNavigationHiddenProvider.notifier).state = true;
        await tester.pumpAndSettle();
        final after = tester.getTopLeft(find.byType(MiniAudioBar));
        if (size.shortestSide < 600 && size.height > 500) {
          expect(after.dy, greaterThan(before.dy));
        }
        audio.emit(_initial.copyWith(errorMessage: '播放错误'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final error = tester.getRect(find.text('播放错误'));
        final player = tester.getRect(find.byType(MiniAudioBar));
        expect(error.bottom, lessThanOrEqualTo(player.top));
        final errorClose = find.byKey(const ValueKey('konata_toast_close'));
        final errorCloseRect = tester.getRect(errorClose);
        expect(errorCloseRect.width, greaterThanOrEqualTo(48));
        expect(errorCloseRect.height, greaterThanOrEqualTo(48));
        await tester.tapAt(errorCloseRect.center);
        await tester.pumpAndSettle();
        expect(find.text('播放错误'), findsNothing);

        await tester.longPress(
          find
              .ancestor(
                of: find.byKey(const ValueKey('mini_title_target')),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text('专辑曲目 (1)'), findsOneWidget);
        final queueClose = find.byKey(const ValueKey('mini_queue_close'));
        final queueCloseRect = tester.getRect(queueClose);
        expect(queueCloseRect.width, greaterThanOrEqualTo(48));
        expect(queueCloseRect.height, greaterThanOrEqualTo(48));
        await tester.tapAt(queueCloseRect.topLeft + const Offset(1, 1));
        await tester.pumpAndSettle();
        expect(find.text('专辑曲目 (1)'), findsNothing);
      }
      audio.emit(const AudioPlaybackState());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(find.text('测试曲目'), findsWidgets);
      await tester.pumpAndSettle();
      expect(find.text('测试曲目'), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
  const safe = EdgeInsets.fromLTRB(0, 24, 0, 20);
  for (final size in [const Size(1280, 800), const Size(800, 1280)]) {
    test('平板左竖胶囊与右侧居中播放坞 $size', () {
      final layout = AdaptiveCapsuleLayout(
        size: size,
        safe: safe,
        android: true,
        playerVisible: true,
      );
      expect(layout.tablet, isTrue);
      expect(layout.navigationRect.left, 0);
      expect(layout.navigationRect.height, lessThan(size.height));
      expect(
        layout.navigationRect.center.dy,
        safe.top + (size.height - safe.vertical) / 2,
      );
      expect(layout.playerRect.height, 64);
      expect(layout.playerRect.width, lessThanOrEqualTo(600));
      expect(layout.playerRect.center.dx, size.width / 2);
      expect(
        size.height - layout.playerRect.bottom,
        safe.bottom + KonataAdaptiveTokens.tabletBottomInset,
      );
    });
  }
  test('手机竖屏双层与二级页补位', () {
    final normal = AdaptiveCapsuleLayout(
      size: const Size(390, 844),
      safe: safe,
      android: true,
      playerVisible: true,
    );
    final detail = AdaptiveCapsuleLayout(
      size: normal.size,
      safe: safe,
      android: true,
      playerVisible: true,
      navigationVisible: false,
    );
    expect(normal.navigationRect.center.dx, 195);
    expect(normal.playerRect.left, 12);
    expect(
      normal.navigationRect.top - normal.playerRect.bottom,
      KonataAdaptiveTokens.capsuleStackGap,
    );
    expect(
      detail.playerRect.bottom - normal.playerRect.bottom,
      normal.navigationThickness + KonataAdaptiveTokens.capsuleStackGap,
    );
    expect(detail.bottomClearance, lessThan(normal.bottomClearance));
  });
  test('手机矮横屏并排且不重叠', () {
    final layout = AdaptiveCapsuleLayout(
      size: const Size(844, 390),
      safe: safe,
      android: true,
      playerVisible: true,
    );
    expect(layout.shortPhone, isTrue);
    expect(layout.playerRect.left - layout.navigationRect.right, 12);
    expect(layout.playerRect.bottom, layout.navigationRect.bottom);
    expect(layout.playerRect.overlaps(layout.navigationRect), isFalse);
  });
  test('桌面宽屏仍为桌面导航', () {
    final layout = AdaptiveCapsuleLayout(
      size: const Size(1920, 1080),
      safe: safe,
      android: false,
    );
    expect(layout.tablet, isFalse);
    expect(layout.leftClearance, 0);
    expect(layout.bottomClearance, 0);
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 800),
    const Size(800, 1280),
  ]) {
    testWidgets('导航四视口热区与零溢出 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final layout = AdaptiveCapsuleLayout(
        size: size,
        safe: safe,
        android: true,
      );
      var selected = -1;
      await tester.pumpWidget(
        MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fromRect(
                  rect: layout.navigationRect,
                  child: CapsuleNavigation(
                    vertical: layout.tablet,
                    selectedIndex: 0,
                    onSelected: (index) => selected = index,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (final element in find.byType(KonataCapsuleIconButton).evaluate()) {
        final box = element.renderObject! as RenderBox;
        expect(box.size.width, greaterThanOrEqualTo(48));
        expect(box.size.height, greaterThanOrEqualTo(48));
      }
      await tester.tap(find.byType(KonataCapsuleIconButton).last);
      expect(selected, 3);
    });
  }
}
