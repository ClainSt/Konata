import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../composition/platform_composition.dart';
import '../../domain/matching/supplementary_subclassifier.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/models/playback_record.dart';
import '../../domain/models/work.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/cue_variant_resolver.dart';
import '../../domain/repositories/desktop_relay_service.dart';
import '../../infrastructure/players/audio_art_extractor.dart';
import '../providers/library_providers.dart';
import '../providers/platform_capability.dart';
import '../providers/playback_providers.dart';
import 'audio_playback_notifier.dart';
import 'playback_preferences_provider.dart';
import 'unified_playback_coordinator.dart';
import 'video_playback_controller.dart';

/// 视频播放统一分发决策结果（保持 `application -> presentation` 严格单向隔离）。
sealed class VideoDispatchDecision {
  const VideoDispatchDecision();
}

/// 分发决策：暂停纯音频后由表现层推入内置高保真视频播放器页。
final class OpenBuiltinVideoDecision extends VideoDispatchDecision {
  /// 创建内置播放器启动决策。
  const OpenBuiltinVideoDecision(this.request);

  /// 完整视频播放启动请求。
  final VideoLaunchRequest request;
}

/// 分发决策：已交由桌面接力程序或已产生回退接力的执行结果。
final class LaunchedExternalVideoDecision extends VideoDispatchDecision {
  /// 创建桌面接力执行结果决策。
  const LaunchedExternalVideoDecision(this.result);

  /// 桌面接力拉起结果。
  final LaunchPlaybackResult result;
}

/// 全局统一音视频播放分发器：
/// 根据全局偏好或单次右键覆写，路由至内置高保真 `libmpv` 或桌面接力程序。
class PlaybackDispatcher {
  /// 创建统一播放分发器。
  const PlaybackDispatcher(this._ref);

  final Ref _ref;

  /// 分发播放指定剧集物理变体（无 Flutter UI / Navigator 依赖）。
  Future<VideoDispatchDecision> dispatchVideoVariant({
    required WorkDetailBundle bundle,
    required Episode episode,
    required MediaVariant variant,
    int startSeconds = 0,
    PreferredPlaybackEngine? overrideEngine,
    String? explicitTargetId,
  }) async {
    final source = bundle.sourcesById[variant.sourceId];
    final sourceType = source?.kind ?? MediaSourceKind.local;
    final mainEpisodeCount = bundle.episodes
        .where((e) => e.category == EpisodeCategory.main)
        .length;

    final prefs = _ref.read(playbackPreferencesProvider);
    final effectiveEngine = KonataPlatform.isAndroid
        ? PreferredPlaybackEngine.builtinLibmpv
        : (explicitTargetId != null
              ? PreferredPlaybackEngine.desktopRelay
              : (overrideEngine ?? prefs.defaultVideoEngine));

    if (effectiveEngine == PreferredPlaybackEngine.builtinLibmpv) {
      final runtime = await _ref.read(mpvRuntimeVersionsProvider.future);
      if (runtime.isAvailable || KonataPlatform.isAndroid) {
        // 互斥暂停全局迷你音频播放器并释放后台外部音频会话声卡占用。
        await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();
        unawaited(
          _ref
              .read(desktopRelayGatewayProvider)
              ?.stopActiveExternalAudioSession(
                beefwebPort: prefs.foobarBeefwebPort,
              ),
        );

        final request = VideoLaunchRequest(
          work: bundle.work,
          episode: episode,
          variant: variant,
          bundle: bundle,
          source: source,
          startSeconds: startSeconds.toDouble(),
        );
        return OpenBuiltinVideoDecision(request);
      }
      // 内嵌 libmpv 不可用时优雅降级至桌面接力程序。
      final fallbackResult = await _ref
          .read(playbackCoordinatorProvider)
          .playVariant(
            work: bundle.work,
            episode: episode,
            variant: variant,
            sourceType: sourceType,
            source: source,
            targetId: explicitTargetId,
            startSeconds: startSeconds,
            mainEpisodeCount: mainEpisodeCount,
          );
      return LaunchedExternalVideoDecision(
        LaunchPlaybackResult(
          launched: fallbackResult.launched,
          message: '内置播放器运行时未就绪，已自动回退外部播放器：${fallbackResult.message}',
        ),
      );
    }

    unawaited(
      _ref
          .read(desktopRelayGatewayProvider)
          ?.stopActiveExternalAudioSession(
            beefwebPort: prefs.foobarBeefwebPort,
          ),
    );
    final extResult = await _ref
        .read(playbackCoordinatorProvider)
        .playVariant(
          work: bundle.work,
          episode: episode,
          variant: variant,
          sourceType: sourceType,
          source: source,
          targetId: explicitTargetId,
          startSeconds: startSeconds,
          mainEpisodeCount: mainEpisodeCount,
        );
    return LaunchedExternalVideoDecision(extResult);
  }

  /// 分发播放指定 CD / 无损音频资产（覆盖内置引擎与桌面专辑/分轨双向接力）。
  Future<LaunchPlaybackResult> playCdVariant({
    required Work work,
    required MediaVariant variant,
    required List<MediaVariant> cdPlaylist,
    required Map<String, MediaSource> sourcesById,
    PreferredPlaybackEngine? overrideEngine,
    String? explicitTargetId,
    bool expandImmersive = false,
    int? initialCueTrackNumber,
    int? startSeconds,
    double? exactStartSeconds,
    bool forceAllowWithoutBeefweb = false,
  }) async {
    final source = sourcesById[variant.sourceId];
    final prefs = _ref.read(playbackPreferencesProvider);
    final effectiveEngine = KonataPlatform.isAndroid
        ? PreferredPlaybackEngine.builtinLibmpv
        : (explicitTargetId != null
              ? PreferredPlaybackEngine.desktopRelay
              : (overrideEngine ?? prefs.defaultAudioEngine));

    if (effectiveEngine == PreferredPlaybackEngine.builtinLibmpv) {
      final runtime = await _ref.read(mpvRuntimeVersionsProvider.future);
      if (runtime.isAvailable || KonataPlatform.isAndroid) {
        if (_ref.read(activeVideoSessionProvider).isActive) {
          await _ref.read(activeVideoSessionProvider.notifier).closeVideo();
        }
        final effectiveList = cdPlaylist.isEmpty ? [variant] : cdPlaylist;
        final initialOffset =
            exactStartSeconds ??
            (startSeconds != null && startSeconds > 0
                ? startSeconds.toDouble()
                : 0.0);
        await _ref
            .read(audioPlaybackProvider.notifier)
            .playCdCollection(
              work: work,
              cdVariants: effectiveList,
              initialVariant: variant,
              sourcesById: sourcesById,
              initialCueTrackNumber: initialCueTrackNumber,
              initialTrackOffsetSeconds: initialOffset,
            );
        if (expandImmersive || !prefs.audioFloatingMiniEnabled) {
          _ref.read(immersiveAudioExpandedProvider.notifier).state = true;
        }
        return const LaunchPlaybackResult(launched: true, message: '');
      }
    }

    // 拉起桌面接力音频程序前，互斥释放内置视频与内置迷你音频持有的声卡设备（兼容 WASAPI 独占）。
    final activeVidReq = _ref.read(activeVideoSessionProvider).request;
    if (activeVidReq != null) {
      await _ref.read(activeVideoSessionProvider.notifier).closeVideo();
    }
    await _ref.read(audioPlaybackProvider.notifier).pauseForVideoSession();

    final effectivePlaylist = cdPlaylist.isEmpty ? [variant] : cdPlaylist;
    final relayBuild = await _buildExternalAlbumRelayRequest(
      work: work,
      variant: variant,
      cdPlaylist: effectivePlaylist,
      source: source,
      explicitTargetId: explicitTargetId,
      initialCueTrackNumber: initialCueTrackNumber,
      explicitStartSeconds: startSeconds,
      explicitExactStartSeconds: exactStartSeconds,
      beefwebPort: prefs.foobarBeefwebPort,
      allowWithoutBeefweb:
          forceAllowWithoutBeefweb || prefs.skipFoobarBeefwebPrompt,
    );
    if (relayBuild.errorResult != null) {
      return relayBuild.errorResult!;
    }

    return _ref
        .read(playbackCoordinatorProvider)
        .playCdAlbumRelay(request: relayBuild.request!);
  }

  /// 将当前活跃的内置流光音频会话带曲目与精确秒数无缝热移交至桌面外部音频播放器。
  Future<LaunchPlaybackResult> relayActiveBuiltinAudioToDesktop({
    bool forceAllowWithoutBeefweb = false,
  }) async {
    final audioState = _ref.read(audioPlaybackProvider);
    final item = audioState.currentItem;
    if (!audioState.isActive || item == null) {
      return const LaunchPlaybackResult(
        launched: false,
        message: '当前没有正在播放的音频曲目',
      );
    }

    final exactPos = audioState.positionSeconds;
    final posSec = exactPos > 0 ? exactPos.floor() : 0;
    final notifier = _ref.read(audioPlaybackProvider.notifier);
    if (audioState.isPlaying) {
      await notifier.setPlaying(false);
    }

    WorkDetailBundle? bundle;
    try {
      bundle = await _ref.read(workDetailBundleProvider(item.work.id).future);
    } catch (error) {
      developer.log(
        '读取作品详情用于外部音频热接力忽略',
        name: 'konata.playback_dispatcher',
        error: error,
      );
    }

    final cdList = (bundle != null && bundle.cdVariants.isNotEmpty)
        ? bundle.cdVariants
        : <MediaVariant>[
            for (final q in audioState.queue) q.variant,
            ?item.pairedCueVariant,
          ];
    final sourcesMap = <String, MediaSource>{
      ...?bundle?.sourcesById,
      if (item.source != null) item.source!.id: item.source!,
    };

    final targetVariant = item.pairedCueVariant ?? item.variant;
    final res = await playCdVariant(
      work: item.work,
      variant: targetVariant,
      cdPlaylist: cdList,
      sourcesById: sourcesMap,
      overrideEngine: PreferredPlaybackEngine.desktopRelay,
      initialCueTrackNumber: item.isCueTrack ? item.trackNumber : null,
      startSeconds: posSec,
      exactStartSeconds: exactPos,
      forceAllowWithoutBeefweb: forceAllowWithoutBeefweb,
    );

    if (res.launched) {
      await notifier.stopAndClose();
    }
    return res;
  }

  Future<
    ({
      ExternalAudioAlbumRelayRequest? request,
      LaunchPlaybackResult? errorResult,
    })
  >
  _buildExternalAlbumRelayRequest({
    required Work work,
    required MediaVariant variant,
    required List<MediaVariant> cdPlaylist,
    required MediaSource? source,
    required String? explicitTargetId,
    required int? initialCueTrackNumber,
    required int? explicitStartSeconds,
    required double? explicitExactStartSeconds,
    required int beefwebPort,
    required bool allowWithoutBeefweb,
  }) async {
    final repo = _ref.read(libraryRepositoryProvider);
    List<PlaybackRecord> workAudioRecords = const [];
    try {
      final all = await repo.getPlaybacksByWork(work.id);
      workAudioRecords = all
          .where((r) => r.isAudioRecord)
          .toList(growable: false);
    } catch (error) {
      developer.log(
        '查询作品既有音频记录用于断点恢复忽略',
        name: 'konata.playback_dispatcher',
        error: error,
      );
    }
    final recordByEpId = <String, PlaybackRecord>{
      for (final r in workAudioRecords) r.episodeId: r,
    };

    final normDir = p.posix.dirname(variant.relativePath.replaceAll('\\', '/'));
    final audiosInDir = cdPlaylist
        .where(
          (v) =>
              v.sourceId == variant.sourceId &&
              AudioPlaybackNotifier.isPlayableAudioFile(v.fileName) &&
              p.posix.dirname(v.relativePath.replaceAll('\\', '/')) == normDir,
        )
        .toList(growable: false);
    final cuesInDir = cdPlaylist
        .where(
          (v) =>
              v.sourceId == variant.sourceId &&
              AudioPlaybackNotifier.isCueSheetFile(v.fileName) &&
              p.posix.dirname(v.relativePath.replaceAll('\\', '/')) == normDir,
        )
        .toList(growable: false);

    MediaVariant? pairedCue;
    if (AudioPlaybackNotifier.isCueSheetFile(variant.fileName)) {
      pairedCue = variant;
    } else if (cuesInDir.isNotEmpty) {
      pairedCue = CueVariantResolver.matchCueVariantForAudio(
        audioVariant: variant,
        cueVariantsInDir: cuesInDir,
        audioVariantsInDir: audiosInDir,
      );
    }

    if (pairedCue != null) {
      if (source == null) {
        return (
          request: null,
          errorResult: const LaunchPlaybackResult(
            launched: false,
            message: 'CUE 所属媒体源不可用，无法定位音频文件',
          ),
        );
      }
      CueSheet? sheet;
      try {
        sheet = await AudioAssetExtractor.loadCueSheet(
          source: source,
          cueRelativePath: pairedCue.relativePath,
          gatewayFactory: _ref.read(mediaSourceGatewayFactoryProvider),
          knownFileSize: pairedCue.fileSize > 0 ? pairedCue.fileSize : null,
          legacyDecoder: _ref.read(legacyCodePageDecoderProvider),
        );
      } catch (error) {
        if (AudioPlaybackNotifier.isCueSheetFile(variant.fileName)) {
          return (
            request: null,
            errorResult: LaunchPlaybackResult(
              launched: false,
              message: 'CUE 读取失败：$error',
            ),
          );
        }
        developer.log(
          '自动配对读取同目录 CUE 失败，降级单文件音频启动',
          name: 'konata.playback_dispatcher',
          error: error,
        );
      }

      if (sheet == null || sheet.tracks.isEmpty) {
        if (AudioPlaybackNotifier.isCueSheetFile(variant.fileName)) {
          return (
            request: null,
            errorResult: const LaunchPlaybackResult(
              launched: false,
              message: '无法解析 CUE 音轨清单',
            ),
          );
        }
      } else {
        final folderName = p.posix.basename(normDir);
        final albumTitle = sheet.title.trim().isNotEmpty
            ? sheet.title.trim()
            : ((folderName.isNotEmpty && folderName != '.')
                  ? folderName
                  : work.title);
        final builtTracks = <ExternalAudioTrackDescriptor>[];
        for (final track in sheet.tracks) {
          final targetAudio = CueVariantResolver.resolve(
            cueVariant: pairedCue,
            cueTrack: track,
            audioVariantsInDir: audiosInDir,
            fallbackInitial: variant,
          );
          if (targetAudio == null) continue;
          final rawTitle = track.title.trim();
          final stripped =
              SupplementarySubclassifier.stripAudioTrackNumberPrefix(
                rawTitle,
              ).cleanTitle.trim();
          final cleanTitle = stripped.isNotEmpty
              ? stripped
              : (rawTitle.isNotEmpty ? rawTitle : '曲目 ${track.trackNumber}');
          final recId =
              '${PlaybackRecord.audioEpisodePrefix}${pairedCue.id}::track_${track.trackNumber}';
          final savedDur = recordByEpId[recId]?.durationSeconds;
          builtTracks.add(
            ExternalAudioTrackDescriptor(
              recordId: recId,
              episodeId: recId,
              variant: targetAudio,
              title: cleanTitle,
              performer: track.performer.trim().isNotEmpty
                  ? track.performer.trim()
                  : sheet.performer.trim(),
              albumTitle: albumTitle,
              trackNumber: track.trackNumber,
              isCueSubtrack: true,
              cueStartSeconds: track.startSeconds,
              cueEndSeconds: track.endSeconds,
              knownDurationSeconds: (savedDur != null && savedDur > 0)
                  ? savedDur
                  : null,
            ),
          );
        }

        if (builtTracks.isEmpty) {
          return (
            request: null,
            errorResult: const LaunchPlaybackResult(
              launched: false,
              message: 'CUE 引用的音频文件不存在或无法唯一确定',
            ),
          );
        }

        final cueDecision = _selectInitialCueTrackAndResume(
          tracks: builtTracks,
          explicitTrackNumber: initialCueTrackNumber,
          explicitStartSeconds: explicitStartSeconds,
          recordByEpId: recordByEpId,
          workAudioRecords: workAudioRecords,
        );

        return (
          request: ExternalAudioAlbumRelayRequest(
            work: work,
            tracks: builtTracks,
            initialTrackIndex: cueDecision.trackIndex,
            startSeconds: cueDecision.startSeconds,
            exactStartSeconds: explicitExactStartSeconds,
            pairedCueVariant: pairedCue,
            parsedCueSheet: sheet,
            source: source,
            targetId: explicitTargetId,
            beefwebPort: beefwebPort,
            allowWithoutBeefweb: allowWithoutBeefweb,
          ),
          errorResult: null,
        );
      }
    }

    // 散装单曲或多曲目专辑分组。
    final playableInSource = cdPlaylist
        .where(
          (v) =>
              v.sourceId == variant.sourceId &&
              AudioPlaybackNotifier.isPlayableAudioFile(v.fileName),
        )
        .toList(growable: false);
    List<MediaVariant> albumVariants;
    if (playableInSource.isEmpty) {
      albumVariants = <MediaVariant>[variant];
    } else {
      final summary = SupplementarySubclassifier.groupCdVariants(
        playableInSource,
      );
      final targetGroupKey = summary.byVariantId[variant.id]?.albumKey;
      if (targetGroupKey != null && targetGroupKey.isNotEmpty) {
        albumVariants = playableInSource
            .where((v) => summary.byVariantId[v.id]?.albumKey == targetGroupKey)
            .toList(growable: false);
      } else {
        albumVariants = audiosInDir.isNotEmpty
            ? audiosInDir
            : <MediaVariant>[variant];
      }
    }
    if (!albumVariants.any((v) => v.id == variant.id)) {
      albumVariants = <MediaVariant>[variant, ...albumVariants];
    }

    final folderName = p.posix.basename(normDir);
    final albumTitle = (folderName.isNotEmpty && folderName != '.')
        ? folderName
        : work.title;
    final builtTracks = <ExternalAudioTrackDescriptor>[];
    var targetIdx = 0;
    for (var i = 0; i < albumVariants.length; i++) {
      final v = albumVariants[i];
      if (v.id == variant.id) {
        targetIdx = i;
      }
      final stem = p.basenameWithoutExtension(v.fileName);
      final parsed = SupplementarySubclassifier.stripAudioTrackNumberPrefix(
        stem,
      );
      final recId = '${PlaybackRecord.audioEpisodePrefix}${v.id}';
      final prevRec = recordByEpId[recId];
      builtTracks.add(
        ExternalAudioTrackDescriptor(
          recordId: recId,
          episodeId: recId,
          variant: v,
          title: parsed.cleanTitle.isNotEmpty ? parsed.cleanTitle : stem,
          albumTitle: albumTitle,
          trackNumber: parsed.trackNumber ?? (i + 1),
          knownDurationSeconds: prevRec != null && prevRec.durationSeconds > 0
              ? prevRec.durationSeconds
              : null,
        ),
      );
    }

    final chosenTrack = builtTracks[targetIdx];
    final savedRec = recordByEpId[chosenTrack.episodeId];
    final effectiveStart =
        explicitStartSeconds ??
        ((savedRec != null && savedRec.hasResumableProgress)
            ? savedRec.positionSeconds
            : 0);

    return (
      request: ExternalAudioAlbumRelayRequest(
        work: work,
        tracks: builtTracks,
        initialTrackIndex: targetIdx,
        startSeconds: effectiveStart,
        exactStartSeconds: explicitExactStartSeconds,
        source: source,
        targetId: explicitTargetId,
        beefwebPort: beefwebPort,
        allowWithoutBeefweb: allowWithoutBeefweb,
      ),
      errorResult: null,
    );
  }

  ({int trackIndex, int startSeconds}) _selectInitialCueTrackAndResume({
    required List<ExternalAudioTrackDescriptor> tracks,
    required int? explicitTrackNumber,
    required int? explicitStartSeconds,
    required Map<String, PlaybackRecord> recordByEpId,
    required List<PlaybackRecord> workAudioRecords,
  }) {
    if (explicitTrackNumber != null) {
      final hitIdx = tracks.indexWhere(
        (t) => t.trackNumber == explicitTrackNumber,
      );
      final safeIdx = hitIdx >= 0 ? hitIdx : 0;
      final saved = recordByEpId[tracks[safeIdx].episodeId];
      final start =
          explicitStartSeconds ??
          ((saved != null && saved.hasResumableProgress)
              ? saved.positionSeconds
              : 0);
      return (trackIndex: safeIdx, startSeconds: start);
    }

    if (explicitStartSeconds != null) {
      return (trackIndex: 0, startSeconds: explicitStartSeconds);
    }

    // 详情页直接点击整轨专辑卡片时：优先接续该碟最近一条未听完子轨，若该子轨刚听完则自动推进到下一未听子轨。
    final trackIndexByEpId = <String, int>{
      for (var i = 0; i < tracks.length; i++) tracks[i].episodeId: i,
    };
    for (final rec in workAudioRecords) {
      final idx = trackIndexByEpId[rec.episodeId];
      if (idx == null) continue;
      if (rec.hasResumableProgress) {
        return (trackIndex: idx, startSeconds: rec.positionSeconds);
      }
      if (rec.isCompleted && idx + 1 < tracks.length) {
        final nextSaved = recordByEpId[tracks[idx + 1].episodeId];
        if (nextSaved == null || !nextSaved.isCompleted) {
          return (
            trackIndex: idx + 1,
            startSeconds: (nextSaved != null && nextSaved.hasResumableProgress)
                ? nextSaved.positionSeconds
                : 0,
          );
        }
      }
      break;
    }

    return (trackIndex: 0, startSeconds: 0);
  }
}

/// 全局统一音视频播放分发器 Provider。
final playbackDispatcherProvider = Provider<PlaybackDispatcher>((ref) {
  return PlaybackDispatcher(ref);
});
