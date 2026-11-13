import 'dart:async';
import 'dart:collection';

import 'debug_log.dart';
import 'auto_classifier.dart';
import 'catalog.dart';
import 'library_foundation.dart';
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
  static final RegExp _excludedSegmentPattern = RegExp(
    r'^(?:'
    r'CDs?|Scans?|BKs?|Booklets?|Gallery|Galleries|Artworks?|Illustrations?|Wallpapers?|Jackets?|'
    r'特典\s*CD.*|ドラマ\s*CD.*|サウンドトラック.*|OSTs?|Soundtracks?|BGM|Character\s*Songs?|キャラソン.*|'
    r'絵コンテ.*|原画集?|設定資料.*|設定集|版権.*|台本.*|ブックレット.*|スキャン.*|掃圖.*|扫图.*|'
    r'Fonts?|字体.*|字體.*|Subs?|Subtitles?|字幕.*|'
    r'@eaDir|#recycle|\$RECYCLE\.BIN|System Volume Information|\.Trash.*'
    r')$',
    caseSensitive: false,
  );

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
    Map<String, Object?> source, {
    List<Map<String, Object?>>? savedRoots,
    void Function()? checkActive,
    Future<void> Function()? beforeFolder,
  }) async {
    final catalog = Catalog.instance;
    if (catalog.scanning) throw StateError('其他扫描仍在进行');
    final id = source['id'].toString();
    final locationRevision = catalog.foundationEnabled
        ? await LibraryFoundation.sourceRevision(catalog.db, id)
        : null;
    final roots = nonOverlappingRoots(savedRoots ?? catalog.rootsFor(id));
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
    WebDav? listingSession;
    final statusClock = Stopwatch()..start();
    var lastStatusMs = -1000;

    void reportFolderProgress(int folderCount) {
      final now = statusClock.elapsedMilliseconds;
      if (folderCount <= 2 || now - lastStatusMs >= 120) {
        lastStatusMs = now;
        catalog.updateStatus('已扫描 $folderCount 个目录，$count 个视频', true);
      }
    }

    var indexTail = Future<void>.value();
    Future<void> enqueueIndex(Future<void> Function() action) {
      final next = indexTail.then((_) => action());
      indexTail = next.catchError((_) {});
      return next;
    }

    try {
      final kind = source['kind']?.toString() ?? 'local';
      final localName = LocalMedia.label(source['location'].toString());
      if (kind == 'local') {
        final base = source['location'].toString();
        final concurrency = beforeFolder == null ? 4 : 1;

        Future<List<String>> processLocalFolder({
          required String root,
          required bool direct,
          required String relative,
          List<({String name, bool directory, int? size})>? cached,
        }) async {
          await beforeFolder?.call();
          run.checkCancelled();
          activity.beginFolder(id, relative);
          final entries =
              cached ?? await LocalMedia.list(base, relative, false);
          run.checkCancelled();
          final childDirs = <String>[];
          final videos =
              <({String relative, int? size, String folder, bool review})>[];
          for (final entity in entries) {
            run.checkCancelled();
            final name = entity.name;
            final childRel = relative.isEmpty ? name : '$relative/$name';
            if (excluded(childRel, root)) continue;
            if (entity.directory) {
              childDirs.add(childRel);
            } else if (Catalog.isVideo(entity.name)) {
              final decision = AutoClassifier.decide(
                relativePath: childRel,
                selectedRoot: root,
                rootHasDirectVideo: direct,
                localRootName: localName,
              );
              if (decision == null) continue;
              videos.add((
                relative: childRel,
                size: entity.size,
                folder: decision.folder,
                review: decision.needsReview,
              ));
            }
          }
          await enqueueIndex(() async {
            await catalog.indexVideos(
              id,
              videos,
              checkCancelled: () {
                run.checkCancelled();
                checkActive?.call();
              },
              expectedLocationRevision: locationRevision,
            );
            for (final video in videos) {
              scannedPaths.add(video.relative);
              activity.video(id, relative);
              if (video.review) reviewCount++;
              count++;
            }
            activity.endFolder(id, relative);
            reportFolderProgress(
              activity.forSource(id)?.completedFolders.length ?? 0,
            );
          });
          return childDirs;
        }

        for (final selected in roots) {
          run.checkCancelled();
          final root = selected['relative_path'].toString();
          await beforeFolder?.call();
          final first = await LocalMedia.list(base, root, false);
          final direct = first.any(
            (entry) => !entry.directory && Catalog.isVideo(entry.name),
          );
          final initialChildren = await processLocalFolder(
            root: root,
            direct: direct,
            relative: root,
            cached: first,
          );
          run.checkCancelled();
          if (initialChildren.isEmpty) continue;

          if (concurrency <= 1) {
            final stack = [...initialChildren];
            while (stack.isNotEmpty) {
              final nextRel = stack.removeLast();
              final sub = await processLocalFolder(
                root: root,
                direct: direct,
                relative: nextRel,
              );
              stack.addAll(sub);
            }
          } else {
            await _drainConcurrentQueue<String>(
              initial: initialChildren,
              concurrency: concurrency,
              checkCancelled: run.checkCancelled,
              visit: (rel) =>
                  processLocalFolder(root: root, direct: direct, relative: rel),
            );
          }
        }
      } else {
        final dav = listingSession = WebDav(
          await catalog.withCredentials(source),
          reuseListings: true,
        );
        final visited = <String>{};
        final concurrency = beforeFolder != null
            ? 1
            : (kind == 'webdav' ? 8 : 1);

        Future<List<({Uri uri, String relative})>> processRemoteFolder({
          required String root,
          required bool direct,
          required Uri uri,
          required String relative,
          List<DavEntry>? cached,
        }) async {
          await beforeFolder?.call();
          run.checkCancelled();
          if (!visited.add(uri.toString())) return const [];
          activity.beginFolder(id, relative);
          final entries = cached ?? await dav.list(uri);
          run.checkCancelled();
          final childDirs = <({Uri uri, String relative})>[];
          final videos =
              <({String relative, int? size, String folder, bool review})>[];
          for (final entry in entries) {
            run.checkCancelled();
            final childRel = relative.isEmpty
                ? entry.name
                : '$relative/${entry.name}';
            if (excluded(childRel, root)) continue;
            if (entry.isDirectory) {
              childDirs.add((uri: entry.uri, relative: childRel));
            } else if (Catalog.isVideo(entry.name)) {
              final decision = AutoClassifier.decide(
                relativePath: childRel,
                selectedRoot: root,
                rootHasDirectVideo: direct,
                localRootName: '',
              );
              if (decision == null) continue;
              videos.add((
                relative: childRel,
                size: entry.size,
                folder: decision.folder,
                review: decision.needsReview,
              ));
            }
          }
          await enqueueIndex(() async {
            await catalog.indexVideos(
              id,
              videos,
              checkCancelled: () {
                run.checkCancelled();
                checkActive?.call();
              },
              expectedLocationRevision: locationRevision,
            );
            for (final video in videos) {
              scannedPaths.add(video.relative);
              activity.video(id, relative);
              if (video.review) reviewCount++;
              count++;
            }
            activity.endFolder(id, relative);
            reportFolderProgress(visited.length);
          });
          return childDirs;
        }

        for (final selected in roots) {
          run.checkCancelled();
          final root = selected['relative_path'].toString();
          final rootUri = dav.directoryUri(root);
          await beforeFolder?.call();
          final first = await dav.list(rootUri);
          final direct = first.any(
            (entry) => !entry.isDirectory && Catalog.isVideo(entry.name),
          );
          final initialChildren = await processRemoteFolder(
            root: root,
            direct: direct,
            uri: rootUri,
            relative: root,
            cached: first,
          );
          run.checkCancelled();
          if (initialChildren.isEmpty) continue;

          if (concurrency <= 1) {
            final stack = [...initialChildren];
            while (stack.isNotEmpty) {
              final next = stack.removeLast();
              final sub = await processRemoteFolder(
                root: root,
                direct: direct,
                uri: next.uri,
                relative: next.relative,
              );
              stack.addAll(sub);
            }
          } else {
            await _drainConcurrentQueue<({Uri uri, String relative})>(
              initial: initialChildren,
              concurrency: concurrency,
              checkCancelled: run.checkCancelled,
              visit: (item) => processRemoteFolder(
                root: root,
                direct: direct,
                uri: item.uri,
                relative: item.relative,
              ),
            );
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
        await indexTail;
      } catch (_) {}
      try {
        await catalog.reload();
      } finally {
        activity.cancelled(id);
        catalog.updateStatus('扫描已取消');
      }
      rethrow;
    } catch (e) {
      try {
        await indexTail;
      } catch (_) {}
      DebugLog.write('Scan', 'failed ${e.runtimeType}', level: 'ERROR');
      activity.fail(id, '扫描失败：$e');
      catalog.updateStatus('扫描失败：$e');
      rethrow;
    } finally {
      listingSession?.close();
    }
  }

  static Future<void> _drainConcurrentQueue<T>({
    required List<T> initial,
    required int concurrency,
    required void Function() checkCancelled,
    required Future<List<T>> Function(T item) visit,
  }) async {
    final queue = Queue<T>.of(initial);
    var inFlight = 0;
    Object? firstError;
    StackTrace? firstStack;
    Completer<void>? signal;

    void wake() {
      final s = signal;
      if (s != null && !s.isCompleted) {
        signal = null;
        s.complete();
      }
    }

    Future<void> worker() async {
      while (firstError == null) {
        if (queue.isEmpty) {
          if (inFlight == 0) {
            wake();
            return;
          }
          signal ??= Completer<void>();
          await signal!.future;
          continue;
        }
        try {
          checkCancelled();
        } catch (e, st) {
          firstError ??= e;
          firstStack ??= st;
          wake();
          return;
        }
        final item = queue.removeFirst();
        inFlight++;
        try {
          final children = await visit(item);
          if (firstError == null && children.isNotEmpty) {
            queue.addAll(children);
          }
        } catch (e, st) {
          firstError ??= e;
          firstStack ??= st;
        } finally {
          inFlight--;
          wake();
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }

  static bool excluded(String relative, String selectedRoot) {
    final normalizedRel = relative.replaceAll('\\', '/');
    final normalizedRoot = selectedRoot.replaceAll('\\', '/');
    final rest = normalizedRoot.isEmpty
        ? normalizedRel
        : normalizedRel
              .substring(normalizedRoot.length)
              .replaceFirst(RegExp(r'^/+'), '');
    if (rest.isEmpty) return false;
    for (final rawPart in rest.split('/')) {
      final trimmed = rawPart
          .trim()
          .replaceFirst(RegExp(r'^[\[\(【（]\s*'), '')
          .replaceFirst(RegExp(r'\s*[\]\)】）]$'), '')
          .trim();
      if (trimmed.isNotEmpty && _excludedSegmentPattern.hasMatch(trimmed)) {
        return true;
      }
    }
    return false;
  }
}
