import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_language.dart';
import 'bangumi_offline_index.dart';
import 'catalog.dart';
import 'cloud_media_asset_presentation.dart';
import 'debug_log.dart';
import 'directory_analyzer.dart';
import 'library_foundation.dart';
import 'metadata.dart';
import 'metadata_http.dart';
import 'metadata_servers.dart';
import 'multi_work_splitter.dart';
import 'personal_scraper.dart';
import 'scan_activity.dart';
import 'work_matcher.dart';
import 'work_season.dart';

/// Fast, high-precision directory-level metadata pipeline.
///
/// Combines:
/// 1. Local [DirectoryAnalyzer] inventory (collapsing multi-version encodes,
///    promoting standalone OVAs, rejecting mixed anthologies).
/// 2. Batch [BangumiOfflineIndex] lookup + minimal concurrent TMDB/Bangumi HTTP
///    requests with cross-provider title rescue and memoization.
/// 3. Deterministic [WorkMatcher] multi-signal scoring:
///    - [MatchTier.high]: auto-bind (`needs_review = 0`) + season mapping.
///    - [MatchTier.medium]: adopt Top-1 cover/metadata (`needs_review = 1`).
///    - [MatchTier.none]: keep clean local title, zero wrong covers.
class ScrapePipeline {
  ScrapePipeline({
    Catalog? catalog,
    http.Client? client,
    BangumiOfflineIndex? offlineIndex,
    this.bangumiBase = 'https://api.bgm.tv',
    this.concurrency = 4,
  }) : _catalog = catalog ?? Catalog.instance,
       _client = client ?? MetadataHttp(),
       _ownsClient = client == null,
       _explicitIndex = offlineIndex;

  final Catalog _catalog;
  final http.Client _client;
  final bool _ownsClient;
  final BangumiOfflineIndex? _explicitIndex;
  final String bangumiBase;
  final int concurrency;

  static const _userAgent =
      'ClainSt/Konata/1.0.0 (https://github.com/ClainSt/Konata)';
  static const _maxMemoEntries = 512;

  final _jsonMemo = <String, Future<Object?>>{};
  void Function()? checkCancelled;

  BangumiOfflineIndex? get _offlineIndex =>
      _explicitIndex ??
      (BangumiOfflineIndex.directory == null
          ? null
          : BangumiOfflineIndex(BangumiOfflineIndex.directory!));

  void close() {
    _jsonMemo.clear();
    if (_ownsClient) _client.close();
  }

  void _check() => checkCancelled?.call();

  /// Scrape all eligible works under [sourceId].
  Future<ScrapeReport> scrapeSource(
    String sourceId, {
    int? limit,
    bool onlyPending = true,
    Set<String>? workIds,
    ScanActivity? run,
  }) async {
    if (_catalog.scanning) throw StateError('当前正在扫描或刮削，请勿同时启动');
    final works = _catalog.works
        .where((w) => w['id']?.toString().startsWith('work:$sourceId:') == true)
        .where((w) => workIds == null || workIds.contains(w['id']?.toString()))
        .toList();

    final assetsByWork = <String, List<Map<String, Object?>>>{};
    for (final asset in _catalog.assets) {
      (assetsByWork[asset['work_id'].toString()] ??= []).add(asset);
    }

    final manualIds = <String>{};
    if (onlyPending && works.isNotEmpty) {
      final rows = await _catalog.db.rawQuery(
        'SELECT o.asset_id FROM asset_overrides o '
        'JOIN assets a ON a.id=o.asset_id WHERE a.work_id LIKE ?',
        ['work:$sourceId:%'],
      );
      for (final row in rows) {
        manualIds.add(row['asset_id'].toString());
      }
    }

    final targets = <Map<String, Object?>>[];
    for (final w in works) {
      if (w['manual_lock'] == 1) continue;
      if (!onlyPending) {
        targets.add(w);
        continue;
      }
      final workId = w['id'].toString();
      final folder = _workFolder(w);
      final isUnclassified =
          folder == '@unclassified' || folder.endsWith('/@unclassified');
      final poster = w['poster']?.toString().trim() ?? '';
      final needsReview = (w['needs_review'] as num?)?.toInt() == 1;
      final hasValidId = w['tmdb_id'] != null || w['bangumi_id'] != null;
      if (isUnclassified || needsReview || !hasValidId || poster.isEmpty) {
        targets.add(w);
        continue;
      }

      final assets = assetsByWork[workId] ?? const [];
      if (assets.isEmpty) continue;
      final workManualIds = <String>{
        for (final a in assets)
          if (manualIds.contains(a['id'].toString())) a['id'].toString(),
      };
      final inventory = _analyzeInventory(workId, folder, assets);
      final uniformSeason = _uniformMainSeason(assets, workManualIds);
      final healed = await _syncLocalAssetCategories(
        workId,
        assets,
        workManualIds,
        inventory,
        uniformSeason: uniformSeason,
      );
      final currentAssets = healed
          ? await _catalog.db.query(
              'assets',
              where: 'work_id=?',
              whereArgs: [workId],
            )
          : assets;
      if (healed) {
        assetsByWork[workId] = currentAssets;
      }
      if (_hasConfirmedWorkAnomalies(
        w,
        folder,
        currentAssets,
        inventory,
        workManualIds,
      )) {
        targets.add(w);
      }
    }

    checkCancelled = run?.checkCancelled;
    var running = true;
    run?.cancelled.then((_) {
      if (running && _ownsClient) _client.close();
    });

    ScanActivityStore.instance.beginScraping(sourceId, targets.length);
    _catalog.updateStatus('准备刮削 ${targets.length} 部作品（TMDB / Bangumi）', true);

    var matched = 0, skipped = 0, review = 0, errors = 0, attempted = 0;
    final deferred = <(Map<String, Object?>, List<Map<String, Object?>>)>[];

    Future<void> process(Map<String, Object?> work) async {
      _check();
      final currentAttempt = ++attempted;
      _catalog.updateStatus(
        '正在刮削 $currentAttempt / ${targets.length}：${work['title']}',
        true,
      );
      try {
        final workId = work['id'].toString();
        final assets = assetsByWork[workId] ?? const [];
        final outcome = await _processWork(work, assets, deferMultiWork: true);
        _check();
        switch (outcome) {
          case _WorkOutcome.deferred:
            deferred.add((work, assets));
          case _WorkOutcome.matched:
            matched++;
            ScanActivityStore.instance.metadataDone(sourceId, matched: true);
          case _WorkOutcome.adoptedForReview:
            review++;
            ScanActivityStore.instance.metadataDone(sourceId, review: true);
          case _WorkOutcome.unmatched:
            final folder = _workFolder(work);
            final isUnclassified =
                folder == '@unclassified' || folder.endsWith('/@unclassified');
            final inv =
                !isUnclassified &&
                    !workId.contains(':classified:') &&
                    assets.length >= 2
                ? _analyzeInventory(workId, folder, assets)
                : null;
            final splitPreview = inv != null
                ? MultiWorkSplitter.split(folder, assets)
                : const <SubWorkCluster>[];
            final shouldDeferSplit =
                inv != null &&
                (inv.tmdbId == null && inv.bangumiId == null
                    ? splitPreview.length >= 2
                    : inv.tmdbId != null &&
                          _shouldSplitExplicitTmdb(inv, splitPreview));
            if (shouldDeferSplit) {
              deferred.add((work, assets));
            } else {
              review++;
              ScanActivityStore.instance.metadataDone(sourceId, review: true);
            }
          case _WorkOutcome.transientError:
            errors++;
            ScanActivityStore.instance.metadataDone(sourceId, error: true);
          case _WorkOutcome.skipped:
            skipped++;
            ScanActivityStore.instance.metadataDone(sourceId);
        }
      } on ScanCancelled {
        rethrow;
      } catch (e) {
        _check();
        DebugLog.write('Scrape', 'failed ${e.runtimeType}', level: 'WARN');
        errors++;
        ScanActivityStore.instance.metadataDone(sourceId, error: true);
      }
    }

    Future<void> processDeferred(
      (Map<String, Object?>, List<Map<String, Object?>>) item,
    ) async {
      _check();
      final (work, assets) = item;
      _catalog.updateStatus('正在拆分合集目录：${work['title']}', true);
      try {
        final outcome = await _processMultiWorkFolder(work, assets);
        _check();
        switch (outcome) {
          case _WorkOutcome.matched:
            matched++;
            ScanActivityStore.instance.metadataDone(sourceId, matched: true);
          case _WorkOutcome.adoptedForReview:
          case _WorkOutcome.unmatched:
          case _WorkOutcome.deferred:
            review++;
            ScanActivityStore.instance.metadataDone(sourceId, review: true);
          case _WorkOutcome.transientError:
            errors++;
            ScanActivityStore.instance.metadataDone(sourceId, error: true);
          case _WorkOutcome.skipped:
            skipped++;
            ScanActivityStore.instance.metadataDone(sourceId);
        }
      } on ScanCancelled {
        rethrow;
      } catch (e) {
        _check();
        DebugLog.write(
          'Scrape',
          'deferred split failed ${e.runtimeType}',
          level: 'WARN',
        );
        errors++;
        ScanActivityStore.instance.metadataDone(sourceId, error: true);
      }
    }

    try {
      final batchTargets = limit == null
          ? targets
          : targets.take(limit < 0 ? 0 : limit).toList();
      final step = concurrency < 1 ? 1 : concurrency;
      for (var offset = 0; offset < batchTargets.length; offset += step) {
        _check();
        await Future.wait(batchTargets.skip(offset).take(step).map(process));
      }
      if (deferred.isNotEmpty) {
        for (var offset = 0; offset < deferred.length; offset += step) {
          _check();
          await Future.wait(
            deferred.skip(offset).take(step).map(processDeferred),
          );
        }
      }
      skipped += works.length - targets.length;
      await _catalog.reload();
      final remaining = targets.length - attempted;
      _catalog.updateStatus(
        '元数据刮削完成：成功 $matched，待复核 $review，'
        '失败 $errors，未处理 $remaining',
      );
      return ScrapeReport(matched, skipped + remaining, review, errors);
    } finally {
      running = false;
      checkCancelled = null;
      _jsonMemo.clear();
      if (_ownsClient) _client.close();
      await _catalog.reload();
      if (_catalog.scanning) _catalog.updateStatus(_catalog.status);
    }
  }

  /// Scrape a single work by [workId]. Returns true if metadata was bound/adopted.
  Future<bool> scrapeWork(
    String workId, {
    ScanActivity? run,
    bool reloadAfter = true,
  }) async {
    final rows = await _catalog.db.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['manual_lock'] == 1) return false;
    checkCancelled = run?.checkCancelled;
    try {
      final assets = _catalog.forWork(workId);
      final outcome = await _processWork(
        rows.single,
        assets,
        deferMultiWork: false,
      );
      if (reloadAfter) await _catalog.reload();
      return outcome == _WorkOutcome.matched ||
          outcome == _WorkOutcome.adoptedForReview;
    } finally {
      checkCancelled = null;
    }
  }

  Future<_WorkOutcome> _processWork(
    Map<String, Object?> work,
    List<Map<String, Object?>> assets, {
    bool deferMultiWork = false,
  }) async {
    final workId = work['id'].toString();
    if (work['manual_lock'] == 1) return _WorkOutcome.skipped;
    if (assets.isEmpty) return _WorkOutcome.skipped;

    final folder = _workFolder(work);
    if (folder == '@unclassified' || folder.endsWith('/@unclassified')) {
      return _processUnclassifiedPool(workId, assets);
    }

    final manualIds = (await _catalog.db.rawQuery(
      'SELECT o.asset_id FROM asset_overrides o '
      'JOIN assets a ON a.id=o.asset_id WHERE a.work_id=?',
      [workId],
    )).map((r) => r['asset_id'].toString()).toSet();

    var inventory = _analyzeInventory(workId, folder, assets);

    if (!workId.contains(':classified:') && assets.length >= 2) {
      if (inventory.tmdbId == null &&
          inventory.bangumiId == null &&
          MultiWorkSplitter.isExplicitCollectionFolder(folder, inventory)) {
        final preview = MultiWorkSplitter.split(folder, assets);
        if (preview.length >= 2) {
          if (deferMultiWork) return _WorkOutcome.deferred;
          return _processMultiWorkFolder(work, assets);
        }
      } else if (inventory.tmdbId != null) {
        final preview = MultiWorkSplitter.split(folder, assets);
        if (_shouldSplitExplicitTmdb(inventory, preview)) {
          if (deferMultiWork) return _WorkOutcome.deferred;
          return _processMultiWorkFolder(work, assets);
        }
      }
    }

    // Sync local main/extra promotions & false-movie-episode cleanup first.
    await _syncLocalAssetCategories(workId, assets, manualIds, inventory);

    if (inventory.shape == WorkShape.empty) {
      await _markEmptyWork(workId, inventory);
      return _WorkOutcome.skipped;
    }
    if (inventory.shape == WorkShape.anthology) {
      await _leaveUnbound(workId, inventory);
      return _WorkOutcome.unmatched;
    }

    final tracker = _TransientTracker();
    final resolved = await _resolveInventory(
      folder,
      inventory,
      tracker: tracker,
    );
    _check();
    if (resolved == null) {
      if (tracker.hadError) {
        await _preserveOnTransientError(workId, inventory);
        return _WorkOutcome.transientError;
      }
      if (!deferMultiWork &&
          !workId.contains(':classified:') &&
          assets.length >= 2) {
        final split = MultiWorkSplitter.split(folder, assets);
        final canSplit = inventory.tmdbId == null && inventory.bangumiId == null
            ? split.length >= 2
            : inventory.tmdbId != null &&
                  _shouldSplitExplicitTmdb(inventory, split);
        if (canSplit) {
          return _processMultiWorkFolder(work, assets);
        }
      }
      await _leaveUnbound(workId, inventory);
      return _WorkOutcome.unmatched;
    }

    if (resolved.tmdbType == 'movie' && inventory.shape == WorkShape.feature) {
      await _clearMovieEpisodeNumbers(assets, manualIds, inventory);
    } else if (resolved.season != null) {
      await _applyResolvedSeason(
        workId,
        assets,
        manualIds,
        inventory,
        resolved.season!,
      );
    }

    final applied = await _saveResolvedWork(workId, resolved, tracker: tracker);
    if (!applied) return _WorkOutcome.skipped;
    return resolved.needsReview
        ? _WorkOutcome.adoptedForReview
        : _WorkOutcome.matched;
  }

  /// Splits a multi-work collection folder into independent `:classified:` works
  /// after all single-work folders have finished scraping.
  Future<_WorkOutcome> _processMultiWorkFolder(
    Map<String, Object?> work,
    List<Map<String, Object?>> assets,
  ) async {
    final workId = work['id'].toString();
    if (work['manual_lock'] == 1 || assets.isEmpty) {
      return _WorkOutcome.skipped;
    }
    final folder = _workFolder(work);
    final fallbackInventory = DirectoryAnalyzer.analyze(folder, [
      for (final asset in assets)
        (
          path: (asset['relative_path'] ?? asset['name'] ?? '').toString(),
          size: (asset['size'] as num?)?.toInt(),
        ),
    ]);
    final clusters = MultiWorkSplitter.split(folder, assets);
    if (clusters.length < 2) {
      await _leaveUnbound(workId, fallbackInventory);
      return _WorkOutcome.unmatched;
    }

    final tracker = _TransientTracker();
    final resolvedList = <_ResolvedWork?>[];
    for (final cluster in clusters) {
      _check();
      if (cluster.inventory.shape == WorkShape.empty ||
          cluster.inventory.shape == WorkShape.anthology) {
        resolvedList.add(null);
        continue;
      }
      final res = await _resolveInventory(
        cluster.virtualFolder,
        cluster.inventory,
        tracker: tracker,
      );
      resolvedList.add(res);
    }

    final anyResolved = resolvedList.any(
      (r) => r != null && (r.tmdbId != null || r.bangumiId != null),
    );
    if (!anyResolved) {
      if (tracker.hadError) {
        await _preserveOnTransientError(workId, fallbackInventory);
        return _WorkOutcome.transientError;
      }
      await _leaveUnbound(workId, fallbackInventory);
      return _WorkOutcome.unmatched;
    }

    final assetById = {for (final a in assets) a['id'].toString(): a};
    final usedIdentities = <String>{};
    final groups =
        <
          ({
            String identity,
            String title,
            int? year,
            int? tmdbId,
            String? tmdbType,
            int? bangumiId,
            List<int> bangumiIds,
            String? poster,
            String? bangumiPoster,
            String? overview,
            bool needsReview,
            List<
              ({
                String assetId,
                String category,
                int season,
                int? episode,
                String? extraType,
              })
            >
            assets,
          })
        >[];

    for (var i = 0; i < clusters.length; i++) {
      final cluster = clusters[i];
      final res = resolvedList[i];
      var baseIdentity = res?.bangumiId != null
          ? 'bgm-${res!.bangumiId}'
          : res?.tmdbId != null
          ? 'tmdb-${res!.tmdbType}-${res.tmdbId}${res.season != null ? "-s${res.season}" : ""}'
          : 'local-${cluster.slug}';
      var identity = baseIdentity;
      if (!usedIdentities.add(identity)) {
        identity = '$baseIdentity-${cluster.slug}';
        var seq = 2;
        while (!usedIdentities.add(identity)) {
          identity = '$baseIdentity-${cluster.slug}-$seq';
          seq++;
        }
      }

      final mappedAssets =
          <
            ({
              String assetId,
              String category,
              int season,
              int? episode,
              String? extraType,
            })
          >[];
      for (final item in cluster.assignments) {
        var season = item.season;
        var episode = item.episode;
        if (item.category == 'main' && res != null) {
          if (res.tmdbType == 'movie' &&
              cluster.inventory.shape == WorkShape.feature) {
            episode = null;
            season = 1;
          } else if (res.season != null) {
            final rawAsset = assetById[item.assetId];
            final explicitFileSeason = rawAsset == null
                ? null
                : CloudMediaAssetPresentation.explicitSeasonNumber({
                    'name': rawAsset['name'],
                    'relative_path': rawAsset['name'],
                  });
            if (explicitFileSeason == null ||
                explicitFileSeason == res.season) {
              season = res.season!;
            }
          }
        }
        mappedAssets.add((
          assetId: item.assetId,
          category: item.category,
          season: season,
          episode: episode,
          extraType: item.extraType,
        ));
      }

      final cleanFallback = Catalog.cleanTitle(cluster.inventory.title);
      groups.add((
        identity: identity,
        title: res != null && res.title.trim().isNotEmpty
            ? res.title.trim()
            : (cleanFallback.isNotEmpty
                  ? cleanFallback
                  : cluster.inventory.title),
        year: res?.year ?? cluster.inventory.year,
        tmdbId: res?.tmdbId,
        tmdbType: res?.tmdbType,
        bangumiId: res?.bangumiId,
        bangumiIds: res?.bangumiIds ?? const [],
        poster: res?.poster,
        bangumiPoster: res?.bangumiPoster,
        overview: res?.overview,
        needsReview: res == null || res.needsReview,
        assets: mappedAssets,
      ));
    }

    final applied = await _catalog.applyMultiWorkSplit(workId, groups);
    if (!applied) return _WorkOutcome.skipped;
    final allClean = groups.every((g) => !g.needsReview);
    return allClean ? _WorkOutcome.matched : _WorkOutcome.adoptedForReview;
  }

  /// Regroups loose root-level files (`@unclassified`) by series stem.
  Future<_WorkOutcome> _processUnclassifiedPool(
    String workId,
    List<Map<String, Object?>> assets,
  ) async {
    final editable = assets.where((a) => a['manual_mapping'] != true).toList();
    if (editable.isEmpty) return _WorkOutcome.skipped;

    final groups = <String, List<Map<String, Object?>>>{};
    for (final asset in editable) {
      final name = (asset['name'] ?? '').toString();
      final stem = _looseFileStem(name);
      (groups[stem] ??= []).add(asset);
    }

    final decisions = <String, ScrapedWork?>{};
    for (final entry in groups.entries) {
      _check();
      if (entry.key.isEmpty) {
        for (final a in entry.value) {
          decisions[a['id'].toString()] = null;
        }
        continue;
      }
      final inv = DirectoryAnalyzer.analyze(entry.key, [
        for (final a in entry.value)
          (
            path: '${entry.key}/${a['name']}',
            size: (a['size'] as num?)?.toInt(),
          ),
      ]);
      final resolved =
          inv.shape == WorkShape.empty || inv.shape == WorkShape.anthology
          ? null
          : await _resolveInventory(entry.key, inv);
      final scraped = resolved != null && !resolved.needsReview
          ? resolved.toScrapedWork()
          : null;
      for (final a in entry.value) {
        decisions[a['id'].toString()] = scraped;
      }
    }

    final complete = await _catalog.applyClassification(workId, decisions);
    return complete && decisions.values.every((v) => v != null)
        ? _WorkOutcome.matched
        : _WorkOutcome.unmatched;
  }

  static String _looseFileStem(String filename) {
    final dot = filename.lastIndexOf('.');
    final stem = dot > 0 ? filename.substring(0, dot) : filename;
    final inv = DirectoryAnalyzer.analyze(stem, [(path: filename, size: null)]);
    if (inv.fileHints.isNotEmpty) return inv.fileHints.first;
    return inv.title;
  }

  static String _workFolder(Map<String, Object?> work) {
    final id = work['id']?.toString() ?? '';
    if (id.startsWith('work:') && !id.contains(':classified:')) {
      final firstColon = id.indexOf(':');
      final secondColon = id.indexOf(':', firstColon + 1);
      if (secondColon > 0 && secondColon + 1 < id.length) {
        try {
          return Uri.decodeComponent(
            id.substring(secondColon + 1),
          ).replaceAll('\\', '/');
        } on FormatException {
          // Fall back to work title below.
        }
      }
    }
    return (work['title'] ?? '').toString();
  }

  static final _crc32BracketPattern = RegExp(
    r'[\[(](?!(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[\])])([0-9a-fA-F]{8})[\])]',
  );

  static String _stripCrc32FromPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized
        .replaceAll(_crc32BracketPattern, ' ')
        .replaceAll(RegExp(r'\s+(?=\.[^./]+$)'), '')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
  }

  DirectoryInventory _analyzeInventory(
    String workId,
    String folder,
    List<Map<String, Object?>> assets,
  ) {
    var inventory = DirectoryAnalyzer.analyze(folder, [
      for (final asset in assets)
        (
          path: _stripCrc32FromPath(
            (asset['relative_path'] ?? asset['name'] ?? '').toString(),
          ),
          size: (asset['size'] as num?)?.toInt(),
        ),
    ]);
    if (inventory.tmdbId == null && inventory.bangumiId == null) {
      inventory = _enrichFromLocalNfo(workId, folder, inventory);
    }
    return inventory;
  }

  static int? _uniformMainSeason(
    List<Map<String, Object?>> assets,
    Set<String> manualIds,
  ) {
    final seasons = <int>{};
    for (final asset in assets) {
      final id = asset['id'].toString();
      if (manualIds.contains(id) || asset['manual_mapping'] == true) continue;
      if (asset['category'] != 'main') continue;
      final season = (asset['season'] as num?)?.toInt();
      if (season == null) return null;
      seasons.add(season);
    }
    return seasons.length == 1 ? seasons.single : null;
  }

  static final _independentInstallmentMarker = RegExp(
    r'(?:^|[^a-z0-9])(?:ova|oad|the[ ._-]*movie|movie)(?=[^a-z0-9]|$)|剧场版|劇場版|映画',
    caseSensitive: false,
  );

  static bool _shouldSplitExplicitTmdb(
    DirectoryInventory inventory,
    List<SubWorkCluster> preview,
  ) {
    if (preview.length < 2) return false;
    final hasUnbound = preview.any((c) => c.inventory.tmdbId == null);
    if (!hasUnbound) return false;
    if (preview.any((c) => c.inventory.tmdbId != null)) return true;
    return preview.any(
      (c) =>
          c.inventory.shape == WorkShape.feature ||
          c.inventory.movieMarker ||
          _independentInstallmentMarker.hasMatch(
            '${c.virtualFolder} ${c.inventory.title} ${c.inventory.titleHints.join(' ')}',
          ),
    );
  }

  static bool _hasConfirmedWorkAnomalies(
    Map<String, Object?> work,
    String folder,
    List<Map<String, Object?>> assets,
    DirectoryInventory inventory,
    Set<String> manualIds,
  ) {
    if (inventory.shape == WorkShape.anthology) return true;
    final workId = work['id'].toString();
    if (!workId.contains(':classified:') && assets.length >= 2) {
      if (inventory.tmdbId == null &&
          inventory.bangumiId == null &&
          MultiWorkSplitter.isExplicitCollectionFolder(folder, inventory)) {
        final preview = MultiWorkSplitter.split(folder, assets);
        if (preview.length >= 2) return true;
      } else if (inventory.tmdbId != null) {
        final preview = MultiWorkSplitter.split(folder, assets);
        if (_shouldSplitExplicitTmdb(inventory, preview)) return true;
      }
    }

    if (work['tmdb_type'] == 'tv') {
      final mainAssets = <Map<String, Object?>>[];
      for (final asset in assets) {
        final id = asset['id'].toString();
        if (manualIds.contains(id) || asset['manual_mapping'] == true) continue;
        if (asset['category'] == 'main') mainAssets.add(asset);
      }
      if (mainAssets.length >= 2) {
        final seasons = <int?>{
          for (final a in mainAssets) (a['season'] as num?)?.toInt(),
        };
        if (seasons.contains(null)) return true;
        if (seasons.length >= 2 && seasons.any((s) => (s ?? 0) > 1)) {
          for (final a in mainAssets) {
            if ((a['season'] as num?)?.toInt() == 1 &&
                CloudMediaAssetPresentation.explicitSeasonNumber({
                      'name': a['name'],
                      'relative_path': a['name'],
                    }) ==
                    null) {
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  Future<bool> _syncLocalAssetCategories(
    String workId,
    List<Map<String, Object?>> assets,
    Set<String> manualIds,
    DirectoryInventory inventory, {
    int? uniformSeason,
  }) async {
    final mainByPath = <String, LogicalItem>{};
    for (final item in inventory.main) {
      for (final file in item.files) {
        mainByPath[file.replaceAll('\\', '/')] = item;
      }
    }
    final extraPaths = {
      for (final file in inventory.extras) file.replaceAll('\\', '/'),
    };

    final updates = <(String, Map<String, Object?>)>[];
    for (final asset in assets) {
      final id = asset['id'].toString();
      if (manualIds.contains(id) || asset['manual_mapping'] == true) continue;
      final rel = (asset['relative_path'] ?? asset['name'] ?? '')
          .toString()
          .replaceAll('\\', '/');
      final strippedRel = _stripCrc32FromPath(rel);
      final matchedMain = mainByPath[rel] ?? mainByPath[strippedRel];
      if (matchedMain != null) {
        final wantedEp = matchedMain.episode ?? asset['episode'];
        final explicitFileSeason =
            CloudMediaAssetPresentation.explicitSeasonNumber({
              'name': asset['name'],
              'relative_path': asset['name'],
            });
        final preferredSeason =
            asset['category'] != 'main' &&
                uniformSeason != null &&
                explicitFileSeason == null
            ? uniformSeason
            : matchedMain.season;
        final wantedSeason = preferredSeason ?? (asset['season'] as int? ?? 1);
        final diff = <String, Object?>{};
        if (asset['category'] != 'main') {
          diff['category'] = 'main';
          diff['extra_type'] = null;
        }
        if (wantedEp != null && asset['episode'] != wantedEp) {
          diff['episode'] = wantedEp;
        }
        if (asset['season'] != wantedSeason && preferredSeason != null) {
          diff['season'] = wantedSeason;
        }
        if (diff.isNotEmpty) updates.add((id, diff));
      } else if (extraPaths.contains(rel) || extraPaths.contains(strippedRel)) {
        if (asset['category'] != 'extra') {
          updates.add((
            id,
            {
              'category': 'extra',
              'extra_type': CloudMediaAssetPresentation.extraType({
                'name': asset['name'],
                'relative_path': rel,
              }),
            },
          ));
        }
      }
    }
    if (updates.isEmpty) return false;
    await _catalog.db.transaction((tx) async {
      for (final (id, diff) in updates) {
        await tx.update('assets', diff, where: 'id=?', whereArgs: [id]);
      }
      await tx.delete('work_details', where: 'work_id=?', whereArgs: [workId]);
    });
    return true;
  }

  Future<void> _applyResolvedSeason(
    String workId,
    List<Map<String, Object?>> assets,
    Set<String> manualIds,
    DirectoryInventory inventory,
    int resolvedSeason,
  ) async {
    final mainPaths = {
      for (final item in inventory.main)
        for (final file in item.files) file.replaceAll('\\', '/'),
    };
    final targetIds = <String>[];
    for (final asset in assets) {
      final id = asset['id'].toString();
      if (manualIds.contains(id) || asset['manual_mapping'] == true) continue;
      final rel = (asset['relative_path'] ?? asset['name'] ?? '')
          .toString()
          .replaceAll('\\', '/');
      final strippedRel = _stripCrc32FromPath(rel);
      if (!mainPaths.contains(rel) && !mainPaths.contains(strippedRel)) {
        continue;
      }
      // Preserve explicit per-file SxxExx seasons when a folder mixes seasons.
      final explicitFileSeason =
          CloudMediaAssetPresentation.explicitSeasonNumber({
            'name': asset['name'],
            'relative_path': asset['name'],
          });
      if (explicitFileSeason != null && explicitFileSeason != resolvedSeason) {
        continue;
      }
      if (asset['season'] != resolvedSeason) {
        targetIds.add(id);
      }
    }
    if (targetIds.isEmpty) return;
    await _catalog.db.transaction((tx) async {
      for (final id in targetIds) {
        await tx.update(
          'assets',
          {'season': resolvedSeason},
          where: 'id=?',
          whereArgs: [id],
        );
      }
    });
  }

  Future<void> _clearMovieEpisodeNumbers(
    List<Map<String, Object?>> assets,
    Set<String> manualIds,
    DirectoryInventory inventory,
  ) async {
    final mainPaths = {
      for (final item in inventory.main)
        for (final file in item.files) file.replaceAll('\\', '/'),
    };
    final targetIds = <String>[];
    for (final asset in assets) {
      final id = asset['id'].toString();
      if (manualIds.contains(id) || asset['manual_mapping'] == true) continue;
      final rel = (asset['relative_path'] ?? asset['name'] ?? '')
          .toString()
          .replaceAll('\\', '/');
      final strippedRel = _stripCrc32FromPath(rel);
      if ((mainPaths.contains(rel) || mainPaths.contains(strippedRel)) &&
          asset['episode'] != null) {
        targetIds.add(id);
      }
    }
    if (targetIds.isEmpty) return;
    await _catalog.db.transaction((tx) async {
      for (final id in targetIds) {
        await tx.update(
          'assets',
          {'episode': null},
          where: 'id=?',
          whereArgs: [id],
        );
      }
    });
  }

  Future<_ResolvedWork?> _resolveInventory(
    String folder,
    DirectoryInventory inventory, {
    _TransientTracker? tracker,
  }) async {
    final queries = _buildQueries(folder, inventory);
    final bgmDetails = <int, Map<String, dynamic>>{};
    final tmdbDetails = <String, Map<String, dynamic>>{};
    var bgmResult = MatchResult.empty;
    var tmdbResult = MatchResult.empty;
    var ignoreExplicitTmdb = false;

    // Fast path when folder carries an explicit {tmdb-N}: fetch that exact ID
    // first (1-2 GETs) and feed its official/original titles into Bangumi lookup.
    // If TMDB returns 404/null for the explicit ID, fall back to regular search.
    var ranExplicitPath = false;
    if (inventory.tmdbId != null && Metadata.credentials.isConfigured) {
      final explicitCandidates = await _collectTmdbCandidates(
        inventory,
        queries,
        MatchResult.empty,
        tmdbDetails,
        exactOnly: true,
        tracker: tracker,
      );
      if (explicitCandidates.isNotEmpty) {
        ranExplicitPath = true;
        final prelimTmdb = WorkMatcher.tmdb(inventory, explicitCandidates);
        final reverseBgmIds = prelimTmdb.candidate == null
            ? const <int>[]
            : await _lookupReverseBangumiIds(
                prelimTmdb.candidate!.type,
                prelimTmdb.candidate!.id,
              );
        final enrichedQueries = <String>[
          if (prelimTmdb.candidate != null) ...[
            prelimTmdb.candidate!.title,
            ...prelimTmdb.candidate!.aliases.take(2),
          ],
          ...queries,
        ];
        final bgmCandidates = await _collectBangumiCandidates(
          inventory,
          enrichedQueries,
          bgmDetails,
          extraSubjectIds: reverseBgmIds,
          tracker: tracker,
        );
        bgmResult = WorkMatcher.bangumi(inventory, bgmCandidates);
        tmdbResult = WorkMatcher.tmdb(
          inventory,
          explicitCandidates,
          bangumi: bgmResult,
        );
      } else if (!(tracker?.tmdbFailed ?? false)) {
        ignoreExplicitTmdb = true;
      }
    }

    if (!ranExplicitPath &&
        (inventory.tmdbId == null ||
            ignoreExplicitTmdb ||
            !Metadata.credentials.isConfigured)) {
      // Standard path: offline/online Bangumi first -> cross-rescue TMDB search.
      final bgmCandidates = await _collectBangumiCandidates(
        inventory,
        queries,
        bgmDetails,
        tracker: tracker,
      );
      bgmResult = WorkMatcher.bangumi(inventory, bgmCandidates);

      final mappedTarget =
          bgmResult.candidate != null && bgmResult.tier == MatchTier.high
          ? await _lookupMappedTarget(bgmResult.candidate!.id)
          : null;

      if (Metadata.credentials.isConfigured) {
        final tmdbCandidates = await _collectTmdbCandidates(
          inventory,
          queries,
          bgmResult,
          tmdbDetails,
          mappedTarget: mappedTarget,
          ignoreExplicitTmdb: ignoreExplicitTmdb,
          tracker: tracker,
        );
        tmdbResult = WorkMatcher.tmdb(
          inventory,
          tmdbCandidates,
          bangumi: bgmResult,
          mappedTarget: mappedTarget == null
              ? null
              : (key: mappedTarget.key, season: mappedTarget.season),
          ignoreTmdbMarker: ignoreExplicitTmdb,
        );
      }

      if (bgmResult.tier == MatchTier.none && tmdbResult.candidate != null) {
        final tmdbWinner = tmdbResult.candidate!;
        final reverseBgmIds = await _lookupReverseBangumiIds(
          tmdbWinner.type,
          tmdbWinner.id,
        );
        final rescueQueries = <String>[
          tmdbWinner.title,
          ...tmdbWinner.aliases.take(2),
        ].where((s) => s.trim().isNotEmpty).toSet().toList();
        if (rescueQueries.isNotEmpty || reverseBgmIds.isNotEmpty) {
          final extraBgm = await _collectBangumiCandidates(
            inventory,
            rescueQueries,
            bgmDetails,
            extraSubjectIds: reverseBgmIds,
            forceOnlineSearch: true,
            tracker: tracker,
          );
          if (extraBgm.isNotEmpty) {
            final merged = <int, MatchCandidate>{
              for (final c in bgmCandidates) c.id: c,
              for (final c in extraBgm) c.id: c,
            }.values.toList();
            bgmResult = WorkMatcher.bangumi(inventory, merged);
            if (Metadata.credentials.isConfigured && tmdbDetails.isNotEmpty) {
              tmdbResult = WorkMatcher.tmdb(
                inventory,
                [
                  for (final entry in tmdbDetails.entries)
                    _tmdbCandidate(entry.key.split(':').first, entry.value),
                ],
                bangumi: bgmResult,
                ignoreTmdbMarker: ignoreExplicitTmdb,
              );
            }
          }
        }
      }
    }

    var tmdbPick = tmdbResult.candidate;
    var tmdbTier = tmdbResult.tier;
    var resolvedSeason = tmdbResult.season;
    var bgmPick = bgmResult.candidate;
    var bgmTier = bgmResult.tier;

    // Guard against pairing a high-confidence primary with a conflicting medium secondary.
    if (tmdbPick != null && bgmPick != null) {
      if (tmdbTier == MatchTier.high &&
          bgmTier == MatchTier.medium &&
          !_providersCompatible(tmdbPick, resolvedSeason, bgmPick)) {
        bgmPick = null;
        bgmTier = MatchTier.none;
      } else if (bgmTier == MatchTier.high &&
          tmdbTier == MatchTier.medium &&
          !_providersCompatible(tmdbPick, resolvedSeason, bgmPick)) {
        tmdbPick = null;
        tmdbTier = MatchTier.none;
        resolvedSeason = null;
      }
    }

    if (tmdbPick == null && bgmPick == null) return null;

    final high = tmdbTier == MatchTier.high || bgmTier == MatchTier.high;

    // Fetch season-specific poster & overview when a TV season is resolved.
    Map<String, dynamic>? seasonDetail;
    if (tmdbPick != null &&
        tmdbPick.type == 'tv' &&
        resolvedSeason != null &&
        Metadata.credentials.isConfigured) {
      try {
        seasonDetail = await _fetchTmdb(
          '/tv/${tmdbPick.id}/season/$resolvedSeason',
          {'language': AppLanguage.instance.metadataLanguage},
        );
      } on ScanCancelled {
        rethrow;
      } catch (_) {
        // Fall back to series-level poster and overview.
      }
    }

    final tmdbRaw = tmdbPick == null
        ? null
        : tmdbDetails['${tmdbPick.type}:${tmdbPick.id}'];
    final bgmRaw = bgmPick == null ? null : bgmDetails[bgmPick.id];
    final bgmSiblingIds =
        bgmPick != null &&
            bgmResult.candidate?.id == bgmPick.id &&
            bgmResult.siblingIds.length >= 2
        ? bgmResult.siblingIds
        : const <int>[];

    return _buildResolvedWork(
      inventory: inventory,
      tmdbPick: tmdbPick,
      tmdbRaw: tmdbRaw,
      seasonDetail: seasonDetail,
      resolvedSeason: resolvedSeason,
      bgmPick: bgmPick,
      bgmRaw: bgmRaw,
      bgmSiblingIds: bgmSiblingIds,
      needsReview: !high,
    );
  }

  static bool _providersCompatible(
    MatchCandidate tmdb,
    int? resolvedSeason,
    MatchCandidate bgm,
  ) {
    final ty = resolvedSeason != null
        ? tmdb.seasons
                  .where((s) => s.number == resolvedSeason)
                  .firstOrNull
                  ?.year ??
              tmdb.year
        : tmdb.year;
    final by = bgm.year;
    if (ty == null || by == null) return true;
    if ((ty - by).abs() <= 2) return true;
    // Multi-season TMDB series first_air_date is often earlier than a sequel/OVA year.
    if (tmdb.type == 'tv' && tmdb.year != null && tmdb.year! <= by + 1) {
      return true;
    }
    return false;
  }

  static final _remasterPattern = RegExp(
    r'(?:HD\s*)?(?:重制版|重製版|Remaster(?:ed)?)|リマスター',
    caseSensitive: false,
  );

  static bool _hasRemasterTag(String value) => _remasterPattern.hasMatch(value);

  static String _stripRemasterTag(String value) => value
      .replaceAll(_remasterPattern, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static bool _isBangumiRemasterIdentity(
    DirectoryInventory inventory,
    MatchCandidate? tmdbPick,
    MatchCandidate? bgmPick,
  ) =>
      bgmPick != null &&
      _hasRemasterTag(inventory.title) &&
      _hasRemasterTag(bgmPick.title) &&
      (tmdbPick == null || !_hasRemasterTag(tmdbPick.title));

  /// True when the local CJK folder title matches Bangumi's season-specific CJK
  /// title far more closely than TMDB's series-level translation (e.g. `魔具少女！` /
  /// `魔具少女！通` vs TMDB `魔剑姬！`, or `两个人是少女福尔摩斯` vs `侦探歌剧 少女福尔摩斯`).
  static bool _useBangumiSeasonIdentity({
    required DirectoryInventory inventory,
    required MatchCandidate? tmdbPick,
    required MatchCandidate? bgmPick,
  }) {
    if (tmdbPick == null || tmdbPick.type != 'tv' || bgmPick == null) {
      return false;
    }
    if (_isBangumiRemasterIdentity(inventory, tmdbPick, bgmPick)) {
      return true;
    }
    final bgmTitle = bgmPick.title.trim();
    final localTitle = inventory.title.trim();
    if (!_hasCjk(bgmTitle) || !_hasCjk(localTitle)) return false;
    final normLocal = DirectoryAnalyzer.normalize(localTitle);
    final normBgm = DirectoryAnalyzer.normalize(bgmTitle);
    final normTmdb = DirectoryAnalyzer.normalize(tmdbPick.title);
    if (normLocal.isEmpty || normBgm.isEmpty || normBgm == normTmdb) {
      return false;
    }
    final localToBgm = WorkMatcher.similarity(normLocal, normBgm);
    final localToTmdb = normTmdb.isEmpty
        ? 0.0
        : WorkMatcher.similarity(normLocal, normTmdb);
    return localToBgm >= 0.85 && localToBgm >= localToTmdb + 0.25;
  }

  /// True when Bangumi identifies a specific sub-installment (split cour,
  /// sequel subtitle, or OVA/movie chapter) while TMDB merges the franchise
  /// under one generic series/season entry.
  static bool _isSpecificSubWork({
    required DirectoryInventory inventory,
    required MatchCandidate tmdbPick,
    required int? resolvedSeason,
    required MatchCandidate? bgmPick,
  }) {
    if (bgmPick == null) return false;
    if (resolvedSeason != null && resolvedSeason > 0) {
      final regular = tmdbPick.seasons.where((s) => s.number > 0).toList();
      final matched = regular
          .where((s) => s.number == resolvedSeason)
          .firstOrNull;
      final mergedSingleSeason =
          regular.length <= 1 &&
          matched != null &&
          inventory.episodeCount > 0 &&
          matched.count >= inventory.episodeCount + 4;
      if (!mergedSingleSeason) return false;
    }
    final bgmTitle = bgmPick.title.trim();
    final tmdbTitle = tmdbPick.title.trim();
    if (bgmTitle.isEmpty || tmdbTitle.isEmpty) return false;
    final normBgm = DirectoryAnalyzer.normalize(bgmTitle);
    final normTmdb = DirectoryAnalyzer.normalize(tmdbTitle);
    if (normBgm.isEmpty || normTmdb.isEmpty || normBgm == normTmdb) {
      return false;
    }
    if (normBgm.startsWith(normTmdb) && normBgm.length >= normTmdb.length + 2) {
      final suffix = bgmTitle.length > tmdbTitle.length
          ? bgmTitle.substring(tmdbTitle.length).trim()
          : '';
      if (suffix.isNotEmpty && _isGenericSeasonName(suffix)) return false;
      return true;
    }
    final normLocal = DirectoryAnalyzer.normalize(inventory.title);
    if (_hasCjk(bgmTitle) &&
        normLocal.length >= normTmdb.length + 2 &&
        WorkMatcher.similarity(normLocal, normBgm) >
            WorkMatcher.similarity(normLocal, normTmdb) + 0.15) {
      return true;
    }
    return false;
  }

  _ResolvedWork _buildResolvedWork({
    required DirectoryInventory inventory,
    required MatchCandidate? tmdbPick,
    required Map<String, dynamic>? tmdbRaw,
    required Map<String, dynamic>? seasonDetail,
    required int? resolvedSeason,
    required MatchCandidate? bgmPick,
    required Map<String, dynamic>? bgmRaw,
    List<int> bgmSiblingIds = const [],
    required bool needsReview,
  }) {
    final lang = AppLanguage.instance.metadataLanguage;
    final seasonPosterPath = seasonDetail?['poster_path']?.toString();
    final tmdbPosterPath = (seasonPosterPath ?? tmdbRaw?['poster_path'])
        ?.toString();
    final tmdbPoster = tmdbPosterPath != null && tmdbPosterPath.startsWith('/')
        ? MetadataServers.tmdbImage(tmdbPosterPath)
        : null;
    final bgmPoster = _bangumiImage(bgmRaw);

    final specificSubWork =
        tmdbPick != null &&
        _isSpecificSubWork(
          inventory: inventory,
          tmdbPick: tmdbPick,
          resolvedSeason: resolvedSeason,
          bgmPick: bgmPick,
        );
    final bangumiSeasonIdentity = _useBangumiSeasonIdentity(
      inventory: inventory,
      tmdbPick: tmdbPick,
      bgmPick: bgmPick,
    );
    // When multiple sub-works (e.g. 女王之刃 S1/S2/OVA) share one TMDB TV ID
    // without dedicated per-installment season posters, when a standalone special
    // maps to Season 0, or when Bangumi holds the exact season identity (e.g.
    // 魔具少女！ / 魔具少女！通), prefer each installment's distinct Bangumi cover.
    final regularCount =
        tmdbPick?.seasons.where((s) => s.number > 0).length ?? 0;
    final lacksDistinctSeasonPoster =
        seasonPosterPath == null ||
        !seasonPosterPath.startsWith('/') ||
        (resolvedSeason != null && resolvedSeason > 0 && regularCount <= 1) ||
        resolvedSeason == 0;
    final preferBgmPoster =
        bgmPoster != null &&
        (resolvedSeason == 0 ||
            bangumiSeasonIdentity ||
            (specificSubWork &&
                tmdbPick.type == 'tv' &&
                lacksDistinctSeasonPoster));
    final primaryPoster = preferBgmPoster
        ? bgmPoster
        : (tmdbPoster ?? bgmPoster);

    final seasonOverview = seasonDetail?['overview']?.toString().trim();
    final tmdbOverview = tmdbRaw?['overview']?.toString().trim();
    final bgmOverview = AppLanguage.bangumiSynopsis(bgmRaw?['summary'], lang);

    String? overview;
    if (resolvedSeason == 0 && bgmOverview != null && bgmOverview.isNotEmpty) {
      overview = bgmOverview;
    } else if (seasonOverview != null && seasonOverview.isNotEmpty) {
      overview = seasonOverview;
    } else if ((specificSubWork || bangumiSeasonIdentity) &&
        bgmOverview != null &&
        bgmOverview.isNotEmpty) {
      overview = bgmOverview;
    } else if (lang.startsWith('zh') &&
        bgmOverview != null &&
        bgmOverview.isNotEmpty &&
        (tmdbOverview == null ||
            tmdbOverview.isEmpty ||
            !_hasCjk(tmdbOverview))) {
      overview = bgmOverview;
    } else if (tmdbOverview != null && tmdbOverview.isNotEmpty) {
      overview = tmdbOverview;
    } else {
      overview = bgmOverview;
    }

    final remasterIdentity = _isBangumiRemasterIdentity(
      inventory,
      tmdbPick,
      bgmPick,
    );
    final seasonYear = resolvedSeason == 0
        ? null
        : _parseYear(seasonDetail?['air_date']);
    final year = remasterIdentity
        ? (bgmPick?.year ?? seasonYear ?? tmdbPick?.year ?? inventory.year)
        : (seasonYear ?? bgmPick?.year ?? tmdbPick?.year ?? inventory.year);

    final title = _chooseDisplayTitle(
      inventory: inventory,
      tmdbPick: tmdbPick,
      seasonDetail: seasonDetail,
      resolvedSeason: resolvedSeason,
      bgmPick: bgmPick,
      bgmSiblingIds: bgmSiblingIds,
    );

    final provider = tmdbPick != null && bgmPick != null
        ? 'TMDB + Bangumi'
        : tmdbPick != null
        ? 'TMDB'
        : 'Bangumi';

    return _ResolvedWork(
      title: title,
      year: year,
      tmdbId: tmdbPick?.id,
      tmdbType: tmdbPick?.type,
      bangumiId: bgmPick?.id,
      bangumiIds: bgmSiblingIds,
      poster: primaryPoster,
      bangumiPoster: bgmPoster,
      overview: overview,
      provider: provider,
      season: resolvedSeason,
      needsReview: needsReview,
    );
  }

  static String _chooseDisplayTitle({
    required DirectoryInventory inventory,
    required MatchCandidate? tmdbPick,
    required Map<String, dynamic>? seasonDetail,
    required int? resolvedSeason,
    required MatchCandidate? bgmPick,
    List<int> bgmSiblingIds = const [],
  }) {
    if (bgmSiblingIds.length >= 2) {
      final cleanLocal = Catalog.cleanTitle(inventory.title);
      if (cleanLocal.isNotEmpty) return cleanLocal;
    }

    if (tmdbPick == null) {
      return (bgmPick?.title.trim().isNotEmpty == true
          ? bgmPick!.title.trim()
          : inventory.title);
    }

    if (_useBangumiSeasonIdentity(
      inventory: inventory,
      tmdbPick: tmdbPick,
      bgmPick: bgmPick,
    )) {
      return bgmPick!.title.trim();
    }

    var baseTitle = tmdbPick.title.trim();
    if (!_hasCjk(baseTitle) &&
        bgmPick != null &&
        _hasCjk(bgmPick.title) &&
        resolvedSeason == null) {
      baseTitle = bgmPick.title.trim();
    }
    if (baseTitle.isEmpty) baseTitle = bgmPick?.title.trim() ?? inventory.title;

    if (_isSpecificSubWork(
      inventory: inventory,
      tmdbPick: tmdbPick,
      resolvedSeason: resolvedSeason,
      bgmPick: bgmPick,
    )) {
      return bgmPick!.title.trim();
    }

    if (tmdbPick.type != 'tv' || resolvedSeason == null) {
      if (bgmPick == null && tmdbPick.type == 'tv' && resolvedSeason == null) {
        final normLocal = DirectoryAnalyzer.normalize(inventory.title);
        final normTmdb = DirectoryAnalyzer.normalize(baseTitle);
        if (normTmdb.isNotEmpty &&
            normLocal.startsWith(normTmdb) &&
            normLocal.length >= normTmdb.length + 2 &&
            !_isGenericSeasonName(normLocal.substring(normTmdb.length))) {
          return inventory.title;
        }
      }
      return baseTitle;
    }

    if (resolvedSeason == 0) {
      // Standalone OVA / Special folder: prefer its specific Bangumi or folder title
      // instead of collapsing to the parent TV series name.
      if (bgmPick != null && bgmPick.title.trim().isNotEmpty) {
        return bgmPick.title.trim();
      }
      final seasonName = seasonDetail?['name']?.toString().trim() ?? '';
      if (seasonName.isNotEmpty && !_isGenericSeasonName(seasonName)) {
        return seasonName.contains(baseTitle)
            ? seasonName
            : '$baseTitle $seasonName';
      }
      return inventory.title.isNotEmpty ? inventory.title : '$baseTitle 特别篇';
    }

    // Never auto-append `' 第x季'` onto works.title; keep single/first season
    // on the original title and prefer Bangumi or non-generic TMDB season
    // subtitles on sequel seasons (season number is persisted to assets.season).
    if (resolvedSeason > 1) {
      if (bgmPick != null) {
        final bgmTitle = bgmPick.title.trim();
        if (bgmTitle.isNotEmpty &&
            !_isGenericSeasonName(bgmTitle) &&
            DirectoryAnalyzer.normalize(bgmTitle) !=
                DirectoryAnalyzer.normalize(baseTitle)) {
          return bgmTitle;
        }
      }
      final detailSeasonName = seasonDetail?['name']?.toString().trim() ?? '';
      final infoSeasonName =
          tmdbPick.seasons
              .where((s) => s.number == resolvedSeason)
              .firstOrNull
              ?.name
              ?.trim() ??
          '';
      final seasonName = detailSeasonName.isNotEmpty
          ? detailSeasonName
          : infoSeasonName;
      if (seasonName.isNotEmpty && !_isGenericSeasonName(seasonName)) {
        final normSeason = DirectoryAnalyzer.normalize(seasonName);
        final normBase = DirectoryAnalyzer.normalize(baseTitle);
        if (seasonName.contains(baseTitle) ||
            (normBase.isNotEmpty && normSeason.startsWith(normBase))) {
          return seasonName;
        }
        return '$baseTitle $seasonName';
      }
    }

    return baseTitle;
  }

  static bool _isGenericSeasonName(String name) => RegExp(
    r'^(?:season\s*\d+|specials?|第\s*[0-9一二三四五六七八九十百]+\s*[季期部]|特别篇|特典)$',
    caseSensitive: false,
  ).hasMatch(name.trim());

  static bool _hasCjk(String s) => RegExp(r'[\u3040-\u9fff]').hasMatch(s);

  static List<String> _buildQueries(
    String folder,
    DirectoryInventory inventory,
  ) {
    final seen = <String>{};
    final out = <String>[];
    void add(String raw) {
      final cleaned = raw
          .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
          .replaceAll(RegExp(r'\(\s*(?:19|20)\d{2}\s*\)'), ' ')
          .replaceAll(RegExp(r'（\s*(?:19|20)\d{2}\s*）'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleaned.isEmpty) return;
      final norm = DirectoryAnalyzer.normalize(cleaned);
      if (norm.isEmpty || !seen.add(norm)) return;
      out.add(cleaned);
    }

    for (final hint in inventory.titleHints) {
      add(hint);
      final strippedPart = WorkSeason.withoutPart(hint);
      if (strippedPart != hint) add(strippedPart);
      final strippedRemaster = _stripRemasterTag(hint);
      if (strippedRemaster != hint && strippedRemaster.isNotEmpty) {
        add(strippedRemaster);
      }
    }
    for (final hint in inventory.fileHints) {
      add(hint);
      final strippedRemaster = _stripRemasterTag(hint);
      if (strippedRemaster != hint && strippedRemaster.isNotEmpty) {
        add(strippedRemaster);
      }
    }

    // Parent series folder hint (e.g. "动画-多作品/XX 作品集/XX 篇章名" -> "XX").
    final parts = folder
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      for (
        var idx = parts.length - 2;
        idx >= 0 && idx >= parts.length - 3;
        idx--
      ) {
        final parent = parts[idx]
            .replaceFirst(
              RegExp(
                r'\s*(?:系列|作品集|合集|全集|Series|Collection)$',
                caseSensitive: false,
              ),
              '',
            )
            .trim();
        if (parent.isNotEmpty &&
            !_isCategoryFolder(parent) &&
            !_isGenericSeasonName(parent)) {
          add(parent);
        }
      }
    }

    // Base franchise stems: strip trailing subtitle/arc ("系列名·副标题",
    // "系列名 篇章名") or leading short modifier ("前缀 作品名").
    for (final base in [
      ...inventory.titleHints.take(2),
      ...inventory.fileHints.take(2),
    ]) {
      final beforePunct = base
          .split(RegExp(r'[:：～~—/·・･]+'))
          .first
          .trim();
      if (beforePunct.isNotEmpty &&
          beforePunct != base &&
          (_hasCjk(beforePunct)
              ? beforePunct.length >= 2
              : beforePunct.length >= 4)) {
        add(beforePunct);
      }
      final tokens = base
          .split(RegExp(r'\s+|[:：～~—\-/·・･]+'))
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.length >= 2) {
        final first = tokens.first.trim();
        if (first != base &&
            (_hasCjk(first) ? first.length >= 2 : first.length >= 4)) {
          add(first);
        }
        final tail = tokens.skip(1).join(' ').trim();
        if (tail != base &&
            first.length <= 6 &&
            (_hasCjk(tail) ? tail.length >= 2 : tail.length >= 4)) {
          add(tail);
        }
      }
    }

    return out.take(8).toList();
  }

  static bool _isCategoryFolder(String name) => RegExp(
    r'^(?:动画|番剧|电影|剧场版|动漫|影视|日漫|国漫|美漫|动画[-_]?单作品|动画[-_]?多作品|anime|movies?|tv|series|bdmv|bdrip|video|media|downloads?)$',
    caseSensitive: false,
  ).hasMatch(name.trim());

  Future<List<MatchCandidate>> _collectBangumiCandidates(
    DirectoryInventory inventory,
    List<String> queries,
    Map<int, Map<String, dynamic>> detailsOut, {
    List<int> extraSubjectIds = const [],
    bool forceOnlineSearch = false,
    _TransientTracker? tracker,
  }) async {
    final rawById = <int, Map<String, dynamic>>{};

    if (inventory.bangumiId != null) {
      try {
        final exact = await _fetchBangumiSubject(inventory.bangumiId!);
        if (exact != null) {
          rawById[inventory.bangumiId!] = exact;
          detailsOut[inventory.bangumiId!] = exact;
        }
      } on ScanCancelled {
        rethrow;
      } catch (e) {
        if (_isTransientError(e)) tracker?.bangumiFailed = true;
      }
    }

    for (final id in extraSubjectIds.take(3)) {
      if (rawById.containsKey(id)) continue;
      try {
        final exact = await _fetchBangumiSubject(id);
        if (exact != null) {
          rawById[id] = exact;
          detailsOut[id] = exact;
        }
      } on ScanCancelled {
        rethrow;
      } catch (e) {
        if (_isTransientError(e)) tracker?.bangumiFailed = true;
      }
    }

    var offlineHigh = false;
    if (rawById.isEmpty && queries.isNotEmpty) {
      final index = _offlineIndex;
      if (index != null && !forceOnlineSearch) {
        try {
          final rows = await index.lookupMany(queries);
          for (final row in rows) {
            final id = (row['id'] as num?)?.toInt();
            if (id != null && id > 0) rawById[id] = row;
          }
          if (rawById.isNotEmpty) {
            final offlineScore = WorkMatcher.bangumi(
              inventory,
              rawById.values.map(_bangumiCandidate).toList(),
            );
            offlineHigh = offlineScore.tier == MatchTier.high;
          }
        } catch (_) {
          // Offline index is an optional accelerator; fall back to online API.
        }
      }

      if (!offlineHigh) {
        final searchTerms = queries.take(3).toList();
        try {
          final searchLists = await Future.wait(
            searchTerms.map(_searchBangumi),
          );
          for (final list in searchLists) {
            for (final row in list) {
              final id = (row['id'] as num?)?.toInt();
              if (id != null && id > 0) rawById.putIfAbsent(id, () => row);
            }
          }
          if (rawById.isEmpty && queries.length > 3) {
            final wave2Lists = await Future.wait(
              queries.skip(3).take(3).map(_searchBangumi),
            );
            for (final list in wave2Lists) {
              for (final row in list) {
                final id = (row['id'] as num?)?.toInt();
                if (id != null && id > 0) rawById.putIfAbsent(id, () => row);
              }
            }
          }
        } on ScanCancelled {
          rethrow;
        } catch (e) {
          if (_isTransientError(e)) tracker?.bangumiFailed = true;
          if (rawById.isEmpty &&
              !Metadata.credentials.isConfigured &&
              !_isTransientError(e)) {
            rethrow;
          }
        }
      }
    }

    if (rawById.isEmpty) return const [];

    // When offline index already settled a high-confidence winner, fetch only
    // that 1 subject's detail (poster + summary); otherwise check Top 4.
    final prelim = rawById.values.map(_bangumiCandidate).toList();
    final prelimMatch = WorkMatcher.bangumi(inventory, prelim);
    final detailLimit = prelimMatch.tier == MatchTier.high ? 1 : 4;
    final topIds = <int>{
      ...prelimMatch.ranking.take(detailLimit).map((e) => e.candidate.id),
      ...prelimMatch.siblingIds,
    }.toList();
    await Future.wait(
      topIds.map((id) async {
        final existing = detailsOut[id] ?? rawById[id];
        if (existing != null &&
            existing['images'] is Map &&
            existing['infobox'] is List) {
          detailsOut[id] = existing;
          return;
        }
        Map<String, dynamic>? full;
        try {
          full = await _fetchBangumiSubject(id);
        } on ScanCancelled {
          rethrow;
        } catch (e) {
          if (_isTransientError(e)) tracker?.bangumiFailed = true;
          if (existing == null && !_isTransientError(e)) rethrow;
        }
        if (full != null) {
          rawById[id] = {...?existing, ...full};
          detailsOut[id] = rawById[id]!;
        } else if (existing != null) {
          detailsOut[id] = existing;
        }
      }),
    );

    return rawById.values.map(_bangumiCandidate).toList();
  }

  Future<List<MatchCandidate>> _collectTmdbCandidates(
    DirectoryInventory inventory,
    List<String> localQueries,
    MatchResult bgmResult,
    Map<String, Map<String, dynamic>> detailsOut, {
    ({String key, String type, int id, int? season})? mappedTarget,
    bool exactOnly = false,
    bool ignoreExplicitTmdb = false,
    _TransientTracker? tracker,
  }) async {
    try {
      if (inventory.tmdbId != null && !ignoreExplicitTmdb) {
        final id = inventory.tmdbId!;
        final types = inventory.tmdbType == 'movie'
            ? const ['movie']
            : inventory.tmdbType == 'tv'
            ? const ['tv']
            : const ['tv', 'movie'];
        await Future.wait(
          types.map((type) async {
            final detail = await _fetchTmdbDetail(type, id);
            if (detail != null) detailsOut['$type:$id'] = detail;
          }),
        );
        if (exactOnly || detailsOut.isNotEmpty || (tracker?.tmdbFailed ?? false)) {
          return [
            for (final entry in detailsOut.entries)
              _tmdbCandidate(entry.key.split(':').first, entry.value),
          ];
        }
      }

      final rawHits = <String, Map<String, dynamic>>{};

      if (mappedTarget != null) {
        try {
          final mappedDetail = await _fetchTmdbDetail(
            mappedTarget.type,
            mappedTarget.id,
          );
          if (mappedDetail != null) {
            rawHits[mappedTarget.key] = mappedDetail;
            detailsOut[mappedTarget.key] = mappedDetail;
          }
        } on ScanCancelled {
          rethrow;
        } catch (e) {
          if (_isTransientError(e)) tracker?.tmdbFailed = true;
        }
      }

      // Build cross-provider enriched query list: Bangumi's official JP/CN names
      // rescue folders whose Chinese fan-title does not match TMDB's translation.
      final searchQueries = <String>[];
      final seen = <String>{};
      void addQuery(String q) {
        final clean = q.trim();
        if (clean.isEmpty) return;
        final norm = DirectoryAnalyzer.normalize(clean);
        if (norm.isEmpty || !seen.add(norm)) return;
        searchQueries.add(clean);
      }

      if (bgmResult.candidate != null) {
        final bgm = bgmResult.candidate!;
        addQuery(bgm.title);
        final strippedRemasterBgm = _stripRemasterTag(bgm.title);
        if (strippedRemasterBgm != bgm.title &&
            strippedRemasterBgm.isNotEmpty) {
          addQuery(strippedRemasterBgm);
        }
        if (bgm.aliases.isNotEmpty) addQuery(bgm.aliases.first);
        final base = bgm.title
            .split(RegExp(r'\s+|[:：～~—\-/·・･]+'))
            .first
            .trim();
        if (base.length >= 2) addQuery(base);
      }
      for (final q in localQueries) {
        addQuery(q);
      }
      for (final raw in [
        inventory.title,
        if (bgmResult.candidate != null) bgmResult.candidate!.title,
        if (bgmResult.candidate != null &&
            bgmResult.candidate!.aliases.isNotEmpty)
          bgmResult.candidate!.aliases.first,
      ]) {
        final beforeTilde = raw.split(RegExp(r'[:：～~—/·・･]')).first.trim();
        final words = beforeTilde
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .toList();
        for (var len = words.length - 1; len >= 1; len--) {
          final prefix = words.take(len).join(' ').trim();
          if (_hasCjk(prefix) ? prefix.length >= 4 : prefix.length >= 6) {
            addQuery(prefix);
          }
        }
        if (words.length >= 2 && words.first.length <= 6) {
          final tail = words.skip(1).join(' ').trim();
          if (_hasCjk(tail) ? tail.length >= 2 : tail.length >= 4) {
            addQuery(tail);
          }
        }
      }

      Future<void> runSearchWave(List<String> wave, bool wantMovie) async {
        final tasks = <Future<void>>[];
        for (final term in wave) {
          tasks.add(() async {
            final tvRows = await _searchTmdb('tv', term);
            for (final r in tvRows.take(6)) {
              final id = (r['id'] as num?)?.toInt();
              if (id != null) rawHits.putIfAbsent('tv:$id', () => r);
            }
          }());
          if (wantMovie) {
            tasks.add(() async {
              final movieRows = await _searchTmdb('movie', term);
              for (final r in movieRows.take(6)) {
                final id = (r['id'] as num?)?.toInt();
                if (id != null) rawHits.putIfAbsent('movie:$id', () => r);
              }
            }());
          }
        }
        await Future.wait(tasks);
      }

      bool waveNeedsBackup() {
        if (rawHits.isEmpty) return true;
        final prelim = [
          for (final entry in rawHits.entries)
            _tmdbCandidate(entry.key.split(':').first, entry.value),
        ];
        final top = WorkMatcher.tmdb(
          inventory,
          prelim,
          bangumi: bgmResult,
          mappedTarget: mappedTarget == null
              ? null
              : (key: mappedTarget.key, season: mappedTarget.season),
          ignoreTmdbMarker: ignoreExplicitTmdb,
        ).ranking.firstOrNull;
        return (top?.score ?? 0) < 42;
      }

      final terms = searchQueries.take(3).toList();
      if (terms.isNotEmpty) {
        final wantMovie =
            inventory.shape == WorkShape.feature || inventory.movieMarker;
        await runSearchWave(terms, wantMovie);

        // When long/modified titles return 0 hits or only weak candidates on
        // TMDB search, run Wave 2 with fileHints, stripped parent series,
        // and base stems.
        if (searchQueries.length > 3 && waveNeedsBackup()) {
          await runSearchWave(
            searchQueries.skip(3).take(5).toList(),
            wantMovie,
          );
        }

        // If TV search returned nothing on a series, also check movie once (e.g. theatrical/OVA split).
        if (rawHits.isEmpty && !wantMovie) {
          final movieRows = await _searchTmdb('movie', terms.first);
          for (final r in movieRows.take(4)) {
            final id = (r['id'] as num?)?.toInt();
            if (id != null) rawHits.putIfAbsent('movie:$id', () => r);
          }
        }
      }

      if (rawHits.isEmpty) return const [];

      final mappedHint = mappedTarget == null
          ? null
          : (key: mappedTarget.key, season: mappedTarget.season);
      final prelim = [
        for (final entry in rawHits.entries)
          _tmdbCandidate(entry.key.split(':').first, entry.value),
      ];
      final ranked = [
        for (final c in prelim)
          (
            c,
            WorkMatcher.tmdb(
                  inventory,
                  [c],
                  bangumi: bgmResult,
                  mappedTarget: mappedHint,
                  ignoreTmdbMarker: ignoreExplicitTmdb,
                ).ranking.firstOrNull?.score ??
                0,
          ),
      ]..sort((a, b) => b.$2.compareTo(a.$2));

      // Fetch full details (seasons + alternative_titles + translations) for Top 4.
      await Future.wait(
        ranked.take(4).map((item) async {
          final c = item.$1;
          if (detailsOut.containsKey(c.key)) return;
          final detail = await _fetchTmdbDetail(c.type, c.id);
          detailsOut[c.key] = detail ?? rawHits[c.key]!;
        }),
      );

      return [
        for (final entry in rawHits.entries)
          _tmdbCandidate(
            entry.key.split(':').first,
            detailsOut[entry.key] ?? entry.value,
          ),
      ];
    } on ScanCancelled {
      rethrow;
    } catch (e) {
      if (_isTransientError(e)) {
        tracker?.tmdbFailed = true;
        return [
          for (final entry in detailsOut.entries)
            _tmdbCandidate(entry.key.split(':').first, entry.value),
        ];
      }
      rethrow;
    }
  }

  /// Strictly read-only local `.nfo` ID extraction (`tvshow.nfo` / `movie.nfo`).
  /// Never writes to or modifies user source directories.
  DirectoryInventory _enrichFromLocalNfo(
    String workId,
    String folder,
    DirectoryInventory inventory,
  ) {
    if (!workId.startsWith('work:')) return inventory;
    final firstColon = workId.indexOf(':');
    final secondColon = workId.indexOf(':', firstColon + 1);
    if (secondColon <= firstColon + 1) return inventory;
    final sourceId = workId.substring(firstColon + 1, secondColon);
    final source = _catalog.sources
        .where((s) => s['id']?.toString() == sourceId)
        .firstOrNull;
    if (source == null || source['kind'] != 'local') return inventory;
    final baseLocation = source['location']?.toString() ?? '';
    if (baseLocation.isEmpty) return inventory;

    final dirPath = folder.isEmpty
        ? baseLocation
        : p.joinAll([
            baseLocation,
            ...folder.split('/').where((s) => s.isNotEmpty),
          ]);
    int? tmdbId = inventory.tmdbId;
    String? tmdbType = inventory.tmdbType;
    int? bangumiId = inventory.bangumiId;

    for (final entry in const [('tvshow.nfo', 'tv'), ('movie.nfo', 'movie')]) {
      final file = File(p.join(dirPath, entry.$1));
      try {
        if (!file.existsSync()) continue;
        final raf = file.openSync(mode: FileMode.read);
        final bytes = raf.readSync(16384);
        raf.closeSync();
        final text = utf8.decode(bytes, allowMalformed: true);
        if (tmdbId == null) {
          final m =
              RegExp(
                r'<tmdbid>\s*(\d+)\s*</tmdbid>',
                caseSensitive: false,
              ).firstMatch(text) ??
              RegExp(
                r'<uniqueid[^>]*\btype=["\x27]tmdb["\x27][^>]*>\s*(\d+)\s*</uniqueid>',
                caseSensitive: false,
              ).firstMatch(text) ??
              RegExp(
                r'themoviedb\.org/(tv|movie)/(\d+)',
                caseSensitive: false,
              ).firstMatch(text);
          if (m != null) {
            if (m.groupCount >= 2 && m.group(2) != null) {
              tmdbType ??= m.group(1)!.toLowerCase();
              tmdbId = int.tryParse(m.group(2)!);
            } else {
              tmdbId = int.tryParse(m.group(1)!);
              tmdbType ??= entry.$2;
            }
          }
        }
        if (bangumiId == null) {
          final bm =
              RegExp(
                r'<bangumiid>\s*(\d+)\s*</bangumiid>',
                caseSensitive: false,
              ).firstMatch(text) ??
              RegExp(
                r'<uniqueid[^>]*\btype=["\x27](?:bangumi|bgm)["\x27][^>]*>\s*(\d+)\s*</uniqueid>',
                caseSensitive: false,
              ).firstMatch(text) ??
              RegExp(
                r'(?:bgm\.tv|bangumi\.tv)/subject/(\d+)',
                caseSensitive: false,
              ).firstMatch(text);
          if (bm != null) {
            bangumiId = int.tryParse(bm.group(1)!);
          }
        }
      } catch (_) {
        // Ignore unreadable or malformed NFO files.
      }
    }

    if (tmdbId == inventory.tmdbId && bangumiId == inventory.bangumiId) {
      return inventory;
    }
    return inventory.withExplicitIds(
      tmdbId: tmdbId,
      tmdbType: tmdbType,
      bangumiId: bangumiId,
    );
  }

  /// Queries any locally installed `open-ani/bangumi-tmdb` index batch for a
  /// deterministic Bangumi -> TMDB target bridge.
  Future<({String key, String type, int id, int? season})?> _lookupMappedTarget(
    int bangumiId,
  ) async {
    try {
      final rows = await _catalog.db.rawQuery(
        "SELECT s.targets FROM mapping_subjects s "
        "JOIN mapping_batches b ON b.id=s.batch "
        "WHERE s.subject=? AND b.state='ready' LIMIT 1",
        [bangumiId],
      );
      if (rows.isEmpty) return null;
      final raw = rows.first['targets']?.toString();
      if (raw == null || raw.isEmpty) return null;
      final list = jsonDecode(raw);
      if (list is! List || list.isEmpty) return null;
      String? sharedType;
      int? sharedId;
      final seasons = <int>{};
      for (final item in list.whereType<Map>()) {
        final type = item['type']?.toString();
        final id = (item['id'] as num?)?.toInt();
        if ((type != 'tv' && type != 'movie') || id == null || id <= 0) {
          continue;
        }
        if (sharedType == null) {
          sharedType = type;
          sharedId = id;
        } else if (sharedType != type || sharedId != id) {
          return null;
        }
        final s = (item['season'] as num?)?.toInt();
        if (s != null) seasons.add(s);
      }
      if (sharedType == null || sharedId == null) return null;
      return (
        key: '$sharedType:$sharedId',
        type: sharedType,
        id: sharedId,
        season: seasons.length == 1 ? seasons.single : null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<int>> _lookupReverseBangumiIds(String type, int tmdbId) async {
    try {
      final rows = await _catalog.db.rawQuery(
        "SELECT DISTINCT r.subject FROM mapping_reverse r "
        "JOIN mapping_batches b ON b.id=r.batch "
        "WHERE r.type=? AND r.tmdb=? AND b.state='ready' LIMIT 4",
        [type, tmdbId],
      );
      return [
        for (final r in rows)
          if ((r['subject'] as num?)?.toInt() case final id? when id > 0) id,
      ];
    } catch (_) {
      return const [];
    }
  }

  static bool _isTransientError(Object error) {
    if (error is TimeoutException ||
        error is IOException ||
        error is http.ClientException) {
      return true;
    }
    if (error is StateError) {
      return RegExp(r'HTTP (?:429|5\d\d)\b').hasMatch(error.message);
    }
    return false;
  }

  Future<T> _withSingleRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ScanCancelled {
      rethrow;
    } catch (e) {
      if (!_isTransientError(e)) rethrow;
      _check();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      _check();
      return action();
    }
  }

  static String? _parseFullDateString(Object? raw) {
    if (raw == null) return null;
    final m = RegExp(
      r'((?:19|20)\d{2})\D+(\d{1,2})\D+(\d{1,2})',
    ).firstMatch(raw.toString());
    if (m == null) return null;
    final y = m.group(1)!;
    final mo = m.group(2)!.padLeft(2, '0');
    final d = m.group(3)!.padLeft(2, '0');
    return '$y-$mo-$d';
  }

  static MatchCandidate _bangumiCandidate(Map<String, dynamic> row) {
    final name = (row['name'] ?? '').toString().trim();
    final nameCn = (row['name_cn'] ?? '').toString().trim();
    final title = nameCn.isNotEmpty ? nameCn : name;
    final aliases = <String>[];
    if (name.isNotEmpty) aliases.add(name);
    if (nameCn.isNotEmpty && nameCn != name) aliases.add(nameCn);

    var airDate = _parseFullDateString(row['date']);
    var year = _parseYear(row['date']);
    final platform = (row['platform'] ?? '').toString().trim().toLowerCase();
    var isSpecialFormat = platform == 'ova' || platform == 'oad';
    if (!isSpecialFormat && row['tags'] is List) {
      for (final t in (row['tags'] as List).whereType<Map>()) {
        final tName = (t['name'] ?? '').toString().trim().toLowerCase();
        if (tName == 'ova' || tName == 'oad') {
          isSpecialFormat = true;
          break;
        }
      }
    }
    final infobox = row['infobox'];
    if (infobox is List) {
      for (final item in infobox.whereType<Map>()) {
        final key = (item['key'] ?? '').toString().trim().toLowerCase();
        final value = item['value'];
        if (['别名', '中文名', 'alias', 'aliases'].contains(key)) {
          if (value is String && value.trim().isNotEmpty) {
            aliases.add(value.trim());
          } else if (value is List) {
            for (final v in value.whereType<Map>()) {
              final text = (v['v'] ?? '').toString().trim();
              if (text.isNotEmpty) aliases.add(text);
            }
          }
        } else if (key.contains('放送开始') ||
            key.contains('上映年度') ||
            key.contains('发售日')) {
          year ??= _parseYear(value);
          airDate ??= _parseFullDateString(value);
        }
      }
    }
    if (!isSpecialFormat) {
      final ovaWord = RegExp(
        r'(?<![a-z0-9])(?:ova|oad)(?![a-z0-9])',
        caseSensitive: false,
      );
      isSpecialFormat =
          ovaWord.hasMatch(title) || aliases.any(ovaWord.hasMatch);
    }

    final eps =
        (row['total_episodes'] as num?)?.toInt() ??
        (row['eps'] as num?)?.toInt();
    return MatchCandidate(
      provider: 'bangumi',
      id: (row['id'] as num).toInt(),
      type: 'anime',
      title: title,
      year: year,
      airDate: airDate,
      isSpecialFormat: isSpecialFormat,
      aliases: aliases,
      seasons: eps != null && eps > 0
          ? [SeasonInfo(1, eps, year, name: title, airDate: airDate)]
          : const [],
    );
  }

  static MatchCandidate _tmdbCandidate(String type, Map<String, dynamic> row) {
    final title = (row['name'] ?? row['title'] ?? '').toString().trim();
    final original = (row['original_name'] ?? row['original_title'] ?? '')
        .toString()
        .trim();
    final rawDate = type == 'movie' ? row['release_date'] : row['first_air_date'];
    final year = _parseYear(rawDate);
    final airDate = _parseFullDateString(rawDate);

    final aliases = <String>[];
    void addAlias(Object? v) {
      final s = v?.toString().trim() ?? '';
      if (s.isNotEmpty && s != title && !aliases.contains(s)) aliases.add(s);
    }

    addAlias(original);
    final alt = row['alternative_titles'];
    if (alt is Map) {
      final list = (alt['results'] ?? alt['titles']);
      if (list is List) {
        for (final item in list.whereType<Map>()) {
          addAlias(item['title']);
        }
      }
    }
    final trans = row['translations'];
    if (trans is Map && trans['translations'] is List) {
      for (final item in (trans['translations'] as List).whereType<Map>()) {
        final iso = (item['iso_639_1'] ?? '').toString();
        if (!const {'zh', 'ja', 'en'}.contains(iso)) continue;
        final data = item['data'];
        if (data is Map) {
          addAlias(data['name'] ?? data['title']);
        }
      }
    }

    final seasons = <SeasonInfo>[];
    if (type == 'tv' && row['seasons'] is List) {
      for (final s in (row['seasons'] as List).whereType<Map>()) {
        final numVal = (s['season_number'] as num?)?.toInt();
        if (numVal == null || numVal < 0) continue;
        final count = (s['episode_count'] as num?)?.toInt() ?? 0;
        final sYear = _parseYear(s['air_date']);
        final sAirDate = _parseFullDateString(s['air_date']);
        final sNameRaw = s['name']?.toString().trim() ?? '';
        seasons.add(
          SeasonInfo(
            numVal,
            count,
            sYear,
            name: sNameRaw.isNotEmpty ? sNameRaw : null,
            airDate: sAirDate,
          ),
        );
        if (sNameRaw.isNotEmpty && !_isGenericSeasonName(sNameRaw)) {
          addAlias(sNameRaw);
          if (title.isNotEmpty && !sNameRaw.contains(title)) {
            addAlias('$title $sNameRaw');
          }
        }
      }
    }

    return MatchCandidate(
      provider: 'tmdb',
      id: (row['id'] as num).toInt(),
      type: type,
      title: title.isNotEmpty ? title : original,
      year: year,
      airDate: airDate,
      aliases: aliases,
      seasons: seasons,
    );
  }

  static String? _bangumiImage(Map<String, dynamic>? row) {
    final images = row?['images'];
    if (images is! Map) return null;
    for (final key in const ['large', 'common', 'medium']) {
      final url = images[key]?.toString().trim();
      if (url != null && url.startsWith('https://')) return url;
    }
    return null;
  }

  static int? _parseYear(Object? raw) {
    if (raw == null) return null;
    final m = RegExp(r'(19|20)\d{2}').firstMatch(raw.toString());
    return m == null ? null : int.tryParse(m.group(0)!);
  }

  Future<Object?> _memoized(String key, Future<Object?> Function() load) {
    if (_jsonMemo.containsKey(key)) return _jsonMemo[key]!;
    if (_jsonMemo.length >= _maxMemoEntries) {
      _jsonMemo.remove(_jsonMemo.keys.first);
    }
    final future = load().catchError((Object e) {
      _jsonMemo.remove(key);
      throw e;
    });
    _jsonMemo[key] = future;
    return future;
  }

  Future<Map<String, dynamic>?> _fetchTmdbDetail(String type, int id) async {
    final detailed = await _fetchTmdb('/$type/$id', {
      'language': 'zh-CN',
      'append_to_response': 'alternative_titles,translations',
    });
    return detailed != null && detailed['id'] == id ? detailed : null;
  }

  Future<List<Map<String, dynamic>>> _searchTmdb(
    String type,
    String query,
  ) async {
    final body = await _fetchTmdb('/search/$type', {
      'query': query,
      'language': 'zh-CN',
      'include_adult': 'false',
    });
    final results = body?['results'];
    if (results is! List) return const [];
    return results
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>?> _fetchTmdb(
    String resource,
    Map<String, String> params,
  ) async {
    _check();
    final credentials = Metadata.credentials;
    if (!credentials.isConfigured) return null;
    final key = 'tmdb:$resource:${jsonEncode(params)}';
    final res = await _memoized(
      key,
      () => _withSingleRetry(() async {
        final response = await _client.get(
          credentials.uri(resource, params),
          headers: credentials.headers,
        );
        if (response.statusCode == 404) return null;
        if (response.statusCode != 200) {
          throw StateError('TMDB HTTP ${response.statusCode}');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
      }),
    );
    return res as Map<String, dynamic>?;
  }

  Future<List<Map<String, dynamic>>> _searchBangumi(String keyword) async {
    _check();
    final key = 'bgm:search:$keyword';
    final res = await _memoized(
      key,
      () => _withSingleRetry(() async {
        final response = await _client.post(
          Uri.parse('$bangumiBase/v0/search/subjects'),
          headers: const {
            'User-Agent': _userAgent,
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'keyword': keyword,
            'filter': {
              'type': [2],
            },
          }),
        );
        if (response.statusCode == 404) return const <Map<String, dynamic>>[];
        if (response.statusCode != 200) {
          throw StateError('Bangumi HTTP ${response.statusCode}');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final data = decoded is Map ? decoded['data'] : null;
        if (data is! List) return const <Map<String, dynamic>>[];
        return data
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }),
    );
    return res as List<Map<String, dynamic>>;
  }

  Future<Map<String, dynamic>?> _fetchBangumiSubject(int id) async {
    _check();
    final key = 'bgm:subject:$id';
    final res = await _memoized(
      key,
      () => _withSingleRetry(() async {
        final response = await _client.get(
          Uri.parse('$bangumiBase/v0/subjects/$id'),
          headers: const {
            'User-Agent': _userAgent,
            'Accept': 'application/json',
          },
        );
        if (response.statusCode == 404) return null;
        if (response.statusCode != 200) {
          throw StateError('Bangumi HTTP ${response.statusCode}');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        return decoded is Map && decoded['id'] == id
            ? Map<String, dynamic>.from(decoded)
            : null;
      }),
    );
    return res as Map<String, dynamic>?;
  }

  Future<bool> _saveResolvedWork(
    String workId,
    _ResolvedWork resolved, {
    _TransientTracker? tracker,
  }) async {
    final rows = await _catalog.db.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['manual_lock'] == 1) return false;
    final old = rows.single;
    final keepOldTmdb =
        resolved.tmdbId == null &&
        (tracker?.tmdbFailed ?? false) &&
        old['tmdb_id'] != null;
    final keepOldBgm =
        resolved.bangumiId == null &&
        (tracker?.bangumiFailed ?? false) &&
        old['bangumi_id'] != null;
    final sameIdentity =
        keepOldTmdb ||
        keepOldBgm ||
        (resolved.tmdbId != null &&
            resolved.tmdbId == old['tmdb_id'] &&
            resolved.tmdbType == old['tmdb_type']) ||
        (resolved.bangumiId != null && resolved.bangumiId == old['bangumi_id']);

    final poster = resolved.poster?.trim();
    final overview = resolved.overview?.trim();
    final update = <String, Object?>{
      'title': resolved.title.trim().isNotEmpty ? resolved.title : old['title'],
      'year': resolved.year ?? (sameIdentity ? old['year'] : null),
      'poster': poster != null && poster.isNotEmpty
          ? poster
          : (sameIdentity ? old['poster'] : null),
      'poster_fallback':
          resolved.bangumiPoster ??
          (sameIdentity ? old['poster_fallback'] : null),
      'overview': overview != null && overview.isNotEmpty
          ? overview
          : (sameIdentity ? old['overview'] : null),
      'tmdb_id': keepOldTmdb
          ? old['tmdb_id']
          : resolved.tmdbId ?? (sameIdentity ? old['tmdb_id'] : null),
      'tmdb_type': keepOldTmdb
          ? old['tmdb_type']
          : resolved.tmdbType ?? (sameIdentity ? old['tmdb_type'] : null),
      'bangumi_id': old['bangumi_link_info'] != null || keepOldBgm
          ? old['bangumi_id']
          : resolved.bangumiId ?? (sameIdentity ? old['bangumi_id'] : null),
      if (!keepOldBgm &&
          old['bangumi_link_info'] == null &&
          old.containsKey('bangumi_ids'))
        'bangumi_ids': resolved.bangumiIds.length >= 2
            ? jsonEncode(resolved.bangumiIds)
            : (sameIdentity && resolved.bangumiId == null
                  ? old['bangumi_ids']
                  : null),
      'needs_review': resolved.needsReview ? 1 : 0,
    };

    if (_catalog.foundationEnabled) {
      return _catalog.db.transaction(
        (tx) => LibraryFoundation.applyAutomatic(tx, workId, update),
      );
    }
    final changed = await _catalog.db.update(
      'works',
      update,
      where: 'id=? AND manual_lock=0',
      whereArgs: [workId],
    );
    return changed > 0;
  }

  /// Preserves any existing metadata when a transient network timeout / 429 /
  /// 5xx occurs, never wiping previously bound IDs or covers to null.
  Future<void> _preserveOnTransientError(
    String workId,
    DirectoryInventory inventory,
  ) async {
    final rows = await _catalog.db.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['manual_lock'] == 1) return;
    final old = rows.single;
    final hasBoundMetadata =
        old['tmdb_id'] != null ||
        old['bangumi_id'] != null ||
        (old['poster']?.toString().trim().isNotEmpty ?? false) ||
        (old['poster_fallback']?.toString().trim().isNotEmpty ?? false);
    if (hasBoundMetadata) return;

    final clean = Catalog.cleanTitle(inventory.title);
    await _catalog.db.update(
      'works',
      {
        if (clean.isNotEmpty) 'title': clean,
        if (inventory.year != null && old['year'] == null)
          'year': inventory.year,
        'needs_review': 1,
      },
      where: 'id=? AND manual_lock=0',
      whereArgs: [workId],
    );
  }

  Future<void> _markEmptyWork(
    String workId,
    DirectoryInventory inventory,
  ) async {
    final clean = Catalog.cleanTitle(inventory.title);
    await _catalog.db.update(
      'works',
      {if (clean.isNotEmpty) 'title': clean, 'needs_review': 0},
      where: 'id=? AND manual_lock=0',
      whereArgs: [workId],
    );
  }

  Future<void> _leaveUnbound(
    String workId,
    DirectoryInventory inventory,
  ) async {
    final rows = await _catalog.db.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['manual_lock'] == 1) return;
    final clean = Catalog.cleanTitle(inventory.title);
    final update = <String, Object?>{
      if (clean.isNotEmpty) 'title': clean,
      if (inventory.year != null) 'year': inventory.year,
      'tmdb_id': null,
      'tmdb_type': null,
      if (rows.single['bangumi_link_info'] == null) 'bangumi_id': null,
      'poster': null,
      'poster_fallback': null,
      'overview': null,
      'needs_review': 1,
    };
    if (_catalog.foundationEnabled) {
      await _catalog.db.transaction(
        (tx) => LibraryFoundation.applyAutomatic(tx, workId, update),
      );
    } else {
      await _catalog.db.update(
        'works',
        update,
        where: 'id=? AND manual_lock=0',
        whereArgs: [workId],
      );
    }
  }
}

enum _WorkOutcome {
  deferred,
  matched,
  adoptedForReview,
  unmatched,
  transientError,
  skipped,
}

class _TransientTracker {
  bool bangumiFailed = false;
  bool tmdbFailed = false;
  bool get hadError => bangumiFailed || tmdbFailed;
}

class _ResolvedWork {
  const _ResolvedWork({
    required this.title,
    required this.provider,
    this.year,
    this.tmdbId,
    this.tmdbType,
    this.bangumiId,
    this.bangumiIds = const [],
    this.poster,
    this.bangumiPoster,
    this.overview,
    this.season,
    this.needsReview = false,
  });

  final String title, provider;
  final int? year, tmdbId, bangumiId, season;
  final List<int> bangumiIds;
  final String? tmdbType, poster, bangumiPoster, overview;
  final bool needsReview;

  ScrapedWork toScrapedWork() => ScrapedWork(
    title: title,
    year: year,
    tmdbId: tmdbId,
    tmdbType: tmdbType,
    bangumiId: bangumiId,
    poster: poster,
    bangumiPoster: bangumiPoster,
    overview: overview,
    provider: provider,
  );
}
