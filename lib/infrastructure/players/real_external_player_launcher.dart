import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/matching/episode_title_formatter.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/external_player_config.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
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
    this.appDataDirOverride,
    this.beefwebBaseUrlOverride,
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

  /// 可选覆盖 `%APPDATA%` 路径（供单测离线校验标准安装版 `foo_beefweb` 目录探测）。
  final String? appDataDirOverride;

  /// 可选覆盖 `Beefweb` 基础地址（供集成单测绑定随机空闲端口）。
  final String? beefwebBaseUrlOverride;

  int _audioSessionEpoch = 0;

  @override
  Future<FoobarComponentStatusSnapshot> probeAudioPlayerStatus({
    required ExternalPlayerConfig? player,
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async {
    if (player == null || player.executablePath.trim().isEmpty) {
      return FoobarComponentStatusSnapshot(
        state: FoobarComponentState.unconfigured,
        port: beefwebPort,
      );
    }
    if (beefwebBaseUrlOverride != null &&
        FoobarBeefwebTracker.isFoobarExecutable(player.executablePath)) {
      final parsed = Uri.tryParse(beefwebBaseUrlOverride!);
      final effectivePort = parsed?.hasPort == true ? parsed!.port : beefwebPort;
      return FoobarBeefwebTracker.inspectStatus(
        executablePath: player.executablePath,
        port: effectivePort,
        appDataDirOverride: appDataDirOverride,
        verifyExecutableExists: verifyExecutableExists,
      );
    }
    return FoobarBeefwebTracker.inspectStatus(
      executablePath: player.executablePath,
      port: beefwebPort,
      appDataDirOverride: appDataDirOverride,
      verifyExecutableExists: verifyExecutableExists,
    );
  }

  @override
  Future<void> stopActiveExternalAudioSession({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async {
    _audioSessionEpoch += 1;
    await FoobarBeefwebTracker.stopKonataSessionIfActive(
      port: beefwebPort,
      baseUrlOverride: beefwebBaseUrlOverride,
    );
  }

  @override
  Future<LaunchPlaybackResult> launchAudioAlbum({
    required ExternalAudioAlbumRelayRequest request,
    ExternalPlayerConfig? player,
    ExternalAudioProgressCallback? onTrackProgress,
  }) async {
    if (request.tracks.isEmpty) {
      return const LaunchPlaybackResult(
        launched: false,
        message: '当前专辑无可播放曲目',
      );
    }
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
        message: '未检测到可用的外部播放器，请在「设置 -> 外部调用」中配置路径',
      );
    }

    final source = request.source;
    if (source == null) {
      return const LaunchPlaybackResult(
        launched: false,
        message: '未找到所属媒体源配置，无法启动外部程序',
      );
    }

    final protocolKind = _detectProtocolKind(effectivePlayer);
    final initialTrack = request.initialTrack;

    // 若用户将外部音频回退或显式指向 MPV / PotPlayer，复用其原生命令行时间轴通道并换算子轨相对进度。
    if (protocolKind == ExternalPlayerKind.mpv ||
        protocolKind == ExternalPlayerKind.potplayer) {
      final cueOffset = initialTrack.cueStartSeconds ?? 0.0;
      final absStart = (cueOffset + request.startSeconds).round();
      final absExact =
          cueOffset +
          (request.exactStartSeconds ?? request.startSeconds.toDouble());
      final tempEpisode = Episode(
        id: initialTrack.episodeId,
        workId: request.work.id,
        seasonNumber: 0,
        episodeNumber: initialTrack.trackNumber,
        category: EpisodeCategory.extra,
        title: initialTrack.title,
      );
      return launch(
        work: request.work,
        episode: tempEpisode,
        variant: initialTrack.variant,
        player: effectivePlayer,
        source: source,
        startSeconds: absStart,
        exactStartSeconds: absExact,
        onProgressUpdate: onTrackProgress == null
            ? null
            : (rawPos, rawDur, {required isFinal}) async {
                final relDur = initialTrack.isCueSubtrack
                    ? ((initialTrack.cueEndSeconds ?? rawDur.toDouble()) -
                              cueOffset)
                          .round()
                    : rawDur;
                final safeDur = relDur > 0 ? relDur : rawDur;
                final relPos = initialTrack.isCueSubtrack
                    ? (rawPos - cueOffset.round()).clamp(0, safeDur)
                    : rawPos;
                final done = PlaybackRecord.computeCompleted(
                  positionSeconds: relPos,
                  durationSeconds: safeDur,
                  isAudio: true,
                );
                await onTrackProgress(
                  initialTrack,
                  done ? safeDur : relPos,
                  safeDur,
                  isCompleted: done,
                  isFinal: isFinal,
                );
              },
      );
    }

    final isFoobar = FoobarBeefwebTracker.isFoobarExecutable(
      effectivePlayer.executablePath,
    );
    FoobarComponentStatusSnapshot? foobarStatus;
    if (isFoobar) {
      foobarStatus = await probeAudioPlayerStatus(
        player: effectivePlayer,
        beefwebPort: request.beefwebPort,
      );
      if (foobarStatus.state == FoobarComponentState.missingComponent &&
          !request.allowWithoutBeefweb) {
        return const LaunchPlaybackResult(
          launched: false,
          requiresBeefwebPrompt: true,
          message: '',
        );
      }
    }

    final sessionEpoch = ++_audioSessionEpoch;
    final useBeefweb = foobarStatus?.isBeefwebReady ?? false;
    final baseUrl =
        beefwebBaseUrlOverride ??
        FoobarBeefwebConfig.buildLoopbackBaseUrl(request.beefwebPort);

    List<String> playlistLoadItems = const [];
    String? fallbackSingleStreamItem;
    String cliLaunchTarget = '';
    String? activeAlbumToken;

    try {
      if (source.kind == MediaSourceKind.local) {
        final localGw = LocalSourceGateway(rootPath: source.location);
        final cueSheet = request.parsedCueSheet;
        if (cueSheet != null && cueSheet.tracks.isNotEmpty) {
          final resolvedByTrack = <int, String>{};
          String? firstAbsAudio;
          for (final t in request.tracks) {
            final absAudio = localGw.resolveAbsolutePath(
              t.variant.relativePath,
            );
            if (!await File(absAudio).exists()) {
              return LaunchPlaybackResult(
                launched: false,
                message: '本地音频文件不存在或已移动：$absAudio',
              );
            }
            firstAbsAudio ??= absAudio;
            if (t.trackNumber != null) {
              resolvedByTrack[t.trackNumber!] = absAudio;
            }
          }
          final cueText = CueSheetSerializer.buildNormalizedCueText(
            sheet: cueSheet,
            resolvedFileByTrackNumber: resolvedByTrack,
            fallbackAlbumTitle: initialTrack.albumTitle.isNotEmpty
                ? initialTrack.albumTitle
                : request.work.title,
          );
          final shadowCuePath = await streamBridge.writeLocalShadowCue(
            seedKey:
                '${request.work.id}_${request.pairedCueVariant?.id ?? initialTrack.variant.id}',
            normalizedCueText: cueText,
          );
          playlistLoadItems = <String>[shadowCuePath];
          fallbackSingleStreamItem = firstAbsAudio;
          cliLaunchTarget = shadowCuePath;
        } else {
          final absTrackPaths = <String>[];
          for (final t in request.tracks) {
            final abs = localGw.resolveAbsolutePath(t.variant.relativePath);
            if (await File(abs).exists()) {
              absTrackPaths.add(abs);
            }
          }
          if (absTrackPaths.isEmpty) {
            final expected = localGw.resolveAbsolutePath(
              initialTrack.variant.relativePath,
            );
            return LaunchPlaybackResult(
              launched: false,
              message: '本地音频文件不存在或已移动：$expected',
            );
          }
          final safeInitIdx = request.initialTrackIndex.clamp(
            0,
            absTrackPaths.length - 1,
          );
          playlistLoadItems = absTrackPaths;
          fallbackSingleStreamItem = absTrackPaths[safeInitIdx];
          cliLaunchTarget = absTrackPaths[safeInitIdx];
        }
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
        final cueSheet = request.parsedCueSheet;

        if (cueSheet != null && cueSheet.tracks.isNotEmpty) {
          final resolvedByTrack = <int, String>{};
          final audioEntries = <VirtualAlbumAudioEntry>[];
          final seenLowerNames = <String>{};
          for (final t in request.tracks) {
            final exposedName = p.basename(t.variant.fileName);
            if (t.trackNumber != null) {
              resolvedByTrack[t.trackNumber!] = exposedName;
            }
            if (seenLowerNames.add(exposedName.toLowerCase())) {
              audioEntries.add(
                VirtualAlbumAudioEntry(
                  entryFileName: exposedName,
                  relativePath: t.variant.relativePath,
                  knownLength: t.variant.fileSize > 0
                      ? t.variant.fileSize
                      : null,
                ),
              );
            }
          }
          final cueText = CueSheetSerializer.buildNormalizedCueText(
            sheet: cueSheet,
            resolvedFileByTrackNumber: resolvedByTrack,
            fallbackAlbumTitle: initialTrack.albumTitle.isNotEmpty
                ? initialTrack.albumTitle
                : request.work.title,
          );
          final reg = await streamBridge.registerCueAlbumSession(
            gateway: readableGw,
            normalizedCueText: cueText,
            audioEntries: audioEntries,
            ownsGateway: true,
            sourceKind: source.kind,
          );
          activeAlbumToken = reg.albumToken;
          playlistLoadItems = <String>[reg.manifestUrl.toString()];
          fallbackSingleStreamItem = reg.primaryAudioUrl.toString();
          cliLaunchTarget = reg.manifestUrl.toString();
        } else if (useBeefweb && request.tracks.length >= 2) {
          final audioEntries = <VirtualAlbumAudioEntry>[
            for (final t in request.tracks)
              VirtualAlbumAudioEntry(
                entryFileName: p.basename(t.variant.fileName),
                relativePath: t.variant.relativePath,
                knownLength: t.variant.fileSize > 0 ? t.variant.fileSize : null,
                title: t.title,
                performer: t.performer,
                durationSeconds: t.resolvedDurationSeconds > 0
                    ? t.resolvedDurationSeconds
                    : -1,
              ),
          ];
          final reg = await streamBridge.registerPlaylistM3u8Session(
            gateway: readableGw,
            audioEntries: audioEntries,
            ownsGateway: true,
            sourceKind: source.kind,
          );
          activeAlbumToken = reg.albumToken;
          final safeIdx = request.initialTrackIndex.clamp(
            0,
            reg.audioUrls.length - 1,
          );
          playlistLoadItems = <String>[reg.manifestUrl.toString()];
          fallbackSingleStreamItem = reg.audioUrls[safeIdx].toString();
          cliLaunchTarget = reg.audioUrls[safeIdx].toString();
        } else {
          final singleReg = await streamBridge.registerSession(
            gateway: readableGw,
            relativePath: initialTrack.variant.relativePath,
            fileName: initialTrack.variant.fileName,
            knownLength: initialTrack.variant.fileSize > 0
                ? initialTrack.variant.fileSize
                : null,
            ownsGateway: true,
            sourceKind: source.kind,
          );
          activeAlbumToken = singleReg.token;
          playlistLoadItems = <String>[singleReg.url.toString()];
          fallbackSingleStreamItem = singleReg.url.toString();
          cliLaunchTarget = singleReg.url.toString();
        }
      }
    } catch (error) {
      if (activeAlbumToken != null) {
        await streamBridge.unregisterAlbumSession(activeAlbumToken);
      }
      final msg = SourceAccessErrorClassifier.toChineseMessage(
        error,
        source.kind,
      );
      return LaunchPlaybackResult(launched: false, message: msg);
    }

    // 分支 A：foobar2000 已安装或已连通 foo_beefweb，走专属播放列表隔离装填 + 子轨定位 + 断点继承 + 跨轨回写。
    if (isFoobar && useBeefweb) {
      Process? spawned;
      if (foobarStatus!.state != FoobarComponentState.connected) {
        try {
          spawned = await _startAndDrainProcess(
            effectivePlayer.executablePath,
            const <String>[],
          );
        } catch (error) {
          if (activeAlbumToken != null) {
            await streamBridge.unregisterAlbumSession(activeAlbumToken);
          }
          return LaunchPlaybackResult(
            launched: false,
            message: '无法启动播放器 ${_displayName(effectivePlayer)}：$error',
          );
        }
      }

      final attachRes = await FoobarBeefwebTracker.attachAlbumAndTrack(
        playlistLoadItems: playlistLoadItems,
        fallbackSingleStreamItem: fallbackSingleStreamItem,
        tracks: request.tracks,
        initialTrackIndex: request.initialTrackIndex,
        startSeconds: request.startSeconds,
        onTrackProgress: onTrackProgress,
        processExitFuture: spawned?.exitCode,
        isCancelled: () => _audioSessionEpoch != sessionEpoch,
        onHeartbeat: activeAlbumToken == null
            ? null
            : () => streamBridge.touchAlbumSession(activeAlbumToken!),
        keepRemoteSessionAlive: activeAlbumToken != null,
        baseUrl: baseUrl,
      );

      if (!attachRes.attachedToBeefweb) {
        // 若 DLL 存在但组件服务未开启，兜底补发一次标准命令行播放请求确保有声起播。
        try {
          final fallbackArgs = sanitizeAndOrderPlayerArguments(
            leadingOptions: const [],
            argumentsTemplate: effectivePlayer.argumentsTemplate,
            targetUrlOrPath: cliLaunchTarget,
          );
          await _startAndDrainProcess(
            effectivePlayer.executablePath,
            fallbackArgs,
          );
        } catch (error) {
          if (activeAlbumToken != null) {
            await streamBridge.unregisterAlbumSession(activeAlbumToken);
          }
          return LaunchPlaybackResult(
            launched: false,
            message: '无法启动播放器 ${_displayName(effectivePlayer)}：$error',
          );
        }
      }

      _bindDeferredStreamCleanup(
        trackingDone: attachRes.trackingDone,
        albumToken: activeAlbumToken,
      );

      final trackCountHint = request.tracks.length > 1
          ? '（共 ${request.tracks.length} 首曲目）'
          : '';
      final resumeHint = attachRes.attachedToBeefweb && request.startSeconds > 0
          ? ' · 从 ${PlaybackRecord.formatClock(request.startSeconds)} 续播'
          : '';
      return LaunchPlaybackResult(
        launched: true,
        message:
            '已移交 ${_displayName(effectivePlayer)}$trackCountHint$resumeHint',
      );
    }

    // 分支 B：未安装 foo_beefweb（用户选择仅单向拉起）或其他自定义外部音频程序。
    Process process;
    try {
      final cliArgs = sanitizeAndOrderPlayerArguments(
        leadingOptions: const [],
        argumentsTemplate: effectivePlayer.argumentsTemplate,
        targetUrlOrPath: cliLaunchTarget,
      );
      process = await _startAndDrainProcess(
        effectivePlayer.executablePath,
        cliArgs,
      );
    } catch (error) {
      if (activeAlbumToken != null) {
        await streamBridge.unregisterAlbumSession(activeAlbumToken);
      }
      return LaunchPlaybackResult(
        launched: false,
        message: '无法启动播放器 ${_displayName(effectivePlayer)}：$error',
      );
    }

    if (activeAlbumToken != null) {
      final startedAt = DateTime.now();
      unawaited(
        process.exitCode
            .then((_) async {
              final exitedFast =
                  DateTime.now().difference(startedAt) <
                  const Duration(seconds: 4);
              // 单实例转发秒退时保留远程流交由空闲回收器托管，独立窗口自然关闭时立即释放。
              if (!exitedFast && _audioSessionEpoch == sessionEpoch) {
                await streamBridge.unregisterAlbumSession(activeAlbumToken!);
              }
            })
            .catchError((Object error) {
              developer.log(
                '等待无组件外部音频进程退出忽略',
                name: 'konata.real_external_player_launcher',
                error: error,
              );
            }),
      );
    }

    final manualSeekHint = request.startSeconds > 0
        ? '（上次进度：${initialTrack.title} ${PlaybackRecord.formatClock(request.startSeconds)}）'
        : '';
    return LaunchPlaybackResult(
      launched: true,
      message: '已启动 ${_displayName(effectivePlayer)}$manualSeekHint',
    );
  }

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
        message: '未检测到可用的外部播放器，请在「设置 -> 外部调用」中配置路径',
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
      process = await _startAndDrainProcess(
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

  Future<Process> _startAndDrainProcess(
    String executablePath,
    List<String> arguments,
  ) async {
    final process = await _processStarter(executablePath, arguments);
    // 必须在 Process.start 返回后的第一时间持续排空 stdout / stderr 匿名管道，
    // 防止播放器日志写满 Windows 4KB 缓冲区引发子进程阻塞死锁。
    unawaited(
      process.stdout.drain<void>().catchError((Object error) {
        developer.log(
          '排空外部进程标准输出忽略',
          name: 'konata.real_external_player_launcher',
          error: error,
        );
      }),
    );
    unawaited(
      process.stderr.drain<void>().catchError((Object error) {
        developer.log(
          '排空外部进程错误输出忽略',
          name: 'konata.real_external_player_launcher',
          error: error,
        );
      }),
    );
    return process;
  }

  void _bindDeferredStreamCleanup({
    required Future<bool> trackingDone,
    required String? albumToken,
  }) {
    if (albumToken == null) return;
    unawaited(
      trackingDone
          .then((unregisterImmediately) async {
            if (unregisterImmediately) {
              await streamBridge.unregisterAlbumSession(albumToken);
            }
          })
          .catchError((Object error) async {
            developer.log(
              '外部音频追踪收尾清理记录',
              name: 'konata.real_external_player_launcher',
              error: error,
            );
            await streamBridge.unregisterAlbumSession(albumToken);
          }),
    );
  }

  String _displayName(ExternalPlayerConfig player) {
    if (FoobarBeefwebTracker.isFoobarExecutable(player.executablePath)) {
      return 'foobar2000';
    }
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
            baseUrl:
                beefwebBaseUrlOverride ?? FoobarBeefwebTracker.defaultBaseUrl,
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
