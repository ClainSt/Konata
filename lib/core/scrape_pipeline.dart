import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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

    final seenSeries = <Object>{}, sharedSeries = <Object>{};
    for (final work in _catalog.works) {
      final id = work['tmdb_id'];
      if (id != null && work['tmdb_type'] == 'tv' && !seenSeries.add(id)) {
        sharedSeries.add(id);
      }
    }

    final targets = works.where((w) {
      if (w['manual_lock'] == 1) return false;
      final poster = w['poster']?.toString().trim() ?? '';
      return !onlyPending ||
          poster.isEmpty ||
          w['needs_review'] == 1 ||
          WorkSeason.needsRefresh(
            w,
            sharedSeries: sharedSeries.contains(w['tmdb_id']),
          );
    }).toList();

    checkCancelled = run?.checkCancelled;
    var running = true;
    run?.cancelled.then((_) {
      if (running && _ownsClient) _client.close();
    });

    ScanActivityStore.instance.beginScraping(sourceId, targets.length);
    _catalog.updateStatus('准备刮削 ${targets.length} 部作品（TMDB / Bangumi）', true);

    var matched = 0, skipped = 0, review = 0, errors = 0, attempted = 0;

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
        final outcome = await _processWork(work, assets);
        _check();
        switch (outcome) {
          case _WorkOutcome.matched:
            matched++;
            ScanActivityStore.instance.metadataDone(sourceId, matched: true);
          case _WorkOutcome.adoptedForReview:
          case _WorkOutcome.unmatched:
            review++;
            ScanActivityStore.instance.metadataDone(sourceId, review: true);
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

    try {
      final batchTargets = limit == null
          ? targets
          : targets.take(limit < 0 ? 0 : limit).toList();
      final step = concurrency < 1 ? 1 : concurrency;
      for (var offset = 0; offset < batchTargets.length; offset += step) {
        _check();
        await Future.wait(batchTargets.skip(offset).take(step).map(process));
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
      final outcome = await _processWork(rows.single, assets);
      if (reloadAfter) await _catalog.reload();
      return outcome == _WorkOutcome.matched ||
          outcome == _WorkOutcome.adoptedForReview;
    } finally {
      checkCancelled = null;
    }
  }

  Future<_WorkOutcome> _processWork(
    Map<String, Object?> work,
    List<Map<String, Object?>> assets,
  ) async {
    final workId = work['id'].toString();
    if (work['manual_lock'] == 1) return _WorkOutcome.skipped;
    if (assets.isEmpty) return _WorkOutcome.skipped;

    final folder = _workFolder(work);
    if (folder == '@unclassified') {
      return _processUnclassifiedPool(workId, assets);
    }

    final manualIds = (await _catalog.db.rawQuery(
      'SELECT o.asset_id FROM asset_overrides o '
      'JOIN assets a ON a.id=o.asset_id WHERE a.work_id=?',
      [workId],
    )).map((r) => r['asset_id'].toString()).toSet();

    final inventory = DirectoryAnalyzer.analyze(folder, [
      for (final asset in assets)
        (
          path: (asset['relative_path'] ?? asset['name'] ?? '').toString(),
          size: (asset['size'] as num?)?.toInt(),
        ),
    ]);

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

    final resolved = await _resolveInventory(folder, inventory);
    _check();
    if (resolved == null) {
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

    final applied = await _saveResolvedWork(workId, resolved);
    if (!applied) return _WorkOutcome.skipped;
    return resolved.needsReview
        ? _WorkOutcome.adoptedForReview
        : _WorkOutcome.matched;
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

  Future<void> _syncLocalAssetCategories(
    String workId,
    List<Map<String, Object?>> assets,
    Set<String> manualIds,
    DirectoryInventory inventory,
  ) async {
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
      if (mainByPath.containsKey(rel)) {
        final item = mainByPath[rel]!;
        final wantedEp = item.episode ?? asset['episode'];
        final wantedSeason = item.season ?? (asset['season'] as int? ?? 1);
        final diff = <String, Object?>{};
        if (asset['category'] != 'main') {
          diff['category'] = 'main';
          diff['extra_type'] = null;
        }
        if (wantedEp != null && asset['episode'] != wantedEp) {
          diff['episode'] = wantedEp;
        }
        if (asset['season'] != wantedSeason && item.season != null) {
          diff['season'] = wantedSeason;
        }
        if (diff.isNotEmpty) updates.add((id, diff));
      } else if (extraPaths.contains(rel)) {
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
    if (updates.isEmpty) return;
    await _catalog.db.transaction((tx) async {
      for (final (id, diff) in updates) {
        await tx.update('assets', diff, where: 'id=?', whereArgs: [id]);
      }
    });
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
      if (!mainPaths.contains(rel)) continue;
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
      if (mainPaths.contains(rel) && asset['episode'] != null) {
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
    DirectoryInventory inventory,
  ) async {
    final queries = _buildQueries(folder, inventory);
    final bgmDetails = <int, Map<String, dynamic>>{};
    final tmdbDetails = <String, Map<String, dynamic>>{};
    var bgmResult = MatchResult.empty;
    var tmdbResult = MatchResult.empty;

    // Fast path when folder carries an explicit {tmdb-N}: fetch that exact ID
    // first (1-2 GETs) and feed its official/original titles into Bangumi lookup.
    if (inventory.tmdbId != null && Metadata.credentials.isConfigured) {
      final tmdbCandidates = await _collectTmdbCandidates(
        inventory,
        queries,
        MatchResult.empty,
        tmdbDetails,
      );
      final prelimTmdb = WorkMatcher.tmdb(inventory, tmdbCandidates);
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
      );
      bgmResult = WorkMatcher.bangumi(inventory, bgmCandidates);
      tmdbResult = WorkMatcher.tmdb(
        inventory,
        tmdbCandidates,
        bangumi: bgmResult,
      );
    } else {
      // Standard path: offline/online Bangumi first -> cross-rescue TMDB search.
      final bgmCandidates = await _collectBangumiCandidates(
        inventory,
        queries,
        bgmDetails,
      );
      bgmResult = WorkMatcher.bangumi(inventory, bgmCandidates);

      if (Metadata.credentials.isConfigured) {
        final tmdbCandidates = await _collectTmdbCandidates(
          inventory,
          queries,
          bgmResult,
          tmdbDetails,
        );
        tmdbResult = WorkMatcher.tmdb(
          inventory,
          tmdbCandidates,
          bangumi: bgmResult,
        );
      }

      if (bgmResult.tier == MatchTier.none && tmdbResult.candidate != null) {
        final tmdbWinner = tmdbResult.candidate!;
        final rescueQueries = <String>[
          tmdbWinner.title,
          ...tmdbWinner.aliases.take(2),
        ].where((s) => s.trim().isNotEmpty).toSet().toList();
        if (rescueQueries.isNotEmpty) {
          final extraBgm = await _collectBangumiCandidates(
            inventory,
            rescueQueries,
            bgmDetails,
            forceOnlineSearch: true,
          );
          if (extraBgm.isNotEmpty) {
            final merged = <int, MatchCandidate>{
              for (final c in bgmCandidates) c.id: c,
              for (final c in extraBgm) c.id: c,
            }.values.toList();
            bgmResult = WorkMatcher.bangumi(inventory, merged);
            if (Metadata.credentials.isConfigured && tmdbDetails.isNotEmpty) {
              tmdbResult = WorkMatcher.tmdb(inventory, [
                for (final entry in tmdbDetails.entries)
                  _tmdbCandidate(entry.key.split(':').first, entry.value),
              ], bangumi: bgmResult);
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

    return _buildResolvedWork(
      inventory: inventory,
      tmdbPick: tmdbPick,
      tmdbRaw: tmdbRaw,
      seasonDetail: seasonDetail,
      resolvedSeason: resolvedSeason,
      bgmPick: bgmPick,
      bgmRaw: bgmRaw,
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

  _ResolvedWork _buildResolvedWork({
    required DirectoryInventory inventory,
    required MatchCandidate? tmdbPick,
    required Map<String, dynamic>? tmdbRaw,
    required Map<String, dynamic>? seasonDetail,
    required int? resolvedSeason,
    required MatchCandidate? bgmPick,
    required Map<String, dynamic>? bgmRaw,
    required bool needsReview,
  }) {
    final lang = AppLanguage.instance.metadataLanguage;
    final tmdbPosterPath =
        (seasonDetail?['poster_path'] ?? tmdbRaw?['poster_path'])?.toString();
    final tmdbPoster = tmdbPosterPath != null && tmdbPosterPath.startsWith('/')
        ? MetadataServers.tmdbImage(tmdbPosterPath)
        : null;
    final bgmPoster = _bangumiImage(bgmRaw);

    final seasonOverview = seasonDetail?['overview']?.toString().trim();
    final tmdbOverview = tmdbRaw?['overview']?.toString().trim();
    final bgmOverview = AppLanguage.bangumiSynopsis(bgmRaw?['summary'], lang);

    String? overview;
    if (seasonOverview != null && seasonOverview.isNotEmpty) {
      overview = seasonOverview;
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

    final seasonYear = _parseYear(seasonDetail?['air_date']);
    final year =
        seasonYear ?? bgmPick?.year ?? tmdbPick?.year ?? inventory.year;

    final title = _chooseDisplayTitle(
      inventory: inventory,
      tmdbPick: tmdbPick,
      seasonDetail: seasonDetail,
      resolvedSeason: resolvedSeason,
      bgmPick: bgmPick,
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
      poster: tmdbPoster ?? bgmPoster,
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
  }) {
    if (tmdbPick == null) {
      return (bgmPick?.title.trim().isNotEmpty == true
          ? bgmPick!.title.trim()
          : inventory.title);
    }

    var baseTitle = tmdbPick.title.trim();
    if (!_hasCjk(baseTitle) &&
        bgmPick != null &&
        _hasCjk(bgmPick.title) &&
        resolvedSeason == null) {
      baseTitle = bgmPick.title.trim();
    }
    if (baseTitle.isEmpty) baseTitle = bgmPick?.title.trim() ?? inventory.title;

    if (tmdbPick.type != 'tv' || resolvedSeason == null) {
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

    final regularSeasons = tmdbPick.seasons.where((s) => s.number > 0).length;
    final needSeasonSuffix =
        regularSeasons > 1 || inventory.season != null || resolvedSeason > 1;
    if (!needSeasonSuffix) return baseTitle;

    // Preserve meaningful subtitle on sequel seasons (e.g. "新妹魔王的契约者 BURST 第2季")
    // while avoiding duplicate "第二季 第2季".
    if (resolvedSeason > 1 && bgmPick != null) {
      final bgmTitle = bgmPick.title.trim();
      final bgmExplicitSeason =
          CloudMediaAssetPresentation.explicitSeasonNumber({
            'work_title': bgmTitle,
          });
      if (bgmTitle.isNotEmpty &&
          bgmExplicitSeason == null &&
          DirectoryAnalyzer.normalize(bgmTitle) !=
              DirectoryAnalyzer.normalize(baseTitle) &&
          !RegExp(r'第\s*\d+\s*季').hasMatch(bgmTitle)) {
        return '$bgmTitle 第$resolvedSeason季';
      }
    }

    return '$baseTitle 第$resolvedSeason季';
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
      final stripped = WorkSeason.withoutPart(hint);
      if (stripped != hint) add(stripped);
    }
    for (final hint in inventory.fileHints.take(2)) {
      add(hint);
    }

    // Parent series folder hint (e.g. "动画-多作品/信长的忍者/信长的忍者 伊势·金崎篇").
    final parts = folder
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      final parent = parts[parts.length - 2]
          .replaceFirst(
            RegExp(r'\s*(?:系列|合集|Collection)$', caseSensitive: false),
            '',
          )
          .trim();
      if (!_isCategoryFolder(parent)) add(parent);
    }

    // Base franchise stem before subtitle separator (e.g. "全金属狂潮 校园篇" -> "全金属狂潮").
    for (final base in [...inventory.titleHints.take(2)]) {
      final split = base.split(RegExp(r'\s+|[:：～~—\-/]')).first.trim();
      if (split.length >= 2 &&
          split != base &&
          (_hasCjk(split) ? split.length >= 2 : split.length >= 4)) {
        add(split);
      }
    }

    return out.take(5).toList();
  }

  static bool _isCategoryFolder(String name) => RegExp(
    r'^(?:动画|番剧|电影|剧场版|动漫|影视|日漫|国漫|美漫|动画[-_]?单作品|动画[-_]?多作品|anime|movies?|tv|series|bdmv|bdrip|video|media|downloads?)$',
    caseSensitive: false,
  ).hasMatch(name.trim());

  Future<List<MatchCandidate>> _collectBangumiCandidates(
    DirectoryInventory inventory,
    List<String> queries,
    Map<int, Map<String, dynamic>> detailsOut, {
    bool forceOnlineSearch = false,
  }) async {
    final rawById = <int, Map<String, dynamic>>{};

    if (inventory.bangumiId != null) {
      final exact = await _fetchBangumiSubject(inventory.bangumiId!);
      if (exact != null) {
        rawById[inventory.bangumiId!] = exact;
        detailsOut[inventory.bangumiId!] = exact;
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
        } on ScanCancelled {
          rethrow;
        } catch (_) {
          if (rawById.isEmpty && !Metadata.credentials.isConfigured) rethrow;
        }
      }
    }

    if (rawById.isEmpty) return const [];

    // When offline index already settled a high-confidence winner, fetch only
    // that 1 subject's detail (poster + summary); otherwise check Top 4.
    final prelim = rawById.values.map(_bangumiCandidate).toList();
    final prelimMatch = WorkMatcher.bangumi(inventory, prelim);
    final detailLimit = prelimMatch.tier == MatchTier.high ? 1 : 4;
    final topIds = prelimMatch.ranking
        .take(detailLimit)
        .map((e) => e.candidate.id)
        .toList();
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
        } catch (_) {
          if (existing == null) rethrow;
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
    Map<String, Map<String, dynamic>> detailsOut,
  ) async {
    if (inventory.tmdbId != null) {
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
      return [
        for (final entry in detailsOut.entries)
          _tmdbCandidate(entry.key.split(':').first, entry.value),
      ];
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
      if (bgm.aliases.isNotEmpty) addQuery(bgm.aliases.first);
      final base = bgm.title.split(RegExp(r'\s+|[:：～~]')).first.trim();
      if (base.length >= 2) addQuery(base);
    }
    for (final q in localQueries) {
      addQuery(q);
    }

    final terms = searchQueries.take(3).toList();
    if (terms.isEmpty) return const [];

    final wantMovie =
        inventory.shape == WorkShape.feature || inventory.movieMarker;
    final rawHits = <String, Map<String, dynamic>>{};

    final tasks = <Future<void>>[];
    for (final term in terms) {
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

    // If TV search returned nothing on a series, also check movie once (e.g. theatrical/OVA split).
    if (rawHits.isEmpty && !wantMovie) {
      final movieRows = await _searchTmdb('movie', terms.first);
      for (final r in movieRows.take(4)) {
        final id = (r['id'] as num?)?.toInt();
        if (id != null) rawHits.putIfAbsent('movie:$id', () => r);
      }
    }

    if (rawHits.isEmpty) return const [];

    final prelim = [
      for (final entry in rawHits.entries)
        _tmdbCandidate(entry.key.split(':').first, entry.value),
    ];
    final ranked = [
      for (final c in prelim)
        (
          c,
          WorkMatcher.tmdb(inventory, [
                c,
              ], bangumi: bgmResult).ranking.firstOrNull?.score ??
              0,
        ),
    ]..sort((a, b) => b.$2.compareTo(a.$2));

    // Fetch full details (seasons + alternative_titles + translations) for Top 4.
    await Future.wait(
      ranked.take(4).map((item) async {
        final c = item.$1;
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
  }

  static MatchCandidate _bangumiCandidate(Map<String, dynamic> row) {
    final name = (row['name'] ?? '').toString().trim();
    final nameCn = (row['name_cn'] ?? '').toString().trim();
    final title = nameCn.isNotEmpty ? nameCn : name;
    final aliases = <String>[];
    if (name.isNotEmpty) aliases.add(name);
    if (nameCn.isNotEmpty && nameCn != name) aliases.add(nameCn);

    var year = _parseYear(row['date']);
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
        } else if (year == null &&
            (key.contains('放送开始') ||
                key.contains('上映年度') ||
                key.contains('发售日'))) {
          year = _parseYear(value);
        }
      }
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
      aliases: aliases,
      seasons: eps != null && eps > 0 ? [SeasonInfo(1, eps, year)] : const [],
    );
  }

  static MatchCandidate _tmdbCandidate(String type, Map<String, dynamic> row) {
    final title = (row['name'] ?? row['title'] ?? '').toString().trim();
    final original = (row['original_name'] ?? row['original_title'] ?? '')
        .toString()
        .trim();
    final year = _parseYear(
      type == 'movie' ? row['release_date'] : row['first_air_date'],
    );

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
        seasons.add(SeasonInfo(numVal, count, sYear));
        final sName = s['name']?.toString().trim() ?? '';
        if (sName.isNotEmpty && !_isGenericSeasonName(sName)) {
          addAlias(sName);
          if (title.isNotEmpty && !sName.contains(title)) {
            addAlias('$title $sName');
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
    final res = await _memoized(key, () async {
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
    });
    return res as Map<String, dynamic>?;
  }

  Future<List<Map<String, dynamic>>> _searchBangumi(String keyword) async {
    _check();
    final key = 'bgm:search:$keyword';
    final res = await _memoized(key, () async {
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
    });
    return res as List<Map<String, dynamic>>;
  }

  Future<Map<String, dynamic>?> _fetchBangumiSubject(int id) async {
    _check();
    final key = 'bgm:subject:$id';
    final res = await _memoized(key, () async {
      final response = await _client.get(
        Uri.parse('$bangumiBase/v0/subjects/$id'),
        headers: const {'User-Agent': _userAgent, 'Accept': 'application/json'},
      );
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) {
        throw StateError('Bangumi HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map && decoded['id'] == id
          ? Map<String, dynamic>.from(decoded)
          : null;
    });
    return res as Map<String, dynamic>?;
  }

  Future<bool> _saveResolvedWork(String workId, _ResolvedWork resolved) async {
    final rows = await _catalog.db.query(
      'works',
      where: 'id=?',
      whereArgs: [workId],
      limit: 1,
    );
    if (rows.isEmpty || rows.single['manual_lock'] == 1) return false;
    final old = rows.single;
    final sameIdentity =
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
      'tmdb_id': resolved.tmdbId ?? (sameIdentity ? old['tmdb_id'] : null),
      'tmdb_type':
          resolved.tmdbType ?? (sameIdentity ? old['tmdb_type'] : null),
      'bangumi_id': old['bangumi_link_info'] != null
          ? old['bangumi_id']
          : resolved.bangumiId ?? (sameIdentity ? old['bangumi_id'] : null),
      if (!sameIdentity &&
          old['bangumi_link_info'] == null &&
          old.containsKey('bangumi_ids'))
        'bangumi_ids': null,
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

enum _WorkOutcome { matched, adoptedForReview, unmatched, skipped }

class _ResolvedWork {
  const _ResolvedWork({
    required this.title,
    required this.provider,
    this.year,
    this.tmdbId,
    this.tmdbType,
    this.bangumiId,
    this.poster,
    this.bangumiPoster,
    this.overview,
    this.season,
    this.needsReview = false,
  });

  final String title, provider;
  final int? year, tmdbId, bangumiId, season;
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
