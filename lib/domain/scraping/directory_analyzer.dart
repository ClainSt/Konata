import 'package:path/path.dart' as p;

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
  LogicalItem(this.key, this.title, this.episode, this.season);
  final String key, title;
  final int? episode, season;
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

  Set<int> get episodes => {
    for (final item in main)
      if (item.episode != null) item.episode!,
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
    r'(?:^|[^a-z])(?:ova|oad|oav)(?:[^a-z]|$)',
    caseSensitive: false,
  );

  /// 语义明确的纯附属影像词汇：即便目录内单独存在，也不视作正片。
  static final _unambiguousExtra = RegExp(
    r'(?<![a-z0-9])(?:nc(?:op|ed)\w*|pv\w*|cm\w*|menus?(?:[ ._-]*ex)?\d*|'
    r'music[ ._-]*(?:video|clip)|mv[ ._-]*making|'
    r'trailers?\d*|teasers?\d*|previews?\d*|samples?\d*|drama[ ._-]*cd|'
    r'making|commentary|eyecatch|karaoke|'
    r'tv[ ._-]*cm|bd[ ._-]*cm|bd[ ._-]*menu\w*)(?![a-z0-9])|'
    r'[\[(【]\s*(?<![a-z0-9])(?:op|ed)\d*(?:v\d+)?(?![a-z0-9])\s*[\])】]|'
    r'[\[(（【]\s*mv\s*[\])）】]|'
    r'[\[【]\s*\d{1,3}\s*[\(（]\s*(?:oad|ova\d*|sp\d*|special)\s*[\)）]\s*[\]】]|'
    r'予告|預告|预告|特報|メニュ|メイキング|映像特典|ノンクレ|'
    r'アイキャッチ(?:集)?|オーディオ[ ._-]*コメンタリー|ミュージック[ ._-]*(?:ビデオ|クリップ)',
    caseSensitive: false,
  );

  /// 上下文敏感的特典词汇：同存正片或体积偏小时判作特典；
  /// 但若独立大型正片（体积 >= 150 MB）标题恰好包含 `Event`/`Talk`/`MV` 等词，
  /// 绝不能被误清为空目录 `[WorkShape.empty]`；`OP/ED` 另外通过严格边界校验识别。
  /// 详见 `[CloudMediaFileClassifier.isOpEdExtra]`。
  static final _ambiguousExtra = RegExp(
    r'(?<![a-z0-9])(?:interviews?|events?|talk|radio|logo|gallery|advice|'
    r'mv|music[ ._-]*clip|spots?|info|supporters?|digest|recap|'
    r'prologue[ ._-]+to[ ._-]+the[ ._-]+movie)(?:[ ._-]*\d+)?(?![a-z0-9])|'
    r'インタビュー|イベント|トーク|ラジオ|特典|宣伝|スポット|座談会|上映会|'
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
    r'(?:^|[\s._\-\[(])(?:(?:19|20)\d{2}[\s._-]+(?=.*\b\d{3,4}p\b)|'
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
  static DirectoryInventory analyze(
    String folder,
    Iterable<({String path, int? size})> files,
  ) {
    final normalizedFolder = folder.replaceAll('\\', '/');
    final name = p.posix.basename(normalizedFolder);
    final supplementaryFolder =
        CloudMediaFileClassifier.isSupplementaryDirectory(name);
    final rawCleanTitle = cleanTitle(name);
    final specialCollectionTitle = supplementaryFolder
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

    for (final entry in videoEntries) {
      final path = entry.path;
      final file = p.posix.basename(path);
      final directory = p.posix.dirname(path) == '.'
          ? ''
          : p.posix.dirname(path);
      final cleanFile = CloudMediaFileClassifier.stripTechnicalNoise(file);
      final plainFile = _plain(file);
      if (supplementaryFolder ||
          CloudMediaFileClassifier.isSupplementaryDirectory(directory) ||
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
          _movieMarker.hasMatch(name) || _movieMarker.hasMatch(_plain(soleBase));
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
    final featureTitles = {
      for (final i in items)
        if (i.episode == null) i.title,
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
    final WorkShape shape;
    if (items.isEmpty) {
      shape = WorkShape.empty;
    } else if (specialCollectionTitle == null &&
        (episodeTitles.length >= 4 && dominant < episodic * 0.5 ||
            featureTitles.length >= 6 &&
                featureTitles.length > episodeTitles.length * 4 &&
                items.where((i) => i.episode != null).length < 6)) {
      // 目录内混杂多部无关剧场版或外传系列（例如 SD 高达外传全集）。
      shape = WorkShape.anthology;
    } else if (items.any((i) => i.episode != null)) {
      shape = WorkShape.series;
    } else {
      shape = WorkShape.feature;
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

    int? inferredSeason = specialCollectionTitle != null
        ? 0
        : WorkSeason.explicit({'title': name});
    final titleHints = <String>[];
    hint(titleHints, title);
    final folderSplit = splitSeasonSuffix(title, isSeries: isSeries);
    inferredSeason ??= folderSplit.season;
    if (folderSplit.baseTitle != title) {
      hint(titleHints, folderSplit.baseTitle);
    }
    final withoutMarker = title
        .replaceAll(
          RegExp(r'剧场版|劇場版|\bOVA\b|\bOAD\b', caseSensitive: false),
          ' ',
        )
        .trim();
    hint(titleHints, withoutMarker);
    // 按频次降序汇总归一化标题，将出现最频繁的文件名主标题排在首位。
    final counts = <String, int>{};
    for (final item in items) {
      for (final file in item.files) {
        for (final candidate in _fileTitles(
          p.posix.basename(file),
          item.episode,
        )) {
          counts.update(candidate, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
    final ranked = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    if (ranked.isNotEmpty) {
      final dominantFile = ranked.first;
      inferredSeason ??= CloudMediaAssetPresentation.explicitSeasonNumber({
        'work_title': dominantFile,
      });
      final domSplit = splitSeasonSuffix(dominantFile, isSeries: isSeries);
      inferredSeason ??= domSplit.season;
    }
    for (final value in ranked) {
      hint(fileHints, value);
      final split = splitSeasonSuffix(value, isSeries: isSeries);
      if (split.baseTitle != value) {
        hint(fileHints, split.baseTitle);
      }
    }

    final folderYear = WorkSeason.year({'title': name});
    int? fileYear;
    if (folderYear == null && shape == WorkShape.feature) {
      final years = {
        for (final file in allMain)
          ?int.tryParse(
            RegExp(
                  r'[(\[ ._]((?:19|20)\d{2})[)\] ._]',
                ).firstMatch(file)?.group(1) ??
                '',
          ),
      };
      if (years.length == 1) fileYear = years.single;
    }
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
    return DirectoryInventory._(
      folder: normalizedFolder,
      title: title,
      year: folderYear ?? fileYear,
      tmdbId: tmdbId,
      tmdbType: tmdbType,
      bangumiId: bangumiId,
      season: inferredSeason,
      folderMovieMarker: folderMovie,
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
    final romanTail = RegExp(
      r'^(.+?)\s+(II|III|IV|Ⅱ|Ⅲ|Ⅳ)$',
      caseSensitive: false,
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
        if (item.episode != null && item.episode! >= 1) item.episode!,
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

  static void _add(
    Map<String, LogicalItem> main,
    String directory,
    String file,
    String path, {
    bool promoted = false,
    int? episodeOverride,
  }) {
    final episode =
        episodeOverride ??
        CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
          directory,
          file,
        );
    final season = RegExp(
      r'(?<![a-z0-9])s(\d{1,2})(?:[ ._-]*e\d{1,4}|[ ._-]+-)',
      caseSensitive: false,
    ).firstMatch(file);
    final core = versionKey(file);
    final title = episode == null
        ? core
        : normalize(
            seriesTitle(
              PersonalFilenameParser.extractAnimeSearchKeyword(file),
              episode,
              rawFile: file,
            ),
          );
    // 同一集的多种压制版本按 `(season, number)` 键折叠去重；
    // 系列标题仅额外保留用于合集判定与名称提示。
    final key = episode == null
        ? 'f:$core'
        : 'e:${season?.group(1) ?? ''}:$episode';
    (main[key] ??= LogicalItem(
        key,
        title,
        episode,
        season == null ? null : int.parse(season.group(1)!),
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

  static String _trimTechnical(String value) {
    final cut = _technical.firstMatch(value);
    var result = cut == null ? value : value.substring(0, cut.start);
    result = result.replaceAll(
      RegExp(
        r'[\s._-]+(?:19|20)\d{2}$|[\s._-]+(?:movie|ova)$',
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

  static bool _isVideo(String path) => RegExp(
    r'\.(?:mkv|mp4|avi|m2ts|ts|webm|mov|wmv)$',
    caseSensitive: false,
  ).hasMatch(path);

  /// 清理刮削源标记、发行年份及方括号标签后的纯净目录名称。
  static String cleanTitle(String folderName) {
    var title = PersonalFilenameParser.withoutTmdbMarkers(folderName)
        .replaceAll(_bangumiMarker, ' ')
        .replaceAll(RegExp(r'[(（]\s*(?:19|20)\d{2}\s*[)）]'), ' ')
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ');
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return title.isEmpty ? folderName : title;
  }

  /// 跨语言标题比对键：统一折叠全半角、大小写、假名、罗马数字、乘号及繁简体，
  /// 剔除标点符号并移除数字前导零（保证 `Legend 01` 与 `Legend 1` 一致）。
  static String normalize(String value) => TitleNormalizer.fold(value)
      .replaceAll(RegExp(r'(?<!\d)0+(?=\d)'), '')
      .replaceAll(
        RegExp(
          r'''[\s\-_—–~～〜:：.,，、;；!！?？・·•'’‘"“”()（）\[\]【】{}「」『』<>《》/\\|&＆+＋*☆★♪]''',
        ),
        '',
      );
}
