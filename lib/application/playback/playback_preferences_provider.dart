import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../composition/platform_composition.dart';
import '../../domain/playback/track_preferences.dart';
import '../../infrastructure/players/android/android_audio_route_bridge.dart';
import '../../infrastructure/players/mpv_quality_profile.dart';
import '../../infrastructure/storage/storage_root_provider.dart';
import '../../infrastructure/subtitles/fontinass_cloud_client.dart';
import '../../infrastructure/subtitles/subtitle_font_pool_manager.dart';
import 'cloud_subset_coordinator.dart';
import 'unified_playback_engine.dart';

/// 全局默认音视频播放引擎路由偏好。
enum PreferredPlaybackEngine {
  /// 默认使用内置高保真 `libmpv`（底层高色深表面 / 纯音频 `vid=no`）。
  builtinLibmpv('内置高保真引擎 (libmpv)'),

  /// 默认拉起桌面已配置的外部程序接力。
  desktopRelay('外部播放器');

  const PreferredPlaybackEngine(this.label);

  /// 界面展示名称。
  final String label;
}

/// 音视频全局播放与音画还原偏好不可变状态模型。
class PlaybackPreferencesState {
  /// 创建播放偏好状态。
  const PlaybackPreferencesState({
    this.defaultVideoEngine = PreferredPlaybackEngine.builtinLibmpv,
    this.defaultAudioEngine = PreferredPlaybackEngine.builtinLibmpv,
    this.preferredRelayKindKey = 'mpv',
    this.qualityConfig = const PlaybackQualityConfig(),
    this.autoNextEpisode = true,
    this.promptChapterSkip = true,
    this.autoSkipChapter = false,
    this.autoEnterPip = true,
    this.defaultVolume = 100.0,
    this.bitstreamPassthrough = false,
    this.androidBitPerfectUsb = false,
    this.cloudSubsetEnabled = false,
    this.cloudSubsetEndpoint = '',
  });

  /// 默认视频（正片 / 特典）播放引擎。
  final PreferredPlaybackEngine defaultVideoEngine;

  /// 默认 CD 音频播放引擎。
  final PreferredPlaybackEngine defaultAudioEngine;

  /// 当使用桌面外部接力时的首选目标类型键名（默认 `mpv`）。
  final String preferredRelayKindKey;

  /// 内置 `libmpv` 画质、音频与字幕配置参数。
  final PlaybackQualityConfig qualityConfig;

  /// 当前集播完是否自动无缝连播下一话正片（并继承音轨/字幕选择）。
  final bool autoNextEpisode;

  /// 检测到 OP / ED 章节区间时是否在右下角弹出 4 秒智能跳过提示。
  final bool promptChapterSkip;

  /// 是否直接自动跳过检测到的 OP / ED（默认关闭，推荐温和提示）。
  final bool autoSkipChapter;

  /// Android 视频播放期间切入系统后台时是否自动开启画中画（默认开启）。
  final bool autoEnterPip;

  /// 内置播放器默认初始音量（`0 ~ 100`）。
  final double defaultVolume;

  /// 桌面端 `audio-spdif` 比特流源码直通（开启时与一切软件 DSP 严格互斥）。
  final bool bitstreamPassthrough;

  /// Android 14+ 原生 `MIXER_BEHAVIOR_BIT_PERFECT` USB DAC 逐位直通偏好。
  final bool androidBitPerfectUsb;

  /// 是否启用可选 FontInAss 云端字幕字体子集化（默认关闭，且需逐 Origin 授权）。
  final bool cloudSubsetEnabled;

  /// 可选 FontInAss 云端字幕字体子集化服务端点地址。
  final String cloudSubsetEndpoint;

  /// 复制并修改局部偏好字段。
  PlaybackPreferencesState copyWith({
    PreferredPlaybackEngine? defaultVideoEngine,
    PreferredPlaybackEngine? defaultAudioEngine,
    String? preferredRelayKindKey,
    PlaybackQualityConfig? qualityConfig,
    bool? autoNextEpisode,
    bool? promptChapterSkip,
    bool? autoSkipChapter,
    bool? autoEnterPip,
    double? defaultVolume,
    bool? bitstreamPassthrough,
    bool? androidBitPerfectUsb,
    bool? cloudSubsetEnabled,
    String? cloudSubsetEndpoint,
  }) {
    return PlaybackPreferencesState(
      defaultVideoEngine: defaultVideoEngine ?? this.defaultVideoEngine,
      defaultAudioEngine: defaultAudioEngine ?? this.defaultAudioEngine,
      preferredRelayKindKey:
          preferredRelayKindKey ?? this.preferredRelayKindKey,
      qualityConfig: qualityConfig ?? this.qualityConfig,
      autoNextEpisode: autoNextEpisode ?? this.autoNextEpisode,
      promptChapterSkip: promptChapterSkip ?? this.promptChapterSkip,
      autoSkipChapter: autoSkipChapter ?? this.autoSkipChapter,
      autoEnterPip: autoEnterPip ?? this.autoEnterPip,
      defaultVolume: defaultVolume ?? this.defaultVolume,
      bitstreamPassthrough: bitstreamPassthrough ?? this.bitstreamPassthrough,
      androidBitPerfectUsb: androidBitPerfectUsb ?? this.androidBitPerfectUsb,
      cloudSubsetEnabled: cloudSubsetEnabled ?? this.cloudSubsetEnabled,
      cloudSubsetEndpoint: cloudSubsetEndpoint ?? this.cloudSubsetEndpoint,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PlaybackPreferencesState &&
        other.defaultVideoEngine == defaultVideoEngine &&
        other.defaultAudioEngine == defaultAudioEngine &&
        other.preferredRelayKindKey == preferredRelayKindKey &&
        other.qualityConfig == qualityConfig &&
        other.autoNextEpisode == autoNextEpisode &&
        other.promptChapterSkip == promptChapterSkip &&
        other.autoSkipChapter == autoSkipChapter &&
        other.autoEnterPip == autoEnterPip &&
        other.defaultVolume == defaultVolume &&
        other.bitstreamPassthrough == bitstreamPassthrough &&
        other.androidBitPerfectUsb == androidBitPerfectUsb &&
        other.cloudSubsetEnabled == cloudSubsetEnabled &&
        other.cloudSubsetEndpoint == cloudSubsetEndpoint;
  }

  @override
  int get hashCode => Object.hash(
    defaultVideoEngine,
    defaultAudioEngine,
    preferredRelayKindKey,
    qualityConfig,
    autoNextEpisode,
    promptChapterSkip,
    autoSkipChapter,
    autoEnterPip,
    defaultVolume,
    bitstreamPassthrough,
    androidBitPerfectUsb,
    cloudSubsetEnabled,
    cloudSubsetEndpoint,
  );
}

/// 全局音视频播放与音画还原偏好状态管理器（`SharedPreferences` 本地持久化）。
class PlaybackPreferencesNotifier
    extends StateNotifier<PlaybackPreferencesState> {
  /// 创建播放偏好管理器。
  PlaybackPreferencesNotifier({
    this.enablePersistence = true,
    this.desktopDelegate,
  }) : super(const PlaybackPreferencesState()) {
    if (enablePersistence) {
      unawaited(_loadFromPrefs());
    }
  }

  static const String _prefsKey = 'konata.playback.preferences.v1';

  /// 是否启用本地 SharedPreferences 持久化（单测可置 false）。
  final bool enablePersistence;

  /// 可选桌面平台参数委托（用于兼容旧桌面配置键迁移，Android 端为 `null`）。
  final MpvPlatformProfileDelegate? desktopDelegate;

  Future<void> _loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty || !mounted) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) return;
      state = _decodeState(decoded, delegate: desktopDelegate);
    } catch (error) {
      // 无插件单测环境下保持默认值安全运行。
      developer.log(
        '可恢复异常已记录',
        name: 'konata.playback_preferences_provider',
        error: error,
      );
    }
  }

  /// 切换默认视频播放引擎。
  Future<void> setDefaultVideoEngine(PreferredPlaybackEngine engine) async {
    state = state.copyWith(defaultVideoEngine: engine);
    await _persist();
  }

  /// 切换默认 CD 音频播放引擎。
  Future<void> setDefaultAudioEngine(PreferredPlaybackEngine engine) async {
    state = state.copyWith(defaultAudioEngine: engine);
    await _persist();
  }

  /// 切换首选桌面视频接力目标类型键名。
  Future<void> setPreferredRelayKindKey(String kindKey) async {
    final trimmed = kindKey.trim();
    if (trimmed.isEmpty) return;
    state = state.copyWith(preferredRelayKindKey: trimmed);
    await _persist();
  }

  /// 原子更新内部画质/音频/字幕配置。
  Future<void> updateQualityConfig(
    PlaybackQualityConfig Function(PlaybackQualityConfig current) updater,
  ) async {
    state = state.copyWith(qualityConfig: updater(state.qualityConfig));
    await _persist();
  }

  /// 切换视频画质预设。
  Future<void> setPreset(VideoQualityPreset preset) =>
      updateQualityConfig((c) => c.copyWith(preset: preset));

  /// 切换硬件解码。
  Future<void> setHardwareDecode(bool value) =>
      updateQualityConfig((c) => c.copyWith(hardwareDecode: value));

  /// 切换去色带（Deband）。
  Future<void> setDebandEnabled(bool value) =>
      updateQualityConfig((c) => c.copyWith(debandEnabled: value));

  /// 切换音频独占直通模式。
  Future<void> setExclusiveAudioOutput(bool value) =>
      updateQualityConfig((c) => c.copyWith(exclusiveAudioOutput: value));

  /// 更新 `soxr` 音频重采样精度（`16 ~ 33`）。
  Future<void> setAudioResamplerPrecision(int precision) => updateQualityConfig(
    (c) => c.copyWith(audioResamplerPrecision: precision.clamp(16, 33)),
  );

  /// 更新默认输出音频设备。
  Future<void> setAudioDevice(String device) =>
      updateQualityConfig((c) => c.copyWith(audioDevice: device));

  /// 开关指定 GLSL 着色器。
  Future<void> toggleShaderPath(String shaderPath, bool enabled) {
    return updateQualityConfig((c) {
      final list = List<String>.from(c.activeShaderPaths);
      if (enabled) {
        if (!list.contains(shaderPath)) {
          list.add(shaderPath);
        }
      } else {
        list.remove(shaderPath);
      }
      return c.copyWith(activeShaderPaths: list);
    });
  }

  /// 批量替换激活着色器链。
  Future<void> setActiveShaderPaths(List<String> paths) =>
      updateQualityConfig((c) => c.copyWith(activeShaderPaths: List.of(paths)));

  /// 切换高色深桌面视频输出管线模式（默认原生 10-bit/HDR `vo=gpu-next` 底层直通）。
  Future<void> setOutputPipelineMode(VideoOutputPipelineMode mode) =>
      updateQualityConfig((c) => c.copyWith(outputPipelineMode: mode));

  /// 更新默认字幕字号。
  Future<void> setSubFontSize(int size) =>
      updateQualityConfig((c) => c.copyWith(subFontSize: size.clamp(24, 96)));

  /// 更新默认字幕底部边距。
  Future<void> setSubBottomMargin(int margin) => updateQualityConfig(
    (c) => c.copyWith(subBottomMargin: margin.clamp(0, 120)),
  );

  /// 更新字幕 ASS 样式覆写模式。
  Future<void> setSubOverrideMode(SubtitleAssOverrideMode mode) =>
      updateQualityConfig((c) => c.copyWith(subOverrideMode: mode));

  /// 更新默认倍速。
  Future<void> setDefaultSpeed(double speed) => updateQualityConfig(
    (c) => c.copyWith(defaultSpeed: speed.clamp(0.25, 4.0)),
  );

  /// 切换变速音调保留。
  Future<void> setKeepPitch(bool value) =>
      updateQualityConfig((c) => c.copyWith(keepPitch: value));

  /// 切换自动连播下一集。
  Future<void> setAutoNextEpisode(bool value) async {
    state = state.copyWith(autoNextEpisode: value);
    await _persist();
  }

  /// 切换智能 OP/ED 跳过提示开关。
  Future<void> setPromptChapterSkip(bool value) async {
    state = state.copyWith(promptChapterSkip: value);
    await _persist();
  }

  /// 切换检测到 OP/ED 时自动跳过。
  Future<void> setAutoSkipChapter(bool value) async {
    state = state.copyWith(autoSkipChapter: value);
    await _persist();
  }

  /// 切换切入后台自动开启画中画开关。
  Future<void> setAutoEnterPip(bool value) async {
    state = state.copyWith(autoEnterPip: value);
    await _persist();
  }

  /// 更新默认音量。
  Future<void> setDefaultVolume(double value) async {
    state = state.copyWith(defaultVolume: value.clamp(0.0, 100.0));
    await _persist();
  }

  /// 切换比特流源码直通（开启时自动与软件 DSP 严格互斥）。
  Future<void> setBitstreamPassthrough(bool value) async {
    state = state.copyWith(bitstreamPassthrough: value);
    await _persist();
  }

  /// 切换 Android 14+ USB DAC `MIXER_BEHAVIOR_BIT_PERFECT` 逐位直通偏好。
  Future<void> setAndroidBitPerfectUsb(bool value) async {
    state = state.copyWith(androidBitPerfectUsb: value);
    await _persist();
  }

  /// 切换可选 FontInAss 云端字幕字体子集化总开关。
  Future<void> setCloudSubsetEnabled(bool value) async {
    state = state.copyWith(cloudSubsetEnabled: value);
    await _persist();
  }

  /// 更新可选 FontInAss 云端字幕字体子集化服务端点地址。
  Future<void> setCloudSubsetEndpoint(String endpoint) async {
    state = state.copyWith(cloudSubsetEndpoint: endpoint.trim());
    await _persist();
  }

  Future<void> _persist() async {
    if (!enablePersistence) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_encodeState(state)));
    } catch (e) {
      debugPrint('保存播放偏好配置失败：$e');
    }
  }

  static Map<String, Object?> _encodeState(PlaybackPreferencesState s) {
    final q = s.qualityConfig;
    return {
      'defaultVideoEngine': s.defaultVideoEngine.name,
      'defaultAudioEngine': s.defaultAudioEngine.name,
      'preferredRelayKindKey': s.preferredRelayKindKey,
      'autoNextEpisode': s.autoNextEpisode,
      'promptChapterSkip': s.promptChapterSkip,
      'autoSkipChapter': s.autoSkipChapter,
      'autoEnterPip': s.autoEnterPip,
      'defaultVolume': s.defaultVolume,
      'bitstreamPassthrough': s.bitstreamPassthrough,
      'androidBitPerfectUsb': s.androidBitPerfectUsb,
      'cloudSubsetEnabled': s.cloudSubsetEnabled,
      'cloudSubsetEndpoint': s.cloudSubsetEndpoint,
      'preset': q.preset.name,
      'outputPipelineMode': q.outputPipelineMode.bridgeKey,
      'outputPipelineSchemaVersion': 2,
      'hardwareDecode': q.hardwareDecode,
      'debandEnabled': q.debandEnabled,
      'demuxerMaxBytesMiB': q.demuxerMaxBytesMiB,
      'demuxerMaxBackBytesMiB': q.demuxerMaxBackBytesMiB,
      'cacheSecs': q.cacheSecs,
      'audioResamplerPrecision': q.audioResamplerPrecision,
      'exclusiveAudioOutput': q.exclusiveAudioOutput,
      'audioDevice': q.audioDevice,
      'activeShaderPaths': q.activeShaderPaths,
      'defaultSpeed': q.defaultSpeed,
      'keepPitch': q.keepPitch,
      'subFontSize': q.subFontSize,
      'subFontName': q.subFontName,
      'subBottomMargin': q.subBottomMargin,
      'subOverrideMode': q.subOverrideMode.name,
      'subColorHex': q.subColorHex,
    };
  }

  static PlaybackPreferencesState _decodeState(
    Map<Object?, Object?> rawMap, {
    MpvPlatformProfileDelegate? delegate,
  }) {
    final map = delegate?.normalizeLegacyPreferenceMap(rawMap) ?? rawMap;

    T parseEnum<T extends Enum>(List<T> values, Object? raw, T fallback) {
      if (raw is! String) return fallback;
      for (final item in values) {
        if (item.name == raw) return item;
      }
      return fallback;
    }

    int parseInt(Object? raw, int fallback, int min, int max) {
      final v = raw is num ? raw.toInt() : fallback;
      return v.clamp(min, max);
    }

    double parseDouble(Object? raw, double fallback, double min, double max) {
      final v = raw is num ? raw.toDouble() : fallback;
      return v.clamp(min, max);
    }

    final rawShaders = map['activeShaderPaths'];
    final shaders = rawShaders is List
        ? rawShaders
              .whereType<String>()
              .where((s) => s.trim().isNotEmpty)
              .toList()
        : const <String>[];

    final relayKind = map['preferredRelayKindKey'];
    return PlaybackPreferencesState(
      defaultVideoEngine: parseEnum(
        PreferredPlaybackEngine.values,
        map['defaultVideoEngine'],
        PreferredPlaybackEngine.builtinLibmpv,
      ),
      defaultAudioEngine: parseEnum(
        PreferredPlaybackEngine.values,
        map['defaultAudioEngine'],
        PreferredPlaybackEngine.builtinLibmpv,
      ),
      preferredRelayKindKey: relayKind is String && relayKind.trim().isNotEmpty
          ? relayKind.trim()
          : 'mpv',
      autoNextEpisode: map['autoNextEpisode'] is bool
          ? map['autoNextEpisode'] as bool
          : true,
      promptChapterSkip: map['promptChapterSkip'] is bool
          ? map['promptChapterSkip'] as bool
          : true,
      autoSkipChapter: map['autoSkipChapter'] is bool
          ? map['autoSkipChapter'] as bool
          : false,
      autoEnterPip: map['autoEnterPip'] is bool
          ? map['autoEnterPip'] as bool
          : true,
      defaultVolume: parseDouble(map['defaultVolume'], 100.0, 0.0, 100.0),
      bitstreamPassthrough: map['bitstreamPassthrough'] is bool
          ? map['bitstreamPassthrough'] as bool
          : false,
      androidBitPerfectUsb: map['androidBitPerfectUsb'] is bool
          ? map['androidBitPerfectUsb'] as bool
          : false,
      cloudSubsetEnabled: map['cloudSubsetEnabled'] is bool
          ? map['cloudSubsetEnabled'] as bool
          : false,
      cloudSubsetEndpoint: map['cloudSubsetEndpoint'] is String
          ? (map['cloudSubsetEndpoint'] as String).trim()
          : '',
      qualityConfig: PlaybackQualityConfig(
        preset: parseEnum(
          VideoQualityPreset.values,
          map['preset'],
          VideoQualityPreset.highFidelity,
        ),
        outputPipelineMode: () {
          final parsed = VideoOutputPipelineMode.parse(
            map['outputPipelineMode'],
            delegate: delegate,
          );
          final schemaVersion = map['outputPipelineSchemaVersion'] is num
              ? (map['outputPipelineSchemaVersion'] as num).toInt()
              : 1;
          if (schemaVersion < 2 &&
              parsed == VideoOutputPipelineMode.gpuNextUnderlay) {
            return VideoOutputPipelineMode.legacyTextureFallback;
          }
          return parsed;
        }(),
        hardwareDecode: map['hardwareDecode'] is bool
            ? map['hardwareDecode'] as bool
            : true,
        debandEnabled: map['debandEnabled'] is bool
            ? map['debandEnabled'] as bool
            : false,
        demuxerMaxBytesMiB: parseInt(
          map['demuxerMaxBytesMiB'],
          PlaybackQualityConfig.defaultDemuxerMaxBytesMiB,
          16,
          512,
        ),
        demuxerMaxBackBytesMiB: parseInt(
          map['demuxerMaxBackBytesMiB'],
          PlaybackQualityConfig.defaultDemuxerMaxBackBytesMiB,
          8,
          256,
        ),
        cacheSecs: parseInt(
          map['cacheSecs'],
          PlaybackQualityConfig.defaultCacheSecs,
          10,
          600,
        ),
        audioResamplerPrecision: parseInt(
          map['audioResamplerPrecision'],
          PlaybackQualityConfig.defaultSoxrPrecision,
          16,
          33,
        ),
        exclusiveAudioOutput: map['exclusiveAudioOutput'] is bool
            ? map['exclusiveAudioOutput'] as bool
            : false,
        audioDevice:
            map['audioDevice'] is String &&
                (map['audioDevice'] as String).trim().isNotEmpty
            ? (map['audioDevice'] as String).trim()
            : PlaybackQualityConfig.defaultAudioDevice,
        activeShaderPaths: shaders,
        defaultSpeed: parseDouble(map['defaultSpeed'], 1.0, 0.25, 4.0),
        keepPitch: map['keepPitch'] is bool ? map['keepPitch'] as bool : true,
        subFontSize: parseInt(
          map['subFontSize'],
          PlaybackQualityConfig.defaultSubFontSize,
          24,
          96,
        ),
        subFontName: map['subFontName'] is String
            ? (map['subFontName'] as String)
            : '',
        subBottomMargin: parseInt(
          map['subBottomMargin'],
          PlaybackQualityConfig.defaultSubBottomMargin,
          0,
          120,
        ),
        subOverrideMode: parseEnum(
          SubtitleAssOverrideMode.values,
          map['subOverrideMode'],
          SubtitleAssOverrideMode.preserveAss,
        ),
        subColorHex:
            map['subColorHex'] is String &&
                (map['subColorHex'] as String).trim().isNotEmpty
            ? (map['subColorHex'] as String).trim()
            : PlaybackQualityConfig.defaultSubColorHex,
      ),
    );
  }
}

/// 全局播放与音画偏好 Provider。
final playbackPreferencesProvider =
    StateNotifierProvider<
      PlaybackPreferencesNotifier,
      PlaybackPreferencesState
    >(
      (ref) => PlaybackPreferencesNotifier(
        desktopDelegate: ref.watch(mpvPlatformProfileDelegateProvider),
      ),
    );

/// 内嵌 `libmpv` 与 `FFmpeg` 运行时实时探测结果 Provider。
final mpvRuntimeVersionsProvider = FutureProvider<MpvRuntimeVersions>((ref) {
  final engine = ref.read(unifiedPlaybackEngineProvider);
  return MpvQualityProfile.probeRuntimeVersions(
    clientFactory: engine.createAuxiliaryNativeClient,
  );
});

/// 内置视频页活跃状态标记（`true` 时自动收起全局迷你音频底栏并协调音视频互斥）。
final videoPlaybackActiveProvider = StateProvider<bool>((ref) => false);

/// 全屏流光沉浸音频页展开状态标记。
final immersiveAudioExpandedProvider = StateProvider<bool>((ref) => false);

/// 供悬浮在 `MaterialApp.builder` 中的全局音频/组件导航使用的根导航键 Provider。
final rootNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => GlobalKey<NavigatorState>(),
);

/// 内置视频会话生命周期串行异步互斥锁（彻底消除快速关闭后立即重开同一文件的 Native 销毁竞态）。
class EmbeddedSessionMutex {
  Future<void> _tail = Future<void>.value();

  /// 将关键初始化与异步销毁流程排入严格 FIFO 串行队列执行。
  Future<T> runExclusive<T>(Future<T> Function() action) {
    final prev = _tail;
    final completer = Completer<void>();
    _tail = completer.future;

    return prev.catchError((Object _) {}).then((_) async {
      try {
        return await action();
      } finally {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });
  }
}

/// 全局内置视频会话串行互斥锁 Provider。
final embeddedSessionMutexProvider = Provider<EmbeddedSessionMutex>(
  (ref) => EmbeddedSessionMutex(),
);

/// 逐 Origin 云端子集化授权白名单持久化键名。
const String kCloudSubsetAuthorizedOriginsPrefsKey =
    'konata.cloud_subset.authorized_origins.v1';

/// 云端子集化逐 Origin 授权状态仓储 Provider（由 Riverpod 统一托管生命周期并持久化至 SharedPreferences）。
final cloudSubsetAuthorizationStoreProvider =
    Provider<CloudSubsetAuthorizationStore>((ref) {
      return CloudSubsetAuthorizationStore(
        onLoad: () async {
          final prefs = await SharedPreferences.getInstance();
          return prefs.getStringList(kCloudSubsetAuthorizedOriginsPrefsKey) ??
              const <String>[];
        },
        onPersist: (originKeys) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(
            kCloudSubsetAuthorizedOriginsPrefsKey,
            originKeys,
          );
        },
        onHydrated: () {
          try {
            ref.read(cloudSubsetAuthRevisionProvider.notifier).state += 1;
          } on StateError catch (error) {
  // 容器已销毁时忽略刷新通知。
  developer.log('可恢复异常已记录', name: 'konata.playback_preferences_provider', error: error);
}
        },
      );
    });

/// 全站唯一字幕字库原位直挂与单级哈希池（3 集合热租约）管理器 Provider。
final subtitleFontPoolManagerProvider = Provider<SubtitleFontPoolManager>(
  (ref) => SubtitleFontPoolManager(
    storageRoot: ref.read(storageRootProvider),
  ),
);

/// FontInAss 云端子集化纯净客户端 Provider。
final fontInAssCloudClientProvider = Provider<FontInAssCloudClient>(
  (ref) => FontInAssCloudClient(
    authorizationStore: ref.read(cloudSubsetAuthorizationStoreProvider),
    storageRoot: ref.read(storageRootProvider),
  ),
);

/// 云端子集化按域编排协调器 Provider（仅取消 `PlaybackTaskDomain.cloudSubset` 分域）。
final cloudSubsetCoordinatorProvider = Provider<CloudSubsetCoordinator>(
  (ref) => CloudSubsetCoordinator(
    playbackEngine: ref.read(unifiedPlaybackEngineProvider),
    cloudClient: ref.read(fontInAssCloudClientProvider),
  ),
);

/// 云端子集化 Origin 授权变更轻量刷新版本号（驱动设置页授权徽章即时同步）。
final cloudSubsetAuthRevisionProvider = StateProvider<int>((ref) => 0);

/// Android 原生音频路由与外设拔出瞬态静音通道桥接 Provider（由 Riverpod 统一托管生命周期）。
final androidAudioRouteBridgeProvider = Provider<AndroidAudioRouteBridge>((
  ref,
) {
  final bridge = AndroidAudioRouteBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});
