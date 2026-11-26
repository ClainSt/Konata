import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'audio_playback_models.dart';

/// 音频回放增益策略枚举。
enum AudioReplayGainMode {
  /// 关闭回放增益，保持原始信号电平。
  none('关闭'),

  /// 按单曲标签执行响度均衡。
  track('按单曲 (Track)'),

  /// 按专辑标签保持同碟动态比例。
  album('按专辑 (Album)');

  const AudioReplayGainMode(this.label);

  /// 界面展示名称。
  final String label;

  /// 根据名称安全解析增益枚举。
  static AudioReplayGainMode parse(Object? raw) {
    if (raw is String) {
      for (final mode in values) {
        if (mode.name == raw) return mode;
      }
    }
    return AudioReplayGainMode.none;
  }
}

/// 音频舞台、发烧安全链与桌面外部转发强类型持久化偏好快照。
class AudioPlaybackPrefsData {
  /// 创建音频播放偏好不可变快照。
  const AudioPlaybackPrefsData({
    this.defaultVolume = 85.0,
    this.isMuted = false,
    this.loopMode = AudioLoopMode.loopAll,
    this.audiophileSafetyLimiterEnabled = true,
    this.replayGainMode = AudioReplayGainMode.none,
    this.replayGainPreampDb = 0.0,
    this.preferredAudioEngine = PreferredPlaybackEngine.builtinLibmpv,
    this.audioResamplerPrecision = PlaybackQualityConfig.defaultSoxrPrecision,
    this.exclusiveAudioOutput = false,
    this.audioDevice = PlaybackQualityConfig.defaultAudioDevice,
    this.keepPitch = true,
    this.bitstreamPassthrough = false,
    this.androidBitPerfectUsb = false,
    this.audioFloatingMiniEnabled = true,
    this.foobarBeefwebPort = 8880,
    this.skipFoobarBeefwebPrompt = false,
    this.preferredRelayTargetId,
  });

  /// 默认安全限幅前输出音量百分比（0 ~ 100）。
  final double defaultVolume;

  /// 默认静音状态。
  final bool isMuted;

  /// 音频队列循环模式。
  final AudioLoopMode loopMode;

  /// 是否启用发烧输出 `-12 dBFS` 防爆耳安全天花板开关。
  final bool audiophileSafetyLimiterEnabled;

  /// 回放增益模式（关闭 / 单曲 / 专辑）。
  final AudioReplayGainMode replayGainMode;

  /// 回放增益前置衰减或微调偏移（单位 dB，范围 `-12.0 ~ +6.0`）。
  final double replayGainPreampDb;

  /// 桌面端默认音频播放引擎路由。
  final PreferredPlaybackEngine preferredAudioEngine;

  /// 内置引擎重采样精度（`20`/`24`/`28`/`32` 位线性相位）。
  final int audioResamplerPrecision;

  /// 是否开启桌面端音频设备独占模式（如 WASAPI Exclusive）。
  final bool exclusiveAudioOutput;

  /// 目标音频输出设备标识符。
  final String audioDevice;

  /// 变速时是否保持音高不失真。
  final bool keepPitch;

  /// 是否开启 HDMI / S/PDIF 压缩源码透传。
  final bool bitstreamPassthrough;

  /// 是否开启 Android 14+ USB DAC 逐位直通协商。
  final bool androidBitPerfectUsb;

  /// 是否启用页内可拖拽迷你悬浮唱片栏。
  final bool audioFloatingMiniEnabled;

  /// foobar2000 Beefweb 外部转发默认监听端口。
  final int foobarBeefwebPort;

  /// 是否跳过 foobar2000 Beefweb 未就绪确认弹窗。
  final bool skipFoobarBeefwebPrompt;

  /// 桌面端首选外部音频接力目标标识。
  final String? preferredRelayTargetId;

  /// 转换为发烧安全协调器所需的轻量配置对象。
  AudiophileAudioPreferences toAudiophilePreferences() {
    return AudiophileAudioPreferences(
      qualityConfig: PlaybackQualityConfig(
        audioResamplerPrecision: audioResamplerPrecision,
        exclusiveAudioOutput: exclusiveAudioOutput,
        audioDevice: audioDevice,
        keepPitch: keepPitch,
      ),
      bitstreamPassthrough: bitstreamPassthrough,
      androidBitPerfectUsb: androidBitPerfectUsb,
    );
  }

  /// 复制并按需更新局部偏好字段。
  AudioPlaybackPrefsData copyWith({
    double? defaultVolume,
    bool? isMuted,
    AudioLoopMode? loopMode,
    bool? audiophileSafetyLimiterEnabled,
    AudioReplayGainMode? replayGainMode,
    double? replayGainPreampDb,
    PreferredPlaybackEngine? preferredAudioEngine,
    int? audioResamplerPrecision,
    bool? exclusiveAudioOutput,
    String? audioDevice,
    bool? keepPitch,
    bool? bitstreamPassthrough,
    bool? androidBitPerfectUsb,
    bool? audioFloatingMiniEnabled,
    int? foobarBeefwebPort,
    bool? skipFoobarBeefwebPrompt,
    String? preferredRelayTargetId,
    bool clearPreferredRelayTargetId = false,
  }) {
    return AudioPlaybackPrefsData(
      defaultVolume: (defaultVolume ?? this.defaultVolume).clamp(0.0, 100.0),
      isMuted: isMuted ?? this.isMuted,
      loopMode: loopMode ?? this.loopMode,
      audiophileSafetyLimiterEnabled:
          audiophileSafetyLimiterEnabled ?? this.audiophileSafetyLimiterEnabled,
      replayGainMode: replayGainMode ?? this.replayGainMode,
      replayGainPreampDb: (replayGainPreampDb ?? this.replayGainPreampDb).clamp(
        -12.0,
        6.0,
      ),
      preferredAudioEngine: preferredAudioEngine ?? this.preferredAudioEngine,
      audioResamplerPrecision:
          audioResamplerPrecision ?? this.audioResamplerPrecision,
      exclusiveAudioOutput: exclusiveAudioOutput ?? this.exclusiveAudioOutput,
      audioDevice: audioDevice ?? this.audioDevice,
      keepPitch: keepPitch ?? this.keepPitch,
      bitstreamPassthrough: bitstreamPassthrough ?? this.bitstreamPassthrough,
      androidBitPerfectUsb: androidBitPerfectUsb ?? this.androidBitPerfectUsb,
      audioFloatingMiniEnabled:
          audioFloatingMiniEnabled ?? this.audioFloatingMiniEnabled,
      foobarBeefwebPort: (foobarBeefwebPort ?? this.foobarBeefwebPort).clamp(
        1,
        65535,
      ),
      skipFoobarBeefwebPrompt:
          skipFoobarBeefwebPrompt ?? this.skipFoobarBeefwebPrompt,
      preferredRelayTargetId: clearPreferredRelayTargetId
          ? null
          : (preferredRelayTargetId ?? this.preferredRelayTargetId),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AudioPlaybackPrefsData &&
        other.defaultVolume == defaultVolume &&
        other.isMuted == isMuted &&
        other.loopMode == loopMode &&
        other.audiophileSafetyLimiterEnabled ==
            audiophileSafetyLimiterEnabled &&
        other.replayGainMode == replayGainMode &&
        other.replayGainPreampDb == replayGainPreampDb &&
        other.preferredAudioEngine == preferredAudioEngine &&
        other.audioResamplerPrecision == audioResamplerPrecision &&
        other.exclusiveAudioOutput == exclusiveAudioOutput &&
        other.audioDevice == audioDevice &&
        other.keepPitch == keepPitch &&
        other.bitstreamPassthrough == bitstreamPassthrough &&
        other.androidBitPerfectUsb == androidBitPerfectUsb &&
        other.audioFloatingMiniEnabled == audioFloatingMiniEnabled &&
        other.foobarBeefwebPort == foobarBeefwebPort &&
        other.skipFoobarBeefwebPrompt == skipFoobarBeefwebPrompt &&
        other.preferredRelayTargetId == preferredRelayTargetId;
  }

  @override
  int get hashCode => Object.hash(
    defaultVolume,
    isMuted,
    loopMode,
    audiophileSafetyLimiterEnabled,
    replayGainMode,
    replayGainPreampDb,
    preferredAudioEngine,
    audioResamplerPrecision,
    exclusiveAudioOutput,
    audioDevice,
    keepPitch,
    bitstreamPassthrough,
    androidBitPerfectUsb,
    audioFloatingMiniEnabled,
    foobarBeefwebPort,
    skipFoobarBeefwebPrompt,
    preferredRelayTargetId,
  );
}

/// 面向 `ScopedPrefsStore` 的 `playback_audio` 强类型切片定义。
final TypedPrefsSlice<AudioPlaybackPrefsData> audioPlaybackPrefsSlice =
    TypedPrefsSlice<AudioPlaybackPrefsData>(
      namespace: AudioPlaybackPreferences.namespace,
      schemaVersion: 1,
      syncPolicy: SyncPolicy.portable,
      defaultValue: const AudioPlaybackPrefsData(),
      encode: (value) => <String, Object?>{
        'defaultVolume': value.defaultVolume,
        'isMuted': value.isMuted,
        'loopMode': value.loopMode.name,
        'audiophileSafetyLimiterEnabled': value.audiophileSafetyLimiterEnabled,
        'replayGainMode': value.replayGainMode.name,
        'replayGainPreampDb': value.replayGainPreampDb,
        'preferredAudioEngine': value.preferredAudioEngine.name,
        'audioResamplerPrecision': value.audioResamplerPrecision,
        'exclusiveAudioOutput': value.exclusiveAudioOutput,
        'audioDevice': value.audioDevice,
        'keepPitch': value.keepPitch,
        'bitstreamPassthrough': value.bitstreamPassthrough,
        'androidBitPerfectUsb': value.androidBitPerfectUsb,
        'audioFloatingMiniEnabled': value.audioFloatingMiniEnabled,
        'foobarBeefwebPort': value.foobarBeefwebPort,
        'skipFoobarBeefwebPrompt': value.skipFoobarBeefwebPrompt,
        'preferredRelayTargetId': value.preferredRelayTargetId,
      },
      decode: (json, _) {
        final rawVolume = json['defaultVolume'];
        final rawPreamp = json['replayGainPreampDb'];
        final rawPrecision = json['audioResamplerPrecision'];
        final rawPort = json['foobarBeefwebPort'];
        final rawEngine = json['preferredAudioEngine'];
        PreferredPlaybackEngine parsedEngine =
            PreferredPlaybackEngine.builtinLibmpv;
        if (rawEngine is String) {
          for (final item in PreferredPlaybackEngine.values) {
            if (item.name == rawEngine) {
              parsedEngine = item;
              break;
            }
          }
        }
        final rawDevice = json['audioDevice'];
        final rawRelayTarget = json['preferredRelayTargetId'];
        return AudioPlaybackPrefsData(
          defaultVolume: rawVolume is num
              ? rawVolume.toDouble().clamp(0.0, 100.0)
              : 85.0,
          isMuted: json['isMuted'] == true,
          loopMode: json['shuffleEnabled'] == true
              ? AudioLoopMode.shuffle
              : AudioLoopMode.parse(json['loopMode']),
          audiophileSafetyLimiterEnabled:
              json['audiophileSafetyLimiterEnabled'] is bool
              ? json['audiophileSafetyLimiterEnabled']! as bool
              : true,
          replayGainMode: AudioReplayGainMode.parse(json['replayGainMode']),
          replayGainPreampDb: rawPreamp is num
              ? rawPreamp.toDouble().clamp(-12.0, 6.0)
              : 0.0,
          preferredAudioEngine: parsedEngine,
          audioResamplerPrecision: rawPrecision is num
              ? _sanitizePrecision(rawPrecision.toInt())
              : PlaybackQualityConfig.defaultSoxrPrecision,
          exclusiveAudioOutput: json['exclusiveAudioOutput'] == true,
          audioDevice: rawDevice is String && rawDevice.trim().isNotEmpty
              ? rawDevice
              : PlaybackQualityConfig.defaultAudioDevice,
          keepPitch: json['keepPitch'] is bool
              ? json['keepPitch']! as bool
              : true,
          bitstreamPassthrough: json['bitstreamPassthrough'] == true,
          androidBitPerfectUsb: json['androidBitPerfectUsb'] == true,
          audioFloatingMiniEnabled: json['audioFloatingMiniEnabled'] is bool
              ? json['audioFloatingMiniEnabled']! as bool
              : true,
          foobarBeefwebPort: rawPort is num
              ? rawPort.toInt().clamp(1, 65535)
              : 8880,
          skipFoobarBeefwebPrompt: json['skipFoobarBeefwebPrompt'] == true,
          preferredRelayTargetId:
              rawRelayTarget is String && rawRelayTarget.isNotEmpty
              ? rawRelayTarget
              : null,
        );
      },
    );

int _sanitizePrecision(int value) {
  return switch (value) {
    20 || 24 || 28 || 32 => value,
    _ => PlaybackQualityConfig.defaultSoxrPrecision,
  };
}

/// 封装 `ScopedPrefsStore` 与低频偏好变更广播的音频设置仓库（不直接耦合状态管理框架）。
class AudioPlaybackPreferences {
  /// 创建基于 `ScopedPrefsStore` 的音频偏好读写适配器。
  AudioPlaybackPreferences({required this._store, this._eventBus});

  /// 本切片在全库设置体系中的唯一命名空间标识。
  static const String namespace = 'playback_audio';

  final ScopedPrefsStore _store;
  final DomainEventBus? _eventBus;

  /// 读取当前持久化音频偏好快照。
  AudioPlaybackPrefsData read() => _store.read(audioPlaybackPrefsSlice);

  /// 订阅命名空间 `playback_audio` 变更事件流。
  Stream<AudioPlaybackPrefsData> watch() =>
      _store.watch(audioPlaybackPrefsSlice);

  /// 写入完整音频偏好快照，并在可用时通过领域事件总线发出低频变更通知。
  void write(AudioPlaybackPrefsData next) {
    final current = read();
    if (current == next) return;
    _store.write(audioPlaybackPrefsSlice, next);
    _eventBus?.publish(
      PrefsSliceChangedEvent(
        namespace: namespace,
        occurredAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 基于当前快照执行纯函数式局部更新。
  AudioPlaybackPrefsData update(
    AudioPlaybackPrefsData Function(AudioPlaybackPrefsData current) transform,
  ) {
    final next = transform(read());
    write(next);
    return next;
  }

  /// 重置恢复本包全部默认设置。
  void resetToDefaults() {
    _store.delete(namespace);
    _eventBus?.publish(
      PrefsSliceChangedEvent(
        namespace: namespace,
        occurredAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}
