import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/app_header.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in [const Locale('zh', 'CN'), const Locale('en')]) {
    testWidgets(
      'shell header has complete undecorated labels outside Navigator: $locale',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1274, 717));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: NipaPlayStyle.theme(Brightness.light),
            // Match the production shell: header sits above the Navigator/Scaffold.
            builder: (_, child) => Overlay.wrap(
              child: Column(
                children: [
                  AppHeader(
                    showSources: false,
                    mobile: false,
                    onNavigate: (_) {},
                    onSettings: () {},
                  ),
                  Expanded(child: child!),
                ],
              ),
            ),
            home: const Scaffold(),
          ),
        );
        await tester.pumpAndSettle();
        for (final name in ['library', 'sources', 'history', 'settings']) {
          final label = find.descendant(
            of: find.byKey(ValueKey('nav-$name')),
            matching: find.byType(Text),
          );
          final paragraph = tester.renderObject<RenderParagraph>(label);
          expect(paragraph.didExceedMaxLines, false, reason: name);
          final effective = (paragraph.text as TextSpan).style!;
          expect(effective.decoration, TextDecoration.none);
        }
      },
    );
  }
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (_) async => false,
        );
  });
  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets(
      'English compact navigation retains accessible names at scale $scale',
      (tester) async {
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
          expect(find.byTooltip(name), findsOneWidget);
        }
        expect(
          tester.getRect(find.byKey(const ValueKey('nav-settings'))).right,
          lessThanOrEqualTo(640),
        );
        expect(tester.takeException(), isNull);
      },
    );

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
