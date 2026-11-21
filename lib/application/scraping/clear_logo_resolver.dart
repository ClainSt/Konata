import 'dart:developer' as developer;

import '../../domain/models/fanart_models.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/bangumi_tmdb_index.dart';
import '../../domain/scraping/work_wall_eligibility.dart';
import '../../infrastructure/network/fanart_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_service.dart';
import 'scrape_artwork_enricher.dart';

/// 单次多源透明徽标与艺术图联合解析结果。
class ClearLogoResolveOutcome {
  /// 创建解析结果。
  const ClearLogoResolveOutcome({
    this.logoPath,
    this.upgradedBackdropPath,
    this.fallbackPosterPath,
    this.resolvedTvdbId,
    this.negativeUntil,
    this.negativeMask = 0,
    this.didProbeOnline = false,
  });

  /// 命中的最优透明徽标路径（TMDB 相对路径或 Fanart.tv HTTPS 地址；未命中为 `null`）。
  final String? logoPath;

  /// 当 TMDB 背景图缺失、低清（`<1920px`）或带文字时，从同次 Fanart 整包挑选的无字 `1080p` 横图。
  final String? upgradedBackdropPath;

  /// 当作品缺失封面时，从同次 Fanart 整包挑选的竖版封面（匹配季优先）。
  final String? fallbackPosterPath;

  /// 解析并可顺带回写的 TheTVDB ID。
  final int? resolvedTvdbId;

  /// 未命中或瞬态失败时写入作品的负缓存冷却截止时间。
  final DateTime? negativeUntil;

  /// 记录本次覆盖的能力源及联合择优位掩码。
  final int negativeMask;

  /// 本次是否实际发起了在线网络探测。
  final bool didProbeOnline;
}

/// 跨源透明徽标（ClearLogo）在途去重协调器（由 Riverpod 托管，避免同作品/同系列并发重复探测）。
class ClearLogoInFlightRegistry {
  final Map<String, Future<ClearLogoResolveOutcome>> _inFlight = {};

  /// 按共享媒体标识键合并并发在途探测。
  Future<ClearLogoResolveOutcome> deduplicate(
    String key,
    Future<ClearLogoResolveOutcome> Function() task,
  ) {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = task().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// 清空全部在途索引。
  void clear() {
    _inFlight.clear();
  }
}

/// 多源透明标题徽标与整包艺术图协同协调器（Stage 0 人工锁定 -> TMDB + Fanart.tv 跨源排序 + 分层负缓存）。
///
/// 职责边界：
/// - 统一复用 [ClearLogoRanker] 合并排序 TMDB 与 Fanart.tv 候选（确保 Fanart 高清日文/中文胜过 TMDB 英文）；
/// - 共享 [FanartArtworkCache] 整包结果，在单次请求内同时完成透明徽标、无字 1080p 背景图升级与缺失封面补齐；
/// - 结合 Single-Flight 去重与分层负缓存（含 `multiSourceUpgraded` 位）彻底消灭重复无效请求。
class ClearLogoResolver {
  /// 创建透明徽标协调器。
  ClearLogoResolver({
    required TmdbService tmdbService,
    required FanartService fanartService,
    required TmdbNetworkConfig networkConfig,
    this._mappingIndex,
    ClearLogoInFlightRegistry? inFlightRegistry,
    DateTime Function()? nowProvider,
  }) : _tmdb = tmdbService,
       _fanart = fanartService,
       _config = networkConfig,
       _inFlight = inFlightRegistry ?? ClearLogoInFlightRegistry(),
       _now = nowProvider ?? DateTime.now;

  final TmdbService _tmdb;
  final FanartService _fanart;
  final TmdbNetworkConfig _config;
  final BangumiTmdbIndex? _mappingIndex;
  final ClearLogoInFlightRegistry _inFlight;
  final DateTime Function() _now;

  /// 当年新番确定无图时的负缓存冷却时长（社区常在播映期内陆续补传徽标）。
  static const Duration recentAnimeNegativeCooldown = Duration(days: 3);

  /// 往年老番确定无图时的负缓存冷却时长。
  static const Duration archiveAnimeNegativeCooldown = Duration(days: 30);

  /// 网络瞬态异常（超时/5xx/429）时的短冷却时长，避免偶发断网长期锁死。
  static const Duration transientErrorCooldown = Duration(minutes: 30);

  /// 计算当前网络配置具备的在线探测能力位掩码。
  static int capabilityMaskForConfig(TmdbNetworkConfig config) {
    var mask = ClearLogoNegativeMask.none;
    if (config.credential.trim().isNotEmpty) {
      mask |= ClearLogoNegativeMask.tmdb;
    }
    if (config.isFanartAvailable) {
      mask |= ClearLogoNegativeMask.fanart;
      if (config.hasFanartClientKey) {
        mask |= ClearLogoNegativeMask.fanartWithClientKey;
      }
    }
    return mask;
  }

  /// 将 TMDB 透明徽标候选列表转换为统一排序模型并剔除已知误挂条目。
  static List<RankedLogoCandidate> toRankedTmdbLogos(
    List<TmdbArtworkImage> tmdbLogos, {
    int? tmdbId,
    TmdbMediaType? mediaType,
  }) {
    if (tmdbLogos.isEmpty) return const [];
    final mistagged =
        (mediaType == TmdbMediaType.tv && tmdbId != null)
        ? TmdbService.tmdbMistaggedTvLogoTargets[tmdbId]
        : null;
    final out = <RankedLogoCandidate>[];
    for (final item in tmdbLogos) {
      final path = item.filePath.trim();
      if (path.isEmpty) continue;
      if (mistagged != null && mistagged.containsKey(path)) continue;
      out.add(
        RankedLogoCandidate(
          filePath: path,
          source: LogoSourceKind.tmdb,
          isoLanguage: item.isoLanguage,
          isoCountry: item.isoCountry,
          isHd: ClearLogoRanker.isTmdbLogoHd(item.width),
          width: item.width,
          height: item.height,
          voteAverage: item.voteAverage ?? 0.0,
          voteCount: item.voteCount ?? 0,
        ),
      );
    }
    return ClearLogoRanker.sortMerged(out);
  }

  /// 将 Fanart.tv 透明徽标候选列表转换为统一排序模型。
  static List<RankedLogoCandidate> toRankedFanartLogos(
    List<FanartLogoCandidate> fanartLogos,
  ) {
    if (fanartLogos.isEmpty) return const [];
    return [
      for (final item in fanartLogos)
        RankedLogoCandidate(
          filePath: item.url.trim(),
          source: LogoSourceKind.fanart,
          isoLanguage: item.lang,
          isHd: item.kind.isHd,
          likes: item.likes,
        ),
    ];
  }

  /// 跨源合并 TMDB 与 Fanart.tv 透明徽标并按语言权重、高清档位与热度统一排序。
  static List<RankedLogoCandidate> mergeAndRankLogos({
    required List<TmdbArtworkImage> tmdbLogos,
    required List<FanartLogoCandidate> fanartLogos,
    int? tmdbId,
    TmdbMediaType? mediaType,
  }) {
    final combined = <RankedLogoCandidate>[
      ...toRankedTmdbLogos(
        tmdbLogos,
        tmdbId: tmdbId,
        mediaType: mediaType,
      ),
      ...toRankedFanartLogos(fanartLogos),
    ];
    return ClearLogoRanker.sortMerged(combined);
  }

  /// 判断作品当前是否应当触发详情页按需透明徽标补全或一次性多源联合择优升级。
  static bool shouldAttemptDetailLogoBackfill({
    required Work work,
    required TmdbNetworkConfig config,
    DateTime? now,
  }) {
    if (work.logoLocked) return false;
    final hasAnyId =
        work.tmdbId != null || work.tvdbId != null || work.bangumiId != null;
    if (!hasAnyId) return false;

    final capability = capabilityMaskForConfig(config);
    if (capability == ClearLogoNegativeMask.none) return false;

    final current = now ?? DateTime.now();
    final existingLogo = work.logoPath?.trim() ?? '';
    if (existingLogo.isNotEmpty) {
      // 已有非锁定 TMDB 徽标时，若尚未经过 TMDB + Fanart 联合择优且 Fanart 可用，仅执行一次静默升级检查。
      if (!existingLogo.startsWith('/')) return false;
      if (!config.isFanartAvailable) return false;
      final alreadyUpgraded =
          (work.logoNegativeMask & ClearLogoNegativeMask.multiSourceUpgraded) !=
          0;
      if (alreadyUpgraded) {
        final needsClientKeyCheck =
            config.hasFanartClientKey &&
            (work.logoNegativeMask &
                    ClearLogoNegativeMask.fanartWithClientKey) ==
                0;
        if (!needsClientKeyCheck) return false;
      }
      final negativeUntil = work.logoNegativeUntil;
      if (negativeUntil != null && current.isBefore(negativeUntil)) {
        return (capability & ~work.logoNegativeMask) != 0;
      }
      return true;
    }

    final negativeUntil = work.logoNegativeUntil;
    if (negativeUntil != null && current.isBefore(negativeUntil)) {
      // 若用户新增了更强能力源（例如新填了 Fanart 个人 Key 或自定义 Key），立刻破冰补查。
      final hasUncoveredCapability =
          (capability & ~work.logoNegativeMask) != 0;
      return hasUncoveredCapability;
    }
    return true;
  }

  /// 根据作品发行年份计算确定无图后的分层冷却截止时间。
  static DateTime computeDefinitiveCooldownUntil({
    required int? workYear,
    required DateTime now,
  }) {
    final isRecent = workYear != null && workYear >= now.year - 1;
    return now.add(
      isRecent ? recentAnimeNegativeCooldown : archiveAnimeNegativeCooldown,
    );
  }

  /// 对单部作品执行去重后的多源透明徽标、无字背景与封面整包协同解析（TMDB + Fanart.tv）。
  Future<ClearLogoResolveOutcome> resolveForWork(
    Work work, {
    bool forceRefresh = false,
    bool skipTmdb = false,
    bool skipTmdbIfAlreadyChecked = true,
    bool allowUpgradeExisting = false,
    bool upgradeBackdropIfSuboptimal = false,
    bool fillPosterIfMissing = false,
    TmdbWorkDetail? preloadedTmdbDetail,
    RequestPriority priority = RequestPriority.background,
  }) async {
    final existingLogo = work.logoPath?.trim() ?? '';
    final needsLogo =
        !work.logoLocked &&
        (existingLogo.isEmpty ||
            forceRefresh ||
            (allowUpgradeExisting && existingLogo.startsWith('/')));
    final needsBackdrop = upgradeBackdropIfSuboptimal && !work.backdropLocked;
    final needsPoster =
        fillPosterIfMissing &&
        !work.posterLocked &&
        (work.posterPath == null || work.posterPath!.trim().isEmpty);

    if (!needsLogo && !needsBackdrop && !needsPoster) {
      return ClearLogoResolveOutcome(
        logoPath: work.logoPath,
        resolvedTvdbId: work.tvdbId,
      );
    }

    final dedupeKey = _dedupeKeyFor(work, forceRefresh: forceRefresh);
    return _inFlight.deduplicate(dedupeKey, () async {
      final now = _now();
      var resolvedTvdbId = work.tvdbId ?? _lookupOfflineTvdbId(work);
      var probedMask = work.logoNegativeMask;
      var tmdbDetail = preloadedTmdbDetail;
      if (tmdbDetail != null) {
        resolvedTvdbId ??= tmdbDetail.tvdbId;
        probedMask |= ClearLogoNegativeMask.tmdb;
      } else if (skipTmdb) {
        probedMask |= ClearLogoNegativeMask.tmdb;
      }
      var hadTransientError = false;
      var didProbeOnline = false;

      final canProbeTmdb =
          tmdbDetail == null &&
          !skipTmdb &&
          work.tmdbId != null &&
          work.tmdbMediaType != null &&
          _config.credential.trim().isNotEmpty;
      final tmdbAlreadyChecked =
          skipTmdbIfAlreadyChecked &&
          !forceRefresh &&
          (work.logoNegativeMask & ClearLogoNegativeMask.tmdb) != 0 &&
          work.logoNegativeUntil != null &&
          now.isBefore(work.logoNegativeUntil!);

      // Stage 1: TMDB /images + external_ids（单次往返同时拿到候选徽标、背景尺寸语言与 tvdbId）
      final needTmdbForDecision =
          !tmdbAlreadyChecked ||
          resolvedTvdbId == null ||
          needsBackdrop ||
          (allowUpgradeExisting && existingLogo.startsWith('/'));
      if (canProbeTmdb && needTmdbForDecision) {
        didProbeOnline = true;
        try {
          final detail = await _tmdb.getWorkDetail(
            work.tmdbId!,
            work.tmdbMediaType!,
            priority: priority,
            includeImages: true,
          );
          if (detail != null) {
            tmdbDetail = detail;
            resolvedTvdbId ??= detail.tvdbId;
            probedMask |= ClearLogoNegativeMask.tmdb;
          }
        } catch (error) {
          hadTransientError = true;
          developer.log(
            '补全 TMDB 透明徽标遇到瞬态异常',
            name: 'konata.clear_logo_resolver',
            error: error,
          );
        }
      }

      final tmdbRanked = tmdbDetail != null
          ? toRankedTmdbLogos(
              tmdbDetail.candidateLogos,
              tmdbId: work.tmdbId,
              mediaType: work.tmdbMediaType,
            )
          : const <RankedLogoCandidate>[];
      // 若 TMDB 仅返回基础 logoPath 而无 candidateLogos 明细，按单条候选补录。
      final effectiveTmdbRanked =
          tmdbRanked.isNotEmpty ||
              tmdbDetail?.logoPath == null ||
              tmdbDetail!.logoPath!.trim().isEmpty
          ? tmdbRanked
          : <RankedLogoCandidate>[
              RankedLogoCandidate(
                filePath: tmdbDetail.logoPath!.trim(),
                source: LogoSourceKind.tmdb,
                isHd: true,
              ),
            ];
      final hasTopZhCnTmdbLogo =
          effectiveTmdbRanked.isNotEmpty &&
          ClearLogoRanker.languageRank(
                effectiveTmdbRanked.first.isoLanguage,
                effectiveTmdbRanked.first.isoCountry,
              ) ==
              0 &&
          effectiveTmdbRanked.first.isHd;

      final backdropSuboptimal =
          needsBackdrop &&
          WorkWallEligibility.isTmdbBackdropSuboptimal(
            selectedBackdropPath: tmdbDetail?.backdropPath ?? work.backdropPath,
            candidateBackdrops: tmdbDetail?.candidateBackdrops ?? const [],
          );

      // Stage 2: Fanart.tv 整包请求（当 TMDB 缺失/非简中高清徽标，或背景需升级/缺封面时触发，命中缓存零额外往返）
      final effectiveMediaType =
          work.tmdbMediaType ??
          (resolvedTvdbId != null ? TmdbMediaType.tv : null);
      final canProbeFanart =
          _fanart.isConfigured &&
          effectiveMediaType != null &&
          (effectiveMediaType == TmdbMediaType.movie
              ? work.tmdbId != null
              : resolvedTvdbId != null);
      final shouldProbeFanart =
          canProbeFanart &&
          ((needsLogo && !hasTopZhCnTmdbLogo) ||
              backdropSuboptimal ||
              needsPoster);

      FanartArtworkResult? fanartRes;
      var fanartCheckedCleanly = false;
      if (shouldProbeFanart) {
        didProbeOnline = true;
        try {
          fanartRes = await _fanart.fetchArtworkBundle(
            mediaType: effectiveMediaType,
            tmdbId: work.tmdbId,
            tvdbId: resolvedTvdbId,
            priority: priority,
            bypassCircuitBreaker: forceRefresh,
            forceRefresh: forceRefresh,
          );
          if (fanartRes.authRejected) {
            hadTransientError = true;
          } else {
            fanartCheckedCleanly = true;
            probedMask |= ClearLogoNegativeMask.fanart;
            if (_config.hasFanartClientKey) {
              probedMask |= ClearLogoNegativeMask.fanartWithClientKey;
            }
          }
        } catch (error) {
          hadTransientError = true;
          developer.log(
            '补全 Fanart.tv 整包艺术图遇到瞬态异常',
            name: 'konata.clear_logo_resolver',
            error: error,
          );
        }
      }

      // 跨源联合排序决出最终最优透明徽标
      String? resolvedLogo;
      if (needsLogo) {
        final merged = ClearLogoRanker.sortMerged([
          ...effectiveTmdbRanked,
          ...toRankedFanartLogos(fanartRes?.logos ?? const []),
        ]);
        if (existingLogo.isEmpty) {
          resolvedLogo = merged.isEmpty ? null : merged.first.filePath;
        } else if (tmdbDetail != null) {
          resolvedLogo = merged.isEmpty ? existingLogo : merged.first.filePath;
        } else if (forceRefresh && fanartRes?.bestLogoUrl != null) {
          resolvedLogo = fanartRes!.bestLogoUrl;
        } else {
          resolvedLogo = existingLogo;
        }
      } else {
        resolvedLogo = work.logoPath;
      }

      final String? upgradedBackdropPath =
          (backdropSuboptimal && fanartRes?.bestBackgroundUrl != null)
          ? fanartRes!.bestBackgroundUrl
          : null;
      final String? fallbackPosterPath =
          (needsPoster && fanartRes != null)
          ? fanartRes.bestPosterUrlForSeason(work.matchedSeason)
          : null;

      if (resolvedLogo != null && resolvedLogo.trim().isNotEmpty) {
        final cleanLogo = resolvedLogo.trim();
        if (cleanLogo.startsWith('/')) {
          if (hasTopZhCnTmdbLogo || fanartCheckedCleanly) {
            return ClearLogoResolveOutcome(
              logoPath: cleanLogo,
              upgradedBackdropPath: upgradedBackdropPath,
              fallbackPosterPath: fallbackPosterPath,
              resolvedTvdbId: resolvedTvdbId,
              negativeUntil: null,
              negativeMask:
                  probedMask | ClearLogoNegativeMask.multiSourceUpgraded,
              didProbeOnline: didProbeOnline,
            );
          }
          if (hadTransientError) {
            return ClearLogoResolveOutcome(
              logoPath: cleanLogo,
              upgradedBackdropPath: upgradedBackdropPath,
              fallbackPosterPath: fallbackPosterPath,
              resolvedTvdbId: resolvedTvdbId,
              negativeUntil: now.add(transientErrorCooldown),
              negativeMask: probedMask,
              didProbeOnline: didProbeOnline,
            );
          }
          return ClearLogoResolveOutcome(
            logoPath: cleanLogo,
            upgradedBackdropPath: upgradedBackdropPath,
            fallbackPosterPath: fallbackPosterPath,
            resolvedTvdbId: resolvedTvdbId,
            negativeUntil: null,
            negativeMask: probedMask,
            didProbeOnline: didProbeOnline,
          );
        }
        return ClearLogoResolveOutcome(
          logoPath: cleanLogo,
          upgradedBackdropPath: upgradedBackdropPath,
          fallbackPosterPath: fallbackPosterPath,
          resolvedTvdbId: resolvedTvdbId,
          negativeUntil: null,
          negativeMask: 0,
          didProbeOnline: didProbeOnline,
        );
      }

      final nextCooldown = hadTransientError
          ? now.add(transientErrorCooldown)
          : computeDefinitiveCooldownUntil(workYear: work.year, now: now);
      return ClearLogoResolveOutcome(
        logoPath: null,
        upgradedBackdropPath: upgradedBackdropPath,
        fallbackPosterPath: fallbackPosterPath,
        resolvedTvdbId: resolvedTvdbId,
        negativeUntil: didProbeOnline ? nextCooldown : work.logoNegativeUntil,
        negativeMask: didProbeOnline ? probedMask : work.logoNegativeMask,
        didProbeOnline: didProbeOnline,
      );
    });
  }

  int? _lookupOfflineTvdbId(Work work) =>
      ScrapeArtworkEnricher.lookupOfflineTvdbId(
        mappingIndex: _mappingIndex,
        bangumiId: work.bangumiId,
        tmdbId: work.tmdbId,
        mediaType: work.tmdbMediaType,
      );

  String _dedupeKeyFor(Work work, {required bool forceRefresh}) {
    final suffix = forceRefresh ? ':force' : '';
    if (work.tmdbId != null && work.tmdbMediaType != null) {
      return 'logo:${work.tmdbMediaType!.name}:${work.tmdbId}:'
          '${_config.hasFanartClientKey ? 1 : 0}:${_config.hasCustomFanartApiKey ? 1 : 0}$suffix';
    }
    if (work.tvdbId != null) {
      return 'logo:tvdb:${work.tvdbId}:${_config.hasFanartClientKey ? 1 : 0}$suffix';
    }
    return 'logo:work:${work.id}$suffix';
  }
}
