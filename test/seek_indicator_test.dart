import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/seek_indicator.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:ccplayer/l10n/strings.dart';

void main() {
  for (final locale in [
    const Locale('en'),
    const Locale('zh', 'CN'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ]) {
    testWidgets(
      'double-tap duration uses locale and grows without wrapping: $locale',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(80, 180));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        for (final seconds in [10, 20, 120]) {
          await tester.pumpWidget(
            MaterialApp(
              locale: locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    final theme = MaterialVideoControlsThemeData(
                      seekDurationLabel: (value) =>
                          context.l10n.seekSeconds(value.inSeconds.abs()),
                    ).copyWith();
                    return MaterialSeekDurationLabel(
                      value: Duration(seconds: seconds),
                      label: theme.seekDurationLabel,
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final text = find.text(
            '$seconds ${locale.languageCode == 'en' ? 's' : '秒'}',
          );
          expect(text, findsOneWidget);
          expect(tester.widget<Text>(text).softWrap, false);
          expect(tester.widget<Text>(text).style!.fontSize, 12);
          expect(tester.takeException(), isNull);
        }
      },
    );
    testWidgets('seek indicator stays single line: $locale', (tester) async {
      await tester.binding.setSurfaceSize(const Size(100, 180));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final seconds in [-120, 120]) {
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SeekIndicator(offset: Duration(seconds: seconds)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final text = find.text(locale.languageCode == 'en' ? '120 s' : '120 秒');
        expect(text, findsOneWidget);
        expect(tester.widget<Text>(text).softWrap, false);
        expect(
          find.byIcon(seconds < 0 ? Icons.fast_rewind : Icons.fast_forward),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    });
  }
}
