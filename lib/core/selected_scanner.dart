import 'debug_log.dart';
import 'auto_classifier.dart';
import 'catalog.dart';
import 'scan_activity.dart';
import 'sources.dart';
import 'local_media.dart';

class SelectedScanResult {
  const SelectedScanResult(this.videoCount, this.workIds);
  final int videoCount;
  final Set<String> workIds;
}

/// Read-only selected-root scanner. Per-directory direct video counts are
/// available in the progress inspector, including folders with zero videos.
class SelectedScanner {
  /// A parent selection already includes its descendants. Scan it once even
  /// when the UI has temporarily selected both parent and child directories.
  static List<Map<String, Object?>> nonOverlappingRoots(
    List<Map<String, Object?>> selected,
  ) {
    String path(Map<String, Object?> row) => row['relative_path']
        .toString()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final sorted = [...selected]
      ..sort((a, b) => path(a).length.compareTo(path(b).length));
    final result = <Map<String, Object?>>[];
    for (final root in sorted) {
      final child = path(root);
      if (result.any((item) {
        final parent = path(item);
        return parent.isEmpty ||
            child == parent ||
            child.startsWith('$parent/');
      })) {
        continue;
      }
      result.add(root);
    }
    return result;
  }

  static Future<int> scan(Map<String, Object?> source) async =>
      (await scanDetailed(source)).videoCount;

  static Future<SelectedScanResult> scanDetailed(
    Map<String, Object?> source,
  ) async {
    final catalog = Catalog.instance;
    if (catalog.scanning) throw StateError('其他扫描仍在进行');
    final id = source['id'].toString();
    final roots = nonOverlappingRoots(catalog.rootsFor(id));
    if (roots.isEmpty) throw StateError('请先在“浏览目录”中勾选刮削文件夹');
    final activity = ScanActivityStore.instance;
    final run = activity.begin(
      id,
      roots.map((r) => r['relative_path'].toString()).toList(),
    );
    catalog.updateStatus('正在扫描已选目录', true);
    DebugLog.write(
      'Scan',
      'begin kind=${source['kind']} roots=${roots.length}',
    );
    var count = 0, reviewCount = 0;
    final scannedPaths = <String>{};
    try {
      final localName = LocalMedia.label(source['location'].toString());
      if (source['kind'] == 'local') {
        final base = source['location'].toString();
        for (final selected in roots) {
          run.checkCancelled();
          final root = selected['relative_path'].toString();
          final first = await LocalMedia.list(base, root);
          final direct = first.any(
            (entry) => !entry.directory && Catalog.isVideo(entry.name),
          );
          final pending =
              <
                ({
                  String relative,
                  List<({String name, bool directory, int? size})>? cached,
                })
              >[(relative: root, cached: first)];
          while (pending.isNotEmpty) {
            run.checkCancelled();
            final current = pending.removeLast();
            activity.beginFolder(id, current.relative);
            final entries =
                current.cached ?? await LocalMedia.list(base, current.relative);
            final videos =
                <({String relative, int? size, String folder, bool review})>[];
            for (final entity in entries) {
              run.checkCancelled();
              final name = entity.name;
              final relative = current.relative.isEmpty
                  ? name
                  : '${current.relative}/$name';
              if (_excluded(relative, root)) continue;
              if (entity.directory) {
                pending.add((relative: relative, cached: null));
              } else if (Catalog.isVideo(entity.name)) {
                final decision = AutoClassifier.decide(
                  relativePath: relative,
                  selectedRoot: root,
                  rootHasDirectVideo: direct,
                  localRootName: localName,
                );
                if (decision == null) continue;
                videos.add((
                  relative: relative,
                  size: entity.size,
                  folder: decision.folder,
                  review: decision.needsReview,
                ));
              }
            }
            await catalog.indexVideos(
              id,
              videos,
              checkCancelled: run.checkCancelled,
            );
            for (final video in videos) {
              scannedPaths.add(video.relative);
              activity.video(id, current.relative);
              if (video.review) reviewCount++;
              count++;
            }
            activity.endFolder(id, current.relative);
            catalog.updateStatus(
              '已扫描 ${activity.forSource(id)?.completedFolders.length ?? 0} 个目录，$count 个视频',
              true,
            );
          }
        }
      } else {
        final dav = WebDav(await catalog.withCredentials(source));
        final visited = <String>{};
        for (final selected in roots) {
          run.checkCancelled();
          final root = selected['relative_path'].toString();
          final rootUri = dav.directoryUri(root);
          final first = await dav.list(rootUri);
          final direct = first.any(
            (entry) => !entry.isDirectory && Catalog.isVideo(entry.name),
          );
          final pending =
              <({Uri uri, String relative, List<DavEntry>? cached})>[
                (uri: rootUri, relative: root, cached: first),
              ];
          while (pending.isNotEmpty) {
            run.checkCancelled();
            final current = pending.removeLast();
            if (!visited.add(current.uri.toString())) continue;
            activity.beginFolder(id, current.relative);
            final entries = current.cached ?? await dav.list(current.uri);
            final videos =
                <({String relative, int? size, String folder, bool review})>[];
            for (final entry in entries) {
              run.checkCancelled();
              final relative = current.relative.isEmpty
                  ? entry.name
                  : '${current.relative}/${entry.name}';
              if (_excluded(relative, root)) continue;
              if (entry.isDirectory) {
                pending.add((uri: entry.uri, relative: relative, cached: null));
              } else if (Catalog.isVideo(entry.name)) {
                final decision = AutoClassifier.decide(
                  relativePath: relative,
                  selectedRoot: root,
                  rootHasDirectVideo: direct,
                  localRootName: '',
                );
                if (decision == null) continue;
                videos.add((
                  relative: relative,
                  size: entry.size,
                  folder: decision.folder,
                  review: decision.needsReview,
                ));
              }
            }
            await catalog.indexVideos(
              id,
              videos,
              checkCancelled: run.checkCancelled,
            );
            for (final video in videos) {
              scannedPaths.add(video.relative);
              activity.video(id, current.relative);
              if (video.review) reviewCount++;
              count++;
            }
            activity.endFolder(id, current.relative);
            catalog.updateStatus('已扫描 ${visited.length} 个目录，$count 个视频', true);
          }
        }
      }
      run.checkCancelled();
      await catalog.pruneOrphanedWorks();
      await catalog.reload();
      final works = catalog.assets
          .where(
            (a) =>
                a['source_id'] == id &&
                scannedPaths.contains(a['relative_path']),
          )
          .map((a) => a['work_id']?.toString())
          .whereType<String>()
          .toSet();
      catalog.updateStatus('扫描完成：$count 个视频，$reviewCount 个文件需要复核');
      DebugLog.write(
        'Scan',
        'complete files=$count works=${works.length} review=$reviewCount',
      );
      return SelectedScanResult(count, works);
    } on ScanCancelled {
      try {
        await catalog.reload();
      } finally {
        activity.cancelled(id);
        catalog.updateStatus('扫描已取消');
      }
      rethrow;
    } catch (e) {
      DebugLog.write('Scan', 'failed ${e.runtimeType}', level: 'ERROR');
      activity.fail(id, '扫描失败：$e');
      catalog.updateStatus('扫描失败：$e');
      rethrow;
    }
  }

  static bool _excluded(String relative, String selectedRoot) {
    final rest = selectedRoot.isEmpty
        ? relative
        : relative
              .substring(selectedRoot.length)
              .replaceFirst(RegExp(r'^/'), '');
    return rest
        .split('/')
        .any(
          (part) =>
              RegExp(r'^(CDs?|Scans?)$', caseSensitive: false).hasMatch(part),
        );
  }
}
