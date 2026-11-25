import 'dart:async';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/chinese_pinyin_collator.dart';
import '../data/library_filter_prefs.dart';
import '../data/library_models.dart';
import '../data/library_search_matcher.dart';

/// 桌面端海报墙卡片自动保活的最大作品数量阈值（超过时禁用以控制内存与纹理句柄）。
const int desktopKeepAliveWorkLimit = 400;

/// 媒体库海报墙与待复核队列状态控制器（零 `Riverpod` 纯构造注入）。
///
/// 职责边界：
/// - 实时监听数据库作品变更流与 `DomainEventBus` 跨模块事件；
/// - 聚合每部作品的视频变体、分集数、压制组标签与跨媒体源重复角标；
/// - 通过 `ScopedPrefsStore` 强类型切片读写排序与多维筛选偏好；
/// - 协调 `ChinesePinyinCollator` 拼音自然排序与 `LibrarySearchMatcher` 本地搜索；
/// - 暴露高速滚动降载与全屏播放态停用卡片保活等性能协同状态。
class LibraryController extends ChangeNotifier {
  /// 创建媒体库主视图控制器。
  LibraryController({
    required this.databases,
    required this.scopedPrefs,
    required this.eventBus,
    this.diagnosticLog,
    int Function()? nowMs,
    bool autoStart = true,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _repository = StorageScrapeRepository(databases, nowMs: nowMs),
       _prefs = scopedPrefs.read(LibraryFilterPrefs.slice) {
    if (autoStart) {
      startWatching();
    }
  }

  /// 三库合一存储句柄。
  final KonataDatabaseBundle databases;

  /// 分作用域配置存储。
  final ScopedPrefsStore scopedPrefs;

  /// 跨模块低频领域事件总线。
  final DomainEventBus eventBus;

  /// 可选诊断日志端口。
  final DiagnosticLogPort? diagnosticLog;

  final int Function() _nowMs;
  final StorageScrapeRepository _repository;

  StreamSubscription<List<WorkRecord>>? _visibleSub;
  StreamSubscription<List<WorkRecord>>? _reviewSub;
  StreamSubscription<LibraryWorkChangedEvent>? _workEventSub;
  StreamSubscription<MediaSourceChangedEvent>? _sourceEventSub;

  LibraryPrefsState _prefs;
  String _searchQuery = '';
  bool _isLoading = true;
  bool _isFastScrolling = false;
  bool _videoPlaybackActive = false;
  bool _disposed = false;

  List<WorkLibraryItem> _allVisibleItems = const <WorkLibraryItem>[];
  List<WorkLibraryItem> _displayedItems = const <WorkLibraryItem>[];
  List<Work> _reviewWorks = const <Work>[];
  List<MediaSource> _sources = const <MediaSource>[];
  Map<String, int> _insertionOrder = const <String, int>{};
  Map<String, int> _updatedAtByWorkId = const <String, int>{};

  /// 当前排序与筛选偏好配置。
  LibraryPrefsState get prefs => _prefs;

  /// 当前生效的实时搜索词（来自桌面顶栏或移动端内联搜索框）。
  String get searchQuery => _searchQuery;

  /// 是否仍处于首次快照载入中。
  bool get isLoading => _isLoading;

  /// 是否处于鼠标滚轮或触控惯性高速滚动冷却期内。
  bool get isFastScrolling => _isFastScrolling;

  /// 宿主当前是否正在进行全屏视频播放（用于释放桌面离屏卡片保活句柄）。
  bool get videoPlaybackActive => _videoPlaybackActive;

  /// 未经筛选的已上墙确认作品集合。
  List<WorkLibraryItem> get allVisibleItems => _allVisibleItems;

  /// 经过多维筛选、排序及搜索排序后的海报墙展示列表。
  List<WorkLibraryItem> get displayedItems => _displayedItems;

  /// 当前处于待人工复核状态的作品列表。
  List<Work> get reviewWorks => _reviewWorks;

  /// 当前所有可用媒体源列表（供来源筛选下拉框消费）。
  List<MediaSource> get sources => _sources;

  /// 全部可用发行年份（倒序去重）。
  List<int> get availableYears {
    final years = <int>{
      for (final item in _allVisibleItems)
        if (item.work.year != null && item.work.year! > 0) item.work.year!,
    }.toList(growable: false);
    years.sort((a, b) => b.compareTo(a));
    return List<int>.unmodifiable(years);
  }

  /// 全部可用压制组 / 字幕组标签（按自然拼音排序）。
  List<String> get availableReleaseGroups {
    final groups = <String>{
      for (final item in _allVisibleItems) ...item.releaseGroups,
    }.toList(growable: false);
    groups.sort(ChinesePinyinCollator.compareNames);
    return List<String>.unmodifiable(groups);
  }

  /// 在桌面端非播放期且海报墙规模受控时启用有限离屏保活以优化滚动复用帧率。
  bool get shouldEnableDesktopKeepAlive =>
      !_videoPlaybackActive &&
      _displayedItems.length <= desktopKeepAliveWorkLimit;

  /// 开始监听本地数据库与领域事件总线，并立即执行首轮数据加载。
  void startWatching() {
    _visibleSub ??= databases.library.works.watchVisible().listen(
      (_) => unawaited(reload()),
    );
    _reviewSub ??= databases.library.works.watchNeedsReview().listen(
      (_) => unawaited(_reloadReview()),
    );
    _workEventSub ??= eventBus.on<LibraryWorkChangedEvent>().listen(
      (_) => unawaited(reload()),
    );
    _sourceEventSub ??= eventBus.on<MediaSourceChangedEvent>().listen(
      (_) => unawaited(reload()),
    );
    unawaited(reload());
  }

  /// 主动从存储层全量重算可见作品墙与待复核列表。
  Future<void> reload() async {
    if (_disposed) return;
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _repository.getAllWorks(),
        _repository.getAllVariants(),
        _repository.getAllEpisodes(),
        _repository.getMediaSources(),
      ]);
      if (_disposed) return;

      final allWorks = results[0] as List<Work>;
      final allVariants = results[1] as List<MediaVariant>;
      final allEpisodes = results[2] as List<Episode>;
      final sources = results[3] as List<MediaSource>;
      final visibleRecords = databases.library.works.listVisible();
      final insertionIds = databases.library.works
          .listVisibleIdsInInsertionOrder();
      _insertionOrder = {
        for (var i = 0; i < insertionIds.length; i++) insertionIds[i].value: i,
      };
      if (!ReleaseGroups.isLoaded &&
          allVariants.any((variant) => variant.assetKind == AssetKind.video)) {
        await ReleaseGroups.prepare();
        if (_disposed) return;
      }

      final sourcesById = <String, MediaSource>{
        for (final s in sources) s.id: s,
      };
      final variantsByWork = <String, List<MediaVariant>>{};
      for (final variant in allVariants) {
        variantsByWork
            .putIfAbsent(variant.workId, () => <MediaVariant>[])
            .add(variant);
      }
      final episodesByWork = <String, List<Episode>>{};
      for (final ep in allEpisodes) {
        episodesByWork.putIfAbsent(ep.workId, () => <Episode>[]).add(ep);
      }

      final rawWall = <WorkLibraryItem>[];
      for (final work in allWorks) {
        final eligible =
            work.scrapeStatus == ScrapeStatus.matched || work.isManualLocked;
        if (!eligible) continue;

        final workVariants = variantsByWork[work.id] ?? const <MediaVariant>[];
        final workEpisodes = episodesByWork[work.id] ?? const <Episode>[];
        rawWall.add(
          _buildLibraryItem(
            work: work,
            variants: workVariants,
            episodes: workEpisodes,
            sourcesById: sourcesById,
          ),
        );
      }

      if (!ChinesePinyinCollator.isLoaded &&
          (_hasPinyinTitles(allWorks) ||
              rawWall.any(
                (item) =>
                    item.releaseGroups.any(ChinesePinyinCollator.needsTable),
              ))) {
        await ChinesePinyinCollator.prepare();
        if (_disposed) return;
      }
      _updatedAtByWorkId = <String, int>{
        for (final rec in visibleRecords) rec.id.value: rec.updatedAtMs,
      };
      _sources = List<MediaSource>.unmodifiable(sources);
      _reviewWorks = _sortWorksByTitle(
        allWorks.where(
          (w) =>
              !w.isManualLocked && w.scrapeStatus == ScrapeStatus.needsReview,
        ),
      );
      _allVisibleItems = annotateCrossSourceBadges(rawWall);
      _isLoading = false;
      _recomputeDisplayedItems();
      if (!_disposed) {
        notifyListeners();
      }
    } catch (error) {
      _isLoading = false;
      diagnosticLog?.logError(
        subsystem: DiagnosticSubsystem.ui,
        code: 'library_reload_failed',
        message:
            '加载媒体库海报墙数据失败: ${DiagnosticTextSanitizer.redactSecrets('$error')}',
        error: error,
        source: 'LibraryController.reload',
      );
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> _reloadReview() async {
    if (_disposed) return;
    try {
      final allWorks = await _repository.getAllWorks();
      if (_disposed) return;
      if (!ChinesePinyinCollator.isLoaded && _hasPinyinTitles(allWorks)) {
        await ChinesePinyinCollator.prepare();
        if (_disposed) return;
      }
      _reviewWorks = _sortWorksByTitle(
        allWorks.where(
          (w) =>
              !w.isManualLocked && w.scrapeStatus == ScrapeStatus.needsReview,
        ),
      );
      notifyListeners();
    } catch (_) {
      // 局部刷新失败时由完整 reload 兜底。
    }
  }

  /// 更新当前实时搜索词并重新过滤排序海报墙结果。
  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    _recomputeDisplayedItems();
    notifyListeners();
  }

  /// 切换排序字段并写入 `ScopedPrefsStore`。
  void setSortMode(LibrarySortMode mode) {
    if (_prefs.sortMode == mode) return;
    _updatePrefs(_prefs.copyWith(sortMode: mode));
  }

  /// 切换排序升降序并持久化。
  void setSortOrder(LibrarySortOrder order) {
    if (_prefs.sortOrder == order) return;
    _updatePrefs(_prefs.copyWith(sortOrder: order));
  }

  /// 翻转当前排序升降方向。
  void toggleSortOrder() {
    final nextOrder = _prefs.sortOrder == LibrarySortOrder.ascending
        ? LibrarySortOrder.descending
        : LibrarySortOrder.ascending;
    _updatePrefs(_prefs.copyWith(sortOrder: nextOrder));
  }

  /// 设置或清除按发行年份筛选条件。
  void setYearFilter(int? year) {
    final next = year == null
        ? _prefs.copyWith(clearYearFilter: true)
        : _prefs.copyWith(yearFilter: year);
    _updatePrefs(next);
  }

  /// 设置或清除按压制组筛选条件。
  void setReleaseGroupFilter(String? group) {
    final clean = group?.trim();
    final next = (clean == null || clean.isEmpty)
        ? _prefs.copyWith(clearReleaseGroupFilter: true)
        : _prefs.copyWith(releaseGroupFilter: clean);
    _updatePrefs(next);
  }

  /// 设置或清除按媒体源 ID 筛选条件。
  void setSourceIdFilter(String? sourceId) {
    final clean = sourceId?.trim();
    final next = (clean == null || clean.isEmpty)
        ? _prefs.copyWith(clearSourceIdFilter: true)
        : _prefs.copyWith(sourceIdFilter: clean);
    _updatePrefs(next);
  }

  /// 切换是否仅看多版本或跨来源存在重复卡片的作品。
  void setOnlyMultiSource(bool value) {
    if (_prefs.onlyMultiSource == value) return;
    _updatePrefs(_prefs.copyWith(onlyMultiSource: value));
  }

  /// 清除全部筛选项与搜索关键词，恢复全量海报墙视图。
  void resetFilters({bool clearSearch = false}) {
    final clearedPrefs = _prefs.clearFiltersOnly().copyWith(
      sortMode: LibrarySortMode.libraryOrder,
      sortOrder: LibrarySortOrder.ascending,
    );
    final prefsChanged =
        _prefs.hasActiveFilters ||
        _prefs.sortMode != LibrarySortMode.libraryOrder ||
        _prefs.sortOrder != LibrarySortOrder.ascending;
    final searchChanged = clearSearch && _searchQuery.isNotEmpty;
    if (!prefsChanged && !searchChanged) return;
    if (clearSearch) {
      _searchQuery = '';
    }
    _updatePrefs(clearedPrefs);
  }

  /// 通知当前是否正处于高速滚动冷却期（用于抑制离屏悬停动画与工具提示挂载）。
  void setFastScrolling(bool active) {
    if (_isFastScrolling == active) return;
    _isFastScrolling = active;
    notifyListeners();
  }

  /// 通知宿主视频全屏播放状态变化（开播时关闭桌面卡片离屏保活）。
  void setVideoPlaybackActive(bool active) {
    if (_videoPlaybackActive == active) return;
    _videoPlaybackActive = active;
    notifyListeners();
  }

  void _updatePrefs(LibraryPrefsState next) {
    _prefs = next;
    scopedPrefs.write(LibraryFilterPrefs.slice, next);
    eventBus.publish(
      PrefsSliceChangedEvent(
        namespace: LibraryFilterPrefs.slice.namespace,
        occurredAtMs: _nowMs(),
      ),
    );
    _recomputeDisplayedItems();
    notifyListeners();
  }

  void _recomputeDisplayedItems() {
    var filtered = <WorkLibraryItem>[
      for (final item in _allVisibleItems)
        if (_matchesPrefsFilters(item)) item,
    ];

    filtered.sort(_compareItems);

    if (_searchQuery.trim().isNotEmpty) {
      filtered = LibrarySearchMatcher.filterAndRank<WorkLibraryItem>(
        items: filtered,
        workOf: (item) => item.work,
        releaseGroupsOf: (item) => item.releaseGroups,
        rawQuery: _searchQuery,
      );
    }

    _displayedItems = List<WorkLibraryItem>.unmodifiable(filtered);
  }

  bool _matchesPrefsFilters(WorkLibraryItem item) {
    if (_prefs.yearFilter != null && item.work.year != _prefs.yearFilter) {
      return false;
    }
    final targetGroup = _prefs.releaseGroupFilter;
    if (targetGroup != null &&
        targetGroup.isNotEmpty &&
        !item.releaseGroups.contains(targetGroup)) {
      return false;
    }
    final targetSource = _prefs.sourceIdFilter;
    if (targetSource != null &&
        targetSource.isNotEmpty &&
        !item.sourceIds.contains(targetSource)) {
      return false;
    }
    if (_prefs.onlyMultiSource &&
        item.crossSourceBadgeLabel == null &&
        item.maxEpisodeVariantCount <= 1) {
      return false;
    }
    return true;
  }

  int _compareItems(WorkLibraryItem a, WorkLibraryItem b) {
    final asc = _prefs.sortOrder == LibrarySortOrder.ascending;
    int primary = 0;

    switch (_prefs.sortMode) {
      case LibrarySortMode.libraryOrder:
        final ai = _insertionOrder[a.work.id] ?? 0;
        final bi = _insertionOrder[b.work.id] ?? 0;
        return asc ? ai.compareTo(bi) : bi.compareTo(ai);
      case LibrarySortMode.title:
        primary = ChinesePinyinCollator.compareNames(
          a.work.title,
          b.work.title,
        );
        return asc ? primary : -primary;
      case LibrarySortMode.year:
        final ya = a.work.year;
        final yb = b.work.year;
        if (ya == null && yb == null) {
          primary = 0;
        } else if (ya == null) {
          return 1;
        } else if (yb == null) {
          return -1;
        } else {
          primary = asc ? ya.compareTo(yb) : yb.compareTo(ya);
        }
      case LibrarySortMode.score:
        final sa = a.work.bangumiScore ?? a.work.voteAverage;
        final sb = b.work.bangumiScore ?? b.work.voteAverage;
        if (sa == null && sb == null) {
          primary = 0;
        } else if (sa == null) {
          return 1;
        } else if (sb == null) {
          return -1;
        } else {
          primary = asc ? sa.compareTo(sb) : sb.compareTo(sa);
        }
      case LibrarySortMode.recent:
        final ta = _updatedAtByWorkId[a.work.id] ?? 0;
        final tb = _updatedAtByWorkId[b.work.id] ?? 0;
        primary = asc ? ta.compareTo(tb) : tb.compareTo(ta);
    }

    if (primary != 0) return primary;
    return ChinesePinyinCollator.compareNames(a.work.title, b.work.title);
  }

  WorkLibraryItem _buildLibraryItem({
    required Work work,
    required List<MediaVariant> variants,
    required List<Episode> episodes,
    required Map<String, MediaSource> sourcesById,
  }) {
    final groups = <String>[];
    final seenGroups = <String>{};
    final sourceIds = <String>[];
    final seenSources = <String>{};
    final epVariantCounts = <String, int>{};

    for (final v in variants) {
      if (seenSources.add(v.sourceId)) {
        sourceIds.add(v.sourceId);
      }
      if (v.assetKind != AssetKind.video) continue;

      final epId = v.episodeId;
      if (epId != null && epId.isNotEmpty) {
        epVariantCounts[epId] = (epVariantCounts[epId] ?? 0) + 1;
      }
      final parsed = BdripParser.parseFileName(
        v.fileName,
        relativePath: v.relativePath,
        folderTitle: work.title,
      );
      final group = parsed.releaseGroup?.trim() ?? '';
      if (group.isNotEmpty && seenGroups.add(group.toLowerCase())) {
        groups.add(group);
      }
    }

    final mainEpisodes = episodes
        .where((e) => e.category == EpisodeCategory.main)
        .length;
    final videoCount = variants
        .where((v) => v.assetKind == AssetKind.video)
        .length;
    final episodeCount = mainEpisodes > 0 ? mainEpisodes : videoCount;
    var maxEpVariants = 1;
    for (final count in epVariantCounts.values) {
      if (count > maxEpVariants) maxEpVariants = count;
    }

    final primarySource = sourceIds.isNotEmpty
        ? sourcesById[sourceIds.first]
        : null;

    return WorkLibraryItem(
      work: work,
      variants: List<MediaVariant>.unmodifiable(variants),
      episodeCount: episodeCount,
      releaseGroups: List<String>.unmodifiable(groups),
      maxEpisodeVariantCount: maxEpVariants,
      sourceIds: List<String>.unmodifiable(sourceIds),
      primarySourceKind: primarySource?.kind,
      primarySourceLabel: primarySource?.label,
    );
  }

  List<Work> _sortWorksByTitle(Iterable<Work> works) {
    final list = works.toList(growable: false)
      ..sort((a, b) => ChinesePinyinCollator.compareNames(a.title, b.title));
    return List<Work>.unmodifiable(list);
  }

  static bool _hasPinyinTitles(List<Work> works) =>
      works.length > 1 &&
      works.any((work) => ChinesePinyinCollator.needsTable(work.title));

  @override
  void dispose() {
    _disposed = true;
    unawaited(_visibleSub?.cancel());
    unawaited(_reviewSub?.cancel());
    unawaited(_workEventSub?.cancel());
    unawaited(_sourceEventSub?.cancel());
    super.dispose();
  }
}
