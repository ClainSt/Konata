import 'package:feature_history/feature_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

final class _FakeNavigator implements AppNavigator {
  final List<({WorkId workId, EpisodeId? episodeId, VariantId? variantId})>
  videoCalls =
      <({WorkId workId, EpisodeId? episodeId, VariantId? variantId})>[];
  final List<
    ({
      WorkId workId,
      VariantId? variantId,
      int? initialCueTrackIndex,
      int? initialPositionSeconds,
    })
  >
  audioCalls =
      <
        ({
          WorkId workId,
          VariantId? variantId,
          int? initialCueTrackIndex,
          int? initialPositionSeconds,
        })
      >[];
  final List<WorkId> detailCalls = <WorkId>[];

  @override
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
    int? initialCueTrackIndex,
    int? initialPositionSeconds,
  }) async {
    audioCalls.add((
      workId: workId,
      variantId: variantId,
      initialCueTrackIndex: initialCueTrackIndex,
      initialPositionSeconds: initialPositionSeconds,
    ));
  }

  @override
  Future<void> openSettings({String? sectionId}) async {}

  @override
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  }) async {
    videoCalls.add((
      workId: workId,
      episodeId: episodeId,
      variantId: variantId,
    ));
  }

  @override
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId}) async {
    detailCalls.add(workId);
  }

  @override
  Future<bool> pop() async => true;

  @override
  Future<void> switchNavSection(String sectionId) async {}
}

final class _StubLog implements DiagnosticLogPort {
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
  late KonataDatabaseBundle db;
  late _FakeNavigator navigator;
  late DateTime fixedNow;

  setUp(() {
    db = KonataDatabaseBundle.openInMemory();
    navigator = _FakeNavigator();
    fixedNow = DateTime(2026, 7, 10, 20, 0);

    db.library.mediaSources.upsert(
      const MediaSourceRecord(
        id: SourceId.trusted('src_1'),
        kind: MediaSourceKind.local,
        label: '本地测试盘',
        location: 'D:/Anime',
      ),
    );
    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('w_frieren'),
        title: '葬送的芙莉莲',
        originalTitle: '葬送のフリーレン',
        tmdbMediaType: TmdbMediaType.tv,
      ),
    );
    db.library.mediaSources.upsert(
      const MediaSourceRecord(
        id: SourceId.trusted('src_1'),
        kind: MediaSourceKind.local,
        label: '本地测试盘',
        location: 'D:/Anime',
      ),
    );
    db.library.works.upsert(
      const WorkRecord(
        id: WorkId.trusted('w_bocchi'),
        title: '孤独摇滚！',
        originalTitle: 'ぼっち・ざ・ろっく！',
        tmdbMediaType: TmdbMediaType.tv,
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: EpisodeId.trusted('ep_f1'),
        workId: WorkId.trusted('w_frieren'),
        seasonNumber: 1,
        episodeNumber: 1,
        title: '冒险的终点',
      ),
    );
    db.library.episodes.upsert(
      const EpisodeRecord(
        id: EpisodeId.trusted('ep_f2'),
        workId: WorkId.trusted('w_frieren'),
        seasonNumber: 1,
        episodeNumber: 2,
        title: '就算不是魔法也没关系',
      ),
    );
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('v_f1'),
        workId: WorkId.trusted('w_frieren'),
        episodeId: EpisodeId.trusted('ep_f1'),
        sourceId: SourceId.trusted('src_1'),
        relativePath: '/Frieren/01.mkv',
        fileName: 'Frieren.E01.mkv',
        fileSize: 1024,
        assetKind: AssetKind.video,
      ),
    );
    db.library.mediaVariants.upsert(
      const MediaVariantRecord(
        id: VariantId.trusted('v_b_ost'),
        workId: WorkId.trusted('w_bocchi'),
        sourceId: SourceId.trusted('src_1'),
        relativePath: '/Bocchi/CD/01.flac',
        fileName: '青春コンプレックス.flac',
        fileSize: 512,
        assetKind: AssetKind.cdAlbum,
      ),
    );

    final today1 = DateTime(2026, 7, 10, 19, 30).toUtc().millisecondsSinceEpoch;
    final today2 = DateTime(2026, 7, 10, 18, 10).toUtc().millisecondsSinceEpoch;
    final yesterday = DateTime(
      2026,
      7,
      9,
      22,
      15,
    ).toUtc().millisecondsSinceEpoch;
    final older = DateTime(2026, 7, 3, 14, 0).toUtc().millisecondsSinceEpoch;

    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'rec_1',
        workId: const WorkId.trusted('w_frieren'),
        episodeId: const EpisodeId.trusted('ep_f1'),
        variantId: const VariantId.trusted('v_f1'),
        playedAtMs: today1,
        seasonNumber: 1,
        episodeNumber: 1,
        episodeTitle: '冒险的终点',
        positionSeconds: 700,
        durationSeconds: 1440,
      ),
    );
    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'rec_2',
        workId: const WorkId.trusted('w_frieren'),
        episodeId: const EpisodeId.trusted('ep_f2'),
        variantId: const VariantId.trusted('v_f1'),
        playedAtMs: today2,
        seasonNumber: 1,
        episodeNumber: 2,
        episodeTitle: '就算不是魔法也没关系',
        positionSeconds: 1400,
        durationSeconds: 1440,
        isCompleted: true,
      ),
    );
    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'rec_cd',
        workId: const WorkId.trusted('w_bocchi'),
        episodeId: const EpisodeId.trusted('cd::v_b_ost#cue:2'),
        variantId: const VariantId.trusted('v_b_ost'),
        playedAtMs: yesterday,
        seasonNumber: 0,
        episodeNumber: 1,
        episodeTitle: '青春情结',
        positionSeconds: 95,
        durationSeconds: 215,
      ),
    );
    db.userState.playbackRecords.upsert(
      PlaybackRecordEntity(
        id: 'rec_old',
        workId: const WorkId.trusted('w_frieren'),
        episodeId: const EpisodeId.trusted('ep_f1'),
        variantId: const VariantId.trusted('v_f1'),
        playedAtMs: older,
        seasonNumber: 1,
        episodeNumber: 1,
        episodeTitle: '冒险的终点',
        positionSeconds: 300,
        durationSeconds: 1440,
      ),
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('按今天/昨天/具体日期二级分组并正确过滤检索和续播路由', () async {
    final controller = HistoryController(
      databases: db,
      navigator: navigator,
      diagnosticLog: _StubLog(),
      clock: () => fixedNow,
    );
    addTearDown(controller.dispose);

    expect(controller.totalCount, equals(4));
    expect(controller.videoCount, equals(3));
    expect(controller.audioCount, equals(1));
    expect(controller.dayGroups.length, equals(3));
    expect(controller.dayGroups[0].dayTitle, equals('今天'));
    expect(controller.dayGroups[0].works.single.entryCount, equals(2));
    expect(controller.dayGroups[1].dayTitle, equals('昨天'));
    expect(controller.dayGroups[1].works.single.isAudioGroup, isTrue);
    expect(controller.dayGroups[2].dayTitle, equals('2026.07.03'));

    // 按媒体分类与关键字筛选。
    controller.setFilter(HistoryMediaFilter.audio);
    expect(controller.dayGroups.length, equals(1));
    expect(controller.dayGroups.single.works.single.workTitle, equals('孤独摇滚！'));

    controller.setFilter(HistoryMediaFilter.all);
    controller.setSearchQuery('フリーレン');
    expect(controller.dayGroups.length, equals(2));

    controller.setSearchQuery('');
    final todayVideoItem = controller.dayGroups.first.works.first.latestItem;
    await controller.resumePlayback(todayVideoItem);
    expect(navigator.videoCalls.length, equals(1));
    expect(navigator.videoCalls.single.workId.value, equals('w_frieren'));
    expect(navigator.videoCalls.single.episodeId?.value, equals('ep_f1'));

    final yesterdayAudioItem = controller.dayGroups[1].works.first.latestItem;
    await controller.resumePlayback(yesterdayAudioItem);
    expect(navigator.audioCalls.length, equals(1));
    expect(navigator.audioCalls.single.workId.value, equals('w_bocchi'));
    expect(
      navigator.audioCalls.single.initialPositionSeconds,
      95,
      reason: '历史音频续播必须传递已保存断点',
    );
    expect(navigator.audioCalls.single.initialCueTrackIndex, 2);
    for (final (id, episode, completed, seconds, track) in [
      ('ordinary', 'cd::v_b_ost', false, 12, null),
      ('legacy', 'cd::v_b_ost::track_3', false, 95, 3),
      ('completed', 'cd::v_b_ost#cue:2', true, 0, 2),
    ]) {
      db.userState.playbackRecords.upsert(
        PlaybackRecordEntity(
          id: id,
          workId: const WorkId.trusted('w_bocchi'),
          episodeId: EpisodeId.trusted(episode),
          variantId: const VariantId.trusted('v_b_ost'),
          playedAtMs: fixedNow.millisecondsSinceEpoch,
          positionSeconds: completed ? 215 : seconds,
          durationSeconds: 215,
          isCompleted: completed,
        ),
      );
      controller.refresh();
      final entry = controller.dayGroups
          .expand((d) => d.works)
          .expand((w) => w.items)
          .singleWhere((e) => e.record.id == id);
      await controller.resumePlayback(entry);
      final call = navigator.audioCalls.last;
      expect(call.initialPositionSeconds, seconds);
      expect(call.initialCueTrackIndex, track);
      expect(call.variantId?.value, 'v_b_ost');
    }

    await controller.openWorkDetail(const WorkId.trusted('w_frieren'));
    expect(navigator.detailCalls.single.value, equals('w_frieren'));
  });

  test('单条软删除与清空全部均落盘跨设备同步墓碑', () {
    final controller = HistoryController(
      databases: db,
      navigator: navigator,
      diagnosticLog: _StubLog(),
      sourceDeviceId: 'win_dev_1',
      clock: () => fixedNow,
    );
    addTearDown(controller.dispose);

    controller.softDeleteRecord('rec_old');
    expect(controller.totalCount, equals(3));
    final tombstonesAfterSingle = db.userState.playbackRecords
        .listAllWithTombstones()
        .where((r) => r.id == 'rec_old')
        .single;
    expect(tombstonesAfterSingle.isDeleted, isTrue);
    expect(
      tombstonesAfterSingle.deletedAtMs,
      equals(fixedNow.toUtc().millisecondsSinceEpoch),
    );
    expect(tombstonesAfterSingle.sourceDeviceId, equals('win_dev_1'));

    controller.clearAllHistory();
    expect(controller.totalCount, equals(0));
    expect(controller.dayGroups, isEmpty);
    final allTombstones = db.userState.playbackRecords.listAllWithTombstones();
    expect(allTombstones.length, equals(4));
    expect(allTombstones.every((r) => r.isDeleted), isTrue);
  });

  test('支持单条、分组与多选批量标记为已看或已听并持久化更新状态', () {
    final controller = HistoryController(
      databases: db,
      navigator: navigator,
      diagnosticLog: _StubLog(),
      sourceDeviceId: 'win_dev_1',
      clock: () => fixedNow,
    );
    addTearDown(controller.dispose);

    controller.markRecordCompleted('rec_cd');
    final bocchiRec = db.userState.playbackRecords
        .listAllWithTombstones()
        .where((r) => r.id == 'rec_cd')
        .single;
    expect(bocchiRec.isCompleted, isTrue);
    expect(bocchiRec.positionSeconds, equals(bocchiRec.durationSeconds));

    controller.enterSelectionMode(
      action: HistorySelectionAction.markCompleted,
      initialRecordId: 'rec_1',
    );
    expect(controller.isSelectionMode, isTrue);
    expect(
      controller.selectionAction,
      equals(HistorySelectionAction.markCompleted),
    );
    controller.toggleRecordSelected('rec_old');
    controller.markSelectedCompleted();

    expect(controller.isSelectionMode, isFalse);
    final updatedToday1 = db.userState.playbackRecords
        .listAllWithTombstones()
        .where((r) => r.id == 'rec_1')
        .single;
    final updatedYesterday = db.userState.playbackRecords
        .listAllWithTombstones()
        .where((r) => r.id == 'rec_old')
        .single;
    expect(updatedToday1.isCompleted, isTrue);
    expect(updatedYesterday.isCompleted, isTrue);
  });
}
