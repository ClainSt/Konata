import 'package:ccplayer/core/scan_activity.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:ccplayer/ui/scrape_task_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('scan task reports completed folders and discovered videos live', (
    tester,
  ) async {
    const source = 'live-progress-fixture';
    final activity = ScanActivityStore.instance;
    activity.begin(source, ['']);
    activity.restoreFolders(source, {'first': 2, 'empty': 0});
    addTearDown(() => activity.complete(source));

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ScrapeWorkPanel(
      tasks: const [
        {'id': 'scan:$source', 'source_id': source, 'state': 'running'},
      ],
      onAction: (_, _) {},
      onReview: (_) {},
      onRetryWork: (_) {},
    ))));
    expect(find.text('2 folders scanned · 2 videos found'), findsOneWidget);

    activity.beginFolder(source, 'next');
    activity.video(source, 'next');
    activity.endFolder(source, 'next');
    await tester.pump();
    expect(find.text('3 folders scanned · 3 videos found'), findsOneWidget);
  });

  testWidgets('work rows group jobs and keep incomplete queries out of history', (tester) async {
    final retried = <String>[];
    final theme = NipaPlayStyle.theme(Brightness.light);
    await tester.pumpWidget(MaterialApp(theme: theme, home: Scaffold(body: ScrapeWorkPanel(
      tasks: const [
        {'id': 'recognize:a', 'work_id': 'a', 'title': 'Pending work', 'state': 'complete',
          'review_count': 1, 'review_error': 'request_failed'},
        {'id': 'art:a', 'work_id': 'a', 'title': 'Pending work', 'state': 'complete',
          'review_count': 1, 'review_error': 'request_failed'},
        {'id': 'recognize:b', 'work_id': 'b', 'title': 'Finished work', 'state': 'complete',
          'review_count': 0},
        {'id': 'recognize:c', 'work_id': 'c', 'title': 'Candidate work', 'state': 'complete',
          'review_count': 1, 'review_pending': 1},
        {'id': 'recognize:d', 'work_id': 'd', 'title': 'Unmatched work', 'state': 'complete',
          'review_count': 0, 'review_pending': 1},
      ], onAction: (_, __) {}, onReview: (_) {}, onRetryWork: retried.add,
    ))));
    expect(find.text('Candidate work'), findsOneWidget);
    expect(find.text('Candidates to confirm 1'), findsOneWidget);
    await tester.tap(find.text('Incomplete 1'));
    await tester.pumpAndSettle();
    final selected = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Incomplete 1'),
    );
    expect(selected.selected, isTrue);
    expect(selected.selectedColor, theme.colorScheme.primary);
    expect(selected.labelStyle?.color, theme.colorScheme.onPrimary);
    expect(selected.checkmarkColor, theme.colorScheme.onPrimary);
    expect(find.text('Pending work'), findsOneWidget);
    expect(find.text('Finished work'), findsNothing);
    await tester.tap(find.text('Retry identification'));
    expect(retried, ['a']);
    await tester.tap(find.text('No candidates 1'));
    await tester.pumpAndSettle();
    expect(find.text('Unmatched work'), findsOneWidget);
    expect(find.text('Review matches'), findsNothing);
    await tester.tap(find.text('Finished 1'));
    await tester.pumpAndSettle();
    expect(find.text('Finished work'), findsOneWidget);
    expect(find.text('Pending work'), findsNothing);
  });

  testWidgets('task actions stay usable after live resize and text enlargement', (
    tester,
  ) async {
    final actions = <String>[];
    final view = tester.view;
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
    for (final size in [
      const Size(320, 600),
      const Size(900, 700),
      const Size(360, 240),
    ]) {
      view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: ScrapeTaskPanel(
                tasks: const [
                  {
                    'id': 'a',
                    'state': 'queued',
                    'title':
                        '较长的中文作品名称 A very long English media title for resizing',
                  },
                ],
                onAction: (id, action) => actions.add(action),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Start'));
      await tester.pumpAndSettle();
      final before = actions.length;
      await tester.tap(find.text('Start'));
      expect(actions.length, before + 1);
      expect(actions.last, 'run');
    }
  });
}
