import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

void main() {
  testWidgets('超长目录批选及分集浮层在桌面与窄屏均无布局异常', (tester) async {
    final folder =
        '动画-单作品/86 -不存在的战区- (2021) {tmdb-100565}/CDs/${'Avid／Hands Up to the Sky アルケミラ'.padRight(220, '长')}';
    final rows = [
      for (var i = 0; i < 4; i++)
        EditableFileMappingRow(
          variant: MediaVariant(
            id: 'v$i',
            workId: 'w',
            sourceId: 's',
            fileSize: 1000,
            fileName: '第$i集.mkv',
            relativePath: '${i < 2 ? folder : 'SPs'}/第$i集.mkv',
          ),
          category: EpisodeCategory.main,
          seasonNumber: 1,
          episodeNumber: i + 1,
          extraType: ExtraKind.sp,
        ),
    ];
    String? copiedText;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    for (final width in [760.0, 360.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      final selected = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(width),
          theme: KonataTheme.darkTheme(),
          home: Scaffold(
            body: FileMappingPanel(
              rows: rows,
              selectedVariantIds: selected,
              referenceEpisodes: const [],
              defaultMainSeason: 1,
              saving: false,
              hasLockedMappings: false,
              onChanged: () {},
              onResetAutoMappings: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('mapping_folder_select')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(folder.split('/').last));
      await tester.pumpAndSettle();
      expect(selected, {'v0', 'v1'});
      expect(tester.takeException(), isNull);
      await tester.longPress(
        find.byKey(const ValueKey('mapping_file_info_v0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('文件信息'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              widget.data == rows.first.variant.fileName,
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              widget.data == rows.first.variant.relativePath,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('复制文件名'));
      await tester.pumpAndSettle();
      expect(copiedText, rows.first.variant.fileName);
      await tester.longPress(
        find.byKey(const ValueKey('mapping_file_info_v0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制相对路径'));
      await tester.pumpAndSettle();
      expect(copiedText, rows.first.variant.relativePath);
      await tester.tap(find.byType(EpisodeSlotPickerButton).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final search = find.byType(EditableText).last;
      await tester.enterText(search, '第 03 集');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
