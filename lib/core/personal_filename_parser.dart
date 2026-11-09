import 'package:path/path.dart' as p;

/// 从常见番组发布文件名中提取更适合搜索的关键词。
///
/// 目标：尽量去掉字幕组/压制组、清晰度、编码等信息，同时保留番名本体（含数字番名）。
class PersonalFilenameParser {
  PersonalFilenameParser._();

  static final _tmdbMarkers = [
    RegExp(
      r'\{\s*tmdb(?:tv|movie|id)?\s*[-=:]\s*(\d+)\s*\}',
      caseSensitive: false,
    ),
    RegExp(
      r'\[\s*tmdb(?:tv|movie|id)?\s*[-=:]\s*(\d+)\s*\]',
      caseSensitive: false,
    ),
    RegExp(r'\{\s*\[\s*tmdbid\s*=\s*(\d+)[^\]]*\]\s*\}', caseSensitive: false),
  ];
  static Set<int> tmdbIds(String title) => {
    for (final pattern in _tmdbMarkers)
      for (final match in pattern.allMatches(title))
        if ((int.tryParse(match.group(1)!) ?? 0) > 0)
          int.parse(match.group(1)!),
  };
  static int? tmdbId(String title) {
    final ids = tmdbIds(title);
    return ids.length == 1 ? ids.single : null;
  }

  static String? tmdbType(String title) {
    if (RegExp(
      r'tmdbmovie\s*[-=:]|type\s*=\s*(movie|film)',
      caseSensitive: false,
    ).hasMatch(title)) {
      return 'movie';
    }
    return tmdbId(title) != null ? 'tv' : null;
  }

  static String withoutTmdbMarkers(String title) {
    var result = title;
    for (final pattern in _tmdbMarkers.reversed) {
      result = result.replaceAll(pattern, ' ');
    }
    return result;
  }

  static String baseNameWithoutExtension(String pathOrName) {
    final trimmed = pathOrName.trim();
    if (trimmed.isEmpty) return '';
    final base = p.posix.basename(trimmed.replaceAll('\\', '/'));
    return p.basenameWithoutExtension(base).trim();
  }

  /// 生成在线元数据搜索的标题候选；保留数字番名和括号中的作品名。
  static String extractAnimeTitleKeyword(String pathOrName) {
    var name = withoutTmdbMarkers(baseNameWithoutExtension(pathOrName));
    if (name.isEmpty) return '';

    // 常见分隔符归一化
    name = name.replaceAll(RegExp(r'[._]+'), ' ').trim();

    // 去掉开头的字幕组/压制组标识（可能存在多个）
    name = _stripLeadingGroupTags(name);

    // 去掉末尾的编码/分辨率等标签（可能存在多个）
    name = _stripTrailingTags(name);

    // A season/episode marker separates the series title from an optional
    // episode subtitle and release metadata. Keep everything before it.
    final episodeMarker = RegExp(
      r'\bS\d{1,2}E\d{1,3}\b|\bEP?\s*\d{1,3}\b|第\s*\d{1,3}\s*[话話集]',
      caseSensitive: false,
    ).firstMatch(name);
    if (episodeMarker != null) {
      name = name.substring(0, episodeMarker.start).trim();
    }

    // 去掉常见季/集标识（仅影响搜索关键词，不做全局数字清理）
    name = name.replaceAll(
      RegExp(r'\bS\d{1,2}E\d{1,3}\b', caseSensitive: false),
      ' ',
    );
    name = name.replaceAll(RegExp(r'\bS\d{1,2}\b', caseSensitive: false), ' ');
    name = name.replaceAll(RegExp(r'\b(?:EP|Ep|ep)\s*\d{1,3}\b'), ' ');
    name = name.replaceAll(RegExp(r'\bE\d{1,3}\b', caseSensitive: false), ' ');

    // 中文/日文“第X话/集/期”
    name = name.replaceAll(RegExp(r'第\s*\d{1,3}\s*[话話集期]'), ' ');
    name = name.replaceAll(RegExp(r'\d{1,3}\s*[话話集期]\b'), ' ');

    // 形如 [01] / 【01】 的独立集数标识（避免误删番名中的数字）
    final numericTitle = RegExp(r'^[\[【]\s*\d{1,3}\s*[\]】]$').hasMatch(name);
    if (!numericTitle) {
      name = name.replaceAll(RegExp(r'[\[【]\s*\d{1,3}\s*[\]】]'), ' ');
    }

    // 形如 " - 01" / "_01" 的结尾集数
    // Remove at most one suffix. Repeating this would turn "Animation 12 -
    // 01" into "Animation" and erase part of the real title.
    name = name.replaceFirst(
      RegExp(
        r'(?:\s*[-_#]\s*\d{1,3}|\s+0\d{1,2})(?:v\d+)?(?:\s*[- ]*(?:END|FINAL|FIN))?$',
        caseSensitive: false,
      ),
      ' ',
    );

    // 清理残留括号/多余空白
    name = name.replaceAll(RegExp(r'[\[\]【】()（）{}]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name;
  }

  /// 在常规标题提取结果上进一步去掉集数、分辨率、编码和字幕语言标签。
  ///
  /// 用于在线名称搜索，不读取视频或计算哈希。调用方仍应保留
  /// [extractAnimeTitleKeyword] 作为更保守的候选，避免数字属于作品名时丢失信息。
  static String extractAnimeSearchKeyword(
    String pathOrName, {
    int? episodeNumber,
  }) {
    final title = extractAnimeTitleKeyword(pathOrName);
    if (title.isEmpty) return '';

    final technicalToken = RegExp(
      r'^(?:'
      r'\d{3,4}p|[248]k|'
      r'x26[45]|h26[45]|hevc|avc|av1|'
      r'aac|flac|opus|ac3|eac3|dts|'
      r'web-?dl|webrip|bluray|bdrip|brrip|hdtv|'
      r'hdr10\+?|hdr|dolby|vision|dv|'
      r'jptc|jpchs|jpcht|chs|cht|gb|big5|'
      r'mp4|mkv'
      r')$',
      caseSensitive: false,
    );
    var removedEpisode = false;
    final kept = <String>[];

    for (final token in title.split(RegExp(r'\s+'))) {
      final normalized = token.replaceAll(
        RegExp(r'^[\[\]【】()（）{}]+|[\[\]【】()（）{}]+$'),
        '',
      );
      if (normalized.isEmpty || technicalToken.hasMatch(normalized)) {
        continue;
      }

      if (!removedEpisode && episodeNumber != null) {
        final numericToken = int.tryParse(normalized);
        if (numericToken == episodeNumber) {
          removedEpisode = true;
          continue;
        }
      }
      kept.add(normalized);
    }

    return kept.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _stripLeadingGroupTags(String name) {
    // A bracketed title followed only by an episode/technical tag must survive.
    // Unknown adjacent bracket blocks cannot be reliably split into title/group.
    final outside = name
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】'), ' ')
        .replaceAll(
          RegExp(r'\b(?:S\d+E\d+|EP?\d+|\d+)\b', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\b(?:\d{3,4}p|x26[45]|h26[45]|hevc|avc|flac|aac|bdrip|bluray|chs|cht)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[\s._-]+'), '');
    if (outside.isEmpty) return name;
    var result = name.trimLeft();
    while (true) {
      if (result.startsWith('[')) {
        final end = result.indexOf(']');
        if (end > 0) {
          result = result.substring(end + 1).trimLeft();
          continue;
        }
      }
      if (result.startsWith('【')) {
        final end = result.indexOf('】');
        if (end > 0) {
          result = result.substring(end + 1).trimLeft();
          continue;
        }
      }
      break;
    }
    return result;
  }

  static String _stripTrailingTags(String name) {
    var result = name.trimRight();
    final block = RegExp(r'\s*(?:\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）)\s*$');
    while (true) {
      final match = block.firstMatch(result);
      if (match == null) break;
      final before = result.substring(0, match.start).trimRight();
      if (before.isEmpty) break;
      result = before;
    }
    return result.trim();
  }
}
