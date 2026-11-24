import 'dart:io';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import '../../domain/playback/subtitle_and_audio_choices.dart';

/// 外挂字幕匹配回调签名（可由上层注入 `engine_sources` 的完整 `SubtitleMatcher`）。
typedef ExternalSubtitleMatchFn =
    List<String> Function({
      required String videoRelativePath,
      required List<String> allSubtitlePaths,
    });

/// 本地附属目录列举、安全路径解析与内置轻量字幕匹配助手（零跨引擎源码耦合）。
abstract final class PlaybackSidecarHelpers {
  static final RegExp _trailingLangBracket = RegExp(
    r'[\s._\-]*[\[(【](?:chs|cht|sc|tc|gb|big5|jpn?|eng?|jpsc|jptc|zh[-_]?(?:cn|tw|hk|hans|hant)|chs&jpn|cht&jpn|sc&jp|tc&jp|bilingual|简日|繁日|简体|繁体|双语|雙語|default|forced)[\])】]\s*$',
    caseSensitive: false,
  );

  static final RegExp _trailingLangSuffix = RegExp(
    r'(?:[\s._\-]+(?:chs|cht|sc|tc|gb|big5|jpn?|jap|eng?|jpsc|jptc|chs&jpn|cht&jpn|sc&jp|tc&jp|zh[-_]?(?:cn|tw|hk|hans|hant)|default|forced))+\s*$',
    caseSensitive: false,
  );

  /// 将媒体源内的相对路径安全解析为根目录内的物理绝对路径，严防 `..` 路径穿越。
  static String resolveLocalSafePath(String rootPath, String relativePath) {
    final normalizedRoot = p.normalize(p.absolute(rootPath));
    final cleanRel = relativePath.trim().replaceAll('\\', '/');
    final segments = cleanRel
        .split('/')
        .where((s) => s.isNotEmpty && s != '.')
        .toList(growable: false);
    if (segments.any((s) => s == '..')) {
      throw ArgumentError.value(relativePath, 'relativePath', '禁止跨目录穿越访问');
    }
    final joined = segments.isEmpty
        ? normalizedRoot
        : p.normalize(p.joinAll(<String>[normalizedRoot, ...segments]));
    if (joined != normalizedRoot && !p.isWithin(normalizedRoot, joined)) {
      throw ArgumentError.value(relativePath, 'relativePath', '目标路径越出本地媒体源根目录');
    }
    return joined;
  }

  /// 列举本地媒体源相对子目录下的直接文件与目录条目（仅限只读遍历）。
  static Future<List<RemoteEntry>> listLocalDirectory(
    String rootPath,
    String dirRelativePath,
  ) async {
    final absDir = resolveLocalSafePath(rootPath, dirRelativePath);
    final dir = Directory(absDir);
    if (!dir.existsSync()) {
      return const <RemoteEntry>[];
    }
    final cleanPrefix = dirRelativePath.trim().replaceAll('\\', '/');
    final prefix = cleanPrefix.endsWith('/')
        ? cleanPrefix.substring(0, cleanPrefix.length - 1)
        : cleanPrefix;
    final out = <RemoteEntry>[];
    for (final entity in dir.listSync(followLinks: false)) {
      final stat = entity.statSync();
      final isDir = stat.type == FileSystemEntityType.directory;
      final isFile = stat.type == FileSystemEntityType.file;
      if (!isDir && !isFile) {
        continue;
      }
      final name = p.basename(entity.path);
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      out.add(
        RemoteEntry(
          name: name,
          relativePath: rel,
          isDirectory: isDir,
          size: isDir ? 0 : stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    return out;
  }

  /// 剥离字幕主干尾部的语言、字体或双语标记，保留干净片名主干。
  static String stripLanguageSuffixes(String fileName) {
    var stem = p.posix.basenameWithoutExtension(fileName).trim();
    var changed = true;
    while (changed) {
      changed = false;
      final b = stem.replaceFirst(_trailingLangBracket, '').trim();
      if (b != stem && b.isNotEmpty) {
        stem = b;
        changed = true;
      }
      final s = stem.replaceFirst(_trailingLangSuffix, '').trim();
      if (s != stem && s.isNotEmpty) {
        stem = s;
        changed = true;
      }
    }
    return stem;
  }

  /// 未注入完整 `engine_sources` 匹配器时的纯 Dart 同目录字幕兜底匹配算法。
  static List<String> matchSubtitlesFallback({
    required String videoRelativePath,
    required List<String> allSubtitlePaths,
  }) {
    final videoPosix = videoRelativePath.replaceAll('\\', '/');
    final videoDir = SubtitleAndAudioChoices.parentDirOf(videoPosix);
    final videoStem = p.posix
        .basenameWithoutExtension(p.posix.basename(videoPosix))
        .toLowerCase();
    final matched = <String>[];

    for (final rawSub in allSubtitlePaths) {
      final subPosix = rawSub.replaceAll('\\', '/');
      final subName = p.posix.basename(subPosix);
      if (!KonataMediaExtensions.isSubtitleFile(subName)) {
        continue;
      }
      var logicalDir = SubtitleAndAudioChoices.parentDirOf(subPosix);
      if (logicalDir.isNotEmpty &&
          SubtitleAndAudioChoices.isSidecarSubdirName(
            p.posix.basename(logicalDir),
          )) {
        logicalDir = SubtitleAndAudioChoices.parentDirOf(logicalDir);
      }
      if (logicalDir != videoDir) {
        continue;
      }
      final cleanSub = stripLanguageSuffixes(subName).toLowerCase();
      if (cleanSub == videoStem ||
          cleanSub.startsWith('$videoStem.') ||
          cleanSub.startsWith('${videoStem}_') ||
          cleanSub.startsWith('$videoStem ') ||
          cleanSub.startsWith('$videoStem[')) {
        matched.add(subPosix);
      }
    }

    matched.sort((a, b) => _subtitlePriority(a).compareTo(_subtitlePriority(b)));
    return matched;
  }

  static int _subtitlePriority(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('chs') ||
        lower.contains('jpsc') ||
        lower.contains('[sc]') ||
        lower.contains('.sc.')) {
      return 0;
    }
    if (lower.contains('cht') ||
        lower.contains('jptc') ||
        lower.contains('[tc]') ||
        lower.contains('.tc.')) {
      return 1;
    }
    if (lower.endsWith('.ass') || lower.endsWith('.ssa')) {
      return 2;
    }
    return 3;
  }
}
