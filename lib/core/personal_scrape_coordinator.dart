import 'catalog.dart';
import 'personal_scraper.dart';

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
  }) async {
    if (_catalog.scanning) throw StateError('当前正在扫描或刮削，请勿同时启动');
    final works = _catalog.works
        .where((w) => w['id']?.toString().startsWith('work:$sourceId:') == true)
        .toList();
    int matched = 0, skipped = 0, review = 0, errors = 0, attempted = 0;
    final targets = works.where((w) {
      if (w['manual_lock'] == 1) return false;
      final poster = w['poster']?.toString().trim() ?? '';
      return !onlyPending || poster.isEmpty || w['needs_review'] == 1;
    }).toList();
    _catalog.updateStatus('准备刮削 ${targets.length} 部作品（TMDB / Bangumi）', true);
    try {
      for (final work in targets) {
        if (limit != null && attempted >= limit) break;
        attempted++;
        _catalog.updateStatus(
          '正在刮削 $attempted / ${targets.length}：${work['title']}',
          true,
        );
        try {
          final filenames = _catalog
              .forWork(work['id'].toString())
              .where((a) => a['category'] == 'main')
              .map((a) => a['name']?.toString() ?? '')
              .where((e) => e.isNotEmpty)
              .take(6)
              .toList();
          final candidate = await _scraper.scrape(work, filenames: filenames);
          if (candidate == null) {
            review++;
            continue;
          }
          if (await _catalog.applyScrapedWork(
            work['id'].toString(),
            candidate,
            reloadAfter: false,
          )) {
            matched++;
          } else {
            skipped++;
          }
        } catch (_) {
          errors++;
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
      if (_ownsScraper) _scraper.close();
      if (_catalog.scanning) _catalog.updateStatus(_catalog.status);
    }
  }
}
