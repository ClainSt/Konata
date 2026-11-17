import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:ccplayer/main.dart' as app;
import 'package:ccplayer/presentation/settings/settings_page.dart';
import 'package:ccplayer/presentation/shell/capsule_navigation.dart';
import 'package:ccplayer/presentation/shell/top_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'process_metrics.dart';

/// 在目标设备执行固定页面切换与设置滚动，保留逐轮原始渲染和内存数据。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('主干页面实机负载', (tester) async {
    await app.main();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final samples = <Map<String, Object>>[];
    final frames = <FrameTiming>[];
    void collect(List<FrameTiming> values) => frames.addAll(values);
    binding.addTimingsCallback(collect);
    try {
      for (var round = 0; round < 6; round++) {
        frames.clear();
        final watch = Stopwatch()..start();
        final cpuStart = processCpuMicroseconds();
        var peakRss = ProcessInfo.currentRss;
        final memorySampler = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) {
            final current = ProcessInfo.currentRss;
            if (current > peakRss) peakRss = current;
          },
        );
        addTearDown(memorySampler.cancel);
        for (final label in ['媒体源', '播放记录', '设置', '媒体库']) {
          final hasCapsuleNav = find
              .byType(CapsuleNavigation)
              .evaluate()
              .isNotEmpty;
          final target = hasCapsuleNav
              ? find
                    .descendant(
                      of: find.byType(CapsuleNavigation),
                      matching: find.byTooltip(label),
                    )
                    .hitTestable()
              : find
                    .descendant(
                      of: find.byType(TopNavBar),
                      matching: find.text(label),
                    )
                    .hitTestable();
          expect(target, findsWidgets, reason: '导航入口必须可见：$label');
          await tester.tap(target.first);
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle(const Duration(milliseconds: 100));
          if (label == '设置') {
            expect(find.byType(SettingsPage), findsOneWidget);
            final singleScroll = find.descendant(
              of: find.byType(SettingsPage),
              matching: find.byType(SingleChildScrollView),
            );
            final scroll = singleScroll.evaluate().isNotEmpty
                ? singleScroll
                : find.descendant(
                    of: find.byType(SettingsPage),
                    matching: find.byType(ListView),
                  );
            expect(scroll, findsWidgets, reason: '设置页面必须存在可交互滚动区域');
            await tester.drag(scroll.first, const Offset(0, -320));
            await tester.pumpAndSettle();
            await tester.drag(scroll.first, const Offset(0, 320));
            await tester.pumpAndSettle();
          }
          final rss = ProcessInfo.currentRss;
          if (rss > peakRss) peakRss = rss;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        watch.stop();
        memorySampler.cancel();
        expect(frames, isNotEmpty, reason: '必须取得真实渲染帧，禁止空采样');
        if (round > 0) {
          samples.add({
            'elapsed_us': watch.elapsedMicroseconds,
            'cpu_us': processCpuMicroseconds() - cpuStart,
            'observed_peak_rss_bytes': peakRss,
            'frame_count': frames.length,
            'build_us': frames
                .map((f) => f.buildDuration.inMicroseconds)
                .toList(),
            'raster_us': frames
                .map((f) => f.rasterDuration.inMicroseconds)
                .toList(),
          });
        }
      }
      binding.reportData = {'samples': samples};
    } finally {
      binding.removeTimingsCallback(collect);
    }
  });
}
