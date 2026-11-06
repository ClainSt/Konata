import 'package:ccplayer/core/metadata.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/tmdb_id_guide.dart';
import 'package:ccplayer/ui/tmdb_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final language in ['en', 'zh-Hant']) {
    for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
      testWidgets('TMDB forms and ID help use $language on $platform', (
        tester,
      ) async {
        final oldToken = Metadata.token,
            oldKey = Metadata.apiKey,
            oldMode = Metadata.authMode;
        Metadata.token = '';
        Metadata.apiKey = '';
        Metadata.authMode = 'token';
        addTearDown(() {
          Metadata.token = oldToken;
          Metadata.apiKey = oldKey;
          Metadata.authMode = oldMode;
        });
        await tester.binding.setSurfaceSize(const Size(320, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final english = language == 'en';
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            locale: english
                ? const Locale('en')
                : const Locale.fromSubtags(
                    languageCode: 'zh',
                    scriptCode: 'Hant',
                  ),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () => TmdbSettingsDialog.show(context),
                      child: const Text('API'),
                    ),
                    TextButton(
                      onPressed: () => TmdbIdGuide.show(context),
                      child: const Text('ID'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('API'));
        await tester.pumpAndSettle();
        final save = find.widgetWithText(FilledButton, english ? 'Save' : '儲存');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(
          find.text(
            english ? 'Enter a token or API key first.' : '請先填寫所選驗證方式的憑證',
          ),
          findsOneWidget,
        );
        final token = find.byKey(const ValueKey('token'));
        await tester.ensureVisible(token);
        await tester.enterText(token, 'test-token');
        final apiKey = find.widgetWithText(SegmentedButton<String>, 'API Key');
        await tester.ensureVisible(apiKey);
        await tester.tap(
          find.descendant(of: apiKey, matching: find.text('API Key')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('apiKey')),
          'test-key',
        );
        await tester.tap(find.text(english ? 'Token' : '存取權杖'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('token')))
              .controller!
              .text,
          'test-token',
        );
        expect(tester.takeException(), isNull);
        // Close the form without persisting the test credentials.
        final close = find.byTooltip(english ? 'Close' : '關閉 TMDB 設定');
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pumpAndSettle();
        await tester.tap(find.text('ID'));
        await tester.pumpAndSettle();
        expect(
          find.text(english ? 'TMDB ID help' : 'TMDB ID 增強識別'),
          findsOneWidget,
        );
        expect(find.textContaining('{tmdb-100565}'), findsWidgets);
        expect(find.textContaining('{tmdbmovie-ID}'), findsOneWidget);
        final done = find.text(english ? 'Got it' : '知道了');
        await tester.tap(done);
        await tester.pumpAndSettle();
        expect(find.byType(TmdbIdGuide), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
