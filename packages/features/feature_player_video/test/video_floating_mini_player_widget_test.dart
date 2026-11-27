import 'package:feature_player_video/feature_player_video.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/video_test_harness.dart';

void main() {
  group('VideoFloatingMiniPlayer 16:9 可拖拽悬浮小窗组件测试', () {
    testWidgets('保持 16:9 比例并直连叶子坐标监听完成拖拽、展开与关闭操作', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = await VideoTestHarness.create();
      addTearDown(harness.dispose);
      final seeded = await harness.seedSampleAnime();
      final controller = harness.createController(enablePeriodicTimers: false);
      addTearDown(controller.dispose);

      await controller.initialize(VideoLaunchRequest(workId: seeded.work.id));
      controller.handleDurationUpdate(1000.0);
      controller.handlePositionUpdate(250.0);

      final offsetNotifier = ValueNotifier<Offset>(const Offset(40, 60));
      addTearDown(offsetNotifier.dispose);

      var controllerRebuilds = 0;
      controller.addListener(() => controllerRebuilds++);

      var expanded = false;
      var closed = false;

      await tester.pumpWidget(
        wrapVideoTestApp(
          child: SizedBox(
            width: 1280,
            height: 720,
            child: Stack(
              children: [
                VideoFloatingMiniPlayer(
                  controller: controller,
                  offsetNotifier: offsetNotifier,
                  viewportSize: const Size(1280, 720),
                  width: 320,
                  onExpand: () => expanded = true,
                  onClose: () => closed = true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final miniFinder = find.byKey(
        const ValueKey('video_floating_mini_player'),
      );
      expect(miniFinder, findsOneWidget);

      final rect = tester.getRect(miniFinder);
      expect(rect.width, closeTo(320, 0.1));
      expect(rect.height, closeTo(180, 0.1));
      expect(rect.width / rect.height, closeTo(16.0 / 9.0, 0.01));

      // 拖拽悬浮小窗，坐标仅更新叶子偏移监听器，零控制器重绘通知。
      await tester.drag(miniFinder, const Offset(120, 85));
      await tester.pump();

      expect(offsetNotifier.value.dx, greaterThan(100));
      expect(offsetNotifier.value.dy, greaterThan(100));
      expect(controllerRebuilds, 0);

      // 同一帧内连续移动也必须累计全局位移，而不是反复使用旧布局坐标。
      final before = offsetNotifier.value;
      final gesture = await tester.startGesture(tester.getCenter(miniFinder));
      await gesture.moveBy(const Offset(30, 20));
      await gesture.moveBy(const Offset(40, 10));
      await gesture.moveBy(const Offset(50, 30));
      await gesture.up();
      await tester.pump();
      expect(offsetNotifier.value.dx - before.dx, closeTo(120, 1));
      expect(offsetNotifier.value.dy - before.dy, closeTo(60, 1));
      expect(controllerRebuilds, 0);

      // 拖出边界时自动钳制于容器安全边距内。
      await tester.drag(miniFinder, const Offset(2000, 2000));
      await tester.pump();
      expect(offsetNotifier.value.dx, lessThanOrEqualTo(1280 - 320 - 12));
      expect(offsetNotifier.value.dy, lessThanOrEqualTo(720 - 180 - 12));

      // 切换播放暂停、回弹全屏及关闭动作验证。
      await tester.tap(
        find.byKey(const ValueKey('mini_player_play_pause_button')),
      );
      await tester.pump();
      expect(controller.state.isPlaying, isTrue);

      await tester.tap(find.byKey(const ValueKey('mini_player_expand_button')));
      await tester.pump();
      expect(expanded, isTrue);

      await tester.tap(find.byKey(const ValueKey('mini_player_close_button')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });
  });
}
