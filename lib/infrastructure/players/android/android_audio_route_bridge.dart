import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Android 14+ 原生 `MIXER_BEHAVIOR_BIT_PERFECT` USB 协商结果快照。
class AndroidBitPerfectNegotiationResult {
  /// 创建协商结果。
  const AndroidBitPerfectNegotiationResult({
    required this.supported,
    required this.engaged,
    this.deviceName = '',
    this.sampleRateHz = 0,
    this.detail = '',
  });

  /// 当前设备及已连接 USB DAC 是否支持逐位混音器属性。
  final bool supported;

  /// 是否已成功向系统设置 `MIXER_BEHAVIOR_BIT_PERFECT` 优先属性。
  final bool engaged;

  /// 命中的外接 USB 音频设备名称。
  final String deviceName;

  /// 协商命中的源采样率（Hz）。
  final int sampleRateHz;

  /// 供诊断显示的补充状态说明。
  final String detail;
}

/// Android 原生音频路由与外设拔出瞬态静音通道桥接（`ccplayer/audio_route`）。
///
/// 采用可实例化对象由 Riverpod Provider 托管生命周期，消除全局可变静态回调与多容器冲突：
/// 1. 在 Android 14+ (API 34+) 上通过 `AudioManager.getSupportedMixerAttributes` 协商 USB DAC 逐位直通；
/// 2. 接收底层双通道外设拔出监听（`ACTION_AUDIO_BECOMING_NOISY` + `AudioDeviceCallback.onAudioDevicesRemoved`），
///    广播至所有已注册播放控制器实现瞬时静音、暂停防爆音与新外设接入重置安全衰减门锁。
class AndroidAudioRouteBridge {
  /// 创建 Android 音频路由通道桥接实例。
  AndroidAudioRouteBridge({
    MethodChannel? channel,
    bool Function()? isSupported,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _isSupported = isSupported ?? (() => Platform.isAndroid);

  static const String _channelName = 'ccplayer/audio_route';

  final MethodChannel _channel;
  final bool Function() _isSupported;

  bool _handlerRegistered = false;
  final Map<Object, void Function(String reason)> _removedListeners = {};
  final Map<Object, void Function(String deviceFingerprint)> _addedListeners =
      {};

  /// 按调用方令牌绑定外设拔出瞬态静音与新外设接入重置安全衰减的实时监听回调。
  void bindRouteListeners({
    required Object owner,
    void Function(String reason)? onOutputDeviceRemoved,
    void Function(String deviceFingerprint)? onOutputDeviceAdded,
  }) {
    if (onOutputDeviceRemoved != null) {
      _removedListeners[owner] = onOutputDeviceRemoved;
    } else {
      _removedListeners.remove(owner);
    }
    if (onOutputDeviceAdded != null) {
      _addedListeners[owner] = onOutputDeviceAdded;
    } else {
      _addedListeners.remove(owner);
    }
    if (!_isSupported() || _handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler(_handlePlatformCall);
    // 按需唤醒原生外设拔出广播与 AudioDeviceCallback（空载冷启动期零 AudioManager IPC）。
    unawaited(
      _channel
          .invokeMethod<Object?>('startMonitoring')
          .catchError((Object _) => null),
    );
  }

  /// 按调用方令牌解绑路由事件回调，不影响其他同时活跃的播放通道。
  void unbindRouteListeners({required Object owner}) {
    _removedListeners.remove(owner);
    _addedListeners.remove(owner);
  }

  Future<Object?> _handlePlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'outputDeviceRemoved':
        final reason = (call.arguments as String?) ?? 'device_removed';
        for (final cb in List<void Function(String)>.of(
          _removedListeners.values,
        )) {
          cb(reason);
        }
      case 'outputDeviceAdded':
        final fingerprint = (call.arguments as String?) ?? 'external_audio';
        for (final cb in List<void Function(String)>.of(
          _addedListeners.values,
        )) {
          cb(fingerprint);
        }
    }
    return null;
  }

  /// 在 Android 14+ 上尝试为外接 USB DAC 协商 `MIXER_BEHAVIOR_BIT_PERFECT` 逐位直通。
  Future<AndroidBitPerfectNegotiationResult> negotiateBitPerfectUsb({
    int preferredSampleRateHz = 48000,
    bool enable = true,
  }) async {
    if (!_isSupported()) {
      return const AndroidBitPerfectNegotiationResult(
        supported: false,
        engaged: false,
        detail: '当前平台无需 Android 混音器逐位协商',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'negotiateBitPerfectUsb',
        <String, Object>{
          'sampleRateHz': preferredSampleRateHz,
          'enable': enable,
        },
      );
      if (raw == null) {
        return const AndroidBitPerfectNegotiationResult(
          supported: false,
          engaged: false,
        );
      }
      return AndroidBitPerfectNegotiationResult(
        supported: raw['supported'] == true,
        engaged: raw['engaged'] == true,
        deviceName: (raw['deviceName'] as String?) ?? '',
        sampleRateHz: (raw['sampleRateHz'] as num?)?.toInt() ?? 0,
        detail: (raw['detail'] as String?) ?? '',
      );
    } catch (e) {
      return AndroidBitPerfectNegotiationResult(
        supported: false,
        engaged: false,
        detail: e.toString(),
      );
    }
  }

  /// 释放通道监听并清空全部已注册回调。
  void dispose() {
    _removedListeners.clear();
    _addedListeners.clear();
    if (_handlerRegistered) {
      _handlerRegistered = false;
      _channel.setMethodCallHandler(null);
    }
  }
}
