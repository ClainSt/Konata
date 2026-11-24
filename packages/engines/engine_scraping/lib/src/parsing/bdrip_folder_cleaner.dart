import '../models/work.dart';
import 'media_tech_parser.dart';
import 'release_groups.dart';
import 'season_number_parser.dart';

/// 目录名称清洗与显式 TMDB ID / 季号 / 年份提取结果。
class FolderTmdbHint {
  /// 创建目录提示结果。
  const FolderTmdbHint({
    required this.cleanTitle,
    this.tmdbId,
    this.tmdbMediaType,
    this.year,
    this.season,
  });

  /// 剥离发布组、技术标签、ID 标记、年份与季号后缀后的纯净作品标题。
  final String cleanTitle;

  /// 显式指定的唯一 TMDB ID（若存在多个互相冲突的 ID 则自动清零为 `null`）。
  final int? tmdbId;

  /// 显式指定的 TMDB 类型（`tv` 或 `movie`，未显式指明时为空）。
  final TmdbMediaType? tmdbMediaType;

  /// 从文件夹名提取的发行年份。
  final int? year;

  /// 从文件夹名提取的季号（如 `Season 2`、`第二季`、`II`）。
  final int? season;
}

/// 媒体目录名清洗与显式元数据识别器。
class BdripFolderCleaner {
  const BdripFolderCleaner._();

  static final RegExp _tmdbMarker = RegExp(
    r'[\[{（(]+\s*tmdb[\s._-]*(tv|movie|id)?\s*[-=:_]\s*(\d+)(?:\s*[;；]\s*type\s*=\s*(tv|movie))?\s*[\]}）)]+',
    caseSensitive: false,
  );
  static final RegExp _bangumiMarker = RegExp(
    r'[\[{（(]\s*(?:bgm|bangumi)(?:id)?\s*[-=:_]\s*(\d+)\s*[\]}）)]',
    caseSensitive: false,
  );
  static final RegExp _bracketYear = RegExp(r'[\[(（]((?:19|20)\d{2})[\])）]');
  static final RegExp _leadingDateTag = RegExp(
    r'^\s*[\[【(]\s*(?:\d{6}|\d{8}|\d{4}[-.]\d{2}[-.]\d{2})\s*[\]】)]\s*',
  );
  static final RegExp _anyBracket = RegExp(
    r'\[([^\[\]]+)\]|【([^【】]+)】|\(([^()]+)\)|（([^（）]+)）',
  );
  static final RegExp _trailingTechNoise = RegExp(
    r'(?:^|\s)(?:BDRip|BDMV|BDISO|BD-?Box|WEB-?DL|WEBRip|HDTV|1080p|2160p|720p|4K|UHD|HEVC|AVC|AV1|x265|x264|10bit|12bit|Ma10p|FLAC|AAC|DTS-?HD|LPCM|PCM|HDR|DV|Fin|Complete|合集|全\d+[集话話]).*$',
    caseSensitive: false,
  );

  /// 清洗目录名并提取显式 TMDB ID、媒体类型、年份与季号。
  static FolderTmdbHint parseFolderName(String rawFolderName) {
    var working = rawFolderName.trim();
    if (working.isEmpty) {
      return const FolderTmdbHint(cleanTitle: '');
    }

    int? tmdbId;
    TmdbMediaType? mediaType;
    final tmdbMatches = _tmdbMarker.allMatches(working).toList(growable: false);
    if (tmdbMatches.isNotEmpty) {
      final uniqueIds = <int>{};
      TmdbMediaType? firstType;
      for (final m in tmdbMatches) {
        final id = int.tryParse(m.group(2) ?? '');
        if (id != null && id > 0) {
          uniqueIds.add(id);
          final kindRaw = (m.group(3) ?? m.group(1))?.toLowerCase();
          firstType ??= switch (kindRaw) {
            'tv' => TmdbMediaType.tv,
            'movie' => TmdbMediaType.movie,
            _ => null,
          };
        }
      }
      // 存在多个互相冲突的 TMDB ID 时主动清零，回退正常匹配流程。
      if (uniqueIds.length == 1) {
        tmdbId = uniqueIds.first;
        mediaType = firstType;
      }
      working = working.replaceAll(_tmdbMarker, ' ');
    }
    working = working.replaceAll(_bangumiMarker, ' ');

    int? year;
    final yearMatches = _bracketYear
        .allMatches(working)
        .toList(growable: false);
    if (yearMatches.isNotEmpty) {
      final parsedYears = yearMatches
          .map((m) => int.tryParse(m.group(1) ?? ''))
          .whereType<int>()
          .toSet();
      if (parsedYears.length == 1) {
        year = parsedYears.first;
      }
      working = working.replaceAll(_bracketYear, ' ');
    }

    working = working.replaceFirst(_leadingDateTag, ' ');

    var hasSeenNonGroupOutside = false;
    working = working.replaceAllMapped(_anyBracket, (m) {
      final inner = (m[1] ?? m[2] ?? m[3] ?? m[4] ?? '').trim();
      if (inner.isEmpty) return ' ';
      if (_isGroupOrTechBlock(inner, hasSeenNonGroupOutside)) {
        return ' ';
      }
      hasSeenNonGroupOutside = true;
      return ' $inner ';
    });

    final techStripped = MediaTechParser.parse(working).strippedText;
    working = techStripped.replaceAll(_trailingTechNoise, ' ');
    working = _normalizeSpaces(working);

    final seasonSplit = SeasonNumberParser.splitSeasonSuffix(working);
    final finalTitle = _normalizeSpaces(seasonSplit.title);

    return FolderTmdbHint(
      cleanTitle: finalTitle.isNotEmpty ? finalTitle : rawFolderName.trim(),
      tmdbId: tmdbId,
      tmdbMediaType: mediaType,
      year: year,
      season: seasonSplit.seasonNumber,
    );
  }

  /// [parseFolderName] 的简短别名。
  static FolderTmdbHint parse(String rawFolderName) =>
      parseFolderName(rawFolderName);

  static final RegExp _groupSepPattern = RegExp(r'[&×+/,]');
  static final RegExp _techResidueSep = RegExp(r'[\s._\-+&,]+');
  static final RegExp _groupHintPattern = RegExp(
    r'字幕|压制|Sub|Raws|Studio|Fansub',
    caseSensitive: false,
  );
  static final RegExp _collectionTagPattern = RegExp(
    r'^(?:合集|全集|全\d+[集话話]|完结|Complete|Fin|BD|TV|OVA|SP|1080p|2160p|720p)$',
    caseSensitive: false,
  );
  static final RegExp _edgePunctPattern = RegExp(
    r'^[\s._\-/\\+|]+|[\s._\-/\\+|]+$',
  );
  static final RegExp _multiSpacePattern = RegExp(r'\s{2,}');

  static bool _isGroupOrTechBlock(String inner, bool seenContentBefore) {
    if (ReleaseGroups.contains(inner)) return true;
    final parts = inner
        .split(_groupSepPattern)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isNotEmpty && parts.every(ReleaseGroups.contains)) {
      return true;
    }
    final tech = MediaTechParser.stripTechTokens(inner);
    if (tech.hasSpec) {
      return tech.strippedText.replaceAll(_techResidueSep, '').isEmpty;
    }
    if (!seenContentBefore && parts.length <= 2 && inner.length <= 24) {
      if (_groupHintPattern.hasMatch(inner)) {
        return true;
      }
    }
    return _collectionTagPattern.hasMatch(inner);
  }

  static String _normalizeSpaces(String input) {
    return input
        .replaceAll(_edgePunctPattern, '')
        .replaceAll(_multiSpacePattern, ' ')
        .trim();
  }
}
