import 'debug_log.dart';
import 'catalog.dart';
import 'scan_activity.dart';
import 'personal_scraper.dart';
import 'work_season.dart';

/// Bounded, read-only metadata workflow. Can retry scraping without
/// repeating a WebDAV filesystem traversal.
class PersonalScrapeCoordinator {
  PersonalScrapeCoordinator({
    Catalog? catalog,
    PersonalMetadataScraper? scraper,
  }) : _catalog = catalog ?? Catalog.instance,
       _scraper = scraper ?? PersonalMetadataScraper(),
       _ownsScraper = scraper == null;
  final Catalog _catalog;
  final PersonalMetadataScraper _scraper;
  final bool _ownsScraper;

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
    int matched = 0, skipped = 0, review = 0, errors = 0, attempted = 0;
    // One linear pass, instead of scanning the entire asset list per title.
    final assetsByWork = <String, List<Map<String, Object?>>>{};
    for (final asset in _catalog.assets) {
      (assetsByWork[asset['work_id'].toString()] ??= []).add(asset);
    }
    _scraper.checkCancelled = run?.checkCancelled;
    var running = true;
    run?.cancelled.then((_) {
      if (running && _ownsScraper) _scraper.close();
    });
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
    ScanActivityStore.instance.beginScraping(sourceId, targets.length);
    _catalog.updateStatus('准备刮削 ${targets.length} 部作品（TMDB / Bangumi）', true);
    Future<void> process(Map<String, Object?> work) async {
      run?.checkCancelled();
      attempted++;
      _catalog.updateStatus(
        '正在刮削 $attempted / ${targets.length}：${work['title']}',
        true,
      );
      try {
        final assets = assetsByWork[work['id'].toString()] ?? [];
        final main = assets
            .where(
              (a) => a['category'] == 'main' && a['manual_mapping'] != true,
            )
            .toList();
        final decisions = await _scraper.classify(work, main);
        final candidates = decisions.values.whereType<ScrapedWork>().toList();
        final uniform =
            candidates.isNotEmpty &&
            candidates.length == main.length &&
            candidates.every(
              (c) =>
                  c.sameWork(candidates.first) &&
                  c.title == candidates.first.title,
            );
        final extras = assets
            .where(
              (a) => a['category'] != 'main' && a['manual_mapping'] != true,
            )
            .toList();
        if (extras.isNotEmpty) {
          decisions.addAll(
            await _scraper.classify(
              work,
              extras,
              unnamedFallback: uniform ? candidates.first : null,
            ),
          );
        }
        run?.checkCancelled();
        final complete = await _catalog.applyClassification(
          work['id'].toString(),
          decisions,
        );
        if (!complete ||
            decisions.isEmpty ||
            decisions.values.any((value) => value == null)) {
          DebugLog.write(
            'Scrape',
            'ambiguous or unmatched; manual confirmation required',
          );
          review++;
          ScanActivityStore.instance.metadataDone(sourceId, review: true);
          return;
        }
        if (decisions.isNotEmpty) {
          DebugLog.write('Scrape', 'classified files=${decisions.length}');
          matched++;
          ScanActivityStore.instance.metadataDone(sourceId, matched: true);
        } else {
          skipped++;
          ScanActivityStore.instance.metadataDone(sourceId);
        }
      } on ScanCancelled {
        rethrow;
      } catch (e) {
        run?.checkCancelled();
        DebugLog.write('Scrape', 'failed ${e.runtimeType}', level: 'WARN');
        errors++;
        ScanActivityStore.instance.metadataDone(sourceId, error: true);
      }
    }

    try {
      final batchTargets = limit == null
          ? targets
          : targets.take(limit < 0 ? 0 : limit).toList();
      // Two work identities at once; all HTTP still shares the six-request
      // global budget with visible artwork. No queue of thousands of futures.
      for (var offset = 0; offset < batchTargets.length; offset += 2) {
        run?.checkCancelled();
        await Future.wait(batchTargets.skip(offset).take(2).map(process));
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
      _scraper.checkCancelled = null;
      if (_ownsScraper) _scraper.close();
      await _catalog.reload();
      if (_catalog.scanning) _catalog.updateStatus(_catalog.status);
    }
  }
}
