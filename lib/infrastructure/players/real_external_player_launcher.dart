import 'dart:async';
import 'dart:io';

import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/repositories/external_player_launcher.dart';
import '../sources/byte_stream_source_gateway.dart';
import '../sources/local_source_gateway.dart';
import '../sources/source_access_error.dart';
import '../sources/source_gateway_factory.dart';
import '../stream_bridge/local_stream_bridge.dart';
import 'foobar_beefweb_tracker.dart';
import 'mpv_ipc_tracker.dart';
import 'potplayer_win32_tracker.dart';

/// 外部播放器进程拉起抽象（方便单测注入替身）。
typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// 基于本地 HTTP 流网桥 + MPV IPC / PotPlayer Win32 / Foobar Beefweb 的真实外部程序启动器。
class RealExternalPlayerLauncher implements ExternalPlayerLauncher {
  /// 创建真实播放器启动器。
  RealExternalPlayerLauncher({
    required this.streamBridge,
    required this.gatewayFactory,
    this.mpvPipeClient = const Win32MpvPipeClient(),
    this.potProbe = const Win32PotPlayerWindowProbe(),
    ProcessStarter? processStarter,
    this.verifyExecutableExists = true,
  }) : _processStarter = processStarter ?? Process.start;

  /// 本地回环 HTTP Range 流媒体网桥。
  final LocalStreamBridge streamBridge;

  /// 媒体源网关构建器。
  final MediaSourceGatewayFactory gatewayFactory;

  /// MPV 命名管道查询客户端。
  final MpvPipeClient mpvPipeClient;

  /// PotPlayer Win32 窗口控制消息探针。
  final PotPlayerWindowProbe potProbe;

  final ProcessStarter _processStarter;

  /// 是否预先检查播放器可执行文件存在于磁盘。
  final bool verifyExecutableExists;

  @override
  Future<LaunchPlaybackResult> launch({
    required Work work,
    required Episode episode,
    required MediaVariant variant,
    ExternalPlayerConfig? player,
    MediaSource? source,
    int startSeconds = 0,
    double? exactStartSeconds,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  }) async {
    final effectivePlayer = await _resolvePlayerConfig(player);
    if (effectivePlayer == null) {
      if (player?.kind == ExternalPlayerKind.audioPlayer) {
        return LaunchPlaybackResult(
          launched: false,
          message: '外部音频播放器路径不存在：${player!.executablePath}',
        );
      }
      return const LaunchPlaybackResult(
        launched: false,
        message: '未检测到可用的外部播放器，请在「设置 -> 外部播放器」中配置路径',
      );
    }

    if (source == null) {
      return const LaunchPlaybackResult(
        launched: false,
        message: '未找到所属媒体源配置，无法启动外部程序',
      );
    }

    String targetUrlOrPath;
    List<String> localSubtitlePaths = const [];
    String? activeSessionToken;

    try {
      if (source.kind == MediaSourceKind.local) {
        final localGw = LocalSourceGateway(rootPath: source.location);
        final absMediaPath = localGw.resolveAbsolutePath(variant.relativePath);
        if (!await File(absMediaPath).exists()) {
          return LaunchPlaybackResult(
            launched: false,
            message: '本地媒体文件不存在或已移动：$absMediaPath',
          );
        }
        targetUrlOrPath = absMediaPath;
        localSubtitlePaths = await _resolveLocalSubtitles(
          localGw,
          variant.externalSubtitles,
        );
      } else {
        final gw = await gatewayFactory.create(source);
        if (gw is! ByteRangeReadableGateway) {
          await gw.close();
          return const LaunchPlaybackResult(
            launched: false,
            message: '当前媒体源网关不支持 HTTP Range 流式透传',
          );
        }
        final readableGw = gw as ByteRangeReadableGateway;
        final session = await streamBridge.registerSession(
          gateway: readableGw,
          relativePath: variant.relativePath,
          fileName: variant.fileName,
          knownLength: variant.fileSize,
          ownsGateway: true,
        );
        activeSessionToken = session.token;
        targetUrlOrPath = session.url.toString();

        if (variant.externalSubtitles.isNotEmpty) {
          localSubtitlePaths = await streamBridge.materializeRemoteSubtitles(
            gateway: readableGw,
            workId: work.id,
            sourceId: source.id,
            subtitleRelativePaths: variant.externalSubtitles,
          );
        }
      }
    } catch (error) {
      if (activeSessionToken != null) {
        await streamBridge.unregisterSession(activeSessionToken);
      }
      final msg = SourceAccessErrorClassifier.toChineseMessage(
        error,
        source.kind,
      );
      return LaunchPlaybackResult(launched: false, message: msg);
    }

    final protocolKind = _detectProtocolKind(effectivePlayer);
    final pipePath = protocolKind == ExternalPlayerKind.mpv
        ? MpvIpcTracker.createPipePath(
            '${variant.id}_${DateTime.now().microsecondsSinceEpoch}',
          )
        : '';

    final displayTitle = EpisodeTitleFormatter.formatPlayerMediaTitle(
      work: work,
      episode: episode,
      mainEpisodeCount: mainEpisodeCount,
      fallbackFileName: variant.fileName,
    );

    final arguments = _buildArguments(
      player: effectivePlayer,
      protocolKind: protocolKind,
      targetUrlOrPath: targetUrlOrPath,
      displayTitle: displayTitle,
      pipePath: pipePath,
      startSeconds: startSeconds,
      exactStartSeconds: exactStartSeconds,
      subtitlePaths: localSubtitlePaths,
    );

    Process process;
    try {
      process = await _processStarter(
        effectivePlayer.executablePath,
        arguments,
      );
    } catch (error) {
      if (activeSessionToken != null) {
        await streamBridge.unregisterSession(activeSessionToken);
      }
      return LaunchPlaybackResult(
        launched: false,
        message: '无法启动播放器 ${_displayName(effectivePlayer)}：$error',
      );
    }

    // 必须在 Process.start 返回后的第一时间持续排空 stdout / stderr 匿名管道，
    // 防止播放器日志写满 Windows 4KB 缓冲区引发子进程阻塞死锁。
    unawaited(process.stdout.drain<void>().catchError((_) {}));
    unawaited(process.stderr.drain<void>().catchError((_) {}));

    _attachProgressTracker(
      player: effectivePlayer,
      protocolKind: protocolKind,
      process: process,
      targetUrlOrPath: targetUrlOrPath,
      pipePath: pipePath,
      startSeconds: startSeconds,
      onProgressUpdate: onProgressUpdate,
      sessionToken: activeSessionToken,
    );

    final resumeHint = startSeconds > 0
        ? ' · 从 ${PlaybackRecord.formatClock(startSeconds)} 续播'
        : '';
    final subHint = localSubtitlePaths.isNotEmpty
        ? '（已挂载 ${localSubtitlePaths.length} 个外挂字幕）'
        : '';
    return LaunchPlaybackResult(
      launched: true,
      message: '已启动 ${_displayName(effectivePlayer)}$resumeHint$subHint',
    );
  }

  String _displayName(ExternalPlayerConfig player) {
    final trimmed = player.name.trim();
    if (trimmed.isNotEmpty) return trimmed;
    if (player.kind == ExternalPlayerKind.audioPlayer) return 'foobar2000';
    if (player.kind == ExternalPlayerKind.mpv) return 'MPV';
    if (player.kind == ExternalPlayerKind.potplayer) return 'PotPlayer';
    return '外部程序';
  }

  ExternalPlayerKind _detectProtocolKind(ExternalPlayerConfig player) {
    if (player.kind == ExternalPlayerKind.mpv ||
        player.kind == ExternalPlayerKind.potplayer) {
      return player.kind;
    }
    final normalized = player.executablePath
        .replaceAll('/', '\\')
        .toLowerCase();
    final idx = normalized.lastIndexOf('\\');
    final exe = idx >= 0 ? normalized.substring(idx + 1) : normalized;
    if (exe == 'mpv.exe' || exe == 'mpvnet.exe' || exe == 'mpv') {
      return ExternalPlayerKind.mpv;
    }
    if (exe.contains('potplayer')) {
      return ExternalPlayerKind.potplayer;
    }
    if (player.kind == ExternalPlayerKind.audioPlayer ||
        exe.contains('foobar')) {
      return ExternalPlayerKind.audioPlayer;
    }
    return player.kind;
  }

  List<String> _buildArguments({
    required ExternalPlayerConfig player,
    required ExternalPlayerKind protocolKind,
    required String targetUrlOrPath,
    required String displayTitle,
    required String pipePath,
    required int startSeconds,
    double? exactStartSeconds,
    required List<String> subtitlePaths,
  }) {
    if (protocolKind == ExternalPlayerKind.mpv) {
      return MpvIpcTracker.buildLaunchArguments(
        targetUrlOrPath: targetUrlOrPath,
        pipePath: pipePath,
        displayTitle: displayTitle,
        startSeconds: startSeconds,
        exactStartSeconds: exactStartSeconds,
        subtitlePaths: subtitlePaths,
        argumentsTemplate: player.argumentsTemplate,
      );
    }
    if (protocolKind == ExternalPlayerKind.potplayer) {
      return PotPlayerWin32Tracker.buildLaunchArguments(
        targetUrlOrPath: targetUrlOrPath,
        startSeconds: startSeconds,
        subtitlePaths: subtitlePaths,
        argumentsTemplate: player.argumentsTemplate,
      );
    }
    return sanitizeAndOrderPlayerArguments(
      leadingOptions: const [],
      argumentsTemplate: player.argumentsTemplate,
      targetUrlOrPath: targetUrlOrPath,
    );
  }

  void _attachProgressTracker({
    required ExternalPlayerConfig player,
    required ExternalPlayerKind protocolKind,
    required Process process,
    required String targetUrlOrPath,
    required String pipePath,
    required int startSeconds,
    required PlaybackProgressCallback? onProgressUpdate,
    required String? sessionToken,
  }) {
    Future<void> persist(int pos, int dur, {required bool isFinal}) async {
      if (onProgressUpdate != null) {
        await onProgressUpdate(pos, dur, isFinal: isFinal);
      }
    }

    unawaited(() async {
      var unregisterImmediately = true;
      try {
        if (protocolKind == ExternalPlayerKind.mpv) {
          await MpvIpcTracker.trackProcess(
            pipePath: pipePath,
            exitCodeFuture: process.exitCode,
            onPersist: persist,
            startSeconds: startSeconds,
            pipeClient: mpvPipeClient,
          );
        } else if (protocolKind == ExternalPlayerKind.potplayer) {
          await PotPlayerWin32Tracker.trackProcess(
            processId: process.pid,
            exitCodeFuture: process.exitCode,
            onPersist: persist,
            startSeconds: startSeconds,
            probe: potProbe,
          );
        } else if (protocolKind == ExternalPlayerKind.audioPlayer) {
          unregisterImmediately = await FoobarBeefwebTracker.trackProcess(
            targetUrlOrPath: targetUrlOrPath,
            exitCodeFuture: process.exitCode,
            onPersist: persist,
            startSeconds: startSeconds,
            keepRemoteSessionAlive: sessionToken != null,
          );
        } else {
          await process.exitCode;
        }
      } finally {
        if (sessionToken != null && unregisterImmediately) {
          await streamBridge.unregisterSession(sessionToken);
        }
      }
    }());
  }

  Future<List<String>> _resolveLocalSubtitles(
    LocalSourceGateway localGw,
    List<String> relativeSubtitles,
  ) async {
    final result = <String>[];
    for (final rel in relativeSubtitles) {
      final abs = localGw.resolveAbsolutePath(rel);
      if (await File(abs).exists()) {
        result.add(abs);
      }
    }
    return result;
  }

  Future<ExternalPlayerConfig?> _resolvePlayerConfig(
    ExternalPlayerConfig? provided,
  ) async {
    if (provided != null && provided.executablePath.trim().isNotEmpty) {
      final candidate = provided.executablePath.trim();
      final hasSeparator = candidate.contains('\\') || candidate.contains('/');
      if (!verifyExecutableExists ||
          !hasSeparator ||
          await File(candidate).exists()) {
        return provided;
      }
      if (provided.kind == ExternalPlayerKind.audioPlayer) {
        return null;
      }
    }
    const presets = <({ExternalPlayerKind kind, String name, String path})>[
      (
        kind: ExternalPlayerKind.mpv,
        name: 'MPV',
        path: r'C:\Program Files\mpv\mpv.exe',
      ),
      (
        kind: ExternalPlayerKind.mpv,
        name: 'MPV',
        path: r'C:\ProgramData\chocolatey\bin\mpv.exe',
      ),
      (
        kind: ExternalPlayerKind.potplayer,
        name: 'PotPlayer',
        path: r'C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe',
      ),
      (
        kind: ExternalPlayerKind.potplayer,
        name: 'PotPlayer',
        path: r'C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe',
      ),
    ];
    for (final preset in presets) {
      if (await File(preset.path).exists()) {
        return ExternalPlayerConfig(
          id: 'auto_${preset.kind.name}',
          name: preset.name,
          kind: preset.kind,
          executablePath: preset.path,
          isDefault: true,
        );
      }
    }
    return null;
  }
}
