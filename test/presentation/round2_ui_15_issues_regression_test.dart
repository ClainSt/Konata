import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ccplayer/application/providers/artwork_provider.dart';
import 'package:ccplayer/application/providers/detail_display_preferences_provider.dart';
import 'package:ccplayer/application/providers/library_providers.dart';
import 'package:ccplayer/application/providers/source_actions_provider.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_source.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/playback_record.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/repositories/file_system_gateway.dart';
import 'package:ccplayer/infrastructure/database/drift_library_repository.dart';
import 'package:ccplayer/infrastructure/database/konata_database.dart';
import 'package:ccplayer/presentation/detail/detail_hero_info.dart';
import 'package:ccplayer/presentation/detail/work_detail_page.dart';
import 'package:ccplayer/presentation/dialogs/manual_match_dialog.dart';
import 'package:ccplayer/presentation/dialogs/series_manage_dialog.dart';
import 'package:ccplayer/presentation/dialogs/work_manual_edit_dialog.dart';
import 'package:ccplayer/presentation/history/playback_history_page.dart';
import 'package:ccplayer/presentation/library/library_page.dart';
import 'package:ccplayer/presentation/settings/settings_display_panel.dart';
import 'package:ccplayer/presentation/settings/settings_players_panel.dart';
import 'package:ccplayer/presentation/sources/source_folder_picker_dialog.dart';
import 'package:ccplayer/presentation/sources/source_selected_scope_panel.dart';
import 'package:ccplayer/presentation/theme/konata_theme.dart';
import 'package:ccplayer/presentation/widgets/design_system/konata_soft_text_field.dart';

Future<Uint8List> _encodeSolidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

class _FakePickerActions extends KonataActionsCoordinator {
  _FakePickerActions(super.ref);

  @override
  Future<List<RemoteEntry>> listSourceDirectory(
    MediaSource source,
    String relativePath,
  ) async {
    if (relativePath.isNotEmpty) return const [];
    return const [
      RemoteEntry(name: 'AnimA', relativePath: 'AnimA', isDirectory: true),
      RemoteEntry(name: 'AnimB', relativePath: 'AnimB', isDirectory: true),
      RemoteEntry(name: 'AnimC', relativePath: 'AnimC', isDirectory: true),
    ];
  }
}

Widget _wrapTestApp(
  Widget child, {
  List<Override> overrides = const [],
  ThemeMode mode = ThemeMode.dark,
  EdgeInsets viewInsets = EdgeInsets.zero,
  EdgeInsets padding = EdgeInsets.zero,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: KonataTheme.lightTheme(),
      darkTheme: KonataTheme.darkTheme(),
      themeMode: mode,
      home: Builder(
        builder: (ctx) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(
            viewInsets: viewInsets,
            padding: padding,
          ),
          child: Scaffold(resizeToAvoidBottomInset: false, body: child),
        ),
      ),
    ),
  );
}

WorkDetailBundle _buildSampleBundle({
  String id = 'w1',
  String title = '86：不存在的战区',
  String? backdropPath = '/backdrop.jpg',
  String? logoPath = '/logo.png',
  String? overview = '为了应对无人机的侵攻，共和国宣称无人伤亡的战场上，青年们正持续奋战。',
}) {
  const source = MediaSource(
    id: 'src_1',
    kind: MediaSourceKind.local,
    label: '本地库',
    location: r'D:\Anime',
  );
  final work = Work(
    id: id,
    title: title,
    originalTitle: '86―エイティシックス―',
    year: 2021,
    overview: overview,
    posterPath: '/poster.jpg',
    backdropPath: backdropPath,
    logoPath: logoPath,
    bangumiScore: 8.6,
    tmdbId: 100565,
    tmdbMediaType: TmdbMediaType.tv,
    scrapeStatus: ScrapeStatus.matched,
  );
  final ep1 = Episode(
    id: '${id}_ep1',
    workId: id,
    seasonNumber: 1,
    episodeNumber: 1,
    title: '送葬者',
  );
  final var1 = MediaVariant(
    id: '${id}_v1',
    workId: id,
    episodeId: ep1.id,
    sourceId: source.id,
    relativePath: '86/01.mkv',
    fileName: '[Moozzi2] 86 - 01.mkv',
    fileSize: 900 * 1024 * 1024,
  );
  return WorkDetailBundle(
    work: work,
    episodes: [ep1],
    variants: [var1],
    sourcesById: {source.id: source},
    latestPlayback: null,
    cdVariants: const [],
    scanVariants: const [],
    editableSupplementaryItems: const [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final androidVariant = TargetPlatformVariant.only(TargetPlatform.android);

  group('第二轮 15 项交互与排版缺陷回归测试', () {
    testWidgets(
      '问题 01 & 11：弹窗软键盘稳态保持焦点且手机横屏切换为紧凑输入态不溢出',
      variant: androidVariant,
      (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);
      addTearDown(db.close);

      final bundle = _buildSampleBundle();
      await repo.upsertWork(bundle.work);

      Future<void> pumpDialogWithInsets(
        EdgeInsets insets, {
        Size? viewport,
        EdgeInsets padding = EdgeInsets.zero,
      }) async {
        if (viewport != null) {
          tester.view.physicalSize = viewport;
        }
        await tester.pumpWidget(
          _wrapTestApp(
            Center(child: SeriesManageDialog(bundle: bundle)),
            viewInsets: insets,
            padding: padding,
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              seriesGroupsProvider.overrideWith((_) async => const []),
              libraryItemsProvider.overrideWith((_) async => const []),
            ],
          ),
        );
        await tester.pump();
      }

      await pumpDialogWithInsets(EdgeInsets.zero);
      await tester.pump(const Duration(milliseconds: 200));

      final textFieldFinder = find.byType(TextField).first;
      await tester.tap(textFieldFinder);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(FocusManager.instance.primaryFocus!.hasFocus, isTrue);

      // 模拟输入法多帧动画推高 viewInsets.bottom
      for (final insetBottom in const [80.0, 180.0, 290.0]) {
        await pumpDialogWithInsets(EdgeInsets.only(bottom: insetBottom));
        expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
      }

      // 问题 11：手机横屏（height < 500）弹出软键盘自动进入紧凑输入模式，隐藏标题并恢复时不溢出
      await pumpDialogWithInsets(
        const EdgeInsets.only(bottom: 180),
        viewport: const Size(800, 360),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('管理系列编组').hitTestable(), findsNothing);

      // 模拟真机横屏极限高度（834x375dp，状态栏 33dp + 软键盘 270dp，仅余 72dp 净空）
      await pumpDialogWithInsets(
        const EdgeInsets.only(bottom: 270),
        viewport: const Size(834, 375),
        padding: const EdgeInsets.only(top: 33),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final extremeFieldRect = tester.getRect(textFieldFinder);
      final extremeBoxFinder = find.ancestor(
        of: textFieldFinder,
        matching: find.byType(KonataSoftTextField),
      );
      final extremeBoxRect = tester.getRect(extremeBoxFinder.first);
      expect(extremeFieldRect.top, greaterThanOrEqualTo(33.0));
      expect(extremeFieldRect.bottom, lessThanOrEqualTo(105.5));
      expect(extremeFieldRect.height, greaterThanOrEqualTo(16.0));
      expect(extremeBoxRect.top, greaterThanOrEqualTo(33.0));
      expect(extremeBoxRect.bottom, lessThanOrEqualTo(105.5));
      expect(extremeBoxRect.height, greaterThanOrEqualTo(28.0));

      // 收起键盘后恢复完整弹窗标题
      await pumpDialogWithInsets(
        EdgeInsets.zero,
        viewport: const Size(800, 360),
      );
      expect(find.text('管理系列编组').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '问题 06：媒体源多选目录点击已选入口栏切换至整窗管理视图并支持全选反选批量移除',
      variant: androidVariant,
      (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(412, 915);
      addTearDown(tester.view.resetPhysicalSize);

      const source = MediaSource(
        id: 'src_picker',
        kind: MediaSourceKind.webdav,
        label: '云盘媒体源',
        location: 'http://192.168.1.2:29798/dav',
      );

      await tester.pumpWidget(
        _wrapTestApp(
          Center(child: SourceFolderPickerDialog(source: source)),
          overrides: [
            konataActionsProvider.overrideWith((ref) => _FakePickerActions(ref)),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 勾选 AnimA 与 AnimB
      final animACheck = find.descendant(
        of: find.ancestor(
          of: find.text('AnimA'),
          matching: find.byType(SourceBrowserEntryRow),
        ),
        matching: find.byType(Checkbox),
      );
      await tester.tap(animACheck.first);
      await tester.pump();
      final animBCheck = find.descendant(
        of: find.ancestor(
          of: find.text('AnimB'),
          matching: find.byType(SourceBrowserEntryRow),
        ),
        matching: find.byType(Checkbox),
      );
      await tester.tap(animBCheck.first);
      await tester.pump();

      expect(find.text('已选目录 · 2（点击管理）'), findsOneWidget);

      // 点击紧凑入口栏切换到整窗「已选目录管理视图」
      await tester.tap(find.byKey(const ValueKey('source_selected_scope_entry')));
      await tester.pumpAndSettle();

      expect(find.text('返回浏览目录'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('反选'), findsOneWidget);

      // 验证反选、全选与移除
      await tester.tap(find.text('反选'));
      await tester.pump();
      expect(find.text('移除 (2)'), findsOneWidget);
      await tester.tap(find.text('反选'));
      await tester.pump();
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('移除 (2)'), findsOneWidget);
      await tester.tap(find.text('移除 (2)'));
      await tester.pump();

      expect(find.text('当前未勾选指定目录（默认扫描整源）'), findsOneWidget);
      await tester.tap(find.text('返回浏览目录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('source_selected_scope_entry')), findsOneWidget);
    });

    testWidgets(
      '问题 09 & 10：手动编辑弹窗三端页签统一精简，文件映射搜索框与按目录全选同行对齐',
      variant: androidVariant,
      (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);

      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);
      addTearDown(db.close);

      final bundle = _buildSampleBundle();
      await repo.upsertWork(bundle.work);

      await tester.pumpWidget(
        _wrapTestApp(
          Center(child: WorkManualEditDialog(bundle: bundle)),
          overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('元数据'), findsOneWidget);
      expect(find.text('文件映射'), findsOneWidget);
      expect(find.text('附属共享'), findsOneWidget);
      expect(find.textContaining('文件映射 ('), findsNothing);
      expect(find.textContaining('附属共享 ('), findsNothing);

      await tester.tap(find.text('文件映射'));
      await tester.pumpAndSettle();

      final searchField = find.byKey(const ValueKey('file_mapping_search_field'));
      final dirDropdown = find.text('按目录全选');
      expect(searchField, findsOneWidget);
      expect(dirDropdown, findsOneWidget);

      final searchRect = tester.getRect(searchField);
      final dropRect = tester.getRect(dirDropdown);
      expect((searchRect.center.dy - dropRect.center.dy).abs(), lessThanOrEqualTo(6.0));
      expect(searchRect.right, lessThanOrEqualTo(dropRect.left));
    });

    testWidgets(
      '问题 07 & 12：图书馆顶栏移除蓝文件夹、遮眼在左待复核最右，搜索展开直接顶替首行',
      variant: androidVariant,
      (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);

      final png = (await tester.runAsync(
        () => _encodeSolidPng(16, 24, Colors.blueGrey),
      ))!;
      final matched = WorkLibraryItem(
        work: const Work(
          id: 'w_lib_1',
          title: '加速世界',
          scrapeStatus: ScrapeStatus.matched,
        ),
        variants: const [],
        episodeCount: 24,
        releaseGroups: const ['VCB-S'],
      );
      final reviewItem = WorkLibraryItem(
        work: const Work(
          id: 'w_rev_1',
          title: '待复核测试',
          scrapeStatus: ScrapeStatus.needsReview,
        ),
        variants: const [],
        episodeCount: 1,
        releaseGroups: const [],
      );

      await tester.pumpWidget(
        _wrapTestApp(
          const LibraryPage(),
          overrides: [
            libraryItemsProvider.overrideWith((_) async => [matched, reviewItem]),
            hiddenWorksProvider.overrideWith(
              (_) async => const [Work(id: 'w_hid', title: '已隐藏作品', isHidden: true)],
            ),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => png,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 不存在旧蓝色文件夹图标
      expect(find.byIcon(Icons.rule_folder_outlined), findsNothing);
      // 存在遮眼与待复核且顺序为 遮眼在左、待复核在最右
      final eyeFinder = find.byIcon(Icons.visibility_off_outlined);
      final reviewFinder = find.byKey(const ValueKey('library_review_pill'));
      expect(eyeFinder, findsOneWidget);
      expect(reviewFinder, findsOneWidget);
      expect(tester.getRect(eyeFinder).right, lessThanOrEqualTo(tester.getRect(reviewFinder).left));
      expect(find.text('1 部'), findsOneWidget);

      // 点击第二行最右侧放大镜后顶替第一行显示搜索栏
      await tester.tap(find.byKey(const ValueKey('library_header_search_button')));
      await tester.pumpAndSettle();
      expect(find.text('全部作品'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);

      // 关闭搜索后恢复「全部作品」
      await tester.tap(find.byKey(const ValueKey('library_header_search_close')));
      await tester.pumpAndSettle();
      expect(find.text('全部作品'), findsOneWidget);
    });

    testWidgets(
      '问题 02 & 03：详情页标题单行同行对齐，播放器设置移除内置核心与默认路由卡片',
      variant: androidVariant,
      (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _wrapTestApp(
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: const [SettingsDisplayPanel(), SettingsPlayersPanel()],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final titleRect = tester.getRect(find.text('详情页标题'));
      final dropdownTextRect = tester.getRect(find.text('标题徽标').first);
      expect((titleRect.center.dy - dropdownTextRect.center.dy).abs(), lessThanOrEqualTo(6.0));
      expect(find.text('内置核心与默认路由'), findsNothing);
    });

    testWidgets(
      '问题 04、05 & 14：Android 播放记录使用继续观看/继续收听，音频卡紧凑排版且平板竖屏撑满宽幅不缩窄',
      variant: androidVariant,
      (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(768, 1024);
      addTearDown(tester.view.resetPhysicalSize);

      final png = (await tester.runAsync(
        () => _encodeSolidPng(32, 32, Colors.indigo),
      ))!;
      final videoWork = const Work(
        id: 'w_hist_vid',
        title: '加速世界',
        posterPath: '/p.jpg',
        scrapeStatus: ScrapeStatus.matched,
      );
      final audioWork = const Work(
        id: 'w_hist_aud',
        title: '86：不存在的战区',
        posterPath: '/a.jpg',
        scrapeStatus: ScrapeStatus.matched,
      );

      final videoRec = PlaybackRecord(
        id: 'r_v1',
        workId: 'w_hist_vid',
        episodeId: 'ep1',
        variantId: 'v1',
        seasonNumber: 1,
        episodeNumber: 1,
        episodeTitle: '加速',
        sourceType: MediaSourceKind.webdav,
        playedAt: DateTime(2026, 11, 18, 12, 0),
        positionSeconds: 120,
        durationSeconds: 1440,
      );
      final audioRec = PlaybackRecord(
        id: '${PlaybackRecord.audioEpisodePrefix}r_a1',
        workId: 'w_hist_aud',
        episodeId: '${PlaybackRecord.audioEpisodePrefix}cd1_t01',
        variantId: 'va1',
        seasonNumber: 0,
        episodeNumber: 1,
        episodeTitle: '01 · Avid',
        sourceType: MediaSourceKind.local,
        playedAt: DateTime(2026, 11, 18, 11, 0),
        positionSeconds: 45,
        durationSeconds: 250,
      );

      await tester.pumpWidget(
        _wrapTestApp(
          const PlaybackHistoryPage(),
          overrides: [
            playbackHistoryProvider.overrideWith((_) async => [videoRec, audioRec]),
            libraryItemsProvider.overrideWith(
              (_) async => [
                WorkLibraryItem(
                  work: videoWork,
                  variants: const [],
                  episodeCount: 24,
                  releaseGroups: const [],
                ),
                WorkLibraryItem(
                  work: audioWork,
                  variants: const [],
                  episodeCount: 11,
                  releaseGroups: const [],
                ),
              ],
            ),
            tmdbImageLoaderProvider.overrideWithValue(
              (_, {targetWidth, imageSize}) async => png,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // 平板竖屏卡片横向应充分利用宽度而非缩在左上角窄条
      final titleRect = tester.getRect(find.text('加速世界'));
      expect(titleRect.width, greaterThan(120.0));

      // 视频记录更多菜单文案应为「继续观看」
      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await tester.pumpAndSettle();
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.text('使用内置播放器续播'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 切换至音频记录卡片校验紧凑无溢出与「继续收听」
      await tester.tap(find.text('音频'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Avid'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await tester.pumpAndSettle();
      expect(find.text('继续收听'), findsOneWidget);
    });

    testWidgets(
      '问题 08 & 13：竖向与横向 ClearLogo 均锁死于头图遮罩不改变正片起点，三端定比背景图无溢出',
      variant: androidVariant,
      (tester) async {
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final backdropPng = (await tester.runAsync(
        () => _encodeSolidPng(320, 180, Colors.deepPurple),
      ))!;
      final tallLogoPng = (await tester.runAsync(
        () => _encodeSolidPng(200, 400, Colors.white),
      ))!;
      final wideLogoPng = (await tester.runAsync(
        () => _encodeSolidPng(800, 120, Colors.white),
      ))!;
      var useTallLogo = true;

      final bundle = _buildSampleBundle();
      final db = KonataDatabase(NativeDatabase.memory());
      final repo = DriftLibraryRepository(db);
      addTearDown(db.close);

      Future<void> pumpDetail(Size viewport) async {
        tester.view.physicalSize = viewport;
        await tester.pumpWidget(
          _wrapTestApp(
            const WorkDetailPage(workId: 'w1'),
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repo),
              workDetailBundleProvider('w1').overrideWith((_) async => bundle),
              detailDisplayPreferencesProvider.overrideWith(
                (_) => DetailDisplayPreferencesNotifier()
                  ..state = const DetailDisplayPreferences(
                    showTitleText: true,
                    showTitleLogo: true,
                    showOverview: true,
                  ),
              ),
              tmdbImageLoaderProvider.overrideWithValue((
                url, {
                targetWidth,
                imageSize,
              }) async {
                if (url.contains('logo')) {
                  return useTallLogo ? tallLogoPng : wideLogoPng;
                }
                return backdropPng;
              }),
            ],
          ),
        );
        await tester.pumpAndSettle();
      }

      // 1. 手机竖屏：竖长 200x400 Logo vs 宽扁 800x120 Logo 下方正片/播放钮起始 Y 坐标零位移
      useTallLogo = true;
      await pumpDetail(const Size(390, 844));
      final tallLogoBox = tester.getSize(
        find.byKey(const ValueKey('detail_hero_locked_logo')),
      );
      expect(tallLogoBox.height, lessThanOrEqualTo(56.0));
      final playTopTall = tester.getTopLeft(find.text('开始播放')).dy;
      final epTabTopTall = tester.getTopLeft(find.text('正片 (1)')).dy;

      useTallLogo = false;
      await pumpDetail(const Size(390, 844));
      final wideLogoBox = tester.getSize(
        find.byKey(const ValueKey('detail_hero_locked_logo')),
      );
      expect(wideLogoBox.height, lessThanOrEqualTo(56.0));
      expect(tester.getTopLeft(find.text('开始播放')).dy, closeTo(playTopTall, 0.5));
      expect(tester.getTopLeft(find.text('正片 (1)')).dy, closeTo(epTabTopTall, 0.5));
      expect(tester.takeException(), isNull);

      // 2. 平板竖屏：16:9 顶部定比背景 + 下方纯暗区简介与选集
      await pumpDetail(const Size(768, 1024));
      expect(find.byType(DetailLockedClearLogo), findsOneWidget);
      expect(find.textContaining('无人机'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 3. 手机横屏：「左文右画」紧凑头图 + 下方平齐选集滑轨无溢出
      await pumpDetail(const Size(844, 390));
      expect(find.byKey(const ValueKey('detail_hero_locked_logo')), findsOneWidget);
      expect(find.textContaining('送葬者'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 补充覆盖 ManualMatchDialog 焦点在场不崩溃
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _wrapTestApp(
          const Center(
            child: ManualMatchDialog(workId: 'w1', initialQuery: '86'),
          ),
          overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
