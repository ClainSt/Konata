import '../models/episode.dart';
import '../models/media_variant.dart';
import '../models/work.dart';
import '../parsing/bdrip_parser.dart';
import '../scraping/directory_analyzer.dart';
import 'supplementary_folder_rules.dart';

/// 连续正片序列防误降级保护：当仅命中弱特典词（如 `Recap`/`Special`/`総集編`）
/// 且集号正好填补同目录连续正片序列缺口或紧接末尾时，保留为正片。
bool shouldRestoreWeakExtraToMain(
  ParsedBdripRelease parsed,
  Set<int> strongMainEpisodes,
) {
  if (!parsed.isWeakExtra) return false;
  final ep = parsed.episode;
  if (ep == null || ep <= 0 || strongMainEpisodes.length < 3) return false;
  var maxEp = 0;
  for (final n in strongMainEpisodes) {
    if (n > maxEp) maxEp = n;
  }
  return ep >= 1 && ep <= maxEp + 1 && !strongMainEpisodes.contains(ep);
}

/// 单视频物理文件的确定性剧集/特典槽位预分配结果。
class EpisodeSlotAssignment {
  /// 创建单视频槽位预分配结果。
  const EpisodeSlotAssignment({
    required this.category,
    required this.seasonNumber,
    this.episodeNumber,
    this.episodeEnd,
    this.extraType,
    this.fractionalLabel,
    this.extraTitleHint,
    this.unnumberedStemKey,
  });

  /// 所属分类（正片或特典）。
  final EpisodeCategory category;

  /// 季号（特典一般为 0）。
  final int seasonNumber;

  /// 集号或特典序号（未解析集号保持 null）。
  final int? episodeNumber;

  /// 多集合并文件的区间结束集号（仅正片；`null` 表示单集，非空时必大于 [episodeNumber]）。
  final int? episodeEnd;

  /// 特典细分类型。
  final ExtraKind? extraType;

  /// 半集/小数集号文本（如 `10.5`）。
  final String? fractionalLabel;

  /// 清洗后的特典展示名提示。
  final String? extraTitleHint;

  /// 无集号特典的精确防撞键（保留 `[CM1]`/`[Menu]`/`[Preview]` 等特征，避免误合并成多版本）。
  final String? unnumberedStemKey;
}

/// 扫描后按作品根目录归拢的强类型分组结果（纯逻辑，零 IO）。
class GroupedWorkFolder {
  /// 创建分组结果。
  const GroupedWorkFolder({
    required this.folderRelativePath,
    required this.folderName,
    required this.cleanTitle,
    this.explicitTmdbId,
    this.explicitMediaType,
    this.year,
    this.seasonHint,
    this.mainEpisodeNumbers = const [],
    this.isMovieHint = false,
    required this.variants,
    this.inventory,
    this.slotAssignmentsByPath = const {},
    this.physicalRootFolder,
    this.isSplitCluster = false,
    this.titleHints = const [],
    this.fileHints = const [],
    this.extraSearchQueries = const [],
    this.parentTmdbId,
    this.parentTmdbType,
    this.allowParentTmdbCandidate = false,
    this.ignoreExplicitTmdb = false,
    this.assetScopesByPath = const {},
  });

  /// 作品根目录相对路径（合集拆分时为虚拟簇标识如 `dir::movie`）。
  final String folderRelativePath;

  /// 作品根目录名称。
  final String folderName;

  /// 清洗后的候选作品名。
  final String cleanTitle;

  /// 从文件夹命名或 `.nfo` 提取的显式 TMDB ID。
  final int? explicitTmdbId;

  /// 显式媒体类型（`tv` 或 `movie`）。
  final TmdbMediaType? explicitMediaType;

  /// 目录年份提示。
  final int? year;

  /// 目录或折叠季子目录提示的目标季号。
  final int? seasonHint;

  /// 归属正片的已识别集号升序列表（用于 WorkMatcher 季级集数消歧）。
  final List<int> mainEpisodeNumbers;

  /// 是否具有明显电影/剧场版特征。
  final bool isMovieHint;

  /// 归属该作品下的全部物理媒体资产（含正片、特典、CD 专辑、扫图画廊）。
  final List<MediaVariant> variants;

  /// 来自 `feat/scrape-pipeline` 目录分析器的完整目录画像。
  final DirectoryInventory? inventory;

  /// 每个视频相对路径对应的预解析剧集/特典槽位。
  final Map<String, EpisodeSlotAssignment> slotAssignmentsByPath;

  /// 物理父目录相对路径（合集拆分前真实目录；未拆分时可为空或等于 `folderRelativePath`）。
  final String? physicalRootFolder;

  /// 是否属于多作品合集拆分出的子簇。
  final bool isSplitCluster;

  /// 从目录层级提取的多候选检索词（高可信度优先）。
  final List<String> titleHints;

  /// 从文件名提取的多候选检索词。
  final List<String> fileHints;

  /// 合集拆分子簇从父目录继承的补充检索词（如 `Accel World EX` / `OAD` / `OVA`）。
  final List<String> extraSearchQueries;

  /// 合集父目录上标注的显式 TMDB ID（若子簇自身无显式 ID 时继承供补充线索）。
  final int? parentTmdbId;

  /// 合集父目录显式 TMDB 类型。
  final TmdbMediaType? parentTmdbType;

  /// 当子簇为特典/OVA 且独立检索无果时，允许回退匹配父系列 TMDB 条目。
  final bool allowParentTmdbCandidate;

  /// 显式 ID 404 失效回退时忽略目录上的 `{tmdb-N}` 标记避免罚分。
  final bool ignoreExplicitTmdb;

  /// 各物理文件在系列中的默认共享/独占作用域预设。
  final Map<String, SupplementaryAssetScope> assetScopesByPath;

  /// 当目录存在正片集号（或已识别为 TV 剧集）且未显式标记为电影或覆写媒体类型时，
  /// TMDB 候选检索仅锁定 `/search/tv`，避免同名冷门电影（如无背景图条目）污染结果。
  bool get prefersTvSearch =>
      !isMovieHint &&
      explicitMediaType == null &&
      (mainEpisodeNumbers.isNotEmpty || inventory?.shape == WorkShape.series);

  /// 返回清除失效显式 TMDB 约束后的拷贝（用于 404 回落搜索时消除误罚分）。
  GroupedWorkFolder withoutExplicitTmdb() {
    return GroupedWorkFolder(
      folderRelativePath: folderRelativePath,
      folderName: folderName,
      cleanTitle: cleanTitle,
      explicitTmdbId: null,
      explicitMediaType: null,
      year: year,
      seasonHint: seasonHint,
      mainEpisodeNumbers: mainEpisodeNumbers,
      isMovieHint: isMovieHint,
      variants: variants,
      inventory: inventory,
      slotAssignmentsByPath: slotAssignmentsByPath,
      physicalRootFolder: physicalRootFolder,
      isSplitCluster: isSplitCluster,
      titleHints: titleHints,
      fileHints: fileHints,
      extraSearchQueries: extraSearchQueries,
      parentTmdbId: parentTmdbId,
      parentTmdbType: parentTmdbType,
      allowParentTmdbCandidate: allowParentTmdbCandidate,
      ignoreExplicitTmdb: true,
      assetScopesByPath: assetScopesByPath,
    );
  }
}

/// 扫描阶段发现的原始文件输入记录。
class ScannedFileInput {
  /// 创建文件输入记录。
  const ScannedFileInput({
    required this.relativePath,
    required this.fileName,
    required this.fileSize,
    required this.assetKind,
    this.externalSubtitles = const [],
    this.subtitleGroupHint,
  });

  /// 相对于媒体源根目录的 POSIX 路径。
  final String relativePath;

  /// 纯文件名。
  final String fileName;

  /// 文件字节大小。
  final int fileSize;

  /// 资产类型（视频/音频 CD/扫图）。
  final AssetKind assetKind;

  /// 已匹配的外挂字幕相对路径列表。
  final List<String> externalSubtitles;

  /// 字幕文件名附带的字幕组提示。
  final String? subtitleGroupHint;
}

/// 作品目录拓扑归拢器：将多压制组、多季目录、CD/Scan 附属子目录折叠为独立作品组。
class DirectoryGrouper {
  const DirectoryGrouper._();

  static final RegExp _movieMarkerPattern = RegExp(
    r'\b(?:movie|film|theatrical)\b|剧场版|劇場版',
    caseSensitive: false,
  );

  /// 从 `.nfo` 文本提取显式 TMDB ID 与媒体类型。
  static ({int? tmdbId, TmdbMediaType? mediaType}) parseNfoText(
    String nfoContent,
  ) {
    final lower = nfoContent.toLowerCase();
    final isMovie = lower.contains('<movie');
    final isTv = lower.contains('<tvshow');
    final type = isMovie
        ? TmdbMediaType.movie
        : (isTv ? TmdbMediaType.tv : null);

    final direct = RegExp(
      r'<tmdbid>\s*(\d+)\s*</tmdbid>',
      caseSensitive: false,
    ).firstMatch(nfoContent);
    if (direct != null) {
      return (tmdbId: int.tryParse(direct.group(1)!), mediaType: type);
    }

    final uniqueId = RegExp(
      r'<uniqueid[^>]*type=["\x27]tmdb["\x27][^>]*>\s*(\d+)\s*</uniqueid>',
      caseSensitive: false,
    ).firstMatch(nfoContent);
    if (uniqueId != null) {
      return (tmdbId: int.tryParse(uniqueId.group(1)!), mediaType: type);
    }

    return (tmdbId: null, mediaType: type);
  }

  /// 将扫描到的所有文件按所属作品归拢为强类型列表。
  static List<GroupedWorkFolder> groupFiles({
    required String sourceId,
    required List<ScannedFileInput> files,
    Map<String, String> nfoByFolder = const {},
  }) {
    final rawBuckets = <String, List<ScannedFileInput>>{};
    for (final file in files) {
      final workFolder = _resolveWorkFolder(file.relativePath);
      rawBuckets.putIfAbsent(workFolder, () => []).add(file);
    }

    final buckets = <String, List<ScannedFileInput>>{};
    final hasRootVideo =
        rawBuckets['']?.any((f) => f.assetKind == AssetKind.video) ?? false;
    final videoFolderKeys = rawBuckets.entries
        .where(
          (e) =>
              e.key.isNotEmpty &&
              e.value.any((f) => f.assetKind == AssetKind.video),
        )
        .map((e) => e.key)
        .toSet();

    for (final entry in rawBuckets.entries) {
      if (entry.key.isNotEmpty &&
          !videoFolderKeys.contains(entry.key) &&
          SupplementaryFolderRules.isAudioOrScanPath(entry.key)) {
        final ancestor = _findNearestAncestorFolder(entry.key, videoFolderKeys);
        if (ancestor != null) {
          buckets.putIfAbsent(ancestor, () => []).addAll(entry.value);
          continue;
        }
        if (hasRootVideo) {
          buckets.putIfAbsent('', () => []).addAll(entry.value);
          continue;
        }
      }
      buckets.putIfAbsent(entry.key, () => []).addAll(entry.value);
    }

    final result = <GroupedWorkFolder>[];
    for (final entry in buckets.entries) {
      final videoFiles = entry.value
          .where((e) => e.assetKind == AssetKind.video)
          .toList();
      if (videoFiles.isEmpty) continue;

      final folderPath = entry.key;
      final folderName = _lastSegment(folderPath);
      final folderHint = BdripParser.parseFolderName(folderName);
      final nfoHint = parseNfoText(nfoByFolder[folderPath] ?? '');

      final explicitTmdbId = nfoHint.tmdbId ?? folderHint.tmdbId;
      final explicitType = nfoHint.mediaType ?? folderHint.tmdbMediaType;

      final variants = <MediaVariant>[];
      final parsedVideos = <ParsedBdripRelease>[];
      for (final file in entry.value) {
        final parsed = file.assetKind == AssetKind.video
            ? BdripParser.parseFileName(
                file.fileName,
                relativePath: file.relativePath,
                folderTitle: folderHint.cleanTitle,
                folderSeasonHint: folderHint.season,
              )
            : null;
        if (parsed != null) parsedVideos.add(parsed);
        variants.add(
          MediaVariant(
            id: '$sourceId::${file.relativePath}',
            workId: '$sourceId::$folderPath',
            sourceId: sourceId,
            relativePath: file.relativePath,
            fileName: file.fileName,
            fileSize: file.fileSize,
            assetKind: file.assetKind,
            releaseGroup: parsed?.releaseGroup,
            subtitleGroup: parsed?.subtitleGroup ?? file.subtitleGroupHint,
            videoCodec: parsed?.videoCodec,
            bitDepth: parsed?.bitDepth,
            resolution: parsed?.resolution,
            audioCodec: parsed?.audioCodec,
            externalSubtitles: file.externalSubtitles,
          ),
        );
      }

      // 第一轮收集强正片集号，并应用连续序列缺口防误降级保护。
      final strongMainEps = <int>{};
      final mainSeasons = <int>{};
      for (final p in parsedVideos) {
        if (p.category == EpisodeCategory.main) {
          mainSeasons.add(p.season);
          if (p.episode != null) strongMainEps.add(p.episode!);
        }
      }

      final mainEpisodeSet = <int>{...strongMainEps};
      var effectiveMainCount = parsedVideos
          .where((p) => p.category == EpisodeCategory.main)
          .length;
      ParsedBdripRelease? singleMainCandidate;
      for (final p in parsedVideos) {
        if (p.category == EpisodeCategory.main) {
          singleMainCandidate ??= p;
        } else if (shouldRestoreWeakExtraToMain(p, strongMainEps)) {
          effectiveMainCount++;
          mainSeasons.add(p.season);
          if (p.episode != null) mainEpisodeSet.add(p.episode!);
        }
      }

      var cleanTitle = folderHint.cleanTitle;
      if (cleanTitle.isEmpty && videoFiles.isNotEmpty) {
        cleanTitle = BdripParser.parseFileName(
          videoFiles.first.fileName,
          relativePath: videoFiles.first.relativePath,
        ).cleanTitle;
      }

      final sortedMainEps = mainEpisodeSet.toList()..sort();
      final resolvedSeasonHint =
          folderHint.season ??
          (mainSeasons.length == 1 && mainSeasons.first > 1
              ? mainSeasons.first
              : null);

      final isMovieHint =
          explicitType == TmdbMediaType.movie ||
          _movieMarkerPattern.hasMatch(folderName) ||
          (effectiveMainCount == 1 &&
              singleMainCandidate != null &&
              singleMainCandidate.episode == null);

      result.add(
        GroupedWorkFolder(
          folderRelativePath: folderPath,
          folderName: folderName,
          cleanTitle: cleanTitle,
          explicitTmdbId: explicitTmdbId,
          explicitMediaType: explicitType,
          year: folderHint.year,
          seasonHint: resolvedSeasonHint,
          mainEpisodeNumbers: List.unmodifiable(sortedMainEps),
          isMovieHint: isMovieHint,
          variants: variants,
        ),
      );
    }

    return result;
  }

  static String _resolveWorkFolder(String relativePath) {
    final segments = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.length <= 1) return '';
    final parentSegments = segments.sublist(0, segments.length - 1);

    var firstSuppIndex = -1;
    for (var i = 1; i < parentSegments.length; i++) {
      if (SupplementaryFolderRules.isSupplementarySegment(parentSegments[i])) {
        firstSuppIndex = i;
        break;
      }
    }
    if (firstSuppIndex > 0) {
      return parentSegments.sublist(0, firstSuppIndex).join('/');
    }

    while (parentSegments.length > 1 &&
        SupplementaryFolderRules.isSupplementarySegment(parentSegments.last)) {
      parentSegments.removeLast();
    }
    return parentSegments.join('/');
  }

  static String? _findNearestAncestorFolder(
    String folderPath,
    Set<String> candidates,
  ) {
    if (folderPath.isEmpty) return null;
    final parts = folderPath.split('/');
    for (var len = parts.length - 1; len >= 1; len--) {
      final candidate = parts.sublist(0, len).join('/');
      if (candidates.contains(candidate)) return candidate;
    }
    return candidates.contains('') ? '' : null;
  }

  static String _lastSegment(String path) {
    if (path.isEmpty) return 'Root';
    final idx = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }
}
