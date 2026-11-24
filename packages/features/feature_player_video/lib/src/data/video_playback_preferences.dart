import 'dart:async';

import 'package:engine_playback/engine_playback.dart';
import 'package:flutter/foundation.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 视频播放器强类型偏好设置切片定义（命名空间固定为 `playback_video`）。
const TypedPrefsSlice<VideoPlaybackPreferences> videoPlaybackPrefsSlice =
    TypedPrefsSlice<VideoPlaybackPreferences>(
      namespace: VideoPlaybackPreferences.prefsNamespace,
      schemaVersion: VideoPlaybackPreferences.currentSchemaVersion,
      syncPolicy: SyncPolicy.portable,
      defaultValue: VideoPlaybackPreferences(),
      encode: _encodeVideoPlaybackPreferences,
      decode: VideoPlaybackPreferences.fromJson,
    );

Map<String, Object?> _encodeVideoPlaybackPreferences(
  VideoPlaybackPreferences value,
) => value.toJson();

/// 内置视频播放、字幕渲染与音画输出偏好配置模型（纯领域值对象）。
@immutable
class VideoPlaybackPreferences {
  /// 创建视频播放偏好配置实例。
  const VideoPlaybackPreferences({
    this.preferredEngine = PreferredPlaybackEngine.builtinLibmpv,
    this.qualityConfig = const PlaybackQualityConfig(),
    this.preferredSubtitleLangs = _defaultSubtitleLangs,
    this.preferredAudioLangs = _defaultAudioLangs,
    this.volume = 1.0,
    this.isMuted = false,
    this.autoPlayNextEpisode = true,
    this.autoSkipChapters = false,
    this.backgroundAudioOnMinimize = true,
    this.enableCloudSubset = false,
    this.fontInAssEndpoint = '',
    this.authorizedCloudSubsetOrigins = const <String>[],
    this.bitstreamPassthrough = false,
    this.androidBitPerfectUsb = false,
    this.skipFoobarBeefwebGuidePrompt = false,
  });

  /// 自治配置存储命名空间标识。
  static const String prefsNamespace = 'playback_video';

  /// 当前序列化结构版本号。
  static const int currentSchemaVersion = 2;

  static const List<String> _defaultAudioLangs = <String>[
    'jpn',
    'ja',
    'japanese',
    'chi',
    'zho',
    'zh',
  ];

  static const List<String> _defaultSubtitleLangs = <String>[
    'chs',
    'zh-hans',
    'zh-cn',
    'sc',
    'chi',
    'zho',
    'zh',
    'cht',
    'zh-hant',
    'zh-tw',
    'zh-hk',
    'tc',
  ];

  /// 默认播放引擎路由偏好。
  final PreferredPlaybackEngine preferredEngine;

  /// 内置播放器画质、渲染后端与字幕样式配置。
  final PlaybackQualityConfig qualityConfig;

  /// 首选字幕语言优先级列表。
  final List<String> preferredSubtitleLangs;

  /// 首选音轨语言优先级列表。
  final List<String> preferredAudioLangs;

  /// 默认归一化音量（0.0 到 1.0 之间）。
  final double volume;

  /// 是否静音。
  final bool isMuted;

  /// 播放完当前正片后是否自动连播下一集。
  final bool autoPlayNextEpisode;

  /// 是否允许自动跳过显式命名的片头或片尾章节。
  final bool autoSkipChapters;

  /// 切入桌面迷你窗口或退居后台时是否允许保持音轨持续播放。
  final bool backgroundAudioOnMinimize;

  /// 是否启用可选云端字体子集化功能。
  final bool enableCloudSubset;

  /// 授权的云端字体子集化服务端地址。
  final String fontInAssEndpoint;

  /// 用户显式授权的云端服务来源列表。
  final List<String> authorizedCloudSubsetOrigins;

  /// 是否开启硬件压缩音频源码透传。
  final bool bitstreamPassthrough;

  /// 是否开启移动端外接解码器逐位直通协商。
  final bool androidBitPerfectUsb;

  /// 是否跳过外接音频控制组件安装提醒。
  final bool skipFoobarBeefwebGuidePrompt;

  /// 派生只读轨道偏好策略。
  TrackPreferences get trackPreferences => TrackPreferences(
    preferredAudioLangs: preferredAudioLangs,
    preferredSubtitleLangs: preferredSubtitleLangs,
  );

  /// 派生发烧音频路由协调偏好配置。
  AudiophileAudioPreferences get audiophilePreferences =>
      AudiophileAudioPreferences(
        qualityConfig: qualityConfig,
        bitstreamPassthrough: bitstreamPassthrough,
        androidBitPerfectUsb: androidBitPerfectUsb,
      );

  /// 序列化为跨设备可同步的轻量字典载荷。
  Map<String, Object?> toJson() => <String, Object?>{
    'preferredEngine': preferredEngine.name,
    'qualityConfig': <String, Object?>{
      'preset': qualityConfig.preset.name,
      'outputPipelineMode': qualityConfig.outputPipelineMode.bridgeKey,
      'hardwareDecode': qualityConfig.hardwareDecode,
      'debandEnabled': qualityConfig.debandEnabled,
      'demuxerMaxBytesMiB': qualityConfig.demuxerMaxBytesMiB,
      'demuxerMaxBackBytesMiB': qualityConfig.demuxerMaxBackBytesMiB,
      'cacheSecs': qualityConfig.cacheSecs,
      'audioResamplerPrecision': qualityConfig.audioResamplerPrecision,
      'exclusiveAudioOutput': qualityConfig.exclusiveAudioOutput,
      'audioDevice': qualityConfig.audioDevice,
      'activeShaderPaths': List<String>.of(qualityConfig.activeShaderPaths),
      'defaultSpeed': qualityConfig.defaultSpeed,
      'keepPitch': qualityConfig.keepPitch,
      'subFontSize': qualityConfig.subFontSize,
      'subFontName': qualityConfig.subFontName,
      'subBottomMargin': qualityConfig.subBottomMargin,
      'subOverrideMode': qualityConfig.subOverrideMode.name,
      'subColorHex': qualityConfig.subColorHex,
    },
    'preferredSubtitleLangs': List<String>.of(preferredSubtitleLangs),
    'preferredAudioLangs': List<String>.of(preferredAudioLangs),
    'volume': volume.clamp(0.0, 1.0),
    'isMuted': isMuted,
    'autoPlayNextEpisode': autoPlayNextEpisode,
    'autoSkipChapters': autoSkipChapters,
    'backgroundAudioOnMinimize': backgroundAudioOnMinimize,
    'enableCloudSubset': enableCloudSubset,
    'fontInAssEndpoint': fontInAssEndpoint,
    'authorizedCloudSubsetOrigins': List<String>.of(
      authorizedCloudSubsetOrigins,
    ),
    'bitstreamPassthrough': bitstreamPassthrough,
    'androidBitPerfectUsb': androidBitPerfectUsb,
    'skipFoobarBeefwebGuidePrompt': skipFoobarBeefwebGuidePrompt,
  };

  /// 从持久化载荷还原强类型偏好配置（自动兼容缺省键与异常类型回退）。
  static VideoPlaybackPreferences fromJson(
    Map<String, Object?> json,
    int storedSchemaVersion,
  ) {
    final engine = _parseEnum(
      PreferredPlaybackEngine.values,
      json['preferredEngine'],
      PreferredPlaybackEngine.builtinLibmpv,
    );
    final rawQuality = json['qualityConfig'];
    final qualityMap = rawQuality is Map<Object?, Object?>
        ? rawQuality
        : const <Object?, Object?>{};

    final preset = _parseEnum(
      VideoQualityPreset.values,
      qualityMap['preset'],
      VideoQualityPreset.highFidelity,
    );
    final pipelineMode = VideoOutputPipelineMode.parse(
      qualityMap['outputPipelineMode'],
    );
    final subOverride = _parseEnum(
      SubtitleAssOverrideMode.values,
      qualityMap['subOverrideMode'],
      SubtitleAssOverrideMode.preserveAss,
    );

    final quality = PlaybackQualityConfig(
      preset: preset,
      outputPipelineMode: pipelineMode,
      hardwareDecode: _readBool(qualityMap['hardwareDecode'], true),
      debandEnabled: _readBool(qualityMap['debandEnabled'], false),
      demuxerMaxBytesMiB: _readInt(
        qualityMap['demuxerMaxBytesMiB'],
        PlaybackQualityConfig.defaultDemuxerMaxBytesMiB,
        min: 4,
        max: 512,
      ),
      demuxerMaxBackBytesMiB: _readInt(
        qualityMap['demuxerMaxBackBytesMiB'],
        PlaybackQualityConfig.defaultDemuxerMaxBackBytesMiB,
        min: 2,
        max: 256,
      ),
      cacheSecs: _readInt(
        qualityMap['cacheSecs'],
        PlaybackQualityConfig.defaultCacheSecs,
        min: 10,
        max: 600,
      ),
      audioResamplerPrecision: _readInt(
        qualityMap['audioResamplerPrecision'],
        PlaybackQualityConfig.defaultSoxrPrecision,
        min: 16,
        max: 32,
      ),
      exclusiveAudioOutput: _readBool(
        qualityMap['exclusiveAudioOutput'],
        false,
      ),
      audioDevice: _readString(
        qualityMap['audioDevice'],
        PlaybackQualityConfig.defaultAudioDevice,
      ),
      activeShaderPaths: _readStringList(qualityMap['activeShaderPaths']),
      defaultSpeed: _readDouble(
        qualityMap['defaultSpeed'],
        1.0,
        min: 0.25,
        max: 4.0,
      ),
      keepPitch: _readBool(qualityMap['keepPitch'], true),
      subFontSize: _readInt(
        qualityMap['subFontSize'],
        PlaybackQualityConfig.defaultSubFontSize,
        min: 12,
        max: 140,
      ),
      subFontName: _readString(qualityMap['subFontName'], ''),
      subBottomMargin: _readInt(
        qualityMap['subBottomMargin'],
        PlaybackQualityConfig.defaultSubBottomMargin,
        min: 0,
        max: 200,
      ),
      subOverrideMode: subOverride,
      subColorHex: _readString(
        qualityMap['subColorHex'],
        PlaybackQualityConfig.defaultSubColorHex,
      ),
    );

    final subLangs = _readStringList(json['preferredSubtitleLangs']);
    final audioLangs = _readStringList(json['preferredAudioLangs']);

    return VideoPlaybackPreferences(
      preferredEngine: engine,
      qualityConfig: quality,
      preferredSubtitleLangs: subLangs.isEmpty
          ? _defaultSubtitleLangs
          : subLangs,
      preferredAudioLangs: audioLangs.isEmpty
          ? _defaultAudioLangs
          : audioLangs,
      volume: _readDouble(json['volume'], 1.0, min: 0.0, max: 1.0),
      isMuted: _readBool(json['isMuted'], false),
      autoPlayNextEpisode: _readBool(json['autoPlayNextEpisode'], true),
      autoSkipChapters: _readBool(json['autoSkipChapters'], false),
      backgroundAudioOnMinimize: _readBool(
        json['backgroundAudioOnMinimize'],
        true,
      ),
      enableCloudSubset: _readBool(json['enableCloudSubset'], false),
      fontInAssEndpoint: _readString(json['fontInAssEndpoint'], ''),
      authorizedCloudSubsetOrigins: _readStringList(
        json['authorizedCloudSubsetOrigins'],
      ),
      bitstreamPassthrough: _readBool(json['bitstreamPassthrough'], false),
      androidBitPerfectUsb: _readBool(json['androidBitPerfectUsb'], false),
      skipFoobarBeefwebGuidePrompt: _readBool(
        json['skipFoobarBeefwebGuidePrompt'],
        false,
      ),
    );
  }

  /// 复制并局部替换视频播放偏好配置字段。
  VideoPlaybackPreferences copyWith({
    PreferredPlaybackEngine? preferredEngine,
    PlaybackQualityConfig? qualityConfig,
    List<String>? preferredSubtitleLangs,
    List<String>? preferredAudioLangs,
    double? volume,
    bool? isMuted,
    bool? autoPlayNextEpisode,
    bool? autoSkipChapters,
    bool? backgroundAudioOnMinimize,
    bool? enableCloudSubset,
    String? fontInAssEndpoint,
    List<String>? authorizedCloudSubsetOrigins,
    bool? bitstreamPassthrough,
    bool? androidBitPerfectUsb,
    bool? skipFoobarBeefwebGuidePrompt,
  }) {
    return VideoPlaybackPreferences(
      preferredEngine: preferredEngine ?? this.preferredEngine,
      qualityConfig: qualityConfig ?? this.qualityConfig,
      preferredSubtitleLangs:
          preferredSubtitleLangs ?? this.preferredSubtitleLangs,
      preferredAudioLangs: preferredAudioLangs ?? this.preferredAudioLangs,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      autoPlayNextEpisode: autoPlayNextEpisode ?? this.autoPlayNextEpisode,
      autoSkipChapters: autoSkipChapters ?? this.autoSkipChapters,
      backgroundAudioOnMinimize:
          backgroundAudioOnMinimize ?? this.backgroundAudioOnMinimize,
      enableCloudSubset: enableCloudSubset ?? this.enableCloudSubset,
      fontInAssEndpoint: fontInAssEndpoint ?? this.fontInAssEndpoint,
      authorizedCloudSubsetOrigins:
          authorizedCloudSubsetOrigins ?? this.authorizedCloudSubsetOrigins,
      bitstreamPassthrough: bitstreamPassthrough ?? this.bitstreamPassthrough,
      androidBitPerfectUsb: androidBitPerfectUsb ?? this.androidBitPerfectUsb,
      skipFoobarBeefwebGuidePrompt:
          skipFoobarBeefwebGuidePrompt ?? this.skipFoobarBeefwebGuidePrompt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VideoPlaybackPreferences &&
        other.preferredEngine == preferredEngine &&
        other.qualityConfig.preset == qualityConfig.preset &&
        other.qualityConfig.outputPipelineMode ==
            qualityConfig.outputPipelineMode &&
        other.qualityConfig.hardwareDecode == qualityConfig.hardwareDecode &&
        other.qualityConfig.debandEnabled == qualityConfig.debandEnabled &&
        other.qualityConfig.demuxerMaxBytesMiB ==
            qualityConfig.demuxerMaxBytesMiB &&
        other.qualityConfig.demuxerMaxBackBytesMiB ==
            qualityConfig.demuxerMaxBackBytesMiB &&
        other.qualityConfig.cacheSecs == qualityConfig.cacheSecs &&
        other.qualityConfig.audioResamplerPrecision ==
            qualityConfig.audioResamplerPrecision &&
        other.qualityConfig.exclusiveAudioOutput ==
            qualityConfig.exclusiveAudioOutput &&
        other.qualityConfig.audioDevice == qualityConfig.audioDevice &&
        listEquals(
          other.qualityConfig.activeShaderPaths,
          qualityConfig.activeShaderPaths,
        ) &&
        other.qualityConfig.defaultSpeed == qualityConfig.defaultSpeed &&
        other.qualityConfig.keepPitch == qualityConfig.keepPitch &&
        other.qualityConfig.subFontSize == qualityConfig.subFontSize &&
        other.qualityConfig.subFontName == qualityConfig.subFontName &&
        other.qualityConfig.subBottomMargin == qualityConfig.subBottomMargin &&
        other.qualityConfig.subOverrideMode == qualityConfig.subOverrideMode &&
        other.qualityConfig.subColorHex == qualityConfig.subColorHex &&
        listEquals(other.preferredSubtitleLangs, preferredSubtitleLangs) &&
        listEquals(other.preferredAudioLangs, preferredAudioLangs) &&
        other.volume == volume &&
        other.isMuted == isMuted &&
        other.autoPlayNextEpisode == autoPlayNextEpisode &&
        other.autoSkipChapters == autoSkipChapters &&
        other.backgroundAudioOnMinimize == backgroundAudioOnMinimize &&
        other.enableCloudSubset == enableCloudSubset &&
        other.fontInAssEndpoint == fontInAssEndpoint &&
        listEquals(
          other.authorizedCloudSubsetOrigins,
          authorizedCloudSubsetOrigins,
        ) &&
        other.bitstreamPassthrough == bitstreamPassthrough &&
        other.androidBitPerfectUsb == androidBitPerfectUsb &&
        other.skipFoobarBeefwebGuidePrompt == skipFoobarBeefwebGuidePrompt;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    preferredEngine,
    qualityConfig.preset,
    qualityConfig.outputPipelineMode,
    qualityConfig.hardwareDecode,
    qualityConfig.debandEnabled,
    qualityConfig.demuxerMaxBytesMiB,
    qualityConfig.demuxerMaxBackBytesMiB,
    qualityConfig.cacheSecs,
    qualityConfig.audioResamplerPrecision,
    qualityConfig.exclusiveAudioOutput,
    qualityConfig.audioDevice,
    Object.hashAll(qualityConfig.activeShaderPaths),
    qualityConfig.defaultSpeed,
    qualityConfig.keepPitch,
    qualityConfig.subFontSize,
    qualityConfig.subFontName,
    qualityConfig.subBottomMargin,
    qualityConfig.subOverrideMode,
    qualityConfig.subColorHex,
    Object.hashAll(preferredSubtitleLangs),
    Object.hashAll(preferredAudioLangs),
    volume,
    isMuted,
    autoPlayNextEpisode,
    autoSkipChapters,
    backgroundAudioOnMinimize,
    enableCloudSubset,
    fontInAssEndpoint,
    Object.hashAll(authorizedCloudSubsetOrigins),
    bitstreamPassthrough,
    androidBitPerfectUsb,
    skipFoobarBeefwebGuidePrompt,
  ]);

  static T _parseEnum<T extends Enum>(
    List<T> values,
    Object? raw,
    T fallback,
  ) {
    if (raw is String) {
      for (final value in values) {
        if (value.name == raw) return value;
      }
    }
    return fallback;
  }

  static bool _readBool(Object? raw, bool fallback) =>
      raw is bool ? raw : fallback;

  static int _readInt(
    Object? raw,
    int fallback, {
    required int min,
    required int max,
  }) {
    final parsed = raw is int ? raw : (raw is num ? raw.round() : fallback);
    return parsed.clamp(min, max);
  }

  static double _readDouble(
    Object? raw,
    double fallback, {
    required double min,
    required double max,
  }) {
    final parsed = raw is num ? raw.toDouble() : fallback;
    if (!parsed.isFinite) return fallback;
    return parsed.clamp(min, max).toDouble();
  }

  static String _readString(Object? raw, String fallback) =>
      raw is String ? raw : fallback;

  static List<String> _readStringList(Object? raw) {
    if (raw is! List<Object?>) return const <String>[];
    return List<String>.unmodifiable(<String>[
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ]);
  }
}

/// 基于 [ScopedPrefsStore] 的视频播放偏好自治存取仓储（完全解耦状态管理框架）。
final class VideoPlaybackPreferencesStore {
  /// 创建视频偏好配置仓储实例。
  VideoPlaybackPreferencesStore(
    this._prefsStore, {
    this.eventBus,
    this.sourceDeviceId = '',
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ScopedPrefsStore _prefsStore;
  final DomainEventBus? eventBus;
  final String sourceDeviceId;
  final int Function() _nowMs;

  /// 同步读取当前生效的视频播放偏好配置。
  VideoPlaybackPreferences read() => _prefsStore.read(videoPlaybackPrefsSlice);

  /// 响应式订阅视频播放偏好切片变化流。
  Stream<VideoPlaybackPreferences> watch() =>
      _prefsStore.watch(videoPlaybackPrefsSlice);

  /// 覆盖写入完整偏好配置并向领域事件总线发布低频变更通知。
  void write(VideoPlaybackPreferences next) {
    final now = _nowMs();
    _prefsStore.write(
      videoPlaybackPrefsSlice,
      next,
      sourceDeviceId: sourceDeviceId,
      updatedAtMs: now,
    );
    eventBus?.publish(
      PrefsSliceChangedEvent(
        namespace: VideoPlaybackPreferences.prefsNamespace,
        occurredAtMs: now,
      ),
    );
  }

  /// 通过函数式更新器原子改写部分偏好配置并持久化。
  VideoPlaybackPreferences update(
    VideoPlaybackPreferences Function(VideoPlaybackPreferences current) updater,
  ) {
    final current = read();
    final next = updater(current);
    if (next == current) {
      return current;
    }
    write(next);
    return next;
  }

  /// 更新默认音视频播放引擎路由。
  void setPreferredEngine(PreferredPlaybackEngine engine) {
    update((current) => current.copyWith(preferredEngine: engine));
  }

  /// 批量替换内置画质与音画参数子模型。
  void updateQualityConfig(
    PlaybackQualityConfig Function(PlaybackQualityConfig current) updater,
  ) {
    update(
      (current) => current.copyWith(qualityConfig: updater(current.qualityConfig)),
    );
  }

  /// 更新默认音量与静音状态。
  void setVolumeAndMute({double? volume, bool? isMuted}) {
    update(
      (current) => current.copyWith(
        volume: volume?.clamp(0.0, 1.0).toDouble() ?? current.volume,
        isMuted: isMuted ?? current.isMuted,
      ),
    );
  }

  /// 切换指定着色器脚本的启用状态并保持选定顺序。
  void toggleShaderPath(String shaderPath, bool enabled) {
    final trimmed = shaderPath.trim();
    if (trimmed.isEmpty) return;
    updateQualityConfig((quality) {
      final list = List<String>.of(quality.activeShaderPaths);
      if (enabled) {
        if (!list.contains(trimmed)) {
          list.add(trimmed);
        }
      } else {
        list.remove(trimmed);
      }
      return quality.copyWith(
        activeShaderPaths: List<String>.unmodifiable(list),
      );
    });
  }

  /// 更新片头片尾章节自动跳过开关。
  void setAutoSkipChapters(bool enabled) {
    update((current) => current.copyWith(autoSkipChapters: enabled));
  }

  /// 更新正片结束后自动连播下一集开关。
  void setAutoPlayNextEpisode(bool enabled) {
    update((current) => current.copyWith(autoPlayNextEpisode: enabled));
  }

  /// 更新切入迷你窗或后台保持声音继续播放开关。
  void setBackgroundAudioOnMinimize(bool enabled) {
    update((current) => current.copyWith(backgroundAudioOnMinimize: enabled));
  }

  /// 更新云端字体子集化功能开关及服务端地址。
  void updateCloudSubsetSettings({
    bool? enabled,
    String? endpointUrl,
  }) {
    update(
      (current) => current.copyWith(
        enableCloudSubset: enabled ?? current.enableCloudSubset,
        fontInAssEndpoint: endpointUrl ?? current.fontInAssEndpoint,
      ),
    );
  }

  /// 授予指定服务来源地址的云端字体子集化访问权限。
  void authorizeCloudSubsetOrigin(String origin) {
    final trimmed = origin.trim();
    if (trimmed.isEmpty) return;
    update((current) {
      if (current.authorizedCloudSubsetOrigins.contains(trimmed)) {
        return current;
      }
      return current.copyWith(
        authorizedCloudSubsetOrigins: List<String>.unmodifiable(<String>[
          ...current.authorizedCloudSubsetOrigins,
          trimmed,
        ]),
      );
    });
  }

  /// 撤销指定服务来源地址的云端字体子集化访问权限。
  void revokeCloudSubsetOrigin(String origin) {
    final trimmed = origin.trim();
    if (trimmed.isEmpty) return;
    update(
      (current) => current.copyWith(
        authorizedCloudSubsetOrigins: List<String>.unmodifiable(<String>[
          for (final item in current.authorizedCloudSubsetOrigins)
            if (item != trimmed) item,
        ]),
      ),
    );
  }

  /// 更新发烧音频路由相关高级开关。
  void setAudiophileFlags({
    bool? bitstreamPassthrough,
    bool? androidBitPerfectUsb,
  }) {
    update(
      (current) => current.copyWith(
        bitstreamPassthrough:
            bitstreamPassthrough ?? current.bitstreamPassthrough,
        androidBitPerfectUsb:
            androidBitPerfectUsb ?? current.androidBitPerfectUsb,
      ),
    );
  }

  /// 记录不再重复弹出外接控制组件提示。
  void setSkipFoobarBeefwebGuidePrompt(bool skip) {
    update((current) => current.copyWith(skipFoobarBeefwebGuidePrompt: skip));
  }
}
