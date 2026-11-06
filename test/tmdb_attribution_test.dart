import 'package:ccplayer/ui/settings_page.dart';
import 'package:ccplayer/ui/tmdb_attribution.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      testWidgets('About attribution: $platform / $brightness', (tester) async {
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
        });
        await tester.binding.setSurfaceSize(
          platform == TargetPlatform.windows
              ? const Size(1280, 900)
              : const Size(320, 640),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness, platform: platform),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const Scaffold(body: SettingsPage()),
          ),
        );
        await tester.tap(find.text('关于').first);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(TmdbAttribution),
          200,
          scrollable: find.descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            'This product uses the TMDB API but is not endorsed or certified by TMDB.',
          ),
          findsOneWidget,
        );
        final logo = tester.widget<Image>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Image &&
                widget.semanticLabel == 'TMDB — The Movie Database',
          ),
        );
        expect(
          (logo.image as AssetImage).assetName,
          'assets/brand/tmdb-logo.png',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final succeeds in [true, false]) {
    testWidgets('TMDB website launch succeeds=$succeeds', (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return succeeds;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TmdbAttribution())),
      );
      await tester.pumpAndSettle();
      expect(find.text('TMDB 官网'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'TMDB'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(calls.single.arguments['url'], 'https://www.themoviedb.org');
      expect(calls.single.arguments['useWebView'], isFalse);
      expect(
        find.text('无法打开浏览器，请访问 https://www.themoviedb.org'),
        succeeds ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
