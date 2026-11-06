import 'catalog.dart';
import 'personal_scrape_coordinator.dart';
import 'personal_scraper.dart';
import 'scan_activity.dart';
import 'selected_scanner.dart';

/// Runs read-only file indexing followed by TMDB/Bangumi metadata scraping.
/// The user's temporary folder selections are cleared only after indexing
/// and scraping finish. UI progress stays accessible throughout both stages.
class SelectedScanWorkflow {
  // Indexing and metadata are one job, including asynchronous transitions.
  static bool _running = false;

  static Future<void> run(
    Map<String, Object?> source, {
    PersonalMetadataScraper? scraper,
  }) async {
    if (_running) throw StateError('其他扫描仍在进行');
    _running = true;
    final sourceId = source['id'].toString();
    final catalog = Catalog.instance;
    final store = ScanActivityStore.instance;
    try {
      final result = await SelectedScanner.scanDetailed(source);
      final run = store.forSource(sourceId)!;
      try {
        run.checkCancelled();
        await PersonalScrapeCoordinator(scraper: scraper).scrapeSource(
          sourceId,
          workIds: result.workIds,
          onlyPending: true,
          run: run,
        );
        run.checkCancelled();
        await catalog.clearScanRoots(sourceId);
        store.complete(sourceId);
      } on ScanCancelled {
        // Completed index writes remain usable, and selections remain available for retry.
        try {
          await catalog.reload();
        } finally {
          store.cancelled(sourceId);
          catalog.updateStatus('扫描已取消');
        }
      } catch (e) {
        store.fail(sourceId, '文件扫描成功，但自动刮削失败：$e');
        catalog.updateStatus('文件扫描成功，元数据刮削失败：$e');
      }
    } on ScanCancelled {
      // The indexing stage has already released its busy state and recorded cancellation.
      return;
    } finally {
      _running = false;
    }
  }
}
