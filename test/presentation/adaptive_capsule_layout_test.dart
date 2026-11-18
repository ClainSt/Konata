import 'package:ccplayer/application/playback/audio_playback_notifier.dart';
import 'package:ccplayer/application/playback/playback_preferences_provider.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/presentation/audio/mini_audio_bar.dart';
import 'package:ccplayer/presentation/shell/adaptive_capsule_layout.dart';
import 'package:ccplayer/presentation/shell/capsule_navigation.dart';
import 'package:ccplayer/presentation/theme/konata_playback_tokens.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/adaptive_action_header.dart';
import 'package:ccplayer/presentation/widgets/playback/konata_playback_capsule.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Audio extends AudioPlaybackNotifier {
  _Audio(super.ref) {
    state = _initial;
  }

  void emit(AudioPlaybackState next) => state = next;
  int previousCalls = 0;
  int nextCalls = 0;

  @override
  Future<void> previous() async {
    previousCalls += 1;
  }

  @override
  Future<void> next() async {
    nextCalls += 1;
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
      miniKind: ref.watch(activeFloatingMiniPlayerKindProvider),
      normalizedMiniAnchor: ref.watch(floatingMiniWindowAnchorProvider),
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

  test('手机矮横屏始终维持底部水平居中紧凑导航且悬浮小窗不压住导航胶囊', () {
    final cramped = AdaptiveCapsuleLayout(
      size: const Size(568, 320),
      safe: const EdgeInsets.fromLTRB(0, 24, 0, 20),
      android: true,
      miniKind: FloatingMiniPlayerKind.audio,
    );
    expect(cramped.shortPhone, isTrue);
    expect(cramped.verticalNavigation, isFalse);
    expect(cramped.navigationRect.center.dx, closeTo(284.0, 0.5));
    final miniRect = cramped.floatingMiniWindowRect!;
    expect(miniRect.overlaps(cramped.navigationRect), isFalse);
  });

  for (final size in [
    const Size(1920, 1080),
    const Size(1280, 800),
    const Size(800, 1280),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('真实播放宿主悬浮小窗热区、进度叶子隔离与 Toast 协同避让 $size', (tester) async {
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

      final miniFinder = find.byKey(
        const ValueKey('konata_floating_mini_player'),
      );
      expect(miniFinder, findsOneWidget);
      // 音频悬浮小窗不显示曲名与循环键
      expect(find.text('测试曲目'), findsNothing);
      expect(tester.takeException(), isNull);

      for (final key in [
        'floating_mini_surface_tap_target',
        'floating_mini_audio_prev',
        'floating_mini_audio_play_pause',
        'floating_mini_audio_next',
      ]) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.width, greaterThanOrEqualTo(48));
      }

      final container = ProviderScope.containerOf(tester.element(miniFinder));
      // 首次轻触封面显现右上 × 与左上展开图标，再次轻触进入全屏音频页
      expect(
        find.byKey(const ValueKey('floating_mini_close_button')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('floating_mini_surface_tap_target')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('floating_mini_close_button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('floating_mini_expand_button')),
      );
      await tester.pump();
      expect(container.read(immersiveAudioExpandedProvider), isTrue);
      container.read(immersiveAudioExpandedProvider.notifier).state = false;
      await tester.pumpAndSettle();

      // 高频进度跳秒只驱动进度叶子，不带动宿主列表或导航胶囊重建
      final rebuilt = <Type>[];
      debugOnRebuildDirtyWidget = (element, _) =>
          rebuilt.add(element.widget.runtimeType);
      final list = tester.widget(find.byType(_PageList));
      audio.emit(_initial.copyWith(positionSeconds: 45));
      await tester.pump();
      expect(identical(tester.widget(find.byType(_PageList)), list), isTrue);
      debugOnRebuildDirtyWidget = null;
      expect(
        rebuilt.where((type) => type.toString() == '_FloatingAudioProgressLeaf'),
        isNotEmpty,
      );
      expect(
        rebuilt.where(
          (type) =>
              type == CapsuleNavigation ||
              type == Scaffold ||
              type == _PageList,
        ),
        isEmpty,
      );

      if (size.width != 1920) {
        final before = tester.getTopLeft(miniFinder);
        container.read(capsuleNavigationHiddenProvider.notifier).state = true;
        await tester.pumpAndSettle();
        final after = tester.getTopLeft(miniFinder);
        if (size.shortestSide < 600 && size.height > 500) {
          expect(after.dy, greaterThan(before.dy));
        }

        audio.emit(_initial.copyWith(errorMessage: '播放错误'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final errorClose = find.byKey(const ValueKey('konata_toast_close'));
        final errorCloseRect = tester.getRect(errorClose);
        expect(errorCloseRect.width, greaterThanOrEqualTo(48));
        expect(errorCloseRect.height, greaterThanOrEqualTo(48));
        await tester.tapAt(errorCloseRect.center);
        await tester.pumpAndSettle();
        expect(find.text('播放错误'), findsNothing);
      }

      audio.emit(const AudioPlaybackState());
      await tester.pumpAndSettle();
      expect(miniFinder, findsNothing);
      expect(tester.takeException(), isNull);
      debugOnRebuildDirtyWidget = null;
      debugDefaultTargetPlatformOverride = null;
    });
  }

  const safe = EdgeInsets.fromLTRB(0, 24, 0, 20);
  for (final size in [const Size(1280, 800), const Size(800, 1280)]) {
    test('平板左竖胶囊与同规格悬浮小窗安全停靠 $size', () {
      final layout = AdaptiveCapsuleLayout(
        size: size,
        safe: safe,
        android: true,
        miniKind: FloatingMiniPlayerKind.video,
      );
      expect(layout.tablet, isTrue);
      expect(layout.navigationRect.left, 0);
      expect(layout.navigationRect.height, lessThan(size.height));
      expect(
        layout.navigationRect.center.dy,
        safe.top + (size.height - safe.vertical) / 2,
      );
      final miniRect = layout.floatingMiniWindowRect!;
      expect(
        miniRect.width,
        equals(KonataPlaybackTokens.floatingMiniVideoWidth),
      );
      expect(
        miniRect.height,
        equals(KonataPlaybackTokens.floatingMiniVideoHeight),
      );
      expect(miniRect.overlaps(layout.navigationRect), isFalse);
    });
  }

  test('手机竖屏悬浮小窗避让导航与二级页下沉补位', () {
    final normal = AdaptiveCapsuleLayout(
      size: const Size(390, 844),
      safe: safe,
      android: true,
      miniKind: FloatingMiniPlayerKind.audio,
    );
    final detail = AdaptiveCapsuleLayout(
      size: normal.size,
      safe: safe,
      android: true,
      navigationVisible: false,
      miniKind: FloatingMiniPlayerKind.audio,
    );
    expect(normal.navigationRect.center.dx, 195);
    final normalMini = normal.floatingMiniWindowRect!;
    final detailMini = detail.floatingMiniWindowRect!;
    expect(
      normal.navigationRect.top - normalMini.bottom,
      closeTo(KonataPlaybackTokens.floatingMiniNavigationGap, 0.5),
    );
    expect(detailMini.bottom, greaterThan(normalMini.bottom));
    expect(detail.bottomClearance, lessThan(normal.bottomClearance));
  });

  test('桌面宽屏仍为桌面导航且无活跃小窗时零底距', () {
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
