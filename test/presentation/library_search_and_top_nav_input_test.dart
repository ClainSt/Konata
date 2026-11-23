import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/domain/matching/library_search_matcher.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/presentation/shell/top_nav_bar.dart';
import 'package:konata/presentation/theme/konata_theme.dart';

void main() {
  group('LibrarySearchMatcher 精确 ID 与分词相关度排序', () {
    const gundam = Work(
      id: 'w_gundam',
      title: '机动战士高达 雷霆宙域 BANDIT FLOWER',
      originalTitle: '機動戦士ガンダム サンダーボルト BANDIT FLOWER',
      tmdbId: 486947,
      bangumiId: 218610,
    );
    const eightySix = Work(
      id: 'w_86',
      title: '86-不存在的战区-',
      originalTitle: '86―エイティシックス―',
      tmdbId: 100565,
      bangumiId: 302189,
    );
    const titleMid86 = Work(
      id: 'w_mid',
      title: '头文字D AE86 传奇',
      originalTitle: 'Initial D',
      tmdbId: 99999,
    );
    const groupMatch = Work(
      id: 'w_group',
      title: '葬送的芙莉莲',
      originalTitle: '葬送のフリーレン',
      tmdbId: 209867,
    );

    final catalog = <({Work work, List<String> groups})>[
      (work: gundam, groups: const ['VCB-Studio']),
      (work: groupMatch, groups: const ['Studio86']),
      (work: titleMid86, groups: const ['Snow-Raws']),
      (work: eightySix, groups: const ['VCB-Studio']),
    ];

    test('搜索 86 不会因 TMDB/Bangumi ID 含子串 86 而误召回高达，且按标题前缀优先稳定排序', () {
      final result = LibrarySearchMatcher.filterAndRank(
        items: catalog,
        rawQuery: '86',
        workOf: (e) => e.work,
        releaseGroupsOf: (e) => e.groups,
      );

      expect(
        result.map((e) => e.work.id).toList(),
        equals(const ['w_86', 'w_mid', 'w_group']),
      );
      expect(result.any((e) => e.work.id == 'w_gundam'), isFalse);
    });

    test('完整数字 ID 与 tmdb:/bgm: 显式前缀可精准命中目标作品', () {
      for (final q in const [
        '486947',
        'tmdb:486947',
        'tmdb-486947',
        '218610',
        'bgm:218610',
        'bangumi:218610',
      ]) {
        final result = LibrarySearchMatcher.filterAndRank(
          items: catalog,
          rawQuery: q,
          workOf: (e) => e.work,
          releaseGroupsOf: (e) => e.groups,
        );
        expect(result.map((e) => e.work.id).toList(), equals(const ['w_gundam']));
      }
    });

    test('支持空格多词联合匹配（跨译名、原名与压制组）', () {
      final hit = LibrarySearchMatcher.filterAndRank(
        items: catalog,
        rawQuery: '高达 雷霆 vcb',
        workOf: (e) => e.work,
        releaseGroupsOf: (e) => e.groups,
      );
      expect(hit.map((e) => e.work.id).toList(), equals(const ['w_gundam']));

      final miss = LibrarySearchMatcher.filterAndRank(
        items: catalog,
        rawQuery: '高达 种子',
        workOf: (e) => e.work,
        releaseGroupsOf: (e) => e.groups,
      );
      expect(miss, isEmpty);
    });
  });

  group('TopNavBar 顶栏搜索框拖拽选字与防抖流畅度回归', () {
    testWidgets(
      'Windows 顶栏搜索框脱离 DragToMoveArea 拦截，支持鼠标按住拖选、输入防抖合并、IME 组合态避让与清空即时响应',
      (tester) async {
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        final dispatched = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: KonataTheme.lightTheme().copyWith(
              platform: TargetPlatform.windows,
            ),
            home: Scaffold(
              body: TopNavBar(
                activeSection: KonataNavSection.library,
                onSectionChanged: (_) {},
                searchQuery: '',
                onSearchChanged: dispatched.add,
                searchFocusNode: focusNode,
                searchExpanded: true,
                onSearchExpandedChanged: (_) {},
                onToggleTheme: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final textFieldFinder = find.byKey(
          const ValueKey('top_nav_search_text_field'),
        );
        expect(textFieldFinder, findsOneWidget);

        // 1. 确认窗口拖拽区存在，但绝不包裹搜索输入框，避免窃取鼠标拖选与双击选词手势
        expect(find.byType(DragToMoveArea), findsOneWidget);
        expect(
          find.ancestor(
            of: textFieldFinder,
            matching: find.byType(DragToMoveArea),
          ),
          findsNothing,
        );

        final textField = tester.widget<TextField>(textFieldFinder);
        final controller = textField.controller!;

        // 2. 连续快速输入防抖合并：未满防抖时长不触发过滤，满时长仅派发一次最终词
        await tester.enterText(textFieldFinder, '8');
        await tester.pump(const Duration(milliseconds: 50));
        expect(dispatched, isEmpty);

        await tester.enterText(textFieldFinder, '86-不存在的战区-');
        await tester.pump(const Duration(milliseconds: 50));
        expect(dispatched, isEmpty);

        await tester.pump(KonataTheme.searchInputDebounce);
        expect(dispatched, equals(const ['86-不存在的战区-']));

        // 3. 鼠标指针按住水平拖动可正常框选已输入内容
        final fieldRect = tester.getRect(textFieldFinder);
        final dragStart = Offset(fieldRect.left + 4, fieldRect.center.dy);
        final dragEnd = Offset(fieldRect.left + 86, fieldRect.center.dy);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: dragStart);
        await tester.pump();
        await mouse.down(dragStart);
        await tester.pump(const Duration(milliseconds: 16));
        await mouse.moveTo(dragEnd);
        await tester.pump(const Duration(milliseconds: 16));
        await mouse.up();
        await tester.pump();

        expect(controller.selection.isValid, isTrue);
        expect(controller.selection.isCollapsed, isFalse);
        expect(
          controller.selection.textInside(controller.text),
          isNotEmpty,
        );

        // 4. 输入法组合态（拼音未上屏）期间不触发无意义过滤，上屏后防抖触发一次
        dispatched.clear();
        controller.value = const TextEditingValue(
          text: 'gaoda',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(dispatched, isEmpty);

        controller.value = const TextEditingValue(
          text: '高达',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange.empty,
        );
        await tester.pump(KonataTheme.searchInputDebounce);
        expect(dispatched, equals(const ['高达']));

        // 5. 清空内容立即响应（0ms 无需等待防抖）
        dispatched.clear();
        await tester.tap(find.byTooltip('清空并收起'));
        await tester.pump();
        expect(dispatched, equals(const ['']));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}
