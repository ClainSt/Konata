import 'dart:async';
import 'dart:convert';

import 'package:engine_sources/engine_sources.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';
import 'package:konata_storage/konata_storage.dart';

import '../data/photos_cleanup_scanner.dart';
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
/// 统筹外观与主题持久化、网络与元数据凭据存取、图片占用统计清理、
/// 脱敏诊断日志导出与关于页外链打开。
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
    this._onNetworkConfigChanged,
    this._connectivityProbeOverride,
  }) : _appearanceRepo = SettingsAppearanceRepository(scopedPrefs),
       _networkRepo = SettingsNetworkRepository(
         scopedPrefs: scopedPrefs,
         secureStorage: secureStorage,
       ),
       _photosScanner = PhotosCleanupScanner(
         photosStorage: photosStorage,
         workDao: databases.library.works,
       ) {
    _appearance = _appearanceRepo.read();
    _networkConfig = _httpClient.config;
    _appearanceSub = _appearanceRepo.watch().listen((next) {
      _appearance = next;
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
  final ValueChanged<KonataNetworkConfig>? _onNetworkConfigChanged;
  final NetworkConnectivityProbe? _connectivityProbeOverride;

  final SettingsAppearanceRepository _appearanceRepo;
  final SettingsNetworkRepository _networkRepo;
  final PhotosCleanupScanner _photosScanner;

  StreamSubscription<SettingsAppearancePrefs>? _appearanceSub;
  bool _disposed = false;

  late SettingsAppearancePrefs _appearance;
  late KonataNetworkConfig _networkConfig;
  bool _isLoadingNetwork = true;
  bool _isSavingNetwork = false;
  bool _isScanningPhotos = false;
  bool _isExportingDiagnostics = false;
  PhotosCleanupSnapshot? _photosSnapshot;
  final Map<String, ConnectivityReport> _probeReports =
      <String, ConnectivityReport>{};
  final Set<String> _probingTargets = <String>{};

  /// 应用当前展示版本号。
  String get appVersion => _appVersion;

  /// 当前主题外观配置。
  SettingsAppearancePrefs get appearance => _appearance;

  /// 当前生效的主题模式。
  ThemeMode get themeMode => _appearance.themeMode;

  /// 当前是否开启柔和流光背景。
  bool get ambientBackdropEnabled => _appearance.ambientBackdropEnabled;

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

  /// 最近一次图片磁盘占用扫描快照。
  PhotosCleanupSnapshot? get photosSnapshot => _photosSnapshot;

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

  /// 初始化异步状态：载入安全凭据区与本地图片统计。
  Future<void> initialize() async {
    await loadNetworkConfig();
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
      final snapshot = await _photosScanner.scanSnapshot();
      _photosSnapshot = snapshot;
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
      var sanitized = DiagnosticTextSanitizer.redactForExport(rawReport);
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

      final now = DateTime.now();
      final stamp =
          '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}';
      final ext = asJson ? 'json' : 'txt';
      final fileName = 'konata_diagnostic_$stamp.$ext';
      final bytes = Uint8List.fromList(utf8.encode(sanitized));
      return await _backupFilePort.saveFile(
        fileName: fileName,
        bytes: bytes,
        dialogTitle: '导出脱敏诊断报告',
      );
    } finally {
      _isExportingDiagnostics = false;
      _safeNotify();
    }
  }

  /// 通过宿主注入的外链端口在浏览器中打开目标链接。
  Future<bool> openExternalUrl(Uri uri) => _urlOpener.openExternalUrl(uri);

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
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
