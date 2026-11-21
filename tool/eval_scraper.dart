import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/application/scraping/scrape_artwork_enricher.dart';
import 'package:ccplayer/application/scraping/scrape_candidate_fetcher.dart';
import 'package:ccplayer/application/scraping/scrape_compute_worker.dart';
import 'package:ccplayer/application/scraping/scrape_match_resolver.dart';
import 'package:ccplayer/domain/formatting/network_error_sanitizer.dart';
import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/matching/work_matcher.dart';
import 'package:ccplayer/domain/models/fanart_models.dart';
import 'package:ccplayer/domain/models/network_config.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/bangumi_tmdb_index.dart';
import 'package:ccplayer/domain/scraping/directory_analyzer.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:ccplayer/domain/scraping/work_wall_eligibility.dart';
import 'package:ccplayer/infrastructure/network/bangumi_service.dart';
import 'package:ccplayer/infrastructure/network/fanart_service.dart';
import 'package:ccplayer/infrastructure/network/priority_http_scheduler.dart';
import 'package:ccplayer/infrastructure/network/tmdb_http_client.dart';
import 'package:ccplayer/infrastructure/network/tmdb_service.dart';
import 'package:http/io_client.dart';

import 'eval/eval_models.dart';
import 'eval/eval_scorer_and_reporter.dart';
import 'eval/eval_vcr_http_client.dart';
import 'scrape_eval_support.dart';

/// 缺少 TMDB 密钥且本地 VCR 缓存未命中时的约定退出码（驱动启动脚本按需延迟弹窗）。
const int exitCodeKeyRequired = 42;

/// Konata 纯 Dart 刮削与 Fanart 整包艺术图自动化评测 CLI。
///
/// 职责边界：
/// - 100% 复用生产解析、拆簇、离线映射、双源匹配、四通道上墙与 Fanart 整包富化逻辑；
/// - 密钥仅从当前进程内存环境变量读取，绝不读取 `dart_defines.dev.json`、绝不落盘、绝不打印；
/// - 严禁下载任何图片二进制、严禁请求单集详情/演职员表、严禁修改或读取用户媒体目录内容。
Future<void> main(List<String> args) async {
  try {
    final options = _EvalCliOptions.parse(args);
    if (options.showHelp) {
      _printUsage();
      return;
    }
    exitCode = await runEvalCli(options);
  } on FormatException catch (e) {
    stderr.writeln('参数错误：${e.message}');
    _printUsage();
    exitCode = 64;
  } on EvalKeyRequiredException catch (e) {
    stderr.writeln(
      '检测到本地 VCR 缓存未命中且内存中缺少 ${e.service.toUpperCase()} 密钥（触发键：${e.canonicalKey}）。',
    );
    exitCode = exitCodeKeyRequired;
  } catch (error) {
    stderr.writeln(
      '评测运行失败：${NetworkErrorSanitizer.redactSecrets(error.toString())}',
    );
    exitCode = 1;
  }
}

/// 可供单测与命令行直接复用的评测执行入口。
Future<int> runEvalCli(
  _EvalCliOptions options, {
  EvalVcrHttpClient? injectedVcrClient,
}) async {
  final evalDir = Directory(options.evalDir);
  final runsDir = Directory('${evalDir.path}${Platform.pathSeparator}runs');
  final cacheDir = Directory(
    '${evalDir.path}${Platform.pathSeparator}http_cache',
  );
  final manifestFile = File(
    options.manifestPath ??
        '${evalDir.path}${Platform.pathSeparator}corpus_manifest.tsv',
  );
  final goldenFile = File(
    options.goldenPath ??
        '${evalDir.path}${Platform.pathSeparator}golden_set.csv',
  );
  final failedKeysFile = File(
    '${evalDir.path}${Platform.pathSeparator}failed_keys.json',
  );
  final baselineFile = File(
    '${runsDir.path}${Platform.pathSeparator}baseline.json',
  );
  final latestSummaryFile = File(
    '${runsDir.path}${Platform.pathSeparator}latest_summary.json',
  );
  final latestDiffFile = File(
    '${runsDir.path}${Platform.pathSeparator}latest_diff.md',
  );

  if (options.mode == EvalMode.acceptBaseline) {
    if (!latestSummaryFile.existsSync()) {
      stderr.writeln('尚无最近一次评测汇总（${latestSummaryFile.path}），无法锁定基线。');
      return 1;
    }
    runsDir.createSync(recursive: true);
    latestSummaryFile.copySync(baselineFile.path);
    stdout.writeln('已将最近一次评测汇总锁定为当前基线：${baselineFile.path}');
    return 0;
  }

  if (!manifestFile.existsSync()) {
    stderr.writeln(
      '未找到目录快照清单：${manifestFile.path}。请先运行 scripts/eval_scraper.ps1 -RefreshSnapshot -MediaRoot "<CD2目录>"。',
    );
    return 2;
  }

  final totalClock = Stopwatch()..start();
  final detectLocalCovers = options.sourceKind == EvalSourceKind.local;

  final goldenCases = _loadGoldenCasesIfNeeded(
    mode: options.mode,
    goldenFile: goldenFile,
  );
  if (options.mode == EvalMode.golden && goldenCases.isEmpty) {
    stderr.writeln(
      '黄金集文件不存在或为空：${goldenFile.path}。请先执行 --mode=init-golden 抽样生成。',
    );
    return 2;
  }

  final prefilterRoots = _computePrefilterPhysicalRoots(
    mode: options.mode,
    manifestFile: manifestFile,
    goldenCases: goldenCases,
    failedKeysFile: failedKeysFile,
    onlyFilters: options.onlyFilters,
  );
  if (options.mode == EvalMode.onlyFailed &&
      options.onlyFilters.isEmpty &&
      prefilterRoots != null &&
      prefilterRoots.isEmpty) {
    stderr.writeln('目标评测集合为空（若运行 --only-failed，说明当前错题本已清空）。');
    return 0;
  }

  final grouped = await groupListing(
    manifestFile.path,
    detectLocalCovers: detectLocalCovers,
    physicalRootPrefixes: prefilterRoots,
  );
  stderr.writeln(
    '快照载入完成：${grouped.files} 媒体文件（${grouped.scanMs}ms），'
    '归组拆簇 ${grouped.groups.length} 作品（${grouped.groupMs}ms）。',
  );

  if (options.mode == EvalMode.initGolden) {
    return _runInitGolden(
      options: options,
      groups: grouped.groups,
      goldenFile: goldenFile,
    );
  }

  final targets = _selectTargetGroups(
    mode: options.mode,
    groups: grouped.groups,
    goldenCases: goldenCases,
    failedKeysFile: failedKeysFile,
    onlyFilters: options.onlyFilters,
    messyFolders: options.messyFolders,
  );
  final activeGoldenCases = _filterGoldenCasesForTargets(
    mode: options.mode,
    goldenCases: goldenCases,
    targets: targets,
    messyFolders: options.messyFolders,
  );

  if (targets.isEmpty) {
    stderr.writeln('目标评测集合为空（若运行 --only-failed，说明当前错题本已清空）。');
    return 0;
  }

  final mapping = _loadActiveMappingIndex();
  final artworkMode = options.effectiveArtworkMode;

  final records = <EvalClusterRecord>[];
  Map<String, Object?> networkStatsJson = const {
    'totalCacheHits': 0,
    'totalCacheMisses': 0,
    'totalNetworkRequests': 0,
    'totalHttp429': 0,
    'domains': <String, Object?>{},
  };

  if (options.mode == EvalMode.parseOnly) {
    for (final g in targets) {
      records.add(_buildParseOnlyRecord(g));
    }
  } else {
    final env = Platform.environment;
    final tmdbKey = (env['KONATA_EVAL_TMDB_KEY'] ?? '').trim();
    final fanartApiKey = (env['KONATA_EVAL_FANART_API_KEY'] ?? '').trim();
    final fanartClientKey = (env['KONATA_EVAL_FANART_CLIENT_KEY'] ?? '').trim();

    // 公开中继物理护栏：仅在无直连 Key 且显式传入 --allow-fanart-relay 时低速启用。
    final fanartRelayAllowed =
        fanartApiKey.isEmpty &&
        options.allowFanartRelay &&
        (options.mode == EvalMode.golden ||
            options.mode == EvalMode.onlyFailed);
    final effectiveFanartBackupBase = fanartRelayAllowed
        ? TmdbNetworkConfig.builtInFanartRelayBase
        : '';

    final netConfig = TmdbNetworkConfig(
      credential: tmdbKey,
      fanartApiKeyOverride: fanartApiKey,
      fanartClientKey: fanartClientKey,
      fanartBackupApiBase: effectiveFanartBackupBase,
      proxyMode: options.noProxy
          ? ProxyMode.none
          : (options.proxyUrl.isNotEmpty ? ProxyMode.custom : ProxyMode.system),
      proxyUrl: options.proxyUrl,
    );

    final vcrClient =
        injectedVcrClient ??
        _createVcrClient(
          cacheDir: cacheDir,
          options: options,
          netConfig: netConfig,
          fanartRelayAllowed: fanartRelayAllowed,
        );

    final workers = options.workers.clamp(1, 12);
    final tmdbHttp = TmdbHttpClient(
      config: netConfig,
      httpClient: vcrClient,
      scheduler: PriorityHttpScheduler(
        backgroundConcurrency: workers * 2,
        backgroundBucketConcurrency: const <String, int>{
          'tmdb': 6,
          'bangumi': 4,
          'fanart': 2,
        },
        maxRetries: 1,
      ),
      primaryTimeout: const Duration(seconds: 25),
      backupTimeout: const Duration(seconds: 30),
    );
    final tmdbService = TmdbService(
      httpClient: tmdbHttp,
      enableSessionCache: true,
    );
    final bangumiService = BangumiService(httpClient: tmdbHttp);
    final fanartService = FanartService(
      httpClient: tmdbHttp,
      artworkCache: FanartArtworkCache(maxEntries: 512),
    );
    final fetcher = ScrapeCandidateFetcher(
      tmdbService,
      bangumiService: bangumiService,
    );
    final resolver = ScrapeMatchResolver(
      fetcher: fetcher,
      computeWorker: const ScrapeComputeWorker(useIsolate: false),
      mappingIndex: mapping.index,
    );
    final enricher = ScrapeArtworkEnricher(
      fanartService: fanartService,
      mappingIndex: mapping.index,
    );

    if (artworkMode != EvalArtworkMode.off && !fanartService.isConfigured) {
      stderr.writeln(
        '提示：未配置 FANART_API_KEY 且未显式启用 -AllowFanartRelay，本次仅评测 TMDB 图集并跳过 Fanart.tv 联网请求。',
      );
    }

    try {
      final results = await _evaluateOnlineBatch(
        targets: targets,
        workers: workers,
        artworkMode: artworkMode,
        withExplicit: options.withExplicit && !options.messyFolders,
        messyFolders: options.messyFolders,
        tmdbService: tmdbService,
        fetcher: fetcher,
        resolver: resolver,
        enricher: enricher,
        mappingIndex: mapping.index,
      );
      records.addAll(results);
      networkStatsJson = vcrClient.stats.toJson();
      if (options.offlineSoft && vcrClient.missedKeys.isNotEmpty) {
        final uniqueMissed = vcrClient.missedKeys.toSet().toList();
        stderr.writeln(
          '离线软回退提示：共 ${vcrClient.missedKeys.length} 次缓存未命中（去重 ${uniqueMissed.length} 个键），前 10 个示例：',
        );
        for (final key in uniqueMissed.take(10)) {
          stderr.writeln('  - $key');
        }
      }
    } finally {
      tmdbHttp.close();
      if (injectedVcrClient == null) {
        vcrClient.close();
      }
    }
  }

  totalClock.stop();
  final runId = _formatRunId(DateTime.now(), options.mode);
  final runDir = Directory('${runsDir.path}${Platform.pathSeparator}$runId')
    ..createSync(recursive: true);

  final report = EvalScorerAndReporter.evaluate(
    runId: runId,
    mode: options.mode,
    artworkMode: artworkMode,
    sourceKind: options.sourceKind,
    mappingInfo: mapping.description,
    elapsedMs: totalClock.elapsedMilliseconds,
    records: records,
    goldenCases: activeGoldenCases,
    networkStatsJson: networkStatsJson,
  );

  final baselineJson = _tryReadJsonMap(baselineFile);
  final diffMd = EvalScorerAndReporter.renderDiffMarkdown(
    report: report,
    baselineJson: baselineJson,
  );

  // 落盘当次完整明细与精简对比摘要。
  final jsonlSink = File(
    '${runDir.path}${Platform.pathSeparator}results.jsonl',
  ).openWrite();
  for (final r in records) {
    jsonlSink.writeln(jsonEncode(r.toJson()));
  }
  await jsonlSink.close();

  final summaryText = const JsonEncoder.withIndent(
    '  ',
  ).convert(report.toJson());
  File(
    '${runDir.path}${Platform.pathSeparator}summary.json',
  ).writeAsStringSync(summaryText, flush: true);
  latestSummaryFile.writeAsStringSync(summaryText, flush: true);
  File(
    '${runDir.path}${Platform.pathSeparator}diff.md',
  ).writeAsStringSync(diffMd, flush: true);
  latestDiffFile.writeAsStringSync(diffMd, flush: true);

  EvalScorerAndReporter.writeFailedKeys(
    file: failedKeysFile,
    report: report,
    baselineJson: baselineJson,
  );

  stdout.writeln(diffMd);
  if (options.mode == EvalMode.corpusNoId ||
      options.mode == EvalMode.corpusAll) {
    final total = records.length;
    final autoCount = records.where((r) => r.matchLevel == 'autoBind').length;
    final reviewCount = records
        .where((r) => r.matchLevel == 'reviewRequired')
        .length;
    final unmatchedCount = total - autoCount - reviewCount;
    final pct = total == 0 ? 0.0 : autoCount * 100.0 / total;
    stdout.writeln(
      '\n## 全库绑定分布（${options.mode.name}，共 $total 部）\n'
      '- 自动绑定（autoBind）：`$autoCount / $total`（`${pct.toStringAsFixed(2)}%`）\n'
      '- 待复核（reviewRequired）：`$reviewCount` ｜ 未命中（unmatched）：`$unmatchedCount`',
    );
    final nonAuto = records.where((r) => r.matchLevel != 'autoBind').toList();
    if (nonAuto.isNotEmpty) {
      stdout.writeln('- 非自动绑定明细（最多展示 40 条）：');
      for (final r in nonAuto.take(40)) {
        stdout.writeln(
          '  - [${r.matchLevel}] `${r.folderKey}` | tmdb=${r.bestTmdbKey ?? 'none'} S${r.matchedSeason} | bgm=${r.bestBangumiId ?? 'none'}(${r.bangumiTier}) | reason=${r.primaryReason}',
        );
      }
    }
  }
  stdout.writeln('精简差异报告已写入：${latestDiffFile.path}');
  return 0;
}

int _runInitGolden({
  required _EvalCliOptions options,
  required List<GroupedWorkFolder> groups,
  required File goldenFile,
}) {
  if (goldenFile.existsSync() && !options.force) {
    stderr.writeln(
      '黄金集文件已存在：${goldenFile.path}（防止覆盖已人工核定的标注；如需重新抽样请附加 --force）。',
    );
    return 1;
  }
  final sample = GoldenSetSampler.buildStratifiedSample(
    groups: groups,
    targetRootCount: options.sampleSize,
  );
  GoldenSetCsvCodec.writeFile(goldenFile, sample);
  final bucketCounts = <String, int>{};
  for (final c in sample) {
    bucketCounts[c.bucket] = (bucketCounts[c.bucket] ?? 0) + 1;
  }
  stdout.writeln(
    '已按目录结构特征分层抽样生成 ${sample.length} 条黄金集用例：${goldenFile.path}',
  );
  stdout.writeln('各分桶分布：$bucketCounts');
  stdout.writeln('请使用 Excel 或 VS Code 打开核对并将已确认行的 verified 列改为 1。');
  return 0;
}

Future<List<EvalClusterRecord>> _evaluateOnlineBatch({
  required List<GroupedWorkFolder> targets,
  required int workers,
  required EvalArtworkMode artworkMode,
  required bool withExplicit,
  required bool messyFolders,
  required TmdbService tmdbService,
  required ScrapeCandidateFetcher fetcher,
  required ScrapeMatchResolver resolver,
  required ScrapeArtworkEnricher enricher,
  required BangumiTmdbIndex? mappingIndex,
}) async {
  final outputs = List<EvalClusterRecord?>.filled(targets.length, null);
  var nextIndex = 0;
  var completed = 0;
  EvalKeyRequiredException? keyRequired;
  final clock = Stopwatch()..start();

  Future<void> workerLoop() async {
    while (true) {
      if (keyRequired != null) return;
      if (nextIndex >= targets.length) return;
      final idx = nextIndex++;
      final folder = targets[idx];
      try {
        outputs[idx] = await _evaluateSingleOnline(
          folder: folder,
          index: idx,
          artworkMode: artworkMode,
          withExplicit: withExplicit,
          messyFolders: messyFolders,
          tmdbService: tmdbService,
          fetcher: fetcher,
          resolver: resolver,
          enricher: enricher,
          mappingIndex: mappingIndex,
        );
      } on EvalKeyRequiredException catch (e) {
        keyRequired ??= e;
        return;
      }
      completed++;
      if (completed % 25 == 0 || completed == targets.length) {
        stderr.writeln(
          '在线评测进度：$completed/${targets.length}，已耗时 ${clock.elapsed.inSeconds}s',
        );
      }
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) workerLoop()]);
  if (keyRequired != null) {
    throw keyRequired!;
  }
  return [for (final item in outputs) if (item != null) item];
}

const List<String> _messyFolderNames = [
  '新建文件夹 (3)',
  '2026年7月新番',
  'BDMV_1080p_x265_FLAC',
  '阿伟推荐的神作2 (2026)',
  '周末补番_硬盘A组',
  '【高清蓝光】我的动画收藏合集',
  'Downloads_042',
  '经典老番_未整理_2025',
  'SourceUnknown.MKV.1080p',
  '随便命名的测试目录',
];

/// 将单作目录的目录名与父级路径全部替换为不规范乱目录名，仅保留原始内部视频文件名用于档位 3 真实压力评测。
GroupedWorkFolder _buildMessyEvalFolder(GroupedWorkFolder folder, int index) {
  final root = _normalizePhysicalRoot(folder);
  var hash = 2166136261;
  for (final code in root.codeUnits) {
    hash ^= code;
    hash = (hash * 16777619) & 0x7fffffff;
  }
  final messyName = _messyFolderNames[hash % _messyFolderNames.length];
  final rootPrefix = '$root/';
  final entries = <({String path, int? size})>[];
  for (final v in folder.variants) {
    final norm = v.relativePath.replaceAll('\\', '/');
    final rel = norm.startsWith(rootPrefix)
        ? norm.substring(rootPrefix.length)
        : v.fileName;
    entries.add((path: rel, size: v.fileSize));
  }
  final messyPath = '乱目录测试/$messyName';
  final messyInv = DirectoryAnalyzer.analyze(messyPath, entries);
  final eps = messyInv.episodes.toList()..sort();
  return GroupedWorkFolder(
    folderRelativePath: messyPath,
    folderName: messyName,
    cleanTitle: messyInv.title,
    year: messyInv.year,
    seasonHint: messyInv.season,
    mainEpisodeNumbers: eps,
    isMovieHint: messyInv.folderMovieMarker || messyInv.fileMovieMarker,
    inventory: messyInv,
    titleHints: messyInv.titleHints,
    fileHints: messyInv.fileHints,
    variants: folder.variants,
  );
}

Future<EvalClusterRecord> _evaluateSingleOnline({
  required GroupedWorkFolder folder,
  required int index,
  required EvalArtworkMode artworkMode,
  required bool withExplicit,
  required bool messyFolders,
  required TmdbService tmdbService,
  required ScrapeCandidateFetcher fetcher,
  required ScrapeMatchResolver resolver,
  required ScrapeArtworkEnricher enricher,
  required BangumiTmdbIndex? mappingIndex,
}) async {
  final info = GoldenSetSampler.inspectFolder(folder);
  final physicalRoot = _normalizePhysicalRoot(folder);
  final evalFolder = messyFolders
      ? _buildMessyEvalFolder(folder, index)
      : (withExplicit ? folder : folder.withoutExplicitTmdb());
  final queries = ScrapeDomainAdapter.buildSearchQueries(evalFolder);

  TmdbWorkDetail? explicitDetail;
  if (withExplicit && evalFolder.explicitTmdbId != null) {
    explicitDetail = await fetcher.fetchExplicitDetail(evalFolder);
  }

  String matchLevel = 'unmatched';
  String? bestTmdbKey;
  String? bestTmdbTitle;
  int? bestTmdbYear;
  int? matchedSeason;
  int? bestBangumiId;
  String? bestBangumiTitle;
  String bangumiTier = 'none';
  String primaryReason = '';
  List<String> topSummary = const [];
  String wallChannel = 'block';
  int? tvdbId;
  String tvdbSource = 'missing';
  String logoSource = 'none';
  String logoLanguage = 'none';
  bool logoIsHd = false;
  String? logoPath;
  bool logoUpgradedByFanart = false;
  bool backdropSuboptimal = false;
  bool backdropUpgradedByFanart = false;
  bool posterNeedsFallback = false;
  bool posterFilledByFanart = false;
  bool fanartQueried = false;
  String? networkError;

  try {
    if (explicitDetail != null) {
      // 与生产 ScrapeOrchestrator 阶段 2 对齐：同步检索 Bangumi 并运行完整季级消歧与双源艺术图补全。
      final bgmCandidates = await fetcher.fetchBangumiCandidates(
        evalFolder,
        extraQueries: [explicitDetail.title, ...explicitDetail.aliases.take(2)],
      );
      final explicitDecision = ScrapeDomainAdapter.evaluateMatch(
        evalFolder,
        [explicitDetail],
        bangumiCandidates: bgmCandidates,
        mappingIndex: mappingIndex,
      );
      matchLevel = MatchLevel.autoBind.name;
      bestTmdbKey = '${explicitDetail.mediaType.name}:${explicitDetail.tmdbId}';
      bestTmdbTitle = explicitDetail.title;
      bestTmdbYear = explicitDetail.year;
      bestBangumiId = explicitDecision.bestBangumi?.subject.id;
      bestBangumiTitle = explicitDecision.bestBangumi?.subject.displayTitle;
      bangumiTier = explicitDecision.bestBangumi != null ? 'high' : 'none';
      matchedSeason =
          explicitDecision.matchedSeason ??
          evalFolder.seasonHint ??
          ScrapeDomainAdapter.fallbackResolveSeason(
            folder: evalFolder,
            detail: explicitDetail,
          );
      primaryReason = 'explicit_id';
      wallChannel = 'tmdb';
      if (artworkMode != EvalArtworkMode.off) {
        final hydrated =
            await tmdbService.getWorkDetail(
              explicitDetail.tmdbId,
              explicitDetail.mediaType,
              priority: RequestPriority.background,
              includeImages: true,
            ) ??
            explicitDetail;
        final enriched = await enricher.enrichTmdbDetail(
          detail: hydrated,
          seasonDetail: null,
          matchedSeason: matchedSeason,
          bangumiCandidate: explicitDecision.bestBangumi,
          priority: RequestPriority.background,
          upgradeNonZhCnLogo: artworkMode == EvalArtworkMode.full,
        );
        tvdbId = enriched.tvdbId;
        tvdbSource = _tvdbSourceName(enriched.tvdbIdSource);
        final chosenLogo = enriched.selectedLogo;
        if (chosenLogo != null) {
          logoSource = chosenLogo.source.name;
          logoLanguage = _logoLanguageBucket(
            chosenLogo.isoLanguage,
            chosenLogo.isoCountry,
          );
          logoIsHd = chosenLogo.isHd;
          logoPath = chosenLogo.filePath;
        }
        logoUpgradedByFanart = enriched.logoUpgradedByFanart;
        backdropSuboptimal = enriched.backdropSuboptimal;
        backdropUpgradedByFanart = enriched.backdropUpgradedByFanart;
        posterNeedsFallback = enriched.needsPosterFallback;
        posterFilledByFanart = enriched.posterFilledByFanart;
        fanartQueried = enriched.fanartQueried;
      }
    } else {
      final resolution = await resolver.resolve(evalFolder);
      final decision = resolution.decision;
      matchLevel = decision.level.name;
      bangumiTier = resolution.bangumiTier.name;
      primaryReason = decision.primaryReason;
      bestBangumiId = decision.bestBangumi?.subject.id;
      bestBangumiTitle = decision.bestBangumi?.subject.displayTitle;
      topSummary = [
        for (final c in decision.topCandidates.take(3))
          '${c.detail.mediaType.name}:${c.detail.tmdbId}:${c.score.round()}:${c.detail.title}',
      ];
      if (resolution.networkError != null) {
        networkError = NetworkErrorSanitizer.redactSecrets(
          resolution.networkError.toString(),
        );
      }

      if (decision.best != null) {
        final winner = decision.best!.detail;
        bestTmdbKey = '${winner.mediaType.name}:${winner.tmdbId}';
        bestTmdbTitle = winner.title;
        bestTmdbYear = winner.year;
        matchedSeason = decision.matchedSeason ?? decision.best!.matchedSeason;

        if (decision.level == MatchLevel.autoBind) {
          wallChannel = 'tmdb';
          if (artworkMode != EvalArtworkMode.off) {
            final hydrated =
                await tmdbService.getWorkDetail(
                  winner.tmdbId,
                  winner.mediaType,
                  priority: RequestPriority.background,
                  includeImages: true,
                ) ??
                winner;
            final enriched = await enricher.enrichTmdbDetail(
              detail: hydrated,
              seasonDetail: null,
              matchedSeason: matchedSeason,
              bangumiCandidate: decision.bestBangumi,
              priority: RequestPriority.background,
              upgradeNonZhCnLogo: artworkMode == EvalArtworkMode.full,
            );
            tvdbId = enriched.tvdbId;
            tvdbSource = _tvdbSourceName(enriched.tvdbIdSource);
            final chosenLogo = enriched.selectedLogo;
            if (chosenLogo != null) {
              logoSource = chosenLogo.source.name;
              logoLanguage = _logoLanguageBucket(
                chosenLogo.isoLanguage,
                chosenLogo.isoCountry,
              );
              logoIsHd = chosenLogo.isHd;
              logoPath = chosenLogo.filePath;
            }
            logoUpgradedByFanart = enriched.logoUpgradedByFanart;
            backdropSuboptimal = enriched.backdropSuboptimal;
            backdropUpgradedByFanart = enriched.backdropUpgradedByFanart;
            posterNeedsFallback = enriched.needsPosterFallback;
            posterFilledByFanart = enriched.posterFilledByFanart;
            fanartQueried = enriched.fanartQueried;
          }
        }
      } else {
        // 通路 B：无 TMDB 绑定但命中 Bangumi，按生产逻辑评估 Fanart 补图与独立上墙资格。
        final fallbackBgm =
            decision.bestBangumi ??
            (resolution.networkError != null ? resolution.bestBangumi : null);
        if (fallbackBgm != null) {
          bestBangumiId ??= fallbackBgm.subject.id;
          bestBangumiTitle ??= fallbackBgm.subject.displayTitle;
          final bgmWall = await enricher.evaluateBangumiOnly(
            folder: evalFolder,
            bangumiCandidate: fallbackBgm,
            bangumiTier: resolution.bangumiTier,
            priority: RequestPriority.background,
          );
          tvdbId = bgmWall.tvdbId;
          tvdbSource = _tvdbSourceName(bgmWall.tvdbIdSource);
          fanartQueried = bgmWall.fanartQueried;
          if (bgmWall.fanartTopLogo != null) {
            logoSource = LogoSourceKind.fanart.name;
            logoLanguage = _logoLanguageBucket(
              bgmWall.fanartTopLogo!.isoLanguage,
              bgmWall.fanartTopLogo!.isoCountry,
            );
            logoIsHd = bgmWall.fanartTopLogo!.isHd;
            logoPath = bgmWall.fanartTopLogo!.filePath;
          }
          if (bgmWall.canPromote ||
              (resolution.networkError == null &&
                  decision.level == MatchLevel.autoBind)) {
            wallChannel = 'bgm_only';
          }
        } else {
          // 通路 C / D：无 TMDB 与 Bangumi 主匹配，评估 Fanart / 本地目录封面兜底上墙。
          final coverWall = await enricher.evaluateCoverFallback(
            folder: evalFolder,
            priority: RequestPriority.background,
          );
          tvdbId = coverWall.tvdbId;
          tvdbSource = _tvdbSourceName(coverWall.tvdbIdSource);
          fanartQueried = coverWall.fanartQueried;
          if (coverWall.fanartTopLogo != null) {
            logoSource = LogoSourceKind.fanart.name;
            logoLanguage = _logoLanguageBucket(
              coverWall.fanartTopLogo!.isoLanguage,
              coverWall.fanartTopLogo!.isoCountry,
            );
            logoIsHd = coverWall.fanartTopLogo!.isHd;
            logoPath = coverWall.fanartTopLogo!.filePath;
          }
          if (coverWall.canPromote) {
            wallChannel = 'cover_fallback';
          }
        }
      }
    }
  } on EvalKeyRequiredException {
    rethrow;
  } catch (error) {
    networkError = NetworkErrorSanitizer.redactSecrets(error.toString());
  }

  return EvalClusterRecord(
    folderKey: folder.folderRelativePath,
    physicalRoot: physicalRoot,
    folderName: folder.folderName,
    cleanTitle: folder.cleanTitle,
    isSplitCluster: folder.isSplitCluster,
    isMovieHint: folder.isMovieHint,
    hasMainPlayable: info.hasMainPlayable,
    mainVideoCount: info.mainVideoCount,
    extraVideoCount: info.extraVideoCount,
    cdAssetCount: info.cdAssetCount,
    scanAssetCount: info.scanAssetCount,
    mainEpisodeNumbers: folder.mainEpisodeNumbers,
    suspectedExtraLeakPaths: info.suspectedLeaks,
    year: folder.year,
    seasonHint: folder.seasonHint,
    explicitTmdbId: folder.explicitTmdbId,
    explicitMediaType: folder.explicitMediaType?.name,
    localPosterPath: folder.localPosterPath,
    queries: queries,
    matchLevel: matchLevel,
    bestTmdbKey: bestTmdbKey,
    bestTmdbTitle: bestTmdbTitle,
    bestTmdbYear: bestTmdbYear,
    matchedSeason: matchedSeason,
    bestBangumiId: bestBangumiId,
    bestBangumiTitle: bestBangumiTitle,
    bangumiTier: bangumiTier,
    primaryReason: primaryReason,
    topTmdbSummary: topSummary,
    wallChannel: wallChannel,
    tvdbId: tvdbId,
    tvdbIdSource: tvdbSource,
    logoSource: logoSource,
    logoLanguage: logoLanguage,
    logoIsHd: logoIsHd,
    logoPath: logoPath,
    logoUpgradedByFanart: logoUpgradedByFanart,
    backdropSuboptimal: backdropSuboptimal,
    backdropUpgradedByFanart: backdropUpgradedByFanart,
    posterNeedsFallback: posterNeedsFallback,
    posterFilledByFanart: posterFilledByFanart,
    fanartQueried: fanartQueried,
    networkError: networkError,
  );
}

EvalClusterRecord _buildParseOnlyRecord(GroupedWorkFolder folder) {
  final info = GoldenSetSampler.inspectFolder(folder);
  return EvalClusterRecord(
    folderKey: folder.folderRelativePath,
    physicalRoot: _normalizePhysicalRoot(folder),
    folderName: folder.folderName,
    cleanTitle: folder.cleanTitle,
    isSplitCluster: folder.isSplitCluster,
    isMovieHint: folder.isMovieHint,
    hasMainPlayable: info.hasMainPlayable,
    mainVideoCount: info.mainVideoCount,
    extraVideoCount: info.extraVideoCount,
    cdAssetCount: info.cdAssetCount,
    scanAssetCount: info.scanAssetCount,
    mainEpisodeNumbers: folder.mainEpisodeNumbers,
    suspectedExtraLeakPaths: info.suspectedLeaks,
    year: folder.year,
    seasonHint: folder.seasonHint,
    explicitTmdbId: folder.explicitTmdbId,
    explicitMediaType: folder.explicitMediaType?.name,
    localPosterPath: folder.localPosterPath,
    queries: ScrapeDomainAdapter.buildSearchQueries(folder),
    matchLevel: 'parse_only',
    wallChannel: info.hasMainPlayable ? 'parse_playable' : 'block',
  );
}

EvalVcrHttpClient _createVcrClient({
  required Directory cacheDir,
  required _EvalCliOptions options,
  required TmdbNetworkConfig netConfig,
  required bool fanartRelayAllowed,
}) {
  final io = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 4)
    ..maxConnectionsPerHost = 12;
  io.findProxy = (uri) {
    if (netConfig.proxyMode == ProxyMode.none) return 'DIRECT';
    if (netConfig.proxyMode == ProxyMode.custom &&
        netConfig.proxyUrl.trim().isNotEmpty) {
      final raw = netConfig.proxyUrl.trim();
      final normalized = raw.contains('://') ? raw : 'http://$raw';
      final parsed = Uri.tryParse(normalized);
      if (parsed != null && parsed.host.isNotEmpty && parsed.hasPort) {
        final scheme = parsed.scheme.toLowerCase();
        if (scheme == 'socks' || scheme == 'socks5') {
          return 'SOCKS5 ${parsed.host}:${parsed.port}; DIRECT';
        }
        return 'PROXY ${parsed.host}:${parsed.port}';
      }
    }
    return HttpClient.findProxyFromEnvironment(
      uri,
      environment: Platform.environment,
    );
  };
  return EvalVcrHttpClient(
    inner: IOClient(io),
    cacheDir: cacheDir,
    refreshPolicy: options.refreshPolicy,
    offlineOnly: options.offlineOnly,
    offlineSoft: options.offlineSoft,
    allowFanartRelay: fanartRelayAllowed,
  );
}

/// 优先载入更新的本地热更新映射表（含 v2 `tvdbId`），否则回退仓库内置二进制快照。
({BangumiTmdbIndex? index, String description}) _loadActiveMappingIndex() {
  BangumiTmdbIndex? tryLoad(File file) {
    if (!file.existsSync()) return null;
    try {
      final bytes = file.readAsBytesSync();
      final idx = BangumiTmdbIndex.fromBytes(bytes);
      return idx.isNotEmpty ? idx : null;
    } catch (_) {
      return null;
    }
  }

  final localIdx = tryLoad(File('userdata/bangumi_tmdb_map.bin'));
  final bundledIdx = tryLoad(File(TmdbNetworkConfig.bundledMappingAssetPath));
  BangumiTmdbIndex? chosen;
  String sourceLabel = '静态回退表';

  if (localIdx != null && bundledIdx != null) {
    final localNewer =
        localIdx.snapshotDateYyyymmdd > bundledIdx.snapshotDateYyyymmdd ||
        (localIdx.snapshotDateYyyymmdd == bundledIdx.snapshotDateYyyymmdd &&
            (localIdx.version > bundledIdx.version ||
                (localIdx.version == bundledIdx.version &&
                    localIdx.recordCount >= bundledIdx.recordCount)));
    chosen = localNewer ? localIdx : bundledIdx;
    sourceLabel = localNewer ? 'userdata 热更新' : 'assets 内置快照';
  } else if (localIdx != null) {
    chosen = localIdx;
    sourceLabel = 'userdata 热更新';
  } else if (bundledIdx != null) {
    chosen = bundledIdx;
    sourceLabel = 'assets 内置快照';
  }

  if (chosen == null) {
    return (index: null, description: '静态 Wikidata 兜底表（无 tvdbId）');
  }
  final tvdbFlag = chosen.supportsTvdbId ? '含 tvdbId' : 'v1 无 tvdbId';
  return (
    index: chosen,
    description:
        '$sourceLabel v${chosen.version} (${chosen.formattedSnapshotDate}, '
        '${chosen.uniqueBangumiCount} 条, $tvdbFlag)',
  );
}

List<GoldenCase> _loadGoldenCasesIfNeeded({
  required EvalMode mode,
  required File goldenFile,
}) {
  if (!goldenFile.existsSync()) return const [];
  if (mode == EvalMode.golden ||
      mode == EvalMode.onlyFailed ||
      mode == EvalMode.parseOnly) {
    return GoldenSetCsvCodec.readFile(goldenFile);
  }
  return const [];
}

Set<String>? _computePrefilterPhysicalRoots({
  required EvalMode mode,
  required File manifestFile,
  required List<GoldenCase> goldenCases,
  required File failedKeysFile,
  required List<String> onlyFilters,
}) {
  if (mode == EvalMode.golden) {
    final roots = <String>{
      for (final c in goldenCases)
        if (c.physicalRoot.trim().isNotEmpty) c.physicalRoot.trim(),
    };
    if (onlyFilters.isEmpty) return roots;
    return {
      for (final r in roots)
        if (onlyFilters.any((f) => r.toLowerCase().contains(f))) r,
    };
  }
  if (mode == EvalMode.onlyFailed && onlyFilters.isEmpty) {
    final failedJson = _tryReadJsonMap(failedKeysFile);
    final rawKeys = <String>{
      for (final key in ((failedJson?['failed_folder_keys'] as List?) ?? const []))
        key.toString(),
      for (final key in ((failedJson?['recently_fixed_keys'] as List?) ?? const []))
        key.toString(),
    };
    final roots = <String>{};
    for (final raw in rawKeys) {
      final sep = raw.indexOf('::');
      final root = (sep > 0 ? raw.substring(0, sep) : raw).trim();
      if (root.isNotEmpty) roots.add(root);
    }
    return roots;
  }
  // 无 ID 全量摸底或指定 --only 过滤时，直接按清单行秒级预筛目标目录，避免全量解析 30 万文件耗时 2 分钟。
  if (mode == EvalMode.corpusNoId || onlyFilters.isNotEmpty) {
    final tmdbMarker = RegExp(r'[\[{（(]\s*tmdb', caseSensitive: false);
    final auxSegment = RegExp(
      r'^(sps?|extras?|bonus|cds?|ost|music|soundtrack|scans?|bk|booklet|'
      r'menus?|nc|ncop|nced|pv|cm|op|ed|fonts?|subs?|subtitles?|scripts?|'
      r'artwork|images?|pics?|videos?|bd|dvd|disc\s*\d*|vol\.?\s*\d*|'
      r'cd\s*\d*|season\s*\d+|s\d+|ova|oad|specials?|movies?|preview|'
      r'trailer|teaser|tokuten|特典|扫图|原声|音乐|字幕|菜单|花絮|剧场版)$',
      caseSensitive: false,
    );
    final splitCue = RegExp(
      r'(?:movie|剧场版|劇場版|前[编編]|后[编編]|後[编編]|zenpen|kouhen|'
      r'の巻|之巻|第[一二三1-3]章|film|超电影版)',
      caseSensitive: false,
    );
    final videoExt = RegExp(
      r'\.(?:mkv|mp4|avi|m2ts|ts|flv|wmv|mov|webm|m4v)$',
      caseSensitive: false,
    );
    final roots = <String>{};
    for (final rawLine in manifestFile.readAsLinesSync()) {
      final tab = rawLine.indexOf('\t');
      final path = (tab > 0 ? rawLine.substring(0, tab) : rawLine)
          .replaceAll('\\', '/')
          .trim();
      if (path.isEmpty) continue;
      if (onlyFilters.isNotEmpty) {
        final lower = path.toLowerCase();
        if (!onlyFilters.any(lower.contains)) continue;
      }
      final parts = path.split('/');
      if (parts.length < 2) continue;
      final parentParts = parts.sublist(0, parts.length - 1);
      final fileName = parts.last;
      if (mode == EvalMode.corpusNoId) {
        var tmdbIdx = -1;
        for (var i = 0; i < parentParts.length; i++) {
          if (tmdbMarker.hasMatch(parentParts[i])) {
            tmdbIdx = i;
            break;
          }
        }
        if (tmdbIdx < 0) {
          roots.add(parentParts.join('/'));
        } else {
          final tmdbRoot = parentParts.sublist(0, tmdbIdx + 1).join('/');
          if (tmdbIdx == parentParts.length - 1) {
            if (videoExt.hasMatch(fileName) && splitCue.hasMatch(fileName)) {
              roots.add(tmdbRoot);
            }
          } else {
            final nextSeg = parentParts[tmdbIdx + 1];
            if (!auxSegment.hasMatch(nextSeg) && videoExt.hasMatch(fileName)) {
              roots.add(parentParts.sublist(0, tmdbIdx + 2).join('/'));
            }
          }
        }
      } else {
        roots.add(parentParts.join('/'));
      }
    }
    return roots;
  }
  return null;
}

List<GroupedWorkFolder> _selectTargetGroups({
  required EvalMode mode,
  required List<GroupedWorkFolder> groups,
  required List<GoldenCase> goldenCases,
  required File failedKeysFile,
  required List<String> onlyFilters,
  bool messyFolders = false,
}) {
  Iterable<GroupedWorkFolder> selected = groups;
  if (mode == EvalMode.golden) {
    final allowedRoots = {for (final c in goldenCases) c.physicalRoot};
    selected = groups.where(
      (g) => allowedRoots.contains(_normalizePhysicalRoot(g)),
    );
  } else if (mode == EvalMode.onlyFailed) {
    final failedData = _tryReadJsonMap(failedKeysFile);
    final allowedRoots = <String>{
      if (failedData?['failedPhysicalRoots'] is List)
        for (final item in failedData!['failedPhysicalRoots'] as List)
          item.toString(),
      if (failedData?['recentlyFixedRoots'] is List)
        for (final item in failedData!['recentlyFixedRoots'] as List)
          item.toString(),
    };
    selected = groups.where(
      (g) => allowedRoots.contains(_normalizePhysicalRoot(g)),
    );
  } else if (mode == EvalMode.corpusNoId) {
    selected = groups.where(
      (g) =>
          g.explicitTmdbId == null &&
          WorkWallEligibility.hasMainPlayableContent(g),
    );
  }

  if (messyFolders) {
    selected = selected.where(
      (g) =>
          !g.isSplitCluster &&
          WorkWallEligibility.hasMainPlayableContent(g) &&
          (g.inventory?.fileHints.isNotEmpty ?? g.fileHints.isNotEmpty),
    );
  }

  if (onlyFilters.isNotEmpty) {
    selected = selected.where((g) {
      final relLower = g.folderRelativePath.toLowerCase();
      final rootLower = _normalizePhysicalRoot(g).toLowerCase();
      return onlyFilters.any(
        (f) => relLower.contains(f) || rootLower.contains(f),
      );
    });
  }
  return selected.toList(growable: false);
}

List<GoldenCase> _filterGoldenCasesForTargets({
  required EvalMode mode,
  required List<GoldenCase> goldenCases,
  required List<GroupedWorkFolder> targets,
  bool messyFolders = false,
}) {
  if (goldenCases.isEmpty) return const [];
  final targetRoots = {for (final g in targets) _normalizePhysicalRoot(g)};
  return [
    for (final c in goldenCases)
      if (targetRoots.contains(c.physicalRoot) &&
          (!messyFolders || c.clusterHint == '*'))
        c,
  ];
}

String _normalizePhysicalRoot(GroupedWorkFolder g) {
  final raw = (g.physicalRootFolder ?? g.folderRelativePath)
      .trim()
      .replaceAll('\\', '/');
  final idx = raw.indexOf('::');
  return idx > 0 ? raw.substring(0, idx) : raw;
}

String _tvdbSourceName(TvdbIdSource source) => switch (source) {
  TvdbIdSource.tmdbExternalIds => 'tmdb_external_ids',
  TvdbIdSource.offlineMappingV2 => 'offline_map_v2',
  TvdbIdSource.missing => 'missing',
};

String _logoLanguageBucket(String? isoLanguage, String? isoCountry) {
  return switch (ClearLogoRanker.languageRank(isoLanguage, isoCountry)) {
    0 => 'zh_cn',
    1 => 'zh_tw',
    2 => 'ja',
    3 => 'en',
    4 => 'neutral',
    _ => 'other',
  };
}

Map<String, Object?>? _tryReadJsonMap(File file) {
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
  } catch (_) {}
  return null;
}

String _formatRunId(DateTime now, EvalMode mode) {
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${now.year}${p2(now.month)}${p2(now.day)}_'
      '${p2(now.hour)}${p2(now.minute)}${p2(now.second)}_${mode.name}';
}

/// 命令行参数强类型封装。
class _EvalCliOptions {
  const _EvalCliOptions({
    required this.mode,
    required this.evalDir,
    this.manifestPath,
    this.goldenPath,
    required this.artworkRaw,
    required this.sourceKind,
    required this.refreshPolicy,
    required this.allowFanartRelay,
    required this.offlineOnly,
    required this.offlineSoft,
    required this.withExplicit,
    required this.messyFolders,
    required this.onlyFilters,
    required this.workers,
    required this.sampleSize,
    required this.force,
    required this.proxyUrl,
    required this.noProxy,
    required this.showHelp,
  });

  final EvalMode mode;
  final String evalDir;
  final String? manifestPath;
  final String? goldenPath;
  final String artworkRaw;
  final EvalSourceKind sourceKind;
  final EvalCacheRefreshPolicy refreshPolicy;
  final bool allowFanartRelay;
  final bool offlineOnly;
  final bool offlineSoft;
  final bool withExplicit;
  final bool messyFolders;
  final List<String> onlyFilters;
  final int workers;
  final int sampleSize;
  final bool force;
  final String proxyUrl;
  final bool noProxy;
  final bool showHelp;

  EvalArtworkMode get effectiveArtworkMode {
    switch (artworkRaw) {
      case 'off':
        return EvalArtworkMode.off;
      case 'batch':
        return EvalArtworkMode.batch;
      case 'full':
        return EvalArtworkMode.full;
      default:
        return switch (mode) {
          EvalMode.parseOnly ||
          EvalMode.initGolden ||
          EvalMode.corpusNoId ||
          EvalMode.corpusAll ||
          EvalMode.acceptBaseline => EvalArtworkMode.off,
          EvalMode.golden || EvalMode.onlyFailed => EvalArtworkMode.full,
        };
    }
  }

  static _EvalCliOptions parse(List<String> args) {
    var mode = EvalMode.golden;
    var evalDir = 'local_eval';
    String? manifestPath;
    String? goldenPath;
    var artworkRaw = 'auto';
    var sourceKind = EvalSourceKind.webdav;
    var refreshPolicy = EvalCacheRefreshPolicy.none;
    var allowFanartRelay = false;
    var offlineOnly = false;
    var offlineSoft = false;
    var withExplicit = false;
    var messyFolders = false;
    var onlyFilters = <String>[];
    var workers = 8;
    var sampleSize = 180;
    var force = false;
    var proxyUrl = '';
    var noProxy = false;
    var showHelp = false;

    for (final raw in args) {
      if (raw == '-h' || raw == '--help') {
        showHelp = true;
      } else if (raw == '--parse-only') {
        mode = EvalMode.parseOnly;
      } else if (raw == '--init-golden') {
        mode = EvalMode.initGolden;
      } else if (raw == '--golden') {
        mode = EvalMode.golden;
      } else if (raw == '--only-failed') {
        mode = EvalMode.onlyFailed;
      } else if (raw == '--corpus-no-id') {
        mode = EvalMode.corpusNoId;
      } else if (raw == '--corpus-all') {
        mode = EvalMode.corpusAll;
      } else if (raw == '--accept-baseline') {
        mode = EvalMode.acceptBaseline;
      } else if (raw.startsWith('--mode=')) {
        mode = _parseMode(raw.substring(7));
      } else if (raw.startsWith('--eval-dir=')) {
        evalDir = raw.substring(11);
      } else if (raw.startsWith('--manifest=')) {
        manifestPath = raw.substring(11);
      } else if (raw.startsWith('--golden-file=')) {
        goldenPath = raw.substring(14);
      } else if (raw.startsWith('--artwork=')) {
        artworkRaw = raw.substring(10).trim().toLowerCase();
      } else if (raw.startsWith('--source-kind=')) {
        final v = raw.substring(14).trim().toLowerCase();
        sourceKind = v == 'local'
            ? EvalSourceKind.local
            : EvalSourceKind.webdav;
      } else if (raw.startsWith('--refresh-cache=')) {
        refreshPolicy = _parseRefreshPolicy(raw.substring(16));
      } else if (raw == '--refresh-cache') {
        refreshPolicy = EvalCacheRefreshPolicy.all;
      } else if (raw == '--allow-fanart-relay') {
        allowFanartRelay = true;
      } else if (raw == '--offline') {
        offlineOnly = true;
      } else if (raw == '--offline-soft') {
        offlineOnly = true;
        offlineSoft = true;
      } else if (raw == '--with-explicit') {
        withExplicit = true;
      } else if (raw == '--messy-folders') {
        messyFolders = true;
      } else if (raw.startsWith('--only=')) {
        onlyFilters = raw
            .substring(7)
            .split(RegExp(r'[|,]'))
            .map((e) => e.trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      } else if (raw.startsWith('--workers=')) {
        workers = int.tryParse(raw.substring(10)) ?? 8;
      } else if (raw.startsWith('--sample-size=')) {
        sampleSize = int.tryParse(raw.substring(14)) ?? 180;
      } else if (raw == '--force') {
        force = true;
      } else if (raw.startsWith('--proxy=')) {
        proxyUrl = raw.substring(8).trim();
      } else if (raw == '--no-proxy') {
        noProxy = true;
      } else {
        throw FormatException('无法识别的命令行参数：$raw');
      }
    }

    return _EvalCliOptions(
      mode: mode,
      evalDir: evalDir,
      manifestPath: manifestPath,
      goldenPath: goldenPath,
      artworkRaw: artworkRaw,
      sourceKind: sourceKind,
      refreshPolicy: refreshPolicy,
      allowFanartRelay: allowFanartRelay,
      offlineOnly: offlineOnly,
      offlineSoft: offlineSoft,
      withExplicit: withExplicit,
      messyFolders: messyFolders,
      onlyFilters: onlyFilters,
      workers: workers,
      sampleSize: sampleSize,
      force: force,
      proxyUrl: proxyUrl,
      noProxy: noProxy,
      showHelp: showHelp,
    );
  }

  static EvalMode _parseMode(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'parse-only' || 'parseonly' => EvalMode.parseOnly,
      'init-golden' || 'initgolden' => EvalMode.initGolden,
      'golden' => EvalMode.golden,
      'only-failed' || 'onlyfailed' => EvalMode.onlyFailed,
      'corpus-no-id' || 'corpusnoid' => EvalMode.corpusNoId,
      'corpus-all' || 'corpusall' => EvalMode.corpusAll,
      'accept-baseline' || 'acceptbaseline' => EvalMode.acceptBaseline,
      _ => throw FormatException('不支持的运行模式：$raw'),
    };
  }

  static EvalCacheRefreshPolicy _parseRefreshPolicy(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'none' || '' => EvalCacheRefreshPolicy.none,
      'all' => EvalCacheRefreshPolicy.all,
      '404' || 'notfound' => EvalCacheRefreshPolicy.notFound,
      'tmdb' => EvalCacheRefreshPolicy.tmdb,
      'bgm' || 'bangumi' => EvalCacheRefreshPolicy.bgm,
      'fanart' => EvalCacheRefreshPolicy.fanart,
      _ => throw FormatException('不支持的缓存刷新策略：$raw'),
    };
  }
}

void _printUsage() {
  stdout.writeln(
    '用法：dart run tool/eval_scraper.dart [选项]\n'
    '  --parse-only                  零网络快速解析、拆簇与噪音过滤并输出差异\n'
    '  --init-golden [--sample-size=180] [--force] 分层抽样生成黄金集 CSV\n'
    '  --golden                      高频回归黄金集（默认 --artwork=full）\n'
    '  --only-failed                 仅重跑错题本与最近修复样本\n'
    '  --accept-baseline             将最近一次评测汇总锁定为对比基线\n'
    '  --artwork=auto|off|batch|full 控制 TMDB 图集与 Fanart.tv 整包协同评测档位\n'
    '  --source-kind=webdav|local    控制是否启用本地目录 poster/cover/folder 探测\n'
    '  --refresh-cache=none|all|404|tmdb|bgm|fanart 指定 VCR 缓存刷新策略\n'
    '  --allow-fanart-relay          无 FANART_API_KEY 时允许低速(1 req/s)走内置中继\n'
    '  --offline                     纯离线回放模式（不触网）\n'
    '  --with-explicit               保留目录已有 {tmdb-N}（默认盲测剥离显式 ID）\n'
    '  --only=<A|B>                  仅评测路径包含指定子串的作品\n'
    '  --workers=<1..12>             在线并发度上限（默认 8，受分域限流保护）\n'
    '  --proxy=<url> / --no-proxy    显式覆盖或禁用代理',
  );
}
