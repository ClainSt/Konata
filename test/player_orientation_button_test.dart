import 'dart:async';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/player_orientation_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video_controls/media_kit_video_controls.dart';

void main() {
  testWidgets('orientation icon follows updated playback control theme', (
    tester,
  ) async {
    var locked = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StatefulBuilder(
          builder: (context, update) {
            final theme = MaterialVideoControlsThemeData(
              bottomButtonBar: [
                PlayerOrientationButton(
                  locked: locked,
                  busy: false,
                  onPressed: () => update(() => locked = !locked),
                ),
              ],
            );
            return Scaffold(
              body: MaterialVideoControlsTheme(
                normal: theme,
                fullscreen: theme,
                child: const _ThemedBottomBar(),
              ),
            );
          },
        ),
      ),
    );
    final button = find.byKey(const ValueKey('playback-orientation'));
    await tester.tap(button);
    await tester.pump();
    expect(find.byIcon(Icons.screen_lock_landscape), findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(find.byIcon(Icons.screen_rotation), findsOneWidget);
  });
  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets('orientation button state and busy guard: $locale', (
      tester,
    ) async {
      final ready = Completer<void>();
      var locked = false;
      var busy = false;
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, update) => Scaffold(
              body: PlayerOrientationButton(
                locked: locked,
                busy: busy,
                onPressed: () async {
                  taps++;
                  update(() => busy = true);
                  await ready.future;
                  update(() {
                    locked = !locked;
                    busy = false;
                  });
                },
              ),
            ),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('playback-orientation'));
      expect(find.byIcon(Icons.screen_rotation), findsOneWidget);
      expect(find.byIcon(Icons.screen_lock_landscape), findsNothing);
      await tester.tap(button);
      await tester.pump();
      await tester.tap(button);
      expect(taps, 1);
      ready.complete();
      await tester.pump();
      expect(find.byIcon(Icons.screen_rotation), findsNothing);
      expect(find.byIcon(Icons.screen_lock_landscape), findsOneWidget);
      expect(
        find.byTooltip(
          locale.languageCode == 'zh' ? '跟随设备方向' : 'Follow device orientation',
        ),
        findsOneWidget,
      );
      await tester.tap(button);
      await tester.pump();
      expect(find.byIcon(Icons.screen_rotation), findsOneWidget);
      expect(find.byIcon(Icons.screen_lock_landscape), findsNothing);
      expect(taps, 2);
    });
  }
  testWidgets(
    'direction action stays visible beside long title at narrow widths',
    (tester) async {
      for (final width in [320.0, 600.0, 1024.0]) {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 600),
                  textScaler: const TextScaler.linear(2),
                ),
                child: Row(
                  children: [
                    const BackButton(),
                    const Expanded(
                      child: Text(
                        '很长的播放标题 Long video title repeated across a narrow window',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    PlayerOrientationButton(
                      locked: false,
                      busy: false,
                      onPressed: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final bounds = tester.getRect(
          find.byKey(const ValueKey('playback-orientation')),
        );
        expect(bounds.right, lessThanOrEqualTo(width));
        expect(bounds.width, greaterThanOrEqualTo(48));
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
}

class _ThemedBottomBar extends StatelessWidget {
  const _ThemedBottomBar();

  @override
  Widget build(BuildContext context) => Row(
    children: MaterialVideoControlsTheme.of(context).normal.bottomButtonBar,
  );
}
