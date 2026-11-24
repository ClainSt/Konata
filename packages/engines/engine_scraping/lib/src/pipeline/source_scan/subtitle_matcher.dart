import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import '../../parsing/bdrip_parser.dart';

/// 单个视频的外挂字幕匹配结果。
class ScrapeMatchedSubtitleSet {
  /// 构造匹配结果。
  const ScrapeMatchedSubtitleSet({
    required this.subtitlePaths,
    this.subtitleGroupHint,
  });

  /// 按优先级排序的外挂字幕相对路径列表。
  final List<String> subtitlePaths;

  /// 从挂载字幕文件名提取的字幕组提示（如 `SweetSub`）。
  final String? subtitleGroupHint;
}

/// 预处理后的外挂字幕条目：语言后缀剥离只做一次，文件名解析在首次需要时做且只做一次。
///
/// 同目录内每个视频都要与全部字幕比对，若逐视频重复剥离与解析，代价是「视频数 × 字幕数 × 解析成本」，
/// 大目录扫描会长时间占用主线程；预处理后单次比对只剩字符串比较。
class ScrapePreparedSubtitle {
  ScrapePreparedSubtitle._(this.path, this.logicalDir, this.lowerCleanStem);

  /// POSIX 风格相对路径。
  final String path;

  /// 所属逻辑目录（`Subs/` 等字幕子目录折叠到其父目录）。
  final String logicalDir;

  /// 剥离语言后缀后的小写主干。
  final String lowerCleanStem;

  late final ParsedBdripRelease _parsed = BdripParser.parseFileName(
    p.posix.basename(path),
    relativePath: path,
  );
}

/// 跨语言后缀剥离与同目录按集号跨文件名外挂字幕匹配器。
class ScrapeSubtitleMatcher {
  const ScrapeSubtitleMatcher._();

  /// 支持挂载的外挂字幕扩展名集合（统一引用领域权威常量表）。
  static const Set<String> supportedExtensions = KonataMediaExtensions.subtitle;

  static final RegExp _trailingLangBracket = RegExp(
    r'[\s._\-]*[\[(【](?:chs|cht|sc|tc|gb|big5|jpn?|eng?|jpsc|jptc|zh[-_]?(?:cn|tw|hk|hans|hant)|chs&jpn|cht&jpn|sc&jp|tc&jp|bilingual|简日|繁日|简体|繁体|双语|雙語|default|forced)[\])】]\s*$',
    caseSensitive: false,
  );

  static final RegExp _trailingLangSuffix = RegExp(
    r'(?:[\s._\-]+(?:chs|cht|sc|tc|gb|big5|jpn?|jap|eng?|jpsc|jptc|chs&jpn|cht&jpn|sc&jp|tc&jp|zh[-_]?(?:cn|tw|hk|hans|hant)|default|forced))+\s*$',
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

  /// 预处理一批字幕路径（跳过非字幕扩展名），供同目录多个视频重复比对。
  static List<ScrapePreparedSubtitle> prepare(
    Iterable<String> subtitleRelativePaths,
  ) {
    final prepared = <ScrapePreparedSubtitle>[];
    for (final rawSub in subtitleRelativePaths) {
      final subPosix = _toPosix(rawSub);
      final subFileName = p.posix.basename(subPosix);
      if (!isSubtitleFile(subFileName)) continue;
      prepared.add(
        ScrapePreparedSubtitle._(
          subPosix,
          _logicalParentDir(_dirname(subPosix)),
          stripLanguageSuffixes(subFileName).toLowerCase(),
        ),
      );
    }
    return prepared;
  }

  /// 针对单个视频相对路径在同目录（含 `Subs/`/`Subtitles/` 子目录）中匹配外挂字幕。
  static ScrapeMatchedSubtitleSet matchForVideo({
    required String videoRelativePath,
    required List<String> allSubtitleRelativePaths,
  }) {
    return matchPrepared(
      videoRelativePath: videoRelativePath,
      subtitles: prepare(allSubtitleRelativePaths),
    );
  }

  /// 与 [matchForVideo] 规则一致，但使用 [prepare] 预处理过的字幕列表。
  static ScrapeMatchedSubtitleSet matchPrepared({
    required String videoRelativePath,
    required List<ScrapePreparedSubtitle> subtitles,
  }) {
    final normalizedVideo = _toPosix(videoRelativePath);
    final videoDir = _dirname(normalizedVideo);
    final videoFileName = p.posix.basename(normalizedVideo);
    final lowerVideoStem = p.posix
        .basenameWithoutExtension(videoFileName)
        .toLowerCase();
    // 仅当存在未按主干命中的同目录字幕时才需要视频集号，按需解析。
    ParsedBdripRelease? parsedVideo;

    final prefixMatches = <String>[];
    final episodeMatches = <String>[];

    for (final sub in subtitles) {
      if (sub.logicalDir != videoDir) continue;
      final lowerCleanSub = sub.lowerCleanStem;

      // 1. 剥离语言后缀后同前缀/完全同主干匹配（优先级最高）
      if (lowerCleanSub == lowerVideoStem ||
          lowerCleanSub.startsWith('$lowerVideoStem.') ||
          lowerCleanSub.startsWith('${lowerVideoStem}_') ||
          lowerCleanSub.startsWith('$lowerVideoStem ') ||
          lowerCleanSub.startsWith('$lowerVideoStem[')) {
        prefixMatches.add(sub.path);
        continue;
      }

      // 2. 同目录按集号跨文件名自动匹配（要求正片/特典归属及集号一致）
      final video = parsedVideo ??= BdripParser.parseFileName(
        videoFileName,
        relativePath: normalizedVideo,
      );
      if (video.category != EpisodeCategory.main || video.episode == null) {
        continue;
      }
      final parsedSub = sub._parsed;
      if (parsedSub.category == EpisodeCategory.main &&
          parsedSub.episode == video.episode &&
          parsedSub.season == video.season) {
        episodeMatches.add(sub.path);
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

    return ScrapeMatchedSubtitleSet(
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
    return ScrapeSubtitleMatcher.logicalParentDirOfSubtitleDir(dir);
  }

  static String _dirname(String posixPath) {
    final dir = p.posix.dirname(posixPath);
    return dir == '.' ? '' : dir;
  }

  static String _toPosix(String path) => path.replaceAll('\\', '/');
  static const Set<String> _subtitleSubdirExactNames = {
    'sub',
    'subs',
    'subtitle',
    'subtitles',
    '字幕',
  };

  static final RegExp _subtitleSubdirTokenRegex = RegExp(
    r'^(?:subs?|subtitles?)(?:[\s._\-]?\d+|[\s._\-](?:chs|cht|sc|tc|jp|jpn|eng|zh|bilingual|all|extra))?$',
    caseSensitive: false,
  );

  /// 判定目录尾段是否为外挂字幕子目录。
  static bool isSubtitleSubdirName(String rawName) {
    final lower = rawName.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (_subtitleSubdirExactNames.contains(lower)) return true;
    if (lower.contains('字幕')) return true;
    return _subtitleSubdirTokenRegex.hasMatch(lower);
  }

  /// 若目录尾段为字幕子目录（如 `Anime/S1/Subs`），返回其逻辑父目录；否则原样返回。
  static String logicalParentDirOfSubtitleDir(String posixDir) {
    final normalized = posixDir
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return '';
    final slash = normalized.lastIndexOf('/');
    final tail = slash < 0 ? normalized : normalized.substring(slash + 1);
    if (!isSubtitleSubdirName(tail)) return normalized;
    return slash < 0 ? '' : normalized.substring(0, slash);
  }

}
