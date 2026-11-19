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
/// 负责：
/// 1. 在 Android 14+ (API 34+) 上通过 `AudioManager.getSupportedMixerAttributes` 协商 USB DAC 逐位直通；
/// 2. 接收底层双通道外设拔出监听（`ACTION_AUDIO_BECOMING_NOISY` + `AudioDeviceCallback.onAudioDevicesRemoved`），
///    回调播放控制器瞬时静音与暂停防爆音，同时在新外设接入时复位安全衰减门锁。
class AndroidAudioRouteBridge {
  AndroidAudioRouteBridge._();

  static const MethodChannel _channel = MethodChannel('ccplayer/audio_route');
  static bool _handlerRegistered = false;
  static void Function(String reason)? _onOutputDeviceRemoved;
  static void Function(String deviceFingerprint)? _onOutputDeviceAdded;

  /// 绑定外设拔出瞬态静音与新外设接入重置安全衰减的实时监听回调。
  static void bindRouteListeners({
    void Function(String reason)? onOutputDeviceRemoved,
    void Function(String deviceFingerprint)? onOutputDeviceAdded,
  }) {
    _onOutputDeviceRemoved = onOutputDeviceRemoved;
    _onOutputDeviceAdded = onOutputDeviceAdded;
    if (!Platform.isAndroid || _handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'outputDeviceRemoved':
          final reason = (call.arguments as String?) ?? 'device_removed';
          _onOutputDeviceRemoved?.call(reason);
        case 'outputDeviceAdded':
          final fingerprint = (call.arguments as String?) ?? 'external_audio';
          _onOutputDeviceAdded?.call(fingerprint);
      }
      return null;
    });
  }

  /// 解绑路由事件回调。
  static void unbindRouteListeners() {
    _onOutputDeviceRemoved = null;
    _onOutputDeviceAdded = null;
  }

  /// 在 Android 14+ 上尝试为外接 USB DAC 协商 `MIXER_BEHAVIOR_BIT_PERFECT` 逐位直通。
  static Future<AndroidBitPerfectNegotiationResult> negotiateBitPerfectUsb({
    int preferredSampleRateHz = 48000,
    bool enable = true,
  }) async {
    if (!Platform.isAndroid) {
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
}
