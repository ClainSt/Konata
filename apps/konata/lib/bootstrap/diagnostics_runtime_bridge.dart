import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 全局诊断运行态桥接器：挂载未捕获框架/异步异常钩子并注册脱敏运行时快照。
final class HostDiagnosticsRuntimeBridge {
  /// 创建并挂载全局未捕获异常与运行时状态快照采集桥接器。
  HostDiagnosticsRuntimeBridge({
    required DiagnosticLogPort this._diagnosticLog,
    required KonataDatabaseBundle this._databases,
    required KonataHttpClientPort this._httpClient,
    required Map<String, String> Function() this._uiSnapshotProvider,
  }) {
    _installGlobalErrorHooks();
    _registerSnapshotContributors();
  }

  final DiagnosticLogPort _diagnosticLog;
  final KonataDatabaseBundle _databases;
  final KonataHttpClientPort _httpClient;
  final Map<String, String> Function() _uiSnapshotProvider;

  FlutterExceptionHandler? _previousFlutterErrorHandler;
  bool Function(Object, StackTrace)? _previousPlatformErrorHandler;
  final List<void Function()> _disposers = <void Function()>[];
  bool _disposed = false;

  void _installGlobalErrorHooks() {
    final prevFlutter = FlutterError.onError;
    _previousFlutterErrorHandler = prevFlutter;
    FlutterError.onError = (FlutterErrorDetails details) {
      _diagnosticLog.logError(
        subsystem: DiagnosticSubsystem.ui,
        severity: DiagnosticSeverity.fatal,
        code: 'UNCAUGHT_FLUTTER_ERROR',
        message: details.exceptionAsString(),
        error: details.exception,
        stackTrace: details.stack,
        source: 'HostDiagnosticsRuntimeBridge.FlutterError',
        context: <String, Object?>{
          if (details.library != null) 'library': details.library,
          if (details.context != null)
            'widgetContext': details.context!.toDescription(),
        },
      );
      prevFlutter?.call(details);
    };

    final dispatcher = PlatformDispatcher.instance;
    final prevPlatform = dispatcher.onError;
    _previousPlatformErrorHandler = prevPlatform;
    dispatcher.onError = (Object error, StackTrace stack) {
      _diagnosticLog.logError(
        subsystem: DiagnosticSubsystem.app,
        severity: DiagnosticSeverity.fatal,
        code: 'UNCAUGHT_PLATFORM_ERROR',
        message: '未捕获全局异步异常：$error',
        error: error,
        stackTrace: stack,
        source: 'HostDiagnosticsRuntimeBridge.PlatformDispatcher',
      );
      if (prevPlatform != null) {
        return prevPlatform(error, stack);
      }
      return false;
    };
  }

  void _registerSnapshotContributors() {
    _disposers.add(
      _diagnosticLog.registerSnapshotContributor(
        'app_ui',
        () => DiagnosticSnapshotSection(
          id: 'app_ui',
          title: '应用界面与窗口壳层状态',
          entries: _uiSnapshotProvider(),
        ),
      ),
    );
    _disposers.add(
      _diagnosticLog.registerSnapshotContributor(
        'library_db',
        _collectLibrarySnapshot,
      ),
    );
    _disposers.add(
      _diagnosticLog.registerSnapshotContributor(
        'network',
        _collectNetworkSnapshot,
      ),
    );
  }

  DiagnosticSnapshotSection _collectLibrarySnapshot() {
    final sources = _databases.library.mediaSources.listAll();
    final works = _databases.library.works.listAll();
    final matched = works
        .where((w) => w.scrapeStatus == ScrapeStatus.matched)
        .length;
    final needsReview = works
        .where((w) => w.scrapeStatus == ScrapeStatus.needsReview)
        .length;
    final hidden = works.where((w) => w.isHidden).length;
    return DiagnosticSnapshotSection(
      id: 'library_db',
      title: '本地媒体库与元数据统计',
      entries: <String, String>{
        'sourcesCount': sources.length.toString(),
        'worksTotal': works.length.toString(),
        'worksMatched': matched.toString(),
        'worksNeedsReview': needsReview.toString(),
        'worksHidden': hidden.toString(),
      },
    );
  }

  DiagnosticSnapshotSection _collectNetworkSnapshot() {
    final config = _httpClient.config;
    return DiagnosticSnapshotSection(
      id: 'network',
      title: '网络与元数据服务配置（凭据已脱敏）',
      entries: <String, String>{
        'proxyMode': config.proxyMode.name,
        'hasProxyUrl': config.proxyUrl.trim().isNotEmpty.toString(),
        'tmdbCredentialConfigured': config.credential.trim().isNotEmpty
            .toString(),
        'fanartClientKeyConfigured': config.fanartClientKey.trim().isNotEmpty
            .toString(),
      },
    );
  }

  /// 释放全部快照贡献者并恢复原有全局异常处理器。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final disposer in _disposers) {
      disposer();
    }
    _disposers.clear();
    FlutterError.onError = _previousFlutterErrorHandler;
    PlatformDispatcher.instance.onError = _previousPlatformErrorHandler;
  }
}

/// 全局路由轨迹观察器：无感记录页面推入与返回面包屑，便于诊断定位复现路径。
final class KonataDiagnosticRouteObserver extends NavigatorObserver {
  /// 创建全局路由诊断观察器。
  KonataDiagnosticRouteObserver(this._diagnosticLog);

  final DiagnosticLogPort _diagnosticLog;

  String _describeRoute(Route<dynamic>? route) {
    if (route == null) return 'none';
    final name = route.settings.name;
    if (name != null && name.trim().isNotEmpty) {
      return name.trim();
    }
    return route.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _diagnosticLog.recordBreadcrumb(
      category: 'route',
      label: '进入页面 ${_describeRoute(route)}',
      detail: previousRoute == null
          ? null
          : 'from=${_describeRoute(previousRoute)}',
      source: 'KonataDiagnosticRouteObserver.didPush',
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _diagnosticLog.recordBreadcrumb(
      category: 'route',
      label: '返回页面 ${_describeRoute(previousRoute)}',
      detail: 'popped=${_describeRoute(route)}',
      source: 'KonataDiagnosticRouteObserver.didPop',
    );
  }
}
