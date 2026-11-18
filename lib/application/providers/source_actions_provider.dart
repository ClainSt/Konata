import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/network_config.dart';
import '../../domain/models/tmdb_models.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../../domain/scraping/bangumi_models.dart';
import '../../domain/sources/source_location_validator.dart';
import '../../infrastructure/network/bangumi_service.dart';
import '../../infrastructure/network/priority_http_scheduler.dart';
import '../../infrastructure/network/tmdb_http_client.dart';
import '../../infrastructure/network/tmdb_service.dart';
import '../../infrastructure/sources/source_credential_store.dart';
import '../../infrastructure/sources/source_gateway_factory.dart';
import 'library_providers.dart';
import 'scraping_providers.dart';

/// 面向 UI 的领域操作协调器（隔离媒体源、TMDB 搜索、网络设置、外部播放器与目录操作）。
class KonataActionsCoordinator {
  /// 创建操作协调器。
  const KonataActionsCoordinator(this._ref);

  final Ref _ref;

  /// 保存或更新媒体源元数据及安全密码凭据（若名称留空则自动派生默认名称）。
  Future<void> saveMediaSource({
    required MediaSource source,
    String? password,
    bool clearPassword = false,
  }) async {
    final validated = SourceLocationValidator.validate(
      source.kind,
      source.location,
    );
    if (!validated.isValid) {
      throw ArgumentError(validated.errorMessage ?? '媒体源地址格式无效');
    }
    final normalizedLabel = source.label.trim().isEmpty
        ? deriveDefaultSourceLabel(source.kind, validated.normalizedLocation)
        : source.label.trim();
    final effectiveSource = source.copyWith(
      label: normalizedLabel,
      location: validated.normalizedLocation,
    );
    final repo = _ref.read(libraryRepositoryProvider);
    await repo.upsertMediaSource(effectiveSource);
    if (effectiveSource.kind != MediaSourceKind.local) {
      if (clearPassword) {
        await const SourceCredentialStore().deletePassword(effectiveSource.id);
      } else if (password != null && password.isNotEmpty) {
        await const SourceCredentialStore().savePassword(
          effectiveSource.id,
          password,
        );
      }
    }
    _ref.invalidate(mediaSourcesProvider);
  }

  /// 删除媒体源及对应安全凭据。
  Future<void> deleteMediaSource(String sourceId) async {
    final repo = _ref.read(libraryRepositoryProvider);
    await repo.deleteMediaSource(sourceId);
    await const SourceCredentialStore().deletePassword(sourceId);
    _ref.invalidate(mediaSourcesProvider);
  }

  /// 浏览指定媒体源的子目录列表（支持本地 / WebDAV / SMB，仅返回子文件夹与常规条目）。
  Future<List<RemoteEntry>> listSourceDirectory(
    MediaSource source,
    String relativePath,
  ) async {
    final gateway = await const MediaSourceGatewayFactory().create(source);
    try {
      return await gateway.listDirectory(relativePath);
    } finally {
      await gateway.close();
    }
  }

  /// 测试媒体源连通性（成功返回 `null`，失败返回中文原因）。
  Future<String?> testMediaSourceConnection(
    MediaSource source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async {
    final validated = SourceLocationValidator.validate(
      source.kind,
      source.location,
    );
    if (!validated.isValid) {
      return validated.errorMessage ?? '媒体源地址格式无效';
    }
    final effectiveSource = source.copyWith(
      location: validated.normalizedLocation,
    );
    final gateway = await const MediaSourceGatewayFactory().create(
      effectiveSource,
      passwordOverride: passwordOverride,
      clearPassword: clearPassword,
    );
    try {
      return await gateway.testConnection();
    } finally {
      await gateway.close();
    }
  }

  /// 前台高优先级搜索 TMDB 候选（供手动纠错弹窗使用；未配置密钥时立即抛出明确中文指引）。
  Future<List<TmdbSearchResult>> searchTmdbInteractive(
    String query, {
    int? year,
  }) async {
    final config = await _ref.read(tmdbNetworkConfigProvider.future);
    if (config.credential.trim().isEmpty) {
      throw StateError('尚未配置 TMDB API 密钥，请先前往「设置 -> 刮削与网络」填写密钥');
    }
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    final tmdb = TmdbService(httpClient: client);
    try {
      return await tmdb.searchAnime(
        query,
        year: year,
        priority: RequestPriority.interactive,
      );
    } finally {
      client.close();
    }
  }

  /// 前台高优先级渐进搜索 Bangumi 动画条目（自动净化连字符并多级回退合并去重）。
  Future<List<BangumiSubjectCandidate>> searchBangumiInteractive(
    String query,
  ) async {
    final config = await _ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    final bgm = BangumiService(httpClient: client);
    try {
      return await bgm.searchSubjectsProgressive(
        query,
        priority: RequestPriority.interactive,
      );
    } finally {
      client.close();
    }
  }

  /// 前台获取 Bangumi 条目详情（含完整简介与实时评分）。
  Future<BangumiSubjectCandidate?> getBangumiSubjectDetailInteractive(
    int subjectId,
  ) async {
    final config = await _ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    final bgm = BangumiService(httpClient: client);
    try {
      return await bgm.getSubjectDetail(
        subjectId,
        priority: RequestPriority.interactive,
      );
    } finally {
      client.close();
    }
  }

  /// 前台获取 TMDB 条目详情与分季列表（用于混合绑定选择母系列与 Season 0/N）。
  Future<TmdbWorkDetail?> getTmdbWorkDetailInteractive(
    int tmdbId,
    TmdbMediaType mediaType,
  ) async {
    final config = await _ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    final tmdb = TmdbService(httpClient: client);
    try {
      return await tmdb.getWorkDetail(
        tmdbId,
        mediaType,
        priority: RequestPriority.interactive,
        includeEnglishImages: true,
      );
    } finally {
      client.close();
    }
  }

  /// 前台获取 TMDB 指定季的分集列表（含 Season 0 特别篇剧照与标题）。
  Future<TmdbSeasonDetail?> getTmdbSeasonDetailInteractive(
    int tmdbId,
    int seasonNumber,
  ) async {
    final config = await _ref.read(tmdbNetworkConfigProvider.future);
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    final tmdb = TmdbService(httpClient: client);
    try {
      return await tmdb.getSeasonDetail(
        tmdbId,
        seasonNumber,
        priority: RequestPriority.interactive,
      );
    } finally {
      client.close();
    }
  }

  /// 保存网络与凭证配置并重置域名冷却状态，立即刷新生效。
  Future<void> saveNetworkConfig(TmdbNetworkConfig config) async {
    await _ref.read(networkConfigRepositoryProvider).save(config);
    DomainCooldownRegistry.shared.clearAll();
    _ref.invalidate(tmdbNetworkConfigProvider);
  }

  /// 测试 TMDB API 连通性（官方优先，受阻自动探测备用地址）。
  Future<ConnectivityReport> testTmdbConnectivity(TmdbNetworkConfig config) =>
      testTmdbApiConnectivity(config);

  /// 测试 TMDB API 连通性（官方优先，受阻自动探测备用地址）。
  Future<ConnectivityReport> testTmdbApiConnectivity(
    TmdbNetworkConfig config,
  ) async {
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    try {
      return await client.testTmdbApiConnectivity();
    } finally {
      client.close();
    }
  }

  /// 测试 TMDB 图片服务器连通性（官方优先，受阻自动探测备用地址）。
  Future<ConnectivityReport> testTmdbImageConnectivity(
    TmdbNetworkConfig config,
  ) async {
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    try {
      return await client.testTmdbImageConnectivity();
    } finally {
      client.close();
    }
  }

  /// 测试 Bangumi API 连通性（官方优先，受阻自动探测社区镜像）。
  Future<ConnectivityReport> testBangumiApiConnectivity(
    TmdbNetworkConfig config,
  ) async {
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    try {
      return await client.testBangumiApiConnectivity();
    } finally {
      client.close();
    }
  }

  /// 测试 Bangumi 图片服务器连通性（官方优先，受阻自动探测备用图片地址）。
  Future<ConnectivityReport> testBangumiImageConnectivity(
    TmdbNetworkConfig config,
  ) async {
    final scheduler = _ref.read(priorityHttpSchedulerProvider);
    final client = TmdbHttpClient(config: config, scheduler: scheduler);
    try {
      return await client.testBangumiImageConnectivity();
    } finally {
      client.close();
    }
  }

  /// 保存单个外部播放器配置。
  Future<void> saveExternalPlayer(ExternalPlayerConfig config) =>
      saveExternalPlayers([config]);

  /// 批量保存外部播放器与查看器配置并合并触发一次列表刷新。
  Future<void> saveExternalPlayers(
    Iterable<ExternalPlayerConfig> configs,
  ) async {
    final repo = _ref.read(libraryRepositoryProvider);
    for (final config in configs) {
      await repo.upsertExternalPlayer(config);
    }
    _ref.invalidate(externalPlayersProvider);
  }

  /// 调整单集的季/集/分类信息（用于剧集卡片右键微调纠错，自动持久化映射锁定）。
  Future<void> updateEpisodeSlot({
    required Episode episode,
    required int seasonNumber,
    required int episodeNumber,
    required EpisodeCategory category,
    ExtraKind? extraType,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    await repo.upsertEpisode(
      Episode(
        id: episode.id,
        workId: episode.workId,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        category: category,
        extraType: category == EpisodeCategory.extra ? extraType : null,
        title: episode.title,
        overview: episode.overview,
        stillPath: episode.stillPath,
      ),
    );
    final variants = await repo.getVariantsByWork(episode.workId);
    for (final variant in variants) {
      if (variant.episodeId == episode.id && !variant.mappingLocked) {
        await repo.upsertMediaVariant(variant.copyWith(mappingLocked: true));
      }
    }
    final work = await repo.findWorkById(episode.workId);
    if (work != null && !work.isManualLocked) {
      await repo.upsertWork(work.copyWith(isManualLocked: true));
    }
    _ref.invalidate(workDetailBundleProvider(episode.workId));
  }

  /// 打开本地媒体文件所在的 Windows 资源管理器目录。
  Future<bool> openLocalContainingFolder({
    required MediaSource source,
    required String relativePath,
  }) async {
    if (source.kind != MediaSourceKind.local) return false;
    final fullPath = p.joinAll([source.location, ...relativePath.split('/')]);
    final dirPath = Directory(p.dirname(fullPath)).path;
    if (!await Directory(dirPath).exists()) return false;
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [dirPath]);
      return true;
    }
    return false;
  }
}

/// 领域操作协调器 Provider。
final konataActionsProvider = Provider<KonataActionsCoordinator>((ref) {
  return KonataActionsCoordinator(ref);
});
