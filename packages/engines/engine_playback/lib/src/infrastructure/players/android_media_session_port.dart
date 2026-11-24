import 'dart:typed_data';

/// Android 原生媒体会话与系统通知栏卡片双向通信端口（纯 Dart 抽象）。
abstract interface class AndroidMediaSessionPort {
  /// 绑定系统锁屏、通知栏与蓝牙耳机媒体按键回调。
  void bindCallbacks({
    required void Function() onPlay,
    required void Function() onPause,
    required void Function() onTogglePlayPause,
    required void Function() onPrevious,
    required void Function() onNext,
    required void Function(double positionSeconds) onSeekToSeconds,
    required void Function() onStop,
  });

  /// 按变更去重与节流策略同步当前音轨元数据、封面及播放进度至原生通知栏。
  Future<void> syncSession({
    required String trackId,
    required String title,
    required String artist,
    required String album,
    required double durationSeconds,
    required double positionSeconds,
    required bool isPlaying,
    required String coverKey,
    Uint8List? coverBytes,
    bool forcePositionSync = false,
  });

  /// 停止并移除系统通知栏媒体卡片。
  Future<void> stopSession();

  /// 释放通道回调引用。
  void dispose();
}

/// 纯 Dart Android 媒体会话去重与节流调度状态机，供平台实现层复用。
class AndroidMediaSessionSyncFilter {
  String _lastMetaSignature = '';
  bool? _lastIsPlaying;
  String _lastSentCoverKey = '';
  int _lastSentPositionMs = -1;
  DateTime? _lastSyncAt;
  bool _sessionActive = false;

  /// 最近一次允许下发的载荷快照（供测试核验）。
  Map<String, Object?>? lastBuiltPayload;

  /// 若本次同步相对上次状态存在有效变更或进度漂移，构建下发载荷并返回；否则返回 `null` 跳过冗余跨通道调用。
  Map<String, Object?>? buildPayloadIfChanged({
    required String trackId,
    required String title,
    required String artist,
    required String album,
    required double durationSeconds,
    required double positionSeconds,
    required bool isPlaying,
    required String coverKey,
    Uint8List? coverBytes,
    bool forcePositionSync = false,
    DateTime? nowOverride,
  }) {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      return null;
    }

    final durationMs = durationSeconds > 0
        ? (durationSeconds * 1000.0).round()
        : 0;
    final positionMs = positionSeconds > 0
        ? (positionSeconds * 1000.0).round()
        : 0;
    final now = nowOverride ?? DateTime.now();

    final roundedDurationBucket = durationMs ~/ 500;
    final metaSig =
        '$trackId|$cleanTitle|$artist|$album|$roundedDurationBucket|$coverKey';
    final coverNeedsPush =
        coverKey.isNotEmpty &&
        coverBytes != null &&
        coverBytes.isNotEmpty &&
        coverKey != _lastSentCoverKey;
    final metaOrPlayChanged =
        !_sessionActive ||
        metaSig != _lastMetaSignature ||
        isPlaying != _lastIsPlaying ||
        coverNeedsPush;

    var positionDrifted = forcePositionSync;
    if (!positionDrifted && _lastSyncAt != null) {
      final elapsedMs = now.difference(_lastSyncAt!).inMilliseconds;
      final expectedPosMs = (_lastIsPlaying ?? false)
          ? _lastSentPositionMs + elapsedMs
          : _lastSentPositionMs;
      if ((positionMs - expectedPosMs).abs() >= 1800 || elapsedMs >= 5000) {
        positionDrifted = true;
      }
    }

    if (!metaOrPlayChanged && !positionDrifted) {
      return null;
    }

    final payload = <String, Object?>{
      'title': cleanTitle,
      'artist': artist,
      'album': album,
      'durationMs': durationMs,
      'positionMs': positionMs,
      'isPlaying': isPlaying,
      'coverKey': coverKey,
      if (coverNeedsPush) 'coverBytes': coverBytes,
    };

    _sessionActive = true;
    _lastMetaSignature = metaSig;
    _lastIsPlaying = isPlaying;
    _lastSentPositionMs = positionMs;
    _lastSyncAt = now;
    if (coverNeedsPush) {
      _lastSentCoverKey = coverKey;
    } else if (coverKey.isEmpty) {
      _lastSentCoverKey = '';
    }
    lastBuiltPayload = payload;
    return payload;
  }

  /// 判断当前是否处于活跃会话且需要通知原生停止。
  bool markStopped() {
    final wasActive = _sessionActive || _lastMetaSignature.isNotEmpty;
    _sessionActive = false;
    _lastMetaSignature = '';
    _lastIsPlaying = null;
    _lastSentCoverKey = '';
    _lastSentPositionMs = -1;
    _lastSyncAt = null;
    lastBuiltPayload = null;
    return wasActive;
  }
}
