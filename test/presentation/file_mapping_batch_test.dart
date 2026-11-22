import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/presentation/dialogs/episode_slot_picker_popover.dart';
import 'package:ccplayer/presentation/dialogs/file_mapping_panel.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';

Widget _wrapPanelTest(Widget child) {
  return MaterialApp(
    theme: KonataTheme.darkTheme(),
    darkTheme: KonataTheme.darkTheme(),
    home: Scaffold(
      body: SizedBox(width: 900, height: 600, child: child),
    ),
  );
}

void main() {
  group('FileMappingPanel 多选与 Shift 区间批量修正测试', () {
    testWidgets('复选框多选 + Shift 区间连选 + 批量设特典/正片 + 批量顺排 + 清空选择', (
      tester,
    ) async {
      final selectedIds = <String>{};
      final rows = List<EditableFileMappingRow>.generate(
        5,
        (i) => EditableFileMappingRow(
          variant: MediaVariant(
            id: 'v_$i',
            workId: 'w_1',
            episodeId: 'ep_$i',
            sourceId: 'src_1',
            relativePath: 'Anime/Episode_0${i + 1}.mkv',
            fileName: 'Episode_0${i + 1}.mkv',
            fileSize: 1000 + i,
          ),
          category: EpisodeCategory.main,
          seasonNumber: 1,
          episodeNumber: i + 1,
          extraType: ExtraKind.sp,
        ),
      );

      await tester.pumpWidget(
        _wrapPanelTest(
          StatefulBuilder(
            builder: (context, setState) => FileMappingPanel(
              rows: rows,
              referenceEpisodes: const <Episode>[],
              defaultMainSeason: 1,
              selectedVariantIds: selectedIds,
              saving: false,
              hasAnyMappingLock: false,
              onChanged: () => setState(() {}),
              onResetMappings: () {},
              onSplitSelected: () {},
              onMoveSelectedToWork: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsNWidgets(5));

      // 单选第 1 行 (index = 0)
      await tester.tap(checkboxes.at(0));
      await tester.pumpAndSettle();
      expect(selectedIds, equals({'v_0'}));
      expect(find.text('已选 1 项'), findsOneWidget);

      // 按住 Shift 点击第 4 行 (index = 3) -> 自动连续勾选 v_0..v_3
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(checkboxes.at(3));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(selectedIds, equals({'v_0', 'v_1', 'v_2', 'v_3'}));
      expect(find.text('已选 4 项'), findsOneWidget);

      // 批量设为特典
      await tester.tap(find.text('设为特典'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(rows[i].category, EpisodeCategory.extra);
        expect(rows[i].seasonNumber, 0);
      }
      expect(rows[4].category, EpisodeCategory.main);

      // 批量设回正片
      await tester.tap(find.text('设为正片'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(rows[i].category, EpisodeCategory.main);
        expect(rows[i].seasonNumber, 1);
      }

      // 批量连续编号：季号设为 2，起始集设为 10
      await tester.tap(find.text('连续编号'));
      await tester.pumpAndSettle();
      final textFields = find.byType(TextField);
      // textFields: [0] 搜索框, [1] 季号, [2] 起始集
      await tester.enterText(textFields.at(1), '2');
      await tester.enterText(textFields.at(2), '10');
      await tester.tap(find.text('应用连续编号'));
      await tester.pumpAndSettle();

      expect(rows[0].seasonNumber, 2);
      expect(rows[0].episodeNumber, 10);
      expect(rows[1].episodeNumber, 11);
      expect(rows[2].episodeNumber, 12);
      expect(rows[3].episodeNumber, 13);
      expect(rows[4].seasonNumber, 1);
      expect(rows[4].episodeNumber, 5);

      // 清空选择 -> 批量工具栏自动收起
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(selectedIds, isEmpty);
      expect(find.textContaining('已选'), findsNothing);
    });
  });
}
