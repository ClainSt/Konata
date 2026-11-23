import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart' as wm;

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/main.dart' as desktop_app;
import 'package:konata/presentation/settings/settings_page.dart';
import 'package:konata/presentation/shell/top_nav_bar.dart';
import 'package:konata/presentation/widgets/playback/desktop_always_on_top_mini_stage.dart';

import 'full_stress_suite_body.dart';

/// Windows 桌面端全功能与全页面实机压力测试入口（含桌面置顶迷你窗与窗口极限缩放压测）。
void main() {
  runFullAppRealDeviceStressSuite(
    launchApp: desktop_app.main,
    platformTag: 'windows_desktop',
    desktopNavFinder: (label) => find
        .descendant(of: find.byType(TopNavBar), matching: find.text(label))
        .hitTestable(),
    desktopHook: _runWindowsExtras,
  );
}

Future<void> _runWindowsExtras(
  WidgetTester tester,
  ProviderContainer container,
  String stage,
  Map<String, Object?> metrics,
) async {
  final miniCtrl = container.read(desktopAlwaysOnTopMiniModeProvider.notifier);
  if (stage == 'video_mini') {
    await miniCtrl.enterVideoMini(fromExpanded: false);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(
      find.byKey(const ValueKey('desktop_always_on_top_video_stage')),
      findsOneWidget,
    );
    await miniCtrl.exitToMainWindow(forceExpanded: false);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    return;
  }

  if (stage == 'audio_mini') {
    await miniCtrl.enterAudioMini(fromExpanded: false);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(
      find.byKey(const ValueKey('desktop_always_on_top_audio_stage')),
      findsOneWidget,
    );
    await miniCtrl.exitToMainWindow(forceExpanded: false);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    return;
  }

  if (stage == 'window_resize') {
    final win = wm.WindowManager.instance.getCurrent();
    for (final size in const [
      Size(960, 620),
      Size(1280, 720),
      Size(1360, 820),
    ]) {
      win?.setSize(wm.SizeToNative(size).toNative(), false);
      for (final section in const [
        KonataNavSection.library,
        KonataNavSection.history,
        KonataNavSection.settings,
      ]) {
        container.read(selectedNavSectionProvider.notifier).state = section;
        if (section == KonataNavSection.settings) {
          container.read(selectedSettingsCategoryProvider.notifier).state =
              SettingsCategory.player;
        }
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }
    }
  }
}
