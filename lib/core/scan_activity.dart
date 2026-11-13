import 'package:flutter/foundation.dart';
import 'dart:async';

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
  final _cancelled = Completer<void>();
  Future<void> get cancelled => _cancelled.future;
  void cancel() {
    cancelRequested = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

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
  final Stopwatch _clock = Stopwatch()..start();
  int _lastNotifyMicros = -1000000;
  static const int _minIntervalMicros = 80000;

  ScanActivity? forSource(String sourceId) => _runs[sourceId];

  void _notifyNow() {
    _lastNotifyMicros = _clock.elapsedMicroseconds;
    notifyListeners();
  }

  void _notifyThrottled({bool force = false}) {
    final now = _clock.elapsedMicroseconds;
    if (force || now - _lastNotifyMicros >= _minIntervalMicros) {
      _lastNotifyMicros = now;
      notifyListeners();
    }
  }

  ScanActivity begin(String sourceId, List<String> roots) {
    final run = ScanActivity(sourceId, List.unmodifiable(roots));
    _runs[sourceId] = run;
    _notifyNow();
    return run;
  }

  void requestCancel(String sourceId) {
    final run = _runs[sourceId];
    if (run == null || run.finishedAt != null || run.cancelRequested) return;
    run.cancel();
    _notifyNow();
  }

  void cancelled(String sourceId) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.phase = ScanPhase.cancelled;
    run.currentFolder = null;
    run.finishedAt = DateTime.now();
    _notifyNow();
  }

  void beginFolder(String sourceId, String path) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.currentFolder = path;
    run.folderVideos.putIfAbsent(path, () => 0);
    _notifyThrottled(force: run.completedFolders.length < 2);
  }

  void restoreFolders(String sourceId, Map<String, int> folders) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.completedFolders.addAll(folders.keys);
    run.folderVideos.addAll(folders);
    run.videoCount = folders.values.fold(0, (total, count) => total + count);
    _notifyNow();
  }

  void video(String sourceId, String folder) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.folderVideos.update(folder, (n) => n + 1, ifAbsent: () => 1);
    run.videoCount++;
    if (run.videoCount % 10 == 0) _notifyThrottled();
  }

  void endFolder(String sourceId, String path) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.folderVideos.putIfAbsent(path, () => 0);
    run.completedFolders.add(path);
    if (run.currentFolder == path) run.currentFolder = null;
    _notifyThrottled(force: run.completedFolders.length <= 2);
  }

  void beginScraping(String sourceId, int total) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.phase = ScanPhase.scraping;
    run.currentFolder = null;
    run.metadataTotal = total;
    _notifyNow();
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
    _notifyThrottled(
      force:
          run.metadataProcessed <= 2 ||
          run.metadataProcessed >= run.metadataTotal,
    );
  }

  void complete(String sourceId) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.phase = ScanPhase.complete;
    run.finishedAt = DateTime.now();
    _notifyNow();
  }

  void fail(String sourceId, String message) {
    final run = _runs[sourceId];
    if (run == null) return;
    run.phase = ScanPhase.failed;
    run.error = message;
    run.finishedAt = DateTime.now();
    _notifyNow();
  }
}
