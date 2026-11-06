import 'dart:io';

import 'package:ccplayer/core/mpv_config_store.dart';
import 'package:ccplayer/core/mpv_engine_store.dart';
import 'package:ccplayer/ui/mpv_settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late MpvConfigStore store;
  late MpvEngineStore engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('ccplayer-mpv-ui-');
    store = MpvConfigStore(rootOverride: temp);
    engine = MpvEngineStore(rootOverride: temp);
  });
  tearDown(() async => temp.delete(recursive: true));

  Future<void> showSettings(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(store.initialize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MpvSettingsPanel(store: store, engineStore: engine),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pumpAndSettle();
  }

  testWidgets(
    'decoding selector persists software mode without disabling GPU rendering',
    (tester) async {
      await showSettings(tester);
      final selector = find.byKey(const ValueKey('decode-mode-automatic'));
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      // The decoder menu stays anchored and compact on a wide settings page.
      final option = find.widgetWithText(
        PopupMenuItem<VideoDecodeMode>,
        '软件解码',
      );
      expect(tester.getSize(option).width, lessThan(400));
      expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
      await tester.tap(find.text('软件解码').last);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pumpAndSettle();
      expect(store.decodeMode, VideoDecodeMode.software);
      expect(store.videoConfiguration.hwdec, 'no');
      expect(store.videoConfiguration.enableHardwareAcceleration, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('default engine and opt-in config controls', (tester) async {
    await showSettings(tester);
    expect(find.byKey(const ValueKey('mpv-config-enabled')), findsOneWidget);
    expect(find.byKey(const ValueKey('mpv-file-mpv.conf')), findsOneWidget);
    expect(find.byKey(const ValueKey('mpv-file-input.conf')), findsOneWidget);
    expect(find.byKey(const ValueKey('mpv-native-ass')), findsNothing);
    expect(find.byKey(const ValueKey('webdav-long-recovery')), findsNothing);
    expect(store.enabled, isFalse);
    expect(find.byKey(const ValueKey('mpv-scripts-enabled')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mpv-config-enabled')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pumpAndSettle();
    expect(store.enabled, isTrue);
    expect(find.byKey(const ValueKey('mpv-scripts-enabled')), findsNothing);
    final engineSwitch = find.byKey(const ValueKey('mpv-engine-enabled'));
    await tester.ensureVisible(engineSwitch);
    expect(tester.widget<SwitchListTile>(engineSwitch).onChanged, isNull);
  });

  testWidgets('portrait Android keeps edit/import actions beneath file title', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(store.initialize);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MpvSettingsPanel(store: store, engineStore: engine),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pumpAndSettle();

    final configTile = tester.widget<ListTile>(
      find.byKey(const ValueKey('mpv-file-mpv.conf')),
    );
    final inputTile = tester.widget<ListTile>(
      find.byKey(const ValueKey('mpv-file-input.conf')),
    );
    expect(configTile.trailing, isNull);
    expect(inputTile.trailing, isNull);
    expect(tester.takeException(), isNull);
  });
}
