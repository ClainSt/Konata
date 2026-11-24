import 'dart:convert';
import 'dart:io';

import 'package:engine_scraping/engine_scraping.dart';

/// 评测运行模式。
enum EvalMode {
  /// 零网络秒级离线解析、归组、拆分与特典分类。
  parseOnly,

  /// 从全量快照分层抽样生成待核对的黄金回归集 CSV。
  initGolden,

  /// 高频回归黄金集，输出六维分桶指标与精确差异。
  golden,

  /// 仅重跑错题本与最近修复样本。
  onlyFailed,

  /// 全量评测云盘快照中所有不带显式 TMDB ID 的可播放作品（验证无 ID 盲测极限覆盖）。
  corpusNoId,

  /// 全量评测云盘快照中的全部归组作品（常与 `--with-explicit --artwork=off` 搭配验收全库 99.5% 指标）。
  corpusAll,

  /// 将最近一次有效评测汇总锁定为当前对比基线。
  acceptBaseline,
}

/// 评测期艺术图（TMDB `/images` + Fanart.tv 整包）探测档位。
enum EvalArtworkMode {
  /// 跳过图集与 Fanart 探测，仅测元数据匹配。
  off,

  /// 复现批量刮削：优胜绑定后拉 TMDB 图集，仅缺封面或背景欠佳/无 TMDB 有 `tvdbId` 时查 Fanart。
  batch,

  /// 复现详情页联合升级：凡 TMDB 缺少简中高清徽标、背景欠佳或缺封面均触发 Fanart 跨源排序。
  full,
}

/// 评测模拟的媒体源类型（控制是否启用本地目录 `poster/cover/folder` 封面识别）。
enum EvalSourceKind {
  /// 模拟远程 WebDAV 源（关闭本地封面探测）。
  webdav,

  /// 模拟本地磁盘源（开启 `poster > cover > folder` 目录封面探测）。
  local,
}

/// 黄金回归集单条标注用例（支持同一物理目录多行描述拆簇子作品）。
class GoldenCase {
  /// 创建单条黄金集用例。
  const GoldenCase({
    required this.caseId,
    required this.bucket,
    required this.physicalRoot,
    this.clusterHint = '*',
    this.expectedTmdb = '',
    this.expectedSeason = '',
    this.expectedBangumi = '',
    this.expectedWall = '',
    this.expectedMainCount,
    this.forbiddenExtraLeak = true,
    this.expectLogoMinTier = '',
    this.verified = false,
    this.suggestedTitle = '',
    this.verifyLinks = '',
    this.notes = '',
  });

  /// 用例唯一编号（如 `G001`、`G002a`）。
  final String caseId;

  /// 分桶标识（`tv` / `mixed_movie` / `ova_sp` / `noise_extra` / `pure_noise` / `remake_multi`）。
  final String bucket;

  /// 物理作品根目录相对路径（不依赖内部虚拟拆簇后缀）。
  final String physicalRoot;

  /// 同一物理目录多子簇时的定位关键词正则；单作品目录填 `*`。
  final String clusterHint;

  /// 期望 TMDB 标识（如 `tv:100565`、`movie:413594`、`none`，多可接受解用 `|` 分隔，留空不计分）。
  final String expectedTmdb;

  /// 期望 TMDB 季号（整数含 `0`、`multi` 或留空不计分）。
  final String expectedSeason;

  /// 期望 Bangumi 条目 ID（数字、`none`、多解用 `|` 分隔或留空不计分）。
  final String expectedBangumi;

  /// 期望独立上墙通道（`tmdb` / `bgm_only` / `cover_fallback` / `block` / 留空不计分）。
  final String expectedWall;

  /// 期望正片集数（`null` 表示不考评精确集数）。
  final int? expectedMainCount;

  /// 是否要求严禁任何 `NCOP/NCED/Menu/PV/CM/Sample` 噪音文件混入正片。
  final bool forbiddenExtraLeak;

  /// 可选期望透明徽标最低语言高清档位（如 `zh_hd` / `ja_hd` / `any` / 留空不考评）。
  final String expectLogoMinTier;

  /// 是否已由人工核对确认真值。
  final bool verified;

  /// 自动预填的参考标题与年份（方便人工表格核对，不参与计分）。
  final String suggestedTitle;

  /// 自动预填的可点击核对链接（不参与计分）。
  final String verifyLinks;

  /// 人工备注。
  final String notes;

  /// 解析可接受的 TMDB 目标集合（空集表示该维度不计分；含 `'none'` 表示明确不得绑定）。
  Set<String> get acceptedTmdbKeys => _splitAccepted(expectedTmdb);

  /// 解析可接受的 Bangumi 目标集合。
  Set<String> get acceptedBangumiKeys => _splitAccepted(expectedBangumi);

  static Set<String> _splitAccepted(String raw) {
    final trimmed = raw.trim().toLowerCase();
    if (trimmed.isEmpty) return const {};
    return trimmed
        .split('|')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
  }
}

/// 黄金集 UTF-8 BOM CSV 编解码器（兼容 Excel 双击直开与 VS Code 编辑）。
abstract final class GoldenSetCsvCodec {
  /// 标准列头顺序。
  static const List<String> headers = <String>[
    'case_id',
    'bucket',
    'physical_root',
    'cluster_hint',
    'expected_tmdb',
    'expected_season',
    'expected_bangumi',
    'expected_wall',
    'expected_main_count',
    'forbidden_extra_leak',
    'expect_logo_min_tier',
    'verified',
    'suggested_title',
    'verify_links',
    'notes',
  ];

  /// 将黄金集写入带 UTF-8 BOM 的 CSV 文件。
  static void writeFile(File file, List<GoldenCase> cases) {
    file.parent.createSync(recursive: true);
    final buf = StringBuffer();
    buf.writeln(headers.map(_escapeCell).join(','));
    for (final c in cases) {
      final row = <String>[
        c.caseId,
        c.bucket,
        c.physicalRoot,
        c.clusterHint,
        c.expectedTmdb,
        c.expectedSeason,
        c.expectedBangumi,
        c.expectedWall,
        c.expectedMainCount?.toString() ?? '',
        c.forbiddenExtraLeak ? 'true' : 'false',
        c.expectLogoMinTier,
        c.verified ? '1' : '0',
        c.suggestedTitle,
        c.verifyLinks,
        c.notes,
      ];
      buf.writeln(row.map(_escapeCell).join(','));
    }
    final contentBytes = utf8.encode(buf.toString());
    final withBom = <int>[0xEF, 0xBB, 0xBF, ...contentBytes];
    file.writeAsBytesSync(withBom, flush: true);
  }

  /// 读取并解析黄金集 CSV 文件（自动剥离 UTF-8 BOM）。
  static List<GoldenCase> readFile(File file) {
    final bytes = file.readAsBytesSync();
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    }
    final rows = parseCsvRows(text);
    if (rows.isEmpty) return const [];
    final headerIdx = <String, int>{};
    for (var i = 0; i < rows.first.length; i++) {
      headerIdx[rows.first[i].trim().toLowerCase()] = i;
    }

    String col(List<String> row, String name) {
      final idx = headerIdx[name];
      if (idx == null || idx >= row.length) return '';
      return row[idx].trim();
    }

    final result = <GoldenCase>[];
    for (final row in rows.skip(1)) {
      if (row.every((cell) => cell.trim().isEmpty)) continue;
      final caseId = col(row, 'case_id');
      final physicalRoot = col(row, 'physical_root').replaceAll('\\', '/');
      if (caseId.isEmpty && physicalRoot.isEmpty) continue;
      final mainCountRaw = col(row, 'expected_main_count');
      final leakRaw = col(row, 'forbidden_extra_leak').toLowerCase();
      final verifiedRaw = col(row, 'verified').toLowerCase();
      result.add(
        GoldenCase(
          caseId: caseId.isEmpty ? 'G${result.length + 1}' : caseId,
          bucket: col(row, 'bucket').isEmpty ? 'tv' : col(row, 'bucket'),
          physicalRoot: physicalRoot,
          clusterHint: col(row, 'cluster_hint').isEmpty
              ? '*'
              : col(row, 'cluster_hint'),
          expectedTmdb: col(row, 'expected_tmdb'),
          expectedSeason: col(row, 'expected_season'),
          expectedBangumi: col(row, 'expected_bangumi'),
          expectedWall: col(row, 'expected_wall'),
          expectedMainCount: mainCountRaw.isEmpty
              ? null
              : int.tryParse(mainCountRaw),
          forbiddenExtraLeak: leakRaw != 'false' && leakRaw != '0',
          expectLogoMinTier: col(row, 'expect_logo_min_tier'),
          verified: verifiedRaw == '1' || verifiedRaw == 'true',
          suggestedTitle: col(row, 'suggested_title'),
          verifyLinks: col(row, 'verify_links'),
          notes: col(row, 'notes'),
        ),
      );
    }
    return result;
  }

  /// 完整 RFC4180 CSV 解析器（支持引号内逗号、双引号转义与换行）。
  static List<List<String>> parseCsvRows(String input) {
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < input.length && input[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          cell.write(ch);
        }
        continue;
      }
      if (ch == '"') {
        inQuotes = true;
      } else if (ch == ',') {
        row.add(cell.toString());
        cell.clear();
      } else if (ch == '\r') {
        if (i + 1 < input.length && input[i + 1] == '\n') i++;
        row.add(cell.toString());
        cell.clear();
        rows.add(row);
        row = <String>[];
      } else if (ch == '\n') {
        row.add(cell.toString());
        cell.clear();
        rows.add(row);
        row = <String>[];
      } else {
        cell.write(ch);
      }
    }

    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    return rows;
  }

  static String _escapeCell(String value) {
    final needsQuote =
        value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');
    if (!needsQuote) return value;
    return '"${value.replaceAll('"', '""')}"';
  }
}

/// 单个归组/拆簇作品的完整评测记录（离线解析 + 在线匹配 + 上墙通道 + Fanart 整包诊断）。
class EvalClusterRecord {
  /// 创建单条评测记录。
  const EvalClusterRecord({
    required this.folderKey,
    required this.physicalRoot,
    required this.folderName,
    required this.cleanTitle,
    required this.isSplitCluster,
    required this.isMovieHint,
    required this.hasMainPlayable,
    required this.mainVideoCount,
    required this.extraVideoCount,
    required this.cdAssetCount,
    required this.scanAssetCount,
    required this.mainEpisodeNumbers,
    required this.suspectedExtraLeakPaths,
    this.year,
    this.seasonHint,
    this.explicitTmdbId,
    this.explicitMediaType,
    this.localPosterPath,
    this.queries = const [],
    this.matchLevel = 'parse_only',
    this.bestTmdbKey,
    this.bestTmdbTitle,
    this.bestTmdbYear,
    this.matchedSeason,
    this.bestBangumiId,
    this.bestBangumiTitle,
    this.bangumiTier = 'none',
    this.primaryReason = '',
    this.topTmdbSummary = const [],
    this.wallChannel = 'block',
    this.tvdbId,
    this.tvdbIdSource = 'missing',
    this.logoSource = 'none',
    this.logoLanguage = 'none',
    this.logoIsHd = false,
    this.logoPath,
    this.logoUpgradedByFanart = false,
    this.backdropSuboptimal = false,
    this.backdropUpgradedByFanart = false,
    this.posterNeedsFallback = false,
    this.posterFilledByFanart = false,
    this.fanartQueried = false,
    this.networkError,
  });

  /// 归组/拆簇唯一路径键（用于基线对比与断点索引）。
  final String folderKey;

  /// 所属物理作品根目录相对路径。
  final String physicalRoot;

  /// 文件夹显示名。
  final String folderName;

  /// 清洗后的候选片名。
  final String cleanTitle;

  /// 是否由多作混放合集拆分产生。
  final bool isSplitCluster;

  /// 解析阶段是否识别出电影/剧场版信号。
  final bool isMovieHint;

  /// 是否通过 `WorkWallEligibility.hasMainPlayableContent` 正片防线。
  final bool hasMainPlayable;

  /// 归类为正片的视频文件数。
  final int mainVideoCount;

  /// 归类为特典的视频文件数。
  final int extraVideoCount;

  /// 附属 CD 音频资产数。
  final int cdAssetCount;

  /// 附属扫图画册资产数。
  final int scanAssetCount;

  /// 正片已提取集号升序列表。
  final List<int> mainEpisodeNumbers;

  /// 疑似非正片噪音却被判入正片的文件相对路径列表。
  final List<String> suspectedExtraLeakPaths;

  /// 解析年份。
  final int? year;

  /// 解析季号提示。
  final int? seasonHint;

  /// 原目录自带的显式 TMDB ID（盲刮模式下仍保留用于弱监督对照）。
  final int? explicitTmdbId;

  /// 原目录显式 TMDB 媒体类型。
  final String? explicitMediaType;

  /// 本地目录封面路径（仅 `--source-kind=local` 启用）。
  final String? localPosterPath;

  /// 生成的检索关键词列表。
  final List<String> queries;

  /// 在线匹配决策等级（`autoBind` / `reviewRequired` / `unmatched` / `parse_only`）。
  final String matchLevel;

  /// 最佳 TMDB 复合键（如 `tv:100565` / `movie:129`）。
  final String? bestTmdbKey;

  /// 最佳 TMDB 条目标题。
  final String? bestTmdbTitle;

  /// 最佳 TMDB 条目年份。
  final int? bestTmdbYear;

  /// 最终匹配季号。
  final int? matchedSeason;

  /// 最佳 Bangumi 条目 ID。
  final int? bestBangumiId;

  /// 最佳 Bangumi 条目标题。
  final String? bestBangumiTitle;

  /// Bangumi 初轮匹配等级（`high` / `medium` / `none`）。
  final String bangumiTier;

  /// 主决策/待复核原因码。
  final String primaryReason;

  /// Top-3 TMDB 候选摘要。
  final List<String> topTmdbSummary;

  /// 最终独立上墙通道（`tmdb` / `bgm_only` / `cover_fallback` / `block`）。
  final String wallChannel;

  /// 解析得到的 TheTVDB ID。
  final int? tvdbId;

  /// `tvdbId` 供给来源（`tmdb_external_ids` / `offline_map_v2` / `missing`）。
  final String tvdbIdSource;

  /// 最终透明徽标来源（`tmdb` / `fanart` / `none`）。
  final String logoSource;

  /// 最终透明徽标语言档位（`zh_cn` / `zh_tw` / `ja` / `en` / `neutral` / `other` / `none`）。
  final String logoLanguage;

  /// 最终透明徽标是否高清档位。
  final bool logoIsHd;

  /// 最终透明徽标路径或 URL（不下载图片二进制）。
  final String? logoPath;

  /// 透明徽标是否由 Fanart.tv 跨源升级胜出。
  final bool logoUpgradedByFanart;

  /// TMDB 背景图是否被判欠佳（缺失、低于 1080p 或带字）。
  final bool backdropSuboptimal;

  /// 背景图是否由 Fanart.tv 无字 1080p 横图成功升级。
  final bool backdropUpgradedByFanart;

  /// 作品是否处于缺封面待补状态。
  final bool posterNeedsFallback;

  /// 封面是否由 Fanart.tv 竖版海报成功补齐。
  final bool posterFilledByFanart;

  /// 本作品是否实际触发了 Fanart 整包查询。
  final bool fanartQueried;

  /// 网络或异常摘要（已脱敏）。
  final String? networkError;

  /// 导出紧凑 JSONL 结构。
  Map<String, Object?> toJson() => {
    'folderKey': folderKey,
    'physicalRoot': physicalRoot,
    'folderName': folderName,
    'cleanTitle': cleanTitle,
    'isSplitCluster': isSplitCluster,
    'isMovieHint': isMovieHint,
    'hasMainPlayable': hasMainPlayable,
    'mainVideoCount': mainVideoCount,
    'extraVideoCount': extraVideoCount,
    'cdAssetCount': cdAssetCount,
    'scanAssetCount': scanAssetCount,
    'mainEpisodeNumbers': mainEpisodeNumbers,
    'suspectedExtraLeakPaths': suspectedExtraLeakPaths,
    'year': year,
    'seasonHint': seasonHint,
    'explicitTmdbId': explicitTmdbId,
    'explicitMediaType': explicitMediaType,
    'localPosterPath': localPosterPath,
    'queries': queries,
    'matchLevel': matchLevel,
    'bestTmdbKey': bestTmdbKey,
    'bestTmdbTitle': bestTmdbTitle,
    'bestTmdbYear': bestTmdbYear,
    'matchedSeason': matchedSeason,
    'bestBangumiId': bestBangumiId,
    'bestBangumiTitle': bestBangumiTitle,
    'bangumiTier': bangumiTier,
    'primaryReason': primaryReason,
    'topTmdbSummary': topTmdbSummary,
    'wallChannel': wallChannel,
    'tvdbId': tvdbId,
    'tvdbIdSource': tvdbIdSource,
    'logoSource': logoSource,
    'logoLanguage': logoLanguage,
    'logoIsHd': logoIsHd,
    'logoPath': logoPath,
    'logoUpgradedByFanart': logoUpgradedByFanart,
    'backdropSuboptimal': backdropSuboptimal,
    'backdropUpgradedByFanart': backdropUpgradedByFanart,
    'posterNeedsFallback': posterNeedsFallback,
    'posterFilledByFanart': posterFilledByFanart,
    'fanartQueried': fanartQueried,
    'networkError': networkError,
  };

  /// 从 JSON Map 反序列化（供基线对比与错题恢复）。
  factory EvalClusterRecord.fromJson(Map<String, Object?> json) {
    List<int> intList(Object? raw) => raw is List
        ? [for (final item in raw) if (item is num) item.toInt()]
        : const [];
    List<String> strList(Object? raw) => raw is List
        ? [for (final item in raw) item.toString()]
        : const [];
    return EvalClusterRecord(
      folderKey: (json['folderKey'] ?? '').toString(),
      physicalRoot: (json['physicalRoot'] ?? '').toString(),
      folderName: (json['folderName'] ?? '').toString(),
      cleanTitle: (json['cleanTitle'] ?? '').toString(),
      isSplitCluster: json['isSplitCluster'] == true,
      isMovieHint: json['isMovieHint'] == true,
      hasMainPlayable: json['hasMainPlayable'] == true,
      mainVideoCount: (json['mainVideoCount'] as num?)?.toInt() ?? 0,
      extraVideoCount: (json['extraVideoCount'] as num?)?.toInt() ?? 0,
      cdAssetCount: (json['cdAssetCount'] as num?)?.toInt() ?? 0,
      scanAssetCount: (json['scanAssetCount'] as num?)?.toInt() ?? 0,
      mainEpisodeNumbers: intList(json['mainEpisodeNumbers']),
      suspectedExtraLeakPaths: strList(json['suspectedExtraLeakPaths']),
      year: (json['year'] as num?)?.toInt(),
      seasonHint: (json['seasonHint'] as num?)?.toInt(),
      explicitTmdbId: (json['explicitTmdbId'] as num?)?.toInt(),
      explicitMediaType: json['explicitMediaType']?.toString(),
      localPosterPath: json['localPosterPath']?.toString(),
      queries: strList(json['queries']),
      matchLevel: (json['matchLevel'] ?? 'parse_only').toString(),
      bestTmdbKey: json['bestTmdbKey']?.toString(),
      bestTmdbTitle: json['bestTmdbTitle']?.toString(),
      bestTmdbYear: (json['bestTmdbYear'] as num?)?.toInt(),
      matchedSeason: (json['matchedSeason'] as num?)?.toInt(),
      bestBangumiId: (json['bestBangumiId'] as num?)?.toInt(),
      bestBangumiTitle: json['bestBangumiTitle']?.toString(),
      bangumiTier: (json['bangumiTier'] ?? 'none').toString(),
      primaryReason: (json['primaryReason'] ?? '').toString(),
      topTmdbSummary: strList(json['topTmdbSummary']),
      wallChannel: (json['wallChannel'] ?? 'block').toString(),
      tvdbId: (json['tvdbId'] as num?)?.toInt(),
      tvdbIdSource: (json['tvdbIdSource'] ?? 'missing').toString(),
      logoSource: (json['logoSource'] ?? 'none').toString(),
      logoLanguage: (json['logoLanguage'] ?? 'none').toString(),
      logoIsHd: json['logoIsHd'] == true,
      logoPath: json['logoPath']?.toString(),
      logoUpgradedByFanart: json['logoUpgradedByFanart'] == true,
      backdropSuboptimal: json['backdropSuboptimal'] == true,
      backdropUpgradedByFanart: json['backdropUpgradedByFanart'] == true,
      posterNeedsFallback: json['posterNeedsFallback'] == true,
      posterFilledByFanart: json['posterFilledByFanart'] == true,
      fanartQueried: json['fanartQueried'] == true,
      networkError: json['networkError']?.toString(),
    );
  }
}

/// BDRip 非正片噪音误入正片检测器与特征分层黄金集抽样器。
abstract final class GoldenSetSampler {
  /// 强噪音特典特征正则（命中却归为正片则标记为疑似噪音泄漏）。
  static final RegExp strictExtraNoisePattern = RegExp(
    r'(?:^|[/\\._\-\[\(（【\s])(?:'
    r'ncop(?:ed)?|nced|creditless|textless|non[._ -]?credit|non[._ -]?telop|'
    r'bd[._ -]?menu|menu(?:[._ -]*\d+)?|menue\d*|hauptmenue|vorschau|'
    r'bd[._ -]?sp[._ -]?live\w*|sp[._ -]?live\w*|bd[._ -]?special[._ -]*talk|'
    r'tvcm|bdcm|pvcm|cm\d+|pv\d+|'
    r'trailer|teaser|sample|making|interview|commentary|tokuten|picture[._ -]*drama|'
    r'映像特典|特典映像|ノンクレジット|ノンテロップ|メニュー|'
    r'tvスポット|プロモーション映像|ミコージック・クリップ|ミュージック・クリップ|'
    r'劇場アナウンス|ピクチャードラマ|スペシャル映像'
    r')(?=$|[/\\._\-\]\)）】\s\d])',
    caseSensitive: false,
  );

  static final RegExp _titleWordSplitter = RegExp(r'[^a-z0-9]+');

  static final RegExp _ovaSpPattern = RegExp(
    r'(?:^|[\s._\-\[\(（【])(?:ova|oad|oav|sp\d*|specials?|ex\d{0,2}|特别篇|特別編)(?=$|[\s._\-\]\)）】])',
    caseSensitive: false,
  );

  static final RegExp _multiSeasonPattern = RegExp(
    r's\d{1,2}\s*[+&~～\-–—]\s*s?\d{1,2}|全[0-9一二三四五六七八九十]+季|全集|合集|系列',
    caseSensitive: false,
  );

  static final RegExp _releaseGroupBracket = RegExp(r'[\[【][^\]】]{2,24}[\]】]');

  /// 扫描单作品分组内的正片文件，返回疑似非正片噪音泄漏路径列表（自动排除作品本体片名自带词，如 `Shomin Sample`）。
  static List<String> detectSuspectedExtraLeaks(GroupedWorkFolder folder) {
    final leaks = <String>[];
    final slots = folder.slotAssignmentsByPath;
    final titleWords = <String>{
      for (final source in [
        folder.cleanTitle,
        folder.folderName,
        ...folder.titleHints,
        ...folder.fileHints,
      ])
        for (final w in source.toLowerCase().split(_titleWordSplitter))
          if (w.length >= 4) w,
    };
    final root = _normalizePhysicalRoot(folder);
    for (final v in folder.variants) {
      if (v.assetKind != AssetKind.video) continue;
      final slot = slots[v.relativePath];
      final isMain = slot == null || slot.category == EpisodeCategory.main;
      if (!isMain) continue;
      var subRel = v.relativePath.replaceAll('\\', '/');
      if (subRel.startsWith('$root/')) {
        subRel = subRel.substring(root.length + 1);
      }
      final hit = strictExtraNoisePattern.firstMatch(subRel);
      if (hit == null) continue;
      final token = hit.group(0)!.toLowerCase().replaceAll(_titleWordSplitter, '');
      if (token.isNotEmpty && titleWords.contains(token)) {
        continue;
      }
      leaks.add(v.relativePath);
    }
    return leaks;
  }

  /// 统计单个归组分组的基础解析与资产特征。
  static ({
    int mainVideoCount,
    int extraVideoCount,
    int cdAssetCount,
    int scanAssetCount,
    bool hasMainPlayable,
    List<String> suspectedLeaks,
  })
  inspectFolder(GroupedWorkFolder folder) {
    var mainVideos = 0;
    var extraVideos = 0;
    var cdAssets = 0;
    var scanAssets = 0;
    final slots = folder.slotAssignmentsByPath;
    for (final v in folder.variants) {
      switch (v.assetKind) {
        case AssetKind.video:
          final slot = slots[v.relativePath];
          if (slot == null || slot.category == EpisodeCategory.main) {
            mainVideos++;
          } else {
            extraVideos++;
          }
        case AssetKind.cdAlbum:
          cdAssets++;
        case AssetKind.scanGallery:
          scanAssets++;
      }
    }
    return (
      mainVideoCount: mainVideos,
      extraVideoCount: extraVideos,
      cdAssetCount: cdAssets,
      scanAssetCount: scanAssets,
      hasMainPlayable: WorkWallEligibility.hasMainPlayableContent(folder),
      suspectedLeaks: detectSuspectedExtraLeaks(folder),
    );
  }

  /// 按目录结构特征分层抽样构建黄金集（物理多簇目录按整组纳入，自动预填参考信息供人工核对）。
  static List<GoldenCase> buildStratifiedSample({
    required List<GroupedWorkFolder> groups,
    Map<String, EvalClusterRecord> predictionsByFolderKey = const {},
    int targetRootCount = 180,
  }) {
    final byRoot = <String, List<GroupedWorkFolder>>{};
    for (final g in groups) {
      final root = _normalizePhysicalRoot(g);
      byRoot.putIfAbsent(root, () => <GroupedWorkFolder>[]).add(g);
    }

    final strata = <String, List<String>>{
      'mixed_movie': <String>[],
      'ova_sp': <String>[],
      'noise_extra': <String>[],
      'pure_noise': <String>[],
      'remake_multi': <String>[],
      'short_numeric': <String>[],
      'complex_naming': <String>[],
      'tv': <String>[],
    };

    final sortedRoots = byRoot.keys.toList()..sort();
    for (final root in sortedRoots) {
      final clusters = byRoot[root]!;
      final bucket = _classifyRootStratum(root, clusters);
      strata[bucket]!.add(root);
    }

    // 按结构复杂度分配目标配额，确保混放、特典噪音、OVA/SP、多季与短名均有充分覆盖。
    final quotas = <String, int>{
      'mixed_movie': (targetRootCount * 0.22).round(),
      'ova_sp': (targetRootCount * 0.16).round(),
      'noise_extra': (targetRootCount * 0.16).round(),
      'pure_noise': (targetRootCount * 0.06).round(),
      'remake_multi': (targetRootCount * 0.10).round(),
      'short_numeric': (targetRootCount * 0.06).round(),
      'complex_naming': (targetRootCount * 0.08).round(),
      'tv': (targetRootCount * 0.16).round(),
    };

    final picked = <String, String>{};
    // 优先将全部多作品拆分根目录纳入黄金集，确保混放 TV+Movie/OVA 拆簇全量受控。
    for (final root in sortedRoots) {
      if (byRoot[root]!.length >= 2 && picked.length < targetRootCount) {
        picked[root] = 'mixed_movie';
      }
    }
    // 优先纳入一定比例的无显式 `{tmdb-N}` 野生目录（如 `未添加TMDB ID`、`天雪论坛`），避免黄金集偏向已规范目录。
    final untaggedQuota = (targetRootCount * 0.16).round();
    final untaggedPool = <({String root, String bucket})>[
      for (final root in sortedRoots)
        if (!picked.containsKey(root) &&
            byRoot[root]!.every((c) => c.explicitTmdbId == null))
          (root: root, bucket: _classifyRootStratum(root, byRoot[root]!)),
    ];
    for (final item in _evenlyPick(untaggedPool, untaggedQuota)) {
      if (picked.length < targetRootCount) {
        picked[item.root] = item.bucket;
      }
    }

    for (final entry in quotas.entries) {
      final pool = [
        for (final r in strata[entry.key]!)
          if (!picked.containsKey(r)) r,
      ];
      final already = picked.values.where((b) => b == entry.key).length;
      final remainingQuota = (entry.value - already).clamp(0, entry.value);
      for (final root in _evenlyPick(pool, remainingQuota)) {
        if (picked.length < targetRootCount) {
          picked[root] = entry.key;
        }
      }
    }

    // 配额未满时从其余未选池均匀回填。
    if (picked.length < targetRootCount) {
      final leftovers = <({String root, String bucket})>[
        for (final entry in strata.entries)
          for (final r in entry.value)
            if (!picked.containsKey(r)) (root: r, bucket: entry.key),
      ];
      final need = targetRootCount - picked.length;
      for (final item in _evenlyPick(leftovers, need)) {
        picked[item.root] = item.bucket;
      }
    }

    final cases = <GoldenCase>[];
    var seq = 1;
    final pickedRoots = picked.keys.toList()..sort();
    for (final root in pickedRoots) {
      final stratum = picked[root]!;
      final clusters = byRoot[root]!;
      final baseId = 'G${seq.toString().padLeft(3, '0')}';
      seq++;

      for (var i = 0; i < clusters.length; i++) {
        final g = clusters[i];
        final suffix = clusters.length == 1
            ? ''
            : String.fromCharCode('a'.codeUnitAt(0) + i);
        final stats = inspectFolder(g);
        final isTruePureNoise = stats.mainVideoCount == 0;
        final pred = predictionsByFolderKey[g.folderRelativePath];
        final bucket = _caseBucketForCluster(stratum, g, !isTruePureNoise);
        final hint = clusters.length == 1
            ? '*'
            : _buildClusterHint(g, i, clusters.length);

        final tmdbPred = pred?.bestTmdbKey ??
            (g.explicitTmdbId != null
                ? '${g.explicitMediaType?.name ?? (g.isMovieHint ? 'movie' : 'tv')}:${g.explicitTmdbId}'
                : '');
        final seasonPred =
            pred?.matchedSeason?.toString() ?? g.seasonHint?.toString() ?? '';
        final bgmPred = pred?.bestBangumiId?.toString() ?? '';
        final wallPred = isTruePureNoise
            ? 'block'
            : (pred?.wallChannel ?? (tmdbPred.isNotEmpty ? 'tmdb' : ''));
        final titleNote = [
          if (pred?.bestTmdbTitle != null) pred!.bestTmdbTitle!,
          if (pred?.bestTmdbTitle == null) g.cleanTitle,
          if ((pred?.bestTmdbYear ?? g.year) != null)
            '(${pred?.bestTmdbYear ?? g.year})',
        ].join(' ');
        final links = _buildVerifyLinks(
          tmdbKey: tmdbPred,
          bangumiId: pred?.bestBangumiId,
        );
        final noteParts = <String>[
          if (clusters.length > 1) '合集拆簇(${i + 1}/${clusters.length})',
          if (stats.extraVideoCount > 0) '特典${stats.extraVideoCount}',
          if (stats.cdAssetCount > 0) 'CD${stats.cdAssetCount}',
          if (stats.scanAssetCount > 0) 'Scan${stats.scanAssetCount}',
          if (g.explicitTmdbId != null) '原目录含tmdb:${g.explicitTmdbId}',
        ];

        cases.add(
          GoldenCase(
            caseId: '$baseId$suffix',
            bucket: bucket,
            physicalRoot: root,
            clusterHint: hint,
            expectedTmdb: isTruePureNoise ? 'none' : tmdbPred,
            expectedSeason: isTruePureNoise ? '' : seasonPred,
            expectedBangumi: isTruePureNoise ? 'none' : bgmPred,
            expectedWall: wallPred,
            expectedMainCount: isTruePureNoise
                ? 0
                : (g.mainEpisodeNumbers.isNotEmpty
                      ? g.mainEpisodeNumbers.toSet().length
                      : stats.mainVideoCount),
            forbiddenExtraLeak: true,
            verified: false,
            suggestedTitle: titleNote,
            verifyLinks: links,
            notes: noteParts.join(' | '),
          ),
        );
      }
    }
    return cases;
  }

  static String _normalizePhysicalRoot(GroupedWorkFolder g) {
    final raw = (g.physicalRootFolder ?? g.folderRelativePath)
        .trim()
        .replaceAll('\\', '/');
    final idx = raw.indexOf('::');
    return idx > 0 ? raw.substring(0, idx) : raw;
  }

  static String _classifyRootStratum(
    String root,
    List<GroupedWorkFolder> clusters,
  ) {
    if (clusters.length >= 2 || clusters.any((c) => c.isSplitCluster)) {
      return 'mixed_movie';
    }
    final single = clusters.single;
    final info = inspectFolder(single);
    if (info.mainVideoCount == 0) {
      return 'pure_noise';
    }
    if (!info.hasMainPlayable) {
      return 'remake_multi';
    }
    if (single.isMovieHint) {
      return 'mixed_movie';
    }
    if (_ovaSpPattern.hasMatch(root) || _ovaSpPattern.hasMatch(single.cleanTitle)) {
      return 'ova_sp';
    }
    if (info.extraVideoCount >= 3 ||
        info.cdAssetCount > 0 ||
        info.scanAssetCount > 0 ||
        info.suspectedLeaks.isNotEmpty) {
      return 'noise_extra';
    }
    final cleanLen = single.cleanTitle.replaceAll(RegExp(r'\s+'), '').length;
    if (cleanLen > 0 && cleanLen <= 4) {
      return 'short_numeric';
    }
    if (_multiSeasonPattern.hasMatch(root) || single.year == null) {
      return 'remake_multi';
    }
    if (_releaseGroupBracket.hasMatch(single.folderName)) {
      return 'complex_naming';
    }
    return 'tv';
  }

  static String _caseBucketForCluster(
    String stratum,
    GroupedWorkFolder g,
    bool hasMainPlayable,
  ) {
    if (!hasMainPlayable) return 'pure_noise';
    if (g.isMovieHint) return 'mixed_movie';
    if (_ovaSpPattern.hasMatch(g.folderName) ||
        _ovaSpPattern.hasMatch(g.cleanTitle)) {
      return 'ova_sp';
    }
    return switch (stratum) {
      'short_numeric' || 'complex_naming' => 'tv',
      _ => stratum,
    };
  }

  static String _buildClusterHint(GroupedWorkFolder g, int idx, int total) {
    final cleaned = g.cleanTitle.trim();
    if (cleaned.isNotEmpty) {
      return cleaned;
    }
    final sep = g.folderRelativePath.indexOf('::');
    if (sep > 0) {
      return g.folderRelativePath.substring(sep + 2);
    }
    return 'cluster_${idx + 1}_of_$total';
  }

  static String _buildVerifyLinks({
    required String tmdbKey,
    required int? bangumiId,
  }) {
    final links = <String>[];
    if (tmdbKey.startsWith('tv:')) {
      links.add('https://www.themoviedb.org/tv/${tmdbKey.substring(3)}');
    } else if (tmdbKey.startsWith('movie:')) {
      links.add('https://www.themoviedb.org/movie/${tmdbKey.substring(6)}');
    }
    if (bangumiId != null && bangumiId > 0) {
      links.add('https://bgm.tv/subject/$bangumiId');
    }
    return links.join(' | ');
  }

  static List<T> _evenlyPick<T>(List<T> source, int count) {
    if (count <= 0 || source.isEmpty) return const [];
    if (source.length <= count) return List<T>.of(source);
    final result = <T>[];
    final step = source.length / count;
    for (var i = 0; i < count; i++) {
      final index = (i * step).floor().clamp(0, source.length - 1);
      result.add(source[index]);
    }
    return result;
  }
}
