import 'package:feature_history/feature_history.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

final class _FakeNavigator implements AppNavigator {
  final List<WorkId> videoResumedWorks = <WorkId>[];
  final List<WorkId> openedDetails = <WorkId>[];

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
    int? initialCueTrackIndex,
    int? initialPositionSeconds,
  }) async {}

  @override
  Future<void> openSettings({String? sectionId}) async {}

  @override
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  }) async {
    videoResumedWorks.add(workId);
  }

  @override
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId}) async {
    openedDetails.add(workId);
  }

  @override
  Future<bool> pop() async => true;

  @override
  Future<void> switchNavSection(String sectionId) async {}
}

final class _FakeLog implements DiagnosticLogPort {
  @override
  void clear() {}

  @override
  Future<String> buildJsonBundle() async => '{}';

  @override
  Future<String> buildTextReport() async => '';

  @override
  void logError({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    required Object error,
    StackTrace? stackTrace,
    DiagnosticSeverity severity = DiagnosticSeverity.error,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
  }) {}

  @override
  void logEvent({
    required DiagnosticSubsystem subsystem,
    required String code,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? source,
    Map<String, Object?> context = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {}

  @override
  void recordBreadcrumb({
    required String category,
    required String label,
    String? source,
    String? detail,
  }) {}

  @override
  void Function() registerSnapshotContributor(
    String sectionId,
    DiagnosticSnapshotContributor contributor,
  ) => () {};

  @override
  void setVerbose(bool enabled) {}

  @override
  List<DiagnosticEvent> snapshotEvents() => const <DiagnosticEvent>[];

  @override
  List<DiagnosticFaultSummary> summarizeFaults() =>
      const <DiagnosticFaultSummary>[];

  @override
  DiagnosticSummaryCounts get summaryCounts => const DiagnosticSummaryCounts(
    totalEvents: 0,
    warningCount: 0,
    errorCount: 0,
    breadcrumbCount: 0,
  );

  @override
  bool get verboseEnabled => false;
}

void main() {
  testWidgets('播放记录时间轴页面适配四组视口并支持展开续播与清空墓碑', (tester) async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final navigator = _FakeNavigator();
    final today = DateTime.now();
    final now = DateTime(today.year, today.month, today.day, 12);

    db.library.works.upsert(
      const WorkRecord(id: WorkId.trusted('w_1'), title: '灵能百分百'),
    );
    db.library.works.upsert(
      const WorkRecord(id: WorkId.trusted('w_2'), title: '轻音少女'),
    );
    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'p_today_1',
        workId: const WorkId.trusted('w_1'),
        episodeId: const EpisodeId.trusted('ep_1'),
        variantId: const VariantId.trusted('v_1'),
        playedAtMs: now.toUtc().millisecondsSinceEpoch,
        episodeNumber: 1,
        episodeTitle: '自称灵能力者·灵幻新隆',
        positionSeconds: 180,
        durationSeconds: 1440,
      ),
    );
    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'p_today_2',
        workId: const WorkId.trusted('w_1'),
        episodeId: const EpisodeId.trusted('ep_2'),
        variantId: const VariantId.trusted('v_2'),
        playedAtMs: now
            .subtract(const Duration(minutes: 25))
            .toUtc()
            .millisecondsSinceEpoch,
        episodeNumber: 2,
        episodeTitle: '关于青春的烦恼',
        positionSeconds: 90,
        durationSeconds: 1440,
      ),
    );
    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'p_yesterday',
        workId: const WorkId.trusted('w_2'),
        episodeId: const EpisodeId.trusted('ep_k1'),
        variantId: const VariantId.trusted('v_k1'),
        playedAtMs: now
            .subtract(const Duration(days: 1))
            .toUtc()
            .millisecondsSinceEpoch,
        episodeNumber: 5,
        episodeTitle: '顾问老师！',
        positionSeconds: 1440,
        durationSeconds: 1440,
        isCompleted: true,
      ),
    );

    expect(featureHistoryManifest.id, equals('feature_history'));
    expect(featureHistoryManifest.navSections.single.id, equals('history'));
    expect(featureHistoryManifest.navSections.single.order, equals(30));

    final deps = FeatureHistoryDependencies(
      databases: db,
      navigator: navigator,
      diagnosticLog: _FakeLog(),
      platform: KonataPlatform.windows,
    );

    const viewports = <Size>[
      Size(390, 780),
      Size(780, 390),
      Size(1024, 700),
      Size(1440, 900),
    ];

    for (final viewport in viewports) {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final toastController = KonataToastController();
      addTearDown(toastController.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            featureHistoryDependenciesProvider.overrideWithValue(deps),
          ],
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: KonataToastScope(
              controller: toastController,
              child: Scaffold(
                body:
                    featureHistoryManifest.navSections.single.viewBuilder(
                          const ViewSlotContext(),
                        )
                        as Widget,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('播放记录'), findsOneWidget);
      expect(
        find.text(now.toIso8601String().substring(0, 10).replaceAll('-', '.')),
        findsOneWidget,
      );
      expect(
        find.text(
          now
              .subtract(const Duration(days: 1))
              .toIso8601String()
              .substring(0, 10)
              .replaceAll('-', '.'),
        ),
        findsOneWidget,
      );
      expect(find.text('灵能百分百'), findsOneWidget);
      expect(find.text('轻音少女'), findsOneWidget);
    }

    // 在桌面视口交互：点击分组卡展开子集、点击续播并执行清空墓碑。
    await tester.tap(find.text('灵能百分百'));
    await tester.pumpAndSettle();
    expect(find.textContaining('关于青春的烦恼'), findsOneWidget);

    await tester.tap(find.byType(HistoryExpandedEpisodeRow).first);
    await tester.pump();
    expect(navigator.videoResumedWorks.first.value, equals('w_1'));

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选当前'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除 (3)'));
    await tester.pumpAndSettle();
    expect(find.text('清理所选播放记录'), findsOneWidget);
    await tester.tap(find.text('确认清理 (3)'));
    await tester.pumpAndSettle();

    expect(find.text('暂无播放记录'), findsOneWidget);
    final tombstones = db.userState.playbackRecords.listAllWithTombstones();
    expect(tombstones.length, equals(3));
    expect(tombstones.every((r) => r.isDeleted), isTrue);
  });

  testWidgets('支持介质胶囊过滤、横向展开抽屉与批量标记已看已听状态持久化', (tester) async {
    final db = KonataDatabaseBundle.openInMemory();
    addTearDown(db.close);
    final navigator = _FakeNavigator();
    final today = DateTime.now();
    final now = DateTime(today.year, today.month, today.day, 12);

    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('w_v'),
        title: '葬送的芙莉莲',
        year: 2023,
        updatedAtMs: 100,
      ),
    );
    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('w_a'),
        title: '孤独摇滚精选',
        year: 2022,
        updatedAtMs: 100,
      ),
    );
    db.library.mediaSources.upsert(
      const MediaSourceRecord(
        id: SourceId.trusted('src_1'),
        kind: MediaSourceKind.local,
        label: '本地',
        location: 'D:/Media',
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: EpisodeId.trusted('ep_v1'),
        workId: WorkId.trusted('w_v'),
        seasonNumber: 1,
        episodeNumber: 1,
        category: EpisodeCategory.main,
        title: '冒险的终点',
        updatedAtMs: 100,
      ),
    );
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('var_v1'),
        workId: WorkId.trusted('w_v'),
        episodeId: EpisodeId.trusted('ep_v1'),
        sourceId: SourceId.trusted('src_1'),
        relativePath: 'Frieren/01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
        assetKind: AssetKind.video,
        updatedAtMs: 100,
      ),
    );
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('var_a1'),
        workId: WorkId.trusted('w_a'),
        sourceId: SourceId.trusted('src_1'),
        relativePath: 'Bocchi/Disc 1/01.flac',
        fileName: '01.flac',
        fileSize: 512,
        assetKind: AssetKind.cdAlbum,
        updatedAtMs: 100,
      ),
    );

    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'rec_v1',
        workId: const WorkId.trusted('w_v'),
        episodeId: const EpisodeId.trusted('ep_v1'),
        variantId: const VariantId.trusted('var_v1'),
        seasonNumber: 1,
        episodeNumber: 1,
        episodeTitle: '冒险的终点',
        sourceKind: MediaSourceKind.local,
        playedAtMs: now.toUtc().millisecondsSinceEpoch,
        positionSeconds: 300,
        durationSeconds: 1440,
      ),
    );
    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'rec_a1',
        workId: const WorkId.trusted('w_a'),
        episodeId: const EpisodeId.trusted('ep_a1'),
        variantId: const VariantId.trusted('var_a1'),
        seasonNumber: 0,
        episodeTitle: '青春コンプレックス',
        sourceKind: MediaSourceKind.local,
        playedAtMs: now
            .subtract(const Duration(minutes: 10))
            .toUtc()
            .millisecondsSinceEpoch,
        positionSeconds: 80,
        durationSeconds: 200,
      ),
    );

    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('w_v2'),
        title: '第二部动画',
        updatedAtMs: 100,
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: EpisodeId.trusted('ep_v2'),
        workId: WorkId.trusted('w_v2'),
        seasonNumber: 1,
        episodeNumber: 1,
        category: EpisodeCategory.main,
        title: '第二部第一话',
        updatedAtMs: 100,
      ),
    );
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('var_v2'),
        workId: WorkId.trusted('w_v2'),
        episodeId: EpisodeId.trusted('ep_v2'),
        sourceId: SourceId.trusted('src_1'),
        relativePath: 'Other/01.mkv',
        fileName: '01.mkv',
        fileSize: 1024,
        assetKind: AssetKind.video,
        updatedAtMs: 100,
      ),
    );
    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'rec_v2',
        workId: const WorkId.trusted('w_v2'),
        episodeId: const EpisodeId.trusted('ep_v2'),
        variantId: const VariantId.trusted('var_v2'),
        seasonNumber: 1,
        episodeNumber: 1,
        episodeTitle: '第二部第一话',
        playedAtMs: now
            .subtract(const Duration(minutes: 5))
            .toUtc()
            .millisecondsSinceEpoch,
        positionSeconds: 120,
        durationSeconds: 1440,
      ),
    );

    final deps = FeatureHistoryDependencies(
      databases: db,
      navigator: navigator,
      diagnosticLog: _FakeLog(),
      platform: KonataPlatform.windows,
    );
    final toastController = KonataToastController();
    addTearDown(toastController.dispose);

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [featureHistoryDependenciesProvider.overrideWithValue(deps)],
        child: MaterialApp(
          theme: KonataTheme.darkTheme(),
          home: KonataToastScope(
            controller: toastController,
            child: Scaffold(
              body:
                  featureHistoryManifest.navSections.single.viewBuilder(
                        const ViewSlotContext(),
                      )
                      as Widget,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(HistoryDaySectionView), findsOneWidget);
    expect(find.byType(HistoryWorkTimelineCard), findsNWidgets(2));
    expect(find.text('全部'), findsNothing);
    expect(find.text('孤独摇滚精选'), findsNothing);
    final videoCard = find.byWidgetPredicate(
      (w) => w is HistoryWorkTimelineCard && w.group.workTitle == '葬送的芙莉莲',
    );
    final otherCard = find.byWidgetPredicate(
      (w) => w is HistoryWorkTimelineCard && w.group.workTitle == '第二部动画',
    );
    expect(tester.getTopLeft(videoCard).dy, tester.getTopLeft(otherCard).dy);
    expect(
      tester.getTopLeft(videoCard).dx,
      isNot(tester.getTopLeft(otherCard).dx),
    );
    await tester.tap(find.text('葬送的芙莉莲'));
    await tester.pumpAndSettle();
    final singleRow = find.byType(HistoryExpandedEpisodeRow);
    expect(singleRow, findsOneWidget);
    expect(
      tester.getSize(singleRow).width,
      greaterThan(tester.getSize(videoCard).width - 30),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('音频'));
    await tester.pumpAndSettle();
    expect(find.text('孤独摇滚精选'), findsOneWidget);
    expect(find.text('葬送的芙莉莲'), findsNothing);
    expect(find.text('标记为已听'), findsOneWidget);
    await tester.tap(find.text('孤独摇滚精选'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryExpandedEpisodeRow), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.done_all_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选当前'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('标为已完播'));
    await tester.pumpAndSettle();
    expect(find.text('已听完'), findsOneWidget);
    expect(
      db.userState.playbackRecords
          .listAllWithTombstones()
          .where((r) => r.isCompleted)
          .length,
      1,
    );

    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    expect(find.text('标记为已看'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.done_all_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选当前'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('标为已完播'));
    await tester.pumpAndSettle();
    expect(find.text('已看完'), findsWidgets);
    expect(
      db.userState.playbackRecords.listAllWithTombstones().every(
        (r) => r.isCompleted,
      ),
      isTrue,
    );
  });
}
