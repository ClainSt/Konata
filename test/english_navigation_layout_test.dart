import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/app_header.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
  });
  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('English header labels stay on one line at scale $scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(640, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: NipaPlayStyle.theme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                AppHeader(
                  showSources: false,
                  mobile: false,
                  onNavigate: (_) {},
                  onSettings: () {},
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final name in ['Library', 'Sources']) {
        final text = find.text(name);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.didExceedMaxLines, false, reason: name);
        final widget = tester.widget<Text>(text);
        expect(widget.maxLines, 1);
        expect(widget.softWrap, false);
      }
      expect(
        tester.getRect(find.byKey(const ValueKey('open-settings'))).right,
        lessThanOrEqualTo(640),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('English sidebar grows to show full labels at scale $scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: NipaPlayStyle.theme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(
            body: SettingsPage(embedded: true, wideLayout: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final name in [
        'Appearance',
        'Language',
        'Metadata',
        'History & sync',
        'About',
      ]) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(name));
        expect(paragraph.didExceedMaxLines, false, reason: name);
      }
      final category = tester.getRect(
        find.byKey(const ValueKey('settings-category-3')),
      );
      expect(category.width, greaterThanOrEqualTo(212));
      expect(tester.takeException(), isNull);
    });
  }
}
