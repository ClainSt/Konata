import 'package:ccplayer/ui/app_header.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final layout in KonataNavigationLayout.values) {
      testWidgets('nav background never flashes dark: $brightness $layout', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final theme = NipaPlayStyle.theme(brightness);
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, update) => AppHeader(
                  layout: layout,
                  showSources: selected == 1,
                  historySelected: selected == 2,
                  settingsSelected: selected == 3,
                  onNavigate: (sources) =>
                      update(() => selected = sources ? 1 : 0),
                  onHistory: () => update(() => selected = 2),
                  onSettings: () => update(() => selected = 3),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final colors = theme.colorScheme;
        final endpoints = [colors.surface, colors.surfaceContainerLow];
        final minLuminance = endpoints
            .map((c) => c.computeLuminance())
            .reduce((a, b) => a < b ? a : b);
        final maxLuminance = endpoints
            .map((c) => c.computeLuminance())
            .reduce((a, b) => a > b ? a : b);
        for (final next in ['sources', 'history', 'settings', 'library']) {
          final indicator = find.byKey(
            const ValueKey('nav-selection-indicator'),
          );
          final start = tester.getRect(indicator);
          final end = tester.getRect(find.byKey(ValueKey('nav-$next')));
          await tester.tap(find.byKey(ValueKey('nav-$next')));
          await tester.pump();
          expect(tester.getRect(indicator), start);
          for (var frame = 0; frame < 10; frame++) {
            await tester.pump(const Duration(milliseconds: 18));
            expect(indicator, findsOneWidget);
            final rect = tester.getRect(indicator);
            final from = layout == KonataNavigationLayout.rail
                ? start.top
                : start.left;
            final to = layout == KonataNavigationLayout.rail
                ? end.top
                : end.left;
            final now = layout == KonataNavigationLayout.rail
                ? rect.top
                : rect.left;
            expect(
              now,
              inInclusiveRange(from < to ? from : to, from > to ? from : to),
            );
            expect(
              rect.width,
              inInclusiveRange(
                (start.width < end.width ? start.width : end.width) - .001,
                (start.width > end.width ? start.width : end.width) + .001,
              ),
            );
            expect(rect.height, closeTo(start.height, .001));
            for (final icon in tester.widgetList<Icon>(
              find.descendant(
                of: find.byKey(ValueKey('navigation-${layout.name}')),
                matching: find.byType(Icon),
              ),
            )) {
              expect(icon.color, colors.onSurfaceVariant);
            }
            for (final box in tester.widgetList<DecoratedBox>(
              find.descendant(
                of: find.byType(AppHeader),
                matching: find.byType(DecoratedBox),
              ),
            )) {
              final decoration = box.decoration;
              if (decoration is! BoxDecoration ||
                  decoration.borderRadius != BorderRadius.circular(28)) {
                continue;
              }
              final painted = Color.alphaBlend(
                decoration.color!,
                colors.surfaceContainerLow,
              );
              expect(
                painted.computeLuminance(),
                inInclusiveRange(minLuminance - .006, maxLuminance + .006),
                reason:
                    'The single moving pill must stay opaque ($next frame $frame)',
              );
            }
          }
        }
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
