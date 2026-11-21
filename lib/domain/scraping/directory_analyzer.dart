import 'package:path/path.dart' as p;

import '../models/media_extensions.dart';
import 'cloud_media_asset_presentation.dart';
import 'cloud_media_file_classifier.dart';
import 'personal_filename_parser.dart';
import 'title_normalizer.dart';
import 'work_season.dart';

/// 仅依据相对路径与文件字节大小推导的作品目录清单画像；
/// 纯确定性计算，零网络请求与视频解码读取，可高频应用于全量扫描。
enum WorkShape {
  /// 单个逻辑正片单元（剧场版或单集 OVA），可合并多个不同压制版本。
  feature,

  /// 包含两集及以上逻辑正片剧集的连续作品。
  series,

  /// 单目录混杂多部互不关联作品的合集形态，严禁自动绑定单线条目。
  anthology,

  /// 不包含任何可播正片内容（仅含特典映像或样片/花絮目录）。
  empty,
}

class LogicalItem {
  LogicalItem(
    this.key,
    this.title,
    this.episode,
    this.season, {
    this.episodeEnd,
  });
  final String key, title;
  final int? episode, season;

  /// 多集合并文件的区间结束集号（`null` 表示单集；非空时必大于 [episode]）。
  final int? episodeEnd;
  final List<String> files = [];

  /// 归并至同一正片逻辑条目下的各压制版本归一化系列标题。
  final List<String> titles = [];
}

class DirectoryInventory {
  DirectoryInventory._({
    required this.folder,
    required this.title,
    required this.year,
    required this.tmdbId,
    required this.tmdbType,
    required this.bangumiId,
    required this.season,
    required this.folderMovieMarker,
    required this.fileMovieMarker,
    required this.main,
    required this.extras,
    required this.shape,
    required this.titleHints,
    required this.fileHints,
  });

  DirectoryInventory.synthetic({
    required String folder,
    required String title,
    int? year,
    int? tmdbId,
    String? tmdbType,
    int? bangumiId,
    int? season,
    bool folderMovieMarker = false,
    bool fileMovieMarker = false,
    required List<LogicalItem> main,
    List<String> extras = const [],
    required WorkShape shape,
    required List<String> titleHints,
    List<String> fileHints = const [],
  }) : this._(
         folder: folder,
         title: title,
         year: year,
         tmdbId: tmdbId,
         tmdbType: tmdbType,
         bangumiId: bangumiId,
         season: season,
         folderMovieMarker: folderMovieMarker,
         fileMovieMarker: fileMovieMarker,
         main: main,
         extras: extras,
         shape: shape,
         titleHints: titleHints,
         fileHints: fileHints,
       );

  final String folder, title;
  final int? year, tmdbId, bangumiId, season;
  final String? tmdbType;

  /// The user wrote 剧场版 / Movie in the folder name.
  final bool folderMovieMarker;

  /// 仅文件名包含剧场版关键词的弱电影特征信号。
  final bool fileMovieMarker;
  final List<LogicalItem> main;
  final List<String> extras;
  final WorkShape shape;

  /// 由目录名解析出的候选标题列表，按置信度从高到低排列。
  final List<String> titleHints;

  /// 由文件名解析出的候选标题列表（涵盖罗马音、原名及副标题）。
  final List<String> fileHints;

  /// 自身目录未显式标注 TMDB 编号且非虚拟拆簇路径时，提取直接父目录名中的 TMDB 编号（如 `物语系列 第二季 (2013) {tmdb-46195}/囮物语`）。
  int? get parentFolderTmdbId {
    if (tmdbId != null || folder.contains('::')) return null;
    final segs = folder
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segs.length < 2) return null;
    return PersonalFilenameParser.tmdbId(segs[segs.length - 2]);
  }

  /// 提取直接父目录清洗后的名称与年份（跳过纯分类或系列合集外层目录），用于识别如 `物语系列 第二季 (2013)/囮物语` 的季级归属。
  ({String title, int? year})? get parentFolderInfo {
    if (folder.contains('::')) return null;
    final segs = folder
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segs.length < 2) return null;
    final rawParent = segs[segs.length - 2].trim();
    if (rawParent.isEmpty) return null;
    if (RegExp(
      r'(?:系列|作品集|合集|Collection)$|^(?:动画|番剧|电影|动漫|未添加TMDB)',
      caseSensitive: false,
    ).hasMatch(rawParent)) {
      return null;
    }
    final clean = DirectoryAnalyzer.cleanTitle(rawParent);
    if (clean.length < 2) return null;
    final pYear = WorkSeason.year({'title': rawParent});
    return (title: clean, year: pYear);
  }

  Set<int> get episodes => {
    for (final item in main)
      if (item.episode != null)
        for (
          var e = item.episode!;
          e <= (item.episodeEnd ?? item.episode!);
          e++
        )
          e,
  };
  int get episodeCount => episodes.length;
  int get featureCount => main.where((item) => item.episode == null).length;
  bool get movieMarker => folderMovieMarker || fileMovieMarker;

  DirectoryInventory withExplicitIds({
    int? tmdbId,
    String? tmdbType,
    int? bangumiId,
  }) => DirectoryInventory._(
    folder: folder,
    title: title,
    year: year,
    tmdbId: this.tmdbId ?? tmdbId,
    tmdbType: this.tmdbType ?? tmdbType,
    bangumiId: this.bangumiId ?? bangumiId,
    season: season,
    folderMovieMarker: folderMovieMarker,
    fileMovieMarker: fileMovieMarker,
    main: main,
    extras: extras,
    shape: shape,
    titleHints: titleHints,
    fileHints: fileHints,
  );

  @override
  String toString() =>
      '$shape "$title" y=$year eps=$episodeCount features=$featureCount '
      'tmdb=$tmdbType:$tmdbId bgm=$bangumiId hints=$titleHints files=$fileHints';
}

abstract final class DirectoryAnalyzer {
  static final _movieMarker = RegExp(
    r'剧场版|劇場版|映画|gekijou?ban|(?:^|[^a-z])(?:the[ ._-]+)?movie(?:[^a-z]|$)|'
    r'(?:^|[^a-z])film(?:[ ._-]*\d)?(?:[^a-z]|$)',
    caseSensitive: false,
  );
  static final _ovaMarker = RegExp(
    r'(?:^|[^a-z])(?:ova|oad|oav|oab)(?:[^a-z]|$)',
    caseSensitive: false,
  );

  /// 语义明确的纯附属影像词汇：即便目录内单独存在，也不视作正片。
  static final _unambiguousExtra = RegExp(
    r'(?<![a-z0-9])(?:nc(?:op|ed)\w*|pv\w*|cm\w*|menus?(?:[ ._-]*ex)?\d*|'
    r'menue\d*|hauptmenue|vorschau|'
    r'music[ ._-]*(?:video|clip)|mv[ ._-]*making|'
    r'trailers?\d*|teasers?\d*|previews?\d*|samples?\d*|drama[ ._-]*cd|'
    r'making|commentary|eyecatch|karaoke|'
    r'tv[ ._-]*cm|bd[ ._-]*cm|bd[ ._-]*menu\w*|'
    r'bd[ ._-]*sp[ ._-]*live\w*|bd[ ._-]*special[ ._-]*talk|'
    r'tokuten[ ._-]*dvd)(?![a-z0-9])|'
    r'[\[(【]\s*(?<![a-z0-9])(?:op|ed)\d*(?:v\d+)?(?![a-z0-9])\s*[\])】]|'
    r'[\[(（【]\s*mv\s*[\])）】]|'
    r'[\[【]\s*\d{1,3}\s*[\(（]\s*(?:oad|ova\d*|sp\d*|special)\s*[\)）]\s*[\]】]|'
    r'予告|預告|预告|特報|メニュ|メイキング|映像特典|ノンクレ|'
    r'プロモーション映像|劇場アナウンス|'
    r'アイキャッチ(?:集)?|オーディオ[ ._-]*コメンタリー|'
    r'(?:ミュージック|ミコージック)[ ._-・]*(?:ビデオ|クリップ)',
    caseSensitive: false,
  );

  /// 上下文敏感的特典词汇：同存正片或体积偏小时判作特典；
  /// 但若独立大型正片（体积 >= 150 MB）标题恰好包含 `Event`/`Talk`/`MV` 等词，
  /// 绝不能被误清为空目录 `[WorkShape.empty]`；`OP/ED` 另外通过严格边界校验识别。
  /// 详见 `[CloudMediaFileClassifier.isOpEdExtra]`。
  static final _ambiguousExtra = RegExp(
    r'(?<![a-z0-9])(?:interviews?|events?|talk|radio|logo|gallery|advice|'
    r'mv|music[ ._-]*clip|spots?|info|supporters?|digest|recap|'
    r'picture[ ._-]*drama|sp[ ._-]*live\w*|special[ ._-]*talk|tokuten|'
    r'prologue[ ._-]+to[ ._-]+the[ ._-]+movie)(?:[ ._-]*\d+)?(?![a-z0-9])|'
    r'インタビュー|イベント|トーク|ラジオ|特典|宣伝|スポット|座談会|上映会|'
    r'ピクチャードラマ|スペシャル[ ._-]*映像|未公開(?:映像)?|'
    r'初日舞台挨拶|舞台挨拶|キャストトークショー|トークショー|'
    r'(?:tv[ ._-]*)?シリーズ[ ._-]*ガイド|ドキュメント[ ._-]*[#＃][ ._-]*\d+',
    caseSensitive: false,
  );

  static final _specialCollectionFolderSuffix = RegExp(
    r'^(.+?)(?:\s*[-–—_:：]\s*|\s+|[\s]*[\[(（【]\s*)'
    r'(?:extras?|specials|sps|特典|映像特典)(?:\s*[\])）】])?\s*$',
    caseSensitive: false,
  );

  /// 从纯特典合集目录中提取干净基础标题
  /// （如 `<标题> Extras`、`<标题> Specials`、`<标题> SPs`、`<标题> 特典` 或 `<标题> Extra`），
  /// 同时完整保留诸如 `Extra Stage` 等自身即带 Extra 的专有作品名称。
  static String? _extractSpecialCollectionTitle(String cleanFolderTitle) {
    final match = _specialCollectionFolderSuffix.firstMatch(cleanFolderTitle);
    if (match == null) return null;
    final base = match.group(1)?.trim() ?? '';
    return base.isEmpty ? null : base;
  }

  static const _minStandaloneFeatureBytes = 150 * 1024 * 1024;
  static const _minEpisodeReferenceBytes = 100 * 1024 * 1024;
  static const _maxTinyClipBytes = 120 * 1024 * 1024;

  static final _technical = RegExp(
    r'(?:^|[\s._\-\[(])(?:(?:19[5-9]\d|20[0-2]\d)[\s._-]+(?=.*\b\d{3,4}p\b)|'
    r'(?:480|576|720|1080|1440|2160|4320)[pi]\b|'
    r'(?:bd|uhd|web|dvd|hd)[ ._-]?(?:rip|dl|remux)\b|blu-?ray\b|remux\b|'
    r'\d{3,4}x\d{3,4}\b)',
    caseSensitive: false,
  );

  static final _bangumiMarker = RegExp(
    r'[\[{]\s*(?:bgm|bangumi)(?:id)?\s*[-=:_]\s*(\d+)\s*[\]}]',
    caseSensitive: false,
  );

  /// 参数 `[files]` 为相对于目录 `[folder]` 的路径列表（兼容 POSIX 与 Windows 分隔符）。
  ///
  /// [anchoredRoot] 表示该目录已按「标题 (年份)」或显式 ID 规范整理为单部作品，
  /// 此时目录名本身就是作品名，不再按 `<标题> Extra/Specials` 解读为纯特典合集。
  static DirectoryInventory analyze(
    String folder,
    Iterable<({String path, int? size})> files, {
    bool anchoredRoot = false,
  }) {
    final normalizedFolder = folder.replaceAll('\\', '/');
    final name = p.posix.basename(normalizedFolder);
    final supplementaryFolder =
        !anchoredRoot &&
        CloudMediaFileClassifier.isSupplementaryDirectory(name);
    final rawCleanTitle = cleanTitle(name);
    final specialCollectionTitle = supplementaryFolder || anchoredRoot
        ? null
        : _extractSpecialCollectionTitle(rawCleanTitle);
    final title = specialCollectionTitle ?? rawCleanTitle;
    final main = <String, LogicalItem>{};
    var soft = <({String path, int? size, bool ambiguous})>[];
    final extras = <String>[];
    final videoEntries = [
      for (final f in files)
        if (_isVideo(f.path))
          (path: f.path.replaceAll('\\', '/'), size: f.size),
    ];
    final sizeByPath = <String, int>{
      for (final v in videoEntries)
        if (v.size != null && v.size! > 0) v.path: v.size!,
    };

    final titleTokens = _pervasiveTitleTokens([
      for (final v in videoEntries) p.posix.basename(v.path),
    ]);
    for (final entry in videoEntries) {
      final path = entry.path;
      final file = p.posix.basename(path);
      final directory = p.posix.dirname(path) == '.'
          ? ''
          : p.posix.dirname(path);
      // 片名自带的特典词（如 `Shomin Sample`、`Special A`）不能作为特典判据，判定前先遮蔽。
      final maskedFile = _maskTokens(file, titleTokens);
      final cleanFile = CloudMediaFileClassifier.stripTechnicalNoise(
        maskedFile,
      );
      final plainFile = _plain(maskedFile);
      if (supplementaryFolder ||
          CloudMediaFileClassifier.isSupplementarySubdirectory(directory) ||
          _unambiguousExtra.hasMatch(plainFile) ||
          CloudMediaFileClassifier.isPreview(cleanFile) ||
          CloudMediaFileClassifier.isNoCredit(cleanFile)) {
        extras.add(path);
      } else if (_ambiguousExtra.hasMatch(plainFile) ||
          CloudMediaFileClassifier.isOpEdExtra(cleanFile)) {
        soft.add((path: path, size: entry.size, ambiguous: true));
      } else if (CloudMediaFileClassifier.isClearlySupplementary(
        directory,
        cleanFile,
      )) {
        soft.add((path: path, size: entry.size, ambiguous: false));
      } else {
        _add(main, directory, file, path);
      }
    }
    if (specialCollectionTitle != null) {
      // 纯特典合集目录（如 `<标题> Extras/Specials/SPs`）将非 OP/ED 的软特典项提升为候选正片，
      // 以便与 TMDB 第 0 季特别篇条目完成精确配对。
      for (final item in soft) {
        final file = p.posix.basename(item.path);
        if (CloudMediaFileClassifier.isOpEdExtra(file)) {
          extras.add(item.path);
          continue;
        }
        final directory = p.posix.dirname(item.path) == '.'
            ? ''
            : p.posix.dirname(item.path);
        _add(main, directory, file, item.path, promoted: true);
      }
    } else {
      soft = _protectContiguousMainEpisodes(
        main,
        soft,
        supplementaryFolder: supplementaryFolder,
      );
      // 独立 OVA / 特别版 / Extra Stage 目录：其中“特别篇”即为该作品主体；
      // 预告片与菜单绝不提升，语义模糊词汇仅在达到主片体量（>= 150 MB）时
      // 才允许提升识别为主正片。
      if (main.isEmpty && !supplementaryFolder) {
        for (final item in soft) {
          if (item.ambiguous &&
              (item.size == null || item.size! < _minStandaloneFeatureBytes)) {
            extras.add(item.path);
            continue;
          }
          final directory = p.posix.dirname(item.path) == '.'
              ? ''
              : p.posix.dirname(item.path);
          _add(
            main,
            directory,
            p.posix.basename(item.path),
            item.path,
            promoted: true,
          );
        }
      } else {
        for (final item in soft) {
          extras.add(item.path);
        }
        // 若无编号短片段体积不足中位单集大小 20% 且小于 120 MB，
        // 在多集正片 BDRip 目录中自动降级归类为附属特典。
        final epSizes = [
          for (final item in main.values)
            if (item.episode != null)
              for (final f in item.files)
                if (sizeByPath.containsKey(f)) sizeByPath[f]!,
        ]..sort();
        if (epSizes.length >= 3) {
          final median = epSizes[epSizes.length ~/ 2];
          if (median >= _minEpisodeReferenceBytes) {
            final demoteKeys = <String>[];
            for (final entry in main.entries) {
              if (entry.value.episode != null) continue;
              final itemSizes = [
                for (final f in entry.value.files)
                  if (sizeByPath.containsKey(f)) sizeByPath[f]!,
              ];
              if (itemSizes.isNotEmpty &&
                  itemSizes.length == entry.value.files.length &&
                  itemSizes.every(
                    (s) => s < median * 0.2 && s < _maxTinyClipBytes,
                  )) {
                demoteKeys.add(entry.key);
              }
            }
            for (final key in demoteKeys) {
              extras.addAll(main.remove(key)!.files);
            }
          }
        }
        // 单/多部大型剧场版目录下若同时平放了大量小体积无编号 BD 花絮短片（如图像剧/宣传片），
        // 当存在 1~3 部超大主片（>= 1.2 GB）且其余全部片段均不足主片 20% 且 < 450 MB 时，
        // 将小体积无编号短片降级归入特典，防止剧场版目录被误判为多作合集。
        if (epSizes.isEmpty &&
            main.length >= 4 &&
            main.values.every((item) => item.episode == null)) {
          final itemMaxSize = <String, int>{};
          var allSized = true;
          var globalMax = 0;
          for (final entry in main.entries) {
            final sizes = [
              for (final f in entry.value.files)
                if (sizeByPath.containsKey(f)) sizeByPath[f]!,
            ];
            if (sizes.length != entry.value.files.length || sizes.isEmpty) {
              allSized = false;
              break;
            }
            final largest = sizes.reduce((a, b) => a > b ? a : b);
            itemMaxSize[entry.key] = largest;
            if (largest > globalMax) globalMax = largest;
          }
          const minGiantFeatureBytes = 1200 * 1024 * 1024;
          const maxBonusClipBytes = 450 * 1024 * 1024;
          if (allSized && globalMax >= minGiantFeatureBytes) {
            final dominantKeys = [
              for (final e in itemMaxSize.entries)
                if (e.value >= globalMax * 0.35) e.key,
            ];
            final tinyKeys = [
              for (final e in itemMaxSize.entries)
                if (e.value < globalMax * 0.20 && e.value < maxBonusClipBytes)
                  e.key,
            ];
            if (dominantKeys.isNotEmpty &&
                dominantKeys.length <= 3 &&
                dominantKeys.length + tinyKeys.length == main.length) {
              for (final key in tinyKeys) {
                extras.addAll(main.remove(key)!.files);
              }
            }
          }
        }
      }
    }

    var items = main.values.toList();
    // 单个带编号的文件通常本身就是带序号的作品标题（如 `Legend 01`、`Movie 3`、`#02`），
    // 而非连续剧第 N 集，除非它显式带有标准剧集前缀标记。
    // (SxxExx, EPxx, E01, 第x話, 02v2, or bracketed/hyphen `[01]`/`- 01` without movie marker).
    final numbered = items.where((i) => i.episode != null).toList();
    if (numbered.length == 1) {
      final solePath = numbered.single.files.first;
      final soleBase = p.posix.basename(solePath);
      final hasMovieHint =
          _movieMarker.hasMatch(name) ||
          _movieMarker.hasMatch(_plain(soleBase));
      final hasStrictEpisodicMarker = RegExp(
        r'(?<![a-z0-9])(?:s\d{1,2}[ ._-]*e\d{1,4}|ep[ ._-]*\d{1,4}|e\d{1,4}|\d{1,3}v\d+)\b|'
        r'第\s*\d{1,3}\s*[话話集]',
        caseSensitive: false,
      ).hasMatch(soleBase);
      final hasBracketOrHyphenEpisode =
          !hasMovieHint &&
          RegExp(
            r'[\[【(]\s*0*\d{1,3}(?:\.\d+)?(?:\s*(?:end|fin|v\d+))?\s*[\]】)]|'
            r'(?:\s[-–—]\s+|#)0*\d{1,3}(?=$|\s*(?:\[|\(|【|\.[a-z0-9]{2,5}$))',
            caseSensitive: false,
          ).hasMatch(soleBase);
      if (!hasStrictEpisodicMarker && !hasBracketOrHyphenEpisode) {
        final only = numbered.single;
        final core = versionKey(soleBase);
        final feature = LogicalItem('f:$core', core, null, only.season)
          ..files.addAll(only.files)
          ..titles.add(core);
        items = [for (final i in items) identical(i, only) ? feature : i];
      }
    }

    bool meaningful(String title) =>
        title.length >= 3 && !RegExp(r'^[0-9a-f]{6,8}$').hasMatch(title);
    final episodeTitles = {
      for (final i in items)
        if (i.episode != null) ...i.titles.where(meaningful),
    };
    // 蓝光原盘流文件（`00000.m2ts`）等纯数字名不构成独立剧场版标题。
    final featureTitles = {
      for (final i in items)
        if (i.episode == null && meaningful(i.title)) i.title,
    };
    // 主干清晰、仅混有少量总集篇或短片花絮的目录仍属单一作品；
    // 只有同时包含多段规模相当的独立系列时才判定为混杂合集。
    final perSeries = <String, int>{};
    for (final item in items.where((i) => i.episode != null)) {
      for (final title in item.titles.where(meaningful)) {
        perSeries.update(title, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final episodic = perSeries.values.fold<int>(0, (a, b) => a + b);
    final dominant = perSeries.values.fold<int>(0, (a, b) => a > b ? a : b);
    // 每个“系列主干”都只出现在一集里：主干实为逐集副标题（`01 - 某某`、`Stage1`），
    // 而真正的混杂合集里各子系列都有多集且各自从第 1 集编号。
    final perEpisodeSubtitles =
        perSeries.isNotEmpty && perSeries.values.every((n) => n == 1);
    // 同季多配音/多剪辑平行版本（如 4 组完整 24 集且集号完全重合、不含 OVA1/Mk1 序号的变体）：
    // 仍属同一部剧集的多版本而非多作合集。
    final numberedItemCount = items.where((i) => i.episode != null).length;
    final parallelSameShowVersions =
        perSeries.length >= 2 &&
        dominant >= 12 &&
        numberedItemCount == dominant &&
        perSeries.values.every((n) => n == dominant) &&
        !perSeries.keys.any(
          (k) => RegExp(
            r'(?:ova|oad|mk|part|vol|season|s)\s*\d+',
            caseSensitive: false,
          ).hasMatch(k),
        );
    final WorkShape shape;
    if (items.isEmpty) {
      shape = WorkShape.empty;
    } else if (specialCollectionTitle == null &&
        (episodeTitles.length >= 4 &&
                dominant < episodic * 0.5 &&
                !perEpisodeSubtitles &&
                !parallelSameShowVersions ||
            featureTitles.length >= 6 &&
                featureTitles.length > episodeTitles.length * 4 &&
                numberedItemCount < 6)) {
      // 目录内混杂多部无关剧场版或外传系列（例如 SD 高达外传全集）。
      shape = WorkShape.anthology;
    } else if (items.any((i) => i.episode != null)) {
      shape = WorkShape.series;
    } else {
      shape = WorkShape.feature;
    }

    var multiSeasonStems = false;
    if (shape == WorkShape.series && specialCollectionTitle == null) {
      final separated = _separateSeriesStems(
        items: items,
        sizeByPath: sizeByPath,
        extras: extras,
        baseSeason: isMultiSeasonTitle(title)
            ? 1
            : (WorkSeason.explicit({'title': name}) ?? 1),
      );
      items = separated.items;
      multiSeasonStems = separated.multiSeason;
    }

    // 连续剧目录中无集号的视频（剧场版总集篇、OVA、特别篇、LIVE 等）不属于正片序列，
    // 只要编号正片占多数即整体降级为特典，交由特别篇槽位匹配。
    if (shape == WorkShape.series && specialCollectionTitle == null) {
      final numberedCount = items.where((i) => i.episode != null).length;
      final unnumbered = items.where((i) => i.episode == null).toList();
      if (numberedCount >= 2 &&
          unnumbered.isNotEmpty &&
          unnumbered.length < numberedCount) {
        for (final item in unnumbered) {
          extras.addAll(item.files);
        }
        items = [
          for (final item in items)
            if (item.episode != null) item,
        ];
      }
    }

    final fileHints = <String>[];
    void hint(List<String> target, String value) {
      final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.length < 2 || RegExp(r'^\d+$').hasMatch(text)) return;
      final key = normalize(text);
      if (key.length < 2 ||
          RegExp(r'^[0-9a-f]{6,8}$').hasMatch(key) ||
          target.any((existing) => normalize(existing) == key) ||
          target.length >= 8) {
        return;
      }
      target.add(text);
    }

    final allMain = items.expand((i) => i.files).map(p.posix.basename).toList();
    final folderMovie = _movieMarker.hasMatch(name);
    final fileMovie =
        shape == WorkShape.feature &&
        allMain.any((f) => _movieMarker.hasMatch(_plain(f)));
    final isSeries = shape == WorkShape.series && !folderMovie && !fileMovie;

    // 按频次降序汇总归一化标题，将出现最频繁的文件名主标题排在首位。
    final counts = <String, int>{};
    final itemCoverage = <String, int>{};
    for (final item in items) {
      final itemSeen = <String>{};
      for (final file in item.files) {
        for (final candidate in _fileTitles(
          p.posix.basename(file),
          item.episode,
        )) {
          counts.update(candidate, (n) => n + 1, ifAbsent: () => 1);
          final normKey = normalize(candidate);
          if (normKey.length >= 2 && itemSeen.add(normKey)) {
            itemCoverage.update(normKey, (n) => n + 1, ifAbsent: () => 1);
          }
        }
      }
    }
    final ranked = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));

    var tmdbId = PersonalFilenameParser.tmdbId(name);
    var tmdbType = PersonalFilenameParser.tmdbType(name);
    if (tmdbId == null && allMain.isNotEmpty) {
      final fileTmdb = {
        for (final f in allMain) ?PersonalFilenameParser.tmdbId(f),
      };
      if (fileTmdb.length == 1) {
        tmdbId = fileTmdb.single;
        final fileTypes = {
          for (final f in allMain) ?PersonalFilenameParser.tmdbType(f),
        };
        if (fileTypes.length == 1) tmdbType = fileTypes.single;
      }
    }
    final bangumi = _bangumiMarker.firstMatch(name);
    var bangumiId = bangumi == null ? null : int.tryParse(bangumi.group(1)!);
    if (bangumiId == null && allMain.isNotEmpty) {
      final fileBgm = {
        for (final f in allMain)
          ?int.tryParse(_bangumiMarker.firstMatch(f)?.group(1) ?? ''),
      };
      if (fileBgm.length == 1) bangumiId = fileBgm.single;
    }

    // 复杂目录容错：当文件夹名仅为通用整理/下载桶（如 `新建文件夹`、`2025年7月新番`、`待看`、`BDMV_042`）
    // 且目录内全部/绝大多数正片视频共享一致的清晰片名主干时，直接以一致文件名主干为主标题，
    // 消除不规范目录名携带的伪年份与伪序号干扰。
    String? consistentFileStem;
    if (ranked.isNotEmpty && items.isNotEmpty) {
      final topStem = ranked.first;
      final topNorm = normalize(topStem);
      final coveredItems = itemCoverage[topNorm] ?? 0;
      final isConsistent =
          (items.length >= 2 && coveredItems * 5 >= items.length * 4) ||
          (items.length == 1 && topNorm.length >= 3);
      if (isConsistent &&
          !RegExp(r'^\d+$').hasMatch(topNorm) &&
          !_isGenericOrIrregularFolderName(topStem)) {
        consistentFileStem = topStem;
      }
    }
    // 若每集文件名带有逐集副标题（如 `小哥斯拉的逆袭 黑多老师...`、`Saint Seiya ... chapter 1/2`）
    // 导致无单一完整词干覆盖 >= 80%，则提取跨 >= 80% 条目的最长公共片名前缀作为一致文件主干。
    final commonPrefixStem = consistentFileStem == null && items.length >= 3
        ? _extractDominantCommonPrefix(items)
        : null;
    consistentFileStem ??= commonPrefixStem;
    final useConsistentFileAsPrimary =
        tmdbId == null &&
        bangumiId == null &&
        consistentFileStem != null &&
        _isGenericOrIrregularFolderName(title);

    final effectiveTitle = useConsistentFileAsPrimary
        ? consistentFileStem
        : title;
    final multiSeasonFolder =
        !useConsistentFileAsPrimary && isMultiSeasonTitle(effectiveTitle);
    int? inferredSeason = specialCollectionTitle != null
        ? 0
        : (useConsistentFileAsPrimary || multiSeasonFolder
              ? null
              : WorkSeason.explicit({'title': name}));
    final titleHints = <String>[];
    hint(titleHints, effectiveTitle);
    final folderSplit = splitSeasonSuffix(effectiveTitle, isSeries: isSeries);
    if (!multiSeasonFolder) inferredSeason ??= folderSplit.season;
    if (folderSplit.baseTitle != effectiveTitle) {
      hint(titleHints, folderSplit.baseTitle);
    }
    // 对 `S1+S2` / `S1-S4` 等多季合装后缀同时产出剥离后的纯净剧名提示，避免主标题相似度被后缀拉低。
    if (multiSeasonFolder) {
      final strippedMulti = effectiveTitle
          .replaceFirst(
            RegExp(
              r'\s+s\d{1,2}(?:\s*[+&~～\-]\s*(?:s?\d{1,2}|ova|oad|sp|movie))+\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (strippedMulti.isNotEmpty && strippedMulti != effectiveTitle) {
        hint(titleHints, strippedMulti);
      }
    }
    final withoutMarker = effectiveTitle
        .replaceAll(
          RegExp(
            r'剧场版|劇場版|総集編|总集篇|\b(?:the\s+movie|movie|ova|oad|oab)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .trim();
    hint(titleHints, withoutMarker);

    // 目录内同时存在多季主干时，季号已逐集记录，不能再用出现最多的文件主干推断整体季号。
    if (ranked.isNotEmpty && !multiSeasonStems) {
      final dominantFile = ranked.first;
      inferredSeason ??= CloudMediaAssetPresentation.explicitSeasonNumber({
        'work_title': dominantFile,
      });
      final domSplit = splitSeasonSuffix(dominantFile, isSeries: isSeries);
      inferredSeason ??= domSplit.season;
    }
    // 当目录未给出明确季号但 >= 80% 的正片文件均携带一致的显式续季标记（如 `S2 - 01`、`S2 [01]`）时，
    // 继承该一致续季号，避免乱目录场景下 `S2` 被搜索词清洗剥离后误落第 1 季。
    if (inferredSeason == null && !multiSeasonStems && isSeries && items.isNotEmpty) {
      final explicitItemSeasons = <int, int>{};
      for (final item in items) {
        final s = item.season;
        if (s != null && s >= 2) {
          explicitItemSeasons.update(s, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      if (explicitItemSeasons.length == 1) {
        final onlyEntry = explicitItemSeasons.entries.single;
        if (onlyEntry.value * 5 >= items.length * 4) {
          inferredSeason = onlyEntry.key;
        }
      }
    }
    if (commonPrefixStem != null) {
      hint(fileHints, commonPrefixStem);
    }
    for (final value in ranked) {
      hint(fileHints, value);
      final split = splitSeasonSuffix(value, isSeries: isSeries);
      if (split.baseTitle != value) {
        hint(fileHints, split.baseTitle);
      }
      final fileWithoutMarker = value
          .replaceAll(
            RegExp(
              r'剧场版|劇場版|総集編|总集篇|\b(?:the\s+movie|movie|ova\d*|oads?|oav\d*|oab)\b',
              caseSensitive: false,
            ),
            ' ',
          )
          .trim();
      if (fileWithoutMarker != value) {
        hint(fileHints, fileWithoutMarker);
      }
      // 提取文件名中 `OVA`/`OAD`/`The Animation` 之前的母系列基础片名作为次级提示，
      // 确保乱目录下含单集副标题的 OVA/OAD（如 `Seraph of the End - OVA - Shahar`、`Neptune The Animation OVA1`）可精确命中母剧。
      final beforeSpecialFile = RegExp(
        r'^(.+?)(?:\s*[-–—]\s*|\s+)(?:ova\d*|oads?|oav\d*|tvsp|sp\d+|special\s+ride)\b',
        caseSensitive: false,
      ).firstMatch(value.trim());
      if (beforeSpecialFile != null) {
        final baseSeries = beforeSpecialFile
            .group(1)!
            .replaceFirst(
              RegExp(r'\s+the\s+animation$', caseSensitive: false),
              '',
            )
            .trim();
        if (baseSeries.length >= 4 ||
            RegExp(r'[\u3040-\u9fff]').hasMatch(baseSeries)) {
          hint(fileHints, baseSeries);
        }
      }
      // 罗马音 + 含假名日文双语拼接文件名（如 `Yuyushiki ゆゆ式 OVA 「...」`）同步拆出独立拉丁段与日文段，
      // 便于乱目录场景下与 TMDB/Bangumi 单语正式片名取得精确匹配。
      final bilingualFile = RegExp(
        r'^([A-Za-z0-9][A-Za-z0-9\s!\-’\x27.,]{3,}?)\s+([\u3040-\u9fff][^\r\n]{1,})$',
      ).firstMatch(value.trim());
      if (bilingualFile != null &&
          RegExp(r'[\u3040-\u30ff]').hasMatch(bilingualFile.group(2)!)) {
        final latinSeg = bilingualFile.group(1)!.trim();
        final cjkSeg = bilingualFile
            .group(2)!
            .split(
              RegExp(
                r'\s+(?:ova\d*|oads?|oab|sp\d*|special|「|『)',
                caseSensitive: false,
              ),
            )
            .first
            .trim();
        if (latinSeg.length >= 4) hint(fileHints, latinSeg);
        if (cjkSeg.length >= 2 &&
            (RegExp(r'[\u4e00-\u9fff]').hasMatch(cjkSeg) ||
                cjkSeg.length >= 5)) {
          hint(fileHints, cjkSeg);
        }
      }
    }

    final folderYear = useConsistentFileAsPrimary
        ? null
        : WorkSeason.year({'title': name});
    int? fileYear;
    if (folderYear == null && allMain.isNotEmpty) {
      final yearCounts = <int, int>{};
      final yearRegex = RegExp(
        shape == WorkShape.feature || useConsistentFileAsPrimary
            ? r'[(\[ ._]((?:19[5-9]|20[0-2])\d)[)\] ._]'
            : r'[(（\[【]\s*((?:19[5-9]|20[0-2])\d)\s*[)）\]】]',
      );
      for (final file in allMain) {
        final m = yearRegex.firstMatch(file);
        final y = m == null ? null : int.tryParse(m.group(1)!);
        if (y != null) {
          yearCounts.update(y, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      if (yearCounts.length == 1) {
        final only = yearCounts.entries.single;
        if (shape == WorkShape.feature ||
            useConsistentFileAsPrimary ||
            only.value * 5 >= allMain.length * 4) {
          fileYear = only.key;
        }
      }
    }
    return DirectoryInventory._(
      folder: normalizedFolder,
      title: effectiveTitle,
      year: folderYear ?? fileYear,
      tmdbId: tmdbId,
      tmdbType: tmdbType,
      bangumiId: bangumiId,
      season: inferredSeason,
      folderMovieMarker: useConsistentFileAsPrimary ? false : folderMovie,
      fileMovieMarker: fileMovie,
      main: items,
      extras: extras,
      shape: shape,
      titleHints: titleHints,
      fileHints: fileHints,
    );
  }

  /// 将尾部季度或续作后缀拆分为 `(baseTitle, season)` 二元组，
  /// 使搜索请求携带纯净基础名称的同时，向 `WorkMatcher` 传递精确季度信号
  /// （例如 `Mob Psycho 100 II` 拆为 `Mob Psycho 100` 与第 2 季）。
  static ({String baseTitle, int? season}) splitSeasonSuffix(
    String raw, {
    required bool isSeries,
  }) {
    final trimmed = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.length < 3) return (baseTitle: trimmed, season: null);

    // 1. Explicit Season N / Nnd Season / S2 / 第N期 / 第N季 at tail.
    final explicitTail = RegExp(
      r'^(.*?S?)\s*(?:[:：\-–—~～]\s*|\s+)'
      r'(?:Season[ ._-]*(\d{1,2})|(\d{1,2})(?:st|nd|rd|th)[ ._-]+Season|'
      r'S0*(\d{1,2})|第[ ._-]*([0-9一二三四五六七八九十两]+)[ ._-]*[季期])\s*$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (explicitTail != null) {
      final base = explicitTail.group(1)!.trim();
      final season = CloudMediaAssetPresentation.explicitSeasonNumber({
        'work_title': trimmed.substring(explicitTail.group(1)!.length),
      });
      if (base.length >= 2 && season != null) {
        return (baseTitle: base, season: season);
      }
    }

    if (!isSeries) return (baseTitle: trimmed, season: null);

    // 2. 识别系列标题末尾罗马季度编号（`II / III / IV / Ⅱ / Ⅲ / Ⅳ`），
    //    自动排除机体型号或技术代号（如 `Mk-II`、`Mark II`、`Type II`、`Part II`）。
    // 罗马数字必须全大写，避免把日文罗马音单词（如 `Tanin ga Ii`）误判为第 2 季。
    final romanTail = RegExp(
      r'^(.+?)\s+(II|III|IV|Ⅱ|Ⅲ|Ⅳ)$',
    ).firstMatch(trimmed);
    if (romanTail != null) {
      final base = romanTail.group(1)!.trim();
      final badPrefix = RegExp(
        r'(?:^|\s)(?:mk|mark|type|part|vol\.?|act|stage|episode|ep|ver\.?|movie|film|chapter)[- ]*$',
        caseSensitive: false,
      ).hasMatch(base);
      if (!badPrefix && base.length >= 2) {
        final token = romanTail.group(2)!.toUpperCase();
        final season = switch (token) {
          'II' || 'Ⅱ' => 2,
          'III' || 'Ⅲ' => 3,
          'IV' || 'Ⅳ' => 4,
          _ => null,
        };
        if (season != null) return (baseTitle: base, season: season);
      }
    }

    return (baseTitle: trimmed, season: null);
  }

  /// 路径或文件名是否显式携带 OVA / OAD / OAV 标记。
  static bool isOvaText(String text) => _ovaMarker.hasMatch(text);

  static bool isOva(DirectoryInventory inventory) =>
      _ovaMarker.hasMatch(inventory.folder) ||
      inventory.main.any((i) => i.files.any((f) => _ovaMarker.hasMatch(f)));

  /// 保留位于主目录内且处于连续 `1..N` 整数序列中的正片剧集，
  /// 防止仅因附带括号注记或回顾提示就被误降级为特典。
  static List<({String path, int? size, bool ambiguous})>
  _protectContiguousMainEpisodes(
    Map<String, LogicalItem> main,
    List<({String path, int? size, bool ambiguous})> soft, {
    required bool supplementaryFolder,
  }) {
    if (supplementaryFolder || soft.isEmpty || main.isEmpty) return soft;
    final mainEpisodes = <int>{
      for (final item in main.values)
        if (item.episode != null && item.episode! >= 1)
          for (
            var e = item.episode!;
            e <= (item.episodeEnd ?? item.episode!);
            e++
          )
            e,
    };
    if (mainEpisodes.length < 2) return soft;

    final candidates =
        <
          int,
          ({String path, int? size, bool ambiguous, String dir, String file})
        >{};
    final kept = <({String path, int? size, bool ambiguous})>[];

    for (final item in soft) {
      final path = item.path;
      final dir = p.posix.dirname(path) == '.' ? '' : p.posix.dirname(path);
      final file = p.posix.basename(path);
      if (CloudMediaFileClassifier.isStrongSupplementary(dir, file)) {
        kept.add(item);
        continue;
      }
      final cleanStem = PersonalFilenameParser.baseNameWithoutExtension(
        CloudMediaFileClassifier.stripTechnicalNoise(file),
      );
      var ep = CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
        dir,
        file,
      );
      if (ep == null) {
        final fallback = RegExp(
          r'(?:^|[\s\]】)])[-–—]\s*(\d{1,3})\s+'
          r'(?:recap|summary|digest|special|総集編|総集篇|总集篇|特別編|特别篇)',
          caseSensitive: false,
        ).firstMatch(cleanStem);
        ep = fallback == null ? null : int.tryParse(fallback.group(1)!);
      }
      if (ep == null ||
          ep < 1 ||
          mainEpisodes.contains(ep) ||
          candidates.containsKey(ep) ||
          CloudMediaFileClassifier.adjacentBracketExtra.hasMatch(file) ||
          CloudMediaFileClassifier.bundledExtraTag.hasMatch(file) ||
          CloudMediaFileClassifier.contextualJapanBdExtra.hasMatch(cleanStem) ||
          RegExp(
            '(?<![a-z0-9])(?:sp|special|ova|oad|ex|bonus)[ ._-]*0*$ep(?![0-9])',
            caseSensitive: false,
          ).hasMatch(cleanStem)) {
        kept.add(item);
        continue;
      }
      candidates[ep] = (
        path: item.path,
        size: item.size,
        ambiguous: item.ambiguous,
        dir: dir,
        file: file,
      );
    }

    if (candidates.isEmpty) return soft;

    final union = <int>{...mainEpisodes, ...candidates.keys};
    final minMain = mainEpisodes.reduce((a, b) => a < b ? a : b);
    for (final entry in candidates.entries) {
      final ep = entry.key;
      var start = ep;
      while (union.contains(start - 1)) {
        start--;
      }
      var end = ep;
      while (union.contains(end + 1)) {
        end++;
      }
      var mainInRun = 0;
      for (var i = start; i <= end; i++) {
        if (mainEpisodes.contains(i)) mainInRun++;
      }
      final contiguousWithMainRun =
          end - start + 1 >= 3 &&
          mainInRun >= 2 &&
          (start == 1 || start <= minMain);
      if (contiguousWithMainRun) {
        _add(
          main,
          entry.value.dir,
          entry.value.file,
          entry.value.path,
          promoted: true,
          episodeOverride: ep,
        );
      } else {
        kept.add((
          path: entry.value.path,
          size: entry.value.size,
          ambiguous: entry.value.ambiguous,
        ));
      }
    }
    return kept;
  }

  /// 纯蓝光光盘结构缩写绝不当作“片名高频词”遮蔽，防止单剧场版附带十余条 `SP/PV/CM/Menu` 时反把自身特典标记抹除。
  static const Set<String> _neverMaskExtraAbbrev = {
    'sp',
    'sps',
    'pv',
    'cm',
    'mv',
    'op',
    'ed',
    'ncop',
    'nced',
    'ncoped',
    'tvcm',
    'bdcm',
    'pvcm',
    'menu',
    'menus',
    'menue',
    'ova',
    'oad',
    'oav',
  };

  /// 片名自带的英文特典词：在不少于 70% 的视频片名关键词中出现、且单独即会触发特典判定的英文词元
  /// （至少 3 个视频时才统计）。只遮蔽单个特典词，不拆散 `True Birth Edition` 这类特典短语。
  static Set<String> _pervasiveTitleTokens(List<String> fileNames) {
    if (fileNames.length < 3) return const {};
    final counts = <String, int>{};
    for (final name in fileNames) {
      final keyword = PersonalFilenameParser.extractAnimeSearchKeyword(
        name,
      ).toLowerCase();
      for (final token
          in keyword
              .split(RegExp(r'[^a-z0-9]+'))
              .where((t) => t.length >= 2)
              .toSet()) {
        counts.update(token, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return {
      for (final e in counts.entries)
        if (e.value >= fileNames.length * 0.7 &&
            !_neverMaskExtraAbbrev.contains(e.key) &&
            RegExp(r'[a-z]').hasMatch(e.key) &&
            (_unambiguousExtra.hasMatch(e.key) ||
                _ambiguousExtra.hasMatch(e.key) ||
                CloudMediaFileClassifier.isClearlySupplementary('', e.key)))
          e.key,
    };
  }

  static String _maskTokens(String name, Set<String> tokens) {
    if (tokens.isEmpty) return name;
    var masked = name;
    for (final token in tokens) {
      masked = masked.replaceAll(
        RegExp(
          '(?<![a-z0-9])${RegExp.escape(token)}(?![a-z0-9])',
          caseSensitive: false,
        ),
        ' ',
      );
    }
    return masked;
  }

  static final _seasonRangeMarker = RegExp(
    r'(?<![a-z0-9])s\d{1,2}\s*[+&＆~～\-–—]\s*s?\d{1,2}(?![a-z0-9])',
    caseSensitive: false,
  );
  static final _seasonWordMarker = RegExp(
    r'第\s*[0-9一二三四五六七八九十]+\s*[季期]|最终季|最終季|season\s*\d|\d(?:st|nd|rd|th)\s*season|(?<![a-z0-9])s\d{1,2}(?![a-z0-9])',
    caseSensitive: false,
  );

  /// 目录名是否声明多季合辑：`S1+S2`/`S1-S3` 季号区间，或以 ` & ` 并列的多段中有两段带季标记，
  /// 或带季标记的一段只是在重复另一段片名（`天地无用! 魉皇鬼 & 天地无用! 魉皇鬼 第2期`）。
  static bool isMultiSeasonTitle(String title) {
    if (_seasonRangeMarker.hasMatch(title)) return true;
    final segments = title
        .split(RegExp(r'\s+[&＆]\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2) return false;
    final marked = segments.where(_seasonWordMarker.hasMatch).toList();
    if (marked.length >= 2) return true;
    if (marked.length != 1) return false;
    final markedBase = normalize(
      marked.single.replaceAll(_seasonWordMarker, ' '),
    );
    return segments.where((s) => !identical(s, marked.single)).any((s) {
      final other = normalize(s);
      return other.length >= 2 && markedBase.startsWith(other);
    });
  }

  static final _leadingReleaseGroup = RegExp(r'^\s*[\[【]([^\]】]+)[\]】]');
  static final _stemMovieMarker = RegExp(
    r'剧场版|劇場版|映画|movie|gekijou?ban',
    caseSensitive: false,
  );
  static final _modelNumberPrefixTail = RegExp(
    r'(?:mk|mark|type|ver|vol|part|no)$',
    caseSensitive: false,
  );
  static final _wholeSeasonToken = RegExp(
    r'^(?:(ii|iii|iv)|r?([2-9])|s([2-9])|season([2-9])|([2-9])(?:nd|rd|th)season|'
    r'(second|third|fourth)(?:season)?|第([二三四五六七八九2-9])[期季]|([2-9])期|x([2-9]))$',
  );
  static final _embeddedSeasonToken = RegExp(
    r'(?:^|[^0-9])([2-9])(?:nd|rd|th)|season([2-9])|(second|third|fourth)season',
  );
  static final _bangOnlySuffix = RegExp(r'^!+$');

  /// 从「与主干公共前缀之后的后缀」中读取续季序号（归一化小写文本）。
  static int? _stemSeasonFromSuffix(String suffix) {
    if (suffix.isEmpty) return null;
    if (_bangOnlySuffix.hasMatch(suffix)) {
      return suffix.length >= 2 ? suffix.length : null;
    }
    final whole = _wholeSeasonToken.firstMatch(suffix);
    if (whole != null) {
      final roman = whole.group(1);
      if (roman != null) return const {'ii': 2, 'iii': 3, 'iv': 4}[roman];
      final word = whole.group(6);
      if (word != null) {
        return const {'second': 2, 'third': 3, 'fourth': 4}[word];
      }
      final cn = whole.group(7);
      if (cn != null) {
        return int.tryParse(cn) ??
            const {
              '二': 2,
              '三': 3,
              '四': 4,
              '五': 5,
              '六': 6,
              '七': 7,
              '八': 8,
              '九': 9,
            }[cn];
      }
      for (final g in [2, 3, 4, 5, 8, 9]) {
        final v = whole.group(g);
        if (v != null) return int.parse(v);
      }
    }
    final embedded = _embeddedSeasonToken.firstMatch(suffix);
    if (embedded != null) {
      final word = embedded.group(3);
      if (word != null) {
        return const {'second': 2, 'third': 3, 'fourth': 4}[word];
      }
      return int.parse(embedded.group(1) ?? embedded.group(2)!);
    }
    return null;
  }

  static int _commonPrefixLength(String a, String b) {
    final n = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static int _trailingBangs(String raw) {
    final m = RegExp(r'([!！]+)\s*$').firstMatch(raw.trim());
    return m == null ? 0 : m.group(1)!.length;
  }

  /// 同一作品目录内按系列主干拆分编号正片，避免不同主干的同号剧集被误并为同一集的多个版本：
  /// 1. 后缀带续季标记（`II`、`2`、`R2`、`2nd`、`!!` 等）的主干改记对应季号；
  /// 2. 不同压制组对同一正片的不同命名保持为多版本；
  /// 3. 体积显著偏小、带剧场版标记或集数明显偏少的衍生主干（迷你动画、短篇、总集剧场版）降级为特典；
  /// 4. 以主干为严格前缀且集数规模相当的主干视为下一季。
  static ({List<LogicalItem> items, bool multiSeason}) _separateSeriesStems({
    required List<LogicalItem> items,
    required Map<String, int> sizeByPath,
    required List<String> extras,
    required int baseSeason,
  }) {
    final records = <({String path, String stem, int episode})>[];
    for (final item in items) {
      if (item.episode == null || item.season != null) continue;
      for (var i = 0; i < item.files.length; i++) {
        records.add((
          path: item.files[i],
          stem: i < item.titles.length ? item.titles[i] : item.title,
          episode: item.episode!,
        ));
      }
    }
    final byStem = <String, List<({String path, String stem, int episode})>>{};
    for (final r in records) {
      (byStem[r.stem] ??= []).add(r);
    }
    if (byStem.length < 2) return (items: items, multiSeason: false);
    // 每个主干只覆盖一集且集号互不重复：主干实为逐集副标题（`[14]新·小哥斯拉的逆袭`），
    // 不是需要拆季或降级为特典的多部系列。
    final stemEpisodes = [
      for (final rs in byStem.values) {for (final r in rs) r.episode},
    ];
    if (stemEpisodes.every((eps) => eps.length == 1) &&
        {for (final eps in stemEpisodes) ...eps}.length == byStem.length) {
      return (items: items, multiSeason: false);
    }

    // 各主干的集号集合、中位/总体积与发布组只计算一次，避免排序比较器内反复遍历。
    final epsByStem = <String, Set<int>>{};
    final medianByStem = <String, double>{};
    final totalByStem = <String, int>{};
    final groupsByStem = <String, Set<String>>{};
    for (final entry in byStem.entries) {
      final sizes = [for (final r in entry.value) ?sizeByPath[r.path]]..sort();
      epsByStem[entry.key] = {for (final r in entry.value) r.episode};
      medianByStem[entry.key] = sizes.isEmpty
          ? 0
          : sizes[sizes.length ~/ 2].toDouble();
      totalByStem[entry.key] = sizes.fold<int>(0, (sum, s) => sum + s);
      groupsByStem[entry.key] = {
        for (final r in entry.value)
          if (_leadingReleaseGroup.firstMatch(p.posix.basename(r.path))
              case final m?)
            m.group(1)!.trim().toLowerCase(),
      };
    }
    Set<int> epsOf(String stem) => epsByStem[stem]!;
    double medianSize(String stem) => medianByStem[stem]!;
    Set<String> groupsOf(String stem) => groupsByStem[stem]!;
    int totalSize(String stem) => totalByStem[stem]!;
    // 主干优先级：集数过少（不足 3 集且存在更长序列）者不参与竞争；其次不带剧场版标记者优先，
    // 再按总体积衡量正片体量，避免集数更多的迷你短篇或单个超大活动录像被误选为正片主干。
    final maxCount = byStem.keys.fold<int>(
      0,
      (m, k) => epsOf(k).length > m ? epsOf(k).length : m,
    );
    final minEligible = maxCount < 3 ? maxCount : 3;
    final stems = byStem.keys.toList()
      ..sort((a, b) {
        final aEligible = epsOf(a).length >= minEligible;
        final bEligible = epsOf(b).length >= minEligible;
        if (aEligible != bEligible) return aEligible ? -1 : 1;
        final aMovie = _stemMovieMarker.hasMatch(a);
        final bMovie = _stemMovieMarker.hasMatch(b);
        if (aMovie != bMovie) return aMovie ? 1 : -1;
        final bySize = totalSize(b).compareTo(totalSize(a));
        if (bySize != 0) return bySize;
        final byCount = epsOf(b).length.compareTo(epsOf(a).length);
        if (byCount != 0) return byCount;
        return a.length.compareTo(b.length);
      });
    final dominant = stems.first;
    final domEps = epsOf(dominant);
    final domSize = medianSize(dominant);
    final domGroups = groupsOf(dominant);

    final seasonByStem = <String, int>{};
    final extraStems = <String>{};
    for (final stem in stems.skip(1)) {
      final eps = epsOf(stem);
      final stemGroups = groupsOf(stem);
      final disjointGroups =
          domGroups.isNotEmpty &&
          stemGroups.isNotEmpty &&
          domGroups.intersection(stemGroups).isEmpty;
      final size = medianSize(stem);
      final muchSmaller = domSize > 0 && size > 0 && size < domSize * 0.45;
      if (eps.intersection(domEps).isEmpty) {
        // 集号不重叠时多为同一正片序列的分卷命名差异；仅同组且体积显著偏小的短篇降级为特典。
        if (muchSmaller && !disjointGroups) extraStems.add(stem);
        continue;
      }
      final prefix = _commonPrefixLength(dominant, stem);
      final domSuffix = dominant.substring(prefix);
      final stemSuffix = stem.substring(prefix);
      final guardedPrefix = _modelNumberPrefixTail.hasMatch(
        dominant.substring(0, prefix),
      );
      // 仅由感叹号数量区分的续季（`Working!!`）要求另一侧后缀为空且出自同一发布组；
      // 若另一侧带有其他后缀（`Haikyuu!!` 对 `Haikyuu!! 2nd Season`），感叹号只是片名的一部分。
      int? seasonOf(String suffix, String otherSuffix) {
        if (guardedPrefix) return null;
        if (_bangOnlySuffix.hasMatch(suffix) &&
            (otherSuffix.isNotEmpty || disjointGroups)) {
          return null;
        }
        return _stemSeasonFromSuffix(suffix);
      }

      final domSeason = seasonOf(domSuffix, stemSuffix);
      final stemSeason = seasonOf(stemSuffix, domSuffix);
      final comparable =
          !muchSmaller && eps.length >= (domEps.length * 0.5).clamp(3, 6);
      final domSide =
          domSeason != null ||
          domSuffix.isEmpty ||
          (stemSeason != null && comparable);
      final stemSide =
          stemSeason != null ||
          stemSuffix.isEmpty ||
          (domSeason != null && comparable);
      if ((domSeason != null || stemSeason != null) &&
          domSide &&
          stemSide &&
          (domSeason ?? baseSeason) != (stemSeason ?? baseSeason)) {
        seasonByStem[dominant] = domSeason ?? baseSeason;
        seasonByStem[stem] = stemSeason ?? baseSeason;
        continue;
      }
      if (disjointGroups) continue;
      if (muchSmaller) {
        extraStems.add(stem);
        continue;
      }
      if (_stemMovieMarker.hasMatch(stem) &&
          !_stemMovieMarker.hasMatch(dominant)) {
        extraStems.add(stem);
        continue;
      }
      final minSeasonCount = domEps.length * 0.5 > 6 ? domEps.length * 0.5 : 6;
      if (domSuffix.isEmpty &&
          stemSuffix.isNotEmpty &&
          eps.length >= minSeasonCount) {
        seasonByStem[dominant] = seasonByStem[dominant] ?? baseSeason;
        seasonByStem[stem] = baseSeason + 1;
        continue;
      }
      if (eps.length < domEps.length * 0.5) {
        extraStems.add(stem);
      }
    }
    if (seasonByStem.isEmpty && extraStems.isEmpty) {
      return (items: items, multiSeason: false);
    }

    final stemByPath = {for (final r in records) r.path: r.stem};
    final rebuilt = <String, LogicalItem>{};
    for (final item in items) {
      for (var i = 0; i < item.files.length; i++) {
        final path = item.files[i];
        final title = i < item.titles.length ? item.titles[i] : item.title;
        final stem = stemByPath[path];
        if (stem != null && extraStems.contains(stem)) {
          extras.add(path);
          continue;
        }
        final season = stem == null ? item.season : seasonByStem[stem];
        final key = item.episode == null
            ? item.key
            : 'e:${season ?? item.season ?? ''}:${item.episode}'
                  '${item.episodeEnd == null ? '' : '-${item.episodeEnd}'}';
        (rebuilt[key] ??= LogicalItem(
            key,
            title,
            item.episode,
            season ?? item.season,
            episodeEnd: item.episodeEnd,
          ))
          ..files.add(path)
          ..titles.add(title);
      }
    }
    return (
      items: rebuilt.values.toList(),
      multiSeason: seasonByStem.isNotEmpty,
    );
  }

  /// 编号正片的系列主干键：片名主干 + 全方括号命名中的衍生副标题块，
  /// 片名以两个及以上感叹号收尾时保留感叹号（`Working!!`、`Hataraku Maou-sama!!` 等以此区分续季）。
  static String _seriesStem(String file, int episode) {
    final series = seriesTitle(
      PersonalFilenameParser.extractAnimeSearchKeyword(file),
      episode,
      rawFile: file,
    );
    final qualifier = PersonalFilenameParser.bracketSeriesQualifier(file);
    final bangs = _trailingBangs(series);
    return normalize('$series $qualifier') + (bangs >= 2 ? '!' * bangs : '');
  }

  static final RegExp _seasonEpisodeMarker = RegExp(
    r'(?<![a-z0-9])s(\d{1,2})(?:[ ._-]*e\d{1,4}|[ ._-]+-|\s*[\[【]\s*\d{1,3}\s*[\]】])',
    caseSensitive: false,
  );

  /// 独立 OVA/OAD/SP 目录软提升正片时的特别篇集号标记（如 `[OAD01]`、`[OVA02]`、`[SP03]`）。
  static final RegExp _promotedSpecialEpisodeMarker = RegExp(
    r'(?:[\[【(]\s*|(?:^|[\s._\-–—]))(?:ova|oad|oav|sp|special|ex)[ ._-]*0*(\d{1,2})(?:v\d+)?(?=\s*[\]】)]|(?![0-9a-z]))',
    caseSensitive: false,
  );

  static void _add(
    Map<String, LogicalItem> main,
    String directory,
    String file,
    String path, {
    bool promoted = false,
    int? episodeOverride,
  }) {
    final span = episodeOverride != null
        ? null
        : CloudMediaFileClassifier.episodeSpanFromNameInDirectory(
            directory,
            file,
          );
    var episode = episodeOverride ?? span?.start;
    var promotedSpecialSeason = false;
    if (promoted && episode == null) {
      final specialMatch = _promotedSpecialEpisodeMarker.firstMatch(file);
      final parsedSpecial = specialMatch == null
          ? null
          : int.tryParse(specialMatch.group(1)!);
      if (parsedSpecial != null && parsedSpecial >= 1 && parsedSpecial <= 99) {
        episode = parsedSpecial;
        promotedSpecialSeason = true;
      }
    }
    final season = _seasonEpisodeMarker.firstMatch(file);
    final resolvedSeason = season != null
        ? int.parse(season.group(1)!)
        : (promotedSpecialSeason ? 0 : null);
    // 多集合并文件：仅正片、非提升/覆盖场景才识别区间结束集（廉价条件在前，特典判定最后执行）。
    final rangeEnd = span?.end;
    final episodeEnd =
        rangeEnd == null ||
            promoted ||
            CloudMediaFileClassifier.isClearlySupplementary(directory, file)
        ? null
        : rangeEnd;
    final core = versionKey(file);
    final title = episode == null ? core : _seriesStem(file, episode);
    // 同一集的多种压制版本按 `(season, number)` 键折叠去重；
    // 区间文件键含结束集，避免与单独的起始集文件被并成同集多版本；
    // 系列标题仅额外保留用于合集判定与名称提示。
    final key = episode == null
        ? 'f:$core'
        : 'e:${resolvedSeason ?? ''}:$episode'
              '${episodeEnd == null ? '' : '-$episodeEnd'}';
    (main[key] ??= LogicalItem(
        key,
        title,
        episode,
        resolvedSeason,
        episodeEnd: episodeEnd,
      ))
      ..files.add(path)
      ..titles.add(title);
  }

  /// 截取集号前面的标题主干（例如 `"Wake Up, Girls! 10"` 提取为 `"Wake Up, Girls!"`），
  /// "キノの旅 #03 予言の国" -> "キノの旅", "SD Gundam Mk3 - Episode 01" ->
  /// 完整保留机体号（`SD Gundam Mk3`）及自带数字的原作片名（如 `86`、`Mob Psycho 100`、
  /// `Steins;Gate 0`），防止右端集号剥离后误伤作品自身数字。
  static String seriesTitle(String keyword, int? episode, {String? rawFile}) {
    var value = keyword;
    if (episode != null) {
      final hash = value.indexOf(RegExp(r'[#＃]'));
      if (hash > 0) value = value.substring(0, hash);
      final epPattern = RegExp('(?<![0-9A-Za-z.])0*$episode(?![0-9.])');
      final inKeyword = epPattern.allMatches(value).length;
      final alreadyStripped =
          rawFile != null &&
          inKeyword > 0 &&
          epPattern
                  .allMatches(
                    PersonalFilenameParser.baseNameWithoutExtension(rawFile),
                  )
                  .length >
              inKeyword;
      if (!alreadyStripped) {
        final number = epPattern
            .allMatches(value)
            .where((m) => m.start > 0)
            .firstOrNull;
        if (number != null) value = value.substring(0, number.start);
      }
    }
    value = value
        .replaceFirst(
          RegExp(
            r'(?:[\s._\-–—]+(?:episode|ep\.?|vol\.?)|第)?[\s._\-–—]*$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return value.isEmpty ? keyword : value;
  }

  /// 同一作品不同压制版本归一化：剔除方圆括号并自首个分辨率、片源或年份
  /// 技术规格词元起截断尾部，以保证不同版本收口为同一作品标题。
  static String versionKey(String file) {
    var base = PersonalFilenameParser.baseNameWithoutExtension(file);
    final withoutBlocks = base
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）'), ' ')
        .replaceAll(RegExp(r'[._]+'), ' ');
    final cut = _technical.firstMatch(withoutBlocks);
    var core = cut == null
        ? withoutBlocks
        : withoutBlocks.substring(0, cut.start);
    core = core.replaceAll(
      RegExp(
        r'\b(?:sdr|hdr\d*|uhd|v\d|rev|x26[45]|hevc|avc|flac|aac|chs|cht)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    var key = normalize(core);
    if (key.isEmpty) {
      key = normalize(
        PersonalFilenameParser.bracketTitleCandidates(file).join(' '),
      );
    }
    if (key.isEmpty) {
      key = normalize(PersonalFilenameParser.extractAnimeSearchKeyword(file));
    }
    return key.isEmpty ? normalize(base) : key;
  }

  static Iterable<String> _fileTitles(String file, int? episode) sync* {
    final keyword = PersonalFilenameParser.extractAnimeSearchKeyword(file);
    if (keyword.isNotEmpty) {
      if (episode == null) {
        final movieClean = keyword
            .replaceAll(RegExp(r'[#＃]\s*\d{1,3}\b'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        yield _trimTechnical(movieClean);
        final withoutPart = movieClean
            .replaceAll(
              RegExp(r'\b(?:前篇|後篇|后篇|中篇|前編|後編)\b|(?:前篇|後篇|后篇|中篇|前編|後編)'),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (withoutPart.isNotEmpty && withoutPart != movieClean) {
          yield _trimTechnical(withoutPart);
        }
      }
      yield _trimTechnical(seriesTitle(keyword, episode, rawFile: file));
    }
    for (final block in PersonalFilenameParser.bracketTitleCandidates(file)) {
      yield block.replaceAll('_', ' ');
    }
    final stripped = PersonalFilenameParser.withoutKnownReleaseGroups(file);
    if (stripped != null) {
      final value = PersonalFilenameParser.extractAnimeSearchKeyword(stripped);
      if (value.isNotEmpty) yield _trimTechnical(seriesTitle(value, episode));
    }
  }

  /// 提取覆盖不少于 80% 主条目的最长公共片名前缀（按空格或中文词界截断），
  /// 用于处理逐集自带单集副标题（如 `小哥斯拉的逆袭 黑多老师...`）或分章序列的文件集合。
  static String? _extractDominantCommonPrefix(List<LogicalItem> items) {
    final samples = <String>[];
    for (final item in items) {
      if (item.files.isEmpty) continue;
      final kw = PersonalFilenameParser.extractAnimeSearchKeyword(
        p.posix.basename(item.files.first),
      ).trim();
      final cleaned = _trimTechnical(kw);
      if (cleaned.length >= 4) samples.add(cleaned);
    }
    if (samples.length < 3) return null;
    final prefixCounts = <String, int>{};
    for (final s in samples) {
      final words = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      if (words.length >= 2) {
        final buf = StringBuffer();
        for (var i = 0; i < words.length - 1; i++) {
          if (i > 0) buf.write(' ');
          buf.write(words[i]);
          final cand = buf.toString().trim();
          final norm = normalize(cand);
          if (norm.length >= 3) {
            prefixCounts.update(cand, (n) => n + 1, ifAbsent: () => 1);
          }
        }
      }
    }
    String? best;
    for (final entry in prefixCounts.entries) {
      if (entry.value * 5 < samples.length * 4) continue;
      if (_isGenericOrIrregularFolderName(entry.key)) continue;
      if (best == null || entry.key.length > best.length) {
        best = entry.key;
      }
    }
    if (best != null) {
      final trimmedStruct = best
          .replaceFirst(
            RegExp(
              r'[\s._\-–—]+(?:chapter|part|vol(?:ume)?|ep(?:isode)?|disc|disk)$',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (normalize(trimmedStruct).length >= 3) {
        return trimmedStruct;
      }
    }
    return best;
  }

  static String _trimTechnical(String value) {
    final cut = _technical.firstMatch(value);
    var result = cut == null ? value : value.substring(0, cut.start);
    // 仅剥离合理发行年份范围（1950~2029），绝不截断科幻片名自带的未来年份（如 `Demon Lord 2099`）。
    result = result.replaceAll(
      RegExp(
        r'[\s._-]+(?:19[5-9]\d|20[0-2]\d)$|[\s._-]+(?:movie|ova)$',
        caseSensitive: false,
      ),
      '',
    );
    return result.trim().isEmpty ? value : result.trim();
  }

  static String _plain(String file) =>
      PersonalFilenameParser.baseNameWithoutExtension(
        CloudMediaFileClassifier.stripTechnicalNoise(file),
      ).replaceAll(RegExp(r'[._]+'), ' ');

  static bool _isVideo(String path) => KonataMediaExtensions.isVideoFile(path);

  static final _genericOrganizerFolderToken = RegExp(
    r'^(?:'
    r'新建文件夹|未命名|未分类|未整理|待看|在看|补番|新番|完结|追番|收藏|下载|临时|杂项|备份|整理|精选集?|推荐|资源|'
    r'个人|我的|动漫|动画|番剧|国漫|日漫|剧场版|蓝光|高清|原盘|生肉|熟肉|压制|字幕|合集|全集|归档|仓库|硬盘|网盘|云盘|目录|分类|默认|测试|文件夹|'
    r'new|folder|untitled|unsorted|temp|tmp|downloads?|misc|backup|animes?|videos?|movies?|series|collection|'
    r'bdmv|bdrip|webrip|raws?|subs?|watch|later|test|dir|disk|archive|part|vol|disc|batch|pack|all|best|fav|favorites?|my|'
    r'第?\d+[季期部弹批组]|(?:19|20)\d{2}年?(?:\d{1,2}月?)?|\d{1,2}月'
    r')+$',
    caseSensitive: false,
  );

  /// 判定目录名是否属于不含真实番名信息的通用整理/下载桶（如 `新建文件夹`、`2025年7月新番`、`BDMV_042`）
  /// 或纯压制规格/编码技术串（如 `SourceUnknown.AVI.702x480.enHard (1)`）。
  /// 纯数字片名（如 `86`）不视作通用桶，避免误伤数字番。
  static bool _isGenericOrIrregularFolderName(String raw) {
    final stripped = raw
        .replaceAll(RegExp(r'[\[\]【】()（）{}「」『』<>《》]'), ' ')
        .replaceAll(RegExp(r'[\s._\-–—~～/\\|&+]+'), ' ')
        .trim();
    if (stripped.isEmpty) return true;
    if (RegExp(r'^\d+$').hasMatch(stripped)) return false;
    final tokens = stripped.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    var sawOrganizerOrTechWord = false;
    for (final tok in tokens) {
      if (RegExp(r'^\d+$').hasMatch(tok)) continue;
      if (_genericOrganizerFolderToken.hasMatch(tok) ||
          PersonalFilenameParser.isTechnicalBracketBlock(tok)) {
        sawOrganizerOrTechWord = true;
        continue;
      }
      return false;
    }
    return sawOrganizerOrTechWord;
  }

  /// 清理刮削源标记、发行年份、开头压制组标签及纯技术规格方括号后的纯净目录名称；
  /// 完整保留片名自身携带的语义方括号（如 `[前篇]`、`[Unlimited Blade Works]`、`[r=1-sinθ]`）。
  static String cleanTitle(String folderName) {
    var title = PersonalFilenameParser.withoutTmdbMarkers(folderName)
        .replaceAll(_bangumiMarker, ' ')
        .replaceAll(RegExp(r'[(（]\s*(?:19|20)\d{2}\s*[)）]'), ' ')
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ');
    // 先移除纯技术规格括号块（如 `[Ma10p_1080p]`、`[WEBDL]`、`[x265_flac]`）。
    title = title.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]|【([^】]+)】'),
      (m) {
        final inner = (m[1] ?? m[2] ?? '').trim();
        return PersonalFilenameParser.isTechnicalBracketBlock(inner)
            ? ' '
            : m[0]!;
      },
    );
    // 剥离目录开头连续的压制组/字幕组方括号标签（如 `[VCB-Studio]`、`[ReinForce]`、`[FLsnow_feat.AO]`）。
    while (true) {
      final lead = RegExp(r'^\s*(?:\[([^\]]+)\]|【([^】]+)】)\s*').firstMatch(
        title,
      );
      if (lead == null) break;
      final inner = (lead[1] ?? lead[2] ?? '').trim();
      final rest = title.substring(lead.end).trim();
      if (rest.isNotEmpty && PersonalFilenameParser.isReleaseGroupTag(inner)) {
        title = rest;
        continue;
      }
      break;
    }
    // 若去除组名与规格后仅剩单个外层方括号包裹片名（如 `[Aikatsu_Planet!-Bloomy_Cafe]`），解包并还原下划线。
    final singleWrapped = RegExp(r'^[\[【]([^\[\]【】]+)[\]】]$').firstMatch(
      title.trim(),
    );
    if (singleWrapped != null) {
      title = singleWrapped[1]!.replaceAll('_', ' ');
    }
    // 目录名里区分同片不同画质的 `1080P`/`2160P`/`4K` 不属于片名。
    title = title.replaceAll(
      RegExp(
        r'(?<![a-z0-9])(?:\d{3,4}[pi]|[248]k)(?![a-z0-9])',
        caseSensitive: false,
      ),
      ' ',
    );
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return title.isEmpty ? folderName : title;
  }

  static bool _isNormalizedStripPunct(int c) {
    switch (c) {
      case 0x20: // 空格
      case 0x09:
      case 0x0A:
      case 0x0D:
      case 0x0C:
      case 0x0B:
      case 0x2D: // -
      case 0x5F: // _
      case 0x2014: // —
      case 0x2013: // –
      case 0x7E: // ~
      case 0xFF5E: // ～
      case 0x301C: // 〜
      case 0x3A: // :
      case 0xFF1A: // ：
      case 0x2E: // .
      case 0x2C: // ,
      case 0xFF0C: // ，
      case 0x3001: // 、
      case 0x3B: // ;
      case 0xFF1B: // ；
      case 0x21: // !
      case 0xFF01: // ！
      case 0x3F: // ?
      case 0xFF1F: // ？
      case 0x30FB: // ・
      case 0x00B7: // ·
      case 0x2022: // •
      case 0x27: // '
      case 0x2019: // ’
      case 0x2018: // ‘
      case 0x22: // "
      case 0x201C: // “
      case 0x201D: // ”
      case 0x28: // (
      case 0x29: // )
      case 0xFF08: // （
      case 0xFF09: // ）
      case 0x5B: // [
      case 0x5D: // ]
      case 0x3010: // 【
      case 0x3011: // 】
      case 0x7B: // {
      case 0x7D: // }
      case 0x300C: // 「
      case 0x300D: // 」
      case 0x300E: // 『
      case 0x300F: // 』
      case 0x3C: // <
      case 0x3E: // >
      case 0x300A: // 《
      case 0x300B: // 》
      case 0x2F: // /
      case 0x5C: // \
      case 0x7C: // |
      case 0x26: // &
      case 0xFF06: // ＆
      case 0x2B: // +
      case 0xFF0B: // ＋
      case 0x2A: // *
      case 0x2606: // ☆
      case 0x2605: // ★
      case 0x266A: // ♪
      case 0x3000: // 全角空格
      case 0x00A0: // NBSP
        return true;
      default:
        return false;
    }
  }

  /// 跨语言标题比对键：统一折叠全半角、大小写、假名、罗马数字、乘号及繁简体，
  /// 剔除标点符号并移除数字前导零（保证 `Legend 01` 与 `Legend 1` 一致）。
  static String normalize(String value) {
    final folded = TitleNormalizer.fold(value);
    final len = folded.length;
    if (len == 0) return '';
    final buf = StringBuffer();
    var i = 0;
    while (i < len) {
      final c = folded.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) {
        // 连续数字段跳过前导零（保留独立单个 `0`），等价于 `(?<!\d)0+(?=\d)`。
        final start = i;
        while (i < len &&
            folded.codeUnitAt(i) >= 0x30 &&
            folded.codeUnitAt(i) <= 0x39) {
          i++;
        }
        var nz = start;
        while (nz < i - 1 && folded.codeUnitAt(nz) == 0x30) {
          nz++;
        }
        for (var k = nz; k < i; k++) {
          buf.writeCharCode(folded.codeUnitAt(k));
        }
        continue;
      }
      if (!_isNormalizedStripPunct(c)) {
        buf.writeCharCode(c);
      }
      i++;
    }
    return buf.toString();
  }
}
