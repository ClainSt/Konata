import 'package:ccplayer/core/app_language.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/core/metadata_servers.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/language_settings.dart';
import 'package:ccplayer/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingLanguage extends AppLanguage {
  @override
  Future<void> setChoice(AppLanguageChoice value) async =>
      throw StateError('disk write failed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .localesTestValue = const [
    Locale('zh', 'CN'),
  ];
  testWidgets(
    'real app navigation switches language while keeping current settings page',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await AppLanguage.instance.load();
      final cat = Catalog.instance;
      final sources = cat.sources, works = cat.works, assets = cat.assets;
      cat.sources = [];
      cat.works = [];
      cat.assets = [];
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        cat.sources = sources;
        cat.works = works;
        cat.assets = assets;
        await AppLanguage.instance.setChoice(AppLanguageChoice.system);
        libraryDestination.value = false;
      });
      await tester.pumpWidget(const CCPlayer(mobile: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-settings')));
      await tester.pumpAndSettle();
      expect(find.text('语言'), findsOneWidget);
      await AppLanguage.instance.setChoice(AppLanguageChoice.en);
      await tester.pumpAndSettle();
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      await AppLanguage.instance.setChoice(AppLanguageChoice.zhHant);
      await tester.pumpAndSettle();
      expect(find.text('語言'), findsOneWidget);
      expect(find.text('媒體來源'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'system is default, invalid saved values fall back, choice survives reload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final language = AppLanguage();
      await language.load();
      expect(language.choice, AppLanguageChoice.system);
      expect(language.locale, isNull);
      for (final choice in AppLanguageChoice.values) {
        await language.setChoice(choice);
        final restarted = AppLanguage();
        await restarted.load();
        expect(restarted.choice, choice);
        restarted.dispose();
      }
      SharedPreferences.setMockInitialValues({
        AppLanguage.preferenceKey: 'obsolete',
      });
      await language.load();
      expect(language.choice, AppLanguageChoice.system);
      language.dispose();
    },
  );

  test(
    'system locale resolves scripts, regions, language lists and fallback',
    () {
      final supported = AppLocalizations.supportedLocales;
      String resolve(List<Locale>? input) =>
          AppLanguage.resolve(input, supported).toLanguageTag();
      expect(resolve([const Locale('zh', 'CN')]), 'zh-Hans');
      expect(resolve([const Locale('zh', 'SG')]), 'zh-Hans');
      for (final region in ['TW', 'HK', 'MO']) {
        expect(resolve([Locale('zh', region)]), 'zh-Hant');
      }
      expect(
        resolve([
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hans',
            countryCode: 'HK',
          ),
        ]),
        'zh-Hans',
      );
      expect(
        resolve([const Locale('ja'), const Locale('zh', 'TW')]),
        'zh-Hant',
      );
      expect(resolve([const Locale('en', 'GB')]), 'en');
      expect(resolve([const Locale('ja')]), 'en');
      expect(resolve(null), 'en');
    },
  );

  for (final size in [const Size(1100, 800), const Size(320, 640)]) {
    testWidgets(
      'language dropdown updates settings immediately without touching metadata at $size',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        await AppLanguage.instance.load();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await AppLanguage.instance.setChoice(AppLanguageChoice.system);
        });
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final servers = List.of(MetadataServers.values);
        final authMode = Metadata.authMode;
        await tester.pumpWidget(
          AnimatedBuilder(
            animation: AppLanguage.instance,
            builder: (_, _) => MaterialApp(
              locale: AppLanguage.instance.locale,
              localeListResolutionCallback: AppLanguage.resolve,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const Scaffold(
                body: SettingsPage(embedded: true, category: 4),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-language')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('English').last);
        await tester.pumpAndSettle();
        expect(find.text('Language'), findsWidgets);
        expect(find.text('Language'), findsWidgets);
        expect(AppLanguage.instance.locale, const Locale('en'));
        final restarted = AppLanguage();
        await restarted.load();
        expect(restarted.choice, AppLanguageChoice.en);
        restarted.dispose();
        expect(MetadataServers.values, servers);
        expect(Metadata.authMode, authMode);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('settings-language')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('繁體中文').last);
        await tester.pumpAndSettle();
        expect(find.text('語言'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('follow system responds to locale changes without restarting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final language = AppLanguage();
    await language.load();
    addTearDown(language.dispose);
    final dispatcher = tester.binding.platformDispatcher;
    addTearDown(() => dispatcher.localesTestValue = const [Locale('zh', 'CN')]);
    dispatcher.localesTestValue = const [Locale('en')];
    await tester.pumpWidget(
      MaterialApp(
        locale: language.locale,
        localeListResolutionCallback: AppLanguage.resolve,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: LanguageSettings(language: language)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsWidgets);
    dispatcher.localesTestValue = const [Locale('zh', 'TW')];
    await tester.pumpAndSettle();
    expect(find.text('語言'), findsWidgets);
  });

  testWidgets('failed language save keeps previous choice and displays error', (
    tester,
  ) async {
    final language = _FailingLanguage();
    addTearDown(language.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LanguageSettings(language: language)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('settings-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(language.choice, AppLanguageChoice.system);
    expect(find.text('语言设置保存失败，请重试'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-language')),
        matching: find.text('跟随系统'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
