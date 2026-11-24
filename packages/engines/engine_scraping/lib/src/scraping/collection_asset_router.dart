import '../matching/directory_grouper.dart';
import '../matching/supplementary_folder_rules.dart';
import '../models/episode.dart';
import '../models/media_variant.dart';
import '../parsing/bdrip_parser.dart';
import 'directory_analyzer.dart';

/// 待分流目标子作品桶的匹配特征摘要。
class CollectionTargetDescriptor {
  /// 创建目标子作品描述符。
  const CollectionTargetDescriptor({
    required this.key,
    required this.seasonNumber,
    required this.isMovie,
    required this.titleTokens,
    this.partIndex,
  });

  /// 目标桶标识（如子目录路径或拆簇 slug）。
  final String key;

  /// 目标季号（未知可为空）。
  final int? seasonNumber;

  /// 是否属于电影 / 剧场版条目。
  final bool isMovie;

  /// 用于匹配特定篇章关键词（如 `code`, `white`, `ova`）的规范化词元集合。
  final Set<String> titleTokens;

  /// 多篇章剧场版/分部作品的序位（如前篇/前編/zenpen/Part 1 -> `1`，后篇/後編/kouhen/Part 2 -> `2`）。
  final int? partIndex;
}

/// 纯领域合集附属资源（特典 / CD / Scan）共享与单季独占智能分流器。
abstract final class CollectionAssetRouter {
  static final RegExp _explicitSeasonTag = RegExp(
    r'(?:^|[\s._\-\[\]()/])(?:'
    r's(?:eason)?[\s._\-]*0?([1-9]\d?)(?=$|[\s._\-\[\]()/e])|'
    r'第\s*([1-9]\d?)\s*[季期]'
    r')',
    caseSensitive: false,
  );

  static final RegExp _movieToken = RegExp(
    r'(?:^|[\s._\-\[\]()/])(?:movie|film|theatrical|剧场版|劇場版)(?=$|[\s._\-\[\]()/])',
    caseSensitive: false,
  );

  static final RegExp _partOneWord = RegExp(
    r'前[篇編编]|上[篇部]|(?:^|[\s._\-\[\]()/])zenpen(?=$|[\s._\-\[\]()/])',
    caseSensitive: false,
  );

  static final RegExp _partTwoWord = RegExp(
    r'[后後][篇編编]|下[篇部]|(?:^|[\s._\-\[\]()/])kouhen(?=$|[\s._\-\[\]()/])',
    caseSensitive: false,
  );

  static final RegExp _explicitNumericPart = RegExp(
    r'(?:^|[\s._\-\[\]()/])(?:'
    r'(?:part|chapter|act|movie|film)[\s._\-]*0?([1-9])(?=$|[\s._\-\[\]()/])|'
    r'part[\s._\-]*(iii|ii|i)(?=$|[\s._\-\[\]()/])|'
    r'第\s*([1-9一二三四五六七八九])\s*[部篇章幕]'
    r')',
    caseSensitive: false,
  );

  static final RegExp _explicitVolumeTag = RegExp(
    r'(?:^|[\s._\-\[\]()/])vol(?:ume)?[\s._\-]*0?([1-9]\d?)(?=$|[\s._\-\[\]()/])',
    caseSensitive: false,
  );

  static const Map<String, int> _zhDigitToInt = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };

  /// 从标题、文件名或子目录路径中提取多部剧场版/前后篇序号（1 起）。
  ///
  /// 统一对齐中文（前篇/后篇/第一章）、日文汉字（前編/後編）、罗马音（zenpen/kouhen）与英文（Part 1/Movie 2）；
  /// 仅当 [allowVolume] 为 `true`（同目录全部子簇均为带序号的分部剧场版且卷号不越界）时，才把 `Vol.01`/`Vol.02` 视为分部序号。
  static int? extractPartIndex(String text, {bool allowVolume = false}) {
    if (text.trim().isEmpty) return null;
    final hasOne = _partOneWord.hasMatch(text);
    final hasTwo = _partTwoWord.hasMatch(text);
    if (hasOne && !hasTwo) return 1;
    if (hasTwo && !hasOne) return 2;

    final numMatch = _explicitNumericPart.firstMatch(text);
    if (numMatch != null) {
      final arabic = numMatch.group(1);
      if (arabic != null) return int.tryParse(arabic);
      final roman = numMatch.group(2)?.toLowerCase();
      if (roman == 'i') return 1;
      if (roman == 'ii') return 2;
      if (roman == 'iii') return 3;
      final zh = numMatch.group(3);
      if (zh != null) {
        return int.tryParse(zh) ?? _zhDigitToInt[zh];
      }
    }

    if (allowVolume) {
      final volMatch = _explicitVolumeTag.firstMatch(text);
      if (volMatch != null) {
        return int.tryParse(volMatch.group(1)!);
      }
    }
    return null;
  }

  static const Set<String> _genericIgnoreTokens = {
    'extra',
    'extras',
    'sp',
    'special',
    'specials',
    'cd',
    'cds',
    'ost',
    'scan',
    'scans',
    'booklet',
    'booklets',
    'menu',
    'menus',
    'pv',
    'cm',
    'mv',
    'ncop',
    'nced',
    'creditless',
    'op',
    'ed',
    'bdrip',
    '1080p',
    '2160p',
    '4k',
    'hevc',
    'avc',
    'flac',
    'x265',
    'x264',
    '10bit',
    'ma10p',
    'hi10p',
    'season',
    'series',
    'ova',
    'oad',
    'disc',
  };

  /// 从文件夹与子桶结构中将「仅含附属特典/CD/Scan 的合集父目录」无损分流至子作品桶。
  ///
  /// 返回每个子桶应附加的父目录提示映射（`bucketKey -> physicalCollectionRoot`）
  /// 及每个物理文件的默认作用域（`relativePath -> SupplementaryAssetScope`）。
  static ({
    Map<String, String> physicalRootByBucket,
    Map<String, SupplementaryAssetScope> assetScopeByPath,
  })
  foldParentCollectionExtras(Map<String, List<ScannedFileInput>> buckets) {
    final physicalRootByBucket = <String, String>{};
    final assetScopeByPath = <String, SupplementaryAssetScope>{};

    final parentKeys = buckets.keys.where((k) => k.isNotEmpty).toList()
      ..sort((a, b) => a.length.compareTo(b.length));

    for (final parentKey in parentKeys) {
      final parentFiles = buckets[parentKey];
      if (parentFiles == null || parentFiles.isEmpty) continue;

      final childKeys =
          buckets.keys
              .where(
                (k) =>
                    k != parentKey &&
                    k.startsWith('$parentKey/') &&
                    buckets[k]!.any((f) => f.assetKind == AssetKind.video),
              )
              .toList()
            ..sort();
      if (childKeys.isEmpty) continue;

      final parentHasNonExtraMainVideo = parentFiles.any((f) {
        if (f.assetKind != AssetKind.video) return false;
        if (_hasSupplementaryAncestorSegment(f.relativePath, parentKey)) {
          return false;
        }
        final parsed = BdripParser.parseFileName(
          f.fileName,
          relativePath: f.relativePath,
        );
        return parsed.category == EpisodeCategory.main;
      });
      if (parentHasNonExtraMainVideo) continue;

      final descriptors = _buildChildDescriptors(parentKey, childKeys, buckets);
      if (descriptors.isEmpty) continue;

      for (final child in descriptors) {
        physicalRootByBucket[child.key] = parentKey;
      }

      final primaryChildKey = _selectPrimaryTargetKey(descriptors);
      for (final file in parentFiles) {
        final routed = routeSupplementaryFile(
          file: file,
          collectionRoot: parentKey,
          targets: descriptors,
          primaryTargetKey: primaryChildKey,
        );
        buckets.putIfAbsent(routed.targetKey, () => []).add(file);
        assetScopeByPath[file.relativePath] = routed.scope;
      }
      buckets.remove(parentKey);
    }

    return (
      physicalRootByBucket: physicalRootByBucket,
      assetScopeByPath: assetScopeByPath,
    );
  }

  /// 将单目录拆簇产生的非视频与附属文件按季/篇章标记分流至对应目标子簇或设为全系列共享。
  static ({
    Map<String, List<ScannedFileInput>> filesByClusterKey,
    Map<String, SupplementaryAssetScope> assetScopeByPath,
  })
  routeSplitClusterExtras({
    required String collectionRoot,
    required List<CollectionTargetDescriptor> targets,
    required List<ScannedFileInput> supplementaryFiles,
  }) {
    final filesByClusterKey = <String, List<ScannedFileInput>>{
      for (final t in targets) t.key: <ScannedFileInput>[],
    };
    final assetScopeByPath = <String, SupplementaryAssetScope>{};
    if (targets.isEmpty || supplementaryFiles.isEmpty) {
      return (
        filesByClusterKey: filesByClusterKey,
        assetScopeByPath: assetScopeByPath,
      );
    }
    final primaryKey = _selectPrimaryTargetKey(targets);
    final allowVolumeAsPart = _canTreatVolumeAsPart(
      collectionRoot: collectionRoot,
      targets: targets,
      supplementaryFiles: supplementaryFiles,
    );
    for (final file in supplementaryFiles) {
      final routed = routeSupplementaryFile(
        file: file,
        collectionRoot: collectionRoot,
        targets: targets,
        primaryTargetKey: primaryKey,
        allowVolumeAsPart: allowVolumeAsPart,
      );
      filesByClusterKey.putIfAbsent(routed.targetKey, () => []).add(file);
      assetScopeByPath[file.relativePath] = routed.scope;
    }
    return (
      filesByClusterKey: filesByClusterKey,
      assetScopeByPath: assetScopeByPath,
    );
  }

  /// 判定单个附属文件（特典视频 / CD / Scan）的季/篇章归属与可见作用域。
  static ({String targetKey, SupplementaryAssetScope scope})
  routeSupplementaryFile({
    required ScannedFileInput file,
    required String collectionRoot,
    required List<CollectionTargetDescriptor> targets,
    required String primaryTargetKey,
    bool allowVolumeAsPart = false,
  }) {
    final relFromRoot = _stripPrefix(file.relativePath, collectionRoot);

    // 1. 优先识别明确季号标记（如 `Scan S3`、`NCOP S2`、`Season 3`、`第3季`）。
    final explicitSeason = _extractSeasonNumber(relFromRoot);
    if (explicitSeason != null) {
      for (final target in targets) {
        if (target.seasonNumber == explicitSeason) {
          return (
            targetKey: target.key,
            scope: SupplementaryAssetScope.workExclusive,
          );
        }
      }
    }

    // 1.5 多篇章/分部剧场版按篇章序位精准归属（如 `前編`/`zenpen`/`Vol.01` -> 前篇，`後編`/`kouhen`/`Vol.02` -> 后篇）。
    final explicitPart = extractPartIndex(
      relFromRoot,
      allowVolume: allowVolumeAsPart,
    );
    if (explicitPart != null) {
      final partMatches = targets
          .where((t) => t.partIndex == explicitPart)
          .toList(growable: false);
      if (partMatches.length == 1) {
        return (
          targetKey: partMatches.single.key,
          scope: SupplementaryAssetScope.workExclusive,
        );
      }
    }

    // 2. 次优识别明确剧场版或特定篇章名称（如 `Code White PV`），多部剧场版打平时不偏袒字典序首位。
    final fileTokens = _extractMeaningfulTokens(relFromRoot);
    final hasMovieWord = _movieToken.hasMatch(relFromRoot);
    CollectionTargetDescriptor? bestMatch;
    var bestScore = 0;
    var secondBestScore = 0;

    for (final target in targets) {
      var score = 0;
      if (hasMovieWord && target.isMovie) {
        score += 2;
      }
      if (target.titleTokens.isNotEmpty) {
        final overlap = target.titleTokens.intersection(fileTokens).length;
        if (overlap >= 2 || (target.titleTokens.length == 1 && overlap == 1)) {
          score += overlap * 3;
        }
      }
      if (score > bestScore) {
        secondBestScore = bestScore;
        bestScore = score;
        bestMatch = target;
      } else if (score > secondBestScore) {
        secondBestScore = score;
      }
    }

    if (bestMatch != null && bestScore >= 2 && bestScore > secondBestScore) {
      return (
        targetKey: bestMatch.key,
        scope: SupplementaryAssetScope.workExclusive,
      );
    }

    // 3. 无明确季或特定篇章标识（如 `Extra/CD`、`Extra/Creditless`、`Extra/Menu`、`Extra/PV`、`Extra/MV`）
    // 自动标记为「系列共享」，挂载在首部作品下对全系列下拉切换开放共享查看。
    return (
      targetKey: primaryTargetKey,
      scope: SupplementaryAssetScope.seriesShared,
    );
  }

  /// 仅当全部目标子簇均为带唯一篇章序位的剧场版且待分派文件里的 `Vol.N` 均未超出最大分部数时，
  /// 才将 `Scans/Vol.01`、`Scans/Vol.02` 与多部剧场版一一对应，避免误分 TV 6 卷 BD Scan。
  static bool _canTreatVolumeAsPart({
    required String collectionRoot,
    required List<CollectionTargetDescriptor> targets,
    required List<ScannedFileInput> supplementaryFiles,
  }) {
    if (targets.length < 2) return false;
    final partSet = <int>{};
    var maxPart = 0;
    for (final t in targets) {
      if (!t.isMovie || t.partIndex == null || t.partIndex! <= 0) return false;
      partSet.add(t.partIndex!);
      if (t.partIndex! > maxPart) maxPart = t.partIndex!;
    }
    if (partSet.length != targets.length) return false;

    for (final file in supplementaryFiles) {
      final rel = _stripPrefix(file.relativePath, collectionRoot);
      final volMatch = _explicitVolumeTag.firstMatch(rel);
      if (volMatch == null) continue;
      final volNum = int.tryParse(volMatch.group(1)!);
      if (volNum == null || volNum <= 0 || volNum > maxPart) {
        return false;
      }
    }
    return true;
  }

  static List<CollectionTargetDescriptor> _buildChildDescriptors(
    String parentKey,
    List<String> childKeys,
    Map<String, List<ScannedFileInput>> buckets,
  ) {
    final parentTokens = _extractMeaningfulTokens(parentKey);
    final out = <CollectionTargetDescriptor>[];
    for (final childKey in childKeys) {
      final files = buckets[childKey] ?? const [];
      final relLeaf = _stripPrefix(childKey, parentKey);
      final videos = files
          .where((f) => f.assetKind == AssetKind.video)
          .toList(growable: false);
      final relVideos = [
        for (final v in videos)
          (
            path: _stripPrefix(v.relativePath, childKey),
            size: v.fileSize > 0 ? v.fileSize : null,
          ),
      ];
      final inv = DirectoryAnalyzer.analyze(childKey, relVideos);
      final season = _extractSeasonNumber(relLeaf) ?? inv.season;
      final isMovie = inv.movieMarker || _movieToken.hasMatch(relLeaf);
      final leafTokens = _extractMeaningfulTokens(relLeaf)
        ..removeAll(parentTokens);

      out.add(
        CollectionTargetDescriptor(
          key: childKey,
          seasonNumber: season,
          isMovie: isMovie,
          titleTokens: Set.unmodifiable(leafTokens),
          partIndex: extractPartIndex(relLeaf),
        ),
      );
    }
    return out;
  }

  static String _selectPrimaryTargetKey(
    List<CollectionTargetDescriptor> targets,
  ) {
    final nonMovies = targets
        .where((t) => !t.isMovie && (t.seasonNumber ?? 1) > 0)
        .toList();
    if (nonMovies.isNotEmpty) {
      nonMovies.sort(
        (a, b) => (a.seasonNumber ?? 1).compareTo(b.seasonNumber ?? 1),
      );
      return nonMovies.first.key;
    }
    final indexed = targets.where((t) => t.partIndex != null).toList();
    if (indexed.isNotEmpty) {
      indexed.sort((a, b) => a.partIndex!.compareTo(b.partIndex!));
      return indexed.first.key;
    }
    return targets.first.key;
  }

  static bool _hasSupplementaryAncestorSegment(
    String relativePath,
    String parentKey,
  ) {
    final rel = _stripPrefix(relativePath, parentKey);
    final parts = rel.split('/');
    if (parts.length <= 1) return false;
    for (var i = 0; i < parts.length - 1; i++) {
      if (SupplementaryFolderRules.isSupplementarySegment(parts[i]) &&
          !SupplementaryFolderRules.isSeasonOrVolumeSegment(parts[i])) {
        return true;
      }
    }
    return false;
  }

  static int? _extractSeasonNumber(String text) {
    final m = _explicitSeasonTag.firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1) ?? m.group(2);
    return raw == null ? null : int.tryParse(raw);
  }

  static final RegExp _squareBrackets = RegExp(r'\[[^\]]*\]');
  static final RegExp _curlyBrackets = RegExp(r'\{[^}]*\}');
  static final RegExp _meaningfulTokenPattern = RegExp(
    r'[a-z]{3,}|[\u4e00-\u9fff]{2,}',
  );
  static final RegExp _edgeSlashes = RegExp(r'^/+|/+$');

  static Set<String> _extractMeaningfulTokens(String raw) {
    final cleaned = raw
        .toLowerCase()
        .replaceAll(_squareBrackets, ' ')
        .replaceAll(_curlyBrackets, ' ');
    final matches = _meaningfulTokenPattern.allMatches(cleaned);
    final tokens = <String>{};
    for (final m in matches) {
      final tok = m.group(0)!;
      if (!_genericIgnoreTokens.contains(tok)) {
        tokens.add(tok);
      }
    }
    return tokens;
  }

  static String _stripPrefix(String path, String prefix) {
    final normPath = path.replaceAll('\\', '/');
    final normPrefix = prefix
        .replaceAll('\\', '/')
        .replaceAll(_edgeSlashes, '');
    if (normPrefix.isEmpty) return normPath;
    if (normPath.startsWith('$normPrefix/')) {
      return normPath.substring(normPrefix.length + 1);
    }
    return normPath;
  }
}
