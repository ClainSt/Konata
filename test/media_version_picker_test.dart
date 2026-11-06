import 'package:ccplayer/ui/media_version_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final versions = List<Map<String, Object?>>.generate(
    20,
    (i) => {
      'id': 'file-$i',
      'source_id': 'dav',
      'size': 1073741824,
      'name':
          '[UHA-WINGS&VCB-Studio] 很长的作品名称 - 01 [Ma10p_1080p][x265_flac_aac] v$i.mkv',
      'relative_path': 'Anime/Work/version-$i.mkv',
    },
  );
  for (final size in [const Size(1100, 800), const Size(320, 640)]) {
    testWidgets(
      'version chooser shows source, metadata and selects exact file at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        Map<String, Object?>? chosen;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    chosen = await MediaVersionPicker.choose(
                      context,
                      versions,
                      sourceLabels: {'dav': '我的 WebDAV'},
                    );
                  },
                  child: const Text('选择'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('选择'));
        await tester.pumpAndSettle();
        expect(find.text('选择播放版本'), findsOneWidget);
        expect(find.text('发布标记（未分类）：UHA-WINGS&VCB-Studio'), findsWidgets);
        expect(find.text('媒体源：我的 WebDAV · 1.00 GiB'), findsWidgets);
        expect(find.text('10-bit'), findsWidgets);
        expect(tester.takeException(), isNull);
        final target = find.byKey(const ValueKey('media-version-file-19'));
        await tester.scrollUntilVisible(
          target,
          400,
          scrollable: find.byType(Scrollable).last,
        );
        // A verbose filename card can exceed the viewport height. Its visible
        // top remains tappable even when the card's center is below the screen.
        await tester.tapAt(tester.getTopLeft(target) + const Offset(24, 24));
        await tester.pumpAndSettle();
        expect(identical(chosen, versions.last), true);
        expect(find.byType(MediaVersionPicker), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('one version returns directly and cancellation starts nothing', (
    tester,
  ) async {
    Map<String, Object?>? chosen;
    var count = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                chosen = await MediaVersionPicker.choose(
                  context,
                  versions.take(count).toList(),
                );
              },
              child: const Text('选择'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    expect(identical(chosen, versions.first), true);
    expect(find.byType(MediaVersionPicker), findsNothing);
    count = 2;
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭版本选择'));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
  });
}
