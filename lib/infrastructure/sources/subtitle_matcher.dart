import 'package:path/path.dart' as p;

import '../../domain/models/episode.dart';
import '../../domain/parsing/bdrip_parser.dart';

/// 单个视频的外挂字幕匹配结果。
class MatchedSubtitleSet {
  /// 构造匹配结果。
  const MatchedSubtitleSet({
    required this.subtitlePaths,
    this.subtitleGroupHint,
  });

  /// 按优先级排序的外挂字幕相对路径列表。
  final List<String> subtitlePaths;

  /// 从挂载字幕文件名提取的字幕组提示（如 `SweetSub`）。
  final String? subtitleGroupHint;
}

/// 跨语言后缀剥离与同目录按集号跨文件名外挂字幕匹配器。
class SubtitleMatcher {
  const SubtitleMatcher._();

  /// 支持挂载的外挂字幕扩展名集合（小写含点）。
  static const Set<String> supportedExtensions = {
    '.ass',
    '.ssa',
    '.srt',
    '.sup',
    '.vtt',
  };

  static final RegExp _trailingLangBracket = RegExp(
    r'[\s._\-]*[\[(【](?:chs|cht|sc|tc|gb|big5|jpn?|eng?|jpsc|jptc|zh[-_]?(?:cn|tw|hk|hans|hant)|chs&jpn|cht&jpn|sc&jp|tc&jp|bilingual|简日|繁日|简体|繁体|双语|雙語|default|forced)[\])】]\s*$',
    caseSensitive: false,
  );

  static final RegExp _trailingLangSuffix = RegExp(
    r'(?:[\s._\-]+(?:chs|cht|sc|tc|gb|big5|jpn?|jap|eng?|jpsc|jptc|chs&jpn|cht&jpn|sc&jp|tc&jp|zh[-_]?(?:cn|tw|hk|hans|hant)|default|forced))+\s*$',
    caseSensitive: false,
  );

  static final RegExp _subDirSuffix = RegExp(
    r'/(?:subs?|subtitles?|字幕)$',
    caseSensitive: false,
  );

  /// 判断文件名是否属于受支持的外挂字幕格式。
  static bool isSubtitleFile(String fileName) {
    final ext = p.posix.extension(fileName).toLowerCase();
    return supportedExtensions.contains(ext);
  }

  /// 剥离字幕主干尾部的语言、字体/版本标记（如 `_chs`、`[SC]`、`.jpsc`、`.tc`、`.jpn`）。
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

  /// 针对单个视频相对路径在同目录（含 `Subs/`/`Subtitles/` 子目录）中匹配外挂字幕。
  static MatchedSubtitleSet matchForVideo({
    required String videoRelativePath,
    required List<String> allSubtitleRelativePaths,
  }) {
    final normalizedVideo = _toPosix(videoRelativePath);
    final videoDir = _dirname(normalizedVideo);
    final videoFileName = p.posix.basename(normalizedVideo);
    final videoStem = p.posix.basenameWithoutExtension(videoFileName);
    final lowerVideoStem = videoStem.toLowerCase();
    final parsedVideo = BdripParser.parseFileName(
      videoFileName,
      relativePath: normalizedVideo,
    );

    final prefixMatches = <String>[];
    final episodeMatches = <String>[];

    for (final rawSub in allSubtitleRelativePaths) {
      final subPosix = _toPosix(rawSub);
      final subDir = _logicalParentDir(_dirname(subPosix));
      if (subDir != videoDir) continue;

      final subFileName = p.posix.basename(subPosix);
      if (!isSubtitleFile(subFileName)) continue;
      final cleanSubStem = stripLanguageSuffixes(subFileName);
      final lowerCleanSub = cleanSubStem.toLowerCase();

      // 1. 剥离语言后缀后同前缀/完全同主干匹配（优先级最高）
      if (lowerCleanSub == lowerVideoStem ||
          lowerCleanSub.startsWith('$lowerVideoStem.') ||
          lowerCleanSub.startsWith('${lowerVideoStem}_') ||
          lowerCleanSub.startsWith('$lowerVideoStem ') ||
          lowerCleanSub.startsWith('$lowerVideoStem[')) {
        prefixMatches.add(subPosix);
        continue;
      }

      // 2. 同目录按集号跨文件名自动匹配（要求正片/特典归属及集号一致）
      final parsedSub = BdripParser.parseFileName(
        subFileName,
        relativePath: subPosix,
      );
      if (parsedVideo.category == EpisodeCategory.main &&
          parsedSub.category == EpisodeCategory.main &&
          parsedVideo.episode != null &&
          parsedSub.episode == parsedVideo.episode &&
          parsedSub.season == parsedVideo.season) {
        episodeMatches.add(subPosix);
      }
    }

    final merged = <String>[...prefixMatches];
    for (final epSub in episodeMatches) {
      if (!merged.contains(epSub)) merged.add(epSub);
    }

    // 按简中/双语权重排序，确保优选 _chs / [SC] 排在前面。
    merged.sort((a, b) => _subtitlePriority(a).compareTo(_subtitlePriority(b)));

    String? groupHint;
    if (merged.isNotEmpty) {
      groupHint = _extractSubtitleGroup(p.posix.basename(merged.first));
    }

    return MatchedSubtitleSet(
      subtitlePaths: merged,
      subtitleGroupHint: groupHint,
    );
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
    if (lower.endsWith('.ass') || lower.endsWith('.ssa')) return 2;
    return 3;
  }

  static String? _extractSubtitleGroup(String subFileName) {
    final m = RegExp(r'^\[([^\[\]]+)\]').firstMatch(subFileName.trim());
    if (m != null) {
      final token = m.group(1)!.trim();
      if (token.isNotEmpty && token.length <= 32) return token;
    }
    return null;
  }

  static String _logicalParentDir(String dir) {
    if (_subDirSuffix.hasMatch(dir)) {
      return dir.replaceFirst(_subDirSuffix, '');
    }
    return dir;
  }

  static String _dirname(String posixPath) {
    final dir = p.posix.dirname(posixPath);
    return dir == '.' ? '' : dir;
  }

  static String _toPosix(String path) => path.replaceAll('\\', '/');
}
