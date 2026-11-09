import 'package:path/path.dart' as p;
import 'release_groups.dart';

/// 从常见番组发布文件名中提取更适合搜索的关键词。
///
/// 目标：尽量去掉字幕组/压制组、清晰度、编码等信息，同时保留番名本体（含数字番名）。
class PersonalFilenameParser {
  PersonalFilenameParser._();

  static String normalizeIdentity(String title) => title
      .toLowerCase()
      .replaceAll(RegExp(r'\{tmdb-\d+\}', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\((?:19|20)\d{2}\)'), ' ')
      .replaceAll(RegExp(r'[\s\-_—–:：.()（）\[\]【】{}!?！？・·,，、]'), '')
      .trim();

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
    final types = tmdbTypes(title);
    return types.length == 1 ? types.single : null;
  }

  static Set<String> tmdbTypes(String title) => {
    if (RegExp(
      r'tmdbmovie\s*[-=:]|type\s*=\s*(movie|film)',
      caseSensitive: false,
    ).hasMatch(title))
      'movie',
    if (RegExp(
      r'tmdbtv\s*[-=:]|type\s*=\s*tv',
      caseSensitive: false,
    ).hasMatch(title))
      'tv',
  };

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

  /// An additional search candidate, never a destructive filename rewrite.
  /// Dictionary membership alone does not establish a work identity.
  static String? withoutKnownReleaseGroups(String filename) {
    final base = baseNameWithoutExtension(filename);
    var stripped = base.replaceAllMapped(RegExp(r'\[([^\]]+)\]|【([^】]+)】'), (
      m,
    ) {
      final tag = (m[1] ?? m[2]!).trim();
      return ReleaseGroups.contains(tag) ? ' ' : m[0]!;
    }).trim();
    final separators = RegExp(r'-').allMatches(stripped).toList();
    // Bound suffix probes; a hyphen inside a group name is part of the name.
    for (final match in separators.skip(
      separators.length > 8 ? separators.length - 8 : 0,
    )) {
      if (ReleaseGroups.contains(stripped.substring(match.end))) {
        stripped = stripped.substring(0, match.start).trimRight();
        break;
      }
    }
    if (stripped.isEmpty || stripped == base) return null;
    return '$stripped${p.extension(filename)}';
  }

  /// Fully bracketed releases can contain a group, several translated titles,
  /// episode and encoding tags. Keep possible titles for provider validation;
  /// position alone is not evidence that a block is a group or a work.
  static List<String> bracketTitleCandidates(String filename) {
    final base = baseNameWithoutExtension(filename);
    final pattern = RegExp(r'\[([^\]]+)\]|【([^】]+)】');
    if (base
        .replaceAll(pattern, '')
        .replaceAll(RegExp(r'[\s._-]'), '')
        .isNotEmpty) {
      return const [];
    }
    final blocks = pattern
        .allMatches(base)
        .map((m) => (m[1] ?? m[2]!).trim())
        .toList();
    final result = <String>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block.isEmpty ||
          tmdbIds('[$block]').isNotEmpty ||
          RegExp(
            r'^(?:S\d{1,2}(?:E\d{1,3})?|EP?\d{1,3})$',
            caseSensitive: false,
          ).hasMatch(block)) {
        continue;
      }
      if (RegExp(r'^\d{1,4}(?:v\d+)?$', caseSensitive: false).hasMatch(block)) {
        // Preserve a numeric title only when another numeric block follows.
        if (!blocks.skip(i + 1).any((b) => RegExp(r'^\d{1,3}$').hasMatch(b))) {
          continue;
        }
      }
      final technical = block.toLowerCase().split(RegExp(r'[\s_+,-]+'));
      if (technical.every(
        (part) => RegExp(
          r'^(?:\d{3,4}[pi]|[248]k|(?:ma|hi)?\d{1,2}p|(?:x|h)26[45]|hevc|avc|av1|aac|flac|opus|ac3|dts|10bit|8bit|bdrip|bluray|web-?dl|webrip|jpsc|jptc|chs|cht|gb|big5|mp4|mkv|[0-9a-f]{8})$',
        ).hasMatch(part),
      )) {
        continue;
      }
      result.add(block);
    }
    return result;
  }

  static ({String title, int episode})? bareEpisode(String filename) {
    final base = _stripTrailingTags(
      _stripLeadingGroupTags(baseNameWithoutExtension(filename)),
    );
    final match = RegExp(
      r'^(.+\S)\s+(\d{1,3})(?:v\d+)?$',
      caseSensitive: false,
    ).firstMatch(base);
    if (match == null || RegExp(r'[-_#]$').hasMatch(match[1]!)) return null;
    return (title: match[1]!.trim(), episode: int.parse(match[2]!));
  }

  static Set<String> sequentialEpisodePrefixes(Iterable<String> filenames) {
    final numbers = <String, Set<int>>{};
    for (final filename in filenames.expand(
      (name) => [name, ?withoutKnownReleaseGroups(name)],
    )) {
      final parsed = bareEpisode(filename);
      if (parsed != null) {
        (numbers[parsed.title.toLowerCase()] ??= {}).add(parsed.episode);
      }
    }
    return {
      for (final entry in numbers.entries)
        if (entry.value.any(
          (n) => entry.value.contains(n + 1) && entry.value.contains(n + 2),
        ))
          entry.key,
    };
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
