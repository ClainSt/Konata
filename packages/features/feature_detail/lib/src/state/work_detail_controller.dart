import 'dart:async';
import 'dart:developer' as developer;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/artwork_crop_math.dart';
import '../data/detail_display_preferences.dart';
import '../data/detail_edit_models.dart';
import '../data/detail_work_actions.dart';
import '../data/local_artwork_cropper.dart';
import '../data/main_episode_frame_backfill_service.dart';
import '../data/main_episode_frame_extractor.dart';
import '../data/work_artwork_options.dart';
import 'detail_bundle_loader.dart';
import 'detail_supplementary_view_data.dart';
import 'work_rescrape_state.dart';

/// 作品详情页核心状态控制器（零 Riverpod，纯构造函数注入并基于 `ChangeNotifier` 驱动视图刷新）。
final class WorkDetailController extends ChangeNotifier {
  /// 创建指定作品的详情状态控制器。
  WorkDetailController({
    required this.workId,
    required this._databases,
    required this._repository,
    required this._photosStorage,
    required this._domainEventBus,
    required this._navigator,
    required this._filePicker,
    required this._urlOpener,
    required this._warmupService,
    required this._platform,
    required this._detailTabs,
    required this._detailActions,
    required this._displayPreferencesStore,
    required this._frameBackfillService,
    required this._artworkOptionsService,
    required this._actionsService,
    required this._scrapePipeline,
    required this._tmdbService,
    required this._bangumiService,
    this.autoStartWarmupAndBackfill = true,
  }) {
    _displayPreferences = _displayPreferencesStore.read();
    _librarySub = _databases.library.engine.changeBus.stream.listen((tables) {
      if (tables.any(_watchedLibraryTables.contains)) {
        _scheduleReload();
      }
    });
    _userStateSub = _databases.userState.engine.changeBus.stream.listen((
      tables,
    ) {
      if (tables.contains('playback_records')) {
        _scheduleReload();
      }
    });
    _domainEventSub = _domainEventBus.on<LibraryWorkChangedEvent>().listen((
      event,
    ) {
      if (event.workId == workId ||
          event.reason == 'merged' ||
          event.reason == 'deleted') {
        _scheduleReload();
      }
    });
    _prefsSub = _displayPreferencesStore.watch().listen((prefs) {
      if (_disposed || prefs == _displayPreferences) return;
      _displayPreferences = prefs;
      notifyListeners();
    });
  }

  static const Set<String> _watchedLibraryTables = <String>{
    'works',
    'episodes',
    'media_variants',
    'series_groups',
    'media_sources',
  };

  /// 当前详情页绑定的作品唯一主键。
  final WorkId workId;

  final KonataDatabaseBundle _databases;
  final LibraryRepository _repository;
  final PhotosStorage _photosStorage;
  final DomainEventBus _domainEventBus;
  final AppNavigator _navigator;
  final FilePickerPort _filePicker;
  final UrlOpenerPort _urlOpener;
  final WorkDetailWarmupService _warmupService;
  final KonataPlatform _platform;
  final List<DetailTabContribution> _detailTabs;
  final List<DetailActionContribution> _detailActions;
  final DetailDisplayPreferencesStore _displayPreferencesStore;
  final MainEpisodeFrameBackfillService _frameBackfillService;
  final WorkArtworkOptionsService _artworkOptionsService;
  final DetailWorkActionsService _actionsService;
  final ScrapePipeline _scrapePipeline;
  final TmdbService _tmdbService;
  final BangumiService _bangumiService;

  /// 是否在首次加载就绪后自动执行静默预热与缺失剧照抽帧补图（单测可显式控制）。
  final bool autoStartWarmupAndBackfill;

  StreamSubscription<Set<String>>? _librarySub;
  StreamSubscription<Set<String>>? _userStateSub;
  StreamSubscription<LibraryWorkChangedEvent>? _domainEventSub;
  StreamSubscription<DetailDisplayPreferences>? _prefsSub;
  Timer? _reloadDebounceTimer;
  Timer? _rescrapeDismissTimer;

  WorkDetailBundle? _bundle;
  late DetailDisplayPreferences _displayPreferences;
  WorkRescrapeState _rescrapeState = const WorkRescrapeIdle();
  bool _isLoading = true;
  Object? _loadError;
  bool _disposed = false;
  bool _reloadPending = false;
  bool _isLoadingNow = false;
  bool _warmupStarted = false;
  bool _scoreCheckStarted = false;
  bool _stillBackfillStarted = false;
  bool _isExtractingFrames = false;

  /// 当前详情页聚合数据包。
  WorkDetailBundle? get bundle => _bundle;

  /// 当前展示偏好切片快照。
  DetailDisplayPreferences get displayPreferences => _displayPreferences;

  /// 当前单作重刮状态机快照。
  WorkRescrapeState get rescrapeState => _rescrapeState;

  /// 是否处于首屏数据装载中。
  bool get isLoading => _isLoading;

  /// 最近一次数据加载失败异常（正常时为空）。
  Object? get loadError => _loadError;

  /// 当前运行宿主平台。
  KonataPlatform get platform => _platform;

  /// 外部链接打开端口。
  UrlOpenerPort get urlOpener => _urlOpener;

  /// 加载或强制刷新作品详情聚合数据，并同步解析动态挂载标签与动作。
  Future<WorkDetailBundle?> load() async {
    if (_disposed) return null;
    if (_isLoadingNow) {
      _reloadPending = true;
      return _bundle;
    }
    _isLoadingNow = true;
    try {
      final nextBundle = await DetailBundleLoader.loadBundle(
        workId: workId,
        repository: _repository,
        platform: _platform,
        detailTabs: _detailTabs,
        detailActions: _detailActions,
        isCancelled: () => _disposed,
      );
      if (_disposed) return null;
      _bundle = nextBundle;
      _isLoading = false;
      _loadError = null;
      notifyListeners();

      if (nextBundle != null && autoStartWarmupAndBackfill) {
        unawaited(_triggerEnterBackgroundTasks(nextBundle));
      }
      return nextBundle;
    } catch (error, stackTrace) {
      developer.log(
        '加载作品详情聚合包失败',
        name: 'konata.work_detail_controller',
        error: error,
        stackTrace: stackTrace,
      );
      if (!_disposed) {
        _isLoading = false;
        _loadError = error;
        notifyListeners();
      }
      return null;
    } finally {
      _isLoadingNow = false;
      if (_reloadPending && !_disposed) {
        _reloadPending = false;
        unawaited(load());
      }
    }
  }

  Future<void> _triggerEnterBackgroundTasks(WorkDetailBundle bundle) async {
    if (_disposed) return;
    if (!_warmupStarted && _displayPreferences.autoSilentWarmup) {
      _warmupStarted = true;
      final targets = [
        for (final v in bundle.variants)
          WarmupVariantTarget(
            sourceId: v.sourceId,
            relativePath: v.relativePath,
            assetKind: v.assetKind,
          ),
      ];
      final sourceViews = <String, MediaSourceView>{
        for (final entry in bundle.sourcesById.entries)
          entry.key: projectMediaSourceView(entry.value),
      };
      unawaited(
        _warmupService.warmupForTargets(
          targets: targets,
          sourcesById: sourceViews,
        ),
      );
    }

    if (!_scoreCheckStarted) {
      _scoreCheckStarted = true;
      if (bundle.work.bangumiScore == null) {
        unawaited(_actionsService.ensureWorkBangumiScore(bundle.work.id));
      }
    }

    if (!_stillBackfillStarted) {
      _stillBackfillStarted = true;
      unawaited(triggerMainStillBackfillIfNeeded(bundle));
    }
  }

  /// 在需要时触发正片单集自动剧照补图（仅对 `EpisodeCategory.main` 正片执行，绝不抽特典）。
  Future<bool> triggerMainStillBackfillIfNeeded([
    WorkDetailBundle? targetBundle,
  ]) async {
    final current = targetBundle ?? _bundle;
    if (_disposed || current == null) return false;
    if (!_displayPreferences.showEpisodeStillThumbnails) return false;
    if (!MainEpisodeFrameBackfillService.shouldBackfillMainEpisodeFrames(
      work: current.work,
      episodes: current.episodes,
    )) {
      return false;
    }
    return _frameBackfillService.backfillMissingMainVisuals(
      work: current.work,
      episodes: current.episodes,
      variants: current.variants,
      sourcesById: current.sourcesById,
      isCancelled: () => _disposed || _isExtractingFrames,
    );
  }

  /// 对当前作品执行单作交互式重新抓取元数据，驱动实时进度胶囊状态机。
  Future<WorkRescrapeState> rescrapeMetadata() async {
    if (_rescrapeState is WorkRescrapeRunning) {
      return _rescrapeState;
    }
    _rescrapeDismissTimer?.cancel();
    _setRescrapeState(
      WorkRescrapeRunning(
        workId: workId,
        stageLabel: '正在连接元数据服务...',
        stepIndex: 1,
        totalSteps: 6,
      ),
    );
    try {
      final before = await _repository.findWorkById(workId.value);
      final updated = await _scrapePipeline.autoBindOrBackfillWorkTmdb(
        workId.value,
        interactive: true,
        onProgress: (p) {
          if (_disposed) return;
          _setRescrapeState(
            WorkRescrapeRunning(
              workId: workId,
              stageLabel: p.stageLabel,
              stepIndex: p.stepIndex,
              totalSteps: p.totalSteps,
              detailText: p.detailText,
            ),
          );
        },
      );

      if (_disposed) return _rescrapeState;

      var surviving = updated ?? await _repository.findWorkById(workId.value);
      var autoMerged = false;
      WorkId? redirectedId;

      if (surviving != null) {
        final variants = await _repository.getVariantsByWork(workId.value);
        final sourceIds = variants.map((v) => v.sourceId).toSet();
        for (final sourceId in sourceIds) {
          final merged =
              await ReleaseGroupWorkMerger.mergeSameSourceIdentityWorks(
                repository: _repository,
                sourceId: sourceId,
                focusWorkIds: <String>{workId.value},
                photosStorage: PhotosStorageArtworkPortAdapter(_photosStorage),
              );
          if (merged.absorbedIds.contains(workId.value)) {
            autoMerged = true;
            if (merged.survivingTargetIds.isNotEmpty) {
              redirectedId = WorkId.trusted(merged.survivingTargetIds.first);
            }
            break;
          }
        }
        if (redirectedId != null) {
          surviving = await _repository.findWorkById(redirectedId.value);
        }
      }

      final targetEventId = redirectedId?.value ?? workId.value;
      _domainEventBus.publish(
        LibraryWorkChangedEvent(
          workId: WorkId.trusted(targetEventId),
          reason: autoMerged ? 'merged' : 'scraped',
          occurredAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await load();

      final result = WorkRescrapeSucceeded(
        workId: workId,
        message: autoMerged
            ? '已更新元数据并自动合并同源版本'
            : (surviving != null && before?.title != surviving.title
                  ? '已刷新为「${surviving.title}」最新元数据'
                  : '已完成元数据与艺术图刷新'),
        updatedWork: surviving,
        autoMerged: autoMerged,
        redirectedWorkId: redirectedId,
      );
      _setRescrapeState(result);
      _scheduleRescrapeAutoDismiss();
      return result;
    } catch (error) {
      developer.log(
        '单作重新抓取失败',
        name: 'konata.work_detail_controller',
        error: error,
      );
      final failed = WorkRescrapeFailed(
        workId: workId,
        errorMessage: '重新抓取元数据失败：$error',
      );
      _setRescrapeState(failed);
      _scheduleRescrapeAutoDismiss();
      return failed;
    }
  }

  /// 重置重刮进度胶囊回空闲态。
  void dismissRescrapeStatus() {
    _rescrapeDismissTimer?.cancel();
    if (_rescrapeState is! WorkRescrapeIdle) {
      _setRescrapeState(const WorkRescrapeIdle());
    }
  }

  void _scheduleRescrapeAutoDismiss() {
    _rescrapeDismissTimer?.cancel();
    _rescrapeDismissTimer = Timer(const Duration(seconds: 4), () {
      if (!_disposed &&
          (_rescrapeState is WorkRescrapeSucceeded ||
              _rescrapeState is WorkRescrapeFailed)) {
        _setRescrapeState(const WorkRescrapeIdle());
      }
    });
  }

  void _setRescrapeState(WorkRescrapeState next) {
    if (_disposed) return;
    _rescrapeState = next;
    notifyListeners();
  }

  /// 对当前作品目录执行轻量自动同步。
  Future<SingleWorkSyncResult> syncWorkDirectory() async {
    final result = await _scrapePipeline.syncSingleWorkDirectory(workId.value);
    if (result.changed) {
      _domainEventBus.publish(
        LibraryWorkChangedEvent(
          workId: workId,
          reason: result.workRemoved ? 'deleted' : 'edited',
          occurredAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await load();
    }
    return result;
  }

  /// 重新自动匹配待复核或未匹配作品。
  Future<RematchWorkResult> rematchReviewWork() async {
    final res = await _scrapePipeline.rematchReviewWork(workId.value);
    _domainEventBus.publish(
      LibraryWorkChangedEvent(
        workId: WorkId.trusted(res.work?.id ?? workId.value),
        reason: res.outcome == RematchWorkOutcome.autoMerged
            ? 'merged'
            : 'scraped',
        occurredAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await load();
    return res;
  }

  /// 路由至全屏视频播放舞台。
  Future<void> playEpisode({
    required EpisodeId episodeId,
    VariantId? variantId,
  }) => _navigator.openVideoPlayer(
    workId: workId,
    episodeId: episodeId,
    variantId: variantId,
  );

  /// 路由至全屏音频播放舞台。
  Future<void> playCdAlbum({VariantId? variantId}) =>
      _navigator.openAudioPlayer(workId: workId, variantId: variantId);

  /// 在详情页内就地切换同系列作品成员。
  Future<void> switchSeriesMember(WorkId targetWorkId) =>
      _navigator.openWorkDetail(targetWorkId);

  /// 返回上一页面。
  Future<bool> navigateBack() => _navigator.pop();

  /// 打开系统本地图片选择器并可选进入比例裁切保存。
  Future<String?> pickLocalImageFile({String? dialogTitle}) =>
      _filePicker.pickImageFile(dialogTitle: dialogTitle);

  /// 拉取多源候选封面、背景与透明徽标列表。
  Future<WorkArtworkOptions> fetchArtworkOptions({bool includeLogos = false}) {
    final work = _bundle?.work;
    if (work == null) {
      return Future<WorkArtworkOptions>.value(const WorkArtworkOptions());
    }
    return _artworkOptionsService.fetchForWork(
      work,
      includeLogos: includeLogos,
    );
  }

  /// 查询 `Fanart.tv` 当前中继熔断健康快照。
  FanartRelayHealthSnapshot get fanartRelayHealth =>
      _artworkOptionsService.fanartRelayHealth;

  /// 为「编辑背景图」弹窗从作品首个正片抽取候选画面。
  Future<List<VideoFrameSample>> extractBackdropFrameCandidates({
    int sampleCount = 8,
    double phaseOffset = 0.0,
    bool Function()? isCancelled,
  }) async {
    _isExtractingFrames = true;
    try {
      return await _frameBackfillService.extractBackdropCandidatesForWork(
        workId.value,
        sampleCount: sampleCount,
        phaseOffset: phaseOffset,
        isCancelled: () => _disposed || (isCancelled?.call() ?? false),
      );
    } finally {
      _isExtractingFrames = false;
    }
  }

  /// 将用户在弹窗中选中的正片抽帧保存为作品锁定背景原画。
  Future<String> applyExtractedBackdropFrame(Uint8List pngBytes) async {
    final work = _bundle?.work;
    if (work == null) throw StateError('作品信息尚未加载');
    final savedPath = await _frameBackfillService.applyExtractedBackdropFrame(
      work: work,
      pngBytes: pngBytes,
    );
    _domainEventBus.publish(
      LibraryWorkChangedEvent(
        workId: workId,
        reason: 'edited',
        occurredAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await load();
    return savedPath;
  }

  /// 读取本地图片文件供比例裁切框加载。
  Future<LoadedLocalArtwork> loadLocalArtworkForCrop(String filePath) =>
      _actionsService.loadLocalArtworkForCrop(filePath);

  /// 裁切本地自定义图片并持久化锁定为封面、背景图或竖版原画。
  Future<String> cropAndSaveLocalArtwork({
    required bool isPoster,
    bool isPortraitBackdrop = false,
    required LoadedLocalArtwork source,
    required ArtworkNormalizedCropRect cropRect,
  }) async {
    final work = _bundle?.work;
    if (work == null) throw StateError('作品信息尚未加载');
    final saved = await _actionsService.cropAndSaveLocalArtwork(
      work: work,
      isPoster: isPoster,
      isPortraitBackdrop: isPortraitBackdrop,
      source: source,
      cropRect: cropRect,
    );
    await load();
    return saved;
  }

  /// 导入本地透明标题徽标并持久化锁定。
  Future<String> saveLocalLogoArtwork(String sourceFilePath) async {
    final work = _bundle?.work;
    if (work == null) throw StateError('作品信息尚未加载');
    final saved = await _actionsService.saveLocalLogoArtwork(
      work: work,
      sourceFilePath: sourceFilePath,
    );
    await load();
    return saved;
  }

  /// 持久化更新作品海报、背景、竖版原画或透明徽标路径。
  Future<void> updateWorkArtwork({
    String? posterPath,
    String? backdropPath,
    String? portraitBackdropPath,
    String? logoPath,
  }) async {
    await _actionsService.updateWorkArtwork(
      workId: workId.value,
      posterPath: posterPath,
      backdropPath: backdropPath,
      portraitBackdropPath: portraitBackdropPath,
      logoPath: logoPath,
    );
    await load();
  }

  /// 解除图像人工锁定并恢复自动抓取默认。
  Future<Work?> resetArtworkLockToAuto({
    bool resetPoster = false,
    bool resetBackdrop = false,
    bool resetPortraitBackdrop = false,
    bool resetLogo = false,
  }) async {
    final result = await _actionsService.resetArtworkLockToAuto(
      workId: workId.value,
      resetPoster: resetPoster,
      resetBackdrop: resetBackdrop,
      resetPortraitBackdrop: resetPortraitBackdrop,
      resetLogo: resetLogo,
    );
    await load();
    return result;
  }

  /// 更新基础元数据并锁定。
  Future<void> updateWorkManualMetadata({
    required String title,
    String? originalTitle,
    int? year,
    String? overview,
    bool lockMetadata = true,
  }) async {
    await _actionsService.updateWorkManualMetadata(
      workId: workId.value,
      title: title,
      originalTitle: originalTitle,
      year: year,
      overview: overview,
      lockMetadata: lockMetadata,
    );
    await load();
  }

  /// 解除基础元数据锁定并恢复自动抓取。
  Future<Work?> resetMetadataLockToAuto() async {
    final result = await _actionsService.resetMetadataLockToAuto(workId.value);
    await load();
    return result;
  }

  /// 保存单文件手动剧集/特典重映射并持久化锁定。
  Future<void> saveEpisodeMappings(
    List<EpisodeFileMappingEdit> mappings,
  ) async {
    await _actionsService.saveEpisodeMappings(
      workId: workId.value,
      mappings: mappings,
    );
    await load();
  }

  /// 解除全部文件映射锁定并按自动规则重映射。
  Future<Work?> resetFileMappingsToAuto() async {
    final result = await _actionsService.resetFileMappingsToAuto(workId.value);
    await load();
    return result;
  }

  /// 保存附属资源作用域。
  Future<void> updateSupplementaryScopes(
    List<SupplementaryScopeEdit> edits,
  ) async {
    await _actionsService.updateSupplementaryScopes(edits);
    await load();
  }

  /// 保存系列编组配置。
  Future<void> saveSeriesGroupConfig({
    String? seriesId,
    required String title,
    required List<SeriesMemberEdit> members,
    int? tmdbCollectionId,
  }) async {
    await _actionsService.saveSeriesGroupConfig(
      seriesId: seriesId,
      title: title,
      members: members,
      tmdbCollectionId: tmdbCollectionId,
    );
    await load();
  }

  /// 从媒体库移除当前作品记录（不删除源文件）。
  Future<void> deleteWorkFromLibrary({bool addToIgnoreList = false}) async {
    await _actionsService.deleteWorkFromLibrary(
      workId.value,
      addToIgnoreList: addToIgnoreList,
    );
  }

  /// 一键将全部正片标为已看完。
  Future<void> markAllMainEpisodesWatched() async {
    await _actionsService.markAllMainEpisodesWatched(workId.value);
    await load();
  }

  /// 清空作品下所有观看记录。
  Future<void> clearWorkPlaybackHistory() async {
    await _actionsService.clearWorkPlaybackHistory(workId.value);
    await load();
  }

  /// 忽略人工复核并按当前名称加锁入库。
  Future<void> dismissWorkReview() async {
    await _actionsService.dismissWorkReview(workId.value);
    await load();
  }

  /// 合并整部作品到库内已有作品。
  Future<WorkMergeOutcome> mergeWorkIntoExisting({
    required String targetWorkId,
    EpisodeCategory? forceCategory,
  }) => _actionsService.mergeWorkIntoExisting(
    sourceWorkId: workId.value,
    targetWorkId: targetWorkId,
    forceCategory: forceCategory,
  );

  /// 迁移选中物理文件至已有作品。
  Future<WorkMergeOutcome> moveVariantsToExistingWork({
    required List<String> variantIds,
    required String targetWorkId,
    required EpisodeCategory targetCategory,
  }) async {
    final res = await _actionsService.moveVariantsToExistingWork(
      sourceWorkId: workId.value,
      variantIds: variantIds,
      targetWorkId: targetWorkId,
      targetCategory: targetCategory,
    );
    if (!res.sourceWorkDeleted) {
      await load();
    }
    return res;
  }

  /// 将选中物理文件拆分为独立作品。
  Future<Work> splitVariantsToIndependentWork({
    required List<String> variantIds,
    HybridMatchRequest? hybridRequest,
    ({int tmdbId, TmdbMediaType mediaType})? tmdbTarget,
    BangumiSubjectCandidate? bangumiOnlySubject,
  }) async {
    final created = await _actionsService.splitVariantsToIndependentWork(
      sourceWorkId: workId.value,
      variantIds: variantIds,
      hybridRequest: hybridRequest,
      tmdbTarget: tmdbTarget,
      bangumiOnlySubject: bangumiOnlySubject,
    );
    await load();
    return created;
  }

  /// 手动重绑当前作品到指定 `TMDB` 条目。
  Future<Work> rebindWorkToTmdb({
    required int tmdbId,
    required TmdbMediaType mediaType,
  }) async {
    final updated = await _actionsService.rebindWorkToTmdb(
      workId: workId.value,
      tmdbId: tmdbId,
      mediaType: mediaType,
    );
    await load();
    return updated;
  }

  /// 绑定为纯 `Bangumi` 条目。
  Future<Work> bindWorkBangumiOnly(BangumiSubjectCandidate subject) async {
    final updated = await _actionsService.bindWorkBangumiOnly(
      workId: workId.value,
      bangumiSubject: subject,
    );
    await load();
    return updated;
  }

  /// 双源混合绑定。
  Future<Work> bindWorkHybrid(HybridMatchRequest request) async {
    final updated = await _actionsService.bindWorkHybrid(
      workId: workId.value,
      request: request,
    );
    await load();
    return updated;
  }

  /// 查询库内全部未删除作品（供合并目标选择与系列管理筛选）。
  Future<List<Work>> listAllVisibleWorks() async {
    final all = await _repository.getAllWorks();
    return all;
  }

  /// 查询库内所有系列编组。
  Future<List<SeriesGroup>> listAllSeriesGroups() =>
      _repository.getAllSeriesGroups();

  /// 交互搜索 `TMDB` 条目候选。
  Future<List<TmdbSearchResult>> searchTmdbAnime(String query) =>
      _tmdbService.searchAnime(query, priority: RequestPriority.interactive);

  /// 获取 `TMDB` 作品完整详情（含分季摘要）。
  Future<TmdbWorkDetail?> getTmdbWorkDetail(
    int tmdbId,
    TmdbMediaType mediaType,
  ) => _tmdbService.getWorkDetail(
    tmdbId,
    mediaType,
    priority: RequestPriority.interactive,
  );

  /// 交互搜索 `Bangumi` 动画条目候选。
  Future<List<BangumiSubjectCandidate>> searchBangumiSubjects(String query) =>
      _bangumiService.searchSubjectsProgressive(
        query,
        priority: RequestPriority.interactive,
      );

  /// 更新是否显示标题徽标（ClearLogo）。
  Future<void> setShowTitleLogo(bool enabled) async {
    _displayPreferencesStore.setShowTitleLogo(enabled);
  }

  /// 更新是否显示作品简介正文。
  Future<void> setShowOverview(bool enabled) async {
    _displayPreferencesStore.setShowOverview(enabled);
  }

  /// 更新是否在选集卡展示原始视频文件名。
  Future<void> setShowRawVideoFilename(bool enabled) async {
    _displayPreferencesStore.setShowRawVideoFilename(enabled);
  }

  /// 更新是否显示 `CD` 分类标签。
  Future<void> setShowCdTab(bool enabled) async {
    _displayPreferencesStore.setShowCdTab(enabled);
  }

  /// 更新是否显示 `Scan` 分类标签。
  Future<void> setShowScanTab(bool enabled) async {
    _displayPreferencesStore.setShowScanTab(enabled);
  }

  Future<void> setShowEpisodeStillThumbnails(bool enabled) async {
    _displayPreferencesStore.setShowEpisodeStillThumbnails(enabled);
  }

  /// 更新「在卡片显示原始文件名副标题」偏好设置。
  Future<void> setShowOriginalSubtitlesOnCards(bool enabled) async {
    _displayPreferencesStore.setShowOriginalSubtitlesOnCards(enabled);
  }

  /// 更新「展示详情全幅背景原画」偏好设置。
  Future<void> setShowMainHeroBackdrop(bool enabled) async {
    _displayPreferencesStore.setShowMainHeroBackdrop(enabled);
  }

  void _scheduleReload() {
    if (_disposed) return;
    _reloadDebounceTimer?.cancel();
    _reloadDebounceTimer = Timer(const Duration(milliseconds: 80), () {
      if (!_disposed) {
        unawaited(load());
      }
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _warmupService.cancelPending();
    _reloadDebounceTimer?.cancel();
    _rescrapeDismissTimer?.cancel();
    unawaited(_librarySub?.cancel() ?? Future<void>.value());
    unawaited(_userStateSub?.cancel() ?? Future<void>.value());
    unawaited(_domainEventSub?.cancel() ?? Future<void>.value());
    unawaited(_prefsSub?.cancel() ?? Future<void>.value());
    super.dispose();
  }
}
