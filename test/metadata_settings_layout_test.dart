import 'package:ccplayer/core/connection_diagnostic.dart';
import 'package:ccplayer/ui/metadata_server_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(1100, 800),
    const Size(640, 480),
    const Size(320, 640),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'metadata settings layout $size $brightness with expanded diagnostic',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(size.width == 320 ? 1.5 : 1),
                ),
                child: child!,
              ),
              home: Scaffold(
                body: MetadataServerSettings(
                  diagnostic: (i, addresses, trust) async => const ConnectionReport(
                    status: DiagnosticStatus.connected,
                    details:
                        'host=api.tmdb.org HTTP 200\nhost=images.tmdb.org HTTP 200 image decoded 937334 bytes\n1422 ms',
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final field = find.byKey(const ValueKey('metadata-address-0'));
          final scrollable = find.byType(Scrollable).first;
          final testButton = find.byKey(const ValueKey('metadata-test-0'));
          await tester.scrollUntilVisible(
            testButton,
            100,
            scrollable: scrollable,
          );
          await tester.tap(testButton);
          await tester.pumpAndSettle();
          expect(find.text('连接成功'), findsOneWidget);
          final details = find.text('连接详情').first;
          await tester.scrollUntilVisible(details, 80, scrollable: scrollable);
          await tester.tap(details);
          await tester.pumpAndSettle();
          expect(find.byType(Scrollbar), findsOneWidget);
          final scrollbarRect = tester.getRect(find.byType(Scrollbar));
          expect(
            tester.getRect(field).right,
            lessThanOrEqualTo(scrollbarRect.right - 24),
          );
          final resultRect = tester.getRect(
            find.byKey(const ValueKey('metadata-result-0')),
          );
          final nextField = tester.getRect(
            find.byKey(const ValueKey('metadata-address-1')),
          );
          expect(resultRect.bottom, lessThan(nextField.top));
          expect(tester.takeException(), isNull);
          final save = find.widgetWithText(FilledButton, '保存');
          expect(tester.getRect(save).bottom, lessThanOrEqualTo(size.height));
        },
      );
    }
  }
}
