import 'package:ccplayer/core/connection_diagnostic.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/ui/metadata_server_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'metadata report follows live language changes without retesting',
    (tester) async {
      final locale = ValueNotifier(const Locale('en'));
      addTearDown(locale.dispose);
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var calls = 0;
      await tester.pumpWidget(
        ValueListenableBuilder<Locale>(
          valueListenable: locale,
          builder: (_, value, _) => MaterialApp(
            locale: value,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: MetadataServerSettings(
                diagnostic: (index, addresses, trust) async {
                  calls++;
                  return const ConnectionReport(
                    status: DiagnosticStatus.connected,
                    details: 'host=example.org HTTP 200\n30 ms',
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('metadata-test-0'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      locale.value = const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
      );
      await tester.pumpAndSettle();
      expect(find.text('連線成功'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unexpected diagnostic failures are localized and allow a retry',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MetadataServerSettings(
              diagnostic: (_, _, _) async {
                calls++;
                if (calls == 1) throw StateError('token=do-not-display');
                return const ConnectionReport(
                  status: DiagnosticStatus.partial,
                  issue: DiagnosticIssue.http,
                  details: 'HTTP 503',
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('metadata-test-0'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        find.text('Connection failed. Check URL and access.'),
        findsOneWidget,
      );
      expect(find.textContaining('do-not-display'), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Some features failed'), findsOneWidget);
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
