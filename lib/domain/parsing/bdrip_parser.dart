import '../models/episode.dart';
import 'bdrip_folder_cleaner.dart';
import 'cloud_media_classifier.dart';
import 'episode_number_extractor.dart';
import 'media_tech_parser.dart';
import 'release_groups.dart';
import 'season_number_parser.dart';

/// 单个媒体文件名的结构化 BDRip / Scene 解析结果。
class ParsedBdripRelease {
  /// 创建解析结果。
  const ParsedBdripRelease({
    required this.cleanTitle,
    this.season = 1,
    this.episode,
    this.episodeEnd,
    this.fractionalEpisode,
    this.category = EpisodeCategory.main,
    this.extraType,
    this.isWeakExtra = false,
    this.releaseGroup,
    this.subtitleGroup,
    this.videoCodec,
    this.bitDepth,
    this.resolution,
    this.audioCodec,
    this.dynamicRange,
    this.year,
  });

  /// 提取出的纯净作品标题。
  final String cleanTitle;

  /// 解析出的季号（特典固定为 `0`，正片未显式标注时默认为 `1`）。
  final int season;

  /// 解析出的起始/主集号或特典序号。
  final int? episode;

  /// 区间集结束集号（如 `01-04` 中的 `4`）。
  final int? episodeEnd;

  /// 小数半集文本（如 `11.5`、`04.5`）。
  final String? fractionalEpisode;

  /// 正片或特典分类。
  final EpisodeCategory category;

  /// 特典细分类型。
  final ExtraKind? extraType;

  /// 是否仅由弱上下文词（`Recap`/`Special`/`総集編`）判定的特典（可被连续正片保护恢复）。
  final bool isWeakExtra;

  /// 压制组名称（如 `VCB-Studio`、`Moozzi2`）。
  final String? releaseGroup;

  /// 字幕组名称（如 `SweetSub`、`Kamigami-Sub`）。
  final String? subtitleGroup;

  /// 视频编码（如 `HEVC`、`AV1`、`AVC`）。
  final String? videoCodec;

  /// 色深（如 `10bit`、`12bit`、`8bit`）。
  final String? bitDepth;

  /// 分辨率（如 `1080p`、`2160p`）。
  final String? resolution;

  /// 音频编码（如 `FLAC`、`PCM`、`DTS-HD`、`OPUS`、`AAC`）。
  final String? audioCodec;

  /// 动态范围（如 `HDR`、`DV`）。
  final String? dynamicRange;

  /// 解析出的年份。
  final int? year;
}

enum _GroupRole { release, subtitle, neither }

/// BDRip 与 Scene 媒体文件名解析入口（组合多模块，严守高内聚短文件）。
class BdripParser {
  const BdripParser._();

  static final RegExp _bracketOrParen = RegExp(
    r'\[([^\[\]]+)\]|【([^【】]+)】|\(([^()]+)\)|（([^（）]+)）',
  );
  static final RegExp _yearBlock = RegExp(r'^(19\d\d|20[0-3]\d)$');
  static final RegExp _pureEpBlock = RegExp(
    r'^(?:S\d{1,2})?E?\d{1,4}(?:v\d+)?(?:\s*[-~&]\s*E?\d{1,4})?(?:\s*(?:END|FIN))?$',
    caseSensitive: false,
  );
  static final RegExp _groupJoinSplit = RegExp(r'[&+]');
  static final RegExp _tailSubTag = RegExp(r'(?:简体|繁体|简日|繁日|简繁|双语|内嵌|内封|外挂)$');
  static final RegExp _spacedGroupPattern = RegExp(
    r'^[A-Za-z][A-Za-z0-9 ._\-&!+]{1,27}$',
  );
  static final RegExp _nonGroupWordPattern = RegExp(
    r'\b(?:Season|Part|Vol|Movie|Ep)\b',
    caseSensitive: false,
  );
  static final RegExp _pureExtraBlockPattern = RegExp(
    r'^(?:nc\s*(?:op|ed)\d*|creditless\s*(?:op|ed|opening|ending)\d*|'
    r'menu\s*(?:ex)?\d*|character\s*pv\s*\d*|bd\s*pv\s*\d*|cm\s*spot\s*\d*|'
    r'spot\s*\d*|pv\s*\d*|cm\s*\d*|iv\s*\d+|sp\s*\d+|ex\s*\d+|extra\s*\d+|'
    r'ova\s*\d*|oad\s*\d*|web\s*preview\s*\d*|true\s+end\s+pv|'
    r'trailer\s*\d*|teaser\s*\d*|preview\s*\d*|making(?:\s+of)?\s*\d*|interview\s*\d*|'
    r'commentary\s*\d*|audio\s*commentary|special\s*\d*|tokuten|omake|bonus|'
    r'特典|映像特典|音声特典)$',
    caseSensitive: false,
  );
  static final RegExp _pureTechResidualTokens = RegExp(
    r'(?<=^|[\s._\-+&,])(?:CR|NF|AMZN|BAHA|BILIBILI|ABEMA|CATCHPLAY|AT-?X|BS11|MX|TX|MP4|MKV|SUP|PGS|CHI|CHS|CHT|SC|TC|JPN|JP|ENG|EN|CN|TW|HK|KR|JPSC|JPTC|ASS(?:x\d)?|SSA|SRT|2D|3D|P\d+(?:\.\d+)?|v\d+|Renew|ESub|Sub)(?=$|[\s._\-+&,])|(?:简繁日内封|简繁内封|简体内封|繁体内封|简繁外挂|内封字幕|日语字幕|日本語字幕|双语字幕|中文字幕|字幕)',
    caseSensitive: false,
  );
  static final RegExp _animeTagPattern = RegExp(
    r'(?:^|[\s._\-+&,])アニメ(?=$|[\s._\-+&,])',
  );
  static final RegExp _techDelimiterChars = RegExp(r'[\s._\-+&,/／]+');
  static final RegExp _spaceDelimChars = RegExp(r'[\s._\-]+');
  static final RegExp _emptyBracketsPattern = RegExp(
    r'\[\s*[\s._\-/／]*\]|\(\s*[\s._\-/／]*\)|【\s*[\s._\-/／]*】|（\s*[\s._\-/／]*）',
  );
  static final RegExp _strayDashesPattern = RegExp(r'(?:\s+-){2,}\s*|\s+-\s+$');
  static final RegExp _edgePunctPattern = RegExp(
    r'^[\s._\-/\\]+|[\s._\-/\\]+$',
  );
  static final RegExp _multiSpacePattern = RegExp(r'\s{2,}');
  static final RegExp _slashPattern = RegExp(r'[/\\]');

  /// 从文件夹名称提取显式 TMDB 标记、年份、季号与纯净标题。
  static FolderTmdbHint parseFolderName(String folderName) =>
      BdripFolderCleaner.parseFolderName(folderName);

  /// 解析单个媒体文件名，提取压制组、字幕组、技术规格、季集与特典信息。
  ///
  /// 调用方若已由上游完成集号/特典/季号判定，可通过 [resolveEpisode]、
  /// [resolveExtraClassification] 与 [resolveTitleAndSeason] 按需关闭对应阶段，
  /// 在大库扫描热路径上避免重复执行昂贵正则；默认全部开启以 100% 保持既有契约。
  static ParsedBdripRelease parseFileName(
    String fileName, {
    String? relativePath,
    String? folderTitle,
    int? folderSeasonHint,
    bool resolveEpisode = true,
    bool resolveExtraClassification = true,
    bool resolveTitleAndSeason = true,
  }) {
    final base = _stripExtension(fileName);
    final tech = MediaTechParser.parseSpecsOnly(base);

    String? releaseGroup;
    String? subtitleGroup;
    int? year;

    final needAfterBlocks = resolveEpisode || resolveTitleAndSeason;
    var blockIndex = 0;
    String afterBlocks;
    if (needAfterBlocks) {
      // 1. 识别括号块中的年份、压制组/字幕组与纯技术参数块，并构建待提取集号的净化文本。
      afterBlocks = base.replaceAllMapped(_bracketOrParen, (match) {
        final raw = match.group(0)!;
        final inner = (match[1] ?? match[2] ?? match[3] ?? match[4] ?? '')
            .trim();
        final idx = blockIndex++;
        if (inner.isEmpty) return ' ';

        final yearMatch = _yearBlock.firstMatch(inner);
        if (yearMatch != null) {
          year ??= int.tryParse(yearMatch.group(1)!);
          return ' ';
        }

        if (_pureEpBlock.hasMatch(inner)) {
          return ' $raw ';
        }

        if (CloudMediaClassifier.extractBundledOvaEpisode(raw) != null) {
          return ' $raw ';
        }

        final assigned = _assignGroupFromBlock(
          inner,
          isLeadingBlock:
              idx == 0 &&
              match.start <= 48 &&
              releaseGroup == null &&
              subtitleGroup == null,
          isAtVeryStart: idx == 0 && match.start == 0,
          isNonLeadingBlock: idx > 0,
          releaseGroup: releaseGroup,
          subtitleGroup: subtitleGroup,
        );
        if (assigned.consumed) {
          releaseGroup ??= assigned.releaseGroup;
          subtitleGroup ??= assigned.subtitleGroup;
          return ' ';
        }

        final innerTech = MediaTechParser.stripTechTokens(inner);
        if (_isPureTechContent(
          innerTech.hasSpec,
          innerTech.strippedText,
          inner,
        )) {
          return ' ';
        }

        if (_isPureExtraBlock(inner)) {
          return ' ';
        }

        return ' $raw ';
      });
    } else {
      // 仅需提取年份与压制组/字幕组时，直接遍历括号块，跳过整串重建与逐块技术清洗。
      afterBlocks = '';
      for (final match in _bracketOrParen.allMatches(base)) {
        final raw = match.group(0)!;
        final inner = (match[1] ?? match[2] ?? match[3] ?? match[4] ?? '')
            .trim();
        final idx = blockIndex++;
        if (inner.isEmpty) continue;

        final yearMatch = _yearBlock.firstMatch(inner);
        if (yearMatch != null) {
          year ??= int.tryParse(yearMatch.group(1)!);
          continue;
        }
        if (_pureEpBlock.hasMatch(inner) ||
            CloudMediaClassifier.extractBundledOvaEpisode(raw) != null) {
          continue;
        }
        final assigned = _assignGroupFromBlock(
          inner,
          isLeadingBlock:
              idx == 0 &&
              match.start <= 48 &&
              releaseGroup == null &&
              subtitleGroup == null,
          isAtVeryStart: idx == 0 && match.start == 0,
          isNonLeadingBlock: idx > 0,
          releaseGroup: releaseGroup,
          subtitleGroup: subtitleGroup,
        );
        if (assigned.consumed) {
          releaseGroup ??= assigned.releaseGroup;
          subtitleGroup ??= assigned.subtitleGroup;
        }
      }
    }

    releaseGroup ??= MediaTechParser.extractTrailingSceneGroup(base);

    // 2. 剥离技术参数后的文本进行 15 级集号抽取（按需执行）。
    int? resolvedEp;
    int? resolvedEpEnd;
    String? fractionalEpisode;
    int? extractedSeasonNumber;
    var titleWorkText = '';
    if (needAfterBlocks) {
      final strippedForEp = _stripTechAndTrailingGroup(afterBlocks);
      final epExtracted = EpisodeNumberExtractor.extract(strippedForEp);
      final bundledOvaEp = CloudMediaClassifier.extractBundledOvaEpisode(base);
      resolvedEp = bundledOvaEp ?? epExtracted.episodeNumber;
      resolvedEpEnd = epExtracted.episodeEnd;
      fractionalEpisode = epExtracted.fractionalEpisode;
      extractedSeasonNumber = epExtracted.seasonNumber;
      titleWorkText = epExtracted.remainingText;
      // 若文件夹纯净标题末尾本来就带有数字（如 "Mob Psycho 100"）且文件名未包含其它分隔式集号，避免把标题固有数字误当作集号。
      if (bundledOvaEp == null &&
          folderTitle != null &&
          resolvedEp != null &&
          !epExtracted.isExplicitSeasonEpisode &&
          _looksLikeFolderTitleIntrinsicNumber(
            strippedForEp,
            folderTitle,
            resolvedEp,
          )) {
        resolvedEp = null;
        titleWorkText = strippedForEp;
      }
    }

    // 3. 单趟判定正片 / 特典分类与弱特典标记（按需执行）。
    ExtraKind? extraType;
    var isWeakExtra = false;
    if (resolveExtraClassification) {
      final extraClassification =
          CloudMediaClassifier.classifyExtraWithStrength(
            fileName: fileName,
            relativePath: relativePath,
            hasFractionalEpisode: fractionalEpisode != null,
          );
      extraType = extraClassification.kind;
      if (extraType != null && resolvedEp == null) {
        resolvedEp = CloudMediaClassifier.extractExplicitExtraNumberFromClean(
          extraClassification.cleanedBase,
        );
      }
      isWeakExtra = extraType != null && !extraClassification.isStrong;
    }
    final category = extraType != null
        ? EpisodeCategory.extra
        : EpisodeCategory.main;

    // 4. 清理标题文本并分离尾部季号后缀（按需执行）。
    var season = category == EpisodeCategory.extra
        ? 0
        : (folderSeasonHint ?? 1);
    var finalTitle = '';
    if (resolveTitleAndSeason) {
      final normalizedTitleRaw = _cleanExtractedTitle(titleWorkText);
      final seasonSplit = SeasonNumberParser.splitSeasonSuffix(
        normalizedTitleRaw,
      );
      final pathSeason = relativePath != null
          ? SeasonNumberParser.extractSeasonFromPath(relativePath)
          : null;

      if (category == EpisodeCategory.extra) {
        season = 0;
      } else {
        season =
            extractedSeasonNumber ??
            pathSeason ??
            seasonSplit.seasonNumber ??
            folderSeasonHint ??
            1;
      }

      final trimmedSeasonTitle = seasonSplit.title.trim();
      if (trimmedSeasonTitle.isNotEmpty) {
        finalTitle = trimmedSeasonTitle;
      } else {
        final cleanFolderFallback =
            folderTitle != null && folderTitle.trim().isNotEmpty
            ? BdripFolderCleaner.parseFolderName(folderTitle).cleanTitle
            : '';
        finalTitle = cleanFolderFallback.isNotEmpty
            ? cleanFolderFallback
            : normalizedTitleRaw;
      }
    }

    return ParsedBdripRelease(
      cleanTitle: finalTitle,
      season: season,
      episode: resolvedEp,
      episodeEnd: resolvedEpEnd,
      fractionalEpisode: fractionalEpisode,
      category: category,
      extraType: extraType,
      isWeakExtra: isWeakExtra,
      releaseGroup: releaseGroup,
      subtitleGroup: subtitleGroup,
      videoCodec: tech.videoCodec,
      bitDepth: tech.bitDepth,
      resolution: tech.resolution,
      audioCodec: tech.audioCodec,
      dynamicRange: tech.dynamicRange,
      year: year,
    );
  }

  static ({bool consumed, String? releaseGroup, String? subtitleGroup})
  _assignGroupFromBlock(
    String inner, {
    required bool isLeadingBlock,
    bool isAtVeryStart = false,
    bool isNonLeadingBlock = false,
    String? releaseGroup,
    String? subtitleGroup,
  }) {
    if (inner.contains('&') || inner.contains('+')) {
      final parts = inner
          .split(_groupJoinSplit)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (parts.length >= 2) {
        String? foundRelease;
        String? foundSub;
        for (final part in parts) {
          final role = _classifyGroupToken(
            part,
            allowHeuristic: isLeadingBlock,
            allowSpacedGroup: isAtVeryStart,
            allowTailSubTag: isNonLeadingBlock,
          );
          if (role == _GroupRole.release) {
            foundRelease ??= part;
          } else if (role == _GroupRole.subtitle) {
            foundSub ??= part;
          }
        }
        if (foundRelease != null || foundSub != null) {
          return (
            consumed: true,
            releaseGroup: foundRelease ?? releaseGroup,
            subtitleGroup: foundSub ?? subtitleGroup,
          );
        }
      }
    }

    final role = _classifyGroupToken(
      inner,
      allowHeuristic: isLeadingBlock,
      allowSpacedGroup: isAtVeryStart,
      allowTailSubTag: isNonLeadingBlock,
    );
    if (role == _GroupRole.release) {
      return (
        consumed: true,
        releaseGroup: releaseGroup ?? inner,
        subtitleGroup: subtitleGroup,
      );
    }
    if (role == _GroupRole.subtitle) {
      return (
        consumed: true,
        releaseGroup: releaseGroup,
        subtitleGroup: subtitleGroup ?? inner,
      );
    }
    return (
      consumed: false,
      releaseGroup: releaseGroup,
      subtitleGroup: subtitleGroup,
    );
  }

  static _GroupRole _classifyGroupToken(
    String block, {
    required bool allowHeuristic,
    bool allowSpacedGroup = false,
    bool allowTailSubTag = false,
  }) {
    final lower = block.toLowerCase();
    final hasSubHint =
        lower.contains('sub') ||
        lower.contains('字幕') ||
        lower.contains('汉化') ||
        lower.contains('fansub') ||
        (allowTailSubTag && _tailSubTag.hasMatch(block));
    final hasRawHint =
        lower.contains('raws') ||
        lower.contains('studio') ||
        lower.contains('rip') ||
        lower.contains('moozzi') ||
        lower.contains('vcb');

    if (hasSubHint) return _GroupRole.subtitle;
    if (hasRawHint) return _GroupRole.release;
    if (ReleaseGroups.contains(block)) {
      return _GroupRole.release;
    }
    if (!allowHeuristic) return _GroupRole.neither;
    if (!block.contains(' ') && block.length <= 24) return _GroupRole.release;
    if (allowSpacedGroup &&
        _spacedGroupPattern.hasMatch(block) &&
        !_nonGroupWordPattern.hasMatch(block)) {
      return _GroupRole.release;
    }
    return _GroupRole.neither;
  }

  static bool _isPureExtraBlock(String inner) {
    final cleaned = inner.trim();
    if (cleaned.isEmpty) return false;
    return _pureExtraBlockPattern.hasMatch(cleaned);
  }

  static bool _isPureTechContent(
    bool hasSpec,
    String strippedText,
    String rawInner,
  ) {
    var rem = strippedText.replaceAll(_pureTechResidualTokens, '');
    if (hasSpec) {
      rem = rem.replaceAll(_animeTagPattern, '');
    }
    rem = rem.replaceAll(_techDelimiterChars, '');
    if (hasSpec) {
      return rem.isEmpty;
    }
    return rem.isEmpty && rawInner.trim().isNotEmpty;
  }

  static String _stripTechAndTrailingGroup(String input) =>
      MediaTechParser.stripTechTokens(input).strippedText;

  static bool _looksLikeFolderTitleIntrinsicNumber(
    String fileText,
    String folderTitle,
    int candidateEp,
  ) {
    final normFile = fileText
        .toLowerCase()
        .replaceAll(_spaceDelimChars, ' ')
        .trim();
    final normFolder = folderTitle
        .toLowerCase()
        .replaceAll(_spaceDelimChars, ' ')
        .trim();
    return normFile == normFolder &&
        RegExp('\\b$candidateEp\\b').hasMatch(normFolder);
  }

  static String _cleanExtractedTitle(String input) {
    var text = input.replaceAll(_emptyBracketsPattern, ' ');
    // 若无空格却含多个点号分隔（典型 Scene 命名如 Sousou.no.Frieren），将点号转空格。
    final compact = text.trim();
    if (!compact.contains(' ')) {
      final firstDot = compact.indexOf('.');
      if (firstDot >= 0 && compact.indexOf('.', firstDot + 1) >= 0) {
        text = text.replaceAll('.', ' ');
      }
    }
    text = text.replaceAll(_strayDashesPattern, ' ');
    // 清理残余括号标记与孤立连字符，保留 "86 -Eighty Six" 内部连字符。
    text = text.replaceAll(_edgePunctPattern, '').trim();
    if ((text.startsWith('[') &&
            text.endsWith(']') &&
            !text.substring(1, text.length - 1).contains('[')) ||
        (text.startsWith('【') &&
            text.endsWith('】') &&
            !text.substring(1, text.length - 1).contains('【'))) {
      text = text.substring(1, text.length - 1).trim();
    }
    text = text.replaceAll(_multiSpacePattern, ' ');
    return text.trim();
  }

  static String _stripExtension(String name) {
    final slash = name.lastIndexOf(_slashPattern);
    final fileOnly = slash >= 0 ? name.substring(slash + 1) : name;
    final dot = fileOnly.lastIndexOf('.');
    return dot > 0 ? fileOnly.substring(0, dot) : fileOnly;
  }
}
