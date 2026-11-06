import 'package:ccplayer/core/watch_settings.dart';
import 'package:ccplayer/ui/watched_threshold_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingSettings extends WatchSettings {
  @override
  Future<void> setCompletionPercent(int value) async =>
      throw StateError('disk write failed');
}

void main() {
  test(
    'threshold defaults to 90, validates input and survives reloading',
    () async {
      for (final invalid in [null, 0, 101, 'bad']) {
        SharedPreferences.setMockInitialValues({
          WatchSettings.preferenceKey: ?invalid,
        });
        final settings = WatchSettings();
        await settings.load();
        expect(settings.completionPercent, 90);
        settings.dispose();
      }
      final settings = WatchSettings();
      await settings.setCompletionPercent(75);
      final restored = WatchSettings();
      await restored.load();
      expect(restored.completionPercent, 75);
      await expectLater(settings.setCompletionPercent(0), throwsRangeError);
      await expectLater(settings.setCompletionPercent(101), throwsRangeError);
      expect(settings.completionPercent, 75);
      settings.dispose();
      restored.dispose();
    },
  );
  for (final failure in [false, true]) {
    testWidgets(
      'threshold slider persists or restores on save failure=$failure',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = failure ? _FailingSettings() : WatchSettings();
        addTearDown(settings.dispose);
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: WatchedThresholdSettings(settings: settings),
              ),
            ),
          ),
        );
        final slider = find.byKey(const ValueKey('watched-threshold'));
        await tester.ensureVisible(slider);
        final rect = tester.getRect(slider);
        await tester.tapAt(Offset(rect.left + rect.width * .6, rect.center.dy));
        await tester.pumpAndSettle();
        if (failure) {
          expect(settings.completionPercent, 90);
          expect(find.text('观看设置保存失败，请重试'), findsOneWidget);
          expect(find.text('90%'), findsOneWidget);
        } else {
          expect(settings.completionPercent, lessThan(90));
          final restored = WatchSettings();
          await restored.load();
          expect(restored.completionPercent, settings.completionPercent);
          restored.dispose();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
