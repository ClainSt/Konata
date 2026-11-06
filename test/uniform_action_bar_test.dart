import 'package:ccplayer/ui/source_editor.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ccplayer/ui/uniform_action_bar.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [const Size(320, 844), const Size(1100, 800)]) {
    testWidgets('source editor actions share one aligned row at $size', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: NipaPlayStyle.theme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(size.width < 400 ? 1.5 : 1),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => SourceEditor.show(context, {
                  'id': 'layout-test',
                  'kind': 'webdav',
                  'label': '动画',
                  'location': 'https://example.invalid/dav',
                  'username': '',
                }),
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      final buttons = [
        find.widgetWithText(TextButton, '取消'),
        find.widgetWithText(OutlinedButton, '测试连接'),
        find.widgetWithText(FilledButton, '保存'),
      ];
      final rects = buttons.map(tester.getRect).toList();
      for (final rect in rects) {
        expect(rect.top, rects.first.top);
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.height, rects.first.height);
        expect(rect.width, closeTo(rects.first.width, .01));
      }
      expect(tester.takeException(), isNull);
      await tester.tap(buttons.first);
      await tester.pumpAndSettle();
      expect(find.text('编辑媒体源'), findsNothing);
    });
  }
  for (final width in [240.0, 320.0, 600.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'uniform actions $width $brightness preserve size shape and callbacks',
        (tester) async {
          var calls = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: NipaPlayStyle.theme(brightness),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: width,
                    child: UniformActionBar(
                      children: [
                        TextButton(
                          key: const ValueKey('cancel'),
                          onPressed: () => calls++,
                          child: const Text('取消'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('test'),
                          onPressed: () => calls++,
                          icon: const Icon(Icons.network_check),
                          label: const Text('测试连接'),
                        ),
                        FilledButton(
                          key: const ValueKey('save'),
                          onPressed: () => calls++,
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final rects = [
            for (final key in ['cancel', 'test', 'save'])
              tester.getRect(find.byKey(ValueKey(key))),
          ];
          for (final rect in rects) {
            expect(rect.height, 48);
            expect(rect.width, closeTo(rects.first.width, .01));
            expect(rect.top, rects.first.top);
          }
          for (final key in ['cancel', 'test', 'save']) {
            final button = tester.widget<ButtonStyleButton>(
              find.byKey(ValueKey(key)),
            );
            final shape =
                button.style!.shape!.resolve({})! as RoundedRectangleBorder;
            expect(shape.borderRadius, BorderRadius.circular(8));
            await tester.tap(find.byKey(ValueKey(key)));
          }
          expect(calls, 3);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('busy test keeps three controls aligned and disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: UniformActionBar(
              children: [
                TextButton(onPressed: null, child: Text('取消')),
                OutlinedButton.icon(
                  onPressed: null,
                  icon: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(),
                  ),
                  label: Text('测试中'),
                ),
                FilledButton(onPressed: null, child: Text('保存')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
}
