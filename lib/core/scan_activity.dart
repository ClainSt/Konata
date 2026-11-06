import 'package:flutter/foundation.dart';

enum ScanPhase { scanning, scraping, complete, cancelled, failed }

class ScanCancelled implements Exception {
  const ScanCancelled();
}

/// In-memory progress for each media source. Counts refer to VIDEO FILES,
/// not WebDAV response objects, archives, subtitle files or images.
class ScanActivity {
  ScanActivity(this.sourceId, this.selectedRoots) : startedAt = DateTime.now();

  final String sourceId;
  final List<String> selectedRoots;
  final DateTime startedAt;
  ScanPhase phase = ScanPhase.scanning;
  final Map<String, int> folderVideos = {};
  final Set<String> completedFolders = {};
  String? currentFolder, error;
  int videoCount = 0;
  int metadataTotal = 0, metadataProcessed = 0;
  int matched = 0, needsReview = 0, metadataErrors = 0;
  DateTime? finishedAt;
  bool cancelRequested = false;

  void checkCancelled() {
    if (cancelRequested) throw const ScanCancelled();
  }

  int videosUnder(String root) => folderVideos.entries
      .where((e) => root.isEmpty || e.key == root || e.key.startsWith('$root/'))
      .fold(0, (sum, e) => sum + e.value);
}

/// The app-bar indicator remains inspectable after scanning finishes.
/// No file paths are written to disk or sent to telemetry by this store.
class ScanActivityStore extends ChangeNotifier {
  ScanActivityStore._();
  static final instance = ScanActivityStore._();
  final Map<String, ScanActivity> _runs = {};
  ScanActivity? forSource(String sourceId) => _runs[sourceId];

  ScanActivity begin(String sourceId, List<String> roots) {
    final run = ScanActivity(sourceId, List.unmodifiable(roots));
    _runs[sourceId] = run;
    notifyListeners();
    return run;
  }

  void requestCancel(String sourceId) {
    final run = _runs[sourceId];
    if (run == null || run.finishedAt != null || run.cancelRequested) return;
    run.cancelRequested = true;
    notifyListeners();
  }

  void cancelled(String sourceId) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.phase = ScanPhase.cancelled;
    run.currentFolder = null;
    run.finishedAt = DateTime.now();
    notifyListeners();
  }

  void beginFolder(String sourceId, String path) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.currentFolder = path;
    run.folderVideos.putIfAbsent(path, () => 0);
    notifyListeners();
  }

  void video(String sourceId, String folder) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.folderVideos.update(folder, (n) => n + 1, ifAbsent: () => 1);
    run.videoCount++;
    // Avoid rebuilding the entire browser for every video in a large folder.
    if (run.videoCount % 10 == 0) notifyListeners();
  }

  void endFolder(String sourceId, String path) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.folderVideos.putIfAbsent(path, () => 0);
    run.completedFolders.add(path);
    run.currentFolder = null;
    notifyListeners();
  }

  void beginScraping(String sourceId, int total) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.phase = ScanPhase.scraping;
    run.currentFolder = null;
    run.metadataTotal = total;
    notifyListeners();
  }

  void metadataDone(
    String sourceId, {
    bool matched = false,
    bool review = false,
    bool error = false,
  }) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.metadataProcessed++;
    if (matched) run.matched++;
    if (review) run.needsReview++;
    if (error) run.metadataErrors++;
    notifyListeners();
  }

  void complete(String sourceId) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.phase = ScanPhase.complete;
    run.finishedAt = DateTime.now();
    notifyListeners();
  }

  void fail(String sourceId, String message) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.phase = ScanPhase.failed;
    run.error = message;
    run.finishedAt = DateTime.now();
    notifyListeners();
  }
}
