import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/presentation/audio/mini_audio_bar.dart';
import 'package:konata/presentation/settings/settings_page.dart';
import 'package:konata/presentation/settings/settings_appearance_panel.dart';
import 'package:konata/presentation/shell/adaptive_capsule_layout.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/design_system/konata_dropdown.dart';
import 'package:konata/presentation/widgets/design_system/konata_pill_button.dart';
import 'package:konata/presentation/widgets/design_system/konata_segmented_capsule.dart';
import 'package:konata/infrastructure/players/mpv_quality_profile.dart';

void main() {
  testWidgets('设置共用控件触屏热区与窄列折行', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: KonataTheme.darkTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 290,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  KonataPillButton.secondary(
                    key: const ValueKey('touch_button'),
                    label: '测试按钮',
                    compact: true,
                    onPressed: () => changes++,
                  ),
                  KonataDropdown<int>(
                    key: const ValueKey('touch_dropdown'),
                    value: 0,
                    options: const [
                      KonataDropdownOption(value: 0, label: '选项甲'),
                      KonataDropdownOption(value: 1, label: '选项乙'),
                    ],
                    onChanged: (_) => changes++,
                  ),
                  KonataSegmentedCapsule<int>(
                    selected: 0,
                    options: const [
                      KonataSegmentOption(value: 0, label: '跟随系统代理默认'),
                      KonataSegmentOption(value: 1, label: '自定义本地代理'),
                      KonataSegmentOption(value: 2, label: '不使用代理'),
                    ],
                    onChanged: (_) => changes++,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('touch_button'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('touch_dropdown'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('测试按钮'));
    await tester.tap(find.text('不使用代理'));
    expect(changes, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  for (final entry in <(TargetPlatform, Size)>[
    (TargetPlatform.windows, const Size(1920, 1080)),
    (TargetPlatform.android, const Size(1280, 800)),
    (TargetPlatform.android, const Size(800, 1280)),
    (TargetPlatform.android, const Size(390, 844)),
    (TargetPlatform.android, const Size(844, 390)),
  ]) {
    testWidgets('设置实际面板与逐级返回 ${entry.$2}', (tester) async {
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      debugDefaultTargetPlatformOverride = entry.$1;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.reset();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = entry.$2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final db = KonataDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(
            DriftLibraryRepository(db),
          ),
          miniAudioBottomClearanceProvider.overrideWithValue(0),
          mpvRuntimeVersionsProvider.overrideWith(
            (ref) async => const MpvRuntimeVersions(
              isAvailable: true,
              mpvVersion: '测试核心',
              ffmpegVersion: '测试核心',
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: const Scaffold(body: SettingsPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final phone =
          entry.$1 == TargetPlatform.android && entry.$2.shortestSide < 600;
      expect(
        find.text('外部调用'),
        entry.$1 == TargetPlatform.android ? findsNothing : findsOneWidget,
      );
      if (phone) expect(find.byType(SettingsAppearancePanel), findsNothing);
      for (final category in SettingsCategory.values) {
        if (entry.$1 == TargetPlatform.android &&
            category == SettingsCategory.externalTools) {
          continue;
        }
        final target = find.byKey(ValueKey('settings_category_$category'));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: category.label);
        if (entry.$1 == TargetPlatform.android) {
          expect(find.text('外部播放器'), findsNothing);
          expect(find.text('窗口材质'), findsNothing);
          expect(find.text('打开目录'), findsNothing);
        }
        if (phone) {
          expect(container.read(capsuleNavigationHiddenProvider), isTrue);
          if (category == SettingsCategory.appearance) {
            final gesture = await tester.startGesture(const Offset(1, 180));
            await gesture.moveBy(const Offset(35, 0));
            await gesture.moveBy(const Offset(-30, 0));
            await gesture.up();
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('settings_detail_back')),
              findsOneWidget,
            );
            expect(container.read(capsuleNavigationHiddenProvider), isTrue);
            tester.view.physicalSize = const Size(1280, 800);
            await tester.pumpAndSettle();
            expect(
              find.byKey(
                const ValueKey('settings_category_SettingsCategory.appearance'),
              ),
              findsWidgets,
            );
            expect(tester.takeException(), isNull);
            tester.view.physicalSize = entry.$2;
            await tester.pumpAndSettle();
          }
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 1));
          expect(container.read(capsuleNavigationHiddenProvider), isFalse);
          expect(
            find.byKey(const ValueKey('settings_detail_back')),
            findsNothing,
          );
        }
      }
      if (phone) {
        await tester.ensureVisible(
          find.byKey(
            const ValueKey('settings_category_SettingsCategory.appearance'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const ValueKey('settings_category_SettingsCategory.appearance'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.dragFrom(
          const Offset(1, 180),
          Offset(entry.$2.width * .8, 0),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('settings_detail_back')),
          findsNothing,
        );
        expect(container.read(capsuleNavigationHiddenProvider), isFalse);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
