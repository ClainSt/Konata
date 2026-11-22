import 'package:konata/application/playback/playback_preferences_provider.dart';
import 'package:konata/application/providers/desktop_external_tools_providers.dart';
import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/models/external_player_config.dart';
import 'package:konata/domain/repositories/desktop_relay_service.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/infrastructure/players/desktop_external_player_store.dart';
import 'package:konata/presentation/settings/settings_external_tools_panel.dart';
import 'package:konata/presentation/theme/konata_theme.dart';
import 'package:konata/presentation/widgets/playback/konata_foobar_beefweb_dialog.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('设置页外部调用面板全宽对称等高对齐且窄窗换位与引导弹窗闭环零溢出', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final db = KonataDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await DesktopExternalPlayerStore(db).upsertExternalPlayer(
      const ExternalPlayerConfig(
        id: 'player_audio',
        name: '外部音频播放器',
        kind: ExternalPlayerKind.audioPlayer,
        executablePath: r'C:\foobar2000\foobar2000.exe',
      ),
    );

    final container = ProviderContainer(
      overrides: [
        konataDatabaseProvider.overrideWithValue(db),
        playbackPreferencesProvider.overrideWith(
          () => PlaybackPreferencesNotifier(enablePersistence: false),
        ),
        foobarBeefwebStatusProvider.overrideWith(
          (_) async => const FoobarComponentStatusSnapshot(
            state: FoobarComponentState.missingComponent,
            executablePath: r'C:\foobar2000\foobar2000.exe',
            port: 8880,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    var dispatchCalls = 0;
    Widget buildApp(ThemeMode mode) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: KonataTheme.lightTheme(),
          darkTheme: KonataTheme.darkTheme(),
          themeMode: mode,
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SettingsExternalToolsPanel(),
                  const SizedBox(height: 16),
                  Consumer(
                    builder: (ctx, ref, _) => ElevatedButton(
                      key: const ValueKey('trigger_guide_test_btn'),
                      onPressed: () {
                        ExternalAudioRelayUiHelper.dispatchWithGuide(
                          context: ctx,
                          ref: ref,
                          action: ({required forceAllowWithoutBeefweb}) async {
                            dispatchCalls += 1;
                            if (!forceAllowWithoutBeefweb) {
                              return const LaunchPlaybackResult(
                                launched: false,
                                requiresBeefwebPrompt: true,
                                message: '',
                              );
                            }
                            return const LaunchPlaybackResult(
                              launched: true,
                              message: '已降级拉起 foobar2000',
                            );
                          },
                        );
                      },
                      child: const Text('触发外部播放'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildApp(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final sectionFinder = find.byKey(
      const ValueKey('settings_foobar_beefweb_card'),
    );
    final portFinder = find.byKey(
      const ValueKey('settings_foobar_beefweb_port_field'),
    );
    final retestFinder = find.byKey(
      const ValueKey('settings_foobar_beefweb_retest_button'),
    );
    final downloadFinder = find.byKey(
      const ValueKey('settings_foobar_beefweb_download_button'),
    );

    expect(sectionFinder, findsOneWidget);
    expect(find.text('未检测到 foo_beefweb 组件'), findsOneWidget);

    // 验证宽屏下 Beefweb 区块撑满卡片内全宽，且端口框与操作按钮精确等高同轴右对齐。
    final sectionRect = tester.getRect(sectionFinder);
    final portRect = tester.getRect(portFinder);
    final retestRect = tester.getRect(retestFinder);
    final downloadRect = tester.getRect(downloadFinder);

    expect(sectionRect.width, greaterThan(1100));
    expect(portRect.height, equals(38.0));
    expect(retestRect.height, equals(38.0));
    expect(downloadRect.height, equals(38.0));
    expect(portRect.top, equals(retestRect.top));
    expect(retestRect.top, equals(downloadRect.top));
    expect(portRect.bottom, equals(downloadRect.bottom));
    expect((sectionRect.right - downloadRect.right).abs(), lessThan(1.0));

    final triggerBtn = find.byKey(const ValueKey('trigger_guide_test_btn'));
    await tester.ensureVisible(triggerBtn);
    await tester.tap(triggerBtn);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('foobar_beefweb_guide_dialog')),
      findsOneWidget,
    );
    expect(find.text('前往官方组件页下载'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('foobar_guide_skip_once_or_forever')),
    );
    await tester.pumpAndSettle();

    expect(dispatchCalls, equals(2));
    expect(
      container.read(playbackPreferencesProvider).skipFoobarBeefwebPrompt,
      isTrue,
    );
    expect(find.text('恢复播放前提醒'), findsOneWidget);

    // 切换窄视口与亮色主题，验证自适应换位零溢出。
    tester.view.physicalSize = const Size(520, 900);
    await tester.pumpWidget(buildApp(ThemeMode.light));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // KonataToast 存在 4 秒自动消失定时器，推进虚拟时钟排空定时器防止测试报残留 Timer。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
