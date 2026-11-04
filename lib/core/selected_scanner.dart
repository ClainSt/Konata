import 'dart:io';
import 'package:path/path.dart' as p;

import 'auto_classifier.dart';
import 'catalog.dart';
import 'sources.dart';

/// Read-only scanner of user-selected trees. File-to-work grouping is
/// inferred from directory metadata and file placement, never a manual mode.
class SelectedScanner {
  static Future<int> scan(Map<String, Object?> source) async {
    final catalog = Catalog.instance;
    if (catalog.scanning) throw StateError('其他扫描仍在进行');
    final id = source['id'].toString();
    final roots = catalog.rootsFor(id);
    if (roots.isEmpty) throw StateError('请先在“浏览目录”中勾选刮削文件夹');
    catalog.updateStatus('正在自动识别已选目录…', true);
    var count = 0;
    var reviewCount = 0;
    try {
      final localName = p.basename(p.normalize(source['location'].toString()));
      if (source['kind'] == 'local') {
        final base = Directory(source['location'].toString());
        for (final selected in roots) {
          final relative = selected['relative_path'].toString();
          final folder = Directory(
            relative.isEmpty
                ? base.path
                : p.joinAll([base.path, ...relative.split('/')]),
          );
          if (!await folder.exists()) {
            throw FileSystemException('已选文件夹不存在', folder.path);
          }
          final direct = await folder
              .list(followLinks: false)
              .any((entity) => entity is File && Catalog.isVideo(entity.path));
          await for (final item in folder.list(
            recursive: true,
            followLinks: false,
          )) {
            if (item is! File || !Catalog.isVideo(item.path)) continue;
            final file = p
                .relative(item.path, from: base.path)
                .replaceAll('\\', '/');
            if (_excluded(file, relative)) continue;
            final decision = AutoClassifier.decide(
              relativePath: file,
              selectedRoot: relative,
              rootHasDirectVideo: direct,
              localRootName: localName,
            );
            if (decision == null) continue;
            await catalog.indexVideo(
              id,
              file,
              (await item.stat()).size,
              workFolder: decision.folder,
              needsReview: decision.needsReview,
            );
            if (decision.needsReview) reviewCount++;
            if (++count % 100 == 0) {
              catalog.updateStatus('已识别 $count 个视频（需复核 $reviewCount）', true);
            }
          }
        }
      } else {
        final dav = WebDav(await catalog.withCredentials(source));
        for (final selected in roots) {
          final root = selected['relative_path'].toString();
          final rootUri = dav.directoryUri(root);
          // Inspect this root first to distinguish a single anime with
          // video files at its root from a collection of child directories.
          final first = await dav.list(rootUri);
          final direct = first.any(
            (entry) => !entry.isDirectory && Catalog.isVideo(entry.name),
          );
          final pending =
              <({Uri uri, String relative, List<DavEntry>? cached})>[
                (uri: rootUri, relative: root, cached: first),
              ];
          final visited = <String>{};
          while (pending.isNotEmpty) {
            final current = pending.removeLast();
            if (!visited.add(current.uri.toString())) continue;
            final entries = current.cached ?? await dav.list(current.uri);
            for (final entry in entries) {
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
                await catalog.indexVideo(
                  id,
                  relative,
                  entry.size,
                  workFolder: decision.folder,
                  needsReview: decision.needsReview,
                );
                if (decision.needsReview) reviewCount++;
                if (++count % 100 == 0) {
                  catalog.updateStatus(
                    '已识别 $count 个视频（需复核 $reviewCount）',
                    true,
                  );
                }
              }
            }
          }
        }
      }
      await catalog.pruneOrphanedWorks();
      catalog.updateStatus('扫描完成：$count 个视频，$reviewCount 个文件需要复核');
      return count;
    } catch (e) {
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
