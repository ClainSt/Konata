import 'catalog.dart';
import 'personal_scrape_coordinator.dart';
import 'personal_scraper.dart';
import 'scan_activity.dart';
import 'selected_scanner.dart';

/// Runs read-only file indexing followed by TMDB/Bangumi metadata scraping.
/// The user's temporary folder selections are cleared only after indexing
/// succeeds. UI progress stays accessible throughout both stages.
class SelectedScanWorkflow {
  static Future<void> run(
    Map<String, Object?> source, {
    PersonalMetadataScraper? scraper,
  }) async {
    final sourceId = source['id'].toString();
    final catalog = Catalog.instance;
    final store = ScanActivityStore.instance;
    final result = await SelectedScanner.scanDetailed(source);
    await catalog.clearScanRoots(sourceId);
    try {
      // Restrict metadata requests to work IDs actually seen in this scan.
      await PersonalScrapeCoordinator(
        scraper: scraper,
      ).scrapeSource(sourceId, workIds: result.workIds, onlyPending: true);
      store.complete(sourceId);
    } catch (e) {
      // Scanned media remain indexed even when the optional provider is down.
      store.fail(sourceId, '文件扫描成功，但自动刮削失败：$e');
      catalog.updateStatus('文件扫描成功，元数据刮削失败：$e');
    }
  }
}
