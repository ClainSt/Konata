import 'dart:io';
import 'package:path/path.dart' as p;
import 'catalog.dart';
import 'sources.dart';

/// Scans only user-selected directories. A selection is either a single work
/// or a collection whose immediate subdirectories each represent one work.
class SelectedScanner {
  static String? workFolderFor({
    required String relativePath,
    required String selectedRoot,
    required String mode,
    String? localRootName,
  }) {
    final file = Catalog.normalizeRoot(relativePath);
    final root = Catalog.normalizeRoot(selectedRoot);
    final prefix = root.isEmpty ? '' : '$root/';
    if (!file.startsWith(prefix) || !Catalog.isVideo(file)) return null;
    if (mode == 'work') {
      return root.isNotEmpty ? root : localRootName;
    }
    if (mode != 'collection') throw ArgumentError.value(mode, 'mode');
    final remainder = file.substring(prefix.length).split('/');
    if (remainder.length < 2 || remainder.first.isEmpty) return null;
    final first = remainder.first;
    if (RegExp(r'^(CDs?|Scans?|SPs?)$', caseSensitive: false).hasMatch(first)) {
      return null;
    }
    return root.isEmpty ? first : '$root/$first';
  }

  static Future<int> scan(Map<String, Object?> source) async {
    final catalog = Catalog.instance;
    if (catalog.scanning) throw StateError('其他扫描仍在进行');
    final id = source['id'].toString();
    final roots = catalog.rootsFor(id);
    if (roots.isEmpty) throw StateError('请先在“浏览目录”中选择刮削文件夹');
    catalog.updateStatus('正在扫描已选目录…', true);
    var count = 0;
    try {
      final localName = p.basename(p.normalize(source['location'].toString()));
      if (source['kind'] == 'local') {
        final base = Directory(source['location'].toString());
        for (final selected in roots) {
          final relative = selected['relative_path'].toString();
          final mode = selected['mode'].toString();
          final folder = Directory(
            relative.isEmpty
                ? base.path
                : p.joinAll([base.path, ...relative.split('/')]),
          );
          if (!await folder.exists()) {
            throw FileSystemException('已选文件夹不存在', folder.path);
          }
          await for (final item in folder.list(
            recursive: true,
            followLinks: false,
          )) {
            if (item is! File || !Catalog.isVideo(item.path)) continue;
            final file = p
                .relative(item.path, from: base.path)
                .replaceAll('\\', '/');
            if (_excluded(file, relative)) continue;
            final work = workFolderFor(
              relativePath: file,
              selectedRoot: relative,
              mode: mode,
              localRootName: localName,
            );
            if (work == null) continue;
            await catalog.indexVideo(
              id,
              file,
              (await item.stat()).size,
              workFolder: work,
            );
            if (++count % 100 == 0) {
              catalog.updateStatus('已索引 $count 个视频', true);
            }
          }
        }
      } else {
        final dav = WebDav(await catalog.withCredentials(source));
        for (final selected in roots) {
          final root = selected['relative_path'].toString();
          final mode = selected['mode'].toString();
          final pending = <({Uri uri, String relative})>[
            (uri: dav.directoryUri(root), relative: root),
          ];
          final visited = <String>{};
          while (pending.isNotEmpty) {
            final current = pending.removeLast();
            if (!visited.add(current.uri.toString())) continue;
            final entries = await dav.list(current.uri);
            for (final entry in entries) {
              final relative = current.relative.isEmpty
                  ? entry.name
                  : '${current.relative}/${entry.name}';
              if (_excluded(relative, root)) continue;
              if (entry.isDirectory) {
                pending.add((uri: entry.uri, relative: relative));
              } else if (Catalog.isVideo(entry.name)) {
                final work = workFolderFor(
                  relativePath: relative,
                  selectedRoot: root,
                  mode: mode,
                );
                if (work == null) continue;
                await catalog.indexVideo(
                  id,
                  relative,
                  entry.size,
                  workFolder: work,
                );
                if (++count % 100 == 0) {
                  catalog.updateStatus('已索引 $count 个视频', true);
                }
              }
            }
          }
        }
      }
      await catalog.reload();
      catalog.updateStatus('扫描完成：$count 个视频');
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
