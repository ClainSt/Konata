import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 原生媒体会话与系统通知栏卡片双向通信桥（连接 `KonataMediaPlaybackService`）。
class AndroidMediaSessionBridge {
  /// 创建媒体会话通道桥。
  AndroidMediaSessionBridge({
    MethodChannel? channel,
    bool Function()? isSupported,
  }) : _channel = channel ?? const MethodChannel('ccplayer/media_session'),
       _isSupported =
           isSupported ??
           (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool Function() _isSupported;

  bool _handlerBound = false;
  VoidCallback? _onPlay;
  VoidCallback? _onPause;
  VoidCallback? _onTogglePlayPause;
  VoidCallback? _onPrevious;
  VoidCallback? _onNext;
  ValueChanged<double>? _onSeekToSeconds;
  VoidCallback? _onStop;

  String _lastMetaSignature = '';
  bool? _lastIsPlaying;
  String _lastSentCoverKey = '';
  int _lastSentPositionMs = -1;
  DateTime? _lastSyncAt;
  bool _sessionActive = false;

  /// 最近一次发往原生层的载荷快照（供自动化单元测试校验）。
  Map<String, Object?>? debugLastSentPayload;

  /// 绑定系统锁屏、通知栏与蓝牙耳机媒体按键回调。
  void bindCallbacks({
    required VoidCallback onPlay,
    required VoidCallback onPause,
    required VoidCallback onTogglePlayPause,
    required VoidCallback onPrevious,
    required VoidCallback onNext,
    required ValueChanged<double> onSeekToSeconds,
    required VoidCallback onStop,
  }) {
    _onPlay = onPlay;
    _onPause = onPause;
    _onTogglePlayPause = onTogglePlayPause;
    _onPrevious = onPrevious;
    _onNext = onNext;
    _onSeekToSeconds = onSeekToSeconds;
    _onStop = onStop;
    if (_handlerBound || !_isSupported()) return;
    try {
      ServicesBinding.instance;
      _handlerBound = true;
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (_) {}
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onMediaAction') return null;
    final map = call.arguments as Map<Object?, Object?>?;
    final cmd = map?['command']?.toString() ?? '';
    switch (cmd) {
      case 'play':
        _onPlay?.call();
      case 'pause':
        _onPause?.call();
      case 'togglePlayPause':
        _onTogglePlayPause?.call();
      case 'previous':
        _onPrevious?.call();
      case 'next':
        _onNext?.call();
      case 'seekTo':
        final rawMs = (map?['positionMs'] as num?)?.toDouble();
        if (rawMs != null) {
          _onSeekToSeconds?.call((rawMs / 1000.0).clamp(0.0, double.infinity));
        }
      case 'stop':
        _onStop?.call();
    }
    return null;
  }

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
  }) async {
    if (!_isSupported()) return;
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      await stopSession();
      return;
    }

    final durationMs = durationSeconds > 0
        ? (durationSeconds * 1000.0).round()
        : 0;
    final positionMs = positionSeconds > 0
        ? (positionSeconds * 1000.0).round()
        : 0;
    final now = DateTime.now();

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
      return;
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
    debugLastSentPayload = payload;

    try {
      await _channel.invokeMethod<void>('update', payload);
    } catch (_) {}
  }

  /// 停止并移除系统通知栏媒体卡片。
  Future<void> stopSession() async {
    if (!_sessionActive && _lastMetaSignature.isEmpty) return;
    _sessionActive = false;
    _lastMetaSignature = '';
    _lastIsPlaying = null;
    _lastSentCoverKey = '';
    _lastSentPositionMs = -1;
    _lastSyncAt = null;
    debugLastSentPayload = null;
    if (!_isSupported()) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// 释放通道回调引用。
  void dispose() {
    if (_handlerBound) {
      try {
        _channel.setMethodCallHandler(null);
      } catch (_) {}
      _handlerBound = false;
    }
    _onPlay = null;
    _onPause = null;
    _onTogglePlayPause = null;
    _onPrevious = null;
    _onNext = null;
    _onSeekToSeconds = null;
    _onStop = null;
  }
}
