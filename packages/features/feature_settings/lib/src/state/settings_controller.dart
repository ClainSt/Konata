import 'dart:async';
import 'dart:convert';

import 'package:engine_scraping/engine_scraping.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/photos_cleanup_scanner.dart';
import '../data/settings_display_prefs.dart';
import '../data/settings_network_repository.dart';
import '../data/settings_prefs.dart';

/// 连通性探测目标标识常量。
abstract final class NetworkProbeTargets {
  /// TMDB 官方及备用 API 接口。
  static const String tmdbApi = 'tmdb_api';

  /// TMDB 官方及备用图片节点。
  static const String tmdbImage = 'tmdb_image';

  /// Bangumi 官方及备用 API 接口。
  static const String bangumiApi = 'bangumi_api';

  /// Bangumi 官方及备用封面图片节点。
  static const String bangumiImage = 'bangumi_image';

  /// Fanart 接口节点。
  static const String fanartApi = 'fanart_api';

  /// Fanart 图片节点。
  static const String fanartImage = 'fanart_image';
}

/// 可选外部网络连通探测回调（供宿主覆盖或单元测试模拟）。
typedef NetworkConnectivityProbe =
    Future<ConnectivityReport> Function(String targetId);

/// 通用设置控制器（状态层严格保持零 Riverpod）。
///
/// 统筹外观与主题持久化、详情展示偏好持久化、网络与元数据凭据存取、
/// 离线动画映射表检查、图片占用统计清理、脱敏诊断日志导出与外链打开。
final class SettingsController extends ChangeNotifier {
  /// 创建通用设置控制器。
  SettingsController({
    required KonataDatabaseBundle databases,
    required ScopedPrefsStore scopedPrefs,
    required SecureStoragePort secureStorage,
    required this._httpClient,
    required PhotosStorage photosStorage,
    required this._backupFilePort,
    required this._urlOpener,
    required this._diagnosticLog,
    this._appVersion = '3.0.0',
    this._onThemeModeChanged,
    this._onAmbientBackdropChanged,
    this._onWindowMaterialChanged,
    this._onNetworkConfigChanged,
    this._connectivityProbeOverride,
    StorageRootPort? storageRoot,
    Future<Uint8List?> Function(String assetPath)? bundledMappingAssetLoader,
  }) : _appearanceRepo = SettingsAppearanceRepository(scopedPrefs),
       _displayRepo = SettingsDisplayRepository(scopedPrefs),
       _networkRepo = SettingsNetworkRepository(
         scopedPrefs: scopedPrefs,
         secureStorage: secureStorage,
       ),
       _photosScanner = PhotosCleanupScanner(
         photosStorage: photosStorage,
         workDao: databases.library.works,
       ),
       _mappingUpdater = BangumiTmdbMapUpdater(
         storageRoot: storageRoot ?? const PortableStorageRootService(),
         prefsStore: scopedPrefs,
         bundledAssetLoader: bundledMappingAssetLoader,
       ) {
    _appearance = _appearanceRepo.read();
    _displayPrefs = _displayRepo.read();
    _networkConfig = _httpClient.config;
    _appearanceSub = _appearanceRepo.watch().listen((next) {
      _appearance = next;
      _safeNotify();
    });
    _displaySub = _displayRepo.watch().listen((next) {
      _displayPrefs = next;
      _safeNotify();
    });
    unawaited(initialize());
  }

  final KonataHttpClientPort _httpClient;
  final BackupFilePort _backupFilePort;
  final UrlOpenerPort _urlOpener;
  final DiagnosticLogPort _diagnosticLog;
  final String _appVersion;
  final ValueChanged<ThemeMode>? _onThemeModeChanged;
  final ValueChanged<bool>? _onAmbientBackdropChanged;
  final ValueChanged<KonataWindowMaterial>? _onWindowMaterialChanged;
  final ValueChanged<KonataNetworkConfig>? _onNetworkConfigChanged;
  final NetworkConnectivityProbe? _connectivityProbeOverride;

  final SettingsAppearanceRepository _appearanceRepo;
  final SettingsDisplayRepository _displayRepo;
  final SettingsNetworkRepository _networkRepo;
  final PhotosCleanupScanner _photosScanner;
  final BangumiTmdbMapUpdater _mappingUpdater;

  StreamSubscription<SettingsAppearancePrefs>? _appearanceSub;
  StreamSubscription<SettingsDisplayPrefs>? _displaySub;
  bool _disposed = false;

  late SettingsAppearancePrefs _appearance;
  late SettingsDisplayPrefs _displayPrefs;
  late KonataNetworkConfig _networkConfig;
  bool _isLoadingNetwork = true;
  bool _isSavingNetwork = false;
  bool _isScanningPhotos = false;
  bool _isExportingDiagnostics = false;
  bool _isUpdatingMapping = false;
  String? _photosRootPath;
  PhotosCleanupSnapshot? _photosSnapshot;
  BangumiTmdbSnapshot? _mappingSnapshot;
  BangumiTmdbUpdateResult? _mappingUpdateResult;
  final Map<String, ConnectivityReport> _probeReports =
      <String, ConnectivityReport>{};
  final Set<String> _probingTargets = <String>{};

  /// 应用当前展示版本号。
  String get appVersion => _appVersion;

  /// 当前主题外观配置。
  SettingsAppearancePrefs get appearance => _appearance;

  /// 当前详情展示偏好配置。
  SettingsDisplayPrefs get displayPrefs => _displayPrefs;

  /// 当前生效的主题模式。
  ThemeMode get themeMode => _appearance.themeMode;

  /// 当前是否开启柔和流光背景。
  bool get ambientBackdropEnabled => _appearance.ambientBackdropEnabled;

  /// 当前 Windows 桌面原生 DWM 窗口材质。
  KonataWindowMaterial get windowMaterial => _appearance.windowMaterial;

  /// 当前加载的网络与元数据配置。
  KonataNetworkConfig get networkConfig => _networkConfig;

  /// 是否正在读取安全凭据存储中的网络配置。
  bool get isLoadingNetwork => _isLoadingNetwork;

  /// 是否正在保存网络配置。
  bool get isSavingNetwork => _isSavingNetwork;

  /// 是否正在扫描图片缓存目录。
  bool get isScanningPhotos => _isScanningPhotos;

  /// 是否正在生成并导出脱敏诊断日志。
  bool get isExportingDiagnostics => _isExportingDiagnostics;

  /// 是否正在检查离线动画映射表增量更新。
  bool get isUpdatingMapping => _isUpdatingMapping;

  /// 最近解析到的本地图片存储根目录路径。
  String? get photosRootPath => _photosRootPath;

  /// 最近一次图片磁盘占用扫描快照。
  PhotosCleanupSnapshot? get photosSnapshot => _photosSnapshot;

  /// 当前已加载的离线动画映射表快照。
  BangumiTmdbSnapshot? get mappingSnapshot => _mappingSnapshot;

  /// 最近一次离线映射表检查更新结果。
  BangumiTmdbUpdateResult? get mappingUpdateResult => _mappingUpdateResult;

  /// 各个探测目标的最新连通性测速报告。
  Map<String, ConnectivityReport> get probeReports =>
      Map<String, ConnectivityReport>.unmodifiable(_probeReports);

  /// 判定指定节点是否正在测速。
  bool isProbingTarget(String targetId) => _probingTargets.contains(targetId);

  /// 诊断日志详细模式是否已开启。
  bool get verboseDiagnosticsEnabled => _diagnosticLog.verboseEnabled;

  /// 当前诊断日志统计计数。
  DiagnosticSummaryCounts get diagnosticCounts => _diagnosticLog.summaryCounts;

  /// 当前诊断故障摘要条目列表。
  List<DiagnosticFaultSummary> get diagnosticFaults =>
      _diagnosticLog.summarizeFaults();

  /// 初始化异步状态：载入安全凭据区、映射表快照与本地图片统计。
  Future<void> initialize() async {
    await loadNetworkConfig();
    await loadMappingSnapshot();
    await refreshPhotosStorage();
  }

  /// 切换并持久化主题模式，同时通知宿主壳层更新。
  void setThemeMode(ThemeMode next) {
    if (_appearance.themeMode == next) {
      return;
    }
    _appearance = _appearance.copyWith(themeMode: next);
    _appearanceRepo.save(_appearance);
    _onThemeModeChanged?.call(next);
    _safeNotify();
  }

  /// 切换并持久化柔和流光背景开关，同时通知宿主壳层更新。
  void setAmbientBackdropEnabled(bool enabled) {
    if (_appearance.ambientBackdropEnabled == enabled) {
      return;
    }
    _appearance = _appearance.copyWith(ambientBackdropEnabled: enabled);
    _appearanceRepo.save(_appearance);
    _onAmbientBackdropChanged?.call(enabled);
    _safeNotify();
  }

  /// 切换并持久化 Windows 桌面原生窗口材质，同时通知宿主 DWM 控制器生效。
  void setWindowMaterial(KonataWindowMaterial next) {
    if (_appearance.windowMaterial == next) {
      return;
    }
    _appearance = _appearance.copyWith(windowMaterial: next);
    _appearanceRepo.save(_appearance);
    _onWindowMaterialChanged?.call(next);
    _safeNotify();
  }

  /// 切换详情页文字标题显示。
  void setShowTitleText(bool enabled) => _updateDisplayPrefs(
    (current) => current.copyWith(showTitleText: enabled),
  );

  /// 切换详情页透明标题徽标显示。
  void setShowTitleLogo(bool enabled) => _updateDisplayPrefs(
    (current) => current.copyWith(showTitleLogo: enabled),
  );

  /// 切换详情页作品简介显示。
  void setShowOverview(bool enabled) => _updateDisplayPrefs(
    (current) => current.copyWith(showOverview: enabled),
  );

  /// 切换选集与特典卡片原始视频文件名显示。
  void setShowRawVideoFilename(bool enabled) => _updateDisplayPrefs(
    (current) => current.copyWith(showRawVideoFilename: enabled),
  );

  /// 切换详情页「CD」分类页签显示。
  void setShowCdTab(bool enabled) => _updateDisplayPrefs(
    (current) => current.copyWith(showCdTab: enabled),
  );

  /// 切换详情页「Scan」分类页签显示。
  void setShowScanTab(bool enabled) => _updateDisplayPrefs(
    (current) => current.copyWith(showScanTab: enabled),
  );

  void _updateDisplayPrefs(
    SettingsDisplayPrefs Function(SettingsDisplayPrefs current) transform,
  ) {
    _displayPrefs = _displayRepo.update(transform);
    _safeNotify();
  }

  /// 重新加载安全凭据与非敏感网络配置。
  Future<void> loadNetworkConfig() async {
    _isLoadingNetwork = true;
    _safeNotify();
    try {
      final loaded = await _networkRepo.load();
      if (_disposed) {
        return;
      }
      _networkConfig = loaded;
      _httpClient.updateConfig(loaded);
    } finally {
      _isLoadingNetwork = false;
      _safeNotify();
    }
  }

  /// 载入当前生效的 Bangumi ↔ TMDB 离线映射表快照。
  Future<void> loadMappingSnapshot() async {
    try {
      final snapshot = await _mappingUpdater.loadActiveSnapshot();
      if (_disposed) {
        return;
      }
      _mappingSnapshot = snapshot;
      _safeNotify();
    } catch (_) {
      // 无内置资产或离线环境保持空态兜底，不阻断设置页初始化。
    }
  }

  /// 手动检查并更新离线动画映射表增量快照。
  Future<BangumiTmdbUpdateResult> checkBangumiTmdbMappingUpdate() async {
    _isUpdatingMapping = true;
    _safeNotify();
    try {
      final result = await _mappingUpdater.checkAndUpdateIfDue(
        force: true,
        networkConfig: _networkConfig,
      );
      if (!_disposed) {
        _mappingUpdateResult = result;
        _mappingSnapshot = result.snapshot;
      }
      return result;
    } finally {
      _isUpdatingMapping = false;
      _safeNotify();
    }
  }

  /// 保存并应用新的网络配置，同步刷新底层 HTTP 客户端配置。
  Future<void> saveNetworkConfig(KonataNetworkConfig next) async {
    _isSavingNetwork = true;
    _safeNotify();
    try {
      await _networkRepo.save(next);
      if (_disposed) {
        return;
      }
      _networkConfig = next;
      _httpClient.updateConfig(next);
      _onNetworkConfigChanged?.call(next);
      _diagnosticLog.logEvent(
        subsystem: DiagnosticSubsystem.network,
        code: 'SETTINGS_NETWORK_SAVED',
        message: '已更新网络代理、备用镜像与元数据凭据配置',
        source: 'SettingsController',
      );
    } finally {
      _isSavingNetwork = false;
      _safeNotify();
    }
  }

  /// 恢复默认网络镜像与代理设置（保留已保存的 TMDB 与 Fanart 密钥）。
  Future<void> resetMirrorsAndProxyPreservingKeys() async {
    const defaults = KonataNetworkConfig();
    final next = _networkConfig.copyWith(
      tmdbBackupApiBase: defaults.tmdbBackupApiBase,
      tmdbBackupImageBase: defaults.tmdbBackupImageBase,
      bangumiBackupApiBase: defaults.bangumiBackupApiBase,
      bangumiBackupImageBase: defaults.bangumiBackupImageBase,
      fanartBackupApiBase: defaults.fanartBackupApiBase,
      fanartBackupImageBase: defaults.fanartBackupImageBase,
      proxyMode: defaults.proxyMode,
      proxyUrl: defaults.proxyUrl,
    );
    await saveNetworkConfig(next);
  }

  /// 对指定目标执行连通性测速探测并更新报告快照。
  Future<ConnectivityReport> runConnectivityProbe(String targetId) async {
    _probingTargets.add(targetId);
    _safeNotify();
    try {
      final ConnectivityReport report;
      final override = _connectivityProbeOverride;
      if (override != null) {
        report = await override(targetId);
      } else if (_httpClient is KonataHttpClient) {
        report = await switch (targetId) {
          NetworkProbeTargets.tmdbApi => _httpClient.testTmdbApiConnectivity(),
          NetworkProbeTargets.tmdbImage =>
            _httpClient.testTmdbImageConnectivity(),
          NetworkProbeTargets.bangumiApi =>
            _httpClient.testBangumiApiConnectivity(),
          NetworkProbeTargets.bangumiImage =>
            _httpClient.testBangumiImageConnectivity(),
          NetworkProbeTargets.fanartApi =>
            _httpClient.testFanartApiConnectivity(),
          NetworkProbeTargets.fanartImage =>
            _httpClient.testFanartImageConnectivity(),
          _ => _httpClient.testTmdbApiConnectivity(),
        };
      } else {
        report = await _probeWithGenericPort(targetId);
      }

      _probeReports[targetId] = report;
      return report;
    } finally {
      _probingTargets.remove(targetId);
      _safeNotify();
    }
  }

  /// 扫描刷新全站 `photos/` 图片占用统计。
  Future<PhotosCleanupSnapshot> refreshPhotosStorage() async {
    _isScanningPhotos = true;
    _safeNotify();
    try {
      _photosRootPath ??= await _photosScanner.resolveRootPath();
      final snapshot = await _photosScanner.scanSnapshot();
      if (!_disposed) {
        _photosSnapshot = snapshot;
        _photosRootPath = snapshot.globalStats.rootPath;
      }
      return snapshot;
    } finally {
      _isScanningPhotos = false;
      _safeNotify();
    }
  }

  /// 清理选中的图片类别（可选限定单个作品），完成后自动重算统计。
  Future<int> clearPhotoCategories(
    Set<PhotoStorageCategory> categories, {
    String? workId,
  }) async {
    final removed = await _photosScanner.clearCategories(
      categories,
      workId: workId,
    );
    await refreshPhotosStorage();
    _diagnosticLog.logEvent(
      subsystem: DiagnosticSubsystem.storage,
      code: 'PHOTOS_CUSTOM_CLEANUP',
      message: '已清理 $removed 个缓存图片文件',
      source: 'SettingsController',
      context: <String, Object?>{
        'removedFiles': removed,
        'categories': categories.map((c) => c.dirName).toList(),
        'workId': ?workId,
      },
    );
    return removed;
  }

  /// 按指定作品目录集合与图片分类精确清理缓存，返回清理文件数与释放字节数。
  Future<({int removedFiles, int freedBytes})> clearCustomPhotos({
    required Set<String> workDirKeys,
    required Set<PhotoStorageCategory> categories,
  }) async {
    final result = await _photosScanner.clearCustomPhotos(
      workDirKeys: workDirKeys,
      categories: categories,
    );
    await refreshPhotosStorage();
    _diagnosticLog.logEvent(
      subsystem: DiagnosticSubsystem.storage,
      code: 'PHOTOS_CUSTOM_CLEANUP',
      message: '已清理 ${result.removedFiles} 张图片',
      source: 'SettingsController',
      context: <String, Object?>{
        'removedFiles': result.removedFiles,
        'freedBytes': result.freedBytes,
        'works': workDirKeys.length,
        'categories': categories.map((c) => c.dirName).toList(),
      },
    );
    return result;
  }

  /// 一键清理所有可再生缓存图片（剧照与扫图微缩图）。
  Future<int> clearRegenerableCaches() async {
    final removed = await _photosScanner.clearRegenerableCaches();
    await refreshPhotosStorage();
    return removed;
  }

  /// 切换诊断日志详细级别开关。
  void setDiagnosticVerbose(bool enabled) {
    _diagnosticLog.setVerbose(enabled);
    _safeNotify();
  }

  /// 清空当前内存中的诊断运行事件。
  void clearDiagnosticLogs() {
    _diagnosticLog.clear();
    _safeNotify();
  }

  /// 生成严格脱敏后的精简诊断定位摘要（供一键复制到剪贴板）。
  Future<String> buildCompactDiagnosticSummary() async {
    final counts = _diagnosticLog.summaryCounts;
    final faults = _diagnosticLog.summarizeFaults();
    final events = _diagnosticLog.snapshotEvents();
    final secrets = await _networkRepo.readCurrentSecretsForRedaction();

    final buf = StringBuffer()
      ..writeln('Konata $_appVersion 诊断定位摘要')
      ..writeln(
        '事件统计：异常 ${counts.errorCount} · 警告 ${counts.warningCount} · '
        '总事件 ${counts.totalEvents} · 轨迹 ${counts.breadcrumbCount}',
      );
    if (faults.isNotEmpty) {
      buf.writeln('最近故障分诊：');
      for (final fault in faults.take(5)) {
        buf.writeln(
          '- [${fault.severity.badge}][${fault.subsystem.code}][${fault.code}] '
          'x${fault.count} ${fault.sampleMessage}',
        );
      }
    }
    if (events.isNotEmpty) {
      final start = events.length > 12 ? events.length - 12 : 0;
      buf.writeln('最近事件轨迹：');
      for (final ev in events.sublist(start)) {
        buf.writeln('- ${ev.formatCompactLine()}');
      }
    }
    return _redactDiagnosticText(buf.toString(), secrets);
  }

  /// 生成严格脱敏后的诊断报告并经 [BackupFilePort.saveFile] 写入磁盘。
  ///
  /// 返回保存的文件路径；若用户取消保存则返回 `null`。
  Future<String?> exportDiagnosticBundle({bool asJson = true}) async {
    _isExportingDiagnostics = true;
    _safeNotify();
    try {
      final rawReport = asJson
          ? await _diagnosticLog.buildJsonBundle()
          : await _diagnosticLog.buildTextReport();
      final secrets = await _networkRepo.readCurrentSecretsForRedaction();
      final sanitized = _redactDiagnosticText(rawReport, secrets);

      final now = DateTime.now();
      final stamp =
          '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';
      final ext = asJson ? 'json' : 'txt';
      final fileName = 'konata_diagnostics_$stamp.$ext';
      final bytes = Uint8List.fromList(utf8.encode(sanitized));
      return await _backupFilePort.saveFile(
        fileName: fileName,
        bytes: bytes,
        dialogTitle: asJson ? '导出结构化诊断包 (JSON)' : '导出诊断日志报告 (TXT)',
      );
    } finally {
      _isExportingDiagnostics = false;
      _safeNotify();
    }
  }

  /// 通过宿主注入的外链端口在浏览器或文件管理器中打开目标链接。
  Future<bool> openExternalUrl(Uri uri) => _urlOpener.openExternalUrl(uri);

  String _redactDiagnosticText(String raw, List<String> secrets) {
    var sanitized = DiagnosticTextSanitizer.redactForExport(raw);
    // 同步兼容 JSON 转义双反斜杠形式的本地用户目录路径脱敏。
    sanitized = sanitized.replaceAll(
      RegExp(r'[A-Za-z]:\\\\Users\\\\[^\\/\s"\x27]+'),
      '<USER_HOME>',
    );
    for (final secret in secrets) {
      if (secret.isNotEmpty) {
        sanitized = sanitized.replaceAll(secret, '[REDACTED]');
      }
    }
    return sanitized;
  }

  Future<ConnectivityReport> _probeWithGenericPort(String targetId) async {
    final primaryUri = switch (targetId) {
      NetworkProbeTargets.tmdbImage => Uri.parse(
        '${KonataNetworkConfig.defaultImageBase}/w92/wwemzKWzjKYJFfCeiB57q3r4Bcm.png',
      ),
      NetworkProbeTargets.bangumiApi => Uri.parse(
        '${KonataNetworkConfig.defaultBangumiApiBase}/v0/subjects/1',
      ),
      NetworkProbeTargets.bangumiImage => Uri.parse(
        '${KonataNetworkConfig.defaultBangumiImageBase}/pic/cover/c/7f/ce/1_3581p.jpg',
      ),
      NetworkProbeTargets.fanartApi => Uri.parse(
        '${KonataNetworkConfig.defaultFanartApiBase}/movies/129',
      ),
      NetworkProbeTargets.fanartImage => Uri.parse(
        '${KonataNetworkConfig.defaultFanartImageBase}/fanart/movies/129/hdmovielogo/spirited-away-5215d8259099b.png',
      ),
      _ => Uri.parse('${KonataNetworkConfig.defaultApiBase}/configuration'),
    };
    final watch = Stopwatch()..start();
    try {
      final res = await _httpClient.getWithFallback(
        primaryUri,
        priority: RequestPriority.interactive,
        timeoutOverride: const Duration(seconds: 6),
      );
      watch.stop();
      final ok = res.statusCode >= 200 && res.statusCode < 500;
      return ConnectivityReport(
        reachable: ok,
        latencyMs: watch.elapsedMilliseconds,
        resolvedAddress: primaryUri.host,
        statusSummary: 'HTTP ${res.statusCode}',
        errorMessage: ok ? null : '服务响应状态码 ${res.statusCode}',
      );
    } catch (error) {
      watch.stop();
      return ConnectivityReport(
        reachable: false,
        latencyMs: watch.elapsedMilliseconds,
        resolvedAddress: primaryUri.host,
        errorMessage: NetworkErrorSanitizer.redactSecrets(error.toString()),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _appearanceSub?.cancel();
    _displaySub?.cancel();
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
