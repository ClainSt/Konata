import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../../domain/models/external_player_config.dart';
import '../../domain/models/relay_target_descriptor.dart';
import '../../domain/repositories/desktop_relay_service.dart';
import '../../domain/repositories/external_player_launcher.dart';
import 'desktop_external_player_store.dart';

/// Windows 桌面专属外部程序接力网关（完整封装 MPV / PotPlayer / 外部音频路由，零泄漏至 Android 入口）。
class WindowsDesktopRelayGateway implements DesktopRelayGateway {
  /// 创建桌面外部程序接力网关。
  const WindowsDesktopRelayGateway({
    required this.store,
    required this.launcher,
  });

  final DesktopExternalPlayerStore store;
  final ExternalPlayerLauncher launcher;

  @override
  Future<List<RelayTargetDescriptor>> listVideoTargets() async {
    final all = await store.getExternalPlayers();
    return [
      for (final p in all)
        if (p.kind == ExternalPlayerKind.mpv ||
            p.kind == ExternalPlayerKind.potplayer ||
            p.kind == ExternalPlayerKind.custom)
          RelayTargetDescriptor(
            id: p.id,
            name: p.name,
            kindKey: p.kind.name,
            isDefault: p.isDefault,
            configured: p.executablePath.trim().isNotEmpty,
          ),
    ];
  }

  @override
  Future<LaunchPlaybackResult> launchVideo({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    String? preferredKindKey,
    int startSeconds = 0,
    int? mainEpisodeCount,
    PlaybackProgressCallback? onProgressUpdate,
  }) async {
    final players = await store.getExternalPlayers();
    final target = _resolveVideoPlayer(
      players,
      targetId: targetId,
      preferredKindKey: preferredKindKey,
    );
    return launcher.launch(
      work: work,
      episode: episode,
      variant: variant,
      player: target,
      source: source,
      startSeconds: startSeconds,
      mainEpisodeCount: mainEpisodeCount,
      onProgressUpdate: onProgressUpdate,
    );
  }

  @override
  Future<LaunchPlaybackResult> launchAudio({
    required WorkRecord work,
    required EpisodeSummaryView episode,
    required MediaVariantRecord variant,
    MediaSourceView? source,
    String? targetId,
    int startSeconds = 0,
    double? exactStartSeconds,
    PlaybackProgressCallback? onProgressUpdate,
  }) async {
    final players = await store.getExternalPlayers();
    final target = _resolveAudioPlayer(players, targetId: targetId);
    return launcher.launch(
      work: work,
      episode: episode,
      variant: variant,
      player: target,
      source: source,
      startSeconds: startSeconds,
      exactStartSeconds: exactStartSeconds,
      onProgressUpdate: onProgressUpdate,
    );
  }

  @override
  Future<LaunchPlaybackResult> launchAudioAlbum(
    ExternalAudioAlbumRelayRequest request, {
    ExternalAudioProgressCallback? onTrackProgress,
  }) async {
    final players = await store.getExternalPlayers();
    final target = _resolveAudioPlayer(players, targetId: request.targetId);
    return launcher.launchAudioAlbum(
      request: request,
      player: target,
      onTrackProgress: onTrackProgress,
    );
  }

  @override
  Future<FoobarComponentStatusSnapshot> probeAudioPlayerStatus({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) async {
    final players = await store.getExternalPlayers();
    ExternalPlayerConfig? audioPlayer;
    for (final p in players) {
      if (p.kind == ExternalPlayerKind.audioPlayer &&
          p.executablePath.trim().isNotEmpty) {
        audioPlayer = p;
        break;
      }
    }
    return launcher.probeAudioPlayerStatus(
      player: audioPlayer,
      beefwebPort: beefwebPort,
    );
  }

  @override
  Future<void> stopActiveExternalAudioSession({
    int beefwebPort = FoobarBeefwebConfig.defaultPort,
  }) {
    return launcher.stopActiveExternalAudioSession(beefwebPort: beefwebPort);
  }

  ExternalPlayerConfig? _resolveVideoPlayer(
    List<ExternalPlayerConfig> players, {
    String? targetId,
    String? preferredKindKey,
  }) {
    if (targetId != null && targetId.isNotEmpty) {
      for (final p in players) {
        if (p.id == targetId && p.executablePath.trim().isNotEmpty) {
          return p;
        }
      }
    }
    final configured = players
        .where(
          (p) =>
              (p.kind == ExternalPlayerKind.mpv ||
                  p.kind == ExternalPlayerKind.potplayer ||
                  p.kind == ExternalPlayerKind.custom) &&
              p.executablePath.trim().isNotEmpty,
        )
        .toList(growable: false);
    if (configured.isEmpty) return null;
    if (preferredKindKey != null && preferredKindKey.isNotEmpty) {
      for (final p in configured) {
        if (p.kind.name == preferredKindKey) return p;
      }
    }
    for (final p in configured) {
      if (p.isDefault) return p;
    }
    return configured.first;
  }

  ExternalPlayerConfig? _resolveAudioPlayer(
    List<ExternalPlayerConfig> players, {
    String? targetId,
  }) {
    if (targetId != null && targetId.isNotEmpty) {
      for (final p in players) {
        if (p.id == targetId && p.executablePath.trim().isNotEmpty) {
          return p;
        }
      }
    }
    for (final p in players) {
      if (p.kind == ExternalPlayerKind.audioPlayer &&
          p.executablePath.trim().isNotEmpty) {
        return p;
      }
    }
    return _resolveVideoPlayer(players);
  }
}
