import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Local filesystem paths and user-granted Android document trees.
/// Documents are streamed through media_kit's existing content URI support.
abstract final class LocalMedia {
  static const channel = MethodChannel('ccplayer/local_media');
  static bool isDocumentTree(String root) => root.startsWith('content://');

  static String label(String root) => isDocumentTree(root)
      ? Uri.parse(root).pathSegments.last.split('/').last.split(':').last
      : p.basename(p.normalize(root));

  static void validateRelative(String relative) {
    if (relative.startsWith('/') ||
        relative.contains('\\') ||
        relative.split('/').any((s) => s == '..' || s == '.')) {
      throw const FormatException('Invalid relative media path');
    }
  }

  static Future<List<({String name, bool directory, int? size})>> list(
    String root, [
    String relative = '',
  ]) async {
    validateRelative(relative);
    if (isDocumentTree(root)) {
      final entries = await channel.invokeListMethod<Object?>('list', {
        'root': root,
        'relative': relative,
      });
      if (entries == null) {
        throw const FileSystemException('Folder unavailable');
      }
      return entries.map((entry) {
        final value = entry as Map;
        return (
          name: value['name'] as String,
          directory: value['directory'] as bool,
          size: value['size'] as int?,
        );
      }).toList();
    }
    final directory = Directory(
      relative.isEmpty ? root : p.joinAll([root, ...relative.split('/')]),
    );
    final entries = <({String name, bool directory, int? size})>[];
    await for (final item in directory.list(followLinks: false)) {
      if (item is! File && item is! Directory) continue;
      entries.add((
        name: p.basename(item.path),
        directory: item is Directory,
        size: item is File ? (await item.stat()).size : null,
      ));
    }
    return entries;
  }

  static Future<String> uri(String root, String relative) async {
    validateRelative(relative);
    if (!isDocumentTree(root)) return p.joinAll([root, ...relative.split('/')]);
    final uri = await channel.invokeMethod<String>('resolve', {
      'root': root,
      'relative': relative,
    });
    if (uri == null) throw const FileSystemException('Media unavailable');
    return uri;
  }
}
