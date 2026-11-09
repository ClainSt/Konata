import 'package:ccplayer/ui/work_edit_dialogs.dart';
import 'package:ccplayer/ui/uniform_action_bar.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('metadata IDs have spacing and no obsolete explanatory text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: NipaPlayStyle.theme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => WorkEditDialogs.metadata(context, {
                'id': 'test',
                'title': '测试',
                'year': 2023,
                'overview': '简介',
                'tmdb_id': 217512,
                'bangumi_id': 413741,
              }, searchAndBind: () async {}),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('角色排序'), findsNothing);
    expect(find.text('搜索并绑定'), findsOneWidget);
    final titleLabel = tester.getRect(find.text('作品标题'));
    final viewport = tester.getRect(find.byType(SingleChildScrollView).first);
    expect(titleLabel.top, greaterThanOrEqualTo(viewport.top));
    final field = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '关联 Bangumi ID',
    );
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    final widget = tester.widget<TextField>(field);
    expect(widget.decoration!.labelText, isNot(contains('（')));
    expect(widget.decoration!.helperText, isNull);
    expect(
      tester.getRect(field).top -
          tester.getRect(find.text('Bangumi: 413741')).bottom,
      greaterThanOrEqualTo(20),
    );
    expect(
      tester.getRect(find.text('Bangumi: 413741')).top,
      greaterThanOrEqualTo(tester.getRect(find.text('TMDB: 217512')).top),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
  testWidgets('local image action uses the same font without scaling down', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NipaPlayStyle.theme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: UniformActionBar(
                children: [
                  TextButton(onPressed: () {}, child: const Text('恢复自动')),
                  TextButton(onPressed: () {}, child: const Text('导入图片')),
                  TextButton(onPressed: () {}, child: const Text('取消')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final labels = [find.text('恢复自动'), find.text('导入图片'), find.text('取消')];
    final sizes = labels
        .map((f) => DefaultTextStyle.of(tester.element(f)).style.fontSize)
        .toSet();
    expect(sizes, {14.0});
    for (final label in labels) {
      final style = DefaultTextStyle.of(tester.element(label)).style;
      expect(
        style.fontFamily,
        Theme.of(tester.element(label)).textTheme.labelLarge!.fontFamily,
      );
      expect(style.letterSpacing, 0);
    }
    expect(
      find.descendant(
        of: find.byType(UniformActionBar),
        matching: find.byType(FittedBox),
      ),
      findsNothing,
    );
    expect(
      tester.renderObject<RenderParagraph>(labels[1]).didExceedMaxLines,
      false,
    );
    expect(tester.takeException(), isNull);
  });
}
