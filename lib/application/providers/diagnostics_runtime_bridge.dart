import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/logging/diagnostic_event.dart';
import '../../domain/models/work.dart';
import '../../infrastructure/logging/diagnostics_log_store.dart';
import '../playback/audio_playback_notifier.dart';
import '../playback/playback_preferences_provider.dart';
import '../playback/unified_playback_coordinator.dart';
import '../playback/video_playback_controller.dart';
import 'diagnostics_providers.dart';
import 'library_providers.dart';
import 'scraping_providers.dart';
import 'theme_providers.dart';

/// 全局诊断运行态桥接器：挂载未捕获框架/异步异常钩子，并在导出日志时动态采集全系统运行状态快照。
class DiagnosticsRuntimeBridge {
  /// 创建并自动挂载全局异常捕获与状态快照贡献者。
  DiagnosticsRuntimeBridge(this._ref, this._store) {
    _installGlobalErrorHooks();
    _registerSnapshotContributors();
  }

  final Ref _ref;
  final DiagnosticsLogStore _store;

  FlutterExceptionHandler? _previousFlutterErrorHandler;
  bool Function(Object, StackTrace)? _previousPlatformErrorHandler;
  final List<void Function()> _disposers = <void Function()>[];
  bool _disposed = false;

  void _installGlobalErrorHooks() {
    final prevFlutter = FlutterError.onError;
    _previousFlutterErrorHandler = prevFlutter;
    FlutterError.onError = (FlutterErrorDetails details) {
      _store.logError(
        subsystem: DiagnosticSubsystem.ui,
        severity: DiagnosticSeverity.fatal,
        code: 'UNCAUGHT_FLUTTER_ERROR',
        message: details.exceptionAsString(),
        error: details.exception,
        stackTrace: details.stack,
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
      _store.logError(
        subsystem: DiagnosticSubsystem.app,
        severity: DiagnosticSeverity.fatal,
        code: 'UNCAUGHT_PLATFORM_ERROR',
        message: '未捕获全局异步异常：$error',
        error: error,
        stackTrace: stack,
      );
      if (prevPlatform != null) {
        return prevPlatform(error, stack);
      }
      return false;
    };
  }

  void _registerSnapshotContributors() {
    _disposers.add(
      _store.registerSnapshotContributor('app_ui', _collectAppUiSnapshot),
    );
    _disposers.add(
      _store.registerSnapshotContributor('playback', _collectPlaybackSnapshot),
    );
    _disposers.add(
      _store.registerSnapshotContributor('library_db', _collectLibrarySnapshot),
    );
    _disposers.add(
      _store.registerSnapshotContributor('network', _collectNetworkSnapshot),
    );
  }

  DiagnosticSnapshotSection _collectAppUiSnapshot() {
    final nav = _ref.read(selectedNavSectionProvider);
    final themeMode = _ref.read(themeModeProvider);
    final material = _ref.read(windowMaterialProvider);
    final searchQuery = _ref.read(librarySearchQueryProvider);
    return DiagnosticSnapshotSection(
      id: 'app_ui',
      title: '应用界面与导航态',
      entries: <String, String>{
        'activeSection': nav.name,
        'themeMode': themeMode.name,
        'windowMaterial': material.name,
        'hasSearchFilter': searchQuery.trim().isNotEmpty.toString(),
        'targetPlatform': defaultTargetPlatform.name,
      },
    );
  }

  DiagnosticSnapshotSection _collectPlaybackSnapshot() {
    final videoSession = _ref.read(activeVideoSessionProvider);
    final audioState = _ref.read(audioPlaybackProvider);
    final prefs = _ref.read(playbackPreferencesProvider);
    final entries = <String, String>{
      'defaultVideoEngine': prefs.defaultVideoEngine.name,
      'defaultAudioEngine': prefs.defaultAudioEngine.name,
      'hwdecEnabled': prefs.qualityConfig.hardwareDecode.toString(),
      'exclusiveAudio': prefs.qualityConfig.exclusiveAudioOutput.toString(),
      'cloudSubsetEnabled': prefs.cloudSubsetEnabled.toString(),
      'videoMiniEnabled': prefs.videoFloatingMiniEnabled.toString(),
      'audioMiniEnabled': prefs.audioFloatingMiniEnabled.toString(),
      'videoActive': videoSession.isActive.toString(),
      'videoExpanded': videoSession.isExpanded.toString(),
      'videoInPip': videoSession.isInPipMode.toString(),
      'audioActive': audioState.isActive.toString(),
      'audioPlaying': audioState.isPlaying.toString(),
    };
    final req = videoSession.request;
    if (req != null) {
      entries['videoWorkId'] = req.work.id;
      entries['videoEpisodeId'] = req.episode.id;
      try {
        final vState = _ref.read(videoPlaybackProvider(req));
        final activeSub = vState.subtitles
            .where((t) => t.selected)
            .firstOrNull;
        final activeAudio = vState.audioTracks
            .where((t) => t.selected)
            .firstOrNull;
        entries['videoPlaying'] = vState.isPlaying.toString();
        entries['videoBuffering'] = vState.isBuffering.toString();
        entries['videoBackend'] = vState.renderBackend.isEmpty
            ? vState.probeStats.voBackend
            : vState.renderBackend;
        entries['videoUnderlay'] = vState.windowsUnderlayActive.toString();
        entries['videoActiveSid'] = '${activeSub?.mpvTrackId ?? 'none'}';
        entries['videoActiveSubTitle'] = activeSub?.title ?? '';
        entries['videoSecondarySid'] =
            '${vState.secondarySubtitleTrackId ?? 'none'}';
        entries['videoActiveAid'] = '${activeAudio?.mpvTrackId ?? 'none'}';
        entries['videoOpenCc'] = vState.subtitleOpenCcMode.name;
        entries['videoHwdecCurrent'] = vState.probeStats.hwdecCurrent.isEmpty
            ? 'none'
            : vState.probeStats.hwdecCurrent;
        if (vState.errorMessage != null && vState.errorMessage!.isNotEmpty) {
          entries['videoError'] = vState.errorMessage!;
        }
      } catch (error) {
        entries['videoControllerProbeError'] = error.toString();
      }
    }
    if (audioState.isActive) {
      entries['audioQueueLength'] = audioState.queue.length.toString();
      entries['audioCurrentIndex'] = audioState.currentIndex.toString();
      if (audioState.errorMessage != null &&
          audioState.errorMessage!.isNotEmpty) {
        entries['audioError'] = audioState.errorMessage!;
      }
    }
    return DiagnosticSnapshotSection(
      id: 'playback',
      title: '音视频播放内核状态',
      entries: entries,
    );
  }

  Future<DiagnosticSnapshotSection> _collectLibrarySnapshot() async {
    final repo = _ref.read(libraryRepositoryProvider);
    final sources = await repo.getMediaSources();
    final works = await repo.getAllWorks();
    final episodes = await repo.getAllEpisodes();
    final playbacks = await repo.getPlaybackHistory(limit: 500);
    final matched = works
        .where((w) => w.scrapeStatus == ScrapeStatus.matched)
        .length;
    final needsReview = works
        .where((w) => w.scrapeStatus == ScrapeStatus.needsReview)
        .length;
    final unmatched = works
        .where((w) => w.scrapeStatus == ScrapeStatus.unmatched)
        .length;
    final hidden = works.where((w) => w.isHidden).length;
    final withBangumi = works.where((w) => w.bangumiId != null).length;
    return DiagnosticSnapshotSection(
      id: 'library_db',
      title: '本地媒体库与元数据统计',
      entries: <String, String>{
        'sourcesCount': sources.length.toString(),
        'sourceKinds': sources.map((s) => s.kind.name).toSet().join(','),
        'worksTotal': works.length.toString(),
        'worksMatched': matched.toString(),
        'worksNeedsReview': needsReview.toString(),
        'worksUnmatched': unmatched.toString(),
        'worksHidden': hidden.toString(),
        'worksWithBangumiId': withBangumi.toString(),
        'episodesTotal': episodes.length.toString(),
        'playbackRecordsSampled': playbacks.length.toString(),
      },
    );
  }

  Future<DiagnosticSnapshotSection> _collectNetworkSnapshot() async {
    final config = await _ref.read(networkConfigRepositoryProvider).load();
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
        'tmdbBackupApiConfigured': config.tmdbBackupApiBase.trim().isNotEmpty
            .toString(),
        'bangumiBackupApiConfigured':
            config.bangumiBackupApiBase.trim().isNotEmpty.toString(),
      },
    );
  }

  /// 释放所有注册的快照贡献者并恢复原全局异常钩子。
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

/// 全局诊断运行态桥接 Provider（由 `KonataApp` 激活并随根容器生命周期自动回收）。
final diagnosticsRuntimeBridgeProvider = Provider<DiagnosticsRuntimeBridge>((
  ref,
) {
  final store = ref.watch(diagnosticsLogStoreProvider);
  final bridge = DiagnosticsRuntimeBridge(ref, store);
  ref.onDispose(bridge.dispose);
  return bridge;
});
