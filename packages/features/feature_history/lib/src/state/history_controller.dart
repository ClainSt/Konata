import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/history_timeline_models.dart';

/// 播放记录时间轴业务控制器（状态层严格保持零 Riverpod）。
///
/// 监听 `PlaybackRecordDao.watchRecent()` 与作品库变更，组装自然日作品时间轴，
/// 处理搜索过滤、点击续播路由跳转、作品详情跳转与单条/批量/清空软删除墓碑。
final class HistoryController extends ChangeNotifier {
  /// 创建播放记录控制器。
  HistoryController({
    required this._databases,
    required this._navigator,
    required this._diagnosticLog,
    this._sourceDeviceId = '',
    DateTime Function()? clock,
    int recentLimit = 500,
  }) : _clock = clock ?? DateTime.now {
    _recentSub = _databases.userState.playbackRecords
        .watchRecent(limit: recentLimit)
        .listen(_onRecentRecords);
    _worksSub = _databases.library.works.watchAll().listen((_) {
      _rebuildGroups();
    });
    _latestRecords = _loadInitialRecent(recentLimit);
    _rebuildGroups();
  }

  final KonataDatabaseBundle _databases;
  final AppNavigator _navigator;
  final DiagnosticLogPort _diagnosticLog;
  final String _sourceDeviceId;
  final DateTime Function() _clock;

  StreamSubscription<List<PlaybackRecordEntity>>? _recentSub;
  StreamSubscription<List<WorkRecord>>? _worksSub;
  bool _disposed = false;

  List<PlaybackRecordEntity> _latestRecords = const <PlaybackRecordEntity>[];
  Map<WorkId, WorkRecord> _worksById = const <WorkId, WorkRecord>{};
  Map<EpisodeId, EpisodeRecord> _episodesById =
      const <EpisodeId, EpisodeRecord>{};
  Map<VariantId, MediaVariantRecord> _variantsById =
      const <VariantId, MediaVariantRecord>{};
  Map<WorkId, int> _mainEpisodeCounts = const <WorkId, int>{};

  HistoryMediaFilter _filter = HistoryMediaFilter.all;
  String _searchQuery = '';
  List<HistoryDayGroup> _dayGroups = const <HistoryDayGroup>[];
  final Set<String> _expandedGroupKeys = <String>{};
  bool _isSelectionMode = false;
  final Set<String> _selectedRecordIds = <String>{};

  /// 当前激活的媒体类型筛选标签。
  HistoryMediaFilter get filter => _filter;

  /// 当前搜索关键词。
  String get searchQuery => _searchQuery;

  /// 当前按自然日及作品聚合后的时间轴分组列表。
  List<HistoryDayGroup> get dayGroups => _dayGroups;

  /// 全部未删除的原始记录条数。
  int get totalCount => _latestRecords.length;

  /// 未删除视频记录条数。
  int get videoCount => _latestRecords
      .where(
        (rec) => !HistoryTimelineGrouper.resolveIsAudio(
          rec,
          _variantsById[rec.variantId],
        ),
      )
      .length;

  /// 未删除音频记录条数。
  int get audioCount => _latestRecords
      .where(
        (rec) => HistoryTimelineGrouper.resolveIsAudio(
          rec,
          _variantsById[rec.variantId],
        ),
      )
      .length;

  /// 当前所有已展开的复合作品卡片分组键。
  Set<String> get expandedGroupKeys =>
      Set<String>.unmodifiable(_expandedGroupKeys);

  /// 是否处于批量多选删除模式。
  bool get isSelectionMode => _isSelectionMode;

  /// 当前多选状态下勾选的记录主键集合。
  Set<String> get selectedRecordIds =>
      Set<String>.unmodifiable(_selectedRecordIds);

  /// 所有未删除记录集合是否为空（未过滤前）。
  bool get hasAnyRecords => _latestRecords.isNotEmpty;

  /// 查询指定聚合卡片是否处于展开状态。
  bool isGroupExpanded(String groupKey) =>
      _expandedGroupKeys.contains(groupKey);

  /// 更新媒体筛选类型。
  void setFilter(HistoryMediaFilter next) {
    if (_filter == next) {
      return;
    }
    _filter = next;
    _rebuildGroups(refreshMetadata: false);
  }

  /// 更新搜索关键词。
  void setSearchQuery(String next) {
    if (_searchQuery == next) {
      return;
    }
    _searchQuery = next;
    _rebuildGroups(refreshMetadata: false);
  }

  /// 切换指定作品聚合分组卡片的展开或收起状态。
  void toggleGroupExpanded(String groupKey) {
    if (!_expandedGroupKeys.add(groupKey)) {
      _expandedGroupKeys.remove(groupKey);
    }
    _safeNotify();
  }

  /// 进入批量多选模式，可选同时预选中一条记录。
  void enterSelectionMode({String? initialRecordId}) {
    _isSelectionMode = true;
    _selectedRecordIds.clear();
    if (initialRecordId != null && initialRecordId.isNotEmpty) {
      _selectedRecordIds.add(initialRecordId);
    }
    _safeNotify();
  }

  /// 退出批量多选模式并清空勾选状态。
  void exitSelectionMode() {
    if (!_isSelectionMode && _selectedRecordIds.isEmpty) {
      return;
    }
    _isSelectionMode = false;
    _selectedRecordIds.clear();
    _safeNotify();
  }

  /// 切换单条记录在多选状态下的勾选标记。
  void toggleRecordSelected(String recordId) {
    if (!_selectedRecordIds.add(recordId)) {
      _selectedRecordIds.remove(recordId);
    }
    _safeNotify();
  }

  /// 勾选当前时间轴展示中的所有记录。
  void selectAllVisible() {
    if (!_isSelectionMode) {
      _isSelectionMode = true;
    }
    for (final day in _dayGroups) {
      for (final work in day.works) {
        for (final item in work.items) {
          _selectedRecordIds.add(item.record.id);
        }
      }
    }
    _safeNotify();
  }

  /// 点击续播，按记录类型跳转至对应播放器路由。
  Future<void> resumePlayback(HistoryEntryView entry) async {
    try {
      if (entry.isAudio) {
        await _navigator.openAudioPlayer(
          workId: entry.record.workId,
          variantId: entry.record.variantId,
        );
        return;
      }
      await _navigator.openVideoPlayer(
        workId: entry.record.workId,
        episodeId: entry.record.episodeId,
        variantId: entry.record.variantId,
      );
    } catch (error, stackTrace) {
      _diagnosticLog.logError(
        subsystem: DiagnosticSubsystem.ui,
        code: 'HISTORY_RESUME_NAVIGATION_FAILED',
        message: '打开续播页面失败',
        error: error,
        stackTrace: stackTrace,
        severity: DiagnosticSeverity.warn,
        source: 'HistoryController',
      );
      rethrow;
    }
  }

  /// 跳转至关联作品详情页。
  Future<void> openWorkDetail(WorkId workId) async {
    await _navigator.openWorkDetail(workId);
  }

  /// 软删除单条播放记录（写入带时间戳墓碑，支持跨设备同步）。
  void softDeleteRecord(String recordId) {
    final nowMs = _clock().toUtc().millisecondsSinceEpoch;
    _databases.userState.playbackRecords.softDelete(
      recordId,
      deletedAtMs: nowMs,
      sourceDeviceId: _sourceDeviceId,
    );
    _selectedRecordIds.remove(recordId);
    _latestRecords = _latestRecords
        .where((rec) => rec.id != recordId)
        .toList(growable: false);
    _rebuildGroups(refreshMetadata: false);
  }

  /// 软删除同一自然日内某作品分组下的全部记录。
  void softDeleteGroup(HistoryWorkGroupEntry group) {
    final nowMs = _clock().toUtc().millisecondsSinceEpoch;
    final deletedIds = <String>{};
    for (final item in group.items) {
      _databases.userState.playbackRecords.softDelete(
        item.record.id,
        deletedAtMs: nowMs,
        sourceDeviceId: _sourceDeviceId,
      );
      deletedIds.add(item.record.id);
      _selectedRecordIds.remove(item.record.id);
    }
    _expandedGroupKeys.remove(group.groupKey);
    _latestRecords = _latestRecords
        .where((rec) => !deletedIds.contains(rec.id))
        .toList(growable: false);
    _rebuildGroups(refreshMetadata: false);
  }

  /// 批量软删除当前选中的所有播放记录并退出多选模式。
  void softDeleteSelected() {
    if (_selectedRecordIds.isEmpty) {
      exitSelectionMode();
      return;
    }
    final nowMs = _clock().toUtc().millisecondsSinceEpoch;
    final targets = Set<String>.of(_selectedRecordIds);
    for (final id in targets) {
      _databases.userState.playbackRecords.softDelete(
        id,
        deletedAtMs: nowMs,
        sourceDeviceId: _sourceDeviceId,
      );
    }
    _isSelectionMode = false;
    _selectedRecordIds.clear();
    _latestRecords = _latestRecords
        .where((rec) => !targets.contains(rec.id))
        .toList(growable: false);
    _rebuildGroups(refreshMetadata: false);
  }

  /// 清空全部播放记录（写入全量软删除墓碑，绝不删减物理媒体文件）。
  void clearAllHistory() {
    final nowMs = _clock().toUtc().millisecondsSinceEpoch;
    _databases.userState.playbackRecords.clearAll(
      deletedAtMs: nowMs,
      sourceDeviceId: _sourceDeviceId,
    );
    _isSelectionMode = false;
    _selectedRecordIds.clear();
    _expandedGroupKeys.clear();
    _latestRecords = const <PlaybackRecordEntity>[];
    _rebuildGroups(refreshMetadata: false);
    _diagnosticLog.logEvent(
      subsystem: DiagnosticSubsystem.ui,
      code: 'HISTORY_CLEARED_TOMBSTONE',
      message: '已软删除清空全部播放记录',
      source: 'HistoryController',
    );
  }

  /// 主动从数据库重新拉取最新播放记录与作品元数据。
  void refresh({int limit = 500}) {
    _latestRecords = _loadInitialRecent(limit);
    _rebuildGroups();
  }

  @override
  void dispose() {
    _disposed = true;
    _recentSub?.cancel();
    _worksSub?.cancel();
    super.dispose();
  }

  List<PlaybackRecordEntity> _loadInitialRecent(int limit) {
    final active = _databases.userState.playbackRecords
        .listAllWithTombstones()
        .where((rec) => !rec.isDeleted)
        .toList()
      ..sort((a, b) => b.playedAtMs.compareTo(a.playedAtMs));
    return active.take(limit).toList(growable: false);
  }

  void _onRecentRecords(List<PlaybackRecordEntity> records) {
    _latestRecords = records;
    _rebuildGroups();
  }

  void _rebuildGroups({bool refreshMetadata = true}) {
    if (_disposed) {
      return;
    }

    if (refreshMetadata) {
      final workMap = <WorkId, WorkRecord>{};
      final epMap = <EpisodeId, EpisodeRecord>{};
      final variantMap = <VariantId, MediaVariantRecord>{};
      final mainEpCounts = <WorkId, int>{};

      final neededWorkIds = _latestRecords.map((r) => r.workId).toSet();
      for (final work in _databases.library.works.listAll()) {
        workMap[work.id] = work;
      }
      for (final workId in neededWorkIds) {
        if (!workMap.containsKey(workId)) {
          final fallback = _databases.library.works.findById(
            workId,
            includeDeleted: true,
          );
          if (fallback != null) {
            workMap[workId] = fallback;
          }
        }
        final eps = _databases.library.episodes.listByWork(workId);
        var mainCount = 0;
        for (final ep in eps) {
          epMap[ep.id] = ep;
          if (!ep.isDeleted &&
              ep.category == EpisodeCategory.main &&
              ep.seasonNumber > 0) {
            mainCount++;
          }
        }
        mainEpCounts[workId] = mainCount;
      }

      for (final variant in _databases.library.mediaVariants.listAll()) {
        variantMap[variant.id] = variant;
      }

      _worksById = workMap;
      _episodesById = epMap;
      _variantsById = variantMap;
      _mainEpisodeCounts = mainEpCounts;
    }

    _dayGroups = HistoryTimelineGrouper.buildGroups(
      records: _latestRecords,
      worksById: _worksById,
      episodesById: _episodesById,
      variantsById: _variantsById,
      mainEpisodeCounts: _mainEpisodeCounts,
      filter: _filter,
      query: _searchQuery,
      now: _clock(),
    );

    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
