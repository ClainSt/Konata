import 'dart:developer' as developer;

import '../../domain/models/fanart_models.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/work.dart';
import '../../domain/scraping/bangumi_tmdb_index.dart';
import '../../infrastructure/network/fanart_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_service.dart';

/// 单次多源透明徽标解析结果。
class ClearLogoResolveOutcome {
  /// 创建解析结果。
  const ClearLogoResolveOutcome({
    this.logoPath,
    this.resolvedTvdbId,
    this.negativeUntil,
    this.negativeMask = 0,
    this.didProbeOnline = false,
  });

  /// 命中的透明徽标路径（TMDB 相对路径或 Fanart.tv HTTPS 地址；未命中为 `null`）。
  final String? logoPath;

  /// 解析并可顺带回写的 TheTVDB ID。
  final int? resolvedTvdbId;

  /// 未命中时写入作品的负缓存冷却截止时间。
  final DateTime? negativeUntil;

  /// 未命中时记录本次覆盖的能力源位掩码。
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

/// 三级透明标题徽标漏斗协调器（Stage 0 人工锁定 -> Stage 1 TMDB -> Stage 2 Fanart.tv + 分层负缓存）。
///
/// 职责边界：
/// - 批量扫描阶段仅走 TMDB（零额外往返），避免大库扫盘制造 Fanart.tv 请求风暴；
/// - 详情页打开缺图作品时按需懒补全，结合 Single-Flight 去重与分层负缓存彻底消灭重复无效请求。
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

  /// 判断作品当前是否应当触发详情页按需透明徽标懒补全。
  static bool shouldAttemptDetailLogoBackfill({
    required Work work,
    required TmdbNetworkConfig config,
    DateTime? now,
  }) {
    if (work.logoLocked) return false;
    if (work.logoPath != null && work.logoPath!.trim().isNotEmpty) return false;
    final hasAnyId =
        work.tmdbId != null || work.tvdbId != null || work.bangumiId != null;
    if (!hasAnyId) return false;

    final capability = capabilityMaskForConfig(config);
    if (capability == ClearLogoNegativeMask.none) return false;

    final current = now ?? DateTime.now();
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

  /// 对单部缺失徽标的作品执行去重后的多源懒补全（TMDB -> Fanart.tv）。
  Future<ClearLogoResolveOutcome> resolveForWork(
    Work work, {
    bool forceRefresh = false,
    bool skipTmdb = false,
    bool skipTmdbIfAlreadyChecked = true,
    RequestPriority priority = RequestPriority.background,
  }) async {
    if (!forceRefresh && work.logoLocked) {
      return ClearLogoResolveOutcome(
        logoPath: work.logoPath,
        resolvedTvdbId: work.tvdbId,
      );
    }
    if (!forceRefresh &&
        work.logoPath != null &&
        work.logoPath!.trim().isNotEmpty) {
      return ClearLogoResolveOutcome(
        logoPath: work.logoPath,
        resolvedTvdbId: work.tvdbId,
      );
    }

    final dedupeKey = _dedupeKeyFor(work);
    return _inFlight.deduplicate(dedupeKey, () async {
      final now = _now();
      var resolvedTvdbId = work.tvdbId ?? _lookupOfflineTvdbId(work);
      var probedMask = work.logoNegativeMask;
      if (skipTmdb) {
        probedMask |= ClearLogoNegativeMask.tmdb;
      }
      var hadTransientError = false;
      var didProbeOnline = false;

      final canProbeTmdb =
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

      // Stage 1: TMDB /images + external_ids（单次往返同时补齐 logoPath 与 tvdbId）
      if (canProbeTmdb && (!tmdbAlreadyChecked || resolvedTvdbId == null)) {
        didProbeOnline = true;
        try {
          final detail = await _tmdb.getWorkDetail(
            work.tmdbId!,
            work.tmdbMediaType!,
            priority: priority,
            includeImages: true,
          );
          if (detail != null) {
            resolvedTvdbId ??= detail.tvdbId;
            probedMask |= ClearLogoNegativeMask.tmdb;
            if (detail.logoPath != null && detail.logoPath!.trim().isNotEmpty) {
              return ClearLogoResolveOutcome(
                logoPath: detail.logoPath!.trim(),
                resolvedTvdbId: resolvedTvdbId,
                negativeUntil: null,
                negativeMask: 0,
                didProbeOnline: true,
              );
            }
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

      // Stage 2: Fanart.tv v3（仅 TMDB 未命中时触发；Movie 用 tmdbId，TV 用 tvdbId）
      final effectiveMediaType =
          work.tmdbMediaType ??
          (resolvedTvdbId != null ? TmdbMediaType.tv : null);
      final canProbeFanart =
          _fanart.isConfigured &&
          effectiveMediaType != null &&
          (effectiveMediaType == TmdbMediaType.movie
              ? work.tmdbId != null
              : resolvedTvdbId != null);

      if (canProbeFanart) {
        didProbeOnline = true;
        try {
          final fanartRes = await _fanart.fetchLogos(
            mediaType: effectiveMediaType,
            tmdbId: work.tmdbId,
            tvdbId: resolvedTvdbId,
            priority: priority,
            bypassCircuitBreaker: forceRefresh,
          );
          if (fanartRes.bestLogoUrl != null) {
            return ClearLogoResolveOutcome(
              logoPath: fanartRes.bestLogoUrl,
              resolvedTvdbId: resolvedTvdbId,
              negativeUntil: null,
              negativeMask: 0,
              didProbeOnline: true,
            );
          }
          if (fanartRes.authRejected) {
            hadTransientError = true;
          } else {
            probedMask |= ClearLogoNegativeMask.fanart;
            if (_config.hasFanartClientKey) {
              probedMask |= ClearLogoNegativeMask.fanartWithClientKey;
            }
          }
        } catch (error) {
          hadTransientError = true;
          developer.log(
            '补全 Fanart.tv 透明徽标遇到瞬态异常',
            name: 'konata.clear_logo_resolver',
            error: error,
          );
        }
      }

      final nextCooldown = hadTransientError
          ? now.add(transientErrorCooldown)
          : computeDefinitiveCooldownUntil(workYear: work.year, now: now);
      return ClearLogoResolveOutcome(
        logoPath: null,
        resolvedTvdbId: resolvedTvdbId,
        negativeUntil: didProbeOnline ? nextCooldown : work.logoNegativeUntil,
        negativeMask: didProbeOnline ? probedMask : work.logoNegativeMask,
        didProbeOnline: didProbeOnline,
      );
    });
  }

  int? _lookupOfflineTvdbId(Work work) {
    final index = _mappingIndex;
    if (index == null || index.isEmpty) return null;
    if (work.bangumiId != null && work.bangumiId! > 0) {
      for (final target in index.lookup(work.bangumiId!)) {
        if (target.tvdbId != null && target.tvdbId! > 0) {
          if (work.tmdbId == null || target.id == work.tmdbId) {
            return target.tvdbId;
          }
        }
      }
    }
    if (work.tmdbId != null && work.tmdbMediaType == TmdbMediaType.tv) {
      return index.lookupTvdbIdByTmdb(
        mediaType: TmdbMediaType.tv,
        tmdbId: work.tmdbId!,
      );
    }
    return null;
  }

  String _dedupeKeyFor(Work work) {
    if (work.tmdbId != null && work.tmdbMediaType != null) {
      return 'logo:${work.tmdbMediaType!.name}:${work.tmdbId}:'
          '${_config.hasFanartClientKey ? 1 : 0}:${_config.hasCustomFanartApiKey ? 1 : 0}';
    }
    if (work.tvdbId != null) {
      return 'logo:tvdb:${work.tvdbId}:${_config.hasFanartClientKey ? 1 : 0}';
    }
    return 'logo:work:${work.id}';
  }
}
