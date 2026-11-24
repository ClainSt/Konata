import 'package:konata_contracts/konata_contracts.dart';
import 'package:path/path.dart' as p;

import 'source_folder_rules.dart';

/// 外挂字幕跨文件名集号匹配所需的轻量季集语义摘要。
class SubtitleEpisodeProbe {
  /// 创建季集语义摘要。
  const SubtitleEpisodeProbe({
    this.category = EpisodeCategory.main,
    this.season = 1,
    this.episode,
  });

  /// 剧集分类（正片或特典）。
  final EpisodeCategory category;

  /// 所属季号（默认 1）。
  final int season;

  /// 解析出的主集号。
  final int? episode;
}

/// 可选精细文件名解析回调签名（供上层注入完整发布名解析器，保持引擎解耦）。
typedef SubtitleEpisodeProbeParser =
    SubtitleEpisodeProbe Function(String fileName, {String? relativePath});

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

/// 预处理后的外挂字幕条目：语言后缀剥离只做一次，集号语义按需惰性解析一次。
class PreparedSubtitle {
  PreparedSubtitle._(
    this.path,
    this.logicalDir,
    this.lowerCleanStem,
    this._episodeParser,
  );

  /// 标准化斜杠分隔相对路径。
  final String path;

  /// 所属逻辑目录（字幕子目录折叠到其父目录）。
  final String logicalDir;

  /// 剥离语言后缀后的小写主干。
  final String lowerCleanStem;

  final SubtitleEpisodeProbeParser _episodeParser;

  late final SubtitleEpisodeProbe _parsed = _episodeParser(
    p.posix.basename(path),
    relativePath: path,
  );
}

/// 跨语言后缀剥离与同目录按集号跨文件名外挂字幕匹配器。
class SubtitleMatcher {
  const SubtitleMatcher._();

  /// 支持挂载的外挂字幕扩展名集合（统一引用契约层权威常量表）。
  static const Set<String> supportedExtensions = KonataMediaExtensions.subtitle;

  static final RegExp _trailingLangBracket = RegExp(
    r'[\s._\-]*[\[(【](?:chs|cht|sc|tc|gb|big5|jpn?|eng?|jpsc|jptc|zh[-_]?(?:cn|tw|hk|hans|hant)|chs&jpn|cht&jpn|sc&jp|tc&jp|bilingual|简日|繁日|简体|繁体|双语|雙語|default|forced)[\])】]\s*$',
    caseSensitive: false,
  );

  static final RegExp _trailingLangSuffix = RegExp(
    r'(?:[\s._\-]+(?:chs|cht|sc|tc|gb|big5|jpn?|jap|eng?|jpsc|jptc|chs&jpn|cht&jpn|sc&jp|tc&jp|zh[-_]?(?:cn|tw|hk|hans|hant)|default|forced))+\s*$',
    caseSensitive: false,
  );

  /// 内置轻量集号提取兜底（零外部引擎依赖）。
  static SubtitleEpisodeProbe parseEpisodeFallback(
    String fileName, {
    String? relativePath,
  }) {
    final probe = SourcePathRules.parseLightweightEpisodeProbe(
      fileName,
      relativePath: relativePath,
    );
    return SubtitleEpisodeProbe(
      category: probe.category,
      season: probe.season,
      episode: probe.episode,
    );
  }

  /// 判断文件名是否属于受支持的外挂字幕格式。
  static bool isSubtitleFile(String fileName) {
    final ext = p.posix.extension(fileName).toLowerCase();
    return supportedExtensions.contains(ext);
  }

  /// 剥离字幕主干尾部的语言、字体或版本标记。
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
  static List<PreparedSubtitle> prepare(
    Iterable<String> subtitleRelativePaths, {
    SubtitleEpisodeProbeParser? episodeParser,
  }) {
    final parser = episodeParser ?? parseEpisodeFallback;
    final prepared = <PreparedSubtitle>[];
    for (final rawSub in subtitleRelativePaths) {
      final subPosix = _toPosix(rawSub);
      final subFileName = p.posix.basename(subPosix);
      if (!isSubtitleFile(subFileName)) continue;
      prepared.add(
        PreparedSubtitle._(
          subPosix,
          _logicalParentDir(_dirname(subPosix)),
          stripLanguageSuffixes(subFileName).toLowerCase(),
          parser,
        ),
      );
    }
    return prepared;
  }

  /// 针对单个视频相对路径在同目录（含字幕子目录）中匹配外挂字幕。
  static MatchedSubtitleSet matchForVideo({
    required String videoRelativePath,
    required List<String> allSubtitleRelativePaths,
    SubtitleEpisodeProbeParser? episodeParser,
  }) {
    return matchPrepared(
      videoRelativePath: videoRelativePath,
      subtitles: prepare(
        allSubtitleRelativePaths,
        episodeParser: episodeParser,
      ),
      episodeParser: episodeParser,
    );
  }

  /// 与 [matchForVideo] 规则一致，但使用 [prepare] 预处理过的字幕列表。
  static MatchedSubtitleSet matchPrepared({
    required String videoRelativePath,
    required List<PreparedSubtitle> subtitles,
    SubtitleEpisodeProbeParser? episodeParser,
  }) {
    final normalizedVideo = _toPosix(videoRelativePath);
    final videoDir = _dirname(normalizedVideo);
    final videoFileName = p.posix.basename(normalizedVideo);
    final lowerVideoStem = p.posix
        .basenameWithoutExtension(videoFileName)
        .toLowerCase();
    final parser = episodeParser ?? parseEpisodeFallback;
    SubtitleEpisodeProbe? parsedVideo;

    final prefixMatches = <String>[];
    final episodeMatches = <String>[];

    for (final sub in subtitles) {
      if (sub.logicalDir != videoDir) continue;
      final lowerCleanSub = sub.lowerCleanStem;

      // 优先按剥离语言后缀后的同前缀或完全同主干匹配。
      if (lowerCleanSub == lowerVideoStem ||
          lowerCleanSub.startsWith('$lowerVideoStem.') ||
          lowerCleanSub.startsWith('${lowerVideoStem}_') ||
          lowerCleanSub.startsWith('$lowerVideoStem ') ||
          lowerCleanSub.startsWith('$lowerVideoStem[')) {
        prefixMatches.add(sub.path);
        continue;
      }

      // 其次按同目录季号与集号跨文件名自动匹配。
      final video = parsedVideo ??= parser(
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

    // 按简中与双语权重排序，确保优选简体字幕排在前面。
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
    return SourcePathRules.logicalParentDirOfSubtitleDir(dir);
  }

  static String _dirname(String posixPath) {
    final dir = p.posix.dirname(posixPath);
    return dir == '.' ? '' : dir;
  }

  static String _toPosix(String path) => path.replaceAll('\\', '/');
}
